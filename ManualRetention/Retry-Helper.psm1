<#
.SYNOPSIS
    Retry helper module for handling transient failures with configurable retry logic.

.DESCRIPTION
    Provides reusable retry patterns for operations that may experience transient failures.
    Supports customizable retry counts, delays, error messages, and success validation.

.NOTES
    Default retry configuration: 5 retries with 2 second delay between attempts.
#>

#region Core Retry Functions

<#
.SYNOPSIS
    Executes a script block with automatic retry logic on failure.

.DESCRIPTION
    Wraps any script block with retry logic, automatically retrying on exceptions.
    Supports custom success validation, error messages, and retry configuration.

.PARAMETER ScriptBlock
    The script block to execute with retry logic.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default is 5.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 2.

.PARAMETER OperationDescription
    Description of the operation being retried, used in warning/error messages.

.PARAMETER SuccessValidator
    Optional script block that validates if the operation succeeded.
    Should return $true for success, $false to trigger retry.
    Receives the result of ScriptBlock as $args[0].

.PARAMETER SuppressWarnings
    If specified, suppresses retry attempt warnings.

.EXAMPLE
    $result = Invoke-WithRetry -ScriptBlock {
        Get-Content "\\server\share\file.txt"
    } -OperationDescription "reading remote file"

.EXAMPLE
    $data = Invoke-WithRetry -ScriptBlock {
        Invoke-RestMethod -Uri $apiUrl
    } -OperationDescription "calling API" -MaxRetries 3 -SuccessValidator {
        param($result)
        return $null -ne $result -and $result.StatusCode -eq 200
    }

.OUTPUTS
    Returns the result of the script block if successful.

.NOTES
    Throws an exception if max retries are exhausted.
#>
function Invoke-WithRetry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ScriptBlock] $ScriptBlock,

        [Parameter(Mandatory = $false)]
        [int] $MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelaySeconds = 2,

        [Parameter(Mandatory = $true)]
        [string] $OperationDescription,

        [Parameter(Mandatory = $false)]
        [ScriptBlock] $SuccessValidator = $null,

        [Parameter(Mandatory = $false)]
        [switch] $SuppressWarnings
    )

    $retryCount = 0
    $lastError = $null

    while ($retryCount -le $MaxRetries)
    {
        try
        {
            $result = & $ScriptBlock

            # If a success validator is provided, use it
            if ($null -ne $SuccessValidator)
            {
                $isSuccess = & $SuccessValidator $result
                if (-not $isSuccess)
                {
                    throw "Success validation failed for operation: $OperationDescription"
                }
            }

            # Success - return the result
            return $result
        }
        catch
        {
            $lastError = $_

            if ($retryCount -ge $MaxRetries)
            {
                throw "Failed to execute operation [$OperationDescription] after $MaxRetries attempts: $($_.Exception.Message)"
            }

            if (-not $SuppressWarnings)
            {
                Write-Warning "Failed to execute operation [$OperationDescription] (attempt $retryCount of $MaxRetries): $($_.Exception.Message)"
            }

            $retryCount++
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    # This should never be reached, but just in case
    throw "Failed to execute operation [$OperationDescription] after $MaxRetries attempts: $($lastError.Exception.Message)"
}

<#
.SYNOPSIS
    Executes an external command with automatic retry logic on failure.

.DESCRIPTION
    Specialized retry function for external commands that validates exit codes.
    Automatically retries if the command returns a non-zero exit code.

.PARAMETER Command
    The command to execute (path to executable or script).

.PARAMETER Arguments
    Array of arguments to pass to the command.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default is 5.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 2.

.PARAMETER OperationDescription
    Description of the command being retried, used in warning/error messages.

.PARAMETER SuccessExitCodes
    Array of exit codes that indicate success. Default is @(0).

.PARAMETER SuppressWarnings
    If specified, suppresses retry attempt warnings.

.EXAMPLE
    Invoke-CommandWithRetry -Command "robocopy.exe" `
        -Arguments @("C:\source", "\\server\destination", "/MIR") `
        -OperationDescription "mirroring files" `
        -SuccessExitCodes @(0, 1)

.OUTPUTS
    Returns the exit code of the successful command execution.

.NOTES
    Throws an exception if max retries are exhausted.
#>
function Invoke-CommandWithRetry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(Mandatory = $false)]
        [string[]] $Arguments = @(),

        [Parameter(Mandatory = $false)]
        [int] $MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelaySeconds = 2,

        [Parameter(Mandatory = $true)]
        [string] $OperationDescription,

        [Parameter(Mandatory = $false)]
        [int[]] $SuccessExitCodes = @(0),

        [Parameter(Mandatory = $false)]
        [switch] $SuppressWarnings
    )

    $retryCount = 0
    $lastExitCode = $null

    while ($retryCount -le $MaxRetries)
    {
        try
        {
            if ($Arguments.Count -gt 0)
            {
                & $Command $Arguments
            }
            else
            {
                & $Command
            }

            $lastExitCode = $LASTEXITCODE

            if ($lastExitCode -in $SuccessExitCodes)
            {
                return $lastExitCode
            }

            throw "Command returned exit code: $lastExitCode"
        }
        catch
        {
            if ($retryCount -ge $MaxRetries)
            {
                throw "Failed to execute command [$Command] for operation [$OperationDescription] after $MaxRetries attempts. Last exit code: $lastExitCode. Error: $($_.Exception.Message)"
            }

            if (-not $SuppressWarnings)
            {
                Write-Warning "Failed to execute command [$Command] for operation [$OperationDescription] (attempt $retryCount of $MaxRetries). Exit code: $lastExitCode. Error: $($_.Exception.Message)"
            }

            $retryCount++
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "Failed to execute command [$Command] for operation [$OperationDescription] after $MaxRetries attempts. Last exit code: $lastExitCode"
}

<#
.SYNOPSIS
    Reads file or network content with automatic retry logic on failure.

.DESCRIPTION
    Specialized retry function for Get-Content operations that may experience transient failures
    when reading from network shares or locked files.

.PARAMETER Path
    The path to the file or resource to read.

.PARAMETER Raw
    If specified, reads the entire file as a single string.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default is 5.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 2.

.PARAMETER SuppressWarnings
    If specified, suppresses retry attempt warnings.

.EXAMPLE
    $content = Get-ContentWithRetry -Path "\\server\share\data.txt" -Raw

.EXAMPLE
    $lines = Get-ContentWithRetry -Path "C:\logs\app.log"

.OUTPUTS
    Returns the content of the file.

.NOTES
    Throws an exception if max retries are exhausted or file does not exist.
#>
function Get-ContentWithRetry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $false)]
        [switch] $Raw,

        [Parameter(Mandatory = $false)]
        [int] $MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelaySeconds = 2,

        [Parameter(Mandatory = $false)]
        [switch] $SuppressWarnings
    )

    $scriptBlock = {
        if ($Raw)
        {
            Get-Content -Path $Path -Raw -ErrorAction Stop
        }
        else
        {
            Get-Content -Path $Path -ErrorAction Stop
        }
    }

    return Invoke-WithRetry -ScriptBlock $scriptBlock `
        -MaxRetries $MaxRetries `
        -RetryDelaySeconds $RetryDelaySeconds `
        -OperationDescription "reading content from [$Path]" `
        -SuppressWarnings:$SuppressWarnings
}

<#
.SYNOPSIS
    Lists directory contents with automatic retry logic on failure.

.DESCRIPTION
    Specialized retry function for Get-ChildItem operations that may experience transient failures
    when enumerating network shares or directories.

.PARAMETER Path
    The path to the directory to enumerate.

.PARAMETER Filter
    Optional filter to apply to the enumeration.

.PARAMETER Recurse
    If specified, enumerates subdirectories recursively.

.PARAMETER Directory
    If specified, returns only directories.

.PARAMETER File
    If specified, returns only files.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default is 5.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 2.

.PARAMETER SuppressWarnings
    If specified, suppresses retry attempt warnings.

.EXAMPLE
    $items = Get-ChildItemWithRetry -Path "\\server\share\folder"

.EXAMPLE
    $dirs = Get-ChildItemWithRetry -Path "\\server\share" -Directory -Recurse

.OUTPUTS
    Returns the directory listing.

.NOTES
    Throws an exception if max retries are exhausted or path does not exist.
#>
function Get-ChildItemWithRetry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $false)]
        [string] $Filter,

        [Parameter(Mandatory = $false)]
        [switch] $Recurse,

        [Parameter(Mandatory = $false)]
        [switch] $Directory,

        [Parameter(Mandatory = $false)]
        [switch] $File,

        [Parameter(Mandatory = $false)]
        [int] $MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelaySeconds = 2,

        [Parameter(Mandatory = $false)]
        [switch] $SuppressWarnings
    )

    $scriptBlock = {
        $params = @{ Path = $Path; ErrorAction = 'Stop' }
        if ($Filter)    { $params['Filter']    = $Filter }
        if ($Recurse)   { $params['Recurse']   = $true }
        if ($Directory) { $params['Directory'] = $true }
        if ($File)      { $params['File']      = $true }

        Get-ChildItem @params
    }

    return Invoke-WithRetry -ScriptBlock $scriptBlock `
        -MaxRetries $MaxRetries `
        -RetryDelaySeconds $RetryDelaySeconds `
        -OperationDescription "listing children of [$Path]" `
        -SuppressWarnings:$SuppressWarnings
}

#endregion

#region Utility Functions

<#
.SYNOPSIS
    Evaluates whether a retry should be attempted based on the exception type.

.DESCRIPTION
    Helper function to determine if a specific exception warrants a retry attempt.
    Useful for implementing smart retry logic that only retries transient failures.

.PARAMETER Exception
    The exception to evaluate.

.PARAMETER TransientExceptionTypes
    Array of exception type names that are considered transient.
    Default includes common transient failure types.

.EXAMPLE
    if (Test-ShouldRetry -Exception $_.Exception) {
        # Retry the operation
    }

.OUTPUTS
    Returns $true if the exception is transient and should be retried, $false otherwise.
#>
function Test-ShouldRetry
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Exception] $Exception,

        [Parameter(Mandatory = $false)]
        [string[]] $TransientExceptionTypes = @(
            'System.IO.IOException',
            'System.Net.WebException',
            'System.TimeoutException',
            'System.Net.Sockets.SocketException',
            'System.UnauthorizedAccessException'
        )
    )

    $exceptionType = $Exception.GetType().FullName

    foreach ($transientType in $TransientExceptionTypes)
    {
        if ($exceptionType -eq $transientType -or $Exception.GetType().IsSubclassOf([Type]$transientType))
        {
            return $true
        }
    }

    # Check for specific error messages that indicate transient issues
    $transientMessages = @(
        'The network path was not found',
        'The process cannot access the file',
        'The remote server returned an error',
        'The operation has timed out',
        'Unable to connect to the remote server'
    )

    foreach ($message in $transientMessages)
    {
        if ($Exception.Message -like "*$message*")
        {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Calculates the delay before the next retry attempt.

.DESCRIPTION
    Helper function to calculate retry delay with support for different backoff strategies.
    Currently supports linear delay, with infrastructure for exponential backoff.

.PARAMETER RetryCount
    The current retry attempt number (0-based).

.PARAMETER BaseDelaySeconds
    The base delay in seconds. Default is 2.

.PARAMETER Strategy
    The backoff strategy to use. Currently only 'Linear' is implemented.
    Future: 'Exponential', 'ExponentialWithJitter'

.EXAMPLE
    $delay = Get-RetryDelay -RetryCount 3 -BaseDelaySeconds 2

.OUTPUTS
    Returns the number of seconds to delay before the next retry.
#>
function Get-RetryDelay
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $true)]
        [int] $RetryCount,

        [Parameter(Mandatory = $false)]
        [int] $BaseDelaySeconds = 2,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Linear', 'Exponential')]
        [string] $Strategy = 'Linear'
    )

    switch ($Strategy)
    {
        'Linear'
        {
            return $BaseDelaySeconds
        }
        'Exponential'
        {
            # Future implementation: exponential backoff
            # return [Math]::Min($BaseDelaySeconds * [Math]::Pow(2, $RetryCount), $MaxDelaySeconds)
            return $BaseDelaySeconds * [Math]::Pow(2, $RetryCount)
        }
        default
        {
            return $BaseDelaySeconds
        }
    }
}

<#
.SYNOPSIS
    Tests if a path exists with retry logic for transient failures.

.DESCRIPTION
    Repeatedly tests if a path exists, retrying on failure until a timeout is reached.
    Useful for waiting for network paths to become available or files to be created.

.PARAMETER Path
    The path to test for existence.

.PARAMETER RetryTimeout
    Maximum time to keep retrying. Default is 60 seconds.

.PARAMETER RetryInterval
    Time to wait between retry attempts. Default is 10 seconds.

.EXAMPLE
    if (Test-PathWithRetries -Path "\\server\share\folder") {
        Write-Host "Path exists"
    }

.EXAMPLE
    Test-PathWithRetries -Path "C:\temp\file.txt" -RetryTimeout (New-TimeSpan -Minutes 5)

.OUTPUTS
    Returns $true if the path exists, $false if timeout is reached.

.NOTES
    Originally from DSSHelpers.psm1, moved to Retry-Helper.psm1 for consolidation.
#>
function Test-PathWithRetries
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $false)]
        [TimeSpan] $RetryTimeout = (New-TimeSpan -Seconds 60),

        [Parameter(Mandatory = $false)]
        [TimeSpan] $RetryInterval = (New-TimeSpan -Seconds 10)
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()

    do {
        if (Test-Path -Path $Path) {
            return $true
        } else {
            Write-Host "$Path did not exist. Checking again in $($RetryInterval.TotalSeconds) seconds in case there were transient errors while checking ..."
            Start-Sleep -Seconds $RetryInterval.TotalSeconds
        }
    } while ($StopWatch.Elapsed -lt $RetryTimeout)

    return $false
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'Invoke-WithRetry',
    'Invoke-CommandWithRetry',
    'Get-ContentWithRetry',
    'Get-ChildItemWithRetry',
    'Test-ShouldRetry',
    'Get-RetryDelay',
    'Test-PathWithRetries'
)
