using System.Text.Json;
using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Manages JSON progress files for resumable runs.
/// Format is compatible with the PowerShell script's progress file.
/// </summary>
public class ProgressTracker
{
    private readonly string _progressFilePath;
    private readonly object _lock = new();
    private readonly Dictionary<string, string> _completedLinks;

    public int CompletedCount
    {
        get { lock (_lock) return _completedLinks.Count; }
    }

    public ProgressTracker(string progressFilePath, bool resetProgress)
    {
        _progressFilePath = progressFilePath;

        // Ensure directory exists
        var dir = Path.GetDirectoryName(progressFilePath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        if (resetProgress && File.Exists(progressFilePath))
        {
            File.Delete(progressFilePath);
            Helpers.ConsoleHelper.WriteWarning($"Progress file reset: {progressFilePath}");
        }

        _completedLinks = ReadProgressFile(progressFilePath);
    }

    public bool IsCompleted(string progressKey)
    {
        lock (_lock)
            return _completedLinks.ContainsKey(progressKey);
    }

    public void MarkCompleted(string progressKey)
    {
        lock (_lock)
            _completedLinks[progressKey] = DateTimeOffset.Now.ToString("o");
    }

    public void Save()
    {
        Dictionary<string, string> snapshot;
        lock (_lock)
            snapshot = new Dictionary<string, string>(_completedLinks);

        var data = new ProgressData { CompletedLinks = snapshot };
        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(_progressFilePath, json);
    }

    /// <summary>
    /// Periodic save — called from the progress monitor to flush every N completions.
    /// </summary>
    public void SaveIfNeeded(int flushIntervalCount, ref int lastFlushCount)
    {
        int currentCount = CompletedCount;
        if (currentCount - lastFlushCount >= flushIntervalCount)
        {
            Save();
            lastFlushCount = currentCount;
        }
    }

    internal static Dictionary<string, string> ReadProgressFile(string path)
    {
        if (!File.Exists(path))
            return new Dictionary<string, string>();

        try
        {
            var json = File.ReadAllText(path);
            var data = JsonSerializer.Deserialize<ProgressData>(json);
            return data?.CompletedLinks ?? new Dictionary<string, string>();
        }
        catch (Exception ex)
        {
            Helpers.ConsoleHelper.WriteWarning($"Could not parse progress file '{path}': {ex.Message}. Starting fresh.");
            return new Dictionary<string, string>();
        }
    }
}
