using System.Text.Json;
using Shanchuan.Windows.Services;
using Xunit;

namespace Shanchuan.Core.Tests;

public sealed class UpdateAuthorizationTests
{
    private const string Digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    [Fact]
    public void DownloadOrNewVersionAloneIsNotPermissionToInstall()
    {
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(null, "0.3.0", "0.4.0", Digest));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(new("0.4.0", Digest), "0.3.0", "0.5.0", Digest));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(new("0.4.0", Digest), "0.3.0", "0.4.0", new string('f', 64)));
    }

    [Fact]
    public void PersistedApprovalOnlyAppliesToExactNewerRelease()
    {
        var original = new UpdateInstallAuthorization("0.4.0", Digest);
        var restored = JsonSerializer.Deserialize<UpdateInstallAuthorization>(JsonSerializer.Serialize(original));
        Assert.True(UpdateInstallAuthorizationPolicy.AllowsInstallation(restored, "0.3.0", "0.4.0", Digest));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(restored, "0.4.0", "0.4.0", Digest));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(restored, "0.5.0", "0.4.0", Digest));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(new("0.4.0", "invalid"), "0.3.0", "0.4.0", "invalid"));
        Assert.False(UpdateInstallAuthorizationPolicy.AllowsInstallation(restored, "invalid", "0.4.0", Digest));
    }
}
