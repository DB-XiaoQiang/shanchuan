using System.Diagnostics;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

namespace Shanchuan.Windows.Services;

public static class WindowsStartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Apply(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, true) ??
            throw L.WithDescription(new InvalidOperationException(L.T("无法打开当前用户的启动项注册表。")), L.M("无法打开当前用户的启动项注册表。"));
        if (!enabled) { key.DeleteValue("Shanchuan", false); return; }

        var executable = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName ??
            throw L.WithDescription(new InvalidOperationException(L.T("无法确定闪传程序路径。")), L.M("无法确定闪传程序路径。"));
        var command = string.Equals(Path.GetFileName(executable), "dotnet.exe", StringComparison.OrdinalIgnoreCase)
            ? $"\"{executable}\" \"{Path.Combine(AppContext.BaseDirectory, "Shanchuan.dll")}\""
            : $"\"{executable}\"";
        key.SetValue("Shanchuan", command, RegistryValueKind.String);
    }
}

public sealed class TrayIconService : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly System.Drawing.Icon _nativeIcon;
    private readonly System.Windows.Forms.ToolStripItem _openItem;
    private readonly System.Windows.Forms.ToolStripItem _quitItem;

    public TrayIconService(Action showWindow, Action exitApplication)
    {
        var executable = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName ??
            throw L.WithDescription(new InvalidOperationException(L.T("无法确定闪传程序路径。")), L.M("无法确定闪传程序路径。"));
        _nativeIcon = System.Drawing.Icon.ExtractAssociatedIcon(executable) ??
            throw L.WithDescription(new InvalidOperationException(L.T("无法读取闪传应用图标。")), L.M("无法读取闪传应用图标。"));
        var menu = new System.Windows.Forms.ContextMenuStrip();
        _openItem = menu.Items.Add(L.T("打开闪传"), null, (_, _) => showWindow());
        _quitItem = menu.Items.Add(L.T("退出"), null, (_, _) => exitApplication());
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Text = L.T("闪传"),
            Icon = _nativeIcon,
            Visible = true,
            ContextMenuStrip = menu
        };
        _icon.DoubleClick += (_, _) => showWindow();
        L.LanguageChanged += OnLanguageChanged;
    }

    private void OnLanguageChanged()
    {
        void Refresh() { _openItem.Text = L.T("打开闪传"); _quitItem.Text = L.T("退出"); _icon.Text = L.T("闪传"); }
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess()) dispatcher.Invoke(Refresh);
        else Refresh();
    }

    public void Dispose()
    {
        L.LanguageChanged -= OnLanguageChanged;
        _icon.Visible = false;
        _icon.ContextMenuStrip?.Dispose();
        _icon.Dispose();
        _nativeIcon.Dispose();
    }
}
