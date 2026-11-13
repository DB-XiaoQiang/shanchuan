using Shanchuan.Core;
using Shanchuan.Windows.Services;

namespace Shanchuan.Windows.ViewModels;

public sealed partial class AppViewModel
{
    private readonly SemaphoreSlim _updateTransferGate = new(1, 1);
    private volatile bool _updateInstallationPaused;

    public AppUpdateService Updates { get; private set; } = null!;
    public SemaphoreSlim UpdateTransferGate => _updateTransferGate;
    public bool IsUpdateInstallationPaused => _updateInstallationPaused;
    public bool HasBusinessTransfers
    {
        get
        {
            lock (_queueSync)
            lock (_receiveSync)
                return _queue.Count > 0 || _currentTransferCts is not null || _receiveCycleCts is not null || _connectionTestCts is not null ||
                       Volatile.Read(ref _copyCaptureInProgress) != 0;
        }
    }

    private int _copyCaptureInProgress;
    public void SetCopyCaptureInProgress(bool active) => Interlocked.Exchange(ref _copyCaptureInProgress, active ? 1 : 0);

    public void InitializeUpdates(string root)
    {
        Updates = new AppUpdateService(this, root);
        OnPropertyChanged(nameof(Updates));
    }

    public string ReadUpdatePassword() => _password;

    // Held across the transition to installation so no receive cycle or send can
    // start after the idle test. The FTP semaphore remains held by the installer.
    public bool TryPauseForUpdateInstallation()
    {
        lock (_queueSync)
        lock (_receiveSync)
        {
            if (_queue.Count > 0 || _currentTransferCts is not null || _receiveCycleCts is not null || _connectionTestCts is not null ||
                Volatile.Read(ref _copyCaptureInProgress) != 0) return false;
            _updateInstallationPaused = true;
        }
        OnUi(() => OnPropertyChanged(nameof(CanSend)));
        return true;
    }

    public void ResumeAfterUpdateFailure()
    {
        _updateInstallationPaused = false;
        OnUi(() => OnPropertyChanged(nameof(CanSend)));
        SignalReceiver();
    }

    public void ReportUpdateMessage(string message, bool error = false) => OnUi(() =>
        AddLog(error ? TransferLogLevel.Warning : TransferLogLevel.Info, L.T("应用更新：") + Sanitize(message)));
}
