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
using Localization = Shanchuan.Core.Localization;

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
        var settings = new AppSettings
        {
            NetworkMode = NetworkMode.Unconfigured,
            Host = "initial.example.invalid",
            Username = "smoke-user",
            DirectoryExclusionRules = string.Join(Environment.NewLine,
                "# 保留原有规则", ".git/", "existing-project/private-cache/")
        };
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
                RunDirectoryRulesAssertions(application, window, viewModel, settingsStore, output);
                await RunUpdateFeedbackAssertionsAsync(application, window, viewModel, dataRoot);
                RunLanguageAssertions(application, window, viewModel, settingsStore, credentials, output);
                File.WriteAllText(Path.Combine(output, "settings-smoke-report.json"), JsonSerializer.Serialize(new
                {
                    passed = true,
                    version = AppUpdateService.InstalledVersion,
                    checks = Checks,
                    screenshot = "settings-page.png",
                    directoryRulesScreenshot = "directory-rules-editor.png",
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

    private static void RunDirectoryRulesAssertions(Application application, MainWindow window,
        AppViewModel viewModel, SettingsStore settingsStore, string output)
    {
        Click(window, "SettingsNav");
        var page = Find<SettingsPage>(window, "SettingsPageRoot");
        var preview = Find<TextBox>(page, "DirectoryRulesPreview");
        var original = viewModel.Settings.DirectoryExclusionRules;
        Check(preview.IsReadOnly && preview.Text == original, "rule-preview-keeps-existing-config");
        Click(page, "OpenDirectoryRules");
        var editor = application.Windows.OfType<DirectoryRulesWindow>().Single();
        var text = Find<TextBox>(editor, "DirectoryRulesEditor");
        Check(editor.Owner == window && ReferenceEquals(editor.DataContext, viewModel),
            "rule-editor-is-owned-by-main-window-and-shares-settings");
        Check(editor.ResizeMode == ResizeMode.CanResize && text.ActualHeight > preview.ActualHeight &&
              text.AcceptsReturn && text.HorizontalScrollBarVisibility == ScrollBarVisibility.Auto &&
              text.VerticalScrollBarVisibility == ScrollBarVisibility.Auto,
            "rule-editor-provides-larger-resizable-multiline-workspace");
        var originalEditorHeight = text.ActualHeight;
        editor.Height += 80;
        Pump();
        Check(text.ActualHeight > originalEditorHeight, "resizing-rule-window-expands-editing-area");
        Click(page, "OpenDirectoryRules");
        Check(application.Windows.OfType<DirectoryRulesWindow>().Single() == editor,
            "reopening-visible-rule-editor-reuses-window");

        var longRule = "project/" + string.Concat(Enumerable.Repeat("long-directory-segment/", 15)) + "*.cache";
        var expanded = original + Environment.NewLine + longRule + Environment.NewLine + string.Join(Environment.NewLine,
            Enumerable.Range(1, 100).Select(index => $"synthetic/project-{index}/build/**"));
        text.SetCurrentValue(TextBox.TextProperty, expanded);
        Pump();
        Check(viewModel.Settings.DirectoryExclusionRules == expanded && preview.Text == expanded,
            "long-rule-input-updates-shared-settings-and-preview");
        Check(text.ExtentWidth > text.ViewportWidth && text.ExtentHeight > text.ViewportHeight,
            "long-rule-list-scrolls-in-both-directions");
        Click(editor, "EditorAddCommonRules");
        var withCommon = text.Text;
        Check(withCommon.StartsWith(expanded, StringComparison.Ordinal) && withCommon.Contains("node_modules/"),
            "adding-common-rules-preserves-original-and-long-input");
        Click(page, "AddCommonDirectoryRules");
        Check(text.Text == withCommon, "common-rules-are-idempotent-across-page-and-editor");
        Capture(editor, Path.Combine(output, "directory-rules-editor.png"));

        // Close immediately after an edit: no lost-focus event or autosave delay
        // is required for the final line to reach the persisted settings.
        var final = withCommon + Environment.NewLine + "last-keystroke-before-close.tmp";
        text.SetCurrentValue(TextBox.TextProperty, final);
        Click(editor, "CompleteDirectoryRules");
        Check(application.Windows.Count == 1 && settingsStore.Load().DirectoryExclusionRules == final,
            "rule-editor-completion-persists-final-input-and-closes");
        Check(preview.Text == final && preview.GetBindingExpression(TextBox.TextProperty) is not null,
            "preview-retains-binding-after-rule-editor-closes");
        Click(page, "OpenDirectoryRules");
        var reopened = application.Windows.OfType<DirectoryRulesWindow>().Single();
        var reopenedText = Find<TextBox>(reopened, "DirectoryRulesEditor");
        Check(reopenedText.Text == final, "reopened-rule-editor-keeps-complete-saved-rules");
        reopenedText.SetCurrentValue(TextBox.TextProperty, final + Environment.NewLine + "!unsupported-negation");
        Click(reopened, "CompleteDirectoryRules");
        Check(reopened.IsVisible && Find<TextBlock>(reopened, "DirectoryRulesValidation").Visibility == Visibility.Visible,
            "invalid-rule-shows-inline-error-and-keeps-editor-open");
        Check(settingsStore.Load().DirectoryExclusionRules == final,
            "invalid-rule-does-not-replace-last-valid-persisted-rules");
        Check(!window.TrySaveSettingsBeforeClose(), "invalid-rule-editor-blocks-main-window-close");
        reopenedText.SetCurrentValue(TextBox.TextProperty, final);
        Click(window, "HistoryNav");
        Check(application.Windows.Count == 1 && Title(window) == "剪贴板记录",
            "leaving-settings-saves-and-closes-owned-rule-editor");
        Click(window, "SettingsNav");
        Check(preview.Text == final && settingsStore.Load().DirectoryExclusionRules == final,
            "page-navigation-keeps-full-rules-after-editor-reopens");
        Check(application.Windows.Count == 1 && viewModel.Settings.NetworkMode == NetworkMode.Unconfigured,
            "rule-editor-validation-keeps-network-disabled-and-no-stray-window");
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
        application.Resources = (ResourceDictionary)XamlReader.Parse(dictionary.ToString()
            .Replace("clr-namespace:Shanchuan.Windows", "clr-namespace:Shanchuan.Windows;assembly=Shanchuan", StringComparison.Ordinal));
    }

    private static void RunLanguageAssertions(Application application, MainWindow window,
        AppViewModel viewModel, SettingsStore store, FakeCredentials credentials, string output)
    {
        Check(Localization.CurrentLanguage == "zh-Hans" && window.Title == "闪传", "chinese-default-independent-of-os-language");
        AssertUpdateDialog(application, window, "闪传更新", "更新并重启", "稍后");
        Click(window, "SettingsNav");
        var page = Find<SettingsPage>(window, "SettingsPageRoot");
        var choice = Find<ComboBox>(page, "SettingLanguage");
        Check((string)choice.SelectedValue == "zh-Hans", "default-language-choice-is-simplified-chinese");
        var settings = viewModel.Settings;
        var savedHost = store.Load().Host;
        var host = Find<TextBox>(page, "SettingHost");
        var port = Find<TextBox>(page, "SettingPort");
        var originalPort = port.Text;
        host.SetCurrentValue(TextBox.TextProperty, "unsaved-draft.example.invalid");
        host.Select(3, 7);
        port.SetCurrentValue(TextBox.TextProperty, "invalid-number-draft");
        Pump();
        Check(Validation.GetHasError(port), "runtime-language-fixture-keeps-invalid-numeric-draft");
        var password = Find<PasswordBox>(page, "SettingPassword").Password;

        // Use synthetic presentation state only: no clipboard, FTP worker,
        // credential API, global hotkey or real upload is started.
        var history = (List<HistoryEntry>)typeof(AppViewModel).GetField("_history", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(viewModel)!;
        history.Add(new HistoryEntry { Kind = HistoryKind.Text, Content = "就绪", Status = "仅本地" });
        viewModel.SearchText = "就绪";
        viewModel.KindFilter = "文本";
        var selected = viewModel.HistoryRows.Single();
        viewModel.SelectedHistory = selected;
        viewModel.Logs.Add(new TransferLogEntry { Level = TransferLogLevel.Warning, Message = "就绪" });
        viewModel.ReportHotkeyError("就绪");
        var logs = viewModel.Logs.Select(x => x.Message).ToArray();
        var progress = new TransferProgressSnapshot(Guid.NewGuid(), TransferPhase.Uploading, "就绪", Fraction: .25,
            UploadedBytes: 25, TotalBytes: 100, QueuedCount: 3, CurrentItemMessage: Localization.M("正在上传"));
        var progressWindow = new ProgressWindow(viewModel);
        typeof(AppViewModel).GetProperty(nameof(AppViewModel.Progress))!.SetValue(viewModel, progress);
        var captureFlag = typeof(AppViewModel).GetField("_copyCaptureInProgress", BindingFlags.NonPublic | BindingFlags.Instance)!;
        captureFlag.SetValue(viewModel, 1);
        Click(window, "OpenDirectoryRules");
        var editor = application.Windows.OfType<DirectoryRulesWindow>().Single();
        var rules = Find<TextBox>(editor, "DirectoryRulesEditor");
        var draftRules = string.Join(Environment.NewLine, Enumerable.Range(1, 140).Select(i => $"synthetic-directory-{i}/"));
        rules.SetCurrentValue(TextBox.TextProperty, draftRules);
        rules.Select(20, 12);
        rules.ScrollToLine(60);
        var scroll = (ScrollViewer)page.FindName("SettingsScroll");
        scroll.ScrollToVerticalOffset(105);
        Pump();
        var ruleOffset = rules.VerticalOffset;
        var pageOffset = scroll.VerticalOffset;
        var hostSelection = (host.SelectionStart, host.SelectionLength);
        var credentialWrites = credentials.SaveCount;
        var transferGate = viewModel.UpdateTransferGate;
        var gateCount = transferGate.CurrentCount;
        var receiveSignal = (System.Threading.SemaphoreSlim)typeof(AppViewModel).GetField("_receiveSignal", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(viewModel)!;
        var receiveSignalCount = receiveSignal.CurrentCount;
        var settingsEvents = 0;
        void Applied(object? sender, EventArgs e) => settingsEvents++;
        viewModel.SettingsApplied += Applied;
        try
        {
            foreach (var language in new[] { "en", "zh-Hans" })
            {
                choice.SelectedValue = language;
                Pump();
                var english = language == "en";
                Check(Localization.CurrentLanguage == language && window.Title == (english ? "Shanchuan" : "闪传"), "runtime-window-title-" + language);
                Check(Title(window) == (english ? "Settings" : "配置中心"), "runtime-page-title-" + language);
                Check(ReferenceEquals(page, Find<SettingsPage>(window, "SettingsPageRoot")) && ReferenceEquals(page.DataContext, viewModel) && ReferenceEquals(settings, viewModel.Settings), "runtime-same-page-model-and-settings-" + language);
                Check(Find<Button>(window, "CheckUpdates").Content as string == (english ? "Check for updates / Retry" : "检查更新 / 重试"), "runtime-update-button-" + language);
                Check(editor.Title == (english ? "Directory exclusion rules" : "目录排除规则") && Find<Button>(editor, "CompleteDirectoryRules").Content as string == (english ? "Done" : "完成"), "runtime-existing-rules-window-" + language);
                Check(rules.Text == draftRules && rules.SelectionStart == 20 && rules.SelectionLength == 12 && Math.Abs(rules.VerticalOffset - ruleOffset) < 1, "runtime-rules-text-selection-and-scroll-preserved-" + language);
                Check(host.Text == "unsaved-draft.example.invalid" && (host.SelectionStart, host.SelectionLength) == hostSelection && port.Text == "invalid-number-draft" && Validation.GetHasError(port), "runtime-invalid-input-and-selection-preserved-" + language);
                Check(Math.Abs(scroll.VerticalOffset - pageOffset) < 1 && Find<PasswordBox>(page, "SettingPassword").Password == password, "runtime-page-scroll-and-secret-draft-preserved-" + language);
                Check(store.Load().Language == language && store.Load().Host == savedHost && credentials.SaveCount == credentialWrites, "runtime-language-only-persistence-without-credential-write-" + language);
                Check(settingsEvents == 0 && transferGate.CurrentCount == gateCount && receiveSignal.CurrentCount == receiveSignalCount && viewModel.HasBusinessTransfers && ReferenceEquals(progress, viewModel.Progress), "runtime-no-service-events-or-task-state-change-" + language);
                Check(ReferenceEquals(selected, viewModel.SelectedHistory) && viewModel.HistoryRows.Single() == selected && viewModel.SearchText == "就绪" && viewModel.KindFilter == "文本" && selected.Title == "就绪", "runtime-history-filter-selection-and-user-text-preserved-" + language);
                Check(viewModel.Logs.Select(x => x.Message).SequenceEqual(logs), "runtime-historical-log-content-preserved-" + language);
                Check(viewModel.StatusMessage == (english ? "Shortcuts unavailable: 就绪" : "快捷键不可用：就绪"), "runtime-current-status-localized-user-argument-opaque-" + language);
                Check(((TextBlock)progressWindow.FindName("PhaseText")).Text == (english ? "Uploading" : "正在上传") && ((TextBlock)progressWindow.FindName("TitleText")).Text == "就绪", "runtime-existing-progress-window-" + language);
                AssertUpdateDialog(application, window, english ? "Shanchuan update" : "闪传更新", english ? "Update and restart" : "更新并重启", english ? "Later" : "稍后");
                Capture(window, Path.Combine(output, english ? "settings-page-english.png" : "settings-page-live-chinese.png"));
                Capture(editor, Path.Combine(output, english ? "directory-rules-editor-english.png" : "directory-rules-editor-live-chinese.png"));
            }
        }
        finally
        {
            viewModel.SettingsApplied -= Applied;
            captureFlag.SetValue(viewModel, 0);
            progressWindow.CloseForShutdown();
            port.SetCurrentValue(TextBox.TextProperty, originalPort);
            host.SetCurrentValue(TextBox.TextProperty, savedHost);
            Pump();
            Click(editor, "CompleteDirectoryRules");
            if (Localization.CurrentLanguage != "zh-Hans") viewModel.ChangeLanguage("zh-Hans");
        }
        Check(application.Windows.Count == 1, "runtime-language-roundtrip-no-replacement-or-stray-windows");
    }

    private static void AssertUpdateDialog(Application application, Window owner, string title, string update, string later)
    {
        Exception? failure = null;
        var initialLanguage = Localization.CurrentLanguage;
        owner.Dispatcher.BeginInvoke(new Action(() =>
        {
            Window? dialog = null;
            try
            {
                dialog = application.Windows.OfType<Window>().Single(x => x.Title == title);
                Check(Find<Button>(dialog, "ConfirmUpdateInstall").Content as string == update, "localized-update-dialog-affirmative-" + Localization.CurrentLanguage);
                var postpone = Find<Button>(dialog, "DialogNo");
                Check(postpone.Content as string == later && postpone.IsDefault, "localized-update-dialog-safe-default-" + Localization.CurrentLanguage);
                var updateButton = Find<Button>(dialog, "ConfirmUpdateInstall");
                var opposite = initialLanguage == "en" ? "zh-Hans" : "en";
                Localization.Configure(opposite);
                Pump();
                Check(dialog.Title == (opposite == "en" ? "Shanchuan update" : "闪传更新") &&
                    ReferenceEquals(updateButton, Find<Button>(dialog, "ConfirmUpdateInstall")) &&
                    updateButton.Content as string == (opposite == "en" ? "Update and restart" : "更新并重启"), "runtime-existing-dialog-title-and-button-" + initialLanguage);
                var message = Find<TextBlock>(dialog, "UpdateDialogMessage").Text;
                Check(message.Contains(opposite == "en" ? "Target version" : "目标版本") && message.Contains("就绪"), "runtime-existing-dialog-message-and-opaque-notes-" + initialLanguage);
                Localization.Configure(initialLanguage);
                Pump();
                postpone.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, postpone));
            }
            catch (Exception error) { failure = error; dialog?.Close(); }
            finally { Localization.Configure(initialLanguage); }
        }), DispatcherPriority.ApplicationIdle);
        var approved = LocalizedMessageBox.ConfirmUpdate(owner,
            Localization.MF($"当前版本：v{"0.1.4"}\n目标版本：v{"0.2.0"}\n\n{"就绪"}\n\n"), Localization.M("闪传更新"));
        if (failure is not null) throw failure;
        Check(!approved, "localized-update-dialog-later-does-not-approve-" + Localization.CurrentLanguage);
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
        Check(stream.Length > 0, Path.GetFileNameWithoutExtension(path) + "-screenshot-rendered");
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
