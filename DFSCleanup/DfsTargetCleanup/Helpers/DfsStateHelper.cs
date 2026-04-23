namespace DfsTargetCleanup.Helpers;

/// <summary>
/// Maps dfsutil XML numeric target state values to human-readable labels.
/// Mirrors Get-TargetStateLabel from the PowerShell script.
/// </summary>
public static class DfsStateHelper
{
    /// <summary>
    /// Converts a dfsutil XML state value string to a human-readable label.
    /// State bit 1 (0x2) = Active, bit 2 (0x4) = Offline.
    /// State 2 = Online (active, not offline).
    /// </summary>
    public static string GetStateLabel(string? xmlStateValue)
    {
        if (string.IsNullOrWhiteSpace(xmlStateValue))
            return "Unknown";

        if (!int.TryParse(xmlStateValue, out int stateInt))
            return $"Unknown ({xmlStateValue})";

        if (stateInt == 2)
            return "Online";

        bool hasOffline = (stateInt & 0x4) != 0;
        if (hasOffline)
            return "Offline";

        bool hasActive = (stateInt & 0x2) != 0;
        if (!hasActive)
            return "Inactive";

        return $"Unknown ({stateInt})";
    }

    /// <summary>
    /// Returns true if the state label indicates the target is online.
    /// </summary>
    public static bool IsOnline(string stateLabel) => stateLabel == "Online";
}
