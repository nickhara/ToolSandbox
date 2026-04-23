using DfsTargetCleanup.Models;
using System.Text;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Writes removal records to a CSV report file.
/// </summary>
public static class ReportWriter
{
    private static readonly string[] CsvHeaders = ["Timestamp", "DfsServer", "LinkPath", "TargetPath", "Reason", "Status"];

    public static void WriteCsv(string path, IEnumerable<RemovalRecord> records)
    {
        var sb = new StringBuilder();
        sb.AppendLine(string.Join(",", CsvHeaders.Select(QuoteCsvField)));

        foreach (var record in records)
        {
            sb.AppendLine(string.Join(",",
                QuoteCsvField(record.Timestamp),
                QuoteCsvField(record.DfsServer),
                QuoteCsvField(record.LinkPath),
                QuoteCsvField(record.TargetPath),
                QuoteCsvField(record.Reason),
                QuoteCsvField(record.Status)));
        }

        // Ensure directory exists
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        File.WriteAllText(path, sb.ToString());
    }

    internal static string QuoteCsvField(string value)
    {
        if (string.IsNullOrEmpty(value))
            return "\"\"";

        // Escape quotes by doubling them, then wrap in quotes
        return $"\"{value.Replace("\"", "\"\"")}\"";
    }
}
