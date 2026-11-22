using System;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Threading;
using System.Threading.Tasks;

namespace Nimbus;

internal static class Net
{
    public readonly record struct CheckResult(bool Ok, bool Connected, double ConnectMs);

    /// <summary>
    /// The equivalent of `curl --resolve host:port:ip`: connects to a fixed IP while keeping the real host for SNI/Host.
    /// Any HTTP status counts as success, like the Mac test (curl exit 0 and code != 000).
    /// </summary>
    public static async Task<CheckResult> CheckAsync(string host, IPAddress? ip, bool https, SslProtocols tls, TimeSpan total, CancellationToken cancel)
    {
        var connected = false;
        double connectMs = 0;
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(2),
            PooledConnectionLifetime = TimeSpan.Zero,
        };
        if (ip != null)
        {
            handler.ConnectCallback = async (context, token) =>
            {
                var watch = Stopwatch.StartNew();
                var socket = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(ip, context.DnsEndPoint.Port), token);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
                connectMs = watch.Elapsed.TotalMilliseconds;
                connected = true;
                return new NetworkStream(socket, true);
            };
        }
        if (https && tls != SslProtocols.None)
        {
            handler.SslOptions = new SslClientAuthenticationOptions { EnabledSslProtocols = tls };
        }
        using var client = new HttpClient(handler) { Timeout = total };
        using var request = new HttpRequestMessage(HttpMethod.Get, (https ? "https://" : "http://") + host + "/")
        {
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };
        request.Headers.UserAgent.ParseAdd("Nimbus");
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
            return new CheckResult(true, connected, connectMs);
        }
        catch (Exception) when (!cancel.IsCancellationRequested)
        {
            return new CheckResult(false, connected, connectMs);
        }
    }

    /// <summary>Discord/YouTube dots on the main page: reachable when any HTTP status 200..499 arrives within 3 s.</summary>
    public static async Task<bool> ProbeAsync(string url)
    {
        try
        {
            using var handler = new SocketsHttpHandler { AllowAutoRedirect = false, PooledConnectionLifetime = TimeSpan.Zero };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Nimbus");
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            var code = (int)response.StatusCode;
            return code >= 200 && code < 500;
        }
        catch
        {
            return false;
        }
    }

    public static async Task<bool> PingAsync(IPAddress ip)
    {
        try
        {
            using var ping = new System.Net.NetworkInformation.Ping();
            var reply = await ping.SendPingAsync(ip, 1000);
            return reply.Status == System.Net.NetworkInformation.IPStatus.Success;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Schannel supports TLS 1.3 starting with Windows 11 / Server 2022 (build 20348).</summary>
    public static bool SupportsTls13 => Environment.OSVersion.Version.Build >= 20348;
}
