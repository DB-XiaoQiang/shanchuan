using System.Text;

namespace Shanchuan.Core;

/// <summary>Exclusion-only globs. Plain names match at any depth; paths are relative to the selected root.</summary>
public sealed class DirectoryExclusions
{
    private sealed record Rule(string[] Components, bool DirectoriesOnly, bool BasenameOnly);
    private readonly List<Rule> _rules;

    private DirectoryExclusions(List<Rule> rules) => _rules = rules;
    public bool IsEmpty => _rules.Count == 0;

    public static DirectoryExclusions Parse(string? text)
    {
        text ??= "";
        if (Encoding.UTF8.GetByteCount(text) > 65_536)
            throw new ArgumentException("目录排除规则过长，请控制在 64 KB 内。");

        var rules = new List<Rule>();
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index].Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (Encoding.UTF8.GetByteCount(line) > 512)
                throw Error(index, "单条规则不能超过 512 字节");
            if (line.StartsWith('!'))
                throw Error(index, "不支持 ! 反向规则，请只填写要排除的名称或路径");
            if (line.Contains('\\') || line.Any(char.IsControl))
                throw Error(index, "路径请使用 /，规则不能含控制字符或反斜杠");

            var directoriesOnly = line.EndsWith('/');
            var anchored = line.StartsWith('/');
            if (anchored) line = line[1..];
            if (directoriesOnly && line.Length > 0) line = line[..^1];
            var components = line.Split('/');
            if (components.Any(component => component.Length == 0 || component is "." or ".."))
                throw Error(index, "请填写有效的相对路径，不能包含 . 或 .. 路径段");

            rules.Add(new Rule(components, directoriesOnly, !anchored && components.Length == 1));
            if (rules.Count > 200) throw new ArgumentException("目录排除规则最多支持 200 条。");
        }
        return new DirectoryExclusions(rules);
    }

    public bool Excludes(string relativePath, bool isDirectory)
    {
        var components = relativePath.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        return _rules.Any(rule =>
        {
            if (rule.DirectoriesOnly && !isDirectory) return false;
            if (rule.BasenameOnly) return ComponentMatches(rule.Components[0], components.LastOrDefault() ?? "");

            var previous = new bool[components.Length + 1];
            previous[0] = true;
            foreach (var pattern in rule.Components)
            {
                var next = new bool[previous.Length];
                if (pattern == "**")
                {
                    next[0] = previous[0];
                    for (var index = 0; index < components.Length; index++)
                        next[index + 1] = previous[index + 1] || next[index];
                }
                else
                {
                    for (var index = 0; index < components.Length; index++)
                        next[index + 1] = previous[index] && ComponentMatches(pattern, components[index]);
                }
                previous = next;
            }
            return previous[components.Length];
        });
    }

    private static ArgumentException Error(int index, string message) =>
        new($"目录排除规则第 {index + 1} 行：{message}。");

    private static bool ComponentMatches(string pattern, string name)
    {
        var previous = new bool[name.Length + 1];
        previous[0] = true;
        foreach (var character in pattern)
        {
            var next = new bool[previous.Length];
            if (character == '*')
            {
                next[0] = previous[0];
                for (var index = 0; index < name.Length; index++)
                    next[index + 1] = previous[index + 1] || next[index];
            }
            else
            {
                for (var index = 0; index < name.Length; index++)
                    next[index + 1] = previous[index] && (character == '?' || character == name[index]);
            }
            previous = next;
        }
        return previous[name.Length];
    }
}
