using System.Security.Cryptography;
using System.Text.Json;

namespace Shanchuan.Core;

/// <summary>Unapproved updates stay outside Velopack's managed packages directory.</summary>
public sealed class UpdateCache(string root, UpdateManifestVerifier verifier)
{
    public string Root { get; } = Path.GetFullPath(root);

    public async Task<VerifiedUpdate> ImportAsync(byte[] bytes, byte[] signature,
        Func<UpdateAsset, string, CancellationToken, Task> download, CancellationToken token = default)
    {
        var manifest = verifier.Verify(bytes, signature);
        RequireWindowsAssets(manifest);
        var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var target = Path.Combine(Root, manifest.Version + "-" + hash);
        Directory.CreateDirectory(Root);
        if (Directory.Exists(target))
        {
            try { return await LoadAsync(target, token); }
            catch (Exception error) when (error is IOException or InvalidDataException or JsonException or CryptographicException)
            { Directory.Delete(target, true); }
        }
        var staging = Path.Combine(Root, "." + Guid.NewGuid().ToString("N") + ".partial");
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var asset in manifest.WindowsUpdateAssets)
            {
                var destination = Path.Combine(staging, asset.Name);
                await download(asset, destination, token);
                await UpdateManifestVerifier.VerifyAssetAsync(destination, asset, token);
            }
            ValidateWindowsFeed(staging, manifest);
            await File.WriteAllBytesAsync(Path.Combine(staging, UpdateManifestVerifier.ManifestName), bytes, token);
            await File.WriteAllBytesAsync(Path.Combine(staging, UpdateManifestVerifier.SignatureName), signature, token);
            Directory.Move(staging, target);
            return new VerifiedUpdate(manifest, target, hash, bytes, signature);
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    }

    public async Task<VerifiedUpdate> LoadAsync(string directory, CancellationToken token = default)
    {
        var path = Path.GetFullPath(directory);
        var relative = Path.GetRelativePath(Root, path);
        if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative) ||
            !Directory.Exists(path) || new DirectoryInfo(path).LinkTarget is not null)
            throw new InvalidDataException("更新缓存目录无效。");
        var bytes = await ReadLimitedAsync(Path.Combine(path, UpdateManifestVerifier.ManifestName), UpdateManifestVerifier.MaxManifestBytes, token);
        var signature = await ReadLimitedAsync(Path.Combine(path, UpdateManifestVerifier.SignatureName), 256, token);
        var manifest = verifier.Verify(bytes, signature);
        RequireWindowsAssets(manifest);
        foreach (var asset in manifest.WindowsUpdateAssets)
            await UpdateManifestVerifier.VerifyAssetAsync(Path.Combine(path, asset.Name), asset, token);
        ValidateWindowsFeed(path, manifest);
        return new VerifiedUpdate(manifest, path, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), bytes, signature);
    }

    public static void RequireWindowsAssets(UpdateManifest manifest)
    {
        if (manifest.WindowsUpdateAssets.Count != 2 || manifest.WindowsUpdateAssets.Count(x => x.Kind == "velopack-full") != 1 ||
            manifest.WindowsUpdateAssets.Count(x => x.Kind == "velopack-feed") != 1 ||
            manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-feed").Name != "releases.win-x64.json")
            throw new InvalidDataException("更新清单缺少唯一的 Windows 完整包和更新索引。");
    }

    public static void ValidateWindowsFeed(string directory, UpdateManifest manifest)
    {
        var full = manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-full");
        var feed = manifest.WindowsUpdateAssets.Single(x => x.Kind == "velopack-feed");
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, feed.Name)));
        if (!document.RootElement.TryGetProperty("Assets", out var assets) || assets.ValueKind != JsonValueKind.Array || assets.GetArrayLength() != 1)
            throw new InvalidDataException("Windows 更新索引必须仅引用本版已签名完整包。");
        var entry = assets[0];
        if (entry.GetProperty("FileName").GetString() != full.Name || entry.GetProperty("Version").GetString() != manifest.Version ||
            entry.GetProperty("Type").GetString() != "Full" || entry.GetProperty("PackageId").GetString() != "Shanchuan" ||
            entry.GetProperty("Size").GetInt64() != full.Size ||
            !string.Equals(entry.GetProperty("SHA256").GetString(), full.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Windows 更新索引与已签名发行清单不一致。");
    }

    internal static async Task<byte[]> ReadLimitedAsync(string path, int maximum, CancellationToken token)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.LinkTarget is not null || info.Length is <= 0 || info.Length > maximum)
            throw new InvalidDataException("更新元数据大小或路径无效。");
        return await File.ReadAllBytesAsync(path, token);
    }
}
