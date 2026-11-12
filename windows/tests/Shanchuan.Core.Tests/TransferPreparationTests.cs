using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed class TransferPreparationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "shanchuan-tests-" + Guid.NewGuid().ToString("N"));

    public TransferPreparationTests() => Directory.CreateDirectory(_root);
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }

    private string Source(string name, string content = "abc")
    {
        var path = Path.Combine(_root, name);
        File.WriteAllBytes(path, new UTF8Encoding(false).GetBytes(content));
        return path;
    }

    private static AppSettings Preferences() => new() { Directory = "/share/" };

    [Fact]
    public void TextIsExactUtf8WithTimestampedControl()
    {
        var text = "你好\r\nfile=literal|text, preserved\n";
        using var plan = TransferPreparationService.Prepare(new HistoryEntry { Kind = HistoryKind.Text, Content = text }, Preferences(), 123456);
        Assert.Single(plan.Files);
        Assert.Equal("copy.temp.123456", plan.Files[0].RemoteName);
        Assert.Equal("/share/system_temp", plan.Files[0].Directory);
        Assert.Equal(new UTF8Encoding(false).GetBytes(text), File.ReadAllBytes(plan.Files[0].LocalPath));
    }

    [Fact]
    public void FileManifestUsesOriginalNamesAndStablePayloadSnapshot()
    {
        var text = Source("a.txt");
        var office = Source("document.docx");
        var entry = new HistoryEntry { Kind = HistoryKind.File, Paths = [text, office] };
        using var plan = TransferPreparationService.Prepare(entry, Preferences(), 42);

        Assert.Equal(["a", "document.docx", "copy.temp.42"], plan.Files.Select(file => file.RemoteName));
        Assert.Equal("file=a.txt|900150983cd24fb0d6963f7d28e17f72,document.docx|900150983cd24fb0d6963f7d28e17f72\r\n42",
            File.ReadAllText(plan.Files[^1].LocalPath, Encoding.UTF8));
        File.WriteAllText(text, "changed after planning");
        Assert.Equal("abc", File.ReadAllText(plan.Files[0].LocalPath));
    }

    [Fact]
    public void OfficeMarkerRequiresBytesAndFlag()
    {
        var file = Source("marked.docx", "877D1Cpayload");
        var entry = new HistoryEntry { Kind = HistoryKind.File, Paths = [file] };
        var settings = Preferences();
        settings.Directory = "/group/share///";
        settings.DecryptPrefix = "/decrypt///";

        using (var marked = TransferPreparationService.Prepare(entry, settings, 2))
        {
            Assert.Equal("/decrypt/share", marked.Files[0].Directory);
            Assert.StartsWith("file=877D1C:marked.docx|", File.ReadAllText(marked.Files[^1].LocalPath));
        }
        settings.AutoDecrypt = false;
        using var plain = TransferPreparationService.Prepare(entry, settings, 3);
        Assert.Equal("/group/share/system_temp", plain.Files[0].Directory);
        Assert.StartsWith("file=marked.docx|", File.ReadAllText(plain.Files[^1].LocalPath));
    }

    [Fact]
    public void FolderIsUtf8ZipWithoutWrappingRootAndControlIsLast()
    {
        var folder = Path.Combine(_root, "资料");
        Directory.CreateDirectory(Path.Combine(folder, "nested"));
        File.WriteAllText(Path.Combine(folder, "说明.txt"), "中文", Encoding.UTF8);
        File.WriteAllText(Path.Combine(folder, "nested", "check.txt"), "ok", Encoding.UTF8);
        var entry = new HistoryEntry { Kind = HistoryKind.File, Paths = [folder] };
        using var plan = TransferPreparationService.Prepare(entry, Preferences(), 5);

        Assert.Equal("资料", plan.Files[0].RemoteName);
        using var archive = ZipFile.OpenRead(plan.Files[0].LocalPath);
        Assert.Contains("说明.txt", archive.Entries.Select(item => item.FullName));
        Assert.Contains("nested/check.txt", archive.Entries.Select(item => item.FullName));
        Assert.DoesNotContain(archive.Entries, item => item.FullName.StartsWith("资料/"));
        var manifest = File.ReadAllText(plan.Files[^1].LocalPath);
        Assert.StartsWith("file=folder:资料|", manifest);
        Assert.EndsWith("\r\n5", manifest);
        Assert.Equal(32, manifest.Split('|')[1].Split("\r\n")[0].Length);
    }

    [Fact]
    public void DirectoryRulesApplyBeforeZipAndSourceIsUnchanged()
    {
        var folder = Path.Combine(_root, "project");
        Directory.CreateDirectory(Path.Combine(folder, "node_modules", "pkg"));
        Directory.CreateDirectory(Path.Combine(folder, "src"));
        File.WriteAllText(Path.Combine(folder, "node_modules", "pkg", "a.js"), "excluded");
        File.WriteAllText(Path.Combine(folder, "debug.log"), "excluded");
        File.WriteAllText(Path.Combine(folder, "src", "keep.txt"), "kept");
        File.WriteAllText(Path.Combine(folder, "src", "drop.log"), "excluded");
        var settings = Preferences();
        settings.DirectoryExclusionRules = "node_modules/\n*.log";
        using var plan = TransferPreparationService.Prepare(new HistoryEntry { Kind = HistoryKind.File, Paths = [folder] }, settings, 8);

        Assert.Equal(3, plan.ExcludedItemCount);
        using var archive = ZipFile.OpenRead(plan.Files[0].LocalPath);
        var fileEntry = Assert.Single(archive.Entries, item => !string.IsNullOrEmpty(item.Name));
        Assert.Equal("src/keep.txt", fileEntry.FullName);
        Assert.True(File.Exists(Path.Combine(folder, "node_modules", "pkg", "a.js")));
        Assert.True(File.Exists(Path.Combine(folder, "debug.log")));
    }

    [Fact]
    public void RejectsAmbiguousNamesAndEntityCollisions()
    {
        foreach (var name in new[] { "bad,name.txt", "bad|name.txt", "bad\nname.txt", "folder:literal", "." })
            Assert.NotNull(ProtocolValidation.ValidateName(name));

        var a = Source("same.txt", "a");
        var b = Source("same.bin", "b");
        Assert.Throws<InvalidDataException>(() => TransferPreparationService.Prepare(
            new HistoryEntry { Kind = HistoryKind.File, Paths = [a, b] }, Preferences(), 7));
    }
}
