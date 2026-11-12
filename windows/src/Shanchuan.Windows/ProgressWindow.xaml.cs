using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;

namespace Shanchuan.Windows;

public partial class ProgressWindow : Window
{
    private readonly AppViewModel _viewModel;
    private readonly DispatcherTimer _hideTimer;
    private Guid? _lastTransferId;
    private Guid? _hiddenFor;
    private bool _allowClose;

    public ProgressWindow(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        _viewModel.PropertyChanged += OnPropertyChanged;
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); Hide(); };
        Closing += OnClosing;
    }

    public void ApplyPreferences()
    {
        if (!_viewModel.Settings.ShowTransferProgress) Hide();
        else Render();
    }

    public void CloseForShutdown()
    {
        _allowClose = true;
        Close();
    }

    private void OnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppViewModel.Progress)) Dispatcher.BeginInvoke(Render);
    }

    private void Render()
    {
        var progress = _viewModel.Progress;
        if (_lastTransferId != progress.Id)
        {
            _lastTransferId = progress.Id;
            _hiddenFor = null;
            _hideTimer.Stop();
        }

        PhaseText.Text = progress.Phase switch
        {
            TransferPhase.Preparing => "正在准备文件",
            TransferPhase.Uploading => "正在上传",
            TransferPhase.Publishing => "正在发布",
            TransferPhase.Cancelling => "正在取消",
            TransferPhase.Completed => "发送完成",
            TransferPhase.Failed => "发送失败",
            TransferPhase.Cancelled => "已取消",
            _ => "闪传"
        };
        TitleText.Text = progress.Title;
        DetailText.Text = string.Join(" · ", new[] { progress.CurrentItem, progress.Detail }.Where(text => !string.IsNullOrWhiteSpace(text)));
        UploadProgress.IsIndeterminate = progress.IsActive && !progress.Fraction.HasValue;
        UploadProgress.Value = (progress.Fraction ?? 0) * 100;
        PercentText.Text = progress.Fraction.HasValue ? $"{progress.Fraction.Value:P0}" : "";
        BytesText.Text = progress.TotalBytes > 0 ? $"{FormatBytes(progress.UploadedBytes)} / {FormatBytes(progress.TotalBytes)}" : "";
        QueueText.Text = progress.QueuedCount > 0 ? $"后面还有 {progress.QueuedCount} 个等待任务" : "";
        HideButton.IsEnabled = true;

        if (!_viewModel.Settings.ShowTransferProgress) { Hide(); return; }
        if (progress.IsActive)
        {
            if (!Equals(_hiddenFor, progress.Id)) ShowAtTopRight();
        }
        else if (progress.Phase == TransferPhase.Failed)
        {
            ShowAtTopRight();
        }
        else if (progress.Phase is TransferPhase.Completed or TransferPhase.Cancelled)
        {
            if (Equals(_hiddenFor, progress.Id)) return;
            ShowAtTopRight();
            _hideTimer.Stop();
            _hideTimer.Start();
        }
        else if (progress.Phase == TransferPhase.Idle) Hide();
    }

    private void ShowAtTopRight()
    {
        if (!IsVisible) Show();
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 16;
        Top = area.Top + 16;
    }

    private void OnHide(object sender, RoutedEventArgs e)
    {
        _hiddenFor = _viewModel.Progress.Id;
        _hideTimer.Stop();
        Hide();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        OnHide(this, new RoutedEventArgs());
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)Math.Max(0, bytes);
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return $"{value:0.##} {units[unit]}";
    }
}
