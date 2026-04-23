using System.CommandLine;
using System.CommandLine.Parsing;
using System.Diagnostics;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Abstractions.Defaults;
using DfsTargetCleanup.Helpers;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;

// ─────────────────────────────────────────────────────────────────────────────
// CLI option definitions (mirrors PowerShell script parameters)
// v2.0.5 API: Option<T>(string name, params string[] aliases)
// ─────────────────────────────────────────────────────────────────────────────

var dfsServersOption = new Option<string[]>("--dfs-servers", "-s") { Required = true, AllowMultipleArgumentsPerToken = true };
dfsServersOption.Description = "One or more DFS server names to process.";

var namespaceOption = new Option<string>("--namespace", "-n") { Description = "DFS namespace to query on each server." };
namespaceOption.DefaultValueFactory = _ => "Builds";

var folderFilterOption = new Option<string>("--folder-filter", "-f") { Description = "Wildcard filter applied to the first path segment of DFS folder link names." };
folderFilterOption.DefaultValueFactory = _ => "*";

var reachabilityTimeoutOption = new Option<int>("--reachability-timeout", "-t") { Description = "Timeout in seconds for UNC path reachability checks." };
reachabilityTimeoutOption.DefaultValueFactory = _ => 30;

var exportDirectoryOption = new Option<string?>("--export-directory", "-e") { Description = "Directory for storing exported DFS namespace XML files." };

var forceExportOption = new Option<bool>("--force-export") { Description = "Force re-export of DFS namespace XMLs even if file already exists." };

var progressFileOption = new Option<string?>("--progress-file") { Description = "Path to a JSON progress file for resumable runs." };

var resetProgressOption = new Option<bool>("--reset-progress") { Description = "Delete the progress file before starting, forcing a full re-scan." };

var logFilePathOption = new Option<string?>("--log-file") { Description = "Transcript log file path." };

var throttleLimitOption = new Option<int>("--throttle-limit", "-p") { Description = "Maximum number of concurrent parallel link processing operations." };
throttleLimitOption.DefaultValueFactory = _ => 16;

var whatIfOption = new Option<bool>("--what-if") { Description = "Preview all removals without making changes." };

var rootCommand = new RootCommand(
    "Validates and removes inactive or unreachable DFS folder targets using dfsutil for fast namespace enumeration, with parallel link processing.");
rootCommand.Add(dfsServersOption);
rootCommand.Add(namespaceOption);
rootCommand.Add(folderFilterOption);
rootCommand.Add(reachabilityTimeoutOption);
rootCommand.Add(exportDirectoryOption);
rootCommand.Add(forceExportOption);
rootCommand.Add(progressFileOption);
rootCommand.Add(resetProgressOption);
rootCommand.Add(logFilePathOption);
rootCommand.Add(throttleLimitOption);
rootCommand.Add(whatIfOption);

rootCommand.SetAction(async (ParseResult parseResult, CancellationToken ct) =>
{
    var options = new AppOptions
    {
        DfsServers = parseResult.GetValue(dfsServersOption)!,
        Namespace = parseResult.GetValue(namespaceOption)!,
        FolderFilter = parseResult.GetValue(folderFilterOption)!,
        ReachabilityTimeoutSeconds = parseResult.GetValue(reachabilityTimeoutOption),
        ExportDirectory = parseResult.GetValue(exportDirectoryOption),
        ForceExport = parseResult.GetValue(forceExportOption),
        ProgressFile = parseResult.GetValue(progressFileOption),
        ResetProgress = parseResult.GetValue(resetProgressOption),
        LogFilePath = parseResult.GetValue(logFilePathOption),
        ThrottleLimit = parseResult.GetValue(throttleLimitOption),
        WhatIf = parseResult.GetValue(whatIfOption)
    };

    await RunAsync(options, ct);
});

var parseResult = rootCommand.Parse(args);
return await parseResult.InvokeAsync();

// ─────────────────────────────────────────────────────────────────────────────
// Main orchestration — mirrors the 5-step pipeline from the PowerShell script
// ─────────────────────────────────────────────────────────────────────────────

static async Task RunAsync(AppOptions options, CancellationToken ct)
{
    var scriptStartTime = Stopwatch.StartNew();
    StreamWriter? logWriter = null;
    string? tempExportDir = null;

    // ── Logging setup ──
    var logFilePath = options.LogFilePath;
    if (string.IsNullOrWhiteSpace(logFilePath))
    {
        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var logDir = Path.Combine(AppContext.BaseDirectory, "logs");
        Directory.CreateDirectory(logDir);
        logFilePath = Path.Combine(logDir, $"DfsTargetCleanup_{timestamp}.log");
    }
    else
    {
        var logDir = Path.GetDirectoryName(logFilePath);
        if (!string.IsNullOrEmpty(logDir))
            Directory.CreateDirectory(logDir);
    }

    // Tee console output to log file
    logWriter = new StreamWriter(logFilePath, append: true) { AutoFlush = true };
    var originalOut = Console.Out;
    Console.SetOut(new TeeTextWriter(originalOut, logWriter));

    ConsoleHelper.WriteGray($"Transcript log: {logFilePath}");

    if (options.WhatIf)
    {
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteWarning(">>> RUNNING IN --what-if MODE — no changes will be made <<<");
        ConsoleHelper.WriteWarning("    Scanning targets and writing removals report only.");
        ConsoleHelper.WriteLine();
    }

    // ── Resolve export directory ──
    bool usingTempExportDir = string.IsNullOrWhiteSpace(options.ExportDirectory);
    string resolvedExportDir;
    if (usingTempExportDir)
    {
        var tempTimestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        resolvedExportDir = Path.Combine(Path.GetTempPath(), $"DfsTargetCleanup_{tempTimestamp}");
        tempExportDir = resolvedExportDir;
    }
    else
    {
        resolvedExportDir = options.ExportDirectory!;
    }
    bool skipExistingExport = !usingTempExportDir && !options.ForceExport;

    // ── Configuration summary ──
    ConsoleHelper.WriteBanner(" DfsTargetCleanup — Configuration");
    ConsoleHelper.WriteGray($"  DFS servers:          {string.Join(", ", options.DfsServers)}");
    ConsoleHelper.WriteGray($"  Namespace:            {options.Namespace}");
    ConsoleHelper.WriteGray($"  Folder filter:        {options.FolderFilter}");
    ConsoleHelper.WriteGray($"  Reachability timeout: {options.ReachabilityTimeoutSeconds}s");
    ConsoleHelper.WriteGray($"  Throttle limit:       {options.ThrottleLimit}");
    ConsoleHelper.WriteGray($"  Export directory:      {(usingTempExportDir ? "(temp)" : options.ExportDirectory)}");
    ConsoleHelper.WriteGray($"  Force export:         {options.ForceExport}");
    ConsoleHelper.WriteGray($"  WhatIf:               {options.WhatIf}");
    ConsoleHelper.WriteGray($"  Started at:           {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
    ConsoleHelper.WriteLine();

    var counters = new SharedCounters();

    // ── Resolve progress file ──
    var progressFilePath = options.ProgressFile;
    if (string.IsNullOrWhiteSpace(progressFilePath))
    {
        var logDir = Path.Combine(AppContext.BaseDirectory, "logs");
        Directory.CreateDirectory(logDir);
        var suffix = options.WhatIf ? "_whatif" : "";
        progressFilePath = Path.Combine(logDir, $"progress_{options.Namespace}{suffix}.json");
    }

    var progress = new ProgressTracker(progressFilePath, options.ResetProgress);
    if (progress.CompletedCount > 0)
        ConsoleHelper.WriteInfo($"Resuming with {progress.CompletedCount} previously completed link(s) from: {progressFilePath}");
    else
        ConsoleHelper.WriteGray($"Progress file: {progressFilePath}");

    // Removals report path
    var removalsReportPath = Path.Combine(
        Path.GetDirectoryName(logFilePath)!,
        $"removals_{DateTime.Now:yyyyMMdd_HHmmss}.csv");

    try
    {
        // ── Step 1: Validate DFSN module ──
        var removalService = new DfsnRemovalService();
        ConsoleHelper.WriteInfo("[Step 1/5] Loading DFSN PowerShell module...");
        if (removalService.ValidateModule())
        {
            ConsoleHelper.WriteSuccess("  DFSN module loaded successfully.");
        }
        else
        {
            ConsoleHelper.WriteError("The DFSN PowerShell module is required but could not be loaded.");
            ConsoleHelper.WriteError("Ensure the DFS Namespaces feature and its PowerShell cmdlets are installed.");
            return;
        }

        // ── Step 2: Pre-flight connectivity checks ──
        var fileSystem = new DefaultFileSystem();
        var networkChecker = new DefaultNetworkChecker();
        var preflightService = new PreflightService(networkChecker, fileSystem);
        var reachableServers = await preflightService.RunAsync(
            options.DfsServers, options.Namespace, counters, ct);
        if (reachableServers.Count == 0) return;

        // ── Step 3: Export namespaces via dfsutil ──
        var processRunner = new DefaultProcessRunner();
        var envProvider = new DefaultEnvironmentProvider();
        var exportService = new DfsExportService(fileSystem, processRunner, envProvider);
        var exports = await exportService.ExportAllAsync(
            reachableServers, options.Namespace, resolvedExportDir, skipExistingExport, counters, ct);
        if (exports.Count == 0) return;

        int totalNamespacesExported = exports.Count;

        // ── Step 4: Parse exported XMLs ──
        var workItems = XmlParserService.ParseExports(exports, out int totalServersProcessed);
        if (workItems.Count == 0) return;

        // ── Step 5: Parallel link processing ──
        var processor = new LinkProcessorService(removalService, fileSystem);
        var removalRecords = await processor.ProcessAsync(workItems, options, counters, progress, ct);

        // ── Post-processing ──
        ConsoleHelper.WriteLine();
        ConsoleHelper.WriteInfo("Saving results...");

        // Save progress
        try
        {
            progress.Save();
            ConsoleHelper.WriteGray($"Progress file saved ({progress.CompletedCount} total completed links).");
        }
        catch (Exception ex)
        {
            ConsoleHelper.WriteWarning($"Failed to save progress file '{progressFilePath}': {ex.Message}");
        }

        // Write removals CSV
        if (removalRecords.Count > 0)
        {
            ReportWriter.WriteCsv(removalsReportPath, removalRecords);
            ConsoleHelper.WriteInfo($"  Removals report:      {removalsReportPath} ({removalRecords.Count} entries)");
        }
        else
        {
            ConsoleHelper.WriteGray("  Removals report:      (none — no targets flagged for removal)");
        }

        // ── Summary ──
        // Derive accurate counts from removal records (matches PS script's defensive null check)
        int totalTargetsRemoved = removalRecords
            .Count(r => r.TargetPath != "(empty link)" && !string.IsNullOrEmpty(r.Status) && !r.Status.StartsWith("Failed:"));
        int totalLinksRemoved = removalRecords
            .Count(r => r.TargetPath == "(empty link)" && !string.IsNullOrEmpty(r.Status) && !r.Status.StartsWith("Failed:"));

        ConsoleHelper.WriteLine();
        if (options.WhatIf)
            ConsoleHelper.WriteBanner(" Summary (WhatIf Mode — no changes were made)");
        else
            ConsoleHelper.WriteBanner(" Summary");

        ConsoleHelper.WriteSuccess($"  Servers processed:    {totalServersProcessed}");
        ConsoleHelper.WriteSuccess($"  Namespaces exported:  {totalNamespacesExported}");
        ConsoleHelper.WriteSuccess($"  Links checked:        {counters.LinksChecked}");
        ConsoleHelper.WriteSuccess($"  Links skipped (resume): {counters.LinksSkipped}");
        ConsoleHelper.WriteSuccess($"  Targets validated:    {counters.TargetsValidated}");

        if (options.WhatIf)
        {
            ConsoleHelper.WriteWarning($"  Targets to remove:    {totalTargetsRemoved}");
            ConsoleHelper.WriteWarning($"  Empty links to remove: {totalLinksRemoved}");
        }
        else
        {
            ConsoleHelper.WriteWarning($"  Targets removed:      {totalTargetsRemoved}");
            ConsoleHelper.WriteWarning($"  Empty links removed:  {totalLinksRemoved}");
        }

        ConsoleHelper.WriteLine($"  Errors:               {counters.Errors}",
            counters.Errors > 0 ? ConsoleColor.Red : ConsoleColor.Green);
        ConsoleHelper.WriteGray($"  Throttle limit:       {options.ThrottleLimit}");
        ConsoleHelper.WriteGray($"  Progress file:        {progressFilePath}");
        scriptStartTime.Stop();
        ConsoleHelper.WriteGray($"  Total elapsed:        {scriptStartTime.Elapsed:hh\\:mm\\:ss\\.fff}");
        ConsoleHelper.WriteGray($"  Completed at:         {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        ConsoleHelper.WriteLine();
    }
    finally
    {
        // Clean up temp export directory
        if (tempExportDir != null && Directory.Exists(tempExportDir))
        {
            try
            {
                Directory.Delete(tempExportDir, true);
                ConsoleHelper.WriteGray($"Cleaned up temp directory: {tempExportDir}");
            }
            catch { /* best effort */ }
        }

        // Restore console and close log
        if (logWriter != null)
        {
            Console.SetOut(originalOut);
            logWriter.Dispose();
        }
    }
}

/// <summary>
/// TextWriter that writes to two underlying writers (console + log file).
/// </summary>
sealed class TeeTextWriter : TextWriter
{
    private readonly TextWriter _primary;
    private readonly TextWriter _secondary;

    public TeeTextWriter(TextWriter primary, TextWriter secondary)
    {
        _primary = primary;
        _secondary = secondary;
    }

    public override System.Text.Encoding Encoding => _primary.Encoding;

    public override void Write(char value)
    {
        _primary.Write(value);
        _secondary.Write(value);
    }

    public override void Write(string? value)
    {
        _primary.Write(value);
        _secondary.Write(value);
    }

    public override void WriteLine(string? value)
    {
        _primary.WriteLine(value);
        _secondary.WriteLine(value);
    }

    public override void Flush()
    {
        _primary.Flush();
        _secondary.Flush();
    }

    public override async Task FlushAsync()
    {
        await _primary.FlushAsync();
        await _secondary.FlushAsync();
    }
}
