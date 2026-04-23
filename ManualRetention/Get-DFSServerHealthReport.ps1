<#
.SYNOPSIS
  Point-in-time DFSN health snapshot for one or more DFS servers.

.DESCRIPTION
  For each specified DFS server, exports the given namespace via dfsutil, parses
  links and targets, and reports:

  - DFSN: counts DFS links (folders), active vs inactive based on Online targets, root target status
  - Event logs: recent errors/warnings for DFS Namespace Server
  - Host basics: uptime, disk free, DFS Namespace service status

  The same namespace name is used across all servers (standalone DFS namespaces
  that are identical per server).

  Outputs one result object per server to the pipeline.

.PARAMETER DfsServers
  One or more DFS server names to evaluate.
  Example: @("DFSSERVER01", "DFSSERVER02")

.PARAMETER Namespace
  DFS namespace to query on each server. Defaults to 'Builds'.
  The same namespace is assumed to exist on every server in DfsServers.

.PARAMETER EventLogLookbackHours
  How many hours of event logs to scan. Defaults to 24.

.PARAMETER ExportDirectory
  Directory for storing exported DFS namespace XMLs. Reuses existing exports
  on subsequent runs. When omitted, a temporary directory under %TEMP% is used
  and cleaned up automatically.

.PARAMETER ForceExport
  Force re-export of namespace XMLs even if they already exist in ExportDirectory.

.EXAMPLE
  .\Get-DFSServerHealthReport.ps1 -DfsServers @("DFSSERVER01","DFSSERVER02")

.EXAMPLE
  .\Get-DFSServerHealthReport.ps1 -DfsServers @("DFSSERVER01") -Namespace "Drops" -ExportDirectory "C:\DfsExports"

.NOTES
  Requires dfsutil.exe (typically at %SystemRoot%\system32\dfsutil.exe).
  Run from an account with rights to query DFS configuration and event logs.
#>

[CmdletBinding()]
param(
  # One or more DFS server names to evaluate.
  [Parameter(Mandatory = $true)]
  [string[]] $DfsServers,

  # DFS namespace to query on each server. Identical across all servers.
  [Parameter(Mandatory = $false)]
  [string] $Namespace = "Builds",

  # How many hours of event logs to scan
  [Parameter(Mandatory = $false)]
  [int] $EventLogLookbackHours = 24,

  # Directory for storing exported DFS namespace XMLs. Reuses existing exports on subsequent runs.
  # When omitted, a temporary directory under %TEMP% is used and cleaned up automatically.
  [Parameter(Mandatory = $false)]
  [string] $ExportDirectory,

  # Force re-export of namespace XMLs even if they already exist in ExportDirectory.
  [Parameter(Mandatory = $false)]
  [switch] $ForceExport
)

function Write-Status {
  param([string]$Message)
  $ts = (Get-Date).ToString("HH:mm:ss.fff")
  Write-Host "[$ts] $Message" -ForegroundColor Gray
}

function Get-DfsUtil {
  if ($env:DFS_UTIL) { return $env:DFS_UTIL }
  return "$env:SystemRoot\system32\dfsutil.exe"
}

function Set-DfsFileEncoding {
  param([string] $File)
  $content = Get-Content -Path $File
  [System.IO.File]::WriteAllLines($File, $content, [System.Text.Encoding]::ASCII)
}

function Export-DFSNamespaceXml {
  param(
    [string] $DfsServer,
    [string] $Namespace,
    [string] $BackupDirectory,
    [bool]   $SkipIfExists = $false
  )
  $dfsUtil = Get-DfsUtil
  $exportDir = Join-Path $BackupDirectory $DfsServer
  $exportPath = Join-Path $exportDir "$Namespace.xml"

  # Reuse existing export when caller allows it.
  if ($SkipIfExists -and (Test-Path -Path $exportPath)) {
    if ((Get-Item $exportPath).Length -eq 0) {
      throw "Existing namespace export is 0 bytes: $exportPath"
    }
    Write-Status "  Reusing existing export: $exportPath"
    return [string]$exportPath
  }

  if (-not (Test-Path $exportDir)) {
    New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
  }
  if (Test-Path $exportPath) {
    Remove-Item -Path $exportPath -Force
  }

  Write-Status "  Running dfsutil export for \\$DfsServer\$Namespace..."
  $output = & "$dfsUtil" /root:"\\$DfsServer\$Namespace" /export:"$exportPath" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "dfsutil export failed for '\\$DfsServer\$Namespace' (exit code $LASTEXITCODE). Output: $output"
  }
  if ((Get-Item $exportPath).Length -eq 0) {
    throw "dfsutil produced a 0-byte export for '\\$DfsServer\$Namespace': $exportPath"
  }
  Set-DfsFileEncoding -File $exportPath
  return [string]$exportPath
}

function Get-TargetStateLabel {
  param([string] $XmlStateValue)
  if ([string]::IsNullOrWhiteSpace($XmlStateValue)) { return "Unknown" }
  try { $stateInt = [int]$XmlStateValue } catch { return "Unknown ($XmlStateValue)" }
  if ($stateInt -eq 2) { return "Online" }
  if (($stateInt -band 0x4) -ne 0) { return "Offline" }
  if (($stateInt -band 0x2) -eq 0) { return "Inactive" }
  return "Unknown ($stateInt)"
}

function Get-Uptime {
  param([string]$ServerName)
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ServerName
    [pscustomobject]@{
      LastBootUpTime = $os.LastBootUpTime
      Uptime         = (Get-Date) - $os.LastBootUpTime
    }
  } catch {
    [pscustomobject]@{
      LastBootUpTime = $null
      Uptime         = $null
      Error          = $_.Exception.Message
    }
  }
}

function Get-ServiceStatus {
  param([string]$ServerName, [string[]]$ServiceNames)
  $ServiceNames | ForEach-Object {
    $name = $_
    try {
      $svc = Get-Service -Name $name -ComputerName $ServerName -ErrorAction Stop
      [pscustomobject]@{
        Name        = $svc.Name
        DisplayName = $svc.DisplayName
        Status      = $svc.Status
        StartType   = (Get-CimInstance Win32_Service -Filter "Name='$name'" -ComputerName $ServerName).StartMode
      }
    } catch {
      [pscustomobject]@{
        Name   = $name
        Status = "NotFoundOrNoAccess"
        Error  = $_.Exception.Message
      }
    }
  }
}

function Get-RecentEvents {
  param(
    [string]$ServerName,
    [string]$LogName,
    [datetime]$StartTime,
    [int[]]$Levels = @(1,2,3) # 1=Critical,2=Error,3=Warning
  )
  try {
    Get-WinEvent -ComputerName $ServerName -FilterHashtable @{
      LogName   = $LogName
      StartTime = $StartTime
    } -ErrorAction Stop |
      Where-Object { $Levels -contains $_.Level } |
      Select-Object -First 200 |
      Select-Object TimeCreated, LevelDisplayName, Id, ProviderName, Message
  } catch {
    @([pscustomobject]@{
      TimeCreated     = $null
      LevelDisplayName= $null
      Id              = $null
      ProviderName    = $null
      Message         = "Could not read $LogName : $($_.Exception.Message)"
    })
  }
}

function Get-Disks {
  param([string]$ServerName)
  try {
    Get-CimInstance -ClassName Win32_LogicalDisk -ComputerName $ServerName -Filter "DriveType=3" |
      Select-Object DeviceID, VolumeName,
        @{n="SizeGB";e={[math]::Round($_.Size/1GB,2)}},
        @{n="FreeGB";e={[math]::Round($_.FreeSpace/1GB,2)}},
        @{n="FreePct";e={ if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace/$_.Size)*100,1) } else { $null } }}
  } catch {
    @([pscustomobject]@{ DeviceID=$null; Error=$_.Exception.Message })
  }
}

# ---------------- Main ----------------

$scriptStartTime = Get-Date
$startTime = $scriptStartTime.AddHours(-1 * $EventLogLookbackHours)

# Resolve export directory — user-specified or auto-generated temp.
$usingTempExportDir = [string]::IsNullOrWhiteSpace($ExportDirectory)
if ($usingTempExportDir) {
  $resolvedExportDir = Join-Path $env:TEMP ("DfsHealthReport_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
} else {
  $resolvedExportDir = $ExportDirectory
}
$skipExisting = (-not $usingTempExportDir) -and (-not $ForceExport)

try {

foreach ($DfsServer in $DfsServers) {
  $serverStartTime = Get-Date
  Write-Status "═══════════════════════════════════════════════════════════════"
  Write-Status " Processing DFS server: $DfsServer (Namespace: $Namespace)"
  Write-Status "═══════════════════════════════════════════════════════════════"

  # -------- Host Info --------
  Write-Status "Gathering host info for $DfsServer..."
  $hostInfo = [pscustomobject]@{
    ComputerName = $DfsServer
    Timestamp    = (Get-Date)
    Uptime       = Get-Uptime -ServerName $DfsServer
    Disks        = Get-Disks -ServerName $DfsServer
    Services     = Get-ServiceStatus -ServerName $DfsServer -ServiceNames @("Dfs")
  }
  Write-Status "Host info gathered."

  # -------- DFSN (Namespaces) --------
  $root = "\\$DfsServer\$Namespace"
  $dfsn = [pscustomobject]@{
    NamespaceRoot      = $root
    LinksTotal         = 0
    LinksActive        = 0
    LinksInactive      = 0
    LinksWithNoTargets = 0
    TargetsTotal       = 0
    TargetsOnline      = 0
    TargetsOffline     = 0
    RootInfo           = $null
    Folders            = @()
    Errors             = @()
  }

  try {
    Write-Status "Processing namespace root: $root"

    # Export namespace via dfsutil
    $exportedXmlPath = $null
    try {
      $exportedXmlPath = Export-DFSNamespaceXml -DfsServer $DfsServer -Namespace $Namespace -BackupDirectory $resolvedExportDir -SkipIfExists $skipExisting
      Write-Status "  Exported: $exportedXmlPath"
    } catch {
      $msg = "Failed to export namespace '$root': $($_.Exception.Message)"
      Write-Warning $msg
      $dfsn.Errors += $msg
      # Still emit partial result for this server, then continue to next server
      [pscustomobject]@{
        Summary = [pscustomobject]@{ DfsServer = $DfsServer; Namespace = $Namespace; Errors = $dfsn.Errors.Count }
        Host    = $hostInfo
        DFSN    = $dfsn
        Events  = $null
      }
      continue
    }

    # Parse the exported XML
    [xml]$xml = Get-Content $exportedXmlPath

    # Root-level targets (from the XML Root element's Target children)
    $rootXmlTargets = @()
    if ($xml.Root.Target) {
      $rootXmlTargets = @($xml.Root.Target)
    }
    $rootOnline  = ($rootXmlTargets | Where-Object { (Get-TargetStateLabel $_.State) -eq 'Online' }).Count
    $rootOffline = $rootXmlTargets.Count - $rootOnline

    $dfsn.RootInfo = [pscustomobject]@{
      RootPath           = $root
      RootTargets        = $rootXmlTargets | ForEach-Object {
        [pscustomobject]@{
          TargetPath = "\\$($_.Server)\$($_.Folder)"
          State      = Get-TargetStateLabel $_.State
        }
      }
      RootTargetsOnline  = $rootOnline
      RootTargetsOffline = $rootOffline
    }

    # Parse links (folders)
    $links = $xml.Root.Link
    if ($null -eq $links) {
      Write-Status "  No links found in namespace."
    } else {
      $allLinks = @($links)
      Write-Status "  Found $($allLinks.Count) link(s). Parsing targets..."

      $linkIndex = 0
      foreach ($link in $allLinks) {
        $linkIndex++
        if ($linkIndex % 500 -eq 0) {
          Write-Status "  Progress: $linkIndex / $($allLinks.Count) links..."
        }

        $linkName = [string]$link.Name
        $namespacePath = "$root\$($linkName.TrimStart('\'))"

        $xmlTargets = $link.Target
        $targetList = @()
        if ($null -ne $xmlTargets) { $targetList = @($xmlTargets) }

        $targetDetails = $targetList | ForEach-Object {
          [pscustomobject]@{
            TargetPath = "\\$($_.Server)\$($_.Folder)"
            State      = Get-TargetStateLabel $_.State
          }
        }

        $targetCount = $targetList.Count
        $onlineCount = ($targetDetails | Where-Object State -eq 'Online').Count
        $offlineCount = $targetCount - $onlineCount
        $isActive = $onlineCount -gt 0

        $dfsn.Folders += [pscustomobject]@{
          NamespacePath  = $namespacePath
          FolderState    = if ($isActive) { 'Online' } else { 'Offline' }
          TargetsTotal   = $targetCount
          TargetsOnline  = $onlineCount
          TargetsOffline = $offlineCount
          Active         = $isActive
          TargetDetails  = $targetDetails
        }
      }

      Write-Status "  Finished parsing $($allLinks.Count) links for $root."
    }

    Write-Status "DFSN enumeration complete. Computing totals..."
    $dfsn.LinksTotal         = $dfsn.Folders.Count
    $dfsn.LinksActive        = ($dfsn.Folders | Where-Object Active).Count
    $dfsn.LinksInactive      = $dfsn.LinksTotal - $dfsn.LinksActive
    $dfsn.LinksWithNoTargets = ($dfsn.Folders | Where-Object TargetsTotal -eq 0).Count
    $dfsn.TargetsTotal       = ($dfsn.Folders | Measure-Object -Property TargetsTotal -Sum).Sum
    $dfsn.TargetsOnline      = ($dfsn.Folders | Measure-Object -Property TargetsOnline -Sum).Sum
    $dfsn.TargetsOffline     = ($dfsn.Folders | Measure-Object -Property TargetsOffline -Sum).Sum

  } catch {
    Write-Warning "DFSN error on ${DfsServer}: $($_.Exception.Message)"
    $dfsn.Errors += $_.Exception.Message
  }

  # -------- Event Logs --------
  Write-Status "Querying event logs on $DfsServer (last $EventLogLookbackHours hours)..."
  $events = [pscustomobject]@{
    LookbackHours   = $EventLogLookbackHours
    StartTime       = $startTime
    DfsNamespace    = Get-RecentEvents -ServerName $DfsServer -LogName "Microsoft-Windows-DFS-Namespace/Operational" -StartTime $startTime
  }
  Write-Status "Event logs queried."

  # -------- Rollup / Summary --------
  $serverElapsed = (Get-Date) - $serverStartTime
  Write-Status "Building summary for $DfsServer... (elapsed: $($serverElapsed.ToString('mm\:ss\.fff')))"
  $summary = [pscustomobject]@{
    DfsServer        = $DfsServer
    Namespace        = $Namespace
    Timestamp        = (Get-Date)
    DFSN             = [pscustomobject]@{
      LinksTotal         = $dfsn.LinksTotal
      LinksActive        = $dfsn.LinksActive
      LinksInactive      = $dfsn.LinksInactive
      LinksWithNoTargets = $dfsn.LinksWithNoTargets
      TargetsTotal       = $dfsn.TargetsTotal
      TargetsOnline      = $dfsn.TargetsOnline
      TargetsOffline     = $dfsn.TargetsOffline
      RootTargetsOffline = if ($dfsn.RootInfo) { $dfsn.RootInfo.RootTargetsOffline } else { 0 }
      Errors             = $dfsn.Errors.Count
    }
    Events           = [pscustomobject]@{
      DfsNamespaceErrorsOrWarnings = ($events.DfsNamespace | Measure-Object).Count
    }
  }

  # Output one result object per server (pipeline-friendly)
  [pscustomobject]@{
    Summary = $summary
    Host    = $hostInfo
    DFSN    = $dfsn
    Events  = $events
  }
}

} finally {
  # Clean up only auto-generated temp directories; preserve user-specified export directories.
  if ($usingTempExportDir -and (Test-Path $resolvedExportDir)) {
    Remove-Item -Path $resolvedExportDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Cleaned up temp export directory."
  } elseif (-not $usingTempExportDir) {
    Write-Status "Exports preserved in: $resolvedExportDir"
  }
}

$totalElapsed = (Get-Date) - $scriptStartTime
Write-Status "Done. Total elapsed: $($totalElapsed.ToString('mm\:ss\.fff'))"
