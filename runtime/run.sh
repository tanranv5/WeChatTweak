#!/bin/bash
# 把 wxrevoketip.dylib 注入微信并启动（仅用于本机实验）
#
#   ./run.sh            # 观察模式：只打日志，不改提示文案
#   ./run.sh --apply    # 生效模式：给撤回提示加 [已拦截] 标记
#   ./run.sh --no-quit  # 不先退出已有微信
#
# 日志：/tmp/wxrevoketip.log
set -euo pipefail

cd "$(dirname "$0")"
DYLIB="$(pwd)/build/libwxrevoketip.dylib"
APP="/Applications/wx.app"
BIN="$APP/Contents/MacOS/WeChat"
LOG="/tmp/wxrevoketip.log"
# 微信带 app-sandbox，真正能写的日志在容器里
LOGS=("$LOG" "$HOME/Library/Containers/com.tencent.xinWeChat/Data/wxrevoketip.log")

[ -f "$DYLIB" ] || { echo "run ./build.sh first"; exit 1; }

APPLY=0
QUIT=1
for a in "$@"; do
    case "$a" in
        --apply)   APPLY=1 ;;
        --no-quit) QUIT=0 ;;
        *) echo "unknown arg: $a"; exit 1 ;;
    esac
done

if [ "$QUIT" = 1 ]; then
    if pgrep -f "^$BIN$" >/dev/null 2>&1; then
        echo "== quitting running WeChat =="
        osascript -e 'quit app id "com.tencent.xinWeChat"' 2>/dev/null || true
        for _ in $(seq 1 20); do
            pgrep -f "^$BIN$" >/dev/null 2>&1 || break
            sleep 0.5
        done
        pgrep -f "^$BIN$" >/dev/null 2>&1 && { echo "still running, sending TERM"; pkill -TERM -f "^$BIN$" || true; sleep 2; }
    fi
fi

: > "$LOG"
rm -f "$HOME/Library/Containers/com.tencent.xinWeChat/Data/wxrevoketip.log"
echo "== start: apply=${APPLY} =="
DYLD_INSERT_LIBRARIES="$DYLIB" WXRT_APPLY="$APPLY" \
    nohup "$BIN" >/tmp/wxrevoketip.stdout 2>&1 &
disown 2>/dev/null || true

sleep 8
echo "== processes =="
pgrep -fl "^$BIN$" || echo "(no WeChat process)"
echo
for f in "${LOGS[@]}"; do
    [ -s "$f" ] || continue
    echo "== injection log: $f =="
    cat "$f"
    echo
done
[ -s "${LOGS[0]}" ] || [ -s "${LOGS[1]}" ] || echo "(no log -> dyld did not load our dylib)"
