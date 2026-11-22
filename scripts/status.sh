#!/bin/sh
# 查看 TwinGate 进程与监听端口（兼容 toybox/busybox/netstat/ss）。
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/paths.sh"
twin_init_paths "$0"
RUNDIR=${TWIN_RUN_DIR:-$TWIN_DATA/run}
if [ -f "$ROOT/config/ports.env" ]; then
    . "$ROOT/config/ports.env"
fi
if [ -f "$RUNDIR/listen-ports" ]; then
    # start.sh 写入的本次实际监听端口（含命令行临时覆盖值）
    PORTS=$(cat "$RUNDIR/listen-ports")
else
    PORTS="$TWIN_HTTP_TLS $TWIN_HTTP_PLAIN $TWIN_SOCKS_TLS $TWIN_SOCKS_PLAIN \
$TWIN_FTP_TLS $TWIN_FTP_PLAIN $TWIN_MUX_PLAIN $TWIN_MIXED_TLS"
fi
PORT_RE=$(printf '%s\n' "$PORTS" | sed 's/^ *//; s/ *$//' | tr -s ' ' '|')

if [ -f "$RUNDIR/runtime-dir" ]; then
    echo "=== RUNTIME ==="
    cat "$RUNDIR/runtime-dir"
fi
if [ -f "$RUNDIR/services" ]; then
    echo "=== SERVICES ==="
    cat "$RUNDIR/services"
fi

echo "=== PID ==="
for pidfile in "$RUNDIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    name=$(basename "$pidfile" .pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "OK   $name $pid"
    else
        echo "DEAD $name $pid"
    fi
done

echo "=== LISTEN ==="
if [ -z "$PORT_RE" ]; then
    echo "（未开放任何端口）"
elif command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
else
    echo "无 ss/netstat，可用: cat /proc/net/tcp"
fi

echo "=== LOG TAIL ==="
for f in "$TWIN_LOG_DIR"/*.out; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f")"
    tail -n 10 "$f" 2>/dev/null || true
done
