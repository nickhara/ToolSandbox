[CmdletBinding()]
param(
    [string]$ResultsPath = (Join-Path $PSScriptRoot "results"),
    [string]$OutputFile = (Join-Path $ResultsPath "removals_all.csv")
)

$csvFiles = Get-ChildItem -Path $ResultsPath -Filter "removals_*.csv" |
    Where-Object { $_.Name -ne "removals_all.csv" } |
    Sort-Object Name

if ($csvFiles.Count -eq 0) {
    Write-Warning "No removals_*.csv files found in '$ResultsPath'."
    return
}

$allRows = @()
foreach ($file in $csvFiles) {
    $rows = Import-Csv -Path $file.FullName
    Write-Host "  Imported $($rows.Count) rows from $($file.Name)"
    $allRows += $rows
}

$allRows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`nMerged $($csvFiles.Count) files -> $($allRows.Count) total rows"
Write-Host "Output: $OutputFile"
