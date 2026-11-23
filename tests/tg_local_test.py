#!/usr/bin/env python3
"""TwinGate 离线自测：不访问外网，自动拉起/停止代理，验证协议通路、认证与证书。

运行：python3 tests/tg_local_test.py
可选：--root /path/to/twingate

流程：
  1) 配置渲染（认证开/关，以及上游 parent 的注入规则）
  2) 证书生成、CA 验签、SAN 检查
  3) 六端口拓扑：HTTP/CONNECT/SOCKS5/FTP 明文 + TLS
  4) 认证正向/反向（错误凭据必须被拒绝）
  5) 上游 SOCKS5 链路：流量确实经过上游、上游不可用时不回退直连
  6) 混合单端口拓扑：同一端口跑全部协议

所有目标站都是脚本内置的本地 HTTP 服务，上游 SOCKS5 也是内置的；不需要 example.com，也不需要容器。
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


class UpstreamSocks5:
    """最小 SOCKS5 上游（无认证），记录被要求连接的目标并转发字节。

    用来证明 TwinGate 的 parent 链路真的把流量交给了上游，而不是直连。
    """

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.targets = []
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._accept, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def saw(self, port):
        with self.lock:
            return [t for t in self.targets if t[1] == port]

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._conn, args=(conn,), daemon=True).start()

    @staticmethod
    def _exact(s, n):
        buf = b""
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    @staticmethod
    def _pipe(src, dst):
        try:
            while True:
                chunk = src.recv(65536)
                if not chunk:
                    break
                dst.sendall(chunk)
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.close()
                except OSError:
                    pass

    def _conn(self, conn):
        try:
            head = self._exact(conn, 2)
            if head[0] != 5:
                conn.close()
                return
            self._exact(conn, head[1])
            conn.sendall(b"\x05\x00")          # 不需要认证
            req = self._exact(conn, 4)
            atyp = req[3]
            if atyp == 1:
                host = socket.inet_ntoa(self._exact(conn, 4))
            elif atyp == 3:
                host = self._exact(conn, self._exact(conn, 1)[0]).decode()
            else:
                host = socket.inet_ntop(socket.AF_INET6, self._exact(conn, 16))
            port = int.from_bytes(self._exact(conn, 2), "big")
            with self.lock:
                self.targets.append((host, port))
            remote = socket.create_connection((host, port), 5)
            conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + (0).to_bytes(2, "big"))
            threading.Thread(target=self._pipe, args=(conn, remote), daemon=True).start()
            self._pipe(remote, conn)
        except (OSError, EOFError, ValueError):
            try:
                conn.close()
            except OSError:
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


class DummyFtp:
    """只回 220/331 的假 FTP 服务器，用来判断 ftppr 有没有真的去连目标。"""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.conns = 0
        threading.Thread(target=self._accept, daemon=True).start()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.conns += 1
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    @staticmethod
    def _serve(conn):
        try:
            conn.sendall(b"220 dummy ftp\r\n")
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                if data.upper().startswith(b"USER"):
                    conn.sendall(b"331 dummy need password\r\n")
                else:
                    conn.sendall(b"230 dummy ok\r\n")
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


def ftp_user(port, tls, cafile, target_port):
    """按 ftppr 语义登录：`代理用户:代理密码:ftp用户@服务器:端口`。"""
    s = proxy_socket(port, tls, cafile)
    banner = recv_all(s, 3.0)
    s.sendall(b"USER %s:%s:ftpuser@127.0.0.1:%d\r\n" %
              (USER.encode(), PASS.encode(), target_port))
    reply = recv_all(s, 3.0)
    s.close()
    return banner, reply


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


def test_parent_config(res, root, tmp):
    """parent 行注入、FTP 策略，以及关闭认证时改用 iponly 的兼容处理。"""

    def render(name, extra, check=True):
        out = os.path.join(tmp, name)
        env = os.environ.copy()
        for k in list(env):
            if k.startswith("TWIN_") or k.startswith("TG_"):
                del env[k]
        env.update({"TWIN_CONFIG_PATH": out, "TWIN_LOG_DIR": os.path.join(tmp, "logs")})
        env.update(extra)
        rc = subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out],
                            cwd=root, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.STDOUT).returncode
        if check and rc != 0:
            raise RuntimeError("render-config failed: %s" % name)
        if rc != 0 or not os.path.exists(out):
            return ""
        with open(out, encoding="utf-8") as f:
            return f.read()

    text = render("cfg-parent-url.cfg", {"TWIN_PARENT": "socks5://bob:pw1@10.0.0.9:7891"})
    res.check("config parent URL 形式解析",
              "parent 1000 socks5+ 10.0.0.9 7891 bob pw1" in text and "__TWIN_" not in text,
              text[:120].replace("\n", " "))
    res.check("config parent 下 FTP 默认拒绝",
              "deny * * * *" in text.split("# @service:ftp", 1)[1])

    text = render("cfg-parent-hp.cfg", {"TWIN_PARENT": "127.0.0.1:1080"})
    res.check("config parent host:port 形式解析",
              "parent 1000 socks5+ 127.0.0.1 1080" in text)

    text = render("cfg-parent-ftp.cfg",
                  {"TWIN_PARENT": "1", "TWIN_PARENT_PORT": "1080", "TWIN_PARENT_FTP": "direct"})
    res.check("config parent 且 FTP 直连时保留 ftppr",
              "deny * * * *" not in text and "ftppr" in text)

    text = render("cfg-parent-noauth.cfg", {"TWIN_PARENT": "1", "TWIN_AUTH": "0"})
    res.check("config parent + 关闭认证改用 auth iponly",
              "auth iponly" in text and "auth none" not in text and
              "parent 1000 socks5+ 127.0.0.1 1080" in text)

    text = render("cfg-parent-bad.cfg", {"TWIN_PARENT": "1", "TWIN_PARENT_PORT": "0"}, check=False)
    res.check("config parent 非法端口被拒绝", "parent 1000" not in text)

    text = render("cfg-parent-v6.cfg", {"TWIN_PARENT": "socks5://[::1]:7891"})
    res.check("config parent IPv6 URL 形式解析",
              "parent 1000 socks5+ ::1 7891" in text, text[:80].replace("\n", " "))

    text = render("cfg-parent-v6bare.cfg", {"TWIN_PARENT": "::1"})
    res.check("config parent 裸 IPv6 取默认端口",
              "parent 1000 socks5+ ::1 1080" in text, text[:80].replace("\n", " "))


def test_tui_env(res, root, tmp):
    """tui.env（控制台保存的配置）必须生效，且显式环境变量优先于它。"""
    tui = os.path.join(tmp, "tui.env")
    with open(tui, "w", encoding="utf-8") as f:
        f.write("# test\n")
        f.write("TWIN_HTTP_PLAIN='41999'\n")
        f.write("TWIN_PARENT='1'\n")
        f.write("TWIN_PARENT_PORT='11080'\n")

    def render(name, extra):
        out = os.path.join(tmp, name)
        env = os.environ.copy()
        for k in list(env):
            if k.startswith("TWIN_") or k.startswith("TG_"):
                del env[k]
        env.update({
            "TWIN_CONFIG_PATH": out,
            "TWIN_LOG_DIR": os.path.join(tmp, "logs"),
            "TWIN_TUI_ENV": tui,
        })
        env.update(extra)
        subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out],
                       cwd=root, env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.STDOUT, check=True)
        with open(out, encoding="utf-8") as f:
            return f.read()

    text = render("cfg-tui.cfg", {})
    res.check("tui.env 的端口生效", "proxy -p41999" in text)
    res.check("tui.env 的上游生效", "parent 1000 socks5+ 127.0.0.1 11080" in text)

    text = render("cfg-tui-env.cfg", {"TWIN_HTTP_PLAIN": "42001"})
    res.check("显式环境变量压过 tui.env", "proxy -p42001" in text and "proxy -p41999" not in text)

    text = render("cfg-tui-bind.cfg", {"TWIN_TUI_ENV": os.path.join(tmp, "no-such.env"),
                                       "TWIN_PLAIN_BIND": "0.0.0.0"})
    res.check("关闭 tui.env 后端口仍按环境变量渲染", "proxy -p31808" in text)


def test_parent_chain(res, root, base_env, ca, origin_port, ports):
    """真实链路：所有协议都必须经过上游 SOCKS5，且上游不可用时不得回退直连。"""
    up = UpstreamSocks5().start()
    fake_ftp = DummyFtp()
    env = base_env.copy()
    env.update({
        "TWIN_SERVICES": "http-plain,socks-plain,ftp-plain",
        "TWIN_HTTP_PLAIN": str(ports[0]),
        "TWIN_SOCKS_PLAIN": str(ports[1]),
        "TWIN_FTP_PLAIN": str(ports[2]),
        "TWIN_PARENT": "1",
        "TWIN_PARENT_HOST": "127.0.0.1",
        "TWIN_PARENT_PORT": str(up.port),
    })
    dead_env = None
    try:
        out = sh(root, "scripts/start.sh", env, check=False)
        up_ok = all(wait_port(p, 5) for p in ports[:3])
        res.check("上游链路启动", up_ok, out[-300:])
        if not up_ok:
            return

        ok, data = http_via(ports[0], origin_port, False, ca)
        res.check("HTTP 经上游 SOCKS5", ok and MARKER in data and bool(up.saw(origin_port)),
                  data[:120])

        ok, data = connect_via(ports[0], origin_port, False, ca)
        res.check("CONNECT 经上游 SOCKS5", ok and bool(up.saw(origin_port)), data[:120])

        ok, data = socks_via(ports[1], origin_port, False, ca)
        res.check("SOCKS5 经上游 SOCKS5", ok and bool(up.saw(origin_port)), data[:120])

        banner, reply = ftp_user(ports[2], False, ca, fake_ftp.port)
        res.check("上游开启时 FTP 登录被拒绝",
                  banner.startswith(b"220") and not reply and fake_ftp.conns == 0,
                  repr(banner) + repr(reply))

        st = sh(root, "scripts/status.sh", env, check=False)
        res.check("status 显示上游信息", "=== PARENT ===" in st and "socks5+" in st, st[:160])

        sh(root, "scripts/stop.sh", env, check=False)
        time.sleep(0.3)

        # 上游端口没人监听：必须直接失败，不能偷偷直连
        dead_env = base_env.copy()
        dead_env.update({
            "TWIN_SERVICES": "http-plain,ftp-plain",
            "TWIN_HTTP_PLAIN": str(ports[3]),
            "TWIN_FTP_PLAIN": str(ports[2]),
            "TWIN_PARENT": "127.0.0.1:%d" % free_ports(1)[0],
            "TWIN_PARENT_FTP": "direct",
        })
        out = sh(root, "scripts/start.sh", dead_env, check=False)
        started = wait_port(ports[3], 5)
        res.check("上游不可用时不阻塞启动", started, out[-300:])
        if started:
            ok, data = http_via(ports[3], origin_port, False, ca)
            res.check("上游不可用时不回退直连", not ok and MARKER not in data, data[:120])
            before = fake_ftp.conns
            banner, reply = ftp_user(ports[2], False, ca, fake_ftp.port)
            res.check("TWIN_PARENT_FTP=direct 时 FTP 可登录",
                      banner.startswith(b"220") and reply.startswith(b"331") and
                      fake_ftp.conns > before,
                      repr(banner) + repr(reply))
    finally:
        if dead_env is not None:
            sh(root, "scripts/stop.sh", dead_env, check=False)
        sh(root, "scripts/stop.sh", env, check=False)
        fake_ftp.close()
        up.close()


def test_config(res, root, tmp):
    # 清掉外部环境里的 TWIN_*，否则开发者本机导出的 TWIN_AUTH 等会让断言失真。
    def base_env():
        env = os.environ.copy()
        for k in list(env):
            if k.startswith("TWIN_") or k.startswith("TG_"):
                del env[k]
        return env

    out1 = os.path.join(tmp, "cfg-on.cfg")
    e1 = base_env()
    e1.update({"TWIN_CONFIG_PATH": out1, "TWIN_LOG_DIR": os.path.join(tmp, "logs")})
    subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out1],
                   cwd=root, env=e1,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=True)
    text = open(out1, encoding="utf-8").read()
    res.check("config auth-on 渲染",
              "users twingate:CL:twingate123" in text and "auth strong" in text and
              "allow twingate" in text and "__TWIN_" not in text)

    out2 = os.path.join(tmp, "cfg-off.cfg")
    e2 = base_env()
    e2.update({"TWIN_AUTH": "0", "TWIN_CONFIG_PATH": out2,
               "TWIN_LOG_DIR": os.path.join(tmp, "logs")})
    subprocess.run(["sh", os.path.join(root, "scripts/render-config.sh"), out2],
                   cwd=root, env=e2, stdout=subprocess.DEVNULL,
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
        test_parent_config(res, root, tmp)
        test_tui_env(res, root, tmp)
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

        # 上游 SOCKS5（parent 链式出口）：预留 4 个端口
        test_parent_chain(res, root, base_env, ca, origin_port, ports[8:12])

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
