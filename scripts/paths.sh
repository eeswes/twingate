#!/bin/sh
# TwinGate 共享路径解析。
#
# 安装模式（命令名为 twingate，位于 <prefix>/bin）：
#   TWIN_ROOT          <prefix>/lib/twingate —— 只放 3proxy / ttp / tgmux 三个二进制
#   TWIN_CONFIG_DIR    ~/.local/config/twingate —— tui.env / 3proxy.cfg
#   TWIN_DATA          ~/.local/share/twingate —— certs / logs / run
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

twin_init_paths() {
    _self=${1:-$0}
    _here=$(CDPATH= cd -- "$(dirname -- "$_self")" 2>/dev/null && pwd) || _here=.
    _name=$(basename -- "$_self")

    # 安装模式只认 <prefix>/bin/twingate；其余一律按源码树处理。
    if [ "$_name" = twingate ] && [ -d "$_here/../lib/twingate" ]; then
        TWIN_INSTALLED=1
        TWIN_PREFIX=$(CDPATH= cd -- "$_here/.." && pwd)
        TWIN_ROOT="$TWIN_PREFIX/lib/twingate"
        TWIN_CONFIG_DIR=${TWIN_CONFIG_DIR:-${HOME:-/tmp}/.local/config/twingate}
        TWIN_DATA=${TWIN_DATA:-${HOME:-/tmp}/.local/share/twingate}
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
