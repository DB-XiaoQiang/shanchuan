using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using Shanchuan.Core;
using Shanchuan.Windows.Services;
using Velopack;
using Velopack.Locators;

namespace Shanchuan.UpdateSmoke;

/// <summary>
/// CI-only console payload used to exercise the real native Setup and Update.exe.
/// It is never included in Shanchuan.Windows or in user release packages.
/// </summary>
internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private static string Root = "";
    private static string BaseVersion = "";
    private static string TargetVersion = "";
    private static string Version => (Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0").Split('+')[0];

    public static int Main(string[] args)
    {
        // Installer fast-exit hooks must run before any fixture or normal-app code.
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        try
        {
            Require(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true", "Native smoke is restricted to disposable Windows GitHub runners.");
            Root = Path.GetFullPath(Environment.GetEnvironmentVariable("SHANCHUAN_UPDATE_SMOKE_ROOT") ?? throw new InvalidOperationException("Missing isolated smoke root."));
            var runnerTemp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new InvalidOperationException("Missing runner temp."));
            Require(IsUnder(Root, runnerTemp), "Smoke root must be below RUNNER_TEMP.");
            BaseVersion = Environment.GetEnvironmentVariable("SHANCHUAN_UPDATE_SMOKE_BASE") ?? "";
            TargetVersion = Environment.GetEnvironmentVariable("SHANCHUAN_UPDATE_SMOKE_TARGET") ?? "";
            Require(UpdateManifestVerifier.IsVersion(BaseVersion) && UpdateManifestVerifier.IsVersion(TargetVersion) && UpdateManifestVerifier.CompareVersions(TargetVersion, BaseVersion) > 0, "Explicit smoke versions are invalid.");
            if (args.Contains("--prepare-fixture")) { PrepareFixture(); return 0; }
            return RunAsync(args).GetAwaiter().GetResult();
        }
        catch (Exception error)
        {
            if (Root.Length > 0)
            {
                try { Write("failure.json", new { version = Version, error = error.ToString(), pid = Environment.ProcessId }); }
                catch { }
            }
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private static async Task<int> RunAsync(string[] args)
    {
        Require(IsUnder(Environment.ProcessPath!, Path.Combine(Root, "install")), "The smoke must run from its actual isolated installation.");
        var manager = new UpdateManager();
        Require(manager.IsInstalled, "Setup did not produce an installed Velopack application.");
        Require(manager.CurrentVersion?.ToString() == Version, "Native installed manifest and assembly version differ.");
        if (Version == TargetVersion)
        {
            Require(args.Contains("--smoke-restarted"), "Target must be relaunched by the native updater, not directly started by the script.");
            using var applying = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Root, "applying.json")));
            var oldPid = applying.RootElement.GetProperty("oldPid").GetInt32();
            Require(oldPid != Environment.ProcessId, "Update did not restart the application process.");
            VerifyUserData();
            Write("success.json", new
            {
                oldVersion = BaseVersion, newVersion = Version, oldPid, newPid = Environment.ProcessId,
                signedManifestVerified = true, noInstallBeforeApproval = true, wrongApprovalRejected = true,
                nativeSetupInstalled = true, nativeUpdateRestarted = true, userDataPreserved = true,
                installedExecutable = Environment.ProcessPath, completedUtc = DateTimeOffset.UtcNow
            });
            return 0;
        }
        Require(Version == BaseVersion, "Unexpected base assembly version.");
        VerifyUserData();
        var publicKey = File.ReadAllText(Path.Combine(Root, "fixture-public-key.pem"));
        var verifier = new UpdateManifestVerifier(publicKey);
        var source = new FixtureSource(Path.Combine(Root, "feed"));
        using var coordinator = new UpdateCoordinator(Path.Combine(Root, "coordinator"), Version,
            () => new AppSettings { NetworkMode = NetworkMode.External, Host = "127.0.0.1", Username = "synthetic", Directory = "/" },
            () => "synthetic-not-a-credential", () => false, verifier, source, new NoNetworkRelay());
        coordinator.Log += line => File.AppendAllText(Path.Combine(Root, "coordinator.log"), line + Environment.NewLine);
        await coordinator.CheckAsync();
        var candidate = coordinator.GetCandidateForInstall() ?? throw new InvalidOperationException("Production coordinator did not acquire a verified candidate.");
        Require(candidate.Manifest.Version == TargetVersion, "Coordinator selected another target.");
        var full = candidate.Manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
        var packages = VelopackLocator.Current.PackagesDir ?? throw new InvalidOperationException("Native packages directory unavailable.");
        Require(IsUnder(packages, Path.Combine(Root, "install")), "Native managed packages escaped the isolated install.");
        Require(!UpdateInstallAuthorizationPolicy.AllowsInstallation(null, Version, candidate.Manifest.Version, candidate.ManifestHash), "Null approval must not allow installation.");
        Require(manager.UpdatePendingRestart is null && !File.Exists(Path.Combine(packages, full.Name)), "Background acquisition staged a managed package before approval.");
        await Task.Delay(1500);
        Require(manager.UpdatePendingRestart is null && !File.Exists(Path.Combine(packages, full.Name)), "An unapproved update became pending.");
        Write("awaiting-approval.json", new { currentVersion = Version, targetVersion = candidate.Manifest.Version, manifestHash = candidate.ManifestHash, oldPid = Environment.ProcessId });

        var approvalPath = Path.Combine(Root, "approval.json");
        var deadline = DateTimeOffset.UtcNow.AddMinutes(2);
        var rejected = false;
        while (true)
        {
            Require(DateTimeOffset.UtcNow < deadline, "Timed out waiting for explicit isolated-test approval.");
            if (!File.Exists(approvalPath)) { await Task.Delay(200); continue; }
            UpdateInstallAuthorization? approval;
            try { approval = JsonSerializer.Deserialize<UpdateInstallAuthorization>(await File.ReadAllTextAsync(approvalPath), JsonOptions); }
            catch (JsonException) { await Task.Delay(100); continue; }
            if (!UpdateInstallAuthorizationPolicy.AllowsInstallation(approval, Version, candidate.Manifest.Version, candidate.ManifestHash))
            {
                File.Delete(approvalPath);
                rejected = true;
                Require(manager.UpdatePendingRestart is null && !File.Exists(Path.Combine(packages, full.Name)), "Wrong approval staged or applied an update.");
                Write("rejected-approval.json", new { version = Version, rejected = true, noManagedTarget = true });
                continue;
            }
            Require(rejected, "The test must prove a mismatched approval is rejected first.");
            break;
        }
        candidate = coordinator.GetCandidateForInstall() ?? throw new InvalidOperationException("Candidate vanished after approval.");
        var approved = JsonSerializer.Deserialize<UpdateInstallAuthorization>(await File.ReadAllTextAsync(approvalPath), JsonOptions);
        Require(UpdateInstallAuthorizationPolicy.AllowsInstallation(approved, Version, candidate.Manifest.Version, candidate.ManifestHash), "Candidate changed after approval.");
        var localManager = new UpdateManager(candidate.CacheDirectory, new UpdateOptions { ExplicitChannel = "win-x64" });
        var update = await localManager.CheckForUpdatesAsync() ?? throw new InvalidOperationException("Native updater did not find the verified local target.");
        Require(update.TargetFullRelease.Version.ToString() == candidate.Manifest.Version && update.TargetFullRelease.FileName == full.Name &&
            update.TargetFullRelease.Size == full.Size && string.Equals(update.TargetFullRelease.SHA256, full.Sha256, StringComparison.OrdinalIgnoreCase), "Native updater selected a package different from the signed manifest.");
        await localManager.DownloadUpdatesAsync(update);
        await UpdateManifestVerifier.VerifyAssetAsync(Path.Combine(packages, full.Name), full);
        VerifyUserData();
        Write("applying.json", new { oldPid = Environment.ProcessId, oldVersion = Version, targetVersion = TargetVersion, manifestHash = candidate.ManifestHash });
        localManager.ApplyUpdatesAndRestart(update.TargetFullRelease, ["--smoke-restarted"]);
        throw new InvalidOperationException("ApplyUpdatesAndRestart returned without terminating the old process.");
    }

    private static void PrepareFixture()
    {
        Require(Version == TargetVersion, "Fixture generation must use the explicit target build.");
        var feedRoot = Path.Combine(Root, "feed");
        var feedPath = Path.Combine(feedRoot, "releases.win-x64.json");
        using var feed = JsonDocument.Parse(File.ReadAllBytes(feedPath));
        var entries = feed.RootElement.GetProperty("Assets");
        Require(entries.GetArrayLength() == 1, "Fixture feed must contain one complete target package.");
        var target = entries[0];
        var packageName = target.GetProperty("FileName").GetString()!;
        Require(UpdateManifestVerifier.IsSafeName(packageName) && target.GetProperty("PackageId").GetString() == "Shanchuan" &&
                target.GetProperty("Version").GetString() == TargetVersion && target.GetProperty("Type").GetString() == "Full", "Wrong fixture package metadata.");
        UpdateAsset Asset(string name, string kind)
        {
            var file = Path.Combine(feedRoot, name);
            return new UpdateAsset { Platform = "windows", Arch = "x64", Kind = kind, Name = name,
                Size = new FileInfo(file).Length, Sha256 = Digest(file) };
        }
        var assets = new[] { Asset(packageName, "velopack-full"), Asset("releases.win-x64.json", "velopack-feed") };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, product = "Shanchuan", channel = "stable", version = TargetVersion,
            releaseNotes = "Isolated native update smoke. No public update channel is enabled.", assets
        }, JsonOptions);
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        File.WriteAllText(Path.Combine(Root, "fixture-public-key.pem"), key.ExportSubjectPublicKeyInfoPem());
        File.WriteAllBytes(Path.Combine(feedRoot, UpdateManifestVerifier.ManifestName), bytes);
        File.WriteAllBytes(Path.Combine(feedRoot, UpdateManifestVerifier.SignatureName), key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));
        var dataRoot = Path.Combine(Root, "user-data");
        Directory.CreateDirectory(dataRoot);
        File.WriteAllText(Path.Combine(dataRoot, "settings.json"), "{\"networkMode\":\"unconfigured\",\"sentinel\":\"preserve-settings\"}");
        File.WriteAllText(Path.Combine(dataRoot, "history.json"), "[{\"sentinel\":\"preserve-history\"}]");
        File.WriteAllBytes(Path.Combine(dataRoot, "media.bin"), [1, 2, 3, 4, 5]);
        Write("data-snapshot.json", Directory.EnumerateFiles(dataRoot).ToDictionary(path => Path.GetFileName(path)!, Digest));
        // No private key is persisted, exported or read from GitHub secrets.
        Write("fixture-ready.json", new { baseVersion = BaseVersion, targetVersion = TargetVersion });
    }

    private static void VerifyUserData()
    {
        var expected = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(Root, "data-snapshot.json")), JsonOptions)!;
        foreach (var (file, digest) in expected)
            Require(Digest(Path.Combine(Root, "user-data", file)) == digest, "Native update changed user-data fixture: " + file);
    }
    private static string Digest(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
    private static bool IsUnder(string candidate, string root) => Path.GetFullPath(candidate).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void Write(string name, object value)
    {
        Directory.CreateDirectory(Root);
        var path = Path.Combine(Root, name);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, JsonOptions));
        File.Move(temporary, path, true);
    }

    private sealed class FixtureSource(string directory) : Shanchuan.Core.IUpdateSource
    {
        public Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token) => Task.FromResult<RemoteUpdateRelease?>(new("v" + TargetVersion,
            File.ReadAllBytes(Path.Combine(directory, UpdateManifestVerifier.ManifestName)), File.ReadAllBytes(Path.Combine(directory, UpdateManifestVerifier.SignatureName))));
        public Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token)
        {
            Require(tag == "v" + TargetVersion, "Fixture requested another version.");
            File.Copy(Path.Combine(directory, asset.Name), destination);
            return Task.CompletedTask;
        }
    }
    private sealed class NoNetworkRelay : IUpdateRelay
    {
        public Task RelayAsync(VerifiedUpdate candidate, AppSettings settings, string password, CancellationToken token) => Task.CompletedTask;
        public Task<VerifiedUpdate?> ReceiveAsync(UpdateCache cache, UpdateManifestVerifier verifier, string minimumVersion, AppSettings settings, string password, CancellationToken token) => throw new InvalidOperationException("This native smoke must not perform FTP receive.");
    }
}
