#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
BASE='/Library/Application Support/ZapretMac'
LABEL='system/io.github.flowseal.zapretmac'
PLIST='/Library/LaunchDaemons/io.github.flowseal.zapretmac.plist'
KEEPINIT='/var/db/zapret-macos.keepinit'

[ "$(/usr/bin/id -u)" = 0 ] || exit 77
[ "$#" = 1 ] || exit 64
case "$1" in
    stop)
        /bin/sh "$BASE/stop.sh"
        if /usr/bin/pgrep -x utunws >/dev/null 2>&1; then
            echo 'ZapretMac did not stop' >&2
            exit 1
        fi
        exit 0
        ;;
    start|restart) ;;
    *) exit 64 ;;
esac

if [ "$1" = start ] && /bin/launchctl print "$LABEL" >/dev/null 2>&1 &&
    /usr/bin/pgrep -x utunws >/dev/null 2>&1 && /sbin/ifconfig utun50 >/dev/null 2>&1; then
    exit 0
fi

# Re-create the timeout backup after stop.sh removes it, as upstream install.sh does.
if [ -L "$KEEPINIT" ]; then exit 77; fi
if [ ! -s "$KEEPINIT" ]; then
    /usr/sbin/sysctl -n net.inet.tcp.keepinit > "$KEEPINIT"
    /bin/chmod 600 "$KEEPINIT"
fi
/usr/sbin/sysctl -w net.inet.tcp.keepinit=7000 >/dev/null
/bin/launchctl enable "$LABEL"
if ! /bin/launchctl print "$LABEL" >/dev/null 2>&1; then
    I=0
    until /bin/launchctl bootstrap system "$PLIST"; do
        I=$((I + 1))
        if [ "$I" -gt 10 ]; then
            /bin/sh "$BASE/stop.sh"
            echo 'Unable to start ZapretMac service' >&2
            exit 1
        fi
        /bin/sleep 0.5
    done
fi
if ! /bin/launchctl kickstart -k "$LABEL"; then
    /bin/sh "$BASE/stop.sh"
    exit 1
fi
I=0
until /usr/bin/pgrep -x utunws >/dev/null 2>&1 && /sbin/ifconfig utun50 >/dev/null 2>&1; do
    I=$((I + 1))
    if [ "$I" -gt 100 ]; then
        /bin/sh "$BASE/stop.sh"
        echo 'utunws did not stay running' >&2
        /usr/bin/tail -20 "$BASE/engine.log" >&2 2>/dev/null || true
        exit 1
    fi
    /bin/sleep 0.1
done
