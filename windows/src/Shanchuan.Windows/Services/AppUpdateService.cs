using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;
using Velopack;
using Velopack.Locators;
using MessageBox = Shanchuan.Windows.LocalizedMessageBox;

namespace Shanchuan.Windows.Services;

/// <summary>
/// Application update state is separate from the clipboard and transfer history.
/// Downloading a verified cache is never permission to install it.
/// </summary>
public sealed class AppUpdateService : ObservableObject, IDisposable
{
    private readonly AppViewModel _owner;
    private readonly UpdateCoordinator _coordinator;
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _timer;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly string _authorizationPath;
    private UpdateSnapshot _snapshot;
    private UpdateInstallAuthorization? _authorized;
    private CancellationTokenSource? _currentTick;
    private bool _ticking;
    private bool _installing;
    private bool _requesting;
    private bool _disposed;
    private string? _installationStatus;
    private bool _manualChecking;
    private DateTimeOffset? _lastManualCheckAt;
    private string _lastManualCheckResult = "";

    public static string InstalledVersion =>
        (Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
         ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0").Split('+')[0];

    public AppUpdateService(AppViewModel owner, string root) : this(owner, root, null) { }

    public AppUpdateService(AppViewModel owner, string root, UpdateCoordinator? coordinator)
    {
        _owner = owner;
        _dispatcher = System.Windows.Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        _authorizationPath = Path.Combine(root, "Updates", "install-authorization.json");
        _coordinator = coordinator ?? new UpdateCoordinator(root, InstalledVersion,
            () => owner.Settings.Clone(), owner.ReadUpdatePassword, () => owner.HasBusinessTransfers,
            transferGate: owner.UpdateTransferGate);
        _snapshot = _coordinator.Snapshot;
        _coordinator.Changed += OnCoordinatorChanged;
        _timer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += OnTick;
    }

    public string CurrentVersion => "v" + InstalledVersion;
    public string CurrentVersionText => L.F($"当前版本 {CurrentVersion}");
    public string? CandidateVersion => _snapshot.CandidateVersion;
    public string Status => _installationStatus ?? (_manualChecking ? L.T("正在检查更新…") :
        !_coordinator.IsBusy && (_snapshot.Status == L.T("检查中") || _snapshot.Status == L.T("下载中")) ? L.T("等待检查更新") : _snapshot.Status);
    public string LastCheckedText => _manualChecking ? L.T("正在手动检查更新…") :
        _lastManualCheckAt is { } checkedAt
            ? L.F($"手动检查完成 {checkedAt:yyyy-MM-dd HH:mm:ss}\n{_lastManualCheckResult}")
            : L.T("尚未手动检查");
    public string CheckButtonText => _manualChecking ? L.T("正在检查…") : L.T("检查更新 / 重试");
    public string DownloadPageUrl => "https://github.com/DB-XiaoQiang/shanchuan/releases";
    public RelayCommand OpenDownloadsCommand => _openDownloadsCommand ??= new RelayCommand(_ => OpenDownloads(), _ => !_disposed);
    private RelayCommand? _openDownloadsCommand;
    public string RelayStatus => _snapshot.RelayStatus;
    public string ReleaseNotes => _snapshot.ReleaseNotes;
    public bool CanCheck => !_disposed && !_ticking && !_requesting && !_installing && !_coordinator.IsBusy && _authorized is null;
    public bool CanInstall => !_disposed && _snapshot.CanInstall && !_requesting && !_ticking && !_coordinator.IsBusy && !_installing && _authorized is null;
    public string InstallButtonText => CandidateVersion is { Length: > 0 } version ? L.F($"更新至 v{version}") : L.T("更新");
    public Visibility InstallButtonVisibility => _snapshot.CanInstall ? Visibility.Visible : Visibility.Collapsed;

    public void Start()
    {
        if (_disposed) return;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        _owner.SettingsApplied += OnSettingsApplied;
        _timer.Start();
        _ = TickAsync();
    }

    // Called only after the App has acquired its single-instance mutex, and
    // before clipboard/FTP workers are started. No authorization means no apply.
    public void RestoreAuthorizedInstallAtStartup()
    {
        if (!File.Exists(_authorizationPath)) return;
        try
        {
            var authorization = JsonSerializer.Deserialize<UpdateInstallAuthorization>(File.ReadAllText(_authorizationPath))
                ?? throw new InvalidDataException(L.T("更新安装授权为空。"));
            if (Version.TryParse(InstalledVersion, out var installed) &&
                Version.TryParse(authorization.Version, out var target) && target <= installed)
            {
                ClearAuthorization();
                return;
            }
            var candidate = _coordinator.GetCandidateForInstall();
            RequireAuthorizedCandidate(candidate, authorization);
            _authorized = authorization;
            var manager = new UpdateManager();
            if (manager.IsInstalled && manager.UpdatePendingRestart is { } pending)
            {
                RequireMatchingPackage(candidate!, pending);
                VerifyManagedPackage(candidate!, pending);
                manager.ApplyUpdatesAndRestart(pending);
            }
            _installationStatus = L.F($"已确认 v{authorization.Version}，等待传输完成后安装");
        }
        catch (Exception error)
        {
            ClearAuthorization();
            _installationStatus = L.T("已暂停上次更新，请重新确认");
            _owner.ReportUpdateMessage(L.T("上次安装授权未能恢复：") + error.Message, error: true);
        }
        NotifyState();
    }

    public Task CheckAsync() => CanCheck ? TickAsync(manual: true) : Task.CompletedTask;
    public Task RetryAsync() => CheckAsync();

    private void OpenDownloads()
    {
        try { Process.Start(new ProcessStartInfo(DownloadPageUrl) { UseShellExecute = true }); }
        catch (Exception error)
        {
            var message = L.T("无法打开下载页：") + ReadableError(error);
            SetInstallationStatus(message);
            _owner.ReportUpdateMessage(message, error: true);
        }
    }

    public async Task RequestInstallAsync(Window owner)
    {
        if (_installing || _requesting || _ticking || _authorized is not null || _disposed) return;
        _requesting = true;
        NotifyState();
        try
        {
            var candidate = await Task.Run(_coordinator.GetCandidateForInstall, _lifetime.Token);
            if (candidate is null) { SetInstallationStatus(L.T("没有已验证的待安装更新")); return; }
            var manager = new UpdateManager();
            if (!manager.IsInstalled)
            {
                MessageBox.Show(owner, L.T("请先使用正式 Release 中的 Setup 安装版安装闪传，再使用应用内更新。"), L.T("安装更新"));
                return;
            }
            var notes = candidate.Manifest.ReleaseNotes;
            if (notes.Length > 6000) notes = notes[..6000] + "…";
            var busy = _owner.HasBusinessTransfers || _coordinator.IsBusy;
            var message = L.F($"当前版本：v{InstalledVersion}\n目标版本：v{candidate.Manifest.Version}\n\n{notes}\n\n") +
                (busy ? L.T("确认后等待传输完成，再安装并重新启动闪传。") : L.T("是否安装此版本并重新启动闪传？")) +
                L.T("\n选择“稍后”则稍后更新，已下载的更新包会保留。");
            if (!LocalizedMessageBox.ConfirmUpdate(owner, message, L.T("闪传更新"))) return;
            // A candidate may have changed while the confirmation dialog was open.
            var fresh = await Task.Run(_coordinator.GetCandidateForInstall, _lifetime.Token);
            var authorization = new UpdateInstallAuthorization(candidate.Manifest.Version, candidate.ManifestHash);
            RequireAuthorizedCandidate(fresh, authorization);
            SaveAuthorization(authorization);
            _authorized = authorization;
            SetInstallationStatus(L.F($"已确认 v{authorization.Version}，等待传输完成后安装"));
            await TryInstallAsync();
        }
        catch (Exception error)
        {
            ClearAuthorization();
            SetInstallationStatus(L.T("安装更新失败，请重试"));
            _owner.ReportUpdateMessage(error.Message, error: true);
        }
        finally { _requesting = false; NotifyState(); }
    }

    private async void OnTick(object? sender, EventArgs e) => await TickAsync();
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume && !_disposed)
            _dispatcher.BeginInvoke(new Action(() => _ = TickAsync()));
    }
    private void OnSettingsApplied(object? sender, EventArgs e)
    {
        if (_disposed) return;
        // Stop an old-mode/old-endpoint transfer; the next tick snapshots the
        // newly saved network policy and credentials before doing any work.
        if (!_installing) _currentTick?.Cancel();
        _ = TickAsync();
    }

    private async Task TickAsync(bool manual = false)
    {
        if (_disposed || _ticking || _requesting || _installing || (manual && _authorized is not null)) return;
        _ticking = true;
        if (manual)
        {
            _manualChecking = true;
            _installationStatus = null;
        }
        string? manualResult = null;
        using var tick = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _currentTick = tick;
        NotifyState();
        try
        {
            if (_authorized is not null) await TryInstallAsync();
            else
            {
                await _coordinator.TickAsync(manual, tick.Token);
            }
        }
        catch (OperationCanceledException) when (tick.IsCancellationRequested)
        {
            manualResult = L.T("检查已取消，请重试。");
        }
        catch (Exception error)
        {
            manualResult = L.T("检查失败：") + ReadableError(error);
            SetInstallationStatus(manualResult);
            _owner.ReportUpdateMessage(manualResult, error: true);
        }
        finally
        {
            if (manual)
            {
                _manualChecking = false;
                _lastManualCheckAt = DateTimeOffset.Now;
                _lastManualCheckResult = manualResult ?? (tick.IsCancellationRequested
                    ? L.T("检查已取消，请重试。") : DescribeManualResult(_coordinator.Snapshot));
            }
            _currentTick = null;
            _ticking = false;
            NotifyState();
        }
    }

    private static string DescribeManualResult(UpdateSnapshot snapshot)
    {
        if (snapshot.Status == L.T("当前无正式更新"))
            return L.T("暂无正式更新；测试版请点“下载测试版”手动下载安装。");
        if (snapshot.Status == L.T("当前无内网更新"))
            return L.T("FTP 中暂无可用的正式更新。");
        if (snapshot.Status == L.T("请先选择网络位置"))
            return L.T("检查未执行，请先在配置中心选择内网或外网。");
        if (snapshot.CanInstall && snapshot.CandidateVersion is { } version)
            return L.F($"发现已验证版本 v{version}，可点击更新。");
        return snapshot.Status;
    }

    private string ReadableError(Exception error)
    {
        var message = error.Message;
        var password = _owner.ReadUpdatePassword();
        if (!string.IsNullOrEmpty(password)) message = message.Replace(password, "***", StringComparison.Ordinal);
        if (!string.IsNullOrEmpty(_owner.Settings.Username)) message = message.Replace(_owner.Settings.Username, "***", StringComparison.Ordinal);
        return message.Replace('\r', ' ').Replace('\n', ' ');
    }

    private async Task TryInstallAsync()
    {
        if (_authorized is null || _installing || _coordinator.IsBusy || _owner.HasBusinessTransfers) return;
        if (!await _owner.UpdateTransferGate.WaitAsync(0, _lifetime.Token)) return;
        var paused = false;
        try
        {
            if (_coordinator.IsBusy || !_owner.TryPauseForUpdateInstallation()) return;
            paused = true;
            _installing = true;
            NotifyState();
            var candidate = await Task.Run(_coordinator.GetCandidateForInstall, _lifetime.Token);
            RequireAuthorizedCandidate(candidate, _authorized);
            var manager = new UpdateManager(candidate!.CacheDirectory,
                new UpdateOptions { ExplicitChannel = "win-x64" });
            if (!manager.IsInstalled) throw new InvalidOperationException(L.T("当前不是可更新的 Setup 安装版本。"));
            var update = await manager.CheckForUpdatesAsync();
            if (update is null) throw new InvalidOperationException(L.T("已确认版本不再是可安装的新版本，请重新检查。"));
            RequireMatchingPackage(candidate, update.TargetFullRelease);
            SetInstallationStatus(L.T("正在准备安装，请稍候…"));
            await manager.DownloadUpdatesAsync(update, cancelToken: _lifetime.Token);
            // Verify the managed copy too, immediately before handing off execution.
            VerifyManagedPackage(candidate, update.TargetFullRelease);
            if (!_owner.SaveSettingsNow()) throw new InvalidOperationException(L.T("配置尚未保存，请先修正配置再安装更新。"));
            SetInstallationStatus(L.T("正在安装并重新启动…"));
            manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception error)
        {
            ClearAuthorization();
            SetInstallationStatus(L.T("安装更新失败，请重试"));
            _owner.ReportUpdateMessage(error.Message, error: true);
        }
        finally
        {
            _installing = false;
            if (paused) _owner.ResumeAfterUpdateFailure();
            _owner.UpdateTransferGate.Release();
            NotifyState();
        }
    }

    private static void RequireAuthorizedCandidate(VerifiedUpdate? candidate, UpdateInstallAuthorization authorization)
    {
        if (candidate is null || !UpdateInstallAuthorizationPolicy.AllowsInstallation(authorization, InstalledVersion,
            candidate.Manifest.Version, candidate.ManifestHash))
            throw new InvalidDataException(L.T("待安装版本或签名清单已经变化，请重新确认。"));
    }

    private static void RequireMatchingPackage(VerifiedUpdate candidate, VelopackAsset package)
    {
        var full = candidate.Manifest.Assets.Single(x => x.Platform == "windows" && x.Arch == "x64" && x.Kind == "velopack-full");
        if (package.Version.ToString() != candidate.Manifest.Version || package.FileName != full.Name ||
            package.Size != full.Size || !string.Equals(package.SHA256, full.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException(L.T("安装器选择的更新包与已签名发行清单不一致。"));
    }

    private static void VerifyManagedPackage(VerifiedUpdate candidate, VelopackAsset package)
    {
        RequireMatchingPackage(candidate, package);
        var full = candidate.Manifest.Assets.Single(x => x.Platform == "windows" && x.Arch == "x64" && x.Kind == "velopack-full");
        var packages = VelopackLocator.Current.PackagesDir ?? throw new InvalidOperationException(L.T("无法确定更新安装缓存目录。"));
        var path = Path.Combine(packages, full.Name);
        using var stream = File.OpenRead(path);
        if (stream.Length != full.Size || !string.Equals(Convert.ToHexString(SHA256.HashData(stream)), full.Sha256,
            StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException(L.T("已暂存的安装包验证失败，已阻止安装。"));
    }

    private void SaveAuthorization(UpdateInstallAuthorization authorization)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_authorizationPath)!);
        var temporary = _authorizationPath + ".tmp";
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 4096,
            FileOptions.WriteThrough))
        {
            JsonSerializer.Serialize(stream, authorization);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, _authorizationPath, overwrite: true);
    }

    private void ClearAuthorization()
    {
        _authorized = null;
        try { File.Delete(_authorizationPath); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void OnCoordinatorChanged(UpdateSnapshot snapshot)
    {
        if (_disposed) return;
        _dispatcher.BeginInvoke(new Action(() =>
        {
            if (_disposed) return;
            var old = _snapshot;
            _snapshot = snapshot;
            NotifyState();
            if (old.Status != snapshot.Status || old.RelayStatus != snapshot.RelayStatus)
                _owner.ReportUpdateMessage(snapshot.Status + (string.IsNullOrEmpty(snapshot.RelayStatus) ? "" : "；" + snapshot.RelayStatus));
        }));
    }

    private void SetInstallationStatus(string status)
    {
        _installationStatus = status;
        NotifyState();
    }

    private void NotifyState()
    {
        if (_disposed) return;
        if (!_dispatcher.CheckAccess()) { _dispatcher.BeginInvoke(new Action(NotifyState)); return; }
        foreach (var property in new[] { nameof(CurrentVersion), nameof(CandidateVersion), nameof(Status), nameof(RelayStatus),
            nameof(LastCheckedText), nameof(CheckButtonText),
            nameof(ReleaseNotes), nameof(CanCheck), nameof(CanInstall), nameof(InstallButtonText), nameof(InstallButtonVisibility) })
            OnPropertyChanged(property);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        _timer.Tick -= OnTick;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _owner.SettingsApplied -= OnSettingsApplied;
        _coordinator.Changed -= OnCoordinatorChanged;
        _lifetime.Cancel();
        _coordinator.Dispose();
    }
}
