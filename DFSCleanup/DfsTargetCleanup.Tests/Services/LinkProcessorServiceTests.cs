using System.Xml.Linq;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;
using Moq;

namespace DfsTargetCleanup.Tests.Services;

public class LinkProcessorServiceTests
{
    private readonly Mock<IDfsnRemovalService> _removalService = new();
    private readonly Mock<IFileSystem> _fileSystem = new();

    private LinkProcessorService CreateService() =>
        new(_removalService.Object, _fileSystem.Object);

    /// <summary>
    /// Creates a minimal DFS link XElement for testing.
    /// State "2" = Online, State "9" = Offline.
    /// </summary>
    private static DfsWorkItem CreateWorkItem(string server, string linkName, string targetServer, string targetFolder, string state = "2")
    {
        var link = new XElement("Link",
            new XAttribute("Name", linkName),
            new XElement("Target",
                new XAttribute("Server", targetServer),
                new XAttribute("Folder", targetFolder),
                new XAttribute("State", state)));
        return new DfsWorkItem { DfsServer = server, Link = link };
    }

    private static AppOptions DefaultOptions(bool whatIf = false, string folderFilter = "*") => new()
    {
        DfsServers = ["SERVER1"],
        Namespace = "Builds",
        FolderFilter = folderFilter,
        ReachabilityTimeoutSeconds = 5,
        ThrottleLimit = 1,
        WhatIf = whatIf
    };

    private static ProgressTracker CreateProgressTracker()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"LinkProcessorTest_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        return new ProgressTracker(Path.Combine(tempDir, "progress.json"), resetProgress: true);
    }

    [Fact]
    public async Task ProcessAsync_OnlineAndReachable_NoRemovals()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);

        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "2") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();

        var result = await svc.ProcessAsync(workItems, DefaultOptions(), counters, progress);

        Assert.Empty(result);
        _removalService.Verify(r => r.RemoveFolderTarget(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task ProcessAsync_OfflineTarget_CreatesRemovalRecord()
    {
        // State "9" = Offline → should be flagged for removal
        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "9") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true);

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Single(result);
        Assert.Contains("Inactive", result[0].Reason);
        Assert.Equal("WhatIf", result[0].Status);
    }

    [Fact]
    public async Task ProcessAsync_UnreachableTarget_CreatesRemovalRecord()
    {
        // Online state but path unreachable
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "2") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true);

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Single(result);
        Assert.Contains("Unreachable", result[0].Reason);
        Assert.Equal("WhatIf", result[0].Status);
    }

    [Fact]
    public async Task ProcessAsync_WhatIfMode_DoesNotCallRemoval()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "2") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true);

        await svc.ProcessAsync(workItems, options, counters, progress);

        _removalService.Verify(r => r.RemoveFolderTarget(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task ProcessAsync_ActualRemoval_CallsRemovalService()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);
        _removalService.Setup(r => r.RemoveFolderTarget(It.IsAny<string>(), It.IsAny<string>())).Returns(true);

        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "2") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: false);

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Single(result);
        Assert.Equal("Removed", result[0].Status);
        _removalService.Verify(r => r.RemoveFolderTarget(It.IsAny<string>(), It.Is<string>(s => s.Contains("TargetSrv"))), Times.Once);
    }

    [Fact]
    public async Task ProcessAsync_RemovalFails_RecordsFailure()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);
        _removalService.Setup(r => r.RemoveFolderTarget(It.IsAny<string>(), It.IsAny<string>()))
            .Throws(new InvalidOperationException("PS error"));

        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "2") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: false);

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Single(result);
        Assert.StartsWith("Failed:", result[0].Status);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task ProcessAsync_FolderFilterExcludesNonMatching()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        // Link name "Folder1\SubFolder" → first segment "Folder1", filter "Other*" won't match
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "9") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(folderFilter: "Other*");

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Empty(result);
    }

    [Fact]
    public async Task ProcessAsync_FolderFilterWildcard_MatchesCorrectly()
    {
        var svc = CreateService();
        // Filter "Fold*" should match "Folder1"
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "9") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true, folderFilter: "Fold*");

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        Assert.Single(result);
    }

    [Fact]
    public async Task ProcessAsync_SkipsAlreadyCompleted()
    {
        var svc = CreateService();
        var workItem = CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "9");
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();

        // Mark as already completed
        var progressKey = ProgressData.GetProgressKey("SERVER1", @"Folder1\SubFolder");
        progress.MarkCompleted(progressKey);

        var result = await svc.ProcessAsync([workItem], DefaultOptions(), counters, progress);

        Assert.Empty(result);
        Assert.Equal(1, counters.LinksSkipped);
    }

    [Fact]
    public async Task ProcessAsync_NoTargetsInLink_SkipsCleanly()
    {
        var svc = CreateService();
        // Link with no Target child elements
        var link = new XElement("Link", new XAttribute("Name", @"EmptyLink"));
        var workItem = new DfsWorkItem { DfsServer = "SERVER1", Link = link };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();

        var result = await svc.ProcessAsync([workItem], DefaultOptions(), counters, progress);

        Assert.Empty(result);
    }

    [Fact]
    public async Task ProcessAsync_MultipleTargets_ProcessesAll()
    {
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        // Link with 2 targets, both offline
        var link = new XElement("Link",
            new XAttribute("Name", @"Folder1\Sub"),
            new XElement("Target",
                new XAttribute("Server", "Target1"),
                new XAttribute("Folder", "Share1"),
                new XAttribute("State", "9")),
            new XElement("Target",
                new XAttribute("Server", "Target2"),
                new XAttribute("Folder", "Share2"),
                new XAttribute("State", "9")));
        var workItem = new DfsWorkItem { DfsServer = "SERVER1", Link = link };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true);

        var result = await svc.ProcessAsync([workItem], options, counters, progress);

        Assert.Equal(2, result.Count);
        Assert.Equal(2, counters.TargetsRemoved);
    }

    [Fact]
    public async Task ProcessAsync_RecordContainsCorrectFields()
    {
        var svc = CreateService();
        var workItems = new List<DfsWorkItem> { CreateWorkItem("SERVER1", @"Folder1\SubFolder", "TargetSrv", "Share1", "9") };
        var counters = new SharedCounters();
        var progress = CreateProgressTracker();
        var options = DefaultOptions(whatIf: true);

        var result = await svc.ProcessAsync(workItems, options, counters, progress);

        var record = result[0];
        Assert.Equal("SERVER1", record.DfsServer);
        Assert.Contains("Builds", record.LinkPath);
        Assert.Contains("TargetSrv", record.TargetPath);
        Assert.NotNull(record.Timestamp);
        Assert.NotNull(record.Reason);
    }
}
