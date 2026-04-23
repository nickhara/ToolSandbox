using System.Net.NetworkInformation;

namespace DfsTargetCleanup.Abstractions.Defaults;

/// <summary>
/// Default implementation that uses System.Net.NetworkInformation.Ping.
/// </summary>
public sealed class DefaultNetworkChecker : INetworkChecker
{
    public async Task<PingCheckResult> PingAsync(string host, int timeoutMs, CancellationToken ct)
    {
        using var ping = new Ping();
        var reply = await ping.SendPingAsync(host, TimeSpan.FromMilliseconds(timeoutMs), null, null, ct);

        if (reply.Status == IPStatus.Success)
        {
            return new PingCheckResult(
                true,
                reply.Address?.ToString(),
                reply.RoundtripTime,
                null);
        }

        return new PingCheckResult(false, null, 0, reply.Status.ToString());
    }
}
