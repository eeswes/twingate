#!/bin/sh
# 停止 TwinGate 全部进程。
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNDIR=${TWIN_RUN_DIR:-$ROOT/run}
PIDS=""
for pidfile in "$RUNDIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && echo "[stop] killed $(basename "$pidfile") ($pid)"
    fi
    PIDS="$PIDS $pid"
    rm -f "$pidfile"
done

# 等待进程真正退出：否则立刻 start 时可能遇到端口仍被占用或二进制 TEXT BUSY。
i=0
while [ "$i" -lt 5 ]; do
    alive=0
    for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    [ "$alive" = 0 ] && break
    sleep 1
    i=$((i + 1))
done
