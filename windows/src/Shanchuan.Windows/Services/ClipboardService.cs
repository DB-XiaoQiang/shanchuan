using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Shanchuan.Core;
using Clipboard = System.Windows.Clipboard;

namespace Shanchuan.Windows.Services;

public sealed record CapturedClipboard(HistoryKind Kind, string Text, IReadOnlyList<string> Paths);

public static class ClipboardService
{
    public static async Task<CapturedClipboard> CopyAndCaptureAsync(Func<string> newImagePath,
        CancellationToken cancellationToken = default)
    {
        await SendInputService.WaitForModifiersReleasedAsync(cancellationToken).ConfigureAwait(true);
        var before = GetClipboardSequenceNumber();
        await SendInputService.SendCopyAsync(cancellationToken).ConfigureAwait(true);

        var clipboardChanged = false;
        string? readError = null;
        for (var attempt = 0; attempt < 50; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (GetClipboardSequenceNumber() != before)
            {
                clipboardChanged = true;
                if (TryRead(newImagePath, out var captured, out readError)) return captured;
            }
            await Task.Delay(100, cancellationToken).ConfigureAwait(true);
        }
        if (clipboardChanged)
            throw new InvalidDataException("目标应用已更新剪贴板，但读取失败。请关闭可能占用剪贴板的工具后重试。" +
                (string.IsNullOrWhiteSpace(readError) ? "" : "原因：" + readError));
        throw new InvalidDataException("等待 5 秒后仍未捕获到新的复制内容。请确认前方应用中有选中的文本、图片或文件，并检查目标应用是否响应 Ctrl+C。");
    }

    private static bool TryRead(Func<string> newImagePath, out CapturedClipboard captured, out string? error)
    {
        error = null;
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                var paths = Clipboard.GetFileDropList().Cast<string>().ToList();
                captured = new CapturedClipboard(HistoryKind.File, "", paths);
                return paths.Count > 0;
            }
            if (Clipboard.ContainsImage())
            {
                var image = Clipboard.GetImage();
                if (image is not null)
                {
                    var path = newImagePath();
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(image));
                    using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        encoder.Save(stream);
                    captured = new CapturedClipboard(HistoryKind.Image, "", [path]);
                    return true;
                }
            }
            if (Clipboard.ContainsText())
            {
                var text = Clipboard.GetText();
                if (text.Length > 0)
                {
                    captured = new CapturedClipboard(HistoryKind.Text, text, []);
                    return true;
                }
            }
        }
        catch (ExternalException exception) { error = exception.Message; }
        catch (InvalidOperationException exception) { error = exception.Message; }
        captured = new CapturedClipboard(HistoryKind.Text, "", []);
        return false;
    }

    public static void Restore(HistoryEntry entry)
    {
        if (entry.Kind == HistoryKind.Text) Clipboard.SetText(entry.Content);
        else if (entry.Kind == HistoryKind.Image && File.Exists(entry.Paths.FirstOrDefault() ?? ""))
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(entry.Paths[0]);
            image.EndInit();
            image.Freeze();
            Clipboard.SetImage(image);
        }
        else if (entry.Paths.Count > 0)
        {
            var paths = new StringCollection();
            paths.AddRange(entry.Paths.Where(File.Exists).ToArray());
            foreach (var directory in entry.Paths.Where(Directory.Exists)) paths.Add(directory);
            if (paths.Count > 0) Clipboard.SetFileDropList(paths);
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();
}
