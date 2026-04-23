using System.Xml.Linq;
using DfsTargetCleanup.Models;
using DfsTargetCleanup.Services;

namespace DfsTargetCleanup.Tests.Services;

public class XmlParserServiceTests
{
    private static string CreateXml(string linksXml) =>
        $"<Root>{linksXml}</Root>";

    private static string CreateTempXml(string xml)
    {
        var path = Path.GetTempFileName();
        File.WriteAllText(path, xml);
        return path;
    }

    [Fact]
    public void ParseSingleExport_WithLinks_ReturnsWorkItems()
    {
        var xml = CreateXml(@"
            <Link Name=""\folder1"">
                <Target Server=""server1"" Folder=""share1"" State=""2"" />
            </Link>
            <Link Name=""\folder2"">
                <Target Server=""server2"" Folder=""share2"" State=""6"" />
            </Link>");
        var path = CreateTempXml(xml);

        try
        {
            var items = XmlParserService.ParseSingleExport("TESTSERVER", path);
            Assert.Equal(2, items.Count);
            Assert.All(items, i => Assert.Equal("TESTSERVER", i.DfsServer));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ParseSingleExport_NoLinks_ReturnsEmpty()
    {
        var xml = CreateXml("");
        var path = CreateTempXml(xml);

        try
        {
            var items = XmlParserService.ParseSingleExport("TESTSERVER", path);
            Assert.Empty(items);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ParseSingleExport_NoRootElement_ReturnsEmpty()
    {
        var path = CreateTempXml("<Something></Something>");

        try
        {
            var items = XmlParserService.ParseSingleExport("TESTSERVER", path);
            Assert.Empty(items);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void GetTargets_ExtractsTargetInfo()
    {
        var linkXml = XElement.Parse(@"
            <Link Name=""\testfolder"">
                <Target Server=""srv1"" Folder=""share1"" State=""2"" />
                <Target Server=""srv2"" Folder=""share2"" State=""6"" />
            </Link>");

        var targets = XmlParserService.GetTargets(linkXml);

        Assert.Equal(2, targets.Count);
        Assert.Equal("srv1", targets[0].Server);
        Assert.Equal("share1", targets[0].Folder);
        Assert.Equal("2", targets[0].State);
        Assert.Equal("srv2", targets[1].Server);
        Assert.Equal("share2", targets[1].Folder);
        Assert.Equal("6", targets[1].State);
    }

    [Fact]
    public void GetTargets_NoTargets_ReturnsEmpty()
    {
        var linkXml = XElement.Parse(@"<Link Name=""\emptyfolder""></Link>");

        var targets = XmlParserService.GetTargets(linkXml);

        Assert.Empty(targets);
    }

    [Fact]
    public void ParseExports_MultipleServers_MergesWorkItems()
    {
        var xml1 = CreateXml(@"<Link Name=""\f1""><Target Server=""s1"" Folder=""sh1"" State=""2"" /></Link>");
        var xml2 = CreateXml(@"<Link Name=""\f2""><Target Server=""s2"" Folder=""sh2"" State=""2"" /></Link>");
        var path1 = CreateTempXml(xml1);
        var path2 = CreateTempXml(xml2);

        try
        {
            var exports = new List<(string Server, string XmlPath)>
            {
                ("SERVER1", path1),
                ("SERVER2", path2)
            };

            var items = XmlParserService.ParseExports(exports, out int serversProcessed);

            Assert.Equal(2, items.Count);
            Assert.Equal(2, serversProcessed);
            Assert.Equal("SERVER1", items[0].DfsServer);
            Assert.Equal("SERVER2", items[1].DfsServer);
        }
        finally
        {
            File.Delete(path1);
            File.Delete(path2);
        }
    }

    [Fact]
    public void DfsWorkItem_LinkName_ExtractsFromAttribute()
    {
        var link = XElement.Parse(@"<Link Name=""\myfolder""></Link>");
        var workItem = new DfsWorkItem { DfsServer = "SRV", Link = link };
        Assert.Equal(@"\myfolder", workItem.LinkName);
    }
}
