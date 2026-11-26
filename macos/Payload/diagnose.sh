#!/bin/sh
# Prints machine-readable diagnostic rows: LEVEL<TAB>NAME<TAB>DETAIL
# Safe to run as root from the privileged helper. Does not change system state.
set -u

OUT=${1:-}
USER_UID=${2:-}
USER_GID=${3:-}
if [ -n "$OUT" ]; then
    case "$OUT" in
        /Users/*/'Library/Application Support/ZapretMac'/diagnostics.txt) ;;
        *) exit 1 ;;
    esac
fi

LOG=/var/run/nimbus-diag.$$
/bin/rm -f "$LOG"
exec 3>&1
exec 1>"$LOG"

ANCHOR=com.apple/zapret-macos
TAB=$(printf '\t')

row() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

PF_INFO=$(/sbin/pfctl -s info 2>/dev/null || true)
case "$PF_INFO" in
    *'Status: Enabled'*) row OK 'pf' 'включён' ;;
    *'Status: Disabled'*) row FAIL 'pf' 'выключен' ;;
    *) row WARN 'pf' 'не удалось прочитать статус' ;;
esac

RULES=$(/sbin/pfctl -a "$ANCHOR" -sr 2>/dev/null || true)
if printf '%s\n' "$RULES" | /usr/bin/grep -q 'route-to.*(utun50'; then
    DETAIL='якорь com.apple/zapret-macos активен'
    if printf '%s\n' "$RULES" | /usr/bin/grep -q 'inet6'; then
        DETAIL="$DETAIL, есть правила IPv6"
    else
        DETAIL="$DETAIL, только IPv4"
    fi
    row OK 'правила pf' "$DETAIL"
else
    row FAIL 'правила pf' 'якорь Nimbus пуст или недоступен'
fi

if /sbin/ifconfig utun50 >/dev/null 2>&1; then
    DETAIL='интерфейс есть'
    if /sbin/ifconfig utun50 | /usr/bin/grep -q 'inet6 fd77::'; then
        DETAIL="$DETAIL, IPv6 fd77::1 настроен"
    else
        DETAIL="$DETAIL, IPv4 10.77.0.1"
    fi
    if /usr/bin/pgrep -x utunws >/dev/null 2>&1; then
        DETAIL="$DETAIL, utunws запущен"
        row OK 'utun50' "$DETAIL"
    else
        row WARN 'utun50' "$DETAIL, но процесс utunws не найден"
    fi
else
    if /usr/bin/pgrep -x utunws >/dev/null 2>&1; then
        row WARN 'utun50' 'интерфейса нет, но utunws ещё жив'
    else
        row WARN 'utun50' 'интерфейс не создан (движок выключен)'
    fi
fi

IFACE=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')
GATEWAY=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2; exit}')
if [ -n "$IFACE" ] && [ -n "$GATEWAY" ]; then
    MAC=$(/usr/sbin/arp -n "$GATEWAY" 2>/dev/null | /usr/bin/awk '/ at /{print $4; exit}')
    DETAIL="iface $IFACE, gateway $GATEWAY"
    case "$MAC" in
        *:*:*:*:*:*) DETAIL="$DETAIL, MAC $MAC" ;;
        *) DETAIL="$DETAIL, MAC не найден" ;;
    esac
    case "$IFACE" in
        utun50) row OK 'маршрут IPv4' "$DETAIL" ;;
        utun*|ipsec*|ppp*) row OK 'маршрут IPv4' "через туннель, Nimbus работает на физическом интерфейсе: $DETAIL" ;;
        *) row OK 'маршрут IPv4' "$DETAIL" ;;
    esac
else
    row FAIL 'маршрут IPv4' 'нет маршрута по умолчанию'
fi

if /sbin/route -n get -inet6 default >/tmp/nimbus-diag-route6 2>/dev/null; then
    IFACE6=$(/usr/bin/awk '/interface:/{print $2; exit}' /tmp/nimbus-diag-route6)
    GATEWAY6=$(/usr/bin/awk '/gateway:/{print $2; exit}' /tmp/nimbus-diag-route6)
    /bin/rm -f /tmp/nimbus-diag-route6
    MAC6=
    if [ -n "$GATEWAY6" ]; then
        MAC6=$(/usr/sbin/ndp -n "$GATEWAY6" 2>/dev/null | /usr/bin/awk '/ at |%/{for(i=1;i<=NF;i++) if($i ~ /^([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}$/){print $i; exit}}')
    fi
    DETAIL="iface ${IFACE6:-?}, gateway ${GATEWAY6:-?}"
    if [ -n "$MAC6" ]; then DETAIL="$DETAIL, MAC $MAC6"; fi
    case "$IFACE6" in
        utun50) row OK 'маршрут IPv6' "$DETAIL" ;;
        utun*|ipsec*|ppp*) row OK 'маршрут IPv6' "через туннель, Nimbus работает на физическом интерфейсе: $DETAIL" ;;
        *) row OK 'маршрут IPv6' "$DETAIL" ;;
    esac
    if /sbin/ifconfig utun50 2>/dev/null | /usr/bin/grep -q 'inet6 fd77::'; then
        if printf '%s\n' "$RULES" | /usr/bin/grep -q 'inet6'; then
            row OK 'IPv6 Nimbus' 'интерфейс и правила inet6 на месте'
        else
            row WARN 'IPv6 Nimbus' 'адрес на utun50 есть, но правил inet6 нет'
        fi
    else
        row WARN 'IPv6 Nimbus' 'есть системный IPv6, но Nimbus работает только по IPv4'
    fi
else
    /bin/rm -f /tmp/nimbus-diag-route6
    row OK 'маршрут IPv6' 'системного IPv6-маршрута нет, используется только IPv4'
fi

# VPN clients (names only; no arguments). Their tunnels and servers are passed through untouched,
# so this is information; only WARP, which takes over every connection, is a warning.
VPN_PROCS=$(/bin/ps -axo comm= 2>/dev/null | /usr/bin/awk 'BEGIN{IGNORECASE=1}
    /WireGuard|wg-quick|openvpn|CloudflareWARP|warp-svc|Amnezia|Hiddify|sing-box|singbox|xray|v2ray|Outline|tailscaled|ZeroTier|ProtonVPN|Mullvad|NordVPN|ExpressVPN|RabbitHole|rabbithole/ {print $0}' |
    /usr/bin/sed 's|.*/||' | /usr/bin/sort -u | /usr/bin/tr '\n' ', ' | /usr/bin/sed 's/,$//; s/,/, /g')
TUNNELS=$(/sbin/ifconfig -l 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/awk '/^(utun|ipsec|ppp|tun|tap|wg)[0-9]+$/ && $0 != "utun50"' | /usr/bin/tr '\n' ' ')
SKIPS=$(printf '%s\n' "$RULES" | /usr/bin/grep -Ec '^pass out quick (on [{]|inet6? to)' || true)
case "$VPN_PROCS" in
    *WARP*|*warp*) row WARN 'VPN' "$VPN_PROCS: перехватывает все соединения, обход не сработает" ;;
    '') row OK 'VPN' 'известных VPN-процессов не видно' ;;
    *) row OK 'VPN' "$VPN_PROCS: трафик туннеля Nimbus не трогает (правил-пропусков: $SKIPS)" ;;
esac
if [ -n "$TUNNELS" ] && [ -z "$VPN_PROCS" ]; then
    row OK 'туннели' "$TUNNELS: не трогаем"
fi

exec 1>&3
/bin/cat "$LOG"
if [ -n "$OUT" ]; then
    /bin/rm -f "$OUT"
    ( set -C; /bin/cat "$LOG" > "$OUT" ) 2>/dev/null || /bin/cp "$LOG" "$OUT"
    if [ -n "$USER_UID" ] && [ -n "$USER_GID" ]; then
        /usr/sbin/chown -h "$USER_UID:$USER_GID" "$OUT" 2>/dev/null || true
    fi
fi
/bin/rm -f "$LOG"

