using System.Text;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;
using Moq;

namespace DfsTargetCleanup.Tests.Services;

public class DfsExportServiceTests
{
    private readonly Mock<IFileSystem> _fileSystem = new();
    private readonly Mock<IProcessRunner> _processRunner = new();
    private readonly Mock<IEnvironmentProvider> _environment = new();

    private DfsExportService CreateService() =>
        new(_fileSystem.Object, _processRunner.Object, _environment.Object);

    // ── GetDfsUtilPath tests ──

    [Fact]
    public void GetDfsUtilPath_WithValidEnvVar_ReturnsEnvPath()
    {
        var path = @"C:\Tools\dfsutil.exe";
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns(path);
        _fileSystem.Setup(f => f.FileExists(path)).Returns(true);

        var svc = CreateService();
        var result = svc.GetDfsUtilPath();

        Assert.Equal(path, result);
    }

    [Fact]
    public void GetDfsUtilPath_WithEnvVarPointingToNonExistentFile_Throws()
    {
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns(@"C:\Missing\dfsutil.exe");
        _fileSystem.Setup(f => f.FileExists(It.IsAny<string>())).Returns(false);

        var svc = CreateService();
        Assert.Throws<InvalidOperationException>(() => svc.GetDfsUtilPath());
    }

    [Fact]
    public void GetDfsUtilPath_WithEnvVarWrongFilename_Throws()
    {
        var path = @"C:\Tools\wrongname.exe";
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns(path);
        _fileSystem.Setup(f => f.FileExists(path)).Returns(true);

        var svc = CreateService();
        Assert.Throws<InvalidOperationException>(() => svc.GetDfsUtilPath());
    }

    [Fact]
    public void GetDfsUtilPath_NoEnvVar_ReturnsSystemRootDefault()
    {
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns((string?)null);
        _environment.Setup(e => e.GetEnvironmentVariable("SystemRoot")).Returns(@"D:\Windows");

        var svc = CreateService();
        var result = svc.GetDfsUtilPath();

        Assert.Equal(@"D:\Windows\system32\dfsutil.exe", result);
    }

    [Fact]
    public void GetDfsUtilPath_NoEnvVarNoSystemRoot_FallsBackToDefault()
    {
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns((string?)null);
        _environment.Setup(e => e.GetEnvironmentVariable("SystemRoot")).Returns((string?)null);

        var svc = CreateService();
        var result = svc.GetDfsUtilPath();

        Assert.Equal(@"C:\Windows\system32\dfsutil.exe", result);
    }

    // ── ExportAllAsync tests ──

    [Fact]
    public async Task ExportAllAsync_SuccessfulExport_ReturnsServerAndPath()
    {
        _environment.Setup(e => e.GetEnvironmentVariable("DFS_UTIL")).Returns((string?)null);
        _environment.Setup(e => e.GetEnvironmentVariable("SystemRoot")).Returns(@"C:\Windows");

        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(0, "Done", ""));

        // After process runs, file should exist with non-zero length
        _fileSystem.Setup(f => f.FileExists(It.Is<string>(s => s.EndsWith(".xml")))).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(It.Is<string>(s => s.EndsWith(".xml")))).Returns(1024);
        _fileSystem.Setup(f => f.ReadAllLines(It.IsAny<string>())).Returns(["<root></root>"]);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1"], "Builds", @"C:\Exports", false, counters);

        Assert.Single(result);
        Assert.Equal("SERVER1", result[0].Server);
        Assert.Contains("Builds.xml", result[0].XmlPath);
    }

    [Fact]
    public async Task ExportAllAsync_ProcessFails_ReturnsEmpty()
    {
        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(1, "", "Error occurred"));

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1"], "Builds", @"C:\Exports", false, counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task ExportAllAsync_ReusesExistingExport_WhenSkipExistingTrue()
    {
        var exportPath = Path.Combine(@"C:\Exports", "SERVER1", "Builds.xml");
        _fileSystem.Setup(f => f.FileExists(exportPath)).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(exportPath)).Returns(500);

        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1"], "Builds", @"C:\Exports", true, counters);

        Assert.Single(result);
        _processRunner.Verify(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task ExportAllAsync_ZeroByteExistingExport_Throws()
    {
        var exportPath = Path.Combine(@"C:\Exports", "SERVER1", "Builds.xml");
        _fileSystem.Setup(f => f.FileExists(exportPath)).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(exportPath)).Returns(0);

        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1"], "Builds", @"C:\Exports", true, counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task ExportAllAsync_MultipleServers_PartialFailure_ReturnsOnlySuccessful()
    {
        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        // SERVER1 succeeds, SERVER2 fails — match on arguments containing server name
        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.Is<string>(a => a.Contains("SERVER1")), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(0, "Done", ""));
        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.Is<string>(a => a.Contains("SERVER2")), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(1, "", "Failed"));

        // Only SERVER1's file exists after export
        _fileSystem.Setup(f => f.FileExists(It.Is<string>(s => s.Contains("SERVER1") && s.EndsWith(".xml")))).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(It.Is<string>(s => s.Contains("SERVER1")))).Returns(1024);
        _fileSystem.Setup(f => f.ReadAllLines(It.IsAny<string>())).Returns(["<root></root>"]);
        _fileSystem.Setup(f => f.FileExists(It.Is<string>(s => s.Contains("SERVER2")))).Returns(false);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1", "SERVER2"], "Builds", @"C:\Exports", false, counters);

        Assert.Single(result);
        Assert.Equal("SERVER1", result[0].Server);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task ExportAllAsync_ProcessSucceeds_ButFileZeroBytes_ReturnsEmpty()
    {
        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(0, "Done", ""));

        // File exists after process but is 0 bytes
        _fileSystem.Setup(f => f.FileExists(It.Is<string>(s => s.EndsWith(".xml")))).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(It.Is<string>(s => s.EndsWith(".xml")))).Returns(0);

        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            ["SERVER1"], "Builds", @"C:\Exports", false, counters);

        Assert.Empty(result);
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task ExportAllAsync_FixesEncoding_AfterSuccessfulExport()
    {
        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        _processRunner.Setup(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new ProcessResult(0, "Done", ""));

        _fileSystem.Setup(f => f.FileExists(It.Is<string>(s => s.EndsWith(".xml")))).Returns(true);
        _fileSystem.Setup(f => f.GetFileLength(It.Is<string>(s => s.EndsWith(".xml")))).Returns(1024);
        _fileSystem.Setup(f => f.ReadAllLines(It.IsAny<string>())).Returns(["<root>data</root>"]);

        var svc = CreateService();
        var counters = new SharedCounters();
        await svc.ExportAllAsync(["SERVER1"], "Builds", @"C:\Exports", false, counters);

        _fileSystem.Verify(f => f.WriteAllLines(
            It.Is<string>(s => s.EndsWith(".xml")),
            It.IsAny<string[]>(),
            Encoding.ASCII), Times.Once);
    }

    [Fact]
    public async Task ExportAllAsync_EmptyServerList_ReturnsEmpty()
    {
        var svc = CreateService();
        var counters = new SharedCounters();
        var result = await svc.ExportAllAsync(
            [], "Builds", @"C:\Exports", false, counters);

        Assert.Empty(result);
        _processRunner.Verify(p => p.RunAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task ExportAllAsync_Cancellation_PropagatesToken()
    {
        _environment.Setup(e => e.GetEnvironmentVariable(It.IsAny<string>())).Returns((string?)null);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var svc = CreateService();
        var counters = new SharedCounters();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            svc.ExportAllAsync(["SERVER1"], "Builds", @"C:\Exports", false, counters, cts.Token));
    }
}
