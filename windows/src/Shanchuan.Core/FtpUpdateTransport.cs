using FluentFTP;
using FluentFTP.Exceptions;

namespace Shanchuan.Core;

public interface IUpdateRelay
{
    Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token);
    Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion,
        AppSettings settings, string password, CancellationToken token);
}

/// <summary>Dedicated update namespace: internal peers never delete shared publisher files.</summary>
public sealed class FtpUpdateTransport(Func<bool>? isBusy = null, SemaphoreSlim? transferGate = null) : IUpdateRelay
{
    private readonly SemaphoreSlim _gate = transferGate ?? new SemaphoreSlim(1, 1);
    private readonly Func<bool> _isBusy = isBusy ?? (() => false);
    public static string UpdateRoot(AppSettings settings) => settings.Directory.TrimEnd('/') + "/shanchuan_updates/stable/win-x64";

    public async Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token)
    {
        NetworkPolicy.RequireUpload(settings);
        Validate(settings, password);
        var batch = UpdateRoot(settings) + "/" + candidate.Manifest.Version + "/" + Guid.NewGuid().ToString("N");
        // Never overwrite a committed batch. Retries use a new batch; incomplete directories are ignored.
        foreach (var asset in candidate.Manifest.WindowsUpdateAssets)
        {
            var file = Path.Combine(candidate.CacheDirectory, asset.Name);
            await UpdateManifestVerifier.VerifyAssetAsync(file, asset, token);
            await UploadAsync(file, batch + "/" + asset.Name, settings, password, token);
        }
        await UploadAsync(Path.Combine(candidate.CacheDirectory, UpdateManifestVerifier.ManifestName), batch + "/" + UpdateManifestVerifier.ManifestName, settings, password, token);
        await UploadAsync(Path.Combine(candidate.CacheDirectory, UpdateManifestVerifier.SignatureName), batch + "/" + UpdateManifestVerifier.SignatureName, settings, password, token);
    }

    public async Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion,
        AppSettings settings, string password, CancellationToken token)
    {
        NetworkPolicy.RequireReceive(settings);
        Validate(settings, password);
        var root = UpdateRoot(settings);
        var versions = (await ListAsync(root, settings, password, token))
            .Where(UpdateManifestVerifier.IsVersion).Where(x => UpdateManifestVerifier.CompareVersions(x, minimumVersion) > 0)
            .OrderByDescending(x => Version.Parse(x)).Take(32).ToArray();
        Exception? lastFailure = null;
        foreach (var version in versions)
        {
            var versionPath = root + "/" + version;
            foreach (var batch in (await ListAsync(versionPath, settings, password, token)).Where(x => Guid.TryParseExact(x, "N", out _)))
            {
                var directory = versionPath + "/" + batch;
                var files = await ListAsync(directory, settings, password, token);
                if (!files.Contains(UpdateManifestVerifier.SignatureName) || !files.Contains(UpdateManifestVerifier.ManifestName)) continue;
                try
                {
                    var manifestBytes = await DownloadBytesAsync(directory + "/" + UpdateManifestVerifier.ManifestName,
                        UpdateManifestVerifier.MaxManifestBytes, settings, password, token);
                    var signature = await DownloadBytesAsync(directory + "/" + UpdateManifestVerifier.SignatureName, 256, settings, password, token);
                    var manifest = verifier.Verify(manifestBytes, signature);
                    if (manifest.Version != version) throw L.WithDescription(new InvalidDataException(L.T("更新目录版本与签名清单不一致。")), L.M("更新目录版本与签名清单不一致。"));
                    var verified = await cache.ImportAsync(manifestBytes, signature, (asset, destination, ct) =>
                        DownloadFileAsync(directory + "/" + asset.Name, destination, asset.Size, settings, password, ct), token);
                    return verified;
                }
                catch (Exception error) when (error is IOException or System.Security.Cryptography.CryptographicException or System.Text.Json.JsonException or FtpException or KeyNotFoundException or InvalidOperationException)
                { lastFailure = error; }
            }
        }
        if (lastFailure is not null) throw L.WithDescription(new InvalidDataException(L.T("内网更新包暂不可用，未安装任何内容。"), lastFailure), L.M("内网更新包暂不可用，未安装任何内容。"));
        return null;
    }

    private async Task<string[]> ListAsync(string remote, AppSettings settings, string password, CancellationToken token)
    {
        await EnterAsync(token);
        try
        {
            using var client = CreateClient(settings, password);
            await client.Connect(token);
            try
            {
                var list = await client.GetNameListing(remote, token);
                if (list.Length > 4096) throw L.WithDescription(new InvalidDataException(L.T("更新目录条目过多。")), L.M("更新目录条目过多。"));
                return list.Select(value => ChildName(value, remote)).Where(x => x is not null).Cast<string>().Distinct(StringComparer.Ordinal).ToArray();
            }
            catch (FtpCommandException error) when (error.CompletionCode == "550") { return []; }
        }
        finally { _gate.Release(); }
    }

    private async Task UploadAsync(string file, string remote, AppSettings settings, string password, CancellationToken token)
    {
        await EnterAsync(token);
        try
        {
            using var client = CreateClient(settings, password);
            await client.Connect(token);
            var status = await client.UploadFile(file, remote, FtpRemoteExists.NoCheck, true, FtpVerify.None, null, token);
            if (status != FtpStatus.Success) throw L.WithDescription(new IOException(L.T("更新包 FTP 上传未完成。")), L.M("更新包 FTP 上传未完成。"));
        }
        finally { _gate.Release(); }
    }

    private async Task DownloadFileAsync(string remote, string destination, long maximum, AppSettings settings, string password, CancellationToken token)
    {
        await EnterAsync(token);
        try
        {
            using var client = CreateClient(settings, password);
            await client.Connect(token);
            await using (var input = await client.OpenRead(remote, FtpDataType.Binary, 0, -1, token))
            await using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true))
                await GitHubUpdateSource.CopyBoundedAsync(input, output, maximum, token);
            // Raw FTP data streams require consuming the transfer-complete reply.
            var reply = await client.GetReply(token);
            if (!reply.Success) throw L.WithDescription(new IOException(L.T("FTP 更新下载未完成。")), L.M("FTP 更新下载未完成。"));
        }
        finally { _gate.Release(); }
    }

    private async Task<byte[]> DownloadBytesAsync(string remote, int maximum, AppSettings settings, string password, CancellationToken token)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "shanchuan-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            await DownloadFileAsync(remote, temporary, maximum, settings, password, token);
            return await UpdateCache.ReadLimitedAsync(temporary, maximum, token);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private async Task EnterAsync(CancellationToken token)
    {
        while (true)
        {
            while (_isBusy()) await Task.Delay(100, token);
            await _gate.WaitAsync(token);
            if (!_isBusy()) return;
            _gate.Release();
        }
    }

    private static string? ChildName(string value, string parent)
    {
        var prefix = parent.TrimEnd('/') + "/";
        var child = value.StartsWith(prefix, StringComparison.Ordinal) ? value[prefix.Length..] : value;
        return UpdateManifestVerifier.IsSafeName(child) ? child : null;
    }

    private static AsyncFtpClient CreateClient(AppSettings settings, string password)
    {
        var client = new AsyncFtpClient(settings.Host.Trim(), settings.Username, password, settings.Port);
        client.Encoding = System.Text.Encoding.UTF8;
        client.Config.CheckCapabilities = false;
        client.Config.DisconnectWithQuit = false;
        client.Config.EncryptionMode = FtpEncryptionMode.None;
        client.Config.DataConnectionType = FtpDataConnectionType.AutoPassive;
        client.Config.ConnectTimeout = 15_000;
        client.Config.ReadTimeout = 60_000;
        client.Config.DataConnectionConnectTimeout = 15_000;
        client.Config.DataConnectionReadTimeout = 60_000;
        return client;
    }

    private static void Validate(AppSettings settings, string password)
    {
        if (settings.ValidateForTransfer() is { } error) throw new InvalidDataException(error);
        if (password.Any(char.IsControl)) throw L.WithDescription(new InvalidDataException(L.T("FTP 密码不能包含控制字符。")), L.M("FTP 密码不能包含控制字符。"));
    }
}
