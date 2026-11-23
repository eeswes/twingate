#!/bin/sh
# 共享的 TUI 配置加载器。
#
# 优先级：显式环境变量 > config/tui.env > config/ports.env 默认值。
#
# 调用顺序很重要，必须是这样：
#   . scripts/load-tui-env.sh
#   tui_snapshot_explicit          # 1) 先记下用户真正在环境变量里给出的键
#   load_tui_env "$TWIN_TUI_ENV"   # 2) 再加载 tui.env（会跳过上一步记下的键）
#   . config/ports.env             # 3) 最后补默认值（${VAR:-default} 不会覆盖已有值）
#
# 反过来的顺序（先 ports.env 再 tui.env）会把每个键都当成"已显式设置"而整份跳过，
# 控制台保存的端口、认证、上游就全部失效——这是之前的真实 bug。
#
# tui.env 由 tgmenu.sh 写成 `KEY='值'` 的单引号形式，加载时用 eval 执行；
# 手工编辑时请保持单引号，不要写命令替换。

TUI_LOADED_KEYS=""
TUI_EXPLICIT_KEYS=""

# 记录当前已存在的配置键，即用户通过环境变量显式给出的键。
# 必须在 source config/ports.env 之前调用。
tui_snapshot_explicit() {
    TUI_EXPLICIT_KEYS=""
    for _k in $(set | sed -n 's/^\(TWIN_[A-Za-z0-9_]*\)=.*/\1/p'); do
        TUI_EXPLICIT_KEYS="$TUI_EXPLICIT_KEYS $_k"
    done
}

# 某个键是否由环境变量显式给出。
tui_explicit() {
    case " ${TUI_EXPLICIT_KEYS:-} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

load_tui_env() {
    TUI_LOADED_KEYS=""
    _cfg=${1:-}
    [ -f "$_cfg" ] || return 0

    _src=""
    _nl='
'
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _k=${_line%%=*}
        case "$_k" in
            [A-Za-z_]*[A-Za-z0-9_]*) ;;
            *) continue ;;
        esac
        tui_explicit "$_k" && continue
        _src="$_src$_line$_nl"
        TUI_LOADED_KEYS="$TUI_LOADED_KEYS $_k"
    done < "$_cfg"

    [ -n "$_src" ] && eval "$_src"
    return 0
}

tui_loaded() {
    case " $TUI_LOADED_KEYS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
