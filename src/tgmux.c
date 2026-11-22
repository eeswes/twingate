/*
 * tgmux - TwinGate single-port protocol demultiplexer
 *
 * Reads the very first bytes of an incoming connection and forwards the
 * session to the matching 3proxy backend:
 *
 *   0x04 / 0x05        -> SOCKS
 *   'U'/'u'/'O'/'o'    -> FTP proxy (USER / OPEN)
 *   no data in time    -> FTP proxy, because ftppr sends the 220 banner first
 *   anything else      -> HTTP proxy (GET/POST/CONNECT/...)
 *
 * Usage:
 *   tgmux <listen_port> <http_port> <socks_port> <ftp_port> [bind_addr]
 *
 * Environment:
 *   TWIN_MUX_PEEK_MS   time to wait for the first client byte (default 500)
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
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static int peek_ms = 500;

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

static void handle_client(int cli, int hp, int sp, int fp, const char *host)
{
    unsigned char first[64];
    ssize_t n = 0;
    struct pollfd p;
    int target_port;
    const char *kind;
    int srv, got;

    p.fd = cli;
    p.events = POLLIN;
    p.revents = 0;
    if (poll(&p, 1, peek_ms) > 0 && (p.revents & POLLIN)) {
        n = recv(cli, first, sizeof(first), MSG_PEEK);
        if (n < 0)
            n = 0;
    }

    if (n <= 0) {
        /* FTP proxy speaks first: ftppr sends "220 Ready" on connect. */
        target_port = fp;
        kind = "ftp(greeting-first)";
    } else if (first[0] == 4 || first[0] == 5) {
        target_port = sp;
        kind = "socks";
    } else if (first[0] == 'U' || first[0] == 'u' ||
               first[0] == 'O' || first[0] == 'o') {
        target_port = fp;
        kind = "ftp";
    } else {
        target_port = hp;
        kind = "http";
    }

    srv = connect_backend(host, target_port);
    if (srv < 0) {
        fprintf(stderr, "[tgmux] cannot connect backend %s:%d\n", host, target_port);
        close(cli);
        return;
    }
    if (n > 0) {
        got = recv(cli, first, (size_t)n, 0);
        if (got > 0 && send_all(srv, first, (size_t)got) != 0) {
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

    fprintf(stderr, "[tgmux] listening on %s:%d -> http:%d socks:%d ftp:%d (peek=%dms)\n",
            bind_addr, listen_port, hp, sp, fp, peek_ms);

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
