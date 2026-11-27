#!/bin/sh
# 卸载 TwinGate 命令。默认保留配置目录与数据目录，避免误删证书/配置。
# 用法：sh scripts/uninstall.sh [--prefix DIR] [--config-dir DIR] [--data-dir DIR] [--purge]
#
# 注意：这个脚本用于"从外面"卸载（源码树里执行、或启动器已经坏了）。
# 装好的 'twingate uninstall' 走的是 scripts/tg-runtime.sh 里的 twin_uninstall——
# 它直接知道 $TWIN_PREFIX / 配置目录 / 数据目录，不需要再靠 sed 反读启动器。
# 两边行为要保持一致：都先停进程，默认保留配置与数据，--purge 才删。
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
CONFIG_DIR=${CONFIG_ARG:-${TWIN_CONFIG_DIR:-}}
DATA_DIR=${DATA_ARG:-${TWIN_DATA_DIR:-}}

# 安装时可能用 --config-dir / --data-dir 改过位置，优先用启动器里记下的默认值，
# 否则 --purge 会去删 ~/.local 下根本没被用过的空目录。
if [ -f "$LAUNCHER" ]; then
    [ -n "$CONFIG_DIR" ] || CONFIG_DIR=$(sed -n "s/^TWIN_DEFAULT_CONFIG_DIR='\([^']*\)'\$/\1/p" "$LAUNCHER" | head -n 1)
    [ -n "$DATA_DIR" ] || DATA_DIR=$(sed -n "s/^TWIN_DEFAULT_DATA_DIR='\([^']*\)'\$/\1/p" "$LAUNCHER" | head -n 1)
fi
if [ -z "$CONFIG_DIR" ]; then
    _xdg=${XDG_CONFIG_HOME:-}
    case "$_xdg" in /*) ;; *) _xdg=${HOME:-/tmp}/.config ;; esac
    CONFIG_DIR=$_xdg/twingate
fi
if [ -z "$DATA_DIR" ]; then
    _xdg=${XDG_DATA_HOME:-}
    case "$_xdg" in /*) ;; *) _xdg=${HOME:-/tmp}/.local/share ;; esac
    DATA_DIR=$_xdg/twingate
fi
# 旧版把配置放在 ~/.local/config/twingate；启动器已经不在了也能一起清掉。
OLD_CONFIG_DIR=${HOME:-/tmp}/.local/config/twingate

if [ ! -e "$LAUNCHER" ] && [ ! -d "$LIBDIR" ]; then
    printf '[uninstall] 没有找到安装: %s\n' "$PREFIX"
    exit 0
fi

# 先停掉由该命令启动的进程。
if [ -x "$LAUNCHER" ]; then
    sh "$LAUNCHER" stop >/dev/null 2>&1 || :
fi

rm -f "$LAUNCHER"
for bin in 3proxy ttp tgmux tgtun; do
    rm -f "$LIBDIR/$bin"
done
rmdir "$LIBDIR" 2>/dev/null || :
printf '[uninstall] 已移除 %s 与 %s\n' "$LIBDIR" "$LAUNCHER"

if [ "$PURGE" = 1 ]; then
    for d in "$CONFIG_DIR" "$DATA_DIR"; do
        case "$d" in
            ""|/|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/")
                printf '[uninstall] 目录值异常（%s），拒绝删除。\n' "$d" >&2
                exit 1 ;;
        esac
    done
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    printf '[uninstall] 已删除配置目录 %s 与数据目录 %s\n' "$CONFIG_DIR" "$DATA_DIR"
    # 旧版的 XDG 错误位置（~/.local/config/twingate）一并清掉，否则残留一份旧配置。
    if [ "$OLD_CONFIG_DIR" != "$CONFIG_DIR" ] && [ -d "$OLD_CONFIG_DIR" ]; then
        rm -rf "$OLD_CONFIG_DIR"
        printf '[uninstall] 已删除旧版配置目录 %s\n' "$OLD_CONFIG_DIR"
    fi
else
    printf '[uninstall] 配置目录已保留: %s\n' "$CONFIG_DIR"
    printf '[uninstall] 数据目录已保留: %s\n' "$DATA_DIR"
fi
