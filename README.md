# TwinGate

本地代理网关：**3proxy 做协议核心，ttp 做 TLS 前端**。支持 HTTP、SOCKS4/5、FTP 代理，并为每个协议提供 TLS 加密入口；默认开启用户名/密码认证，方便直接给局域网设备使用。可在普通 Linux 主机上运行，也可用于 x86_64 ReDroid 容器（容器内需以 root 运行代理）。

英文文档见 [README.en.md](README.en.md)。

## 架构

```
客户端 ──TLS──> ttp (BearSSL, 每协议一个进程) ──明文──> 3proxy (127.0.0.1) ──> 目标网络
客户端 ──明文─> 3proxy <TWIN_PLAIN_BIND>:<plain port> ──────────────────────> 目标网络
                         （默认 127.0.0.1，可开关改为 0.0.0.0）
                 认证在 3proxy 层完成：HTTP Basic / SOCKS5 用户名密码 / FTP USER-PASS
                 ttp 只透传字节，所以 TLS 与明文入口的认证行为一致
```

- **3proxy**：0.9 LTS（固定提交 `4f7a611`），提供 HTTP proxy / HTTPS CONNECT / SOCKS4/5 / FTP proxy(`ftppr`)。构建不需要 OpenSSL 开发库。
- **ttp**：固定提交 `24f055f`，使用 BearSSL（固定提交 `7bea48e`），仅做 TLS 终止并把明文转发到 `127.0.0.1:<plain port>`。
- ttp 原生只支持单个监听端口 → 每个协议启动一个 ttp 实例。
- 明文服务默认只绑定 `127.0.0.1`；TLS 端口由 ttp 绑定 `0.0.0.0`（上游限制，如需收窄请用主机/容器的网络或防火墙）。
- 如需让主机/局域网设备直连明文端口，设 `TWIN_PLAIN_BIND=0.0.0.0`；此时认证仍然生效。

## 端口（可用 config/ports.env 覆盖）

| 协议 | TLS 入口 (ttp) | 明文入口 (3proxy, 默认仅本机) |
| --- | --- | --- |
| HTTP / CONNECT | 18080 | 31808 |
| SOCKS4/5 | 11080 | 31080 |
| FTP proxy | 10021 | 30021 |
| 混合 | 17890 | 37890 |

## 单端口混合模式（可选）

默认仍是上表的 6 端口拓扑。设 `TWIN_MIXED=1` 后改为 **2 个端口**：

| 用途 | 端口 | 说明 |
| --- | --- | --- |
| TLS 入口 | 17890（`TWIN_MIXED_TLS`） | 单个 ttp 实例 |
| 明文入口 | 37890（`TWIN_MUX_PLAIN`） | `tgmux` 协议分发器 |

HTTP / CONNECT / SOCKS5 / FTP 全部复用这两个端口。`tgmux` 靠首字节分发：`0x04/0x05` → SOCKS，`USER`/`OPEN` → FTP，其余 → HTTP；若客户端在 `TWIN_MUX_PEEK_MS`（默认 500ms）内不发数据，则按 FTP 处理，因为 `ftppr` 会先发 220 横幅。

```sh
sh scripts/stop.sh
TWIN_MIXED=1 sh scripts/start.sh
python3 tests/tg_probe.py --mixed --mode all --target example.com
```

### 自定义开放哪些端口

`TWIN_SERVICES` 是逗号分隔的服务清单，决定实际启动哪些监听端口。可选值：

```
http-tls   http-plain
socks-tls  socks-plain
ftp-tls    ftp-plain
mixed-tls  mixed-plain
```

不写时保持原有行为：`TWIN_MIXED=1` 开两个混合端口，否则开六个传统端口。只开两个混合端口：

```sh
TWIN_SERVICES=mixed-tls,mixed-plain TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
```

每个协议明文后端的绑定地址可单独覆盖：`TWIN_HTTP_BIND` / `TWIN_SOCKS_BIND` / `TWIN_FTP_BIND`，默认继承 `TWIN_PLAIN_BIND`。被关闭的服务不会生成对应 3proxy 配置段；仍开放的 TLS 服务，其明文后端只在 `127.0.0.1` 监听供 ttp 转发。

## 用户名/密码认证

**默认开启**，开箱即用的凭据是：

```
用户名：twingate
密码：  twingate123
```

这是公开默认值，**给局域网设备用之前请务必修改**。两种方式：

```sh
# 环境变量（可写进自己的启动脚本）
TWIN_AUTH_USER=myuser TWIN_AUTH_PASS='MyPassw0rd' sh scripts/start.sh

# 或：tgmenu.sh -> 配置 -> 7) 认证设置（会保存到 config/tui.env）
```

不需要认证时关闭：

```sh
TWIN_AUTH=0 sh scripts/start.sh
```

说明：

- 支持 HTTP 代理的 `Proxy-Authorization: Basic`、SOCKS5 的 RFC1929 用户名密码；FTP 代理按 3proxy `ftppr` 语义使用 `USER`/`PASS`。
- 认证由 3proxy 执行，所以 TLS 入口和明文入口行为一致；ttp 不解析应用层协议。
- 用户名/密码只允许字母、数字和 `. _ @ -`（3proxy 配置格式限制）。
- `tests/tg_probe.py` 会自动读取 `TWIN_AUTH*` 配置发送凭据；手工测试可用 `--user` / `--pass`，或用 `--no-auth` 验证拒绝行为。
- FTP 代理的认证与真实 FTP 登录是两回事；离线自测只验证 220 通路，完整 FTP 登录请在实际环境验证。

## 证书信任（信任一次即可）

`scripts/gen-certs.sh` 会生成**本地 CA + 服务器证书链**，SAN 自动包含 `localhost`、`127.0.0.1` 以及生成时在机器上检测到的所有 IPv4 地址。客户端只需要导入一张 `run/certs/ca.crt`，之后连接 TLS 端口不再需要 `--insecure`。

```sh
sh scripts/gen-certs.sh                  # 生成/更新，CA 会复用
sh scripts/install-ca.sh                 # Linux/Termux/macOS/Windows 自动安装
python3 tests/tg_probe.py --tls --mode all --verify   # 校验证书的连接测试
```

如果客户端实际连接用的是另一个 IP 或域名，追加后重新生成即可（CA 不变，客户端无需重新导入）：

```sh
TWIN_CERT_IPS="192.168.1.50" TWIN_CERT_DNS="twingate.local" sh scripts/gen-certs.sh
```

Android/ReDroid 需在设置里手工安装 CA；跨平台步骤与排错见 **[CERTS.md](CERTS.md)**。未安装 CA 的环境下，探测脚本默认跳过校验，可用 `--verify` 或 TUI「配置 → 探测设置 → 证书校验」打开。

## 目录

- `scripts/fetch-vendor.sh` — 拉取并固定上游版本
- `scripts/build.sh` — 构建，产物在 `dist/`（`3proxy`, `ttp`, `tgmux`）
- `src/tgmux.c` — 单端口混合模式的协议分发器
- `scripts/gen-certs.sh` — 生成本地 CA + 服务器证书链 + `run/certs/ttp.env`
- `scripts/install-ca.sh` — 把 `ca.crt` 安装进当前系统信任库
- `scripts/render-config.sh` — 由模板生成 `run/3proxy.cfg`（含认证开关）
- `scripts/start.sh` / `stop.sh` / `status.sh` — 进程管理
- `scripts/probe-env.sh` — 容器内环境探测（回传用）
- `tgmenu.sh` — 纯 sh 文本控制台
- `config/tui.env` — 控制台保存的配置与凭据（首次运行自动生成，不入库）
- `tests/tg_probe.py` — 需要目标站可达的协议探测
- `tests/tg_local_test.py` — 不依赖外网的本地自测
- `CERTS.md` — 证书说明

## 文本控制台（推荐）

不用记 `sh scripts/xxx.sh`，也不需要 `make`。Linux 主机上普通用户即可运行；在 ReDroid 容器里运行控制台时，**必须以 root 身份启动代理**（`adb shell` 后 `su`，或 Termux 里先 `su`）：

```sh
cd /path/to/this/repo
su                 # 或：adb shell 后执行 su
id -u              # 容器内必须是 0
sh tgmenu.sh
```

> **仅限 Android/ReDroid 容器：非 root 下会“假成功”。** 用户实测：Termux 里 `su` 后启动主机可以连；`exit` 回普通用户再启动，`status.sh` 仍显示 `OK` / `LISTEN`，但主机连不上。这是 Android 按 UID 限制应用套接字入站连接导致的。容器内遇到“状态正常但主机不通”时，**先检查 `id -u` 是否为 0**。宿主机普通 Linux 没有这个限制。

纯 POSIX sh，只依赖 mksh/toybox。菜单包含：启动/停止/重启/状态；服务开关、8 个端口、绑定地址、认证设置、探测设置；重新构建；证书生成；需要外网的探测；**不依赖外网的本地自测**；证书信任说明。

控制台会按系统 locale 自动选择**简体中文或英文**（只支持这两种）；可用 `TWIN_UI_LANG=zh` 或 `TWIN_UI_LANG=en` 覆盖，也可在「配置 → 9) 界面语言」里切换并保存到 `config/tui.env`。

## 快速开始

```sh
sh scripts/fetch-vendor.sh
sh scripts/build.sh          # 需要 cc/make；容器内构建得到 bionic 版，Linux 主机上直接构建即可
sh scripts/gen-certs.sh      # 需要 openssl，可在宿主机执行后把 run/certs 拷进容器
sh scripts/install-ca.sh     # 客户端信任 ca.crt（可选但推荐）
sh scripts/start.sh          # 首次启动会提示修改默认凭据
sh scripts/status.sh
sh scripts/stop.sh
```

`vendor/` 不入库（约 24 MB 上游源码）。克隆仓库后先执行 `sh scripts/fetch-vendor.sh` 拉取固定提交。

同步源码到 ReDroid 容器：

```sh
sh push.sh                              # 默认连第一个 adb 设备
ADB_SERIAL=localhost:5555 sh push.sh    # 多设备时指定序列号
```

推送的 zip 不含 `dist/`、私钥、`ttp.env` 和 `config/tui.env`，也不会删除容器里的项目目录，容器内已构建的二进制、证书和本地配置不会被覆盖。

环境变量覆盖示例：

```sh
CC=clang JOBS=2 TWIN_3PROXY_LIBS='' sh scripts/build.sh
TWIN_HTTP_TLS=28080 sh scripts/start.sh
TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
TWIN_MIXED=1 sh scripts/start.sh
TWIN_AUTH=0 sh scripts/start.sh                            # 关闭认证
TWIN_RUN_DIR=/tmp/tg-run sh scripts/start.sh               # 隔离的运行目录（自测用）
```

## 不依赖外网的本地自测

`tests/tg_local_test.py` 自带本地 HTTP 源站，会自动拉起/停止 TwinGate，覆盖配置渲染、CA 验签、SAN、HTTP/CONNECT/SOCKS5/FTP 的明文与 TLS 通路、认证正向/反向、混合单端口模式，**不访问任何外部网络**：

```sh
make selftest
# 或
python3 tests/tg_local_test.py
```

Makefile 里 `make test` 仍是依赖外部目标站的全量探测。

## 已知限制

- ttp 只支持 TLS 1.2，且目标地址必须是 IPv4 字面量（本项目固定用 `127.0.0.1`）。
- ttp 每连接 fork 一个进程；高频场景需要观察 ReDroid 的进程数限制。
- FTP proxy 使用 `ftppr` 语义：用户名格式为 `ftpuser@ftpserver`，被动/主动数据通道需要容器允许临时端口。
- FTP 代理的认证由 3proxy 处理，与真实 FTP 服务器登录凭据是两回事；离线自测只验证 220 通路。
- 仅在 Android/ReDroid 容器内，代理进程必须以 root 运行；宿主机普通用户无此限制。
- 关闭认证且把明文端口绑到 `0.0.0.0` 时，任何能连到容器的设备都可直接使用代理，请自行评估网络安全。

## 许可证与致谢

- 本项目自身代码（分发器、脚本、控制台、测试）使用 **LGPL-2.1-or-later**，见 `LICENSE`（包含 LGPLv2.1 与 GPLv2 官方全文）。
- 上游组件各有自己的许可证：3proxy（BSD 风格自由软件）、ttp（Unlicense）、BearSSL（MIT）。详见 `THIRD_PARTY_NOTICES.md`。
- 本项目未修改上游源码，所有 bionic / Termux 适配都在构建脚本和配置中完成。
- English documentation: [README.en.md](README.en.md).
