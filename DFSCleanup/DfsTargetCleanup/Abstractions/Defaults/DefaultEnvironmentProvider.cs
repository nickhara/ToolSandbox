namespace DfsTargetCleanup.Abstractions.Defaults;

/// <summary>
/// Default implementation that delegates to System.Environment.
/// </summary>
public sealed class DefaultEnvironmentProvider : IEnvironmentProvider
{
    public string? GetEnvironmentVariable(string name)
        => Environment.GetEnvironmentVariable(name);
}
