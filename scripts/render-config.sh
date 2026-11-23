#!/bin/sh
# 由 config/ports.env + config/3proxy.cfg.tpl 生成实际配置，不依赖 envsubst。
# 注意：安装模式的 twingate 用的是 scripts/tg-runtime.sh:twin_render_config()，
#       两处的渲染逻辑（认证、parent、服务裁剪）必须同步修改。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/paths.sh"
twin_init_paths "$0"
# tgmenu.sh 保存的配置也参与渲染。加载器要先记录显式环境变量、再读 tui.env、
# 最后才套用 ports.env 的默认值，否则 tui.env 会被默认值提前占位而整份失效。
. "$ROOT/scripts/load-tui-env.sh"
tui_snapshot_explicit
load_tui_env "$TWIN_TUI_ENV"
. "$ROOT/config/ports.env"
# 上游 SOCKS5（parent）的解析与注入
. "$ROOT/scripts/parent.sh"

OUT="${1:-${TWIN_CONFIG_PATH:-$TWIN_DATA/run/3proxy.cfg}}"
mkdir -p "$(dirname "$OUT")" "$TWIN_LOG_DIR"

cp "$ROOT/config/3proxy.cfg.tpl" "$OUT"
for k in TWIN_HTTP_PLAIN TWIN_SOCKS_PLAIN TWIN_FTP_PLAIN TWIN_DNS_SERVER \
         TWIN_EXTERNAL TWIN_LOG_DIR TWIN_PLAIN_BIND \
         TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND; do
    eval "val=\${$k}"
    # 转义 sed 替换串中的特殊字符
    esc=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
    sed -i "s|\${$k}|$esc|g" "$OUT"
done

# ---------------- 上游 SOCKS5（parent 链式出口） ----------------
# 注意：parent 挂在 allow 规则上，而 3proxy 只有在 auth 带 authorizer（strong/iponly）
# 时才会检查 ACL；auth none 下 allow/deny 与 parent 都不生效。所以要提前解析。
twin_parent_resolve || exit 1

# ---------------- 用户名/密码认证 ----------------
if [ "${TWIN_AUTH:-0}" = 1 ]; then
    case "${TWIN_AUTH_USER:-}" in
        ''|*[!A-Za-z0-9_.@-]*)
            echo "[config] TWIN_AUTH_USER 只允许字母数字和 . _ @ -" >&2; exit 1 ;;
    esac
    case "${TWIN_AUTH_PASS:-}" in
        ''|*[!A-Za-z0-9_.@-]*)
            echo "[config] TWIN_AUTH_PASS 只允许字母数字和 . _ @ -" >&2; exit 1 ;;
    esac
    sed -i "s|__TWIN_USERS_LINE__|users ${TWIN_AUTH_USER}:CL:${TWIN_AUTH_PASS}|" "$OUT"
    sed -i 's|__TWIN_AUTH_MODE__|auth strong|' "$OUT"
    sed -i "s|__TWIN_ALLOW__|${TWIN_AUTH_USER}|g" "$OUT"
    echo "[config] 认证已开启：用户 ${TWIN_AUTH_USER}"
else
    sed -i 's|__TWIN_USERS_LINE__|# 认证已关闭（TWIN_AUTH=0）|' "$OUT"
    if [ "${PARENT_ON:-0}" = 1 ]; then
        # 保留 ACL 检查，parent 才能生效（iponly 不校验密码）
        sed -i 's|__TWIN_AUTH_MODE__|auth iponly|' "$OUT"
        echo "[config] 认证已关闭，但为让上游 parent 生效改用 auth iponly（仍不校验密码）"
    else
        sed -i 's|__TWIN_AUTH_MODE__|auth none|' "$OUT"
        echo "[config] 认证已关闭：任何客户端均可连接（TWIN_AUTH=0）"
    fi
    sed -i 's|__TWIN_ALLOW__|* * * *|g' "$OUT"
fi

twin_parent_apply "$OUT" || exit 1
if [ "${PARENT_ON:-0}" = 1 ]; then
    echo "[config] 上游 SOCKS5：$PARENT_DESC"
fi

# 只保留 start.sh 判定需要的 3proxy 服务；直接调用本脚本时默认三个都保留。
[ "${TWIN_NEED_HTTP:-1}" = 1 ] || sed -i '/^# @service:http$/,/^# @end$/d' "$OUT"
[ "${TWIN_NEED_SOCKS:-1}" = 1 ] || sed -i '/^# @service:socks$/,/^# @end$/d' "$OUT"
[ "${TWIN_NEED_FTP:-1}" = 1 ] || sed -i '/^# @service:ftp$/,/^# @end$/d' "$OUT"

echo "[config] 已生成 $OUT"
