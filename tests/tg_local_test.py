#!/usr/bin/env python3
"""TwinGate 离线自测：不访问外网，自动拉起/停止代理，验证协议通路、认证与证书。

运行：python3 tests/tg_local_test.py
可选：--root /path/to/twingate

流程：
  1) 配置渲染（认证开/关）
  2) 证书生成、CA 验签、SAN 检查
  3) 六端口拓扑：HTTP/CONNECT/SOCKS5/FTP 明文 + TLS
  4) 认证正向/反向（错误凭据必须被拒绝）
  5) 混合单端口拓扑：同一端口跑全部协议

所有目标站都是脚本内置的本地 HTTP 服务；不需要 example.com，也不需要容器。
"""
import argparse
import base64
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER = b"TG-LOCAL-OK"
USER = "localuser"
PASS = "localpass123"


class OriginHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(MARKER)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(MARKER)

    def log_message(self, *_args):
        pass


class Results:
    def __init__(self):
        self.items = []

    def check(self, name, ok, detail=""):
        ok = bool(ok)
        self.items.append((name, ok, detail))
        line = ("PASS " if ok else "FAIL ") + name
        if detail:
            line += " :: " + str(detail)[:300]
        print(line, flush=True)
        return ok

    def finish(self):
        failed = [x for x in self.items if not x[1]]
        print("\n%d/%d PASS" % (len(self.items) - len(failed), len(self.items)), flush=True)
        return 1 if failed else 0


def free_ports(n):
    socks = []
    for _ in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        socks.append(s)
    ports = [s.getsockname()[1] for s in socks]
    for s in socks:
        s.close()
    return ports


def sh(root, script, env, check=True):
    p = subprocess.run(["sh", os.path.join(root, script)], env=env, cwd=root,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    out = p.stdout.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise RuntimeError("%s failed (%d):\n%s" % (script, p.returncode, out))
    return out


def wait_port(port, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), 0.3)
            s.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def recv_all(s, timeout=5.0):
    s.settimeout(timeout)
    data = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    except (socket.timeout, TimeoutError):
        pass
    return data


def recv_some(s, n, timeout=3.0):
    s.settimeout(timeout)
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            break
        data += chunk
    return data


def recv_headers(s, timeout=5.0):
    s.settimeout(timeout)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf


def proxy_socket(port, tls, cafile):
    s = socket.create_connection(("127.0.0.1", port), 5)
    if tls:
        ctx = ssl.create_default_context(cafile=cafile)
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
        s = ctx.wrap_socket(s, server_hostname="localhost")
    return s


def basic(port, user, password):
    if user is None:
        return ""
    tok = base64.b64encode(("%s:%s" % (user, password or "")).encode()).decode()
    return "Proxy-Authorization: Basic %s\r\n" % tok


def http_via(port, origin, tls, cafile, user=USER, password=PASS, expect=200):
    s = proxy_socket(port, tls, cafile)
    req = ("GET http://127.0.0.1:%d/ HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s"
           "Proxy-Connection: close\r\nConnection: close\r\n\r\n") % (
               origin, origin, basic(port, user, password))
    s.sendall(req.encode())
    data = recv_all(s)
    s.close()
    status_ok = data.startswith(("HTTP/1.1 %d" % expect).encode()) or \
                data.startswith(("HTTP/1.0 %d" % expect).encode())
    return status_ok, data


def connect_via(port, origin, tls, cafile, user=USER, password=PASS):
    s = proxy_socket(port, tls, cafile)
    s.sendall(("CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n" %
               (origin, origin, basic(port, user, password))).encode())
    head = recv_headers(s)
    s.close()
    return head.startswith(b"HTTP/1.1 200") or head.startswith(b"HTTP/1.0 200"), head


def socks_via(port, origin, tls, cafile, user=USER, password=PASS, no_auth=False):
    s = proxy_socket(port, tls, cafile)
    if no_auth:
        s.sendall(b"\x05\x01\x00")
    else:
        s.sendall(b"\x05\x02\x00\x02")
    greet = recv_some(s, 2)
    if len(greet) < 2 or greet[0] != 5:
        return False, "greeting=" + repr(greet)
    if greet[1] == 255:
        return False, "no acceptable auth method"
    if greet[1] == 2:
        if no_auth:
            return False, "server selected auth unexpectedly"
        u, p = user.encode(), password.encode()
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        aret = recv_some(s, 2)
        if aret != b"\x01\x00":
            return False, "auth rejected=" + repr(aret)
    elif greet[1] != 0:
        return False, "method=" + repr(greet[1])
    s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + origin.to_bytes(2, "big"))
    reply = recv_some(s, 10)
    if len(reply) < 2 or reply[1] != 0:
        return False, "connect reply=" + repr(reply)
    s.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").encode())
    data = recv_all(s)
    s.close()
    return data.startswith(b"HTTP/1.") and MARKER in data, "reply=" + repr(reply) + " data=" + repr(data[:80])


def ftp_banner(port, tls, cafile):
    s = proxy_socket(port, tls, cafile)
    banner = recv_all(s, 4.0)
    s.close()
    return banner.startswith(b"220"), banner[:120]


def clean_env(root, tmp, cert_dir, run_dir, log_dir, runtime_dir):
    env = os.environ.copy()
    for k in list(env):
        if k.startswith("TWIN_") or k.startswith("TG_"):
            del env[k]
    env.update({
        "TWIN_CERT_DIR": cert_dir,
        "TWIN_RUN_DIR": run_dir,
        "TWIN_LOG_DIR": log_dir,
        "TWIN_RUNTIME_DIR": runtime_dir,
        "TWIN_AUTH": "1",
        "TWIN_AUTH_USER": USER,
        "TWIN_AUTH_PASS": PASS,
        "TWIN_PLAIN_BIND": "127.0.0.1",
    })
    return env


def test_config(res, root, tmp):
    out1 = os.path.join(tmp, "cfg-on.cfg")
    subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out1],
                   cwd=root, env={**os.environ, "TWIN_CONFIG_PATH": out1},
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=True)
    text = open(out1, encoding="utf-8").read()
    res.check("config auth-on 渲染",
              "users twingate:CL:twingate123" in text and "auth strong" in text and
              "allow twingate" in text and "__TWIN_" not in text)

    out2 = os.path.join(tmp, "cfg-off.cfg")
    e = os.environ.copy(); e["TWIN_AUTH"] = "0"
    subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out2],
                   cwd=root, env=e, stdout=subprocess.DEVNULL,
                   stderr=subprocess.STDOUT, check=True)
    text = open(out2, encoding="utf-8").read()
    res.check("config auth-off 渲染", "auth none" in text and "users " not in text and
              "allow * * * *" in text and "__TWIN_" not in text)


def test_certs(res, root, cert_dir):
    if not shutil.which("openssl"):
        res.check("openssl 可用", False, "未安装 openssl，跳过证书检查")
        return
    subprocess.run(["sh", os.path.join(root, "scripts/gen-certs.sh")], cwd=root,
                   env={**os.environ, "TWIN_CERT_DIR": cert_dir},
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=True)
    ca = os.path.join(cert_dir, "ca.crt")
    leaf = os.path.join(cert_dir, "server.crt")
    v = subprocess.run(["openssl", "verify", "-CAfile", ca, leaf],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    res.check("CA 验签服务器证书", v.returncode == 0, v.stdout.decode().strip())

    san = subprocess.run(["openssl", "x509", "-in", leaf, "-noout", "-ext", "subjectAltName"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode()
    res.check("证书 SAN 含 localhost/127.0.0.1",
              "localhost" in san and "127.0.0.1" in san, san.strip().replace("\n", " "))

    ctx = ssl.create_default_context(cafile=ca)
    try:
        with open(os.path.join(cert_dir, "server-chain.crt"), "rb") as f:
            ctx.load_verify_locations(cadata=f.read().decode())
        res.check("Python 可加载 CA 与证书链", True)
    except Exception as exc:
        res.check("Python 可加载 CA 与证书链", False, repr(exc))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    res = Results()
    tmp = tempfile.mkdtemp(prefix="tg-selftest-")
    origin = ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
    origin_port = origin.server_address[1]
    threading.Thread(target=origin.serve_forever, daemon=True).start()

    cert_dir = os.path.join(tmp, "certs")
    run_dir = os.path.join(tmp, "run")
    log_dir = os.path.join(tmp, "logs")
    runtime_dir = os.path.join(tmp, "bin")
    for d in (cert_dir, run_dir, log_dir, runtime_dir):
        os.makedirs(d, exist_ok=True)

    # 12 个端口：6 传统 + 2 混合 + 4 预留（避免碰撞）
    ports = free_ports(12)
    (hp, ht, sp, st, fp, ft, mp, mt) = ports[:8]
    base_env = None
    mixed_env = None

    try:
        test_config(res, root, tmp)
        test_certs(res, root, cert_dir)
        if not os.path.exists(os.path.join(cert_dir, "ttp.env")):
            print("证书不可用，终止后续网络测试", flush=True)
            return 1

        base_env = clean_env(root, tmp, cert_dir, run_dir, log_dir, runtime_dir)
        base_env.update({
            "TWIN_SERVICES": "http-plain,http-tls,socks-plain,socks-tls,ftp-plain,ftp-tls",
            "TWIN_HTTP_PLAIN": str(hp), "TWIN_HTTP_TLS": str(ht),
            "TWIN_SOCKS_PLAIN": str(sp), "TWIN_SOCKS_TLS": str(st),
            "TWIN_FTP_PLAIN": str(fp), "TWIN_FTP_TLS": str(ft),
        })

        def start(env):
            return sh(root, "scripts/start.sh", env, check=False)

        def stop(env):
            sh(root, "scripts/stop.sh", env, check=False)
            time.sleep(0.3)

        out = start(base_env)
        res.check("六端口服务启动", all(wait_port(p, 5) for p in (hp, ht, sp, st, fp, ft)), out[-300:])
        ca = os.path.join(cert_dir, "ca.crt")

        for name, port_plain, port_tls in (
            ("http", hp, ht), ("connect", hp, ht),
            ("socks5", sp, st), ("ftp", fp, ft),
        ):
            for tls, port in ((False, port_plain), (True, port_tls)):
                tag = name + "-" + ("tls" if tls else "plain")
                if name == "http":
                    ok, data = http_via(port, origin_port, tls, ca)
                    ok = ok and MARKER in data
                elif name == "connect":
                    ok, data = connect_via(port, origin_port, tls, ca)
                elif name == "socks5":
                    ok, data = socks_via(port, origin_port, tls, ca)
                else:
                    ok, data = ftp_banner(port, tls, ca)
                res.check(tag + " 认证通过", ok, data[:120])

        ok, data = http_via(hp, origin_port, False, ca, user=None)
        res.check("HTTP 无认证被拒绝", not ok, data[:120])
        ok, data = http_via(hp, origin_port, False, ca, password="wrongpass")
        res.check("HTTP 错误密码被拒绝", not ok, data[:120])
        ok, data = socks_via(sp, origin_port, False, ca, no_auth=True)
        res.check("SOCKS 无认证被拒绝", not ok, data[:120])
        ok, data = http_via(ht, origin_port, True, ca, password="wrongpass")
        res.check("HTTP-TLS 错误密码被拒绝", not ok, data[:120])

        stop(base_env)

        # 混合单端口拓扑
        mixed_env = base_env.copy()
        mixed_env["TWIN_SERVICES"] = "mixed-plain,mixed-tls"
        mixed_env["TWIN_MUX_PLAIN"] = str(mp)
        mixed_env["TWIN_MIXED_TLS"] = str(mt)
        out = start(mixed_env)
        res.check("混合端口启动", wait_port(mp, 5) and wait_port(mt, 5), out[-300:])

        for tls, port in ((False, mp), (True, mt)):
            tag = "mixed-" + ("tls" if tls else "plain")
            ok, data = http_via(port, origin_port, tls, ca)
            res.check(tag + " HTTP", ok and MARKER in data, data[:120])
            ok, data = socks_via(port, origin_port, tls, ca)
            res.check(tag + " SOCKS5", ok, data[:120])
            ok, data = ftp_banner(port, tls, ca)
            res.check(tag + " FTP 220", ok, data[:120])
        stop(mixed_env)
    finally:
        for env in (base_env, mixed_env):
            if env:
                try:
                    sh(root, "scripts/stop.sh", env, check=False)
                except Exception:
                    pass
        origin.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)

    return res.finish()


if __name__ == "__main__":
    sys.exit(main())
