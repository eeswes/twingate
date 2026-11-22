#!/bin/sh
# 把 run/certs/ca.crt 安装进当前系统的信任库，客户端校验代理证书时就不用 --insecure。
# 用法：sh scripts/install-ca.sh [ca.crt 路径]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CERTDIR=${TWIN_CERT_DIR:-$ROOT/run/certs}
CA=${1:-$CERTDIR/ca.crt}
NAME=twingate-local-ca

if [ ! -f "$CA" ]; then
    echo "[install-ca] 找不到 $CA" >&2
    echo "[install-ca] 请先执行 sh scripts/gen-certs.sh" >&2
    exit 1
fi

os=$(uname -s 2>/dev/null || printf 'unknown')
case "$os" in
    Darwin)
        KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
        [ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain"
        security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$CA"
        echo "[install-ca] 已安装到 macOS 用户钥匙串：$KEYCHAIN"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        WCA=$(cygpath -w "$CA" 2>/dev/null || printf '%s' "$CA")
        certutil -addstore -f ROOT "$WCA"
        echo "[install-ca] 已安装到 Windows 受信任的根证书颁发机构"
        ;;
    Linux)
        if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/etc/ca-certificates" ]; then
            # Termux
            DEST="$PREFIX/etc/ca-certificates/certs/$NAME.crt"
            cp "$CA" "$DEST"
            if command -v update-ca-certificates >/dev/null 2>&1; then
                update-ca-certificates >/dev/null 2>&1 || \
                    echo "[install-ca] update-ca-certificates 执行失败，请手工检查。"
            fi
            echo "[install-ca] 已安装到 Termux：$DEST"
        elif [ -e /system/bin/linker64 ] || [ -d /system/app ]; then
            # Android / ReDroid 系统级 CA 不能靠复制文件完成，给出可操作步骤
            adb push "$CA" /sdcard/twingate-ca.crt 2>/dev/null || \
                cp "$CA" /sdcard/twingate-ca.crt 2>/dev/null || :
            cat <<EOF
[install-ca] Android/ReDroid 需要手工导入系统 CA：
  1) 把 $CA 传到设备（上面已尝试复制到 /sdcard/twingate-ca.crt）
  2) 设置 -> 安全 -> 更多安全设置 -> 从存储设备安装 -> CA 证书
  3) 选择 twingate-ca.crt；此后用域名/IP 连接 TLS 端口即可通过校验
  注意：Firefox 等使用自有信任库的应用仍需在应用内单独导入。
EOF
        else
            # 普通 Linux（Debian/Ubuntu 或 RHEL 系）
            if [ "$(id -u)" != 0 ]; then
                echo "[install-ca] 需要 root，请用 sudo 执行：sudo sh $0" >&2
                exit 1
            fi
            if command -v update-ca-certificates >/dev/null 2>&1; then
                cp "$CA" "/usr/local/share/ca-certificates/$NAME.crt"
                update-ca-certificates >/dev/null
                echo "[install-ca] 已安装到 /usr/local/share/ca-certificates/$NAME.crt"
            elif command -v update-ca-trust >/dev/null 2>&1; then
                cp "$CA" "/etc/pki/ca-trust/source/anchors/$NAME.crt"
                update-ca-trust extract
                echo "[install-ca] 已安装到 /etc/pki/ca-trust/source/anchors/$NAME.crt"
            else
                echo "[install-ca] 未找到 update-ca-certificates / update-ca-trust，请手动信任 $CA" >&2
                exit 1
            fi
        fi
        ;;
    *)
        echo "[install-ca] 未识别的系统：$os。请手动信任 $CA，详见 CERTS.md" >&2
        exit 1
        ;;
esac

cat <<'EOF'

[install-ca] 验证：连接 TLS 端口时不再需要 --proxy-insecure
  curl -x https://<主机>:<TLS端口> -I --max-time 8 https://example.com
  或：python3 tests/tg_probe.py --tls --mode all --host <主机>

[install-ca] 若仍报 certificate verify failed，请检查连接时用的 IP/域名
  是否写在证书 SAN 中；可用 TWIN_CERT_IPS / TWIN_CERT_DNS 追加后重新 gen-certs.sh。
EOF
