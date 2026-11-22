using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Nimbus.Core;

namespace Nimbus;

/// <summary>Port of macos/Payload/test-strategies.sh: same targets, same checks (ping, HTTP, TLS 1.2, TLS 1.3), same scoring.</summary>
internal sealed class StrategyTester
{
    private sealed record Target(string Host, IPAddress Ip, bool Ok);

    public event Action<string>? Progress;
    public event Action<StrategyResult>? Result;

    public async Task<string> RunAsync(IReadOnlyList<Strategy> strategies, string originalStrategy, string originalIpset, bool originalRunning, CancellationToken cancel)
    {
        var report = new StringBuilder();
        var best = new BestTracker();
        var cancelled = false;
        var maxTotal = 0;
        try
        {
            Progress?.Invoke("Подготовка");
            await Task.Run(Engine.Stop);
            var targets = (await Task.WhenAll(TestTargets.Hosts.Select(h => DiscoverAsync(h, cancel)))).ToList();
            cancel.ThrowIfCancellationRequested();

            var tls13 = Net.SupportsTls13;
            var available = targets.Where(t => t != null).Select(t => t!).ToList();
            maxTotal = available.Count * (3 + (tls13 ? 1 : 0));

            report.AppendLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
            report.AppendLine(tls13 ? "TLS1.3: yes" : "TLS1.3: no");
            report.AppendLine().AppendLine("IP:");
            for (var i = 0; i < TestTargets.Hosts.Length; i++)
            {
                var t = targets[i];
                report.AppendLine(t == null ? $"{TestTargets.Hosts[i],-30} -" : $"{t.Host,-30} {t.Ip,-15} {(t.Ok ? "ok" : "tcp")}");
            }
            report.AppendLine().AppendLine($"{"Strategy",-34} {"Score",7} {"Ping",7} {"HTTP",7} {"TLS1.2",7} {"TLS1.3",7}");
            if (available.Count == 0) report.AppendLine("Нет доступных IP");

            var number = 0;
            await Task.Run(Engine.PrepareFiles, cancel);
            foreach (var strategy in strategies)
            {
                if (available.Count == 0) break;
                cancel.ThrowIfCancellationRequested();
                number++;
                Progress?.Invoke($"Стратегия {number}/{strategies.Count}: {strategy.Name}");
                try
                {
                    await Task.Run(() => Engine.Start(strategy.Id, IpsetModes.Any, prepare: false), cancel);
                }
                catch (Exception) when (!cancel.IsCancellationRequested)
                {
                    report.AppendLine($"{strategy.Name,-34} ошибка запуска");
                    var failed = new StrategyResult(strategy.Name, 0, 0, 0, Error: true);
                    best.Add(failed);
                    Result?.Invoke(failed);
                    continue;
                }

                var checks = available.Select(async t =>
                {
                    var ping = Net.PingAsync(t.Ip);
                    var http = Net.CheckAsync(t.Host, t.Ip, false, SslProtocols.None, TimeSpan.FromSeconds(4), cancel);
                    var tls12 = Net.CheckAsync(t.Host, t.Ip, true, SslProtocols.Tls12, TimeSpan.FromSeconds(4), cancel);
                    var tls13Task = tls13
                        ? Net.CheckAsync(t.Host, t.Ip, true, SslProtocols.Tls13, TimeSpan.FromSeconds(4), cancel)
                        : Task.FromResult(new Net.CheckResult(false, false, 0));
                    await Task.WhenAll(ping, http, tls12, tls13Task);
                    return (Ping: ping.Result, Http: http.Result.Ok, Tls12: tls12.Result.Ok, Tls13: tls13Task.Result.Ok);
                });
                var results = await Task.WhenAll(checks);
                cancel.ThrowIfCancellationRequested();

                int pingOk = results.Count(r => r.Ping), httpOk = results.Count(r => r.Http);
                int tls12Ok = results.Count(r => r.Tls12), tls13Ok = results.Count(r => r.Tls13);
                var score = pingOk + httpOk + tls12Ok + tls13Ok;
                var result = new StrategyResult(strategy.Name, score, maxTotal, tls12Ok + tls13Ok);
                var n = available.Count;
                report.AppendLine($"{strategy.Name,-34} {score + "/" + maxTotal,7} {pingOk + "/" + n,7} {httpOk + "/" + n,7} {tls12Ok + "/" + n,7} {(tls13 ? tls13Ok + "/" + n : "-"),7}");
                best.Add(result);
                Result?.Invoke(result);
            }
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
        }
        finally
        {
            Progress?.Invoke("Восстановление настроек");
            await Task.Run(() =>
            {
                try
                {
                    if (originalRunning) Engine.Start(originalStrategy, originalIpset);
                    else Engine.Stop();
                }
                catch (Exception ex)
                {
                    Log.Write("restore after test: " + ex.Message);
                }
            });
        }

        var summary = best.Summary(maxTotal, cancelled);
        report.AppendLine().AppendLine(summary);
        try { File.WriteAllText(Paths.TestReport, report.ToString()); } catch { }
        return summary;
    }

    /// <summary>System DNS plus 1.1.1.1 and 8.8.8.8 (like dig in the Mac script), then the fastest IP that answers.</summary>
    private static async Task<Target?> DiscoverAsync(string host, CancellationToken cancel)
    {
        var lookups = new List<Task<List<IPAddress>>>
        {
            SystemLookupAsync(host),
            DnsClient.QueryAsync(IPAddress.Parse("1.1.1.1"), host, TimeSpan.FromSeconds(1.5), cancel),
            DnsClient.QueryAsync(IPAddress.Parse("8.8.8.8"), host, TimeSpan.FromSeconds(1.5), cancel),
        };
        var ips = (await Task.WhenAll(lookups)).SelectMany(x => x).Distinct().ToList();
        var probes = await Task.WhenAll(ips.Select(async ip =>
        {
            var r = await Net.CheckAsync(host, ip, true, SslProtocols.Tls12, TimeSpan.FromSeconds(3), cancel);
            var rank = r.Ok ? 0 : r.Connected ? 1 : 2;
            return (Ip: ip, Rank: rank, r.ConnectMs);
        }));
        var pick = probes.Where(p => p.Rank < 2).OrderBy(p => p.Rank).ThenBy(p => p.ConnectMs).FirstOrDefault();
        return pick.Ip == null ? null : new Target(host, pick.Ip, pick.Rank == 0);
    }

    private static async Task<List<IPAddress>> SystemLookupAsync(string host)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var all = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, cts.Token);
            return all.ToList();
        }
        catch
        {
            return new List<IPAddress>();
        }
    }
}
