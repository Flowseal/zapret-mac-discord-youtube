using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace Nimbus;

/// <summary>Files embedded into Nimbus.exe: macos/Payload (shared with the Mac app) and the winws engine.</summary>
internal static class Payload
{
    private static readonly Assembly Assembly = typeof(Payload).Assembly;

    public static IEnumerable<string> Names(string prefix) =>
        Assembly.GetManifestResourceNames().Where(n => n.StartsWith(prefix, StringComparison.Ordinal)).OrderBy(n => n, StringComparer.Ordinal);

    public static byte[] Read(string name)
    {
        using var stream = Assembly.GetManifestResourceStream(name) ?? throw new FileNotFoundException("Встроенный файл не найден: " + name);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    public static string ReadText(string name) => Encoding.UTF8.GetString(Read(name));

    public static bool HasEngine => Assembly.GetManifestResourceInfo("engine/winws.exe") != null;

    /// <summary>Writes every resource under <paramref name="prefix"/> into <paramref name="dir"/> when its content differs.</summary>
    public static void Extract(string prefix, string dir, bool overwrite = true)
    {
        Directory.CreateDirectory(dir);
        foreach (var name in Names(prefix))
        {
            var target = Path.Combine(dir, name[prefix.Length..].Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (File.Exists(target) && !overwrite) continue;
            var data = Read(name);
            if (File.Exists(target) && SameContent(target, data)) continue;
            var tmp = target + ".new";
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, target, true);
        }
    }

    private static bool SameContent(string path, byte[] data)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Length != data.Length) return false;
            using var stream = info.OpenRead();
            return SHA256.HashData(stream).AsSpan().SequenceEqual(SHA256.HashData(data));
        }
        catch
        {
            return false;
        }
    }
}
