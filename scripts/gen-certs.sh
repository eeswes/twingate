#!/bin/sh
# 生成 TwinGate 的本地 CA + 服务器证书链，并输出 ttp 需要的 base64 环境文件。
#
# 与旧版（单张自签证书，只含 localhost）的区别：
#   - 生成一个本地 CA（ca.crt），客户端只需信任这一张证书，之后不必再用 --insecure；
#   - 服务器证书的 SAN 自动包含本机所有 IPv4 地址，局域网设备用 IP 访问也能通过校验；
#   - 可通过 TWIN_CERT_IPS / TWIN_CERT_DNS 追加访问时实际使用的 IP 或域名。
#
# 建议在有 openssl 的宿主机/Termux 上执行，然后把整个 run/certs 拷进容器。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CERTDIR=${TWIN_CERT_DIR:-$ROOT/run/certs}
DAYS=${TWIN_CERT_DAYS:-365}
CA_DAYS=${TWIN_CERT_CA_DAYS:-3650}
CN=${TWIN_CERT_CN:-TwinGate}
CA_CN=${TWIN_CERT_CA_CN:-TwinGate Local CA}

command -v openssl >/dev/null 2>&1 || { echo "需要 openssl" >&2; exit 1; }
mkdir -p "$CERTDIR"

# ---------------- 自动收集 SAN ----------------
# 只取 IPv4；排除回环。可用 TWIN_CERT_IPS="192.168.1.5,10.0.0.2" 手工补充。
detect_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p'
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | tr ' ' '\n'
    fi
}

SAN="DNS:localhost,IP:127.0.0.1"
for ip in $(detect_ips | sed 's/^ *//; s/ *$//' | sort -u); do
    [ -z "$ip" ] && continue
    [ "$ip" = "127.0.0.1" ] && continue
    case "$ip" in 169.254.*) continue ;; esac
    case ",$SAN," in *",IP:$ip,"*) ;; *) SAN="$SAN,IP:$ip" ;; esac
done
# 用户显式追加的 IP / DNS
oifs=$IFS; IFS=,
for x in ${TWIN_CERT_IPS:-}; do
    [ -z "$x" ] && continue
    case ",$SAN," in *",IP:$x,"*) ;; *) SAN="$SAN,IP:$x" ;; esac
done
for x in ${TWIN_CERT_DNS:-}; do
    [ -z "$x" ] && continue
    case ",$SAN," in *",DNS:$x,"*) ;; *) SAN="$SAN,DNS:$x" ;; esac
done
IFS=$oifs

echo "[cert] SAN: $SAN"

# ---------------- 本地 CA ----------------
# CA 只在第一次生成；服务器证书每次重签，以便 SAN 跟随当前网络环境更新。
if [ ! -f "$CERTDIR/ca.key" ] || [ ! -f "$CERTDIR/ca.crt" ]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/ca.key"
    cat > "$CERTDIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = $CA_CN
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
    openssl req -new -x509 -key "$CERTDIR/ca.key" -out "$CERTDIR/ca.crt" \
        -days "$CA_DAYS" -config "$CERTDIR/ca.cnf" 2>/dev/null
    echo "[cert] 已生成本地 CA：$CERTDIR/ca.crt"
fi

# ---------------- 服务器证书 ----------------
openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/server.key"
openssl req -new -key "$CERTDIR/server.key" -out "$CERTDIR/server.csr" \
    -subj "/CN=$CN" 2>/dev/null
cat > "$CERTDIR/server.cnf" <<EOF
[v3_server]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $SAN
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
rm -f "$CERTDIR/server.srl"
openssl x509 -req -in "$CERTDIR/server.csr" \
    -CA "$CERTDIR/ca.crt" -CAkey "$CERTDIR/ca.key" -CAcreateserial \
    -out "$CERTDIR/server.crt" -days "$DAYS" \
    -extfile "$CERTDIR/server.cnf" -extensions v3_server 2>/dev/null

# ttp 发送完整链（叶子 + CA），客户端信任 ca.crt 即可；也保留单独的 server.crt 便于检查。
cat "$CERTDIR/server.crt" "$CERTDIR/ca.crt" > "$CERTDIR/server-chain.crt"

# base64 单行化，兼容 GNU / busybox / toybox
b64() { base64 "$1" | tr -d '\n'; }
printf 'TTP_SERVER_CERT_B64=%s\n' "$(b64 "$CERTDIR/server-chain.crt")" > "$CERTDIR/ttp.env"
printf 'TTP_SERVER_KEY_B64=%s\n' "$(b64 "$CERTDIR/server.key")" >> "$CERTDIR/ttp.env"

chmod 600 "$CERTDIR/ca.key" "$CERTDIR/server.key" 2>/dev/null || :

echo "[cert] 完成：$CERTDIR"
echo "[cert] 客户端信任文件：$CERTDIR/ca.crt"
echo "[cert] 安装到本机：sh scripts/install-ca.sh"
echo "[cert] 跨平台说明：CERTS.md"
ls -l "$CERTDIR"
