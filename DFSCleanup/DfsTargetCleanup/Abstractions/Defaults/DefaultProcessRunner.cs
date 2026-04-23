using System.Diagnostics;

namespace DfsTargetCleanup.Abstractions.Defaults;

/// <summary>
/// Default implementation that runs external processes via System.Diagnostics.Process.
/// </summary>
public sealed class DefaultProcessRunner : IProcessRunner
{
    public async Task<ProcessResult> RunAsync(string fileName, string arguments, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(fileName, arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException($"Failed to start process: {fileName}");

        var stdoutTask = process.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = process.StandardError.ReadToEndAsync(ct);

        await process.WaitForExitAsync(ct);

        return new ProcessResult(process.ExitCode, await stdoutTask, await stderrTask);
    }
}
