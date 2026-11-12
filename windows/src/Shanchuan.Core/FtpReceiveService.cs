using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using FluentFTP;
using FluentFTP.Exceptions;

namespace Shanchuan.Core;

public sealed record ReceiveFailure(string ControlName, string Reason);

public sealed record ReceiveBatchResult(
    IReadOnlyList<HistoryEntry> Received,
    IReadOnlyList<ReceiveFailure> Failures,
    IReadOnlyList<string> Warnings,
    int DiscoveredCount);

/// <summary>Receives committed control files on the internal side. No upload or directory creation is performed.</summary>
public sealed class FtpReceiveService(ReceiveStateStore stateStore)
{
    private const int MaxControlBytes = 16 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly HashSet<string> OfficeExtensions = new(StringComparer.OrdinalIgnoreCase)
        { "doc", "docx", "xls", "xlsx", "ppt", "pptx" };

    public async Task<ReceiveBatchResult> ReceivePendingAsync(AppSettings settings, string password,
        CancellationToken cancellationToken = default)
    {
        NetworkPolicy.RequireReceive(settings);
        Validate(settings, password);
        var receiveDirectory = NetworkPolicy.ResolveReceiveDirectory(settings.ReceiveDirectory);
        var systemDirectory = settings.Directory.TrimEnd('/') + "/system_temp";
        var state = stateStore.Load(EndpointKey(settings));
        var received = new List<HistoryEntry>();
        var failures = new List<ReceiveFailure>();
        var warnings = new List<string>();

        using var client = CreateClient(settings, password);
        await client.Connect(cancellationToken).ConfigureAwait(false);
        warnings.AddRange(await CleanupPending(state, client, cancellationToken).ConfigureAwait(false));

        var listing = await client.GetNameListing(systemDirectory, cancellationToken).ConfigureAwait(false);
        var controls = listing.Select(RemoteName).Where(name => IsControl(name, settings.TextRemoteName))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(name => ParseTimestamp(name, settings.TextRemoteName)).ToList();
        foreach (var controlName in controls)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (state.ProcessedControls.Contains(controlName, StringComparer.Ordinal)) continue;
            var controlPath = systemDirectory + "/" + controlName;
            ReceivedItem? item = null;
            try
            {
                item = await ReceiveOne(client, settings, controlPath, receiveDirectory, cancellationToken)
                    .ConfigureAwait(false);
                received.Add(item.Entry);
                state.ProcessedControls.Add(controlName);
                state.PendingCleanup[controlName] = [controlPath, .. item.EntityPaths];
                try
                {
                    stateStore.Save(state);
                }
                catch (Exception error)
                {
                    state.ProcessedControls.RemoveAt(state.ProcessedControls.Count - 1);
                    state.PendingCleanup.Remove(controlName);
                    warnings.Add($"“{item.Entry.Title}”已保存到本地，但接收状态保存失败，远端数据暂未删除：{error.Message}");
                    continue;
                }

                var cleanupWarnings = await CleanupOne(state, client, controlName, cancellationToken).ConfigureAwait(false);
                warnings.AddRange(cleanupWarnings);
                if (cleanupWarnings.Count == 0)
                {
                    try { stateStore.Save(state); }
                    catch (Exception error) { warnings.Add("远端已清理，但本机接收状态未能更新：" + error.Message); }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error)
            {
                // A failed item remains on the server for a later retry. No remote deletion occurs here.
                failures.Add(new ReceiveFailure(controlName, DescribeError(error)));
            }
        }
        return new ReceiveBatchResult(received, failures, warnings, controls.Count);
    }

    private static async Task<ReceivedItem> ReceiveOne(AsyncFtpClient client, AppSettings settings,
        string controlPath, string receiveDirectory, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(receiveDirectory);
        var staging = Path.Combine(receiveDirectory, ".shanchuan-receiving-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            var controlFile = Path.Combine(staging, "control");
            await Download(client, controlFile, controlPath, cancellationToken).ConfigureAwait(false);
            if (new FileInfo(controlFile).Length > MaxControlBytes)
                throw new InvalidDataException("控制文件超过 16 MiB，已停止处理。");
            var content = await File.ReadAllTextAsync(controlFile, StrictUtf8, cancellationToken).ConfigureAwait(false);
            if (!content.StartsWith("file=", StringComparison.Ordinal))
                return new ReceivedItem(new HistoryEntry
                {
                    Kind = HistoryKind.Text,
                    Content = content,
                    Status = "已接收"
                }, []);

            var entities = ParseManifest(content, settings);
            var prepared = new List<PreparedEntity>();
            for (var index = 0; index < entities.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var entity = entities[index];
                var payload = Path.Combine(staging, "payload-" + index.ToString(CultureInfo.InvariantCulture));
                await Download(client, payload, entity.RemotePath, cancellationToken).ConfigureAwait(false);
                var actualHash = await Md5(payload, cancellationToken).ConfigureAwait(false);
                if (!string.Equals(actualHash, entity.ExpectedMd5, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"MD5 校验失败：{entity.LocalName}；预期 {entity.ExpectedMd5.ToLowerInvariant()}，" +
                        $"实际 {actualHash}，下载 {new FileInfo(payload).Length} 字节。远端数据已保留，请检查是否有同名投递覆盖或传输不完整。");
                if (entity.IsFolder)
                {
                    var folder = Path.Combine(staging, "folder-" + index.ToString(CultureInfo.InvariantCulture));
                    await SafeZipExtractor.Extract(payload, folder, cancellationToken).ConfigureAwait(false);
                    prepared.Add(new PreparedEntity(entity.LocalName, folder, true));
                }
                else prepared.Add(new PreparedEntity(entity.LocalName, payload, false));
            }

            var paths = Commit(prepared, receiveDirectory);
            return new ReceivedItem(new HistoryEntry
            {
                Kind = HistoryKind.File,
                Paths = paths,
                Status = "已接收"
            }, entities.Select(entity => entity.RemotePath).ToList());
        }
        finally
        {
            try { Directory.Delete(staging, true); }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static List<RemoteEntity> ParseManifest(string content, AppSettings settings)
    {
        var firstBreak = content.IndexOfAny(['\r', '\n']);
        if (firstBreak < 0) throw new InvalidDataException("文件控制清单缺少时间戳，远端数据已保留。");
        var manifest = content[5..firstBreak];
        var timestamp = content[(firstBreak + 1)..].Trim();
        if (!long.TryParse(timestamp, NumberStyles.None, CultureInfo.InvariantCulture, out _))
            throw new InvalidDataException("文件控制清单的时间戳无效，远端数据已保留。");
        if (manifest.Length == 0) throw new InvalidDataException("文件控制清单为空，远端数据已保留。");

        var entities = new List<RemoteEntity>();
        var remotePaths = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in manifest.Split(','))
        {
            var parts = item.Split('|');
            if (parts.Length != 2 || parts[1].Length != 32 || !parts[1].All(Uri.IsHexDigit))
                throw new InvalidDataException("文件控制清单包含无效的名称或 MD5，远端数据已保留。");
            var isFolder = parts[0].StartsWith("folder:", StringComparison.Ordinal);
            var isMarked = parts[0].StartsWith("877D1C:", StringComparison.Ordinal);
            if (isFolder && isMarked) throw new InvalidDataException("文件控制清单包含冲突的类型标记。");
            var prefixLength = isFolder ? 7 : isMarked ? 7 : 0;
            var localName = parts[0][prefixLength..];
            Require(ProtocolValidation.ValidateName(localName));
            Require(ValidateLocalName(localName));
            var isOffice = OfficeExtensions.Contains(Path.GetExtension(localName).TrimStart('.'));
            var remoteName = isFolder || isOffice ? localName : RemoveExtension(localName);
            Require(ProtocolValidation.ValidateName(remoteName));
            string remoteDirectory;
            if (isMarked)
            {
                Require(ProtocolValidation.ValidateDirectory(settings.DecryptPrefix));
                var tail = settings.Directory.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                remoteDirectory = settings.DecryptPrefix.TrimEnd('/') + (tail is null ? "" : "/" + tail);
            }
            else remoteDirectory = settings.Directory.TrimEnd('/') + "/system_temp";
            var remotePath = remoteDirectory + "/" + remoteName;
            if (!remotePaths.Add(remotePath)) throw new InvalidDataException("文件控制清单包含重复的远端实体。");
            entities.Add(new RemoteEntity(localName, remotePath, parts[1], isFolder));
        }
        return entities;
    }

    private static List<string> Commit(IEnumerable<PreparedEntity> prepared, string receiveDirectory)
    {
        var committed = new List<string>();
        try
        {
            foreach (var item in prepared)
            {
                var destination = UniqueDestination(receiveDirectory, item.LocalName, item.IsFolder);
                if (item.IsFolder) Directory.Move(item.LocalPath, destination);
                else File.Move(item.LocalPath, destination);
                committed.Add(destination);
            }
            return committed;
        }
        catch
        {
            foreach (var path in Enumerable.Reverse(committed))
            {
                try
                {
                    if (Directory.Exists(path)) Directory.Delete(path, true);
                    else if (File.Exists(path)) File.Delete(path);
                }
                catch { }
            }
            throw;
        }
    }

    private static string UniqueDestination(string root, string name, bool isFolder)
    {
        var extension = isFolder ? "" : Path.GetExtension(name);
        var stem = isFolder ? name : name[..^extension.Length];
        for (var index = 0; index < 10_000; index++)
        {
            var suffix = index == 0 ? "" : $" ({index})";
            var candidate = Path.Combine(root, stem + suffix + extension);
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
        throw new IOException($"接收目录中已有过多同名文件：{name}");
    }

    private static string? ValidateLocalName(string name)
    {
        var windowsReserved = new[] { "CON", "PRN", "AUX", "NUL" };
        var stem = name.Split('.')[0];
        var reservedDevice = windowsReserved.Contains(stem, StringComparer.OrdinalIgnoreCase) ||
            (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
             stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && stem[3] is >= '1' and <= '9');
        if (name.EndsWith(' ') || name.EndsWith('.') || name.Any(char.IsControl) ||
            name.IndexOfAny(['<', '>', ':', '"', '/', '\\', '|', '?', '*']) >= 0 || reservedDevice)
            return $"文件名不能安全写入 Windows：{name}";
        return null;
    }

    private static bool IsControl(string name, string prefix) =>
        name.Length > prefix.Length + 1 && name.StartsWith(prefix + ".", StringComparison.Ordinal) &&
        long.TryParse(name[(prefix.Length + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out _);

    private static long ParseTimestamp(string name, string prefix) =>
        long.Parse(name[(prefix.Length + 1)..], NumberStyles.None, CultureInfo.InvariantCulture);

    private static string RemoteName(string path)
    {
        var separator = path.LastIndexOf('/');
        return separator < 0 ? path : path[(separator + 1)..];
    }

    private static string RemoveExtension(string name)
    {
        var extension = Path.GetExtension(name);
        return extension.Length == 0 || extension == name ? name : name[..^extension.Length];
    }

    private static async Task Download(AsyncFtpClient client, string localPath, string remotePath,
        CancellationToken cancellationToken)
    {
        var result = await client.DownloadFile(localPath, remotePath, FtpLocalExists.Overwrite,
            FtpVerify.None, null, cancellationToken).ConfigureAwait(false);
        if (result != FtpStatus.Success) throw new IOException($"FTP 下载未完成：{remotePath}（{result}）。");
    }

    private static async Task<string> Md5(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        var buffer = new byte[1024 * 1024];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
            hash.AppendData(buffer, 0, read);
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private async Task<IReadOnlyList<string>> CleanupPending(ReceiveState state, AsyncFtpClient client,
        CancellationToken cancellationToken)
    {
        var warnings = new List<string>();
        foreach (var control in state.PendingCleanup.Keys.ToList())
        {
            var itemWarnings = await CleanupOne(state, client, control, cancellationToken).ConfigureAwait(false);
            warnings.AddRange(itemWarnings);
        }
        if (warnings.Count == 0 && state.PendingCleanup.Count == 0)
        {
            try { stateStore.Save(state); }
            catch (Exception error) { warnings.Add("接收清理状态保存失败：" + error.Message); }
        }
        return warnings;
    }

    private static async Task<IReadOnlyList<string>> CleanupOne(ReceiveState state, AsyncFtpClient client,
        string controlName, CancellationToken cancellationToken)
    {
        if (!state.PendingCleanup.TryGetValue(controlName, out var paths)) return [];
        var warnings = new List<string>();
        foreach (var path in paths)
        {
            try { await client.DeleteFile(path, cancellationToken).ConfigureAwait(false); }
            catch (FtpCommandException error) when (error.CompletionCode == "550") { }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                warnings.Add($"远端清理失败：{path}；{DescribeError(error)}");
            }
        }
        if (warnings.Count == 0) state.PendingCleanup.Remove(controlName);
        return warnings;
    }

    public static string DescribeError(Exception error)
    {
        var detail = string.IsNullOrWhiteSpace(error.Message) ? "未提供错误消息" : error.Message.Trim();
        if (error is FtpCommandException ftp && !string.IsNullOrWhiteSpace(ftp.CompletionCode))
            detail += "；FTP 响应码 " + ftp.CompletionCode;
        return error.GetType().Name + "：" + detail;
    }

    private static AsyncFtpClient CreateClient(AppSettings settings, string password)
    {
        var client = new AsyncFtpClient(settings.Host.Trim(), settings.Username, password, settings.Port);
        client.Encoding = Encoding.UTF8;
        client.Config.EncryptionMode = FtpEncryptionMode.None;
        client.Config.DataConnectionType = FtpDataConnectionType.AutoPassive;
        client.Config.ConnectTimeout = 15_000;
        client.Config.ReadTimeout = 60_000;
        client.Config.DataConnectionConnectTimeout = 15_000;
        client.Config.DataConnectionReadTimeout = 60_000;
        return client;
    }

    private static string EndpointKey(AppSettings settings) =>
        settings.Host.Trim().ToLowerInvariant() + ":" + settings.Port.ToString(CultureInfo.InvariantCulture) +
        "|" + settings.Username + "|" + settings.Directory.TrimEnd('/');

    private static void Validate(AppSettings settings, string password)
    {
        if (settings.ValidateForTransfer() is { } error) throw new InvalidDataException(error);
        if (password.Any(char.IsControl)) throw new InvalidDataException("FTP 密码不能包含控制字符。");
    }

    private static void Require(string? error)
    {
        if (error is not null) throw new InvalidDataException(error);
    }

    private sealed record RemoteEntity(string LocalName, string RemotePath, string ExpectedMd5, bool IsFolder);
    private sealed record PreparedEntity(string LocalName, string LocalPath, bool IsFolder);
    private sealed record ReceivedItem(HistoryEntry Entry, IReadOnlyList<string> EntityPaths);
}

public sealed class ReceiveState
{
    public string EndpointKey { get; set; } = "";
    public List<string> ProcessedControls { get; set; } = [];
    public Dictionary<string, List<string>> PendingCleanup { get; set; } = new(StringComparer.Ordinal);
}

public sealed class ReceiveStateStore(string root)
{
    private const int ProcessedLimit = 4096;
    private string FilePath => Path.Combine(root, "receive-state.json");

    public ReceiveState Load(string endpointKey)
    {
        if (!File.Exists(FilePath)) return new ReceiveState { EndpointKey = endpointKey };
        var state = JsonFileStore.Read<ReceiveState>(FilePath);
        if (!string.Equals(state.EndpointKey, endpointKey, StringComparison.Ordinal))
            return new ReceiveState { EndpointKey = endpointKey };
        state.ProcessedControls = state.ProcessedControls.Where(name => !string.IsNullOrEmpty(name))
            .Distinct(StringComparer.Ordinal).TakeLast(ProcessedLimit).ToList();
        state.PendingCleanup = state.PendingCleanup.Where(item => item.Value is { Count: > 0 })
            .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        return state;
    }

    public void Save(ReceiveState state)
    {
        state.ProcessedControls = state.ProcessedControls.Distinct(StringComparer.Ordinal)
            .TakeLast(ProcessedLimit).ToList();
        JsonFileStore.Write(FilePath, state);
    }
}

internal static class SafeZipExtractor
{
    public static async Task Extract(string archivePath, string destination, CancellationToken cancellationToken)
    {
        using var archive = ZipFile.OpenRead(archivePath);
        var comparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        var paths = new HashSet<string>(comparer);
        var entries = new List<(ZipArchiveEntry Entry, string RelativePath, bool IsDirectory)>();
        foreach (var entry in archive.Entries)
        {
            var isDirectory = entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\');
            var relative = ValidateEntry(entry.FullName, isDirectory);
            var unixType = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixType == 0xA000) throw new InvalidDataException("ZIP 包含符号链接，已拒绝解压。");
            if (!paths.Add(relative)) throw new InvalidDataException("ZIP 包含重复路径，已拒绝解压。");
            entries.Add((entry, relative, isDirectory));
        }

        Directory.CreateDirectory(destination);
        try
        {
            foreach (var (entry, relative, isDirectory) in entries)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var path = Path.Combine(destination, relative.Replace('/', Path.DirectorySeparatorChar));
                if (isDirectory) { Directory.CreateDirectory(path); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await using var input = entry.Open();
                await using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
            }
        }
        catch
        {
            try { Directory.Delete(destination, true); } catch { }
            throw;
        }
    }

    private static string ValidateEntry(string name, bool isDirectory)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Contains('\0')) throw new InvalidDataException("ZIP 包含空路径。");
        var normalized = name.Replace('\\', '/');
        if (normalized.StartsWith('/')) throw new InvalidDataException("ZIP 包含绝对路径，已拒绝解压。");
        var components = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (components.Length == 0 && !isDirectory) throw new InvalidDataException("ZIP 包含无效文件路径。");
        foreach (var component in components)
        {
            if (component is "." or ".." || component.EndsWith(' ') || component.EndsWith('.') ||
                component.Any(char.IsControl) || component.IndexOfAny(['<', '>', ':', '"', '|', '?', '*']) >= 0)
                throw new InvalidDataException($"ZIP 包含不安全路径：{name}");
        }
        return string.Join('/', components);
    }
}
