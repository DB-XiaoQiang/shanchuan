using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;
using TextBox = System.Windows.Controls.TextBox;

namespace Shanchuan.Windows;

public partial class DirectoryRulesWindow : Window
{
    private readonly AppViewModel _viewModel;
    private readonly bool _initializing;
    private bool _settingsAlreadySaved;
    private bool _ruleErrorFromRules;

    public DirectoryRulesWindow(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        _initializing = true;
        DataContext = viewModel;
        InitializeComponent();
        _initializing = false;
        Closing += OnClosing;
        Loaded += (_, _) => RulesEditor.Focus();
        L.LanguageChanged += OnLanguageChanged;
        Closed += (_, _) => L.LanguageChanged -= OnLanguageChanged;
    }

    public event EventHandler? RulesChanged;

    private void RulesEdited(object sender, TextChangedEventArgs e)
    {
        if (_initializing) return;
        RulesEditor.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
        RuleValidation.Visibility = Visibility.Collapsed;
        _viewModel.SettingsEdited();
        RulesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void AddCommonRulesClicked(object sender, RoutedEventArgs e) => AddCommonRules();

    public void AddCommonRules() => RulesEditor.SetCurrentValue(TextBox.TextProperty, AppendCommonRules(RulesEditor.Text));

    internal static string AppendCommonRules(string text)
    {
        string[] common = [".git/", "node_modules/", "target/", "dist/", "*.log"];
        var existing = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim()).ToHashSet(StringComparer.Ordinal);
        var missing = common.Where(rule => !existing.Contains(rule)).ToArray();
        if (missing.Length == 0) return text;
        var separator = text.Length == 0 || text.EndsWith('\n') || text.EndsWith('\r') ? "" : Environment.NewLine;
        return text + separator + string.Join(Environment.NewLine, missing);
    }

    // The settings object is shared with the page. Explicitly flush before
    // saving or closing so the final keystroke never remains only in the editor.
    internal bool TryFlush()
    {
        RulesEditor.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
        try { _ = DirectoryExclusions.Parse(_viewModel.Settings.DirectoryExclusionRules); }
        catch (ArgumentException error)
        {
            _ruleErrorFromRules = true;
            RuleValidation.Text = error.Message;
            RuleValidation.Visibility = Visibility.Visible;
            RulesEditor.Focus();
            return false;
        }
        RuleValidation.Visibility = Visibility.Collapsed;
        return true;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_settingsAlreadySaved) return;
        if (!TryFlush())
        {
            e.Cancel = true;
            return;
        }
        if (!_viewModel.SaveSettingsNow())
        {
            _ruleErrorFromRules = false;
            RuleValidation.Text = _viewModel.SettingsStatus;
            RuleValidation.Visibility = Visibility.Visible;
            e.Cancel = true;
        }
    }

    internal void CloseAfterSaved()
    {
        _settingsAlreadySaved = true;
        Close();
    }

    private void Complete(object sender, RoutedEventArgs e) => Close();

    private void OnLanguageChanged() => Dispatcher.Invoke(() =>
    {
        var text = RulesEditor.Text;
        var start = RulesEditor.SelectionStart; var length = RulesEditor.SelectionLength;
        var vertical = RulesEditor.VerticalOffset; var horizontal = RulesEditor.HorizontalOffset;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!IsLoaded || RulesEditor.Text != text) return;
            RulesEditor.Select(start, length);
            RulesEditor.ScrollToVerticalOffset(vertical);
            RulesEditor.ScrollToHorizontalOffset(horizontal);
        }), System.Windows.Threading.DispatcherPriority.Loaded);
        if (RuleValidation.Visibility == Visibility.Visible)
        {
            if (!_ruleErrorFromRules) RuleValidation.Text = _viewModel.SettingsStatus;
            else
            {
                try { _ = DirectoryExclusions.Parse(_viewModel.Settings.DirectoryExclusionRules); }
                catch (ArgumentException error) { RuleValidation.Text = error.Message; }
            }
        }
    });
}
