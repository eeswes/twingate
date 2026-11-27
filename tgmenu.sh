#!/bin/sh
# TwinGate text console (TUI)
#
# Target: POSIX sh on Linux hosts and ReDroid containers (mksh / toybox).
# No make, bash,
# whiptail, dialog or Python required. Python is only needed for the full probe.
#
# Usage:
#   cd /sdcard/Download/twingate
#   sh tgmenu.sh
#
# Language: auto-detected from the locale (Simplified Chinese / English only).
# Override with TWIN_UI_LANG=zh or TWIN_UI_LANG=en, or set it in Config menu.
#
# Settings are stored in tui.env and exported to the existing scripts, so every
# choice is equivalent to `TWIN_XXX=... sh scripts/start.sh`.
# 源码树里是 config/tui.env；装成 twingate 命令后是 ~/.config/twingate/tui.env
# （XDG 配置目录，由 paths.sh 决定，安装时会把旧位置/仓库里的配置带过去）。
set -u

_TG_SELF=$0
_TG_HERE=$(CDPATH= cd -- "$(dirname -- "$_TG_SELF")" && pwd)
# 安装模式下路径层与 runtime 已内嵌到本文件；源码树模式下从 scripts/ 加载。
if ! command -v twin_init_paths >/dev/null 2>&1; then
    . "$_TG_HERE/scripts/paths.sh"
fi
twin_init_paths "$_TG_SELF"
ROOT=$TWIN_ROOT
CFG="$TWIN_TUI_ENV"
RUNDIR="$TWIN_RUN_DIR"
if ! command -v twin_start >/dev/null 2>&1; then
    . "$ROOT/scripts/tg-runtime.sh"
fi

MANAGED="TWIN_SERVICES TWIN_PLAIN_BIND \
TWIN_HTTP_TLS TWIN_HTTP_PLAIN \
TWIN_SOCKS_TLS TWIN_SOCKS_PLAIN \
TWIN_FTP_TLS TWIN_FTP_PLAIN \
TWIN_MIXED_TLS TWIN_MUX_PLAIN TWIN_MIXED_FTP \
TWIN_RUNTIME_DIR TWIN_MUX_PEEK_MS TTP_SESSION_CACHE_KB \
TWIN_AUTH TWIN_AUTH_USER TWIN_AUTH_PASS TG_PROBE_VERIFY \
TWIN_PARENT TWIN_PARENT_HOST TWIN_PARENT_PORT TWIN_PARENT_TYPE \
TWIN_PARENT_USER TWIN_PARENT_PASS TWIN_PARENT_FTP \
TWIN_TUN TWIN_TUN_DEV TWIN_TUN_BIND TWIN_TIMEOUTS \
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
        err.invalid) printf '无效选择：请输入菜单里的编号（0 返回/退出，直接回车同样返回）。' ;;
        exited) printf '[已退出]' ;;
        bye) printf '已退出。' ;;
        created.cfg) printf '已创建默认配置：' ;;
        auto) printf '<自动>' ;;
        on) printf '开' ;;
        off) printf '关' ;;
        word.port) printf '端口' ;;
        word.user) printf '用户' ;;
        word.auth) printf '认证' ;;
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
        ports.1) printf 'HTTP TLS' ;;
        ports.2) printf 'HTTP 明文' ;;
        ports.3) printf 'SOCKS TLS' ;;
        ports.4) printf 'SOCKS 明文' ;;
        ports.5) printf 'FTP TLS' ;;
        ports.6) printf 'FTP 明文' ;;
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
        cfg.parent) printf '上游 SOCKS5' ;;
        menu.parent) printf '上游 SOCKS5（parent 链式出口）' ;;
        parent.toggle) printf '上游开关' ;;
        parent.type) printf '类型' ;;
        parent.host) printf '地址' ;;
        parent.port) printf '端口' ;;
        parent.user) printf '用户名' ;;
        parent.pass) printf '密码' ;;
        parent.ftp) printf 'FTP 代理' ;;
        parent.ftp.off) printf '拒绝（推荐）' ;;
        parent.ftp.direct) printf '直连（绕过上游）' ;;
        parent.none) printf '（无）' ;;
        parent.off) printf '未启用' ;;
        parent.clear) printf '清除上游用户名/密码' ;;
        parent.hint1) printf '开启后 HTTP / CONNECT / SOCKS4/5 全部经这个上游 SOCKS5 出网，所有客户端共享它。' ;;
        parent.hint2) printf '上游不通时直接失败，不会回退直连；socks5+ 表示域名交给上游解析。' ;;
        parent.hint3) printf 'FTP 代理（ftppr）无法走 parent：默认拒绝，选「直连」会让 FTP 暴露真实出口。' ;;
        parent.hint4) printf '在这里改任意字段会切换成显式字段模式（TWIN_PARENT=1）。' ;;
        ask.parent.type) printf '上游类型：socks5+ / socks5 / socks4 / socks4+ / connect / connect+' ;;
        ask.parent.host) printf '上游地址（IP 或主机名）' ;;
        err.parent.type) printf '类型只能是 socks5+ / socks5 / socks4 / socks4+ / connect / connect+。' ;;
        err.parent.host) printf '上游地址只能包含字母数字和 . : _ -' ;;
        main.parent) printf '上游' ;;
        cfg.tun) printf 'TUN 接力' ;;
        cfg.timeout) printf '超时设置' ;;
        cfg.mixedftp) printf '混合端口 FTP' ;;
        mixftp.on) printf '带（同端口可连 FTP）' ;;
        mixftp.off) printf '不带（只分 HTTP / SOCKS）' ;;
        cfg.tpsc) printf 'TLS 会话缓存' ;;
        tpsc.off) printf '关（每次完整握手）' ;;
        ask.tpsc) printf 'TLS 会话缓存（KB，0 关闭，上限 8192）' ;;
        err.tpsc) printf '请输入 0~8192 之间的整数。' ;;
        menu.timeout) printf '超时设置（秒）' ;;
        tmo.connect) printf '连目标超时' ;;
        tmo.conn) printf '客户端空闲超时' ;;
        tmo.dns) printf 'DNS 解析超时' ;;
        tmo.default) printf '恢复默认' ;;
        tmo.hint1) printf '连目标超时（CONNECT_TO）：连不上目标后放弃的时间。走公网慢代理时' ;;
        tmo.hint2) printf '  太短会表现为「有时候能连、有时候隧道失败」，建议 30~45。' ;;
        tmo.hint3) printf 'DNS 解析超时（DNS_TO）：3proxy 自己解析域名时的单次等待，连不上会' ;;
        tmo.hint4) printf '  表现为「第一次几秒、之后 2~3 秒」。收紧到 5 秒，或改用本机 DNS。' ;;
        ask.tmo.sec) printf '秒数' ;;
        menu.tun) printf 'TUN 虚拟网卡接力（出站绑定）' ;;
        tun.off) printf '未启用' ;;
        tun.any) printf '任意 tun*/utun*' ;;
        tun.none) printf '未找到 TUN' ;;
        tun.error) printf '探测失败' ;;
        tun.iface.missing) printf '未找到网卡' ;;
        tun.notbuilt) printf '缺少 tgtun，请先构建' ;;
        tun.noexec) printf 'tgtun 没有可执行权限（/sdcard 等不支持执行位），请换目录构建' ;;
        tun.toggle) printf '开关' ;;
        tun.iface) printf '网卡' ;;
        tun.bind) printf '绑定策略' ;;
        tun.detect) printf '检测一次（列出候选网卡）' ;;
        tun.mode.direct) printf '已承载默认路由，零配置' ;;
        tun.mode.device) printf 'SO_BINDTODEVICE' ;;
        tun.mode.source) printf 'bind 源地址' ;;
        tun.mode.auto) printf 'auto（有权限绑网卡，否则绑源地址）' ;;
        tun.mode.direct.name) printf 'direct（不做任何绑定）' ;;
        tun.detect.empty) printf '没有找到 tun*/utun* 网卡，或它们没有地址。' ;;
        tun.hint1) printf '开启后 3proxy 的出站改从本机 VPN 的 TUN 网卡出网，所有客户端共享它。' ;;
        tun.hint2) printf 'TUN 已承载默认路由时什么都不用做；否则有 root 就绑网卡，没有就绑源地址。' ;;
        tun.hint3) printf '绑源地址只改源 IP、不改路由：目标网段不在 TUN 的路由里时仍会走物理网卡。' ;;
        tun.hint4) printf '改网卡：按 2 再输入名字（tun0 / wg0），留空 = 自动挑选；也可以直接在这里输入网卡名。' ;;
        ask.tun.iface) printf '网卡名（如 tun0 / wg0）' ;;
        ask.tun.keep) printf '（直接回车 = 自动挑选）' ;;
        err.tun.iface) printf '网卡名只能包含字母数字和 . _ -（最长 15 个字符）' ;;
        err.tun.picknum) printf 'TUN 菜单只有 1-4 这四项；要指定网卡请按 2，或直接输入网卡名（如 tun0）。' ;;
        tun.iface.auto) printf '网卡：自动挑选' ;;
        tun.iface.set) printf '网卡已设为 ' ;;
        main.tun) printf 'TUN' ;;
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
        m5) printf '配置（服务 / 端口 / 绑定 / 上游 / TUN / 探测）' ;;
        m6) printf '重新构建' ;;
        m7) printf '运行全量探测（需要 python3）' ;;
        m8) printf '生成 / 更新证书' ;;
        m9) printf '本地自测（不依赖外网，需 python3）' ;;
        m10) printf '证书信任说明' ;;
        m11) printf '安装为 twingate 命令' ;;
        m12) printf '卸载 twingate 命令' ;;
        m0) printf '退出' ;;
        ask.select) printf '请选择' ;;
        cli.usage) printf '用法: twingate [子命令]（无参数进入菜单）' ;;
        cli.cmds) printf '子命令: start stop restart status config build certs probe selftest trust install uninstall help' ;;
        cli.unknown) printf '未知子命令:' ;;
        installed.only) printf '该功能仅源码树模式可用，请在项目目录运行 tgmenu.sh。' ;;
        cli.help) printf 'TwinGate 单命令入口。无参数启动文本菜单；配置与数据分别保存在用户配置目录和数据目录。' ;;
        install.title) printf '安装为单个 twingate 命令' ;;
        install.user) printf '用户目录 ~/.local（无需 root，推荐）' ;;
        install.system) printf '系统目录 /usr/local（需要写权限）' ;;
        install.termux) printf 'Termux 目录 $PREFIX' ;;
        install.custom) printf '自定义前缀' ;;
        install.ask.prefix) printf '安装前缀' ;;
        install.confirm) printf '确认安装？会复制程序文件并生成启动器' ;;
        install.done) printf '安装完成。试着运行: twingate status' ;;
        install.already) printf '已经安装过了（当前这条命令就是安装版）。要重装请先执行 twingate uninstall。' ;;
        install.nobins) printf '缺少 dist/3proxy 或 dist/ttp，请先在菜单 6) 重新构建' ;;
        uninstall.title) printf '卸载 twingate 命令' ;;
        uninstall.confirm) printf '确认卸载？用户数据（配置/证书/日志）会保留' ;;
        uninstall.done) printf '卸载完成。' ;;
    esac
}

msg_en() {
    case "$1" in
        press.enter) printf '[Press Enter to return to menu] ' ;;
        ask.keep) printf '(press Enter to keep current value)' ;;
        err.quote) printf 'Value must not contain a single quote.' ;;
        err.port.digit) printf 'Enter a numeric port.' ;;
        err.port.range) printf 'Port must be between 1 and 65535.' ;;
        err.invalid) printf 'Invalid selection: type a number from the menu (0 or Enter goes back).' ;;
        exited) printf '[Exited]' ;;
        bye) printf 'Exited.' ;;
        created.cfg) printf 'Created default config: ' ;;
        auto) printf '<auto>' ;;
        on) printf 'on' ;;
        off) printf 'off' ;;
        word.port) printf 'port' ;;
        word.user) printf 'user' ;;
        word.auth) printf 'auth' ;;
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
        cfg.parent) printf 'Upstream SOCKS5' ;;
        menu.parent) printf 'Upstream SOCKS5 (parent chaining)' ;;
        parent.toggle) printf 'Upstream' ;;
        parent.type) printf 'Type' ;;
        parent.host) printf 'Address' ;;
        parent.port) printf 'Port' ;;
        parent.user) printf 'Username' ;;
        parent.pass) printf 'Password' ;;
        parent.ftp) printf 'FTP proxy' ;;
        parent.ftp.off) printf 'deny (recommended)' ;;
        parent.ftp.direct) printf 'direct (bypasses upstream)' ;;
        parent.none) printf '(none)' ;;
        parent.off) printf 'off' ;;
        parent.clear) printf 'Clear upstream username/password' ;;
        parent.hint1) printf 'When on, every HTTP / CONNECT / SOCKS4/5 connection egresses through this one upstream SOCKS5; all clients share it.' ;;
        parent.hint2) printf 'If the upstream is down the connection just fails (no direct fallback); socks5+ lets the upstream resolve names.' ;;
        parent.hint3) printf 'The FTP proxy (ftppr) cannot chain: FTP is denied by default; "direct" exposes your real egress.' ;;
        parent.hint4) printf 'Editing any field here switches to explicit fields (TWIN_PARENT=1).' ;;
        ask.parent.type) printf 'Upstream type: socks5+ / socks5 / socks4 / socks4+ / connect / connect+' ;;
        ask.parent.host) printf 'Upstream address (IP or host name)' ;;
        err.parent.type) printf 'Type must be socks5+ / socks5 / socks4 / socks4+ / connect / connect+.' ;;
        err.parent.host) printf 'Upstream address may only contain letters, digits and . : _ -' ;;
        main.parent) printf 'Upstream' ;;
        cfg.tun) printf 'TUN egress' ;;
        cfg.timeout) printf 'Timeouts' ;;
        cfg.mixedftp) printf 'Mixed-port FTP' ;;
        mixftp.on) printf 'on (FTP shares the port)' ;;
        mixftp.off) printf 'off (HTTP / SOCKS only)' ;;
        cfg.tpsc) printf 'TLS cache' ;;
        tpsc.off) printf 'off (full handshake)' ;;
        ask.tpsc) printf 'TLS session cache in KB (0 = off, max 8192)' ;;
        err.tpsc) printf 'Enter an integer between 0 and 8192.' ;;
        menu.timeout) printf 'Timeouts (seconds)' ;;
        tmo.connect) printf 'Connect to target' ;;
        tmo.conn) printf 'Client idle' ;;
        tmo.dns) printf 'DNS lookup' ;;
        tmo.default) printf 'Restore defaults' ;;
        tmo.hint1) printf 'Connect timeout (CONNECT_TO): give up on an unreachable target. Too' ;;
        tmo.hint2) printf '  short looks like "sometimes it works, sometimes the tunnel fails". 30-45.' ;;
        tmo.hint3) printf 'DNS timeout (DNS_TO): one lookup done by 3proxy itself. A dead resolver' ;;
        tmo.hint4) printf '  shows as "slow once, then 2-3s". Try 5 seconds, or a local resolver.' ;;
        ask.tmo.sec) printf 'seconds' ;;
        menu.tun) printf 'TUN egress (bind outgoing sockets)' ;;
        tun.off) printf 'off' ;;
        tun.any) printf 'any tun*/utun*' ;;
        tun.none) printf 'no TUN found' ;;
        tun.error) printf 'detection failed' ;;
        tun.iface.missing) printf 'interface not found:' ;;
        tun.notbuilt) printf 'tgtun missing, build first' ;;
        tun.noexec) printf 'tgtun is not executable (noexec fs), build elsewhere' ;;
        tun.toggle) printf 'State' ;;
        tun.iface) printf 'Interface' ;;
        tun.bind) printf 'Bind mode' ;;
        tun.detect) printf 'Detect now (list candidates)' ;;
        tun.mode.direct) printf 'carries the default route, zero config' ;;
        tun.mode.device) printf 'SO_BINDTODEVICE' ;;
        tun.mode.source) printf 'bind source address' ;;
        tun.mode.auto) printf 'auto (device when permitted, else source)' ;;
        tun.mode.direct.name) printf 'direct (no binding)' ;;
        tun.detect.empty) printf 'No tun*/utun* interface with an address was found.' ;;
        tun.hint1) printf 'Outgoing traffic leaves through the local VPN TUN interface; every client shares it.' ;;
        tun.hint2) printf 'Nothing to do when the TUN carries the default route; otherwise bind the device (root) or the source address.' ;;
        tun.hint3) printf 'Binding the source address does not change routing: destinations outside the TUN routes still use the physical NIC.' ;;
        tun.hint4) printf 'To change the interface press 2 and type a name (tun0 / wg0); empty = auto-select. Typing the name right here also works.' ;;
        ask.tun.iface) printf 'Interface name (e.g. tun0 / wg0)' ;;
        ask.tun.keep) printf ' (press Enter for auto-select)' ;;
        err.tun.iface) printf 'Interface names may contain only letters, digits and . _ - (max 15 chars)' ;;
        err.tun.picknum) printf 'The TUN menu only has items 1-4; press 2 to choose an interface, or type the interface name here (e.g. tun0).' ;;
        tun.iface.auto) printf 'Interface: auto-select' ;;
        tun.iface.set) printf 'Interface set to ' ;;
        main.tun) printf 'TUN' ;;
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
        m5) printf 'Configuration (services / ports / bind / upstream / probe)' ;;
        m6) printf 'Rebuild' ;;
        m7) printf 'Run full probe (requires python3)' ;;
        m8) printf 'Generate / update certificate' ;;
        m9) printf 'Local self-test (offline, requires python3)' ;;
        m10) printf 'Certificate trust help' ;;
        m11) printf 'Install as twingate command' ;;
        m12) printf 'Uninstall twingate command' ;;
        m0) printf 'Exit' ;;
        ask.select) printf 'Your choice' ;;
        cli.usage) printf 'Usage: twingate [command] (no arguments opens the menu)' ;;
        cli.cmds) printf 'Commands: start stop restart status config build certs probe selftest trust install uninstall help' ;;
        cli.unknown) printf 'Unknown command:' ;;
        installed.only) printf 'Available only from the source tree; run tgmenu.sh in the project directory.' ;;
        cli.help) printf 'TwinGate single command. Run without arguments for the menu; config and data live in separate user directories.' ;;
        install.title) printf 'Install twingate as a single command' ;;
        install.user) printf 'User directory ~/.local (no root, recommended)' ;;
        install.system) printf 'System directory /usr/local (needs write access)' ;;
        install.termux) printf 'Termux directory $PREFIX' ;;
        install.custom) printf 'Custom prefix' ;;
        install.ask.prefix) printf 'Install prefix' ;;
        install.confirm) printf 'Install now? Program files and a launcher will be created' ;;
        install.done) printf 'Installed. Try: twingate status' ;;
        install.already) printf 'Already installed (this command is the installed build). Run twingate uninstall first to reinstall.' ;;
        install.nobins) printf 'dist/3proxy or dist/ttp missing; rebuild first via menu 6)' ;;
        uninstall.title) printf 'Uninstall twingate command' ;;
        uninstall.confirm) printf 'Uninstall now? User data (config/certs/logs) is kept' ;;
        uninstall.done) printf 'Uninstalled.' ;;
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

# ---------------------------------------------------------------- 表格对齐
# 只用制表符、不补空格：标签和值各自落在制表位上，中文英文都不会因为
# "%-14s 按字节补空格"而错位（一个汉字是 3 字节但占 2 列，按字节算必然歪）。
#
# dwidth：显示宽度 = ASCII 字节数 + 2 × (非 ASCII 字节数 / 3)，UTF-8 汉字三字节。
dwidth() {
    _b=$(printf '%s' "$1" | LC_ALL=C wc -c)
    _na=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177' | LC_ALL=C wc -c)
    printf '%s' $((_b - _na + 2 * (_na / 3)))
}

# 从第 $1 列用制表符推到第 $2 列之后（制表位每 8 列一个）。
# 至少发一个 \t，否则标签正好落在边界上时会和值黏在一起。
tabs_after() {
    _c=$1
    _n=0
    while [ "$_c" -lt "$2" ]; do
        printf '\t'
        _c=$(( ((_c - 1) / 8 + 1) * 8 + 1 ))
        _n=1
    done
    [ "$_n" = 1 ] || printf '\t'
}

# 值列：默认第 25 列。菜单里出现长标签时由 col_for 算出更靠右的制表位。
ROW_COL=25

# 按一组标签算值列。9 = "编号)" + \t 之后标签的起始列。
# 值列必须是严格大于「标签末列」的制表位，否则标签会顶到值上。
# 例：英文 "Plain bind address" 18 列 -> 9+18=27 -> 值列 33。
col_for() {
    _max=0
    for _l in "$@"; do
        _w=$(dwidth "$_l")
        [ "$_w" -gt "$_max" ] && _max=$_w
    done
    _c=$((9 + _max + 1))
    [ "$_c" -lt 25 ] && _c=25
    printf '%s' $(( ((_c - 1 + 7) / 8) * 8 + 1 ))
}

# 菜单项：编号 \t 标签 \t… 值。值统一落在 $ROW_COL 列。
row() {
    printf '%s)\t%s' "$1" "$2"
    tabs_after $((9 + $(dwidth "$2"))) "$ROW_COL"
    printf '%s\n' "$3"
}

# 只有说明文字、没有值的菜单项。
item() {
    printf '%s)\t%s\n' "$1" "$2"
}

# 顶部信息行的值列：标签从第 1 列开始，所以不再预留编号宽度。
# 中文标签 4 列时落在第 9 列；英文 "Services" 8 列会顶到第 9 列，
# 于是整块一起右移到第 17 列——同一块里所有行必须共用同一列。
KV_COL=9

col_for_kv() {
    _max=0
    for _l in "$@"; do
        _w=$(dwidth "$_l")
        [ "$_w" -gt "$_max" ] && _max=$_w
    done
    _c=$((_max + 2))
    [ "$_c" -lt 9 ] && _c=9
    printf '%s' $(( ((_c - 1 + 7) / 8) * 8 + 1 ))
}

# 顶部信息行：标签 \t… 值，值统一落在 $KV_COL 列。
kv() {
    printf '%s' "$1"
    tabs_after $((1 + $(dwidth "$1"))) "$KV_COL"
    printf '%s\n' "$2"
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
# 第二个参数可替换"直接回车保持不变"这句提示（例如 TUN 网卡里回车 = 自动挑选）。
ask_value() {
    printf '%s%s: ' "$1" "${2:-$(T ask.keep)}"
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
        TWIN_MIXED_TLS TWIN_MUX_PLAIN TWIN_MIXED_FTP \
        TWIN_RUNTIME_DIR TWIN_MUX_PEEK_MS TTP_SESSION_CACHE_KB \
        TWIN_AUTH TWIN_AUTH_USER TWIN_AUTH_PASS TG_PROBE_VERIFY \
        TWIN_PARENT TWIN_PARENT_HOST TWIN_PARENT_PORT TWIN_PARENT_TYPE \
        TWIN_PARENT_USER TWIN_PARENT_PASS TWIN_PARENT_FTP \
        TWIN_TUN TWIN_TUN_DEV TWIN_TUN_BIND TWIN_TIMEOUTS \
        TWIN_LOG_DIR TWIN_CERT_DIR \
        TG_PROBE_HOST TG_PROBE_TARGET TG_PYTHON TWIN_UI_LANG
}

load_config() {
    # twin_ports_init 内部按「显式环境变量 -> tui.env -> 默认值」的顺序加载，这里不再重复读。
    twin_ports_init
    if [ -z "${TWIN_SERVICES:-}" ]; then
        TWIN_SERVICES="http-tls,http-plain,socks-tls,socks-plain,ftp-tls,ftp-plain"
    else
        # 允许 TWIN_SERVICES="http-tls, socks-tls" 这种带空格的写法
        TWIN_SERVICES=$(printf '%s' "$TWIN_SERVICES" | tr -d ' ')
    fi
    : "${TWIN_RUNTIME_DIR:=}"
    : "${TG_PROBE_VERIFY:=0}"
    : "${TG_PROBE_HOST:=127.0.0.1}"
    : "${TG_PROBE_TARGET:=example.com}"
    : "${TG_PYTHON:=}"
    : "${TWIN_PARENT:=0}"
    : "${TWIN_TUN:=off}"
    : "${TWIN_TUN_DEV:=}"
    : "${TWIN_TUN_BIND:=auto}"
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
    # 文件里有代理与上游密码，只给属主读。
    chmod 600 "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$CFG" || return 1
    export_config
}

# 把 URL 里的 user:pass 换成 ***，用于屏幕显示（不用于配置文件）。
mask_url_cred() {
    case "$1" in
        *://*@*) printf '%s://***@%s' "${1%%://*}" "${1#*@}" ;;
        *) printf '%s' "$1" ;;
    esac
}

show_config() {
    printf '\n=== %s (%s) ===\n' "$(T cfg.title)" "$CFG"
    for k in $MANAGED; do
        eval "v=\${$k:-}"
        case "$k" in
            *_PASS) [ -n "$v" ] && v='******' ;;
            TWIN_PARENT) v=$(mask_url_cred "$v") ;;
        esac
        if [ -z "$v" ]; then v=$(T auto); fi
        printf '  %s' "$k"
        tabs_after $((2 + ${#k})) 17
        printf '%s\n' "$v"
    done
}

svc_has() {
    case ",$TWIN_SERVICES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# 上游 SOCKS5 的一行摘要：关 / 「类型 地址:端口」 / 原始 URL 形式（凭据打码）。
parent_show() {
    case "${TWIN_PARENT:-0}" in
        0|off|no|'')
            printf '%s' "$(T parent.off)"
            ;;
        1|on|yes|true)
            printf '%s %s:%s' "${TWIN_PARENT_TYPE:-socks5+}" \
                "${TWIN_PARENT_HOST:-127.0.0.1}" "${TWIN_PARENT_PORT:-1080}"
            ;;
        *)
            # URL 里可能带 user:pass，屏幕上只显示 ***@。
            mask_url_cred "$TWIN_PARENT"
            ;;
    esac
}

# 混合端口是否带 FTP 这一路的显示。
mixed_ftp_show() {
    case "${TWIN_MIXED_FTP:-1}" in
        0|off|no|false) printf '%s' "$(T mixftp.off)" ;;
        *)              printf '%s' "$(T mixftp.on)" ;;
    esac
}

# 认证开关的显示值。配置里存的是 1/0，直接打印数字在英文界面会读成
# "Authentication 1"，所以转成 开/关（on/off）两个词。
auth_state() {
    case "${TWIN_AUTH:-1}" in
        0|off|no|false) printf '%s' "$(T off)" ;;
        *)              printf '%s' "$(T on)" ;;
    esac
}

# ttp 的 TLS 会话复用缓存（KB）。0 表示关掉，界面上直接说清楚。
tpsc_show() {
    _k=${TTP_SESSION_CACHE_KB:-256}
    if [ "$_k" = 0 ]; then
        printf '%s' "$(T tpsc.off)"
    else
        printf '%s KB' "$_k"
    fi
}

# 缓存大小只接受 0~8192（与 ttp 内部的夹取范围一致）。
ask_tpsc() {
    ask_value "$1" || return $?
    case "$VAL" in
        ''|*[!0-9]*) printf '%s\n' "$(T err.tpsc)"; return 1 ;;
    esac
    if [ "$VAL" -gt 8192 ] 2>/dev/null; then
        printf '%s\n' "$(T err.tpsc)"
        return 1
    fi
    return 0
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
    twin_start
    _rc=$?
    # 先存下 $?，否则 "$(T act.exit)" 的命令替换会把它重置成 0。
    printf '[start] %s: %s\n' "$(T act.exit)" "$_rc"
    return $_rc
}

do_stop() {
    printf '\n[stop] %s\n' "$(T act.stop)"
    twin_stop
    _rc=$?
    printf '[stop] %s: %s\n' "$(T act.exit)" "$_rc"
    return $_rc
}

do_restart() {
    do_stop
    command -v sleep >/dev/null 2>&1 && sleep 1
    do_start
}

do_status() {
    printf '\n[status] %s\n' "$(T act.status)"
    twin_status
}

do_build() {
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf '[build] %s\n' "$(T installed.only)"
        return 1
    fi
    printf '\n[build] %s\n' "$(T build.note1)"
    printf '[build] %s\n' "$(T build.note2)"
    if confirm "$(T build.confirm)"; then
        sh "$ROOT/scripts/build.sh"
        _rc=$?
        printf '[build] %s: %s\n' "$(T act.exit)" "$_rc"
        return $_rc
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
        TWIN_CERT_IPS="$_cert_ips" TWIN_CERT_DNS="$_cert_dns" twin_gen_certs
    else
        twin_gen_certs
    fi
    _rc=$?
    printf '[cert] %s: %s\n' "$(T act.exit)" "$_rc"
    return $_rc
}

do_install() {
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf '[install] %s\n' "$(T install.already)"
        return 1
    fi
    printf '\n[install] %s\n' "$(T install.title)"
    if [ ! -f "$ROOT/dist/3proxy" ] || [ ! -f "$ROOT/dist/ttp" ]; then
        printf '[install] %s\n' "$(T install.nobins)"
        return 1
    fi
    printf ' 1) %s\n' "$(T install.user)"
    printf ' 2) %s\n' "$(T install.system)"
    printf ' 3) %s\n' "$(T install.termux)"
    printf ' 4) %s\n' "$(T install.custom)"
    printf '\n%s: ' "$(T ask.select)"
    read -r c || return 1
    case "$c" in
        1) set -- --user ;;
        2) set -- --system ;;
        3) set -- --termux ;;
        4)
            ask_value "$(T install.ask.prefix)" || { pause; return 1; }
            set -- --prefix "$VAL"
            ;;
        *) printf '%s\n' "$(T err.invalid)"; return 1 ;;
    esac
    confirm "$(T install.confirm)" || { printf '[install] %s\n' "$(T build.cancelled)"; return 1; }
    sh "$ROOT/scripts/install.sh" "$@"
    rc=$?
    [ "$rc" -eq 0 ] && printf '[install] %s\n' "$(T install.done)"
    return "$rc"
}

do_uninstall() {
    printf '\n[uninstall] %s\n' "$(T uninstall.title)"
    confirm "$(T uninstall.confirm)" || { printf '[uninstall] %s\n' "$(T build.cancelled)"; return 1; }
    # 安装模式下启动器自己就认得安装位置，不必回源码树找 uninstall.sh。
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        twin_uninstall "$@"
    else
        sh "$ROOT/scripts/uninstall.sh" "$@"
    fi
    rc=$?
    [ "$rc" -eq 0 ] && printf '[uninstall] %s\n' "$(T uninstall.done)"
    return "$rc"
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
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf '[probe] %s\n' "$(T installed.only)"
        return 1
    fi
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
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf '[selftest] %s\n' "$(T installed.only)"
        return 1
    fi
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
    printf ' 2) %s %s\n' "$(T certhelp.dist)" "$TWIN_CERT_DIR/ca.crt"
    printf ' 3) %s\n' "$(T certhelp.trust)"
    printf '    %s\n' "$(T certhelp.android)"
    printf ' 4) %s\n\n' "$(T certhelp.verify)"
    if [ "${TWIN_INSTALLED:-0}" = 1 ]; then
        printf ' %s CERTS.md (see source tree)\n\n' "$(T certhelp.full)"
    else
        printf ' %s %s/CERTS.md\n\n' "$(T certhelp.full)" "$ROOT"
    fi
    pause
}

# ---------------------------------------------------------------- config menus

menu_services() {
    while :; do
        ROW_COL=25
        clear_screen
        printf '=== %s ===\n' "$(T menu.services)"
        printf '%s%s\n\n' "$(T menu.current)" "$TWIN_SERVICES"
        i=1
        for s in $ALL_SERVICES; do
            if svc_has "$s"; then st=$(T on); else st=$(T off); fi
            row "$i" "$s" "[$st]"
            i=$((i + 1))
        done
        printf '\n'
        item 0 "$(T menu.return)"
        printf '\n%s: ' "$(T menu.select.service)"
        read -r c || return
        case "$c" in
            ''|0) return ;;
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
        ROW_COL=25
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.ports)"
        row 1 "$(T ports.1)" "$TWIN_HTTP_TLS"
        row 2 "$(T ports.2)" "$TWIN_HTTP_PLAIN"
        row 3 "$(T ports.3)" "$TWIN_SOCKS_TLS"
        row 4 "$(T ports.4)" "$TWIN_SOCKS_PLAIN"
        row 5 "$(T ports.5)" "$TWIN_FTP_TLS"
        row 6 "$(T ports.6)" "$TWIN_FTP_PLAIN"
        row 7 "$(T ports.7)" "$TWIN_MIXED_TLS"
        row 8 "$(T ports.8)" "$TWIN_MUX_PLAIN"
        printf '\n'
        item 0 "$(T menu.return)"
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
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_auth() {
    while :; do
        ROW_COL=25
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.auth)"
        if [ "${TWIN_AUTH:-1}" = 1 ]; then st=$(T on); else st=$(T off); fi
        row 1 "$(T auth.toggle)" "[$st]"
        row 2 "$(T auth.user)" "${TWIN_AUTH_USER:-twingate}"
        row 3 "$(T auth.pass)" '******'
        printf '\n'
        item 0 "$(T menu.return)"
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
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_probe_settings() {
    while :; do
        ROW_COL=$(col_for "$(T probe.target)" "$(T probe.host)" \
            "$(T probe.python)" "$(T probe.verify)")
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.probe)"
        row 1 "$(T probe.target)" "$TG_PROBE_TARGET"
        row 2 "$(T probe.host)" "$TG_PROBE_HOST"
        if [ -n "${TG_PYTHON:-}" ]; then
            row 3 "$(T probe.python)" "$TG_PYTHON"
        else
            row 3 "$(T probe.python)" "$(T probe.autodetect)"
        fi
        if [ "${TG_PROBE_VERIFY:-0}" = 1 ]; then
            row 4 "$(T probe.verify)" "$(T probe.verify.on)"
        else
            row 4 "$(T probe.verify)" "$(T probe.verify.off)"
        fi
        printf '\n'
        item 0 "$(T menu.return)"
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
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

# ---- 超时设置 ----------------------------------------------------------
# TWIN_TIMEOUTS 是 3proxy 的 11 个超时，按位取值很容易写错位置（CONNECT_TO 在第 9 位），
# 所以这里只暴露最常调的三个，其余位保持原样。
#   位置（从 1 数）：1 SINGLEBYTE_S 2 SINGLEBYTE_L 3 STRING_S 4 STRING_L
#                  5 CONNECTION_S 6 CONNECTION_L 7 DNS_TO 8 CHAIN_TO
#                  9 CONNECT_TO 10 CONNBACK_TO 11 LINGER_TO
TMO_DEFAULT="1 5 30 60 180 1800 15 60 15 5 5"

# tmo_field <位置> <新值>：把第 N 位换成新值，输出完整的 11 位串。
tmo_field() {
    _pos=$1; _val=$2; _i=1; _out=""
    for _f in ${TWIN_TIMEOUTS:-$TMO_DEFAULT}; do
        if [ "$_i" = "$_pos" ]; then _out="$_out $_val"; else _out="$_out $_f"; fi
        _i=$((_i + 1))
    done
    # 配置被手工改短时补齐到 11 位，否则最后几位会整体前移（CONNECT_TO 就跑位了）。
    while [ "$_i" -le 11 ]; do
        _d=$(printf '%s\n' "$TMO_DEFAULT" | cut -d' ' -f"$_i")
        _out="$_out $_d"
        _i=$((_i + 1))
    done
    printf '%s' "$_out" | sed 's/^ //'
}

tmo_get() {
    printf '%s\n' "${TWIN_TIMEOUTS:-$TMO_DEFAULT}" | cut -d' ' -f"$1"
}

menu_timeouts() {
    while :; do
        ROW_COL=$(col_for "$(T tmo.connect)" "$(T tmo.conn)" "$(T tmo.dns)")
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.timeout)"
        row 1 "$(T tmo.connect)" "$(tmo_get 9) $(T ask.tmo.sec)"
        row 2 "$(T tmo.conn)" "$(tmo_get 5) $(T ask.tmo.sec)"
        row 3 "$(T tmo.dns)" "$(tmo_get 7) $(T ask.tmo.sec)"
        item 4 "$(T tmo.default)"
        printf '\n'
        item 0 "$(T menu.return)"
        printf '\n%s\n%s\n%s\n%s\n' \
            "$(T tmo.hint1)" "$(T tmo.hint2)" "$(T tmo.hint3)" "$(T tmo.hint4)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1|2|3)
                case "$c" in
                    1) _pos=9 ;;   # CONNECT_TO
                    2) _pos=5 ;;   # CONNECTION_S
                    3) _pos=7 ;;   # DNS_TO
                esac
                ask_port "$(T ask.tmo.sec)" || { pause; continue; }
                TWIN_TIMEOUTS=$(tmo_field "$_pos" "$VAL")
                save_config
                ;;
            4) TWIN_TIMEOUTS=$TMO_DEFAULT; save_config ;;
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

menu_language() {
    while :; do
        clear_screen
        printf '=== %s ===\n\n' "$(T cfg.lang)"
        item 1 "$(T lang.zh)"
        item 2 "$(T lang.en)"
        printf '\n'
        item 0 "$(T menu.return)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1) TWIN_UI_LANG=zh; UI_LANG=zh; save_config; return ;;
            2) TWIN_UI_LANG=en; UI_LANG=en; save_config; return ;;
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

# 把 URL / 简写解析出的结果固化成显式字段。
# 必要性：TWIN_PARENT 写成 URL 时，页面上的地址与端口来自临时解析结果，
# 直接改某一项会把 TWIN_PARENT 切换成 1，其余字段就回落到默认值、丢掉原地址。
parent_pin_fields() {
    TWIN_PARENT_TYPE=${PARENT_TYPE:-socks5+}
    TWIN_PARENT_HOST=${PARENT_HOST:-127.0.0.1}
    TWIN_PARENT_PORT=${PARENT_PORT:-1080}
    TWIN_PARENT_USER=${PARENT_USER:-}
    TWIN_PARENT_PASS=${PARENT_PASS:-}
    TWIN_PARENT=1
}

menu_parent() {
    while :; do
        ROW_COL=25
        clear_screen
        twin_parent_resolve >/dev/null 2>&1 || :
        printf '=== %s ===\n\n' "$(T menu.parent)"
        if [ "${PARENT_ON:-0}" = 1 ]; then st=$(T on); else st=$(T off); fi
        row 1 "$(T parent.toggle)" "[$st]"
        row 2 "$(T parent.type)" "${PARENT_TYPE:-socks5+}"
        row 3 "$(T parent.host)" "${PARENT_HOST:-127.0.0.1}"
        row 4 "$(T parent.port)" "${PARENT_PORT:-1080}"
        row 5 "$(T parent.user)" "${PARENT_USER:-$(T parent.none)}"
        if [ -n "${PARENT_PASS:-}" ]; then
            row 6 "$(T parent.pass)" '******'
        else
            row 6 "$(T parent.pass)" "$(T parent.none)"
        fi
        case "${TWIN_PARENT_FTP:-off}" in
            direct) ftpst=$(T parent.ftp.direct) ;;
            *)      ftpst=$(T parent.ftp.off) ;;
        esac
        row 7 "$(T parent.ftp)" "$ftpst"
        item 8 "$(T parent.clear)"
        printf '\n'
        item 0 "$(T menu.return)"
        printf '\n%s\n%s\n%s\n%s\n' \
            "$(T parent.hint1)" "$(T parent.hint2)" "$(T parent.hint3)" "$(T parent.hint4)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            1)
                if [ "${PARENT_ON:-0}" = 1 ]; then
                    parent_pin_fields      # 关掉前先固化字段，重新打开不会丢地址
                    TWIN_PARENT=0
                else
                    TWIN_PARENT=1
                fi
                save_config
                ;;
            2)
                ask_value "$(T ask.parent.type)" || { pause; continue; }
                case "$VAL" in
                    socks4|socks4+|socks5|socks5+|connect|connect+) ;;
                    *) printf '%s\n' "$(T err.parent.type)"; pause; continue ;;
                esac
                parent_pin_fields; TWIN_PARENT_TYPE=$VAL; save_config
                ;;
            3)
                ask_value "$(T ask.parent.host)" || { pause; continue; }
                case "$VAL" in
                    *[!A-Za-z0-9.:_-]*) printf '%s\n' "$(T err.parent.host)"; pause; continue ;;
                esac
                parent_pin_fields; TWIN_PARENT_HOST=$VAL; save_config
                ;;
            4)
                ask_port "$(T parent.port)" && { parent_pin_fields; TWIN_PARENT_PORT=$VAL; save_config; }
                ;;
            5)
                ask_value "$(T ask.user)" || { pause; continue; }
                case "$VAL" in
                    *[!A-Za-z0-9_.@-]*) printf '%s\n' "$(T err.user)"; pause; continue ;;
                esac
                parent_pin_fields; TWIN_PARENT_USER=$VAL; save_config
                ;;
            6)
                ask_value "$(T ask.pass)" || { pause; continue; }
                case "$VAL" in
                    *[!A-Za-z0-9_.@-]*) printf '%s\n' "$(T err.pass)"; pause; continue ;;
                esac
                parent_pin_fields; TWIN_PARENT_PASS=$VAL; save_config
                ;;
            7)
                case "${TWIN_PARENT_FTP:-off}" in
                    direct) TWIN_PARENT_FTP=off ;;
                    *)      TWIN_PARENT_FTP=direct ;;
                esac
                save_config
                ;;
            8)
                TWIN_PARENT_USER=""; TWIN_PARENT_PASS=""; save_config
                ;;
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

# TUN 接力的一行摘要：off / 自动 → tun0 · SO_BINDTODEVICE / tun0 · bind 10.8.0.2
tun_show() {
    case "${TWIN_TUN:-off}" in
        0|off|no|false|'')
            printf '%s' "$(T tun.off)"
            return
            ;;
    esac
    twin_bin_state "$(twin_tun_bin)"
    case $? in
        1) printf '%s' "$(T tun.notbuilt)"; return ;;
        2) printf '%s' "$(T tun.noexec)"; return ;;
    esac
    # twin_tun_resolve 只做探测，不改配置；失败时只影响这一行的显示。
    if ! twin_tun_resolve >/dev/null 2>&1; then
        case "${TUN_REASON:-}" in
            iface-not-found) printf '%s %s' "$(T tun.iface.missing)" "${TWIN_TUN_DEV:-}" ;;
            *)               printf '%s' "$(T tun.error)" ;;
        esac
        return
    fi
    if [ "${TUN_ON:-0}" != 1 ]; then
        printf '%s' "$(T tun.none)"
        return
    fi
    case "${TWIN_TUN:-off}" in
        1|on|yes|true|auto) _lbl="$(T tun.any) -> $TUN_DEV" ;;
        *)                  _lbl=$TUN_DEV ;;
    esac
    case "$TUN_MODE" in
        direct) _how=$(T tun.mode.direct) ;;
        device) _how=$(T tun.mode.device) ;;
        source) _how="$(T tun.mode.source) $TUN_BIND_IP" ;;
        *)      _how=$(T tun.none) ;;
    esac
    printf '%s · %s' "$_lbl" "$_how"
}

# 保存要绑定的网卡：空 / auto = 自动挑选。名字校验与内核 IFNAMSIZ 对齐（最长 15）。
tun_set_iface() {
    _ti=$1
    if [ -z "$_ti" ] || [ "$(printf '%s' "$_ti" | tr 'A-Z' 'a-z')" = auto ]; then
        TWIN_TUN_DEV=""
        save_config
        printf '%s\n' "$(T tun.iface.auto)"
        return 0
    fi
    case "$_ti" in
        *[!A-Za-z0-9_.-]*) printf '%s\n' "$(T err.tun.iface)"; return 1 ;;
    esac
    if [ ${#_ti} -gt 15 ]; then
        printf '%s\n' "$(T err.tun.iface)"
        return 1
    fi
    TWIN_TUN_DEV=$_ti
    save_config
    printf '%s%s\n' "$(T tun.iface.set)" "$_ti"
    return 0
}

menu_tun() {
    while :; do
        ROW_COL=25
        clear_screen
        printf '=== %s ===\n\n' "$(T menu.tun)"
        case "${TWIN_TUN:-off}" in
            0|off|no|false|'') st=$(T off) ;;
            *)                 st=$(T on) ;;
        esac
        row 1 "$(T tun.toggle)" "[$st]"
        ifc=${TWIN_TUN_DEV:-}
        case "$ifc" in
            ''|auto|any) ifc=$(T tun.any) ;;
        esac
        row 2 "$(T tun.iface)" "$ifc"
        case "${TWIN_TUN_BIND:-auto}" in
            device) bm=$(T tun.mode.device) ;;
            source) bm=$(T tun.mode.source) ;;
            direct) bm=$(T tun.mode.direct.name) ;;
            *)      bm=$(T tun.mode.auto) ;;
        esac
        row 3 "$(T tun.bind)" "$bm"
        item 4 "$(T tun.detect)"
        printf '\n'
        item 0 "$(T menu.return)"
        printf '\n%s\n%s\n%s\n%s\n' \
            "$(T tun.hint1)" "$(T tun.hint2)" "$(T tun.hint3)" "$(T tun.hint4)"
        printf '\n%s: ' "$(T ask.select)"
        read -r c || return
        case "$c" in
            ''|0) return ;;
            1)
                case "${TWIN_TUN:-off}" in
                    0|off|no|false|'') TWIN_TUN=1 ;;
                    *)                 TWIN_TUN=0 ;;
                esac
                save_config
                ;;
            2)
                # ask_value: 0 = 有值，2 = 直接回车（这里语义是"自动挑选"），1 = 读失败。
                ask_value "$(T ask.tun.iface)" "$(T ask.tun.keep)"
                _rc=$?
                case "$_rc" in
                    0) tun_set_iface "$VAL" || { pause; continue; } ;;
                    2) tun_set_iface "" ;;
                    *) pause; continue ;;
                esac
                pause
                ;;
            3)
                case "${TWIN_TUN_BIND:-auto}" in
                    auto)   TWIN_TUN_BIND=device ;;
                    device) TWIN_TUN_BIND=source ;;
                    source) TWIN_TUN_BIND=direct ;;
                    *)      TWIN_TUN_BIND=auto ;;
                esac
                save_config
                ;;
            4)
                _tun_dev=${TWIN_TUN_DEV:-}
                case "$_tun_dev" in
                    auto|any) _tun_dev="" ;;
                esac
                if [ ! -x "$(twin_tun_bin)" ]; then
                    twin_bin_state "$(twin_tun_bin)"
                    if [ $? = 2 ]; then
                        printf '%s\n' "$(T tun.noexec)"
                    else
                        printf '%s\n' "$(T tun.notbuilt)"
                    fi
                else
                    if [ -n "$_tun_dev" ]; then
                        _tun_list=$("$(twin_tun_bin)" list --iface "$_tun_dev" 2>/dev/null || true)
                    else
                        _tun_list=$("$(twin_tun_bin)" list 2>/dev/null || true)
                    fi
                    case "$_tun_list" in
                        ''|none|not-found) printf '%s\n' "$(T tun.detect.empty)" ;;
                        *) printf '%s\n' "$_tun_list" ;;
                    esac
                    echo
                    if [ -n "$_tun_dev" ]; then
                        "$(twin_tun_bin)" plan --iface "$_tun_dev" || true
                    else
                        "$(twin_tun_bin)" plan || true
                    fi
                fi
                pause
                ;;
            *)
                # 这里最容易踩的坑：大家会直接把网卡名当菜单项敲进来。
                # 含字母 → 按网卡名处理；纯数字/纯符号 → 提示该按 2。
                case "$c" in
                    *[A-Za-z]*)
                        tun_set_iface "$c" || :
                        pause
                        ;;
                    *)
                        printf '%s\n' "$(T err.tun.picknum)"
                        pause
                        ;;
                esac
                ;;
        esac
    done
}

menu_config() {
    while :; do
        ROW_COL=$(col_for "$(T cfg.services)" "$(T cfg.ports)" "$(T cfg.bind)" \
            "$(T cfg.runtime)" "$(T cfg.probe)" "$(T cfg.peek)" "$(T cfg.auth)" \
            "$(T cfg.lang)" "$(T cfg.parent)" "$(T cfg.tun)" "$(T cfg.timeout)" \
            "$(T cfg.mixedftp)" "$(T cfg.tpsc)")
        clear_screen
        printf '=== %s ===\n' "$(T menu.config)"
        printf '%s%s\n\n' "$(T config.file)" "$CFG"
        row 1 "$(T cfg.services)" "$TWIN_SERVICES"
        row 2 "$(T cfg.ports)" "$(T cfg.ports.value)"
        row 3 "$(T cfg.bind)" "$TWIN_PLAIN_BIND"
        row 4 "$(T cfg.runtime)" "${TWIN_RUNTIME_DIR:-$(T auto)}"
        row 5 "$(T cfg.probe)" "$(T cfg.probe.value)"
        row 6 "$(T cfg.peek)" "$TWIN_MUX_PEEK_MS ms"
        row 7 "$(T cfg.auth)" \
            "$(T word.user) ${TWIN_AUTH_USER:-twingate} / $(T word.auth) $(auth_state)"
        item 8 "$(T cfg.view)"
        row 9 "$(T cfg.lang)" "$UI_LANG"
        row 10 "$(T cfg.parent)" "$(parent_show)"
        row 11 "$(T cfg.tun)" "$(tun_show)"
        row 12 "$(T cfg.timeout)" \
            "$(T tmo.connect) $(tmo_get 9)s / $(T tmo.dns) $(tmo_get 7)s"
        row 13 "$(T cfg.mixedftp)" "$(mixed_ftp_show)"
        row 14 "$(T cfg.tpsc)" "$(tpsc_show)"
        printf '\n'
        item 0 "$(T menu.back.parent)"
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
            10) menu_parent ;;
            11) menu_tun ;;
            12) menu_timeouts ;;
            13)
                case "${TWIN_MIXED_FTP:-1}" in
                    0|off|no|false) TWIN_MIXED_FTP=1 ;;
                    *)              TWIN_MIXED_FTP=0 ;;
                esac
                save_config
                ;;
            14)
                ask_tpsc "$(T ask.tpsc)" && { TTP_SESSION_CACHE_KB=$VAL; save_config; }
                ;;
            ''|0) return ;;
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

# ---------------------------------------------------------------- main menu

draw_main() {
    # 值列按本语言最长的标签算一次，避免"Services 在第 17 列、Bind 在第 9 列"。
    KV_COL=$(col_for_kv "$(T main.services)" "$(T main.bind)" "$(T main.auth)" \
        "$(T main.parent)" "$(T main.tun)" "$(T main.config)")
    clear_screen
    printf '==================================================\n'
    printf '  TwinGate %s\n' "$(T main.title)"
    printf '==================================================\n'
    kv "$(T main.services)" "$TWIN_SERVICES"
    kv "$(T main.bind)" "$TWIN_PLAIN_BIND"
    if [ "${TWIN_AUTH:-1}" = 1 ]; then
        if [ "${TWIN_AUTH_USER:-twingate}" = twingate ] &&
           [ "${TWIN_AUTH_PASS:-twingate123}" = twingate123 ]; then
            kv "$(T main.auth)" "$(T on) ($(T main.auth.default))"
        else
            kv "$(T main.auth)" "$(T on) ($(T word.user) $TWIN_AUTH_USER)"
        fi
    else
        kv "$(T main.auth)" "$(T off) ($(T main.auth.off))"
    fi
    kv "$(T main.parent)" "$(parent_show)"
    kv "$(T main.tun)" "$(tun_show)"
    kv "$(T main.config)" "$CFG"
    printf '%s\n' '--------------------------------------------------'
    item 1 "$(T m1)"
    item 2 "$(T m2)"
    item 3 "$(T m3)"
    item 4 "$(T m4)"
    item 5 "$(T m5)"
    item 6 "$(T m6)"
    item 7 "$(T m7)"
    item 8 "$(T m8)"
    item 9 "$(T m9)"
    item 10 "$(T m10)"
    item 11 "$(T m11)"
    item 12 "$(T m12)"
    printf '\n'
    item 0 "$(T m0)"
    printf '%s\n' '--------------------------------------------------'
}

# 非交互子命令：twingate <cmd>，无参数时进入菜单。
run_cli() {
    cmd=$1
    shift
    case "$cmd" in
        start)          do_start ;;
        stop)           do_stop ;;
        restart)        do_restart ;;
        status)         do_status ;;
        config)         show_config ;;
        build)          do_build ;;
        certs|cert)     twin_gen_certs ;;
        trust)          twin_install_ca "$@" ;;
        probe)          do_probe ;;
        selftest)       do_local_test ;;
        install)        if [ "${TWIN_INSTALLED:-0}" = 1 ]; then do_install; else sh "$ROOT/scripts/install.sh" "$@"; fi ;;
        uninstall)      if [ "${TWIN_INSTALLED:-0}" = 1 ]; then twin_uninstall "$@"; else sh "$ROOT/scripts/uninstall.sh" "$@"; fi ;;
        menu)           return 0 ;;
        help|-h|--help)
            printf '%s\n' "$(T cli.usage)"
            printf '%s\n' "$(T cli.cmds)"
            printf '%s\n' "$(T cli.help)"
            ;;
        version|-V|--version) printf 'TwinGate (LGPL-2.1-or-later)\n' ;;
        *) printf '%s %s\n' "$(T cli.unknown)" "$cmd" >&2
           printf '%s\n' "$(T cli.cmds)" >&2
           return 1 ;;
    esac
}

main() {
    cd "$ROOT" || exit 1
    load_config

    if [ "$#" -gt 0 ]; then
        case "$1" in
            menu) shift; [ "$#" -eq 0 ] || { printf '%s %s\n' "$(T cli.unknown)" "$*" >&2; exit 1; } ;;
            *) run_cli "$@"; exit $? ;;
        esac
    fi

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
            11) do_install; pause ;;
            12) do_uninstall; pause ;;
            0) printf '%s\n' "$(T bye)"; exit 0 ;;
            '') continue ;;   # 直接回车只是重画菜单，别让手滑退出
            *) printf '%s\n' "$(T err.invalid)"; pause ;;
        esac
    done
}

main "$@"
