namespace DfsTargetCleanup.Abstractions;

/// <summary>
/// Abstracts network connectivity checks for testability.
/// </summary>
public interface INetworkChecker
{
    Task<PingCheckResult> PingAsync(string host, int timeoutMs, CancellationToken ct);
}

/// <summary>
/// Result of a ping connectivity check.
/// </summary>
public sealed record PingCheckResult(bool Success, string? Address, long RoundtripTime, string? StatusMessage);
