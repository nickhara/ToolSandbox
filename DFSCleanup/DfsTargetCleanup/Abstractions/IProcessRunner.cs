namespace DfsTargetCleanup.Abstractions;

/// <summary>
/// Abstracts external process execution for testability.
/// </summary>
public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(string fileName, string arguments, CancellationToken ct);
}

/// <summary>
/// Result of an external process execution.
/// </summary>
public sealed record ProcessResult(int ExitCode, string Stdout, string Stderr);
