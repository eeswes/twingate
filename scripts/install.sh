#!/bin/sh
# 安装 TwinGate 为单个命令。
#
# 安装布局（默认 --user）：
#   ~/.local/bin/twingate              唯一的命令脚本（tgmenu.sh + 内嵌运行逻辑）
#   ~/.local/lib/twingate/3proxy       仅这三个二进制
#   ~/.local/lib/twingate/ttp
#   ~/.local/lib/twingate/tgmux
#   ~/.local/config/twingate/          tui.env / 3proxy.cfg 等配置
#   ~/.local/share/twingate/           certs / logs / run 等运行时数据
#
# 用法：sh scripts/install.sh [选项]
#   --user              装到 $HOME/.local（默认，无需 root）
#   --system            装到 /usr/local（需要写权限）
#   --termux            装到 $PREFIX（Termux）
#   --prefix DIR        自定义安装前缀
#   --config-dir DIR    自定义配置目录
#   --data-dir DIR      自定义数据目录（证书/日志/PID）
#   --force             已安装时也覆盖
#
# 环境变量等价于选项：TWIN_PREFIX / TWIN_CONFIG_DIR / TWIN_DATA_DIR / TWIN_FORCE=1
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# ---------------- 解析参数 ----------------
MODE=""
PREFIX_ARG=""
CONFIG_ARG=""
DATA_ARG=""
FORCE=${TWIN_FORCE:-0}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)        MODE=user; shift ;;
        --system)      MODE=system; shift ;;
        --termux)      MODE=termux; shift ;;
        --prefix)      PREFIX_ARG=${2:-}; shift 2 ;;
        --config-dir)  CONFIG_ARG=${2:-}; shift 2 ;;
        --data-dir)    DATA_ARG=${2:-}; shift 2 ;;
        --force)       FORCE=1; shift ;;
        -h|--help)
            printf '%s\n' '用法: sh scripts/install.sh [--user|--system|--termux] [--prefix DIR] [--config-dir DIR] [--data-dir DIR] [--force]'
            exit 0 ;;
        *) printf '[install] 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# ---------------- 选择目录 ----------------
if [ -n "$PREFIX_ARG" ]; then
    PREFIX=$PREFIX_ARG
elif [ -n "${TWIN_PREFIX:-}" ]; then
    PREFIX=$TWIN_PREFIX
else
    case "$MODE" in
        system) PREFIX=/usr/local ;;
        termux) PREFIX=${PREFIX:-/data/data/com.termux/files/usr} ;;
        user|"") PREFIX=${HOME:-/nonexistent}/.local ;;
    esac
fi
[ -n "$PREFIX" ] || { printf '[install] 未确定安装前缀\n' >&2; exit 1; }

LIBDIR="$PREFIX/lib/twingate"
BINDIR="$PREFIX/bin"
LAUNCHER="$BINDIR/twingate"
CONFIG_DIR=${CONFIG_ARG:-${TWIN_CONFIG_DIR:-${HOME:-/tmp}/.local/config/twingate}}
DATA_DIR=${DATA_ARG:-${TWIN_DATA_DIR:-${HOME:-/tmp}/.local/share/twingate}}

printf '[install] 命令    : %s\n' "$LAUNCHER"
printf '[install] 程序目录: %s （仅二进制）\n' "$LIBDIR"
printf '[install] 配置目录: %s\n' "$CONFIG_DIR"
printf '[install] 数据目录: %s\n' "$DATA_DIR"

# ---------------- 权限预检 ----------------
for d in "$PREFIX" "$PREFIX/lib" "$BINDIR" "$LIBDIR" "$CONFIG_DIR" "$DATA_DIR"; do
    mkdir -p "$d" 2>/dev/null || {
        printf '[install] 无法创建 %s；系统级安装请用 sudo，或改用 --user。\n' "$d" >&2
        exit 1
    }
done
for d in "$BINDIR" "$LIBDIR"; do
    [ -w "$d" ] || {
        printf '[install] 目录不可写: %s；请用 sudo 或 --user 安装到用户目录。\n' "$d" >&2
        exit 1
    }
done
if [ -e "$LAUNCHER" ] && [ "$FORCE" != 1 ]; then
    printf '[install] 已存在 %s；如要覆盖请加 --force。\n' "$LAUNCHER" >&2
    exit 1
fi
for bin in 3proxy ttp; do
    [ -f "$ROOT/dist/$bin" ] || {
        printf '[install] 缺少 dist/%s，请先执行 scripts/build.sh。\n' "$bin" >&2
        exit 1
    }
done

# ---------------- 只安装三个二进制 ----------------
for bin in 3proxy ttp tgmux; do
    if [ -f "$ROOT/dist/$bin" ]; then
        cp "$ROOT/dist/$bin" "$LIBDIR/$bin"
        chmod 755 "$LIBDIR/$bin"
    fi
done

# ---------------- 生成自包含命令 ----------------
# 安装后的 twingate 是单个脚本：路径层 + 内嵌默认配置/模板 + runtime + TUI。
# 因此不需要把 scripts/、config/、tests/ 复制到 lib 目录。
_suffix=$$
_eof_ports="TWIN_PORTS_EOF_$_suffix"
_eof_tpl="TWIN_TPL_EOF_$_suffix"
_tmp="$BINDIR/.twingate.$$"

strip_shebang() {
    sed '1{/^#!/d;}' "$1"
}

{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# TwinGate 单命令入口，由 scripts/install.sh 生成。'
    printf '%s\n' '# 程序目录只放二进制；配置与数据分别放在用户可写目录。'
    strip_shebang "$ROOT/scripts/paths.sh"
    printf '\n'
    printf '%s\n' "twin_embedded_ports() { cat <<'$_eof_ports'"
    cat "$ROOT/config/ports.env"
    printf '%s\n' "$_eof_ports"
    printf '%s\n' '}'
    printf '\n'
    printf '%s\n' "twin_embedded_tpl() { cat <<'$_eof_tpl'"
    cat "$ROOT/config/3proxy.cfg.tpl"
    printf '%s\n' "$_eof_tpl"
    printf '%s\n' '}'
    printf '\n'
    strip_shebang "$ROOT/scripts/tg-runtime.sh"
    printf '\n'
    strip_shebang "$ROOT/tgmenu.sh"
} > "$_tmp"

chmod 755 "$_tmp"
mv -f "$_tmp" "$LAUNCHER"

printf '[install] 完成。运行: %s start\n' "$LAUNCHER"
case ":${PATH:-}:" in
    *":$BINDIR:"*) ;;
    *) printf '[install] 提示: %s 不在 PATH 中，请把 export PATH="%s:$PATH" 加到 shell 配置。\n' \
            "$BINDIR" "$BINDIR" ;;
esac
