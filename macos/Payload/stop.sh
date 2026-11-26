#!/bin/sh

LABEL=io.github.flowseal.zapretmac
ANCHOR=com.apple/zapret-macos
TOKEN_FILE=/var/run/zapret-macos.pf-token
KEEPINIT_FILE=/var/db/zapret-macos.keepinit

# KeepAlive brings the job back whenever bootout fails or only the engine is killed, so unload by every route,
# kill the supervisor before the engine and look again after the throttle interval.
stop_once() {
    /bin/launchctl disable "system/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl remove "$LABEL" >/dev/null 2>&1 || true
    /usr/bin/pkill -9 -f 'ZapretMac/run\.sh' >/dev/null 2>&1 || true
    /usr/bin/pkill -9 -f 'ZapretMac/watchdog\.sh' >/dev/null 2>&1 || true
    /usr/bin/pkill -9 -x utunws >/dev/null 2>&1 || true
    /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
}

alive() {
    /usr/bin/pgrep -x utunws >/dev/null 2>&1 || /usr/bin/pgrep -f 'ZapretMac/run\.sh' >/dev/null 2>&1
}

ROUND=0
while :; do
    stop_once
    sleep 2.5
    if ! alive; then break; fi
    ROUND=$((ROUND + 1))
    if [ "$ROUND" -ge 4 ]; then break; fi
done
# a respawned run.sh can load the anchor again in its first moments
/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true

if [ -s "$TOKEN_FILE" ]; then
    TOKEN=$(/bin/cat "$TOKEN_FILE" 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then /sbin/pfctl -X "$TOKEN" >/dev/null 2>&1 || true; fi
    /bin/rm -f "$TOKEN_FILE"
fi
if [ -s "$KEEPINIT_FILE" ]; then
    KEEPINIT=$(/bin/cat "$KEEPINIT_FILE" 2>/dev/null || true)
    case "$KEEPINIT" in
        *[!0-9]*|'') ;;
        *) /usr/sbin/sysctl -w "net.inet.tcp.keepinit=$KEEPINIT" >/dev/null 2>&1 || true ;;
    esac
    /bin/rm -f "$KEEPINIT_FILE"
fi

if alive; then
    echo 'utunws is still running after stop' >&2
    exit 1
fi
exit 0
