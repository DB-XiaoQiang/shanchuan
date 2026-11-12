using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed partial class FtpLoopbackTests
{
    [Fact]
    public async Task UploadsExactProtocolOverLoopbackFtp()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-ftp-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var settings = new AppSettings
            {
                Host = "127.0.0.1",
                Port = server.Port,
                Username = "fixture",
                Directory = "/share",
                NetworkMode = NetworkMode.External
            };
            const string password = "fixture-password";
            var service = new FtpTransferService();
            await service.TestConnectionAsync(settings, password);

            using var text = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.Text, Content = "Windows 闪传\r\nUTF-8 🧪" }, settings, 123);
            var progress = new ConcurrentQueue<TransferProgressValues>();
            await service.UploadPreparedAsync(text, settings, password, new InlineProgress<TransferProgressValues>(progress.Enqueue));

            var ordinary = Path.Combine(root, "普通文件.txt");
            File.WriteAllText(ordinary, "普通文件内容\n", Encoding.UTF8);
            var folder = Path.Combine(root, "测试文件夹");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "说明.txt"), "目录内容\n", Encoding.UTF8);
            using var files = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.File, Paths = [ordinary, folder] }, settings, 42);
            await service.UploadPreparedAsync(files, settings, password);

            Assert.Empty(server.Errors);
            Assert.Equal([
                "/share/system_temp/copy.temp.123",
                "/share/system_temp/普通文件",
                "/share/system_temp/测试文件夹",
                "/share/system_temp/copy.temp.42"
            ], server.Uploads.Select(item => item.RemotePath));
            Assert.Equal("Windows 闪传\r\nUTF-8 🧪", Encoding.UTF8.GetString(server.Uploads[0].Content));
            Assert.Equal(File.ReadAllBytes(ordinary), server.Uploads[1].Content);
            Assert.Equal(File.ReadAllBytes(files.Files[^1].LocalPath), server.Uploads[3].Content);
            Assert.Contains(progress, value => value.Fraction == 1);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task ConnectionTestSkipsNonessentialRoundTrips()
    {
        using var server = new LoopbackFtpServer();
        var settings = new AppSettings
        {
            Host = "127.0.0.1",
            Port = server.Port,
            Username = "fixture",
            Directory = "/share"
        };

        await new FtpTransferService().TestConnectionAsync(settings, "fixture-password");

        Assert.Empty(server.Errors);
        Assert.Contains("CWD", server.Commands);
        Assert.DoesNotContain("FEAT", server.Commands);
        Assert.DoesNotContain("QUIT", server.Commands);
    }

    [Fact]
    public async Task InternalSideReceivesTextFilesAndFoldersThenDeletesOnlyCommittedItems()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-receive-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var external = Settings(server, NetworkMode.External);
            var ordinary = Path.Combine(root, "普通文件.txt");
            File.WriteAllText(ordinary, "来自外网的普通文件\n", Encoding.UTF8);
            var folder = Path.Combine(root, "测试文件夹");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "说明.txt"), "目录内容\n", Encoding.UTF8);
            using var text = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.Text, Content = "外网文本\r\n你好 🧪" }, external, 123);
            using var files = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.File, Paths = [ordinary, folder] }, external, 124);
            var uploader = new FtpTransferService();
            await uploader.UploadPreparedAsync(text, external, "fixture-password");
            await uploader.UploadPreparedAsync(files, external, "fixture-password");
            server.Seed("/share/system_temp/copy.temp.pending", "not a committed control"u8.ToArray());
            server.Seed("/share/system_temp/other.125", "unrelated"u8.ToArray());

            var internalSettings = Settings(server, NetworkMode.Internal);
            internalSettings.ReceiveDirectory = Path.Combine(root, "接收目录");
            Directory.CreateDirectory(internalSettings.ReceiveDirectory);
            var existing = Path.Combine(internalSettings.ReceiveDirectory, "普通文件.txt");
            File.WriteAllText(existing, "保留本机同名文件", Encoding.UTF8);
            var stateStore = new ReceiveStateStore(Path.Combine(root, "state"));
            var receiver = new FtpReceiveService(stateStore);
            var result = await receiver.ReceivePendingAsync(internalSettings, "fixture-password");

            Assert.Empty(result.Failures);
            Assert.Empty(result.Warnings);
            Assert.Equal(2, result.Received.Count);
            Assert.Equal("外网文本\r\n你好 🧪", result.Received[0].Content);
            Assert.All(result.Received, entry => Assert.Equal("已接收", entry.Status));
            var receivedFile = Assert.Single(result.Received[1].Paths, File.Exists);
            Assert.Equal("普通文件 (1).txt", Path.GetFileName(receivedFile));
            Assert.Equal("来自外网的普通文件\n", File.ReadAllText(receivedFile));
            Assert.Equal("保留本机同名文件", File.ReadAllText(existing));
            var receivedFolder = Assert.Single(result.Received[1].Paths, Directory.Exists);
            Assert.Equal("目录内容\n", File.ReadAllText(Path.Combine(receivedFolder, "说明.txt"), Encoding.UTF8));
            Assert.Equal(2, server.Files.Count);
            Assert.True(server.Files.ContainsKey("/share/system_temp/copy.temp.pending"));
            Assert.True(server.Files.ContainsKey("/share/system_temp/other.125"));
            Assert.Equal(4, server.Commands.Count(command => command == "DELE"));

            var repeated = await receiver.ReceivePendingAsync(internalSettings, "fixture-password");
            Assert.Empty(repeated.Received);
            Assert.Empty(repeated.Failures);
            Assert.Equal(2, Directory.GetFiles(internalSettings.ReceiveDirectory, "普通文件*.txt").Length);
            Assert.False(File.Exists(Path.Combine(internalSettings.ReceiveDirectory, "普通文件 (2).txt")));
            Assert.Empty(server.Errors);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task InvalidManifestAndMd5MismatchRemainOnServer()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-invalid-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var external = Settings(server, NetworkMode.External);
            var source = Path.Combine(root, "a.txt");
            File.WriteAllText(source, "correct", Encoding.UTF8);
            using var plan = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.File, Paths = [source] }, external, 77);
            await new FtpTransferService().UploadPreparedAsync(plan, external, "fixture-password");
            server.Files["/share/system_temp/a"] = "corrupted"u8.ToArray();
            server.Seed("/share/system_temp/copy.temp.88", "file=broken\r\n88"u8.ToArray());
            var internalSettings = Settings(server, NetworkMode.Internal);
            internalSettings.ReceiveDirectory = Path.Combine(root, "received");
            var receiver = new FtpReceiveService(new ReceiveStateStore(Path.Combine(root, "state")));

            var result = await receiver.ReceivePendingAsync(internalSettings, "fixture-password");

            Assert.Empty(result.Received);
            Assert.Equal(2, result.Failures.Count);
            Assert.Contains(result.Failures, failure => failure.ControlName == "copy.temp.77" && failure.Reason.Contains("MD5"));
            Assert.Contains(result.Failures, failure => failure.ControlName == "copy.temp.88");
            Assert.True(server.Files.ContainsKey("/share/system_temp/a"));
            Assert.True(server.Files.ContainsKey("/share/system_temp/copy.temp.77"));
            Assert.True(server.Files.ContainsKey("/share/system_temp/copy.temp.88"));
            Assert.DoesNotContain("DELE", server.Commands);
            Assert.Empty(server.Errors);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task ZipTraversalIsRejectedWithoutDeletingRemoteData()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-zip-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            byte[] zip;
            using (var memory = new MemoryStream())
            {
                using (var archive = new System.IO.Compression.ZipArchive(memory, System.IO.Compression.ZipArchiveMode.Create, true))
                using (var writer = new StreamWriter(archive.CreateEntry("../escape.txt").Open(), Encoding.UTF8))
                    writer.Write("must not escape");
                zip = memory.ToArray();
            }
            var hash = Convert.ToHexString(System.Security.Cryptography.MD5.HashData(zip)).ToLowerInvariant();
            server.Seed("/share/system_temp/folder", zip);
            server.Seed("/share/system_temp/copy.temp.99", Encoding.UTF8.GetBytes($"file=folder:folder|{hash}\r\n99"));
            var internalSettings = Settings(server, NetworkMode.Internal);
            internalSettings.ReceiveDirectory = Path.Combine(root, "received");

            var result = await new FtpReceiveService(new ReceiveStateStore(Path.Combine(root, "state")))
                .ReceivePendingAsync(internalSettings, "fixture-password");

            var failure = Assert.Single(result.Failures);
            Assert.Contains("路径", failure.Reason);
            Assert.Empty(result.Received);
            Assert.False(File.Exists(Path.Combine(root, "escape.txt")));
            Assert.True(server.Files.ContainsKey("/share/system_temp/folder"));
            Assert.True(server.Files.ContainsKey("/share/system_temp/copy.temp.99"));
            Assert.Empty(server.Errors);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task FailedRemoteDeletionRetriesCleanupWithoutReceivingTwice()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-cleanup-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var external = Settings(server, NetworkMode.External);
            using var plan = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.Text, Content = "只接收一次" }, external, 98);
            await new FtpTransferService().UploadPreparedAsync(plan, external, "fixture-password");
            var internalSettings = Settings(server, NetworkMode.Internal);
            internalSettings.ReceiveDirectory = Path.Combine(root, "received");
            var receiver = new FtpReceiveService(new ReceiveStateStore(Path.Combine(root, "state")));
            server.RejectNextDelete = true;

            var first = await receiver.ReceivePendingAsync(internalSettings, "fixture-password");
            Assert.Single(first.Received);
            Assert.Single(first.Warnings);
            Assert.True(server.Files.ContainsKey("/share/system_temp/copy.temp.98"));

            var retry = await receiver.ReceivePendingAsync(internalSettings, "fixture-password");
            Assert.Empty(retry.Received);
            Assert.Empty(retry.Failures);
            Assert.Empty(retry.Warnings);
            Assert.Empty(server.Files);
            Assert.Empty(server.Errors);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task NetworkModesRejectForbiddenOperationsBeforeConnecting()
    {
        using var server = new LoopbackFtpServer();
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-policy-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var external = Settings(server, NetworkMode.External);
            using var plan = TransferPreparationService.Prepare(
                new HistoryEntry { Kind = HistoryKind.Text, Content = "policy" }, external, 100);
            var uploader = new FtpTransferService();
            var receiver = new FtpReceiveService(new ReceiveStateStore(Path.Combine(root, "state")));
            foreach (var mode in new[] { NetworkMode.Unconfigured, NetworkMode.Internal })
            {
                var settings = Settings(server, mode);
                await Assert.ThrowsAsync<InvalidOperationException>(() =>
                    uploader.UploadPreparedAsync(plan, settings, "fixture-password"));
            }
            foreach (var mode in new[] { NetworkMode.Unconfigured, NetworkMode.External })
            {
                var settings = Settings(server, mode);
                await Assert.ThrowsAsync<InvalidOperationException>(() =>
                    receiver.ReceivePendingAsync(settings, "fixture-password"));
            }

            Assert.Empty(server.Commands);
            Assert.Empty(server.Files);
            Assert.Empty(server.Errors);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static AppSettings Settings(LoopbackFtpServer server, NetworkMode mode) => new()
    {
        Host = "127.0.0.1",
        Port = server.Port,
        Username = "fixture",
        Directory = "/share",
        NetworkMode = mode
    };

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed record Upload(string RemotePath, byte[] Content);

    private sealed class LoopbackFtpServer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _lifetime = new();
        private readonly Task _acceptTask;

        public LoopbackFtpServer()
        {
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _acceptTask = AcceptClients();
        }

        public int Port { get; }
        public List<Upload> Uploads { get; } = [];
        public ConcurrentDictionary<string, byte[]> Files { get; } = new(StringComparer.Ordinal);
        public ConcurrentQueue<string> Commands { get; } = new();
        public ConcurrentQueue<string> Errors { get; } = new();
        public bool RejectNextDelete { get; set; }

        public void Seed(string remotePath, byte[] content) => Files[remotePath] = content;

        private async Task AcceptClients()
        {
            try
            {
                while (!_lifetime.IsCancellationRequested)
                {
                    var client = await _listener.AcceptTcpClientAsync(_lifetime.Token);
                    _ = Task.Run(() => Handle(client));
                }
            }
            catch (OperationCanceledException) { }
            catch (ObjectDisposedException) { }
            catch (SocketException) when (_lifetime.IsCancellationRequested) { }
        }

        private async Task Handle(TcpClient client)
        {
            try
            {
                using var _ = client;
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, new UTF8Encoding(false));
                using var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\r\n" };
                TcpListener? passive = null;
                var cwd = "/";
                await writer.WriteLineAsync("220 Loopback fixture");
                while (await reader.ReadLineAsync(_lifetime.Token) is { } line)
                {
                    var separator = line.IndexOf(' ');
                    var command = (separator >= 0 ? line[..separator] : line).ToUpperInvariant();
                    Commands.Enqueue(command);
                    var argument = separator >= 0 ? line[(separator + 1)..] : "";
                    switch (command)
                    {
                        case "USER":
                            await writer.WriteLineAsync(argument == "fixture" ? "331 Password required" : "530 Invalid user");
                            break;
                        case "PASS":
                            await writer.WriteLineAsync(argument == "fixture-password" ? "230 Logged in" : "530 Invalid password");
                            break;
                        case "PWD":
                            await writer.WriteLineAsync($"257 \"{cwd}\"");
                            break;
                        case "CWD":
                            cwd = RemotePath(cwd, argument);
                            await writer.WriteLineAsync("250 Directory changed");
                            break;
                        case "TYPE":
                        case "OPTS":
                        case "CLNT":
                        case "MODE":
                        case "STRU":
                        case "NOOP":
                            await writer.WriteLineAsync("200 OK");
                            break;
                        case "SYST":
                            await writer.WriteLineAsync("215 UNIX Type: L8");
                            break;
                        case "FEAT":
                            await writer.WriteLineAsync("211 No extensions");
                            break;
                        case "EPSV":
                        case "PASV":
                            passive?.Stop();
                            passive = new TcpListener(IPAddress.Loopback, 0);
                            passive.Start();
                            var port = ((IPEndPoint)passive.LocalEndpoint).Port;
                            await writer.WriteLineAsync(command == "EPSV"
                                ? $"229 Entering Extended Passive Mode (|||{port}|)"
                                : $"227 Entering Passive Mode (127,0,0,1,{port / 256},{port % 256})");
                            break;
                        case "NLST":
                            if (passive is null) { await writer.WriteLineAsync("425 No data listener"); break; }
                            await writer.WriteLineAsync("150 Opening directory listing");
                            using (var data = await passive.AcceptTcpClientAsync(_lifetime.Token))
                            {
                                var directory = RemotePath(cwd, argument).TrimEnd('/');
                                var names = Files.Keys.Where(path => path.StartsWith(directory + "/", StringComparison.Ordinal))
                                    .Select(path => path[(directory.Length + 1)..].Split('/')[0])
                                    .Distinct(StringComparer.Ordinal).OrderBy(name => name, StringComparer.Ordinal);
                                var listing = string.Join("\r\n", names) + "\r\n";
                                await data.GetStream().WriteAsync(new UTF8Encoding(false).GetBytes(listing), _lifetime.Token);
                            }
                            passive.Stop();
                            passive = null;
                            await writer.WriteLineAsync("226 Listing complete");
                            break;
                        case "STOR":
                            if (passive is null) { await writer.WriteLineAsync("425 No data listener"); break; }
                            await writer.WriteLineAsync("150 Opening data connection");
                            using (var data = await passive.AcceptTcpClientAsync(_lifetime.Token))
                            using (var input = data.GetStream())
                            using (var content = new MemoryStream())
                            {
                                await input.CopyToAsync(content, _lifetime.Token);
                                var path = RemotePath(cwd, argument);
                                Uploads.Add(new Upload(path, content.ToArray()));
                                Files[path] = content.ToArray();
                            }
                            passive.Stop();
                            passive = null;
                            await writer.WriteLineAsync("226 Transfer complete");
                            break;
                        case "RETR":
                            if (passive is null) { await writer.WriteLineAsync("425 No data listener"); break; }
                            var remotePath = RemotePath(cwd, argument);
                            if (!Files.TryGetValue(remotePath, out var bytes))
                            {
                                await writer.WriteLineAsync("550 File unavailable");
                                break;
                            }
                            await writer.WriteLineAsync("150 Opening data connection");
                            using (var data = await passive.AcceptTcpClientAsync(_lifetime.Token))
                                await data.GetStream().WriteAsync(bytes, _lifetime.Token);
                            passive.Stop();
                            passive = null;
                            await writer.WriteLineAsync("226 Transfer complete");
                            break;
                        case "DELE":
                            if (RejectNextDelete)
                            {
                                RejectNextDelete = false;
                                await writer.WriteLineAsync("451 Temporary delete failure");
                                break;
                            }
                            await writer.WriteLineAsync(Files.TryRemove(RemotePath(cwd, argument), out var deletedContent)
                                ? "250 Deleted" : "550 File unavailable");
                            break;
                        case "MKD":
                        case "XMKD":
                            await writer.WriteLineAsync("257 Directory created");
                            break;
                        case "SIZE":
                            await writer.WriteLineAsync("213 0");
                            break;
                        case "MDTM":
                            await writer.WriteLineAsync("213 20260101000000");
                            break;
                        case "REST":
                            await writer.WriteLineAsync("350 Restart accepted");
                            break;
                        case "ABOR":
                            await writer.WriteLineAsync("226 Aborted");
                            break;
                        case "QUIT":
                            await writer.WriteLineAsync("221 Goodbye");
                            return;
                        default:
                            Errors.Enqueue("Unexpected command: " + command);
                            await writer.WriteLineAsync("502 Unsupported fixture command");
                            break;
                    }
                }
            }
            catch (Exception error) when (error is OperationCanceledException or IOException or SocketException or ObjectDisposedException)
            {
                if (!_lifetime.IsCancellationRequested) Errors.Enqueue(error.Message);
            }
            catch (Exception error) { Errors.Enqueue(error.Message); }
        }

        private static string RemotePath(string cwd, string path)
        {
            var combined = path.StartsWith('/') ? path : cwd.TrimEnd('/') + "/" + path;
            while (combined.Contains("//")) combined = combined.Replace("//", "/");
            return combined;
        }

        private static string Parent(string path)
        {
            var separator = path.LastIndexOf('/');
            return separator < 0 ? "" : path[..separator].TrimEnd('/');
        }

        public void Dispose()
        {
            _lifetime.Cancel();
            _listener.Stop();
            try { _acceptTask.Wait(TimeSpan.FromSeconds(2)); } catch { }
            _lifetime.Dispose();
        }
    }
}
