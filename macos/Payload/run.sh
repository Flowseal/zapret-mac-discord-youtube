#!/bin/sh
set -eu

DATA_ROOT=$1
BASE='/Library/Application Support/ZapretMac'
ANCHOR=com.apple/zapret-macos
TOKEN_FILE=/var/run/zapret-macos.pf-token
KEEPINIT_FILE=/var/db/zapret-macos.keepinit
ENGINE_PID=
WATCHDOG_PID=
LEAVE_ALONE_FILE=

case "$DATA_ROOT" in
    /Users/*/'Library/Application Support/ZapretMac') ;;
    *) exit 1 ;;
esac

LEAVE_ALONE_FILE="$DATA_ROOT/leave-alone"

# shellcheck source=pf-lib.sh
. "$BASE/pf-lib.sh"

if [ -s "$KEEPINIT_FILE" ]; then
    /usr/sbin/sysctl -w net.inet.tcp.keepinit=7000 >/dev/null
fi

clear_intercept() {
    /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
}

release_pf_token() {
    if [ -s "$TOKEN_FILE" ]; then
        TOKEN=$(/bin/cat "$TOKEN_FILE" 2>/dev/null || true)
        if [ -n "$TOKEN" ]; then /sbin/pfctl -X "$TOKEN" >/dev/null 2>&1 || true; fi
        /bin/rm -f "$TOKEN_FILE"
    fi
}

cleanup() {
    trap - EXIT INT TERM HUP
    clear_intercept
    if [ -n "$WATCHDOG_PID" ]; then kill "$WATCHDOG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$ENGINE_PID" ]; then kill "$ENGINE_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$WATCHDOG_PID" ]; then wait "$WATCHDOG_PID" >/dev/null 2>&1 || true; fi
    if [ -n "$ENGINE_PID" ]; then wait "$ENGINE_PID" >/dev/null 2>&1 || true; fi
    release_pf_token
}

trap cleanup EXIT INT TERM HUP
clear_intercept
/usr/bin/pkill -9 -x utunws >/dev/null 2>&1 || true

# The interface and gateway the engine sends on. While a VPN owns the default route the physical one is still
# in the table as a scoped entry, so look for the first default route that is not a tunnel.
physical_default() {
    /usr/sbin/netstat -rn -f inet 2>/dev/null | pf_physical_default
}

PHYSICAL=$(physical_default)
if [ -z "$PHYSICAL" ]; then
    PHYSICAL=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{i=$2} /gateway:/{g=$2} END{ if (i != "" && g != "") print i, g }')
fi
PHYSICAL_IFACE=${PHYSICAL% *}
GATEWAY=${PHYSICAL#* }
if [ -z "$PHYSICAL" ] || [ -z "$PHYSICAL_IFACE" ] || [ -z "$GATEWAY" ]; then exit 1; fi
/sbin/ping -c 1 -t 1 "$GATEWAY" >/dev/null 2>&1 || true
GATEWAY_MAC=$(/usr/sbin/arp -n "$GATEWAY" | /usr/bin/awk '/ at /{print $4; exit}')
case "$GATEWAY_MAC" in
    *:*:*:*:*:*) ;;
    *) exit 1 ;;
esac

GATEWAY6_MAC=
if /sbin/route -n get -inet6 default >/var/run/zapret-macos.route6 2>/dev/null; then
    GATEWAY6=$(/usr/bin/awk '/gateway:/{print $2; exit}' /var/run/zapret-macos.route6)
    if [ -n "$GATEWAY6" ]; then
        GATEWAY6_MAC=$(/usr/sbin/ndp -n "$GATEWAY6" 2>/dev/null | /usr/bin/awk '/ at |%/{for(i=1;i<=NF;i++) if($i ~ /^([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}$/){print $i; exit}}')
    fi
fi
/bin/rm -f /var/run/zapret-macos.route6

STRATEGY=$(/usr/bin/tr -d '[:space:]' <"$DATA_ROOT/selected-strategy" 2>/dev/null || true)
if ! printf '%s\n' "$STRATEGY" | /usr/bin/grep -Eq '^general(-[a-z0-9]+)*$' || [ ! -f "$BASE/strategies/$STRATEGY.conf.in" ]; then
    STRATEGY=general-simple-fake
fi

if [ -L "$DATA_ROOT" ] || [ -L "$DATA_ROOT/lists" ] || [ ! -d "$DATA_ROOT/lists" ]; then exit 1; fi
RUNTIME_LISTS="$BASE/lists"
/bin/mkdir -p "$RUNTIME_LISTS"
for NAME in list-general.txt list-general-user.txt list-google.txt list-exclude.txt list-exclude-user.txt ipset-all.txt ipset-all-user.txt ipset-exclude.txt ipset-exclude-user.txt; do
    SOURCE_LIST="$DATA_ROOT/lists/$NAME"
    if [ -L "$SOURCE_LIST" ] || [ ! -f "$SOURCE_LIST" ]; then exit 1; fi
    /usr/bin/install -m 0644 "$SOURCE_LIST" "$RUNTIME_LISTS/$NAME"
done
/usr/sbin/chown -R root:wheel "$RUNTIME_LISTS"
/bin/chmod 755 "$RUNTIME_LISTS"

IPSET_MODE=$(/usr/bin/tr -d '[:space:]' <"$DATA_ROOT/ipset-mode" 2>/dev/null || true)
case "$IPSET_MODE" in
    loaded) IPSET="$RUNTIME_LISTS/ipset-all.txt" ;;
    any) IPSET="$BASE/ipset-any.txt" ;;
    *) IPSET="$BASE/ipset-none.txt" ;;
esac

/usr/bin/sed -e "s|@BASE@|$BASE|g" -e "s|@LISTS@|$RUNTIME_LISTS|g" -e "s|@IPSET@|$IPSET|g" "$BASE/strategies/$STRATEGY.conf.in" > /var/run/zapret-macos.conf.tmp
/usr/bin/awk '
    { print }
    $0 ~ /--ipset-exclude=.*ipset-exclude-user\.txt/ { print "--ipset=\"'"$RUNTIME_LISTS"'/ipset-all-user.txt\"" }
' /var/run/zapret-macos.conf.tmp > /var/run/zapret-macos.conf
/bin/rm -f /var/run/zapret-macos.conf.tmp

export ZAPRET_IFACE="$PHYSICAL_IFACE"
export ZAPRET_GATEWAY_MAC="$GATEWAY_MAC"
export ZAPRET_GATEWAY6_MAC="$GATEWAY6_MAC"
export ZAPRET_UTUN_UNIT=51
"$BASE/bin/utunws" @/var/run/zapret-macos.conf >>"$BASE/engine.log" 2>&1 &
ENGINE_PID=$!

I=0
while ! /sbin/ifconfig utun50 >/dev/null 2>&1; do
    I=$((I + 1))
    if ! kill -0 "$ENGINE_PID" 2>/dev/null || [ "$I" -gt 100 ]; then exit 1; fi
    sleep 0.1
done
/sbin/ifconfig utun50 10.77.0.1 10.77.0.2 netmask 255.255.255.255 up
IPV6_ON=0
case "$GATEWAY6_MAC" in
    *:*:*:*:*:*)
        if /sbin/ifconfig utun50 inet6 fd77::1 fd77::2 prefixlen 128 up; then
            IPV6_ON=1
        fi
        ;;
esac
"$BASE/watchdog.sh" $$ "$ENGINE_PID" &
WATCHDOG_PID=$!

if /sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Disabled'; then
    TOKEN=$(/sbin/pfctl -E 2>&1 | /usr/bin/awk '/Token :/ { print $3 }')
    if [ -n "$TOKEN" ]; then /bin/echo "$TOKEN" >"$TOKEN_FILE"; fi
fi

# Tunnel interfaces, VPN servers and the user's own list are passed untouched before anything is redirected.
# The anchor is reloaded when they change; the engine and its states are left alone (the rules keep no state).
VPN_ENDPOINTS=
LAST_RULES=
FAILED_RULES=
# with "safe": only the redirect itself, in case something in the extras keeps pf from loading the set
build_rules() {
    TUNNELS=
    MANUAL=
    if [ "${1:-}" != safe ]; then
        TUNNELS=$(/sbin/ifconfig -l 2>/dev/null | pf_tunnels)
        if [ -r "$LEAVE_ALONE_FILE" ]; then MANUAL=$(pf_valid_entries <"$LEAVE_ALONE_FILE" || true); fi
    fi
    pf_render "$PHYSICAL_IFACE" "$IPV6_ON" "$TUNNELS" "$([ "${1:-}" = safe ] || printf '%s' "$VPN_ENDPOINTS")" "$MANUAL"
}

refresh_endpoints() {
    VPN_ENDPOINTS=$({
        /usr/sbin/lsof +c 0 -nP -i -F pcPn 2>/dev/null | pf_lsof_endpoints
        /usr/sbin/netstat -rn -f inet 2>/dev/null | pf_host_routes "$GATEWAY"
    } | /usr/bin/sort -u)
}

# Returns non-zero when pf refuses the rules; a rule set that does not load must never stop the engine.
apply_rules() {
    RULES=$(build_rules "${1:-}")
    if [ "$RULES" = "$LAST_RULES" ]; then return 0; fi
    if [ "$RULES" = "$FAILED_RULES" ]; then return 1; fi
    if printf '%s\n' "$RULES" | /sbin/pfctl -a "$ANCHOR" -f - 2>/dev/null; then
        LAST_RULES=$RULES
        return 0
    fi
    FAILED_RULES=$RULES
    return 1
}

refresh_endpoints
if ! apply_rules; then
    # a stale interface name or a bad entry: redirect without the extras rather than not at all
    apply_rules safe
fi

TICK=0
LOST=0
while kill -0 "$ENGINE_PID" 2>/dev/null; do
    sleep 2
    TICK=$((TICK + 1))
    CURRENT=$(physical_default)
    if [ -z "$CURRENT" ]; then
        # the network is briefly gone, or a VPN is replacing routes: wait a few rounds before giving up
        LOST=$((LOST + 1))
        if [ "$LOST" -gt 5 ]; then exit 1; fi
        continue
    fi
    LOST=0
    if [ "$CURRENT" != "$PHYSICAL_IFACE $GATEWAY" ]; then exit 1; fi
    if [ $((TICK % 3)) -eq 1 ]; then refresh_endpoints; fi
    apply_rules || true
done
exit 1
