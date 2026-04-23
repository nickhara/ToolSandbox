using DfsTargetCleanup.Models;

namespace DfsTargetCleanup.Tests.Models;

public class SharedCountersTests
{
    [Fact]
    public void AllCounters_StartAtZero()
    {
        var counters = new SharedCounters();
        Assert.Equal(0, counters.LinksChecked);
        Assert.Equal(0, counters.LinksSkipped);
        Assert.Equal(0, counters.TargetsValidated);
        Assert.Equal(0, counters.TargetsRemoved);
        Assert.Equal(0, counters.Errors);
        Assert.Equal(0, counters.LinksRemoved);
        Assert.Equal(0, counters.LinksProcessed);
    }

    [Fact]
    public void IncrementLinksChecked_IncrementsCorrectly()
    {
        var counters = new SharedCounters();
        counters.IncrementLinksChecked();
        counters.IncrementLinksChecked();
        Assert.Equal(2, counters.LinksChecked);
    }

    [Fact]
    public void IncrementErrors_IncrementsCorrectly()
    {
        var counters = new SharedCounters();
        counters.IncrementErrors();
        Assert.Equal(1, counters.Errors);
    }

    [Fact]
    public async Task Counters_AreThreadSafe()
    {
        var counters = new SharedCounters();
        var tasks = Enumerable.Range(0, 100).Select(_ =>
            Task.Run(() =>
            {
                counters.IncrementLinksChecked();
                counters.IncrementTargetsValidated();
                counters.IncrementLinksProcessed();
            }));

        await Task.WhenAll(tasks);

        Assert.Equal(100, counters.LinksChecked);
        Assert.Equal(100, counters.TargetsValidated);
        Assert.Equal(100, counters.LinksProcessed);
    }
}

public class ProgressDataTests
{
    [Fact]
    public void GetProgressKey_FormatsCorrectly()
    {
        var key = ProgressData.GetProgressKey("SERVER1", @"\folder1");
        Assert.Equal(@"SERVER1::\folder1", key);
    }

    [Fact]
    public void CompletedLinks_DefaultsToEmptyDictionary()
    {
        var data = new ProgressData();
        Assert.NotNull(data.CompletedLinks);
        Assert.Empty(data.CompletedLinks);
    }
}
