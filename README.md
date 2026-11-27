# TwinGate

本地代理网关：**3proxy 做协议核心，ttp 做 TLS 前端**。支持 HTTP、SOCKS4/5、FTP 代理，并为每个协议提供 TLS 加密入口；默认开启用户名/密码认证，方便直接给局域网设备使用。可选把出网接力到本机一个上游 SOCKS5，让所有客户端共享同一条出口。可在普通 Linux 主机上运行，也可用于 x86_64 ReDroid 容器（容器内需以 root 运行代理）。

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
- 可选：用 3proxy 的 `parent` 把出网接力到本机一个上游 SOCKS5，所有客户端共享它（见「上游 SOCKS5」）。

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

HTTP / CONNECT / SOCKS5 / FTP 全部复用这两个端口。`tgmux` 靠首字节分发：`0x04/0x05` → SOCKS，`USER`/`OPEN` → FTP，其余 → HTTP。

客户端**先开口**的连接走快路径：连上就把首包发过来（浏览器、curl 都这样），一次 `poll(…, 0)` 立刻分发，不会去碰 `ftppr`。

客户端**不开口**时才会做 FTP 判定：先连 `ftppr`（它一连上就发 `220` 横幅），拿到横幅后**先扣住不转发**，再给客户端 `TWIN_MUX_FTP_GRACE_MS`（默认 150ms）的宽限——期间客户端发数据就按首字节分发，仍然沉默才判定 FTP 并把横幅原样还给它。这段宽限是必须的：沉默的 FTP 客户端和浏览器的 preconnect（提前建连、暂不发请求）在报文层面完全一样，只能靠时间区分。原来的实现是固定盲等 500ms，现在 FTP 的首个响应从 500ms 降到「横幅到达 + 150ms」。

```sh
sh scripts/stop.sh
TWIN_MIXED=1 sh scripts/start.sh
python3 tests/tg_probe.py --mixed --mode all --target example.com
```

### 不需要 FTP 时把这一路关掉

`TWIN_MIXED_FTP=0` 让混合端口只分 HTTP / SOCKS：`ftppr` 不再监听、配置里连 `ftp` 段都不生成，`tgmux` 也不会去连它。沉默的客户端（浏览器的 preconnect）等够 `TWIN_MUX_FTP_GRACE_MS` 就直接交给 HTTP，跳过整个 220 横幅竞速。

```sh
TWIN_SERVICES=mixed-tls,mixed-plain TWIN_MIXED_FTP=0 sh scripts/start.sh
```

TUI 在「配置 → 13) 混合端口 FTP」里也能切。代价是这台端口上**没有 FTP 了**：FTP 客户端连过来拿不到 `220`，会被当成 HTTP。只在偶尔用一次 FTP 的机器上建议开；`twingate status` 的 `=== SERVICES ===` 会标一行 `mixed-ftp: off`。

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

- 支持 HTTP 代理的 `Proxy-Authorization: Basic`、SOCKS5 的 RFC1929 用户名密码；FTP 代理按 3proxy `ftppr` 语义使用 `USER`/`PASS`，开启认证时用户名为 `代理用户:代理密码:ftpuser@ftpserver`。
- 认证由 3proxy 执行，所以 TLS 入口和明文入口行为一致；ttp 不解析应用层协议。
- 用户名/密码只允许字母、数字和 `. _ @ -`（3proxy 配置格式限制）。
- `tests/tg_probe.py` 会自动读取 `TWIN_AUTH*` 配置发送凭据；手工测试可用 `--user` / `--pass`，或用 `--no-auth` 验证拒绝行为。
- FTP 代理的认证与真实 FTP 登录是两回事；离线自测只验证 220 通路，完整 FTP 登录请在实际环境验证。

## 上游 SOCKS5（parent 链式出口）

TwinGate 本身只监听、不负责"出网线路"。如果你已经在本机跑了一个 SOCKS5（比如隧道的本地入口），可以让 3proxy 用 `parent` 把**所有客户端**的流量接力到那一个上游：HTTP / CONNECT / SOCKS4/5 全部从它出去，连进来的每个设备共享同一个上游，日志里看到的是上游的出口。

```
客户端 ──> TwinGate（HTTP/SOCKS/FTP，认证在这一层）
                └─ 3proxy parent 1000 socks5+ 127.0.0.1 1080 ──> 上游 SOCKS5 ──> 目标
```

```sh
# 最简：上游在本机 1080
TWIN_PARENT=1 sh scripts/start.sh

# 写成一行 URL（含认证）
TWIN_PARENT='socks5://user:pass@127.0.0.1:1080' sh scripts/start.sh

# 或 host:port / 分开写
TWIN_PARENT=127.0.0.1:7890 sh scripts/start.sh
TWIN_PARENT=1 TWIN_PARENT_PORT=7890 TWIN_PARENT_TYPE=socks5 sh scripts/start.sh

# 控制台：配置 -> 10) 上游 SOCKS5（会写进 config/tui.env）
sh tgmenu.sh
```

配置项（`config/ports.env` 是默认值，环境变量 / `tui.env` 优先）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TWIN_PARENT` | `0` | `0`/`1`，或直接写 `socks5://[user:pass@]host:port`、`host:port`、`[::1]:1080`；也认 `socks5h://` / `socks4://` / `http://`（URL 形式默认按 `socks5+` 处理） |
| `TWIN_PARENT_HOST` | `127.0.0.1` | 上游地址；写了就覆盖 URL 里的主机部分 |
| `TWIN_PARENT_PORT` | `1080` | 上游端口 |
| `TWIN_PARENT_TYPE` | `socks5+` | `socks5+` 域名交给上游解析；`socks5` 本地解析；也支持 `socks4`/`socks4+`/`connect`/`connect+` |
| `TWIN_PARENT_USER` / `TWIN_PARENT_PASS` | 空 | 上游需要认证时填；只允许字母数字和 `. _ @ -` |
| `TWIN_PARENT_FTP` | `off` | `off` = 拒绝 FTP 代理；`direct` = FTP 直连（绕过上游） |

行为要点：

- **始终走上游，不回退直连。** `parent` 的权重是 1000 分制的命中概率，只有写满 `1000` 才能保证每条连接都选这条链（小于 1000 时可能一次都没选中，3proxy 会当成没有链而直接直连），所以这里固定 `1000`。上游连不上时请求直接失败（HTTP 返回 502），不会"悄悄直连"，因此不会泄漏真实出口。`tests/tg_local_test.py` 里有对应用例。
- **所有客户端共享一个上游。** parent 挂在 3proxy 的 ACL 上，与客户端数量和身份无关；3proxy 侧仍然做自己的用户名/密码认证。
- **FTP 代理不能链式。** 3proxy 的 `ftppr` 不支持 parent 数据通道，所以默认把 FTP 段改成拒绝（客户端仍会先收到 `220` 横幅，执行 `USER` 后连接被关闭）。确实要让 FTP 直连就设 `TWIN_PARENT_FTP=direct`，但那样 FTP 会暴露真实出口。
- **关闭认证时仍要检查 ACL。** `auth none` 下 3proxy 不读 allow/deny，parent 会失效；因此 `TWIN_AUTH=0` + 上游启用时会自动改用 `auth iponly`（不校验密码，只保留 ACL 生效）。
- **域名仍会本地解析一次。** 即使 `socks5+` 把域名交给上游，3proxy 为了 ACL 与日志会用 `nserver`（`TWIN_DNS_SERVER`）解析一次，所以这个 DNS 要可用。
- 状态里能看到当前链路：`twingate status` 的 `=== PARENT ===` 段，控制台首页也有「上游」一行。

## TUN 虚拟网卡接力（出站绑定）

如果出网线路不是 SOCKS5，而是本机 VPN 建出来的 TUN 网卡（`tun0` / `utun0` …），可以让 3proxy 的出站直接绑到那张网卡上，同样所有客户端共享它：

```
客户端 ──> TwinGate（HTTP/SOCKS/FTP，认证在这一层）
                └─ 出站 socket 绑 tun0 ──> VPN ──> 目标
```

```sh
# 自动挑选 tun*/utun*，并自动决定绑定方式
TWIN_TUN=auto sh scripts/start.sh

# 指定网卡（wg0 这类非 tun 名字也可以）
TWIN_TUN=tun0 sh scripts/start.sh

# 强制只绑源地址（没有 root 时的退化路径）
TWIN_TUN=tun0 TWIN_TUN_BIND=source sh scripts/start.sh

# 控制台：配置 -> 11) TUN 接力
sh tgmenu.sh
```

控制台里进 `11) TUN 接力` 后能看到的四项就是全部操作：`1` 开关、`2` 选网卡、`3` 切绑定策略、`4` 立刻检测一次；`0` 或**直接回车**返回上一级。要指定网卡，按 `2` 再输入名字（留空 = 自动挑选），也可以**直接在这个菜单里输入 `tun0` / `wg0`**，效果和按 `2` 一样。

探测与决策由 `dist/tgtun`（源码 `src/tgtun.c`）完成，启动时注入一次：

1. 用 `getifaddrs()` 找 `tun*` / `utun*` 中 up 且带地址的网卡；
2. 读 `/proc/net/route` 与 `/proc/net/ipv6_route`，看**当前生效的默认路由**（metric 最小的那条）是不是它；
3. 承载默认路由 → 什么都不加（零配置），系统本来就从它出网；
4. 不承载 → 给每条服务行追加参数：

   - 有 root / `CAP_NET_RAW`：`-De<网卡>`，3proxy 对每个出站 socket 设置 `SO_BINDTODEVICE`；
   - 没有权限：`-e<源地址>`，3proxy bind 到该网卡的源 IP。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TWIN_TUN` | `off` | 开关：`0`/`1`（也可写 `auto`）；写成网卡名（`tun0`）等价于「开启 + 指定该网卡」 |
| `TWIN_TUN_DEV` | 空 | 要绑的网卡；空 = 自动挑 `tun*` / `utun*`，也可以写 `wg0` 这类名字 |
| `TWIN_TUN_BIND` | `auto` | `auto` 按权限决定；`device` / `source` / `direct` 强制某一种 |

行为要点：

- **权限是"试"出来的。** `tgtun` 真的对一个临时 socket 调用 `setsockopt(SO_BINDTODEVICE)`，只有 `EPERM` 才退到绑源地址；容器/用户命名空间里 root 也可能没有 `CAP_NET_RAW`，所以不猜 `euid`。
- **绑网卡要求该网卡上有到目标的路由。** 绑上之后内核只在这张网卡的路由表里查，网卡上没有对应路由就直接 `ENETUNREACH`。典型 VPN 会往 TUN 里塞一条 `0.0.0.0/0`（metric 通常比物理网卡大），这种情况正好；只把少数网段指进 TUN 的分流 VPN，就只能连通那些网段。
- **绑源地址只改源 IP，不改路由。** 没有权限时的这条退化路径只在"路由本来就指向 TUN"时有意义，否则包依旧从物理网卡出去（很可能被丢弃）。
- **DNS 不受绑定影响。** 3proxy 的 `nserver` 用独立 socket 解析，不走 `-De`；需要解析也走隧道时，把 `TWIN_DNS_SERVER` 换成隧道内可达的 DNS，或改用上游 `socks5+` 让对端解析。
- **只认主路由表。** `ip rule` 配的策略路由看不到；这种情况直接写 `TWIN_TUN=<网卡>`。
- 状态里能看到结果：`twingate status` 的 `=== TUN ===` 段（`device tun0` / `source 10.8.0.2` / `direct`），控制台首页也有一行「TUN」。
- 自测会在独立 netns 里造一张 `tun9` 并验证三种注入结果（`tests/tg_local_test.py`，没有 root 时跳过）；另外实测过：同一条 SOCKS 请求，加上 `-Detun9` 后对端看到的源地址由物理网卡 IP 变成 TUN 的 IP。

## 证书信任（信任一次即可）

`scripts/gen-certs.sh` 会生成**本地 CA + 服务器证书链**，源码树模式下在 `run/certs/`，安装为单命令后改在 `~/.local/share/twingate/certs/`；SAN 自动包含 `localhost`、`127.0.0.1` 以及生成时在机器上检测到的所有 IPv4 地址。客户端只需要导入一张 `ca.crt`，之后连接 TLS 端口不再需要 `--insecure`。

**没生成证书也能直接启动**：`start` 发现没有证书会就地补一张，并打印提醒。这张证书是刚签的，客户端不信任，所以经 `https://` 代理访问时要跳过校验——`curl` 用 `--proxy-insecure`（注意 `-k` 只管目标站，管不到 `https://` 代理），浏览器/Electron 加 `--ignore-certificate-errors`。想让客户端正常校验，随后执行 `twingate certs` + `twingate trust` 即可。

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

## 延迟与 CPU

### 关掉 Nagle

TLS 握手收尾是 6 字节的 CCS 紧跟 45 字节的 Finished。对端若走 40ms 的 delayed-ACK，Nagle 会压住后面这个小包，于是**每条新连接**都白等一个 40ms 台阶。容器内自用（RTT≈0、连接复用）察觉不到，主机经代理连入时非常明显。

`ttp` 与 `tgmux` 现在都对已连接 socket 设了 `TCP_NODELAY`（3proxy 上游默认已开）。实测（docker0 直连、RTT 0.25ms、各 10 次新连接）：`ttp` 的 TLS 握手从 **43.7~45.7ms 降到 2.6~4.8ms**。

### TLS 1.2 会话复用

浏览器对同一个代理端口会反复建连（每个域名每批请求一条），每次都完整握手意味着每次都重做一遍 ECDHE 和证书签名，CPU 就是这么烧掉的。

`ttp` 是 fork-per-connection，进程内的缓存活不过一次握手，所以 BearSSL 的 LRU 会话缓存被放进 `MAP_SHARED` 的匿名映射：父子进程看到同一块物理页，外面套一把共享内存里的自旋锁（临界区只有一次百来字节的 memcpy，不需要链接 pthread）。客户端带回上次的 32 字节 session id 时，服务端直接走 abbreviated handshake，跳过密钥交换和签名。

实测（docker0、30 次连续连接）：完整握手约 3.0ms，复用后 **0.74ms**；缓存关闭时 30 次全是完整握手。24 线程并发握手没有失败，锁没有把索引写坏。

缓存大小由 `TTP_SESSION_CACHE_KB` 控制（**默认 256**，约 2600 条会话；`0` 关闭，上限 8192 即 8MB）。
TUI 里是「配置 → 14) TLS 会话缓存」，也可以直接写环境变量。每条会话固定 100 字节，所以
256KB 只是常驻内存里的 256KB 共享页，和 3proxy 每连接 64KB 的转发缓冲比微不足道；
容器内存实在紧时调小，缓存不够只是复用率下降，不影响正确性。

### 超时：为什么"有时候能连、有时候隧道失败"

3proxy 的 `timeouts` 有 11 个值，其中两个在走公网代理时最要命：

| 值 | 位置 | 默认 | 作用 |
| --- | --- | --- | --- |
| `CONNECT_TO` | 第 9 位 | 15s | 连目标（或连上游）单次等待 |
| `DNS_TO` | 第 7 位 | 15s | 3proxy 自己解析域名时单次等待 |

**DNS_TO 就是"第一次六点几秒、之后 2~3 秒"最常见的来源。** `nserver` 是明文 UDP 53，不经过 TUN 绑定、也不会跟着上游代理走：容器里配 `8.8.8.8` 时，这个查询在国内网络下多半被丢包，3proxy 每个域名都要等满 `DNS_TO` 才拿到结果（或失败）。实测把一个只会丢包、从不回答的 DNS 配上去，默认 15s 时每次请求都恰好卡 **15.01s**，把 `DNS_TO` 改成 5 就是 **5.01s**——一分不差地跟着这个值走。第一次慢、后面快，是因为 3proxy 有 `nscache`，解析成功一次就缓存住。

修法优先级：
1. **把 `TWIN_DNS_SERVER` 换成容器里真正可达的 DNS**（运营商的、局域网路由器的，或 `127.0.0.1` 上自己跑的）。这是根治。
2. 启用上游 `socks5+`（域名交给上游解析），但注意 3proxy 仍会本地解析一次用于 ACL 与日志——这一跳省不掉，只能选①或收紧超时。
3. 收紧 `DNS_TO`（TUI「配置 → 超时设置」，或 `TWIN_DNS_TO=5`），让坏 DNS 快速失败而不是干等。

**`CONNECT_TO` 太短会表现成浏览器 `ERR_TUNNEL_CONNECTION_FAILED`。** 公网代理的握手本身就要几百毫秒到几秒，偶尔抖动超过 15s，3proxy 就回 `502` 并关掉隧道，浏览器把这记成"隧道连接失败"——所以症状是"也不是全都失败，时不时的"。把 `CONNECT_TO` 调到 30~45 更稳。

实测（目标 `10.255.255.1:9`，不可路由，SYN 无人应答）：`CONNECT_TO=3` 时 curl 拿到响应用了 **6.007s**，`CONNECT_TO=8` 时是 **16.017s**——正好是 2 倍。`strace` 数过：它对**同一个地址**发了两次 `connect()`（不是 IPv6/IPv4 各一次，3proxy 默认只解析 A 记录），每次吃满 `CONNECT_TO`。所以 **`CONNECT_TO` 是每次尝试的上限**，一个彻底打不通的目标最多等 2 倍。

三个值都能在 TUI「配置 → 超时设置」里改，也能用环境变量：
`TWIN_CONNECT_TO` / `TWIN_DNS_TO` / `TWIN_CONNECTION_S`（客户端空闲），或者直接写完整的 `TWIN_TIMEOUTS="1 5 30 60 180 1800 15 60 15 5 5"`。写错（少一位、非数字）时渲染会直接拒绝并列出正确顺序——3proxy 自己对多写/少写是静默忽略的，错在配置层比错在运行时好查。

拿不准是不是 DNS 的问题时，直接看 `twingate status`：它会把配置里的 `nserver`／超时和**实测的一次明文查询**并排打出来（`=== DNS ===` 段）。几十毫秒 = 这个 DNS 能用；`超时 >6s` = 容器里根本到不了，这时不管 `DNS_TO` 调多小都只是"少等一会儿"，正解是换 DNS。

### 「域名慢、IP 快」多半是 CDN 调度，不是 DNS 慢

同一台机器、同一分钟内实测：

| 目标 | ping | TCP 建连 | TLS 握手 | 总耗时 |
| --- | --- | --- | --- | --- |
| `example.com`（解析到 Cloudflare `172.66.147.243` / `104.20.23.154`） | 200ms，**20% 丢包** | 200ms | 440~1240ms | 0.8~1.7s |
| `example.com` 强制解析到 `202.89.233.100`（Akamai，同一站点的另一个边缘） | 30ms，**0% 丢包** | 29ms | 100ms | 0.12~0.46s |
| `https://202.89.233.100/`（直接写 IP） | 30ms，0% 丢包 | 29ms | 96~147ms | 0.12~0.5s |

`8.8.8.8` / `223.5.5.5` / `119.29.29.29` 三个公共 DNS 返回的都是同一对 Cloudflare IP，解析本身只花 **7~40ms**。所以慢的不是"解析"这一步，而是**解析出来的那个 IP**：

- 域名解析到的是 CDN 按"DNS 出口的位置"挑的边缘，未必离你近。写 IP 就跳过了这次挑选，直接落到某个固定的边缘——如果它恰好是近的那个，就快一个数量级。
- TLS 握手要 2 RTT 加证书（好几个来回的包），链路上丢 1 个包就是一次 RTO（约 1s），所以丢包对 TLS 的放大远大于对单个 SYN 的建连。这就是"1~3 秒不等"的来源：TCP 200ms 很稳，TLS 在 440ms 和 1.2s 之间跳。
- 3proxy 只用配置里的 `nserver`，**不读 `/etc/resolv.conf`**，所以换系统 DNS 对代理无效；而 `nscache` 拿到哪个 IP 就缓存整个 TTL（通常 300s），这段时间里一直用那个。
- 验证办法：`curl -w '%{time_connect} %{time_appconnect}\n' --resolve example.com:443:202.89.233.100 https://example.com/`——域名不变、只换解析结果，快慢立刻分晓。

要根治得让解析结果贴近你的位置：把 `TWIN_DNS_SERVER` 换成运营商 DNS（或本机 DNS），看它返回的 IP 是否比公共 DNS 近；实在不行才对个别域名写 hosts 钉住。

### 用公网代理测这个项目会自欺

容器用公网代理出网、主机再连回容器，测到的是"公网代理 RTT × 跳数"，跟 TwinGate 自己的开销无关，而且抖动极大。判断这个项目本身的延迟，要把出口换成主机上开的代理、容器连过来：这样 RTT≈0，剩下的才是 TwinGate 的几毫秒（TLS 握手 + 认证 + 一次转发）。

但"容器连主机代理再共享回主机"比直连还是慢一点，差距是**结构性**的，不是 bug：同一台机器上多经过一次 TCP + TLS + 认证 + relay（≈1~3ms），直连是 0 跳。这点差距主要体现在 TTFB 上，浏览器里就是"感觉有点钝"，不可能消掉，只能减少跳数——不用 FTP 时把 `TWIN_SERVICES` 设成 `http-tls,socks-tls` 可以整跳掉 tgmux。

## 目录

`vendor/` 不入库，对上游的修改保存在 `vendor-patches/`：`ttp-nodelay.patch` 与 `ttp-session-cache.patch`。`fetch-vendor.sh` 与 `build.sh` 会在编译前按顺序幂等应用，重新拉取上游不会丢改动。**改 vendor 里的文件时必须同时更新对应补丁，否则下次 `make vendor` 就白改了。**

补丁不是"命令没报错就算打上了"，有三层校验，任何一层不过都会中止构建：

1. **完整性** — `vendor-patches/SHA256SUMS` 固定补丁文件的内容哈希，被截断或手工改过会直接报错（改了补丁就重新生成：`sh scripts/vendor-patch.sh`）；
2. **双向确认** — 反向 `patch --dry-run` 必须成功（源码里确实有补丁内容），正向 dry-run 必须失败（否则说明还能再打一遍，即上次没真正落盘）；
3. **期望特征** — `<补丁>.expect` 列出打完必须出现的代码（例如 `ttp.c:cache_kb = 256`），逐个 `grep -F` 核对，防止"补丁进了一半"。

补丁打不上时会打印每个文件的匹配情况（`已含补丁` / `未打补丁` / `部分匹配`）。跨文件的补丁（`ttp-session-cache` 改 3 个文件）只还原其中一个就会变成半打状态，修复办法是 `git -C vendor/ttp checkout -- .` 后重新构建。

## 目录

- `scripts/fetch-vendor.sh` — 拉取并固定上游版本
- `scripts/vendor-patch.sh` — 给上游源码幂等打本地补丁（`vendor-patches/` 下）
- `scripts/build.sh` — 构建，产物在 `dist/`（`3proxy`, `ttp`, `tgmux`, `tgtun`）
- `src/tgmux.c` — 单端口混合模式的协议分发器
- `src/tgtun.c` — TUN 网卡探测与出站绑定决策（`dist/tgtun`）
- `scripts/gen-certs.sh` — 生成本地 CA + 服务器证书链 + `run/certs/ttp.env` 的命令行入口
- `scripts/cert.sh` — 证书生成与"缺了就补一张"的唯一实现（安装时内嵌进 `twingate`）
- `scripts/install-ca.sh` — 把 `ca.crt` 安装进当前系统信任库
- `scripts/render-config.sh` — 由模板生成 `run/3proxy.cfg`（含认证开关与上游 parent）
- `scripts/start.sh` / `stop.sh` / `status.sh` — 进程管理
- `scripts/parent.sh` — 上游 SOCKS5（parent 链式出口）的解析与注入
- `scripts/tun.sh` — TUN 接力：探测结果转成 3proxy 的 `-De` / `-e` 参数
- `scripts/lifecycle.sh` — 重复启动拦截、遗留进程回收（安装模式内嵌进 `twingate`）
- `scripts/load-tui-env.sh` — 按「环境变量 > `tui.env` > `ports.env` 默认值」加载配置
- `scripts/paths.sh` — 区分程序目录、配置目录与数据目录
- `scripts/tg-runtime.sh` — 运行逻辑函数库（安装时内嵌到 `twingate`）
- `scripts/install.sh` / `uninstall.sh` — 安装/卸载为 `twingate` 命令
- `scripts/probe-env.sh` — 容器内环境探测（回传用）
- `tgmenu.sh` — 纯 sh 文本控制台
- `config/tui.env` — 控制台保存的配置与凭据（首次运行自动生成，不入库）
- `tests/tg_probe.py` — 需要目标站可达的协议探测
- `tests/tg_local_test.py` — 不依赖外网的本地自测
- `CERTS.md` — 证书说明

## 安装为单个命令（推荐）

不想每次敲一堆 `sh scripts/xxx.sh`，可以安装成一条 `twingate` 命令。安装后 `<prefix>/bin/twingate` 是**唯一的可执行脚本**（TUI + 运行逻辑全部内嵌），`<prefix>/lib/twingate/` 里**只有 `3proxy`、`ttp`、`tgmux`、`tgtun` 四个二进制**，不会复制脚本树、配置模板或测试文件。

目录布局（默认用户级安装）：

| 用途 | 路径 |
| --- | --- |
| 命令 | `~/.local/bin/twingate` |
| 程序（仅二进制） | `~/.local/lib/twingate/` |
| 配置（`tui.env`、`3proxy.cfg`） | `~/.config/twingate/`（旧版的 `~/.local/config/twingate/` 会在重新安装时自动迁移） |
| 数据（证书、日志、PID） | `~/.local/share/twingate/` |

```sh
# 用户级安装（默认，无需 root）
make install
# 系统级安装（需要写权限）
make install PREFIX=/usr/local
# Termux 安装到 $PREFIX
make install PREFIX=/data/data/com.termux/files/usr
# 自定义配置 / 数据目录
make install CONFIG_DIR=/path/to/config DATA_DIR=/path/to/data
# 或用脚本
sh scripts/install.sh --user
sh scripts/install.sh --system
sh scripts/install.sh --termux
```

`--prefix` / `--config-dir` / `--data-dir` 会写进生成的 `twingate` 启动器，之后运行时不用再重复指定；想临时换位置，设 `TWIN_CONFIG_DIR` / `TWIN_DATA` 环境变量即可（优先于安装时写下的值）。注意：目录是**安装时**定下的，改完要重新 `install.sh`，或者改用环境变量。

安装后：

```sh
twingate              # 无参数：文本菜单
twingate start        # 启动
twingate status       # 状态
twingate config       # 查看当前配置
twingate certs        # 生成 CA + 服务器证书（写入 ~/.local/share/twingate/certs）
twingate trust        # 把 ca.crt 导入本机信任库
twingate help         # 查看全部子命令
```

完整子命令：`start` / `stop` / `restart` / `status` / `config` / `build` / `certs` / `trust` / `probe` / `selftest` / `install` / `uninstall` / `help` / `version`。其中 `build`、`probe`、`selftest`、`install` 需要在源码树运行（`twingate` 会给出提示），因为安装形态只携带二进制。环境变量覆盖照常生效，例如 `TWIN_AUTH=0 twingate start`。

卸载可以直接用安装好的命令，不必回源码树：`twingate uninstall` 会先停进程，再删启动器与 `lib/twingate` 下的二进制，配置与数据（含证书）保留；`twingate uninstall --purge` 连它们一起删。源码树里对应的是 `make uninstall` / `sh scripts/uninstall.sh --purge`。

> Android/ReDroid 容器里安装后，仍**必须以 root 运行** `twingate start`（`adb shell` 后 `su`，或 Termux 里先 `su`），原因见下文。

## 文本控制台（推荐）

不用记 `sh scripts/xxx.sh`，也不需要 `make`。Linux 主机上普通用户即可运行；在 ReDroid 容器里运行控制台时，**必须以 root 身份启动代理**（`adb shell` 后 `su`，或 Termux 里先 `su`）：

```sh
cd /path/to/this/repo
su                 # 或：adb shell 后执行 su
id -u              # 容器内必须是 0
sh tgmenu.sh
```

> **仅限 Android/ReDroid 容器：非 root 下会“假成功”。** 用户实测：Termux 里 `sudo` 启动主机可以连；回普通用户再启动，`status.sh` 仍显示 `OK` / `LISTEN`，但主机连不上。这是 Android 按 UID 限制应用套接字入站连接导致的。容器内遇到“状态正常但主机不通”时，**先检查 `id -u` 是否为 0**。宿主机普通 Linux 没有这个限制。

纯 POSIX sh，只依赖 mksh/toybox。菜单包含：启动/停止/重启/状态；服务开关、8 个端口、绑定地址、认证设置、上游 SOCKS5、探测设置；重新构建；证书生成；需要外网的探测；**不依赖外网的本地自测**；证书信任说明。

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

**项目放在 `/sdcard` 上时**：这类外部存储是 noexec，不允许给文件加可执行位。构建本身会成功，`dist/` 里的二进制只是没有 `x` 位——`scripts/start.sh` 会自动把它们复制到可执行目录（默认 `~/.twingate/bin`）并 `chmod` 后再启动，不需要你处理。构建结束时会打印一行提示说明这一点；如果看到的是「存在但没有可执行权限」，那**不是编译失败**，重新构建也不会改变，按提示换目录或设 `TWIN_RUNTIME_DIR` 即可。

**重复启动会被拒绝**（`[start] 已经在运行…`，退出码 1），不会覆盖正在运行的实例的 pid 记录；要换配置请先 `stop` 或用控制台的「重启」。若上次异常退出留下孤儿进程（pid 文件丢失但端口仍被占），`start` 会先自动清理它们，`stop` 也会按运行目录回收。

环境变量覆盖示例：

```sh
CC=clang JOBS=2 TWIN_3PROXY_LIBS='' sh scripts/build.sh
TWIN_HTTP_TLS=28080 sh scripts/start.sh
TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
TWIN_MIXED=1 sh scripts/start.sh
TWIN_AUTH=0 sh scripts/start.sh                            # 关闭认证
TWIN_PARENT=1 sh scripts/start.sh                          # 所有流量接力到本机 SOCKS5 1080
TWIN_RUN_DIR=/tmp/tg-run sh scripts/start.sh               # 隔离的运行目录（自测用）
```

## 不依赖外网的本地自测

`tests/tg_local_test.py` 自带本地 HTTP 源站，会自动拉起/停止 TwinGate，覆盖配置渲染、CA 验签、SAN、HTTP/CONNECT/SOCKS5/FTP 的明文与 TLS 通路、认证正向/反向、混合单端口模式，以及**上游 SOCKS5 链路**（自带上游、验证流量确实经过它、上游不可用时不得回退直连），**不访问任何外部网络**：

```sh
make selftest
# 或
python3 tests/tg_local_test.py
```

TUN 接力需要真网卡才能验到底，所以另有一个需要 root 的脚本：它在独立 netns 里建 veth 对，分别验证「不绑定走物理网卡」「绑定后出站包从 TUN 发出」「绑定后经 TUN 端到端可用」：

```sh
sudo sh tests/tun_netns_check.sh
```

Makefile 里 `make test` 仍是依赖外部目标站的全量探测。

## 已知限制

- ttp 只支持 TLS 1.2，且目标地址必须是 IPv4 字面量（本项目固定用 `127.0.0.1`）。
- ttp 每连接 fork 一个进程；高频场景需要观察 ReDroid 的进程数限制。
- FTP proxy 使用 `ftppr` 语义：用户名格式为 `ftpuser@ftpserver`（开认证时为 `代理用户:代理密码:ftpuser@ftpserver`），被动/主动数据通道需要容器允许临时端口。
- FTP 代理的认证由 3proxy 处理，与真实 FTP 服务器登录凭据是两回事；离线自测只验证 220 通路。
- 仅在 Android/ReDroid 容器内，代理进程必须以 root 运行；宿主机普通用户无此限制。
- 关闭认证且把明文端口绑到 `0.0.0.0` 时，任何能连到容器的设备都可直接使用代理，请自行评估网络安全。
- 上游 `parent` 只能接力 HTTP / CONNECT / SOCKS：3proxy 的 `ftppr` 不支持链式数据通道，启用上游后 FTP 默认被拒绝（见「上游 SOCKS5」）。
- 上游只支持单跳（固定 weight 1000）；需要多跳就在上游那侧继续接力。
- TUN 接力只是把出站 socket 绑到网卡：不改路由表、不管 DNS、不支持策略路由；网卡上没有到目标的路由时连接会直接失败（见「TUN 虚拟网卡接力」）。

## 许可证与致谢

- 本项目自身代码（分发器、脚本、控制台、测试）使用 **LGPL-2.1-or-later**，见 `LICENSE`（包含 LGPLv2.1 与 GPLv2 官方全文）。
- 本项目未修改上游源码，所有 bionic / Termux 适配都在构建脚本和配置中完成。
- English documentation: [README.en.md](README.en.md).
