#!/bin/sh
# 在 ReDroid 容器 / Termux 中执行，回传全部输出，用于判断构建可行性。
echo "=== TIME ==="; date
echo "=== UNAME ==="; uname -a
echo "=== ABI ==="
getprop ro.product.cpu.abi 2>/dev/null || true
getprop ro.product.cpu.abilist 2>/dev/null || true
echo "=== OS RELEASE ==="
cat /etc/os-release 2>/dev/null || true
cat /system/build.prop 2>/dev/null | grep -E 'ro.build.version|ro.product.cpu' || true
echo "=== LIBC ==="
ldd --version 2>&1 | head -3 || true
getconf LONG_BIT 2>/dev/null || true
echo "=== TOOLS ==="
for t in sh bash cc gcc clang make cmake git openssl base64 curl python3 python ss netstat toybox busybox; do
    p=$(command -v "$t" 2>/dev/null || true)
    [ -n "$p" ] && echo "$t -> $p"
done
echo "=== VERSIONS ==="
cc --version 2>&1 | head -2 || true
clang --version 2>&1 | head -2 || true
make --version 2>&1 | head -2 || true
openssl version 2>/dev/null || true
curl --version 2>/dev/null | head -2 || true
python3 --version 2>/dev/null || true
echo "=== HEADERS ==="
for h in /usr/include/openssl/ssl.h $PREFIX/include/openssl/ssl.h /data/data/com.termux/files/usr/include/openssl/ssl.h; do
    [ -f "$h" ] && echo "FOUND $h"
done
echo "=== PORTS IN USE ==="
cat /proc/net/tcp 2>/dev/null | head -20 || true
echo "=== SELINUX ==="
getenforce 2>/dev/null || true
echo "=== MOUNTS ==="
mount 2>/dev/null | grep -E ' / | /data | /sdcard ' | head -10 || true
