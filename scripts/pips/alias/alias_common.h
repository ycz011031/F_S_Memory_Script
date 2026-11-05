/*
 * alias_common.h: what alias-nvme and alias-rdma share.
 *
 * The page pattern. A device writes into pages first + i * stride of a
 * region (i < ws), visited cyclic, in one fixed shuffled order, or at random.
 * The region's IOVA is aligned at least to its own size (alias-nvme places it
 * itself; the kernel's IOVA allocator size-aligns an RDMA MR), so page k's
 * IOVA page number has k in its low bits, and the low bits are what an IOTLB
 * set index is made of:
 *   stride 1, ws above the IOTLB's entries      capacity misses (the curve's
 *                                               knee is the entry count)
 *   stride a multiple of the set count, ws just conflict misses (all pages in
 *   above the ways                              one set; few pages in all)
 * Both are two corners of one (ws, stride) plane; the campaign sweeps both
 * axes. --page-list gives the pages outright.
 *
 * The backing. ws * stride pages of distinct memory would be gigabytes at a
 * large stride, and the IOTLB keys on IOVA, not on the physical page. So the
 * region repeats --backing-pages physical pages (a memfd mapped again and
 * again): every IOVA page is mapped and DMA-able, but only that many are
 * distinct in memory.
 *
 * The output: per instance the files fio would have written for the runners
 * (run-dualssd-experiment.sh, run-dualnic-experiment.sh) and
 * dualssd-results.py fio-sum: <prefix>.json (jobs[0].read: iops, bw_bytes,
 * io_bytes, total_ios, runtime, lat_ns.mean, clat_ns.percentile, job_start)
 * and <prefix>_iops.1.log (epoch_ms, iops, 0, bs, 0 per second), both from
 * the end of the warm-up on, as fio does after ramp_time.
 */
#ifndef ALIAS_COMMON_H
#define ALIAS_COMMON_H

#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define ALIAS_PAGE 4096ULL
#define ALIAS_MAX_CHUNKS 60000      /* VMAs (vm.max_map_count 65530) or VFIO mappings (65535) */

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "ERROR: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(2);
}

static inline uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static inline uint64_t epoch_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (uint64_t)t.tv_sec * 1000ull + (uint64_t)t.tv_nsec / 1000000ull;
}

static inline uint64_t parse_u64(const char *name, const char *s)
{
    char *end = NULL;
    errno = 0;
    if (!s || s[0] == '-')
        die("%s: not a non-negative integer: '%s'", name, s ? s : "");
    unsigned long long v = strtoull(s, &end, 0);
    uint64_t mult = 1;
    if (end && (*end == 'k' || *end == 'K')) { mult = 1024; end++; }
    else if (end && (*end == 'm' || *end == 'M')) { mult = 1024 * 1024; end++; }
    else if (end && (*end == 'g' || *end == 'G')) { mult = 1024ull * 1024 * 1024; end++; }
    if (errno || end == s || *end != '\0')
        die("%s: not a non-negative integer: '%s'", name, s);
    return (uint64_t)v * mult;
}

/* ------------------------------------------------------------ pattern */
enum alias_order { ORDER_CYCLIC, ORDER_SHUFFLE, ORDER_RANDOM };

struct alias_pattern {
    uint64_t ws, stride, first, seed;
    enum alias_order order;
    const char *list_path;
    uint64_t *page;             /* ws page indices into the region, in visit order */
    uint64_t span;              /* pages the region covers: the largest index + 1 */
};

struct alias_cursor { uint64_t pos, rng; };

static inline uint64_t xorshift(uint64_t *s)
{
    uint64_t x = *s;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    *s = x;
    return x * 2685821657736338717ull;
}

static inline enum alias_order parse_order(const char *s)
{
    if (!strcmp(s, "cyclic")) return ORDER_CYCLIC;
    if (!strcmp(s, "shuffle")) return ORDER_SHUFFLE;
    if (!strcmp(s, "random")) return ORDER_RANDOM;
    die("--order: cyclic, shuffle or random, not '%s'", s);
}

static inline const char *order_name(enum alias_order o)
{
    return o == ORDER_CYCLIC ? "cyclic" : o == ORDER_SHUFFLE ? "shuffle" : "random";
}

static inline void pattern_defaults(struct alias_pattern *p)
{
    memset(p, 0, sizeof(*p));
    p->ws = 64; p->stride = 1; p->first = 0; p->seed = 1; p->order = ORDER_CYCLIC;
}

static void pattern_load_list(struct alias_pattern *p)
{
    FILE *f = fopen(p->list_path, "r");
    char line[4096];
    size_t cap = 0;
    if (!f)
        die("--page-list %s: %s", p->list_path, strerror(errno));
    p->ws = 0;
    while (fgets(line, sizeof(line), f)) {
        char *c = line;
        for (;;) {
            while (*c == ' ' || *c == '\t' || *c == ',' || *c == '\n' || *c == '\r')
                c++;
            if (*c == '\0' || *c == '#')
                break;
            char *end = NULL;
            errno = 0;
            unsigned long long v = strtoull(c, &end, 0);
            if (errno || end == c || *c == '-')
                die("--page-list %s: bad token near '%.20s'", p->list_path, c);
            if (p->ws == cap) {
                cap = cap ? cap * 2 : 256;
                p->page = realloc(p->page, cap * sizeof(*p->page));
                if (!p->page)
                    die("out of memory");
            }
            p->page[p->ws++] = v;
            c = end;
        }
    }
    fclose(f);
    if (!p->ws)
        die("--page-list %s: no pages", p->list_path);
}

static inline void pattern_build(struct alias_pattern *p)
{
    if (p->list_path) {
        pattern_load_list(p);
    } else {
        if (!p->ws || !p->stride)
            die("--ws and --stride must be at least 1");
        if (p->stride > (UINT64_MAX - p->first) / p->ws)
            die("--ws %" PRIu64 " x --stride %" PRIu64 " overflows", p->ws, p->stride);
        p->page = malloc(p->ws * sizeof(*p->page));
        if (!p->page)
            die("out of memory");
        for (uint64_t i = 0; i < p->ws; i++)
            p->page[i] = p->first + i * p->stride;
    }
    if (p->order == ORDER_SHUFFLE) {          /* one fixed order, cycled */
        uint64_t s = p->seed | 1;
        for (uint64_t i = p->ws - 1; i > 0; i--) {
            uint64_t j = xorshift(&s) % (i + 1), t = p->page[i];
            p->page[i] = p->page[j];
            p->page[j] = t;
        }
    }
    p->span = 0;
    for (uint64_t i = 0; i < p->ws; i++)
        if (p->page[i] + 1 > p->span)
            p->span = p->page[i] + 1;
    if (p->span > (1ull << 30))
        die("the pattern spans %" PRIu64 " pages (4 TiB at most)", p->span);
}

/* Cursor k of n starts k/n of the way round, so n queues spread over the set. */
static inline void cursor_init(const struct alias_pattern *p, struct alias_cursor *c,
                               uint64_t k, uint64_t n)
{
    c->pos = n ? (p->ws * k) / n : 0;
    c->rng = (p->seed + 1) * 0x9E3779B97F4A7C15ull ^ (k + 1) * 0xD1B54A32D192ED03ull;
    if (!c->rng)
        c->rng = 1;
}

static inline uint64_t pattern_next(const struct alias_pattern *p, struct alias_cursor *c)
{
    if (p->order == ORDER_RANDOM)
        return p->page[xorshift(&c->rng) % p->ws];
    uint64_t v = p->page[c->pos];
    if (++c->pos == p->ws)
        c->pos = 0;
    return v;
}

static inline void pattern_print(const struct alias_pattern *p, FILE *f, const char *who)
{
    if (p->list_path)
        fprintf(f, "%s: pattern page-list %s: %" PRIu64 " pages, span %" PRIu64 " pages, order %s\n",
                who, p->list_path, p->ws, p->span, order_name(p->order));
    else
        fprintf(f, "%s: pattern ws %" PRIu64 " stride %" PRIu64 " first %" PRIu64
                ", span %" PRIu64 " pages (%.1f MiB of IOVA), order %s\n",
                who, p->ws, p->stride, p->first, p->span,
                (double)p->span * ALIAS_PAGE / 1048576.0, order_name(p->order));
}

/* ------------------------------------------------------------ backing */
/* backing pages: the distinct physical pages behind the region (default: the
 * span, at most 65536 = 256 MiB). One memfd of that size, mapped once. */
struct alias_backing {
    int fd;
    uint64_t pages;
    unsigned char *va;
};

static inline uint64_t backing_default(uint64_t span)
{
    return span < 65536 ? span : 65536;
}

static inline void backing_create(struct alias_backing *b, uint64_t pages)
{
    b->pages = pages;
    b->fd = (int)syscall(SYS_memfd_create, "alias-backing", 0);
    if (b->fd < 0)
        die("memfd_create: %s", strerror(errno));
    if (ftruncate(b->fd, (off_t)(pages * ALIAS_PAGE)) != 0)
        die("ftruncate backing (%" PRIu64 " pages): %s", pages, strerror(errno));
    b->va = mmap(NULL, pages * ALIAS_PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, b->fd, 0);
    if (b->va == MAP_FAILED)
        die("mmap backing: %s", strerror(errno));
    madvise(b->va, pages * ALIAS_PAGE, MADV_NOHUGEPAGE);
    for (uint64_t i = 0; i < pages; i++) {     /* fault every page in, tag it */
        memset(b->va + i * ALIAS_PAGE, 0, ALIAS_PAGE);
        memcpy(b->va + i * ALIAS_PAGE, &i, sizeof(i));
    }
}

/* A virtually contiguous region of span pages, repeating the backing (for an
 * RDMA MR, which has to be one virtual range). */
static inline unsigned char *backing_region(const struct alias_backing *b, uint64_t span)
{
    uint64_t chunks = (span + b->pages - 1) / b->pages;
    if (chunks > ALIAS_MAX_CHUNKS)
        die("span %" PRIu64 " pages / backing %" PRIu64 " = %" PRIu64 " mappings (at most %d): "
            "raise --backing-pages", span, b->pages, chunks, ALIAS_MAX_CHUNKS);
    unsigned char *r = mmap(NULL, span * ALIAS_PAGE, PROT_NONE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (r == MAP_FAILED)
        die("reserve %" PRIu64 " pages of address space: %s", span, strerror(errno));
    for (uint64_t c = 0; c < chunks; c++) {
        uint64_t n = span - c * b->pages < b->pages ? span - c * b->pages : b->pages;
        void *at = r + c * b->pages * ALIAS_PAGE;
        if (mmap(at, n * ALIAS_PAGE, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED,
                 b->fd, 0) != at)
            die("map backing chunk %" PRIu64 ": %s", c, strerror(errno));
    }
    madvise(r, span * ALIAS_PAGE, MADV_NOHUGEPAGE);
    return r;
}

/* ------------------------------------------------------------ stats */
/* Latency histogram: 16 buckets per power of two of nanoseconds. */
#define HIST_N (64 * 16)
struct alias_stats {
    volatile uint64_t ios, bytes;       /* the I/O thread's; the sampler reads */
    uint64_t lat_sum_ns, lat_n;
    uint64_t hist[HIST_N];
};

static inline unsigned hist_idx(uint64_t ns)
{
    if (ns < 16)
        return (unsigned)ns;
    unsigned msb = 63u - (unsigned)__builtin_clzll(ns);
    return msb * 16 + (unsigned)((ns >> (msb - 4)) & 15);
}

static inline uint64_t hist_low(unsigned i)
{
    if (i < 16)
        return i;
    unsigned msb = i / 16;
    return (1ull << msb) | ((uint64_t)(i % 16) << (msb - 4));
}

static inline void stats_add(struct alias_stats *s, uint64_t bytes, uint64_t lat_ns, int measured)
{
    __atomic_store_n(&s->ios, s->ios + 1, __ATOMIC_RELAXED);
    __atomic_store_n(&s->bytes, s->bytes + bytes, __ATOMIC_RELAXED);
    if (measured) {
        s->lat_sum_ns += lat_ns;
        s->lat_n++;
        s->hist[hist_idx(lat_ns)]++;
    }
}

static inline double stats_pct(const struct alias_stats *s, double q)
{
    uint64_t want = (uint64_t)((double)s->lat_n * q), seen = 0;
    for (unsigned i = 0; i < HIST_N; i++) {
        seen += s->hist[i];
        if (seen > want)
            return (double)hist_low(i);
    }
    return 0;
}

/* One instance's output: the per-second log and, at the end, the JSON. */
struct alias_out {
    char prefix[512], name[128];
    FILE *log;
    uint64_t start_ms, start_ns;        /* end of the warm-up: what fio calls job_start */
    uint64_t ios0, bytes0;              /* counters at that moment */
    uint64_t last_ios, last_ns;
    int started;
};

static inline void out_open(struct alias_out *o, const char *prefix, const char *name)
{
    memset(o, 0, sizeof(*o));
    snprintf(o->prefix, sizeof(o->prefix), "%s", prefix);
    snprintf(o->name, sizeof(o->name), "%s", name);
    char path[600];
    snprintf(path, sizeof(path), "%s_iops.1.log", prefix);
    o->log = fopen(path, "w");
    if (!o->log)
        die("%s: %s", path, strerror(errno));
}

/* The warm-up is over: from here on the log and the JSON count. */
static inline void out_start(struct alias_out *o, const struct alias_stats *s)
{
    o->start_ms = epoch_ms();
    o->start_ns = now_ns();
    o->ios0 = o->last_ios = __atomic_load_n(&s->ios, __ATOMIC_RELAXED);
    o->bytes0 = __atomic_load_n(&s->bytes, __ATOMIC_RELAXED);
    o->last_ns = o->start_ns;
    o->started = 1;
}

/* Once a second: the mean IOPS over the second that just ended. */
static inline double out_sample(struct alias_out *o, const struct alias_stats *s, uint64_t bs)
{
    if (!o->started)
        return 0;
    uint64_t t = now_ns(), n = __atomic_load_n(&s->ios, __ATOMIC_RELAXED);
    double dt = (double)(t - o->last_ns) / 1e9;
    double iops = dt > 0 ? (double)(n - o->last_ios) / dt : 0;
    fprintf(o->log, "%" PRIu64 ", %.0f, 0, %" PRIu64 ", 0\n", epoch_ms(), iops, bs);
    fflush(o->log);
    o->last_ios = n;
    o->last_ns = t;
    return iops;
}

static inline void out_close(struct alias_out *o, const struct alias_stats *s,
                             const char *extra_json, int error)
{
    if (o->log)
        fclose(o->log);
    o->log = NULL;
    uint64_t ios = s->ios - o->ios0, bytes = s->bytes - o->bytes0;
    uint64_t ms = o->started ? (now_ns() - o->start_ns) / 1000000ull : 0;
    double sec = ms ? (double)ms / 1000.0 : 0;
    char path[600];
    snprintf(path, sizeof(path), "%s.json", o->prefix);
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "ERROR: %s: %s\n", path, strerror(errno));
        return;
    }
    fprintf(f, "{\n  \"alias\": {%s},\n  \"jobs\": [{\n", extra_json ? extra_json : "");
    fprintf(f, "    \"jobname\": \"%s\", \"error\": %d, \"job_start\": %" PRIu64 ",\n",
            o->name, error, o->start_ms);
    fprintf(f, "    \"read\": {\"io_bytes\": %" PRIu64 ", \"total_ios\": %" PRIu64
            ", \"runtime\": %" PRIu64 ", \"iops\": %.3f, \"bw_bytes\": %.0f,\n",
            bytes, ios, ms, sec ? (double)ios / sec : 0, sec ? (double)bytes / sec : 0);
    fprintf(f, "      \"lat_ns\": {\"mean\": %.1f},\n",
            s->lat_n ? (double)s->lat_sum_ns / (double)s->lat_n : 0);
    fprintf(f, "      \"clat_ns\": {\"percentile\": {\"50.000000\": %.0f, \"99.000000\": %.0f, "
            "\"99.900000\": %.0f}}},\n",
            stats_pct(s, 0.50), stats_pct(s, 0.99), stats_pct(s, 0.999));
    fprintf(f, "    \"write\": {\"io_bytes\": 0}, \"trim\": {\"io_bytes\": 0}\n  }]\n}\n");
    fclose(f);
}

/* ------------------------------------------------------------ signals */
static volatile sig_atomic_t g_stop;
static void on_stop(int sig) { (void)sig; g_stop = 1; }
static inline void stop_on_signals(void)
{
    struct sigaction a;
    memset(&a, 0, sizeof(a));
    a.sa_handler = on_stop;             /* no SA_RESTART: sleeps return early */
    sigaction(SIGINT, &a, NULL);
    sigaction(SIGTERM, &a, NULL);
    signal(SIGPIPE, SIG_IGN);
}

/* Sleep until the monotonic clock reaches target_ns (or a stop signal);
 * sleeps again after an early wake, so a once-a-second loop never samples twice. */
static inline void sleep_until(uint64_t target_ns)
{
    for (;;) {
        uint64_t t = now_ns();
        if (t >= target_ns || g_stop)
            return;
        struct timespec d = { (time_t)((target_ns - t) / 1000000000ull), (long)((target_ns - t) % 1000000000ull) };
        nanosleep(&d, NULL);
    }
}

static inline void pin_cpu(int cpu)
{
    if (cpu < 0)
        return;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0)
        fprintf(stderr, "WARNING: cannot pin to CPU %d: %s\n", cpu, strerror(errno));
}

#endif
