namespace DfsTargetCleanup.Abstractions;

/// <summary>
/// Abstracts environment variable access for testability.
/// </summary>
public interface IEnvironmentProvider
{
    string? GetEnvironmentVariable(string name);
}
