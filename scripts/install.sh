#!/bin/sh
# 安装 TwinGate 为单个命令。
#
# 安装布局（默认 --user）：
#   ~/.local/bin/twingate              唯一的命令脚本（tgmenu.sh + 内嵌运行逻辑）
#   ~/.local/lib/twingate/3proxy       仅这几个二进制
#   ~/.local/lib/twingate/ttp
#   ~/.local/lib/twingate/tgmux
#   ~/.local/lib/twingate/tgtun
#   ~/.config/twingate/                tui.env / 3proxy.cfg 等配置（XDG 配置目录）
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

# 相对路径的 --prefix/--config-dir/--data-dir 会原样写进启动器与提示，运行时按
# "当时的 cwd" 解析——和安装时看到的目录根本不是同一个（证书、日志会跑到别处）。
# 这里统一转成绝对路径。用词法解析而不是 `cd && pwd`：目录此刻可能还不存在
# （下面才 mkdir），靠 cd 失败退回原值等于这个 bug 白修。
abs_dir() {
    case "$1" in
        /*) _p=$1 ;;
        *)  _p=$PWD/$1 ;;
    esac
    _o=
    _oldifs=$IFS; IFS=/
    for _s in $_p; do
        case "$_s" in
            ''|.) ;;
            ..)   _o=${_o%/*} ;;
            *)    _o=$_o/$_s ;;
        esac
    done
    IFS=$_oldifs
    printf '%s' "${_o:-/}"
}
PREFIX=$(abs_dir "$PREFIX")

LIBDIR="$PREFIX/lib/twingate"
BINDIR="$PREFIX/bin"
LAUNCHER="$BINDIR/twingate"
CONFIG_DIR=${CONFIG_ARG:-${TWIN_CONFIG_DIR:-}}
DATA_DIR=${DATA_ARG:-${TWIN_DATA_DIR:-}}
# XDG 默认位置：配置 ~/.config/twingate、数据 ~/.local/share/twingate。
# 旧版把配置放在 ~/.local/config/twingate（那不是 XDG 目录），下面会做一次迁移。
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
CONFIG_DIR=$(abs_dir "$CONFIG_DIR")
DATA_DIR=$(abs_dir "$DATA_DIR")

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

# --config-dir / --data-dir 已在上方转成绝对路径（见 abs_dir）。
if [ -e "$LAUNCHER" ] && [ "$FORCE" != 1 ]; then
    printf '[install] 已存在 %s；如要覆盖请加 --force。\n' "$LAUNCHER" >&2
    exit 1
fi

# ---------------- 配置文件迁移 ----------------
# 旧版把配置写在 ~/.local/config/twingate（不是 XDG 目录）。重新安装时把那份
# tui.env 带过来，否则用户装完会发现"设置全没了"。旧文件保留，由用户自己删。
_old_cfg=${HOME:-/tmp}/.local/config/twingate
if [ "$_old_cfg" != "$CONFIG_DIR" ] && [ -f "$_old_cfg/tui.env" ] \
        && [ ! -f "$CONFIG_DIR/tui.env" ]; then
    if cp "$_old_cfg/tui.env" "$CONFIG_DIR/tui.env" 2>/dev/null; then
        chmod 600 "$CONFIG_DIR/tui.env" 2>/dev/null || :
        printf '[install] 已迁移旧配置：%s -> %s\n' "$_old_cfg/tui.env" "$CONFIG_DIR/tui.env"
        printf '[install] 旧文件保留在 %s，确认无误后可自行删除。\n' "$_old_cfg"
    fi
fi

# 源码树里的 config/tui.env 是"当前这份配置"，安装后新位置没有就带过去：
# 它不在仓库以外任何地方，不复制等于让用户重新配一遍。tui.env 含密码，权限 600。
if [ -f "$ROOT/config/tui.env" ] && [ ! -f "$CONFIG_DIR/tui.env" ]; then
    if cp "$ROOT/config/tui.env" "$CONFIG_DIR/tui.env" 2>/dev/null; then
        chmod 600 "$CONFIG_DIR/tui.env" 2>/dev/null || :
        printf '[install] 已复制现有配置：%s\n' "$CONFIG_DIR/tui.env"
    fi
fi

for bin in 3proxy ttp; do
    [ -f "$ROOT/dist/$bin" ] || {
        printf '[install] 缺少 dist/%s，请先执行 scripts/build.sh。\n' "$bin" >&2
        exit 1
    }
done

# ---------------- 只安装二进制 ----------------
# 先写临时文件再原子替换：旧进程还在跑时直接 cp 覆盖会报 Text file busy。
for bin in 3proxy ttp tgmux tgtun; do
    if [ -f "$ROOT/dist/$bin" ]; then
        _tmpbin="$LIBDIR/.$bin.new.$$"
        cp "$ROOT/dist/$bin" "$_tmpbin"
        if ! chmod 755 "$_tmpbin" 2>/dev/null; then
            rm -f "$_tmpbin"
            printf '[install] 无法给 %s 设置可执行位。\n' "$LIBDIR/$bin" >&2
            printf '[install] %s 可能在不支持可执行位的文件系统上（如 /sdcard）。\n' "$LIBDIR" >&2
            printf '[install] 安装目录必须可执行，请换一个 --prefix，例如默认的 ~/.local。\n' >&2
            exit 1
        fi
        mv -f "$_tmpbin" "$LIBDIR/$bin"
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

# 把安装时确定的目录写进启动器：否则运行时只会退回 ~/.local 默认值，
# 让 --config-dir / --data-dir 变成只影响安装提示的摆设。
sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# TwinGate 单命令入口，由 scripts/install.sh 生成。'
    printf '%s\n' '# 程序目录只放二进制；配置与数据分别放在用户可写目录。'
    printf 'TWIN_DEFAULT_CONFIG_DIR=%s\n' "$(sq "$CONFIG_DIR")"
    printf 'TWIN_DEFAULT_DATA_DIR=%s\n' "$(sq "$DATA_DIR")"
    printf '\n'
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
    strip_shebang "$ROOT/scripts/parent.sh"
    printf '\n'
    strip_shebang "$ROOT/scripts/lifecycle.sh"
    printf '\n'
    strip_shebang "$ROOT/scripts/tun.sh"
    printf '\n'
    # 证书生成/补齐（twin_gen_certs / twin_cert_ensure）同样只有一份实现。
    strip_shebang "$ROOT/scripts/cert.sh"
    printf '\n'
    # status.sh 必须在 tg-runtime.sh 之前：安装模式没有 scripts/ 目录，
    # twin_status 调用的 twin_status_report 只能来自这里内嵌的一份。
    strip_shebang "$ROOT/scripts/status.sh"
    printf '\n'
    strip_shebang "$ROOT/scripts/tg-runtime.sh"
    printf '\n'
    strip_shebang "$ROOT/tgmenu.sh"
} > "$_tmp"

if ! chmod 755 "$_tmp" 2>/dev/null; then
    printf '[install] 无法给 %s 设置可执行位。\n' "$LAUNCHER" >&2
    printf '[install] %s 可能在不支持可执行位的文件系统上（如 /sdcard）。\n' "$BINDIR" >&2
    printf '[install] 请换一个 --prefix，例如默认的 ~/.local。\n' >&2
    rm -f "$_tmp"
    exit 1
fi
mv -f "$_tmp" "$LAUNCHER"

printf '[install] 完成。运行: %s start\n' "$LAUNCHER"
case ":${PATH:-}:" in
    *":$BINDIR:"*) ;;
    *) printf '[install] 提示: %s 不在 PATH 中，请把 export PATH="%s:$PATH" 加到 shell 配置。\n' \
            "$BINDIR" "$BINDIR" ;;
esac
