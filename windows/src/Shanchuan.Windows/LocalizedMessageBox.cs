using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Button = System.Windows.Controls.Button;
using Orientation = System.Windows.Controls.Orientation;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Shanchuan.Windows;

/// <summary>App-owned dialogs use the selected app language, including their buttons.</summary>
public static class LocalizedMessageBox
{
    public static MessageBoxResult Show(string message, string title,
        MessageBoxButton buttons = MessageBoxButton.OK, MessageBoxImage image = MessageBoxImage.None,
        MessageBoxResult defaultResult = MessageBoxResult.None) =>
        Show(System.Windows.Application.Current?.MainWindow, message, title, buttons, image, defaultResult);

    public static MessageBoxResult Show(Window? owner, string message, string title,
        MessageBoxButton buttons = MessageBoxButton.OK, MessageBoxImage image = MessageBoxImage.None,
        MessageBoxResult defaultResult = MessageBoxResult.None) =>
        ShowDialog(owner, message, title, buttons, defaultResult, null, null);

    public static bool ConfirmUpdate(Window owner, string message, string title) =>
        ShowDialog(owner, message, title, MessageBoxButton.YesNo, MessageBoxResult.No,
            L.T("更新并重启"), L.T("稍后")) == MessageBoxResult.Yes;

    private static MessageBoxResult ShowDialog(Window? owner, string message, string title,
        MessageBoxButton buttons, MessageBoxResult defaultResult, string? yesTitle, string? noTitle)
    {
        var result = buttons == MessageBoxButton.OK ? MessageBoxResult.OK :
            buttons == MessageBoxButton.YesNo ? MessageBoxResult.No : MessageBoxResult.Cancel;
        var window = new Window
        {
            Title = title, Width = 580, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            WindowStartupLocation = owner?.IsVisible == true ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Background = Brushes.White, Foreground = new SolidColorBrush(Color.FromRgb(23, 32, 51))
        };
        if (owner?.IsVisible == true) window.Owner = owner;
        var content = new StackPanel { Margin = new Thickness(24) };
        content.Children.Add(new ScrollViewer
        {
            MaxHeight = 440, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, FontSize = 14 }
        });
        var choices = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 20, 0, 0)
        };
        void Add(string label, MessageBoxResult value)
        {
            var button = new Button
            {
                Content = label, MinWidth = 90, Padding = new Thickness(14, 8, 14, 8),
                Margin = new Thickness(8, 0, 0, 0), IsDefault = value == defaultResult ||
                    (defaultResult == MessageBoxResult.None && value == MessageBoxResult.OK),
                IsCancel = value is MessageBoxResult.Cancel or MessageBoxResult.No
            };
            System.Windows.Automation.AutomationProperties.SetAutomationId(button,
                yesTitle is not null && value == MessageBoxResult.Yes ? "ConfirmUpdateInstall" : "Dialog" + value);
            button.Click += (_, _) => { result = value; window.Close(); };
            choices.Children.Add(button);
        }
        if (buttons is MessageBoxButton.YesNo or MessageBoxButton.YesNoCancel)
        {
            Add(yesTitle ?? L.T("是"), MessageBoxResult.Yes);
            Add(noTitle ?? L.T("否"), MessageBoxResult.No);
        }
        else Add(L.T("确定"), MessageBoxResult.OK);
        if (buttons is MessageBoxButton.OKCancel or MessageBoxButton.YesNoCancel) Add(L.T("取消"), MessageBoxResult.Cancel);
        content.Children.Add(choices);
        window.Content = content;
        window.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; window.Close(); }
        };
        window.ShowDialog();
        return result;
    }
}
