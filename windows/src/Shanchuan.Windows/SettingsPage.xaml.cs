using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Data;
using System.Windows.Media;
using Shanchuan.Core;
using Shanchuan.Windows.ViewModels;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using TextBox = System.Windows.Controls.TextBox;

namespace Shanchuan.Windows;

public partial class SettingsPage : System.Windows.Controls.UserControl
{
    private readonly AppViewModel _viewModel;
    private readonly bool _initializing;

    public SettingsPage(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        DataContext = viewModel;
        _initializing = true;
        InitializeComponent();
        NetworkModeSelector.SelectedIndex = (int)viewModel.Settings.NetworkMode;
        DefaultReceivePath.Text = "留空使用：" + NetworkPolicy.ResolveReceiveDirectory("");
        PasswordBox.Password = viewModel.GetPasswordForEditing();
        CopyHotkey.Text = viewModel.Settings.Shortcuts.Copy.DisplayName;
        PasteHotkey.Text = viewModel.Settings.Shortcuts.Paste.DisplayName;
        _initializing = false;
    }

    private void SettingChanged(object sender, RoutedEventArgs e)
    {
        if (!_initializing)
        {
            PageValidation.Visibility = Visibility.Collapsed;
            _viewModel.SettingsEdited();
        }
    }

    private void NetworkModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing || NetworkModeSelector.SelectedIndex < 0) return;
        _viewModel.Settings.NetworkMode = (NetworkMode)NetworkModeSelector.SelectedIndex;
        _viewModel.SettingsEdited();
    }

    private void BrowseReceiveDirectory(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择内网接收文件和文件夹的保存位置",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true
        };
        var current = NetworkPolicy.ResolveReceiveDirectory(_viewModel.Settings.ReceiveDirectory);
        if (Directory.Exists(current)) dialog.SelectedPath = current;
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            _viewModel.Settings.ReceiveDirectory = dialog.SelectedPath;
            ReceiveDirectoryBox.SetCurrentValue(TextBox.TextProperty, dialog.SelectedPath);
            _viewModel.SettingsEdited();
        }
    }

    private void PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (!_initializing) _viewModel.PasswordEdited(PasswordBox.Password);
    }

    private async void TestConnection(object sender, RoutedEventArgs e) => await _viewModel.TestConnectionAsync();

    private void RecordHotkey(object sender, KeyEventArgs e)
    {
        if (sender is not TextBox box) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape)
        {
            box.Text = box.Tag as string == "Copy"
                ? _viewModel.Settings.Shortcuts.Copy.DisplayName
                : _viewModel.Settings.Shortcuts.Paste.DisplayName;
            return;
        }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
            return;

        var modifiers = HotkeyModifiers.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= HotkeyModifiers.Control;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= HotkeyModifiers.Alt;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= HotkeyModifiers.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) modifiers |= HotkeyModifiers.Windows;
        var binding = new ShortcutBinding((uint)KeyInterop.VirtualKeyFromKey(key), modifiers);
        var options = _viewModel.Settings.Shortcuts.Clone();
        if (box.Tag as string == "Copy") options.Copy = binding;
        else options.Paste = binding;
        if (options.Validate() is { } error)
        {
            HotkeyError.Text = error;
            return;
        }

        _viewModel.Settings.Shortcuts.Copy = options.Copy;
        _viewModel.Settings.Shortcuts.Paste = options.Paste;
        CopyHotkey.Text = options.Copy.DisplayName;
        PasteHotkey.Text = options.Paste.DisplayName;
        HotkeyError.Text = "";
        _viewModel.SettingsEdited();
    }

    private void ResetHotkeys(object sender, RoutedEventArgs e)
    {
        _viewModel.Settings.Shortcuts.Copy = new ShortcutBinding(0x43, HotkeyModifiers.Control | HotkeyModifiers.Alt);
        _viewModel.Settings.Shortcuts.Paste = new ShortcutBinding(0x56, HotkeyModifiers.Control | HotkeyModifiers.Alt);
        CopyHotkey.Text = _viewModel.Settings.Shortcuts.Copy.DisplayName;
        PasteHotkey.Text = _viewModel.Settings.Shortcuts.Paste.DisplayName;
        HotkeyError.Text = "";
        _viewModel.SettingsEdited();
    }

    private void AddCommonRules(object sender, RoutedEventArgs e)
    {
        string[] common = [".git/", "node_modules/", "target/", "dist/", "*.log"];
        var lines = ExclusionRules.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim()).ToHashSet(StringComparer.Ordinal);
        foreach (var rule in common) lines.Add(rule);
        ExclusionRules.SetCurrentValue(TextBox.TextProperty, string.Join(Environment.NewLine, lines));
        ExclusionRules.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
        _viewModel.SettingsEdited();
    }

    /// Flush bindings as well as the view model: invalid numeric input otherwise
    /// leaves an older valid value in Settings and must not disappear on navigation.
    public bool TrySave()
    {
        var controls = Descendants(this).ToArray();
        foreach (var box in controls.OfType<TextBox>())
            box.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
        var invalid = controls.OfType<System.Windows.Controls.Control>()
            .FirstOrDefault(Validation.GetHasError);
        if (invalid is not null)
        {
            PageValidation.Text = "配置尚未保存：请修正标红的输入值后再离开此页面。";
            PageValidation.Visibility = Visibility.Visible;
            invalid.BringIntoView();
            invalid.Focus();
            return false;
        }
        if (!_viewModel.SaveSettingsNow())
        {
            PageValidation.Text = _viewModel.SettingsStatus;
            PageValidation.Visibility = Visibility.Visible;
            return false;
        }
        PageValidation.Visibility = Visibility.Collapsed;
        return true;
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
