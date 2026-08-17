#!/bin/sh
set -eu

PLIST=/Library/LaunchDaemons/io.github.flowseal.zapretmac.plist
if [ ! -f "$PLIST" ]; then exit 0; fi
/bin/launchctl enable system/io.github.flowseal.zapretmac
if ! /bin/launchctl print system/io.github.flowseal.zapretmac >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$PLIST"
fi
/bin/launchctl kickstart -k system/io.github.flowseal.zapretmac
