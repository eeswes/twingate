/*
 * tgtun - TUN 虚拟网卡探测与出站绑定决策
 *
 * 目的：让 3proxy 的出站流量「接力」到本机 VPN 的 TUN 网卡，而不是物理网卡。
 *
 * 用法：
 *   tgtun plan [--iface DEV] [--bind auto|device|source|direct]
 *              [--route-file F] [--route6-file F] [--net-dir D]
 *   tgtun list [--iface DEV] [--route-file F] [--route6-file F]
 *   tgtun check DEV
 *
 * plan 输出 key=value（每行一个），供 shell 直接解析：
 *   status=ok|none|error           none = 没找到可用的 TUN，error = 指定网卡不存在
 *   iface=tun0                     选中的网卡（没有则为空）
 *   ip4=10.8.0.2  ip6=fc00::2      该网卡的全局地址（没有则为空）
 *   default4=eth0 default6=         承载默认路由的网卡（没有则为空）
 *   carries_default=0|1            选中的网卡是否承载默认路由
 *   device_bind=1|0|-1             SO_BINDTODEVICE 是否被允许（-1 = 探测失败）
 *   mode=direct|device|source|none 出站策略
 *   arg=-Detun0 / -e10.8.0.2       追加到 3proxy 服务行的参数（direct/none 时为空）
 *   reason=...                     决策原因（机器可读，shell 负责翻译）
 *
 * 决策规则（与 README 一致）：
 *   1. 选中的 TUN 已经承载默认路由 —— 系统本来就从它出网，零配置（mode=direct）。
 *   2. 否则把 socket 绑到该网卡：有 CAP_NET_RAW/root 时用 SO_BINDTODEVICE
 *      （3proxy 的 -De<dev>），没有权限时退化为 bind 源地址（-e<ip>）。
 *
 * 说明：/proc/net/route 与 /proc/net/ipv6_route 只反映主路由表，
 *       ip rule / 多路由表（策略路由）看不到；这种情况请显式指定 --iface。
 *
 * 无第三方依赖，glibc 与 bionic 均可编译。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define MAXCAND 8
#define DEVLEN IFNAMSIZ

/* 候选网卡 */
struct cand {
    char name[DEVLEN];
    unsigned flags;
    int has4, has6;
    char ip4[INET_ADDRSTRLEN];
    char ip6[INET6_ADDRSTRLEN];
};

/* 绑定策略：命令行 --bind，auto 表示按探测结果决定 */
enum bindmode { BIND_AUTO, BIND_DEVICE, BIND_SOURCE, BIND_DIRECT };

static const char *route_file = "/proc/net/route";
static const char *route6_file = "/proc/net/ipv6_route";

static int is_tun_name(const char *n)
{
    return strncmp(n, "tun", 3) == 0 || strncmp(n, "utun", 4) == 0;
}

static int find_cand(const struct cand *list, int n, const char *name)
{
    int i;
    for (i = 0; i < n; i++)
        if (strcmp(list[i].name, name) == 0)
            return i;
    return -1;
}

/* 枚举候选网卡：forced 为空时按名字前缀挑 tun* / utun*，否则只认指定网卡。
   返回候选数量，-1 表示 getifaddrs 失败。 */
static int collect(struct cand *list, int max, const char *forced)
{
    struct ifaddrs *head = NULL, *ifa;
    int n = 0;

    if (getifaddrs(&head) != 0)
        return -1;

    for (ifa = head; ifa != NULL; ifa = ifa->ifa_next) {
        int i;
        if (ifa->ifa_name == NULL)
            continue;
        if (forced != NULL) {
            if (strcmp(ifa->ifa_name, forced) != 0)
                continue;
        } else if (!is_tun_name(ifa->ifa_name)) {
            continue;
        }
        i = find_cand(list, n, ifa->ifa_name);
        if (i < 0) {
            if (n >= max)
                continue;
            i = n++;
            memset(&list[i], 0, sizeof(list[i]));
            snprintf(list[i].name, sizeof(list[i].name), "%s", ifa->ifa_name);
        }
        list[i].flags |= ifa->ifa_flags;
        if (ifa->ifa_addr == NULL)
            continue;
        if (ifa->ifa_addr->sa_family == AF_INET && !list[i].has4) {
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, list[i].ip4, sizeof(list[i].ip4)) != NULL)
                list[i].has4 = 1;
        } else if (ifa->ifa_addr->sa_family == AF_INET6 && !list[i].has6) {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ifa->ifa_addr;
            /* 链路本地地址不能当出站源地址用，跳过。 */
            if (!IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr) &&
                inet_ntop(AF_INET6, &sin6->sin6_addr, list[i].ip6, sizeof(list[i].ip6)) != NULL)
                list[i].has6 = 1;
        }
    }
    freeifaddrs(head);
    return n;
}

/* 解析 /proc/net/route，找出承载 IPv4 默认路由的网卡（metric 最小的那条）。
   返回 1 找到、0 没有、-1 读不到文件。 */
static int default_route4(char *dev, size_t len)
{
    FILE *fp;
    char line[512];
    unsigned long best = 0;
    int found = 0;

    fp = fopen(route_file, "r");
    if (fp == NULL)
        return -1;
    /* 跳过表头 */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp);
        return 0;
    }
    while (fgets(line, sizeof(line), fp) != NULL) {
        char ifc[DEVLEN];
        unsigned dest, gw, flags, mask, metric;
        int got;

        got = sscanf(line, "%15s %8x %8x %8x %*u %*u %u %8x",
                     ifc, &dest, &gw, &flags, &metric, &mask);
        if (got != 6)
            continue;
        /* 默认路由 = 目标 0.0.0.0/0、UP 且 GATEWAY */
        if (dest != 0 || mask != 0)
            continue;
        if (!(flags & 0x1) || !(flags & 0x2))
            continue;
        if (!found || metric < best) {
            found = 1;
            best = metric;
            snprintf(dev, len, "%s", ifc);
        }
    }
    fclose(fp);
    return found;
}

static int all_zero(const char *hex)
{
    size_t i;
    for (i = 0; hex[i] != '\0'; i++)
        if (hex[i] != '0')
            return 0;
    return i > 0;
}

/* 解析 /proc/net/ipv6_route，找出 ::/0 所在网卡。字段顺序：
   dest(32) plen(2) src(32) srclen(2) nexthop(32) metric(8) ref(8) use(8) flags(8) dev */
static int default_route6(char *dev, size_t len)
{
    FILE *fp;
    char line[512];
    unsigned long best = 0;
    int found = 0;

    fp = fopen(route6_file, "r");
    if (fp == NULL)
        return -1;
    while (fgets(line, sizeof(line), fp) != NULL) {
        char dst[40], plen[8], metric[16], flags[16], ifc[DEVLEN];
        unsigned long m;
        int got;

        got = sscanf(line, "%39s %7s %*39s %*7s %*39s %15s %*15s %*15s %15s %15s",
                     dst, plen, metric, flags, ifc);
        if (got != 5)
            continue;
        if (!all_zero(dst) || strcmp(plen, "00") != 0)
            continue;
        if (strcmp(ifc, "lo") == 0)
            continue;
        if (sscanf(metric, "%lx", &m) != 1)
            m = 0;
        if (!found || m < best) {
            found = 1;
            best = m;
            snprintf(dev, len, "%s", ifc);
        }
    }
    fclose(fp);
    return found;
}

/* 该网卡是否 up：以 getifaddrs 的 IFF_UP 为准，operstate 只在 list 里展示。 */
static int cand_up(const struct cand *c)
{
    return (c->flags & IFF_UP) != 0;
}

/* 试探 SO_BINDTODEVICE 权限：1 允许、0 明确被拒、-1 探测失败。
   不猜 euid —— 用户命名空间、容器 capability 都可能让 root 也拿不到 CAP_NET_RAW。 */
static int device_bind_allowed(const char *dev)
{
    int s, r, e;

    s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0)
        return -1;
    r = setsockopt(s, SOL_SOCKET, SO_BINDTODEVICE, dev, strlen(dev) + 1);
    e = errno;
    close(s);
    if (r == 0)
        return 1;
    if (e == EPERM || e == EACCES)
        return 0;
    return -1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s plan  [--iface DEV] [--bind auto|device|source|direct]\n"
            "       %s list  [--iface DEV]\n"
            "       %s check DEV\n"
            "  --route-file F    IPv4 路由表（默认 /proc/net/route）\n"
            "  --route6-file F   IPv6 路由表（默认 /proc/net/ipv6_route）\n",
            prog, prog, prog);
}

static int parse_args(int argc, char **argv, const char **iface, enum bindmode *bm)
{
    int i;

    for (i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--iface") == 0) {
            if (++i >= argc)
                return -1;
            *iface = argv[i];
        } else if (strcmp(argv[i], "--bind") == 0) {
            if (++i >= argc)
                return -1;
            if (strcmp(argv[i], "auto") == 0)
                *bm = BIND_AUTO;
            else if (strcmp(argv[i], "device") == 0)
                *bm = BIND_DEVICE;
            else if (strcmp(argv[i], "source") == 0)
                *bm = BIND_SOURCE;
            else if (strcmp(argv[i], "direct") == 0)
                *bm = BIND_DIRECT;
            else
                return -1;
        } else if (strcmp(argv[i], "--route-file") == 0) {
            if (++i >= argc)
                return -1;
            route_file = argv[i];
        } else if (strcmp(argv[i], "--route6-file") == 0) {
            if (++i >= argc)
                return -1;
            route6_file = argv[i];
        } else {
            return -1;
        }
    }
    return 0;
}

/* 选中的网卡是否承载所有存在的默认路由。
   只要有一条默认路由不在它身上（例如 IPv4 走物理网卡），就算「不承载」，
   因为此时系统默认出口不是它。 */
static int carries_default(const struct cand *c, const char *d4, const char *d6)
{
    int any = 0;

    if (d4[0] != '\0') {
        any = 1;
        if (strcmp(d4, c->name) != 0)
            return 0;
    }
    if (d6[0] != '\0') {
        any = 1;
        if (strcmp(d6, c->name) != 0)
            return 0;
    }
    return any;
}

static void print_list(const struct cand *list, int n, const char *d4, const char *d6)
{
    int i;
    for (i = 0; i < n; i++) {
        const char *state = cand_up(&list[i]) ? "up" : "down";
        printf("%-8s %-4s ip4=%-15s ip6=%-24s default=%s\n",
               list[i].name, state,
               list[i].has4 ? list[i].ip4 : "-",
               list[i].has6 ? list[i].ip6 : "-",
               carries_default(&list[i], d4, d6) ? "yes" : "no");
    }
}

int main(int argc, char **argv)
{
    struct cand list[MAXCAND];
    char d4[DEVLEN] = "", d6[DEVLEN] = "";
    const char *iface = NULL;
    enum bindmode bm = BIND_AUTO;
    const char *cmd, *mode = "none", *reason = "";
    char arg[DEVLEN + 8] = "";
    const char *bind_ip = "";
    int n, idx = -1, binds;
    int v4ok, v6ok;

    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }
    cmd = argv[1];

    if (strcmp(cmd, "check") == 0) {
        int r;
        if (argc != 3) {
            usage(argv[0]);
            return 2;
        }
        r = device_bind_allowed(argv[2]);
        printf("%s\n", r == 1 ? "allow" : (r == 0 ? "deny" : "error"));
        return r == 1 ? 0 : 1;
    }
    if (strcmp(cmd, "plan") != 0 && strcmp(cmd, "list") != 0) {
        usage(argv[0]);
        return 2;
    }
    if (parse_args(argc - 2, argv + 2, &iface, &bm) != 0) {
        usage(argv[0]);
        return 2;
    }
    if (iface != NULL && *iface == '\0')
        iface = NULL;

    n = collect(list, MAXCAND, iface);
    if (n < 0) {
        if (strcmp(cmd, "plan") == 0) {
            printf("status=error\nreason=getifaddrs-failed\n");
        } else {
            fprintf(stderr, "tgtun: getifaddrs failed\n");
        }
        return 1;
    }

    v4ok = default_route4(d4, sizeof(d4)) > 0;
    v6ok = default_route6(d6, sizeof(d6)) > 0;
    if (!v4ok)
        d4[0] = '\0';
    if (!v6ok)
        d6[0] = '\0';

    /* 优先挑 up 且有地址的网卡；其次挑承载默认路由的。 */
    {
        int i, best = -1, best_score = -1;
        for (i = 0; i < n; i++) {
            int score = 0;
            if (!cand_up(&list[i]))
                continue;
            if (list[i].has4 || list[i].has6)
                score += 2;
            if (carries_default(&list[i], d4, d6))
                score += 3;
            if (score > best_score) {
                best_score = score;
                best = i;
            }
        }
        /* 全部 down / 无地址时也保留第一个，交给下面报 no-address。 */
        idx = (best >= 0) ? best : (n > 0 ? 0 : -1);
    }

    if (strcmp(cmd, "list") == 0) {
        if (n == 0)
            printf("%s\n", iface ? "not-found" : "none");
        else
            print_list(list, n, d4, d6);
        return n == 0 ? 2 : 0;
    }

    if (iface != NULL && n == 0) {
        printf("status=error\nreason=iface-not-found\niface=%s\n", iface);
        return 1;
    }
    if (n == 0 || idx < 0) {
        printf("status=none\nreason=no-iface\nmode=none\n");
        return 2;
    }

    {
        const struct cand *c = &list[idx];
        int carries = carries_default(c, d4, d6);

        if (!cand_up(c) || (!c->has4 && !c->has6)) {
            printf("status=error\niface=%s\nreason=no-address\nmode=none\n", c->name);
            printf("ip4=%s\nip6=%s\n", c->ip4, c->ip6);
            return 1;
        }

        binds = device_bind_allowed(c->name);

        if (bm == BIND_DIRECT) {
            mode = "direct";
            reason = "forced-direct";
        } else if (bm == BIND_DEVICE) {
            mode = "device";

            reason = "forced-device";
            snprintf(arg, sizeof(arg), "-De%s", c->name);
        } else if (bm == BIND_SOURCE) {
            mode = "source";
            bind_ip = c->has4 ? c->ip4 : c->ip6;
            reason = "forced-source";
            snprintf(arg, sizeof(arg), "-e%s", bind_ip);
        } else if (carries) {
            /* 系统本来就走这张网卡，什么都不用加。 */
            mode = "direct";
            reason = "carries-default";
        } else if (binds == 1) {
            mode = "device";

            reason = "no-default-route";
            snprintf(arg, sizeof(arg), "-De%s", c->name);
        } else {
            /* 没有 CAP_NET_RAW：只能绑源地址，路由仍由系统决定。 */
            mode = "source";
            bind_ip = c->has4 ? c->ip4 : c->ip6;
            reason = (binds == 0) ? "device-denied" : "device-unsupported";
            snprintf(arg, sizeof(arg), "-e%s", bind_ip);
        }

        printf("status=ok\n");
        printf("iface=%s\n", c->name);
        printf("ip4=%s\n", c->has4 ? c->ip4 : "");
        printf("ip6=%s\n", c->has6 ? c->ip6 : "");
        printf("default4=%s\ndefault6=%s\n", d4, d6);
        printf("carries_default=%d\n", carries);
        printf("device_bind=%d\n", binds);
        printf("mode=%s\narg=%s\nreason=%s\n", mode, arg, reason);
    }
    return 0;
}
