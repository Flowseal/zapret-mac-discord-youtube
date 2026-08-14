#!/bin/sh
set -eu

NEW_APP=$1
TARGET_APP=$2
APP_PID=$3
WORK_ROOT=$4
WAS_RUNNING=$5
DATA_ROOT=$6
USER_UID=$7
USER_GID=$8

case "$NEW_APP:$TARGET_APP:$WORK_ROOT:$DATA_ROOT" in
    "$WORK_ROOT"/extracted/ZapretMac.app:*.app:*/ZapretMac-Update-*:/Users/*/'Library/Application Support/ZapretMac') ;;
    *) exit 1 ;;
esac
case "$APP_PID:$USER_UID:$USER_GID" in
    *[!0-9:]*) exit 1 ;;
esac
case "$WAS_RUNNING" in
    0|1) ;;
    *) exit 1 ;;
esac

[ -d "$NEW_APP" ]
[ -d "$TARGET_APP" ]
[ -f "$NEW_APP/Contents/Info.plist" ]
[ -x "$NEW_APP/Contents/MacOS/ZapretMac" ]

I=0
while /bin/kill -0 "$APP_PID" >/dev/null 2>&1; do
    I=$((I + 1))
    [ "$I" -le 300 ] || exit 1
    /bin/sleep 0.1
done

PARENT=$(/usr/bin/dirname "$TARGET_APP")
BACKUP="$PARENT/.ZapretMac.app.update-$$"
OWNER=$(/usr/bin/stat -f %u "$TARGET_APP")
GROUP=$(/usr/bin/stat -f %g "$TARGET_APP")
ERROR_FILE="$DATA_ROOT/update-error"

reopen() {
    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "#$USER_UID" -H /usr/bin/open "$TARGET_APP"
}

/bin/mv "$TARGET_APP" "$BACKUP"
if ! /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
    /bin/rm -rf "$TARGET_APP"
    /bin/mv "$BACKUP" "$TARGET_APP"
    reopen
    exit 1
fi
/usr/sbin/chown -R "$OWNER:$GROUP" "$TARGET_APP"
if ! /usr/bin/codesign --verify --deep --strict "$TARGET_APP" || ! /usr/bin/lipo "$TARGET_APP/Contents/MacOS/ZapretMac" -verify_arch x86_64 arm64; then
    /bin/rm -rf "$TARGET_APP"
    /bin/mv "$BACKUP" "$TARGET_APP"
    reopen
    exit 1
fi
/bin/rm -rf "$BACKUP"
/bin/rm -f "$ERROR_FILE"
if [ "$WAS_RUNNING" = 1 ]; then
    if ! /bin/sh "$TARGET_APP/Contents/Resources/Payload/install.sh" "$TARGET_APP/Contents/Resources/Payload" "$DATA_ROOT"; then
        echo 'Приложение обновлено, но не удалось перезапустить Zapret. Запустите его из меню ещё раз.' > "$ERROR_FILE"
        /usr/sbin/chown "$USER_UID:$USER_GID" "$ERROR_FILE"
    fi
fi
reopen
/usr/sbin/chown "$USER_UID:$USER_GID" "$DATA_ROOT/update.log" >/dev/null 2>&1 || true
/bin/rm -rf "$WORK_ROOT"
