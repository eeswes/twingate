# TwinGate

A local proxy gateway: **3proxy handles the protocols, ttp handles TLS termination**.
It supports HTTP, SOCKS4/5 and FTP proxies, with a TLS entry point for every protocol.
Username/password authentication is enabled by default so the gateway can be handed
to LAN devices directly. It runs on ordinary Linux hosts and on x86_64 ReDroid
containers (containers require the proxy to run as root).

[简体中文文档](README.md)

## Architecture

```
client --TLS--> ttp (BearSSL, one process per protocol) --plain--> 3proxy (127.0.0.1) --> network
client --plain--> 3proxy <TWIN_PLAIN_BIND>:<plain port> ------------------------------> network
                          (127.0.0.1 by default; switch to 0.0.0.0 with a flag)
                  Authentication is enforced by 3proxy: HTTP Basic / SOCKS5 RFC1929 /
                  FTP USER-PASS. ttp only relays bytes, so TLS and plain entries
                  behave identically.
```

- **3proxy**: 0.9 LTS (pinned commit `4f7a611`), provides HTTP proxy / HTTPS CONNECT /
  SOCKS4/5 / FTP proxy (`ftppr`). No OpenSSL development headers needed at build time.
- **ttp**: pinned commit `24f055f`, uses BearSSL (pinned commit `7bea48e`). It only
  terminates TLS and forwards plaintext to `127.0.0.1:<plain port>`.
- ttp supports only one listening port per process, so one instance is started per protocol.
- Plain services bind to `127.0.0.1` by default; TLS ports are bound to `0.0.0.0` by ttp
  (upstream behavior — narrow access with host/container networking or a firewall if needed).
- To let the host or LAN devices reach the plain ports, set `TWIN_PLAIN_BIND=0.0.0.0`.
  Authentication still applies.

## Ports (override with config/ports.env)

| Protocol | TLS entry (ttp) | Plain entry (3proxy, local only by default) |
| --- | --- | --- |
| HTTP / CONNECT | 18080 | 31808 |
| SOCKS4/5 | 11080 | 31080 |
| FTP proxy | 10021 | 30021 |
| Mixed | 17890 | 37890 |

## Single-port mixed mode (optional)

The default is the 6-port topology above. With `TWIN_MIXED=1`, two ports are used:

| Purpose | Port | Notes |
| --- | --- | --- |
| TLS entry | 17890 (`TWIN_MIXED_TLS`) | one ttp instance |
| Plain entry | 37890 (`TWIN_MUX_PLAIN`) | `tgmux` protocol dispatcher |

HTTP / CONNECT / SOCKS5 / FTP all share these two ports. `tgmux` dispatches on the first
byte: `0x04`/`0x05` → SOCKS, `USER`/`OPEN` → FTP, anything else → HTTP. If a client sends
no data within `TWIN_MUX_PEEK_MS` (500 ms by default), the connection is treated as FTP
because `ftppr` sends a 220 banner first.

```sh
sh scripts/stop.sh
TWIN_MIXED=1 sh scripts/start.sh
python3 tests/tg_probe.py --mixed --mode all --target example.com
```

### Choosing which ports to open

`TWIN_SERVICES` is a comma-separated list that decides which listeners are actually
started:

```
http-tls   http-plain
socks-tls  socks-plain
ftp-tls    ftp-plain
mixed-tls  mixed-plain
```

When unset, the previous behavior applies: `TWIN_MIXED=1` opens the two mixed ports,
otherwise the six traditional ports are opened. To open only the two mixed ports:

```sh
TWIN_SERVICES=mixed-tls,mixed-plain TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
```

The bind address of each protocol's plain backend can be overridden individually with
`TWIN_HTTP_BIND` / `TWIN_SOCKS_BIND` / `TWIN_FTP_BIND` (they inherit `TWIN_PLAIN_BIND`
by default). Disabled services produce no 3proxy config section; plain backends of
still-enabled TLS services listen only on `127.0.0.1` for ttp forwarding.

## Username/password authentication

**Enabled by default.** The out-of-the-box credentials are:

```
username: twingate
password: twingate123
```

These are public defaults — **change them before exposing the proxy to LAN devices**:

```sh
# environment variables (can be written into your own start script)
TWIN_AUTH_USER=myuser TWIN_AUTH_PASS='MyPassw0rd' sh scripts/start.sh

# or: tgmenu.sh -> Config -> 7) Authentication
```

To disable authentication:

```sh
TWIN_AUTH=0 sh scripts/start.sh
```

Notes:

- HTTP proxy uses `Proxy-Authorization: Basic`; SOCKS5 uses RFC1929 username/password;
  the FTP proxy follows 3proxy `ftppr` semantics with `USER`/`PASS`.
- Authentication is performed by 3proxy, so TLS and plain entries behave the same;
  ttp never parses application-layer protocols.
- Usernames/passwords may contain only letters, digits and `. _ @ -` (3proxy config format).
- `tests/tg_probe.py` reads `TWIN_AUTH*` automatically; for manual runs use `--user` /
  `--pass`, or `--no-auth` to verify rejection.
- FTP proxy authentication is not the same as logging in to a real FTP server; the
  offline self-test only verifies the 220 path.

## Certificate trust (import once)

`scripts/gen-certs.sh` creates a **local CA plus a server certificate chain**. The SAN
automatically includes `localhost`, `127.0.0.1` and every IPv4 address detected on the
machine at generation time. Clients only need to import one file, `run/certs/ca.crt`;
afterwards TLS connections no longer need `--insecure`.

```sh
sh scripts/gen-certs.sh                  # create/update; the CA is reused
sh scripts/install-ca.sh                 # automatic install on Linux/Termux/macOS/Windows
python3 tests/tg_probe.py --tls --mode all --verify   # connection test with verification
```

If clients connect through a different IP or domain name, append it and regenerate —
the CA stays the same, so clients do not need to import it again:

```sh
TWIN_CERT_IPS="192.168.1.50" TWIN_CERT_DNS="twingate.local" sh scripts/gen-certs.sh
```

On Android/ReDroid, install the CA manually in system settings. See **[CERTS.md](CERTS.md)**
for cross-platform steps and troubleshooting. Without an installed CA, the probe script
skips verification by default; enable it with `--verify` or TUI "Config -> Probe settings
-> Certificate verification".

## Layout

- `scripts/fetch-vendor.sh` — fetch and pin upstream versions
- `scripts/build.sh` — build; output in `dist/` (`3proxy`, `ttp`, `tgmux`)
- `src/tgmux.c` — protocol dispatcher for the mixed single-port mode
- `scripts/gen-certs.sh` — generate the local CA + server chain + `run/certs/ttp.env`
- `scripts/install-ca.sh` — install `ca.crt` into the current system trust store
- `scripts/render-config.sh` — render `run/3proxy.cfg` from the template (incl. auth)
- `scripts/start.sh` / `stop.sh` / `status.sh` — process management
- `scripts/probe-env.sh` — in-container environment probe (for support reports)
- `tgmenu.sh` — pure-sh text console, auto-detects Simplified Chinese or English
- `config/tui.env` — console settings and credentials (created on first run, not committed)
- `tests/tg_probe.py` — protocol probes that need a reachable target
- `tests/tg_local_test.py` — offline self-test with a built-in local origin
- `CERTS.md` — certificate guide

## Text console (recommended)

No need to memorize `sh scripts/xxx.sh`, or to use `make`. A normal user is fine on
a Linux host; inside a ReDroid container, **the proxy must be started as root** (`adb shell` then
`su`, or `su` in Termux):

```sh
cd /path/to/this/repo
su                 # or: adb shell, then su
id -u              # must be 0 inside the container
sh tgmenu.sh
```

> **Android/ReDroid containers only: non-root gives a false success.** Reported behavior:
> starting after `su` in Termux works from the host; after `exit` back to a normal
> user and starting again, `status.sh` still shows `OK` / `LISTEN` but the host cannot
> connect. Android restricts inbound sockets per UID. When "status looks fine but the
> host cannot connect" happens inside a container, **check `id -u` is 0 first**.
> A normal Linux host has no such limitation.

The console is pure POSIX sh and needs only mksh/toybox. Menus cover start/stop/restart/status;
service toggles, 8 ports, bind address, authentication, probe settings; rebuild; certificate
generation; online probes; **offline self-test**; and certificate trust help. It selects
Simplified Chinese or English automatically from the locale. Override with
`TWIN_UI_LANG=zh` or `TWIN_UI_LANG=en`, or set it in "Config -> Interface language".

## Quick start

```sh
sh scripts/fetch-vendor.sh
sh scripts/build.sh          # needs cc/make; build in the container for bionic binaries, or directly on a Linux host
sh scripts/gen-certs.sh      # needs openssl; can run on the host and copy run/certs in
sh scripts/install-ca.sh     # client trusts ca.crt (optional but recommended)
sh scripts/start.sh          # first run warns about the default credentials
sh scripts/status.sh
sh scripts/stop.sh
```

`vendor/` is not committed (about 24 MB of upstream sources). After cloning, run
`sh scripts/fetch-vendor.sh` to fetch the pinned commits.

Sync sources to a ReDroid container:

```sh
sh push.sh                              # first adb device by default
ADB_SERIAL=localhost:5555 sh push.sh    # specify a serial with multiple devices
```

The pushed zip excludes `dist/`, private keys, `ttp.env` and `config/tui.env`; it does
not delete the project directory on the device, so already-built binaries, certificates
and local settings there are preserved.

Environment override examples:

```sh
CC=clang JOBS=2 TWIN_3PROXY_LIBS='' sh scripts/build.sh
TWIN_HTTP_TLS=28080 sh scripts/start.sh
TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
TWIN_MIXED=1 sh scripts/start.sh
TWIN_AUTH=0 sh scripts/start.sh                            # disable authentication
TWIN_RUN_DIR=/tmp/tg-run sh scripts/start.sh               # isolated runtime dir (tests)
```

## Offline self-test

`tests/tg_local_test.py` has a built-in local HTTP origin. It starts and stops TwinGate
automatically and covers config rendering, CA verification, SANs, plaintext and TLS paths
for HTTP/CONNECT/SOCKS5/FTP, positive and negative authentication, and mixed single-port
mode — **without touching any external network**:

```sh
make selftest
# or
python3 tests/tg_local_test.py
```

`make test` remains the full probe suite that requires an external target.

## Known limitations

- ttp only supports TLS 1.2 and requires an IPv4 literal as the target (this project
  always uses `127.0.0.1`).
- ttp forks one process per connection; watch ReDroid's process limit under high load.
- The FTP proxy uses `ftppr` semantics: the username is `ftpuser@ftpserver`, and
  passive/active data channels require the container to allow ephemeral ports.
- FTP proxy authentication is separate from real FTP server login; the offline test
  only verifies the 220 path.
- Inside Android/ReDroid containers the proxy must run as root; a normal host user
  has no such restriction.
- With authentication disabled and plain ports bound to `0.0.0.0`, any device that
  can reach the container can use the proxy — assess your network security first.

## License and credits

- TwinGate's own code (dispatcher, scripts, console, tests) is licensed under
  **LGPL-2.1-or-later**; see `LICENSE`, which includes the official LGPLv2.1 and GPLv2 texts.
- Upstream components keep their own licenses: 3proxy (BSD-style free software),
  ttp (Unlicense), BearSSL (MIT). See `THIRD_PARTY_NOTICES.md`.
- No upstream source code was modified; all bionic / Termux adaptations live in the
  build scripts and configuration.
