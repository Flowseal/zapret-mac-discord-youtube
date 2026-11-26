#!/bin/sh
# Checks the text the pf helpers produce. Needs only sh and awk: no pf, no root, no network.
set -u

HERE=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
# shellcheck source=../Payload/pf-lib.sh
. "$HERE/../Payload/pf-lib.sh"

FAILED=0
PASSED=0

check() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n--- expected\n%s\n--- got\n%s\n' "$1" "$3" "$2"
    fi
}

# --- manual entries -------------------------------------------------------------------------
check 'separators and comments' \
    "$(printf '203.0.113.7, 198.51.100.0/24;2001:db8::/32\n192.0.2.1\t# note\n# only a comment\n' | pf_valid_entries)" \
    '203.0.113.7
198.51.100.0/24
2001:db8:0:0:0:0:0:0/32
192.0.2.1'

check 'host bits are cleared' \
    "$(printf '10.1.2.3/8 192.168.1.77/24 203.0.113.7/32 2001:db8:1234::5/48' | pf_valid_entries)" \
    '10.0.0.0/8
192.168.1.0/24
203.0.113.7
2001:db8:1234:0:0:0:0:0/48'

check 'ipv6 forms' \
    "$(printf '2001:DB8::1 ::ffff:1 fe80::1' | pf_valid_entries)" \
    '2001:db8:0:0:0:0:0:1
0:0:0:0:0:0:ffff:1
fe80:0:0:0:0:0:0:1'

check 'junk is dropped' \
    "$(printf 'example.com 1.2.3 256.1.1.1 203.0.113.7/33 203.0.113.7/ 0.0.0.0 0.0.0.0/0 ::/0 ::  010.1.1.1 1.2.3.4.5 12345 ok;rm' | pf_valid_entries)" \
    ''

check 'duplicates collapse' \
    "$(printf '203.0.113.7 203.0.113.7 10.9.9.9/8 10.0.0.0/8' | pf_valid_entries)" \
    '203.0.113.7
10.0.0.0/8'

check 'list is capped at 64' \
    "$(i=1; while [ "$i" -le 80 ]; do printf '10.0.%s.1\n' "$i"; i=$((i + 1)); done | pf_valid_entries | wc -l | tr -d ' ')" \
    '64'

check 'empty input' "$(printf '' | pf_valid_entries)" ''

# --- tunnels --------------------------------------------------------------------------------
check 'tunnels from ifconfig -l' \
    "$(printf 'lo0 gif0 stf0 en0 en1 utun0 utun1 utun4 utun50 ipsec0 ppp0 tun1 tap0 wg0 bridge0 awdl0' | pf_tunnels)" \
    'utun0
utun1
utun4
ipsec0
ppp0
tun1
tap0
wg0'

check 'no tunnels' "$(printf 'lo0 en0 awdl0 utun50' | pf_tunnels)" ''
check 'own interface follows NIMBUS_IFACE' "$(export NIMBUS_IFACE=utun7; printf 'utun7 utun50' | pf_tunnels)" 'utun50'

# --- default route --------------------------------------------------------------------------
ROUTES='Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            10.8.0.5           UGSc                utun4
default            192.168.1.1        UGScIg                en0
default            link#17            UCSIg               utun5
10.8.0.1/32        10.8.0.5           UGSc                utun4
127.0.0.1          127.0.0.1          UH                    lo0
203.0.113.7        192.168.1.1        UGHS                  en0
198.51.100.4       192.168.9.9        UGHS                  en0
192.168.1.1        link#4             UHRLWIig              en0
224.0.0.251        link#4             UHmLWI                en0'
check 'physical default skips tunnels' "$(printf '%s\n' "$ROUTES" | pf_physical_default)" 'en0 192.168.1.1'
check 'only tunnel defaults' "$(printf 'default 10.8.0.5 UGSc utun4\ndefault link#17 UCSIg utun5\n' | pf_physical_default)" ''
check 'plain default' "$(printf 'default            192.168.0.1        UGScg                 en1\n' | pf_physical_default)" 'en1 192.168.0.1'
check 'host routes through the gateway' "$(printf '%s\n' "$ROUTES" | pf_host_routes 192.168.1.1)" '203.0.113.7'
check 'host routes through another gateway' "$(printf '%s\n' "$ROUTES" | pf_host_routes 192.168.9.9)" '198.51.100.4'

# --- lsof -----------------------------------------------------------------------------------
LSOF='p101
cWindowServer
PUDP
n*:*
p4242
copenvpn
PUDP
n192.168.1.5:50123->203.0.113.7:1194
PTCP
n127.0.0.1:7505->127.0.0.1:50122
PTCP
n*:7505
p4243
cwireguard-go
PUDP
n[2001:db8::5]:51820->[2001:db8::7]:51820
p4300
cSafari
PTCP
n192.168.1.5:50200->198.51.100.50:443
p4400
cTailscaled
PTCP
n192.168.1.5:50300->203.0.113.99:443'
check 'lsof endpoints of VPN clients only' "$(printf '%s\n' "$LSOF" | pf_lsof_endpoints)" '203.0.113.7
2001:db8::7
203.0.113.99'

# --- rules ----------------------------------------------------------------------------------
check 'plain rules, nothing to skip' "$(pf_render en0 0 '' '' '')" \
    'pass out quick on en0 route-to (utun50 10.77.0.2) inet proto tcp from any to any port {80,443,2053,2083,2087,2096,8443} user { >root } no state
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto udp from any to any port {443,19294:19344,50000:50100} user { >root } no state'

check 'full rule set' "$(pf_render en0 1 'utun4
utun6' '203.0.113.7
2001:db8::7' '10.0.0.0/8
198.51.100.0/24')" \
    'pass out quick on { utun4, utun6 } all no state
pass out quick inet to { 203.0.113.7, 10.0.0.0/8, 198.51.100.0/24 } no state
pass out quick inet6 to { 2001:db8::7 } no state
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto tcp from any to any port {80,443,2053,2083,2087,2096,8443} user { >root } no state
pass out quick on en0 route-to (utun50 10.77.0.2) inet proto udp from any to any port {443,19294:19344,50000:50100} user { >root } no state
pass out quick on en0 route-to (utun50 fd77::2) inet6 proto tcp from any to any port {80,443,2053,2083,2087,2096,8443} user { >root } no state
pass out quick on en0 route-to (utun50 fd77::2) inet6 proto udp from any to any port {443,19294:19344,50000:50100} user { >root } no state'

RULES=$(pf_render en0 1 'utun4' '203.0.113.7' '')
FIRST_REDIRECT=$(printf '%s\n' "$RULES" | grep -n route-to | head -1 | cut -d: -f1)
LAST_SKIP=$(printf '%s\n' "$RULES" | grep -n -v route-to | tail -1 | cut -d: -f1)
check 'skips come before every redirect' "$([ "$LAST_SKIP" -lt "$FIRST_REDIRECT" ] && echo yes || echo no)" yes
check 'every redirect is bound to the interface' "$(printf '%s\n' "$RULES" | grep route-to | grep -vc ' on en0 route-to')" '0'
check 'only IPv4 entries' "$(pf_render en0 0 '' '203.0.113.7' '' | head -1)" 'pass out quick inet to { 203.0.113.7 } no state'

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
