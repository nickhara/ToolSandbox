using System.Xml.Linq;

namespace DfsTargetCleanup.Models;

/// <summary>
/// Represents a single DFS link to be processed (server + parsed XML link element).
/// </summary>
public sealed class DfsWorkItem
{
    public required string DfsServer { get; init; }
    public required XElement Link { get; init; }
    public string LinkName => Link.Attribute("Name")?.Value ?? string.Empty;
}
