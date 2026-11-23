#!/bin/sh
# 构建 TwinGate（3proxy 0.9 LTS + ttp）。在 Termux / ReDroid 容器内直接执行即可。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
JOBS=${JOBS:-4}
CC=${CC:-cc}
PROXY_SRC=${TWIN_PROXY_SRC:-$ROOT/vendor/3proxy-lts}
# 0.9 LTS 在 Linux 上通常需要 -ldl；bionic 可置空。
TWIN_3PROXY_LIBS=${TWIN_3PROXY_LIBS:--ldl}
# ttp 上游 Makefile 默认 --static，bionic 下往往不可用，默认动态链接。
TTP_LDFLAGS=${TTP_LDFLAGS:-}

# bionic 的 <sys/random.h> 真实存在，但 getrandom() 声明受 API >= 28 保护。
# 若编译目标是 android24，3proxy 的 common.c 就会报 getrandom 未声明。
# 这里把编译目标切换到设备实际 API，从而使用真正的 bionic 头文件和 libc 实现。
TARGET_TRIPLE=$("$CC" -dumpmachine 2>/dev/null || true)
CC_CMD=$CC
case "$TARGET_TRIPLE" in
    *android*)
        and_api=${TWIN_ANDROID_API:-}
        if [ -z "$and_api" ]; then
            if command -v getprop >/dev/null 2>&1; then
                and_api=$(getprop ro.build.version.sdk 2>/dev/null || true)
            fi
            if [ -z "$and_api" ] && [ -x /system/bin/getprop ]; then
                and_api=$(/system/bin/getprop ro.build.version.sdk 2>/dev/null || true)
            fi
        fi
        case "$and_api" in
            ''|*[!0-9]*)
                echo "[build] 无法获取设备 Android API 级别。" >&2
                echo "[build] 请在容器执行：/system/bin/getprop ro.build.version.sdk" >&2
                echo "[build] 然后设置 TWIN_ANDROID_API=<数值> 后重建。" >&2
                exit 1
                ;;
        esac
        if [ "$and_api" -lt 28 ]; then
            echo "[build] 设备 API $and_api < 28：bionic 没有真正的 getrandom()/sys/random.h 声明。" >&2
            echo "[build] 方案 A：升级到 API >= 28 的设备/容器镜像（推荐）。" >&2
            echo "[build] 方案 B：退回 arc4random_buf 或 syscall 方案（需你确认）。" >&2
            exit 1
        fi
        base=${TARGET_TRIPLE%android*}
        new_target="${base}android${and_api}"
        CC_CMD="$CC --target=$new_target"
        echo "[build] bionic：切换 target $TARGET_TRIPLE -> $new_target，使用真实 <sys/random.h>"

        # 预检：确认切 target 后能同时编译并链接真正的 getrandom()。
        mkdir -p "$ROOT/build"
        check_src="$ROOT/build/getrandom-check.c"
        check_bin="$ROOT/build/getrandom-check"
        cat > "$check_src" <<'EOF'
#include <sys/random.h>
int main(void) {
    unsigned char b[1];
    return getrandom(b, 1, 0) == 1 ? 0 : 1;
}
EOF
        if ! $CC_CMD "$check_src" -o "$check_bin" 2>"$ROOT/build/getrandom-check.err"; then
            echo "[build] 预检失败：切到 $new_target 后无法编译/链接 getrandom()。" >&2
            sed -n '1,20p' "$ROOT/build/getrandom-check.err" >&2 || true
            echo "[build] 请确认 Termux 的 sys/random.h 来自与设备 API 匹配的 NDK sysroot。" >&2
            exit 1
        fi
        echo "[build] 预检通过：真实 <sys/random.h> + getrandom() 可用"
        ;;
esac

mkdir -p "$DIST"

clean_3proxy_objects() {
    cd "$PROXY_SRC"
    find src -maxdepth 1 -name '*.o' -type f -exec rm -f {} + 2>/dev/null || true
    find src/plugins -name '*.o' -type f -exec rm -f {} + 2>/dev/null || true
}

build_3proxy_try() {
    defs=$1
    clean_3proxy_objects
    cd "$PROXY_SRC"
    [ -f Makefile ] || ln -sf Makefile.Linux Makefile
    # PREFIX 必须显式覆盖：Termux 环境变量 PREFIX=/data/data/com.termux/files/usr
    # 会让 3proxy 的 Makefile 把输出路径拼成 ../bin//data/data/.../usrcrypt。
    # PLUGINS 置空：FilePlugin 依赖 bionic 没有的 sys/timeb.h，且 TwinGate 不用插件。
    make -j"$JOBS" -f Makefile.Linux MAKEFILE=Makefile.Linux \
        CC="$CC_CMD" \
        PREFIX=3proxy_ CRYPT_PREFIX=3proxy_ PLUGINS= \
        WOLFSSL_CHECK=false OPENSSL_CHECK=false FTP=true \
        CFLAGS="-O2 -fno-strict-aliasing -c -pthread $defs" \
        LDFLAGS="-pthread" \
        LIBS="$TWIN_3PROXY_LIBS"
}

FULL_DEFS="-D_GNU_SOURCE -DGETHOSTBYNAME_R -D_THREAD_SAFE -D_REENTRANT -DFD_SETSIZE=4096 -DWITH_POLL -DWITH_UN -DWITH_FTP -DWITHSPLICE -DWITH_NETFILTER -DWITH_TRANSPARENT"
# Android/bionic 通常缺少 netfilter 头、splice 声明，用精简定义重试。
SAFE_DEFS="-D_GNU_SOURCE -DGETHOSTBYNAME_R -D_THREAD_SAFE -D_REENTRANT -DFD_SETSIZE=4096 -DWITH_POLL -DWITH_UN -DWITH_FTP"

echo "[build] 3proxy: 首次尝试（完整 Linux 特性）"
if ! build_3proxy_try "$FULL_DEFS"; then
    echo "[build] 3proxy: 完整特性失败，改用 Android/bionic 精简特性重试"
    build_3proxy_try "$SAFE_DEFS"
fi
install -m 755 "$PROXY_SRC/bin/3proxy" "$DIST/3proxy"
for f in 3proxy_proxy 3proxy_socks 3proxy_ftppr; do
    [ -f "$PROXY_SRC/bin/$f" ] && install -m 755 "$PROXY_SRC/bin/$f" "$DIST/$f"
done

echo "[build] ttp (BearSSL)"
cd "$ROOT/vendor/ttp"
make clean >/dev/null 2>&1 || true
make -j"$JOBS" CC="$CC_CMD" LDFLAGS="$TTP_LDFLAGS"
install -m 755 ttp "$DIST/ttp"

echo "[build] tgmux (单端口协议分发器)"
$CC_CMD -O2 -Wall -D_GNU_SOURCE "$ROOT/src/tgmux.c" -o "$DIST/tgmux"
chmod 755 "$DIST/tgmux"

echo "[build] tgtun (TUN 虚拟网卡探测)"
$CC_CMD -O2 -Wall -D_GNU_SOURCE "$ROOT/src/tgtun.c" -o "$DIST/tgtun"
chmod 755 "$DIST/tgtun"

echo "[build] 完成："
ls -l "$DIST"
