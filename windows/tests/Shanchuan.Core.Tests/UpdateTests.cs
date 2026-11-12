using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed class UpdateTests
{
    [Fact]
    public async Task VerifiesSharedCrossPlatformSignatureAndRejectsTampering()
    {
        var root = RepositoryRoot();
        var fixture = Path.Combine(root, "Fixtures", "Updates");
        var verifier = new UpdateManifestVerifier(File.ReadAllText(Path.Combine(fixture, "public-key.pem")));
        var bytes = File.ReadAllBytes(Path.Combine(fixture, "manifest.json"));
        var signature = File.ReadAllBytes(Path.Combine(fixture, "manifest.sig"));
        var manifest = verifier.Verify(bytes, signature);
        Assert.Equal("9.8.7", manifest.Version);
        await UpdateManifestVerifier.VerifyAssetAsync(Path.Combine(fixture, "payload.bin"), manifest.Assets.Single());
        var corrupt = bytes.ToArray(); corrupt[10] ^= 1;
        Assert.Throws<InvalidDataException>(() => verifier.Verify(corrupt, signature));
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Assert.Throws<InvalidDataException>(() => new UpdateManifestVerifier(key.ExportSubjectPublicKeyInfoPem()).Verify(bytes, signature));
        using var temp = new TemporaryRoot();
        var payload = Path.Combine(temp.Path, "payload.bin");
        File.WriteAllBytes(payload, "tampered"u8.ToArray());
        await Assert.ThrowsAsync<InvalidDataException>(() => UpdateManifestVerifier.VerifyAssetAsync(payload, manifest.Assets.Single()));
    }

    [Theory]
    [InlineData("../escape.bin", "windows", "x64")]
    [InlineData("C:\\escape.bin", "windows", "x64")]
    [InlineData("normal.bin", "windows", "arm64")]
    [InlineData("normal.bin", "linux", "x64")]
    [InlineData("normal.bin", "macos", "arm64")]
    public void RejectsSignedUnsafeOrWrongPlatformAssets(string name, string platform, string arch)
    {
        using var fixture = new UpdateFixture();
        var altered = fixture.Manifest with { Assets = [fixture.Manifest.Assets[0] with { Name = name, Platform = platform, Arch = arch }] };
        var signed = fixture.Sign(altered);
        Assert.Throws<InvalidDataException>(() => fixture.Verifier.Verify(signed.Bytes, signed.Signature));
    }

    [Fact]
    public void RejectsDuplicateFieldsEvenWithValidSignature()
    {
        using var fixture = new UpdateFixture();
        var json = Encoding.UTF8.GetString(fixture.Bytes).Replace("\"version\":", "\"version\":\"99.0.0\",\"version\":");
        var bytes = Encoding.UTF8.GetBytes(json);
        Assert.Throws<InvalidDataException>(() => fixture.Verifier.Verify(bytes, fixture.SignBytes(bytes)));
        Assert.Throws<InvalidDataException>(() => fixture.Verifier.Verify(new byte[UpdateManifestVerifier.MaxManifestBytes + 1], fixture.Signature));
    }

    [Fact]
    public async Task CacheRejectsTruncationAndSignedFeedWhichReferencesAnotherPackage()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        await Assert.ThrowsAsync<InvalidDataException>(() => cache.ImportAsync(fixture.Bytes, fixture.Signature,
            (asset, path, _) => File.WriteAllBytesAsync(path, fixture.Files[asset.Name][..^1])));
        Assert.Empty(Directory.EnumerateDirectories(root.Path));
        fixture.ChangeFeed(fullName: "unsigned.nupkg");
        await Assert.ThrowsAsync<InvalidDataException>(() => cache.ImportAsync(fixture.Bytes, fixture.Signature, fixture.CopyAsset));
        Assert.Empty(Directory.EnumerateDirectories(root.Path));
    }

    [Fact]
    public async Task RevalidatesAllCachedFilesBeforeInstallation()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        var verified = await cache.ImportAsync(fixture.Bytes, fixture.Signature, fixture.CopyAsset);
        Assert.Equal(fixture.Manifest.Version, (await cache.LoadAsync(verified.CacheDirectory)).Manifest.Version);
        var full = fixture.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
        await File.WriteAllBytesAsync(Path.Combine(verified.CacheDirectory, full.Name), new byte[full.Size]);
        await Assert.ThrowsAsync<InvalidDataException>(() => cache.LoadAsync(verified.CacheDirectory));
        await Assert.ThrowsAsync<InvalidDataException>(() => cache.LoadAsync(Path.Combine(root.Path, "..")));
    }

    [Fact]
    public void DailyWindowCatchesMissedChecksAndHandlesLocalTimezone()
    {
        var utc = TimeZoneInfo.Utc;
        var before = new DateTimeOffset(2026, 11, 12, 0, 59, 59, TimeSpan.Zero);
        Assert.Equal(new DateTimeOffset(2026, 11, 11, 1, 0, 0, TimeSpan.Zero), UpdateSchedule.LatestWindow(before, utc));
        Assert.Equal(new DateTimeOffset(2026, 11, 12, 1, 0, 0, TimeSpan.Zero), UpdateSchedule.LatestWindow(before.AddSeconds(1), utc));
        Assert.Equal(UpdateSchedule.WindowKey(before.AddSeconds(1), utc), UpdateSchedule.WindowKey(before.AddHours(20), utc));
        var east = TimeZoneInfo.CreateCustomTimeZone("FixtureEast", TimeSpan.FromHours(8), "Fixture", "Fixture");
        Assert.Equal(TimeSpan.FromHours(8), UpdateSchedule.LatestWindow(before, east).Offset);
        Assert.Equal(1, UpdateSchedule.LatestWindow(before, east).Hour);
        Assert.Equal(new[] { 1, 5, 15, 60, 60 }, Enumerable.Range(1, 5).Select(x => (int)UpdateSchedule.Backoff(x).TotalMinutes));
    }

    [Fact]
    public async Task ExternalDownloadsAndRelaysWithoutInstallOrHistoryThenDeduplicatesAndRestores()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var source = new FakeSource(fixture);
        var relay = new FakeRelay(fixture);
        var settings = Settings(NetworkMode.External);
        var clock = DateTimeOffset.Now;
        using (var coordinator = Coordinator(root.Path, fixture, source, relay, settings, () => clock))
        {
            await coordinator.TickAsync();
            Assert.Equal(1, source.Checks);
            Assert.Equal(1, relay.Sends);
            Assert.True(coordinator.Snapshot.CanInstall);
            Assert.Equal("已投递更新包", coordinator.Snapshot.RelayStatus);
            Assert.NotNull(coordinator.GetCandidateForInstall());
            await coordinator.TickAsync();
            Assert.Equal(1, source.Checks);
            Assert.Equal(1, relay.Sends);
            clock = clock.AddHours(25);
            await coordinator.TickAsync();
            Assert.Equal(2, source.Checks);
            Assert.Equal(1, relay.Sends);
            Assert.False(File.Exists(Path.Combine(root.Path, "history.json")));
            Assert.False(Directory.Exists(Path.Combine(root.Path, "packages")));
        }
        using var restored = Coordinator(root.Path, fixture, source, relay, settings, () => clock);
        // Installation authorization may be restored before the first timer tick.
        Assert.NotNull(restored.GetCandidateForInstall());
        await restored.TickAsync();
        Assert.Equal(2, source.Checks);
        Assert.Equal(1, relay.Sends);
    }

    [Fact]
    public async Task ExternalCurrentVersionStillRelaysForOlderInternalPeersAndNeverCallsReceiver()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var source = new FakeSource(fixture);
        var relay = new FakeRelay(fixture);
        using var coordinator = new UpdateCoordinator(root.Path, fixture.Manifest.Version, () => Settings(NetworkMode.External), () => "password",
            () => false, fixture.Verifier, source, relay);
        await coordinator.TickAsync();
        Assert.Equal(1, relay.Sends);
        Assert.Equal(0, relay.Receives);
        Assert.False(coordinator.Snapshot.CanInstall);
    }

    [Fact]
    public async Task InternalNeverCallsGitHubAndCorruptStateDoesNotPreventStartup()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        Directory.CreateDirectory(Path.Combine(root.Path, "Updates"));
        File.WriteAllText(Path.Combine(root.Path, "Updates/update-state.json"), "broken json");
        var source = new FakeSource(fixture);
        var relay = new FakeRelay(fixture);
        using var coordinator = Coordinator(root.Path, fixture, source, relay, Settings(NetworkMode.Internal), () => DateTimeOffset.Now);
        await coordinator.TickAsync();
        Assert.Equal(0, source.Checks);
        Assert.Equal(1, relay.Receives);
        Assert.Equal(0, relay.Sends);
        Assert.True(coordinator.Snapshot.CanInstall);
    }

    [Fact]
    public async Task CheckFailureBackoffAndConcurrentTicksDoNotDuplicateNetwork()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var source = new FakeSource(fixture) { Fail = true, Delay = true };
        var relay = new FakeRelay(fixture);
        var now = DateTimeOffset.Now;
        using var coordinator = Coordinator(root.Path, fixture, source, relay, Settings(NetworkMode.External), () => now);
        await Task.WhenAll(coordinator.TickAsync(), coordinator.TickAsync(), coordinator.TickAsync());
        Assert.Equal(1, source.Checks);
        Assert.Equal(now.AddMinutes(1), coordinator.State.NextCheckAttemptUtc);
        await coordinator.TickAsync(); Assert.Equal(1, source.Checks);
        now = now.AddMinutes(1); await coordinator.TickAsync();
        Assert.Equal(2, source.Checks);
        Assert.Equal(now.AddMinutes(5), coordinator.State.NextCheckAttemptUtc);
        source.Fail = false;
        await coordinator.CheckAsync();
        Assert.True(coordinator.Snapshot.CanInstall);
        Assert.Equal(0, coordinator.State.CheckFailures);
    }

    [Fact]
    public async Task RefusesReplayAfterHigherReleaseAndRetriesRelayWithoutAnotherGitHubCheck()
    {
        using var root = new TemporaryRoot();
        using var fixture = new UpdateFixture();
        var source = new FakeSource(fixture);
        var relay = new FakeRelay(fixture) { FailSend = true };
        var now = DateTimeOffset.Now;
        using var coordinator = Coordinator(root.Path, fixture, source, relay, Settings(NetworkMode.External), () => now);
        await coordinator.TickAsync();
        Assert.Equal(1, source.Checks);
        Assert.StartsWith("转发失败", coordinator.Snapshot.RelayStatus);
        relay.FailSend = false; now = now.AddMinutes(1);
        await coordinator.TickAsync();
        Assert.Equal(1, source.Checks);
        Assert.Equal("已投递更新包", coordinator.Snapshot.RelayStatus);
        using var old = new UpdateFixture("0.1.0");
        // Trusted publisher key signs an older version: reject it even though it is authentic.
        var replayBytes = fixture.Sign(old.Manifest);
        source.Override = new RemoteUpdateRelease("v0.1.0", replayBytes.Bytes, replayBytes.Signature);
        await coordinator.CheckAsync();
        Assert.StartsWith("检查失败", coordinator.Snapshot.Status);
        Assert.Equal(fixture.Manifest.Version, coordinator.Snapshot.CandidateVersion);
    }

    [Fact]
    public async Task GitHubPinsAssetUrlsAndIgnoresDraftsOrPrereleases()
    {
        using var fixture = new UpdateFixture();
        var requests = new List<Uri>();
        using var http = new HttpClient(new DelegateHandler(request =>
        {
            requests.Add(request.RequestUri!);
            byte[] bytes;
            if (request.RequestUri!.Host == "api.github.com")
                bytes = JsonSerializer.SerializeToUtf8Bytes(new { draft = false, prerelease = false, tag_name = "v" + fixture.Manifest.Version,
                    assets = new[] { new { name = "update-manifest.json" }, new { name = "update-manifest.sig" } } });
            else bytes = request.RequestUri.AbsolutePath.EndsWith(".sig") ? fixture.Signature : fixture.Bytes;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
        }));
        var source = new GitHubUpdateSource(http);
        var release = await source.GetLatestAsync(default);
        Assert.NotNull(release);
        Assert.All(requests.Skip(1), url => Assert.StartsWith("https://github.com/DB-XiaoQiang/shanchuan/releases/download/v", url.AbsoluteUri));
        Assert.Throws<InvalidDataException>(() => GitHubUpdateSource.AssetUrl("../other", "test"));
        Assert.Throws<InvalidDataException>(() => GitHubUpdateSource.AssetUrl("v1.0.0", "../test"));
        using var draftHttp = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent("{\"draft\":true,\"prerelease\":false}") }));
        Assert.Null(await new GitHubUpdateSource(draftHttp).GetLatestAsync(default));
    }

    private static UpdateCoordinator Coordinator(string root, UpdateFixture fixture, IUpdateSource source, IUpdateRelay relay,
        AppSettings settings, Func<DateTimeOffset> clock) => new(root, "0.3.0", () => settings, () => "fixture-password", () => false,
            fixture.Verifier, source, relay, clock);
    internal static AppSettings Settings(NetworkMode mode) => new()
    { Host = "127.0.0.1", Username = "fixture", Directory = "/share", NetworkMode = mode };
    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "Fixtures/Updates"))) directory = directory.Parent;
        return directory?.FullName ?? throw new InvalidOperationException("找不到跨平台签名样例。");
    }

    private sealed class FakeSource(UpdateFixture fixture) : IUpdateSource
    {
        public int Checks;
        public bool Fail;
        public bool Delay;
        public RemoteUpdateRelease? Override;
        public async Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token)
        {
            Checks++;
            if (Delay) await Task.Delay(30, token);
            if (Fail) throw new IOException("fixture unavailable");
            return Override ?? new RemoteUpdateRelease("v" + fixture.Manifest.Version, fixture.Bytes, fixture.Signature);
        }
        public Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token) => fixture.CopyAsset(asset, destination, token);
    }
    private sealed class FakeRelay(UpdateFixture fixture) : IUpdateRelay
    {
        public int Sends;
        public int Receives;
        public bool FailSend;
        public Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token)
        { Sends++; return FailSend ? Task.FromException(new IOException("fixture unavailable")) : Task.CompletedTask; }
        public async Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion, AppSettings settings, string password, CancellationToken token)
        { Receives++; return await cache.ImportAsync(fixture.Bytes, fixture.Signature, fixture.CopyAsset, token); }
    }
    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response(request));
    }
}

internal sealed class TemporaryRoot : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "shanchuan-update-tests-" + Guid.NewGuid().ToString("N"));
    public TemporaryRoot() => Directory.CreateDirectory(Path);
    public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
}

internal sealed class UpdateFixture : IDisposable
{
    private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    public UpdateManifestVerifier Verifier { get; }
    public UpdateManifest Manifest { get; private set; }
    public byte[] Bytes { get; private set; } = [];
    public byte[] Signature { get; private set; } = [];
    public Dictionary<string, byte[]> Files { get; } = [];
    public UpdateFixture(string version = "9.8.7")
    {
        Verifier = new UpdateManifestVerifier(_key.ExportSubjectPublicKeyInfoPem());
        var full = "Shanchuan-" + version + "-win-x64-full.nupkg";
        Files[full] = "synthetic complete update package"u8.ToArray();
        Manifest = new UpdateManifest { SchemaVersion = 1, Product = "Shanchuan", Channel = "stable", Version = version, ReleaseNotes = "合成更新说明", Assets = [Asset(full, "velopack-full")] };
        ChangeFeed();
    }
    public void ChangeFeed(string? fullName = null)
    {
        var full = Manifest.Assets.Single(x => x.Kind == "velopack-full");
        Files["releases.win-x64.json"] = JsonSerializer.SerializeToUtf8Bytes(new { Assets = new[] { new { PackageId = "Shanchuan", Version = Manifest.Version,
            Type = "Full", FileName = fullName ?? full.Name, Size = full.Size, SHA256 = full.Sha256 } } });
        Manifest = Manifest with { Assets = [full, Asset("releases.win-x64.json", "velopack-feed")] };
        (Bytes, Signature) = Sign(Manifest);
    }
    private UpdateAsset Asset(string name, string kind) => new() { Platform = "windows", Arch = "x64", Kind = kind, Name = name,
        Size = Files[name].Length, Sha256 = Convert.ToHexString(SHA256.HashData(Files[name])).ToLowerInvariant() };
    public (byte[] Bytes, byte[] Signature) Sign(UpdateManifest manifest)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(manifest, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        return (bytes, SignBytes(bytes));
    }
    public byte[] SignBytes(byte[] bytes) => _key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    public Task CopyAsset(UpdateAsset asset, string destination, CancellationToken token) => File.WriteAllBytesAsync(destination, Files[asset.Name], token);
    public void Dispose() => _key.Dispose();
}
