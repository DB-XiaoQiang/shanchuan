using System.Globalization;
using System.Text.Json;

namespace Shanchuan.Core;

/// <summary>Application language is explicit and independent from the OS language.
/// Chinese source keys stay stable; protocol identifiers and user content are never translated.</summary>
public static class Localization
{
    public const string DefaultLanguage = "zh-Hans";
    public const string English = "en";
    private static readonly IReadOnlyDictionary<string, string> ChineseTable = Load(DefaultLanguage);
    private static readonly IReadOnlyDictionary<string, string> EnglishTable = Load(English);
    public static string CurrentLanguage { get; private set; } = DefaultLanguage;
    public static IReadOnlyList<string> SupportedLanguages { get; } = [DefaultLanguage, English];

    public static string NormalizeLanguage(string? language) => language == English ? English : DefaultLanguage;

    /// <summary>Call once before constructing windows and services. Changing the saved choice requires restart.</summary>
    public static void Configure(string? language)
    {
        CurrentLanguage = NormalizeLanguage(language);
        var culture = CultureInfo.GetCultureInfo(CurrentLanguage);
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
    }

    public static string T(string key) => Translate(key, CurrentLanguage);
    public static string Translate(string key, string? language) =>
        GetTable(NormalizeLanguage(language)).TryGetValue(key, out var translated) ? translated : key;

    public static string F(FormattableString message) =>
        Format(message.Format, CurrentLanguage, message.GetArguments());

    public static string Format(string key, string? language, params object?[] arguments) =>
        string.Format(CultureInfo.GetCultureInfo(NormalizeLanguage(language)), Translate(key, language), arguments);

    public static IReadOnlyDictionary<string, string> GetTable(string language) =>
        NormalizeLanguage(language) == English ? EnglishTable : ChineseTable;

    private static IReadOnlyDictionary<string, string> Load(string language)
    {
        using var stream = typeof(Localization).Assembly.GetManifestResourceStream($"Localization.{language}.json")
            ?? throw new InvalidOperationException($"Missing language resource: {language}");
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)
            ?? throw new InvalidDataException($"Invalid language resource: {language}");
    }
}
