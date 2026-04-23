using DfsTargetCleanup.Helpers;

namespace DfsTargetCleanup.Tests.Helpers;

public class ConsoleHelperTests
{
    [Fact]
    public void WriteLine_WritesToConsole()
    {
        var sw = new StringWriter();
        var originalOut = Console.Out;
        Console.SetOut(sw);

        try
        {
            ConsoleHelper.WriteLine("test message");
            Assert.Contains("test message", sw.ToString());
        }
        finally
        {
            Console.SetOut(originalOut);
        }
    }

    [Fact]
    public void WriteProgress_OverwritesLine()
    {
        var sw = new StringWriter();
        var originalOut = Console.Out;
        Console.SetOut(sw);

        try
        {
            ConsoleHelper.WriteProgress("progress 50%");
            var output = sw.ToString();
            Assert.Contains("\r", output);
            Assert.Contains("progress 50%", output);
        }
        finally
        {
            Console.SetOut(originalOut);
        }
    }
}
