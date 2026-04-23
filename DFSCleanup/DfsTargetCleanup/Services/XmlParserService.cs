using System.Xml.Linq;
using DfsTargetCleanup.Helpers;
using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Step 4: Parses exported dfsutil XMLs and builds unified work-item list.
/// </summary>
public static class XmlParserService
{
    /// <summary>
    /// Parses all exported XMLs and returns work items (one per link per server).
    /// </summary>
    public static List<DfsWorkItem> ParseExports(
        IReadOnlyList<(string Server, string XmlPath)> exports,
        out int serversProcessed)
    {
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteInfo("[Step 4/5] Parsing exported XMLs and building work-item list...");

        var workItems = new List<DfsWorkItem>();
        serversProcessed = 0;

        foreach (var (server, xmlPath) in exports)
        {
            var items = ParseSingleExport(server, xmlPath);
            if (items.Count > 0)
            {
                workItems.AddRange(items);
                serversProcessed++;
            }
        }

        if (workItems.Count == 0)
            ConsoleHelper.WriteWarning("No links found across any server. Nothing to process.");

        return workItems;
    }

    /// <summary>
    /// Parses a single dfsutil XML export file and returns work items for its links.
    /// </summary>
    public static List<DfsWorkItem> ParseSingleExport(string server, string xmlPath)
    {
        var doc = XDocument.Load(xmlPath);
        var root = doc.Element("Root");
        if (root == null)
        {
            ConsoleHelper.WriteWarning($"[{server}] No <Root> element found in XML.");
            return [];
        }

        var links = root.Elements("Link").ToList();
        if (links.Count == 0)
        {
            ConsoleHelper.WriteWarning($"[{server}] No links found in namespace.");
            return [];
        }

        ConsoleHelper.WriteSuccess($"[{server}] Found {links.Count} link(s) in namespace.");

        return links.Select(link => new DfsWorkItem
        {
            DfsServer = server,
            Link = link
        }).ToList();
    }

    /// <summary>
    /// Extracts target information from a Link XML element.
    /// Returns (server, folder, state) tuples for each target.
    /// </summary>
    public static List<(string Server, string Folder, string? State)> GetTargets(XElement linkElement)
    {
        return linkElement.Elements("Target")
            .Select(t => (
                Server: t.Attribute("Server")?.Value ?? t.Element("Server")?.Value ?? "",
                Folder: t.Attribute("Folder")?.Value ?? t.Element("Folder")?.Value ?? "",
                State: t.Attribute("State")?.Value ?? t.Element("State")?.Value
            ))
            .ToList();
    }
}
