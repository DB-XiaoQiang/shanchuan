using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;
using DragEventArgs = System.Windows.DragEventArgs;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;
using MessageBox = Shanchuan.Windows.LocalizedMessageBox;

namespace Shanchuan.Windows;

public partial class MainWindow : Window
{
    private readonly AppViewModel _viewModel;
    private SettingsPage? _settingsPage;

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

    private void NavigateHistory(object sender, RoutedEventArgs e) => ShowPage(HistoryPanel, L.T("剪贴板记录"));
    private void NavigateLogs(object sender, RoutedEventArgs e) => ShowPage(LogsPanel, L.T("传输日志"));
    private void NavigateHelp(object sender, RoutedEventArgs e) => ShowPage(HelpPanel, L.T("使用说明"));
    private void NavigateSettings(object sender, RoutedEventArgs e) => ShowPage(SettingsPanel, L.T("配置中心"));

    private void ShowPage(FrameworkElement selected, string title)
    {
        if (SettingsPanel.Visibility == Visibility.Visible && selected != SettingsPanel &&
            _settingsPage is not null && !_settingsPage.TrySave()) return;
        if (selected == SettingsPanel && _settingsPage is null)
            SettingsPanel.Content = _settingsPage = new SettingsPage(_viewModel);
        HistoryPanel.Visibility = Visibility.Collapsed;
        LogsPanel.Visibility = Visibility.Collapsed;
        HelpPanel.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        selected.Visibility = Visibility.Visible;
        PageTitle.Text = title;
    }

    private void AddFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = L.T("选择要发送的文件"),
            Multiselect = true,
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) == true) _viewModel.EnqueuePaths(dialog.FileNames);
    }

    private void AddFolder(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = L.T("选择要发送的文件夹"),
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) _viewModel.EnqueuePaths([dialog.SelectedPath]);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = HistoryPanel.Visibility == Visibility.Visible && _viewModel.CanSend && e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (HistoryPanel.Visibility == Visibility.Visible && _viewModel.CanSend &&
            e.Data.GetData(DataFormats.FileDrop) is string[] paths) _viewModel.EnqueuePaths(paths);
        e.Handled = true;
    }

    private void ClearHistory(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(L.T("确定清空所有未在传输中的历史记录吗？此操作不会删除你主动发送的原始文件。"),
                L.T("清空历史"), MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            _viewModel.ClearHistory();
    }

    private void ClearLogs(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(L.T("确定清空全部传输日志吗？"), L.T("清空日志"),
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

    public bool TrySaveSettingsBeforeClose()
    {
        var saved = _settingsPage?.TrySave() ?? _viewModel.SaveSettingsNow();
        if (!saved)
        {
            ShowPage(SettingsPanel, L.T("配置中心"));
            _settingsPage?.TrySave();
        }
        return saved;
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
        if (TrySaveSettingsBeforeClose()) Hide();
    }
}
