using System.Text.Json.Serialization;

namespace Shanchuan.Core;

public enum HistoryKind
{
    Text,
    File,
    Image
}

public sealed class HistoryEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;
    public HistoryKind Kind { get; set; }
    public string Content { get; set; } = "";
    public List<string> Paths { get; set; } = [];
    public string Status { get; set; } = "仅本地";

    [JsonIgnore]
    public string Title => Kind == HistoryKind.Text
        ? Content
        : string.Join("、", Paths.Select(GetPathName));

    public HistoryEntry CloneForResend() => new()
    {
        Id = Guid.NewGuid(),
        Date = DateTimeOffset.Now,
        Kind = Kind,
        Content = Content,
        Paths = [.. Paths],
        Status = "等待发送"
    };

    private static string GetPathName(string path)
    {
        if (Directory.Exists(path))
            return new DirectoryInfo(path).Name;
        return Path.GetFileName(path);
    }
}

public enum TransferLogLevel
{
    Info,
    Success,
    Warning,
    Error,
    Cancelled
}

public sealed class TransferLogEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;
    public TransferLogLevel Level { get; set; }
    public string Message { get; set; } = "";
}

public enum TransferPhase
{
    Idle,
    Preparing,
    Uploading,
    Publishing,
    Cancelling,
    Completed,
    Failed,
    Cancelled
}

public sealed record TransferProgressSnapshot(
    Guid? Id = null,
    TransferPhase Phase = TransferPhase.Idle,
    string Title = "",
    string CurrentItem = "",
    double? Fraction = null,
    long UploadedBytes = 0,
    long TotalBytes = 0,
    int QueuedCount = 0,
    string Detail = "",
    LocalizedText? CurrentItemMessage = null,
    LocalizedText? DetailMessage = null,
    LocalizedText? TitleMessage = null)
{
    public string DisplayCurrentItem => CurrentItemMessage?.ToString() ?? CurrentItem;
    public string DisplayDetail => DetailMessage?.ToString() ?? Detail;
    public string DisplayTitle => TitleMessage?.ToString() ?? Title;
    public bool IsActive => Phase is TransferPhase.Preparing or TransferPhase.Uploading
        or TransferPhase.Publishing or TransferPhase.Cancelling;

    public bool IsTerminal => Phase is TransferPhase.Completed or TransferPhase.Failed or TransferPhase.Cancelled;
}
