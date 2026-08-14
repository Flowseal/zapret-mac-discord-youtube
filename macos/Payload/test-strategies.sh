#!/bin/sh
set -u

SOURCE=$1
DATA_ROOT=$2
TEST_UID=$3
TEST_GID=$4
BASE='/Library/Application Support/ZapretMac'
REPORT="$DATA_ROOT/strategy-test.txt"
PROGRESS="$DATA_ROOT/strategy-test-progress"
CANCEL="$DATA_ROOT/strategy-test-cancel"
TMP=$(/usr/bin/mktemp -d /tmp/zapret-strategy-test.XXXXXX)
ORIGINAL_STRATEGY=$(/usr/bin/tr -d '[:space:]' <"$DATA_ROOT/selected-strategy" 2>/dev/null || true)
ORIGINAL_IPSET=$(/usr/bin/tr -d '[:space:]' <"$DATA_ROOT/ipset-mode" 2>/dev/null || true)
ORIGINAL_RUNNING=0
INSTALLED=0
CANCELLED=0

case "$DATA_ROOT" in
    /Users/*/'Library/Application Support/ZapretMac') ;;
    *) exit 1 ;;
esac
case "$TEST_UID:$TEST_GID" in
    *[!0-9:]*|:|*:|:*) exit 1 ;;
esac

if /usr/bin/pgrep -x utunws >/dev/null 2>&1; then ORIGINAL_RUNNING=1; fi

restore() {
    trap - EXIT INT TERM HUP
    set_progress 'Восстановление настроек'
    printf '%s\n' "$ORIGINAL_STRATEGY" >"$DATA_ROOT/selected-strategy"
    printf '%s\n' "$ORIGINAL_IPSET" >"$DATA_ROOT/ipset-mode"
    if [ "$ORIGINAL_RUNNING" -eq 1 ]; then
        if [ "$INSTALLED" -eq 1 ]; then
            "$BASE/restart.sh" >/dev/null 2>&1 || true
        else
            "$SOURCE/install.sh" "$SOURCE" "$DATA_ROOT" >/dev/null 2>&1 || true
        fi
    else
        "$SOURCE/stop.sh" >/dev/null 2>&1 || true
    fi
    /usr/sbin/chown "$TEST_UID:$TEST_GID" "$REPORT" 2>/dev/null || true
    /bin/chmod 644 "$REPORT" 2>/dev/null || true
    /bin/rm -f "$PROGRESS" "$CANCEL"
    /bin/rm -rf "$TMP"
}

trap restore EXIT INT TERM HUP

run_user() {
    /usr/bin/sudo -u "#$TEST_UID" -H "$@"
}

set_progress() {
    printf '%s\n' "$1" >"$PROGRESS"
    /usr/sbin/chown "$TEST_UID:$TEST_GID" "$PROGRESS" 2>/dev/null || true
}

cancel_requested() {
    [ -e "$CANCEL" ]
}

probe_direct() {
    HOST=$1
    IP=$2
    OUT=$3
    VALUE=$(run_user /usr/bin/curl --noproxy '*' --resolve "$HOST:443:$IP" --connect-timeout 2 --max-time 3 --tlsv1.2 --tls-max 1.2 --http1.1 -sS -o /dev/null -w '%{time_connect}\t%{http_code}\t%{time_total}' "https://$HOST/" 2>/dev/null)
    STATUS=$?
    OLD_IFS=$IFS
    IFS="$(printf '\t')"
    set -- $VALUE
    IFS=$OLD_IFS
    CONNECT=${1:-0}
    CODE=${2:-000}
    TOTAL=${3:-0}
    RANK=2
    if [ "$STATUS" -eq 0 ] && [ "$CODE" != 000 ]; then
        RANK=0
    elif /usr/bin/awk -v value="$CONNECT" 'BEGIN { exit !(value > 0) }'; then
        RANK=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$RANK" "$CONNECT" "$IP" "$CODE" "$TOTAL" >"$OUT"
}

discover_target() {
    INDEX=$1
    HOST=$2
    DIR="$TMP/discovery-$INDEX"
    /bin/mkdir -p "$DIR"
    run_user /usr/bin/dig +time=1 +tries=1 +short "$HOST" A >"$DIR/system" 2>/dev/null &
    run_user /usr/bin/dig @1.1.1.1 +time=1 +tries=1 +short "$HOST" A >"$DIR/cloudflare" 2>/dev/null &
    run_user /usr/bin/dig @8.8.8.8 +time=1 +tries=1 +short "$HOST" A >"$DIR/google" 2>/dev/null &
    wait
    /usr/bin/awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/' "$DIR/system" "$DIR/cloudflare" "$DIR/google" 2>/dev/null | /usr/bin/sort -u >"$DIR/ips"
    NUMBER=0
    while IFS= read -r IP; do
        NUMBER=$((NUMBER + 1))
        probe_direct "$HOST" "$IP" "$DIR/probe-$NUMBER" &
    done <"$DIR/ips"
    wait
    if /bin/ls "$DIR"/probe-* >/dev/null 2>&1; then
        /bin/cat "$DIR"/probe-* | /usr/bin/sort -t "$(printf '\t')" -k1,1n -k2,2n >"$DIR/ranked"
        LINE=$(/usr/bin/awk -F "$(printf '\t')" '$1 < 2 { print; exit }' "$DIR/ranked")
        if [ -n "$LINE" ]; then
            printf '%s\n' "$LINE" >"$TMP/selected-$INDEX"
        fi
    fi
}

curl_test() {
    KIND=$1
    HOST=$2
    IP=$3
    OUT=$4
    PORT=443
    URL="https://$HOST/"
    TLS_ARGS=''
    case "$KIND" in
        http)
            PORT=80
            URL="http://$HOST/"
            ;;
        tls12)
            TLS_ARGS='--tlsv1.2 --tls-max 1.2'
            ;;
        tls13)
            TLS_ARGS='--tlsv1.3 --tls-max 1.3'
            ;;
    esac
    VALUE=$(run_user /usr/bin/curl --noproxy '*' --resolve "$HOST:$PORT:$IP" --connect-timeout 2 --max-time 4 --http1.1 $TLS_ARGS -sS -o /dev/null -w '%{http_code}\t%{time_total}' "$URL" 2>/dev/null)
    STATUS=$?
    OLD_IFS=$IFS
    IFS="$(printf '\t')"
    set -- $VALUE
    IFS=$OLD_IFS
    CODE=${1:-000}
    TIME=${2:-0}
    if [ "$STATUS" -eq 0 ] && [ "$CODE" != 000 ]; then
        printf 'OK\t%s\t%s\n' "$CODE" "$TIME" >"$OUT"
    else
        printf 'FAIL\t%s\t%s\t%s\n' "$CODE" "$TIME" "$STATUS" >"$OUT"
    fi
}

ping_test() {
    IP=$1
    OUT=$2
    if run_user /sbin/ping -n -c 1 -W 1000 "$IP" >/dev/null 2>&1; then
        printf 'OK\n' >"$OUT"
    else
        printf 'FAIL\n' >"$OUT"
    fi
}

wait_for_engine() {
    OLD_PID=$1
    I=0
    while [ "$I" -lt 80 ]; do
        if cancel_requested; then return 2; fi
        NEW_PID=$(/usr/bin/pgrep -x utunws 2>/dev/null | /usr/bin/head -1)
        if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && /sbin/ifconfig utun50 >/dev/null 2>&1 && /sbin/pfctl -a com.apple/zapret-macos -sr 2>/dev/null | /usr/bin/grep -q route-to; then
            return 0
        fi
        I=$((I + 1))
        sleep 0.1
    done
    return 1
}

start_strategy() {
    STRATEGY=$1
    OLD_PID=$(/usr/bin/pgrep -x utunws 2>/dev/null | /usr/bin/head -1)
    printf '%s\n' "$STRATEGY" >"$DATA_ROOT/selected-strategy"
    printf 'any\n' >"$DATA_ROOT/ipset-mode"
    if [ "$INSTALLED" -eq 0 ]; then
        if ! "$SOURCE/install.sh" "$SOURCE" "$DATA_ROOT" >"$TMP/install.log" 2>&1; then return 1; fi
        INSTALLED=1
    else
        if ! "$BASE/restart.sh" >"$TMP/restart.log" 2>&1; then return 1; fi
    fi
    wait_for_engine "$OLD_PID"
}

TARGETS='discord.com
gateway.discord.gg
cdn.discordapp.com
updates.discord.com
www.youtube.com
youtu.be
i.ytimg.com
redirector.googlevideo.com
www.gstatic.com'

: >"$REPORT"
set_progress 'Подготовка'
"$SOURCE/stop.sh" >/dev/null 2>&1 || true
INDEX=0
while IFS= read -r HOST; do
    INDEX=$((INDEX + 1))
    discover_target "$INDEX" "$HOST" &
done <<EOF
$TARGETS
EOF
wait
if cancel_requested; then
    printf 'Остановлено\n' >>"$REPORT"
    exit 0
fi

TLS13=0
INDEX=0
printf '%s\n' "$TARGETS" | while IFS= read -r HOST; do
    INDEX=$((INDEX + 1))
    if [ -s "$TMP/selected-$INDEX" ]; then
        IP=$(/usr/bin/awk -F "$(printf '\t')" '{print $3}' "$TMP/selected-$INDEX")
        run_user /usr/bin/curl --noproxy '*' --resolve "$HOST:443:$IP" --connect-timeout 2 --max-time 3 --tlsv1.3 --tls-max 1.3 --http1.1 -sS -o /dev/null "https://$HOST/" >/dev/null 2>&1
        STATUS=$?
        if [ "$STATUS" -ne 4 ]; then printf '1\n' >"$TMP/tls13"; fi
        break
    fi
done
if [ -s "$TMP/tls13" ]; then TLS13=1; fi

{
    /bin/date '+%Y-%m-%d %H:%M:%S %z'
    if [ "$TLS13" -eq 1 ]; then printf 'TLS1.3: yes\n'; else printf 'TLS1.3: no\n'; fi
    printf '\nIP:\n'
} >>"$REPORT"

INDEX=0
printf '%s\n' "$TARGETS" | while IFS= read -r HOST; do
    INDEX=$((INDEX + 1))
    if [ -s "$TMP/selected-$INDEX" ]; then
        OLD_IFS=$IFS
        IFS="$(printf '\t')"
        set -- $(/bin/cat "$TMP/selected-$INDEX")
        IFS=$OLD_IFS
        RANK=$1
        CONNECT=$2
        IP=$3
        if [ "$RANK" -eq 0 ]; then STATE='ok'; else STATE='tcp'; fi
        printf '%-30s %-15s %s\n' "$HOST" "$IP" "$STATE" >>"$REPORT"
        printf '1\n' >"$TMP/available-$INDEX"
    else
        printf '%-30s -\n' "$HOST" >>"$REPORT"
    fi
done
AVAILABLE_COUNT=$(/bin/ls "$TMP"/available-* 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')

BEST_SCORE=-1
BEST_TLS=-1
BEST_NAMES=''
STRATEGY_NUMBER=0
STRATEGY_TOTAL=$(/usr/bin/wc -l <"$SOURCE/strategies.tsv" | /usr/bin/tr -d ' ')
MAX_TOTAL=$((AVAILABLE_COUNT * (3 + TLS13)))
printf '\n%-34s %7s %7s %7s %7s %7s\n' 'Strategy' 'Score' 'Ping' 'HTTP' 'TLS1.2' 'TLS1.3' >>"$REPORT"
TAB=$(printf '\t')
if [ "$AVAILABLE_COUNT" -eq 0 ]; then
    printf 'Нет доступных IP\n' >>"$REPORT"
fi
while IFS="$TAB" read -r STRATEGY_ID STRATEGY_NAME; do
    [ -n "$STRATEGY_ID" ] || continue
    [ "$AVAILABLE_COUNT" -gt 0 ] || break
    if cancel_requested; then CANCELLED=1; break; fi
    STRATEGY_NUMBER=$((STRATEGY_NUMBER + 1))
    set_progress "Стратегия $STRATEGY_NUMBER/$STRATEGY_TOTAL: $STRATEGY_NAME"
    RESULT_DIR="$TMP/results-$STRATEGY_NUMBER"
    /bin/mkdir -p "$RESULT_DIR"
    if ! start_strategy "$STRATEGY_ID"; then
        if cancel_requested; then CANCELLED=1; break; fi
        printf '%-34s %s\n' "$STRATEGY_NAME" 'ошибка запуска' >>"$REPORT"
        continue
    fi
    INDEX=0
    while IFS= read -r HOST; do
        INDEX=$((INDEX + 1))
        [ -s "$TMP/available-$INDEX" ] || continue
        IP=$(/usr/bin/awk -F "$TAB" '{print $3}' "$TMP/selected-$INDEX")
        ping_test "$IP" "$RESULT_DIR/$INDEX-ping" &
        curl_test http "$HOST" "$IP" "$RESULT_DIR/$INDEX-http" &
        curl_test tls12 "$HOST" "$IP" "$RESULT_DIR/$INDEX-tls12" &
        if [ "$TLS13" -eq 1 ]; then curl_test tls13 "$HOST" "$IP" "$RESULT_DIR/$INDEX-tls13" & fi
    done <<EOF
$TARGETS
EOF
    wait
    if cancel_requested; then CANCELLED=1; break; fi
    SCORE=0
    TLS_SCORE=0
    TOTAL=0
    PING_OK=0
    HTTP_OK=0
    TLS12_OK=0
    TLS13_OK=0
    INDEX=0
    while IFS= read -r HOST; do
        INDEX=$((INDEX + 1))
        [ -s "$TMP/available-$INDEX" ] || continue
        IP=$(/usr/bin/awk -F "$TAB" '{print $3}' "$TMP/selected-$INDEX")
        PING=$(/usr/bin/awk -F "$TAB" '{print $1}' "$RESULT_DIR/$INDEX-ping")
        HTTP=$(/usr/bin/awk -F "$TAB" '{print $1}' "$RESULT_DIR/$INDEX-http")
        TLS12_RESULT=$(/usr/bin/awk -F "$TAB" '{print $1}' "$RESULT_DIR/$INDEX-tls12")
        TLS13_RESULT='N/A'
        if [ "$TLS13" -eq 1 ]; then TLS13_RESULT=$(/usr/bin/awk -F "$TAB" '{print $1}' "$RESULT_DIR/$INDEX-tls13"); fi
        TOTAL=$((TOTAL + 3 + TLS13))
        if [ "$PING" = OK ]; then SCORE=$((SCORE + 1)); PING_OK=$((PING_OK + 1)); fi
        if [ "$HTTP" = OK ]; then SCORE=$((SCORE + 1)); HTTP_OK=$((HTTP_OK + 1)); fi
        if [ "$TLS12_RESULT" = OK ]; then SCORE=$((SCORE + 1)); TLS_SCORE=$((TLS_SCORE + 1)); TLS12_OK=$((TLS12_OK + 1)); fi
        if [ "$TLS13_RESULT" = OK ]; then SCORE=$((SCORE + 1)); TLS_SCORE=$((TLS_SCORE + 1)); TLS13_OK=$((TLS13_OK + 1)); fi
    done <<EOF
$TARGETS
EOF
    if [ "$TLS13" -eq 1 ]; then TLS13_TEXT="$TLS13_OK/$AVAILABLE_COUNT"; else TLS13_TEXT='-'; fi
    printf '%-34s %7s %7s %7s %7s %7s\n' "$STRATEGY_NAME" "$SCORE/$TOTAL" "$PING_OK/$AVAILABLE_COUNT" "$HTTP_OK/$AVAILABLE_COUNT" "$TLS12_OK/$AVAILABLE_COUNT" "$TLS13_TEXT" >>"$REPORT"
    if [ "$SCORE" -gt "$BEST_SCORE" ] || { [ "$SCORE" -eq "$BEST_SCORE" ] && [ "$TLS_SCORE" -gt "$BEST_TLS" ]; }; then
        BEST_SCORE=$SCORE
        BEST_TLS=$TLS_SCORE
        BEST_NAMES=$STRATEGY_NAME
    elif [ "$SCORE" -eq "$BEST_SCORE" ] && [ "$TLS_SCORE" -eq "$BEST_TLS" ]; then
        BEST_NAMES="$BEST_NAMES, $STRATEGY_NAME"
    fi
done <"$SOURCE/strategies.tsv"

if [ "$CANCELLED" -eq 1 ] || cancel_requested; then
    printf '\nОстановлено\n' >>"$REPORT"
elif [ "$BEST_SCORE" -ge 0 ]; then
    printf '\nЛучшая: %s (%s/%s)\n' "$BEST_NAMES" "$BEST_SCORE" "$MAX_TOTAL" >>"$REPORT"
else
    printf '\nЛучшая: не определена\n' >>"$REPORT"
fi
printf 'Готово\n'
