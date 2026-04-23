using System.Management.Automation;
using DfsTargetCleanup.Abstractions;
using DfsTargetCleanup.Helpers;

namespace DfsTargetCleanup.Services;

/// <summary>
/// Wrapper for DFSN PowerShell cmdlets (Remove-DfsnFolderTarget, Remove-DfsnFolder).
/// Uses System.Management.Automation to invoke PowerShell from C#.
/// </summary>
public class DfsnRemovalService : IDfsnRemovalService
{
    /// <summary>
    /// Removes a DFS folder target. Returns true on success.
    /// </summary>
    public virtual bool RemoveFolderTarget(string dfsFolderPath, string targetPath)
    {
        using var ps = PowerShell.Create();
        ps.AddCommand("Import-Module").AddParameter("Name", "DFSN").AddParameter("ErrorAction", "SilentlyContinue");
        ps.Invoke();
        ps.Commands.Clear();

        ps.AddCommand("Remove-DfsnFolderTarget")
          .AddParameter("Path", dfsFolderPath)
          .AddParameter("TargetPath", targetPath)
          .AddParameter("Force", true)
          .AddParameter("ErrorAction", "Stop");

        ps.Invoke();

        if (ps.HadErrors)
        {
            var errors = string.Join("; ", ps.Streams.Error.Select(e => e.ToString()));
            throw new InvalidOperationException($"Remove-DfsnFolderTarget failed: {errors}");
        }

        return true;
    }

    /// <summary>
    /// Removes an empty DFS folder link. Returns true on success.
    /// </summary>
    public virtual bool RemoveFolder(string dfsFolderPath)
    {
        using var ps = PowerShell.Create();
        ps.AddCommand("Import-Module").AddParameter("Name", "DFSN").AddParameter("ErrorAction", "SilentlyContinue");
        ps.Invoke();
        ps.Commands.Clear();

        ps.AddCommand("Remove-DfsnFolder")
          .AddParameter("Path", dfsFolderPath)
          .AddParameter("Force", true)
          .AddParameter("ErrorAction", "Stop");

        ps.Invoke();

        if (ps.HadErrors)
        {
            var errors = string.Join("; ", ps.Streams.Error.Select(e => e.ToString()));
            throw new InvalidOperationException($"Remove-DfsnFolder failed: {errors}");
        }

        return true;
    }

    /// <summary>
    /// Validates that the DFSN PowerShell module is available.
    /// </summary>
    public virtual bool ValidateModule()
    {
        try
        {
            using var ps = PowerShell.Create();
            ps.AddCommand("Import-Module")
              .AddParameter("Name", "DFSN")
              .AddParameter("ErrorAction", "Stop");
            ps.Invoke();
            return !ps.HadErrors;
        }
        catch
        {
            return false;
        }
    }
}
