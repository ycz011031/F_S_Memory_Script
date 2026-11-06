/*
 * alias-rdma: RDMA READ load whose landing pages follow an aliasing pattern
 * (alias_common.h): the in-house replacement for iperf3 in the NIC campaign.
 *
 * The host under test (icx, NICs behind PIPS) runs the CLIENT. It posts
 * one-sided RDMA READs to a SERVER (styx), and its own NIC writes the
 * responses into a local MR, one scatter entry per 4 KiB page, in the
 * pattern's order. Data moves as in the iperf3 campaign: the NIC behind the
 * switch writes into icx memory (MWr upstream through PIPS). The MR is
 * registered once and stays mapped: no map/unmap per packet, so in strict and
 * lazy mode the IOTLB misses come from the pattern, not from invalidations.
 * The kernel size-aligns the MR's IOVA range, so region page k sits at IOVA
 * page base + k with base's low bits zero (see alias_common.h). The server
 * side is a plain registered buffer: nothing there is measured.
 *
 *   styx: alias-rdma --role server --netdev ens1f1np1 --port 18600
 *   icx:  alias-rdma --role client --netdev enp153s0f0np0 --server-ip 192.168.10.52 \
 *             --port 18600 --qps 4 --depth 16 --bs 4096 --ws 32 --stride 512 \
 *             --warm 10 --seconds 120 --out logs/run/fio-nic0
 *
 * Client options:
 *   --server-ip A --port N    the server (TCP bootstrap; retried for 30 s)
 *   --netdev IF | --ib-dev D  the local NIC (IF resolves to its RDMA device and GID)
 *   --qps N                   queue pairs (default 4); one thread polls them all
 *   --depth N                 logical READs in flight per QP (default 16); the
 *                             wire depth is capped at the devices' rd_atom
 *   --bs BYTES                bytes per logical READ (default 4096): below 4096
 *                             one entry in one page, else whole pages, each from
 *                             the pattern (split into several READs past the
 *                             device's scatter limit; one completion per READ group)
 *   --ws --stride --first --order --seed --page-list --backing-pages: the pattern
 *   --warm S --seconds S      warm-up, then measure S seconds (0 = until SIGINT/TERM)
 *   --out PREFIX              PREFIX.json and PREFIX_iops.1.log (fio's format)
 *   --name NAME --cpu C --heartbeat S --ready-file PATH (touched once loaded)
 * Server options: --netdev/--ib-dev, --port, --heartbeat. It serves one client
 * and exits when that client closes the connection (or on SIGINT/TERM).
 * Exit: 0 done, 2 usage/setup, 3 a READ failed (the run is not valid).
 */
#include "alias_common.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <infiniband/verbs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>

#define MAGIC 0x414c4941u   /* "ALIA" */
#define VERSION 1
#define MAXQ 64
#define MAXWR 16            /* READs per logical I/O */
#define MAXSGE 32

static uint64_t g_backing;  /* --backing-pages (0: the default) */

struct hello {
    uint32_t magic, version, nqps, mtu, rd_atom, rkey;
    uint64_t addr, len;
    uint8_t gid[16];
    uint32_t qpn[MAXQ], psn[MAXQ];
} __attribute__((packed));

struct dev {
    char name[64], netdev[64];
    int port, gid_index;
    struct ibv_context *ctx;
    struct ibv_pd *pd;
    struct ibv_device_attr attr;
    struct ibv_port_attr pattr;
    union ibv_gid gid;
};

static int read_line(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, (int)n, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    buf[strcspn(buf, "\n")] = 0;
    return 0;
}

/* The RDMA device behind a netdev: /sys/class/net/IF/device/infiniband/<dev>. */
static void netdev_to_ibdev(const char *netdev, char *out, size_t n)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/class/net/%s/device/infiniband", netdev);
    DIR *d = opendir(path);
    if (!d)
        die("%s: no RDMA device (is it an mlx5 port with RoCE?)", netdev);
    struct dirent *e;
    out[0] = 0;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.') {
            snprintf(out, n, "%.63s", e->d_name);   /* names are short (mlx5_2) */
            break;
        }
    closedir(d);
    if (!out[0])
        die("%s: no RDMA device under %s", netdev, path);
}

/* A RoCE v2 GID with an IPv4 address, on the netdev when one is given. */
static int pick_gid(struct dev *d)
{
    char p[384], v[128];
    for (int i = 0; i < 256; i++) {
        snprintf(p, sizeof(p), "/sys/class/infiniband/%s/ports/%d/gid_attrs/types/%d", d->name, d->port, i);
        if (read_line(p, v, sizeof(v)) || strncmp(v, "RoCE v2", 7))
            continue;
        snprintf(p, sizeof(p), "/sys/class/infiniband/%s/ports/%d/gids/%d", d->name, d->port, i);
        if (read_line(p, v, sizeof(v)) || strncmp(v, "0000:0000:0000:0000:0000:ffff:", 30))
            continue;
        if (d->netdev[0]) {
            snprintf(p, sizeof(p), "/sys/class/infiniband/%s/ports/%d/gid_attrs/ndevs/%d", d->name, d->port, i);
            if (read_line(p, v, sizeof(v)) || strcmp(v, d->netdev))
                continue;
        }
        return i;
    }
    return -1;
}

static void dev_open(struct dev *d)
{
    if (d->netdev[0] && !d->name[0])
        netdev_to_ibdev(d->netdev, d->name, sizeof(d->name));
    int n = 0;
    struct ibv_device **list = ibv_get_device_list(&n);
    if (!list)
        die("ibv_get_device_list: %s", strerror(errno));
    for (int i = 0; i < n; i++)
        if (!strcmp(ibv_get_device_name(list[i]), d->name))
            d->ctx = ibv_open_device(list[i]);
    ibv_free_device_list(list);
    if (!d->ctx)
        die("cannot open RDMA device %s", d->name);
    if (ibv_query_device(d->ctx, &d->attr) || ibv_query_port(d->ctx, (uint8_t)d->port, &d->pattr))
        die("%s: query device/port failed", d->name);
    if (d->pattr.state != IBV_PORT_ACTIVE)
        die("%s port %d is not active", d->name, d->port);
    d->gid_index = pick_gid(d);
    if (d->gid_index < 0)
        die("%s port %d: no RoCE v2 IPv4 GID%s%s (is the address set?)", d->name, d->port,
            d->netdev[0] ? " on " : "", d->netdev);
    if (ibv_query_gid(d->ctx, (uint8_t)d->port, d->gid_index, &d->gid))
        die("%s: query GID %d failed", d->name, d->gid_index);
    d->pd = ibv_alloc_pd(d->ctx);
    if (!d->pd)
        die("%s: ibv_alloc_pd failed", d->name);
    printf("alias-rdma: device %s%s%s port %d, GID index %d, active MTU %d, rd_atom %d/%d, max_sge_rd %d\n",
           d->name, d->netdev[0] ? " (" : "", d->netdev[0] ? d->netdev : "", d->port, d->gid_index,
           128 << d->pattr.active_mtu, d->attr.max_qp_rd_atom, d->attr.max_qp_init_rd_atom,
           d->attr.max_sge_rd);
}

static struct ibv_qp *qp_create(struct dev *d, struct ibv_cq *cq, uint32_t send_wr, uint32_t sge, int access)
{
    struct ibv_qp_init_attr ia = {
        .send_cq = cq, .recv_cq = cq, .qp_type = IBV_QPT_RC,
        .cap = { .max_send_wr = send_wr, .max_recv_wr = 1, .max_send_sge = sge, .max_recv_sge = 1 },
    };
    struct ibv_qp *qp = ibv_create_qp(d->pd, &ia);
    if (!qp)
        die("ibv_create_qp (send_wr %u, sge %u): %s", send_wr, sge, strerror(errno));
    struct ibv_qp_attr a = { .qp_state = IBV_QPS_INIT, .pkey_index = 0,
                             .port_num = (uint8_t)d->port, .qp_access_flags = access };
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS))
        die("QP to INIT: %s", strerror(errno));
    return qp;
}

static void qp_connect(struct dev *d, struct ibv_qp *qp, uint32_t rqpn, uint32_t rpsn, uint32_t lpsn,
                       const uint8_t *rgid, int mtu, int dest_rd, int rd)
{
    struct ibv_qp_attr a;
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTR;
    a.path_mtu = (enum ibv_mtu)mtu;
    a.dest_qp_num = rqpn;
    a.rq_psn = rpsn;
    a.max_dest_rd_atomic = (uint8_t)dest_rd;
    a.min_rnr_timer = 12;
    a.ah_attr.is_global = 1;
    a.ah_attr.port_num = (uint8_t)d->port;
    memcpy(a.ah_attr.grh.dgid.raw, rgid, 16);
    a.ah_attr.grh.sgid_index = (uint8_t)d->gid_index;
    a.ah_attr.grh.hop_limit = 64;
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
                      IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
        die("QP to RTR: %s", strerror(errno));
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTS;
    a.timeout = 14;
    a.retry_cnt = 7;
    a.rnr_retry = 7;
    a.sq_psn = lpsn;
    a.max_rd_atomic = (uint8_t)rd;
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                      IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC))
        die("QP to RTS: %s", strerror(errno));
}

static int io_full(int fd, void *buf, size_t n, int wr)
{
    unsigned char *p = buf;
    while (n) {
        ssize_t k = wr ? write(fd, p, n) : read(fd, p, n);
        if (k < 0 && errno == EINTR && !g_stop)
            continue;
        if (k <= 0)
            return -1;
        p += k;
        n -= (size_t)k;
    }
    return 0;
}

static void touch(const char *path)
{
    if (!path || !path[0])
        return;
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%d\n", (int)getpid());
        fclose(f);
    }
}

/* ------------------------------------------------------------ server */
static int run_server(struct dev *d, int port, int hb)
{
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port),
                              .sin_addr.s_addr = htonl(INADDR_ANY) };
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (ls < 0 || bind(ls, (struct sockaddr *)&sa, sizeof(sa)) || listen(ls, 1))
        die("TCP port %d: %s", port, strerror(errno));
    printf("alias-rdma server: listening on TCP %d\n", port);
    fflush(stdout);
    uint64_t t0 = now_ns();
    int cs = -1;
    while (!g_stop && cs < 0) {
        struct pollfd pf = { .fd = ls, .events = POLLIN };
        int r = poll(&pf, 1, hb * 1000);
        if (r > 0)
            cs = accept(ls, NULL, NULL);
        else if (r == 0)
            printf("alias-rdma server: waiting for a client, %.0f s\n", (double)(now_ns() - t0) / 1e9);
        fflush(stdout);
    }
    close(ls);
    if (cs < 0)
        return 0;
    struct hello in, outh;
    if (io_full(cs, &in, sizeof(in), 0) || in.magic != MAGIC || in.version != VERSION ||
        !in.nqps || in.nqps > MAXQ)
        die("bad hello from the client (another program on this port?)");
    uint64_t len = in.len < (1u << 20) ? (1u << 20) : in.len;
    void *buf = NULL;
    if (posix_memalign(&buf, ALIAS_PAGE, len))
        die("server buffer of %" PRIu64 " bytes", len);
    memset(buf, 0x5a, len);
    struct ibv_mr *mr = ibv_reg_mr(d->pd, buf, len, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ);
    if (!mr)
        die("server ibv_reg_mr: %s", strerror(errno));
    struct ibv_cq *cq = ibv_create_cq(d->ctx, 64, NULL, NULL, 0);
    if (!cq)
        die("server ibv_create_cq");
    memset(&outh, 0, sizeof(outh));
    outh.magic = MAGIC; outh.version = VERSION; outh.nqps = in.nqps;
    outh.mtu = d->pattr.active_mtu; outh.rd_atom = (uint32_t)d->attr.max_qp_rd_atom;
    outh.addr = (uint64_t)(uintptr_t)buf; outh.len = len; outh.rkey = mr->rkey;
    memcpy(outh.gid, d->gid.raw, 16);
    int mtu = (int)(in.mtu < outh.mtu ? in.mtu : outh.mtu);
    struct ibv_qp *qp[MAXQ];
    srand48((long)getpid() ^ (long)time(NULL));
    for (uint32_t i = 0; i < in.nqps; i++) {
        qp[i] = qp_create(d, cq, 4, 1, IBV_ACCESS_REMOTE_READ);
        outh.qpn[i] = qp[i]->qp_num;
        outh.psn[i] = (uint32_t)lrand48() & 0xffffff;
        qp_connect(d, qp[i], in.qpn[i], in.psn[i], outh.psn[i], in.gid, mtu,
                   d->attr.max_qp_rd_atom, 1);
    }
    if (io_full(cs, &outh, sizeof(outh), 1))
        die("send hello to the client");
    printf("alias-rdma server: serving %u QP(s), MTU %d, region %" PRIu64 " KiB\n",
           in.nqps, 128 << mtu, len >> 10);
    fflush(stdout);
    char c;
    uint64_t t1 = now_ns();
    while (!g_stop) {          /* until the client closes the connection */
        struct pollfd pf = { .fd = cs, .events = POLLIN };
        int r = poll(&pf, 1, hb * 1000);
        if (r > 0) {
            if (read(cs, &c, 1) <= 0)
                break;
        } else if (r == 0) {
            printf("alias-rdma server: serving, %.0f s\n", (double)(now_ns() - t1) / 1e9);
            fflush(stdout);
        }
    }
    printf("alias-rdma server: client gone after %.0f s, exiting\n", (double)(now_ns() - t1) / 1e9);
    for (uint32_t i = 0; i < in.nqps; i++)
        ibv_destroy_qp(qp[i]);
    ibv_destroy_cq(cq);
    ibv_dereg_mr(mr);
    close(cs);
    return 0;
}

/* ------------------------------------------------------------ client */
struct client {
    struct dev *d;
    struct alias_pattern pat;
    uint32_t nqps, depth, bs, pages, sge, wrs;    /* pages per logical READ, scatter per READ, READs */
    struct ibv_qp *qp[MAXQ];
    struct ibv_cq *cq;
    struct ibv_mr *mr;
    unsigned char *region;
    uint64_t raddr, rlen;
    uint32_t rkey;
    uint64_t *t0;                                  /* submit time per (qp, slot) */
    struct alias_cursor cur;
    uint64_t rnext;                                /* remote offset, cycles */
    struct alias_stats st;
    int measuring;
};

static int post_io(struct client *c, uint32_t q, uint32_t slot)
{
    struct ibv_send_wr wr[MAXWR], *bad = NULL;
    struct ibv_sge sg[MAXWR][MAXSGE];
    uint32_t left = c->pages ? c->pages : 1;
    uint64_t roff = c->rnext;
    c->rnext += c->bs;
    if (c->rnext + c->bs > c->rlen)
        c->rnext = 0;
    for (uint32_t w = 0; w < c->wrs; w++) {
        uint32_t n = left < c->sge ? left : c->sge;
        for (uint32_t k = 0; k < n; k++) {
            uint64_t pg = pattern_next(&c->pat, &c->cur);
            sg[w][k].addr = (uint64_t)(uintptr_t)(c->region + pg * ALIAS_PAGE);
            sg[w][k].length = c->pages ? (uint32_t)ALIAS_PAGE : c->bs;
            sg[w][k].lkey = c->mr->lkey;
        }
        memset(&wr[w], 0, sizeof(wr[w]));
        wr[w].wr_id = ((uint64_t)q << 32) | slot;
        wr[w].sg_list = sg[w];
        wr[w].num_sge = (int)n;
        wr[w].opcode = IBV_WR_RDMA_READ;
        wr[w].send_flags = w == c->wrs - 1 ? IBV_SEND_SIGNALED : 0;
        wr[w].wr.rdma.remote_addr = c->raddr + roff;
        wr[w].wr.rdma.rkey = c->rkey;
        wr[w].next = w == c->wrs - 1 ? NULL : &wr[w + 1];
        roff += (uint64_t)n * (c->pages ? ALIAS_PAGE : c->bs);
        left -= n;
    }
    c->t0[(uint64_t)q * c->depth + slot] = now_ns();
    int r = ibv_post_send(c->qp[q], wr, &bad);
    if (r)
        fprintf(stderr, "ERROR: ibv_post_send on QP %u: %s\n", q, strerror(r));
    return r;
}

static int connect_tcp(const char *ip, int port)
{
    char ps[16];
    snprintf(ps, sizeof(ps), "%d", port);
    uint64_t t0 = now_ns();
    for (int tries = 0; !g_stop; tries++) {
        struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *res = NULL;
        if (getaddrinfo(ip, ps, &hints, &res) == 0) {
            int s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
            if (s >= 0 && connect(s, res->ai_addr, res->ai_addrlen) == 0) {
                freeaddrinfo(res);
                return s;
            }
            if (s >= 0)
                close(s);
            freeaddrinfo(res);
        }
        if (now_ns() - t0 > 30000000000ull)
            die("no alias-rdma server at %s:%d after 30 s", ip, port);
        if (tries % 10 == 0)
            printf("alias-rdma client: waiting for the server at %s:%d\n", ip, port);
        fflush(stdout);
        usleep(200000);
    }
    exit(2);
}

static int run_client(struct client *c, const char *ip, int port, double warm, double secs,
                      const char *out, const char *name, int hb, const char *ready)
{
    struct dev *d = c->d;
    char who[160];
    snprintf(who, sizeof(who), "alias-rdma %s", name);
    pattern_build(&c->pat);
    pattern_print(&c->pat, stdout, who);

    /* scatter: whole pages from the pattern, at most the device's per-READ limit */
    if (c->bs < ALIAS_PAGE) {
        c->pages = 0; c->sge = 1; c->wrs = 1;
    } else {
        if (c->bs % ALIAS_PAGE)
            die("--bs %u: below 4096 or a multiple of it", c->bs);
        c->pages = c->bs / (uint32_t)ALIAS_PAGE;
        int lim = d->attr.max_sge_rd > 0 ? d->attr.max_sge_rd : d->attr.max_sge;
        c->sge = (uint32_t)(lim < MAXSGE ? lim : MAXSGE);
        if (c->sge > c->pages)
            c->sge = c->pages;
        c->wrs = (c->pages + c->sge - 1) / c->sge;
        if (c->wrs > MAXWR)
            die("--bs %u needs %u READs of %u pages (at most %d)", c->bs, c->wrs, c->sge, MAXWR);
    }

    struct alias_backing bk;
    backing_create(&bk, g_backing ? g_backing : backing_default(c->pat.span));
    c->region = backing_region(&bk, c->pat.span);
    c->mr = ibv_reg_mr(d->pd, c->region, c->pat.span * ALIAS_PAGE, IBV_ACCESS_LOCAL_WRITE);
    if (!c->mr)
        die("ibv_reg_mr of %" PRIu64 " pages: %s (sudo, or ulimit -l unlimited)", c->pat.span, strerror(errno));
    printf("%s: MR %p, %" PRIu64 " pages over %" PRIu64 " backing pages, lkey 0x%x; "
           "%u page(s) per logical READ in %u READ(s) of <= %u entries\n",
           who, (void *)c->region, c->pat.span, bk.pages, c->mr->lkey, c->pages ? c->pages : 1, c->wrs, c->sge);

    c->cq = ibv_create_cq(d->ctx, (int)(c->nqps * c->depth + 64), NULL, NULL, 0);
    if (!c->cq)
        die("ibv_create_cq (%u entries)", c->nqps * c->depth + 64);
    struct hello h, sv;
    memset(&h, 0, sizeof(h));
    h.magic = MAGIC; h.version = VERSION; h.nqps = c->nqps; h.mtu = d->pattr.active_mtu;
    h.rd_atom = (uint32_t)d->attr.max_qp_init_rd_atom;
    h.len = (uint64_t)c->bs * 64;
    memcpy(h.gid, d->gid.raw, 16);
    srand48((long)getpid() ^ (long)time(NULL));
    for (uint32_t i = 0; i < c->nqps; i++) {
        c->qp[i] = qp_create(d, c->cq, c->depth * c->wrs + 1, c->sge, 0);
        h.qpn[i] = c->qp[i]->qp_num;
        h.psn[i] = (uint32_t)lrand48() & 0xffffff;
    }
    int s = connect_tcp(ip, port);
    if (io_full(s, &h, sizeof(h), 1) || io_full(s, &sv, sizeof(sv), 0) || sv.magic != MAGIC ||
        sv.nqps != c->nqps)
        die("hello with the server at %s:%d failed", ip, port);
    int mtu = (int)(h.mtu < sv.mtu ? h.mtu : sv.mtu);
    uint32_t rd = c->depth * c->wrs;
    if (rd > (uint32_t)d->attr.max_qp_init_rd_atom) rd = (uint32_t)d->attr.max_qp_init_rd_atom;
    if (rd > sv.rd_atom) rd = sv.rd_atom;
    if (rd < 1) rd = 1;
    for (uint32_t i = 0; i < c->nqps; i++)
        qp_connect(d, c->qp[i], sv.qpn[i], sv.psn[i], h.psn[i], sv.gid, mtu, 1, (int)rd);
    c->raddr = sv.addr; c->rlen = sv.len; c->rkey = sv.rkey;
    printf("%s: connected to %s:%d, %u QP(s) x depth %u, MTU %d, %u READs on the wire per QP, "
           "bs %u\n", who, ip, port, c->nqps, c->depth, 128 << mtu, rd, c->bs);

    c->t0 = calloc((size_t)c->nqps * c->depth, sizeof(*c->t0));
    if (!c->t0)
        die("out of memory");
    cursor_init(&c->pat, &c->cur, 0, 1);
    struct alias_out o;
    out_open(&o, out, name);
    uint64_t inflight = 0;
    int err = 0;
    for (uint32_t q = 0; q < c->nqps && !err; q++)
        for (uint32_t k = 0; k < c->depth && !err; k++) {
            if (post_io(c, q, k)) err = 1;
            else inflight++;
        }
    touch(ready);
    printf("%s: READY, %" PRIu64 " READ group(s) in flight\n", who, inflight);
    fflush(stdout);

    uint64_t t0 = now_ns(), next_tick = t0 + 1000000000ull, next_hb = t0 + (uint64_t)hb * 1000000000ull;
    uint64_t warm_end = t0 + (uint64_t)(warm * 1e9), stop_at = secs > 0 ? warm_end + (uint64_t)(secs * 1e9) : 0;
    double last_iops = 0;
    struct ibv_wc wc[64];
    int stopping = 0;
    uint64_t drain_until = 0;
    for (unsigned spin = 0; ; spin++) {
        int n = ibv_poll_cq(c->cq, 64, wc);
        if (n < 0) {
            fprintf(stderr, "ERROR: ibv_poll_cq failed\n");
            err = 1;
            n = 0;
        }
        uint64_t t = n ? now_ns() : 0;
        for (int i = 0; i < n; i++) {
            uint32_t q = (uint32_t)(wc[i].wr_id >> 32), k = (uint32_t)wc[i].wr_id;
            inflight--;
            if (wc[i].status != IBV_WC_SUCCESS) {
                fprintf(stderr, "ERROR: READ on QP %u failed: %s (%d), vendor 0x%x\n", q,
                        ibv_wc_status_str(wc[i].status), wc[i].status, wc[i].vendor_err);
                err = 1;
                continue;
            }
            stats_add(&c->st, c->bs, t - c->t0[(uint64_t)q * c->depth + k], o.started);
            if (!stopping && !err) {
                if (post_io(c, q, k)) err = 1;
                else inflight++;
            }
        }
        if (n && (spin & 63))
            continue;
        t = now_ns();
        if (!o.started && t >= warm_end)
            out_start(&o, &c->st);
        if (t >= next_tick) {
            last_iops = out_sample(&o, &c->st, c->bs);
            next_tick += 1000000000ull;
            if (next_tick < t) next_tick = t + 1000000000ull;
        }
        if (t >= next_hb) {
            printf("%s: t=%.0fs %s %.1f kIOPS %.2f Gb/s, %" PRIu64 " in flight\n", who,
                   (double)(t - t0) / 1e9, o.started ? "measuring" : "warming", last_iops / 1e3,
                   last_iops * c->bs * 8 / 1e9, inflight);
            fflush(stdout);
            next_hb += (uint64_t)hb * 1000000000ull;
        }
        if (!stopping && (g_stop || err || (stop_at && t >= stop_at))) {
            stopping = 1;
            drain_until = t + 5000000000ull;
        }
        if (stopping && (inflight == 0 || t >= drain_until))
            break;
    }
    if (inflight)
        fprintf(stderr, "WARNING: %" PRIu64 " READ group(s) still in flight after 5 s\n", inflight);
    char extra[1024];
    snprintf(extra, sizeof(extra),
             "\"tool\": \"alias-rdma\", \"device\": \"%s\", \"server\": \"%s:%d\", \"qps\": %u, "
             "\"depth\": %u, \"bs\": %u, \"wire_rd\": %u, \"mtu\": %d, \"ws\": %" PRIu64
             ", \"stride\": %" PRIu64 ", \"first\": %" PRIu64 ", \"order\": \"%s\", \"span_pages\": %" PRIu64
             ", \"backing_pages\": %" PRIu64 ", \"page_list\": \"%s\"",
             d->name, ip, port, c->nqps, c->depth, c->bs, rd, 128 << mtu, c->pat.ws, c->pat.stride,
             c->pat.first, order_name(c->pat.order), c->pat.span, bk.pages,
             c->pat.list_path ? c->pat.list_path : "");
    out_close(&o, &c->st, extra, err);
    uint64_t ios = c->st.ios - o.ios0;
    double sec = o.started ? (double)(now_ns() - o.start_ns) / 1e9 : 0;
    printf("%s: done: %" PRIu64 " READ groups in %.1f s measured, %.1f kIOPS, %.2f Gb/s, "
           "mean %.1f us, p99 %.1f us%s\n", who, ios, sec, sec ? ios / sec / 1e3 : 0,
           sec ? ios * (double)c->bs * 8 / sec / 1e9 : 0,
           c->st.lat_n ? (double)c->st.lat_sum_ns / c->st.lat_n / 1e3 : 0, stats_pct(&c->st, 0.99) / 1e3,
           err ? " (FAILED)" : "");
    close(s);                  /* the server exits on this */
    for (uint32_t i = 0; i < c->nqps; i++)
        ibv_destroy_qp(c->qp[i]);
    ibv_destroy_cq(c->cq);
    ibv_dereg_mr(c->mr);
    return err ? 3 : 0;
}

static void usage(void)
{
    puts("alias-rdma --role server --netdev IF [--port N]\n"
         "alias-rdma --role client --netdev IF --server-ip A [--port N] [--qps N] [--depth N] [--bs B]\n"
         "           [--ws N] [--stride N] [--first N] [--order cyclic|shuffle|random] [--seed N]\n"
         "           [--page-list PATH] [--backing-pages N] [--warm S] [--seconds S] [--out PREFIX]\n"
         "           [--name NAME] [--cpu C] [--heartbeat S] [--ready-file PATH]\n"
         "(the comment at the top of alias-rdma.c says what each does)");
}

int main(int argc, char **argv)
{
    struct dev d;
    struct client c;
    memset(&d, 0, sizeof(d));
    memset(&c, 0, sizeof(c));
    d.port = 1;
    pattern_defaults(&c.pat);
    c.nqps = 4; c.depth = 16; c.bs = 4096; c.d = &d;
    const char *role = NULL, *ip = NULL, *out = "alias-rdma", *name = "alias-rdma", *ready = NULL;
    int port = 18600, cpu = -1, hb = 5;
    double warm = 0, secs = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
#define ARG(s) (!strcmp(a, s) && v && ++i)
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
        else if (ARG("--role")) role = v;
        else if (ARG("--netdev")) snprintf(d.netdev, sizeof(d.netdev), "%s", v);
        else if (ARG("--ib-dev")) snprintf(d.name, sizeof(d.name), "%s", v);
        else if (ARG("--ib-port")) d.port = (int)parse_u64(a, v);
        else if (ARG("--port")) port = (int)parse_u64(a, v);
        else if (ARG("--server-ip")) ip = v;
        else if (ARG("--qps")) c.nqps = (uint32_t)parse_u64(a, v);
        else if (ARG("--depth")) c.depth = (uint32_t)parse_u64(a, v);
        else if (ARG("--bs")) c.bs = (uint32_t)parse_u64(a, v);
        else if (ARG("--ws")) c.pat.ws = parse_u64(a, v);
        else if (ARG("--stride")) c.pat.stride = parse_u64(a, v);
        else if (ARG("--first")) c.pat.first = parse_u64(a, v);
        else if (ARG("--order")) c.pat.order = parse_order(v);
        else if (ARG("--seed")) c.pat.seed = parse_u64(a, v);
        else if (ARG("--page-list")) c.pat.list_path = v;
        else if (ARG("--backing-pages")) g_backing = parse_u64(a, v);
        else if (ARG("--warm")) warm = atof(v);
        else if (ARG("--seconds")) secs = atof(v);
        else if (ARG("--out")) out = v;
        else if (ARG("--name")) name = v;
        else if (ARG("--cpu")) cpu = (int)parse_u64(a, v);
        else if (ARG("--heartbeat")) hb = (int)parse_u64(a, v);
        else if (ARG("--ready-file")) ready = v;
        else { usage(); die("unknown or incomplete option '%s'", a); }
#undef ARG
    }
    if (!role || (strcmp(role, "server") && strcmp(role, "client")))
        die("--role server or --role client");
    if (!d.netdev[0] && !d.name[0])
        die("--netdev IF or --ib-dev DEV");
    if (hb < 1) hb = 1;
    stop_on_signals();
    pin_cpu(cpu);
    dev_open(&d);
    if (!strcmp(role, "server"))
        return run_server(&d, port, hb);
    if (!ip)
        die("--server-ip is required for the client");
    if (!c.nqps || c.nqps > MAXQ || !c.depth || !c.bs)
        die("--qps 1-%d, --depth and --bs at least 1", MAXQ);
    return run_client(&c, ip, port, warm, secs, out, name, hb, ready);
}
