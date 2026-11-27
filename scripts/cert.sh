#!/bin/sh
# TwinGate 证书：生成（twin_gen_certs）与"缺了就地补一张"（twin_cert_ensure）。
#
# 只在这里实现一份：scripts/gen-certs.sh 是命令行入口、tgmenu 的「生成证书」
# 走 twin_gen_certs、start 缺证书时走 twin_cert_ensure。安装时本文件会被
# install.sh 内嵌进启动器，所以函数名/变量名都带 twin_ 前缀，避免撞车。
#
# 需要先执行 twin_init_paths（用到 $TWIN_CERT_DIR / $TWIN_DATA）。

# ---------------------------------------------------------------- 生成
# 生成一个本地 CA + 由它签发的服务器证书，并把 ttp 需要的 base64 写进 ttp.env。
# 客户端信任 ca.crt 即可；没有导入 CA 的客户端必须跳过证书校验。
twin_gen_certs() {
    command -v openssl >/dev/null 2>&1 || { echo "需要 openssl" >&2; return 1; }
    CERTDIR=${TWIN_CERT_DIR:-${TWIN_DATA:-.}/run/certs}
    DAYS=${TWIN_CERT_DAYS:-365}
    CA_DAYS=${TWIN_CERT_CA_DAYS:-3650}
    CN=${TWIN_CERT_CN:-TwinGate}
    CA_CN=${TWIN_CERT_CA_CN:-TwinGate Local CA}
    mkdir -p "$CERTDIR" || return 1

    # 只取 IPv4；排除回环。可用 TWIN_CERT_IPS="192.168.1.5,10.0.0.2" 手工补充。
    twin_detect_ips() {
        if command -v ip >/dev/null 2>&1; then
            ip -4 -o addr show 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p'
        elif command -v hostname >/dev/null 2>&1; then
            hostname -I 2>/dev/null | tr ' ' '\n'
        fi
    }
    SAN="DNS:localhost,IP:127.0.0.1"
    for ip in $(twin_detect_ips | sed 's/^ *//; s/ *$//' | sort -u); do
        [ -z "$ip" ] && continue
        [ "$ip" = 127.0.0.1 ] && continue
        case "$ip" in 169.254.*) continue ;; esac
        case ",$SAN," in *",IP:$ip,"*) ;; *) SAN="$SAN,IP:$ip" ;; esac
    done
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

    # CA 只在第一次生成；服务器证书每次重签，以便 SAN 跟随当前网络环境更新。
    if [ ! -f "$CERTDIR/ca.key" ] || [ ! -f "$CERTDIR/ca.crt" ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/ca.key" || return 1
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
            -days "$CA_DAYS" -config "$CERTDIR/ca.cnf" 2>/dev/null || return 1
        echo "[cert] 已生成本地 CA：$CERTDIR/ca.crt"
    fi

    openssl ecparam -name prime256v1 -genkey -noout -out "$CERTDIR/server.key" || return 1
    openssl req -new -key "$CERTDIR/server.key" -out "$CERTDIR/server.csr" \
        -subj "/CN=$CN" 2>/dev/null || return 1
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
        -extfile "$CERTDIR/server.cnf" -extensions v3_server 2>/dev/null || return 1

    # ttp 发送完整链（叶子 + CA），客户端信任 ca.crt 即可。
    cat "$CERTDIR/server.crt" "$CERTDIR/ca.crt" > "$CERTDIR/server-chain.crt"

    # base64 单行化，兼容 GNU / busybox / toybox
    b64() { base64 "$1" | tr -d '\n'; }
    printf 'TTP_SERVER_CERT_B64=%s\n' "$(b64 "$CERTDIR/server-chain.crt")" > "$CERTDIR/ttp.env"
    printf 'TTP_SERVER_KEY_B64=%s\n' "$(b64 "$CERTDIR/server.key")" >> "$CERTDIR/ttp.env"

    # ttp.env 里有服务器私钥的 base64，和 *.key 一样只给属主读。
    chmod 600 "$CERTDIR/ca.key" "$CERTDIR/server.key" "$CERTDIR/ttp.env" 2>/dev/null || :
    echo "[cert] 完成：$CERTDIR"
    echo "[cert] 客户端信任文件：$CERTDIR/ca.crt"
    return 0
}

# ---------------------------------------------------------------- 缺失时补齐
# 刚装好还没生成证书就 start 时不再直接拒绝：就地生成一张，然后把"客户端不信任"
# 这件事讲清楚（curl 要 --proxy-insecure，浏览器/Electron 要 --ignore-certificate-errors），
# 否则用户会以为代理坏了。
twin_cert_ensure() {
    _ce_dir=${TWIN_CERT_DIR:-${TWIN_DATA:-.}/run/certs}
    if [ -f "$_ce_dir/ttp.env" ]; then
        return 0
    fi

    echo "[cert] 未找到证书（$_ce_dir/ttp.env），正在自动生成一张自签证书……" >&2
    if ! command -v openssl >/dev/null 2>&1; then
        echo "[cert] 没有 openssl，无法自动生成。" >&2
        echo "[cert] 请在有 openssl 的机器上执行 'twingate certs'，再把 $_ce_dir 整个拷过来。" >&2
        return 1
    fi
    if ! twin_gen_certs; then
        echo "[cert] 自动生成失败。请手工执行 'twingate certs' 查看原因。" >&2
        return 1
    fi

    cat >&2 <<EOF
[cert] 警告：这张证书是刚生成的，客户端默认不信任它。
[cert]   经 TLS 入口（https:// 代理）访问时必须跳过校验：
[cert]     curl            加 --proxy-insecure（-k 只管目标站，管不到 https:// 代理）
[cert]     浏览器 / Electron 启动参数加 --ignore-certificate-errors
[cert]   长期做法：执行 'twingate trust' 把 CA 装进本机信任库，之后就不必再跳过校验。
[cert]   CA 证书：$_ce_dir/ca.crt
EOF
    return 0
}
