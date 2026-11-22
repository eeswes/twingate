#!/bin/sh
# 由 config/ports.env + config/3proxy.cfg.tpl 生成实际配置，不依赖 envsubst。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/config/ports.env"
# tgmenu.sh 保存的配置也参与渲染；与 start.sh 共用加载器，保证环境变量优先的规则一致。
. "$ROOT/scripts/load-tui-env.sh"
load_tui_env "$ROOT/config/tui.env"

OUT="${1:-${TWIN_CONFIG_PATH:-$ROOT/run/3proxy.cfg}}"
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
    sed -i 's|__TWIN_AUTH_MODE__|auth none|' "$OUT"
    sed -i 's|__TWIN_ALLOW__|* * * *|g' "$OUT"
    echo "[config] 认证已关闭：任何客户端均可连接（TWIN_AUTH=0）"
fi

# 只保留 start.sh 判定需要的 3proxy 服务；直接调用本脚本时默认三个都保留。
[ "${TWIN_NEED_HTTP:-1}" = 1 ] || sed -i '/^# @service:http$/,/^# @end$/d' "$OUT"
[ "${TWIN_NEED_SOCKS:-1}" = 1 ] || sed -i '/^# @service:socks$/,/^# @end$/d' "$OUT"
[ "${TWIN_NEED_FTP:-1}" = 1 ] || sed -i '/^# @service:ftp$/,/^# @end$/d' "$OUT"

echo "[config] 已生成 $OUT"
