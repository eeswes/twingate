/*
 * tgmux - TwinGate single-port protocol demultiplexer
 *
 * Reads the very first bytes of an incoming connection and forwards the
 * session to the matching 3proxy backend:
 *
 *   0x04 / 0x05        -> SOCKS
 *   'U'/'u'/'O'/'o'    -> FTP proxy (USER / OPEN)
 *   anything else      -> HTTP proxy (GET/POST/CONNECT/...)
 *   client stays mute  -> race the FTP greeting: whichever speaks first wins,
 *                         so a real FTP client still reaches ftppr instantly
 *
 * Usage:
 *   tgmux <listen_port> <http_port> <socks_port> <ftp_port> [bind_addr]
 *
 * Environment:
 *   TWIN_MUX_PEEK_MS   upper bound for the greeting race (default 500)
 *   TWIN_MUX_FTP_GRACE_MS   grace after the 220 banner before declaring FTP
 *                           (default 150; 0 = banner alone settles it,
 *                            500 = the old blind wait)
 *
 * No third-party dependencies; builds with gcc/clang on glibc and bionic.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static int peek_ms = 500;
/* banner 已到、客户端仍沉默时的宽限（毫秒）。0 = 一拿到 banner 就判 FTP。 */
static int ftp_grace_ms = 150;

/* 单调时钟的相对毫秒数，用于 poll 循环里的剩余时间计算。 */
static long elapsed_ms(const struct timespec *t0)
{
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long)(now.tv_sec - t0->tv_sec) * 1000L +
           (long)(now.tv_nsec - t0->tv_nsec) / 1000000L;
}

/* 关掉 Nagle：转发层是小包高交互，40ms 的 delayed-ACK 台阶比省下的包头贵得多。
   3proxy 自己默认已开，这里补上 tgmux 的两端。失败不影响功能，只是慢，故不报错。 */
static void set_nodelay(int fd)
{
    int on = 1;

    if (fd >= 0)
        (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
}

static int valid_port(const char *s)
{
    char *end;
    long v;

    if (s == NULL || *s == '\0')
        return 0;
    errno = 0;
    v = strtol(s, &end, 10);
    if (errno != 0 || *end != '\0' || v < 1 || v > 65535)
        return 0;
    return 1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s <listen_port> <http_port> <socks_port> <ftp_port> [bind_addr]\n",
            prog);
}

static int connect_backend(const char *host, int port)
{
    char portstr[16];
    struct addrinfo hints, *res = NULL, *rp;
    int fd = -1;

    snprintf(portstr, sizeof(portstr), "%d", port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;

    if (getaddrinfo(host, portstr, &hints, &res) != 0)
        return -1;
    /* 后端端口是纯数字，走一次就够；用不到的那条地址跳过即可。 */
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0)
        set_nodelay(fd);
    return fd;
}

/*
 * 把"解析出一批地址"和"逐个 connect"拆成两步。
 *
 * 拆分本身是为后续优化留的口子：后端地址是纯数字，解析一次就够，没必要在
 * 每次重试时重做；而且分两步之后，将来可以在 connect 的同时先把客户端首包
 * 收进来（"应答已在等"的场景），不必串行地等 connect 回来再 recv。
 * 目前 handle_client() 仍是先连后端再取首包，行为与拆分前一致。
 */
struct backaddrs {
    struct addrinfo *res;
};

static int backend_addrs(const char *host, int port, struct backaddrs *ba)
{
    char portstr[16];
    struct addrinfo hints;

    snprintf(portstr, sizeof(portstr), "%d", port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    ba->res = NULL;
    if (getaddrinfo(host, portstr, &hints, &ba->res) != 0)
        return -1;
    return 0;
}

/* 用 backend_addrs 的结果建连；成败都释放地址表，只能用一次。 */
static int connect_backend_addrs(struct backaddrs *ba)
{
    struct addrinfo *rp;
    int fd = -1;

    if (ba->res == NULL)
        return -1;
    for (rp = ba->res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(ba->res);
    ba->res = NULL;
    if (fd >= 0)
        set_nodelay(fd);
    return fd;
}

static int send_all(int fd, const unsigned char *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        return -1;
    }
    return 0;
}

/* Full-duplex relay with half-close support. */
static void relay(int cli, int srv)
{
    struct pollfd fds[2];
    unsigned char buf[16384];
    int cli_open = 1, srv_open = 1;

    fds[0].fd = cli;
    fds[0].events = POLLIN;
    fds[1].fd = srv;
    fds[1].events = POLLIN;

    while (cli_open || srv_open) {
        int r = poll(fds, 2, -1);
        int i;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        for (i = 0; i < 2; i++) {
            int src, dst;
            ssize_t n;
            if (fds[i].revents == 0)
                continue;
            src = fds[i].fd;
            dst = (i == 0) ? srv : cli;
            n = recv(src, buf, sizeof(buf), 0);
            if (n > 0) {
                if (send_all(dst, buf, (size_t)n) != 0)
                    goto done;
                continue;
            }
            if (n == 0) {
                shutdown(dst, SHUT_WR);
                if (i == 0) {
                    cli_open = 0;
                    /* 置 -1 而不是 events=0：POLLHUP 不受 events 影响，
                       否则 poll 会一直返回同一个 fd，形成忙循环。 */
                    fds[0].fd = -1;
                } else {
                    srv_open = 0;
                    fds[1].fd = -1;
                }
                continue;
            }
            if (errno == EINTR || errno == EAGAIN)
                continue;
            goto done;
        }
    }

done:
    shutdown(cli, SHUT_RDWR);
    shutdown(srv, SHUT_RDWR);
    close(cli);
    close(srv);
}

/* 按首字节判断协议。返回后端端口，*kind 写日志用的名字。 */
static int classify(const unsigned char *b, int hp, int sp, int fp,
                    const char **kind)
{
    if (b[0] == 4 || b[0] == 5) {
        *kind = "socks";
        return sp;
    }
    if (b[0] == 'U' || b[0] == 'u' || b[0] == 'O' || b[0] == 'o') {
        *kind = "ftp";
        return fp;
    }
    *kind = "http";
    return hp;
}

/*
 * 分发策略（首包优先 + banner 竞速）：
 *
 * 1) 快路径：客户端首包通常在建连后立刻到（浏览器/curl 发 CONNECT、SOCKS 客户端
 *    发问候），这里用 0 超时 poll 一次。命中就直接按首字节分发，完全不碰 ftppr。
 * 2) 慢路径：客户端暂时沉默，就先连 ftppr（它一连上就吐 220 banner），
 *    拿到 banner 后**不立刻转发**，而是再给客户端 TWIN_MUX_FTP_GRACE_MS 的宽限：
 *    期间客户端发话 → 按首字节分发；仍沉默 → 判定 FTP，把 banner 原样还给它。
 *
 * 为什么需要宽限：沉默的 FTP 客户端和浏览器的 preconnect（提前建连、暂不发请求）
 * 在报文层面完全一样，只能靠时间区分。宽限就是这段不可区分区间的长度——
 * 原来固定盲等 500ms，现在 FTP 的首个响应从 500ms 降到「banner 到达 + 宽限」。
 */
static void handle_client(int cli, int hp, int sp, int fp, const char *host)
{
    unsigned char buf[512];
    unsigned char banner[512];
    ssize_t n = 0, got, blen = 0;
    struct pollfd p[2];
    int target_port, srv = -1, ftp_sock = -1, rv;
    const char *kind;

    /* 越早越好：后面 peek / 转发首包都是小包。 */
    set_nodelay(cli);

    p[0].fd = cli;
    p[0].events = POLLIN;
    p[0].revents = 0;
    if (poll(p, 1, 0) > 0 && (p[0].revents & (POLLIN | POLLHUP)))
        n = recv(cli, buf, sizeof(buf), MSG_PEEK);
    if (n < 0)
        n = 0;

    if (n == 0) {
        struct timespec t0;
        long elapsed, limit;
        int have_banner = 0;

        ftp_sock = connect_backend(host, fp);
        if (ftp_sock < 0) {
            fprintf(stderr, "[tgmux] cannot connect ftp backend %s:%d\n",
                    host, fp);
            close(cli);
            return;
        }

        p[0].fd = cli;
        p[0].events = POLLIN;
        p[1].fd = ftp_sock;
        p[1].events = POLLIN;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        for (;;) {
            /* banner 到之前等客户端首包（peek_ms）；到了之后只等宽限。 */
            limit = have_banner ? (long)ftp_grace_ms : (long)peek_ms;
            elapsed = elapsed_ms(&t0);
            if (elapsed >= limit) {
                if (have_banner) {
                    if (send_all(cli, banner, (size_t)blen) != 0) {
                        close(cli);
                        close(ftp_sock);
                        return;
                    }
                    fprintf(stderr,
                            "[tgmux] fd=%d -> %s:%d (ftp, greeting-first)\n",
                            cli, host, fp);
                } else {
                    /* 连 banner 都没有：沿用旧行为当 FTP 直通。 */
                    fprintf(stderr,
                            "[tgmux] fd=%d -> %s:%d (ftp, no greeting yet)\n",
                            cli, host, fp);
                }
                relay(cli, ftp_sock);
                return;
            }

            p[0].revents = 0;
            p[1].revents = 0;
            rv = poll(p, 2, (int)(limit - elapsed));
            if (rv < 0) {
                if (errno == EINTR)
                    continue;
                fprintf(stderr, "[tgmux] fd=%d poll failed: %s\n", cli,
                        strerror(errno));
                close(cli);
                close(ftp_sock);
                return;
            }
            if (rv == 0)
                continue;               /* 回到循环顶部按 elapsed 判超时 */

            if (p[0].revents & (POLLIN | POLLHUP)) {
                n = recv(cli, buf, sizeof(buf), MSG_PEEK);
                if (n > 0)
                    break;              /* 客户端发话了，交给 classify */
                if (n == 0) {           /* 客户端已关闭 */
                    close(cli);
                    close(ftp_sock);
                    return;
                }
                if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    close(cli);
                    close(ftp_sock);
                    return;
                }
            }

            if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
                if (!have_banner) {
                    blen = recv(ftp_sock, banner, sizeof(banner), 0);
                    if (blen <= 0) {
                        /* ftppr 没吐 banner 就关了，只能让客户端看到断开 */
                        close(cli);
                        close(ftp_sock);
                        return;
                    }
                    have_banner = 1;
                    clock_gettime(CLOCK_MONOTONIC, &t0);  /* 宽限从这里算 */
                    continue;
                }
                /* banner 之后又推数据：只可能是 FTP，直接连人带数据一起转 */
                got = recv(ftp_sock, buf, sizeof(buf), 0);
                if (got <= 0 ||
                    send_all(cli, banner, (size_t)blen) != 0 ||
                    send_all(cli, buf, (size_t)got) != 0) {
                    close(cli);
                    close(ftp_sock);
                    return;
                }
                fprintf(stderr, "[tgmux] fd=%d -> %s:%d (ftp, greeting-first)\n",
                        cli, host, fp);
                relay(cli, ftp_sock);
                return;
            }
        }
    }

    target_port = classify(buf, hp, sp, fp, &kind);

    /* 已判定为 FTP 时复用竞速阶段那条连接，避免再握一次手。 */
    if (target_port == fp && ftp_sock >= 0) {
        srv = ftp_sock;
        ftp_sock = -1;
        /* banner 被我们扣下了，客户端先发 USER 的场合要补给 220。 */
        if (blen > 0 && send_all(cli, banner, (size_t)blen) != 0) {
            close(cli);
            close(srv);
            return;
        }
    } else {
        /*
         * 快路径：先把后端地址解析好、连上，再把首包转发过去。
         * 地址解析与建连都是本机调用，通常亚毫秒完成；3proxy 复用了空闲连接池
         * 里的 fd 时，客户端手里那条连接已经在等 CONNECT 应答，我们早一毫秒
         * 把首包送过去它就少等一毫秒。
         */
        struct backaddrs ba;

        if (backend_addrs(host, target_port, &ba) != 0) {
            fprintf(stderr, "[tgmux] cannot resolve backend %s:%d\n",
                    host, target_port);
            close(cli);
            if (ftp_sock >= 0)
                close(ftp_sock);
            return;
        }
        srv = connect_backend_addrs(&ba);
        if (srv < 0) {
            fprintf(stderr, "[tgmux] cannot connect backend %s:%d\n",
                    host, target_port);
            close(cli);
            if (ftp_sock >= 0)
                close(ftp_sock);
            return;
        }
    }
    if (ftp_sock >= 0) {
        close(ftp_sock);        /* 竞速阶段的候选连接用不上了 */
        ftp_sock = -1;
    }
    if (n > 0) {
        got = recv(cli, buf, (size_t)n, 0);
        if (got > 0 && send_all(srv, buf, (size_t)got) != 0) {
            close(cli);
            close(srv);
            return;
        }
    }
    fprintf(stderr, "[tgmux] fd=%d -> %s:%d (%s)\n", cli, host, target_port, kind);
    relay(cli, srv);
}

int main(int argc, char **argv)
{
    int listen_port, hp, sp, fp;
    const char *bind_addr;
    const char *peek_env;
    struct sockaddr_in addr;
    int ls, on = 1;

    if (argc < 5 || argc > 6) {
        usage(argv[0]);
        return 2;
    }
    if (!valid_port(argv[1]) || !valid_port(argv[2]) ||
        !valid_port(argv[3]) || !valid_port(argv[4])) {
        usage(argv[0]);
        return 2;
    }
    listen_port = (int)strtol(argv[1], NULL, 10);
    hp = (int)strtol(argv[2], NULL, 10);
    sp = (int)strtol(argv[3], NULL, 10);
    fp = (int)strtol(argv[4], NULL, 10);
    bind_addr = (argc >= 6) ? argv[5] : "127.0.0.1";

    peek_env = getenv("TWIN_MUX_PEEK_MS");
    if (peek_env != NULL && *peek_env != '\0') {
        long v = strtol(peek_env, NULL, 10);
        if (v > 0)
            peek_ms = (v > 60000) ? 60000 : (int)v;
    }
    if (peek_ms < 50)
        peek_ms = 50;

    peek_env = getenv("TWIN_MUX_FTP_GRACE_MS");
    if (peek_env != NULL && *peek_env != '\0') {
        long v = strtol(peek_env, NULL, 10);
        if (v < 0)
            v = 0;
        ftp_grace_ms = (v > 60000) ? 60000 : (int)v;
    }
    /* 宽限比首包等待还长会让 FTP 比原来更慢，没有意义。 */
    if (ftp_grace_ms > peek_ms)
        ftp_grace_ms = peek_ms;

    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) {
        perror("[tgmux] socket");
        return 1;
    }
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)listen_port);
    if (inet_pton(AF_INET, bind_addr, &addr.sin_addr) != 1) {
        fprintf(stderr, "[tgmux] invalid bind address: %s\n", bind_addr);
        close(ls);
        return 2;
    }
    if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[tgmux] bind");
        close(ls);
        return 1;
    }
    if (listen(ls, 128) < 0) {
        perror("[tgmux] listen");
        close(ls);
        return 1;
    }

    fprintf(stderr,
            "[tgmux] listening on %s:%d -> http:%d socks:%d ftp:%d (peek=%dms grace=%dms)\n",
            bind_addr, listen_port, hp, sp, fp, peek_ms, ftp_grace_ms);

    for (;;) {
        int cli = accept(ls, NULL, NULL);
        pid_t pid;
        if (cli < 0) {
            if (errno == EINTR)
                continue;
            perror("[tgmux] accept");
            continue;
        }
        pid = fork();
        if (pid < 0) {
            close(cli);
            continue;
        }
        if (pid == 0) {
            close(ls);
            handle_client(cli, hp, sp, fp, "127.0.0.1");
            _exit(0);
        }
        close(cli);
    }
}
