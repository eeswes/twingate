# TwinGate

A local proxy gateway: **3proxy handles the protocols, ttp handles TLS termination**.
It supports HTTP, SOCKS4/5 and FTP proxies, with a TLS entry point for every protocol.
Username/password authentication is enabled by default so the gateway can be handed
to LAN devices directly. Optionally, the egress can be chained through a local upstream
SOCKS5 so every client shares one exit. It runs on ordinary Linux hosts and on x86_64
ReDroid containers (containers require the proxy to run as root).

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
- Optional: use 3proxy `parent` to chain the egress through a local upstream SOCKS5 that
  every client shares (see "Upstream SOCKS5").

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
  the FTP proxy follows 3proxy `ftppr` semantics with `USER`/`PASS`; with authentication on,
  the FTP user name is `proxyuser:proxypass:ftpuser@ftpserver`.
- Authentication is performed by 3proxy, so TLS and plain entries behave the same;
  ttp never parses application-layer protocols.
- Usernames/passwords may contain only letters, digits and `. _ @ -` (3proxy config format).
- `tests/tg_probe.py` reads `TWIN_AUTH*` automatically; for manual runs use `--user` /
  `--pass`, or `--no-auth` to verify rejection.
- FTP proxy authentication is not the same as logging in to a real FTP server; the
  offline self-test only verifies the 220 path.

## Upstream SOCKS5 (parent chaining)

TwinGate only listens; it does not own the egress path. If a SOCKS5 already runs locally (for example the local end of a tunnel), let 3proxy chain everything to it with `parent`: HTTP / CONNECT / SOCKS4/5 all leave through that one upstream, every connected device shares it, and the traffic appears with the upstream's exit address.

```
client ──> TwinGate (HTTP/SOCKS/FTP, authentication here)
              └─ 3proxy parent 1000 socks5+ 127.0.0.1 1080 ──> upstream SOCKS5 ──> target
```

```sh
# simplest: upstream on local port 1080
TWIN_PARENT=1 sh scripts/start.sh

# single URL (with credentials)
TWIN_PARENT='socks5://user:pass@127.0.0.1:1080' sh scripts/start.sh

# host:port, or separate fields
TWIN_PARENT=127.0.0.1:7890 sh scripts/start.sh
TWIN_PARENT=1 TWIN_PARENT_PORT=7890 TWIN_PARENT_TYPE=socks5 sh scripts/start.sh

# console: Config -> 10) Upstream SOCKS5 (stored in config/tui.env)
sh tgmenu.sh
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `TWIN_PARENT` | `0` | `0`/`1`, or `socks5://[user:pass@]host:port` / `host:port` / `[::1]:1080`; `socks5h://` / `socks4://` / `http://` are accepted too (a URL implies `socks5+`) |
| `TWIN_PARENT_HOST` | `127.0.0.1` | Upstream host; overrides the host part of the URL |
| `TWIN_PARENT_PORT` | `1080` | Upstream port |
| `TWIN_PARENT_TYPE` | `socks5+` | `socks5+` lets the upstream resolve names, `socks5` resolves locally; also `socks4`/`socks4+`/`connect`/`connect+` |
| `TWIN_PARENT_USER` / `TWIN_PARENT_PASS` | empty | Upstream credentials; letters, digits and `. _ @ -` only |
| `TWIN_PARENT_FTP` | `off` | `off` denies the FTP proxy, `direct` lets FTP go direct (bypassing the upstream) |

Behaviour:

- **Always chained, never falls back to direct.** A `parent` weight is a probability out of 1000; only `1000` guarantees the chain is picked for every connection (a lower weight may go unselected, and 3proxy then connects directly), so it is pinned to `1000`. If the upstream is unreachable the request fails (HTTP 502) instead of silently connecting directly, so the real exit address never leaks. Covered by `tests/tg_local_test.py`.
- **All clients share one upstream.** `parent` lives on the 3proxy ACL, independent of how many clients connect; 3proxy still enforces its own user/password authentication.
- **The FTP proxy cannot chain.** 3proxy's `ftppr` has no parent support for its data channel, so the FTP block is turned into a deny (clients still receive the `220` banner, then the connection is closed on `USER`). Set `TWIN_PARENT_FTP=direct` if you really want direct FTP, knowing it exposes the real egress.
- **ACLs are still required when authentication is off.** With `auth none`, 3proxy never evaluates allow/deny and `parent` would be ignored, so `TWIN_AUTH=0` plus an upstream automatically renders `auth iponly` (no password, ACL still enforced).
- **Names are still resolved locally once.** Even with `socks5+` the upstream resolves the target, 3proxy resolves it too for ACLs and logs using `nserver` (`TWIN_DNS_SERVER`), so that DNS must work.
- The active chain is visible in `twingate status` under `=== PARENT ===`, and on the console home screen.

## TUN egress (binding outgoing sockets)

If the egress path is not a SOCKS5 but a TUN interface created by a local VPN (`tun0` / `utun0` …), the outgoing sockets can be bound to that interface instead — every client still shares one exit.

```
client ──> TwinGate (HTTP/SOCKS/FTP, authentication here)
              └─ outgoing socket bound to tun0 ──> VPN ──> target
```

```sh
# pick any tun*/utun* and decide how to bind
TWIN_TUN=auto sh scripts/start.sh

# name the interface (names such as wg0 work too)
TWIN_TUN=tun0 sh scripts/start.sh

# force the source-address fallback
TWIN_TUN=tun0 TWIN_TUN_BIND=source sh scripts/start.sh

# console: Config -> 11) TUN egress
sh tgmenu.sh
```

Inside `11) TUN egress` the four items are the whole story: `1` state, `2` interface, `3` bind mode, `4` detect now; `0` or **a bare Enter** goes back. To pick an interface press `2` and type the name (empty = auto-select), or just **type `tun0` / `wg0` right in that menu** — same result.

Detection and the decision come from `dist/tgtun` (source `src/tgtun.c`) and are applied once at start:

1. `getifaddrs()` finds the `tun*` / `utun*` interfaces that are up and have an address;
2. `/proc/net/route` and `/proc/net/ipv6_route` say whether the **currently effective default route** (lowest metric) belongs to it;
3. if it carries the default route, nothing is added — zero config, the system already egresses there;
4. otherwise every service line gets an extra option:

   - with root / `CAP_NET_RAW`: `-De<iface>`, 3proxy sets `SO_BINDTODEVICE` on each outgoing socket;
   - without it: `-e<source-ip>`, 3proxy binds to the interface address.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TWIN_TUN` | `off` | Switch: `0`/`1` (or `auto`); an interface name (`tun0`) means "on, and use that one" |
| `TWIN_TUN_DEV` | empty | Interface to bind; empty auto-selects `tun*` / `utun*`, names such as `wg0` work too |
| `TWIN_TUN_BIND` | `auto` | `auto` follows the permission probe; `device` / `source` / `direct` force one strategy |

Behaviour:

- **Permission is probed, not guessed.** `tgtun` calls `setsockopt(SO_BINDTODEVICE)` on a throwaway socket and only falls back to the source address on `EPERM`; inside containers or user namespaces even root may lack `CAP_NET_RAW`.
- **Device binding needs a route on that device.** Routing is then looked up on that interface only, so a target with no route there fails with `ENETUNREACH`. Typical VPNs install a `0.0.0.0/0` route on the TUN (usually with a higher metric than the physical NIC), which is exactly the case this is for; split-tunnel VPNs only cover the prefixes they route.
- **Binding the source address does not change routing.** The unprivileged fallback only helps when routing already points at the TUN; otherwise packets still leave through the physical NIC (and are likely dropped).
- **DNS is not bound.** 3proxy resolves `nserver` queries on its own socket, unaffected by `-De`; point `TWIN_DNS_SERVER` at a resolver reachable through the tunnel, or use an upstream `socks5+` and let the far end resolve.
- **Main routing table only.** Policy routing (`ip rule`, extra tables) is invisible here; name the interface explicitly with `TWIN_TUN=<iface>` in that case.
- Visible in `twingate status` under `=== TUN ===` (`device tun0` / `source 10.8.0.2` / `direct`) and on the console home screen.
- The self-test builds a `tun9` inside its own netns and checks all three injection results (`tests/tg_local_test.py`; skipped without root). It was also verified end to end: the same SOCKS request reaches the peer from the physical address without `-Detun9`, and from the TUN address with it.

## Certificate trust (import once)

`scripts/gen-certs.sh` creates a **local CA plus a server certificate chain**. It writes to
`run/certs/` in the source tree and to `~/.local/share/twingate/certs/` after single-command
installation. The SAN automatically includes `localhost`, `127.0.0.1` and every IPv4 address
detected on the machine at generation time. Clients only need to import one file, `ca.crt`;
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
- `scripts/build.sh` — build; output in `dist/` (`3proxy`, `ttp`, `tgmux`, `tgtun`)
- `src/tgmux.c` — protocol dispatcher for the mixed single-port mode
- `scripts/gen-certs.sh` — generate the local CA + server chain + `run/certs/ttp.env`
- `scripts/install-ca.sh` — install `ca.crt` into the current system trust store
- `scripts/render-config.sh` — render `run/3proxy.cfg` from the template (auth + upstream parent)
- `scripts/start.sh` / `stop.sh` / `status.sh` — process management
- `scripts/parent.sh` — parse and inject the upstream SOCKS5 (parent chaining)
- `scripts/lifecycle.sh` — refuse double starts, reclaim orphan processes (embedded in `twingate`)
- `scripts/load-tui-env.sh` — load config as env vars > `tui.env` > `ports.env` defaults
- `scripts/paths.sh` — separates program, config and data directories
- `scripts/tg-runtime.sh` — runtime function library (embedded into `twingate` at install time)
- `scripts/install.sh` / `uninstall.sh` — install/uninstall the `twingate` command
- `scripts/probe-env.sh` — in-container environment probe (for support reports)
- `tgmenu.sh` — pure-sh text console, auto-detects Simplified Chinese or English
- `config/tui.env` — console settings and credentials (created on first run, not committed)
- `tests/tg_probe.py` — protocol probes that need a reachable target
- `tests/tg_local_test.py` — offline self-test with a built-in local origin
- `CERTS.md` — certificate guide

## Install as a single command (recommended)

Instead of typing a bunch of `sh scripts/xxx.sh`, install TwinGate as one `twingate` command. After installation, `<prefix>/bin/twingate` is the **only executable script** (TUI and runtime logic are embedded), and `<prefix>/lib/twingate/` contains **only the four binaries** `3proxy`, `ttp`, `tgmux` and `tgtun` — no script tree, config templates or tests are copied.

Layout (default user-level install):

| Purpose | Path |
| --- | --- |
| Command | `~/.local/bin/twingate` |
| Programs (binaries only) | `~/.local/lib/twingate/` |
| Config (`tui.env`, `3proxy.cfg`) | `~/.local/config/twingate/` |
| Data (certs, logs, PID files) | `~/.local/share/twingate/` |

```sh
# user-level install (default, no root needed)
make install
# system-wide (needs write access)
make install PREFIX=/usr/local
# Termux: install into $PREFIX
make install PREFIX=/data/data/com.termux/files/usr
# custom config / data directories
make install CONFIG_DIR=/path/to/config DATA_DIR=/path/to/data
# or call the script directly
sh scripts/install.sh --user
sh scripts/install.sh --system
sh scripts/install.sh --termux
```

`--prefix` / `--config-dir` / `--data-dir` are baked into the generated `twingate` launcher, so you do not repeat them at runtime; to override temporarily, set `TWIN_CONFIG_DIR` / `TWIN_DATA` (they win over the installed values). The locations are fixed at install time — re-run `install.sh` to change them permanently.

After installation:

```sh
twingate              # no arguments: text menu
twingate start        # start
twingate status       # status
twingate config       # show current configuration
twingate certs        # generate CA + server certificate (into ~/.local/share/twingate/certs)
twingate trust        # import ca.crt into the local trust store
twingate help         # list all subcommands
```

Full list: `start` / `stop` / `restart` / `status` / `config` / `build` / `certs` / `trust` / `probe` / `selftest` / `install` / `uninstall` / `help` / `version`. `build`, `probe`, `selftest`, `install` and `uninstall` require the source tree (`twingate` will tell you so), since the installed form carries binaries only. Environment overrides still work, e.g. `TWIN_AUTH=0 twingate start`.

Uninstall keeps config and data: `make uninstall`; to remove them too: `sh scripts/uninstall.sh --purge`.

> Inside an Android/ReDroid container, `twingate start` must still **run as root** (`adb shell` then `su` in Termux) — see below.

## Text console (recommended)

No need to memorize `sh scripts/xxx.sh`, or to use `make`. A normal user is fine on
a Linux host; inside a ReDroid container, **the proxy must be started as root** (`adb shell` then
`su` in Termux):

```sh
cd /path/to/this/repo
su                 # or: adb shell, then su
id -u              # must be 0 inside the container
sh tgmenu.sh
```

> **Android/ReDroid containers only: non-root gives a false success.** Reported behavior:
> starting with `sudo` in Termux works from the host; after back to a normal
> user and starting again, `status.sh` still shows `OK` / `LISTEN` but the host cannot
> connect. Android restricts inbound sockets per UID. When "status looks fine but the
> host cannot connect" happens inside a container, **check `id -u` is 0 first**.
> A normal Linux host has no such limitation.

The console is pure POSIX sh and needs only mksh/toybox. Menus cover start/stop/restart/status;
service toggles, 8 ports, bind address, authentication, upstream SOCKS5, probe settings; rebuild;
certificate generation; online probes; **offline self-test**; and certificate trust help. It selects
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

**Starting twice is refused** (`[start] 已经在运行…`, exit code 1) so a running instance never
loses its pid records; stop it first or use "Restart" in the console. If a previous crash left
orphan processes (pid files gone but ports still held), `start` cleans them up automatically and
`stop` reclaims them by runtime directory.

Environment override examples:

```sh
CC=clang JOBS=2 TWIN_3PROXY_LIBS='' sh scripts/build.sh
TWIN_HTTP_TLS=28080 sh scripts/start.sh
TWIN_PLAIN_BIND=0.0.0.0 sh scripts/start.sh
TWIN_MIXED=1 sh scripts/start.sh
TWIN_AUTH=0 sh scripts/start.sh                            # disable authentication
TWIN_PARENT=1 sh scripts/start.sh                          # chain all traffic to local SOCKS5 1080
TWIN_RUN_DIR=/tmp/tg-run sh scripts/start.sh               # isolated runtime dir (tests)
```

## Offline self-test

`tests/tg_local_test.py` has a built-in local HTTP origin. It starts and stops TwinGate
automatically and covers config rendering, CA verification, SANs, plaintext and TLS paths
for HTTP/CONNECT/SOCKS5/FTP, positive and negative authentication, mixed single-port mode,
and the **upstream SOCKS5 chain** (built-in upstream, verifies traffic really goes through it,
and that an unreachable upstream never falls back to direct) — **without touching any external
network**:

```sh
make selftest
# or
python3 tests/tg_local_test.py
```

TUN egress can only be proven against real interfaces, so a separate root-only script builds
veth pairs inside its own netns and checks "unbound goes through the physical NIC", "bound
sends packets out of the TUN" and "bound works end to end through the TUN":

```sh
sudo sh tests/tun_netns_check.sh
```

`make test` remains the full probe suite that requires an external target.

## Known limitations

- ttp only supports TLS 1.2 and requires an IPv4 literal as the target (this project
  always uses `127.0.0.1`).
- ttp forks one process per connection; watch ReDroid's process limit under high load.
- The FTP proxy uses `ftppr` semantics: the username is `ftpuser@ftpserver`
  (`proxyuser:proxypass:ftpuser@ftpserver` when authentication is on), and
  passive/active data channels require the container to allow ephemeral ports.
- FTP proxy authentication is separate from real FTP server login; the offline test
  only verifies the 220 path.
- Inside Android/ReDroid containers the proxy must run as root; a normal host user
  has no such restriction.
- With authentication disabled and plain ports bound to `0.0.0.0`, any device that
  can reach the container can use the proxy — assess your network security first.
- The upstream `parent` chains HTTP / CONNECT / SOCKS only: 3proxy's `ftppr` has no
  chained data channel, so FTP is denied by default once an upstream is enabled
  (see "Upstream SOCKS5").
- Only a single upstream hop is supported (weight fixed at 1000); chain further on
  the upstream side if you need more.
- TUN egress only binds outgoing sockets: it does not change routing, does not touch
  DNS and does not understand policy routing. When the interface has no route to the
  target, the connection simply fails (see "TUN egress").

## License and credits

- TwinGate's own code (dispatcher, scripts, console, tests) is licensed under
  **LGPL-2.1-or-later**; see `LICENSE`, which includes the official LGPLv2.1 and GPLv2 texts.
- No upstream source code was modified; all bionic / Termux adaptations live in the
  build scripts and configuration.
