using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;
using DragEventArgs = System.Windows.DragEventArgs;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;
using MessageBox = System.Windows.MessageBox;

namespace Shanchuan.Windows;

public partial class MainWindow : Window
{
    private readonly AppViewModel _viewModel;

    public MainWindow(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        Closing += OnClosing;
        UpdateMainProgress();
    }

    public bool AllowClose { get; set; }

    private void NavigateHistory(object sender, RoutedEventArgs e) => ShowPage(HistoryPanel, "剪贴板记录");
    private void NavigateLogs(object sender, RoutedEventArgs e) => ShowPage(LogsPanel, "传输日志");
    private void NavigateHelp(object sender, RoutedEventArgs e) => ShowPage(HelpPanel, "使用说明");

    private void ShowPage(FrameworkElement selected, string title)
    {
        HistoryPanel.Visibility = Visibility.Collapsed;
        LogsPanel.Visibility = Visibility.Collapsed;
        HelpPanel.Visibility = Visibility.Collapsed;
        selected.Visibility = Visibility.Visible;
        PageTitle.Text = title;
    }

    private void AddFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择要发送的文件",
            Multiselect = true,
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) == true) _viewModel.EnqueuePaths(dialog.FileNames);
    }

    private void AddFolder(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择要发送的文件夹",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) _viewModel.EnqueuePaths([dialog.SelectedPath]);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = _viewModel.CanSend && e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) _viewModel.EnqueuePaths(paths);
    }

    private void ClearHistory(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("确定清空所有未在传输中的历史记录吗？此操作不会删除你主动发送的原始文件。",
                "清空历史", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            _viewModel.ClearHistory();
    }

    private void ClearLogs(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("确定清空全部传输日志吗？", "清空日志",
                MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            _viewModel.ClearLogs();
    }

    private void FilterLogs(object sender, TextChangedEventArgs e)
    {
        var query = LogSearch.Text;
        var view = CollectionViewSource.GetDefaultView(_viewModel.Logs);
        view.Filter = item => item is TransferLogEntry log &&
            (query.Length == 0 || log.Message.Contains(query, StringComparison.OrdinalIgnoreCase));
        view.Refresh();
    }

    private async void CheckForUpdates(object sender, RoutedEventArgs e) => await _viewModel.Updates.CheckAsync();

    private async void InstallUpdate(object sender, RoutedEventArgs e) => await _viewModel.Updates.RequestInstallAsync(this);

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        var settings = new SettingsWindow(_viewModel) { Owner = this };
        settings.ShowDialog();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppViewModel.Progress)) UpdateMainProgress();
    }

    private void UpdateMainProgress()
    {
        var progress = _viewModel.Progress;
        MainProgress.Visibility = progress.IsActive ? Visibility.Visible : Visibility.Collapsed;
        MainProgress.IsIndeterminate = progress.IsActive && !progress.Fraction.HasValue;
        MainProgress.Value = (progress.Fraction ?? 0) * 100;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (AllowClose) return;
        e.Cancel = true;
        Hide();
    }
}
