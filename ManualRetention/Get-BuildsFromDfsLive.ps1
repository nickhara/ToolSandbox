<#
.SYNOPSIS
    Queries live DFS servers and generates BuildsCache JSON files for Remove-OldBuilds.ps1.

.DESCRIPTION
    Connects to the specified DFS servers, exports their "Builds" namespace via dfsutil,
    parses the exported XML to extract unique fileserver + build path combinations,
    and writes one BuildsCache_<server>.json file per fileserver.

    This script produces identical output to Get-BuildsFromDfsBackup.ps1 but sources data
    from live DFS servers instead of backup XML files on disk.

    The output JSON matches the schema expected by Remove-OldBuilds.ps1 and includes
    DFS link metadata for optional DFS unlink workflows:
        { DfsFolderName, BuildNumber, CreationTime, State, DfsLinkPath }

.PARAMETER DfsServers
    Mandatory array of 2nd-level DFS server names to query live.
    Example: @("DFSSERVER01", "DFSSERVER02")

.PARAMETER Namespace
    DFS namespace to query on each server. Defaults to 'Builds'.

.PARAMETER OutputDirectory
    Where to write the BuildsCache_*.json files.
    Defaults to the ManualRetention directory.

.PARAMETER ResolveCreationTime
    When set, queries the filesystem for actual CreationTime values on each build path.
    Requires network access to the fileservers. Without this switch, CreationTime defaults
    to a very old date (2000-01-01) so all builds are eligible for retention.

.PARAMETER BranchNameFilter
    Wildcard filter applied to branch/DfsFolderName to limit scope. Defaults to '*' (all branches).

.PARAMETER FileServerFilter
    Wildcard filter applied to target fileserver names. Defaults to '*' (all fileservers).

.PARAMETER ExportDirectory
    Optional directory for storing exported DFS namespace XML files. When specified, the
    script writes exports here and reuses existing XMLs on subsequent runs, avoiding
    redundant dfsutil calls. When omitted, a temporary directory under %TEMP% is used
    (and cleaned up automatically when the script completes).

.PARAMETER ForceExport
    When set, forces re-export of DFS namespace XMLs even if the file already exists in
    ExportDirectory. Has no effect when ExportDirectory is not specified.

.PARAMETER ProgressFile
    Path to a JSON file used to track which fileservers have been fully processed. On
    restart, fileservers already recorded in this file are skipped, allowing the script
    to resume where it left off. When omitted, a default file named
    progress_GetBuildsFromDfsLive.json is created under a logs\ folder next to this script.

.PARAMETER ResetProgress
    When set, deletes the progress file before starting, forcing a full re-process of all
    fileservers.

.PARAMETER LogFilePath
    Optional path to the transcript log file. When omitted, a timestamped log file is
    created under a logs\ folder next to this script.

.PARAMETER ThrottleLimit
    Maximum number of concurrent CreationTime resolution calls when -ResolveCreationTime
    is enabled. Each call makes a network round-trip to resolve a DFS/UNC path, so this
    controls how many paths are resolved in parallel. Default is 20. Valid range: 1–256.
    Tune this based on network and DFS server capacity.

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01")

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01","DFSSERVER02") -ResolveCreationTime

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -ResolveCreationTime -ThrottleLimit 100

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -BranchNameFilter "git_MyProject_*" -OutputDirectory "C:\temp\caches"

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -Namespace "Drops"

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -ExportDirectory "C:\DfsExports"

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -ExportDirectory "C:\DfsExports" -ForceExport

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -ProgressFile "C:\temp\progress.json"

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -ResetProgress

.EXAMPLE
    .\Get-BuildsFromDfsLive.ps1 -DfsServers @("DFSSERVER01") -LogFilePath "C:\temp\Get-BuildsFromDfsLive.log"
#>
param(
    [Parameter(Mandatory=$true)]
    [string[]] $DfsServers,

    [string] $Namespace = "Builds",

    [string] $OutputDirectory,

    [switch] $ResolveCreationTime,

    [string] $BranchNameFilter = "git_*",

    [string] $FileServerFilter = "*",

    [string] $ExportDirectory,

    [switch] $ForceExport,

    [string] $ProgressFile,

    [switch] $ResetProgress,

    [string] $LogFilePath,

    [ValidateRange(1, 256)]
    [int] $ThrottleLimit = 50
)

$ErrorActionPreference = "Stop"

function Set-FileEncoding {
    param(
        [string]$File,
        [string]$Encoding
    )
    $content = Get-Content $File
    $content | Out-File -FilePath $File -Encoding $Encoding
}

function Get-DfsUtil {
    if ($env:DFS_UTIL) {
        $dfsUtil = $env:DFS_UTIL
    } else {
        $dfsUtil = "$env:SystemRoot\system32\dfsutil.exe"
    }
    return $dfsUtil
}

function Export-DFSNamespace {
    param(
        [string] $DfsServer,
        [string] $Namespace,
        [string] $BackupDirectory,
        [bool]   $SkipIfExists = $false
    )
    $DfsUtil = Get-DfsUtil
    $exportDirectory = Join-Path $BackupDirectory $DfsServer
    $exportPath = Join-Path $exportDirectory "$Namespace.xml"

    # Reuse existing export when caller allows it.
    if ($SkipIfExists -and (Test-Path -Path $exportPath)) {
        if ((Get-Item $exportPath).Length -eq 0) {
            throw "Existing namespace export is 0 bytes: $exportPath"
        }
        Write-Host "  Reusing existing export: $exportPath" -ForegroundColor DarkGreen
        return [string]$exportPath
    }

    if (-not (Test-Path -Path $exportDirectory)) {
        New-Item $exportDirectory -ItemType Directory | Out-Null
    }
    if (Test-Path -Path $exportPath) {
        Remove-Item -Path $exportPath -Force
    } 
    & "$DfsUtil" /root:"\\$DfsServer\$Namespace" /export:"$exportPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Couldn't export DFS namespace '\\$DfsServer\$Namespace'"
    }
    if ((Get-Item $exportPath).Length -eq 0) {
        throw "dfsutil produced a 0-byte export for '\\$DfsServer\$Namespace': $exportPath"
    }
    Set-FileEncoding -File $exportPath -Encoding "ascii"

    return [string]$exportPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Progress / checkpoint helpers
# ─────────────────────────────────────────────────────────────────────────────

# Progress is stored as a JSON object: { "completedServers": { "servername": "timestamp", ... } }

function Read-ProgressFile {
    param([string] $Path)
    if (-not (Test-Path $Path)) {
        return @{}
    }
    try {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $ht = @{}
        if ($json.completedServers) {
            $json.completedServers.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        }
        return $ht
    } catch {
        Write-Warning "Could not parse progress file '$Path': $($_.Exception.Message). Starting fresh."
        return @{}
    }
}

function Save-ProgressFile {
    param(
        [string]    $Path,
        [hashtable] $CompletedServers
    )
    $obj = [pscustomobject]@{ completedServers = $CompletedServers }
    $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $Path -Force
}

if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFilePath = Join-Path $PSScriptRoot "logs\Get-BuildsFromDfsLive_$timestamp.log"
}

$logDirectory = Split-Path -Path $LogFilePath -Parent
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

Start-Transcript -Path $LogFilePath -Append | Out-Null
Write-Host "Transcript log: $LogFilePath" -ForegroundColor Gray

# Import-Module "$PSScriptRoot\modules\DfsFunctions.psm1"    -DisableNameChecking

# Resolve progress file path
if ([string]::IsNullOrWhiteSpace($ProgressFile)) {
    $ProgressFile = Join-Path $PSScriptRoot "logs\progress_GetBuildsFromDfsLive.json"
}

$progressDirectory = Split-Path -Path $ProgressFile -Parent
if (-not [string]::IsNullOrWhiteSpace($progressDirectory) -and -not (Test-Path $progressDirectory)) {
    New-Item -ItemType Directory -Path $progressDirectory -Force | Out-Null
}

if ($ResetProgress -and (Test-Path $ProgressFile)) {
    Remove-Item -Path $ProgressFile -Force
    Write-Host "Progress file reset: $ProgressFile" -ForegroundColor Yellow
}

$completedServers = Read-ProgressFile -Path $ProgressFile
if ($completedServers.Count -gt 0) {
    Write-Host "Resuming with $($completedServers.Count) previously completed fileserver(s) from: $ProgressFile" -ForegroundColor Cyan
} else {
    Write-Host "Progress file: $ProgressFile" -ForegroundColor Gray
}

# Resolve the export directory — use user-specified or create a temp directory.
$usingTempExportDir = [string]::IsNullOrWhiteSpace($ExportDirectory)
if ($usingTempExportDir) {
    $tempTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResolvedExportDirectory = Join-Path $env:TEMP "Get-BuildsFromDfsLive_$tempTimestamp"
} else {
    $ResolvedExportDirectory = $ExportDirectory
}
$skipExistingExport = (-not $usingTempExportDir) -and (-not $ForceExport)

try {

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: Export live DFS data from each server
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Phase 0: Exporting live DFS data from servers" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$exportedXmlFiles = @()
$failedServers = @()

foreach ($dfsServer in $DfsServers) {
    Write-Host ""
    Write-Host "Querying DFS server: $dfsServer" -ForegroundColor Green
    Write-Host "  Namespace: $Namespace" -ForegroundColor Gray

    try {
        $exportedPath = Export-DFSNamespace -DfsServer $dfsServer -Namespace $Namespace -BackupDirectory $ResolvedExportDirectory -SkipIfExists $skipExistingExport

        if (Test-Path $exportedPath) {
            Write-Host "  Exported: $exportedPath" -ForegroundColor Green
            $exportedXmlFiles += $exportedPath
        } else {
            Write-Host "  Export succeeded but file not found: $exportedPath" -ForegroundColor Yellow
            $failedServers += $dfsServer
        }
    } catch {
        Write-Warning "Failed to export namespace '$Namespace' from server '$dfsServer': $($_.Exception.Message)"
        $failedServers += $dfsServer
    }
}

if ($failedServers.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed to export from $($failedServers.Count) server(s): $($failedServers -join ', ')" -ForegroundColor Yellow
}

if ($exportedXmlFiles.Count -eq 0) {
    Write-Host "No DFS data was exported. Nothing to process." -ForegroundColor Yellow
    exit
}

Write-Host ""
Write-Host "Successfully exported $($exportedXmlFiles.Count) namespace(s)." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Parse exported XMLs and extract fileserver + build paths
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Phase 1: Parsing exported DFS namespace XMLs" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$DefaultCreationTime = [datetime]::new(2000, 1, 1)

# Key = normalized fileserver name, Value = hashtable of "DfsFolderName|BuildNumber" → build object
$fileServerBuilds = @{}

$totalLinks = 0
$totalDuplicates = 0

foreach ($xmlFile in $exportedXmlFiles) {
    $dfsServer = (Split-Path (Split-Path $xmlFile -Parent) -Leaf)
    Write-Host ""
    Write-Host "Processing server: $dfsServer" -ForegroundColor Green
    Write-Host "  File: $xmlFile" -ForegroundColor Gray

    [xml]$xml = Get-Content $xmlFile
    $rootNamespace = [string]$xml.Root.Name
    $links = $xml.Root.Link

    if ($null -eq $links) {
        Write-Host "  No links found." -ForegroundColor Yellow
        continue
    }

    $linkCount = @($links).Count
    Write-Host "  Links: $linkCount" -ForegroundColor Gray

    $processedCount = 0
    foreach ($link in $links) {
        $processedCount++
        if ($processedCount % 5000 -eq 0) {
            Write-Host "  Processed $processedCount / $linkCount links..." -ForegroundColor Gray
        }

        $linkName = [string]$link.Name
        $dfsLinkPath = $null
        if (-not [string]::IsNullOrWhiteSpace($rootNamespace) -and -not [string]::IsNullOrWhiteSpace($linkName)) {
            $dfsLinkPath = "{0}\{1}" -f $rootNamespace.TrimEnd("\"), $linkName.TrimStart("\")
        }

        # Each link may have one or more targets (fileserver replicas)
        $targets = $link.Target
        if ($null -eq $targets) { continue }

        # Collect all target paths upfront so every build entry gets the complete list
        $dfsTargetPaths = @()
        foreach ($target in $targets) {
            $dfsTargetPaths += "\\$($target.Server)\$($target.Folder)"
        }

        foreach ($target in $targets) {
            # Strip the FQDN domain suffix to get the short server name.
            # Replace the regex below with your organization's domain suffix.
            $fileServer = $target.Server -replace "\.yourdomain\.example\.com$", ""
            $targetFolder = $target.Folder

            if (-not $fileServer -or -not $targetFolder) { continue }

            # Apply fileserver filter
            if ($fileServer -notlike $FileServerFilter) { continue }

            # Parse the target folder path: <share>\<branch>\<build>
            # e.g. "drops\git_MyProject_main\1_0_01265_314_32123608"
            $folderParts = $targetFolder -split "\\", 3
            if ($folderParts.Count -lt 3) {
                # Not enough path segments to extract branch and build
                continue
            }

            $dfsFolderName = $folderParts[1]
            $buildNumber = $folderParts[2]

            # Apply branch name filter
            if ($dfsFolderName -notlike $BranchNameFilter) { continue }

            # Normalize fileserver name for grouping
            $normalizedServer = $fileServer.Split(".")[0].ToLower()
            $dedupeKey = "$dfsFolderName|$buildNumber"

            if (-not $fileServerBuilds.ContainsKey($normalizedServer)) {
                $fileServerBuilds[$normalizedServer] = @{}
            }

            if ($fileServerBuilds[$normalizedServer].ContainsKey($dedupeKey)) {
                $totalDuplicates++
                continue
            }

            $fileServerBuilds[$normalizedServer][$dedupeKey] = @{
                DfsFolderName = $dfsFolderName
                BuildNumber   = $buildNumber
                FileServer    = $fileServer
                TargetFolder  = $targetFolder
                DfsLinkPath   = $dfsLinkPath
                DfsTargetPaths = $dfsTargetPaths
            }
            $totalLinks++
        }
    }

    Write-Host "  Finished processing $linkCount links." -ForegroundColor Gray
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Unique fileservers: $($fileServerBuilds.Count)" -ForegroundColor Green
Write-Host "  Unique builds: $totalLinks" -ForegroundColor Green
Write-Host "  Duplicates skipped: $totalDuplicates" -ForegroundColor Gray

foreach ($entry in $fileServerBuilds.GetEnumerator() | Sort-Object Key) {
    Write-Host "    $($entry.Key): $($entry.Value.Count) builds" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Optionally resolve CreationTime, then write JSON output
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Phase 2: Writing BuildsCache JSON files" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Write-Host "Created output directory: $OutputDirectory" -ForegroundColor Yellow
}

$filesWritten = 0
$filesSkipped = 0

foreach ($serverEntry in $fileServerBuilds.GetEnumerator() | Sort-Object Key) {
    $normalizedServer = $serverEntry.Key
    $builds = $serverEntry.Value

    $cacheFileName = "BuildsCache_$normalizedServer.json"
    $cacheFilePath = Join-Path $OutputDirectory $cacheFileName

    # Skip fileservers already completed in a previous run
    if ($completedServers.ContainsKey($normalizedServer)) {
        Write-Host ""
        Write-Host "Skipping $normalizedServer ($($builds.Count) builds) — already completed." -ForegroundColor DarkGreen
        $filesSkipped++
        continue
    }

    Write-Host ""
    Write-Host "Writing $cacheFileName ($($builds.Count) builds)..." -ForegroundColor Green

    if ($ResolveCreationTime) {
        Write-Host "  Resolving CreationTime for $($builds.Values.Count) builds in parallel (ThrottleLimit = $ThrottleLimit)..." -ForegroundColor Gray
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Each parallel block returns a result object; no shared mutable state needed.
        $discoveredBuilds = $builds.Values | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $buildEntry = $_
            $creationTime = $using:DefaultCreationTime
            $hasError = $false

            $uncPath = $buildEntry.DfsLinkPath
            try {
                $item = Get-Item -Path $uncPath -ErrorAction Stop
                $creationTime = $item.CreationTime
            } catch {
                $hasError = $true
            }

            [PSCustomObject]@{
                DfsFolderName  = $buildEntry.DfsFolderName
                BuildNumber    = $buildEntry.BuildNumber
                CreationTime   = $creationTime
                State          = "NotStarted"
                DfsLinkPath    = $buildEntry.DfsLinkPath
                DfsTargetPaths = $buildEntry.DfsTargetPaths
                _resolveError  = $hasError
            }
        }

        $stopwatch.Stop()

        # Force array even for single-element results
        $discoveredBuilds = @($discoveredBuilds)
        $resolveErrors = @($discoveredBuilds | Where-Object { $_._resolveError }).Count

        if ($resolveErrors -gt 0) {
            Write-Host "  CreationTime resolution errors: $resolveErrors / $($builds.Count)" -ForegroundColor Yellow
        }
        Write-Host "  Resolved $($builds.Count) builds in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor Gray

        # Strip the internal error flag before serialization
        $discoveredBuilds = $discoveredBuilds | Select-Object DfsFolderName, BuildNumber, CreationTime, State, DfsLinkPath, DfsTargetPaths
    } else {
        $discoveredBuilds = foreach ($buildEntry in $builds.Values) {
            [PSCustomObject]@{
                DfsFolderName  = $buildEntry.DfsFolderName
                BuildNumber    = $buildEntry.BuildNumber
                CreationTime   = $DefaultCreationTime
                State          = "NotStarted"
                DfsLinkPath    = $buildEntry.DfsLinkPath
                DfsTargetPaths = $buildEntry.DfsTargetPaths
            }
        }
    }

    $discoveredBuilds | ConvertTo-Json -Depth 5 | Out-File -FilePath $cacheFilePath -Encoding UTF8
    Write-Host "  Written: $cacheFilePath" -ForegroundColor Green
    $filesWritten++

    # Mark this fileserver as completed and save progress
    $completedServers[$normalizedServer] = (Get-Date).ToString("o")
    try {
        Save-ProgressFile -Path $ProgressFile -CompletedServers $completedServers
    } catch {
        Write-Warning "Failed to save progress file '$ProgressFile': $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Done! Wrote $filesWritten BuildsCache JSON file(s) to:" -ForegroundColor Cyan
Write-Host " $OutputDirectory" -ForegroundColor Cyan
if ($filesSkipped -gt 0) {
    Write-Host " Skipped $filesSkipped fileserver(s) (already completed)." -ForegroundColor Cyan
}
Write-Host " Progress file: $ProgressFile" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: Run Remove-OldBuilds.ps1 for each fileserver:" -ForegroundColor Yellow
foreach ($server in ($fileServerBuilds.Keys | Sort-Object)) {
    Write-Host "  .\Remove-OldBuilds.ps1 -FileServer '$server' -UnlinkDfsLink -WhatIf" -ForegroundColor Yellow
}

}
finally {
    # Clean up only auto-generated temp directories; preserve user-specified export directories.
    if ($usingTempExportDir -and (Test-Path $ResolvedExportDirectory)) {
        Remove-Item -Path $ResolvedExportDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "Cleaned up temp directory: $ResolvedExportDirectory" -ForegroundColor Gray
    }

    Stop-Transcript | Out-Null
}
