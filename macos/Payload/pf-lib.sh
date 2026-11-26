#!/bin/sh
# Helpers for the pf anchor that run.sh keeps loaded. Sourced, not executed.
#
# Nimbus only redirects ordinary traffic on the physical interface. Everything that belongs to a VPN is
# left alone: traffic on tunnel interfaces, the servers VPN clients talk to, and the addresses the user
# listed under "Не трогать адреса". Each function reads its input from stdin or arguments and prints text,
# so macos/tests/pf-lib-test.sh can check them without pf or root.

NIMBUS_IFACE=${NIMBUS_IFACE:-utun50}
NIMBUS_GATEWAY4=${NIMBUS_GATEWAY4:-10.77.0.2}
NIMBUS_GATEWAY6=${NIMBUS_GATEWAY6:-fd77::2}
PF_VPN_PROCESSES='openvpn|wireguard|openconnect|racoon|vpnc|charon|tailscale|sing-box|xray|v2ray|hysteria|mihomo|clash|amnezia'

# stdin: text with addresses or CIDR networks separated by commas, spaces, semicolons or lines (# starts a comment).
# stdout: one valid entry per line. Host bits of a network are cleared, bad tokens are dropped.
pf_valid_entries() {
    /usr/bin/awk '
    function hexval(s,   i, n, c) {
        n = 0
        for (i = 1; i <= length(s); i++) {
            c = index("0123456789abcdef", substr(s, i, 1)) - 1
            n = n * 16 + c
        }
        return n
    }
    function v4(tok,   a, n, p, i, addr, bits, net, host, o, out) {
        n = split(tok, a, "/")
        if (n > 2) return ""
        split(a[1], o, ".")
        if (a[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return ""
        addr = 0
        for (i = 1; i <= 4; i++) {
            if (length(o[i]) > 3 || (length(o[i]) > 1 && substr(o[i], 1, 1) == "0") || o[i] + 0 > 255) return ""
            addr = addr * 256 + o[i]
        }
        bits = 32
        if (n == 2) {
            if (a[2] !~ /^[0-9]+$/ || length(a[2]) > 2) return ""
            bits = a[2] + 0
            if (bits < 1 || bits > 32) return ""
        } else if (addr == 0) return ""
        host = 2 ^ (32 - bits)
        net = addr - (addr % host)
        out = int(net / 16777216) "." int(net / 65536) % 256 "." int(net / 256) % 256 "." net % 256
        return bits == 32 ? out : out "/" bits
    }
    function v6(tok,   a, n, i, j, k, g, ng, left, right, nl, nr, groups, bits, keep, v, out, lg, rg, miss) {
        n = split(tok, a, "/")
        if (n > 2) return ""
        tok = tolower(a[1])
        if (tok !~ /^[0-9a-f:]+$/ || tok ~ /:::/) return ""
        bits = 128
        if (n == 2) {
            if (a[2] !~ /^[0-9]+$/ || length(a[2]) > 3) return ""
            bits = a[2] + 0
            if (bits < 1 || bits > 128) return ""
        }
        i = index(tok, "::")
        if (i > 0 && index(substr(tok, i + 2), "::") > 0) return ""
        if (i > 0) {
            left = substr(tok, 1, i - 1); right = substr(tok, i + 2)
            nl = (left == "") ? 0 : split(left, lg, ":")
            nr = (right == "") ? 0 : split(right, rg, ":")
            miss = 8 - nl - nr
            if (miss < 1) return ""
            for (j = 1; j <= nl; j++) groups[j] = lg[j]
            for (j = 1; j <= miss; j++) groups[nl + j] = "0"
            for (j = 1; j <= nr; j++) groups[nl + miss + j] = rg[j]
        } else {
            if (split(tok, groups, ":") != 8) return ""
        }
        out = ""
        for (j = 1; j <= 8; j++) {
            g = groups[j]
            if (g == "" || length(g) > 4) return ""
            v = hexval(g)
            if (n == 2) {
                keep = bits - (j - 1) * 16
                if (keep < 0) keep = 0
                if (keep > 16) keep = 16
                v = v - (v % (2 ^ (16 - keep)))
            }
            out = out (j > 1 ? ":" : "") sprintf("%x", v)
        }
        if (n == 2 && bits < 128) return out "/" bits
        if (out == "0:0:0:0:0:0:0:0") return ""
        return out
    }
    {
        line = $0
        sub(/#.*/, "", line)
        gsub(/[,;\t]/, " ", line)
        k = split(line, tok, " ")
        for (t = 1; t <= k; t++) {
            r = ""
            if (tok[t] ~ /:/) r = v6(tok[t]); else r = v4(tok[t])
            if (r != "" && !(r in seen) && count < 64) { seen[r] = 1; count++; print r }
        }
    }'
}

# stdin: `ifconfig -l` output. stdout: tunnel interfaces other than Nimbus's own, one per line.
pf_tunnels() {
    /usr/bin/tr ' ' '\n' | /usr/bin/awk -v own="$NIMBUS_IFACE" '
        $0 == own { next }
        /^(utun|ipsec|ppp|tun|tap|wg)[0-9]+$/ { print }'
}

# stdin: `lsof +c 0 -nP -i -F pcPn` output. stdout: remote addresses of connected sockets that belong to VPN clients.
pf_lsof_endpoints() {
    /usr/bin/awk -v procs="$PF_VPN_PROCESSES" '
    BEGIN { re = "(" procs ")" }
    /^p/ { mine = 0; next }
    /^c/ { mine = (tolower(substr($0, 2)) ~ re); next }
    /^n/ {
        if (!mine) next
        i = index($0, "->")
        if (i == 0) next
        r = substr($0, i + 2)
        sub(/ .*/, "", r)
        if (substr(r, 1, 1) == "[") { sub(/^\[/, "", r); sub(/\].*/, "", r) } else { sub(/:[0-9]+$/, "", r) }
        if (r == "" || r == "*" || r ~ /^127\./ || r == "::1" || r ~ /^fe80:/ || r ~ /^0\.0\.0\.0$/) next
        if (!(r in seen)) { seen[r] = 1; print r }
    }'
}

# arg: the physical default gateway. stdin: `netstat -rn -f inet`.
# stdout: hosts that have a /32 route through that gateway, which is how VPN clients pin their server.
pf_host_routes() {
    /usr/bin/awk -v gw="$1" '
    $2 == gw && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /H/ && $1 != gw {
        split($1, o, ".")
        if (o[1] + 0 < 224 && o[1] + 0 != 127 && !($1 in seen)) { seen[$1] = 1; print $1 }
    }'
}

# stdin: `netstat -rn -f inet`. stdout: "iface gateway" of the first default route that is not a tunnel.
# A VPN that takes over the default route leaves the physical one behind as a scoped entry.
pf_physical_default() {
    /usr/bin/awk '
    $1 == "default" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        for (i = 4; i <= NF; i++) {
            if ($i ~ /^[a-z]+[0-9]+$/) {
                if ($i !~ /^(utun|ipsec|ppp|tun|tap|wg|gif|stf)[0-9]+$/) { print $i, $2; exit }
                break
            }
        }
    }'
}

# args: physical interface, "1" if IPv6 is configured, tunnels, VPN endpoints, manual entries
# (the last three are whitespace separated lists). stdout: the rules for the anchor, skips first.
pf_render() {
    _iface=$1
    _ipv6=$2
    _tunnels=$3
    _endpoints=$4
    _manual=$5
    _v4=$(printf '%s\n%s\n' "$_endpoints" "$_manual" | /usr/bin/awk 'NF && $0 !~ /:/ { printf "%s%s", (n++ ? ", " : ""), $0 }')
    _v6=$(printf '%s\n%s\n' "$_endpoints" "$_manual" | /usr/bin/awk 'NF && $0 ~ /:/ { printf "%s%s", (n++ ? ", " : ""), $0 }')
    _tun=$(printf '%s\n' "$_tunnels" | /usr/bin/awk 'NF { printf "%s%s", (n++ ? ", " : ""), $1 }')
    if [ -n "$_tun" ]; then
        printf 'pass out quick on { %s } all no state\n' "$_tun"
    fi
    if [ -n "$_v4" ]; then
        printf 'pass out quick inet to { %s } no state\n' "$_v4"
    fi
    if [ -n "$_v6" ]; then
        printf 'pass out quick inet6 to { %s } no state\n' "$_v6"
    fi
    printf '%s\n' \
      "pass out quick on $_iface route-to ($NIMBUS_IFACE $NIMBUS_GATEWAY4) inet proto tcp from any to any port {80,443,2053,2083,2087,2096,8443} user { >root } no state" \
      "pass out quick on $_iface route-to ($NIMBUS_IFACE $NIMBUS_GATEWAY4) inet proto udp from any to any port {443,19294:19344,50000:50100} user { >root } no state"
    if [ "$_ipv6" = 1 ]; then
        printf '%s\n' \
          "pass out quick on $_iface route-to ($NIMBUS_IFACE $NIMBUS_GATEWAY6) inet6 proto tcp from any to any port {80,443,2053,2083,2087,2096,8443} user { >root } no state" \
          "pass out quick on $_iface route-to ($NIMBUS_IFACE $NIMBUS_GATEWAY6) inet6 proto udp from any to any port {443,19294:19344,50000:50100} user { >root } no state"
    fi
}
