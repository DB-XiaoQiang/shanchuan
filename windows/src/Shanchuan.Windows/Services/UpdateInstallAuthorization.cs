using Shanchuan.Core;

namespace Shanchuan.Windows.Services;

/// <summary>Approval is bound to the exact verified release, not merely to a downloaded package.</summary>
public sealed record UpdateInstallAuthorization(string Version, string ManifestHash);

public static class UpdateInstallAuthorizationPolicy
{
    public static bool AllowsInstallation(UpdateInstallAuthorization? approval, string currentVersion,
        string? candidateVersion, string? candidateManifestHash)
    {
        if (approval is null || !UpdateManifestVerifier.IsVersion(currentVersion) ||
            !UpdateManifestVerifier.IsVersion(candidateVersion) ||
            !UpdateManifestVerifier.IsVersion(approval.Version) ||
            approval.ManifestHash is null || approval.ManifestHash.Length != 64 ||
            !approval.ManifestHash.All(Uri.IsHexDigit)) return false;
        return UpdateManifestVerifier.CompareVersions(candidateVersion!, currentVersion) > 0 &&
            string.Equals(approval.Version, candidateVersion, StringComparison.Ordinal) &&
            string.Equals(approval.ManifestHash, candidateManifestHash, StringComparison.OrdinalIgnoreCase);
    }
}
