namespace DfsTargetCleanup.Models;

/// <summary>
/// Thread-safe counters for tracking progress across parallel operations.
/// </summary>
public sealed class SharedCounters
{
    private int _linksChecked;
    private int _linksSkipped;
    private int _targetsValidated;
    private int _targetsRemoved;
    private int _errors;
    private int _linksRemoved;
    private int _linksProcessed;

    public int LinksChecked => _linksChecked;
    public int LinksSkipped => _linksSkipped;
    public int TargetsValidated => _targetsValidated;
    public int TargetsRemoved => _targetsRemoved;
    public int Errors => _errors;
    public int LinksRemoved => _linksRemoved;
    public int LinksProcessed => _linksProcessed;

    public int IncrementLinksChecked() => Interlocked.Increment(ref _linksChecked);
    public int IncrementLinksSkipped() => Interlocked.Increment(ref _linksSkipped);
    public int IncrementTargetsValidated() => Interlocked.Increment(ref _targetsValidated);
    public int IncrementTargetsRemoved() => Interlocked.Increment(ref _targetsRemoved);
    public int IncrementErrors() => Interlocked.Increment(ref _errors);
    public int IncrementLinksRemoved() => Interlocked.Increment(ref _linksRemoved);
    public int IncrementLinksProcessed() => Interlocked.Increment(ref _linksProcessed);
}
