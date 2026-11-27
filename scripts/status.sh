#!/bin/sh
# TwinGate 状态报告（唯一实现）。
#
# 两种用法，走的是同一份代码：
#   1. 独立运行：sh scripts/status.sh
#   2. 被 install.sh 内嵌进 twingate 启动器，由 tg-runtime.sh 的 twin_status 调用
#      twin_status_report —— 安装模式下没有 scripts/ 目录，所以必须内嵌而不是 forks。
#
# 被 source 时只定义函数：末尾的 case 用 $0 的文件名判断"是不是被直接执行"，
# 内嵌到启动器里之后 $0 是 twingate，自然跳过初始化。

twin_status_report() {
    _st_rundir=${TWIN_RUN_DIR:-${TWIN_DATA:-/tmp}/run}
    _st_logdir=${TWIN_LOG_DIR:-${TWIN_DATA:-/tmp}/logs}

    if [ -f "$_st_rundir/listen-ports" ]; then
        # start.sh 写入的本次实际监听端口（含命令行临时覆盖值）
        _st_ports=$(cat "$_st_rundir/listen-ports")
    else
        _st_ports="${TWIN_HTTP_TLS:-} ${TWIN_HTTP_PLAIN:-} ${TWIN_SOCKS_TLS:-} ${TWIN_SOCKS_PLAIN:-} \
${TWIN_FTP_TLS:-} ${TWIN_FTP_PLAIN:-} ${TWIN_MUX_PLAIN:-} ${TWIN_MIXED_TLS:-}"
    fi
    _st_port_re=$(printf '%s\n' "$_st_ports" | sed 's/^ *//; s/ *$//' | tr -s ' ' '|')

    [ -f "$_st_rundir/runtime-dir" ] && { echo "=== RUNTIME ==="; cat "$_st_rundir/runtime-dir"; }
    [ -f "$_st_rundir/services" ] && { echo "=== SERVICES ==="; cat "$_st_rundir/services"; }
    [ -f "$_st_rundir/parent" ] && { echo "=== PARENT ==="; cat "$_st_rundir/parent"; }
    [ -f "$_st_rundir/tun" ] && { echo "=== TUN ==="; cat "$_st_rundir/tun"; }
    twin_status_dns "$_st_rundir"

    echo "=== PID ==="
    for _st_pidfile in "$_st_rundir"/*.pid; do
        [ -f "$_st_pidfile" ] || continue
        _st_pid=$(cat "$_st_pidfile" 2>/dev/null || true)
        _st_name=$(basename "$_st_pidfile" .pid)
        if [ -n "$_st_pid" ] && kill -0 "$_st_pid" 2>/dev/null; then
            echo "OK   $_st_name $_st_pid"
        else
            echo "DEAD $_st_name $_st_pid"
        fi
    done

    echo "=== LISTEN ==="
    if [ -z "$_st_port_re" ]; then
        echo "（未开放任何端口）"
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep -E ":($_st_port_re)" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | grep -E ":($_st_port_re)" || true
    else
        echo "无 ss/netstat，可用: cat /proc/net/tcp"
    fi

    echo "=== LOG TAIL ==="
    for _st_f in "$_st_logdir"/*.out; do
        [ -f "$_st_f" ] || continue
        echo "--- $(basename "$_st_f")"
        tail -n 10 "$_st_f" 2>/dev/null || true
    done
}

# DNS 段：3proxy 的 nserver 是明文 UDP 53，不走 TUN，也不保证能过上游代理；
# 配一个本机到不了的 DNS 时每个新域名都要等满 DNS_TO。所以这里真发一个查询计时，
# 而不是读配置猜。
twin_status_dns() {
    _st_dns_dir=$1
    _st_cfg=""
    for _st_c in "${TWIN_3PROXY_CFG:-}" "$_st_dns_dir/3proxy.cfg"; do
        [ -n "$_st_c" ] && [ -f "$_st_c" ] && { _st_cfg=$_st_c; break; }
    done
    [ -n "$_st_cfg" ] || return 0
    _st_ns=$(sed -n 's/^nserver[[:space:]]*\([^[:space:]]*\).*/\1/p' "$_st_cfg" | head -1)
    _st_tmo=$(sed -n 's/^timeouts[[:space:]]*//p' "$_st_cfg" | head -1)
    [ -n "$_st_ns" ] || return 0
    # 第 7 位是 DNS_TO，第 9 位是 CONNECT_TO
    _st_dns_to=$(printf '%s\n' "$_st_tmo" | cut -d' ' -f7)
    _st_conn_to=$(printf '%s\n' "$_st_tmo" | cut -d' ' -f9)

    echo "=== DNS ==="
    echo "nserver      $_st_ns（DNS_TO=${_st_dns_to:-?}s CONNECT_TO=${_st_conn_to:-?}s）"

    # 去掉 :port，还原成主机名/地址；IPv6 的 [addr]:port 形式也照顾到。
    _st_nshost=$_st_ns
    case "$_st_ns" in
        \[*\]:*) _st_nshost=${_st_ns%]:*} ;;      # [::1]:53
        \[*\])   _st_nshost=${_st_ns#\[}; _st_nshost=${_st_nshost%\]} ;;
        *:*:*)   : ;;                        # 裸 IPv6，端口是默认的 53
        *:*)     _st_nshost=${_st_ns%:*} ;;
    esac

    # 真的发一个 DNS 查询，量往返时间。用 Python 而不是 getent/nslookup：
    # 后两者走系统解析器、查缓存，量不到 3proxy 那条路径。
    _st_py=""
    for _st_cand in python3 python; do
        command -v "$_st_cand" >/dev/null 2>&1 && { _st_py=$_st_cand; break; }
    done
    if [ -z "$_st_py" ]; then
        echo "（没有 python，跳过解析实测；可用 nslookup 手工验证）"
        return 0
    fi
    "$_st_py" - "$_st_nshost" "${_st_dns_to:-15}" <<'PY' 2>/dev/null || echo "解析实测失败（超时或不可达）"
import socket, struct, sys, time

host = sys.argv[1]
dns_to = sys.argv[2]
port = 53
if host.startswith("[") and "]:" in host:
    host, port = host[1:].split("]:")
port = int(port)
# 一个最小的 A 查询：example.com
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for label in b"example.com".split(b"."):
    q += bytes([len(label)]) + label
q += b"\x00" + struct.pack(">HH", 1, 1)

s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET,
                  socket.SOCK_DGRAM)
s.settimeout(6)
t0 = time.perf_counter()
try:
    s.sendto(q, (host, port))
    s.recvfrom(2048)
    ms = (time.perf_counter() - t0) * 1000
    print("实测解析     %.1f ms（example.com，明文 UDP）" % ms)
except socket.timeout:
    print("实测解析     超时 >6s —— 这个 DNS 从容器里到不了，")
    print("             每次新域名都会等满 DNS_TO=" + dns_to + "s 才继续。")
except OSError as e:
    print("实测解析     失败：%s" % e)
PY
    case "$_st_dns_to" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_st_dns_to" -ge 10 ]; then
                echo "提示：DNS_TO 是 ${_st_dns_to}s，一旦解析不到就要干等这么久；"
                echo "     把它收紧到 5（TWIN_DNS_TO=5），或换成本机可达的 DNS。"
            fi
            ;;
    esac
}

# 只有"被直接执行"才自己解析路径并出报告。内嵌到启动器后 $0 是 twingate，
# 这里不会触发；由 twin_status 先 twin_ports_init 再调 twin_status_report。
case "${0##*/}" in
    status.sh)
        set -u
        _st_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
        . "$_st_root/scripts/paths.sh"
        twin_init_paths "$0"
        # 源码树里没有 listen-ports（没启动过）时，用 ports.env 的默认端口显示。
        [ -f "$_st_root/config/ports.env" ] && . "$_st_root/config/ports.env"
        twin_status_report
        ;;
esac
