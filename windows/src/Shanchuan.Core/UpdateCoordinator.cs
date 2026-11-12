using System.Security.Cryptography;
using System.Text;

namespace Shanchuan.Core;

public sealed class UpdateState
{
    public string? LastSuccessfulWindow { get; set; }
    public DateTimeOffset? LastCheckedAt { get; set; }
    public int CheckFailures { get; set; }
    public DateTimeOffset? NextCheckAttemptUtc { get; set; }
    public int RelayFailures { get; set; }
    public DateTimeOffset? NextRelayAttemptUtc { get; set; }
    public string? HighestSeenVersion { get; set; }
    public string? CandidateCacheDirectory { get; set; }
    public string? RelayedKey { get; set; }
}

public sealed record UpdateSnapshot(string CurrentVersion, string? CandidateVersion, string Status,
    string RelayStatus, bool IsWorking, bool CanInstall, string ReleaseNotes);

public static class UpdateSchedule
{
    public static DateTimeOffset LatestWindow(DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var local = TimeZoneInfo.ConvertTime(now, zone);
        var date = DateTime.SpecifyKind(local.Date.AddHours(1), DateTimeKind.Unspecified);
        if (local.DateTime < date) date = date.AddDays(-1);
        while (zone.IsInvalidTime(date)) date = date.AddMinutes(1);
        return new DateTimeOffset(date, zone.GetUtcOffset(date));
    }
    public static TimeSpan Backoff(int failures) => TimeSpan.FromMinutes(failures switch { <= 1 => 1, 2 => 5, 3 => 15, _ => 60 });
    public static string WindowKey(DateTimeOffset now, TimeZoneInfo? zone = null) => LatestWindow(now, zone).ToString("O");
}

/// <summary>Coordinates background acquisition only. Installation always belongs to an explicit UI authorization.</summary>
public sealed class UpdateCoordinator : IDisposable
{
    private readonly string _currentVersion;
    private readonly Func<AppSettings> _getSettings;
    private readonly Func<string> _getPassword;
    private readonly Func<bool> _businessBusy;
    private readonly Func<DateTimeOffset> _clock;
    private readonly UpdateManifestVerifier _verifier;
    private readonly IUpdateSource _source;
    private readonly IUpdateRelay _relay;
    private readonly UpdateCache _cache;
    private readonly string _statePath;
    private readonly SemaphoreSlim _serial = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private VerifiedUpdate? _candidate;
    private DateTimeOffset? _lastInternalPoll;
    private bool _loaded;
    private bool _disposed;
    private string _status = "等待检查更新";
    private string _relayStatus = "";

    public UpdateCoordinator(string root, string currentVersion, Func<AppSettings> getSettings, Func<string> getPassword,
        Func<bool> isBusy, UpdateManifestVerifier? verifier = null, IUpdateSource? source = null,
        IUpdateRelay? transport = null, Func<DateTimeOffset>? clock = null, SemaphoreSlim? transferGate = null)
    {
        if (!UpdateManifestVerifier.IsVersion(currentVersion)) throw new ArgumentException("当前版本无效。", nameof(currentVersion));
        _currentVersion = currentVersion;
        _getSettings = getSettings;
        _getPassword = getPassword;
        _businessBusy = isBusy;
        _clock = clock ?? (() => DateTimeOffset.Now);
        _verifier = verifier ?? UpdateManifestVerifier.CreateDefault();
        _source = source ?? new GitHubUpdateSource();
        _relay = transport ?? new FtpUpdateTransport(isBusy, transferGate);
        _cache = new UpdateCache(Path.Combine(root, "Updates", "Cache"), _verifier);
        _statePath = Path.Combine(root, "Updates", "update-state.json");
        try { State = File.Exists(_statePath) ? JsonFileStore.Read<UpdateState>(_statePath) : new UpdateState(); }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        { State = new UpdateState(); _status = "更新状态无法读取，将重新检查"; }
        Snapshot = new UpdateSnapshot(_currentVersion, null, _status, "", false, false, "");
    }

    public UpdateState State { get; }
    public UpdateSnapshot Snapshot { get; private set; }
    public bool IsBusy => Snapshot.IsWorking;
    public event Action<UpdateSnapshot>? Changed;
    public event Action<string>? Log;
    public Task CheckAsync(CancellationToken cancellationToken = default) => TickAsync(true, cancellationToken);
    public Task RetryAsync(CancellationToken cancellationToken = default) => TickAsync(true, cancellationToken);

    public async Task TickAsync(bool manual = false, CancellationToken cancellationToken = default)
    {
        if (_disposed || !await _serial.WaitAsync(0, cancellationToken)) return;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token, cancellationToken);
        var token = linked.Token;
        try
        {
            if (!_loaded)
            {
                _loaded = true;
                if (State.CandidateCacheDirectory is { } directory)
                {
                    try
                    {
                        _candidate = await _cache.LoadAsync(directory, token).ConfigureAwait(false);
                        if (UpdateManifestVerifier.CompareVersions(_candidate.Manifest.Version, _currentVersion) < 0) _candidate = null;
                        _status = _candidate is null ? "当前已是最新版本" : ReadyStatus();
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    { State.CandidateCacheDirectory = null; _status = "更新缓存校验失败，请重试"; }
                }
                Publish(false);
            }
            var settings = _getSettings().Clone();
            var password = _getPassword();
            var now = _clock();
            if (settings.NetworkMode == NetworkMode.Unconfigured)
            {
                _status = "请先选择网络位置";
                Publish(false);
                return;
            }
            if (_businessBusy() && !manual) return;
            if (settings.NetworkMode == NetworkMode.Internal)
            {
                if (!manual && ((_lastInternalPoll is { } poll && now - poll < TimeSpan.FromSeconds(Math.Max(2, settings.ReceiveIntervalSeconds))) ||
                    State.NextCheckAttemptUtc > now)) return;
                _lastInternalPoll = now;
                await ReceiveInternalAsync(settings, password, now, token).ConfigureAwait(false);
            }
            else
            {
                var window = UpdateSchedule.WindowKey(now);
                if (manual || (State.LastSuccessfulWindow != window && (State.NextCheckAttemptUtc is null || State.NextCheckAttemptUtc <= now)))
                    await CheckExternalAsync(window, settings, password, now, token).ConfigureAwait(false);
                if (_candidate is not null && (manual || State.NextRelayAttemptUtc is null || State.NextRelayAttemptUtc <= now))
                    await RelayAsync(settings, password, now, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally { Publish(false); _serial.Release(); }
    }

    private async Task CheckExternalAsync(string window, AppSettings settings, string password, DateTimeOffset now, CancellationToken token)
    {
        _status = "检查中";
        Publish(true);
        try
        {
            var release = await _source.GetLatestAsync(token).ConfigureAwait(false);
            if (release is not null)
            {
                var manifest = _verifier.Verify(release.ManifestBytes, release.Signature);
                if (release.Tag != "v" + manifest.Version) throw new InvalidDataException("GitHub 标签与签名版本不匹配。");
                RequireNotOlder(manifest.Version);
                _status = "下载中";
                Publish(true);
                _candidate = await _cache.ImportAsync(release.ManifestBytes, release.Signature,
                    (asset, destination, ct) => _source.DownloadAssetAsync(release.Tag, asset, destination, ct), token).ConfigureAwait(false);
                AcceptCandidate(_candidate);
                _status = ReadyStatus();
            }
            else _status = _candidate is null ? "当前无正式更新" : ReadyStatus();
            State.LastSuccessfulWindow = window;
            CheckSucceeded(now);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            _status = "检查失败：" + SafeError(error, settings, password);
            CheckFailed(now);
            Log?.Invoke(_status);
        }
    }

    private async Task ReceiveInternalAsync(AppSettings settings, string password, DateTimeOffset now, CancellationToken token)
    {
        _status = "检查中";
        Publish(true);
        try
        {
            var minimum = _candidate?.Manifest.Version ?? _currentVersion;
            var candidate = await _relay.ReceiveAsync(_cache, _verifier, minimum, settings, password, token).ConfigureAwait(false);
            if (candidate is not null)
            {
                RequireNotOlder(candidate.Manifest.Version);
                _candidate = candidate;
                AcceptCandidate(candidate);
            }
            _status = _candidate is null ? "当前无内网更新" : ReadyStatus();
            _relayStatus = "更新来自 FTP，只读接收";
            CheckSucceeded(now);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            _status = "检查失败：" + SafeError(error, settings, password);
            CheckFailed(now);
            Log?.Invoke(_status);
        }
    }

    private async Task RelayAsync(AppSettings settings, string password, DateTimeOffset now, CancellationToken token)
    {
        var candidate = _candidate!;
        var endpoint = settings.Host.Trim() + "|" + settings.Port + "|" + settings.Username + "|" + settings.Directory;
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(endpoint))) + ":" + candidate.ManifestHash;
        if (State.RelayedKey == key) { _relayStatus = "已投递更新包"; return; }
        _relayStatus = "等待转发";
        Publish(true);
        try
        {
            if (settings.ValidateForTransfer() is { } error) throw new InvalidDataException(error);
            _candidate = candidate = await _cache.LoadAsync(candidate.CacheDirectory, token).ConfigureAwait(false);
            _relayStatus = "转发中";
            Publish(true);
            await _relay.RelayAsync(candidate, settings, password, token).ConfigureAwait(false);
            State.RelayedKey = key;
            State.RelayFailures = 0;
            State.NextRelayAttemptUtc = null;
            _relayStatus = "已投递更新包";
            Save();
            Log?.Invoke("已将 Windows 更新包投递 FTP，版本 " + candidate.Manifest.Version + "；不表示内网已安装。");
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            _relayStatus = "转发失败：" + SafeError(error, settings, password);
            State.RelayFailures = Math.Min(State.RelayFailures + 1, 4);
            State.NextRelayAttemptUtc = now + UpdateSchedule.Backoff(State.RelayFailures);
            Save();
            Log?.Invoke(_relayStatus);
        }
    }

    public VerifiedUpdate? GetCandidateForInstall()
    {
        var path = _candidate?.CacheDirectory ?? State.CandidateCacheDirectory;
        if (path is null) return null;
        var verified = Task.Run(() => _cache.LoadAsync(path)).GetAwaiter().GetResult();
        if (UpdateManifestVerifier.CompareVersions(verified.Manifest.Version, _currentVersion) <= 0) return null;
        RequireNotOlder(verified.Manifest.Version);
        _candidate = verified;
        return verified;
    }

    private void AcceptCandidate(VerifiedUpdate candidate)
    {
        State.CandidateCacheDirectory = candidate.CacheDirectory;
        State.HighestSeenVersion = candidate.Manifest.Version;
        Save();
    }
    private void RequireNotOlder(string version)
    {
        if (UpdateManifestVerifier.CompareVersions(version, _currentVersion) < 0 ||
            (UpdateManifestVerifier.IsVersion(State.HighestSeenVersion) && UpdateManifestVerifier.CompareVersions(version, State.HighestSeenVersion!) < 0))
            throw new InvalidDataException("拒绝旧版本回放或降级。");
    }
    private string ReadyStatus() => _candidate is not null && UpdateManifestVerifier.CompareVersions(_candidate.Manifest.Version, _currentVersion) > 0 ? "可安装" : "当前已是最新版本";
    private void CheckSucceeded(DateTimeOffset now)
    {
        State.LastCheckedAt = now;
        State.CheckFailures = 0;
        State.NextCheckAttemptUtc = null;
        Save();
    }
    private void CheckFailed(DateTimeOffset now)
    {
        State.LastCheckedAt = now;
        State.CheckFailures = Math.Min(State.CheckFailures + 1, 4);
        State.NextCheckAttemptUtc = now + UpdateSchedule.Backoff(State.CheckFailures);
        Save();
    }
    private void Save() => JsonFileStore.Write(_statePath, State);
    private void Publish(bool working)
    {
        Snapshot = new UpdateSnapshot(_currentVersion, _candidate?.Manifest.Version, _status, _relayStatus, working,
            _candidate is not null && UpdateManifestVerifier.CompareVersions(_candidate.Manifest.Version, _currentVersion) > 0,
            _candidate?.Manifest.ReleaseNotes ?? "");
        if (!_disposed) Changed?.Invoke(Snapshot);
    }
    private static string SafeError(Exception error, AppSettings settings, string password)
    {
        var text = error.Message;
        if (!string.IsNullOrEmpty(password)) text = text.Replace(password, "***", StringComparison.Ordinal);
        if (!string.IsNullOrEmpty(settings.Username)) text = text.Replace(settings.Username, "***", StringComparison.Ordinal);
        return text.Replace('\r', ' ').Replace('\n', ' ');
    }
    public void Dispose() { _disposed = true; _lifetime.Cancel(); }
}
