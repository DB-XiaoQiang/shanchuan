using System.Text.Json;
using System.Text.Json.Serialization;

namespace Shanchuan.Core;

public static class AppDataPaths
{
    public static string DefaultRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Shanchuan");
}

public sealed class SettingsStore(string root)
{
    private string FilePath => Path.Combine(root, "settings.json");

    public AppSettings Load() => File.Exists(FilePath)
        ? JsonFileStore.Read<AppSettings>(FilePath)
        : new AppSettings();

    public void Save(AppSettings settings) => JsonFileStore.Write(FilePath, settings);
}

public sealed class HistoryStore(string root)
{
    public string MediaDirectory { get; } = Path.Combine(root, "Media");
    private string FilePath => Path.Combine(root, "history.json");

    public List<HistoryEntry> Load() => File.Exists(FilePath)
        ? JsonFileStore.Read<List<HistoryEntry>>(FilePath)
        : [];

    public void Save(IEnumerable<HistoryEntry> entries) => JsonFileStore.Write(FilePath, entries.ToList());

    public List<HistoryEntry> Prune(IEnumerable<HistoryEntry> entries, int days, DateTimeOffset? now = null)
    {
        var cutoff = (now ?? DateTimeOffset.Now).AddDays(-Math.Max(1, days));
        return entries.Where(entry => entry.Date >= cutoff).ToList();
    }

    public string NewImagePath()
    {
        Directory.CreateDirectory(MediaDirectory);
        return Path.Combine(MediaDirectory, Guid.NewGuid().ToString("N") + ".png");
    }

    public void RemoveUnreferencedMedia(IEnumerable<HistoryEntry> entries)
    {
        if (!Directory.Exists(MediaDirectory)) return;
        var referenced = entries.SelectMany(entry => entry.Paths).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var file in Directory.EnumerateFiles(MediaDirectory))
            if (!referenced.Contains(file)) File.Delete(file);
    }
}

public sealed class TransferLogStore(string root, int limit = 1000)
{
    private readonly int _limit = Math.Max(0, limit);
    private string FilePath => Path.Combine(root, "transfer-logs.json");

    public List<TransferLogEntry> Load() => File.Exists(FilePath)
        ? JsonFileStore.Read<List<TransferLogEntry>>(FilePath).Take(_limit).ToList()
        : [];

    public void Save(IEnumerable<TransferLogEntry> entries) =>
        JsonFileStore.Write(FilePath, entries.Take(_limit).ToList());
}

internal static class JsonFileStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public static T Read<T>(string path)
    {
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<T>(json, Options) ?? throw new InvalidDataException($"无法读取 {Path.GetFileName(path)}。");
    }

    public static void Write<T>(string path, T value)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new InvalidOperationException("数据文件路径无效。");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value, Options));
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
