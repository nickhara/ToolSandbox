using System.Collections.Concurrent;
using System.Diagnostics;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Helpers;
using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Step 5: Processes DFS links in parallel — validates targets and removes inactive/unreachable ones.
/// </summary>
public class LinkProcessorService
{
    private readonly IDfsnRemovalService _removalService;
    private readonly IFileSystem _fileSystem;

    public LinkProcessorService(IDfsnRemovalService removalService, IFileSystem fileSystem)
    {
        _removalService = removalService;
        _fileSystem = fileSystem;
    }

    /// <summary>
    /// Processes all work items in parallel, returning removal records.
    /// </summary>
    public async Task<List<RemovalRecord>> ProcessAsync(
        IReadOnlyList<DfsWorkItem> workItems,
        AppOptions options,
        SharedCounters counters,
        ProgressTracker progress,
        CancellationToken ct = default)
    {
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteBanner($" [Step 5/5] Processing {workItems.Count} link(s) (throttle={options.ThrottleLimit})");

        var removalRecords = new ConcurrentBag<RemovalRecord>();
        var processingStart = Stopwatch.StartNew();

        // Background progress monitor
        var progressCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var progressTask = Task.Run(() => RunProgressMonitor(
            counters, workItems.Count, processingStart, progress, progressCts.Token), ct);

        try
        {
            await Parallel.ForEachAsync(workItems, new ParallelOptions
            {
                MaxDegreeOfParallelism = options.ThrottleLimit,
                CancellationToken = ct
            }, async (workItem, token) =>
            {
                await ProcessSingleLink(workItem, options, counters, progress, removalRecords, token);
            });
        }
        finally
        {
            // Stop progress monitor
            await progressCts.CancelAsync();
            try { await progressTask; } catch (OperationCanceledException) { }
            Console.WriteLine(); // Move past progress line
        }

        processingStart.Stop();
        ConsoleHelper.WriteSuccess($"Link processing completed in {processingStart.Elapsed:mm\\:ss\\.fff}.");

        return [.. removalRecords];
    }

    private async Task ProcessSingleLink(
        DfsWorkItem workItem,
        AppOptions options,
        SharedCounters counters,
        ProgressTracker progress,
        ConcurrentBag<RemovalRecord> removalRecords,
        CancellationToken ct)
    {
        var linkName = workItem.LinkName;
        var folderLeafName = linkName.TrimStart('\\').Split('\\')[0];

        // Apply folder filter (wildcard matching)
        if (!MatchesWildcard(folderLeafName, options.FolderFilter))
        {
            counters.IncrementLinksProcessed();
            return;
        }

        var dfsFolderPath = $@"\\{workItem.DfsServer}\{options.Namespace}\{linkName.TrimStart('\\')}";
        var progressKey = ProgressData.GetProgressKey(workItem.DfsServer, linkName);

        // Skip links already completed in a previous run
        if (progress.IsCompleted(progressKey))
        {
            counters.IncrementLinksSkipped();
            counters.IncrementLinksProcessed();
            return;
        }

        counters.IncrementLinksChecked();

        // Validate targets from XML
        var targets = XmlParserService.GetTargets(workItem.Link);
        if (targets.Count == 0)
        {
            progress.MarkCompleted(progressKey);
            counters.IncrementLinksProcessed();
            return;
        }

        var targetsToRemove = new List<(string TargetPath, string Reason)>();

        foreach (var (targetServer, targetFolder, stateValue) in targets)
        {
            counters.IncrementTargetsValidated();
            var targetPath = $@"\\{targetServer}\{targetFolder}";
            string? removeReason = null;

            // Check 1: DFSN state from XML
            var stateLabel = DfsStateHelper.GetStateLabel(stateValue);
            if (!DfsStateHelper.IsOnline(stateLabel))
            {
                removeReason = $"Inactive (State: {stateLabel})";
            }

            // Check 2: UNC path reachability (only if state check passed)
            if (removeReason == null)
            {
                bool reachable = await CheckPathReachable(targetPath, options.ReachabilityTimeoutSeconds, ct);
                if (!reachable)
                {
                    ConsoleHelper.WriteDarkGray($"  Unreachable: {targetPath} (State: {stateLabel}) [Link: {dfsFolderPath}]");
                    removeReason = "Unreachable (path not accessible)";
                }
            }

            if (removeReason != null)
                targetsToRemove.Add((targetPath, removeReason));
        }

        if (targetsToRemove.Count == 0)
        {
            progress.MarkCompleted(progressKey);
            counters.IncrementLinksProcessed();
            return;
        }

        // Remove flagged targets
        ConsoleHelper.WriteWarning($"  {dfsFolderPath} — {targetsToRemove.Count} target(s) to remove");

        foreach (var (targetPath, reason) in targetsToRemove)
        {
            string status;
            if (options.WhatIf)
            {
                ConsoleHelper.WriteInfo($"    [WhatIf] Would remove target: {dfsFolderPath} -> {targetPath} | {reason}");
                status = "WhatIf";
                counters.IncrementTargetsRemoved();
            }
            else
            {
                try
                {
                    _removalService.RemoveFolderTarget(dfsFolderPath, targetPath);
                    ConsoleHelper.WriteSuccess($"    REMOVED: {dfsFolderPath} -> {targetPath}");
                    status = "Removed";
                    counters.IncrementTargetsRemoved();
                }
                catch (Exception ex)
                {
                    ConsoleHelper.WriteWarning($"    FAILED: {dfsFolderPath} -> {targetPath}: {ex.Message}");
                    status = $"Failed: {ex.Message}";
                    counters.IncrementErrors();
                }
            }

            removalRecords.Add(new RemovalRecord
            {
                Timestamp = DateTimeOffset.Now.ToString("o"),
                DfsServer = workItem.DfsServer,
                LinkPath = dfsFolderPath,
                TargetPath = targetPath,
                Reason = reason,
                Status = status
            });
        }

        // NOTE: Empty link removal is intentionally disabled (matches commented-out block in PS script)

        progress.MarkCompleted(progressKey);
        counters.IncrementLinksProcessed();
    }

    private async Task<bool> CheckPathReachable(string uncPath, int timeoutSeconds, CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            return await Task.Run(() => _fileSystem.DirectoryExists(uncPath), cts.Token);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch
        {
            return false;
        }
    }

    private static bool MatchesWildcard(string input, string pattern)
    {
        if (pattern == "*") return true;

        // Simple wildcard match supporting * and ?
        var regexPattern = "^" +
            System.Text.RegularExpressions.Regex.Escape(pattern)
                .Replace("\\*", ".*")
                .Replace("\\?", ".") +
            "$";
        return System.Text.RegularExpressions.Regex.IsMatch(
            input, regexPattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }

    private static void RunProgressMonitor(
        SharedCounters counters,
        int total,
        Stopwatch elapsed,
        ProgressTracker progress,
        CancellationToken ct)
    {
        int lastFlushCount = 0;

        while (!ct.IsCancellationRequested)
        {
            try { Task.Delay(2000, ct).Wait(ct); }
            catch (OperationCanceledException) { break; }

            // Counter reads may be slightly stale due to CPU cache visibility, but this is
            // acceptable for progress display purposes (matches PS script design, line 936).
            int done = counters.LinksProcessed;
            if (total > 0)
            {
                double pct = Math.Min(Math.Round((double)done / total * 100, 1), 100);
                int barWidth = 30;
                int filled = (int)Math.Floor(pct / 100 * barWidth);
                int empty = barWidth - filled;
                var bar = "[" + new string('#', filled) + new string('-', empty) + "]";
                var status = $"  {bar} {pct}% ({done}/{total}) | Checked: {counters.LinksChecked} | Skipped: {counters.LinksSkipped} | Removed: {counters.TargetsRemoved} | Errors: {counters.Errors} | {elapsed.Elapsed:mm\\:ss}  ";
                ConsoleHelper.WriteProgress(status);
            }

            // Periodic progress flush every 30 completed links
            progress.SaveIfNeeded(30, ref lastFlushCount);

            if (done >= total) break;
        }
    }
}
