[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory=$true, HelpMessage="The name of the file server where we will be deleting the builds from.")]
    [string] $FileServer,

    [int] $MaxConcurrentDeletions = 5,
    [string] $DeleteOperationName = "manualRetention",

    [Parameter(Mandatory=$false, HelpMessage="A unique folder name for this run of the script. Used as the subfolder in the DSS operation (\\fileserver\DSS\deleteOperation\branch\buildnumber\uniqueRunName) so you can re-run the same operations if they previously failed.")]
    [string] $UniqueSubFolderName,

    [string] $PathToBuildsToPreserveCsv = "\\FILESERVER01\Backups\PreservedBuilds.csv",

    [Parameter(HelpMessage="Flag to skip the status check when a new deletion is started. This can be used to speed up the deletes, but can result in errors if the build was already requested to be deleted.")]
    [switch] $SkipStatusCheck,

    [Parameter(HelpMessage="When set, also removes the DFS namespace link for each build after DSS deletion completes. Requires Dfsn module and DfsLinkPath in the cache JSON.")]
    [switch] $UnlinkDfsLink,

    [Parameter(Mandatory=$false, HelpMessage="Folder containing BuildsCache_<fileserver>.json files. Defaults to this script's folder.")]
    [string] $BuildsCacheFolderPath = $PSScriptRoot,

    [Parameter(Mandatory=$false, HelpMessage="Optional transcript log path. Defaults to logs\\Remove-OldBuilds_<timestamp>.log under this script folder.")]
    [string] $LogFilePath,

    [int] $RetentionPolicyAgeInDays = 90,
    [int] $SleepBetweenStatusChecksInSeconds = 15
)

$ConfirmPreference = 'None'
$TranscriptStarted = $false

if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFilePath = Join-Path $PSScriptRoot "logs\Remove-OldBuilds_$timestamp.log"
}

$logDirectory = Split-Path -Path $LogFilePath -Parent
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

Start-Transcript -Path $LogFilePath -Append | Out-Null
$TranscriptStarted = $true
Write-Host "Transcript log: $LogFilePath" -ForegroundColor Gray

try {

Import-Module -Name "$PSScriptRoot\DSSHelpers.psm1" -Force
Import-Module -Name "$PSScriptRoot\Retry-Helper.psm1" -Force

function Import-BuildDropsToPreserve
{
    param
    (
        [Parameter(Mandatory=$true, HelpMessage="The path to the CSV file that contains the list of build drops to preserve.")]
        [string] $PathToBuildsToPreserveCsv
    )

    if ([string]::IsNullOrWhiteSpace($PathToBuildsToPreserveCsv))
    {
        throw "Path to builds to preserve CSV file must be specified."
    }

    $BuildsToPreserveCsv = Get-ContentWithRetry -Path $PathToBuildsToPreserveCsv -Raw | ConvertFrom-Csv

    if ($BuildsToPreserveCsv.Count -eq 0)
    {
        throw "Preserved builds CSV file is empty: $PathToBuildsToPreserveCsv"
    }

    $PreservedBuilds = @()
    foreach ($BuildToPreserve in $BuildsToPreserveCsv) {
        try {
            # Build a new object for the BuildDrops that converts the QueueDateTime to a DateTime Object
            $PreservedBuilds += [PSCustomObject]@{
                QueueDateTime = [DateTime]::Parse($BuildToPreserve.QueueDateTime)
                BranchName = $BuildToPreserve.BranchName
                BuildNumber = $BuildToPreserve.BuildNumber
                BranchBuildName = Join-Path -Path $BuildToPreserve.branchName -ChildPath $BuildToPreserve.buildNumber
                PreserveForDays = [int]$BuildToPreserve.PreserveForDays
                PreserveUntilDateTime = ([DateTime]::Parse($BuildToPreserve.QueueDateTime)).AddDays([int]$BuildToPreserve.PreserveForDays)
            }
        }
        catch
        {
            throw "Failed to parse build drop entry: $($BuildToPreserve | ConvertTo-Json -Depth 5). Error: $($_.Exception.Message)"
        }
    }

    return $PreservedBuilds
}

function Test-BuildDropPreserved
{
    param
    (
        [string] $BranchName,
        [string] $BuildNumber,
        [Parameter(Mandatory=$true, HelpMessage="The list of builds to preserve.")]
        [PSCustomObject[]] $BuildsToPreserve
    )

    foreach ($preservedBuild in $BuildsToPreserve | Where-Object { $_.PreserveUntilDateTime -gt (Get-Date) })
    {
        if ($BranchName -eq $preservedBuild.BranchName -and $BuildNumber -eq $preservedBuild.BuildNumber)
        {
            Write-Host "Build drop $BranchName\$BuildNumber is marked for preservation until $($preservedBuild.PreserveUntilDateTime)" -ForegroundColor Yellow
            return $true
        }
    }
    return $false
}

function Remove-DfsBuildLink
{
    param
    (
        [Parameter(Mandatory=$true, HelpMessage="Full DFS namespace link path to remove.")]
        [string] $DfsLinkPath,

        [string] $BranchName,
        [string] $BuildNumber
    )

    $removeDfsnFolderCommand = Get-Command -Name Remove-DfsnFolder -ErrorAction SilentlyContinue
    if ($null -eq $removeDfsnFolderCommand)
    {
        try {
            Import-Module -Name Dfsn -ErrorAction Stop | Out-Null
        }
        catch {
            # Ignore here and rely on follow-up command check for clearer warning.
        }

        $removeDfsnFolderCommand = Get-Command -Name Remove-DfsnFolder -ErrorAction SilentlyContinue
        if ($null -eq $removeDfsnFolderCommand)
        {
            Write-Warning "Cannot unlink DFS path '$DfsLinkPath' for build $BranchName\$BuildNumber because Remove-DfsnFolder is unavailable. Ensure DFSN module is installed and available in this session."
            return $false
        }
    }

    try
    {
        if ($WhatIfPreference) {
            Write-Host "WhatIf: Would remove DFS link '$DfsLinkPath' for build $BranchName\$BuildNumber." -ForegroundColor Yellow
            Remove-DfsnFolder -Path $DfsLinkPath -Force -ErrorAction Stop -WhatIf:$true
            return $true
        }

        Write-Host "Removing DFS link '$DfsLinkPath' for build $BranchName\$BuildNumber..." -ForegroundColor Cyan
        Remove-DfsnFolder -Path $DfsLinkPath -Force -ErrorAction Stop
        Write-Host "DFS link removed for build $BranchName\$BuildNumber." -ForegroundColor Green
        return $true
    }
    catch
    {
        Write-Warning "Failed to remove DFS link '$DfsLinkPath' for build $BranchName\$BuildNumber. Error: $($_.Exception.Message)"
        return $false
    }
}

function Set-BuildDfsUnlinkState
{
    param
    (
        [Parameter(Mandatory=$true)]
        [object] $Build,

        [Parameter(Mandatory=$true)]
        [string] $State
    )

    if ($Build.PSObject.Properties.Name -contains "DfsUnlinkState") {
        $Build.DfsUnlinkState = $State
    } else {
        Add-Member -InputObject $Build -MemberType NoteProperty -Name "DfsUnlinkState" -Value $State
    }
}

# If the $FileServer parameter is not in the form of a FQDN, append the default domain.
if ($FileServer -notlike "*.*") {
    $DefaultDomain = "yourdomain.example.com"
    Write-Host "Appending the domain name to the file server name since it is not in the form of a FQDN. ($FileServer -> $FileServer.$DefaultDomain)" -ForegroundColor Yellow
    $FileServer = "$FileServer.$DefaultDomain"
}
$NormalizedFileServerName = $FileServer.Split(".")[0].ToLower()
$BuildsCacheFilePath = Join-Path -Path $BuildsCacheFolderPath -ChildPath "BuildsCache_$NormalizedFileServerName.json"
if (-Not (Test-Path -Path $BuildsCacheFilePath)) {
    Write-Host "The builds cache file does not exist at $BuildsCacheFilePath. Please run Get-Builds.ps1 first to populate the cache file before running this script." -ForegroundColor Red
    exit
}

# Get the list of preserved builds
$PreservedBuilds = Import-BuildDropsToPreserve -PathToBuildsToPreserveCsv $PathToBuildsToPreserveCsv
Write-Host "Imported $($PreservedBuilds.Count) builds to preserve from $PathToBuildsToPreserveCsv" -ForegroundColor Cyan

# Populate the initial list of builds, sorted by oldest creation time first.
$BuildsToProcess = [System.Collections.Generic.List[object]](
    Get-Content -Path $BuildsCacheFilePath -Raw |
        ConvertFrom-Json |
        Sort-Object -Property CreationTime
)

if ($UnlinkDfsLink) {
    foreach ($Build in $BuildsToProcess) {
        if (-not ($Build.PSObject.Properties.Name -contains "DfsUnlinkState")) {
            Set-BuildDfsUnlinkState -Build $Build -State "NotStarted"
        }
    }
}

# We will not process any builds that were created after this cutoff date. But we will keep them in the list since we might re-run this script later to delete them.
$CutoffDate = (Get-Date).AddDays(-$RetentionPolicyAgeInDays)
$TotalBuildsToDelete = $BuildsToProcess | Where-Object { $_.CreationTime -lt $CutoffDate } | Measure-Object | Select-Object -ExpandProperty Count
$TotalBuildsInCache = $BuildsToProcess.Count
$TotalBuildsDeleted = 0
$DfsUnlinkFailures = [System.Collections.Generic.HashSet[string]]::new()
$MissingDfsLinkPathCount = 0
$PreservedBuildsSkippedCount = 0
$DssDeleteRequestsSubmittedCount = 0
$DssCompletedBuildsCount = 0
$DfsUnlinkAttemptedCount = 0
$DfsUnlinkSucceededCount = 0
$DfsUnlinkFailedCount = 0
$RemovedArtifactFolders = [System.Collections.Generic.HashSet[string]]::new()
$RemovedDfsLinks = [System.Collections.Generic.HashSet[string]]::new()
Write-Host "There are $($BuildsToProcess.Count) total builds in the cache file, of which $TotalBuildsToDelete are older than the cutoff date of $CutoffDate and will be processed for deletion." -ForegroundColor Cyan
$ActivityName = "Deleting Builds on $FileServer more than $RetentionPolicyAgeInDays days old"

if ($UnlinkDfsLink) {
    Write-Host "DFS unlink is enabled. The script will also remove DfsLinkPath entries after deletion completes." -ForegroundColor Cyan
}

# Loop through the list until we we have deleted everything. We will exit the loop if we have reached the builds that were created after the cutoff date.
while ($BuildsToProcess.Count -gt 0) {
    $percentComplete = [Math]::Round(($TotalBuildsDeleted / $TotalBuildsToDelete) * 100, 2)

    # Get the list of builds currently being processed.
    $InProgressBuilds = @($BuildsToProcess | Where-Object { $_.State -eq "InProgress" })
    $InProgressBuildCount = $InProgressBuilds.Count

    if ($InProgressBuildCount -gt 0) {
        Write-Host "$InProgressBuildCount builds are currently being processed. Checking on their status to see if we can add any new parallel deletions." -ForegroundColor Cyan

        # Update the state of the builds.
        $InProgressBuildNumber = 0
        foreach ($Build in $InProgressBuilds) {
            $InProgressBuildNumber++
            Write-Progress `
                -Activity $ActivityName `
                -CurrentOperation "Checking status of $InProgressBuildNumber of $InProgressBuildCount InProgress builds" `
                -Status "$TotalBuildsDeleted of $TotalBuildsToDelete builds deleted." `
                -PercentComplete $percentComplete

            $NewState = if ($WhatIfPreference) {
                # In WhatIf mode, just simulate that the DSS action is complete.
                [PSCustomObject]@{ JobStatus = 'Completed'; JobResult = 'Succeeded' }
            } else {
                Get-DSSOperationStatus -FileServer $FileServer -OperationName $DeleteOperationName -DfsFolderName $Build.DfsFolderName -BuildNumber $Build.BuildNumber -SubFolderName $UniqueSubFolderName
            }

            $MarkAsDeleted = $false
            switch ($NewState.JobStatus) {
                'Completed' {
                    Write-Host "Build $($Build.DfsFolderName)\$($Build.BuildNumber) has completed deletion (Result = $($NewState.JobResult))." -ForegroundColor Green
                    $MarkAsDeleted = $true
                }
                'InProgress' {
                    Write-Host "Build $($Build.DfsFolderName)\$($Build.BuildNumber) is still in-progress." -ForegroundColor Yellow
                }
                'Queued' {
                    Write-Host "Build $($Build.DfsFolderName)\$($Build.BuildNumber) is queued and has not yet been picked up by the DSS server. If this persists, check the DSS server status." -ForegroundColor Yellow
                }
                'Stalled' {
                    Write-Warning "Build $($Build.DfsFolderName)\$($Build.BuildNumber) is stalled (picked up by DSS server but no result written). Giving up and treating this as Completed."
                    $MarkAsDeleted = $true
                }
                'NotSubmitted' {
                    Write-Warning "Build $($Build.DfsFolderName)\$($Build.BuildNumber) is no longer submitted. It may have been cleaned up externally."
                    $MarkAsDeleted = $true
                }
                default {
                    Write-Warning "Build $($Build.DfsFolderName)\$($Build.BuildNumber) has an unexpected status: $($NewState.JobStatus)."
                }
            }

            if ($MarkAsDeleted) {
                $DssCompletedBuildsCount++
                $null = $RemovedArtifactFolders.Add("$($Build.DfsFolderName)\$($Build.BuildNumber)")
                if ($UnlinkDfsLink) {
                    if (-not ($Build.PSObject.Properties.Name -contains "DfsLinkPath") -or [string]::IsNullOrWhiteSpace($Build.DfsLinkPath)) {
                        Set-BuildDfsUnlinkState -Build $Build -State "MissingPath"
                        $Build.State = "Completed"
                        $InProgressBuildCount--
                        $MissingDfsLinkPathCount++
                        if ($MissingDfsLinkPathCount -le 5) {
                            Write-Warning "Build $($Build.DfsFolderName)\$($Build.BuildNumber) has no DfsLinkPath in cache JSON; skipping DFS unlink."
                        } elseif ($MissingDfsLinkPathCount -eq 6) {
                            Write-Warning "Suppressing further missing DfsLinkPath warnings for this run."
                        }
                    } else {
                        $DfsUnlinkAttemptedCount++
                        $dfsUnlinkSucceeded = Remove-DfsBuildLink -DfsLinkPath $Build.DfsLinkPath -BranchName $Build.DfsFolderName -BuildNumber $Build.BuildNumber -WhatIf:$WhatIfPreference
                        if ($dfsUnlinkSucceeded) {
                            $DfsUnlinkSucceededCount++
                            $null = $RemovedDfsLinks.Add($Build.DfsLinkPath)
                            Set-BuildDfsUnlinkState -Build $Build -State "Completed"
                            $null = $BuildsToProcess.Remove($Build)
                            $InProgressBuildCount--
                            $TotalBuildsDeleted++
                            $null = $DfsUnlinkFailures.Remove("$($Build.DfsFolderName)\$($Build.BuildNumber) -> $($Build.DfsLinkPath)")
                        } else {
                            $DfsUnlinkFailedCount++
                            Set-BuildDfsUnlinkState -Build $Build -State "Failed"
                            $Build.State = "Completed"
                            $InProgressBuildCount--
                            $null = $DfsUnlinkFailures.Add("$($Build.DfsFolderName)\$($Build.BuildNumber) -> $($Build.DfsLinkPath)")
                        }
                    }
                } else {
                    $BuildsToProcess.Remove($Build) | Out-Null
                    $InProgressBuildCount--
                    $TotalBuildsDeleted++
                }
            }
        }

        Write-Host "There are now $InProgressBuildCount builds in-progress after checking status." -ForegroundColor Cyan
    } else {
        Write-Host "No builds are currently being processed. Adding more builds to process." -ForegroundColor Cyan
    }

    if ($UnlinkDfsLink) {
        $PendingDfsUnlinkBuilds = @(
            $BuildsToProcess | Where-Object {
                $_.State -eq "Completed" -and
                ($_.PSObject.Properties.Name -contains "DfsUnlinkState") -and
                ($_.DfsUnlinkState -in @("NotStarted", "Failed"))
            }
        )

        if ($PendingDfsUnlinkBuilds.Count -gt 0) {
            Write-Host "Retrying DFS unlink for $($PendingDfsUnlinkBuilds.Count) completed build(s)." -ForegroundColor Cyan
        }

        foreach ($Build in $PendingDfsUnlinkBuilds) {
            if (-not ($Build.PSObject.Properties.Name -contains "DfsLinkPath") -or [string]::IsNullOrWhiteSpace($Build.DfsLinkPath)) {
                Set-BuildDfsUnlinkState -Build $Build -State "MissingPath"
                $MissingDfsLinkPathCount++
                if ($MissingDfsLinkPathCount -le 5) {
                    Write-Warning "Build $($Build.DfsFolderName)\$($Build.BuildNumber) has no DfsLinkPath in cache JSON; skipping DFS unlink."
                } elseif ($MissingDfsLinkPathCount -eq 6) {
                    Write-Warning "Suppressing further missing DfsLinkPath warnings for this run."
                }
                continue
            }

            $DfsUnlinkAttemptedCount++
            $dfsUnlinkSucceeded = Remove-DfsBuildLink -DfsLinkPath $Build.DfsLinkPath -BranchName $Build.DfsFolderName -BuildNumber $Build.BuildNumber -WhatIf:$WhatIfPreference
            if ($dfsUnlinkSucceeded) {
                $DfsUnlinkSucceededCount++
                $null = $RemovedDfsLinks.Add($Build.DfsLinkPath)
                Set-BuildDfsUnlinkState -Build $Build -State "Completed"
                $null = $BuildsToProcess.Remove($Build)
                $TotalBuildsDeleted++
                $null = $DfsUnlinkFailures.Remove("$($Build.DfsFolderName)\$($Build.BuildNumber) -> $($Build.DfsLinkPath)")
            } else {
                $DfsUnlinkFailedCount++
                Set-BuildDfsUnlinkState -Build $Build -State "Failed"
                $null = $DfsUnlinkFailures.Add("$($Build.DfsFolderName)\$($Build.BuildNumber) -> $($Build.DfsLinkPath)")
            }
        }
    }

    $NumberOfNewBuildsToDelete = [Math]::Max($MaxConcurrentDeletions - $InProgressBuildCount, 0)

    if ($NumberOfNewBuildsToDelete -le 0) {
        Write-Host "The number of builds currently in-progress ($InProgressBuildCount) has reached the maximum concurrent deletions limit of $MaxConcurrentDeletions, so we cannot add any new builds to process until some of the in-progress builds have completed." -ForegroundColor Yellow
    } else {
        Write-Host "Starting a new batch of deletions of $NumberOfNewBuildsToDelete builds older that are than $CutoffDate with up to $NumberOfNewBuildsToDelete builds in this batch." -ForegroundColor Cyan

        $BuildsToStart = $BuildsToProcess |
            Where-Object { $_.State -eq "NotStarted" } |
            Where-Object { $_.CreationTime -lt $CutoffDate } |
            Select-Object -First $NumberOfNewBuildsToDelete
        
        $BuildToStartNumber = 0
        foreach ($BuildToStart in $BuildsToStart) {
            $BuildToStartNumber++
            Write-Progress `
                -Activity $ActivityName `
                -CurrentOperation "Starting $BuildToStartNumber of $NumberOfNewBuildsToDelete new deletions" `
                -Status "$TotalBuildsDeleted of $TotalBuildsToDelete builds deleted." `
                -PercentComplete $percentComplete

            if (Test-BuildDropPreserved -BranchName $BuildToStart.DfsFolderName -BuildNumber $BuildToStart.BuildNumber -BuildsToPreserve $PreservedBuilds)
            {
                Write-Host "Skipping deletion of build $($BuildToStart.DfsFolderName)\$($BuildToStart.BuildNumber) because it is marked for preservation." -ForegroundColor Yellow
                # Remove the build from the list since we are not going to delete it.
                $BuildsToProcess.Remove($BuildToStart) | Out-Null
                $PreservedBuildsSkippedCount++
                $TotalBuildsDeleted++
                continue
            } else {
                $AgeInDays = [Math]::Round(((Get-Date) - $BuildToStart.CreationTime).TotalDays)
                Write-Host "Starting deletion of build $($BuildToStart.DfsFolderName)\$($BuildToStart.BuildNumber) because it is $AgeInDays days old." -ForegroundColor Green

                Remove-DSSBuild -FileServer $FileServer -OperationName $DeleteOperationName -DfsFolderName $BuildToStart.DfsFolderName -BuildNumber $BuildToStart.BuildNumber -SubFolderName $UniqueSubFolderName -SkipStatusCheck:$SkipStatusCheck -WhatIf:$WhatIfPreference | Out-Null
                $DssDeleteRequestsSubmittedCount++
                $BuildToStart.State = "InProgress"
                if ($UnlinkDfsLink) {
                    Set-BuildDfsUnlinkState -Build $BuildToStart -State "NotStarted"
                }
                $InProgressBuildCount++
            }
        }

        Write-Progress `
            -Activity $ActivityName `
            -CurrentOperation "Updating State file" `
            -Status "$TotalBuildsDeleted of $TotalBuildsToDelete builds deleted." `
            -PercentComplete $percentComplete

        # Persist current state so a re-run can resume without restarting from scratch.
        Write-Host "Persisting the current state of the builds to the cache file at $BuildsCacheFilePath so that we can resume from this point if needed." -ForegroundColor Cyan
        $BuildsToProcess | ConvertTo-Json -Depth 5 | Out-File -FilePath $BuildsCacheFilePath -Encoding UTF8

        # End the loop if no additional work can be performed in this run.
        $RemainingDeletionCandidates = @($BuildsToProcess | Where-Object { $_.State -eq "NotStarted" -and $_.CreationTime -lt $CutoffDate }).Count
        $RemainingPendingDfsUnlink = if ($UnlinkDfsLink) {
            @(
                $BuildsToProcess | Where-Object {
                    $_.State -eq "Completed" -and
                    ($_.PSObject.Properties.Name -contains "DfsUnlinkState") -and
                    ($_.DfsUnlinkState -in @("NotStarted", "Failed"))
                }
            ).Count
        } else {
            0
        }

        if ($InProgressBuildCount -le 0 -and $RemainingDeletionCandidates -le 0 -and $RemainingPendingDfsUnlink -le 0) {
            Write-Host "There are no more builds to process in this run. Remaining cache entries are either newer than cutoff, preserved, or missing DFS link metadata for unlink." -ForegroundColor Cyan
            break
        }
    }

    Write-Progress `
        -Activity $ActivityName `
        -CurrentOperation "Waiting $SleepBetweenStatusChecksInSeconds seconds for DSS operations to progress before checking again" `
        -Status "$TotalBuildsDeleted of $TotalBuildsToDelete builds deleted." `
        -PercentComplete $percentComplete

    # Sleep for a bit before checking on the status of the in-progress deletions.
    Write-Host "Sleeping for $SleepBetweenStatusChecksInSeconds seconds before checking on the status of the in-progress deletions." -ForegroundColor Cyan
    Start-Sleep -Seconds $SleepBetweenStatusChecksInSeconds
}

Write-Progress `
    -Activity $ActivityName `
    -Completed

$RemainingDeletionCandidates = @($BuildsToProcess | Where-Object { $_.State -eq "NotStarted" -and $_.CreationTime -lt $CutoffDate }).Count
$RemainingInProgress = @($BuildsToProcess | Where-Object { $_.State -eq "InProgress" }).Count
$RemainingCompletedPendingUnlink = if ($UnlinkDfsLink) {
    @(
        $BuildsToProcess | Where-Object {
            $_.State -eq "Completed" -and
            ($_.PSObject.Properties.Name -contains "DfsUnlinkState") -and
            ($_.DfsUnlinkState -in @("NotStarted", "Failed"))
        }
    ).Count
} else {
    0
}

Write-Host "" 
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Operation Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Mode: $(if ($WhatIfPreference) { 'WhatIf (simulation)' } else { 'Execute' })" -ForegroundColor Gray
Write-Host "  File server: $FileServer" -ForegroundColor Gray
Write-Host "  Cache file: $BuildsCacheFilePath" -ForegroundColor Gray
Write-Host "  Total in cache at start: $TotalBuildsInCache" -ForegroundColor Gray
Write-Host "  Eligible by age cutoff: $TotalBuildsToDelete" -ForegroundColor Gray
Write-Host "  Preserved builds skipped: $PreservedBuildsSkippedCount" -ForegroundColor Gray
Write-Host "  DSS delete requests submitted: $DssDeleteRequestsSubmittedCount" -ForegroundColor Gray
Write-Host "  DSS completed detections: $DssCompletedBuildsCount" -ForegroundColor Gray
Write-Host "  Builds processed/removed from queue: $TotalBuildsDeleted" -ForegroundColor Gray

if ($UnlinkDfsLink) {
    Write-Host "  DFS unlink attempts: $DfsUnlinkAttemptedCount" -ForegroundColor Gray
    Write-Host "  DFS unlink succeeded: $DfsUnlinkSucceededCount" -ForegroundColor Gray
    Write-Host "  DFS unlink failed (this run): $DfsUnlinkFailedCount" -ForegroundColor Gray
    Write-Host "  DFS unlink missing path: $MissingDfsLinkPathCount" -ForegroundColor Gray
    Write-Host "  Remaining completed pending unlink: $RemainingCompletedPendingUnlink" -ForegroundColor Gray
}

Write-Host "  Remaining in-progress: $RemainingInProgress" -ForegroundColor Gray
Write-Host "  Remaining eligible not started: $RemainingDeletionCandidates" -ForegroundColor Gray
Write-Host "  Remaining entries in cache: $($BuildsToProcess.Count)" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($RemovedArtifactFolders.Count -gt 0) {
    $artifactActionText = if ($WhatIfPreference) { "Artifact folders that would be removed" } else { "Artifact folders removed" }
    Write-Host "" 
    Write-Host "$artifactActionText ($($RemovedArtifactFolders.Count))" -ForegroundColor Cyan
    foreach ($folder in ($RemovedArtifactFolders | Sort-Object)) {
        Write-Host "  $folder" -ForegroundColor Gray
    }
}

if ($UnlinkDfsLink -and $RemovedDfsLinks.Count -gt 0) {
    $dfsActionText = if ($WhatIfPreference) { "DFS links that would be removed" } else { "DFS links removed" }
    Write-Host "" 
    Write-Host "$dfsActionText ($($RemovedDfsLinks.Count))" -ForegroundColor Cyan
    foreach ($dfsLink in ($RemovedDfsLinks | Sort-Object)) {
        Write-Host "  $dfsLink" -ForegroundColor Gray
    }
}

if ($UnlinkDfsLink) {
    if ($MissingDfsLinkPathCount -gt 0) {
        Write-Warning "$MissingDfsLinkPathCount build(s) were missing DfsLinkPath and were not unlinked from DFS namespace."
    }

    if ($DfsUnlinkFailures.Count -gt 0) {
        Write-Warning "$($DfsUnlinkFailures.Count) DFS unlink operation(s) failed."
        foreach ($failure in $DfsUnlinkFailures) {
            Write-Warning "  $failure"
        }
    } else {
        Write-Host "DFS unlink operations completed with no reported failures." -ForegroundColor Green
    }
}

Write-Host "All builds in the cache file have been processed." -ForegroundColor Green

}
finally {
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}