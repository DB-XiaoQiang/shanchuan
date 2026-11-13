using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

[CollectionDefinition("Application language", DisableParallelization = true)]
public sealed class ApplicationLanguageCollection { }

[Collection("Application language")]
public sealed class LocalizationTests
{
    [Fact]
    public void ChineseIsDefaultEvenOnAnEnglishSystemAndUnknownChoicesFallBack()
    {
        var previous = Localization.CurrentLanguage;
        var previousCulture = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("en-US");
            Localization.Configure(null);
            Assert.Equal("zh-Hans", Localization.CurrentLanguage);
            Assert.Equal("检查更新 / 重试", Localization.T("检查更新 / 重试"));
            Assert.Equal("zh-Hans", new AppSettings().Language);
            Assert.Equal("zh-Hans", new AppSettings { Language = "unknown" }.Language);
        }
        finally { Localization.Configure(previous); CultureInfo.CurrentUICulture = previousCulture; }
    }

    [Fact]
    public void EveryResourceHasBothLanguagesAndMatchingFormatArguments()
    {
        var chinese = Localization.GetTable("zh-Hans");
        var english = Localization.GetTable("en");
        Assert.True(chinese.Count > 300);
        Assert.Equal(chinese.Keys.Order(), english.Keys.Order());
        foreach (var (key, value) in english)
        {
            Assert.False(string.IsNullOrWhiteSpace(value));
            Assert.Equal(key, chinese[key]);
            Assert.Equal(CompositeFormat.Parse(key).MinimumArgumentCount, CompositeFormat.Parse(value).MinimumArgumentCount);
            // Language names stay in their native spelling; other English UI strings must be translated.
            if (key != "简体中文") Assert.DoesNotMatch("[\\p{IsCJKUnifiedIdeographs}]", value);
        }
    }

    [Fact]
    public void EnglishFormattingPreservesUntrustedUserContentAsAnArgument()
    {
        const string name = "报告{0}中文.zip";
        Assert.Equal("Update attachment SHA-256 verification failed: " + name,
            Localization.Format("更新附件 SHA-256 校验失败：{0}", "en", name));
        Assert.Equal("报告{0}中文.zip", Localization.Translate(name, "en"));
    }

    [Fact]
    public void SettingsLanguageRoundTripsWithoutChangingExistingConfiguration()
    {
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-language-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, "settings.json"), "{\"host\":\"synthetic.invalid\",\"directoryExclusionRules\":\"报告/\"}");
            var store = new SettingsStore(root);
            var old = store.Load();
            Assert.Equal("zh-Hans", old.Language);
            old.Language = "en";
            store.Save(old);
            var loaded = store.Load();
            Assert.Equal("en", loaded.Language);
            Assert.Equal("en", loaded.Clone().Language);
            Assert.Equal("synthetic.invalid", loaded.Host);
            Assert.Equal("报告/", loaded.DirectoryExclusionRules);
            Assert.Equal(NetworkMode.Unconfigured, loaded.NetworkMode);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void EnglishRuntimeTranslatesValidationButKeepsStoredHistoryCodesAndNetworkPolicy()
    {
        var previous = Localization.CurrentLanguage;
        try
        {
            Localization.Configure("en");
            Assert.Equal("Enter the FTP server address.", new AppSettings().ValidateForTransfer());
            Assert.Equal("Internal network · Receive only", NetworkPolicy.DisplayName(NetworkMode.Internal));
            Assert.Equal("仅本地", new HistoryEntry().Status);
            Assert.Equal("Queued", Localization.T(new HistoryEntry().CloneForResend().Status));
            Assert.Throws<InvalidOperationException>(() => NetworkPolicy.RequireUpload(new AppSettings { NetworkMode = NetworkMode.Internal }));
            Assert.Equal("Update to v0.1.4", Localization.F($"更新至 v{"0.1.4"}"));
        }
        finally { Localization.Configure(previous); }
    }

    [Fact]
    public void ExistingMessageRendersBothLanguagesWithoutRewritingOpaqueArguments()
    {
        const string userContent = "就绪{0}.zip";
        var message = Localization.M("已加入发送队列：") + userContent;
        Assert.Equal("已加入发送队列：" + userContent, message.Render("zh-Hans"));
        Assert.Equal("Added to send queue: " + userContent, message.Render("en"));
        var nested = Localization.MF($"已捕获新的剪贴板{Localization.M("图片")}，正在加入发送队列…");
        Assert.Contains("Image", nested.Render("en"));
        Assert.Contains("图片", nested.Render("zh-Hans"));
        Assert.Equal("就绪", Localization.Describe(new Exception("就绪")).Render("en"));
        var ownError = Localization.WithDescription(new InvalidDataException("更新清单签名验证失败。"), Localization.M("更新清单签名验证失败。"));
        Assert.Equal("The update manifest signature could not be verified.", Localization.Describe(ownError).Render("en"));
    }

    [Fact]
    public void RuntimeChangesNotifyOnceAndDoNotMutateProgressOrHistoricalText()
    {
        var previous = Localization.CurrentLanguage;
        Localization.Configure("zh-Hans");
        var changes = 0;
        void Changed() => changes++;
        Localization.LanguageChanged += Changed;
        try
        {
            var progress = new TransferProgressSnapshot(Guid.NewGuid(), TransferPhase.Uploading, "正在上传",
                Fraction: .25, UploadedBytes: 25, TotalBytes: 100, CurrentItemMessage: Localization.M("正在上传"));
            var log = new TransferLogEntry { Message = "正在上传" };
            Localization.Configure("en");
            Assert.Equal("Uploading", progress.DisplayCurrentItem);
            Assert.Equal("正在上传", progress.DisplayTitle);
            Assert.Equal("正在上传", log.Message);
            Assert.Equal(.25, progress.Fraction);
            Localization.Configure("en");
            Assert.Equal(1, changes);
            Localization.Configure("zh-Hans");
            Assert.Equal("正在上传", progress.DisplayCurrentItem);
            Assert.Equal(2, changes);
        }
        finally { Localization.LanguageChanged -= Changed; Localization.Configure(previous); }
    }

    [Fact]
    public void ExistingUpdateCoordinatorLocalizesWithoutCheckingOrRecreatingState()
    {
        var previous = Localization.CurrentLanguage;
        var root = Path.Combine(Path.GetTempPath(), "shanchuan-live-language-" + Guid.NewGuid().ToString("N"));
        var settingsRequests = 0;
        try
        {
            Localization.Configure("zh-Hans");
            using var updates = new UpdateCoordinator(root, "0.2.0", () => { settingsRequests++; return new AppSettings(); }, () => "", () => false);
            var state = updates.State;
            var events = 0;
            updates.Changed += _ => events++;
            Assert.Equal("等待检查更新", updates.Snapshot.Status);
            Localization.Configure("en");
            Assert.Equal("Waiting to check for updates", updates.Snapshot.Status);
            Localization.Configure("zh-Hans");
            Assert.Equal("等待检查更新", updates.Snapshot.Status);
            Assert.Same(state, updates.State);
            Assert.Equal(0, settingsRequests);
            Assert.Equal(0, events);
            Assert.Null(updates.State.LastCheckedAt);
        }
        finally { Localization.Configure(previous); if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
