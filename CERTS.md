# TwinGate 证书信任说明

目标是**信任一次，之后连接 TLS 端口不再需要 `--insecure`**。

## 工作原理

`scripts/gen-certs.sh` 会生成：

| 文件 | 作用 | 需要分发给客户端吗 |
| --- | --- | --- |
| `ca.crt` | 本地 CA 根证书 | **是，只需这一个** |
| `ca.key` | CA 私钥 | 否，妥善保管，绝不外传 |
| `server.crt` | 服务器证书（叶子） | 否（仅供检查） |
| `server.key` | 服务器私钥 | 否 |
| `server-chain.crt` | 叶子 + CA，ttp 实际发送 | 否（已写进 `ttp.env`） |
| `ttp.env` | base64 形式的证书/私钥，供 start.sh 读取 | 否 |

证书 SAN 自动包含 `localhost`、`127.0.0.1` 和**生成时在本机检测到的所有 IPv4 地址**。如果客户端实际连接用的是另一个 IP/域名（例如端口转发后的地址、mDNS 名称），用环境变量追加后再生成：

```sh
TWIN_CERT_IPS="192.168.1.50,10.0.0.7" \
TWIN_CERT_DNS="twingate.local,my-nas" \
sh scripts/gen-certs.sh
```

然后在每个客户端**只导入一次 `run/certs/ca.crt`**。

## 生成与推送

在有 openssl 的宿主机或 Termux 上：

```sh
sh scripts/gen-certs.sh
sh push.sh                      # 推送到 /sdcard/Download/twingate.zip
# 在容器里解压覆盖，run/certs 会落到 $TG/run/certs/
```

重新生成时 CA 会复用，服务器证书会按当前网络重新签发，**客户端不需要重新导入**。

## 各平台导入

### 自动安装（Linux / Termux / macOS / Windows）

```sh
sh scripts/install-ca.sh
# 或指定路径
sh scripts/install-ca.sh /path/to/ca.crt
```

脚本会按系统选择正确位置：Debian/Ubuntu 放 `/usr/local/share/ca-certificates/` 并执行 `update-ca-certificates`；RHEL 系放 `/etc/pki/ca-trust/source/anchors/` 并执行 `update-ca-trust`；Termux 放 `$PREFIX/etc/ca-certificates/certs/`；macOS 加进用户钥匙串；Windows 用 `certutil -addstore ROOT`。Linux 需要 root，请用 `sudo sh scripts/install-ca.sh`。

### Android / ReDroid 手工导入

系统 CA 不能靠复制文件到容器完成，需要在 Android 设置里操作：

1. 把 `ca.crt` 放到设备可访问的位置，例如 `adb push run/certs/ca.crt /sdcard/twingate-ca.crt`；
2. 设置 → 安全 → 更多安全设置 → 从存储设备安装 → **CA 证书**；
3. 选择 `twingate-ca.crt`，按提示完成。

> 使用自有信任库的应用（典型如 Firefox）不会读取系统 CA，需要在应用内单独导入。

## 验证

导入后在客户端执行（注意**不带** `--proxy-insecure`）：

```sh
curl -x https://<主机>:<TLS端口> -I --max-time 8 https://example.com
```

或运行仓库里的探测脚本（它使用系统默认信任库）：

```sh
python3 tests/tg_probe.py --tls --mode all --host <主机> --target example.com
```

若看到 `SSL: CERTIFICATE_VERIFY_FAILED` 或 curl 报 `SSL certificate problem`：

1. 确认客户端连接时用的 IP/域名出现在 `openssl x509 -in run/certs/ca.crt -noout -subject` 之外，实际要看服务器证书的 SAN：
   `openssl x509 -in run/certs/server.crt -noout -ext subjectAltName`
2. 把缺失的地址通过 `TWIN_CERT_IPS` / `TWIN_CERT_DNS` 加入后重新 `gen-certs.sh`，并重启代理；
3. 确认客户端确实导入了 `ca.crt`（不是 `server.crt`），且导入的是当前 CA——`ca.key` 被删后重新生成 CA 时，旧信任会失效，需要重新导入。
