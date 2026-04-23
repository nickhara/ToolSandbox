Import-Module "$PSScriptRoot\Retry-Helper.psm1"


<#
.SYNOPSIS
    Gets the current status of a DSS operation by inspecting the action root folder.

.DESCRIPTION
    Determines the job status and result of a DSS operation by checking for the presence
    of well-known sentinel files in the operation's action root directory on the file server.
    Uses retry logic to handle transient network issues when listing the directory.

.PARAMETER FileServer
    The file server hosting the DSS share.

.PARAMETER OperationName
    The DSS operation name (e.g. "DeleteBuildShare").

.PARAMETER DfsFolderName
    The DFS folder name identifying the branch (e.g. "git_MyProject_main").

.PARAMETER BuildNumber
    The build number (e.g. "1.2.3.4").

.PARAMETER SubFolderName
    Optional subfolder under the build folder (e.g. "maindrop").

.OUTPUTS
    A PSCustomObject with the following properties:
      JobStatus  - One of: NotSubmitted, Queued, InProgress, Stalled, Completed
      JobResult  - One of: Unknown, Succeeded, Failed
      ActionRoot - The full UNC path to the action root directory that was checked.

.NOTES
    Status is determined by the presence of sentinel files, matching the DSS server-side agent logic:
      .lock                - InProgress
      .success or .failure - Completed
      action.json.processed (no lock/result files) - Stalled (picked up but no result written)
      action.json          - Queued (submitted, not yet picked up by DSS server)
      None of the above    - NotSubmitted

    Throws if the directory listing fails for a reason other than the path not existing
    (e.g. exhausted retries due to a network failure).
#>
function Get-DSSOperationStatus
{
    param
    (
        [Parameter(HelpMessage="The file server to check DSS status for.", Mandatory=$true)]
        [string] $FileServer,
        [Parameter(HelpMessage="The operation name.", Mandatory=$true)]
        [string] $OperationName,
        [Parameter(HelpMessage="The DFS folder name (e.g. git_MyProject_main).", Mandatory=$true)]
        [string] $DfsFolderName,
        [Parameter(HelpMessage="The build number (e.g. 1.2.3.4).", Mandatory=$true)]
        [string] $BuildNumber,
        [Parameter(HelpMessage="Optional subfolder name under the build folder (e.g. maindrop).", Mandatory=$false)]
        [string] $SubFolderName
    )

    $ActionRoot = "\\$FileServer\DSS\$OperationName\$DfsFolderName\$BuildNumber\$SubFolderName".TrimEnd('\')

    $files = $null
    try
    {
        $files = Get-ChildItemWithRetry -Path $ActionRoot -File -MaxRetries 3 | Select-Object -ExpandProperty Name
    }
    catch
    {
        # If the path simply doesn't exist, the action was never submitted.
        # Re-throw anything else (e.g. exhausted retries on a transient network failure)
        # so the caller can handle it.
        if ($_.Exception.Message -like '*does not exist*' -or
            $_.Exception.Message -like '*cannot find path*' -or
            $_ -is [System.Management.Automation.ItemNotFoundException])
        {
            return [PSCustomObject]@{
                JobStatus  = 'NotSubmitted'
                JobResult  = 'Unknown'
                ActionRoot = $ActionRoot
            }
        }
        throw
    }

    # Determine JobResult: .failure takes priority over .success
    $jobResult = 'Unknown'
    if ($files -contains '.failure')
    {
        $jobResult = 'Failed'
    }
    elseif ($files -contains '.success')
    {
        $jobResult = 'Succeeded'
    }

    # Determine JobStatus using the same priority order as the DSS server-side agent:
    #   .lock           → InProgress
    #   .success/.failure → Completed
    #   action.json.processed (no lock/result) → Stalled (picked up but no result written)
    #   action.json     → Queued (submitted, not yet picked up)
    #   none of the above → NotSubmitted
    $jobStatus = switch ($true)
    {
        ($files -contains '.lock')                        { 'InProgress'; break }
        ($files -contains '.success' -or
         $files -contains '.failure')                     { 'Completed';  break }
        ($files -contains 'action.json.processed')        { 'Stalled';    break }
        ($files -contains 'action.json')                  { 'Queued';     break }
        default                                           { 'NotSubmitted' }
    }

    return [PSCustomObject]@{
        JobStatus  = $jobStatus
        JobResult  = $jobResult
        ActionRoot = $ActionRoot
    }
}


<#
.SYNOPSIS
    Submits a DSS build share deletion action for a given build.

.DESCRIPTION
    Queues a build share deletion by writing an action.json file to the DSS operation directory
    on the target file server. The DSS server will pick up the file and process the deletion.

    By default, the current operation status is checked first using Get-DSSOperationStatus. If the
    action has already been submitted (any status other than NotSubmitted), the function logs a
    warning and returns the existing status without creating a duplicate action.json.

    Supports -WhatIf: when specified, the directory and action.json are not created, but the
    function still returns a Queued status object so callers behave consistently in dry-run mode.

.PARAMETER FileServer
    The file server hosting the DSS share where the action.json will be written.

.PARAMETER OperationName
    The DSS operation name (e.g. "manualRetention"). Used as a subfolder under \\FileServer\DSS\.

.PARAMETER DfsFolderName
    The DFS folder name identifying the branch (e.g. "git_MyProject_main").

.PARAMETER BuildNumber
    The build number to delete (e.g. "1.2.3.4").

.PARAMETER SubFolderName
    Optional subfolder under the build folder (e.g. "maindrop"). If omitted the build root is used.

.PARAMETER SkipStatusCheck
    If specified, skips the pre-submission status check via Get-DSSOperationStatus. This speeds up
    bulk submissions but risks writing a duplicate action.json if the build was already submitted.

.OUTPUTS
    A PSCustomObject with the following properties:
      JobStatus  - 'Queued' (or the existing status if already submitted)
      JobResult  - 'Unknown'
      ActionRoot - The full UNC path to the action root directory.

.EXAMPLE
    Remove-DSSBuild -FileServer "myserver.yourdomain.example.com" `
        -OperationName "manualRetention" `
        -DfsFolderName "git_MyRepo_master" `
        -BuildNumber "1.2.3.4"

.EXAMPLE
    Remove-DSSBuild -FileServer "myserver" -OperationName "manualRetention" `
        -DfsFolderName "git_MyRepo_master" -BuildNumber "1.2.3.4" -WhatIf

.NOTES
    Throws if the directory or file cannot be created (e.g. no write access to the DSS share).
#>
function Remove-DSSBuild {
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(HelpMessage="The file server to delete the build from.", Mandatory=$true)]
        [string] $FileServer,
        [Parameter(HelpMessage="The operation name.", Mandatory=$true)]
        [string] $OperationName,
        [Parameter(HelpMessage="The DFS folder name (e.g. git_MyProject_main).", Mandatory=$true)]
        [string] $DfsFolderName,
        [Parameter(HelpMessage="The build number (e.g. 1.2.3.4).", Mandatory=$true)]
        [string] $BuildNumber,
        [Parameter(HelpMessage="Optional subfolder name under the build folder (e.g. maindrop).", Mandatory=$false)]
        [string] $SubFolderName,
        [Parameter(HelpMessage="The flag to skip status check when starting a new deletion operation.")]
        [switch] $SkipStatusCheck
    )

    $ActionRoot = "\\$FileServer\DSS\$OperationName\$DfsFolderName\$BuildNumber\$SubFolderName".TrimEnd('\')

    if (-not $SkipStatusCheck) {
        # Check current state before doing anything. We use Get-DSSOperationStatus here so that
        # Get-ChildItemWithRetry handles transient network issues consistently.
        $CurrentStatus = Get-DSSOperationStatus -FileServer $FileServer `
            -OperationName $OperationName `
            -DfsFolderName $DfsFolderName `
            -BuildNumber $BuildNumber `
            -SubFolderName $SubFolderName

        if ($CurrentStatus.JobStatus -ne 'NotSubmitted')
        {
            Write-Warning "Skipping deletion of $DfsFolderName\$BuildNumber - already submitted (JobStatus = $($CurrentStatus.JobStatus), JobResult = $($CurrentStatus.JobResult))."
            return $CurrentStatus
        }
    }
    
    # Action has not been submitted yet — create the action.json to queue the deletion.
    $ActionJsonPath = Join-Path -Path $ActionRoot -ChildPath 'action.json'
    $ActionJson = [PSCustomObject]@{
        Action            = 'buildsharedeletion'
        DestinationServer = $FileServer
        DfsFolderName     = $DfsFolderName
        BuildNumber       = $BuildNumber
        BuildType         = "ManualRetention"
        GitRepositoryName = "Unknown"
    }
    if ($SubFolderName) { $ActionJson | Add-Member -NotePropertyName 'SubFolderName' -NotePropertyValue $SubFolderName }

    if ($PSCmdlet.ShouldProcess($ActionRoot, "Submit DSS deletion action for $DfsFolderName\$BuildNumber"))
    {
        $null = New-Item -Path $ActionRoot -ItemType Directory -Force
        $ActionJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $ActionJsonPath -Encoding UTF8
    }

    return [PSCustomObject]@{
        JobStatus  = 'Queued'
        JobResult  = 'Unknown'
        ActionRoot = $ActionRoot
    }
}

Export-ModuleMember -Function "Get-DSSOperationStatus"
Export-ModuleMember -Function "Remove-DSSBuild"