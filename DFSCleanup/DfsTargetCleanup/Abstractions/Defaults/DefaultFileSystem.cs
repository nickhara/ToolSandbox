using System.Text;

namespace DfsTargetCleanup.Abstractions.Defaults;

/// <summary>
/// Default implementation that delegates to System.IO.
/// </summary>
public sealed class DefaultFileSystem : IFileSystem
{
    public bool FileExists(string path) => File.Exists(path);

    public bool DirectoryExists(string path) => Directory.Exists(path);

    public void CreateDirectory(string path) => Directory.CreateDirectory(path);

    public void DeleteFile(string path) => File.Delete(path);

    /// <summary>
    /// Requires the file to exist; throws FileNotFoundException otherwise.
    /// Callers must check FileExists() first.
    /// </summary>
    public long GetFileLength(string path) => new FileInfo(path).Length;

    public string[] ReadAllLines(string path) => File.ReadAllLines(path);

    public void WriteAllLines(string path, string[] contents, Encoding encoding)
        => File.WriteAllLines(path, contents, encoding);

    public IEnumerable<string> EnumerateFileSystemEntries(string path)
        => Directory.EnumerateFileSystemEntries(path);
}
