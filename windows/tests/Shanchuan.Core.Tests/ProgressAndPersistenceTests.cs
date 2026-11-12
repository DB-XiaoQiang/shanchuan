using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed class ProgressAndPersistenceTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "shanchuan-store-tests-" + Guid.NewGuid().ToString("N"));
    public ProgressAndPersistenceTests() => Directory.CreateDirectory(_root);
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }

    [Fact]
    public void ByteProgressIsWeightedMonotonicAndIncludesAllFiles()
    {
        var progress = new TransferByteProgress([100, 20]);
        var first = progress.Update(0, 0.5);
        Assert.Equal(50, first.UploadedBytes);
        Assert.Equal(120, first.TotalBytes);
        Assert.True(first.Fraction > 0.4 && first.Fraction < 0.42);

        var second = progress.Update(1, 0.5);
        Assert.Equal(60, second.UploadedBytes);
        Assert.True(second.Fraction > first.Fraction);
        var done = progress.Update(0, 1);
        Assert.True(done.Fraction < 1);
        done = progress.Update(1, 1);
        Assert.Equal(1, done.Fraction);
        Assert.Equal(120, done.UploadedBytes);
    }

    [Fact]
    public void EmptyFilesOnlyCompleteAfterExplicitCallbacks()
    {
        var progress = new TransferByteProgress([0, 0]);
        Assert.Equal(0, progress.Update(0, 0).Fraction);
        Assert.Equal(0, progress.Update(0, 1).Fraction);
        Assert.Equal(1, progress.Update(1, 1).Fraction);
    }

    [Fact]
    public void SettingsRoundTripAndNeverContainPassword()
    {
        var store = new SettingsStore(_root);
        var settings = new AppSettings
        {
            Host = "127.0.0.1",
            Username = "tester",
            Directory = "/研发中心",
            NetworkMode = NetworkMode.Internal,
            ReceiveDirectory = _root,
            ReceiveIntervalSeconds = 7
        };
        store.Save(settings);
        var json = File.ReadAllText(Path.Combine(_root, "settings.json"));
        Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
        var loaded = store.Load();
        Assert.Equal(settings.Host, loaded.Host);
        Assert.Equal(settings.Directory, loaded.Directory);
        Assert.Equal(NetworkMode.Internal, loaded.NetworkMode);
        Assert.Equal(_root, loaded.ReceiveDirectory);
        Assert.Equal(7, loaded.ReceiveIntervalSeconds);
        Assert.Equal(21, loaded.Port);
    }

    [Fact]
    public void HistoryAndLogsPersistWithLimitsAndRetention()
    {
        var history = new HistoryStore(_root);
        var now = DateTimeOffset.Now;
        history.Save([
            new HistoryEntry { Kind = HistoryKind.Text, Content = "new", Date = now },
            new HistoryEntry { Kind = HistoryKind.Text, Content = "old", Date = now.AddDays(-100) }
        ]);
        Assert.Single(history.Prune(history.Load(), 90, now));

        var logs = new TransferLogStore(_root, 2);
        logs.Save([
            new TransferLogEntry { Message = "one" },
            new TransferLogEntry { Message = "two" },
            new TransferLogEntry { Message = "three" }
        ]);
        Assert.Equal(["one", "two"], logs.Load().Select(item => item.Message));
    }

    [Fact]
    public void ShortcutDefaultsAreValidAndNativeCopyIsReserved()
    {
        var options = new ShortcutOptions();
        Assert.Null(options.Validate());
        options.Copy = new ShortcutBinding(0x43, HotkeyModifiers.Control);
        Assert.NotNull(options.Validate());
        options.Paste = options.Copy;
        Assert.NotNull(options.Validate());
    }
}
