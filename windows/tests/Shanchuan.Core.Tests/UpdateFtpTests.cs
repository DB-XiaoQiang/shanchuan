using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed partial class FtpLoopbackTests
{
    [Fact]
    public async Task UpdateRelayCommitsSignatureLastAndAllInternalPeersReadWithoutDeleting()
    {
        using var server = new LoopbackFtpServer();
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var external = Settings(server, NetworkMode.External);
        var senderCache = new UpdateCache(Path.Combine(root.Path, "sender"), fixture.Verifier);
        var candidate = await senderCache.ImportAsync(fixture.Bytes, fixture.Signature, fixture.CopyAsset);
        var transport = new FtpUpdateTransport();
        await transport.RelayAsync(candidate, external, "fixture-password", default);
        await transport.RelayAsync(candidate, external, "fixture-password", default);
        Assert.Equal(8, server.Uploads.Count);
        Assert.All(server.Uploads, upload => Assert.StartsWith("/share/shanchuan_updates/stable/win-x64/9.8.7/", upload.RemotePath));
        Assert.EndsWith("/update-manifest.sig", server.Uploads[3].RemotePath);
        Assert.EndsWith("/update-manifest.sig", server.Uploads[7].RemotePath);
        Assert.NotEqual(server.Uploads[3].RemotePath, server.Uploads[7].RemotePath);
        var inner = Settings(server, NetworkMode.Internal);
        var first = await transport.ReceiveAsync(new UpdateCache(Path.Combine(root.Path, "inner1"), fixture.Verifier), fixture.Verifier,
            "0.3.0", inner, "fixture-password", default);
        var second = await transport.ReceiveAsync(new UpdateCache(Path.Combine(root.Path, "inner2"), fixture.Verifier), fixture.Verifier,
            "0.3.0", inner, "fixture-password", default);
        Assert.NotNull(first);
        Assert.NotNull(second);
        Assert.Equal(first.ManifestHash, second.ManifestHash);
        Assert.Equal(8, server.Files.Count);
        Assert.DoesNotContain("DELE", server.Commands);
        Assert.Empty(server.Errors);
        Assert.False(File.Exists(Path.Combine(root.Path, "history.json")));
    }

    [Fact]
    public async Task ReceiverIgnoresInterruptedUpdateAndRejectsCorruptedCommittedBatch()
    {
        using var server = new LoopbackFtpServer();
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var settings = Settings(server, NetworkMode.Internal);
        var batch = "/share/shanchuan_updates/stable/win-x64/9.8.7/" + Guid.NewGuid().ToString("N") + "/";
        server.Seed(batch + "update-manifest.json", fixture.Bytes);
        var transport = new FtpUpdateTransport();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        Assert.Null(await transport.ReceiveAsync(cache, fixture.Verifier, "0.3.0", settings, "fixture-password", default));
        Assert.DoesNotContain("RETR", server.Commands);
        server.Seed(batch + "update-manifest.sig", fixture.Signature);
        foreach (var (name, content) in fixture.Files) server.Seed(batch + name, content);
        var fullName = fixture.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full").Name;
        server.Seed(batch + fullName, new byte[fixture.Files[fullName].Length + 1]);
        await Assert.ThrowsAsync<InvalidDataException>(() => transport.ReceiveAsync(cache, fixture.Verifier, "0.3.0", settings, "fixture-password", default));
        Assert.Empty(Directory.EnumerateDirectories(root.Path));
        Assert.DoesNotContain("DELE", server.Commands);
        server.Seed(batch + fullName, fixture.Files[fullName]);
        Assert.NotNull(await transport.ReceiveAsync(cache, fixture.Verifier, "0.3.0", settings, "fixture-password", default));
        Assert.Null(await transport.ReceiveAsync(cache, fixture.Verifier, "9.8.7", settings, "fixture-password", default));
        Assert.Null(await transport.ReceiveAsync(cache, fixture.Verifier, "10.0.0", settings, "fixture-password", default));
    }

    [Fact]
    public async Task ReceiverFindsCommittedBatchAfterManyAbandonedAttempts()
    {
        using var server = new LoopbackFtpServer();
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        const string versionRoot = "/share/shanchuan_updates/stable/win-x64/9.8.7/";
        // Lexically earlier interrupted uploads must not hide a later complete delivery.
        for (var index = 1; index <= 64; index++)
            server.Seed(versionRoot + index.ToString("x32") + "/update-manifest.json", fixture.Bytes);
        var committed = versionRoot + new string('f', 32) + "/";
        foreach (var (name, content) in fixture.Files) server.Seed(committed + name, content);
        server.Seed(committed + "update-manifest.json", fixture.Bytes);
        server.Seed(committed + "update-manifest.sig", fixture.Signature);
        var candidate = await new FtpUpdateTransport().ReceiveAsync(new UpdateCache(root.Path, fixture.Verifier),
            fixture.Verifier, "0.3.0", Settings(server, NetworkMode.Internal), "fixture-password", default);
        Assert.NotNull(candidate);
        Assert.Equal("9.8.7", candidate.Manifest.Version);
        Assert.DoesNotContain("DELE", server.Commands);
        Assert.Empty(server.Errors);
    }

    [Fact]
    public async Task RelayWaitsForBusinessTransfersAndRejectsWrongNetworkModesBeforeConnecting()
    {
        using var server = new LoopbackFtpServer();
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        var candidate = await cache.ImportAsync(fixture.Bytes, fixture.Signature, fixture.CopyAsset);
        var busy = true;
        using var gate = new SemaphoreSlim(1, 1);
        var transport = new FtpUpdateTransport(() => busy, gate);
        var external = Settings(server, NetworkMode.External);
        var inner = Settings(server, NetworkMode.Internal);
        await Assert.ThrowsAsync<InvalidOperationException>(() => transport.RelayAsync(candidate, inner, "fixture-password", default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => transport.ReceiveAsync(cache, fixture.Verifier, "0.3.0", external, "fixture-password", default));
        Assert.Empty(server.Commands);
        var upload = transport.RelayAsync(candidate, external, "fixture-password", default);
        await Task.Delay(100);
        Assert.Empty(server.Commands);
        busy = false;
        await upload;
        Assert.Equal(4, server.Uploads.Count);
        Assert.Empty(server.Errors);
    }
}
