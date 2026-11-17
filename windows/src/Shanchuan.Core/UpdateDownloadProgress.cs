namespace Shanchuan.Core;

/// <summary>Actual available package bytes, separate from verification and installation authorization.</summary>
public sealed record UpdateDownloadProgress(long DownloadedBytes, long TotalBytes, string CurrentAsset,
    bool IsVerifying = false, bool IsVerified = false)
{
    public double Fraction => TotalBytes > 0 ? Math.Clamp((double)DownloadedBytes / TotalBytes, 0, 1) : 0;
    public double Percent => Fraction * 100;
    public string BytesText => L.F($"{FormatBytes(DownloadedBytes)} / {FormatBytes(TotalBytes)}");
    public string Summary => L.F($"已下载 {Math.Floor(Percent):0}% · {FormatBytes(DownloadedBytes)} / {FormatBytes(TotalBytes)}");
    public static string FormatBytes(long count)
    {
        var value = Math.Max(0, count);
        if (value < 1024) return L.F($"{value} B");
        if (value < 1024L * 1024) return L.F($"{value / 1024d:0.0} KB");
        if (value < 1024L * 1024 * 1024) return L.F($"{value / (1024d * 1024):0.0} MB");
        return L.F($"{value / (1024d * 1024 * 1024):0.0} GB");
    }
}

internal sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
{
    public void Report(T value) => report(value);
}

internal sealed class UpdateDownloadTracker(IReadOnlyList<UpdateAsset> assets, IProgress<UpdateDownloadProgress>? progress)
{
    private readonly long[] _received = new long[assets.Count];
    private readonly long _total = assets.Sum(asset => asset.Size);
    private readonly object _sync = new();
    private long _lastNotification;
    private int _currentIndex = -1;
    private bool _hasPublished;
    private bool _verifying;
    private bool _completed;

    public void Report(int index, long count, bool verifying = false)
    {
        lock (_sync)
        {
            // A delayed transport callback must never undo verified completion
            // or switch the UI back to a previous file/verification stage.
            if (_completed || index < _currentIndex) return;
            var switchedFile = index != _currentIndex;
            var completedFile = false;
            var changedBytes = false;
            if (index >= 0 && index < assets.Count)
            {
                var previous = _received[index];
                _received[index] = Math.Max(previous, Math.Clamp(count, 0, assets[index].Size));
                completedFile = previous < assets[index].Size && _received[index] == assets[index].Size;
                changedBytes = previous != _received[index];
            }
            var changedStage = verifying && !_verifying;
            if (switchedFile) { _currentIndex = index; _verifying = verifying; }
            else if (verifying) _verifying = true;
            var force = !_hasPublished || switchedFile || changedStage || completedFile;
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!force && (!changedBytes || now - _lastNotification < System.Diagnostics.Stopwatch.Frequency / 10)) return;
            _lastNotification = now;
            _hasPublished = true;
            progress?.Report(new UpdateDownloadProgress(_received.Sum(), _total,
                index >= 0 && index < assets.Count ? assets[index].Name : "", _verifying));
        }
    }
    public void Complete()
    {
        lock (_sync)
        {
            if (_completed) return;
            _completed = true;
            for (var index = 0; index < assets.Count; index++) _received[index] = assets[index].Size;
            progress?.Report(new UpdateDownloadProgress(_total, _total, "", IsVerified: true));
        }
    }
}
