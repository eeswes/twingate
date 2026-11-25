#!/bin/sh
# TwinGate 共享路径解析。
#
# 安装模式（命令名为 twingate，位于 <prefix>/bin）：
#   TWIN_ROOT          <prefix>/lib/twingate —— 只放 3proxy / ttp / tgmux / tgtun 四个二进制
#   TWIN_CONFIG_DIR    ~/.local/config/twingate —— tui.env / 3proxy.cfg
#                      （install.sh --config-dir 可改，会写进启动器）
#   TWIN_DATA          ~/.local/share/twingate —— certs / logs / run
#                      （install.sh --data-dir 可改）
#
# 源码树模式（sh scripts/xxx.sh 或 sh tgmenu.sh）：
#   TWIN_ROOT          项目根目录
#   TWIN_CONFIG_DIR    $TWIN_ROOT/config
#   TWIN_DATA          $TWIN_ROOT（保持原来的 run/certs、logs、run 位置）
#
# 用法：. <dir>/scripts/paths.sh; twin_init_paths "$0"
# 结果变量：$TWIN_ROOT $TWIN_INSTALLED $TWIN_CONFIG_DIR $TWIN_DATA
#           $TWIN_RUN_DIR $TWIN_CERT_DIR $TWIN_LOG_DIR
#           $TWIN_TUI_ENV $TWIN_3PROXY_CFG
#
# 注意：$TWIN_ROOT 在两种模式下含义不同（安装模式=二进制目录，源码树=项目根目录），
# 所以取二进制一律用 twin_bin_dir，不要自己拼 $TWIN_ROOT/<程序名>。

twin_init_paths() {
    _self=${1:-$0}
    _here=$(CDPATH= cd -- "$(dirname -- "$_self")" 2>/dev/null && pwd) || _here=.
    _name=$(basename -- "$_self")

    # 安装模式只认 <prefix>/bin/twingate；其余一律按源码树处理。
    if [ "$_name" = twingate ] && [ -d "$_here/../lib/twingate" ]; then
        TWIN_INSTALLED=1
        TWIN_PREFIX=$(CDPATH= cd -- "$_here/.." && pwd)
        TWIN_ROOT="$TWIN_PREFIX/lib/twingate"
        # 安装时由 install.sh 写进启动器的 TWIN_DEFAULT_* 优先；
        # 没有（例如手工拷进 <prefix>/bin）才退回 ~/.local 默认值。
        TWIN_CONFIG_DIR=${TWIN_CONFIG_DIR:-${TWIN_DEFAULT_CONFIG_DIR:-${HOME:-/tmp}/.local/config/twingate}}
        TWIN_DATA=${TWIN_DATA:-${TWIN_DEFAULT_DATA_DIR:-${HOME:-/tmp}/.local/share/twingate}}
    else
        TWIN_INSTALLED=0
        if [ -n "${TWIN_ROOT:-}" ]; then
            :
        elif [ -f "$_here/config/ports.env" ]; then
            TWIN_ROOT=$_here
        elif [ -f "$_here/../config/ports.env" ]; then
            TWIN_ROOT=$(CDPATH= cd -- "$_here/.." && pwd)
        else
            TWIN_ROOT=$_here
        fi
        TWIN_CONFIG_DIR=${TWIN_CONFIG_DIR:-$TWIN_ROOT/config}
        TWIN_DATA=${TWIN_DATA:-$TWIN_ROOT}
    fi

    TWIN_RUN_DIR=${TWIN_RUN_DIR:-$TWIN_DATA/run}
    if [ "$TWIN_INSTALLED" = 1 ]; then
        TWIN_CERT_DIR=${TWIN_CERT_DIR:-$TWIN_DATA/certs}
    else
        TWIN_CERT_DIR=${TWIN_CERT_DIR:-$TWIN_DATA/run/certs}
    fi
    TWIN_LOG_DIR=${TWIN_LOG_DIR:-$TWIN_DATA/logs}
    TWIN_TUI_ENV=${TWIN_TUI_ENV:-$TWIN_CONFIG_DIR/tui.env}
    if [ "$TWIN_INSTALLED" = 1 ]; then
        TWIN_3PROXY_CFG=${TWIN_3PROXY_CFG:-$TWIN_CONFIG_DIR/3proxy.cfg}
    else
        TWIN_3PROXY_CFG=${TWIN_3PROXY_CFG:-$TWIN_RUN_DIR/3proxy.cfg}
    fi

    export TWIN_ROOT TWIN_INSTALLED TWIN_CONFIG_DIR TWIN_DATA TWIN_PREFIX 2>/dev/null || :
    export TWIN_RUN_DIR TWIN_CERT_DIR TWIN_LOG_DIR TWIN_TUI_ENV TWIN_3PROXY_CFG 2>/dev/null || :
}

# 3proxy / ttp / tgmux / tgtun 所在目录：安装模式下就在 $TWIN_ROOT 里，
# 源码树模式下是 scripts/build.sh 产出的 $TWIN_ROOT/dist。
# 需要先执行 twin_init_paths。
twin_bin_dir() {
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf '%s\n' "$TWIN_ROOT"
    else
        printf '%s\n' "$TWIN_ROOT/dist"
    fi
}

# 判断一个二进制能不能直接执行：0 = 可以，1 = 文件不存在，2 = 存在但没有执行位。
# "存在但不可执行"在 /sdcard 这类 noexec 文件系统上很常见，和"没构建"是两回事，
# 提示必须分开，否则用户会反复重建却毫无作用。
twin_bin_state() {
    [ -e "$1" ] || return 1
    [ -x "$1" ] || return 2
    return 0
}

# 把 twin_bin_state 的结果翻译成可操作的提示；失败时写 stderr 并返回同样的码。
twin_bin_diagnose() {
    _diag_path=$1
    _diag_name=${2:-$(basename -- "$1")}

    twin_bin_state "$_diag_path"
    case $? in
        0) return 0 ;;
        1)
            printf '缺少 %s（%s）。\n' "$_diag_name" "$_diag_path" >&2
            printf '  请先执行：sh scripts/build.sh\n' >&2
            return 1
            ;;
    esac

    printf '%s 存在，但没有可执行权限：%s\n' "$_diag_name" "$_diag_path" >&2
    printf '  这说明文件已经编译好了，只是当前文件系统不允许可执行位——\n' >&2
    printf '  /sdcard 这类外部存储（noexec）就是这样，重新构建也不会改变。\n' >&2
    printf '  处理办法：把项目放到支持可执行位的目录重新构建（如 Termux 的 $HOME、\n' >&2
    printf '  容器内的 /data），或者设 TWIN_RUNTIME_DIR 指向一个可执行的目录，\n' >&2
    printf '  scripts/start.sh 会把二进制复制过去再运行。\n' >&2
    return 2
}
