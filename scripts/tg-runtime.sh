#!/bin/sh
# TwinGate 运行逻辑（函数库）。
#
# 源码树模式：由 tgmenu.sh source 本文件。
# 安装模式：scripts/install.sh 把本文件内容直接内嵌到 <prefix>/bin/twingate，
#           因此安装后只有这一个脚本 + lib 目录下的三个二进制，不再复制脚本树。
#
# 所有函数都依赖 scripts/paths.sh 已先行执行 twin_init_paths。

# ---------------------------------------------------------------- 配置加载

TUI_LOADED_KEYS=""

twin_ports_init() {
    [ "${TWIN_PORTS_INITIALIZED:-0}" = 1 ] && return 0
    if command -v twin_embedded_ports >/dev/null 2>&1; then
        eval "$(twin_embedded_ports)"
    elif [ -f "$TWIN_CONFIG_DIR/ports.env" ]; then
        . "$TWIN_CONFIG_DIR/ports.env"
    fi
    TWIN_PORTS_INITIALIZED=1
    export TWIN_PORTS_INITIALIZED
}

twin_load_tui_env() {
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
                printf '%s\n' "$_line" >> "$_tmp"
                TUI_LOADED_KEYS="$TUI_LOADED_KEYS $_k"
                ;;
        esac
    done < "$_cfg"
    [ -n "$TUI_LOADED_KEYS" ] && . "$_tmp"
    rm -f "$_tmp"
    return 0
}

twin_tui_loaded() {
    case " $TUI_LOADED_KEYS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 兼容旧名字，供直接调用 scripts/start.sh 等使用。
load_tui_env() { twin_load_tui_env "$@"; }
tui_loaded()   { twin_tui_loaded "$@"; }

twin_template() {
    if command -v twin_embedded_tpl >/dev/null 2>&1; then
        twin_embedded_tpl
    else
        cat "$TWIN_CONFIG_DIR/3proxy.cfg.tpl"
    fi
}

# ---------------------------------------------------------------- 配置渲染

twin_render_config() {
    twin_ports_init
    twin_load_tui_env "$TWIN_TUI_ENV"

    OUT=${1:-${TWIN_CONFIG_PATH:-$TWIN_3PROXY_CFG}}
    mkdir -p "$(dirname "$OUT")" "$TWIN_LOG_DIR" || return 1
    twin_template > "$OUT" || return 1

    for k in TWIN_HTTP_PLAIN TWIN_SOCKS_PLAIN TWIN_FTP_PLAIN TWIN_DNS_SERVER \
             TWIN_EXTERNAL TWIN_LOG_DIR TWIN_PLAIN_BIND \
             TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND; do
        eval "val=\${$k:-}"
        esc=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
        sed -i "s|\${$k}|$esc|g" "$OUT"
    done

    if [ "${TWIN_AUTH:-0}" = 1 ]; then
        case "${TWIN_AUTH_USER:-}" in
            ''|*[!A-Za-z0-9_.@-]*) echo "[config] TWIN_AUTH_USER 只允许字母数字和 . _ @ -" >&2; return 1 ;;
        esac
        case "${TWIN_AUTH_PASS:-}" in
            ''|*[!A-Za-z0-9_.@-]*) echo "[config] TWIN_AUTH_PASS 只允许字母数字和 . _ @ -" >&2; return 1 ;;
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

    [ "${TWIN_NEED_HTTP:-1}" = 1 ] || sed -i '/^# @service:http$/,/^# @end$/d' "$OUT"
    [ "${TWIN_NEED_SOCKS:-1}" = 1 ] || sed -i '/^# @service:socks$/,/^# @end$/d' "$OUT"
    [ "${TWIN_NEED_FTP:-1}" = 1 ] || sed -i '/^# @service:ftp$/,/^# @end$/d' "$OUT"
    echo "[config] 已生成 $OUT"
}

# ---------------------------------------------------------------- 启动

twin_check_exec_dir() {
    d=$1
    mkdir -p "$d" 2>/dev/null || return 1
    [ -w "$d" ] || return 1
    probe="$d/.tg-exec-test.$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    if "$probe" >/dev/null 2>&1; then rm -f "$probe"; return 0; fi
    rm -f "$probe"
    return 1
}

twin_find_runtime_dir() {
    if [ -n "${TWIN_RUNTIME_DIR:-}" ]; then
        twin_check_exec_dir "$TWIN_RUNTIME_DIR" && { printf '%s\n' "$TWIN_RUNTIME_DIR"; return 0; }
        return 1
    fi
    for cand in \
        "${HOME:-}/.twingate/bin" \
        "${TMPDIR:-}/twingate-bin" \
        /data/local/tmp/twingate-bin \
        /data/data/com.termux/files/usr/tmp/twingate-bin \
        /tmp/twingate-bin
    do
        [ -n "$cand" ] || continue
        twin_check_exec_dir "$cand" && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

twin_start() {
    twin_ports_init

    # 显式环境变量优先；随后 tui.env 里写出的绑定键也算显式。
    _explicit_http_bind=${TWIN_HTTP_BIND+x}
    _explicit_socks_bind=${TWIN_SOCKS_BIND+x}
    _explicit_ftp_bind=${TWIN_FTP_BIND+x}
    twin_load_tui_env "$TWIN_TUI_ENV"
    if twin_tui_loaded TWIN_HTTP_BIND;  then _explicit_http_bind=x;  fi
    if twin_tui_loaded TWIN_SOCKS_BIND; then _explicit_socks_bind=x; fi
    if twin_tui_loaded TWIN_FTP_BIND;   then _explicit_ftp_bind=x;   fi

    if [ "${TWIN_AUTH:-0}" = 1 ] &&
       [ "${TWIN_AUTH_USER:-}" = twingate ] && [ "${TWIN_AUTH_PASS:-}" = twingate123 ]; then
        echo "[auth] 警告：正在使用默认凭据 twingate / twingate123。"
        if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
            echo "[auth] 请用 'twingate config' 的认证设置修改，或设 TWIN_AUTH=0 关闭。"
        else
            echo "[auth] 请用 tgmenu.sh 的「配置 -> 认证设置」修改，或设 TWIN_AUTH=0 关闭。"
        fi
    fi

    DEFAULT_SERVICES="http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain"
    if [ "${TWIN_MIXED:-0}" = 1 ]; then DEFAULT_SERVICES="mixed-tls mixed-plain"; fi
    if [ -n "${TWIN_SERVICES:-}" ]; then
        SERVICES=$(printf '%s\n' "$TWIN_SERVICES" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
    else
        SERVICES=$DEFAULT_SERVICES
    fi

    for s in $SERVICES; do
        case "$s" in
            http-tls|http-plain|socks-tls|socks-plain|ftp-tls|ftp-plain|mixed-tls|mixed-plain) ;;
            *) echo "[start] 未知服务：$s" >&2
               echo "[start] 可用：http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain mixed-tls mixed-plain" >&2
               return 1 ;;
        esac
    done

    twin_has_svc() { case " $SERVICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
    need_http=0; need_socks=0; need_ftp=0; need_mux=0
    if twin_has_svc http-tls || twin_has_svc http-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_http=1; fi
    if twin_has_svc socks-tls || twin_has_svc socks-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_socks=1; fi
    if twin_has_svc ftp-tls || twin_has_svc ftp-plain || \
       twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_ftp=1; fi
    if twin_has_svc mixed-tls || twin_has_svc mixed-plain; then need_mux=1; fi
    export TWIN_NEED_HTTP=$need_http TWIN_NEED_SOCKS=$need_socks TWIN_NEED_FTP=$need_ftp

    if [ "$_explicit_http_bind" != x ] && ! twin_has_svc http-plain; then TWIN_HTTP_BIND=127.0.0.1; fi
    if [ "$_explicit_socks_bind" != x ] && ! twin_has_svc socks-plain; then TWIN_SOCKS_BIND=127.0.0.1; fi
    if [ "$_explicit_ftp_bind" != x ] && ! twin_has_svc ftp-plain; then TWIN_FTP_BIND=127.0.0.1; fi
    export TWIN_HTTP_BIND TWIN_SOCKS_BIND TWIN_FTP_BIND

    [ -f "$TWIN_ROOT/3proxy" ] || { echo "[start] 缺少 $TWIN_ROOT/3proxy，请先构建并安装。" >&2; return 1; }
    [ -f "$TWIN_ROOT/ttp" ]    || { echo "[start] 缺少 $TWIN_ROOT/ttp，请先构建并安装。" >&2; return 1; }
    if [ "$need_mux" = 1 ]; then
        [ -f "$TWIN_ROOT/tgmux" ] || { echo "[start] 缺少 $TWIN_ROOT/tgmux，请重新构建并安装。" >&2; return 1; }
    fi
    [ -f "$TWIN_CERT_DIR/ttp.env" ] || {
        echo "[start] 缺少证书，请先执行 'twingate certs' 或 tgmenu.sh 的证书生成。" >&2
        return 1
    }
    . "$TWIN_CERT_DIR/ttp.env"

    RUNDIR=$TWIN_RUN_DIR
    mkdir -p "$RUNDIR" "$TWIN_LOG_DIR" || return 1
    RUNTIME_DIR=$(twin_find_runtime_dir) || {
        echo "[start] 找不到可执行且可写的目录；请设置 TWIN_RUNTIME_DIR。" >&2
        return 1
    }
    mkdir -p "$RUNTIME_DIR"
    printf '%s\n' "$RUNTIME_DIR" > "$RUNDIR/runtime-dir"
    printf '%s\n' "$SERVICES" > "$RUNDIR/services"

    LISTEN_PORTS=""
    twin_has_svc http-tls    && LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_TLS"
    twin_has_svc http-plain  && LISTEN_PORTS="$LISTEN_PORTS $TWIN_HTTP_PLAIN"
    twin_has_svc socks-tls   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_TLS"
    twin_has_svc socks-plain && LISTEN_PORTS="$LISTEN_PORTS $TWIN_SOCKS_PLAIN"
    twin_has_svc ftp-tls     && LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_TLS"
    twin_has_svc ftp-plain   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_FTP_PLAIN"
    twin_has_svc mixed-tls   && LISTEN_PORTS="$LISTEN_PORTS $TWIN_MIXED_TLS"
    twin_has_svc mixed-plain && LISTEN_PORTS="$LISTEN_PORTS $TWIN_MUX_PLAIN"
    printf '%s\n' "$LISTEN_PORTS" | sed 's/^ *//; s/ *$//' > "$RUNDIR/listen-ports"

    echo "[start] 运行时目录：$RUNTIME_DIR"
    echo "[start] 开放服务：$SERVICES"

    BINS="3proxy ttp"
    [ "$need_mux" = 1 ] && BINS="$BINS tgmux"
    for bin in $BINS; do
        tmpbin="$RUNTIME_DIR/$bin.new.$$"
        cp "$TWIN_ROOT/$bin" "$tmpbin" || return 1
        chmod 755 "$tmpbin"
        mv -f "$tmpbin" "$RUNTIME_DIR/$bin" || return 1
    done

    if [ -e /system/bin/linker64 ]; then
        for bin in $BINS; do
            if grep -aq '/lib64/ld-linux' "$RUNTIME_DIR/$bin" 2>/dev/null; then
                echo "[start] $bin 是 glibc 二进制，无法在 Android/bionic 上运行。" >&2
                return 1
            fi
        done
    fi

    twin_render_config "$TWIN_3PROXY_CFG" || return 1

    twin_start_one() {
        name=$1; shift
        "$@" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
        echo $! > "$TWIN_RUN_DIR/$name.pid"
        echo "[start] $name pid=$!"
    }
    twin_start_ttp() {
        name=$1 listen=$2 target=$3
        env TTP_LISTEN_PORT="$listen" \
            TTP_TARGET_HOST=127.0.0.1 \
            TTP_TARGET_PORT="$target" \
            TTP_LOG_PATH="$TWIN_LOG_DIR/$name.log" \
            TTP_SERVER_CERT_B64="$TTP_SERVER_CERT_B64" \
            TTP_SERVER_KEY_B64="$TTP_SERVER_KEY_B64" \
            "$RUNTIME_DIR/ttp" >"$TWIN_LOG_DIR/$name.out" 2>&1 &
        echo $! > "$TWIN_RUN_DIR/$name.pid"
        echo "[start] $name pid=$! listen=$listen -> 127.0.0.1:$target"
    }

    if [ "$need_http$need_socks$need_ftp" != 000 ]; then
        twin_start_one 3proxy "$RUNTIME_DIR/3proxy" "$TWIN_3PROXY_CFG"
    fi
    if [ "$need_mux" = 1 ]; then
        export TWIN_MUX_PEEK_MS
        twin_start_one tgmux "$RUNTIME_DIR/tgmux" \
            "$TWIN_MUX_PLAIN" "$TWIN_HTTP_PLAIN" "$TWIN_SOCKS_PLAIN" \
            "$TWIN_FTP_PLAIN" "$TWIN_MUX_BIND"
    fi
    twin_has_svc http-tls   && twin_start_ttp ttp-http "$TWIN_HTTP_TLS" "$TWIN_HTTP_PLAIN"
    twin_has_svc socks-tls  && twin_start_ttp ttp-socks "$TWIN_SOCKS_TLS" "$TWIN_SOCKS_PLAIN"
    twin_has_svc ftp-tls    && twin_start_ttp ttp-ftp "$TWIN_FTP_TLS" "$TWIN_FTP_PLAIN"
    twin_has_svc mixed-tls  && twin_start_ttp ttp-mixed "$TWIN_MIXED_TLS" "$TWIN_MUX_PLAIN"
    echo "[start] 完成。运行 'twingate status' 查看状态。"
}

# ---------------------------------------------------------------- 停止 / 状态

twin_stop() {
    PIDS=""
    for pidfile in "$TWIN_RUN_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile" 2>/dev/null || true)
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && echo "[stop] killed $(basename "$pidfile") ($pid)"
        fi
        PIDS="$PIDS $pid"
        rm -f "$pidfile"
    done
    i=0
    while [ "$i" -lt 5 ]; do
        alive=0
        for pid in $PIDS; do
            kill -0 "$pid" 2>/dev/null && alive=1
        done
        [ "$alive" = 0 ] && break
        sleep 1
        i=$((i + 1))
    done
}

twin_status() {
    twin_ports_init
    RUNDIR=$TWIN_RUN_DIR
    if [ -f "$RUNDIR/listen-ports" ]; then
        PORTS=$(cat "$RUNDIR/listen-ports")
    else
        PORTS="$TWIN_HTTP_TLS $TWIN_HTTP_PLAIN $TWIN_SOCKS_TLS $TWIN_SOCKS_PLAIN \
$TWIN_FTP_TLS $TWIN_FTP_PLAIN $TWIN_MUX_PLAIN $TWIN_MIXED_TLS"
    fi
    PORT_RE=$(printf '%s\n' "$PORTS" | sed 's/^ *//; s/ *$//' | tr -s ' ' '|')

    [ -f "$RUNDIR/runtime-dir" ] && { echo "=== RUNTIME ==="; cat "$RUNDIR/runtime-dir"; }
    [ -f "$RUNDIR/services" ] && { echo "=== SERVICES ==="; cat "$RUNDIR/services"; }

    echo "=== PID ==="
    for pidfile in "$RUNDIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile" 2>/dev/null || true)
        name=$(basename "$pidfile" .pid)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "OK   $name $pid"
        else
            echo "DEAD $name $pid"
        fi
    done

    echo "=== LISTEN ==="
    if [ -z "$PORT_RE" ]; then
        echo "（未开放任何端口）"
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | grep -E ":($PORT_RE)" || true
    else
        echo "无 ss/netstat，可用: cat /proc/net/tcp"
    fi

    echo "=== LOG TAIL ==="
    for f in "$TWIN_LOG_DIR"/*.out; do
        [ -f "$f" ] || continue
        echo "--- $(basename "$f")"
        tail -n 10 "$f" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------- 证书

twin_gen_certs() {
    command -v openssl >/dev/null 2>&1 || { echo "需要 openssl" >&2; return 1; }
    CERTDIR=$TWIN_CERT_DIR
    DAYS=${TWIN_CERT_DAYS:-365}
    CA_DAYS=${TWIN_CERT_CA_DAYS:-3650}
    CN=${TWIN_CERT_CN:-TwinGate}
    CA_CN=${TWIN_CERT_CA_CN:-TwinGate Local CA}
    mkdir -p "$CERTDIR" || return 1

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

    cat "$CERTDIR/server.crt" "$CERTDIR/ca.crt" > "$CERTDIR/server-chain.crt"
    b64() { base64 "$1" | tr -d '\n'; }
    printf 'TTP_SERVER_CERT_B64=%s\n' "$(b64 "$CERTDIR/server-chain.crt")" > "$CERTDIR/ttp.env"
    printf 'TTP_SERVER_KEY_B64=%s\n' "$(b64 "$CERTDIR/server.key")" >> "$CERTDIR/ttp.env"
    chmod 600 "$CERTDIR/ca.key" "$CERTDIR/server.key" 2>/dev/null || :
    echo "[cert] 完成：$CERTDIR"
    echo "[cert] 客户端信任文件：$CERTDIR/ca.crt"
}

twin_install_ca() {
    CA=${1:-$TWIN_CERT_DIR/ca.crt}
    NAME=twingate-local-ca
    if [ ! -f "$CA" ]; then
        echo "[install-ca] 找不到 $CA" >&2
        echo "[install-ca] 请先执行 'twingate certs'" >&2
        return 1
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
                DEST="$PREFIX/etc/ca-certificates/certs/$NAME.crt"
                cp "$CA" "$DEST"
                command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || :
                echo "[install-ca] 已安装到 Termux：$DEST"
            elif [ -d /etc/pki/ca-trust/source/anchors ]; then
                cp "$CA" "/etc/pki/ca-trust/source/anchors/$NAME.crt"
                command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || :
                echo "[install-ca] 已安装到 RHEL 信任库"
            elif [ -d /usr/local/share/ca-certificates ]; then
                cp "$CA" "/usr/local/share/ca-certificates/$NAME.crt"
                command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || :
                echo "[install-ca] 已安装到 Debian/Ubuntu 信任库"
            else
                echo "[install-ca] 未识别的 Linux 发行版，请手工导入：$CA"
            fi
            ;;
        *)
            echo "[install-ca] 平台 $os，请手工把 $CA 导入系统/浏览器信任库。"
            ;;
    esac
}
