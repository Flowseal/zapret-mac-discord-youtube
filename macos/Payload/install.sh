#!/bin/sh
set -eu

SOURCE=$1
DATA_ROOT=$2
DEST='/Library/Application Support/ZapretMac'
PLIST=/Library/LaunchDaemons/io.github.flowseal.zapretmac.plist
ANCHOR=com.apple/zapret-macos
KEEPINIT_FILE=/var/db/zapret-macos.keepinit

case "$DATA_ROOT" in
    /Users/*/'Library/Application Support/ZapretMac') ;;
    *) echo 'invalid user data path'; exit 1 ;;
esac

/bin/launchctl bootout system/io.github.flowseal.zapretmac >/dev/null 2>&1 || true
/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
/usr/bin/pkill -9 -x utunws >/dev/null 2>&1 || true
/bin/mkdir -p "$DEST"
/usr/bin/rsync -a --delete "$SOURCE/" "$DEST/"
/usr/bin/touch "$DEST/ipset-any.txt"
/usr/sbin/chown -R root:wheel "$DEST"
/bin/chmod 755 "$DEST/install.sh" "$DEST/run.sh" "$DEST/restart.sh" "$DEST/stop.sh" "$DEST/test-strategies.sh" "$DEST/update-app.sh" "$DEST/watchdog.sh" "$DEST/bin/utunws"
/usr/bin/sed "s|@DATA_ROOT@|$DATA_ROOT|g" "$DEST/io.github.flowseal.zapretmac.plist.in" > "$PLIST"
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
if [ ! -s "$KEEPINIT_FILE" ]; then
    /usr/sbin/sysctl -n net.inet.tcp.keepinit > "$KEEPINIT_FILE"
    /bin/chmod 600 "$KEEPINIT_FILE"
fi
/usr/sbin/sysctl -w net.inet.tcp.keepinit=7000 >/dev/null
/bin/launchctl enable system/io.github.flowseal.zapretmac
I=0
while ! /bin/launchctl bootstrap system "$PLIST"; do
    I=$((I + 1))
    if [ "$I" -gt 10 ]; then
        /bin/sh "$DEST/stop.sh"
        exit 1
    fi
    sleep 0.5
done
/bin/launchctl kickstart -k system/io.github.flowseal.zapretmac

I=0
while ! /sbin/ifconfig utun50 >/dev/null 2>&1; do
    I=$((I + 1))
    if [ "$I" -gt 100 ]; then
        /bin/sh "$DEST/stop.sh"
        echo 'utunws did not stay running' >&2
        /usr/bin/tail -40 "$DEST/engine.log" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.1
done
