#!/bin/sh
# 卸载 TwinGate 命令。默认保留配置目录与数据目录，避免误删证书/配置。
# 用法：sh scripts/uninstall.sh [--prefix DIR] [--config-dir DIR] [--data-dir DIR] [--purge]
set -eu

PREFIX_ARG=""
CONFIG_ARG=""
DATA_ARG=""
PURGE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)     PREFIX_ARG=${2:-}; shift 2 ;;
        --config-dir) CONFIG_ARG=${2:-}; shift 2 ;;
        --data-dir)   DATA_ARG=${2:-}; shift 2 ;;
        --purge)      PURGE=1; shift ;;
        -h|--help)
            printf '%s\n' '用法: sh scripts/uninstall.sh [--prefix DIR] [--config-dir DIR] [--data-dir DIR] [--purge]'
            exit 0 ;;
        *) printf '[uninstall] 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

if [ -n "$PREFIX_ARG" ]; then
    PREFIX=$PREFIX_ARG
elif [ -n "${TWIN_PREFIX:-}" ]; then
    PREFIX=$TWIN_PREFIX
else
    PREFIX=${HOME:-/nonexistent}/.local
fi
LIBDIR="$PREFIX/lib/twingate"
LAUNCHER="$PREFIX/bin/twingate"
CONFIG_DIR=${CONFIG_ARG:-${TWIN_CONFIG_DIR:-${HOME:-/tmp}/.local/config/twingate}}
DATA_DIR=${DATA_ARG:-${TWIN_DATA_DIR:-${HOME:-/tmp}/.local/share/twingate}}

if [ ! -e "$LAUNCHER" ] && [ ! -d "$LIBDIR" ]; then
    printf '[uninstall] 没有找到安装: %s\n' "$PREFIX"
    exit 0
fi

# 先停掉由该命令启动的进程。
if [ -x "$LAUNCHER" ]; then
    sh "$LAUNCHER" stop >/dev/null 2>&1 || :
fi

rm -f "$LAUNCHER"
for bin in 3proxy ttp tgmux; do
    rm -f "$LIBDIR/$bin"
done
rmdir "$LIBDIR" 2>/dev/null || :
printf '[uninstall] 已移除 %s 与 %s\n' "$LIBDIR" "$LAUNCHER"

if [ "$PURGE" = 1 ]; then
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    printf '[uninstall] 已删除配置目录 %s 与数据目录 %s\n' "$CONFIG_DIR" "$DATA_DIR"
else
    printf '[uninstall] 配置目录已保留: %s\n' "$CONFIG_DIR"
    printf '[uninstall] 数据目录已保留: %s\n' "$DATA_DIR"
fi
