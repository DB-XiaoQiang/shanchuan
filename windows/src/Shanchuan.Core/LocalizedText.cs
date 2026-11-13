namespace Shanchuan.Core;

/// <summary>A live presentation message. Resource keys and opaque user arguments
/// stay separate, so switching language never searches or rewrites user content.</summary>
public sealed class LocalizedText
{
    private readonly Func<string, string> _render;
    private LocalizedText(Func<string, string> render) => _render = render;
    public static LocalizedText Key(string key) => new(language => Localization.Translate(key, language));
    public static LocalizedText Raw(string? value) => new(_ => value ?? "");
    public static LocalizedText Live(Func<string> value) => new(_ => value());
    public static LocalizedText Formatted(FormattableString message)
    {
        var key = message.Format;
        var arguments = message.GetArguments().ToArray();
        return new(language => Localization.Format(key, language,
            arguments.Select(argument => argument is LocalizedText text ? text.Render(language) : argument).ToArray()));
    }
    public string Render(string language) => _render(Localization.NormalizeLanguage(language));
    public override string ToString() => Render(Localization.CurrentLanguage);
    public static implicit operator LocalizedText(string? value) => Raw(value);
    public static implicit operator string(LocalizedText value) => value.ToString();
    public static LocalizedText operator +(LocalizedText left, LocalizedText right) => new(language => left.Render(language) + right.Render(language));
    public static LocalizedText operator +(LocalizedText left, string? right) => left + Raw(right);
    public static LocalizedText operator +(string? left, LocalizedText right) => Raw(left) + right;
}
