namespace DfsTargetCleanup.Models;

/// <summary>
/// A single record in the removals CSV report.
/// </summary>
public sealed class RemovalRecord
{
    public string Timestamp { get; init; } = "";
    public string DfsServer { get; init; } = "";
    public string LinkPath { get; init; } = "";
    public string TargetPath { get; init; } = "";
    public string Reason { get; init; } = "";
    public string Status { get; init; } = "";
}
