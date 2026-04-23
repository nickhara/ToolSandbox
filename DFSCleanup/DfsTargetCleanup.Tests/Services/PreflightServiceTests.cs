using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;
using Moq;

namespace DfsTargetCleanup.Tests.Services;

public class PreflightServiceTests
{
    private readonly Mock<INetworkChecker> _networkChecker = new();
    private readonly Mock<IFileSystem> _fileSystem = new();

    private PreflightService CreateService() =>
        new(_networkChecker.Object, _fileSystem.Object);

    [Fact]
    public async Task RunAsync_AllServersReachable_ReturnsAll()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);
        _fileSystem.Setup(f => f.EnumerateFileSystemEntries(It.IsAny<string>()))
            .Returns(new[] { @"\\server\share\item" });

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1", "SERVER2"], "Builds", counters);

        Assert.Equal(2, result.Count);
        Assert.Contains("SERVER1", result);
        Assert.Contains("SERVER2", result);
        Assert.Equal(0, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_PingFails_ExcludesServer()
    {
        _networkChecker.Setup(n => n.PingAsync("SERVER1", It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _networkChecker.Setup(n => n.PingAsync("SERVER2", It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(false, null, 0, "Ping failed: TimedOut"));

        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);
        _fileSystem.Setup(f => f.EnumerateFileSystemEntries(It.IsAny<string>()))
            .Returns(new[] { @"\\server\share\item" });

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1", "SERVER2"], "Builds", counters);

        Assert.Single(result);
        Assert.Equal("SERVER1", result[0]);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_PingThrows_ExcludesServer()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new Exception("Network error"));

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1"], "Builds", counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_ShareNotAccessible_ExcludesServer()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1"], "Builds", counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_ShareAccessThrows_ExcludesServer()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Throws(new UnauthorizedAccessException("Access denied"));

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1"], "Builds", counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_ShareEmptyButAccessible_StillReturnsServer()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);
        _fileSystem.Setup(f => f.EnumerateFileSystemEntries(It.IsAny<string>()))
            .Returns(Enumerable.Empty<string>());

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1"], "Builds", counters);

        Assert.Single(result);
        Assert.Equal("SERVER1", result[0]);
    }

    [Fact]
    public async Task RunAsync_ShareContentThrows_ExcludesServer()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);
        _fileSystem.Setup(f => f.EnumerateFileSystemEntries(It.IsAny<string>()))
            .Throws(new IOException("Disk error"));

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync(["SERVER1"], "Builds", counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task RunAsync_NoServers_ReturnsEmpty()
    {
        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.RunAsync([], "Builds", counters);

        Assert.Empty(result);
    }

    [Fact]
    public async Task RunAsync_PreservesOriginalOrder()
    {
        _networkChecker.Setup(n => n.PingAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PingCheckResult(true, "192.0.2.1", 5, null));
        _fileSystem.Setup(f => f.DirectoryExists(It.IsAny<string>())).Returns(true);
        _fileSystem.Setup(f => f.EnumerateFileSystemEntries(It.IsAny<string>()))
            .Returns(new[] { "entry" });

        var svc = CreateService();
        var counters = new SharedCounters();
        var servers = new[] { "ALPHA", "BETA", "GAMMA" };
        var result = await svc.RunAsync(servers, "Builds", counters);

        Assert.Equal(["ALPHA", "BETA", "GAMMA"], result);
    }

    [Fact]
    public async Task RunAsync_Cancellation_PropagatesToken()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var svc = CreateService();
        var counters = new SharedCounters();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            svc.RunAsync(["SERVER1"], "Builds", counters, cts.Token));
    }
}
