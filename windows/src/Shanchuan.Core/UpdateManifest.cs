using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shanchuan.Core;

public sealed record UpdateAsset
{
    public string Platform { get; init; } = "";
    public string Arch { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Name { get; init; } = "";
    public long Size { get; init; }
    public string Sha256 { get; init; } = "";
}

public sealed record UpdateManifest
{
    public int SchemaVersion { get; init; }
    public string Product { get; init; } = "";
    public string Channel { get; init; } = "";
    public string Version { get; init; } = "";
    public string ReleaseNotes { get; init; } = "";
    public List<UpdateAsset> Assets { get; init; } = [];
    public IReadOnlyList<UpdateAsset> WindowsUpdateAssets => Assets
        .Where(x => x.Platform == "windows" && x.Arch == "x64" && x.Kind is "velopack-full" or "velopack-feed").ToList();
}

/// <summary>Verifies publisher authorization before reading any manifest-provided paths.</summary>
public sealed class UpdateManifestVerifier(string publicKeyPem)
{
    public const int MaxManifestBytes = 256 * 1024;
    public const long MaxAssetBytes = 2L * 1024 * 1024 * 1024;
    public const string ManifestName = "update-manifest.json";
    public const string SignatureName = "update-manifest.sig";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly Regex VersionPattern = new(@"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$", RegexOptions.CultureInvariant);
    private static readonly Regex NamePattern = new(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$", RegexOptions.CultureInvariant);
    private static readonly Regex HashPattern = new("^[a-f0-9]{64}$", RegexOptions.CultureInvariant);

    public static UpdateManifestVerifier CreateDefault()
    {
        using var stream = typeof(UpdateManifestVerifier).Assembly.GetManifestResourceStream("UpdateSigningPublicKey.pem")
            ?? throw L.WithDescription(new InvalidOperationException(L.T("此构建缺少更新验签公钥。")), L.M("此构建缺少更新验签公钥。"));
        using var reader = new StreamReader(stream);
        return new UpdateManifestVerifier(reader.ReadToEnd());
    }

    public UpdateManifest Verify(byte[] manifest, byte[] signature)
    {
        if (manifest.Length is 0 or > MaxManifestBytes || signature.Length is 0 or > 256)
            throw L.WithDescription(new InvalidDataException(L.T("更新清单或签名大小无效。")), L.M("更新清单或签名大小无效。"));
        using var key = ECDsa.Create();
        key.ImportFromPem(publicKeyPem);
        if (key.KeySize != 256 || key.ExportParameters(false).Curve.Oid.Value != "1.2.840.10045.3.1.7" ||
            !key.VerifyData(manifest, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))
            throw L.WithDescription(new InvalidDataException(L.T("更新清单签名验证失败。")), L.M("更新清单签名验证失败。"));
        using var document = JsonDocument.Parse(manifest, new JsonDocumentOptions { MaxDepth = 16 });
        RejectDuplicateProperties(document.RootElement);
        var result = JsonSerializer.Deserialize<UpdateManifest>(manifest, JsonOptions)
            ?? throw L.WithDescription(new InvalidDataException(L.T("更新清单为空。")), L.M("更新清单为空。"));
        if (result.SchemaVersion != 1 || result.Product != "Shanchuan" || result.Channel != "stable" || !IsVersion(result.Version))
            throw L.WithDescription(new InvalidDataException(L.T("更新协议、产品、发布通道或版本不匹配。")), L.M("更新协议、产品、发布通道或版本不匹配。"));
        if (result.Assets is null || result.Assets.Count is 0 or > 32 || result.ReleaseNotes is null || result.ReleaseNotes.Length > 64 * 1024)
            throw L.WithDescription(new InvalidDataException(L.T("更新清单附件或说明无效。")), L.M("更新清单附件或说明无效。"));
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var asset in result.Assets)
        {
            if (asset is null || !IsSafeName(asset.Name) || !names.Add(asset.Name) || asset.Size is <= 0 or > MaxAssetBytes ||
                !HashPattern.IsMatch(asset.Sha256 ?? "") ||
                !((asset.Platform == "windows" && asset.Arch == "x64" && asset.Kind is "velopack-full" or "velopack-feed" or "setup" or "portable") ||
                  (asset.Platform == "macos" && asset.Arch == "arm64" && asset.Kind is "sparkle-zip" or "dmg" or "appcast")))
                throw L.WithDescription(new InvalidDataException(L.T("更新附件名称、平台、大小或摘要无效。")), L.M("更新附件名称、平台、大小或摘要无效。"));
        }
        return result;
    }

    public static bool IsSafeName(string? name) => name is not null && NamePattern.IsMatch(name) && name != "." && name != "..";
    public static bool IsVersion(string? version) => version is not null && VersionPattern.IsMatch(version) && version.Split('.').All(part => int.TryParse(part, out var component) && component <= 999999);
    public static int CompareVersions(string left, string right)
    {
        if (!IsVersion(left) || !IsVersion(right)) throw L.WithDescription(new InvalidDataException(L.T("更新版本号无效。")), L.M("更新版本号无效。"));
        var a = left.Split('.').Select(int.Parse).ToArray();
        var b = right.Split('.').Select(int.Parse).ToArray();
        for (var i = 0; i < 3; i++) if (a[i] != b[i]) return a[i].CompareTo(b[i]);
        return 0;
    }

    public static async Task VerifyAssetAsync(string path, UpdateAsset asset, CancellationToken token = default)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.LinkTarget is not null || info.Length != asset.Size)
            throw new InvalidDataException(L.F($"更新附件大小或路径不正确：{asset.Name}"));
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, true);
        var digest = Convert.ToHexString(await SHA256.HashDataAsync(stream, token)).ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(digest), Convert.FromHexString(asset.Sha256)))
            throw new InvalidDataException(L.F($"更新附件 SHA-256 校验失败：{asset.Name}"));
    }

    private static void RejectDuplicateProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!keys.Add(property.Name)) throw L.WithDescription(new InvalidDataException(L.T("更新清单包含重复字段。")), L.M("更新清单包含重复字段。"));
                RejectDuplicateProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var child in element.EnumerateArray()) RejectDuplicateProperties(child);
    }
}

public sealed record VerifiedUpdate(UpdateManifest Manifest, string CacheDirectory, string ManifestHash, byte[] ManifestBytes, byte[] Signature)
{
    public string Directory => CacheDirectory;
}
