#!/usr/bin/env python3
"""TwinGate 协议探测：对明文端口或 TLS 端口分别验证 HTTP / CONNECT / SOCKS5 / FTP。

用法示例：
  python3 tests/tg_probe.py --mode all --tls
  python3 tests/tg_probe.py --mode http --plain --target http://example.com/
  python3 tests/tg_probe.py --mode all --user alice --pass s3cret   # 自定义凭据
  python3 tests/tg_probe.py --mode all --no-auth                    # 验证认证应被拒绝

默认从 TWIN_AUTH / TWIN_AUTH_USER / TWIN_AUTH_PASS 环境变量读取认证设置，
与 config/ports.env 保持一致；目标站需要外网，离线自测请用 tg_local_test.py。
"""
import argparse
import base64
import os
import socket
import ssl
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--target", default="example.com")
parser.add_argument("--http-tls", type=int, default=18080)
parser.add_argument("--http-plain", type=int, default=31808)
parser.add_argument("--socks-tls", type=int, default=11080)
parser.add_argument("--socks-plain", type=int, default=31080)
parser.add_argument("--ftp-tls", type=int, default=10021)
parser.add_argument("--ftp-plain", type=int, default=30021)
parser.add_argument("--mux-plain", type=int, default=37890, help="混合模式明文端口")
parser.add_argument("--mixed-tls", type=int, default=17890, help="混合模式 TLS 端口")
parser.add_argument("--mixed", action="store_true", help="所有协议都走同一个混合端口")
parser.add_argument("--mode", choices=["http", "connect", "socks", "ftp", "all"], default="all")
parser.add_argument("--tls", action="store_true")
parser.add_argument("--plain", action="store_true")
parser.add_argument("--user", default=None, help="代理用户名（默认取 TWIN_AUTH_USER）")
parser.add_argument("--pass", dest="password", default=None, help="代理密码（默认取 TWIN_AUTH_PASS）")
parser.add_argument("--no-auth", action="store_true", help="不发送代理认证")
parser.add_argument("--verify", action="store_true",
                    help="校验服务器证书（需先安装 ca.crt；默认跳过以兼容容器内未装 CA 的场景）")
parser.add_argument("--timeout", type=float, default=6.0)
args = parser.parse_args()

if not (args.tls or args.plain):
    args.tls = args.plain = True

if args.mixed:
    args.http_plain = args.socks_plain = args.ftp_plain = args.mux_plain
    args.http_tls = args.socks_tls = args.ftp_tls = args.mixed_tls

# 认证设置：显式 --user/--pass 优先，其次环境变量，最后与 config/ports.env 一致的默认值。
AUTH_ON = (not args.no_auth) and (
    args.user is not None or args.password is not None or
    os.environ.get("TWIN_AUTH", "1") != "0"
)
USER = args.user if args.user is not None else os.environ.get("TWIN_AUTH_USER", "twingate")
PASS = args.password if args.password is not None else os.environ.get("TWIN_AUTH_PASS", "twingate123")


def connect(port, tls):
    s = socket.create_connection((args.host, port), args.timeout)
    if tls:
        ctx = ssl.create_default_context()
        if not (args.verify or os.environ.get("TG_PROBE_VERIFY") == "1"):
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname="localhost")
    return s


def proxy_auth_header():
    if not AUTH_ON:
        return ""
    token = base64.b64encode(("%s:%s" % (USER, PASS)).encode()).decode()
    return "Proxy-Authorization: Basic %s\r\n" % token


def recv_retry(s, n):
    """首次读取超时时，用翻倍超时再读一次，避免冷启动/网络抖动误报 FAIL。"""
    try:
        return s.recv(n)
    except (socket.timeout, TimeoutError):
        s.settimeout(args.timeout * 2)
        return s.recv(n)


def snippet(data):
    return data[:160].decode("utf-8", "replace").replace("\r", "\\r").replace("\n", "\\n")


def report(name, ok, detail):
    print(("PASS " if ok else "FAIL ") + name + " :: " + detail)
    return ok


def http_proxy(tls):
    port = args.http_tls if tls else args.http_plain
    try:
        s = connect(port, tls)
        req = ("GET http://%s/ HTTP/1.1\r\nHost: %s\r\n%s"
               "Proxy-Connection: close\r\nConnection: close\r\n\r\n") % (
                   args.target, args.target, proxy_auth_header())
        s.sendall(req.encode())
        data = recv_retry(s, 4096)
        s.close()
        # 407 是代理拒绝认证，不能算通路 PASS
        ok = data.startswith(b"HTTP/") and not data.startswith(
            (b"HTTP/1.1 407", b"HTTP/1.0 407"))
        return report("http" + ("-tls" if tls else "-plain"), ok, snippet(data))
    except Exception as e:
        return report("http" + ("-tls" if tls else "-plain"), False, repr(e))


def http_connect(tls):
    port = args.http_tls if tls else args.http_plain
    try:
        s = connect(port, tls)
        s.sendall(("CONNECT %s:80 HTTP/1.1\r\nHost: %s:80\r\n%s\r\n" %
                   (args.target, args.target, proxy_auth_header())).encode())
        data = recv_retry(s, 4096)
        s.close()
        return report("connect" + ("-tls" if tls else "-plain"),
                      data.startswith(b"HTTP/1.1 200") or data.startswith(b"HTTP/1.0 200"),
                      snippet(data))
    except Exception as e:
        return report("connect" + ("-tls" if tls else "-plain"), False, repr(e))


def socks5(tls):
    port = args.socks_tls if tls else args.socks_plain
    try:
        s = connect(port, tls)
        # 认证开启时同时声明 no-auth 与 RFC1929 username/password，由服务端选择。
        if AUTH_ON:
            s.sendall(b"\x05\x02\x00\x02")
        else:
            s.sendall(b"\x05\x01\x00")
        greeting = recv_retry(s, 2)
        if len(greeting) < 2 or greeting[0] != 5:
            return report("socks5" + ("-tls" if tls else "-plain"),
                          False, "greeting=" + repr(greeting))
        if greeting[1] == 2:
            u, p = USER.encode(), PASS.encode()
            s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
            aret = recv_retry(s, 2)
            if aret != b"\x01\x00":
                return report("socks5" + ("-tls" if tls else "-plain"),
                              False, "auth rejected=" + repr(aret))
        elif greeting[1] != 0:
            return report("socks5" + ("-tls" if tls else "-plain"),
                          False, "method=" + repr(greeting[1]))
        host = socket.gethostbyname(args.target)
        ip = socket.inet_aton(host)
        req = b"\x05\x01\x00\x01" + ip + (80).to_bytes(2, "big")
        s.sendall(req)
        reply = recv_retry(s, 10)
        s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" %
                   args.target).encode())
        data = recv_retry(s, 4096)
        s.close()
        return report("socks5" + ("-tls" if tls else "-plain"),
                      len(reply) >= 2 and reply[1] == 0 and data.startswith(b"HTTP/"),
                      "reply=" + repr(reply) + " data=" + snippet(data))
    except Exception as e:
        return report("socks5" + ("-tls" if tls else "-plain"), False, repr(e))


def ftp(tls):
    port = args.ftp_tls if tls else args.ftp_plain
    try:
        s = connect(port, tls)
        banner = recv_retry(s, 4096)
        s.close()
        # ftppr 的 USER 阶段会去解析并连接真实 FTP 服务器，结果依赖外部网络，
        # 因此连通性判定只看 220 横幅（足以证明 TLS/明文到 ftppr 的通路是通的）。
        return report("ftp" + ("-tls" if tls else "-plain"),
                      banner.startswith(b"220"), "banner=" + snippet(banner))
    except Exception as e:
        return report("ftp" + ("-tls" if tls else "-plain"), False, repr(e))


ok = True
for tls in (True, False):
    if tls and not args.tls:
        continue
    if not tls and not args.plain:
        continue
    if args.mode in ("http", "all"):
        ok &= http_proxy(tls)
    if args.mode in ("connect", "all"):
        ok &= http_connect(tls)
    if args.mode in ("socks", "all"):
        ok &= socks5(tls)
    if args.mode in ("ftp", "all"):
        ok &= ftp(tls)

sys.exit(0 if ok else 1)
