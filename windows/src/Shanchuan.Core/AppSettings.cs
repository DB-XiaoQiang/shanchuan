namespace Shanchuan.Core;

public enum NetworkMode
{
    Unconfigured,
    Internal,
    External
}

public sealed class AppSettings
{
    private string _language = Localization.DefaultLanguage;
    public string Language { get => _language; set => _language = Localization.NormalizeLanguage(value); }
    public string Host { get; set; } = "";
    public int Port { get; set; } = 21;
    public string Username { get; set; } = "";
    public string Directory { get; set; } = "/";
    public NetworkMode NetworkMode { get; set; } = NetworkMode.Unconfigured;
    public string ReceiveDirectory { get; set; } = "";
    public int ReceiveIntervalSeconds { get; set; } = 5;
    public int TtlDays { get; set; } = 90;
    public bool ShowTransferProgress { get; set; } = true;
    public bool RestoreOnResend { get; set; }
    public bool StartWithWindows { get; set; }
    public string TextRemoteName { get; set; } = "copy.temp";
    public bool AutoDecrypt { get; set; } = true;
    public string DecryptPrefix { get; set; } = "/jiemi/";
    public string DirectoryExclusionRules { get; set; } = "";
    public ShortcutOptions Shortcuts { get; set; } = new();

    public AppSettings Clone() => new()
    {
        Language = Language,
        Host = Host,
        Port = Port,
        Username = Username,
        Directory = Directory,
        NetworkMode = NetworkMode,
        ReceiveDirectory = ReceiveDirectory,
        ReceiveIntervalSeconds = ReceiveIntervalSeconds,
        TtlDays = TtlDays,
        ShowTransferProgress = ShowTransferProgress,
        RestoreOnResend = RestoreOnResend,
        StartWithWindows = StartWithWindows,
        TextRemoteName = TextRemoteName,
        AutoDecrypt = AutoDecrypt,
        DecryptPrefix = DecryptPrefix,
        DirectoryExclusionRules = DirectoryExclusionRules,
        Shortcuts = Shortcuts.Clone()
    };

    public string? ValidateForStorage()
    {
        if (!Enum.IsDefined(NetworkMode)) return L.T("请选择有效的网络位置。");
        if (Port is < 1 or > 65535) return L.T("端口须为 1–65535。");
        if (TtlDays is < 1 or > 3650) return L.T("历史保留天数须为 1–3650。");
        if (ReceiveIntervalSeconds is < 2 or > 3600) return L.T("接收检查间隔须为 2–3600 秒。");
        if (NetworkPolicy.ValidateReceiveDirectory(ReceiveDirectory) is { } receiveError) return receiveError;
        if (!string.IsNullOrWhiteSpace(Directory) && ProtocolValidation.ValidateDirectory(Directory) is { } directoryError)
            return directoryError;
        try { _ = DirectoryExclusions.Parse(DirectoryExclusionRules); }
        catch (ArgumentException error) { return error.Message; }
        return Shortcuts.Validate();
    }

    public string? ValidateForTransfer()
    {
        var host = Host.Trim();
        if (host.Length == 0) return L.T("请填写 FTP 服务器地址。");
        if (host.Length > 253 || host.Any(char.IsWhiteSpace) || host.Contains("://") ||
            host.IndexOfAny(['/', '\\', '@', '?', '#', '\r', '\n', '\t']) >= 0)
            return L.T("服务器地址只能填写主机名或 IP，不需要 ftp:// 前缀。");
        if (Port is < 1 or > 65535) return L.T("端口须为 1–65535。");
        if (Username.Length == 0) return L.T("请填写 FTP 用户名。");
        if (Username.Contains(':') || Username.Any(char.IsControl)) return L.T("FTP 用户名不能包含冒号或控制字符。");
        if (ProtocolValidation.ValidateDirectory(Directory) is { } directoryError) return directoryError;
        if (ProtocolValidation.ValidateName(TextRemoteName) is { } nameError) return nameError;
        return ValidateForStorage();
    }
}

[Flags]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Windows = 0x0008
}

public sealed record ShortcutBinding(uint VirtualKey, HotkeyModifiers Modifiers)
{
    public string DisplayName
    {
        get
        {
            var parts = new List<string>();
            if (Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(HotkeyModifiers.Windows)) parts.Add("Win");
            parts.Add(KeyName(VirtualKey));
            return string.Join(" + ", parts);
        }
    }

    public string? Validate()
    {
        if (VirtualKey is < 0x08 or > 0xFE) return L.T("请选择有效的快捷键按键。");
        if (Modifiers is HotkeyModifiers.None or HotkeyModifiers.Shift) return L.T("快捷键至少需要 Ctrl、Alt 或 Win。");
        if ((Modifiers & ~(HotkeyModifiers.Alt | HotkeyModifiers.Control | HotkeyModifiers.Shift | HotkeyModifiers.Windows)) != 0)
            return L.T("快捷键包含不支持的修饰键。");
        if (VirtualKey is 0x43 or 0x56 && Modifiers == HotkeyModifiers.Control)
            return L.T("请保留系统原生 Ctrl+C / Ctrl+V，选择其他组合。");
        return null;
    }

    private static string KeyName(uint key) => key switch
    {
        >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x41 and <= 0x5A => ((char)key).ToString(),
        >= 0x70 and <= 0x87 => $"F{key - 0x6F}",
        0x20 => L.T("空格"),
        0x09 => "Tab",
        0x0D => "Enter",
        0x1B => "Esc",
        0x08 => "Backspace",
        0x2E => "Delete",
        0x25 => "←",
        0x26 => "↑",
        0x27 => "→",
        0x28 => "↓",
        _ => L.F($"键码 0x{key:X2}")
    };
}

public sealed class ShortcutOptions
{
    public bool Enabled { get; set; } = true;
    public ShortcutBinding Copy { get; set; } = new(0x43, HotkeyModifiers.Control | HotkeyModifiers.Alt);
    public ShortcutBinding Paste { get; set; } = new(0x56, HotkeyModifiers.Control | HotkeyModifiers.Alt);

    public ShortcutOptions Clone() => new() { Enabled = Enabled, Copy = Copy, Paste = Paste };

    public string? Validate()
    {
        if (!Enabled) return null;
        if (Copy.Validate() is { } copyError) return L.T("复制并发送快捷键：") + copyError;
        if (Paste.Validate() is { } pasteError) return L.T("粘贴快捷键：") + pasteError;
        return Copy == Paste ? L.T("复制和粘贴快捷键不能相同。") : null;
    }
}

public static class ProtocolValidation
{
    public static string? ValidateName(string value)
    {
        if (string.IsNullOrEmpty(value) || value is "." or ".." ||
            value.StartsWith("folder:", StringComparison.Ordinal) || value.StartsWith("877D1C:", StringComparison.Ordinal) ||
            value.IndexOfAny([',', '|', '/', '\\', '\r', '\n', '\0']) >= 0)
            return L.F($"协议不能安全表示文件名：{value}");
        return null;
    }

    public static string? ValidateDirectory(string value)
    {
        if (!value.StartsWith('/') || value.Split('/', StringSplitOptions.RemoveEmptyEntries).Contains("..") ||
            value.IndexOfAny(['\r', '\n', '\0', '\\']) >= 0)
            return L.T("FTP 目录须以 / 开头，且不能包含反斜杠、控制字符或上级目录路径。");
        return null;
    }
}
