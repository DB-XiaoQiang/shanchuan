using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using Shanchuan.Core;
using Shanchuan.Windows.Services;
using Application = System.Windows.Application;

namespace Shanchuan.Windows.ViewModels;

public sealed class HistoryRow(HistoryEntry entry, bool privacyMode)
{
    public HistoryEntry Entry { get; } = entry;
    public string Title => privacyMode ? "内容已隐藏（隐私模式）" : Entry.Title;
    public string Date => Entry.Date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
    public string Kind => Entry.Kind switch
    {
        HistoryKind.Text => "文本",
        HistoryKind.Image => "图片",
        _ => "文件"
    };
    public string Status => Entry.Status;
}

public sealed partial class AppViewModel : ObservableObject, IDisposable
{
    private readonly SettingsStore _settingsStore;
    private readonly HistoryStore _historyStore;
    private readonly TransferLogStore _logStore;
    private readonly ICredentialStore _credentialStore;
    private readonly FtpTransferService _ftp;
    private readonly FtpReceiveService _receiver;
    private readonly DispatcherTimer _autosaveTimer;
    private readonly List<HistoryEntry> _history;
    private string _password;
    private string _searchText = "";
    private string _kindFilter = "全部";
    private bool _privacyMode;
    private HistoryRow? _selectedHistory;
    private string _statusMessage = "就绪";
    private string _hotkeyStatus = "全局快捷键尚未初始化";
    private string _settingsStatus = "修改后自动保存";
    private string _connectionTestStatus = "";
    private bool _isTestingConnection;
    private TransferProgressSnapshot _progress = new();

    public AppViewModel(AppSettings settings, string password,
        SettingsStore settingsStore, HistoryStore historyStore, TransferLogStore logStore,
        ICredentialStore credentialStore, FtpTransferService ftp, FtpReceiveService receiver,
        IEnumerable<HistoryEntry> history, IEnumerable<TransferLogEntry> logs)
    {
        Settings = settings;
        _password = password;
        _settingsStore = settingsStore;
        _historyStore = historyStore;
        _logStore = logStore;
        _credentialStore = credentialStore;
        _ftp = ftp;
        _receiver = receiver;
        _savedNetworkMode = settings.NetworkMode;
        _receiveStatus = IdleReceiveStatus(settings.NetworkMode);
        _history = historyStore.Prune(history, settings.TtlDays).OrderByDescending(item => item.Date).ToList();
        Logs = new ObservableCollection<TransferLogEntry>(logs);
        HistoryRows = [];
        _autosaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _autosaveTimer.Tick += (_, _) => { _autosaveTimer.Stop(); SaveSettingsNow(); };
        ResendCommand = new RelayCommand(_ => ResendSelected(), _ => SelectedHistory is not null);
        DeleteCommand = new RelayCommand(_ => DeleteSelected(), _ => SelectedHistory is not null);
        CancelCommand = new RelayCommand(_ => CancelTransfers(), _ => Progress.IsActive || QueuedCount > 0);
        RefreshHistory();
        SaveHistoryAndMedia();
    }

    public AppSettings Settings { get; }
    public ObservableCollection<HistoryRow> HistoryRows { get; }
    public ObservableCollection<TransferLogEntry> Logs { get; }
    public RelayCommand ResendCommand { get; }
    public RelayCommand DeleteCommand { get; }
    public RelayCommand CancelCommand { get; }

    public event EventHandler? SettingsApplied;
    public event EventHandler<HistoryEntry>? ClipboardRestoreRequested;

    public TransferProgressSnapshot Progress
    {
        get => _progress;
        private set { SetProperty(ref _progress, value); RelayCommand.Refresh(); }
    }

    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public string HotkeyStatus { get => _hotkeyStatus; private set => SetProperty(ref _hotkeyStatus, value); }
    public string SettingsStatus { get => _settingsStatus; private set => SetProperty(ref _settingsStatus, value); }
    public string ConnectionTestStatus { get => _connectionTestStatus; private set => SetProperty(ref _connectionTestStatus, value); }
    public bool IsTestingConnection { get => _isTestingConnection; private set => SetProperty(ref _isTestingConnection, value); }

    public string SearchText
    {
        get => _searchText;
        set { if (SetProperty(ref _searchText, value)) RefreshHistory(); }
    }

    public string KindFilter
    {
        get => _kindFilter;
        set { if (SetProperty(ref _kindFilter, value)) RefreshHistory(); }
    }

    public bool PrivacyMode
    {
        get => _privacyMode;
        set { if (SetProperty(ref _privacyMode, value)) RefreshHistory(); }
    }

    public HistoryRow? SelectedHistory
    {
        get => _selectedHistory;
        set { SetProperty(ref _selectedHistory, value); RelayCommand.Refresh(); }
    }

    public void SettingsEdited()
    {
        SettingsStatus = "正在等待自动保存…";
        _autosaveTimer.Stop();
        _autosaveTimer.Start();
    }

    public string GetPasswordForEditing() => _password;

    public void PasswordEdited(string password)
    {
        _password = password;
        SettingsEdited();
    }

    public void ReportHotkeysReady()
    {
        HotkeyStatus = Settings.Shortcuts.Enabled
            ? $"全局快捷键已启用 · 发送 {Settings.Shortcuts.Copy.DisplayName} · 粘贴 {Settings.Shortcuts.Paste.DisplayName}"
            : "全局快捷键已停用";
    }

    public void ReportHotkeyError(string message)
    {
        HotkeyStatus = "快捷键不可用：" + message;
        StatusMessage = HotkeyStatus;
        AddLog(TransferLogLevel.Error, HotkeyStatus);
    }

    public void ReportCopyStarted()
    {
        StatusMessage = "复制快捷键已触发，正在等待前方应用产生新的复制内容…";
        AddLog(TransferLogLevel.Info, "复制快捷键已触发，开始模拟 Ctrl+C 并捕获新剪贴板。");
    }

    public void ReportCopyCaptured(HistoryKind kind)
    {
        var name = kind switch { HistoryKind.Text => "文本", HistoryKind.Image => "图片", _ => "文件" };
        StatusMessage = $"已捕获新的剪贴板{name}，正在加入发送队列…";
        AddLog(TransferLogLevel.Info, $"已捕获新的剪贴板{name}，准备加入发送队列。");
    }

    public void ReportActionError(string message)
    {
        StatusMessage = message;
        AddLog(TransferLogLevel.Error, message);
    }

    public bool SaveSettingsNow()
    {
        _autosaveTimer.Stop();
        if (Settings.ValidateForStorage() is { } validationError)
        {
            SettingsStatus = validationError;
            return false;
        }
        try
        {
            _settingsStore.Save(Settings);
            if (_password.Length == 0) _credentialStore.Delete();
            else _credentialStore.Save(_password);
            OnNetworkSettingsSaved();
            SettingsApplied?.Invoke(this, EventArgs.Empty);
            SettingsStatus = "已自动保存 · " + DateTime.Now.ToString("HH:mm:ss");
            StatusMessage = "配置已保存 · " + NetworkStatus;
            return true;
        }
        catch (Exception error)
        {
            SettingsStatus = "保存失败：" + Sanitize(error.Message);
            return false;
        }
    }

    public async Task TestConnectionAsync()
    {
        if (IsTestingConnection || _updateInstallationPaused) return;
        IsTestingConnection = true;
        ConnectionTestStatus = "正在测试连接和目录访问…";
        _connectionTestCts = new CancellationTokenSource();
        try
        {
            await _updateTransferGate.WaitAsync(_connectionTestCts.Token);
            try { await _ftp.TestConnectionAsync(Settings.Clone(), _password, _connectionTestCts.Token); }
            finally { _updateTransferGate.Release(); }
            ConnectionTestStatus = "连接成功，账号登录和目标目录访问正常。未上传文件。";
        }
        catch (TimeoutException) { ConnectionTestStatus = "连接超时，请检查服务器地址、端口和网络。"; }
        catch (OperationCanceledException) { ConnectionTestStatus = "连接测试已停止。"; }
        catch (Exception error) { ConnectionTestStatus = "连接失败：" + Sanitize(error.Message); }
        finally
        {
            _connectionTestCts.Dispose();
            _connectionTestCts = null;
            IsTestingConnection = false;
        }
    }

    public void RefreshHistory()
    {
        HistoryRows.Clear();
        var kind = KindFilter switch
        {
            "文本" => HistoryKind.Text,
            "图片" => HistoryKind.Image,
            "文件" => HistoryKind.File,
            _ => (HistoryKind?)null
        };
        foreach (var entry in _history.Where(item =>
                     (!kind.HasValue || item.Kind == kind.Value) &&
                     (SearchText.Length == 0 || item.Title.Contains(SearchText, StringComparison.OrdinalIgnoreCase))))
            HistoryRows.Add(new HistoryRow(entry, PrivacyMode));
    }

    public void DeleteSelected()
    {
        if (SelectedHistory is null) return;
        var entry = SelectedHistory.Entry;
        if (entry.Status is "等待发送" or "准备中" or "上传中") { StatusMessage = "该记录正在传输，请先取消。"; return; }
        _history.Remove(entry);
        SelectedHistory = null;
        RefreshHistory();
        SaveHistoryAndMedia();
    }

    public void ClearHistory()
    {
        _history.RemoveAll(entry => entry.Status is not ("等待发送" or "准备中" or "上传中"));
        RefreshHistory();
        SaveHistoryAndMedia();
    }

    public void ClearLogs()
    {
        Logs.Clear();
        SaveLogs();
    }

    private void ResendSelected()
    {
        if (SelectedHistory is null) return;
        var entry = SelectedHistory.Entry.CloneForResend();
        if (Settings.RestoreOnResend) ClipboardRestoreRequested?.Invoke(this, entry);
        Enqueue(entry);
    }

    private void SaveHistoryAndMedia()
    {
        try
        {
            _historyStore.Save(_history);
            _historyStore.RemoveUnreferencedMedia(_history);
        }
        catch (Exception error) { StatusMessage = "历史保存失败：" + Sanitize(error.Message); }
    }

    private void SaveLogs()
    {
        try { _logStore.Save(Logs); }
        catch (Exception error) { StatusMessage = "日志保存失败：" + Sanitize(error.Message); }
    }

    private void AddLog(TransferLogLevel level, string message)
    {
        Logs.Insert(0, new TransferLogEntry { Level = level, Message = message });
        while (Logs.Count > 1000) Logs.RemoveAt(Logs.Count - 1);
        SaveLogs();
    }

    private void OnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.Invoke(action);
    }

    private void PublishProgress(TransferProgressSnapshot snapshot)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) Progress = snapshot;
        else dispatcher.BeginInvoke(() => Progress = snapshot);
    }

    private string Sanitize(string message)
    {
        if (_password.Length > 0) message = message.Replace(_password, "[已隐藏]", StringComparison.Ordinal);
        return message;
    }

    public void Dispose()
    {
        Updates?.Dispose();
        CancelTransfers();
        _lifetimeCts.Cancel();
        lock (_receiveSync) _receiveCycleCts?.Cancel();
        _signal.Release();
        SignalReceiver();
        _connectionTestCts?.Cancel();
    }
}
