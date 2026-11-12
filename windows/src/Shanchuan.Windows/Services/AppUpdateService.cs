using System.IO;
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
using MessageBox = System.Windows.MessageBox;

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

    public static string InstalledVersion =>
        (Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
         ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0").Split('+')[0];

    public AppUpdateService(AppViewModel owner, string root)
    {
        _owner = owner;
        _dispatcher = System.Windows.Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        _authorizationPath = Path.Combine(root, "Updates", "install-authorization.json");
        _coordinator = new UpdateCoordinator(root, InstalledVersion,
            () => owner.Settings.Clone(), owner.ReadUpdatePassword, () => owner.HasBusinessTransfers,
            transferGate: owner.UpdateTransferGate);
        _snapshot = _coordinator.Snapshot;
        _coordinator.Changed += OnCoordinatorChanged;
        _timer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += OnTick;
    }

    public string CurrentVersion => "v" + InstalledVersion;
    public string? CandidateVersion => _snapshot.CandidateVersion;
    public string Status => _installationStatus ?? _snapshot.Status;
    public string RelayStatus => _snapshot.RelayStatus;
    public string ReleaseNotes => _snapshot.ReleaseNotes;
    public bool CanCheck => !_ticking && !_requesting && !_installing && _authorized is null;
    public bool CanInstall => _snapshot.CanInstall && !_requesting && !_ticking && !_coordinator.IsBusy && !_installing && _authorized is null;
    public string InstallButtonText => CandidateVersion is { Length: > 0 } version ? $"更新至 v{version}" : "更新";
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
                ?? throw new InvalidDataException("更新安装授权为空。");
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
            _installationStatus = $"已确认 v{authorization.Version}，等待传输完成后安装";
        }
        catch (Exception error)
        {
            ClearAuthorization();
            _installationStatus = "已暂停上次更新，请重新确认";
            _owner.ReportUpdateMessage("上次安装授权未能恢复：" + error.Message, error: true);
        }
        NotifyState();
    }

    public Task CheckAsync() => TickAsync(manual: true);
    public Task RetryAsync() => TickAsync(manual: true);

    public async Task RequestInstallAsync(Window owner)
    {
        if (_installing || _requesting || _ticking || _authorized is not null || _disposed) return;
        _requesting = true;
        NotifyState();
        try
        {
            var candidate = await Task.Run(_coordinator.GetCandidateForInstall, _lifetime.Token);
            if (candidate is null) { SetInstallationStatus("没有已验证的待安装更新"); return; }
            var manager = new UpdateManager();
            if (!manager.IsInstalled)
            {
                MessageBox.Show(owner, "请先使用正式 Release 中的 Setup 安装版安装闪传，再使用应用内更新。", "安装更新");
                return;
            }
            var notes = candidate.Manifest.ReleaseNotes;
            if (notes.Length > 6000) notes = notes[..6000] + "…";
            var busy = _owner.HasBusinessTransfers || _coordinator.IsBusy;
            var message = $"当前版本：v{InstalledVersion}\n目标版本：v{candidate.Manifest.Version}\n\n{notes}\n\n" +
                (busy ? "确认后等待传输完成，再安装并重新启动闪传。" : "是否安装此版本并重新启动闪传？") +
                "\n选择“否”则稍后更新，已下载的更新包会保留。";
            if (MessageBox.Show(owner, message, "闪传更新", MessageBoxButton.YesNo, MessageBoxImage.Question,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
            // A candidate may have changed while the confirmation dialog was open.
            var fresh = await Task.Run(_coordinator.GetCandidateForInstall, _lifetime.Token);
            var authorization = new UpdateInstallAuthorization(candidate.Manifest.Version, candidate.ManifestHash);
            RequireAuthorizedCandidate(fresh, authorization);
            SaveAuthorization(authorization);
            _authorized = authorization;
            SetInstallationStatus($"已确认 v{authorization.Version}，等待传输完成后安装");
            await TryInstallAsync();
        }
        catch (Exception error)
        {
            ClearAuthorization();
            SetInstallationStatus("安装更新失败，请重试");
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
        if (_disposed || _ticking || _requesting || _installing) return;
        _ticking = true;
        using var tick = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _currentTick = tick;
        NotifyState();
        try
        {
            if (_authorized is not null) await TryInstallAsync();
            else
            {
                if (manual) _installationStatus = null;
                await _coordinator.TickAsync(manual, tick.Token);
            }
        }
        catch (OperationCanceledException) when (tick.IsCancellationRequested) { }
        catch (Exception error)
        {
            SetInstallationStatus("检查更新失败，点击重试");
            _owner.ReportUpdateMessage(error.Message, error: true);
        }
        finally { _currentTick = null; _ticking = false; NotifyState(); }
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
            if (!manager.IsInstalled) throw new InvalidOperationException("当前不是可更新的 Setup 安装版本。");
            var update = await manager.CheckForUpdatesAsync();
            if (update is null) throw new InvalidOperationException("已确认版本不再是可安装的新版本，请重新检查。");
            RequireMatchingPackage(candidate, update.TargetFullRelease);
            SetInstallationStatus("正在准备安装，请稍候…");
            await manager.DownloadUpdatesAsync(update, cancelToken: _lifetime.Token);
            // Verify the managed copy too, immediately before handing off execution.
            VerifyManagedPackage(candidate, update.TargetFullRelease);
            if (!_owner.SaveSettingsNow()) throw new InvalidOperationException("配置尚未保存，请先修正配置再安装更新。");
            SetInstallationStatus("正在安装并重新启动…");
            manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception error)
        {
            ClearAuthorization();
            SetInstallationStatus("安装更新失败，请重试");
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
            throw new InvalidDataException("待安装版本或签名清单已经变化，请重新确认。");
    }

    private static void RequireMatchingPackage(VerifiedUpdate candidate, VelopackAsset package)
    {
        var full = candidate.Manifest.Assets.Single(x => x.Platform == "windows" && x.Arch == "x64" && x.Kind == "velopack-full");
        if (package.Version.ToString() != candidate.Manifest.Version || package.FileName != full.Name ||
            package.Size != full.Size || !string.Equals(package.SHA256, full.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("安装器选择的更新包与已签名发行清单不一致。");
    }

    private static void VerifyManagedPackage(VerifiedUpdate candidate, VelopackAsset package)
    {
        RequireMatchingPackage(candidate, package);
        var full = candidate.Manifest.Assets.Single(x => x.Platform == "windows" && x.Arch == "x64" && x.Kind == "velopack-full");
        var packages = VelopackLocator.Current.PackagesDir ?? throw new InvalidOperationException("无法确定更新安装缓存目录。");
        var path = Path.Combine(packages, full.Name);
        using var stream = File.OpenRead(path);
        if (stream.Length != full.Size || !string.Equals(Convert.ToHexString(SHA256.HashData(stream)), full.Sha256,
            StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("已暂存的安装包验证失败，已阻止安装。");
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
