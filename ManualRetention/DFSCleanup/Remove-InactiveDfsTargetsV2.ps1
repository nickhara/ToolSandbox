<#
.SYNOPSIS
    Validates and removes inactive or unreachable DFS folder targets using dfsutil for fast
    namespace enumeration, with parallel link processing for speed.

.DESCRIPTION
    For each specified DFS server, exports the given namespace via dfsutil to XML, parses all
    folder links and their targets, and validates each target by checking:

      1. DFSN state — targets whose state in the exported XML is not Online (State=2) are
         considered inactive.
      2. UNC path reachability — targets whose UNC path is not accessible are considered
         unreachable.

    Targets that fail either check are removed via Remove-DfsnFolderTarget. If removing targets
    leaves a DFS folder link with zero remaining targets, the empty link is also removed via
    Remove-DfsnFolder.

    Links are processed in parallel using ForEach-Object -Parallel (PowerShell 7+).
    The -ThrottleLimit parameter controls concurrency.

    This script is functionally equivalent to Remove-InactiveDfsTargets.ps1 but replaces the
    slow DFSN PowerShell cmdlet enumeration (Get-DfsnRoot, Get-DfsnFolder, Get-DfsnFolderTarget)
    with a fast bulk export via dfsutil, similar to Get-BuildsFromDfsLive.ps1.

    Supports -WhatIf to preview all removals without making changes. In WhatIf mode, the full
    scan (state + reachability) is performed and results are written to both the console and a
    removals CSV report (with Status=WhatIf entries). WhatIf runs use a separate progress
    checkpoint file (suffixed with _whatif) so they do not interfere with real runs.

.PARAMETER DfsServers
    One or more DFS server names to process.
    Example: @("DFSSERVER01", "DFSSERVER02")

.PARAMETER Namespace
    DFS namespace to query on each server. Defaults to 'Builds'.

.PARAMETER FolderFilter
    Wildcard filter applied to DFS folder link names. Defaults to '*' (all folders).

.PARAMETER ReachabilityTimeoutSeconds
    Timeout in seconds for UNC path reachability checks via Test-Path. Defaults to 5.

.PARAMETER ExportDirectory
    Optional directory for storing exported DFS namespace XML files. When specified, the
    script writes exports here and reuses existing XMLs on subsequent runs, avoiding
    redundant dfsutil calls. When omitted, a temporary directory under %TEMP% is used
    (and cleaned up automatically when the script completes).

.PARAMETER ForceExport
    When set, forces re-export of DFS namespace XMLs even if the file already exists in
    ExportDirectory. Has no effect when ExportDirectory is not specified.

.PARAMETER ProgressFile
    Path to a JSON file used to track which links have been processed. On restart, links
    already recorded in this file are skipped, allowing the script to resume where it left
    off. When omitted, a default file named progress_<Namespace>.json is created next to
    this script.

.PARAMETER ResetProgress
    When set, deletes the progress file before starting, forcing a full re-scan of all links.

.PARAMETER LogFilePath
    Optional transcript log path. When omitted, a timestamped log file is created under
    a logs\ folder next to this script.

.PARAMETER ThrottleLimit
    Maximum number of concurrent parallel link processing operations. Defaults to 16.
    Higher values increase parallelism but also increase load on DFS servers and the network.

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -ExportDirectory "C:\DfsExports" -WhatIf

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -ExportDirectory "C:\DfsExports" -ForceExport

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -WhatIf

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01","DFSSERVER02") -Namespace "Builds"

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -FolderFilter "git_MyProject_*"

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -Namespace "Drops" -ReachabilityTimeoutSeconds 10

.EXAMPLE
    .\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -ThrottleLimit 32

.NOTES
    Requires PowerShell 7 or later (ForEach-Object -Parallel).
    Requires dfsutil.exe (typically at %SystemRoot%\system32\dfsutil.exe) for namespace export.
    Requires the DFSN PowerShell module (Remove-DfsnFolderTarget, Remove-DfsnFolder) for
    target and link removal, and appropriate permissions to modify the DFS namespace.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true, HelpMessage="One or more DFS server names to process.")]
    [string[]] $DfsServers,

    [Parameter(Mandatory=$false, HelpMessage="DFS namespace to query on each server.")]
    [string] $Namespace = "Builds",

    [Parameter(Mandatory=$false, HelpMessage="Wildcard filter for DFS folder link names. Defaults to '*' (all).")]
    [string] $FolderFilter = "*",

    [Parameter(Mandatory=$false, HelpMessage="Timeout in seconds for UNC path reachability checks.")]
    [int] $ReachabilityTimeoutSeconds = 30,

    [Parameter(Mandatory=$false, HelpMessage="Directory for storing exported DFS namespace XMLs. Reuses existing exports unless -ForceExport is set.")]
    [string] $ExportDirectory,

    [Parameter(Mandatory=$false, HelpMessage="Force re-export even if the XML already exists in ExportDirectory.")]
    [switch] $ForceExport,

    [Parameter(Mandatory=$false, HelpMessage="JSON progress file for resumable runs. Links recorded here are skipped on restart.")]
    [string] $ProgressFile,

    [Parameter(Mandatory=$false, HelpMessage="Delete the progress file before starting, forcing a full re-scan.")]
    [switch] $ResetProgress,

    [Parameter(Mandatory=$false, HelpMessage="Optional transcript log path.")]
    [string] $LogFilePath,

    [Parameter(Mandatory=$false, HelpMessage="Max concurrent link processing operations. Default is 16.")]
    [int] $ThrottleLimit = 16
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# PowerShell 7+ guard (required for ForEach-Object -Parallel)
# ─────────────────────────────────────────────────────────────────────────────

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or later for parallel processing (ForEach-Object -Parallel). Current version: $($PSVersionTable.PSVersion)"
    return
}

Import-Module "$PSScriptRoot\..\Retry-Helper.psm1" -Force

if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Error "Start-ThreadJob is required but not available. Ensure PowerShell 7 or later is installed, or install the ThreadJob module."
    return
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging setup
# ─────────────────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFilePath = Join-Path $PSScriptRoot "logs\Remove-InactiveDfsTargetsV2_$timestamp.log"
}

$logDirectory = Split-Path -Path $LogFilePath -Parent
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force -WhatIf:$false | Out-Null
}

$TranscriptStarted = $false
Start-Transcript -Path $LogFilePath -Append -WhatIf:$false | Out-Null
$TranscriptStarted = $true
Write-Host "Transcript log: $LogFilePath" -ForegroundColor Gray

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host ">>> RUNNING IN -WhatIf MODE — no changes will be made <<<" -ForegroundColor Yellow
    Write-Host "    Scanning targets and writing removals report only." -ForegroundColor Yellow
    Write-Host ""
}

# Resolve the export directory — use user-specified or create a temp directory.
$usingTempExportDir = [string]::IsNullOrWhiteSpace($ExportDirectory)
if ($usingTempExportDir) {
    $tempTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResolvedExportDirectory = Join-Path $env:TEMP "Remove-InactiveDfsTargetsV2_$tempTimestamp"
} else {
    $ResolvedExportDirectory = $ExportDirectory
}
$skipExistingExport = (-not $usingTempExportDir) -and (-not $ForceExport)

# ─────────────────────────────────────────────────────────────────────────────
# Configuration summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Remove-InactiveDfsTargetsV2 — Configuration" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  DFS servers:          $($DfsServers -join ', ')" -ForegroundColor Gray
Write-Host "  Namespace:            $Namespace" -ForegroundColor Gray
Write-Host "  Folder filter:        $FolderFilter" -ForegroundColor Gray
Write-Host "  Reachability timeout: ${ReachabilityTimeoutSeconds}s" -ForegroundColor Gray
Write-Host "  Throttle limit:       $ThrottleLimit" -ForegroundColor Gray
Write-Host "  Export directory:      $(if ($usingTempExportDir) { '(temp)' } else { $ExportDirectory })" -ForegroundColor Gray
Write-Host "  Force export:         $ForceExport" -ForegroundColor Gray
Write-Host "  WhatIf:               $WhatIfPreference" -ForegroundColor Gray
Write-Host "  PowerShell:           $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "  Started at:           $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

$scriptStartTime = Get-Date

# ─────────────────────────────────────────────────────────────────────────────
# Counters and thread-safe collections for parallel processing
# ─────────────────────────────────────────────────────────────────────────────

# Sequential counters (only updated in the outer server loop)
$totalServersProcessed   = 0
$totalNamespacesExported = 0

# Parallel-safe counters (updated inside ForEach-Object -Parallel)
$sharedCounters = [hashtable]::Synchronized(@{
    LinksChecked      = [int]0
    LinksSkipped      = [int]0
    TargetsValidated  = [int]0
    TargetsRemoved    = [int]0
    Errors            = [int]0
    LinksRemoved      = [int]0
    LinksProcessed    = [int]0
})

# Thread-safe progress tracking for newly completed links
$newCompletedLinks = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

# Thread-safe bag for removal report records
$removalRecords = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

# Structured removals report — written in batch after parallel phase
$removalsReportPath = Join-Path (Split-Path $LogFilePath -Parent) ("removals_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".csv")

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Locate dfsutil.exe
# ─────────────────────────────────────────────────────────────────────────────

function Get-DfsUtil {
    if ($env:DFS_UTIL) {
        return $env:DFS_UTIL
    }
    return "$env:SystemRoot\system32\dfsutil.exe"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Fix file encoding for XML parsing
# ─────────────────────────────────────────────────────────────────────────────

function Set-FileEncoding {
    param(
        [string] $File,
        [string] $Encoding
    )
    # Force write even under -WhatIf so discovery data is usable.
    $content = Get-Content -Path $File
    [System.IO.File]::WriteAllLines($File, $content, [System.Text.Encoding]::ASCII)
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Export a DFS namespace to XML via dfsutil
# ─────────────────────────────────────────────────────────────────────────────

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

    # In -WhatIf mode we still need live discovery data, so force temp export prep to run.
    if (-not (Test-Path -Path $exportDirectory)) {
        New-Item -Path $exportDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    if (Test-Path -Path $exportPath) {
        Remove-Item -Path $exportPath -Force -WhatIf:$false
    }
    Write-Host "Executing $DfsUtil /root:'\\$DfsServer\$Namespace' /export:'$exportPath'..." -ForegroundColor Gray
    $dfsutilOutput = & "$DfsUtil" /root:"\\$DfsServer\$Namespace" /export:"$exportPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dfsutil export failed for '\\$DfsServer\$Namespace' (exit code $LASTEXITCODE). Output: $dfsutilOutput"
    }
    Write-Verbose "dfsutil output: $dfsutilOutput"
    if ((Get-Item $exportPath).Length -eq 0) {
        throw "dfsutil produced a 0-byte export for '\\$DfsServer\$Namespace': $exportPath"
    }
    Set-FileEncoding -File $exportPath -Encoding "ascii"

    return [string]$exportPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Map dfsutil XML numeric target state to a human-readable label
# ─────────────────────────────────────────────────────────────────────────────

function Get-TargetStateLabel {
    param(
        [string] $XmlStateValue
    )

    # dfsutil exports target state as a numeric value.
    # Bit 1 (0x2) = Active, Bit 2 (0x4) = Offline.
    # State 2 = Online (active, not offline).
    # State 6 = Offline (active + offline bits set).
    # Treat state 2 as Online; anything else as not Online.
    if ([string]::IsNullOrWhiteSpace($XmlStateValue)) {
        return "Unknown"
    }

    try {
        $stateInt = [int]$XmlStateValue
    } catch {
        return "Unknown ($XmlStateValue)"
    }

    if ($stateInt -eq 2) {
        return "Online"
    }

    $hasActive  = ($stateInt -band 0x2) -ne 0
    $hasOffline = ($stateInt -band 0x4) -ne 0

    if ($hasOffline) {
        return "Offline"
    }
    if (-not $hasActive) {
        return "Inactive"
    }

    return "Unknown ($stateInt)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Progress / checkpoint helpers
# ─────────────────────────────────────────────────────────────────────────────

# Progress is stored as a JSON object: { "completedLinks": { "SERVER::linkName": "timestamp", ... } }

function Read-ProgressFile {
    param([string] $Path)
    if (-not (Test-Path $Path)) {
        return @{}
    }
    try {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $ht = @{}
        if ($json.completedLinks) {
            $json.completedLinks.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
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
        [hashtable] $CompletedLinks
    )
    $obj = [pscustomobject]@{ completedLinks = $CompletedLinks }
    $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $Path -Force -WhatIf:$false
}

function Get-ProgressKey {
    param([string] $DfsServer, [string] $LinkName)
    return "${DfsServer}::${LinkName}"
}

# Resolve progress file path
if ([string]::IsNullOrWhiteSpace($ProgressFile)) {
    if ($WhatIfPreference) {
        $ProgressFile = Join-Path $PSScriptRoot "logs\progress_${Namespace}_whatif.json"
    } else {
        $ProgressFile = Join-Path $PSScriptRoot "logs\progress_$Namespace.json"
    }
}

if ($ResetProgress -and (Test-Path $ProgressFile)) {
    Remove-Item -Path $ProgressFile -Force -WhatIf:$false
    Write-Host "Progress file reset: $ProgressFile" -ForegroundColor Yellow
}

$completedLinks = [hashtable]::Synchronized((Read-ProgressFile -Path $ProgressFile))
if ($completedLinks.Count -gt 0) {
    Write-Host "Resuming with $($completedLinks.Count) previously completed link(s) from: $ProgressFile" -ForegroundColor Cyan
} else {
    Write-Host "Progress file: $ProgressFile" -ForegroundColor Gray
}

try {

    # ─────────────────────────────────────────────────────────────────────────────
    # Step 1: Ensure DFSN module is available (needed for removal cmdlets)
    # ─────────────────────────────────────────────────────────────────────────────

    Write-Host "[Step 1/5] Loading DFSN PowerShell module..." -ForegroundColor Cyan
    try {
        Import-Module DFSN -ErrorAction Stop
        Write-Host "  DFSN module loaded successfully." -ForegroundColor Green
    } catch {
        Write-Error "The DFSN PowerShell module is required but could not be loaded. Ensure the DFS Namespaces feature and its PowerShell cmdlets are installed.`n$($_.ScriptStackTrace)"
        return
    }

    # ─────────────────────────────────────────────────────────────────────────────
    # Step 2: Pre-flight — Network connectivity and share accessibility checks
    # ─────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "[Step 2/5] Running pre-flight connectivity checks ($($DfsServers.Count) server(s) in parallel)..." -ForegroundColor Cyan
    $preflightStart = Get-Date

    $preflightResults = [System.Collections.Concurrent.ConcurrentDictionary[string, PSObject]]::new()

    $DfsServers | ForEach-Object -ThrottleLimit $DfsServers.Count -Parallel {
        $server = $_
        $ns = $using:Namespace
        $results = $using:preflightResults
        $namespacePath = "\\$server\$ns"

        $result = [PSCustomObject]@{
            Server    = $server
            Reachable = $false
            Message   = ""
        }

        # Check 1: Network connectivity to the DFS server
        try {
            $pingResult = Test-Connection -TargetName $server -Count 1 -TimeoutSeconds 5 -ErrorAction Stop
            Write-Host "  [$server] Network connectivity OK (Address: $($pingResult.Address), Latency: $($pingResult.Latency)ms)" -ForegroundColor Green
        } catch {
            Write-Host "  [$server] Cannot reach server: $($_.Exception.Message)" -ForegroundColor Red
            $result.Message = "Network unreachable: $($_.Exception.Message)"
            $results.TryAdd($server, $result) | Out-Null
            return
        }

        # Check 2: DFS namespace share accessibility
        $shareAccessible = Test-Path -Path $namespacePath -ErrorAction SilentlyContinue
        if (-not $shareAccessible) {
            Write-Host "  [$server] Cannot access DFS namespace share '$namespacePath'" -ForegroundColor Red
            $result.Message = "Share not accessible: $namespacePath"
            $results.TryAdd($server, $result) | Out-Null
            return
        }

        # Check 3: Verify the share returns content (deeper accessibility check)
        try {
            $shareCheck = Get-ChildItem -Path $namespacePath -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $shareCheck) {
                Write-Host "  [$server] Share is accessible but appears empty: $namespacePath" -ForegroundColor Yellow
            } else {
                Write-Host "  [$server] Share accessibility verified: $namespacePath" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [$server] Share path exists but content is not accessible: $($_.Exception.Message)" -ForegroundColor Red
            $result.Message = "Share content not accessible: $($_.Exception.Message)"
            $results.TryAdd($server, $result) | Out-Null
            return
        }

        $result.Reachable = $true
        $results.TryAdd($server, $result) | Out-Null
    }

    # Collect results preserving original server order
    $reachableServers = [System.Collections.Generic.List[string]]::new()
    foreach ($server in $DfsServers) {
        $result = $preflightResults[$server]
        if ($null -eq $result -or -not $result.Reachable) {
            $msg = if ($null -ne $result) { $result.Message } else { "No result returned" }
            Write-Warning "  Skipping server '$server': $msg"
            $sharedCounters['Errors'] = [int]$sharedCounters['Errors'] + 1
        } else {
            $reachableServers.Add($server)
        }
    }

    if ($reachableServers.Count -eq 0) {
        Write-Host ""
        Write-Host "No DFS servers are reachable. Please verify network connectivity and try again." -ForegroundColor Red
        return
    }

    if ($reachableServers.Count -lt $DfsServers.Count) {
        Write-Host ""
        Write-Host "Pre-flight: $($reachableServers.Count) of $($DfsServers.Count) server(s) reachable. Proceeding with reachable servers only." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "Pre-flight: All $($DfsServers.Count) server(s) reachable." -ForegroundColor Green
    }
    $preflightElapsed = (Get-Date) - $preflightStart
    Write-Host "  Pre-flight completed in $($preflightElapsed.ToString('mm\:ss\.fff'))." -ForegroundColor Gray

    # ─────────────────────────────────────────────────────────────────────────────
    # Step 3: Parallel namespace export via dfsutil
    # ─────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "[Step 3/5] Exporting namespaces in parallel ($($reachableServers.Count) server(s))..." -ForegroundColor Cyan
    $exportStart = Get-Date

    $exportResults = [System.Collections.Concurrent.ConcurrentDictionary[string, PSObject]]::new()

    $reachableServers | ForEach-Object -ThrottleLimit $reachableServers.Count -Parallel {
        $server  = $_
        $ns      = $using:Namespace
        $backupDir = $using:ResolvedExportDirectory
        $skipIfExists = $using:skipExistingExport
        $results = $using:exportResults

        $result = [PSCustomObject]@{
            Server  = $server
            XmlPath = $null
            Error   = $null
        }

        try {
            # Resolve and validate dfsutil path
            $dfsUtilPath = if ($env:DFS_UTIL) { $env:DFS_UTIL } else { "$env:SystemRoot\system32\dfsutil.exe" }
            if (-not (Test-Path $dfsUtilPath) -or (Split-Path $dfsUtilPath -Leaf).ToLower() -ne "dfsutil.exe") {
                throw "Invalid dfsutil path: $dfsUtilPath. Ensure it points to dfsutil.exe."
            }

            $exportDirectory = Join-Path $backupDir $server
            $exportPath = Join-Path $exportDirectory "$ns.xml"

            # Reuse existing export when allowed
            if ($skipIfExists -and (Test-Path -Path $exportPath)) {
                if ((Get-Item $exportPath).Length -eq 0) {
                    throw "Existing namespace export is 0 bytes: $exportPath"
                }
                Write-Host "  [$server] Reusing existing export: $exportPath" -ForegroundColor DarkGreen
                $result.XmlPath = [string]$exportPath
                $results.TryAdd($server, $result) | Out-Null
                return
            }

            # Prepare export directory
            if (-not (Test-Path -Path $exportDirectory)) {
                New-Item -Path $exportDirectory -ItemType Directory -Force | Out-Null
            }
            if (Test-Path -Path $exportPath) {
                Remove-Item -Path $exportPath -Force
            }

            Write-Host "  [$server] Exporting namespace '\\$server\$ns' via dfsutil..." -ForegroundColor Gray
            $dfsutilOutput = & "$dfsUtilPath" /root:"\\$server\$ns" /export:"$exportPath" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "dfsutil export failed for '\\$server\$ns' (exit code $LASTEXITCODE). Output: $dfsutilOutput"
            }
            if ((Get-Item $exportPath).Length -eq 0) {
                throw "dfsutil produced a 0-byte export for '\\$server\$ns': $exportPath"
            }

            # Fix encoding for XML parsing
            $content = Get-Content -Path $exportPath
            [System.IO.File]::WriteAllLines($exportPath, $content, [System.Text.Encoding]::ASCII)

            Write-Host "  [$server] Export complete: $exportPath" -ForegroundColor Green
            $result.XmlPath = [string]$exportPath
        } catch {
            Write-Host "  [$server] Export failed: $($_.Exception.Message)" -ForegroundColor Red
            $result.Error = $_.Exception.Message
        }

        $results.TryAdd($server, $result) | Out-Null
    }

    # Collect export results and determine which servers have usable exports
    $serversWithExports = [System.Collections.Generic.List[string]]::new()
    foreach ($server in $reachableServers) {
        $result = $exportResults[$server]
        if ($null -eq $result -or $null -ne $result.Error) {
            $msg = if ($null -ne $result) { $result.Error } else { "No result returned" }
            Write-Warning "Failed to export namespace '$Namespace' from '$server': $msg"
            $sharedCounters['Errors'] = [int]$sharedCounters['Errors'] + 1
        } else {
            $totalNamespacesExported++
            $serversWithExports.Add($server)
        }
    }

    if ($serversWithExports.Count -eq 0) {
        Write-Host ""
        Write-Host "All namespace exports failed. Nothing to process." -ForegroundColor Red
        return
    }

    Write-Host "Exported $totalNamespacesExported of $($reachableServers.Count) namespace(s) successfully." -ForegroundColor Green
    $exportElapsed = (Get-Date) - $exportStart
    Write-Host "  Export completed in $($exportElapsed.ToString('mm\:ss\.fff'))." -ForegroundColor Gray

    # ─────────────────────────────────────────────────────────────────────────────
    # Step 4: Parse exported XMLs and build unified work-item list
    # ─────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "[Step 4/5] Parsing exported XMLs and building work-item list..." -ForegroundColor Cyan
    $allWorkItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($DfsServer in $serversWithExports) {
        $exportedXmlPath = $exportResults[$DfsServer].XmlPath

        [xml]$xml = Get-Content $exportedXmlPath
        $links = $xml.Root.Link

        if ($null -eq $links) {
            Write-Host "[$DfsServer] No links found in namespace." -ForegroundColor Yellow
            continue
        }

        $serverLinks = @($links)
        Write-Host "[$DfsServer] Found $($serverLinks.Count) link(s) in namespace." -ForegroundColor Green
        $totalServersProcessed++

        foreach ($link in $serverLinks) {
            $allWorkItems.Add([PSCustomObject]@{
                DfsServer = $DfsServer
                Link      = $link
            })
        }
    }

    if ($allWorkItems.Count -eq 0) {
        Write-Host "No links found across any server. Nothing to process." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " [Step 5/5] Processing $($allWorkItems.Count) link(s) across $totalServersProcessed server(s) (throttle=$ThrottleLimit)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # ─────────────────────────────────────────────────────────────────────────────
    # Step 5: Parallel link processing — single pipeline across all servers
    # ─────────────────────────────────────────────────────────────────────────────

    $isWhatIf = $WhatIfPreference
    $totalWorkItems = $allWorkItems.Count
    $processingStart = Get-Date

    $sharedCounters['LinksProcessed'] = [int]0

    # ── Background progress monitor ──
    # Uses [Console]::Write with carriage return to overwrite the status line in-place,
    # because Write-Progress inside a ThreadJob buffers to the job's progress
    # stream and never renders on the host console.
    $progressJob = Start-ThreadJob -ScriptBlock {
        param($counters, $total, $startTime, $newCompleted, $existingCompleted, $progressFilePath)
        $lastFlushCount = 0
        while ($true) {
            Start-Sleep -Seconds 2
            $done = $counters['LinksProcessed']
            if ($total -gt 0) {
                $pct = [math]::Min([math]::Round(($done / $total) * 100, 1), 100)
                $elapsed = (Get-Date) - $startTime
                $checked  = $counters['LinksChecked']
                $skipped  = $counters['LinksSkipped']
                $removed  = $counters['TargetsRemoved']
                $errors   = $counters['Errors']
                $barWidth = 30
                $filledWidth = [math]::Floor($pct / 100 * $barWidth)
                $emptyWidth  = $barWidth - $filledWidth
                $bar = "[" + ("#" * $filledWidth) + ("-" * $emptyWidth) + "]"
                $status = "`r  $bar $pct% ($done/$total) | Checked: $checked | Skipped: $skipped | Removed: $removed | Errors: $errors | $($elapsed.ToString('mm\:ss'))  "
                [Console]::Write($status)
            }
            # Periodic progress flush every 30 completed links
            $currentCount = $newCompleted.Count
            if (($currentCount - $lastFlushCount) -ge 30) {
                try {
                    $merged = $existingCompleted.Clone()
                    foreach ($kvp in $newCompleted.GetEnumerator()) { $merged[$kvp.Key] = $kvp.Value }
                    $obj = [pscustomobject]@{ completedLinks = $merged }
                    $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $progressFilePath -Force -WhatIf:$false
                    $lastFlushCount = $currentCount
                } catch { }
            }
            if ($done -ge $total) { break }
        }
        [Console]::WriteLine()
    } -ArgumentList $sharedCounters, $totalWorkItems, $processingStart, $newCompletedLinks, $completedLinks, $ProgressFile

    try {
    $allWorkItems | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $workItem = $_
        $link = $workItem.Link
        $server = $workItem.DfsServer
        $linkName = [string]$link.Name
        $folderLeafName = ($linkName.TrimStart("\") -split "\\")[0]

        # Import references from parent scope
        $counters      = $using:sharedCounters
        $newCompleted  = $using:newCompletedLinks
        $removalBag    = $using:removalRecords
        $completed     = $using:completedLinks
        $filter        = $using:FolderFilter
        $ns            = $using:Namespace
        $timeoutSec    = $using:ReachabilityTimeoutSeconds
        $whatIf        = $using:isWhatIf

            # Apply folder filter
            if ($folderLeafName -notlike $filter) {
                $counters['LinksProcessed'] = [int]$counters['LinksProcessed'] + 1
                return
            }

            $dfsFolderPath = "\\$server\$ns\$($linkName.TrimStart('\'))"
            $progressKey = "${server}::${linkName}"

            # Skip links already completed in a previous run
            if ($completed.ContainsKey($progressKey)) {
                $counters['LinksSkipped'] = [int]$counters['LinksSkipped'] + 1
                $counters['LinksProcessed'] = [int]$counters['LinksProcessed'] + 1
                return
            }

            $counters['LinksChecked'] = [int]$counters['LinksChecked'] + 1

            # ── Validate targets from XML ──
            $xmlTargets = $link.Target
            if ($null -eq $xmlTargets) {
                $newCompleted.TryAdd($progressKey, (Get-Date).ToString("o")) | Out-Null
                $counters['LinksProcessed'] = [int]$counters['LinksProcessed'] + 1
                return
            }
            $xmlTargets = @($xmlTargets)

            $targetsToRemove = @()

            foreach ($xmlTarget in $xmlTargets) {
                $counters['TargetsValidated'] = [int]$counters['TargetsValidated'] + 1
                $targetServer = [string]$xmlTarget.Server
                $targetFolder = [string]$xmlTarget.Folder
                $targetPath   = "\\$targetServer\$targetFolder"
                $removeReason = $null

                # Check 1: DFSN state from XML (inline Get-TargetStateLabel)
                $xmlStateValue = $xmlTarget.State
                $stateLabel = "Unknown"
                if (-not [string]::IsNullOrWhiteSpace($xmlStateValue)) {
                    try {
                        $stateInt = [int]$xmlStateValue
                        if ($stateInt -eq 2) {
                            $stateLabel = "Online"
                        } elseif (($stateInt -band 0x4) -ne 0) {
                            $stateLabel = "Offline"
                        } elseif (($stateInt -band 0x2) -eq 0) {
                            $stateLabel = "Inactive"
                        } else {
                            $stateLabel = "Unknown ($stateInt)"
                        }
                    } catch {
                        $stateLabel = "Unknown ($xmlStateValue)"
                    }
                }

                if ($stateLabel -ne "Online") {
                    $removeReason = "Inactive (State: $stateLabel)"
                }

                # Check 2: UNC path reachability (only if state check passed)
                if (-not $removeReason) {
                    # Inline Test-TargetReachable
                    $reachable = $false
                    $ps = $null
                    try {
                        $ps = [PowerShell]::Create()
                        $ps.AddCommand("Test-Path").AddParameter("Path", $targetPath) | Out-Null
                        $handle = $ps.BeginInvoke()
                        if ($handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($timeoutSec))) {
                            $result = $ps.EndInvoke($handle)
                            $reachable = [bool]$result[0]
                        } else {
                            $ps.Stop()
                            try { $ps.EndInvoke($handle) } catch { }
                        }
                    } catch { } finally {
                        if ($ps) { $ps.Dispose() }
                    }

                    if (-not $reachable) {
                        Write-Host "  Unreachable: $targetPath (State: $stateLabel) [Link: $dfsFolderPath]" -ForegroundColor DarkGray
                        $removeReason = "Unreachable (path not accessible)"
                    }
                }

                if ($removeReason) {
                    $targetsToRemove += [PSCustomObject]@{
                        TargetPath = $targetPath
                        Reason     = $removeReason
                    }
                }
            }

            if ($targetsToRemove.Count -eq 0) {
                # Link is healthy — checkpoint for resume
                $newCompleted.TryAdd($progressKey, (Get-Date).ToString("o")) | Out-Null
                $counters['LinksProcessed'] = [int]$counters['LinksProcessed'] + 1
                return
            }

            # ── Remove flagged targets ──
            Import-Module DFSN -ErrorAction SilentlyContinue
            Write-Host "  $dfsFolderPath — $($targetsToRemove.Count) target(s) to remove" -ForegroundColor DarkGray

            $successfulRemovals = 0
            foreach ($flagged in $targetsToRemove) {
                $status = $null
                if ($whatIf) {
                    Write-Host "    [WhatIf] Would remove target: $dfsFolderPath -> $($flagged.TargetPath) | $($flagged.Reason)" -ForegroundColor Cyan
                    $status = "WhatIf"
                    $successfulRemovals++
                    $counters['TargetsRemoved'] = [int]$counters['TargetsRemoved'] + 1
                } else {
                    try {
                        Remove-DfsnFolderTarget -Path $dfsFolderPath -TargetPath $flagged.TargetPath -Force -ErrorAction Stop
                        Write-Host "    REMOVED: $dfsFolderPath -> $($flagged.TargetPath)" -ForegroundColor Green
                        $status = "Removed"
                        $successfulRemovals++
                        $counters['TargetsRemoved'] = [int]$counters['TargetsRemoved'] + 1
                    } catch {
                        Write-Warning "    FAILED: $dfsFolderPath -> $($flagged.TargetPath): $($_.Exception.Message)"
                        $status = "Failed: $($_.Exception.Message)"
                        $counters['Errors'] = [int]$counters['Errors'] + 1
                    }
                }

                $removalBag.Add([PSCustomObject]@{
                    Timestamp  = (Get-Date).ToString("o")
                    DfsServer  = $server
                    LinkPath   = $dfsFolderPath
                    TargetPath = $flagged.TargetPath
                    Reason     = $flagged.Reason
                    Status     = $status
                })
            }

            # # ── Empty link detection — all targets removed/would be removed ──
            # if ($successfulRemovals -eq $targetsToRemove.Count -and $targetsToRemove.Count -eq $xmlTargets.Count) {
            #     $linkStatus = $null
            #     if ($whatIf) {
            #         Write-Host "    [WhatIf] Would remove empty link: $dfsFolderPath (all $($xmlTargets.Count) target(s) would be removed)" -ForegroundColor Cyan
            #         $linkStatus = "WhatIf"
            #         $counters['LinksRemoved'] = [int]$counters['LinksRemoved'] + 1
            #     } else {
            #         try {
            #             Remove-DfsnFolder -Path $dfsFolderPath -Force -ErrorAction Stop
            #             Write-Host "    REMOVED empty link: $dfsFolderPath" -ForegroundColor Green
            #             $linkStatus = "Removed"
            #             $counters['LinksRemoved'] = [int]$counters['LinksRemoved'] + 1
            #         } catch {
            #             Write-Warning "    FAILED to remove empty link ${dfsFolderPath}: $($_.Exception.Message)"
            #             $linkStatus = "Failed: $($_.Exception.Message)"
            #             $counters['Errors'] = [int]$counters['Errors'] + 1
            #         }
            #     }
            #     $removalBag.Add([PSCustomObject]@{
            #         Timestamp  = (Get-Date).ToString("o")
            #         DfsServer  = $server
            #         LinkPath   = $dfsFolderPath
            #         TargetPath = "(empty link)"
            #         Reason     = "All $($xmlTargets.Count) target(s) removed — empty link cleanup"
            #         Status     = $linkStatus
            #     })
            # }

            # Checkpoint link as completed
            $newCompleted.TryAdd($progressKey, (Get-Date).ToString("o")) | Out-Null
            $counters['LinksProcessed'] = [int]$counters['LinksProcessed'] + 1
        }
    } finally {
        # Stop progress monitor first — must complete before enumerating shared collections
        if ($null -ne $progressJob) {
            $progressJob | Wait-Job -Timeout 5 | Out-Null
            $progressJob | Remove-Job -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
        # Ensure the cursor moves past the progress line
        [Console]::WriteLine()

        # Merge newly completed links now that the progress monitor is stopped
        foreach ($kvp in $newCompletedLinks.GetEnumerator()) {
            $completedLinks[$kvp.Key] = $kvp.Value
        }
    }

    $processingElapsed = (Get-Date) - $processingStart
    Write-Host "Link processing completed in $($processingElapsed.ToString('mm\:ss\.fff'))." -ForegroundColor Green

    # ─────────────────────────────────────────────────────────────────────────────
    # Post-processing: Save progress and write reports
    # ─────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "Saving results..." -ForegroundColor Cyan

    # Batch-write progress file
    try {
        Save-ProgressFile -Path $ProgressFile -CompletedLinks $completedLinks
        Write-Host "Progress file saved ($($completedLinks.Count) total completed links)." -ForegroundColor Gray
    } catch {
        Write-Warning "Failed to save progress file '$ProgressFile': $($_.Exception.Message)"
    }

    # ─────────────────────────────────────────────────────────────────────────────
    # Batch-write removals report CSV
    # ─────────────────────────────────────────────────────────────────────────────

    $removalItems = @($removalRecords.ToArray())
    if ($removalItems.Count -gt 0) {
        $removalItems | Export-Csv -Path $removalsReportPath -NoTypeInformation -Force -WhatIf:$false
        Write-Host "  Removals report:      $removalsReportPath ($($removalItems.Count) entries)" -ForegroundColor Cyan
    } else {
        Write-Host "  Removals report:      (none — no targets flagged for removal)" -ForegroundColor Gray
    }

    # ─────────────────────────────────────────────────────────────────────────────
    # Summary — derive accurate removal counts from the ConcurrentBag (thread-safe)
    # rather than the shared counters (which use non-atomic read-modify-write).
    # The counters are still used for progress bar display where slight races are OK.
    # ─────────────────────────────────────────────────────────────────────────────

    $totalLinksChecked      = $sharedCounters['LinksChecked']
    $totalLinksSkipped      = $sharedCounters['LinksSkipped']
    $totalTargetsValidated  = $sharedCounters['TargetsValidated']

    # Derive accurate counts from the removal records (ConcurrentBag is thread-safe)
    $totalTargetsRemoved    = @($removalItems | Where-Object { $_.TargetPath -ne "(empty link)" -and $_.Status -ne $null -and -not $_.Status.StartsWith("Failed:") }).Count
    $totalLinksRemoved      = @($removalItems | Where-Object { $_.TargetPath -eq "(empty link)" -and $_.Status -ne $null -and -not $_.Status.StartsWith("Failed:") }).Count
    $totalErrors            = $sharedCounters['Errors']

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    if ($WhatIfPreference) {
        Write-Host " Summary (WhatIf Mode — no changes were made)" -ForegroundColor Yellow
    } else {
        Write-Host " Summary" -ForegroundColor Cyan
    }
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Servers processed:    $totalServersProcessed" -ForegroundColor Green
    Write-Host "  Namespaces exported:  $totalNamespacesExported" -ForegroundColor Green
    Write-Host "  Links checked:        $totalLinksChecked" -ForegroundColor Green
    Write-Host "  Links skipped (resume): $totalLinksSkipped" -ForegroundColor Green
    Write-Host "  Targets validated:    $totalTargetsValidated" -ForegroundColor Green

    if ($WhatIfPreference) {
        Write-Host "  Targets to remove:    $totalTargetsRemoved" -ForegroundColor Yellow
        Write-Host "  Empty links to remove: $totalLinksRemoved" -ForegroundColor Yellow
    } else {
        Write-Host "  Targets removed:      $totalTargetsRemoved" -ForegroundColor Yellow
        Write-Host "  Empty links removed:  $totalLinksRemoved" -ForegroundColor Yellow
    }

    Write-Host "  Errors:               $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { "Red" } else { "Green" })
    Write-Host "  Throttle limit:       $ThrottleLimit" -ForegroundColor Gray
    Write-Host "  Progress file:        $ProgressFile" -ForegroundColor Gray
    $totalElapsed = (Get-Date) - $scriptStartTime
    Write-Host "  Total elapsed:        $($totalElapsed.ToString('hh\:mm\:ss\.fff'))" -ForegroundColor Gray
    Write-Host "  Completed at:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ""

} finally {
    # Clean up only auto-generated temp directories; preserve user-specified export directories.
    if ($usingTempExportDir -and (Test-Path $ResolvedExportDirectory)) {
        Remove-Item -Path $ResolvedExportDirectory -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
        Write-Host "Cleaned up temp directory: $ResolvedExportDirectory" -ForegroundColor Gray
    }

    if ($TranscriptStarted) {
        Stop-Transcript -WhatIf:$false | Out-Null
    }
}
