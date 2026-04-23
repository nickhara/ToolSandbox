using System.Text;

namespace DfsTargetCleanup.Abstractions;

/// <summary>
/// Abstracts file and directory system operations for testability.
/// </summary>
public interface IFileSystem
{
    bool FileExists(string path);
    bool DirectoryExists(string path);
    void CreateDirectory(string path);
    void DeleteFile(string path);
    long GetFileLength(string path);
    string[] ReadAllLines(string path);
    void WriteAllLines(string path, string[] contents, Encoding encoding);
    IEnumerable<string> EnumerateFileSystemEntries(string path);
}
