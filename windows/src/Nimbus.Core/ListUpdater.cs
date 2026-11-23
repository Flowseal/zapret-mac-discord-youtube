namespace Nimbus.Core;

public sealed record ListValidation(bool Ok, string Reason)
{
    public static ListValidation Pass() => new(true, "");
    public static ListValidation Fail(string reason) => new(false, reason);
}

/// <summary>
/// Downloads and validates upstream Flowseal hostlists / ipsets. Never writes *-user.txt.
/// </summary>
public static class ListUpdater
{
    public const string DefaultBaseUrl = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/";
    public const int MaxBytes = 8 * 1024 * 1024;

    public static readonly string[] UpstreamFiles =
    {
        "list-general.txt",
        "list-google.txt",
        "list-exclude.txt",
        "ipset-all.txt",
        "ipset-exclude.txt",
    };

    public static bool IsUpstream(string name) => UpstreamFiles.Contains(name, StringComparer.Ordinal);
    public static bool IsUser(string name) => name.Contains("-user", StringComparison.Ordinal);

    public static string FileUrl(string name, string? baseUrl = null) =>
        (baseUrl ?? DefaultBaseUrl).TrimEnd('/') + "/" + name;

    public static ListValidation Validate(string name, byte[] bytes)
    {
        if (IsUser(name)) return ListValidation.Fail("Пользовательские списки не обновляются из upstream.");
        if (!IsUpstream(name)) return ListValidation.Fail("Неизвестный список: " + name);
        if (bytes.Length == 0) return ListValidation.Fail(name + ": пустой ответ.");
        if (bytes.Length > MaxBytes) return ListValidation.Fail(name + ": слишком большой файл.");
        var text = Decode(bytes);
        return Validate(name, text);
    }

    public static ListValidation Validate(string name, string text)
    {
        if (IsUser(name)) return ListValidation.Fail("Пользовательские списки не обновляются из upstream.");
        if (!IsUpstream(name)) return ListValidation.Fail("Неизвестный список: " + name);
        if (string.IsNullOrWhiteSpace(text)) return ListValidation.Fail(name + ": пустой файл.");
        var lower = text.TrimStart().ToLowerInvariant();
        if (lower.StartsWith("<!doctype") || lower.StartsWith("<html") || lower.Contains("<head>") || lower.Contains("404: not found"))
        {
            return ListValidation.Fail(name + ": ответ не похож на список (HTML).");
        }

        var total = 0;
        var valid = 0;
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            total++;
            if (HostEntry.Parse(line) != null) valid++;
        }
        if (valid == 0) return ListValidation.Fail(name + ": нет ни одной корректной записи.");
        if (total > 0 && valid * 5 < total * 4) // less than 80% valid
        {
            return ListValidation.Fail(name + ": слишком много битых строк.");
        }
        return ListValidation.Pass();
    }

    public static string Decode(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        {
            return System.Text.Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        }
        return System.Text.Encoding.UTF8.GetString(bytes);
    }

    /// <summary>Writes validated upstream files atomically and keeps a backup. User lists are never touched.</summary>
    public static IReadOnlyList<string> Apply(string listsDir, IReadOnlyDictionary<string, string> files, string backupDir)
    {
        foreach (var name in files.Keys)
        {
            if (IsUser(name)) throw new InvalidOperationException("Refusing to overwrite " + name);
            var check = Validate(name, files[name]);
            if (!check.Ok) throw new InvalidOperationException(check.Reason);
        }

        Directory.CreateDirectory(listsDir);
        Directory.CreateDirectory(backupDir);
        foreach (var (name, text) in files)
        {
            var dest = Path.Combine(listsDir, name);
            if (File.Exists(dest)) File.Copy(dest, Path.Combine(backupDir, name), overwrite: true);
            var normalized = ListCatalog.NormalizeForSave(text);
            if (!normalized.EndsWith('\n')) normalized += "\n";
            var tmp = dest + ".tmp";
            File.WriteAllText(tmp, normalized);
            File.Move(tmp, dest, overwrite: true);
        }
        return files.Keys.OrderBy(x => x, StringComparer.Ordinal).ToList();
    }
}
