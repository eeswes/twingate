#!/bin/sh
# 共享的 TUI 配置加载器。
#
# 规则：显式环境变量 > config/tui.env > config/ports.env 默认值。
# 之前 start.sh 与 render-config.sh 的优先级不一致，可能出现
# "TWIN_AUTH=0 启动但配置文件里仍是 auth strong" 这类隐形错配。
#
# 用法：. scripts/load-tui-env.sh; load_tui_env <配置文件路径>
# 加载过的键名会写入 $TUI_LOADED_KEYS（空格分隔），供调用方判断来源。

TUI_LOADED_KEYS=""

load_tui_env() {
    TUI_LOADED_KEYS=""
    _cfg=${1:-}
    [ -f "$_cfg" ] || return 0

    _tmp="${TMPDIR:-/tmp}/tg-tui-env.$$"
    : > "$_tmp" || return 0

    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|\#*) continue ;;
            *=*)
                _k=${_line%%=*}
                case "$_k" in
                    [A-Za-z_]*[A-Za-z0-9_]*) ;;
                    *) continue ;;
                esac
                eval "_already=\${$_k+x}"
                [ -n "$_already" ] && continue
                # tui.env 的值由 tgmenu.sh 写入，统一用单引号，source 是安全的。
                printf '%s\n' "$_line" >> "$_tmp"
                TUI_LOADED_KEYS="$TUI_LOADED_KEYS $_k"
                ;;
        esac
    done < "$_cfg"

    [ -n "$TUI_LOADED_KEYS" ] && . "$_tmp"
    rm -f "$_tmp"
    return 0
}

tui_loaded() {
    case " $TUI_LOADED_KEYS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
