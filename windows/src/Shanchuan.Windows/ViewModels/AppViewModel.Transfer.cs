using System.IO;
using Shanchuan.Core;

namespace Shanchuan.Windows.ViewModels;

public sealed partial class AppViewModel
{
    private readonly object _queueSync = new();
    private readonly Queue<HistoryEntry> _queue = new();
    private readonly SemaphoreSlim _signal = new(0);
    private readonly CancellationTokenSource _lifetimeCts = new();
    private CancellationTokenSource? _connectionTestCts;
    private CancellationTokenSource? _currentTransferCts;
    private Task? _worker;
    private int _queuedCount;

    public int QueuedCount
    {
        get => _queuedCount;
        private set { SetProperty(ref _queuedCount, value); RelayCommand.Refresh(); }
    }

    public void Start()
    {
        if (_worker is null) _worker = Task.Run(ProcessQueueAsync);
        StartReceiver();
    }

    public void EnqueueText(string content)
    {
        if (string.IsNullOrEmpty(content)) { StatusMessage = "剪贴板中没有可发送的文本。"; return; }
        Enqueue(new HistoryEntry { Kind = HistoryKind.Text, Content = content, Status = "等待发送" });
    }

    public void EnqueueImage(string imagePath) =>
        Enqueue(new HistoryEntry { Kind = HistoryKind.Image, Paths = [imagePath], Status = "等待发送" });

    public void EnqueuePaths(IEnumerable<string> paths)
    {
        var items = paths.Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (items.Count == 0) { StatusMessage = "没有可发送的文件或文件夹。"; return; }
        Enqueue(new HistoryEntry { Kind = HistoryKind.File, Paths = items, Status = "等待发送" });
    }

    private void Enqueue(HistoryEntry entry)
    {
        try { NetworkPolicy.RequireUpload(Settings); }
        catch (InvalidOperationException error)
        {
            StatusMessage = error.Message;
            AddLog(TransferLogLevel.Warning, "已阻止发送：" + error.Message);
            return;
        }
        _history.Insert(0, entry);
        RefreshHistory();
        SaveHistoryAndMedia();
        lock (_queueSync) _queue.Enqueue(entry);
        QueuedCount = GetQueuedCount();
        _signal.Release();
        StatusMessage = "已加入发送队列：" + entry.Title;
        AddLog(TransferLogLevel.Info, "已加入发送队列：" + entry.Title);
    }

    private async Task ProcessQueueAsync()
    {
        while (true)
        {
            try
            {
                await _signal.WaitAsync(_lifetimeCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }

            HistoryEntry? entry;
            lock (_queueSync) entry = _queue.Count > 0 ? _queue.Dequeue() : null;
            if (entry is null) continue;
            QueuedCount = GetQueuedCount();

            using var current = CancellationTokenSource.CreateLinkedTokenSource(_lifetimeCts.Token);
            lock (_queueSync) _currentTransferCts = current;
            try
            {
                OnUi(() =>
                {
                    entry.Status = "准备中";
                    RefreshHistory();
                    SaveHistoryAndMedia();
                    StatusMessage = "正在准备：" + entry.Title;
                    AddLog(TransferLogLevel.Info, "开始准备：" + entry.Title);
                });
                PublishProgress(new TransferProgressSnapshot(entry.Id, TransferPhase.Preparing,
                    entry.Title, "正在整理文件并计算校验值", null, QueuedCount: GetQueuedCount()));

                var settings = Settings.Clone();
                var password = _password;
                var transfer = await Task.Run(
                    () => TransferPreparationService.Prepare(entry, settings, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), current.Token),
                    current.Token).ConfigureAwait(false);
                using (transfer)
                {
                    var total = transfer.Files.Sum(file => new FileInfo(file.LocalPath).Length);
                    PublishProgress(new TransferProgressSnapshot(entry.Id, TransferPhase.Uploading,
                        entry.Title, "正在上传", 0, 0, total, GetQueuedCount()));
                    OnUi(() =>
                    {
                        entry.Status = "上传中";
                        RefreshHistory();
                        SaveHistoryAndMedia();
                        AddLog(TransferLogLevel.Info, "开始 FTP 上传：" + entry.Title);
                    });

                    var uploadProgress = new Progress<TransferProgressValues>(values =>
                        PublishProgress(new TransferProgressSnapshot(entry.Id,
                            values.Fraction >= 1 ? TransferPhase.Publishing : TransferPhase.Uploading,
                            entry.Title, values.Fraction >= 1 ? "正在发布控制文件" : "正在上传",
                            values.Fraction, values.UploadedBytes, values.TotalBytes, GetQueuedCount())));

                    await _ftp.UploadPreparedAsync(transfer, settings, password, uploadProgress, current.Token).ConfigureAwait(false);
                }

                OnUi(() =>
                {
                    entry.Status = "已发送";
                    StatusMessage = "发送成功：" + entry.Title;
                    RefreshHistory();
                    SaveHistoryAndMedia();
                    var extra = transfer.ExcludedItemCount > 0 ? $"，目录排除 {transfer.ExcludedItemCount} 项" : "";
                    AddLog(TransferLogLevel.Success, "发送成功：" + entry.Title + extra);
                });
                PublishProgress(new TransferProgressSnapshot(entry.Id, TransferPhase.Completed,
                    entry.Title, "发送完成", 1, Detail: "文件实体与控制文件均已上传"));
            }
            catch (OperationCanceledException)
            {
                OnUi(() =>
                {
                    entry.Status = "已取消";
                    StatusMessage = "传输已取消";
                    RefreshHistory();
                    SaveHistoryAndMedia();
                    AddLog(TransferLogLevel.Cancelled, "已取消：" + entry.Title);
                });
                PublishProgress(new TransferProgressSnapshot(entry.Id, TransferPhase.Cancelled,
                    entry.Title, "传输已取消", Detail: "当前任务和等待队列已停止"));
            }
            catch (Exception error)
            {
                var reason = Sanitize(error.Message);
                OnUi(() =>
                {
                    entry.Status = "发送失败";
                    StatusMessage = "发送失败：" + reason;
                    RefreshHistory();
                    SaveHistoryAndMedia();
                    AddLog(TransferLogLevel.Error, "发送失败：" + entry.Title + "；" + reason);
                });
                PublishProgress(new TransferProgressSnapshot(entry.Id, TransferPhase.Failed,
                    entry.Title, "发送失败", Detail: reason));
            }
            finally
            {
                lock (_queueSync)
                {
                    if (ReferenceEquals(_currentTransferCts, current)) _currentTransferCts = null;
                }
                QueuedCount = GetQueuedCount();
            }
        }
    }

    public void CancelTransfers()
    {
        List<HistoryEntry> waiting;
        CancellationTokenSource? current;
        lock (_queueSync)
        {
            waiting = _queue.ToList();
            _queue.Clear();
            current = _currentTransferCts;
        }
        if (current is not null) current.Cancel();
        OnUi(() =>
        {
            foreach (var entry in waiting) entry.Status = "已取消";
            if (waiting.Count > 0)
            {
                RefreshHistory();
                SaveHistoryAndMedia();
                AddLog(TransferLogLevel.Cancelled, $"已清空 {waiting.Count} 个等待任务。");
            }
            StatusMessage = current is not null ? "正在取消当前传输…" : "等待队列已清空";
        });
        if (current is not null)
            PublishProgress(Progress with { Phase = TransferPhase.Cancelling, CurrentItem = "正在取消", Detail = "正在停止当前 FTP 会话" });
        else if (waiting.Count > 0)
            PublishProgress(new TransferProgressSnapshot(Phase: TransferPhase.Cancelled, Title: "传输已取消"));
        QueuedCount = 0;
    }

    private int GetQueuedCount()
    {
        lock (_queueSync) return _queue.Count;
    }
}
