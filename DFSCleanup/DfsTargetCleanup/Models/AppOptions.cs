namespace DfsTargetCleanup.Models;

/// <summary>
/// CLI options mirroring the PowerShell script parameters.
/// </summary>
public sealed class AppOptions
{
    public required string[] DfsServers { get; init; }
    public string Namespace { get; init; } = "Builds";
    public string FolderFilter { get; init; } = "*";
    public int ReachabilityTimeoutSeconds { get; init; } = 30;
    public string? ExportDirectory { get; init; }
    public bool ForceExport { get; init; }
    public string? ProgressFile { get; init; }
    public bool ResetProgress { get; init; }
    public string? LogFilePath { get; init; }
    public int ThrottleLimit { get; init; } = 16;
    public bool WhatIf { get; init; }
}
