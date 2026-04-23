using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;

namespace DfsTargetCleanup.Tests.Services;

public class ReportWriterTests : IDisposable
{
    private readonly string _tempDir;

    public ReportWriterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"DfsCleanupTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, true);
    }

    [Fact]
    public void WriteCsv_EmptyRecords_WritesHeaderOnly()
    {
        var path = Path.Combine(_tempDir, "report.csv");
        ReportWriter.WriteCsv(path, []);

        var lines = File.ReadAllLines(path);
        Assert.Single(lines);
        Assert.Contains("Timestamp", lines[0]);
        Assert.Contains("DfsServer", lines[0]);
        Assert.Contains("Status", lines[0]);
    }

    [Fact]
    public void WriteCsv_WithRecords_WritesAllData()
    {
        var path = Path.Combine(_tempDir, "report.csv");
        var records = new List<RemovalRecord>
        {
            new()
            {
                Timestamp = "2026-03-01T10:00:00Z",
                DfsServer = "SERVER1",
                LinkPath = @"\\SERVER1\Builds\folder1",
                TargetPath = @"\\target1\share1",
                Reason = "Inactive (State: Offline)",
                Status = "WhatIf"
            },
            new()
            {
                Timestamp = "2026-03-01T10:01:00Z",
                DfsServer = "SERVER1",
                LinkPath = @"\\SERVER1\Builds\folder2",
                TargetPath = @"\\target2\share2",
                Reason = "Unreachable (path not accessible)",
                Status = "Removed"
            }
        };

        ReportWriter.WriteCsv(path, records);

        var lines = File.ReadAllLines(path);
        Assert.Equal(3, lines.Length); // header + 2 records
        Assert.Contains("SERVER1", lines[1]);
        Assert.Contains("Offline", lines[1]);
        Assert.Contains("Removed", lines[2]);
    }

    [Fact]
    public void WriteCsv_EscapesQuotesAndCommas()
    {
        var path = Path.Combine(_tempDir, "report.csv");
        var records = new List<RemovalRecord>
        {
            new()
            {
                Timestamp = "2026-01-01T00:00:00Z",
                DfsServer = "SRV",
                LinkPath = @"\\SRV\NS\link",
                TargetPath = @"\\target\share",
                Reason = "Contains, commas and \"quotes\"",
                Status = "OK"
            }
        };

        ReportWriter.WriteCsv(path, records);

        var content = File.ReadAllText(path);
        // Quotes should be doubled inside the field
        Assert.Contains("\"\"quotes\"\"", content);
    }

    [Fact]
    public void WriteCsv_CreatesDirectory()
    {
        var nestedDir = Path.Combine(_tempDir, "sub", "dir");
        var path = Path.Combine(nestedDir, "report.csv");

        ReportWriter.WriteCsv(path, []);

        Assert.True(File.Exists(path));
    }

    [Fact]
    public void QuoteCsvField_EmptyString_ReturnsQuoted()
    {
        Assert.Equal("\"\"", ReportWriter.QuoteCsvField(""));
    }

    [Fact]
    public void QuoteCsvField_NormalString_WrapsInQuotes()
    {
        Assert.Equal("\"hello\"", ReportWriter.QuoteCsvField("hello"));
    }

    [Fact]
    public void QuoteCsvField_StringWithQuotes_DoublesQuotes()
    {
        Assert.Equal("\"say \"\"hi\"\"\"", ReportWriter.QuoteCsvField("say \"hi\""));
    }
}
