namespace DfsTargetCleanup.Abstractions;

/// <summary>
/// Abstracts DFS namespace folder target removal operations for testability.
/// </summary>
public interface IDfsnRemovalService
{
    bool RemoveFolderTarget(string dfsFolderPath, string targetPath);
    bool RemoveFolder(string dfsFolderPath);
    bool ValidateModule();
}
