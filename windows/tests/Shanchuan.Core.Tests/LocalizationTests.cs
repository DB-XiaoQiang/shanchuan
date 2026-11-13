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
}
