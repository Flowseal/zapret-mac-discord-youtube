using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Nimbus.Core;

namespace Nimbus;

/// <summary>What the machine looks like right now from the engine's point of view.</summary>
internal sealed record NetworkSnapshot(EnginePlan Plan, IReadOnlyList<string> Endpoints)
{
    public static readonly NetworkSnapshot Empty = new(EnginePlan.None, Array.Empty<string>());
}

/// <summary>
/// Leaves VPN traffic alone: finds tunnel adapters and the servers VPN clients talk to,
/// and keeps the engine's exclude list in sync with them.
/// </summary>
internal static class Tunnels
{
    [DllImport("iphlpapi.dll")]
    private static extern uint GetBestInterface(uint destAddr, out uint bestIfIndex);

    public static NetworkSnapshot Capture(bool withEndpoints = true)
    {
        try
        {
            var adapters = new List<AdapterInfo>();
            var gateways = new Dictionary<int, string>();
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                try
                {
                    var props = nic.GetIPProperties();
                    var index = -1;
                    try { index = props.GetIPv4Properties()?.Index ?? -1; } catch (NetworkInformationException) { }
                    if (index < 0)
                    {
                        try { index = props.GetIPv6Properties()?.Index ?? -1; } catch (NetworkInformationException) { }
                    }
                    var gateway = props.GatewayAddresses.FirstOrDefault(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !g.Address.Equals(System.Net.IPAddress.Any));
                    if (gateway != null && index >= 0) gateways[index] = gateway.Address.ToString();
                    adapters.Add(new AdapterInfo(nic.Name, nic.Description, nic.NetworkInterfaceType.ToString(),
                        nic.OperationalStatus == OperationalStatus.Up, index, gateway != null));
                }
                catch (Exception)
                {
                    // an adapter that cannot be read is not worth failing for
                }
            }
            int? best = null;
            // 8.8.8.8 (same bytes in either byte order): the interface Windows would use for the internet
            if (GetBestInterface(0x08080808, out var idx) == 0) best = (int)idx;
            var plan = VpnEndpoints.Plan(adapters, best);
            if (!withEndpoints || (plan.TunnelIndexes.Count == 0 && !VpnProcessIds().Any())) return new NetworkSnapshot(plan, Array.Empty<string>());
            var gatewayText = plan.PinnedIfIndex is { } pinned && gateways.TryGetValue(pinned, out var g) ? g : gateways.Values.FirstOrDefault();
            return new NetworkSnapshot(plan, Endpoints(gatewayText));
        }
        catch (Exception ex)
        {
            Log.Write("network snapshot: " + ex.Message);
            return NetworkSnapshot.Empty;
        }
    }

    private static HashSet<int> VpnProcessIds()
    {
        var pids = new HashSet<int>();
        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (VpnSignatures.MatchProcess(process.ProcessName).IsVpn) pids.Add(process.Id);
                }
                catch
                {
                    // process exited while we looked
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // listing processes can fail under tight ACLs
        }
        return pids;
    }

    private static IReadOnlyList<string> Endpoints(string? gateway)
    {
        var result = new List<string>();
        var pids = VpnProcessIds();
        if (pids.Count > 0)
        {
            var rows = VpnEndpoints.ParseNetstat(Run("netstat", "-ano"));
            result.AddRange(VpnEndpoints.RemotesOf(rows, pids));
        }
        if (!string.IsNullOrEmpty(gateway))
        {
            foreach (var host in VpnEndpoints.HostRoutes(Run("route", "print -4"), gateway))
                if (!result.Contains(host)) result.Add(host);
        }
        return result.Take(LeaveAlone.MaxEntries).ToList();
    }

    private static string Run(string file, string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo(file)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in arguments.Split(' ')) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return "";
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(8000)) { try { p.Kill(); } catch { } return ""; }
            return output.Result;
        }
        catch
        {
            return "";
        }
    }

    /// <summary>The user's own list from settings, valid entries only.</summary>
    public static IReadOnlyList<string> ManualEntries() => LeaveAlone.Parse(State.Read(Paths.LeaveAlone)).Entries;

    /// <summary>
    /// Rewrites the exclude file winws watches (it reloads lists when they change on disk), so new VPN servers
    /// and edits to the user's list apply without restarting the engine. Returns true when the file changed.
    /// </summary>
    public static bool WriteLeaveAloneFile(IEnumerable<string> detected)
    {
        var text = LeaveAlone.Merge(ManualEntries(), detected);
        var path = Path.Combine(Paths.RuntimeLists, EngineArguments.LeaveAloneFile);
        try
        {
            Directory.CreateDirectory(Paths.RuntimeLists);
            if (File.Exists(path) && File.ReadAllText(path) == text) return false;
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, path, true);
            return true;
        }
        catch (Exception ex)
        {
            Log.Write("leave-alone file: " + ex.Message);
            return false;
        }
    }
}
