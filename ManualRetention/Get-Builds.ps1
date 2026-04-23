param (
    [Parameter(Mandatory=$true, HelpMessage="The file server to get the list of builds from.")]
    [string] $FileServer,
    [Parameter(Mandatory=$false, HelpMessage="The filter to use for selecting branches. Defaults to 'git_*' to only select Git branches. Use '*' to select all branches.")]
    [string] $BranchNameFilter = "git_*", # e.g. "Windows*"
    [Parameter(Mandatory=$false, HelpMessage="The share names to look for drops on.")]
    [string[]] $DropShareNames = @("Drops")
)

Import-Module -Name "$PSScriptRoot\Retry-Helper.psm1"

# If the $FileServer parameter is not in the form of a FQDN, append the default domain.
if ($FileServer -notlike "*.*") {
    $DefaultDomain = "yourdomain.example.com"
    Write-Host "Appending the domain name to the file server name since it is not in the form of a FQDN. ($FileServer -> $FileServer.$DefaultDomain)" -ForegroundColor Yellow
    $FileServer = "$FileServer.$DefaultDomain"
}
$NormalizedFileServerName = $FileServer.Split(".")[0].ToLower()
$CacheFilePath = Join-Path -Path $PSScriptRoot -ChildPath "BuildsCache_$NormalizedFileServerName.json"

# If the cache file already exists, prompt the user to confirm if they want to overwrite it since it will be used by the retention script and we don't want to accidentally overwrite it if it already exists.
if (Test-Path -Path $CacheFilePath) {
    $UserInput = Read-Host -Prompt "The cache file already exists at $CacheFilePath. Do you want to overwrite it? (Y/N)"
    if ($UserInput -ne "Y") {
        Write-Host "Exiting without overwriting the cache file." -ForegroundColor Yellow
        exit
    }
}

$DiscoveredBuilds = @()
foreach ($ShareName in $DropShareNames) {
    $DropShare = "\\$FileServer\$ShareName"
    $ActivityName = "Getting list of builds on $DropShare"
    Write-Host "Processing $DropShare" -ForegroundColor Cyan

    Write-Progress `
        -Activity $ActivityName `
        -CurrentOperation "Getting list of branches on $DropShare"

    $Branches = @(Get-ChildItemWithRetry -Path $DropShare -Filter $BranchNameFilter -Directory -ErrorAction Stop)
    $BranchCount = $Branches.Count

    Write-Host "Found $($Branches.Count) branches in $DropShare (filter: $BranchNameFilter). Getting Build information from each branch ..."
    $BranchNumber = 0
    foreach ($Branch in $Branches) {
        $BranchNumber++
        $BranchPath = $Branch.FullName
        $DfsFolderName = $Branch.Name

        Write-Progress `
            -Activity $ActivityName `
            -CurrentOperation "Getting list of builds in $BranchPath" `
            -Status "$BranchNumber of $BranchCount branches scanned." `
            -PercentComplete ([Math]::Round(($BranchNumber / $BranchCount) * 100, 2))

        $Builds = @(Get-ChildItemWithRetry -Path $BranchPath -Directory -ErrorAction Stop)
        Write-Host "Found $($Builds.Count) builds in $BranchPath"
        foreach ($Build in $Builds) {
            $DiscoveredBuilds += [PSCustomObject]@{
                DfsFolderName = $DfsFolderName
                BuildNumber = $Build.Name
                CreationTime = $Build.CreationTime
                State = "NotStarted"
            }
        }
    }

    Write-Progress `
        -Activity $ActivityName `
        -Completed
}

# Save this to the cache for processing by the retention script.
Write-Host "Saving the discovered builds to the cache file at $CacheFilePath for processing by the retention script." -ForegroundColor Cyan
$DiscoveredBuilds | ConvertTo-Json -Depth 5 | Out-File -FilePath $CacheFilePath -Encoding UTF8