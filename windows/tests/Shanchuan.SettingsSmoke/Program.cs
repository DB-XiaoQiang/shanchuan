using System.IO;
using System.Text.Json;
using System.Reflection;
using System.Xml.Linq;
using System.Windows.Markup;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Shanchuan.Core;
using Shanchuan.Windows;
using Shanchuan.Windows.Services;
using Shanchuan.Windows.ViewModels;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;

namespace Shanchuan.SettingsSmoke;

internal static class Program
{
    private static readonly List<string> Checks = [];

    [STAThread]
    private static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("This smoke test requires Windows WPF.");
            return 2;
        }
        var output = Path.GetFullPath(args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "shanchuan-settings-smoke-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(output);
        var dataRoot = Path.Combine(output, "fixture-data");
        Directory.CreateDirectory(dataRoot);
        using var watchdog = new System.Threading.Timer(_ =>
        {
            Console.Error.WriteLine("SETTINGS_PAGE_SMOKE_TIMEOUT");
            Environment.Exit(124);
        }, null, TimeSpan.FromSeconds(45), Timeout.InfiniteTimeSpan);

        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        LoadProductionStyles(application);
        var settingsStore = new SettingsStore(dataRoot);
        var credentials = new FakeCredentials();
        var settings = new AppSettings { NetworkMode = NetworkMode.Unconfigured, Host = "initial.example.invalid", Username = "smoke-user" };
        var viewModel = new AppViewModel(settings, "synthetic-initial-password", settingsStore,
            new HistoryStore(dataRoot), new TransferLogStore(dataRoot), credentials,
            new FtpTransferService(), new FtpReceiveService(new ReceiveStateStore(dataRoot)), [], []);
        // Construct the state service for bindings only. No Start(), receiver,
        // Velopack hook, global hotkey or real credential manager is used.
        viewModel.InitializeUpdates(dataRoot);
        var window = new MainWindow(viewModel) { Width = 1080, Height = 800 };
        var exitCode = 1;
        window.Loaded += (_, _) => window.Dispatcher.BeginInvoke(new Action(async () =>
        {
            try
            {
                RunAssertions(application, window, viewModel, settingsStore, credentials, output);
                await RunUpdateFeedbackAssertionsAsync(application, window, viewModel, dataRoot);
                File.WriteAllText(Path.Combine(output, "settings-smoke-report.json"), JsonSerializer.Serialize(new
                {
                    passed = true,
                    version = AppUpdateService.InstalledVersion,
                    checks = Checks,
                    screenshot = "settings-page.png",
                    ftpWorkersStarted = false,
                    systemCredentialStoreUsed = false
                }, new JsonSerializerOptions { WriteIndented = true }));
                Console.WriteLine("SETTINGS_PAGE_SMOKE_PASS " + Checks.Count + " checks");
                exitCode = 0;
            }
            catch (Exception error)
            {
                File.WriteAllText(Path.Combine(output, "settings-smoke-report.json"), JsonSerializer.Serialize(new
                {
                    passed = false,
                    checks = Checks,
                    error = error.ToString()
                }, new JsonSerializerOptions { WriteIndented = true }));
                Console.Error.WriteLine("SETTINGS_PAGE_SMOKE_FAIL " + error);
            }
            finally
            {
                window.AllowClose = true;
                window.Close();
                viewModel.Dispose();
                application.Shutdown(exitCode);
            }
        }), DispatcherPriority.ApplicationIdle);
        application.Run(window);
        return exitCode;
    }

    private static void LoadProductionStyles(Application application)
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("ProductionApplication.xaml")
            ?? throw new InvalidOperationException("Missing production application styles.");
        var document = XDocument.Load(source);
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var resources = document.Root?.Element(presentation + "Application.Resources")
            ?? throw new InvalidOperationException("Missing Application.Resources.");
        var dictionary = new XElement(presentation + "ResourceDictionary",
            new XAttribute(XNamespace.Xmlns + "x", xaml), resources.Elements());
        application.Resources = (ResourceDictionary)XamlReader.Parse(dictionary.ToString());
    }

    private static void RunAssertions(Application application, MainWindow window, AppViewModel viewModel,
        SettingsStore settingsStore, FakeCredentials credentials, string output)
    {
        Check(application.Windows.Count == 1, "single-main-window");
        Click(window, "SettingsNav");
        var page = Find<SettingsPage>(window, "SettingsPageRoot");
        Check(page.IsVisible && Window.GetWindow(page) == window, "settings-is-embedded-visible-page");
        Check(ReferenceEquals(page.DataContext, viewModel), "settings-reuses-main-view-model");
        Check(application.Windows.Count == 1, "navigation-opens-no-settings-dialog");

        var host = Find<TextBox>(page, "SettingHost");
        host.SetCurrentValue(TextBox.TextProperty, "ftp.example.invalid");
        var password = Find<PasswordBox>(page, "SettingPassword");
        password.Password = "synthetic-updated-password";
        Click(window, "HistoryNav");
        Check(Title(window) == "剪贴板记录", "navigate-back-to-history");
        Check(settingsStore.Load().Host == "ftp.example.invalid", "edits-persist-on-navigation");
        Check(credentials.Value == "synthetic-updated-password" && credentials.SaveCount > 0,
            "password-edits-use-injected-credential-store");

        Click(window, "SettingsNav");
        var repeatedPage = Find<SettingsPage>(window, "SettingsPageRoot");
        Check(ReferenceEquals(page, repeatedPage), "settings-page-created-only-once");
        Check(ReferenceEquals(host, Find<TextBox>(repeatedPage, "SettingHost")), "input-controls-survive-navigation");
        Check(password.Password == "synthetic-updated-password", "password-not-reset-on-reentry");
        Capture(window, Path.Combine(output, "settings-page.png"));

        var port = Find<TextBox>(page, "SettingPort");
        port.SetCurrentValue(TextBox.TextProperty, "not-a-number");
        Pump();
        Click(window, "HistoryNav");
        Check(Title(window) == "配置中心" && page.IsVisible, "invalid-input-blocks-page-exit");
        Check(Find<TextBlock>(page, "SettingsPageValidation").Visibility == Visibility.Visible,
            "validation-is-inline");
        Check(application.Windows.Count == 1, "validation-opens-no-dialog");
        Check(!window.TrySaveSettingsBeforeClose(), "invalid-input-blocks-close");

        port.SetCurrentValue(TextBox.TextProperty, "2121");
        Pump();
        Click(window, "HistoryNav");
        Check(Title(window) == "剪贴板记录" && settingsStore.Load().Port == 2121,
            "corrected-input-saves-and-allows-navigation");
        Click(window, "SettingsNav");
        Check(Find<TextBox>(page, "SettingPort").Text == "2121", "corrected-value-survives-reentry");
        Check(viewModel.Settings.NetworkMode == NetworkMode.Unconfigured, "fixture-remains-network-disabled");
        Check(window.TrySaveSettingsBeforeClose(), "valid-settings-allow-close");
    }

    private static async Task RunUpdateFeedbackAssertionsAsync(Application application, MainWindow window,
        AppViewModel viewModel, string root)
    {
        var source = new ControlledUpdateSource();
        var fixedNow = new DateTimeOffset(2026, 11, 12, 13, 0, 0, TimeSpan.Zero);
        var external = new AppSettings { NetworkMode = NetworkMode.External, Host = "ftp.example.invalid", Username = "smoke-user" };
        var coordinator = new UpdateCoordinator(Path.Combine(root, "feedback"), AppUpdateService.InstalledVersion,
            () => external, () => "synthetic-password", () => false, source: source,
            transport: new ForbiddenUpdateTransport(), clock: () => fixedNow);
        using var updates = new AppUpdateService(viewModel, root, coordinator);
        var status = Find<TextBlock>(window, "UpdateStatus");
        var checkedText = Find<TextBlock>(window, "UpdateLastChecked");
        // Retain the real production bindings, overriding only their inherited
        // source with an isolated service whose network ports are all fake.
        status.DataContext = new { Updates = updates };
        checkedText.DataContext = new { Updates = updates };
        try
        {
            var operation = updates.CheckAsync();
            Pump();
            Check(!operation.IsCompleted && !updates.CanCheck && status.Text == "正在检查更新…",
                "manual-check-shows-pending-state-without-network");
            Check(checkedText.Text.Contains("正在手动检查"), "manual-check-feedback-binding-updates");
            source.Response.SetResult(null);
            await operation;
            Pump();
            Check(updates.CanCheck && checkedText.Text.Contains("暂无正式更新") && checkedText.Text.Contains("下载测试版"),
                "no-stable-release-explains-manual-test-download");
            Check(checkedText.Text.Contains("手动检查完成 ") && checkedText.Text.Contains(DateTime.Now.ToString("yyyy-MM-dd")),
                "manual-check-shows-local-completion-time");
            var completedText = checkedText.Text;
            updates.Start();
            await Task.Delay(1200);
            Pump();
            Check(checkedText.Text == completedText && source.Requests == 1,
                "background-tick-preserves-manual-result-and-time");
            source.ResetPending();
            var cancelled = updates.CheckAsync();
            Pump();
            Check(viewModel.SaveSettingsNow(), "synthetic-config-save-cancels-old-manual-check");
            await cancelled;
            Pump();
            Check(checkedText.Text.Contains("检查已取消") && status.Text != "检查中",
                "cancelled-manual-check-finishes-with-explicit-feedback");
            source.Fail = true;
            await updates.CheckAsync();
            Pump();
            Check(checkedText.Text.Contains("synthetic-check-error"), "manual-check-preserves-readable-failure");
            Check(application.Windows.Count == 1, "manual-check-feedback-opens-no-dialog");
            Check(updates.DownloadPageUrl == "https://github.com/DB-XiaoQiang/shanchuan/releases" &&
                  updates.OpenDownloadsCommand.CanExecute(null), "download-entry-is-official-releases-page");
            updates.Dispose();
            var requests = source.Requests;
            await updates.CheckAsync();
            Check(!updates.CanCheck && source.Requests == requests, "disabled-check-entry-performs-no-work");
        }
        finally
        {
            status.ClearValue(FrameworkElement.DataContextProperty);
            checkedText.ClearValue(FrameworkElement.DataContextProperty);
        }
    }

    private sealed class ControlledUpdateSource : Shanchuan.Core.IUpdateSource
    {
        public TaskCompletionSource<RemoteUpdateRelease?> Response { get; private set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void ResetPending() => Response = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Requests { get; private set; }
        public bool Fail { get; set; }
        public Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token)
        {
            Requests++;
            return Fail ? Task.FromException<RemoteUpdateRelease?>(new IOException("synthetic-check-error")) : Response.Task.WaitAsync(token);
        }
        public Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token) =>
            throw new InvalidOperationException("A no-release check must not download a package.");
    }

    private sealed class ForbiddenUpdateTransport : IUpdateRelay
    {
        public Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token) =>
            throw new InvalidOperationException("This feedback smoke test must not access FTP.");
        public Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion,
            AppSettings settings, string password, CancellationToken token) =>
            throw new InvalidOperationException("This feedback smoke test must not access FTP.");
    }

    private static string Title(MainWindow window) => ((TextBlock)window.FindName("PageTitle")).Text;

    private static void Click(DependencyObject root, string id)
    {
        var button = Find<Button>(root, id);
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, button));
        Pump();
    }

    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
    {
        if (root is T matched && AutomationProperties.GetAutomationId(root) == id) return matched;
        foreach (var child in Children(root))
        {
            if (child is T result && AutomationProperties.GetAutomationId(child) == id) return result;
        }
        throw new InvalidOperationException("Missing UI control: " + id);
    }

    private static IEnumerable<DependencyObject> Children(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var nested in Children(child)) yield return nested;
        }
    }

    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => frame.Continue = false), DispatcherPriority.ApplicationIdle);
        Dispatcher.PushFrame(frame);
    }

    private static void Capture(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight),
            96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
        Check(stream.Length > 0, "settings-page-screenshot-rendered");
    }

    private static void Check(bool success, string name)
    {
        if (!success) throw new InvalidOperationException("Assertion failed: " + name);
        Checks.Add(name);
    }

    private sealed class FakeCredentials : ICredentialStore
    {
        public string? Value { get; private set; }
        public int SaveCount { get; private set; }
        public string? Read() => Value;
        public void Save(string password) { Value = password; SaveCount++; }
        public void Delete() => Value = null;
    }
}
