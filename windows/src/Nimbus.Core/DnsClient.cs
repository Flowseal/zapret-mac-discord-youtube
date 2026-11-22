using System.Net;
using System.Net.Sockets;

namespace Nimbus.Core;

/// <summary>Minimal UDP DNS A-record client, used like `dig @1.1.1.1` in the Mac strategy test.</summary>
public static class DnsClient
{
    public static byte[] BuildQuery(ushort id, string host)
    {
        var buffer = new List<byte>
        {
            (byte)(id >> 8), (byte)id,
            0x01, 0x00, // recursion desired
            0x00, 0x01, // QDCOUNT
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        foreach (var label in host.TrimEnd('.').Split('.'))
        {
            var bytes = System.Text.Encoding.ASCII.GetBytes(label);
            if (bytes.Length == 0 || bytes.Length > 63) throw new ArgumentException("bad host", nameof(host));
            buffer.Add((byte)bytes.Length);
            buffer.AddRange(bytes);
        }
        buffer.Add(0);
        buffer.AddRange(new byte[] { 0x00, 0x01, 0x00, 0x01 }); // A, IN
        return buffer.ToArray();
    }

    public static List<IPAddress> ParseA(byte[] response, ushort expectedId)
    {
        var result = new List<IPAddress>();
        if (response.Length < 12) return result;
        if (((response[0] << 8) | response[1]) != expectedId) return result;
        if ((response[3] & 0x0F) != 0) return result; // RCODE
        var qd = (response[4] << 8) | response[5];
        var an = (response[6] << 8) | response[7];
        var pos = 12;
        for (var i = 0; i < qd; i++)
        {
            pos = SkipName(response, pos);
            pos += 4;
            if (pos > response.Length) return result;
        }
        for (var i = 0; i < an; i++)
        {
            pos = SkipName(response, pos);
            if (pos + 10 > response.Length) break;
            var type = (response[pos] << 8) | response[pos + 1];
            var cls = (response[pos + 2] << 8) | response[pos + 3];
            var len = (response[pos + 8] << 8) | response[pos + 9];
            pos += 10;
            if (pos + len > response.Length) break;
            if (type == 1 && cls == 1 && len == 4)
            {
                result.Add(new IPAddress(new[] { response[pos], response[pos + 1], response[pos + 2], response[pos + 3] }));
            }
            pos += len;
        }
        return result;
    }

    private static int SkipName(byte[] data, int pos)
    {
        while (pos < data.Length)
        {
            var len = data[pos];
            if (len == 0) return pos + 1;
            if ((len & 0xC0) == 0xC0) return pos + 2;
            pos += len + 1;
        }
        return data.Length + 1;
    }

    public static async Task<List<IPAddress>> QueryAsync(IPAddress server, string host, TimeSpan timeout, CancellationToken cancel = default)
    {
        var id = (ushort)Random.Shared.Next(1, 65535);
        var query = BuildQuery(id, host);
        using var udp = new UdpClient(server.AddressFamily);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(timeout);
        try
        {
            await udp.SendAsync(query, new IPEndPoint(server, 53), cts.Token);
            var reply = await udp.ReceiveAsync(cts.Token);
            return ParseA(reply.Buffer, id);
        }
        catch (Exception) when (!cancel.IsCancellationRequested)
        {
            return new List<IPAddress>();
        }
    }
}
