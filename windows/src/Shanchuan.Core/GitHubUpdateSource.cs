using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Shanchuan.Core;

public sealed record RemoteUpdateRelease(string Tag, byte[] ManifestBytes, byte[] Signature);

public interface IUpdateSource
{
    Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token);
    Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token);
}

/// <summary>Only public stable releases from the owning repository are accepted.</summary>
public sealed class GitHubUpdateSource : IUpdateSource
{
    public const string Repository = "DB-XiaoQiang/shanchuan";
    private readonly HttpClient _http;
    public GitHubUpdateSource(HttpClient? http = null) => _http = http ?? SharedClient;
    private static readonly HttpClient SharedClient = new() { Timeout = TimeSpan.FromMinutes(10) };

    public async Task<RemoteUpdateRelease?> GetLatestAsync(CancellationToken token)
    {
        using var request = Request("https://api.github.com/repos/" + Repository + "/releases/latest", api: true);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        await using var input = await response.Content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        await CopyBoundedAsync(input, output, 512 * 1024, token);
        using var json = JsonDocument.Parse(output.ToArray());
        var release = json.RootElement;
        if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) return null;
        var tag = release.GetProperty("tag_name").GetString() ?? "";
        RequireTag(tag);
        var names = release.GetProperty("assets").EnumerateArray().Select(x => x.GetProperty("name").GetString()).ToHashSet();
        if (!names.Contains(UpdateManifestVerifier.ManifestName) || !names.Contains(UpdateManifestVerifier.SignatureName))
            throw new InvalidDataException("正式版本缺少已签名更新清单。");
        var manifest = await DownloadBytesAsync(AssetUrl(tag, UpdateManifestVerifier.ManifestName), UpdateManifestVerifier.MaxManifestBytes, token);
        var signature = await DownloadBytesAsync(AssetUrl(tag, UpdateManifestVerifier.SignatureName), 256, token);
        return new RemoteUpdateRelease(tag, manifest, signature);
    }

    public async Task DownloadAssetAsync(string tag, UpdateAsset asset, string destination, CancellationToken token)
    {
        using var request = Request(AssetUrl(tag, asset.Name));
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is { } length && length != asset.Size)
            throw new InvalidDataException("GitHub 更新附件大小与清单不一致。");
        await using var input = await response.Content.ReadAsStreamAsync(token);
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true);
        await CopyBoundedAsync(input, output, asset.Size, token);
        if (output.Length != asset.Size) throw new InvalidDataException("GitHub 更新附件未完整下载。");
    }

    public static string AssetUrl(string tag, string name)
    {
        RequireTag(tag);
        if (!UpdateManifestVerifier.IsSafeName(name)) throw new InvalidDataException("更新附件名无效。");
        return "https://github.com/" + Repository + "/releases/download/" + tag + "/" + name;
    }

    public static void RequireTag(string tag)
    {
        if (!tag.StartsWith('v') || !UpdateManifestVerifier.IsVersion(tag[1..]))
            throw new InvalidDataException("GitHub 正式版本标签无效。");
    }

    private static HttpRequestMessage Request(string url, bool api = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("Shanchuan-Updater/1");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(api ? "application/vnd.github+json" : "application/octet-stream"));
        return request;
    }

    private async Task<byte[]> DownloadBytesAsync(string url, int maximum, CancellationToken token)
    {
        using var request = Request(url);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > maximum) throw new InvalidDataException("更新元数据过大。");
        await using var input = await response.Content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        await CopyBoundedAsync(input, output, maximum, token);
        return output.ToArray();
    }

    internal static async Task CopyBoundedAsync(Stream input, Stream output, long maximum, CancellationToken token)
    {
        var buffer = new byte[128 * 1024];
        long total = 0;
        int count;
        while ((count = await input.ReadAsync(buffer, token)) > 0)
        {
            total += count;
            if (total > maximum) throw new InvalidDataException("更新下载超过清单允许的大小。");
            await output.WriteAsync(buffer.AsMemory(0, count), token);
        }
    }
}
