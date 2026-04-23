using DfsTargetCleanup.Helpers;

namespace DfsTargetCleanup.Tests.Helpers;

public class DfsStateHelperTests
{
    [Theory]
    [InlineData("2", "Online")]
    [InlineData("6", "Offline")]       // 0x2 | 0x4
    [InlineData("4", "Offline")]       // 0x4 only
    [InlineData("0", "Inactive")]      // No active bit
    [InlineData("1", "Inactive")]      // Bit 0 set but not active bit (0x2)
    [InlineData("3", "Unknown (3)")]   // Active + bit 0, no offline
    public void GetStateLabel_ReturnsCorrectLabel(string stateValue, string expected)
    {
        var result = DfsStateHelper.GetStateLabel(stateValue);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData(null, "Unknown")]
    [InlineData("", "Unknown")]
    [InlineData("  ", "Unknown")]
    public void GetStateLabel_NullOrWhitespace_ReturnsUnknown(string? stateValue, string expected)
    {
        var result = DfsStateHelper.GetStateLabel(stateValue);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("abc", "Unknown (abc)")]
    [InlineData("xyz", "Unknown (xyz)")]
    public void GetStateLabel_NonNumeric_ReturnsUnknownWithValue(string stateValue, string expected)
    {
        var result = DfsStateHelper.GetStateLabel(stateValue);
        Assert.Equal(expected, result);
    }

    [Fact]
    public void IsOnline_OnlineLabel_ReturnsTrue()
    {
        Assert.True(DfsStateHelper.IsOnline("Online"));
    }

    [Theory]
    [InlineData("Offline")]
    [InlineData("Inactive")]
    [InlineData("Unknown")]
    [InlineData("Unknown (3)")]
    public void IsOnline_NonOnlineLabel_ReturnsFalse(string label)
    {
        Assert.False(DfsStateHelper.IsOnline(label));
    }
}
