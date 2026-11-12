using System.IO;
using System.Windows;
using System.Windows.Interop;
using Shanchuan.Core;
using Shanchuan.Windows.Services;
using Shanchuan.Windows.ViewModels;
using MessageBox = System.Windows.MessageBox;

namespace Shanchuan.Windows;

public partial class App : System.Windows.Application
{
    private const string MutexName = @"Local\Shanchuan.Windows.7A4C0E6D";
    private Mutex? _mutex;
    private bool _ownsMutex;
    private AppViewModel? _viewModel;
    private MainWindow? _mainWindow;
    private ProgressWindow? _progressWindow;
    private GlobalHotkeyService? _hotkeys;
    private TrayIconService? _tray;
    private HistoryStore? _historyStore;
    private bool _hotkeysInitialized;
    private int _copyInProgress;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _mutex = new Mutex(true, MutexName, out _ownsMutex);
        if (!_ownsMutex)
        {
            MessageBox.Show("闪传已经在运行，请通过任务栏托盘打开。", "闪传",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        var root = AppDataPaths.DefaultRoot;
        Directory.CreateDirectory(root);
        var settingsStore = new SettingsStore(root);
        _historyStore = new HistoryStore(root);
        var logStore = new TransferLogStore(root);
        var credentials = new WindowsCredentialStore();
        var startupErrors = new List<string>();

        var settings = Load("配置", () => settingsStore.Load(), new AppSettings(), startupErrors);
        var password = Load("FTP 密码", () => credentials.Read() ?? "", "", startupErrors);
        var history = Load("历史记录", () => _historyStore.Load(), new List<HistoryEntry>(), startupErrors);
        var logs = Load("传输日志", logStore.Load, new List<TransferLogEntry>(), startupErrors);

        _viewModel = new AppViewModel(settings, password, settingsStore, _historyStore, logStore,
            credentials, new FtpTransferService(), new FtpReceiveService(new ReceiveStateStore(root)), history, logs);
        _hotkeys = new GlobalHotkeyService();
        _hotkeys.CopyRequested += OnCopyRequested;
        _hotkeys.PasteRequested += OnPasteRequested;
        _viewModel.SettingsApplied += OnSettingsApplied;
        _viewModel.ClipboardRestoreRequested += (_, entry) => ClipboardService.Restore(entry);

        _mainWindow = new MainWindow(_viewModel);
        _mainWindow.SourceInitialized += (_, _) => InitializeHotkeys();
        MainWindow = _mainWindow;
        _progressWindow = new ProgressWindow(_viewModel);
        _tray = new TrayIconService(ShowMainWindow, ExitApplication);
        _mainWindow.Show();
        _viewModel.Start();

        if (startupErrors.Count > 0)
            MessageBox.Show(string.Join("\n", startupErrors), "部分本机数据未能读取",
                MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private static T Load<T>(string name, Func<T> load, T fallback, List<string> errors)
    {
        try { return load(); }
        catch (Exception error)
        {
            errors.Add($"{name}：{error.Message}");
            return fallback;
        }
    }

    private void InitializeHotkeys()
    {
        if (_hotkeysInitialized || _hotkeys is null || _mainWindow is null || _viewModel is null) return;
        _hotkeysInitialized = true;
        try
        {
            _hotkeys.Initialize(new WindowInteropHelper(_mainWindow).Handle);
            _hotkeys.Update(_viewModel.Settings.Shortcuts);
            _viewModel.ReportHotkeysReady();
        }
        catch (Exception error) { _viewModel.ReportHotkeyError(error.Message); }
    }

    private void OnSettingsApplied(object? sender, EventArgs e)
    {
        if (_viewModel is null) return;
        try
        {
            _hotkeys?.Update(_viewModel.Settings.Shortcuts);
            _viewModel.ReportHotkeysReady();
        }
        catch (Exception error) { _viewModel.ReportHotkeyError(error.Message); }
        try { WindowsStartupService.Apply(_viewModel.Settings.StartWithWindows); }
        catch (Exception error) { _viewModel.ReportActionError("登录启动设置失败：" + error.Message); }
        _progressWindow?.ApplyPreferences();
    }

    private async void OnCopyRequested(object? sender, ShortcutBinding binding)
    {
        if (_viewModel is null || _historyStore is null) return;
        if (!_viewModel.CanSend)
        {
            _viewModel.ReportActionError("当前不是外网（只发送）模式，已阻止复制上传。请检查配置中心的网络位置。");
            return;
        }
        if (Interlocked.CompareExchange(ref _copyInProgress, 1, 0) != 0)
        {
            _viewModel.ReportActionError("上一次复制内容仍在捕获中，请稍候再按快捷键。");
            return;
        }
        try
        {
            _viewModel.ReportCopyStarted();
            var captured = await ClipboardService.CopyAndCaptureAsync(() => _historyStore.NewImagePath());
            _viewModel.ReportCopyCaptured(captured.Kind);
            switch (captured.Kind)
            {
                case HistoryKind.Text: _viewModel.EnqueueText(captured.Text); break;
                case HistoryKind.Image when captured.Paths.Count > 0: _viewModel.EnqueueImage(captured.Paths[0]); break;
                case HistoryKind.File: _viewModel.EnqueuePaths(captured.Paths); break;
            }
        }
        catch (Exception error) { _viewModel.ReportActionError("复制捕获失败：" + error.Message); }
        finally { Interlocked.Exchange(ref _copyInProgress, 0); }
    }

    private async void OnPasteRequested(object? sender, ShortcutBinding binding)
    {
        if (_viewModel is null) return;
        try
        {
            await SendInputService.WaitForModifiersReleasedAsync();
            await SendInputService.SendPasteAsync();
        }
        catch (Exception error) { _viewModel.ReportActionError("粘贴失败：" + error.Message); }
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
        _mainWindow.Topmost = true;
        _mainWindow.Topmost = false;
        _mainWindow.Focus();
    }

    private void ExitApplication()
    {
        _viewModel?.SaveSettingsNow();
        if (_mainWindow is not null)
        {
            _mainWindow.AllowClose = true;
            _mainWindow.Close();
        }
        _progressWindow?.CloseForShutdown();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkeys?.Dispose();
        _tray?.Dispose();
        _viewModel?.Dispose();
        if (_ownsMutex) _mutex?.ReleaseMutex();
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
