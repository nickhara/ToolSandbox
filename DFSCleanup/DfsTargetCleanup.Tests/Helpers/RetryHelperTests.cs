using DfsTargetCleanup.Helpers;

namespace DfsTargetCleanup.Tests.Helpers;

public class RetryHelperTests
{
    [Fact]
    public async Task ExecuteWithRetryAsync_SucceedsOnFirstAttempt()
    {
        int callCount = 0;
        var result = await RetryHelper.ExecuteWithRetryAsync(
            () => { callCount++; return Task.FromResult(42); },
            "test operation",
            maxRetries: 3,
            retryDelaySeconds: 0);

        Assert.Equal(42, result);
        Assert.Equal(1, callCount);
    }

    [Fact]
    public async Task ExecuteWithRetryAsync_RetriesOnFailure()
    {
        int callCount = 0;
        var result = await RetryHelper.ExecuteWithRetryAsync(
            () =>
            {
                callCount++;
                if (callCount < 3) throw new Exception("transient error");
                return Task.FromResult("success");
            },
            "test operation",
            maxRetries: 5,
            retryDelaySeconds: 0,
            suppressWarnings: true);

        Assert.Equal("success", result);
        Assert.Equal(3, callCount);
    }

    [Fact]
    public async Task ExecuteWithRetryAsync_ThrowsAfterMaxRetries()
    {
        int callCount = 0;
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            RetryHelper.ExecuteWithRetryAsync<int>(
                () =>
                {
                    callCount++;
                    throw new Exception("persistent error");
                },
                "failing operation",
                maxRetries: 2,
                retryDelaySeconds: 0,
                suppressWarnings: true));

        Assert.Contains("failing operation", ex.Message);
        Assert.Contains("2 attempts", ex.Message);
        Assert.Equal(3, callCount); // initial + 2 retries
    }

    [Fact]
    public async Task ExecuteWithRetryAsync_SuccessValidator_RetriesToValidate()
    {
        int callCount = 0;
        var result = await RetryHelper.ExecuteWithRetryAsync(
            () =>
            {
                callCount++;
                return Task.FromResult(callCount);
            },
            "validation test",
            maxRetries: 5,
            retryDelaySeconds: 0,
            successValidator: r => r >= 3,
            suppressWarnings: true);

        Assert.Equal(3, result);
    }

    [Fact]
    public async Task ExecuteWithRetryAsync_RespectsCancel()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(() =>
            RetryHelper.ExecuteWithRetryAsync(
                () => Task.FromResult(1),
                "cancel test",
                cancellationToken: cts.Token));
    }

    [Fact]
    public void ExecuteWithRetry_Sync_SucceedsOnFirstAttempt()
    {
        var result = RetryHelper.ExecuteWithRetry(
            () => "hello",
            "sync test",
            maxRetries: 3,
            retryDelaySeconds: 0);

        Assert.Equal("hello", result);
    }

    [Fact]
    public void ExecuteWithRetry_Sync_RetriesOnFailure()
    {
        int callCount = 0;
        var result = RetryHelper.ExecuteWithRetry(
            () =>
            {
                callCount++;
                if (callCount < 2) throw new IOException("io error");
                return 99;
            },
            "sync retry test",
            maxRetries: 3,
            retryDelaySeconds: 0,
            suppressWarnings: true);

        Assert.Equal(99, result);
        Assert.Equal(2, callCount);
    }

    [Theory]
    [InlineData(typeof(IOException), true)]
    [InlineData(typeof(TimeoutException), true)]
    [InlineData(typeof(ArgumentException), false)]
    [InlineData(typeof(NullReferenceException), false)]
    public void IsTransient_IdentifiesTransientExceptions(Type exType, bool expected)
    {
        var ex = (Exception)Activator.CreateInstance(exType, "test")!;
        Assert.Equal(expected, RetryHelper.IsTransient(ex));
    }

    [Fact]
    public void IsTransient_SocketException_ReturnsTrue()
    {
        var ex = new System.Net.Sockets.SocketException();
        Assert.True(RetryHelper.IsTransient(ex));
    }

    [Fact]
    public void IsTransient_TransientMessage_ReturnsTrue()
    {
        var ex = new Exception("The network path was not found");
        Assert.True(RetryHelper.IsTransient(ex));
    }

    [Fact]
    public void IsTransient_NonTransientMessage_ReturnsFalse()
    {
        var ex = new Exception("Something completely different");
        Assert.False(RetryHelper.IsTransient(ex));
    }
}
