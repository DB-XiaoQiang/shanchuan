using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Automation;
using Microsoft.Win32;
using Shanchuan.Core;
using Shanchuan.Windows.Services;

namespace Shanchuan.GuiUpdateSmoke;

/// <summary>CI-only external UIA driver. It never loads or patches the product GUI assembly.</summary>
internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private static readonly List<string> Checks = [];
    private static string Work = "", ReportRoot = "", InstallRoot = "", AppData = "", BaseVersion = "", TargetVersion = "";
    private static readonly List<int> GuiPids = [];
    private static readonly string FixturePassword = "ci-synthetic-" + Guid.NewGuid().ToString("N");
    private static bool CreatedCredential;

    [STAThread]
    public static int Main(string[] args)
    {
        Exception? failure = null;
        try
        {
            Require(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true", "This GUI acceptance driver only runs on disposable GitHub Windows runners.");
            Require(args.Length == 6, "Expected work, old Setup, target feed, base version, target version and report directory.");
            Work = Path.GetFullPath(args[0]); InstallRoot = Path.Combine(Work, "install"); ReportRoot = Path.GetFullPath(args[5]);
            Require(IsUnder(Work, Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "missing"), "Work directory must be isolated below RUNNER_TEMP.");
            Require(IsUnder(InstallRoot, Work) && IsUnder(args[1], Work) && IsUnder(args[2], Work), "Fixture paths escaped isolated work root.");
            BaseVersion = args[3]; TargetVersion = args[4];
            Require(UpdateManifestVerifier.IsVersion(BaseVersion) && UpdateManifestVerifier.IsVersion(TargetVersion) && UpdateManifestVerifier.CompareVersions(TargetVersion, BaseVersion) > 0, "Explicit test versions invalid.");
            Directory.CreateDirectory(ReportRoot);
            AssertFreshProfile();
            // The parent removed this environment variable before creating us.
            Require(string.IsNullOrEmpty(Environment.GetEnvironmentVariable("UPDATE_MANIFEST_PRIVATE_KEY")), "Signing private key must arrive through stdin, never child environment.");
            var privateKey = Console.In.ReadToEnd();
            Require(!string.IsNullOrWhiteSpace(privateKey), "Private signing input missing.");
            var candidate = SeedVerifiedFixture(args[2], privateKey);
            privateKey = "";
            InstallBase(args[1]);
            RunRealGuiUpgrade(candidate);
        }
        catch (Exception error)
        {
            failure = error;
            Console.Error.WriteLine(error);
            TryWriteReport(false, error.ToString());
        }
        finally
        {
            try { CleanupOwnedInstallation(); }
            catch (Exception error)
            {
                if (ReportRoot.Length > 0) File.WriteAllText(Path.Combine(ReportRoot, "cleanup.log"), error.ToString());
                failure ??= error;
            }
            if (CreatedCredential)
            {
                try { new WindowsCredentialStore().Delete(); }
                catch (Exception error)
                {
                    failure ??= error;
                    File.WriteAllText(Path.Combine(ReportRoot, "credential-cleanup.log"), error.ToString());
                }
            }
        }
        if (failure is not null) return 1;
        TryWriteReport(true, null);
        Console.WriteLine("ACTUAL_PRODUCT_GUI_UPDATE_PASS " + BaseVersion + " -> " + TargetVersion);
        return 0;
    }

    private static void AssertFreshProfile()
    {
        AppData = AppDataPaths.DefaultRoot;
        Require(!Directory.Exists(AppData) && !Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shanchuan")), "Existing product data found; refusing to modify this profile.");
        Require(Process.GetProcessesByName("Shanchuan").Length == 0, "Existing Shanchuan process found.");
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var existing = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\Shanchuan");
            Require(existing is null, "Existing Shanchuan uninstall registration found.");
        }
        using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            Require(run?.GetValue("Shanchuan") is null, "Existing Shanchuan startup registration found.");
        if (CredRead("Shanchuan/FTP", 1, 0, out var credential))
        {
            CredFree(credential);
            throw new InvalidOperationException("Existing product credential found; refusing to run.");
        }
        Require(Marshal.GetLastWin32Error() == 1168, "Credential-presence guard failed.");
        Checks.Add("fresh-disposable-profile-no-existing-product-data-process-registration-or-credential");
    }

    private static VerifiedUpdate SeedVerifiedFixture(string feedRoot, string privateKeyPem)
    {
        using var feed = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(feedRoot, "releases.win-x64.json")));
        var entries = feed.RootElement.GetProperty("Assets"); Require(entries.GetArrayLength() == 1, "Target feed must contain one full release.");
        var entry = entries[0];
        Require(entry.GetProperty("PackageId").GetString() == "Shanchuan" && entry.GetProperty("Type").GetString() == "Full" && entry.GetProperty("Version").GetString() == TargetVersion, "Target feed does not describe the actual product version.");
        var packageName = entry.GetProperty("FileName").GetString()!;
        Require(UpdateManifestVerifier.IsSafeName(packageName), "Unsafe package filename.");
        UpdateAsset Asset(string name, string kind) => new()
        {
            Platform = "windows", Arch = "x64", Kind = kind, Name = name,
            Size = new FileInfo(Path.Combine(feedRoot, name)).Length, Sha256 = Digest(Path.Combine(feedRoot, name))
        };
        var assets = new[] { Asset(packageName, "velopack-full"), Asset("releases.win-x64.json", "velopack-feed") };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, product = "Shanchuan", channel = "stable", version = TargetVersion,
            releaseNotes = "CI private-cache acceptance: actual public old GUI to actual new GUI. Public prerelease discovery remains disabled.", assets
        }, JsonOptions);
        byte[] signature;
        using (var key = ECDsa.Create())
        {
            key.ImportFromPem(privateKeyPem);
            signature = key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        privateKeyPem = "";
        var verifier = UpdateManifestVerifier.CreateDefault();
        verifier.Verify(bytes, signature); // Proves CI secret matches the public key shipped in both real applications.
        Directory.CreateDirectory(AppData);
        var settings = new AppSettings { NetworkMode = NetworkMode.Unconfigured, Username = "gui-smoke-fixture", ReceiveIntervalSeconds = 600, TtlDays = 90, StartWithWindows = false };
        settings.Shortcuts.Enabled = false;
        new SettingsStore(AppData).Save(settings);
        var historyStore = new HistoryStore(AppData);
        Directory.CreateDirectory(historyStore.MediaDirectory);
        var media = Path.Combine(historyStore.MediaDirectory, "fixture.png");
        File.WriteAllBytes(media, Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0JcAAAAASUVORK5CYII="));
        historyStore.Save([
            new HistoryEntry { Kind = HistoryKind.Text, Content = "GUI update preserved history fixture", Status = "仅本地" },
            new HistoryEntry { Kind = HistoryKind.Image, Paths = [media], Status = "仅本地" }
        ]);
        var cache = new UpdateCache(Path.Combine(AppData, "Updates", "Cache"), verifier);
        var candidate = cache.ImportAsync(bytes, signature, (asset, destination, _) =>
        {
            File.Copy(Path.Combine(feedRoot, asset.Name), destination); return Task.CompletedTask;
        }).GetAwaiter().GetResult();
        var state = new UpdateState { CandidateCacheDirectory = candidate.CacheDirectory, HighestSeenVersion = TargetVersion };
        File.WriteAllText(Path.Combine(AppData, "Updates", "update-state.json"), JsonSerializer.Serialize(state, JsonOptions));
        new WindowsCredentialStore().Save(FixturePassword);
        CreatedCredential = true;
        Require(new WindowsCredentialStore().Read() == FixturePassword, "Synthetic credential fixture could not be read back.");
        Checks.Add("actual-product-key-verified-private-cache-seeded-without-changing-discovery-or-trust");
        return candidate;
    }

    private static void InstallBase(string setup)
    {
        RunProcess(setup, ["--silent", "--installto", InstallRoot, "--log", Path.Combine(ReportRoot, "old-setup.log")], 120);
        var executable = Path.Combine(InstallRoot, "current", "Shanchuan.exe");
        Require(File.Exists(executable) && ProductVersion(executable) == BaseVersion, "Original public Setup did not install the expected unmodified GUI version.");
        Checks.Add("original-public-setup-installed-version-" + BaseVersion);
    }

    private static void RunRealGuiUpgrade(VerifiedUpdate candidate)
    {
        var executable = Path.Combine(InstallRoot, "current", "Shanchuan.exe");
        var process = StartClean(executable, []);
        GuiPids.Add(process.Id);
        var oldPid = process.Id;
        var oldWindow = WaitFor(() => FindWindow(oldPid), 60, "old GUI window");
        WaitFor(() => Find(oldWindow, AutomationElement.NameProperty, "当前版本 v" + BaseVersion), 45, "old GUI footer version");
        var installButton = WaitFor(() => Find(oldWindow, AutomationElement.NameProperty, "更新至 v" + TargetVersion), 60, "verified update footer button");
        WaitFor(() => installButton.Current.IsEnabled ? installButton : null, 30, "enabled footer install button");
        var baseline = DataSnapshot();
        Require(new WindowsCredentialStore().Read() == FixturePassword, "Old GUI startup changed synthetic credentials.");
        Require(new SettingsStore(AppData).Load().NetworkMode == NetworkMode.Unconfigured, "Old GUI unexpectedly enabled network mode.");
        var managed = Path.Combine(InstallRoot, "packages", candidate.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full").Name);
        Require(!File.Exists(managed), "Real old GUI staged native target before confirmation.");
        Thread.Sleep(1500);
        Require(!File.Exists(managed) && !process.HasExited, "Real old GUI installed or staged without consent.");
        SaveScreenshot(oldWindow, "old-gui-before-approval.png");
        Checks.Add("real-old-gui-shows-candidate-without-staging-or-installing-before-consent");
        var invoke = Task.Run(() => Invoke(installButton));
        var confirmation = WaitFor(() => FindConfirmation(oldPid), 30, "native real GUI update confirmation");
        var yes = WaitFor(() => Find(confirmation, AutomationElement.AutomationIdProperty, "6"), 15, "native confirmation Yes button ID 6");
        Invoke(yes);
        Require(invoke.Wait(TimeSpan.FromSeconds(30)), "Footer click did not return after confirmation.");
        Checks.Add("real-footer-and-native-yes-confirmation-invoked");
        var newer = WaitFor(() => FindInstalledProcessExcept(oldPid), 180, "new GUI process after native replacement");
        GuiPids.Add(newer.Id);
        Require(newer.Id != oldPid && ProductVersion(executable) == TargetVersion, "Native replacement did not change PID and actual GUI version.");
        var newWindow = WaitFor(() => FindWindow(newer.Id), 60, "new GUI window");
        WaitFor(() => Find(newWindow, AutomationElement.NameProperty, "当前版本 v" + TargetVersion), 60, "new GUI footer version");
        Require(process.HasExited, "Old GUI remained running after native restart.");
        Require(new SettingsStore(AppData).Load().NetworkMode == NetworkMode.Unconfigured, "Network mode changed during upgrade.");
        Require(DataSnapshot().OrderBy(x => x.Key).SequenceEqual(baseline.OrderBy(x => x.Key)), "Settings, history or referenced media changed during GUI upgrade.");
        Require(new WindowsCredentialStore().Read() == FixturePassword, "Actual GUI upgrade changed synthetic credentials.");
        Checks.Add("synthetic-windows-credential-preserved-across-both-gui-startups");
        var settingsButton = WaitFor(() => Find(newWindow, AutomationElement.AutomationIdProperty, "SettingsNav"), 30, "new configuration navigation");
        Invoke(settingsButton);
        WaitFor(() => Find(newWindow, AutomationElement.AutomationIdProperty, "SettingsPageRoot"), 30, "embedded configuration page");
        WaitFor(() => Find(newWindow, AutomationElement.AutomationIdProperty, "SettingHost"), 15, "configuration content in main window");
        var windows = AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, newer.Id));
        Require(windows.Cast<AutomationElement>().Count(x => x.Current.Name.StartsWith("闪传", StringComparison.Ordinal)) == 1, "Configuration opened an additional settings window.");
        SaveScreenshot(newWindow, "updated-gui-settings-page.png");
        Checks.Add("actual-0.1.2-gui-restarted-with-embedded-settings-and-no-extra-settings-window");
        Checks.Add("synthetic-settings-history-and-referenced-media-byte-preserved");
        File.WriteAllText(Path.Combine(ReportRoot, "gui-processes.json"), JsonSerializer.Serialize(new { oldPid, newPid = newer.Id, oldVersion = BaseVersion, newVersion = ProductVersion(executable) }, JsonOptions));
    }

    private static Dictionary<string, string> DataSnapshot() => new[] { Path.Combine(AppData, "settings.json"), Path.Combine(AppData, "history.json"), Path.Combine(AppData, "Media", "fixture.png") }.ToDictionary(path => Path.GetRelativePath(AppData, path), Digest);
    private static string ProductVersion(string executable) => (FileVersionInfo.GetVersionInfo(executable).ProductVersion ?? "").Split('+')[0];
    private static string Digest(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
    private static bool IsUnder(string candidate, string root) => Path.GetFullPath(candidate).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static AutomationElement? Find(AutomationElement root, AutomationProperty property, object value) => root.FindFirst(TreeScope.Descendants, new PropertyCondition(property, value));
    private static AutomationElement? FindWindow(int pid) => AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, pid)).Cast<AutomationElement>().FirstOrDefault(x => x.Current.ControlType == ControlType.Window && x.Current.Name == "闪传");
    private static AutomationElement? FindConfirmation(int pid) => AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, pid)).Cast<AutomationElement>().FirstOrDefault(x => x.Current.Name == "闪传更新");
    private static Process? FindInstalledProcessExcept(int oldPid) => Process.GetProcessesByName("Shanchuan").FirstOrDefault(p => p.Id != oldPid && IsUnder(SafeProcessPath(p), InstallRoot));
    private static string SafeProcessPath(Process process) { try { return process.MainModule?.FileName ?? "missing"; } catch { return "missing"; } }
    private static T WaitFor<T>(Func<T?> action, int seconds, string description) where T : class
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(seconds);
        while (DateTimeOffset.UtcNow < deadline)
        {
            try { if (action() is { } result) return result; }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
            Thread.Sleep(200);
        }
        throw new TimeoutException("Timed out waiting for " + description);
    }
    private static void Invoke(AutomationElement element)
    {
        Require(element.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern), "Element does not expose InvokePattern: " + element.Current.Name);
        ((InvokePattern)pattern!).Invoke();
    }
    private static Process StartClean(string executable, string[] args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false };
        info.Environment.Remove("UPDATE_MANIFEST_PRIVATE_KEY");
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("Could not start fixture child.");
    }
    private static void RunProcess(string executable, string[] args, int seconds)
    {
        using var process = StartClean(executable, args);
        Require(process.WaitForExit(seconds * 1000), "Child process timed out: " + Path.GetFileName(executable));
        Require(process.ExitCode == 0, "Child process failed: " + Path.GetFileName(executable));
    }
    private static void CleanupOwnedInstallation()
    {
        if (InstallRoot.Length == 0 || !Directory.Exists(InstallRoot)) return;
        foreach (var process in Process.GetProcesses())
        {
            if (IsUnder(SafeProcessPath(process), InstallRoot)) { try { process.Kill(true); process.WaitForExit(10000); } catch { } }
            process.Dispose();
        }
        var updater = Path.Combine(InstallRoot, "Update.exe");
        if (File.Exists(updater)) RunProcess(updater, ["uninstall", "--silent", "--log", Path.Combine(ReportRoot, "gui-uninstall.log")], 60);
    }
    private static void SaveScreenshot(AutomationElement window, string name)
    {
        var handle = new IntPtr(window.Current.NativeWindowHandle);
        Require(GetWindowRect(handle, out var rect), "Could not read GUI window bounds.");
        using var image = new System.Drawing.Bitmap(Math.Max(1, rect.Right - rect.Left), Math.Max(1, rect.Bottom - rect.Top));
        using var graphics = System.Drawing.Graphics.FromImage(image);
        var dc = graphics.GetHdc();
        try { Require(PrintWindow(handle, dc, 2), "Could not capture actual product GUI."); }
        finally { graphics.ReleaseHdc(dc); }
        image.Save(Path.Combine(ReportRoot, name), ImageFormat.Png);
    }
    private static void TryWriteReport(bool passed, string? error)
    {
        if (ReportRoot.Length == 0) return;
        Directory.CreateDirectory(ReportRoot);
        File.WriteAllText(Path.Combine(ReportRoot, "gui-update-report.json"), JsonSerializer.Serialize(new
        {
            passed, baseVersion = BaseVersion, targetVersion = TargetVersion, checks = Checks, error,
            originalPublishedGuiInstaller = true, actualProductGui = true,
            discoveryMethod = "explicitly imported signed private CI cache",
            publicPrereleaseAutoDiscoveryTested = false, formalUpdateChannelEnabled = false,
            fixtureNetworkMode = "unconfigured", signingKeyPersisted = false,
            syntheticCredentialChecked = Checks.Contains("synthetic-windows-credential-preserved-across-both-gui-startups")
        }, JsonOptions));
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredRead(string target, uint type, int reserved, out IntPtr credential);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr credential);
}
