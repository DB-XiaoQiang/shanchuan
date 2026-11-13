using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Shanchuan.Core;

public sealed record PreparedUpload(string LocalPath, string RemoteName, string Directory);

public sealed class PreparedTransfer : IDisposable
{
    private readonly string _temporaryRoot;
    private int _disposed;

    internal PreparedTransfer(string temporaryRoot, IReadOnlyList<PreparedUpload> files, int excludedItemCount)
    {
        _temporaryRoot = temporaryRoot;
        Files = files;
        ExcludedItemCount = excludedItemCount;
    }

    public IReadOnlyList<PreparedUpload> Files { get; }
    public int ExcludedItemCount { get; }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        try { if (Directory.Exists(_temporaryRoot)) Directory.Delete(_temporaryRoot, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// <summary>Builds the observed wire format. The final upload is always the commit/control file.</summary>
public static class TransferPreparationService
{
    private static readonly HashSet<string> OfficeExtensions = new(StringComparer.OrdinalIgnoreCase)
        { "doc", "docx", "xls", "xlsx", "ppt", "pptx" };

    private sealed record FileSpec(string Path, string Name, string Directory, bool Folder, bool Marked);

    public static PreparedTransfer Prepare(HistoryEntry entry, AppSettings preferences, long timestamp,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Require(ProtocolValidation.ValidateName(preferences.TextRemoteName));
        Require(ProtocolValidation.ValidateDirectory(preferences.Directory));

        var systemDirectory = preferences.Directory.TrimEnd('/') + "/system_temp";
        var controlName = preferences.TextRemoteName + "." + timestamp;
        var specs = new List<FileSpec>();
        var entities = new HashSet<string>(StringComparer.Ordinal);

        if (entry.Kind != HistoryKind.Text)
        {
            if (entry.Paths.Count == 0) throw new InvalidDataException(L.T("没有可发送的文件。"));
            foreach (var sourcePath in entry.Paths)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var path = Path.GetFullPath(sourcePath);
                var isDirectory = Directory.Exists(path);
                if (!isDirectory && !File.Exists(path)) throw new FileNotFoundException(L.T("要发送的文件或文件夹不存在。"), path);
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException(L.T("不支持直接发送符号链接或联接点，请选择实际文件或文件夹。"));

                var name = isDirectory ? new DirectoryInfo(path).Name : Path.GetFileName(path);
                Require(ProtocolValidation.ValidateName(name));
                if (name.StartsWith("folder:", StringComparison.Ordinal) || name.StartsWith("877D1C:", StringComparison.Ordinal))
                    throw new InvalidDataException(L.F($"协议不能安全表示文件名：{name}"));

                var isOffice = !isDirectory && OfficeExtensions.Contains(Path.GetExtension(name).TrimStart('.'));
                var marked = isOffice && preferences.AutoDecrypt && HasMarker(path);
                var remoteName = isDirectory || isOffice ? name : RemoveExtension(name);
                Require(ProtocolValidation.ValidateName(remoteName));

                string directory;
                if (marked)
                {
                    Require(ProtocolValidation.ValidateDirectory(preferences.DecryptPrefix));
                    var tail = preferences.Directory.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                    directory = preferences.DecryptPrefix.TrimEnd('/') + (tail is null ? "" : "/" + tail);
                }
                else directory = systemDirectory;

                var key = directory + "/" + remoteName;
                if (!entities.Add(key) || key == systemDirectory + "/" + controlName)
                    throw new InvalidDataException(L.F($"多个文件映射为同一远端实体：{remoteName}"));
                specs.Add(new FileSpec(path, name, directory, isDirectory, marked));
            }
        }

        var root = Path.Combine(Path.GetTempPath(), "shanchuan-protocol-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var uploads = new List<PreparedUpload>();
            var manifest = new List<string>();
            var excludedItemCount = 0;
            for (var index = 0; index < specs.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var spec = specs[index];
                string payload;
                string remoteName;
                if (spec.Folder)
                {
                    payload = Path.Combine(root, "archive-" + index);
                    excludedItemCount += DirectoryArchiver.CreateZip(spec.Path, payload,
                        DirectoryExclusions.Parse(preferences.DirectoryExclusionRules),
                        Path.Combine(root, "staging-" + index), cancellationToken);
                    remoteName = spec.Name;
                }
                else
                {
                    payload = Path.Combine(root, "payload-" + index);
                    CopyFile(spec.Path, payload, cancellationToken);
                    remoteName = OfficeExtensions.Contains(Path.GetExtension(spec.Name).TrimStart('.'))
                        ? spec.Name
                        : RemoveExtension(spec.Name);
                }

                var hash = Md5(payload, cancellationToken);
                var manifestName = (spec.Folder ? "folder:" : spec.Marked ? "877D1C:" : "") + spec.Name;
                manifest.Add(manifestName + "|" + hash);
                uploads.Add(new PreparedUpload(payload, remoteName, spec.Directory));
            }

            var content = entry.Kind == HistoryKind.Text
                ? entry.Content
                : "file=" + string.Join(',', manifest) + "\r\n" + timestamp;
            cancellationToken.ThrowIfCancellationRequested();
            var control = Path.Combine(root, "control");
            File.WriteAllBytes(control, new UTF8Encoding(false).GetBytes(content));
            uploads.Add(new PreparedUpload(control, controlName, systemDirectory));
            return new PreparedTransfer(root, uploads, excludedItemCount);
        }
        catch
        {
            try { Directory.Delete(root, true); } catch { }
            throw;
        }
    }

    private static void Require(string? error)
    {
        if (error is not null) throw new InvalidDataException(error);
    }

    private static string RemoveExtension(string name)
    {
        var extension = Path.GetExtension(name);
        return extension.Length == 0 || extension == name ? name : name[..^extension.Length];
    }

    private static bool HasMarker(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Span<byte> marker = stackalloc byte[6];
        return stream.Read(marker) == marker.Length && marker.SequenceEqual("877D1C"u8);
    }

    private static string Md5(string path, CancellationToken cancellationToken)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        var buffer = new byte[1024 * 1024];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            hash.AppendData(buffer, 0, read);
        }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    internal static void CopyFile(string source, string destination, CancellationToken cancellationToken)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        var buffer = new byte[1024 * 1024];
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            output.Write(buffer, 0, read);
        }
    }
}

internal static class DirectoryArchiver
{
    public static int CreateZip(string source, string destination, DirectoryExclusions rules,
        string staging, CancellationToken cancellationToken)
    {
        try
        {
            var excluded = CopyRetainedEntries(source, staging, rules, "", cancellationToken);
            using (var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, false, Encoding.UTF8))
            {
                foreach (var directory in Directory.EnumerateDirectories(staging, "*", SearchOption.AllDirectories))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var relative = Relative(staging, directory) + "/";
                    archive.CreateEntry(relative, CompressionLevel.NoCompression);
                }
                foreach (var file in Directory.EnumerateFiles(staging, "*", SearchOption.AllDirectories))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var entry = archive.CreateEntry(Relative(staging, file), CompressionLevel.Optimal);
                    using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
                    using var output = entry.Open();
                    input.CopyTo(output);
                }
            }
            return excluded;
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
        }
    }

    private static int CopyRetainedEntries(string source, string destination, DirectoryExclusions rules,
        string prefix, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(destination);
        var excluded = 0;
        foreach (var child in Directory.EnumerateFileSystemEntries(source))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var name = Path.GetFileName(child);
            var relative = prefix + name;
            var attributes = File.GetAttributes(child);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException(L.F($"目录中包含符号链接或联接点，已停止打包：{relative}"));
            var isDirectory = (attributes & FileAttributes.Directory) != 0;
            if (rules.Excludes(relative, isDirectory)) { excluded++; continue; }
            var output = Path.Combine(destination, name);
            if (isDirectory)
                excluded += CopyRetainedEntries(child, output, rules, relative + "/", cancellationToken);
            else
                TransferPreparationService.CopyFile(child, output, cancellationToken);
        }
        return excluded;
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
}
