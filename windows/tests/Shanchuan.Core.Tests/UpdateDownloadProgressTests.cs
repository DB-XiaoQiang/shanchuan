using System.Net;
using System.Text.Json;
using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

[Collection("Application language")]
public sealed class UpdateDownloadProgressTests
{
    [Fact]
    public async Task ChunkedHttpWithoutContentLengthReportsRealIntermediateBytes()
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var asset = fixture.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
        var received = new List<long>();
        using var http = new HttpClient(new Handler(_ => Response(fixture.Files[asset.Name], chunk: 3)));
        var source = new GitHubUpdateSource(http);
        var path = Path.Combine(root.Path, asset.Name);
        await source.DownloadAssetAsync("v" + fixture.Manifest.Version, asset, path, default, new Capture<long>(received.Add));
        Assert.Equal(0, received.First());
        Assert.Equal(asset.Size, received.Last());
        Assert.Contains(received, bytes => bytes > 0 && bytes < asset.Size);
        Assert.Equal(received.Order(), received);
        Assert.Equal(fixture.Files[asset.Name], await File.ReadAllBytesAsync(path));
    }

    [Fact]
    public async Task OversizedOrCancelledHttpNeverReportsSuccessfulCompletion()
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var asset = fixture.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
        var received = new List<long>();
        using (var http = new HttpClient(new Handler(_ => Response(new byte[asset.Size + 20], chunk: 3))))
        {
            await Assert.ThrowsAsync<InvalidDataException>(() => new GitHubUpdateSource(http).DownloadAssetAsync(
                "v" + fixture.Manifest.Version, asset, Path.Combine(root.Path, "oversized"), default, new Capture<long>(received.Add)));
            Assert.All(received, value => Assert.InRange(value, 0, asset.Size));
        }
        received.Clear();
        using var cancel = new CancellationTokenSource();
        using var cancellationHttp = new HttpClient(new Handler(_ => Response(fixture.Files[asset.Name], chunk: 3)));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new GitHubUpdateSource(cancellationHttp).DownloadAssetAsync(
            "v" + fixture.Manifest.Version, asset, Path.Combine(root.Path, "cancelled"), cancel.Token,
            new Capture<long>(value => { received.Add(value); if (value >= 6) cancel.Cancel(); })));
        Assert.InRange(received.Last(), 1, asset.Size - 1);
    }

    [Fact]
    public async Task AggregateIncludesFullPackageFeedAndVerifiedCacheWithoutDownloadingAgain()
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        var snapshots = new List<UpdateDownloadProgress>();
        var expectedTotal = fixture.Manifest.WindowsUpdateAssets.Sum(x => x.Size);
        await cache.ImportAsync(fixture.Bytes, fixture.Signature, async (asset, path, progress, ct) =>
        {
            var bytes = fixture.Files[asset.Name];
            await using var output = File.Create(path);
            var split = bytes.Length / 2;
            await output.WriteAsync(bytes.AsMemory(0, split), ct); progress?.Report(split);
            await output.WriteAsync(bytes.AsMemory(split), ct); progress?.Report(bytes.Length);
        }, new Capture<UpdateDownloadProgress>(snapshots.Add));
        Assert.All(snapshots, item => Assert.Equal(expectedTotal, item.TotalBytes));
        Assert.Contains(snapshots, item => item.DownloadedBytes > 0 && item.DownloadedBytes < expectedTotal);
        Assert.Contains(snapshots, item => item.DownloadedBytes == expectedTotal && item.IsVerifying && !item.IsVerified);
        Assert.True(snapshots.Last().IsVerified);
        Assert.Equal(expectedTotal, snapshots.Last().DownloadedBytes);
        Assert.Equal(snapshots.Select(x => x.DownloadedBytes).Order(), snapshots.Select(x => x.DownloadedBytes));
        snapshots.Clear();
        var calls = 0;
        await cache.ImportAsync(fixture.Bytes, fixture.Signature, (_, _, _, _) =>
        {
            calls++;
            throw new InvalidOperationException("A verified complete cache must not download again.");
        }, new Capture<UpdateDownloadProgress>(snapshots.Add));
        Assert.Equal(0, calls);
        Assert.True(snapshots.Last().IsVerified);
        Assert.Equal(expectedTotal, snapshots.Last().DownloadedBytes);
        Assert.All(snapshots, item => Assert.InRange(item.DownloadedBytes, 0, expectedTotal));
    }

    [Fact]
    public async Task ProgressNotificationsAreThrottledAndLateCallbacksCannotUndoVerifiedState()
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var cache = new UpdateCache(root.Path, fixture.Verifier);
        var snapshots = new List<UpdateDownloadProgress>();
        var callbacks = new List<IProgress<long>>();
        const int reportsPerFile = 10_000;
        await cache.ImportAsync(fixture.Bytes, fixture.Signature, async (asset, path, progress, ct) =>
        {
            callbacks.Add(progress!);
            await File.WriteAllBytesAsync(path, fixture.Files[asset.Name], ct);
            for (var index = 0; index <= reportsPerFile; index++)
                progress?.Report(asset.Size * index / reportsPerFile);
        }, new Capture<UpdateDownloadProgress>(snapshots.Add));
        Assert.True(snapshots.Count < reportsPerFile / 10, "Transport chunks must not flood the dispatcher queue.");
        Assert.Contains(snapshots, item => item.DownloadedBytes > 0 && item.DownloadedBytes < item.TotalBytes);
        Assert.True(snapshots.Last().IsVerified);
        var count = snapshots.Count;
        foreach (var callback in callbacks) { callback.Report(0); callback.Report(1); }
        Assert.Equal(count, snapshots.Count);
        Assert.True(snapshots.Last().IsVerified);
        Assert.Equal(snapshots.Last().TotalBytes, snapshots.Last().DownloadedBytes);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task BadHashOrSignedFeedNeverBecomesVerifiedOrInstallable(bool badFeed)
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var snapshots = new List<UpdateSnapshot>();
        if (badFeed) fixture.ChangeFeed(fullName: "not-the-signed-package.nupkg");
        else
        {
            var full = fixture.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
            fixture.Files[full.Name][0] ^= 1;
        }
        using var http = new HttpClient(new Handler(request => FixtureResponse(request, fixture)));
        using var coordinator = new UpdateCoordinator(root.Path, "0.3.0", () => UpdateTests.Settings(NetworkMode.External), () => "synthetic",
            () => false, fixture.Verifier, new GitHubUpdateSource(http), new NoRelay());
        coordinator.Changed += snapshots.Add;
        await coordinator.CheckAsync();
        Assert.Contains(snapshots, item => item.Download is { IsVerifying: true });
        Assert.DoesNotContain(snapshots, item => item.Download is { IsVerified: true });
        Assert.DoesNotContain(snapshots, item => item.CanInstall);
        Assert.Null(coordinator.Snapshot.Download);
        Assert.Null(coordinator.GetCandidateForInstall());
    }

    [Fact]
    public async Task CoordinatorPublishesRealAggregateBeforeItEnablesInstall()
    {
        using var fixture = new UpdateFixture();
        using var root = new TemporaryRoot();
        var snapshots = new List<UpdateSnapshot>();
        using var http = new HttpClient(new Handler(request => FixtureResponse(request, fixture)));
        using var coordinator = new UpdateCoordinator(root.Path, "0.3.0", () => UpdateTests.Settings(NetworkMode.External), () => "synthetic",
            () => false, fixture.Verifier, new GitHubUpdateSource(http), new NoRelay());
        coordinator.Changed += snapshots.Add;
        await coordinator.CheckAsync();
        Assert.Contains(snapshots, item => item.Download is { Fraction: > 0 and < 1 } && !item.CanInstall);
        Assert.All(snapshots.Where(item => item.Download is { IsVerified: false }), item => Assert.False(item.CanInstall));
        Assert.True(coordinator.Snapshot.CanInstall);
        Assert.True(coordinator.Snapshot.Download!.IsVerified);
        Assert.Equal(100, coordinator.Snapshot.Download.Percent);
        Assert.Equal(fixture.Manifest.WindowsUpdateAssets.Sum(x => x.Size), coordinator.Snapshot.Download.DownloadedBytes);
    }

    [Fact]
    public async Task ExistingCandidateIsDisabledDuringMetadataAndUntilNewVerifiedCacheIsCommitted()
    {
        using var first = new UpdateFixture("9.8.7");
        using var next = new UpdateFixture("9.8.8");
        using var root = new TemporaryRoot();
        // Both manifests use the same publisher key; only their version and packages differ.
        var nextSigned = first.Sign(next.Manifest);
        var source = new SwitchingSource(first);
        var snapshots = new List<UpdateSnapshot>();
        using var coordinator = new UpdateCoordinator(root.Path, "0.3.0", () => UpdateTests.Settings(NetworkMode.External), () => "synthetic",
            () => false, first.Verifier, source, new NoRelay());
        coordinator.Changed += snapshots.Add;
        await coordinator.CheckAsync();
        Assert.True(coordinator.Snapshot.CanInstall);
        source.Next = new RemoteUpdateRelease("v" + next.Manifest.Version, nextSigned.Bytes, nextSigned.Signature);
        source.Files = next.Files;
        source.HoldMetadata = true;
        snapshots.Clear();
        var operation = coordinator.CheckAsync();
        Assert.False(operation.IsCompleted);
        Assert.False(coordinator.Snapshot.CanInstall);
        Assert.Null(coordinator.GetCandidateForInstall());
        source.ReleaseMetadata.TrySetResult();
        await operation;
        Assert.Contains(snapshots, item => item.Download is { IsVerified: true } && item.CandidateVersion == "9.8.7" && !item.CanInstall);
        Assert.DoesNotContain(snapshots, item => item.Download is { IsVerified: true } && item.CandidateVersion == "9.8.7" && item.CanInstall);
        Assert.Equal("9.8.8", coordinator.Snapshot.CandidateVersion);
        Assert.True(coordinator.Snapshot.CanInstall);
    }

    [Fact]
    public void LiveLanguageSwitchKeepsSameBytesAndPercent()
    {
        var previous = Localization.CurrentLanguage;
        try
        {
            var progress = new UpdateDownloadProgress(256 * 1024, 1024 * 1024, "signed-package.nupkg");
            Localization.Configure("zh-Hans");
            Assert.Equal("已下载 25% · 256.0 KB / 1.0 MB", progress.Summary);
            Localization.Configure("en");
            Assert.Equal("Downloaded 25% · 256.0 KB / 1.0 MB", progress.Summary);
            Assert.Equal(25, progress.Percent);
            Assert.Equal(256 * 1024, progress.DownloadedBytes);
        }
        finally { Localization.Configure(previous); }
    }

    private static HttpResponseMessage FixtureResponse(HttpRequestMessage request, UpdateFixture fixture)
    {
        if (request.RequestUri!.Host == "api.github.com")
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(new
            {
                draft = false, prerelease = false, tag_name = "v" + fixture.Manifest.Version,
                assets = new[] { new { name = UpdateManifestVerifier.ManifestName }, new { name = UpdateManifestVerifier.SignatureName } }
            })) };
        var name = Path.GetFileName(request.RequestUri.AbsolutePath);
        var bytes = name == UpdateManifestVerifier.ManifestName ? fixture.Bytes : name == UpdateManifestVerifier.SignatureName ? fixture.Signature : fixture.Files[name];
        return Response(bytes, 3);
    }
    private static HttpResponseMessage Response(byte[] bytes, int chunk) => new(HttpStatusCode.OK)
    { Content = new StreamContent(new ChunkedStream(bytes, chunk)) };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => Task.FromResult(response(request));
    }
    private sealed class Capture<T>(Action<T> capture) : IProgress<T>
    {
        public void Report(T value) => capture(value);
    }
    private sealed class NoRelay : IUpdateRelay
    {
        public Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token) => Task.CompletedTask;
        public Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion, AppSettings settings, string password, CancellationToken token) => Task.FromResult<VerifiedUpdate?>(null);
    }
    private sealed class SwitchingSource(UpdateFixture first) : IUpdateSource
    {
        public RemoteUpdateRelease? Next;
        public Dictionary<string, byte[]> Files = first.Files;
        public bool HoldMetadata;
        public TaskCompletionSource ReleaseMetadata { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token)
        {
            if (HoldMetadata) await ReleaseMetadata.Task.WaitAsync(token);
            return Next ?? new RemoteUpdateRelease("v" + first.Manifest.Version, first.Bytes, first.Signature);
        }
        public Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token) =>
            File.WriteAllBytesAsync(destination, Files[asset.Name], token);
        public async Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token, IProgress<long>? progress)
        {
            var bytes = Files[asset.Name];
            await File.WriteAllBytesAsync(destination, bytes, token);
            progress?.Report(bytes.Length);
        }
    }
    private sealed class ChunkedStream(byte[] bytes, int chunk) : Stream
    {
        private int _position;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => bytes.Length;
        public override long Position { get => _position; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count)
        {
            var length = Math.Min(Math.Min(count, chunk), bytes.Length - _position);
            bytes.AsSpan(_position, length).CopyTo(buffer.AsSpan(offset, length)); _position += length; return length;
        }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            token.ThrowIfCancellationRequested();
            var length = Math.Min(Math.Min(buffer.Length, chunk), bytes.Length - _position);
            bytes.AsMemory(_position, length).CopyTo(buffer); _position += length; return ValueTask.FromResult(length);
        }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
