using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Shanchuan.Windows.Services;

/// <summary>Sends ordinary Ctrl+C / Ctrl+V input only after the custom hotkey's modifiers are released.</summary>
public static class SendInputService
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint ControlKey = 0x11;

    public static async Task WaitForModifiersReleasedAsync(CancellationToken cancellationToken = default)
    {
        var start = Environment.TickCount64;
        while (AnyModifierPressed())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Environment.TickCount64 - start > 2_000)
                throw new TimeoutException(L.T("请完全松开自定义快捷键后再试。"));
            await Task.Delay(20, cancellationToken);
        }
    }

    public static Task SendCopyAsync(CancellationToken cancellationToken = default)
    {
        SendShortcut(0x43);
        return Task.Delay(150, cancellationToken);
    }

    public static Task SendPasteAsync()
    {
        SendShortcut(0x56);
        return Task.CompletedTask;
    }

    private static bool AnyModifierPressed()
    {
        uint[] keys = [0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5];
        return keys.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0);
    }

    private static void SendShortcut(uint key)
    {
        var inputs = new[]
        {
            Keyboard(ControlKey, false), Keyboard(key, false),
            Keyboard(key, true), Keyboard(ControlKey, true)
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length) throw new Win32Exception(Marshal.GetLastWin32Error(), L.T("无法向前台应用发送复制或粘贴按键。"));
    }

    private static Input Keyboard(uint key, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = (ushort)key, Flags = keyUp ? KeyEventKeyUp : 0 } }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInput
    {
        public uint Message;
        public ushort ParamL;
        public ushort ParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(uint key);
}
