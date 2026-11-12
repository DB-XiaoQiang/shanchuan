using Shanchuan.Core;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed class DirectoryExclusionsTests
{
    [Theory]
    [InlineData(".git/", ".git", true, true)]
    [InlineData(".git/", ".git/config", false, false)]
    [InlineData("node_modules/", "a/node_modules", true, true)]
    [InlineData("*.log", "src/debug.log", false, true)]
    [InlineData("*.log", "src/debug.txt", false, false)]
    [InlineData("src/**/*.log", "src/a/b/error.log", false, true)]
    [InlineData("src/**/*.log", "other/error.log", false, false)]
    [InlineData("/dist/", "dist", true, true)]
    [InlineData("/dist/", "nested/dist", true, false)]
    [InlineData("file?.txt", "file1.txt", false, true)]
    public void MatchesExpectedPaths(string pattern, string path, bool directory, bool expected) =>
        Assert.Equal(expected, DirectoryExclusions.Parse(pattern).Excludes(path, directory));

    [Theory]
    [InlineData("!keep.txt")]
    [InlineData("a/../b")]
    [InlineData("a\\b")]
    [InlineData("a//b")]
    public void RejectsUnsafeOrUnsupportedRules(string pattern) =>
        Assert.Throws<ArgumentException>(() => DirectoryExclusions.Parse(pattern));

    [Fact]
    public void EmptyAndCommentLinesAreIgnored()
    {
        var rules = DirectoryExclusions.Parse("\n# comment\n*.tmp\n");
        Assert.False(rules.IsEmpty);
        Assert.True(rules.Excludes("a/file.tmp", false));
    }
}
