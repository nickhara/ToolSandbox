using System.Text.Json.Serialization;

namespace DfsTargetCleanup.Models;

/// <summary>
/// JSON-serializable progress checkpoint, compatible with the PowerShell script format.
/// Format: { "completedLinks": { "SERVER::linkName": "timestamp", ... } }
/// </summary>
public sealed class ProgressData
{
    [JsonPropertyName("completedLinks")]
    public Dictionary<string, string> CompletedLinks { get; set; } = new();

    public static string GetProgressKey(string dfsServer, string linkName)
        => $"{dfsServer}::{linkName}";
}
