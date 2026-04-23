<#
.SYNOPSIS
    Compares two DFS namespace XML exports to find removed links/targets and
    generates a removals-fix CSV consumable by Repair-DfsTargetsFromCsv.ps1.

.DESCRIPTION
    Takes a "before" and "after" dfsutil XML export for the same DFS server and
    determines which DFS links or targets were removed between the two snapshots.

    For every link/target present in the "before" XML but missing in the "after"
    XML, a row is written to the output CSV with the standard removals schema:
        Timestamp, DfsServer, LinkPath, TargetPath, Reason, Status

    The output CSV is directly consumable by Repair-DfsTargetsFromCsv.ps1 for
    recovery of incorrectly removed targets.

    Three types of removals are detected:
      1. Entire links removed — all targets under a link that no longer exists.
      2. Individual targets removed — a target that was dropped from a link that
         still exists.
      3. Target state changes — a target whose State changed from Online (2) to
         a non-Online state.

.PARAMETER BeforeXmlPath
    Path to the "before" DFS namespace XML export (the baseline / known-good state).

.PARAMETER AfterXmlPath
    Path to the "after" DFS namespace XML export (the current / post-change state).

.PARAMETER OutputCsvPath
    Path to the output removals-fix CSV. When omitted, a timestamped file is
    created under the results\ folder next to this script.

.PARAMETER IncludeStateChanges
    When set, also reports targets whose State changed from Online to a non-Online
    state (even if the target still exists in the after XML).

.EXAMPLE
    .\Compare-DfsNamespaceXml.ps1 `
        -BeforeXmlPath ".\Data\DFSSERVER01\Builds.PossibleDesctructive.xml" `
        -AfterXmlPath  ".\Data\DFSSERVER01\Builds.xml"

.EXAMPLE
    .\Compare-DfsNamespaceXml.ps1 `
        -BeforeXmlPath ".\Data\DFSSERVER02\Builds.Before.xml" `
        -AfterXmlPath  ".\Data\DFSSERVER02\Builds.xml" `
        -OutputCsvPath  ".\results\removals_fix_DFSSERVER02.csv"

.EXAMPLE
    .\Compare-DfsNamespaceXml.ps1 `
        -BeforeXmlPath ".\Data\DFSSERVER01\Builds.PossibleDesctructive.xml" `
        -AfterXmlPath  ".\Data\DFSSERVER01\Builds.xml" `
        -IncludeStateChanges

.NOTES
    The XML files are expected to be dfsutil /export output with the structure:
        <Root Name="\\SERVER\Namespace" ...>
          <Link Name="branches\branch\build" ...>
            <Target Server="FILESERVER" Folder="drops\branch\build" State="2" />
          </Link>
        </Root>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="Path to the 'before' DFS namespace XML export.")]
    [string] $BeforeXmlPath,

    [Parameter(Mandatory=$true, HelpMessage="Path to the 'after' DFS namespace XML export.")]
    [string] $AfterXmlPath,

    [Parameter(Mandatory=$false, HelpMessage="Path to the output removals-fix CSV.")]
    [string] $OutputCsvPath,

    [Parameter(Mandatory=$false, HelpMessage="Also report targets whose state changed from Online to non-Online.")]
    [switch] $IncludeStateChanges
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# Validate inputs
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $BeforeXmlPath)) {
    Write-Error "Before XML not found: $BeforeXmlPath"
    return
}
if (-not (Test-Path $AfterXmlPath)) {
    Write-Error "After XML not found: $AfterXmlPath"
    return
}
if ((Get-Item $BeforeXmlPath).Length -eq 0) {
    Write-Error "Before XML is empty (0 bytes): $BeforeXmlPath"
    return
}
if ((Get-Item $AfterXmlPath).Length -eq 0) {
    Write-Error "After XML is empty (0 bytes): $AfterXmlPath"
    return
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve output path
# ─────────────────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $resultsDir = Join-Path $PSScriptRoot "results"
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    }
    $OutputCsvPath = Join-Path $resultsDir "removals_fix_$timestamp.csv"
}

$outputDir = Split-Path -Path $OutputCsvPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Parse a dfsutil XML into a structured hashtable
#   Returns: @{ "linkName" => @{ Targets = @( @{Server;Folder;State;TargetKey} ); LinkState } }
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-DfsLinkMap {
    param(
        [xml] $Xml
    )

    $rootName = $Xml.Root.Name
    $map = [ordered]@{}

    $links = $Xml.Root.Link
    if ($null -eq $links) {
        return @{ RootName = $rootName; Links = $map }
    }

    foreach ($link in @($links)) {
        $linkName = [string]$link.Name
        $targets = @()

        if ($null -ne $link.Target) {
            foreach ($t in @($link.Target)) {
                $server = [string]$t.Server
                $folder = [string]$t.Folder
                $state  = [string]$t.State
                # Canonical key for matching: lowercase server + folder
                $targetKey = "$($server.ToLowerInvariant())|$($folder.ToLowerInvariant())"
                $targets += @{
                    Server    = $server
                    Folder    = $folder
                    State     = $state
                    TargetKey = $targetKey
                }
            }
        }

        $map[$linkName] = @{
            LinkState = [string]$link.State
            Targets   = $targets
        }
    }

    return @{ RootName = $rootName; Links = $map }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Extract DFS server name from the Root Name attribute
#   e.g. "\\DFSSERVER01.yourdomain.example.com\Builds" => "DFSSERVER01"
# ─────────────────────────────────────────────────────────────────────────────

function Get-DfsServerFromRoot {
    param([string] $RootName)
    # Strip leading backslashes, take the server part, remove domain suffix
    $serverFqdn = ($RootName.TrimStart('\') -split '\\')[0]
    $shortName = ($serverFqdn -split '\.')[0]
    return $shortName
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Build the DFS folder path for a link
# ─────────────────────────────────────────────────────────────────────────────

function Get-DfsFolderPath {
    param(
        [string] $DfsServer,
        [string] $Namespace,
        [string] $LinkName
    )
    return "\\$DfsServer\$Namespace\$($LinkName.TrimStart('\'))"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Build the UNC target path
# ─────────────────────────────────────────────────────────────────────────────

function Get-TargetPath {
    param(
        [string] $Server,
        [string] $Folder
    )
    return "\\$Server\$Folder"
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse both XMLs
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "Loading before XML: $BeforeXmlPath" -ForegroundColor Gray
[xml]$beforeXml = Get-Content $BeforeXmlPath
$before = ConvertTo-DfsLinkMap -Xml $beforeXml

Write-Host "Loading after XML:  $AfterXmlPath" -ForegroundColor Gray
[xml]$afterXml = Get-Content $AfterXmlPath
$after = ConvertTo-DfsLinkMap -Xml $afterXml

$dfsServer = Get-DfsServerFromRoot -RootName $before.RootName
$namespace = ($before.RootName.TrimStart('\') -split '\\')[1]

Write-Host ""
Write-Host "DFS Server:   $dfsServer" -ForegroundColor Cyan
Write-Host "Namespace:    $namespace" -ForegroundColor Cyan
Write-Host "Before links: $($before.Links.Count)" -ForegroundColor Cyan
Write-Host "After links:  $($after.Links.Count)" -ForegroundColor Cyan
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# Compare: find removed links and removed targets
# ─────────────────────────────────────────────────────────────────────────────

$removedRecords = @()
$now = (Get-Date).ToString("o")

$removedLinkCount   = 0
$removedTargetCount = 0
$stateChangeCount   = 0

foreach ($linkName in $before.Links.Keys) {
    $beforeLink = $before.Links[$linkName]
    $dfsFolderPath = Get-DfsFolderPath -DfsServer $dfsServer -Namespace $namespace -LinkName $linkName

    if (-not $after.Links.Contains($linkName)) {
        # Entire link was removed — emit a row for each target that was under it
        $removedLinkCount++
        foreach ($target in $beforeLink.Targets) {
            $targetPath = Get-TargetPath -Server $target.Server -Folder $target.Folder
            $removedRecords += [PSCustomObject]@{
                Timestamp  = $now
                DfsServer  = $dfsServer
                LinkPath   = $dfsFolderPath
                TargetPath = $targetPath
                Reason     = "Link removed (entire link missing in after XML)"
                Status     = "Removed"
            }
            $removedTargetCount++
        }
    } else {
        # Link still exists — check for removed or changed targets
        $afterLink = $after.Links[$linkName]
        $afterTargetKeys = @{}
        foreach ($t in $afterLink.Targets) {
            $afterTargetKeys[$t.TargetKey] = $t
        }

        foreach ($beforeTarget in $beforeLink.Targets) {
            $targetPath = Get-TargetPath -Server $beforeTarget.Server -Folder $beforeTarget.Folder

            if (-not $afterTargetKeys.ContainsKey($beforeTarget.TargetKey)) {
                # Target was removed from this link
                $removedRecords += [PSCustomObject]@{
                    Timestamp  = $now
                    DfsServer  = $dfsServer
                    LinkPath   = $dfsFolderPath
                    TargetPath = $targetPath
                    Reason     = "Target removed (present in before XML, missing in after XML)"
                    Status     = "Removed"
                }
                $removedTargetCount++
            } elseif ($IncludeStateChanges) {
                # Target still exists — check for state changes
                $afterTarget = $afterTargetKeys[$beforeTarget.TargetKey]
                if ($beforeTarget.State -eq "2" -and $afterTarget.State -ne "2") {
                    $removedRecords += [PSCustomObject]@{
                        Timestamp  = $now
                        DfsServer  = $dfsServer
                        LinkPath   = $dfsFolderPath
                        TargetPath = $targetPath
                        Reason     = "State changed from Online (2) to $($afterTarget.State)"
                        Status     = "Removed"
                    }
                    $stateChangeCount++
                }
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Write output CSV
# ─────────────────────────────────────────────────────────────────────────────

if ($removedRecords.Count -eq 0) {
    Write-Host "No removed links or targets found. The two XMLs are equivalent." -ForegroundColor Green
    return
}

$removedRecords | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Comparison Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Links only in before:        $removedLinkCount" -ForegroundColor Yellow
Write-Host "  Targets removed:             $removedTargetCount" -ForegroundColor Yellow
if ($IncludeStateChanges) {
    Write-Host "  State changes (Online->other): $stateChangeCount" -ForegroundColor Yellow
}
Write-Host "  Total rows written:          $($removedRecords.Count)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Output CSV: $OutputCsvPath" -ForegroundColor Green
Write-Host ""
Write-Host "To repair, run:" -ForegroundColor Gray
Write-Host "  .\Repair-DfsTargetsFromCsv.ps1 -RemovalsCsvPath `"$OutputCsvPath`" -WhatIf" -ForegroundColor Gray
