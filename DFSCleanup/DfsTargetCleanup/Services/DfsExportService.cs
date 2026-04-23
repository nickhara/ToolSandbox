using System.Diagnostics;
using System.Text;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Helpers;
using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Step 3: Exports DFS namespaces to XML via dfsutil.exe.
/// Mirrors the PowerShell script's parallel export block.
/// </summary>
public class DfsExportService
{
    private readonly IFileSystem _fileSystem;
    private readonly IProcessRunner _processRunner;
    private readonly IEnvironmentProvider _environment;

    public DfsExportService(IFileSystem fileSystem, IProcessRunner processRunner, IEnvironmentProvider environment)
    {
        _fileSystem = fileSystem;
        _processRunner = processRunner;
        _environment = environment;
    }

    public sealed record ExportResult(string Server, string? XmlPath, string? Error);

    /// <summary>
    /// Exports namespaces for all servers in parallel, returns servers that have usable exports.
    /// </summary>
    public async Task<List<(string Server, string XmlPath)>> ExportAllAsync(
        IReadOnlyList<string> servers,
        string namespaceName,
        string exportDirectory,
        bool skipExistingExport,
        SharedCounters counters,
        CancellationToken ct = default)
    {
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteInfo($"[Step 3/5] Exporting namespaces in parallel ({servers.Count} server(s))...");
        var sw = Stopwatch.StartNew();

        var results = new System.Collections.Concurrent.ConcurrentDictionary<string, ExportResult>();

        await Parallel.ForEachAsync(servers, new ParallelOptions
        {
            MaxDegreeOfParallelism = Math.Max(1, servers.Count),
            CancellationToken = ct
        }, async (server, token) =>
        {
            var result = await ExportSingleServer(server, namespaceName, exportDirectory, skipExistingExport, token);
            results.TryAdd(server, result);
        });

        // Collect results preserving order
        var successes = new List<(string Server, string XmlPath)>();
        foreach (var server in servers)
        {
            if (results.TryGetValue(server, out var result) && result.XmlPath != null)
            {
                successes.Add((server, result.XmlPath));
            }
            else
            {
                var msg = results.TryGetValue(server, out var r) ? r.Error : "No result returned";
                ConsoleHelper.WriteWarning($"Failed to export namespace '{namespaceName}' from '{server}': {msg}");
                counters.IncrementErrors();
            }
        }

        sw.Stop();
        if (successes.Count == 0)
        {
            ConsoleHelper.WriteLine();
            ConsoleHelper.WriteError("All namespace exports failed. Nothing to process.");
        }
        else
        {
            ConsoleHelper.WriteSuccess($"Exported {successes.Count} of {servers.Count} namespace(s) successfully.");
            ConsoleHelper.WriteGray($"  Export completed in {sw.Elapsed:mm\\:ss\\.fff}.");
        }

        return successes;
    }

    private async Task<ExportResult> ExportSingleServer(
        string server, string namespaceName, string baseExportDir, bool skipIfExists, CancellationToken ct)
    {
        try
        {
            var dfsUtilPath = GetDfsUtilPath();
            var serverExportDir = Path.Combine(baseExportDir, server);
            var exportPath = Path.Combine(serverExportDir, $"{namespaceName}.xml");

            // Reuse existing export when allowed
            if (skipIfExists && _fileSystem.FileExists(exportPath))
            {
                var length = _fileSystem.GetFileLength(exportPath);
                if (length == 0)
                    throw new InvalidOperationException($"Existing namespace export is 0 bytes: {exportPath}");

                ConsoleHelper.WriteLine($"  [{server}] Reusing existing export: {exportPath}", ConsoleColor.DarkGreen);
                return new ExportResult(server, exportPath, null);
            }

            // Prepare directory
            _fileSystem.CreateDirectory(serverExportDir);
            if (_fileSystem.FileExists(exportPath))
                _fileSystem.DeleteFile(exportPath);

            ConsoleHelper.WriteGray($"  [{server}] Exporting namespace '\\\\{server}\\{namespaceName}' via dfsutil...");

            // Run dfsutil
            var arguments = $"/root:\"\\\\{server}\\{namespaceName}\" /export:\"{exportPath}\"";
            var processResult = await _processRunner.RunAsync(dfsUtilPath, arguments, ct);

            if (processResult.ExitCode != 0)
                throw new InvalidOperationException(
                    $"dfsutil export failed for '\\\\{server}\\{namespaceName}' (exit code {processResult.ExitCode}). Output: {processResult.Stderr} {processResult.Stdout}");

            if (!_fileSystem.FileExists(exportPath) || _fileSystem.GetFileLength(exportPath) == 0)
                throw new InvalidOperationException(
                    $"dfsutil produced a 0-byte export for '\\\\{server}\\{namespaceName}': {exportPath}");

            // Fix encoding for XML parsing (same as PS Set-FileEncoding)
            FixFileEncoding(exportPath);

            ConsoleHelper.WriteSuccess($"  [{server}] Export complete: {exportPath}");
            return new ExportResult(server, exportPath, null);
        }
        catch (Exception ex)
        {
            ConsoleHelper.WriteError($"  [{server}] Export failed: {ex.Message}");
            return new ExportResult(server, null, ex.Message);
        }
    }

    internal string GetDfsUtilPath()
    {
        var envPath = _environment.GetEnvironmentVariable("DFS_UTIL");
        if (!string.IsNullOrEmpty(envPath))
        {
            if (!_fileSystem.FileExists(envPath) ||
                !Path.GetFileName(envPath).Equals("dfsutil.exe", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    $"Invalid dfsutil path: {envPath}. Ensure it points to dfsutil.exe.");
            }
            return envPath;
        }

        var systemRoot = _environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        return Path.Combine(systemRoot, "system32", "dfsutil.exe");
    }

    private void FixFileEncoding(string filePath)
    {
        var lines = _fileSystem.ReadAllLines(filePath);
        _fileSystem.WriteAllLines(filePath, lines, Encoding.ASCII);
    }
}
