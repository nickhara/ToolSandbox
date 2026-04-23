namespace DfsTargetCleanup.Helpers;

/// <summary>
/// Colored console output helpers mirroring PowerShell Write-Host with -ForegroundColor.
/// </summary>
public static class ConsoleHelper
{
    private static readonly object ConsoleLock = new();

    public static void Write(string message, ConsoleColor? color = null)
    {
        lock (ConsoleLock)
        {
            if (color.HasValue)
            {
                var prev = Console.ForegroundColor;
                Console.ForegroundColor = color.Value;
                Console.Write(message);
                Console.ForegroundColor = prev;
            }
            else
            {
                Console.Write(message);
            }
        }
    }

    public static void WriteLine(string message = "", ConsoleColor? color = null)
        => Write(message + Environment.NewLine, color);

    public static void WriteInfo(string message) => WriteLine(message, ConsoleColor.Cyan);
    public static void WriteSuccess(string message) => WriteLine(message, ConsoleColor.Green);
    public static void WriteWarning(string message) => WriteLine(message, ConsoleColor.Yellow);
    public static void WriteError(string message) => WriteLine(message, ConsoleColor.Red);
    public static void WriteGray(string message) => WriteLine(message, ConsoleColor.Gray);
    public static void WriteDarkGray(string message) => WriteLine(message, ConsoleColor.DarkGray);

    public static void WriteBanner(string message)
    {
        const string separator = "═══════════════════════════════════════════════════════════════";
        WriteInfo(separator);
        WriteInfo(message);
        WriteInfo(separator);
    }

    /// <summary>
    /// Overwrites the current console line with a progress status (carriage return trick).
    /// </summary>
    public static void WriteProgress(string message)
    {
        lock (ConsoleLock)
        {
            Console.Write($"\r{message}");
        }
    }
}
