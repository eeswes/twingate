#!/bin/sh
# TwinGate text console (TUI)
#
# Target: ReDroid container via adb shell + su (mksh / toybox). No make, bash,
# whiptail, dialog or Python required. Python is only needed for the full probe.
#
# Usage:
#   cd /sdcard/Download/twingate
#   sh tgmenu.sh
#
# Language: auto-detected from the locale (Simplified Chinese / English only).
# Override with TWIN_UI_LANG=zh or TWIN_UI_LANG=en, or set it in Config menu.
#
# Settings are stored in config/tui.env and exported to the existing scripts, so
# every choice is equivalent to `TWIN_XXX=... sh scripts/start.sh`.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CFG="$ROOT/config/tui.env"
RUNDIR="$ROOT/run"

MANAGED="TWIN_SERVICES TWIN_PLAIN_BIND \
TWIN_HTTP_TLS TWIN_HTTP_PLAIN \
TWIN_SOCKS_TLS TWIN_SOCKS_PLAIN \
TWIN_FTP_TLS TWIN_FTP_PLAIN \
TWIN_MIXED_TLS TWIN_MUX_PLAIN \
TWIN_RUNTIME_DIR TWIN_MUX_PEEK_MS \
TWIN_AUTH TWIN_AUTH_USER TWIN_AUTH_PASS TG_PROBE_VERIFY \
TG_PROBE_HOST TG_PROBE_TARGET TG_PYTHON TWIN_UI_LANG"

ALL_SERVICES="http-tls http-plain socks-tls socks-plain ftp-tls ftp-plain mixed-tls mixed-plain"

VAL=""
ANS=""
UI_LANG=en
trap 'printf "\n%s\n" "$(T exited)"; exit 0' INT TERM

# ---------------------------------------------------------------- i18n
# Only two languages are supported: zh (Simplified Chinese) and en (English).
# All user-visible strings go through T <key>; printf format strings stay ASCII
# so a leading '-' can never be parsed as a printf option.

detect_ui_lang() {
    _lang=${TWIN_UI_LANG:-}
    if [ -z "$_lang" ]; then
        _lang=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
    fi
    case "$_lang" in
        zh*|ZH*) UI_LANG=zh ;;
        *) UI_LANG=en ;;
    esac
}

msg_zh() {
    case "$1" in
        press.enter) printf '[按回车返回菜单] ' ;;
        ask.keep) printf '（直接回车保持不变）' ;;
        err.quote) printf '值不能包含单引号。' ;;
        err.port.digit) printf '请输入数字端口。' ;;
        err.port.range) printf '端口范围是 1-65535。' ;;
        err.invalid) printf '无效选择。' ;;
        exited) printf '[已退出]' ;;
        bye) printf '已退出。' ;;
        created.cfg) printf '已创建默认配置：' ;;
        auto) printf '<自动>' ;;
        on) printf '开' ;;
        off) printf '关' ;;
        word.port) printf '端口' ;;
        word.user) printf '用户' ;;
        cfg.header) printf '# TwinGate 控制台配置（由 tgmenu.sh 生成，可手动编辑）' ;;
        cfg.title) printf '当前配置' ;;
        act.start) printf '启动（服务）' ;;
        act.stop) printf '停止所有服务' ;;
        act.status) printf '运行状态' ;;
        act.exit) printf '退出码' ;;
        build.note1) printf '注意：必须在容器内构建，生成的二进制才是 bionic 版本。' ;;
        build.note2) printf '不要在 Termux 里构建给 adb shell 使用，也不要用宿主机 dist/ 覆盖。' ;;
        build.confirm) printf '确认重新构建？会覆盖 dist/ 下的现有二进制' ;;
        build.cancelled) printf '已取消。' ;;
        cert.title) printf '生成/更新 CA + 服务器证书（需要 openssl）' ;;
        cert.custom) printf '是否追加自定义 IP / 域名（客户端实际连接代理时用的地址）' ;;
        cert.auto) printf '自动包含：localhost、127.0.0.1、本机全部 IPv4' ;;
        cert.ask.ip) printf '自定义 IP（逗号分隔，直接回车跳过）  : ' ;;
        cert.ask.dns) printf '自定义域名（逗号分隔，直接回车跳过）: ' ;;
        cert.err.ip) printf 'IP 只能包含数字、点和逗号，已忽略。' ;;
        cert.err.dns) printf '域名只能包含字母数字、点、横线和下划线，已忽略。' ;;
        cert.san) printf '追加 SAN：' ;;
        probe.title) printf '全量协议探测（只探测已启用的服务）' ;;
        probe.no.python) printf '未找到 python3。' ;;
        probe.tips.termux) printf '可在 Termux 执行：pkg install python' ;;
        probe.tips.path) printf '若 adb shell 下仍找不到，请在「配置 -> 探测设置」里填写 Termux 的绝对路径。' ;;
        probe.saved) printf '结果已存到' ;;
        selftest.title) printf '本地自测（不依赖外网，会自动拉起/停止代理）' ;;
        selftest.no.python) printf '未找到 python3，请在「配置 -> 探测设置」里填写路径。' ;;
        certhelp.title) printf '证书信任流程（信任一次即可）' ;;
        certhelp.gen) printf '生成：主菜单 8) 生成 / 更新证书' ;;
        certhelp.gen1) printf '会询问是否追加自定义 IP/域名（客户端连接代理用的地址），' ;;
        certhelp.gen2) printf '再生成 ca.crt + 含本机局域网 IP 的服务器证书链' ;;
        certhelp.dist) printf '分发：客户端只需要' ;;
        certhelp.trust) printf '信任：Linux/Termux/macOS/Windows 执行 sh scripts/install-ca.sh' ;;
        certhelp.android) printf 'Android/ReDroid：设置 -> 安全 -> 从存储设备安装 -> CA 证书' ;;
        certhelp.verify) printf '验证：配置 -> 探测设置 -> 证书校验 打开，再跑全量探测' ;;
        certhelp.full) printf '完整说明：' ;;
        menu.services) printf '服务开关' ;;
        menu.current) printf '当前：' ;;
        menu.return) printf '返回' ;;
        menu.back.parent) printf '返回上一级' ;;
        menu.select.service) printf '选择要切换的服务编号' ;;
        menu.ports) printf '端口设置' ;;
        menu.select.port) printf '选择要修改的端口' ;;
        ports.1) printf 'HTTP  TLS' ;;
        ports.2) printf 'HTTP  明文' ;;
        ports.3) printf 'SOCKS TLS' ;;
        ports.4) printf 'SOCKS 明文' ;;
        ports.5) printf 'FTP   TLS' ;;
        ports.6) printf 'FTP   明文' ;;
        ports.7) printf '混合 TLS' ;;
        ports.8) printf '混合 明文' ;;
        menu.auth) printf '认证设置' ;;
        auth.toggle) printf '认证开关' ;;
        auth.user) printf '用户名' ;;
        auth.pass) printf '密码' ;;
        auth.hint1) printf '默认凭据 twingate / twingate123 仅供开箱体验，请尽快修改；' ;;
        auth.hint2) printf '不需要认证时把开关关掉（TWIN_AUTH=0）。' ;;
        ask.user) printf '用户名（只允许字母数字 . _ @ -）' ;;
        ask.pass) printf '密码（只允许字母数字 . _ @ -）' ;;
        err.user) printf '用户名含非法字符。' ;;
        err.pass) printf '密码含非法字符。' ;;
        menu.probe) printf '探测设置' ;;
        probe.target) printf '探测目标' ;;
        probe.host) printf '探测来源地址' ;;
        probe.python) printf 'Python 路径' ;;
        probe.autodetect) printf '自动探测' ;;
        probe.verify) printf '证书校验' ;;
        probe.verify.on) printf '[开]（需已安装 ca.crt）' ;;
        probe.verify.off) printf '[关]' ;;
        menu.select.item) printf '选择要修改的项' ;;
        ask.probe.target) printf '探测目标（域名或 IP）' ;;
        ask.probe.host) printf '探测来源地址' ;;
        ask.python) printf 'Python 路径（留空则自动探测）' ;;
        menu.config) printf '配置' ;;
        config.file) printf '配置文件：' ;;
        cfg.services) printf '服务开关' ;;
        cfg.ports) printf '端口设置' ;;
        cfg.ports.value) printf '8 个端口' ;;
        cfg.bind) printf '明文绑定地址' ;;
        cfg.runtime) printf '运行时目录' ;;
        cfg.probe) printf '探测设置' ;;
        cfg.probe.value) printf '目标 / 来源 / Python' ;;
        cfg.peek) printf '分发等待时间' ;;
        cfg.auth) printf '认证设置' ;;
        cfg.view) printf '查看当前配置' ;;
        cfg.lang) printf '界面语言' ;;
        lang.zh) printf '简体中文' ;;
        lang.en) printf 'English' ;;
        ask.bind) printf '明文绑定地址（127.0.0.1 或 0.0.0.0）' ;;
        warn.bind1) printf '警告：0.0.0.0 会把明文入口暴露给所有能连到容器的设备；' ;;
        warn.bind2) printf '       认证仍生效，但请确认已改掉默认用户名/密码。' ;;
        confirm.continue) printf '仍要继续吗' ;;
        ask.runtime) printf '运行时目录（可执行且可写，留空自动探测）' ;;
        ask.peek) printf '分发等待毫秒数（FTP 需要，建议 500）' ;;
        main.title) printf '控制台' ;;
        main.services) printf '服务' ;;
        main.bind) printf '绑定' ;;
        main.auth) printf '认证' ;;
        main.auth.default) printf '默认凭据 twingate / twingate123，请尽快修改！' ;;
        main.auth.off) printf '任何客户端均可连接' ;;
        main.config) printf '配置' ;;
        m1) printf '启动代理' ;;
        m2) printf '停止代理' ;;
        m3) printf '重启代理' ;;
        m4) printf '查看状态' ;;
        m5) printf '配置（服务 / 端口 / 绑定 / 探测）' ;;
        m6) printf '重新构建' ;;
        m7) printf '运行全量探测（需要 python3）' ;;
        m8) printf '生成 / 更新证书' ;;
        m9) printf '本地自测（不依赖外网，需 python3）' ;;
        m10) printf '证书信任说明' ;;
        m0) printf '退出' ;;
        ask.select) printf '请选择' ;;
    esac
}

msg_en() {
    case "$1" in
        press.enter) printf '[Press Enter to return to menu] ' ;;
        ask.keep) printf '(press Enter to keep current value)' ;;
        err.quote) printf 'Value must not contain a single quote.' ;;
        err.port.digit) printf 'Enter a numeric port.' ;;
        err.port.range) printf 'Port must be between 1 and 65535.' ;;
        err.invalid) printf 'Invalid selection.' ;;
        exited) printf '[Exited]' ;;
        bye) printf 'Exited.' ;;
        created.cfg) printf 'Created default config: ' ;;
        auto) printf '<auto>' ;;
        on) printf 'on' ;;
        off) printf 'off' ;;
        word.port) printf 'port' ;;
        word.user) printf 'user' ;;
        cfg.header) printf '# TwinGate console config (generated by tgmenu.sh, editable)' ;;
        cfg.title) printf 'Current configuration' ;;
        act.start) printf 'Start (services)' ;;
        act.stop) printf 'Stop all services' ;;
        act.status) printf 'Runtime status' ;;
        act.exit) printf 'exit code' ;;
        build.note1) printf 'Note: build inside the container so the binaries are bionic.' ;;
        build.note2) printf 'Do not build in Termux for adb shell use, and do not overwrite with host dist/.' ;;
        build.confirm) printf 'Rebuild now? Existing binaries in dist/ will be overwritten' ;;
        build.cancelled) printf 'Cancelled.' ;;
        cert.title) printf 'Generate/update CA + server certificate (requires openssl)' ;;
        cert.custom) printf 'Add custom IP / domain names (addresses clients actually use)?' ;;
        cert.auto) printf 'Automatically included: localhost, 127.0.0.1, all local IPv4 addresses' ;;
        cert.ask.ip) printf 'Custom IPs (comma separated, Enter to skip)   : ' ;;
        cert.ask.dns) printf 'Custom domains (comma separated, Enter to skip): ' ;;
        cert.err.ip) printf 'IPs may contain only digits, dots and commas; ignored.' ;;
        cert.err.dns) printf 'Domains may contain only letters, digits, dots, dashes and underscores; ignored.' ;;
        cert.san) printf 'Adding SANs: ' ;;
        probe.title) printf 'Full protocol probe (only enabled services)' ;;
        probe.no.python) printf 'python3 not found.' ;;
        probe.tips.termux) printf 'In Termux run: pkg install python' ;;
        probe.tips.path) printf 'If still missing under adb shell, set the absolute Termux path in "Config -> Probe settings".' ;;
        probe.saved) printf 'results saved to' ;;
        selftest.title) printf 'Local self-test (offline, starts/stops the proxy automatically)' ;;
        selftest.no.python) printf 'python3 not found; set its path in "Config -> Probe settings".' ;;
        certhelp.title) printf 'Certificate trust (import once)' ;;
        certhelp.gen) printf 'Generate: main menu 8) Generate / update certificate' ;;
        certhelp.gen1) printf 'It asks whether to add custom IPs/domains (the addresses clients use),' ;;
        certhelp.gen2) printf 'then generates ca.crt plus a server chain including local LAN IPs' ;;
        certhelp.dist) printf 'Distribute: clients only need' ;;
        certhelp.trust) printf 'Trust: on Linux/Termux/macOS/Windows run sh scripts/install-ca.sh' ;;
        certhelp.android) printf 'Android/ReDroid: Settings -> Security -> Install from storage -> CA certificate' ;;
        certhelp.verify) printf 'Verify: enable Config -> Probe settings -> Certificate verification, then run a full probe' ;;
        certhelp.full) printf 'Full guide: ' ;;
        menu.services) printf 'Service toggles' ;;
        menu.current) printf 'Current: ' ;;
        menu.return) printf 'Back' ;;
        menu.back.parent) printf 'Back to previous menu' ;;
        menu.select.service) printf 'Select the service number to toggle' ;;
        menu.ports) printf 'Port settings' ;;
        menu.select.port) printf 'Select a port to change' ;;
        ports.1) printf 'HTTP  TLS' ;;
        ports.2) printf 'HTTP  plain' ;;
        ports.3) printf 'SOCKS TLS' ;;
        ports.4) printf 'SOCKS plain' ;;
        ports.5) printf 'FTP   TLS' ;;
        ports.6) printf 'FTP   plain' ;;
        ports.7) printf 'Mixed TLS' ;;
        ports.8) printf 'Mixed plain' ;;
        menu.auth) printf 'Authentication' ;;
        auth.toggle) printf 'Authentication' ;;
        auth.user) printf 'Username' ;;
        auth.pass) printf 'Password' ;;
        auth.hint1) printf 'Default credentials twingate / twingate123 are for first-run only; change them ASAP;' ;;
        auth.hint2) printf 'Set TWIN_AUTH=0 to disable authentication.' ;;
        ask.user) printf 'Username (letters, digits, . _ @ - only)' ;;
        ask.pass) printf 'Password (letters, digits, . _ @ - only)' ;;
        err.user) printf 'Username contains invalid characters.' ;;
        err.pass) printf 'Password contains invalid characters.' ;;
        menu.probe) printf 'Probe settings' ;;
        probe.target) printf 'Probe target' ;;
        probe.host) printf 'Probe source address' ;;
        probe.python) printf 'Python path' ;;
        probe.autodetect) printf 'auto-detect' ;;
        probe.verify) printf 'Certificate verification' ;;
        probe.verify.on) printf '[on] (requires installed ca.crt)' ;;
        probe.verify.off) printf '[off]' ;;
        menu.select.item) printf 'Select an item to change' ;;
        ask.probe.target) printf 'Probe target (domain or IP)' ;;
        ask.probe.host) printf 'Probe source address' ;;
        ask.python) printf 'Python path (blank for auto-detect)' ;;
        menu.config) printf 'Configuration' ;;
        config.file) printf 'Config file: ' ;;
        cfg.services) printf 'Services' ;;
        cfg.ports) printf 'Ports' ;;
        cfg.ports.value) printf '8 ports' ;;
        cfg.bind) printf 'Plain bind address' ;;
        cfg.runtime) printf 'Runtime dir' ;;
        cfg.probe) printf 'Probe settings' ;;
        cfg.probe.value) printf 'target / source / Python' ;;
        cfg.peek) printf 'Dispatch wait time' ;;
        cfg.auth) printf 'Authentication' ;;
        cfg.view) printf 'Show current configuration' ;;
        cfg.lang) printf 'Interface language' ;;
        lang.zh) printf '简体中文 (Chinese)' ;;
        lang.en) printf 'English' ;;
        ask.bind) printf 'Plain bind address (127.0.0.1 or 0.0.0.0)' ;;
        warn.bind1) printf 'Warning: 0.0.0.0 exposes the plain entry to every device that can reach the container;' ;;
        warn.bind2) printf '         authentication still applies, but make sure you changed the default username/password.' ;;
        confirm.continue) printf 'Continue anyway' ;;
        ask.runtime) printf 'Runtime dir (executable and writable, blank for auto-detect)' ;;
        ask.peek) printf 'Dispatch wait in ms (needed for FTP, 500 recommended)' ;;
        main.title) printf 'console' ;;
        main.services) printf 'Services' ;;
        main.bind) printf 'Bind' ;;
        main.auth) printf 'Auth' ;;
        main.auth.default) printf 'default credentials twingate / twingate123, change them ASAP!' ;;
        main.auth.off) printf 'any client can connect' ;;
        main.config) printf 'Config' ;;
        m1) printf 'Start proxy' ;;
        m2) printf 'Stop proxy' ;;
        m3) printf 'Restart proxy' ;;
        m4) printf 'Show status' ;;
        m5) printf 'Configuration (services / ports / bind / probe)' ;;
        m6) printf 'Rebuild' ;;
        m7) printf 'Run full probe (requires python3)' ;;
        m8) printf 'Generate / update certificate' ;;
        m9) printf 'Local self-test (offline, requires python3)' ;;
        m10) printf 'Certificate trust help' ;;
        m0) printf 'Exit' ;;
        ask.select) printf 'Your choice' ;;
    esac
}

T() {
    case "$UI_LANG" in
        zh) _out=$(msg_zh "$@") ;;
        *)  _out=$(msg_en "$@") ;;
    esac
    [ -n "$_out" ] || _out=$(msg_en "$@")
    printf '%s' "$_out"
}

# ---------------------------------------------------------------- basic tools

clear_screen() {
    printf '\033[2J\033[H'
}

pause() {
    printf '\n%s ' "$(T press.enter)"
    read -r ANS || :
}

confirm() {
    printf '%s [y/N] ' "$1"
    read -r ANS || return 1
    case "$ANS" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Read a non-empty value into $VAL; bare Enter returns 2 (keep current value).
ask_value() {
    printf '%s%s: ' "$1" "$(T ask.keep)"
    read -r VAL || return 1
    [ -n "$VAL" ] || return 2
    case "$VAL" in
        *"'"*) printf '%s\n' "$(T err.quote)"; return 1 ;;
    esac
    return 0
}

# Read a port in 1-65535 into $VAL.
ask_port() {
    ask_value "$1" || return $?
    case "$VAL" in
        ''|*[!0-9]*) printf '%s\n' "$(T err.port.digit)"; return 1 ;;
    esac
    if [ "$VAL" -lt 1 ] 2>/dev/null || [ "$VAL" -gt 65535 ] 2>/dev/null; then
        printf '%s\n' "$(T err.port.range)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- config persistence

export_config() {
    export TWIN_SERVICES TWIN_PLAIN_BIND \
        TWIN_HTTP_TLS TWIN_HTTP_PLAIN \
        TWIN_SOCKS_TLS TWIN_SOCKS_PLAIN \
        TWIN_FTP_TLS TWIN_FTP_PLAIN \
        TWIN_MIXED_TLS TWIN_MUX_PLAIN \
        TWIN_RUNTIME_DIR TWIN_MUX_PEEK_MS \
        TWIN_AUTH TWIN_AUTH_USER TWIN_AUTH_PASS TG_PROBE_VERIFY \
        TWIN_LOG_DIR TWIN_CERT_DIR \
        TG_PROBE_HOST TG_PROBE_TARGET TG_PYTHON TWIN_UI_LANG
}

load_config() {
    . "$ROOT/config/ports.env"
    . "$ROOT/scripts/load-tui-env.sh"
    load_tui_env "$CFG"
    if [ -z "${TWIN_SERVICES:-}" ]; then
        TWIN_SERVICES="http-tls,http-plain,socks-tls,socks-plain,ftp-tls,ftp-plain"
    fi
    : "${TWIN_RUNTIME_DIR:=}"
    : "${TG_PROBE_VERIFY:=0}"
    : "${TG_PROBE_HOST:=127.0.0.1}"
    : "${TG_PROBE_TARGET:=example.com}"
    : "${TG_PYTHON:=}"
    detect_ui_lang
    export_config
}

save_config() {
    mkdir -p "$(dirname "$CFG")" || return 1
    tmp="$CFG.tmp.$$"
    : > "$tmp" || return 1
    printf '%s\n' "$(T cfg.header)" >> "$tmp"
    for k in $MANAGED; do
        eval "v=\${$k:-}"
        printf "%s='%s'\n" "$k" "$v" >> "$tmp"
    done
    mv -f "$tmp" "$CFG" || return 1
    export_config
}

show_config() {
    printf '\n=== %s (%s) ===\n' "$(T cfg.title)" "$CFG"
    for k in $MANAGED; do
        eval "v=\${$k:-}"
        if [ -z "$v" ]; then v=$(T auto); fi
        printf '  %-20s %s\n' "$k" "$v"
    done
}

svc_has() {
    case ",$TWIN_SERVICES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

svc_toggle() {
    if svc_has "$1"; then
        new=""
        old=$TWIN_SERVICES
        oifs=$IFS
        IFS=,
        for s in $old; do
            [ "$s" = "$1" ] && continue
            if [ -z "$new" ]; then new=$s; else new="$new,$s"; fi
        done
        IFS=$oifs
        TWIN_SERVICES=$new
    else
        if [ -z "$TWIN_SERVICES" ]; then
            TWIN_SERVICES=$1
        else
            TWIN_SERVICES="$TWIN_SERVICES,$1"
        fi
    fi
    save_config
}

# ---------------------------------------------------------------- actions

do_start() {
    printf '\n[start] %s: %s\n' "$(T act.start)" "$TWIN_SERVICES"
    sh "$ROOT/scripts/start.sh"
    printf '[start] %s: %s\n' "$(T act.exit)" "$?"
}

do_stop() {
    printf '\n[stop] %s\n' "$(T act.stop)"
    sh "$ROOT/scripts/stop.sh"
    printf '[stop] %s: %s\n' "$(T act.exit)" "$?"
}

do_restart() {
    do_stop
    command -v sleep >/dev/null 2>&1 && sleep 1
    do_start
}

do_status() {
    printf '\n[status] %s\n' "$(T act.status)"
    sh "$ROOT/scripts/status.sh"
}

do_build() {
    printf '\n[build] %s\n' "$(T build.note1)"
    printf '[build] %s\n' "$(T build.note2)"
    if confirm "$(T build.confirm)"; then
        sh "$ROOT/scripts/build.sh"
        printf '[build] %s: %s\n' "$(T act.exit)" "$?"
    else
        printf '[build] %s\n' "$(T build.cancelled)"
    fi
}

do_certs() {
    printf '\n[cert] %s\n' "$(T cert.title)"
    _cert_ips=""
    _cert_dns=""
    if confirm "$(T cert.custom)"; then
        printf '%s\n' "$(T cert.auto)"
        printf '%s' "$(T cert.ask.ip)"
        read -r _cert_ips || _cert_ips=""
        printf '%s' "$(T cert.ask.dns)"
        read -r _cert_dns || _cert_dns=""
        case "$_cert_ips" in
            ''|*[!0-9.,]*) printf '[cert] %s\n' "$(T cert.err.ip)"; _cert_ips="" ;;
        esac
        case "$_cert_dns" in
            ''|*[!A-Za-z0-9._,-]*) printf '[cert] %s\n' "$(T cert.err.dns)"; _cert_dns="" ;;
        esac
    fi
    if [ -n "$_cert_ips" ] || [ -n "$_cert_dns" ]; then
        printf '[cert] %s IP=[%s] DNS=[%s]\n' "$(T cert.san)" "$_cert_ips" "$_cert_dns"
        TWIN_CERT_IPS="$_cert_ips" TWIN_CERT_DNS="$_cert_dns" sh "$ROOT/scripts/gen-certs.sh"
    else
        sh "$ROOT/scripts/gen-certs.sh"
    fi
    printf '[cert] %s: %s\n' "$(T act.exit)" "$?"
}

find_python() {
    if [ -n "${TG_PYTHON:-}" ]; then
        [ -x "$TG_PYTHON" ] && { printf '%s\n' "$TG_PYTHON"; return 0; }
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    if [ -x /data/data/com.termux/files/usr/bin/python3 ]; then
        printf '%s\n' /data/data/com.termux/files/usr/bin/python3
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi
    return 1
}

# Collect probe modes for one transport (tls/plain) into $MODES.
collect_modes() {
    transport=$1
    MODES=""
    add_mode() {
        case " $MODES " in
            *" $1 "*) ;;
            *) MODES="$MODES $1" ;;
        esac
    }
    oifs=$IFS
    IFS=,
    for s in $TWIN_SERVICES; do
        case "$s" in
            mixed-$transport) add_mode http; add_mode connect; add_mode socks; add_mode ftp ;;
            http-$transport)  add_mode http; add_mode connect ;;
            socks-$transport) add_mode socks ;;
            ftp-$transport)   add_mode ftp ;;
        esac
    done
    IFS=$oifs
    MODES=${MODES# }
}

# probe_one <mode> <tls|plain>
probe_one() {
    mode=$1
    transport=$2
    set -- \
        --host "$TG_PROBE_HOST" --target "$TG_PROBE_TARGET" \
        --http-tls "$TWIN_HTTP_TLS" --http-plain "$TWIN_HTTP_PLAIN" \
        --socks-tls "$TWIN_SOCKS_TLS" --socks-plain "$TWIN_SOCKS_PLAIN" \
        --ftp-tls "$TWIN_FTP_TLS" --ftp-plain "$TWIN_FTP_PLAIN" \
        --mixed-tls "$TWIN_MIXED_TLS" --mux-plain "$TWIN_MUX_PLAIN" \
        --mode "$mode"
    if [ "$transport" = tls ]; then
        set -- "$@" --tls
    else
        set -- "$@" --plain
    fi
    if [ "$MIXED_ON" = 1 ]; then
        set -- "$@" --mixed
    fi
    if [ "${TWIN_AUTH:-1}" = 1 ]; then
        set -- "$@" --user "$TWIN_AUTH_USER" --pass "$TWIN_AUTH_PASS"
    else
        set -- "$@" --no-auth
    fi
    if [ "${TG_PROBE_VERIFY:-0}" = 1 ]; then
        set -- "$@" --verify
    fi

    out="$RUNDIR/probe-menu.$$"
    printf '[probe] %s tests/tg_probe.py %s\n' "$py" "$*"
    "$py" "$ROOT/tests/tg_probe.py" "$@" > "$out" 2>&1
    rc=$?
    cat "$out"
    cat "$out" >> "$TWIN_LOG_DIR/probe-menu.txt" 2>/dev/null || :
    rm -f "$out"
    [ "$rc" -eq 0 ] || PROBE_RC=1
}

do_probe() {
    printf '\n[probe] %s\n' "$(T probe.title)"
    py=$(find_python) || {
        printf '[probe] %s\n' "$(T probe.no.python)"
        printf '[probe] %s\n' "$(T probe.tips.termux)"
        printf '[probe] %s\n' "$(T probe.tips.path)"
        return 1
    }

    MIXED_ON=0
    case ",$TWIN_SERVICES," in
        *",mixed-tls,"*|*",mixed-plain,"*) MIXED_ON=1 ;;
    esac

    mkdir -p "$TWIN_LOG_DIR" 2>/dev/null || :
    : > "$TWIN_LOG_DIR/probe-menu.txt" 2>/dev/null || :
    PROBE_RC=0
    for transport in tls plain; do
        collect_modes "$transport"
        [ -n "$MODES" ] || continue
        n=0
        for m in $MODES; do n=$((n + 1)); done
        if [ "$n" -eq 4 ]; then
            probe_one all "$transport"
        else
            for m in $MODES; do
                probe_one "$m" "$transport"
            done
        fi
    done
    printf '[probe] %s: %s (%s %s/probe-menu.txt)\n' \
        "$(T act.exit)" "$PROBE_RC" "$(T probe.saved)" "$TWIN_LOG_DIR"
    return "$PROBE_RC"
}

do_local_test() {
    printf '\n[selftest] %s\n' "$(T selftest.title)"
    py=$(find_python) || {
        printf '[selftest] %s\n' "$(T selftest.no.python)"
        return 1
    }
    "$py" "$ROOT/tests/tg_local_test.py" --root "$ROOT"
    rc=$?
    printf '[selftest] %s: %s\n' "$(T act.exit)" "$rc"
    return "$rc"
}

do_cert_help() {
    clear_screen
    printf '=== %s ===\n\n' "$(T certhelp.title)"
    printf ' 1) %s\n' "$(T certhelp.gen)"
    printf '    %s\n' "$(T certhelp.gen1)"
    printf '    %s\n' "$(T certhelp.gen2)"
    printf ' 2) %s %s\n' "$(T certhelp.dist)" "$ROOT/run/certs/ca.crt"
    printf ' 3) %s\n' "$(T certhelp.trust)"
    printf '    %s\n' "$(T certhelp.android)"
    printf ' 4) %s\n\n' "$(T certhelp.verify)"
    printf ' %s %s/CERTS.md\n\n' "$(T certhelp.full)" "$ROOT"
    pause
}

# ---------------------------------------------------------------- config menus

menu_services() {
    while :; do
        clear_screen
        printf '=== %s ===\n' "$(T menu.services)"
        printf '%s%s\n\n' "$(T menu.current)" "$TWIN_SERVICES"
        i=1
        for s in $ALL_SERVICES; do
            if svc_has "$s"; then st=$(T on); else st=$(T off); fi
            printf ' %s) %-12s [%s]\n' "$i" "$s" "$st"
            i=$((i + 1))
        done
        printf '\n 0) %s\n' "$(T menu.return)"
        printf '\n%s: ' "$(T menu.select.service)"
        read -r c || return
        case "$c" in
            0) return ;;
            1) svc_toggle http-tls ;;
            2) svc_toggle http-plain ;;
            3) svc_toggle socks-tls ;;
            4) svc_toggle socks-plain ;;
            5) svc_toggle ftp-tls ;;
            6) svc_toggle ftp-plain ;;
            7) svc_toggle mixed-tls ;;
            8) svc_toggle mixed-plain ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_ports() {
    while :; do
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.ports)"
        printf ' %s) %-12s %s\n' 1 "$(T ports.1)" "$TWIN_HTTP_TLS"
        printf ' %s) %-12s %s\n' 2 "$(T ports.2)" "$TWIN_HTTP_PLAIN"
        printf ' %s) %-12s %s\n' 3 "$(T ports.3)" "$TWIN_SOCKS_TLS"
        printf ' %s) %-12s %s\n' 4 "$(T ports.4)" "$TWIN_SOCKS_PLAIN"
        printf ' %s) %-12s %s\n' 5 "$(T ports.5)" "$TWIN_FTP_TLS"
        printf ' %s) %-12s %s\n' 6 "$(T ports.6)" "$TWIN_FTP_PLAIN"
        printf ' %s) %-12s %s\n' 7 "$(T ports.7)" "$TWIN_MIXED_TLS"
        printf ' %s) %-12s %s\n' 8 "$(T ports.8)" "$TWIN_MUX_PLAIN"
        printf '\n 0) %s\n' "$(T menu.return)"
        printf '\n%s: ' "$(T menu.select.port)"
        read -r c || return
        case "$c" in
            1) ask_port "$(T ports.1) $(T word.port)" && { TWIN_HTTP_TLS=$VAL; save_config; } ;;
            2) ask_port "$(T ports.2) $(T word.port)" && { TWIN_HTTP_PLAIN=$VAL; save_config; } ;;
            3) ask_port "$(T ports.3) $(T word.port)" && { TWIN_SOCKS_TLS=$VAL; save_config; } ;;
            4) ask_port "$(T ports.4) $(T word.port)" && { TWIN_SOCKS_PLAIN=$VAL; save_config; } ;;
            5) ask_port "$(T ports.5) $(T word.port)" && { TWIN_FTP_TLS=$VAL; save_config; } ;;
            6) ask_port "$(T ports.6) $(T word.port)" && { TWIN_FTP_PLAIN=$VAL; save_config; } ;;
            7) ask_port "$(T ports.7) $(T word.port)" && { TWIN_MIXED_TLS=$VAL; save_config; } ;;
            8) ask_port "$(T ports.8) $(T word.port)" && { TWIN_MUX_PLAIN=$VAL; save_config; } ;;
            0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_auth() {
    while :; do
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.auth)"
        if [ "${TWIN_AUTH:-1}" = 1 ]; then st=$(T on); else st=$(T off); fi
        printf ' 1) %-14s [%s]\n' "$(T auth.toggle)" "$st"
        printf ' 2) %-14s %s\n' "$(T auth.user)" "${TWIN_AUTH_USER:-twingate}"
        printf ' 3) %-14s %s\n' "$(T auth.pass)" "${TWIN_AUTH_PASS:-twingate123}"
        printf '\n 0) %s\n' "$(T menu.return)"
        printf '\n%s\n' "$(T auth.hint1)"
        printf '%s\n' "$(T auth.hint2)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1)
                if [ "${TWIN_AUTH:-1}" = 1 ]; then TWIN_AUTH=0; else TWIN_AUTH=1; fi
                save_config
                ;;
            2)
                ask_value "$(T ask.user)" || { pause; continue; }
                case "$VAL" in
                    ''|*[!A-Za-z0-9_.@-]*) printf '%s\n' "$(T err.user)"; pause; continue ;;
                esac
                TWIN_AUTH_USER=$VAL; save_config
                ;;
            3)
                ask_value "$(T ask.pass)" || { pause; continue; }
                case "$VAL" in
                    ''|*[!A-Za-z0-9_.@-]*) printf '%s\n' "$(T err.pass)"; pause; continue ;;
                esac
                TWIN_AUTH_PASS=$VAL; save_config
                ;;
            0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_probe_settings() {
    while :; do
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.probe)"
        printf ' 1) %-14s %s\n' "$(T probe.target)" "$TG_PROBE_TARGET"
        printf ' 2) %-14s %s\n' "$(T probe.host)" "$TG_PROBE_HOST"
        if [ -n "${TG_PYTHON:-}" ]; then
            printf ' 3) %-14s %s\n' "$(T probe.python)" "$TG_PYTHON"
        else
            printf ' 3) %-14s %s\n' "$(T probe.python)" "$(T probe.autodetect)"
        fi
        if [ "${TG_PROBE_VERIFY:-0}" = 1 ]; then
            printf ' 4) %-14s %s\n' "$(T probe.verify)" "$(T probe.verify.on)"
        else
            printf ' 4) %-14s %s\n' "$(T probe.verify)" "$(T probe.verify.off)"
        fi
        printf '\n 0) %s\n' "$(T menu.return)"
        printf '\n%s: ' "$(T menu.select.item)"
        read -r c || return
        case "$c" in
            1) ask_value "$(T ask.probe.target)" && { TG_PROBE_TARGET=$VAL; save_config; } ;;
            2) ask_value "$(T ask.probe.host)" && { TG_PROBE_HOST=$VAL; save_config; } ;;
            3) ask_value "$(T ask.python)" && { TG_PYTHON=$VAL; save_config; } ;;
            4)
                if [ "${TG_PROBE_VERIFY:-0}" = 1 ]; then TG_PROBE_VERIFY=0; else TG_PROBE_VERIFY=1; fi
                save_config
                ;;
            0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_language() {
    while :; do
        clear_screen
        printf '=== %s ===\n\n' "$(T cfg.lang)"
        printf ' 1) %s\n' "$(T lang.zh)"
        printf ' 2) %s\n' "$(T lang.en)"
        printf '\n 0) %s\n' "$(T menu.return)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1) TWIN_UI_LANG=zh; UI_LANG=zh; save_config; return ;;
            2) TWIN_UI_LANG=en; UI_LANG=en; save_config; return ;;
            0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_config() {
    while :; do
        clear_screen
        printf '=== %s ===\n' "$(T menu.config)"
        printf '%s%s\n\n' "$(T config.file)" "$CFG"
        printf ' 1) %-20s %s\n' "$(T cfg.services)" "$TWIN_SERVICES"
        printf ' 2) %-20s %s\n' "$(T cfg.ports)" "$(T cfg.ports.value)"
        printf ' 3) %-20s %s\n' "$(T cfg.bind)" "$TWIN_PLAIN_BIND"
        printf ' 4) %-20s %s\n' "$(T cfg.runtime)" "${TWIN_RUNTIME_DIR:-$(T auto)}"
        printf ' 5) %-20s %s\n' "$(T cfg.probe)" "$(T cfg.probe.value)"
        printf ' 6) %-20s %s ms\n' "$(T cfg.peek)" "$TWIN_MUX_PEEK_MS"
        printf ' 7) %-20s %s %s / %s %s\n' "$(T cfg.auth)" \
            "$(T word.user)" "${TWIN_AUTH_USER:-twingate}" "$(T auth.toggle)" "${TWIN_AUTH:-1}"
        printf ' 8) %-20s\n' "$(T cfg.view)"
        printf ' 9) %-20s %s\n' "$(T cfg.lang)" "$UI_LANG"
        printf '\n 0) %s\n' "$(T menu.back.parent)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1) menu_services ;;
            2) menu_ports ;;
            3)
                ask_value "$(T ask.bind)" || { pause; continue; }
                if [ "$VAL" = 0.0.0.0 ]; then
                    printf '%s\n' "$(T warn.bind1)"
                    printf '%s\n' "$(T warn.bind2)"
                    confirm "$(T confirm.continue)" || { printf '%s\n' "$(T build.cancelled)"; pause; continue; }
                fi
                TWIN_PLAIN_BIND=$VAL
                save_config
                ;;
            4)
                ask_value "$(T ask.runtime)" && { TWIN_RUNTIME_DIR=$VAL; save_config; }
                ;;
            5) menu_probe_settings ;;
            6)
                ask_port "$(T ask.peek)" && { TWIN_MUX_PEEK_MS=$VAL; save_config; }
                ;;
            7) menu_auth ;;
            8) show_config; pause ;;
            9) menu_language ;;
            0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

# ---------------------------------------------------------------- main menu

draw_main() {
    clear_screen
    printf '==================================================\n'
    printf '  TwinGate %s   (adb shell + su)\n' "$(T main.title)"
    printf '==================================================\n'
    printf ' %s: %s\n' "$(T main.services)" "$TWIN_SERVICES"
    printf ' %s: %s\n' "$(T main.bind)" "$TWIN_PLAIN_BIND"
    if [ "${TWIN_AUTH:-1}" = 1 ]; then
        if [ "${TWIN_AUTH_USER:-twingate}" = twingate ] &&
           [ "${TWIN_AUTH_PASS:-twingate123}" = twingate123 ]; then
            printf ' %s: %s (%s)\n' "$(T main.auth)" "$(T on)" "$(T main.auth.default)"
        else
            printf ' %s: %s (%s %s)\n' "$(T main.auth)" "$(T on)" "$(T word.user)" "$TWIN_AUTH_USER"
        fi
    else
        printf ' %s: %s (%s)\n' "$(T main.auth)" "$(T off)" "$(T main.auth.off)"
    fi
    printf ' %s: %s\n' "$(T main.config)" "$CFG"
    printf '%s\n' '--------------------------------------------------'
    printf '  1) %s\n' "$(T m1)"
    printf '  2) %s\n' "$(T m2)"
    printf '  3) %s\n' "$(T m3)"
    printf '  4) %s\n' "$(T m4)"
    printf '  5) %s\n' "$(T m5)"
    printf '  6) %s\n' "$(T m6)"
    printf '  7) %s\n' "$(T m7)"
    printf '  8) %s\n' "$(T m8)"
    printf '  9) %s\n' "$(T m9)"
    printf ' 10) %s\n' "$(T m10)"
    printf '\n  0) %s\n' "$(T m0)"
    printf '%s\n' '--------------------------------------------------'
}

main() {
    cd "$ROOT" || exit 1
    load_config
    if [ ! -f "$CFG" ]; then
        save_config
        printf '%s%s\n' "$(T created.cfg)" "$CFG"
        pause
    fi
    while :; do
        draw_main
        printf '%s: ' "$(T ask.select)"
        read -r c || { printf '\n%s\n' "$(T exited)"; exit 0; }
        case "$c" in
            1) do_start;    pause ;;
            2) do_stop;     pause ;;
            3) do_restart;  pause ;;
            4) do_status;   pause ;;
            5) menu_config ;;
            6) do_build;    pause ;;
            7) do_probe;    pause ;;
            8) do_certs;    pause ;;
            9) do_local_test;  pause ;;
            10) do_cert_help ;;
            0) printf '%s\n' "$(T bye)"; exit 0 ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

main "$@"
