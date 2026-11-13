using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using Shanchuan.Core;
using Shanchuan.Windows.Services;
using Application = System.Windows.Application;

namespace Shanchuan.Windows.ViewModels;

public sealed class HistoryRow(HistoryEntry entry, bool privacyMode) : ObservableObject
{
    public HistoryEntry Entry { get; } = entry;
    public string Title => privacyMode ? L.T("内容已隐藏（隐私模式）") : Entry.Title;
    public string Date => Entry.Date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
    public string Kind => Entry.Kind switch
    {
        HistoryKind.Text => L.T("文本"),
        HistoryKind.Image => L.T("图片"),
        _ => L.T("文件")
    };
    public string Status => L.T(Entry.Status);
    public void RefreshLanguage()
    {
        foreach (var name in new[] { nameof(Title), nameof(Date), nameof(Kind), nameof(Status) }) OnPropertyChanged(name);
    }
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
    private LocalizedText _statusMessage = L.M("就绪");
    private LocalizedText _hotkeyStatus = L.M("全局快捷键尚未初始化");
    private LocalizedText _settingsStatus = L.M("修改后自动保存");
    private LocalizedText _connectionTestStatus = "";
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
        _autosaveTimer.Tick += (_, _) =>
        {
            _autosaveTimer.Stop();
            if (CanAutosaveDraft?.Invoke() == false)
                SettingsText = L.M("配置尚未保存：请修正标红的输入值后再离开此页面。");
            else SaveSettingsNow();
        };
        ResendCommand = new RelayCommand(_ => ResendSelected(), _ => SelectedHistory is not null);
        DeleteCommand = new RelayCommand(_ => DeleteSelected(), _ => SelectedHistory is not null);
        CancelCommand = new RelayCommand(_ => CancelTransfers(), _ => Progress.IsActive || QueuedCount > 0);
        RefreshHistory();
        SaveHistoryAndMedia();
        L.LanguageChanged += OnLanguageChanged;
    }

    public AppSettings Settings { get; }
    public Func<bool>? CanAutosaveDraft { get; set; }
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

    public string StatusMessage => _statusMessage.ToString();
    private LocalizedText StatusText { get => _statusMessage; set => SetProperty(ref _statusMessage, value, nameof(StatusMessage)); }
    public string HotkeyStatus => _hotkeyStatus.ToString();
    private LocalizedText HotkeyText { get => _hotkeyStatus; set => SetProperty(ref _hotkeyStatus, value, nameof(HotkeyStatus)); }
    public string SettingsStatus => _settingsStatus.ToString();
    private LocalizedText SettingsText { get => _settingsStatus; set => SetProperty(ref _settingsStatus, value, nameof(SettingsStatus)); }
    public string ConnectionTestStatus => _connectionTestStatus.ToString();
    private LocalizedText ConnectionTestText { get => _connectionTestStatus; set => SetProperty(ref _connectionTestStatus, value, nameof(ConnectionTestStatus)); }
    public string QueuedText => L.F($"等待 {QueuedCount} 项");
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
        SettingsText = L.M("正在等待自动保存…");
        _autosaveTimer.Stop();
        _autosaveTimer.Start();
    }

    public bool ChangeLanguage(string language)
    {
        Settings.Language = language;
        var saved = true;
        try
        {
            // Persist only the language in the last valid settings. Other
            // controls may contain a draft or invalid numeric input; do not
            // flush them, touch credentials, restart FTP or register hotkeys.
            var persisted = _settingsStore.Load();
            persisted.Language = Settings.Language;
            _settingsStore.Save(persisted);
        }
        catch (Exception error)
        {
            saved = false;
            SettingsText = L.M("语言保存失败：") + SanitizeError(error);
        }
        L.Configure(Settings.Language);
        return saved;
    }

    private void OnLanguageChanged() => OnUi(() =>
    {
        foreach (var name in new[] { nameof(StatusMessage), nameof(HotkeyStatus), nameof(SettingsStatus),
            nameof(ConnectionTestStatus), nameof(QueuedText), nameof(NetworkStatus), nameof(ReceiveStatus) })
            OnPropertyChanged(name);
        foreach (var row in HistoryRows) row.RefreshLanguage();
    });

    public string GetPasswordForEditing() => _password;

    public void PasswordEdited(string password)
    {
        _password = password;
        SettingsEdited();
    }

    public void ReportHotkeysReady()
    {
        HotkeyText = Settings.Shortcuts.Enabled
            ? L.MF($"全局快捷键已启用 · 发送 {Settings.Shortcuts.Copy.DisplayName} · 粘贴 {Settings.Shortcuts.Paste.DisplayName}")
            : L.M("全局快捷键已停用");
    }

    public void ReportHotkeyError(LocalizedText message)
    {
        HotkeyText = L.M("快捷键不可用：") + message;
        StatusText = HotkeyText;
        AddLog(TransferLogLevel.Error, HotkeyStatus);
    }

    public void ReportCopyStarted()
    {
        StatusText = L.M("复制快捷键已触发，正在等待前方应用产生新的复制内容…");
        AddLog(TransferLogLevel.Info, L.T("复制快捷键已触发，开始模拟 Ctrl+C 并捕获新剪贴板。"));
    }

    public void ReportCopyCaptured(HistoryKind kind)
    {
        var name = kind switch { HistoryKind.Text => L.M("文本"), HistoryKind.Image => L.M("图片"), _ => L.M("文件") };
        StatusText = L.MF($"已捕获新的剪贴板{name}，正在加入发送队列…");
        AddLog(TransferLogLevel.Info, L.F($"已捕获新的剪贴板{name}，准备加入发送队列。"));
    }

    public void ReportActionError(LocalizedText message)
    {
        StatusText = message;
        AddLog(TransferLogLevel.Error, message);
    }

    public bool SaveSettingsNow()
    {
        _autosaveTimer.Stop();
        if (Settings.ValidateForStorage() is { } validationError)
        {
            SettingsText = LocalizedText.Live(() => Settings.ValidateForStorage() ?? "");
            return false;
        }
        try
        {
            _settingsStore.Save(Settings);
            if (_password.Length == 0) _credentialStore.Delete();
            else _credentialStore.Save(_password);
            OnNetworkSettingsSaved();
            SettingsApplied?.Invoke(this, EventArgs.Empty);
            SettingsText = L.M("已自动保存 · ") + DateTime.Now.ToString("HH:mm:ss");
            StatusText = L.M("配置已保存 · ") + LocalizedText.Live(() => NetworkStatus);
            return true;
        }
        catch (Exception error)
        {
            SettingsText = L.M("保存失败：") + SanitizeError(error);
            return false;
        }
    }

    public async Task TestConnectionAsync()
    {
        if (IsTestingConnection || _updateInstallationPaused) return;
        IsTestingConnection = true;
        ConnectionTestText = L.M("正在测试连接和目录访问…");
        _connectionTestCts = new CancellationTokenSource();
        try
        {
            await _updateTransferGate.WaitAsync(_connectionTestCts.Token);
            try { await _ftp.TestConnectionAsync(Settings.Clone(), _password, _connectionTestCts.Token); }
            finally { _updateTransferGate.Release(); }
            ConnectionTestText = L.M("连接成功，账号登录和目标目录访问正常。未上传文件。");
        }
        catch (TimeoutException) { ConnectionTestText = L.M("连接超时，请检查服务器地址、端口和网络。"); }
        catch (OperationCanceledException) { ConnectionTestText = L.M("连接测试已停止。"); }
        catch (Exception error) { ConnectionTestText = L.M("连接失败：") + SanitizeError(error); }
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
        if (entry.Status is "等待发送" or "准备中" or "上传中") { StatusText = L.M("该记录正在传输，请先取消。"); return; }
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
        catch (Exception error) { StatusText = L.M("历史保存失败：") + SanitizeError(error); }
    }

    private void SaveLogs()
    {
        try { _logStore.Save(Logs); }
        catch (Exception error) { StatusText = L.M("日志保存失败：") + SanitizeError(error); }
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

    private LocalizedText SanitizeError(Exception error) => LocalizedText.Live(() => Sanitize(L.Describe(error)));

    private string Sanitize(string message)
    {
        if (_password.Length > 0) message = message.Replace(_password, L.T("[已隐藏]"), StringComparison.Ordinal);
        return message;
    }

    public void Dispose()
    {
        L.LanguageChanged -= OnLanguageChanged;
        Updates?.Dispose();
        CancelTransfers();
        _lifetimeCts.Cancel();
        lock (_receiveSync) _receiveCycleCts?.Cancel();
        _signal.Release();
        SignalReceiver();
        _connectionTestCts?.Cancel();
    }
}
