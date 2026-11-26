using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading.Tasks;
using Nimbus.Core;

namespace Nimbus;

internal static class SystemDiagnostics
{
    public static IReadOnlyList<DiagnosticRow> Collect()
    {
        var rows = new List<DiagnosticRow>
        {
            TcpTimestamps(),
            EngineProcess(),
            ConflictingProcesses(),
            ConflictingServices(),
            VpnAdapters(),
        };
        rows.Add(DnsCheck());
        rows.Add(HttpsCheck());
        return rows;
    }

    public static string Format(IReadOnlyList<DiagnosticRow> rows) =>
        DiagnosticReport.Format($"Nimbus {Updater.CurrentVersion} · {DateTime.Now:yyyy-MM-dd HH:mm:ss}", rows);

    public static VpnMatch DetectVpn()
    {
        foreach (var nic in SafeInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            var match = VpnSignatures.MatchAdapter(nic.Name, nic.Description, nic.NetworkInterfaceType.ToString());
            if (match.IsVpn) return match;
        }
        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    var match = VpnSignatures.MatchProcess(process.ProcessName);
                    if (match.IsVpn) return match;
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // listing processes can fail under tight ACLs; adapter check is enough
        }
        return new VpnMatch(false, null);
    }

    private static DiagnosticRow TcpTimestamps()
    {
        try
        {
            var psi = new ProcessStartInfo("netsh")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in "interface tcp show global".Split(' ')) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            var text = p == null ? "" : p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p?.WaitForExit(3000);
            var lower = text.ToLowerInvariant();
            if (lower.Contains("timestamps") && (lower.Contains("enabled") || lower.Contains("включен")))
            {
                return new DiagnosticRow("TCP timestamps", DiagnosticLevel.Pass, "включены");
            }
            if (lower.Contains("timestamps") && (lower.Contains("disabled") || lower.Contains("отключен") || lower.Contains("disabled")))
            {
                return new DiagnosticRow("TCP timestamps", DiagnosticLevel.Fail, "выключены — стратегии с fooling=ts не сработают");
            }
            return new DiagnosticRow("TCP timestamps", DiagnosticLevel.Warn, "не удалось разобрать ответ netsh");
        }
        catch (Exception ex)
        {
            return new DiagnosticRow("TCP timestamps", DiagnosticLevel.Warn, ex.Message);
        }
    }

    private static DiagnosticRow EngineProcess()
    {
        try
        {
            var ours = 0;
            var others = new List<string>();
            foreach (var process in Process.GetProcessesByName("winws"))
            {
                using (process)
                {
                    string? path = null;
                    try { path = process.MainModule?.FileName; } catch { }
                    if (!string.IsNullOrEmpty(path) && PathsEqual(path, Paths.Winws)) ours++;
                    else others.Add(string.IsNullOrEmpty(path) ? $"pid {process.Id}" : path);
                }
            }
            if (others.Count > 0)
            {
                return new DiagnosticRow("winws", DiagnosticLevel.Fail, "чужой процесс: " + string.Join(", ", others));
            }
            if (ours > 1)
            {
                return new DiagnosticRow("winws", DiagnosticLevel.Warn, $"запущено несколько копий Nimbus ({ours})");
            }
            if (ours == 1)
            {
                return new DiagnosticRow("winws", DiagnosticLevel.Pass, "работает копия Nimbus");
            }
            return new DiagnosticRow("winws", DiagnosticLevel.Pass, "процесс не запущен (движок выключен)");
        }
        catch (Exception ex)
        {
            return new DiagnosticRow("winws", DiagnosticLevel.Warn, ex.Message);
        }
    }

    private static DiagnosticRow ConflictingProcesses()
    {
        var names = new[] { "goodbyedpi", "winws1", "zapret", "flowseal", "discordfixer" };
        var hits = new List<string>();
        foreach (var name in names)
        {
            try
            {
                foreach (var process in Process.GetProcessesByName(name))
                {
                    hits.Add(process.ProcessName);
                    process.Dispose();
                }
            }
            catch
            {
            }
        }
        if (hits.Count == 0) return new DiagnosticRow("Другие обходы", DiagnosticLevel.Pass, "GoodbyeDPI и чужие zapret не найдены");
        return new DiagnosticRow("Другие обходы", DiagnosticLevel.Fail, "лучше выключить: " + string.Join(", ", hits.Distinct()));
    }

    private static DiagnosticRow ConflictingServices()
    {
        var hits = new List<string>();
        foreach (var name in new[] { "GoodbyeDPI", "zapret", "zapret-discord-youtube" })
        {
            try
            {
                var psi = new ProcessStartInfo("sc")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    ArgumentList = { "query", name },
                };
                using var p = Process.Start(psi);
                var text = p == null ? "" : p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p?.WaitForExit(2000);
                if (text.Contains("RUNNING", StringComparison.OrdinalIgnoreCase) &&
                    !text.Contains("FAILED 1060", StringComparison.OrdinalIgnoreCase))
                {
                    hits.Add(name);
                }
            }
            catch
            {
            }
        }
        if (hits.Count == 0) return new DiagnosticRow("Службы", DiagnosticLevel.Pass, "конфликтующих служб не видно");
        return new DiagnosticRow("Службы", DiagnosticLevel.Fail, "запущены: " + string.Join(", ", hits));
    }

    private static DiagnosticRow VpnAdapters()
    {
        var match = DetectVpn();
        if (match.IsVpn && VpnSignatures.IsFullTunnelClient(match.Reason))
            return new DiagnosticRow("VPN", DiagnosticLevel.Warn, (match.Reason ?? "WARP") + ": перехватывает все соединения, обход не сработает");
        if (match.IsVpn) return new DiagnosticRow("VPN", DiagnosticLevel.Pass, (match.Reason ?? "туннель") + ": трафик туннеля Nimbus не трогает");
        return new DiagnosticRow("VPN", DiagnosticLevel.Pass, "активного VPN-туннеля не видно");
    }

    private static DiagnosticRow DnsCheck()
    {
        try
        {
            var addrs = System.Net.Dns.GetHostAddresses("one.one.one.one");
            if (addrs.Length == 0) return new DiagnosticRow("DNS", DiagnosticLevel.Fail, "не резолвится one.one.one.one");
            return new DiagnosticRow("DNS", DiagnosticLevel.Pass, addrs[0].ToString());
        }
        catch (Exception ex)
        {
            return new DiagnosticRow("DNS", DiagnosticLevel.Fail, ex.Message);
        }
    }

    private static DiagnosticRow HttpsCheck()
    {
        var https = Task.Run(() => Net.ProbeAsync("https://www.cloudflare.com/")).GetAwaiter().GetResult();
        return https
            ? new DiagnosticRow("HTTPS", DiagnosticLevel.Pass, "www.cloudflare.com отвечает")
            : new DiagnosticRow("HTTPS", DiagnosticLevel.Warn, "www.cloudflare.com не ответил за 3 с");
    }

    private static IEnumerable<NetworkInterface> SafeInterfaces()
    {
        try { return NetworkInterface.GetAllNetworkInterfaces(); }
        catch { return Array.Empty<NetworkInterface>(); }
    }

    private static bool PathsEqual(string a, string b)
    {
        try { return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }
        catch { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
    }
}
