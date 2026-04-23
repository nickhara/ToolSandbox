param (
    [Parameter(Mandatory=$true, HelpMessage="One or more DFS branch paths to scan for builds. Example: '\\DFSSERVER01\builds\branches\git_myrepo_main'")]
    [string[]] $BranchPaths
)

Import-Module -Name "$PSScriptRoot\Retry-Helper.psm1"

# Cache for DFS target resolutions so we don't call Get-DfsnFolderTarget multiple times for the same namespace path.
$DfsTargetCache = @{}

function Resolve-DfsTarget {
    param (
        [Parameter(Mandatory=$true)]
        [string] $DfsNamespacePath
    )

    if ($DfsTargetCache.ContainsKey($DfsNamespacePath)) {
        return $DfsTargetCache[$DfsNamespacePath]
    }

    Write-Host "Resolving DFS target for '$DfsNamespacePath' ..." -ForegroundColor Cyan
    try {
        $Targets = @(Get-DfsnFolderTarget -Path $DfsNamespacePath -ErrorAction Stop)
    }
    catch {
        throw "Failed to resolve DFS target for '$DfsNamespacePath'. Ensure the DFSN PowerShell module is installed and the path is a valid DFS namespace folder. Error: $($_.Exception.Message)"
    }

    if ($Targets.Count -eq 0) {
        throw "No DFS targets found for '$DfsNamespacePath'."
    }

    # Prefer online targets; fall back to the first target if none are explicitly online.
    $OnlineTargets = @($Targets | Where-Object { $_.State -eq 'Online' })
    if ($OnlineTargets.Count -gt 0) {
        $SelectedTarget = $OnlineTargets[0]
        if ($OnlineTargets.Count -gt 1) {
            Write-Warning "Multiple online DFS targets found for '$DfsNamespacePath'. Using the first one: $($SelectedTarget.TargetPath)"
        }
    }
    else {
        $SelectedTarget = $Targets[0]
        Write-Warning "No DFS targets in 'Online' state for '$DfsNamespacePath'. Using: $($SelectedTarget.TargetPath)"
    }

    Write-Host "Resolved DFS target: $DfsNamespacePath -> $($SelectedTarget.TargetPath)" -ForegroundColor Green
    $DfsTargetCache[$DfsNamespacePath] = $SelectedTarget.TargetPath
    return $SelectedTarget.TargetPath
}

foreach ($BranchPath in $BranchPaths) {
    $BranchPath = $BranchPath.TrimEnd('\')
    $BranchName = Split-Path -Path $BranchPath -Leaf
    $DfsNamespacePath = Split-Path -Path $BranchPath -Parent

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Processing branch: $BranchName" -ForegroundColor Cyan
    Write-Host "DFS path: $BranchPath" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Resolve the DFS namespace path to the actual file server target.
    $TargetBasePath = Resolve-DfsTarget -DfsNamespacePath $DfsNamespacePath
    $ResolvedBranchPath = Join-Path -Path $TargetBasePath -ChildPath $BranchName
    Write-Host "Resolved branch path: $ResolvedBranchPath" -ForegroundColor Green

    # Determine cache file path and check for overwrite.
    $CacheFilePath = Join-Path -Path $PSScriptRoot -ChildPath "BuildsCache_$BranchName.json"
    if (Test-Path -Path $CacheFilePath) {
        $UserInput = Read-Host -Prompt "The cache file already exists at $CacheFilePath. Do you want to overwrite it? (Y/N)"
        if ($UserInput -ne "Y") {
            Write-Host "Skipping branch '$BranchName' without overwriting the cache file." -ForegroundColor Yellow
            continue
        }
    }

    # Enumerate build folders under the resolved branch path.
    $ActivityName = "Scanning builds for branch $BranchName"
    Write-Progress -Activity $ActivityName -CurrentOperation "Enumerating build folders in $ResolvedBranchPath"

    $Builds = @(Get-ChildItemWithRetry -Path $ResolvedBranchPath -Directory -ErrorAction Stop)
    Write-Host "Found $($Builds.Count) builds in $ResolvedBranchPath" -ForegroundColor Cyan

    $DiscoveredBuilds = @()
    $BuildNumber = 0
    foreach ($Build in $Builds) {
        $BuildNumber++
        Write-Progress `
            -Activity $ActivityName `
            -CurrentOperation "Processing build $($Build.Name)" `
            -Status "$BuildNumber of $($Builds.Count) builds scanned." `
            -PercentComplete ([Math]::Round(($BuildNumber / $Builds.Count) * 100, 2))

        $DiscoveredBuilds += [PSCustomObject]@{
            DfsFolderName = $BranchName
            BuildNumber   = $Build.Name
            CreationTime  = $Build.CreationTime
            State         = "NotStarted"
        }
    }

    Write-Progress -Activity $ActivityName -Completed

    # Save to cache file.
    Write-Host "Saving $($DiscoveredBuilds.Count) builds to $CacheFilePath" -ForegroundColor Cyan
    $DiscoveredBuilds | ConvertTo-Json -Depth 5 | Out-File -FilePath $CacheFilePath -Encoding UTF8
    Write-Host "Cache file written: $CacheFilePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "All branch paths have been processed." -ForegroundColor Green
