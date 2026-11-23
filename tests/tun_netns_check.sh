#!/bin/sh
# TUN 接力的手工验证（Linux + root）。
#
# 为什么单独放一个脚本：验证「-De<dev> 真的让出站从该网卡发出」必须改造网络，
# 不适合塞进不需要特权的离线自测（tests/tg_local_test.py）。
#
# 用法：sudo sh tests/tun_netns_check.sh
#
# 拓扑（两个 netns，用 pid 把 veth 对端移过去）：
#   A: tun9(10.9.9.2/24) --veth-- B: b1(10.9.9.1/24)     “隧道”路径
#   A: eth0(10.8.8.2/24) --veth-- B: b0(10.8.8.1/24)     “物理”路径
#   A: default via eth0，另有 default via tun9 metric 1000（不绑网卡时选不到）
#
# 三项检查：
#   1) 不绑定        -> 走 eth0，对端看到 10.8.8.2
#   2) 绑 tun9       -> 出站包从 tun9 发出（对端回包在实验拓扑里会被 rp_filter 丢掉）
#   3) 绑 tun9 + 对端就在 tun9 网段 -> 端到端可用，对端看到 10.9.9.2
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROXY="$ROOT/dist/3proxy"
WORK="$ROOT/run/tun-check"

if [ ! -x "$PROXY" ]; then
    echo "[tun-check] 缺少 $PROXY，请先执行 scripts/build.sh" >&2
    exit 1
fi
if [ "$(id -u)" != 0 ]; then
    echo "[tun-check] 需要 root（要建 netns 与 veth）" >&2
    exit 1
fi
if ! command -v unshare >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    echo "[tun-check] 需要 iproute2（ip）与 unshare" >&2
    exit 1
fi

rm -rf "$WORK"; mkdir -p "$WORK"
FAIL=0

check() {
    name=$1; ok=$2; detail=$3
    if [ "$ok" = 1 ]; then
        printf 'PASS %s :: %s\n' "$name" "$detail"
    else
        printf 'FAIL %s :: %s\n' "$name" "$detail"
        FAIL=1
    fi
}

cat > "$WORK/server.py" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9099))
s.listen(8)
while True:
    c, a = s.accept()
    with open(sys.argv[1], "a") as f:
        f.write(a[0] + "\n")
    c.sendall(b"ok\n")
    c.close()
EOF

cat > "$WORK/client.py" <<'EOF'
import socket, struct, sys
port, target = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), 5)
s.sendall(b"\x05\x01\x00")
s.recv(2)
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(target) + struct.pack("!H", 9099))
rep = s.recv(10)
print("reply", rep[:2].hex(), s.recv(16))
EOF

unshare -n sleep 300 &
B_PID=$!
trap 'kill $B_PID 2>/dev/null || true' EXIT INT TERM
sleep 0.3

ip link add tun9 type veth peer name b1 || { echo "[tun-check] 建 veth 失败" >&2; exit 1; }
ip link add eth0 type veth peer name b0 || { echo "[tun-check] 建 veth 失败" >&2; exit 1; }
ip link set b1 netns "$B_PID"
ip link set b0 netns "$B_PID"
ip addr add 10.9.9.2/24 dev tun9
ip addr add 10.8.8.2/24 dev eth0
ip link set lo up; ip link set tun9 up; ip link set eth0 up
ip route add default via 10.8.8.1 dev eth0
ip route add default via 10.9.9.1 dev tun9 metric 1000

nsenter -t "$B_PID" -n sh -c "
ip addr add 10.9.9.1/24 dev b1
ip addr add 10.8.8.1/24 dev b0
ip link set lo up; ip link set b1 up; ip link set b0 up
python3 $WORK/server.py $WORK/peers.txt &
sleep 0.5
"
sleep 0.5

txpkts() { awk -v d="$1:" '$1==d {print $11}' /proc/net/dev; }

run_case() {
    name=$1; svcopt=$2; port=$3; target=$4
    : > "$WORK/peers.txt"
    cat > "$WORK/$name.cfg" <<EOF
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log $WORK/$name.log
auth none
allow * * * *
internal 127.0.0.1
socks -p$port $svcopt
EOF
    t0=$(txpkts tun9); e0=$(txpkts eth0)
    "$PROXY" "$WORK/$name.cfg" &
    pid=$!
    sleep 1.2
    python3 "$WORK/client.py" "$port" "$target" > "$WORK/$name.out" 2>&1 || true
    sleep 0.4
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    T_DELTA=$(( $(txpkts tun9) - t0 ))
    E_DELTA=$(( $(txpkts eth0) - e0 ))
    PEER=$(tr '\n' ' ' < "$WORK/peers.txt" | sed 's/ *$//')
    REPLY=$(head -1 "$WORK/$name.out")
}

run_case plain "" 11180 10.8.8.1
check "不绑定时走物理网卡" \
    "$([ "$PEER" = 10.8.8.2 ] && echo 1 || echo 0)" "peer=$PEER, ${REPLY}"

run_case bound "-Detun9" 11181 10.8.8.1
check "绑定后出站包从 tun9 发出" \
    "$([ "$T_DELTA" -gt 0 ] && [ "$T_DELTA" -gt "$E_DELTA" ] && echo 1 || echo 0)" \
    "tun9 tx +$T_DELTA, eth0 tx +$E_DELTA"

run_case bound-sym "-Detun9" 11182 10.9.9.1
check "绑定时端到端可用（对端在 tun9 网段）" \
    "$([ "$PEER" = 10.9.9.2 ] && echo 1 || echo 0)" "peer=$PEER, ${REPLY}"

[ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项" >&2
exit "$FAIL"
