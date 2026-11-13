using FluentFTP;

namespace Shanchuan.Core;

/// <summary>FTP transport with serial, byte-weighted uploads and a read-only connection test.</summary>
public sealed class FtpTransferService
{
    public async Task TestConnectionAsync(AppSettings settings, string password,
        CancellationToken cancellationToken = default)
    {
        Validate(settings, password);
        using var client = CreateClient(settings, password);
        client.Config.ConnectTimeout = 5_000;
        client.Config.ReadTimeout = 5_000;
        client.Config.CheckCapabilities = false;
        client.Config.DisconnectWithQuit = false;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            await client.Connect(timeout.Token).ConfigureAwait(false);
            await client.SetWorkingDirectory(settings.Directory, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(L.T("连接测试超过 10 秒，请检查服务器地址、端口和网络。"), error);
        }
    }

    public async Task UploadPreparedAsync(PreparedTransfer transfer, AppSettings settings, string password,
        IProgress<TransferProgressValues>? progress = null, CancellationToken cancellationToken = default)
    {
        NetworkPolicy.RequireUpload(settings);
        Validate(settings, password);
        var sizes = transfer.Files.Select(file => new FileInfo(file.LocalPath).Length).ToArray();
        var tracker = new TransferByteProgress(sizes);
        progress?.Report(tracker.Update(-1, 0));

        using var client = CreateClient(settings, password);
        await client.Connect(cancellationToken).ConfigureAwait(false);
        for (var index = 0; index < transfer.Files.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = transfer.Files[index];
            var remotePath = file.Directory.TrimEnd('/') + "/" + file.RemoteName;
            var fileProgress = new Progress<FtpProgress>(value =>
                progress?.Report(tracker.Update(index, value.Progress / 100)));
            var result = await client.UploadFile(file.LocalPath, remotePath, FtpRemoteExists.Overwrite,
                true, FtpVerify.None, fileProgress, cancellationToken).ConfigureAwait(false);
            if (result != FtpStatus.Success)
                throw new IOException(L.F($"FTP 上传未完成：{file.RemoteName}（{result}）。"));
            progress?.Report(tracker.Update(index, 1));
        }
    }

    private static AsyncFtpClient CreateClient(AppSettings settings, string password)
    {
        var client = new AsyncFtpClient(settings.Host.Trim(), settings.Username, password, settings.Port);
        client.Encoding = System.Text.Encoding.UTF8;
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
        if (password.Any(char.IsControl)) throw new InvalidDataException(L.T("FTP 密码不能包含控制字符。"));
    }
}
