#!/bin/sh
# 上游 SOCKS5（3proxy parent 链式出口）的解析与渲染。
#
# 作用：让连到 TwinGate 的所有客户端（HTTP / CONNECT / SOCKS4/5）都从同一个上游
#       SOCKS5 出网。3proxy 的 parent 是挂在「前一条 allow 规则」上的，weight 是
#       1000 分制的命中概率：只有写满 1000 才能保证每条连接都选这条链；小于 1000
#       时可能一次都没选中，3proxy 会当成没有链、直接直连。所以这里固定 1000。
#
# 输入（环境变量或 config/tui.env）：
#   TWIN_PARENT        0/off（默认）| 1 | socks5://user:pass@127.0.0.1:1080 | 127.0.0.1:1080
#   TWIN_PARENT_HOST   上游地址，默认 127.0.0.1
#   TWIN_PARENT_PORT   上游端口，默认 1080
#   TWIN_PARENT_TYPE   socks5+（默认：域名交给上游解析）| socks5 | socks4 | socks4+
#                      | connect | connect+
#   TWIN_PARENT_USER   上游用户名（可选）
#   TWIN_PARENT_PASS   上游密码（可选）
#   TWIN_PARENT_FTP    off（默认：拒绝 FTP 代理，避免绕过上游）| direct（FTP 直连）
#
# 输出：PARENT_ON PARENT_TYPE PARENT_HOST PARENT_PORT PARENT_USER PARENT_PASS
#       PARENT_LINE（写进 3proxy.cfg 的 parent 行）、PARENT_DESC（给 status 看）
#
# 显式字段优先：设置了 TWIN_PARENT_HOST/PORT/USER/PASS/TYPE 时，会覆盖 URL 里的对应部分。

# 归一化配置。返回非 0 表示配置非法（调用方应终止启动）。
twin_parent_resolve() {
    PARENT_ON=0
    PARENT_TYPE=${TWIN_PARENT_TYPE:-socks5+}
    PARENT_HOST=${TWIN_PARENT_HOST:-127.0.0.1}
    PARENT_PORT=${TWIN_PARENT_PORT:-1080}
    PARENT_USER=${TWIN_PARENT_USER:-}
    PARENT_PASS=${TWIN_PARENT_PASS:-}
    PARENT_LINE=""
    PARENT_DESC="off"

    _raw=${TWIN_PARENT:-0}
    # 开关判断不区分大小写（OFF / On 之类），地址仍用原始大小写。
    _flag=$(printf '%s' "$_raw" | tr 'A-Z' 'a-z')
    _default_type=""
    case "$_flag" in
        0|off|no|false|'')
            ;;
        1|on|yes|true)
            PARENT_ON=1
            ;;
        *://*)
            _scheme=${_raw%%://*}
            _rest=${_raw#*://}
            _rest=${_rest%%/*}
            case "$(printf '%s' "$_scheme" | tr 'A-Z' 'a-z')" in
                # 上游解析域名（socks5+），避免本地 DNS 泄漏
                socks5h|socks5) _default_type=socks5+ ;;
                socks4)         _default_type=socks4 ;;
                http)           _default_type=connect ;;
                *)
                    printf '[parent] 不支持的上游协议：%s（可用 socks5:// 或 socks5h:// = 上游解析域名）\n' \
                        "$_scheme" >&2
                    return 1
                    ;;
            esac
            PARENT_ON=1
            _cred=""
            case "$_rest" in
                *@*) _cred=${_rest%@*}; _rest=${_rest##*@} ;;
            esac
            _host=$_rest
            _port=1080
            case "$_rest" in
                \[*\]:*)
                    _host=${_rest%]:*}; _host=${_host#[}
                    _port=${_rest##*]:}
                    ;;
                \[*\])
                    _host=${_rest#[}; _host=${_host%]}
                    ;;
                *:*)
                    _host=${_rest%:*}
                    _port=${_rest##*:}
                    ;;
            esac
            [ -n "${TWIN_PARENT_TYPE:-}" ] || PARENT_TYPE=$_default_type
            [ -n "${TWIN_PARENT_HOST:-}" ] || PARENT_HOST=$_host
            [ -n "${TWIN_PARENT_PORT:-}" ] || PARENT_PORT=$_port
            if [ -n "$_cred" ]; then
                [ -n "${TWIN_PARENT_USER:-}" ] || PARENT_USER=${_cred%%:*}
                case "$_cred" in
                    *:*) [ -n "${TWIN_PARENT_PASS:-}" ] || PARENT_PASS=${_cred#*:} ;;
                esac
            fi
            ;;
        \[*\]:*)
            PARENT_ON=1
            _h=${_raw%]:*}; _h=${_h#[}
            PARENT_HOST=${TWIN_PARENT_HOST:-$_h}
            PARENT_PORT=${TWIN_PARENT_PORT:-${_raw##*]:}}
            ;;
        \[*\])
            # 带方括号的 IPv6 但没写端口
            PARENT_ON=1
            _h=${_raw#[}; _h=${_h%]}
            PARENT_HOST=${TWIN_PARENT_HOST:-$_h}
            ;;
        *:*:*)
            # 裸 IPv6 字面量（如 ::1、2001:db8::1），没有端口；
            # 要指定端口请写成 [::1]:1080。
            PARENT_ON=1
            PARENT_HOST=${TWIN_PARENT_HOST:-$_raw}
            ;;
        *:*)
            PARENT_ON=1
            PARENT_HOST=${TWIN_PARENT_HOST:-${_raw%:*}}
            PARENT_PORT=${TWIN_PARENT_PORT:-${_raw##*:}}
            ;;
        *)
            # 只写了主机名：端口沿用默认值
            PARENT_ON=1
            PARENT_HOST=${TWIN_PARENT_HOST:-$_raw}
            ;;
    esac

    if [ "$PARENT_ON" != 1 ]; then
        return 0
    fi

    case "$PARENT_TYPE" in
        socks4|socks4+|socks5|socks5+|connect|connect+) ;;
        *)
            printf '%s\n' '[parent] TWIN_PARENT_TYPE 只能是 socks4 / socks4+ / socks5 / socks5+ / connect / connect+' >&2
            return 1
            ;;
    esac
    case "$PARENT_PORT" in
        ''|*[!0-9]*)
            printf '%s\n' '[parent] TWIN_PARENT_PORT 必须是数字端口' >&2
            return 1
            ;;
    esac
    if [ "$PARENT_PORT" -lt 1 ] || [ "$PARENT_PORT" -gt 65535 ]; then
        printf '%s\n' '[parent] TWIN_PARENT_PORT 范围是 1-65535' >&2
        return 1
    fi
    case "$PARENT_HOST" in
        ''|*[!A-Za-z0-9.:_-]*)
            printf '%s\n' '[parent] TWIN_PARENT_HOST 只允许字母数字和 . : _ -（IPv6 写 ::1 或 [::1]:1080）' >&2
            return 1
            ;;
    esac
    case "$PARENT_USER" in
        *[!A-Za-z0-9_.@-]*)
            printf '%s\n' '[parent] TWIN_PARENT_USER 只允许字母数字和 . _ @ -' >&2
            return 1
            ;;
    esac
    case "$PARENT_PASS" in
        *[!A-Za-z0-9_.@-]*)
            printf '%s\n' '[parent] TWIN_PARENT_PASS 只允许字母数字和 . _ @ -' >&2
            return 1
            ;;
    esac
    if [ -n "$PARENT_PASS" ] && [ -z "$PARENT_USER" ]; then
        printf '%s\n' '[parent] 设置了 TWIN_PARENT_PASS 但没有 TWIN_PARENT_USER' >&2
        return 1
    fi

    PARENT_LINE="parent 1000 $PARENT_TYPE $PARENT_HOST $PARENT_PORT"
    [ -n "$PARENT_USER" ] && PARENT_LINE="$PARENT_LINE $PARENT_USER"
    [ -n "$PARENT_PASS" ] && PARENT_LINE="$PARENT_LINE $PARENT_PASS"
    PARENT_DESC="$PARENT_TYPE $PARENT_HOST:$PARENT_PORT"
    [ -n "$PARENT_USER" ] && PARENT_DESC="$PARENT_DESC user=$PARENT_USER"
    return 0
}

# 把 __TWIN_PARENT__ 换成真正的 parent 行，并处理 FTP（ftppr 不支持 parent）。
twin_parent_apply() {
    _cfg=$1
    [ -f "$_cfg" ] || return 1

    if [ "${PARENT_ON:-0}" != 1 ]; then
        sed -i 's|__TWIN_PARENT__|# 上游 SOCKS5 未启用（TWIN_PARENT=0）|' "$_cfg" || return 1
        return 0
    fi

    _esc=$(printf '%s' "$PARENT_LINE" | sed -e 's/[\/&|]/\\&/g')
    sed -i "s|__TWIN_PARENT__|$_esc|g" "$_cfg" || return 1

    # FTP 段没启用时不用提示策略，否则会误导（"已改为拒绝"但根本没开 FTP）。
    [ "${TWIN_NEED_FTP:-1}" = 1 ] || return 0

    case "${TWIN_PARENT_FTP:-off}" in
        direct)
            printf '%s\n' '[parent] FTP 代理不走上游（TWIN_PARENT_FTP=direct）：FTP 会直连目标网络。'
            ;;
        *)
            # ftppr 无法通过 parent 建立数据通道，默认直接拒掉，避免 FTP 泄漏真实出口。
            sed -i '/^# @service:ftp$/,/^# @end$/ s/^allow .*/deny * * * */' "$_cfg" || return 1
            printf '%s\n' '[parent] FTP 代理不支持 parent，已改为拒绝（TWIN_PARENT_FTP=direct 可放行直连）。'
            ;;
    esac
    return 0
}

# 把本次的上游状态写到运行目录，供 status 显示。
twin_parent_write_state() {
    _dir=${1:-}
    [ -n "$_dir" ] && [ -d "$_dir" ] || return 0
    if [ "${PARENT_ON:-0}" = 1 ]; then
        printf '%s (ftp=%s)\n' "$PARENT_DESC" "${TWIN_PARENT_FTP:-off}" > "$_dir/parent"
    else
        printf '%s\n' 'off' > "$_dir/parent"
    fi
    return 0
}
