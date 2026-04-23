using System.Text.Json;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;

namespace DfsTargetCleanup.Tests.Services;

public class ProgressTrackerTests : IDisposable
{
    private readonly string _tempDir;

    public ProgressTrackerTests()
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
    public void NewTracker_EmptyFile_StartsWithZeroCompleted()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);

        Assert.Equal(0, tracker.CompletedCount);
    }

    [Fact]
    public void MarkCompleted_IncreasesCount()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);

        tracker.MarkCompleted("SERVER1::link1");
        tracker.MarkCompleted("SERVER1::link2");

        Assert.Equal(2, tracker.CompletedCount);
    }

    [Fact]
    public void IsCompleted_ReturnsTrueForCompleted()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);

        tracker.MarkCompleted("SERVER1::link1");

        Assert.True(tracker.IsCompleted("SERVER1::link1"));
        Assert.False(tracker.IsCompleted("SERVER1::link2"));
    }

    [Fact]
    public void Save_And_Reload_PreservesState()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);
        tracker.MarkCompleted("SERVER1::link1");
        tracker.MarkCompleted("SERVER2::link2");
        tracker.Save();

        // Reload
        var tracker2 = new ProgressTracker(path, resetProgress: false);
        Assert.Equal(2, tracker2.CompletedCount);
        Assert.True(tracker2.IsCompleted("SERVER1::link1"));
        Assert.True(tracker2.IsCompleted("SERVER2::link2"));
    }

    [Fact]
    public void ResetProgress_DeletesFile()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);
        tracker.MarkCompleted("SERVER1::link1");
        tracker.Save();

        Assert.True(File.Exists(path));

        var tracker2 = new ProgressTracker(path, resetProgress: true);
        Assert.Equal(0, tracker2.CompletedCount);
    }

    [Fact]
    public void MalformedProgressFile_StartsClean()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        File.WriteAllText(path, "NOT VALID JSON {{{");

        var tracker = new ProgressTracker(path, resetProgress: false);
        Assert.Equal(0, tracker.CompletedCount);
    }

    [Fact]
    public void Save_WritesValidJson()
    {
        var path = Path.Combine(_tempDir, "progress.json");
        var tracker = new ProgressTracker(path, resetProgress: false);
        tracker.MarkCompleted("SRV::link1");
        tracker.Save();

        var json = File.ReadAllText(path);
        var data = JsonSerializer.Deserialize<ProgressData>(json);
        Assert.NotNull(data);
        Assert.Single(data!.CompletedLinks);
        Assert.True(data.CompletedLinks.ContainsKey("SRV::link1"));
    }

    [Fact]
    public void CompatibleWithPowerShellFormat()
    {
        // Simulate a progress file written by the PowerShell script
        var psJson = """
        {
            "completedLinks": {
                "DFSSERVER01::\\folder1": "2026-03-01T10:00:00.0000000+00:00",
                "DFSSERVER01::\\folder2": "2026-03-01T10:05:00.0000000+00:00"
            }
        }
        """;
        var path = Path.Combine(_tempDir, "progress.json");
        File.WriteAllText(path, psJson);

        var tracker = new ProgressTracker(path, resetProgress: false);
        Assert.Equal(2, tracker.CompletedCount);
        Assert.True(tracker.IsCompleted(@"DFSSERVER01::\folder1"));
        Assert.True(tracker.IsCompleted(@"DFSSERVER01::\folder2"));
    }
}
