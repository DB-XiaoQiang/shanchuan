using System.Reflection;
using System.Windows;
using Velopack;
using Velopack.Sources;
using MessageBox = System.Windows.MessageBox;

namespace Shanchuan.Windows.Services;

internal static class AppUpdateService
{
    public static async Task CheckAsync(Window owner, bool silent = false)
    {
        var repository = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(x => x.Key == "UpdateRepository")?.Value;
        if (string.IsNullOrWhiteSpace(repository))
        {
            if (!silent) MessageBox.Show(owner, "此构建尚未配置更新源，请从项目 Release 下载新版本。", "检查更新");
            return;
        }
        try
        {
            var manager = new UpdateManager(new GithubSource(repository, null, false));
            if (!manager.IsInstalled)
            {
                if (!silent) MessageBox.Show(owner, "请先使用 Release 中的 Setup 安装版，随后即可在应用内更新。", "检查更新");
                return;
            }
            var update = await manager.CheckForUpdatesAsync();
            if (update is null)
            {
                if (!silent) MessageBox.Show(owner, "当前已是最新版本。", "检查更新");
                return;
            }
            if (MessageBox.Show(owner, $"发现新版本 {update.TargetFullRelease.Version}，是否下载？下载后下次启动安装。",
                "闪传更新", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
            await manager.DownloadUpdatesAsync(update);
            // Do not terminate an FTP operation. Apply only on the next explicit launch.
            MessageBox.Show(owner, "更新已下载。请等待传输完成后，从托盘退出闪传并重新打开，新版本将自动安装。", "闪传更新");
        }
        catch (Exception error)
        {
            if (!silent) MessageBox.Show(owner, "检查或下载更新失败：" + error.Message + "\n私有仓库或无法访问 GitHub 的网络需要配置可访问的更新源。", "闪传更新");
        }
    }
}
