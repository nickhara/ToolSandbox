using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Helpers;
using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Step 2: Pre-flight connectivity and share accessibility checks.
/// Mirrors the PowerShell script's parallel pre-flight block.
/// </summary>
public class PreflightService
{
    private readonly INetworkChecker _networkChecker;
    private readonly IFileSystem _fileSystem;

    public PreflightService(INetworkChecker networkChecker, IFileSystem fileSystem)
    {
        _networkChecker = networkChecker;
        _fileSystem = fileSystem;
    }

    public sealed record PreflightResult(string Server, bool Reachable, string Message = "");

    /// <summary>
    /// Runs connectivity checks for all servers in parallel.
    /// Returns only the servers that are reachable.
    /// </summary>
    public async Task<List<string>> RunAsync(
        string[] dfsServers,
        string namespaceName,
        SharedCounters counters,
        CancellationToken ct = default)
    {
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteInfo($"[Step 2/5] Running pre-flight connectivity checks ({dfsServers.Length} server(s) in parallel)...");
        var sw = System.Diagnostics.Stopwatch.StartNew();

        var results = new System.Collections.Concurrent.ConcurrentDictionary<string, PreflightResult>();

        await Parallel.ForEachAsync(dfsServers, new ParallelOptions
        {
            MaxDegreeOfParallelism = Math.Max(1, dfsServers.Length),
            CancellationToken = ct
        }, async (server, token) =>
        {
            var result = await CheckServer(server, namespaceName, token);
            results.TryAdd(server, result);
        });

        // Collect results preserving original order
        var reachable = new List<string>();
        foreach (var server in dfsServers)
        {
            if (results.TryGetValue(server, out var result) && result.Reachable)
            {
                reachable.Add(server);
            }
            else
            {
                var msg = results.TryGetValue(server, out var r) ? r.Message : "No result returned";
                ConsoleHelper.WriteWarning($"  Skipping server '{server}': {msg}");
                counters.IncrementErrors();
            }
        }

        sw.Stop();
        if (reachable.Count == 0)
        {
            ConsoleHelper.WriteLine();
            ConsoleHelper.WriteError("No DFS servers are reachable. Please verify network connectivity and try again.");
        }
        else if (reachable.Count < dfsServers.Length)
        {
            ConsoleHelper.WriteLine();
            ConsoleHelper.WriteWarning($"Pre-flight: {reachable.Count} of {dfsServers.Length} server(s) reachable. Proceeding with reachable servers only.");
        }
        else
        {
            ConsoleHelper.WriteLine();
            ConsoleHelper.WriteSuccess($"Pre-flight: All {dfsServers.Length} server(s) reachable.");
        }

        ConsoleHelper.WriteGray($"  Pre-flight completed in {sw.Elapsed:mm\\:ss\\.fff}.");
        return reachable;
    }

    private async Task<PreflightResult> CheckServer(string server, string namespaceName, CancellationToken ct)
    {
        var namespacePath = $@"\\{server}\{namespaceName}";

        // Check 1: Network connectivity
        try
        {
            var pingResult = await _networkChecker.PingAsync(server, 5000, ct);
            if (pingResult.Success)
            {
                ConsoleHelper.WriteSuccess($"  [{server}] Network connectivity OK (Address: {pingResult.Address}, Latency: {pingResult.RoundtripTime}ms)");
            }
            else
            {
                ConsoleHelper.WriteError($"  [{server}] {pingResult.StatusMessage}");
                return new PreflightResult(server, false, pingResult.StatusMessage);
            }
        }
        catch (Exception ex)
        {
            ConsoleHelper.WriteError($"  [{server}] Cannot reach server: {ex.Message}");
            return new PreflightResult(server, false, $"Network unreachable: {ex.Message}");
        }

        // Check 2: DFS namespace share accessibility
        try
        {
            bool accessible = await Task.Run(() => _fileSystem.DirectoryExists(namespacePath), ct);
            if (!accessible)
            {
                ConsoleHelper.WriteError($"  [{server}] Cannot access DFS namespace share '{namespacePath}'");
                return new PreflightResult(server, false, $"Share not accessible: {namespacePath}");
            }
        }
        catch (Exception ex)
        {
            ConsoleHelper.WriteError($"  [{server}] Share access error: {ex.Message}");
            return new PreflightResult(server, false, $"Share access error: {ex.Message}");
        }

        // Check 3: Verify share returns content
        try
        {
            var entries = await Task.Run(() =>
                _fileSystem.EnumerateFileSystemEntries(namespacePath).Take(1).ToList(), ct);
            if (entries.Count == 0)
                ConsoleHelper.WriteWarning($"  [{server}] Share is accessible but appears empty: {namespacePath}");
            else
                ConsoleHelper.WriteSuccess($"  [{server}] Share accessibility verified: {namespacePath}");
        }
        catch (Exception ex)
        {
            ConsoleHelper.WriteError($"  [{server}] Share path exists but content is not accessible: {ex.Message}");
            return new PreflightResult(server, false, $"Share content not accessible: {ex.Message}");
        }

        return new PreflightResult(server, true);
    }
}
