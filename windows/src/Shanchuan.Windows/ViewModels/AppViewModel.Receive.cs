using Shanchuan.Core;

namespace Shanchuan.Windows.ViewModels;

public sealed partial class AppViewModel
{
    private readonly SemaphoreSlim _receiveSignal = new(0, 1);
    private readonly object _receiveSync = new();
    private NetworkMode _savedNetworkMode;
    private LocalizedText _receiveStatus = "";
    private CancellationTokenSource? _receiveCycleCts;
    private Task? _receiveWorker;

    public string NetworkStatus => NetworkPolicy.DisplayName(Settings.NetworkMode);
    public string ReceiveStatus => _receiveStatus.ToString();
    private LocalizedText ReceiveText { get => _receiveStatus; set => SetProperty(ref _receiveStatus, value, nameof(ReceiveStatus)); }
    public bool CanSend => Settings.NetworkMode == NetworkMode.External && !_updateInstallationPaused;

    private static LocalizedText IdleReceiveStatus(NetworkMode mode) => mode switch
    {
        NetworkMode.Internal => L.M("内网 · 等待检查外网投递"),
        NetworkMode.External => L.M("外网 · 接收已禁用，禁止下载和删除"),
        _ => L.M("未设置 · 发送和接收均已禁用")
    };

    private void StartReceiver()
    {
        if (_receiveWorker is null) _receiveWorker = Task.Run(ReceiveLoopAsync);
        SignalReceiver();
    }

    private void OnNetworkSettingsSaved()
    {
        var modeChanged = _savedNetworkMode != Settings.NetworkMode;
        _savedNetworkMode = Settings.NetworkMode;
        OnPropertyChanged(nameof(NetworkStatus));
        OnPropertyChanged(nameof(CanSend));
        if (modeChanged)
        {
            lock (_receiveSync) _receiveCycleCts?.Cancel();
            if (Settings.NetworkMode != NetworkMode.External) CancelTransfers();
        }
        ReceiveText = IdleReceiveStatus(Settings.NetworkMode);
        SignalReceiver();
    }

    private void SignalReceiver()
    {
        if (_receiveSignal.CurrentCount == 0) _receiveSignal.Release();
    }

    private async Task ReceiveLoopAsync()
    {
        while (!_lifetimeCts.IsCancellationRequested)
        {
            var settings = Settings.Clone();
            if (_updateInstallationPaused)
            {
                try { await Task.Delay(500, _lifetimeCts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }
            if (settings.NetworkMode != NetworkMode.Internal)
            {
                OnUi(() => ReceiveText = IdleReceiveStatus(settings.NetworkMode));
                try { await _receiveSignal.WaitAsync(_lifetimeCts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            using var current = CancellationTokenSource.CreateLinkedTokenSource(_lifetimeCts.Token);
            lock (_receiveSync)
            {
                if (_updateInstallationPaused) continue;
                _receiveCycleCts = current;
            }
            try
            {
                if (settings.ValidateForTransfer() is { } validationError)
                {
                    OnUi(() => ReceiveText = L.M("内网 · 配置不完整：") + LocalizedText.Live(() => settings.ValidateForTransfer() ?? ""));
                }
                else
                {
                    OnUi(() => ReceiveText = L.M("内网 · 正在检查外网投递…"));
                    await _updateTransferGate.WaitAsync(current.Token).ConfigureAwait(false);
                    ReceiveBatchResult result;
                    try
                    {
                        result = await _receiver.ReceivePendingAsync(settings, _password, current.Token).ConfigureAwait(false);
                    }
                    finally { _updateTransferGate.Release(); }
                    OnUi(() => ApplyReceiveResult(result));
                }
            }
            catch (OperationCanceledException) when (current.IsCancellationRequested)
            {
                if (!_lifetimeCts.IsCancellationRequested)
                    OnUi(() => ReceiveText = IdleReceiveStatus(Settings.NetworkMode));
            }
            catch (Exception error)
            {
                var reason = SanitizeError(error);
                OnUi(() =>
                {
                    ReceiveText = L.M("内网 · 检查失败：") + reason;
                    StatusText = L.M("接收检查失败：") + reason;
                    AddLog(TransferLogLevel.Error, L.T("接收检查失败：") + reason);
                });
            }
            finally
            {
                lock (_receiveSync)
                {
                    if (ReferenceEquals(_receiveCycleCts, current)) _receiveCycleCts = null;
                }
            }

            if (_lifetimeCts.IsCancellationRequested) return;
            try
            {
                await _receiveSignal.WaitAsync(TimeSpan.FromSeconds(Math.Clamp(settings.ReceiveIntervalSeconds, 2, 3600)),
                    _lifetimeCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
        }
    }

    private void ApplyReceiveResult(ReceiveBatchResult result)
    {
        var clipboardFailed = false;
        foreach (var entry in result.Received)
        {
            _history.Insert(0, entry);
            AddLog(TransferLogLevel.Success, L.T("接收成功：") + entry.Title);
            try { ClipboardRestoreRequested?.Invoke(this, entry); }
            catch (Exception error)
            {
                clipboardFailed = true;
                AddLog(TransferLogLevel.Warning, L.T("已接收并保存，但写入 Windows 剪贴板失败：") +
                    entry.Title + "；" + SanitizeError(error));
            }
        }
        if (result.Received.Count > 0)
        {
            RefreshHistory();
            SaveHistoryAndMedia();
            StatusText = clipboardFailed
                ? L.MF($"已接收 {result.Received.Count} 项，但部分剪贴板写入失败；请查看传输日志。")
                : L.MF($"已接收 {result.Received.Count} 项，内容已写入剪贴板。");
        }

        foreach (var failure in result.Failures)
            AddLog(TransferLogLevel.Error, L.F($"接收失败：{failure.ControlName}；{Sanitize(failure.Reason)}；远端数据已保留。"));
        foreach (var warning in result.Warnings)
            AddLog(TransferLogLevel.Warning, Sanitize(warning));

        LocalizedText detail = result.Received.Count > 0 ? L.MF($"接收 {result.Received.Count} 项") :
            result.DiscoveredCount > 0 ? L.M("未发现新的待接收内容") : L.M("暂无外网投递");
        if (result.Failures.Count > 0) detail += L.MF($"，失败 {result.Failures.Count} 项");
        if (result.Warnings.Count > 0) detail += L.MF($"，清理警告 {result.Warnings.Count} 条");
        ReceiveText = L.MF($"内网 · 最近检查 {DateTime.Now:HH:mm:ss} · {detail}");
        if (result.Failures.Count > 0 && result.Received.Count == 0)
            StatusText = L.M("接收失败，远端数据已保留；请查看传输日志。");
    }
}
