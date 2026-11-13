using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using Shanchuan.Core;

namespace Shanchuan.Windows.Services;

public sealed class GlobalHotkeyService : IDisposable
{
    private const int WmHotKey = 0x0312;
    private const int CopyId = 0x5343;
    private const int PasteId = 0x5350;
    private const uint ModNoRepeat = 0x4000;
    private IntPtr _handle;
    private HwndSource? _source;
    private ShortcutOptions _options = new();

    public event EventHandler<ShortcutBinding>? CopyRequested;
    public event EventHandler<ShortcutBinding>? PasteRequested;

    public void Initialize(IntPtr handle)
    {
        _handle = handle;
        _source = HwndSource.FromHwnd(handle) ?? throw L.WithDescription(new InvalidOperationException(L.T("无法初始化 Windows 热键窗口。")), L.M("无法初始化 Windows 热键窗口。"));
        _source.AddHook(WindowProc);
    }

    public void Update(ShortcutOptions options)
    {
        if (_handle == IntPtr.Zero) throw L.WithDescription(new InvalidOperationException(L.T("全局热键窗口尚未初始化，请重新启动闪传。")), L.M("全局热键窗口尚未初始化，请重新启动闪传。"));
        Unregister();
        _options = options.Clone();
        if (!options.Enabled) return;
        Register(CopyId, options.Copy);
        try { Register(PasteId, options.Paste); }
        catch
        {
            UnregisterHotKey(_handle, CopyId);
            throw;
        }
    }

    private void Register(int id, ShortcutBinding binding)
    {
        if (!RegisterHotKey(_handle, id, (uint)binding.Modifiers | ModNoRepeat, binding.VirtualKey))
            throw new Win32Exception(Marshal.GetLastWin32Error(), L.F($"无法注册全局快捷键 {binding.DisplayName}，可能被其他程序占用。"));
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey)
        {
            if (wParam.ToInt32() == CopyId) CopyRequested?.Invoke(this, _options.Copy);
            else if (wParam.ToInt32() == PasteId) PasteRequested?.Invoke(this, _options.Paste);
            handled = true;
        }
        return IntPtr.Zero;
    }

    private void Unregister()
    {
        if (_handle == IntPtr.Zero) return;
        UnregisterHotKey(_handle, CopyId);
        UnregisterHotKey(_handle, PasteId);
    }

    public void Dispose()
    {
        Unregister();
        _source?.RemoveHook(WindowProc);
        _source = null;
        _handle = IntPtr.Zero;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
