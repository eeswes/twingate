#!/bin/sh
# 生成 TwinGate 的本地 CA + 服务器证书链，并输出 ttp 需要的 base64 环境文件。
#
# 实际逻辑在 scripts/cert.sh（与安装模式的 'twingate certs' 共用一份），
# 这里只是源码树的命令行入口。
#
# 与旧版（单张自签证书，只含 localhost）的区别：
#   - 生成一个本地 CA（ca.crt），客户端只需信任这一张证书，之后不必再用 --insecure；
#   - 服务器证书的 SAN 自动包含本机所有 IPv4 地址，局域网设备用 IP 访问也能通过校验；
#   - 可通过 TWIN_CERT_IPS / TWIN_CERT_DNS 追加访问时实际使用的 IP 或域名。
#
# 建议在有 openssl 的宿主机/Termux 上执行，然后把整个 certs 目录拷进容器。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/paths.sh"
twin_init_paths "$0"
. "$ROOT/scripts/cert.sh"

twin_gen_certs

echo "[cert] 安装到本机：sh scripts/install-ca.sh"
echo "[cert] 跨平台说明：CERTS.md"
ls -l "$TWIN_CERT_DIR"
