namespace Shanchuan.Core;

/// <summary>Explicit user-selected network location; never inferred from an IP address.</summary>
public static class NetworkPolicy
{
    public static string DisplayName(NetworkMode mode) => mode switch
    {
        NetworkMode.Internal => "内网 · 只接收",
        NetworkMode.External => "外网 · 只发送",
        _ => "未设置网络位置"
    };

    public static void RequireUpload(AppSettings settings)
    {
        if (settings.NetworkMode == NetworkMode.External) return;
        var reason = settings.NetworkMode == NetworkMode.Internal
            ? "当前为内网（只接收），禁止上传。外网电脑才能发送。"
            : "请先在配置中心选择网络位置；外网电脑选择“外网（只发送）”。";
        throw new InvalidOperationException(reason);
    }

    public static void RequireReceive(AppSettings settings)
    {
        if (settings.NetworkMode == NetworkMode.Internal) return;
        var reason = settings.NetworkMode == NetworkMode.External
            ? "当前为外网（只发送），禁止下载和删除远端文件。"
            : "请先在配置中心选择网络位置；内网电脑选择“内网（只接收）”。";
        throw new InvalidOperationException(reason);
    }

    public static string ResolveReceiveDirectory(string configuredPath)
    {
        var path = string.IsNullOrWhiteSpace(configuredPath)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Shanchuan")
            : Environment.ExpandEnvironmentVariables(configuredPath.Trim());
        return Path.GetFullPath(path);
    }

    public static string? ValidateReceiveDirectory(string configuredPath)
    {
        if (string.IsNullOrWhiteSpace(configuredPath)) return null;
        try
        {
            var path = Environment.ExpandEnvironmentVariables(configuredPath.Trim());
            if (!Path.IsPathRooted(path)) return "接收目录须填写完整的本地路径，或留空使用下载目录。";
            _ = Path.GetFullPath(path);
            return null;
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return "接收目录无效：" + error.Message;
        }
    }
}
