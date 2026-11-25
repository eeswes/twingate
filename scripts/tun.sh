#!/bin/sh
# TUN 虚拟网卡接力（3proxy 出站绑定）的解析与渲染。
#
# 场景：主机/容器里跑着 VPN，多出一张 tun0（Linux）或 utun0（macOS）网卡。
#       默认情况下 3proxy 的出站走系统默认路由；开启本功能后，让它改从这张
#       TUN 出网，连进来的所有客户端共享同一个出口。
#
# 两种情形（与 src/tgtun.c 的决策一致）：
#   1) TUN 已经承载默认路由 —— 系统本来就从它出网，什么都不用做（零配置）。
#   2) TUN 不承载默认路由 —— 把出站 socket 绑到这张网卡：
#      · 有权限（root / CAP_NET_RAW）：追加 -De<dev> 到 3proxy 服务行，
#        由 3proxy 对出站 socket 设置 SO_BINDTODEVICE；
#      · 没有权限：退化为 -e<ip>，由 3proxy bind 到该网卡的源地址。
#
# 输入（环境变量或 config/tui.env）：
#   TWIN_TUN       0/off（默认）| 1/on/auto；也可以直接写网卡名（等价于 TWIN_TUN=1 且指定该网卡）
#   TWIN_TUN_DEV   要绑的网卡，留空 = 自动挑 tun* / utun*（也可以写 wg0 这类名字）
#   TWIN_TUN_BIND  auto（默认：有权限绑网卡、没权限绑源地址）| device | source | direct
#
# 输出：
#   TUN_ON       0/1
#   TUN_MODE     direct|device|source|none
#   TUN_DEV      选中的网卡名
#   TUN_BIND_IP  mode=source 时的源地址
#   TUN_ARG      要追加到 3proxy 服务行的参数（-De<dev> / -e<ip> / 空）
#   TUN_REASON   决策原因代码（由调用方翻译成提示语）

# tgtun 的位置：安装模式在 $TWIN_ROOT，源码树在 $TWIN_ROOT/dist。
# 项目目录在 noexec 文件系统（/sdcard）时，start.sh 会把它复制到可执行目录，
# 并通过 TWIN_TUN_BIN_RUN 指过来；那份才真正能执行。
twin_tun_bin() {
    if [ -n "${TWIN_TUN_BIN_RUN:-}" ] && [ -x "$TWIN_TUN_BIN_RUN" ]; then
        printf '%s\n' "$TWIN_TUN_BIN_RUN"
        return 0
    fi
    printf '%s/tgtun\n' "$(twin_bin_dir)"
}

# 解析配置。返回非 0 表示配置非法（调用方应终止启动）。
twin_tun_resolve() {
    TUN_ON=0
    TUN_MODE=none
    TUN_DEV=""
    TUN_BIND_IP=""
    TUN_ARG=""
    TUN_REASON="off"

    _tun_raw=${TWIN_TUN:-off}
    _tun_flag=$(printf '%s' "$_tun_raw" | tr 'A-Z' 'a-z')
    case "$_tun_flag" in
        0|off|no|false|'')
            return 0
            ;;
        1|on|yes|true|auto)
            # 单独记住的网卡名；留空则自动挑。
            _tun_iface=${TWIN_TUN_DEV:-}
            case "$(printf '%s' "$_tun_iface" | tr 'A-Z' 'a-z')" in
                auto|any|'') _tun_iface="" ;;
            esac
            ;;
        *)
            # 显式指定网卡：只允许网卡名字符集，避免拼进 3proxy 参数时出问题。
            case "$_tun_raw" in
                *[!A-Za-z0-9_.-]*)
                    printf '[tun] TWIN_TUN 只能是 off / auto / 网卡名，当前值非法：%s\n' \
                        "$_tun_raw" >&2
                    return 1
                    ;;
            esac
            _tun_iface=$_tun_raw
            ;;
    esac

    # 显式网卡名同样做一次字符集校验（可能来自 TWIN_TUN_DEV）。
    case "$_tun_iface" in
        *[!A-Za-z0-9_.-]*)
            printf '[tun] 网卡名非法：%s（只允许字母数字和 . _ -）\n' "$_tun_iface" >&2
            return 1
            ;;
    esac

    _tun_bind=${TWIN_TUN_BIND:-auto}
    case "$_tun_bind" in
        auto) _tun_bind=auto ;;
        device|source|direct) ;;
        *)
            printf '[tun] TWIN_TUN_BIND 只能是 auto / device / source / direct，当前值：%s\n' \
                "$_tun_bind" >&2
            return 1
            ;;
    esac

    _tun_bin=$(twin_tun_bin)
    # 区分"没构建"和"有文件但没执行位"：后者在 /sdcard 上很常见，
    # 反复重建不会有任何变化，只会让人以为构建失败。
    twin_bin_diagnose "$_tun_bin" tgtun || return 1

    # 只取 key=value，逐行解析；不 eval，避免网卡名/地址被当成代码执行。
    if [ -n "$_tun_iface" ]; then
        _tun_out=$("$_tun_bin" plan --iface "$_tun_iface" --bind "$_tun_bind" 2>/dev/null)
    else
        _tun_out=$("$_tun_bin" plan --bind "$_tun_bind" 2>/dev/null)
    fi
    _tun_rc=$?
    if [ "$_tun_rc" -gt 2 ]; then
        printf '[tun] tgtun 执行失败（退出码 %s）：%s\n' "$_tun_rc" "$_tun_out" >&2
        return 1
    fi

    _tun_status=none
    _tun_iface_out=""
    _tun_ip4=""
    _tun_ip6=""
    while IFS= read -r _line; do
        case "$_line" in
            *=*)
                _k=${_line%%=*}
                _v=${_line#*=}
                case "$_k" in
                    status)          _tun_status=$_v ;;
                    iface)           _tun_iface_out=$_v ;;
                    ip4)             _tun_ip4=$_v ;;
                    ip6)             _tun_ip6=$_v ;;
                    mode)            TUN_MODE=$_v ;;
                    arg)             TUN_ARG=$_v ;;
                    reason)          TUN_REASON=$_v ;;
                esac
                ;;
        esac
    done <<EOF
$_tun_out
EOF

    case "$_tun_status" in
        ok)
            TUN_ON=1
            TUN_DEV=$_tun_iface_out
            if [ "$TUN_MODE" = source ]; then
                TUN_BIND_IP=${_tun_ip4:-$_tun_ip6}
            fi
            ;;
        none)
            TUN_MODE=none
            TUN_ARG=""
            TUN_DEV=""
            printf '[tun] 没有找到可用的 TUN 网卡（tun* / utun*），本次不启用 TUN 接力。\n' >&2
            return 0
            ;;
        *)
            printf '[tun] 探测失败（%s），请检查 TWIN_TUN=%s 是否写对。\n' \
                "$TUN_REASON" "${_tun_iface:-auto}" >&2
            return 1
            ;;
    esac
    return 0
}

# 把 -De<dev> / -e<ip> 追加到 3proxy 的每个服务行（proxy / socks / ftppr）。
# 位置：服务行上的选项由 3proxy 按服务解析，-De 只影响该服务的出站 socket。
# 幂等：已经带过就不重复追加。
twin_tun_apply_cfg() {
    _cfg=$1
    [ -f "$_cfg" ] || return 1
    [ "${TUN_ON:-0}" = 1 ] || return 0
    [ -n "${TUN_ARG:-}" ] || return 0

    if grep -q -- "$TUN_ARG" "$_cfg"; then
        return 0
    fi

    _esc=$(printf '%s' "$TUN_ARG" | sed -e 's/[\/&|]/\\&/g')
    # 逐个服务行追加。不用 sed 的 \| 交替：BusyBox sed（Termux/Android）不支持。
    for _svc in proxy socks ftppr; do
        sed -i "s|^$_svc \(.*\)\$|$_svc \1 $_esc|" "$_cfg" || return 1
    done

    # 追加一行说明，方便直接看 3proxy.cfg 的人理解这个参数从哪来。
    sed -i "1a # TUN 接力：TUN_MODE=${TUN_MODE} TUN_DEV=${TUN_DEV}（由 scripts/tun.sh 注入 $_esc）" \
        "$_cfg" || return 1
    return 0
}

# 把本次的 TUN 状态写到运行目录，供 status 显示。
twin_tun_write_state() {
    _dir=${1:-}
    [ -n "$_dir" ] && [ -d "$_dir" ] || return 0
    if [ "${TUN_ON:-0}" = 1 ]; then
        if [ -n "${TUN_BIND_IP:-}" ]; then
            printf '%s %s %s\n' "$TUN_MODE" "$TUN_DEV" "$TUN_BIND_IP" > "$_dir/tun"
        else
            printf '%s %s\n' "$TUN_MODE" "$TUN_DEV" > "$_dir/tun"
        fi
    else
        printf '%s\n' 'off' > "$_dir/tun"
    fi
    return 0
}

# 人类可读的一行摘要（给 status / TUI 用）。
twin_tun_desc() {
    if [ "${TUN_ON:-0}" != 1 ]; then
        printf 'off'
        return
    fi
    case "$TUN_MODE" in
        direct) printf 'direct %s（已承载默认路由，零配置）' "${TUN_DEV:-?}" ;;
        device) printf 'device %s（SO_BINDTODEVICE）' "${TUN_DEV:-?}" ;;
        source) printf 'source %s（bind %s）' "${TUN_DEV:-?}" "${TUN_BIND_IP:-?}" ;;
        *)      printf '%s' "$TUN_MODE" ;;
    esac
}
