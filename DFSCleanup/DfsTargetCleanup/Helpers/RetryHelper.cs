namespace DfsTargetCleanup.Helpers;

/// <summary>
/// Generic retry helper ported from Retry-Helper.psm1.
/// Provides configurable retry logic for operations that may experience transient failures.
/// </summary>
public static class RetryHelper
{
    /// <summary>
    /// Executes an async function with automatic retry logic on failure.
    /// </summary>
    public static async Task<T> ExecuteWithRetryAsync<T>(
        Func<Task<T>> operation,
        string operationDescription,
        int maxRetries = 5,
        int retryDelaySeconds = 2,
        Func<T, bool>? successValidator = null,
        bool suppressWarnings = false,
        CancellationToken cancellationToken = default)
    {
        Exception? lastException = null;

        for (int attempt = 0; attempt <= maxRetries; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                T result = await operation();

                if (successValidator != null && !successValidator(result))
                    throw new InvalidOperationException($"Success validation failed for operation: {operationDescription}");

                return result;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                lastException = ex;

                if (attempt >= maxRetries)
                    throw new InvalidOperationException(
                        $"Failed to execute operation [{operationDescription}] after {maxRetries} attempts: {ex.Message}", ex);

                if (!suppressWarnings)
                    ConsoleHelper.WriteWarning(
                        $"Failed to execute operation [{operationDescription}] (attempt {attempt + 1} of {maxRetries}): {ex.Message}");

                await Task.Delay(TimeSpan.FromSeconds(retryDelaySeconds), cancellationToken);
            }
        }

        throw new InvalidOperationException(
            $"Failed to execute operation [{operationDescription}] after {maxRetries} attempts: {lastException?.Message}",
            lastException);
    }

    /// <summary>
    /// Executes a synchronous function with retry logic.
    /// </summary>
    public static T ExecuteWithRetry<T>(
        Func<T> operation,
        string operationDescription,
        int maxRetries = 5,
        int retryDelaySeconds = 2,
        Func<T, bool>? successValidator = null,
        bool suppressWarnings = false)
    {
        Exception? lastException = null;

        for (int attempt = 0; attempt <= maxRetries; attempt++)
        {
            try
            {
                T result = operation();

                if (successValidator != null && !successValidator(result))
                    throw new InvalidOperationException($"Success validation failed for operation: {operationDescription}");

                return result;
            }
            catch (Exception ex)
            {
                lastException = ex;

                if (attempt >= maxRetries)
                    throw new InvalidOperationException(
                        $"Failed to execute operation [{operationDescription}] after {maxRetries} attempts: {ex.Message}", ex);

                if (!suppressWarnings)
                    ConsoleHelper.WriteWarning(
                        $"Failed to execute operation [{operationDescription}] (attempt {attempt + 1} of {maxRetries}): {ex.Message}");

                Thread.Sleep(TimeSpan.FromSeconds(retryDelaySeconds));
            }
        }

        throw new InvalidOperationException(
            $"Failed to execute operation [{operationDescription}] after {maxRetries} attempts: {lastException?.Message}",
            lastException);
    }

    /// <summary>
    /// Executes a process/command with retry logic, checking exit codes.
    /// </summary>
    public static async Task<int> ExecuteCommandWithRetryAsync(
        string command,
        string arguments,
        string operationDescription,
        int maxRetries = 5,
        int retryDelaySeconds = 2,
        int[]? successExitCodes = null,
        bool suppressWarnings = false,
        CancellationToken cancellationToken = default)
    {
        successExitCodes ??= [0];

        return await ExecuteWithRetryAsync(
            async () =>
            {
                var psi = new System.Diagnostics.ProcessStartInfo(command, arguments)
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var process = System.Diagnostics.Process.Start(psi)
                    ?? throw new InvalidOperationException($"Failed to start process: {command}");

                await process.WaitForExitAsync(cancellationToken);

                if (!successExitCodes.Contains(process.ExitCode))
                {
                    string stderr = await process.StandardError.ReadToEndAsync(cancellationToken);
                    throw new InvalidOperationException(
                        $"Command returned exit code {process.ExitCode}: {stderr}");
                }

                return process.ExitCode;
            },
            operationDescription,
            maxRetries,
            retryDelaySeconds,
            suppressWarnings: suppressWarnings,
            cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Determines if an exception is likely transient and worth retrying.
    /// </summary>
    public static bool IsTransient(Exception ex)
    {
        if (ex is IOException or TimeoutException or System.Net.Sockets.SocketException)
            return true;

        string[] transientMessages =
        [
            "The network path was not found",
            "The process cannot access the file",
            "The remote server returned an error",
            "The operation has timed out",
            "Unable to connect to the remote server"
        ];

        return transientMessages.Any(msg => ex.Message.Contains(msg, StringComparison.OrdinalIgnoreCase));
    }
}
