/*
 * pips - host-side bring-up tool for PIPS, the FPGA PCIe switch (VCK190).
 *
 * Maps the switch's upstream port BAR0 (10ee:b048) through sysfs resource0
 * and reaches, through it: the BAR0 registers and BRAM, the AXI window, and
 * behind the window the batcher/logger config register (0xA4000000), the log
 * DMA (0xA4010000) and the FPGA DDR the DMA writes the TLP log into.
 *
 *   sudo ./pips [-s BDF] [-f] <command> [args]
 *
 *   info                       identity, status, window and log registers
 *   rd OFF [N]                 read N 32-bit BAR0 words at OFF
 *   wr OFF VAL                 write one 32-bit BAR0 word
 *   axi-rd ADDR [N]            read N 32-bit words at AXI address ADDR
 *   axi-wr ADDR VAL            write one 32-bit word at AXI address ADDR
 *   cfg                        batcher/logger config register and the drain
 *                              config register (design >= 0x0a03), decoded,
 *                              the build's DESIGN_ID and its log format
 *   cfg set K=V...             read-modify-write them: depth= time= mrd= log=
 *                              raw= (reg0) cap= (reg1, drain_depth_cap); from
 *                              design 0x0a06 also pb= pushoff= quantum= raw3=
 *                              (reg3) thr= thr0= thr1= raw2= (reg2); from
 *                              design 0x0a07 also rcap0= rcap1= rcapout= rcap=
 *                              (both inputs) raw4= (reg4, rate caps)
 *   status                     page batcher status (design >= 0x0a06): overflow
 *                              flags and counts, stuck, longest MRd wait, since
 *                              the previous read (reading clears them); from
 *                              0x0a07 also the counters below
 *   counters                   refused and rate-cap-held cycles per input
 *                              (design >= 0x0a07): free-running 32-bit, wrap,
 *                              no read side effect (take differences)
 *   dma                        log DMA (S2MM) registers, decoded
 *   dma-reset                  soft-reset the log DMA
 *   log-clear                  zero the log region in DDR
 *   log-start                  arm the DMA on the log region, start a recording
 *   log-stop [MS]              end the recording, wait for the DMA (2000 ms)
 *   log-wait [MS]              wait for the DMA, recording left on (region full)
 *   log-dump FILE [BYTES]      copy the recording (default: what the DMA wrote)
 *   ddr-dump ADDR BYTES FILE   copy any DDR range
 *   hwtest [--ddr-addr A] [STEP...]   bring-up checks; stops at the first
 *                              failing step. Steps, in order: regs bram
 *                              regfile dma ddr err split log (default: all)
 *   soak [N]                   N random 4/8-byte BRAM write/read pairs (1e6)
 *   bg ...                     the background read engine (design >= 0x0a08,
 *                              pips_bg_rd_0 at 0xA4020000): info, set K=V,
 *                              start, stop, wait, run, counters, clear, hist,
 *                              trace, capture, census, facts, table (pips bg
 *                              help). Whatever starts a run stops it on exit
 *                              (bg run: also on SIGINT/TERM/HUP, leak, clash)
 *
 *   -s BDF   upstream port (default $PIPS_BDF, else the only 10ee:b048)
 *   -f       skip the ID/VERSION check (rd and wr never check)
 *
 * Exit status: 0 ok, 1 failure, 2 usage, 3 timeout (log-stop, log-wait, bg
 * stop/wait); bg run: 4 an error stopped the run, 5 a leak or clash.
 * Output lines of the form key=value are for scripts; lines starting with #
 * are notes. Register map: pips_regs.h. Access rules (single aligned 4/8-byte
 * accesses, never memcpy on the mapping): README.md in this folder.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "pips_regs.h"

#ifdef PIPS_SIM
#define LOCK_FILE       "/tmp/pips-sim-bar0.lock"
#else
#define LOCK_FILE       "/tmp/pips-bar0.lock"
#endif
#define USER_CLK_HZ     250e6       /* upstream user_clk, the logger's clock (pips.tcl) */
#define DEFAULT_DDR_TEST 0x10000000ull
#define UNMAPPED_AXI    0xB0000000ull
#define CFG_RESERVED    0xFEFE0000u
#define DMA_SR_SG_INCLD (1u << 3)
#define DMA_SR_DLY_IRQ  (1u << 13)
#define DMA_SR_ERRS     (PIPS_DMA_SR_INT_ERR | PIPS_DMA_SR_SLV_ERR | PIPS_DMA_SR_DEC_ERR)
#define DMA_SR_IRQS     (PIPS_DMA_SR_IOC | DMA_SR_DLY_IRQ | PIPS_DMA_SR_ERR_IRQ)
#define TRAILER_INFO    0x88

/* ------------------------------------------------------------ BAR0 access */
#ifdef PIPS_SIM
/* pips_sim.c: a software model of BAR0, for testing without hardware */
uint32_t sim_rd32(uint32_t off);
void sim_wr32(uint32_t off, uint32_t v);
uint64_t sim_rd64(uint32_t off);
void sim_wr64(uint32_t off, uint64_t v);
void sim_wr8(uint32_t off, uint8_t v);
void sim_open(void);
int sim_cfg_read(unsigned off, void *buf, size_t n);
#define bar_rd32 sim_rd32
#define bar_wr32 sim_wr32
#define bar_rd64 sim_rd64
#define bar_wr64 sim_wr64
#define bar_wr8  sim_wr8
#else
static volatile uint8_t *g_bar;
static uint32_t bar_rd32(uint32_t off) { return pips_rd32(g_bar, off); }
static void bar_wr32(uint32_t off, uint32_t v) { pips_wr32(g_bar, off, v); }
static uint64_t bar_rd64(uint32_t off) { return *(volatile uint64_t *)(g_bar + off); }
static void bar_wr64(uint32_t off, uint64_t v) { *(volatile uint64_t *)(g_bar + off) = v; }
static void bar_wr8(uint32_t off, uint8_t v) { *(volatile uint8_t *)(g_bar + off) = v; }
#endif

static char g_bdf[64];

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("pips: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec * 1e-9;
}

static void sleep_ms(unsigned ms)
{
    struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000L };
    while (nanosleep(&t, &t) && errno == EINTR)
        ;
}

static uint64_t parse_num(const char *s, const char *what)
{
    char *end;
    unsigned long long v;

    errno = 0;
    v = strtoull(s, &end, 0);
    if (errno || end == s || *s == '-')
        die("bad %s: '%s'", what, s);
    switch (*end) {
    case 'k': case 'K': v <<= 10; end++; break;
    case 'm': case 'M': v <<= 20; end++; break;
    case 'g': case 'G': v <<= 30; end++; break;
    }
    if (*end)
        die("bad %s: '%s'", what, s);
    return v;
}

/* ------------------------------------------------------------ device */
#ifndef PIPS_SIM
static int sysfs_hex(const char *dir, const char *name, unsigned *v)
{
    char p[512];
    FILE *f;
    int ok;

    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/%s", dir, name);
    if (!(f = fopen(p, "r")))
        return -1;
    ok = fscanf(f, "%x", v) == 1;
    fclose(f);
    return ok ? 0 : -1;
}

static void find_usp(void)
{
    const char *env = getenv("PIPS_BDF");
    char found[8][64];
    struct dirent *e;
    unsigned ven, dev;
    int n = 0;
    DIR *d;

    if (!g_bdf[0] && env && *env)
        snprintf(g_bdf, sizeof g_bdf, "%s", env);
    if (g_bdf[0]) {
        if (strlen(g_bdf) == 7) {               /* 97:00.0 -> 0000:97:00.0 */
            char t[16];
            snprintf(t, sizeof t, "0000:%.7s", g_bdf);
            snprintf(g_bdf, sizeof g_bdf, "%s", t);
        }
        return;
    }
    if (!(d = opendir("/sys/bus/pci/devices")))
        die("/sys/bus/pci/devices: %s", strerror(errno));
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || sysfs_hex(e->d_name, "vendor", &ven) ||
            sysfs_hex(e->d_name, "device", &dev))
            continue;
        if (ven == PIPS_VENDOR_ID && dev == PIPS_USP_DEVICE_ID && n < 8)
            snprintf(found[n++], sizeof found[0], "%.63s", e->d_name);
    }
    closedir(d);
    if (n == 0)
        die("no PIPS upstream port (10ee:b048): FPGA not programmed, or not rescanned "
            "(echo 1 > /sys/bus/pci/rescan)");
    if (n > 1)
        die("%d PIPS upstream ports (%s, %s, ...): pick one with -s", n, found[0], found[1]);
    snprintf(g_bdf, sizeof g_bdf, "%s", found[0]);
}
#endif

/* Read the upstream port's PCI config space (0 = ok). */
static int cfg_space(unsigned off, void *buf, size_t n)
{
#ifdef PIPS_SIM
    return sim_cfg_read(off, buf, n);
#else
    char p[512];
    ssize_t r;
    int fd;

    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/config", g_bdf);
    if ((fd = open(p, O_RDONLY)) < 0)
        return -1;
    r = pread(fd, buf, n, off);
    close(fd);
    return r == (ssize_t)n ? 0 : -1;
#endif
}

static void open_bar(void)
{
#ifdef PIPS_SIM
    snprintf(g_bdf, sizeof g_bdf, "sim");
    sim_open();
#else
    unsigned long long start = 0, end = 0;
    char path[512];
    uint16_t cmd;
    FILE *f;
    void *p;
    int fd;

    find_usp();
    /* BAR0 as the kernel holds it: first line of `resource`, "start end flags".
     * Unassigned: start 0. Not implemented by the bitstream: all zero. */
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource", g_bdf);
    if (!(f = fopen(path, "r")))
        die("%s: %s (wrong BDF?)", path, strerror(errno));
    if (fscanf(f, "%llx %llx", &start, &end) != 2)
        start = end = 0;
    fclose(f);
    if (!end)
        die("%s has no BAR0: this bitstream's upstream port has none", g_bdf);
    if (end - start + 1 != PIPS_BAR0_SIZE)
        die("%s: BAR0 is %llu bytes; the PIO needs 32 KB, and its registers at 0x800 are "
            "outside a smaller BAR. 1 KB is what pips.tcl's pf0_bar0_size 32 (Kilobytes) gives "
            "on this Type 1 port: the IP encodes it as for an endpoint. Build with 1 Megabytes "
            "(scripts/pips/README.md, \"BAR0 size\")", g_bdf, end - start + 1);
    if (!start)
        die("%s: BAR0 has no address (Region 0 <unassigned>): boot with pci=realloc", g_bdf);
    if (cfg_space(4, &cmd, 2) == 0 && !(cmd & 2))
        die("%s: memory space is disabled (Mem-). Enable it: setpci -s %s COMMAND=0x02:0x02",
            g_bdf, g_bdf);
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", g_bdf);
    if ((fd = open(path, O_RDWR | O_SYNC)) < 0)
        die("open %s: %s%s", path, strerror(errno), errno == EACCES ? " (run as root)" : "");
    p = mmap(NULL, PIPS_BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED)
        die("mmap %s: %s", path, strerror(errno));
    close(fd);
    g_bar = p;
#endif
}

/* WIN_BASE is shared state: one pips at a time. The file is opened without
 * O_CREAT when it exists: with fs.protected_regular, even root may not
 * O_CREAT-open another user's file in /tmp. */
static int g_lock_fd = -1;
static void take_lock(void)
{
    int fd = open(LOCK_FILE, O_RDONLY);

    if (fd < 0 && errno == ENOENT && (fd = open(LOCK_FILE, O_RDONLY | O_CREAT, 0666)) >= 0)
        fchmod(fd, 0666);
    if (fd < 0)
        die("%s: %s", LOCK_FILE, strerror(errno));
    for (int i = 0; flock(fd, LOCK_EX | LOCK_NB); i++) {
        if (i == 50)
            die("another pips has held %s for 5 s", LOCK_FILE);
        sleep_ms(100);
    }
    g_lock_fd = fd;
}

static void check_id(void)
{
    uint32_t id = bar_rd32(PIPS_REG_ID), ver = bar_rd32(PIPS_REG_VERSION);

    if (id != PIPS_ID_VALUE)
        die("%s: ID reads 0x%08x, expected 0x%08x%s", g_bdf, id, PIPS_ID_VALUE,
            id == 0xFFFFFFFFu ? ": no completion (FPGA not programmed, link down, or BAR "
                                "moved: remove + rescan)"
                              : ": not a PIPS bitstream with the PIO");
    if (PIPS_VERSION_MAJOR(ver) != 2)
        die("register map v%u.%u; this tool is for v2.x", PIPS_VERSION_MAJOR(ver),
            PIPS_VERSION_MINOR(ver));
}

/* ------------------------------------------------------------ AXI window */
static uint64_t g_page = UINT64_MAX;    /* AXI page WIN_BASE holds, as far as we know */

static uint32_t win_off(uint64_t addr)
{
    uint64_t page = addr & ~(uint64_t)(PIPS_WIN_SIZE - 1u);

    if (addr & 3u)
        die("AXI address 0x%" PRIx64 " is not 4-byte aligned", addr);
    if (page != g_page) {
        bar_wr32(PIPS_REG_WIN_BASE_LO, (uint32_t)page);
        bar_wr32(PIPS_REG_WIN_BASE_HI, (uint32_t)(page >> 32));
        g_page = page;
    }
    return PIPS_WIN_OFF + (uint32_t)(addr & (PIPS_WIN_SIZE - 1u));
}

static uint32_t axi_rd(uint64_t a) { return bar_rd32(win_off(a)); }
static void axi_wr(uint64_t a, uint32_t v) { bar_wr32(win_off(a), v); }

static uint64_t win_err_addr(void)
{
    return bar_rd32(PIPS_REG_WIN_ERR_LO) | (uint64_t)bar_rd32(PIPS_REG_WIN_ERR_HI) << 32;
}

static const char *win_flags(uint32_t st)
{
    static const char *names[] = { "rd_err", "wr_err", "timeout", "rd_past_64B", "dropped" };
    static char b[96];

    b[0] = 0;
    for (int i = 0; i < 5; i++)
        if (st & (1u << i))
            snprintf(b + strlen(b), sizeof b - strlen(b), "%s%s", b[0] ? " " : "", names[i]);
    if (st & PIPS_WIN_ST_BUSY)
        snprintf(b + strlen(b), sizeof b - strlen(b), "%sbusy", b[0] ? " " : "");
    return b[0] ? b : "ok";
}

/* Sticky window status since the last check, cleared. Printed with `what` when set. */
static uint32_t win_check(const char *what)
{
    uint32_t st = bar_rd32(PIPS_REG_WIN_STATUS);

    if (st & PIPS_WIN_ST_STICKY) {
        uint64_t ea = win_err_addr();
        if (what)
            fprintf(stderr, "pips: %s: WIN_STATUS 0x%08x (%s), last failed AXI address 0x%" PRIx64
                    "\n", what, st, win_flags(st), ea);
        bar_wr32(PIPS_REG_WIN_STATUS, PIPS_WIN_ST_STICKY);
    }
    return st & PIPS_WIN_ST_STICKY;
}

/* Before window work: report and clear what earlier accesses left behind. */
static void win_start(void)
{
    uint32_t st = bar_rd32(PIPS_REG_WIN_STATUS);

    if (st & PIPS_WIN_ST_STICKY) {
        printf("# WIN_STATUS 0x%08x (%s) left by an earlier access to 0x%" PRIx64 "; cleared\n",
               st, win_flags(st), win_err_addr());
        bar_wr32(PIPS_REG_WIN_STATUS, PIPS_WIN_ST_STICKY);
    }
    if (st & PIPS_WIN_ST_BUSY)
        printf("# AXI busy since an earlier timeout: window accesses are dropped until the late "
               "response arrives\n");
}

static uint32_t axi_rd_ok(uint64_t a, const char *what)
{
    uint32_t v = axi_rd(a);

    if (win_check(what))
        die("%s failed (AXI 0x%" PRIx64 ")", what, a);
    return v;
}

static void axi_wr_ok(uint64_t a, uint32_t v, const char *what)
{
    axi_wr(a, v);
    if (win_check(what))
        die("%s failed (AXI 0x%" PRIx64 ")", what, a);
}

/* ------------------------------------------------------------ config register */
static uint32_t cfg_rd(void)
{
    return axi_rd_ok(PIPS_AXI_REGFILE + PIPS_BATCH_CFG_OFF, "config register read");
}

static void cfg_wr(uint32_t v)
{
    axi_wr_ok(PIPS_AXI_REGFILE + PIPS_BATCH_CFG_OFF, v, "config register write");
}

static void cfg_print(uint32_t v)
{
    printf("cfg=0x%08x depth_threshold=%u time_threshold=%u batch_mrd=%u log_enable=%u\n", v,
           (v & PIPS_BATCH_DEPTH_MASK) >> PIPS_BATCH_DEPTH_SHIFT,
           (v & PIPS_BATCH_TIME_MASK) >> PIPS_BATCH_TIME_SHIFT, !!(v & PIPS_BATCH_MRD),
           !!(v & PIPS_BATCH_LOG_ENABLE));
    if (v & CFG_RESERVED)
        printf("# reserved bits set (0x%08x): written with the old XSCT layout? "
               "Old 0x1608 is 0x01001608 now\n", v & CFG_RESERVED);
}

/* The build's DESIGN_ID, or -1 for a build from before the register (DECERR). */
static int design_id(void)
{
    uint32_t id = axi_rd(PIPS_AXI_REGFILE + PIPS_DESIGN_ID_OFF);

    return win_check(NULL) ? -1 : (int)PIPS_DESIGN_ID(id);
}

static int has_drain_cfg(int id) { return id >= (int)PIPS_DESIGN_ID_DRAIN_CFG; }
static int has_page_batch(int id) { return id >= (int)PIPS_DESIGN_ID_PAGE_BATCH; }
static int has_rate_cap(int id) { return id >= (int)PIPS_DESIGN_ID_RATE_CAP; }

/* The TLP log record format a build writes (pips_regs.h, "Record format"). */
static const char *log_format(int id) { return id >= (int)PIPS_DESIGN_ID_LOG_V2 ? "v2" : "v1"; }

static uint32_t drain_rd(void)
{
    return axi_rd_ok(PIPS_AXI_REGFILE + PIPS_BATCH_DRAIN_OFF, "drain config register read");
}

/* The drain line, then the design ID and log format: key=value lines for scripts. */
static void drain_id_print(int id, int have, uint32_t drain)
{
    if (have)
        printf("drain=0x%08x drain_depth_cap=%u\n", drain, !!(drain & PIPS_BATCH_DRAIN_DEPTH_CAP));
    else
        printf("drain=none drain_depth_cap=0\n# no drain config register (design < 0x%04x): "
               "every drain sends the whole FIFO\n", PIPS_DESIGN_ID_DRAIN_CFG);
    if (id < 0)
        printf("design_id=none\n# no DESIGN_ID register: a build older than design 0x%04x\n",
               PIPS_DESIGN_ID_FIRST);
    else
        printf("design_id=0x%04x\n", id);
    printf("log_format=%s\n", log_format(id));
}

/* Page batcher registers (design >= 0x0a06): reg2 thresholds, reg3 mode and arbitration. */
static uint32_t pb_rd(uint32_t off)
{
    return axi_rd_ok(PIPS_AXI_REGFILE + off, "page batcher register read");
}

/* key=value lines for scripts; on older builds "none", so a parser always finds the keys. */
static void pb_print(int have, uint32_t pb, uint32_t thr)
{
    if (!have) {
        printf("pb=none page_batch_en=0 ctrl_push_off=0 grant_quantum=0\n"
               "thr=none ctrl_dw_thr_0=0 ctrl_dw_thr_1=0\n"
               "# no page batcher registers (design < 0x%04x)\n", PIPS_DESIGN_ID_PAGE_BATCH);
        return;
    }
    printf("pb=0x%08x page_batch_en=%u ctrl_push_off=%u grant_quantum=%u\n", pb, !!(pb & PIPS_PB_EN),
           !!(pb & PIPS_PB_CTRL_PUSH_OFF), (pb >> PIPS_PB_QUANTUM_SHIFT) & PIPS_PB_QUANTUM_MAX);
    printf("thr=0x%08x ctrl_dw_thr_0=%u ctrl_dw_thr_1=%u\n", thr, (thr >> PIPS_PB_THR0_SHIFT) & PIPS_PB_THR_MAX,
           (thr >> PIPS_PB_THR1_SHIFT) & PIPS_PB_THR_MAX);
    if (!(thr & PIPS_PB_THR_MAX) || !((thr >> PIPS_PB_THR1_SHIFT) & PIPS_PB_THR_MAX))
        printf("# ctrl_dw_thr 0 = %u DW (the power-on value)\n", PIPS_PB_THR_DEFAULT);
}

/* Rate caps (design >= 0x0a07), the same way: "none" and zeros on older builds. */
static void rcap_print(int have, uint32_t rc)
{
    unsigned c0 = (rc >> PIPS_RCAP_IN0_SHIFT) & PIPS_RCAP_MAX, c1 = (rc >> PIPS_RCAP_IN1_SHIFT) & PIPS_RCAP_MAX,
             co = (rc >> PIPS_RCAP_OUT_SHIFT) & PIPS_RCAP_MAX;

    if (!have) {
        printf("rcap=none rate_cap_0=0 rate_cap_1=0 rate_cap_out=0\n"
               "# no rate caps (design < 0x%04x)\n", PIPS_DESIGN_ID_RATE_CAP);
        return;
    }
    printf("rcap=0x%08x rate_cap_0=%u rate_cap_1=%u rate_cap_out=%u\n", rc, c0, c1, co);
    if (c0 || c1 || co)
        printf("# rate caps in Gb/s of 64-byte beats (0 = uncapped): in0 %.1f, in1 %.1f, out %.1f\n",
               c0 * 0.5, c1 * 0.5, co * 0.5);
}

static int cmd_cfg(int argc, char **argv)
{
    uint32_t old, v, rb, dold = 0, d = 0, drb = 0, pbo = 0, pb = 0, pbr = 0, tho = 0, th = 0, thr = 0;
    uint32_t rco = 0, rc = 0, rcr = 0;
    int id, have, havepb, haverc, set_cap = 0, set_pb = 0, set_thr = 0, set_rc = 0;

    win_start();
    old = cfg_rd();
    id = design_id();
    have = has_drain_cfg(id);
    havepb = has_page_batch(id);
    haverc = has_rate_cap(id);
    if (have)
        dold = drain_rd();
    if (havepb) {
        pbo = pb_rd(PIPS_PB_CFG_OFF);
        tho = pb_rd(PIPS_PB_THR_OFF);
    }
    if (haverc)
        rco = pb_rd(PIPS_RCAP_OFF);
    if (argc == 0) {
        cfg_print(old);
        drain_id_print(id, have, dold);
        pb_print(havepb, pbo, tho);
        rcap_print(haverc, rco);
        return 0;
    }
    if (strcmp(argv[0], "set") || argc < 2)
        die("usage: pips cfg [set depth=N time=N mrd=0|1 log=0|1 raw=VAL cap=0|1 "
            "pb=0|1 pushoff=0|1 quantum=N thr=N thr0=N thr1=N raw2=VAL raw3=VAL "
            "rcap=N rcap0=N rcap1=N rcapout=N raw4=VAL ...]");
    v = old;
    d = dold;
    pb = pbo;
    th = tho;
    rc = rco;
    for (int i = 1; i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        uint64_t n;

        if (!eq)
            die("expected K=V, got '%s'", argv[i]);
        *eq = 0;
        n = parse_num(eq + 1, argv[i]);
        if (!strcmp(argv[i], "raw")) {
            if (n > 0xFFFFFFFFu) die("raw: 32 bits");
            v = (uint32_t)n;
        } else if (!strcmp(argv[i], "depth")) {
            if (n > 255) die("depth: 0..255");
            v = (v & ~PIPS_BATCH_DEPTH_MASK) | (uint32_t)n << PIPS_BATCH_DEPTH_SHIFT;
        } else if (!strcmp(argv[i], "time")) {
            if (n > 255) die("time: 0..255");
            v = (v & ~PIPS_BATCH_TIME_MASK) | (uint32_t)n << PIPS_BATCH_TIME_SHIFT;
        } else if (!strcmp(argv[i], "mrd") || !strcmp(argv[i], "log")) {
            uint32_t bit = argv[i][0] == 'm' ? PIPS_BATCH_MRD : PIPS_BATCH_LOG_ENABLE;
            if (n > 1) die("%s: 0 or 1", argv[i]);
            v = n ? v | bit : v & ~bit;
        } else if (!strcmp(argv[i], "cap")) {
            if (n > 1) die("cap: 0 or 1");
            if (!have) {
                if (id < 0)
                    die("cap: this build has no DESIGN_ID, so no drain config register "
                        "(needs design >= 0x%04x)", PIPS_DESIGN_ID_DRAIN_CFG);
                die("cap: design 0x%04x has no drain config register (needs >= 0x%04x)", id,
                    PIPS_DESIGN_ID_DRAIN_CFG);
            }
            d = n ? d | PIPS_BATCH_DRAIN_DEPTH_CAP : d & ~PIPS_BATCH_DRAIN_DEPTH_CAP;
            set_cap = 1;
        } else if (!strcmp(argv[i], "pb") || !strcmp(argv[i], "pushoff") || !strcmp(argv[i], "quantum") ||
                   !strcmp(argv[i], "raw3") || !strcmp(argv[i], "thr") || !strcmp(argv[i], "thr0") ||
                   !strcmp(argv[i], "thr1") || !strcmp(argv[i], "raw2")) {
            if (!havepb)
                die("%s: design 0x%04x has no page batcher registers (needs >= 0x%04x)", argv[i],
                    id < 0 ? 0 : (unsigned)id, PIPS_DESIGN_ID_PAGE_BATCH);
            if (!strcmp(argv[i], "pb") || !strcmp(argv[i], "pushoff")) {
                uint32_t bit = argv[i][1] == 'b' ? PIPS_PB_EN : PIPS_PB_CTRL_PUSH_OFF;
                if (n > 1) die("%s: 0 or 1", argv[i]);
                pb = n ? pb | bit : pb & ~bit;
                set_pb = 1;
            } else if (!strcmp(argv[i], "quantum")) {
                if (n > PIPS_PB_QUANTUM_MAX) die("quantum: 0..%u beats (0 = off)", PIPS_PB_QUANTUM_MAX);
                pb = (pb & ~(PIPS_PB_QUANTUM_MAX << PIPS_PB_QUANTUM_SHIFT)) | (uint32_t)n << PIPS_PB_QUANTUM_SHIFT;
                set_pb = 1;
            } else if (!strcmp(argv[i], "raw3")) {
                if (n > 0xFFFFFFFFu) die("raw3: 32 bits");
                pb = (uint32_t)n;
                set_pb = 1;
            } else if (!strcmp(argv[i], "raw2")) {
                if (n > 0xFFFFFFFFu) die("raw2: 32 bits");
                th = (uint32_t)n;
                set_thr = 1;
            } else {                                    /* thr (both inputs), thr0, thr1 */
                if (n > PIPS_PB_THR_MAX) die("%s: 0..%u DW (0 = %u)", argv[i], PIPS_PB_THR_MAX, PIPS_PB_THR_DEFAULT);
                if (strcmp(argv[i], "thr1"))
                    th = (th & ~(PIPS_PB_THR_MAX << PIPS_PB_THR0_SHIFT)) | (uint32_t)n << PIPS_PB_THR0_SHIFT;
                if (strcmp(argv[i], "thr0"))
                    th = (th & ~(PIPS_PB_THR_MAX << PIPS_PB_THR1_SHIFT)) | (uint32_t)n << PIPS_PB_THR1_SHIFT;
                set_thr = 1;
            }
        } else if (!strcmp(argv[i], "rcap") || !strcmp(argv[i], "rcap0") || !strcmp(argv[i], "rcap1") ||
                   !strcmp(argv[i], "rcapout") || !strcmp(argv[i], "raw4")) {
            if (!haverc)
                die("%s: design 0x%04x has no rate caps (needs >= 0x%04x)", argv[i],
                    id < 0 ? 0 : (unsigned)id, PIPS_DESIGN_ID_RATE_CAP);
            if (!strcmp(argv[i], "raw4")) {
                if (n > 0xFFFFFFFFu) die("raw4: 32 bits");
                rc = (uint32_t)n;
            } else {
                int sh[2] = { -1, -1 };
                if (n > PIPS_RCAP_MAX) die("%s: 0..%u beats per %u cycles (0 = uncapped)", argv[i],
                                           PIPS_RCAP_MAX, PIPS_RCAP_WIN_CYCLES);
                if (!strcmp(argv[i], "rcapout"))
                    sh[0] = PIPS_RCAP_OUT_SHIFT;
                else if (!strcmp(argv[i], "rcap0"))
                    sh[0] = PIPS_RCAP_IN0_SHIFT;
                else if (!strcmp(argv[i], "rcap1"))
                    sh[0] = PIPS_RCAP_IN1_SHIFT;
                else {                                  /* rcap: both inputs */
                    sh[0] = PIPS_RCAP_IN0_SHIFT;
                    sh[1] = PIPS_RCAP_IN1_SHIFT;
                }
                for (int k = 0; k < 2 && sh[k] >= 0; k++)
                    rc = (rc & ~(PIPS_RCAP_MAX << sh[k])) | (uint32_t)n << sh[k];
            }
            set_rc = 1;
        } else {
            die("unknown field '%s' (depth time mrd log raw cap pb pushoff quantum thr thr0 thr1 raw2 raw3 "
                "rcap rcap0 rcap1 rcapout raw4)", argv[i]);
        }
    }
    if (set_rc)
        axi_wr_ok(PIPS_AXI_REGFILE + PIPS_RCAP_OFF, rc, "rate cap register write");
    /* Thresholds before the mode: a switch to per-page mode never sees the old threshold. */
    if (set_thr)
        axi_wr_ok(PIPS_AXI_REGFILE + PIPS_PB_THR_OFF, th, "page batcher threshold register write");
    if (set_pb)
        axi_wr_ok(PIPS_AXI_REGFILE + PIPS_PB_CFG_OFF, pb, "page batcher config register write");
    cfg_wr(v);
    rb = cfg_rd();
    if (set_cap)
        axi_wr_ok(PIPS_AXI_REGFILE + PIPS_BATCH_DRAIN_OFF, d, "drain config register write");
    if (have)
        drb = drain_rd();
    if (havepb) {
        pbr = pb_rd(PIPS_PB_CFG_OFF);
        thr = pb_rd(PIPS_PB_THR_OFF);
    }
    if (haverc)
        rcr = pb_rd(PIPS_RCAP_OFF);
    printf("# was 0x%08x", old);
    if (have)
        printf(", drain 0x%08x", dold);
    if (havepb)
        printf(", pb 0x%08x, thr 0x%08x", pbo, tho);
    if (haverc)
        printf(", rcap 0x%08x", rco);
    putchar('\n');
    cfg_print(rb);
    drain_id_print(id, have, drb);
    pb_print(havepb, pbr, thr);
    rcap_print(haverc, rcr);
    if (rb != v) {
        fprintf(stderr, "pips: wrote 0x%08x, read back 0x%08x\n", v, rb);
        return 1;
    }
    if (set_cap && (drb & PIPS_BATCH_DRAIN_DEPTH_CAP) != (d & PIPS_BATCH_DRAIN_DEPTH_CAP)) {
        fprintf(stderr, "pips: drain config: wrote 0x%08x, read back 0x%08x\n", d, drb);
        return 1;
    }
    if ((set_pb && pbr != pb) || (set_thr && thr != th)) {
        fprintf(stderr, "pips: page batcher: wrote pb 0x%08x thr 0x%08x, read back pb 0x%08x thr 0x%08x\n",
                pb, th, pbr, thr);
        return 1;
    }
    if (set_rc && rcr != rc) {
        fprintf(stderr, "pips: rate caps: wrote 0x%08x, read back 0x%08x\n", rc, rcr);
        return 1;
    }
    return 0;
}

/* Refused and rate-cap-held cycles per input (design >= 0x0a07): one key=value line.
 * Free-running 32-bit counters that wrap; reading has no side effect. */
static void counters_print(void)
{
    uint32_t b0 = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_BP_CYCLES_0_OFF, "bp_cycles_0 read"),
             b1 = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_BP_CYCLES_1_OFF, "bp_cycles_1 read"),
             h0 = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_CAP_HOLD_0_OFF, "cap_hold_cycles_0 read"),
             h1 = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_CAP_HOLD_1_OFF, "cap_hold_cycles_1 read");

    printf("bp_cycles_0=%u bp_cycles_1=%u cap_hold_cycles_0=%u cap_hold_cycles_1=%u\n", b0, b1, h0, h1);
}

static int cmd_counters(void)
{
    int id;

    win_start();
    id = design_id();
    if (!has_rate_cap(id)) {
        printf("counters=none\n# design %s has no refused-cycle counters (needs >= 0x%04x)\n",
               id < 0 ? "none" : "older", PIPS_DESIGN_ID_RATE_CAP);
        return 0;
    }
    printf("counters=ok\n");
    counters_print();
    printf("# free-running 32-bit cycle counts (4 ns), wrap after 17.2 s counted: take differences\n");
    return 0;
}

/* Page batcher status (design >= 0x0a06). The 0x24 read returns the sticky flags
 * and clears them and the batcher's status, and latches the counts at 0x28/0x2C:
 * each call reports the period since the previous one (or since power-on). */
static int cmd_status(void)
{
    uint32_t f, c, w;
    int id;

    win_start();
    id = design_id();
    if (!has_page_batch(id)) {
        printf("status=none\n# design %s has no page batcher status (needs >= 0x%04x)\n",
               id < 0 ? "none" : "older", PIPS_DESIGN_ID_PAGE_BATCH);
        return 0;
    }
    f = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_PB_STAT_FLAGS_OFF, "status flags read");
    c = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_PB_STAT_OVF_COUNT_OFF, "overflow count read");
    w = axi_rd_ok(PIPS_AXI_REGFILE + PIPS_PB_STAT_MRD_WAIT_OFF, "MRd wait read");
    printf("status=ok\n");
    printf("stat_flags=0x%08x ovf0=%u ovf1=%u stuck=%u\n", f, !!(f & PIPS_PB_STAT_OVF0),
           !!(f & PIPS_PB_STAT_OVF1), !!(f & PIPS_PB_STAT_STUCK));
    printf("ovf_count_0=%u ovf_count_1=%u\n", c & 0xFFFFu, c >> 16);
    printf("mrd_wait_max_0=%u mrd_wait_max_1=%u\n", w & 0xFFFFu, w >> 16);
    printf("mrd_wait_max_us_0=%.2f mrd_wait_max_us_1=%.2f\n", (w & 0xFFFFu) / USER_CLK_HZ * 1e6,
           (w >> 16) / USER_CLK_HZ * 1e6);
    printf("# since the previous status read (this read cleared them); counts saturate at 65535\n");
    if (has_rate_cap(id)) {
        counters_print();
        printf("# bp_cycles/cap_hold_cycles: free-running, wrap, not cleared by this read\n");
    }
    if (f & PIPS_PB_STAT_STUCK)
        printf("# STUCK: the batcher's watchdog found the output idle with data held and forced a drain\n");
    return 0;
}

/* ------------------------------------------------------------ log DMA */
static uint32_t dma_rd(uint32_t reg) { return axi_rd_ok(PIPS_AXI_DMA_LOG + reg, "DMA register read"); }
static void dma_wr(uint32_t reg, uint32_t v) { axi_wr_ok(PIPS_AXI_DMA_LOG + reg, v, "DMA register write"); }

static const char *dmasr_flags(uint32_t sr)
{
    static const struct { uint32_t bit; const char *name; } f[] = {
        { PIPS_DMA_SR_HALTED, "halted" }, { PIPS_DMA_SR_IDLE, "idle" },
        { DMA_SR_SG_INCLD, "sg_included" }, { PIPS_DMA_SR_INT_ERR, "int_err" },
        { PIPS_DMA_SR_SLV_ERR, "slv_err" }, { PIPS_DMA_SR_DEC_ERR, "dec_err" },
        { PIPS_DMA_SR_IOC, "ioc" }, { DMA_SR_DLY_IRQ, "dly_irq" },
        { PIPS_DMA_SR_ERR_IRQ, "err_irq" },
    };
    static char b[128];

    b[0] = 0;
    for (size_t i = 0; i < sizeof f / sizeof f[0]; i++)
        if (sr & f[i].bit)
            snprintf(b + strlen(b), sizeof b - strlen(b), "%s%s", b[0] ? " " : "", f[i].name);
    return b[0] ? b : "running";
}

static const char *dma_state(uint32_t sr)
{
    if (sr & DMA_SR_ERRS)
        return "error (log-start resets it)";
    if (sr & PIPS_DMA_SR_HALTED)
        return "halted: reset state, or stopped";
    if (sr & PIPS_DMA_SR_IDLE)
        return "running, idle: the last transfer is done";
    return "running, transfer programmed: waiting for log data";
}

static void dma_print(void)
{
    uint32_t cr = dma_rd(PIPS_DMA_S2MM_DMACR), sr = dma_rd(PIPS_DMA_S2MM_DMASR);
    uint32_t da = dma_rd(PIPS_DMA_S2MM_DA), len = dma_rd(PIPS_DMA_S2MM_LENGTH);

    printf("dmacr=0x%08x run=%u\n", cr, !!(cr & PIPS_DMA_CR_RS));
    printf("dmasr=0x%08x %s\n", sr, dmasr_flags(sr));
    printf("da=0x%08x\n", da);
    printf("length=%u\n", len);
    printf("# %s; length is %s\n", dma_state(sr),
           (sr & PIPS_DMA_SR_IDLE) ? "the bytes the last transfer wrote" : "as programmed");
}

static void dma_reset(void)
{
    dma_wr(PIPS_DMA_S2MM_DMACR, PIPS_DMA_CR_RESET);
    for (int i = 0; i < 100; i++) {
        if (!(dma_rd(PIPS_DMA_S2MM_DMACR) & PIPS_DMA_CR_RESET))
            return;
        sleep_ms(1);
    }
    die("DMA soft reset did not complete in 100 ms (DMACR bit 2 still set)");
}

/* ------------------------------------------------------------ log recording */
struct region { uint32_t base, bytes; };

static struct region log_region(void)
{
    uint32_t ver = bar_rd32(PIPS_REG_VERSION), hi;
    struct region r;

    if (PIPS_VERSION_MINOR(ver) < 1)
        die("register map v2.%u has no LOG_* registers (needs v2.1)", PIPS_VERSION_MINOR(ver));
    r.base = bar_rd32(PIPS_REG_LOG_BASE_LO);
    hi = bar_rd32(PIPS_REG_LOG_BASE_HI);
    r.bytes = bar_rd32(PIPS_REG_LOG_BYTES);
    if (!r.bytes)
        die("LOG_BYTES is 0: this bitstream has no log region");
    if (hi)
        die("LOG_BASE is above 4 GB (0x%08x_%08x); the DMA has 32-bit addresses", hi, r.base);
    if ((r.base | r.bytes) & 15u)
        die("log region 0x%08x + %u is not 16-byte aligned", r.base, r.bytes);
    return r;
}

/* Smallest power of two >= the region and >= 4 KB: the DMA's aperture (pips.tcl). */
static uint64_t log_range(struct region r)
{
    uint64_t n = 4096;

    while (n < r.bytes)
        n <<= 1;
    return n;
}

/* Steps 1-3 of the recording sequence (README, telemetry_dma_format.md §7). */
static void log_start(int quiet)
{
    struct region r = log_region();
    uint32_t cfg = cfg_rd(), sr;
    int i;

    if (cfg & PIPS_BATCH_LOG_ENABLE) {
        if (!quiet)
            printf("# log_enable was 1 (an open or region-full recording): clearing it\n");
        cfg_wr(cfg & ~PIPS_BATCH_LOG_ENABLE);
        sleep_ms(1);
    }
    sr = dma_rd(PIPS_DMA_S2MM_DMASR);
    /* A programmed transfer may still be taking the tail of the previous recording. */
    for (i = 0; i < 100 && !(sr & (PIPS_DMA_SR_HALTED | PIPS_DMA_SR_IDLE | DMA_SR_ERRS)); i++) {
        sleep_ms(1);
        sr = dma_rd(PIPS_DMA_S2MM_DMASR);
    }
    if (sr & DMA_SR_ERRS || !(sr & (PIPS_DMA_SR_HALTED | PIPS_DMA_SR_IDLE))) {
        printf("# DMA %s (DMASR 0x%08x %s): resetting it\n",
               sr & DMA_SR_ERRS ? "has errors" : "still waits for data from an earlier arm",
               sr, dmasr_flags(sr));
        dma_reset();
    }
    dma_wr(PIPS_DMA_S2MM_DMASR, DMA_SR_IRQS);
    dma_wr(PIPS_DMA_S2MM_DMACR, PIPS_DMA_CR_RS);
    for (i = 0; (sr = dma_rd(PIPS_DMA_S2MM_DMASR)) & PIPS_DMA_SR_HALTED; i++) {
        if (i == 10)
            die("the DMA stays halted after RS=1 (DMASR 0x%08x): check the S2MM register "
                "offsets (PG021) and the DMA's clock and reset", sr);
        sleep_ms(1);
    }
    for (i = 0;; i++) {
        uint32_t stale;

        dma_wr(PIPS_DMA_S2MM_DA, r.base);
        dma_wr(PIPS_DMA_S2MM_LENGTH, r.bytes);
        sleep_ms(2);
        sr = dma_rd(PIPS_DMA_S2MM_DMASR);
        if (sr & DMA_SR_ERRS)
            die("DMA error right after arming: DMASR 0x%08x (%s)%s", sr, dmasr_flags(sr),
                sr & PIPS_DMA_SR_DEC_ERR ? ": S2MM_DA outside the DMA's aperture?" : "");
        if (!(sr & (PIPS_DMA_SR_IDLE | PIPS_DMA_SR_IOC)))
            break;
        /* The logger still held the end of an earlier recording; the DMA took it at once. */
        stale = dma_rd(PIPS_DMA_S2MM_LENGTH);
        printf("# the DMA took %u stale bytes (the end of an earlier recording); re-arming\n",
               stale);
        dma_wr(PIPS_DMA_S2MM_DMASR, DMA_SR_IRQS);
        if (i == 2)
            die("the DMA keeps completing at once (DMASR 0x%08x)", sr);
    }
    cfg = cfg_rd();
    cfg_wr(cfg | PIPS_BATCH_LOG_ENABLE);
    if (!quiet)
        printf("log_base=0x%08x\nlog_bytes=%u\nrecording=started\n", r.base, r.bytes);
}

struct logres {
    uint32_t dmasr, bytes, n_records, n_dropped, duration;
    uint8_t reason;
};

static const char *stop_name(uint8_t reason)
{
    return reason == 1 ? "enable_low" : reason == 2 ? "region_full" : "unknown";
}

/* Step 5 of the sequence: wait for the DMA, read the byte count and the trailer.
 * 0 ok, 1 error, 3 timeout. Messages go to stderr; *res is filled as far as known.
 * Polls every 1 ms for 100 ms, then every 10 ms: each poll is a few BAR0 TLPs,
 * and those briefly hold up the switch's host-to-device requests (D7). */
static int log_finish(unsigned timeout_ms, struct logres *res)
{
    struct region r = log_region();
    double t0 = now_s();
    uint32_t t[4];

    memset(res, 0, sizeof *res);
    for (;;) {
        res->dmasr = dma_rd(PIPS_DMA_S2MM_DMASR);
        if (res->dmasr & (PIPS_DMA_SR_IDLE | PIPS_DMA_SR_IOC | DMA_SR_ERRS | PIPS_DMA_SR_HALTED))
            break;
        if ((now_s() - t0) * 1000 >= timeout_ms) {
            fprintf(stderr, "pips: the DMA still waits for log data after %u ms: the recording "
                    "is open (log-stop ends it), or the logger never sent its trailer\n",
                    timeout_ms);
            return 3;
        }
        sleep_ms(now_s() - t0 < 0.1 ? 1 : 10);
    }
    if (res->dmasr & DMA_SR_ERRS) {
        fprintf(stderr, "pips: DMA error: DMASR 0x%08x (%s)\n", res->dmasr,
                dmasr_flags(res->dmasr));
        return 1;
    }
    if (!(res->dmasr & (PIPS_DMA_SR_IDLE | PIPS_DMA_SR_IOC))) {
        fprintf(stderr, "pips: the DMA is halted, not armed: no recording (log-start)\n");
        return 1;
    }
    res->bytes = dma_rd(PIPS_DMA_S2MM_LENGTH);
    if (res->bytes < 16 || res->bytes % 16 || res->bytes > r.bytes) {
        fprintf(stderr, "pips: the DMA reports %u bytes written (region %u)\n", res->bytes,
                r.bytes);
        return 1;
    }
    for (int i = 0; i < 4; i++)
        t[i] = axi_rd(r.base + res->bytes - 16 + 4u * i);
    if (win_check("trailer read"))
        return 1;
    if (((t[3] >> 16) & 0xFF) != TRAILER_INFO) {
        fprintf(stderr, "pips: the last record is not a trailer (info byte 0x%02x)\n",
                (t[3] >> 16) & 0xFF);
        return 1;
    }
    res->n_records = t[0];
    res->n_dropped = t[1];
    res->duration = t[2];
    res->reason = t[3] & 0xFF;
    return 0;
}

static void logres_print(const struct logres *res, int rc)
{
    printf("dmasr=0x%08x %s\n", res->dmasr, dmasr_flags(res->dmasr));
    if (rc == 3)
        printf("status=timeout\n");
    if (rc)
        return;
    printf("bytes_written=%u\nn_records=%u\nn_dropped=%u\nduration_cycles=%u\n"
           "duration_us=%.1f\nstop_reason=%s\n", res->bytes, res->n_records, res->n_dropped,
           res->duration, res->duration / USER_CLK_HZ * 1e6, stop_name(res->reason));
    if ((uint64_t)res->n_records * 16 + 16 != res->bytes)
        printf("# %u records + trailer = %" PRIu64 " bytes, the DMA wrote %u (pad records?)\n",
               res->n_records, (uint64_t)res->n_records * 16 + 16, res->bytes);
}

static int cmd_log_finish(unsigned timeout_ms, int stop)
{
    struct logres res;
    uint32_t cfg;
    int rc;

    win_start();
    if (stop && ((cfg = cfg_rd()) & PIPS_BATCH_LOG_ENABLE))
        cfg_wr(cfg & ~PIPS_BATCH_LOG_ENABLE);
    rc = log_finish(timeout_ms, &res);
    logres_print(&res, rc);
    return rc;
}

/* ------------------------------------------------------------ DDR dumps */
static void ddr_dump(uint64_t addr, uint64_t bytes, const char *file)
{
    static uint32_t buf[PIPS_WIN_SIZE / 4];
    double t0 = now_s(), dt;
    FILE *f;

    if ((addr | bytes) & 3u)
        die("address and size must be multiples of 4");
    if (addr + bytes > PIPS_AXI_DDR_SIZE)
        die("0x%" PRIx64 " + %" PRIu64 " runs past the end of DDR (2 GB)", addr, bytes);
    if (!(f = fopen(file, "wb")))
        die("%s: %s", file, strerror(errno));
    for (uint64_t done = 0; done < bytes;) {
        uint64_t a = addr + done;
        uint64_t chunk = PIPS_WIN_SIZE - (a & (PIPS_WIN_SIZE - 1u));

        if (chunk > bytes - done)
            chunk = bytes - done;
        for (uint64_t i = 0; i < chunk / 4; i++)
            buf[i] = axi_rd(a + 4 * i);
        if (win_check("DDR read"))
            die("DDR read failed in [0x%" PRIx64 ", 0x%" PRIx64 ")", a, a + chunk);
        if (fwrite(buf, 1, chunk, f) != chunk)
            die("%s: %s", file, strerror(errno));
        done += chunk;
    }
    if (fclose(f))
        die("%s: %s", file, strerror(errno));
    dt = now_s() - t0;
    printf("dumped=%" PRIu64 "\nfile=%s\n# DDR 0x%" PRIx64 ", %.2f s, %.2f us per 32-bit read\n",
           bytes, file, addr, dt, bytes ? dt / (bytes / 4) * 1e6 : 0.0);
}

static int cmd_log_dump(int argc, char **argv)
{
    struct region r;
    uint64_t bytes;
    uint32_t sr;

    if (argc < 1 || argc > 2)
        die("usage: pips log-dump FILE [BYTES]");
    win_start();
    r = log_region();
    if (argc == 2) {
        bytes = parse_num(argv[1], "BYTES");
        if (bytes > r.bytes)
            die("BYTES %" PRIu64 " is larger than the log region (%u)", bytes, r.bytes);
    } else {
        sr = dma_rd(PIPS_DMA_S2MM_DMASR);
        if (!(sr & (PIPS_DMA_SR_IDLE | PIPS_DMA_SR_IOC)) || (sr & DMA_SR_ERRS))
            die("the DMA has not finished a transfer (DMASR 0x%08x %s): log-stop first, or give "
                "BYTES to dump the region as it is", sr, dmasr_flags(sr));
        bytes = dma_rd(PIPS_DMA_S2MM_LENGTH);
        if (bytes > r.bytes)
            die("S2MM_LENGTH %" PRIu64 " is larger than the log region", bytes);
    }
    ddr_dump(r.base, bytes, argv[0]);
    return 0;
}

static int cmd_log_clear(void)
{
    struct region r;
    double t0;
    uint32_t sr;

    win_start();
    r = log_region();
    sr = dma_rd(PIPS_DMA_S2MM_DMASR);
    if (!(sr & (PIPS_DMA_SR_HALTED | PIPS_DMA_SR_IDLE | DMA_SR_ERRS)))
        die("the DMA has a transfer programmed (DMASR 0x%08x): log-stop or dma-reset first", sr);
    t0 = now_s();
    for (uint64_t a = r.base; a < (uint64_t)r.base + r.bytes; a += 4)
        axi_wr(a, 0);
    if (win_check("log-clear"))
        die("log-clear failed");
    printf("# zeroed DDR 0x%08x + %u bytes in %.2f s\n", r.base, r.bytes, now_s() - t0);
    return 0;
}

/* ------------------------------------------------------------ info */
static int cmd_info(void)
{
    uint32_t v[0x80 / 4];
    uint8_t bus[3];
    int id;

    for (uint32_t i = 0; i < 0x80 / 4; i++)
        v[i] = bar_rd32(PIPS_REG_BLOCK_OFF + 4 * i);
#define R(name) v[((name) - PIPS_REG_BLOCK_OFF) / 4]
    printf("PIPS upstream port %s, BAR0 32 KB\n", g_bdf);
    printf("ID           0x%08x  %s\n", R(PIPS_REG_ID),
           R(PIPS_REG_ID) == PIPS_ID_VALUE ? "\"PIPS\"" : "WRONG");
    printf("VERSION      0x%08x  map v%u.%u\n", R(PIPS_REG_VERSION),
           PIPS_VERSION_MAJOR(R(PIPS_REG_VERSION)), PIPS_VERSION_MINOR(R(PIPS_REG_VERSION)));
    printf("SCRATCH      0x%08x\n", R(PIPS_REG_SCRATCH));
    printf("BUS_NUM      0x%08x  primary %02x secondary %02x subordinate %02x",
           R(PIPS_REG_BUS_NUM), PIPS_BUS_PRIMARY(R(PIPS_REG_BUS_NUM)),
           PIPS_BUS_SECONDARY(R(PIPS_REG_BUS_NUM)), PIPS_BUS_SUBORDINATE(R(PIPS_REG_BUS_NUM)));
    if (cfg_space(0x18, bus, 3) == 0)
        printf("  (config space %02x %02x %02x: %s)", bus[0], bus[1], bus[2],
               bus[0] == PIPS_BUS_PRIMARY(R(PIPS_REG_BUS_NUM)) &&
               bus[1] == PIPS_BUS_SECONDARY(R(PIPS_REG_BUS_NUM)) &&
               bus[2] == PIPS_BUS_SUBORDINATE(R(PIPS_REG_BUS_NUM)) ? "match" : "MISMATCH");
    putchar('\n');
    printf("CQ_SPLIT     0x%08x  PIO: ", R(PIPS_REG_CQ_SPLIT));
    if (R(PIPS_REG_CQ_SPLIT) & PIPS_SPLIT_PIO_SEEN)
        printf("BAR ID %u aperture %u", PIPS_SPLIT_PIO_BAR_ID(R(PIPS_REG_CQ_SPLIT)),
               PIPS_SPLIT_PIO_APERTURE(R(PIPS_REG_CQ_SPLIT)));
    else
        printf("none seen");
    printf("   switch: ");
    if (R(PIPS_REG_CQ_SPLIT) & PIPS_SPLIT_SW_SEEN)
        printf("BAR ID %u aperture %u\n", PIPS_SPLIT_SW_BAR_ID(R(PIPS_REG_CQ_SPLIT)),
               PIPS_SPLIT_SW_APERTURE(R(PIPS_REG_CQ_SPLIT)));
    else
        printf("none seen\n");
    printf("MWR_COUNT    %u\n", R(PIPS_REG_MWR_COUNT));
    printf("MRD_COUNT    %u\n", R(PIPS_REG_MRD_COUNT));
    printf("PIO_STATUS   0x%08x  %s\n", R(PIPS_REG_PIO_STATUS),
           R(PIPS_REG_PIO_STATUS) & PIPS_PIO_ST_CC_OVERFLOW ? "CC FIFO OVERFLOW" : "ok");
    printf("MEM_BASE     0x%08x  MEM_LIMIT 0x%08x  (downstream port 1 windows)\n",
           R(PIPS_REG_MEM_BASE), R(PIPS_REG_MEM_LIMIT));
    printf("PF_BASE      0x%08x_%08x  PF_LIMIT 0x%08x_%08x\n", R(PIPS_REG_PF_BASE_HI),
           R(PIPS_REG_PF_BASE_LO), R(PIPS_REG_PF_LIMIT_HI), R(PIPS_REG_PF_LIMIT_LO));
    printf("CTRL0-7     ");
    for (int i = 0; i < 8; i++)
        printf(" %08x", R(PIPS_REG_CTRL(i)));
    putchar('\n');
    printf("WIN_BASE     0x%08x_%08x\n", R(PIPS_REG_WIN_BASE_HI), R(PIPS_REG_WIN_BASE_LO));
    printf("WIN_STATUS   0x%08x  %s\n", R(PIPS_REG_WIN_STATUS), win_flags(R(PIPS_REG_WIN_STATUS)));
    printf("WIN_ERR      0x%08x_%08x\n", R(PIPS_REG_WIN_ERR_HI), R(PIPS_REG_WIN_ERR_LO));
    printf("LOG_BASE     0x%08x_%08x\n", R(PIPS_REG_LOG_BASE_HI), R(PIPS_REG_LOG_BASE_LO));
    printf("LOG_BYTES    0x%08x  %u KiB, %u records + trailer\n", R(PIPS_REG_LOG_BYTES),
           R(PIPS_REG_LOG_BYTES) >> 10,
           R(PIPS_REG_LOG_BYTES) ? R(PIPS_REG_LOG_BYTES) / 16 - 1 : 0);
#undef R
    win_start();
    id = design_id();
    if (id < 0)
        printf("DESIGN_ID    none        older than 0x%04x; log format v1\n", PIPS_DESIGN_ID_FIRST);
    else
        printf("DESIGN_ID    0x%04x      log format %s, drain config %s\n", id, log_format(id),
               has_drain_cfg(id) ? "yes" : "no");
    return 0;
}

/* ------------------------------------------------------------ hwtest */
static unsigned g_checks, g_fails, g_warns;

static int check(int ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int check(int ok, const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    printf("  %s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
    g_checks++;
    g_fails += !ok;
    return ok;
}

static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void note(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    printf("       ");
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
}

static void warnx(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void warnx(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    printf("  WARN ");
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
    g_warns++;
}

static void t_regs(void)
{
    static const uint32_t pats[] = { 0x55AA55AA, 0xA55AA55A, 0x00000000, 0xFFFFFFFF, 0x12345678 };
    uint32_t id = bar_rd32(PIPS_REG_ID), ver = bar_rd32(PIPS_REG_VERSION);
    uint32_t st = bar_rd32(PIPS_REG_PIO_STATUS), save, v, a, b, bn;
    uint8_t bus[3];

    check(id == PIPS_ID_VALUE, "ID 0x%08x (expect 0x%08x \"PIPS\")", id, PIPS_ID_VALUE);
    check(PIPS_VERSION_MAJOR(ver) == 2, "VERSION 0x%08x: map v%u.%u (expect v2.x)", ver,
          PIPS_VERSION_MAJOR(ver), PIPS_VERSION_MINOR(ver));
    if (PIPS_VERSION_MINOR(ver) < 1)
        warnx("map v2.%u has no LOG_* registers: the log commands need v2.1",
              PIPS_VERSION_MINOR(ver));
    check(st == 0, "PIO_STATUS 0x%08x (expect 0; bit 0 = CC FIFO overflow)", st);
    save = bar_rd32(PIPS_REG_SCRATCH);
    for (size_t i = 0; i < sizeof pats / sizeof pats[0]; i++) {
        bar_wr32(PIPS_REG_SCRATCH, pats[i]);
        v = bar_rd32(PIPS_REG_SCRATCH);
        check(v == pats[i], "SCRATCH wrote 0x%08x read 0x%08x", pats[i], v);
    }
    a = bar_rd32(PIPS_REG_MWR_COUNT);
    for (int i = 0; i < 3; i++)
        bar_wr32(PIPS_REG_SCRATCH, save);
    b = bar_rd32(PIPS_REG_MWR_COUNT);
    check(b - a == 3, "MWR_COUNT advances by 3 over 3 writes (%u -> %u)", a, b);
    a = bar_rd32(PIPS_REG_MRD_COUNT);
    b = bar_rd32(PIPS_REG_MRD_COUNT);
    check(b - a == 1, "MRD_COUNT advances by 1 per read (%u -> %u)", a, b);
    bn = bar_rd32(PIPS_REG_BUS_NUM);
    if (cfg_space(0x18, bus, 3))
        note("BUS_NUM 0x%08x (config space not readable here)", bn);
    else if (bus[0] == PIPS_BUS_PRIMARY(bn) && bus[1] == PIPS_BUS_SECONDARY(bn) &&
             bus[2] == PIPS_BUS_SUBORDINATE(bn))
        check(1, "BUS_NUM %02x/%02x/%02x matches the upstream port's config space",
              bus[0], bus[1], bus[2]);
    else
        warnx("BUS_NUM primary/secondary/subordinate %02x/%02x/%02x, config space %02x/%02x/%02x",
              PIPS_BUS_PRIMARY(bn), PIPS_BUS_SECONDARY(bn), PIPS_BUS_SUBORDINATE(bn),
              bus[0], bus[1], bus[2]);
    if (PIPS_VERSION_MINOR(ver) >= 1) {
        uint32_t base = bar_rd32(PIPS_REG_LOG_BASE_LO), bytes = bar_rd32(PIPS_REG_LOG_BYTES);
        if (bytes)
            note("LOG_BASE 0x%08x_%08x LOG_BYTES 0x%08x (as built: 0x0 / 0x00400000)",
                 bar_rd32(PIPS_REG_LOG_BASE_HI), base, bytes);
        else
            warnx("LOG_BYTES is 0: no log region in this bitstream");
    }
}

static void t_bram(void)
{
    static const uint32_t o32[] = { 0x000, 0x014, 0x03C, 0x7FC };
    static const uint32_t o64[] = { 0x038, 0x040, 0x7F8 };
    uint32_t v, bad = 0;
    uint64_t p, q;

    for (size_t i = 0; i < sizeof o32 / sizeof o32[0]; i++) {
        uint32_t pat = 0xA5A50000u | (o32[i] * 0x11u);
        bar_wr32(o32[i], pat);
        v = bar_rd32(o32[i]);
        check(v == pat, "BRAM 4-byte at 0x%03x: wrote 0x%08x read 0x%08x", o32[i], pat, v);
    }
    for (size_t i = 0; i < sizeof o64 / sizeof o64[0]; i++) {
        p = 0xFEEDFACE00000000ull | 0xCAFE0000u | o64[i];
        bar_wr64(o64[i], p);
        q = bar_rd64(o64[i]);
        check(q == p, "BRAM 8-byte at 0x%03x: wrote 0x%016" PRIx64 " read 0x%016" PRIx64,
              o64[i], p, q);
    }
    bar_wr64(0x038, 0x1111111122222222ull);
    bar_wr32(0x03C, 0x33333333);
    check(bar_rd32(0x038) == 0x22222222 && bar_rd32(0x03C) == 0x33333333,
          "4-byte write at 0x03C leaves 0x038 alone");
    bar_wr32(0x100, 0xA5A50001);
    bar_wr8(0x101, 0x77);
    v = bar_rd32(0x100);
    check(v == 0xA5A57701, "byte write 0x77 at 0x101: 0x100 reads 0x%08x (expect 0xa5a57701)", v);
    for (uint32_t i = 0; i < 16; i++)
        bar_wr32(0x200 + 4 * i, 0xB0B00000u + i * 0x0101u);
    for (uint32_t i = 0; i < 16; i++)
        bad += bar_rd32(0x200 + 4 * i) != 0xB0B00000u + i * 0x0101u;
    check(bad == 0, "16 words at 0x200, written one by one and read back: %u wrong", bad);
    v = bar_rd32(0x000);
    check(bar_rd32(0x1000) == v, "0x1000 aliases 0x000 (0x%08x)", v);
    check(bar_rd32(0x880) == 0 && bar_rd32(0xFFC) == 0, "0x880 and 0xFFC (no register) read 0");
    v = bar_rd32(PIPS_REG_PIO_STATUS);
    check(v == 0, "PIO_STATUS 0x%08x after BRAM traffic", v);
}

static void t_regfile(void)
{
    const uint64_t a = PIPS_AXI_REGFILE + PIPS_BATCH_CFG_OFF;
    uint32_t lo, hi, orig, v, st, id, bad, pats[3];
    int drain, pb, rc;

    win_start();
    bar_wr32(PIPS_REG_WIN_BASE_LO, (uint32_t)PIPS_AXI_REGFILE | 3u);
    bar_wr32(PIPS_REG_WIN_BASE_HI, 0);
    lo = bar_rd32(PIPS_REG_WIN_BASE_LO);
    hi = bar_rd32(PIPS_REG_WIN_BASE_HI);
    check(lo == (uint32_t)PIPS_AXI_REGFILE && hi == 0,
          "WIN_BASE wrote 0x00000000_a4000003, read 0x%08x_%08x (bits [1:0] read 0)", hi, lo);
    g_page = UINT64_MAX;
    orig = axi_rd(a);
    st = win_check(NULL);
    if (!check(st == 0, "regfile reg0 at 0x%08" PRIx64 " answers: 0x%08x (WIN_STATUS %s)", a,
               orig, win_flags(st)))
        return;
    note("depth %u, time %u, batch_mrd %u, log_enable %u. XSCT \"mrd 0xA4000000\" should match",
         orig & 0xFF, (orig >> 8) & 0xFF, !!(orig & PIPS_BATCH_MRD),
         !!(orig & PIPS_BATCH_LOG_ENABLE));
    if (orig & CFG_RESERVED)
        warnx("reserved bits set (0x%08x): old XSCT layout? old 0x1608 = new 0x01001608",
              orig & CFG_RESERVED);
    /* log_enable kept as is: no edge, no recording started or ended */
    pats[0] = (orig & PIPS_BATCH_LOG_ENABLE) | 0x5Au | 0xA5u << 8 | ((orig & PIPS_BATCH_MRD) ^ PIPS_BATCH_MRD);
    pats[1] = (orig & PIPS_BATCH_LOG_ENABLE) | 0xA5u | 0x5Au << 8 | (orig & PIPS_BATCH_MRD);
    pats[2] = orig;
    for (int i = 0; i < 3; i++) {
        axi_wr(a, pats[i]);
        v = axi_rd(a);
        st = win_check(NULL);
        check(v == pats[i] && !st, "reg0 wrote 0x%08x read 0x%08x%s", pats[i], v,
              i == 2 ? " (restored)" : "");
    }
    /* The rest of the 64-byte aperture (pips.tcl, above axil4_regfile_0): DESIGN_ID at 0x20,
     * read-only; from design 0x0a03 the drain config at 0x04; every other register reads 0;
     * the 64 bytes repeat through the segment. */
    id = axi_rd(a + PIPS_DESIGN_ID_OFF);
    st = win_check(NULL);
    if (st & PIPS_WIN_ST_RD_ERR) {
        warnx("no DESIGN_ID (decode error at 0x%08" PRIx64 "): a build older than design 0x%04x, "
              "with reg0 only; layout checks skipped", a + PIPS_DESIGN_ID_OFF,
              PIPS_DESIGN_ID_FIRST);
        return;
    }
    check(!st && !(id >> 16) && PIPS_DESIGN_ID(id) >= PIPS_DESIGN_ID_FIRST,
          "DESIGN_ID 0x%04x at 0x%08" PRIx64 " (pips.tcl pips_design_id; bits [31:16] 0x%04x)",
          PIPS_DESIGN_ID(id), a + PIPS_DESIGN_ID_OFF, id >> 16);
    note("log format %s; drain config register %s; page batcher registers %s; rate caps %s",
         log_format((int)PIPS_DESIGN_ID(id)),
         has_drain_cfg((int)PIPS_DESIGN_ID(id)) ? "at +0x04" : "absent (design < 0x0a03)",
         has_page_batch((int)PIPS_DESIGN_ID(id)) ? "at +0x08/+0x0c, status +0x24-+0x2c"
                                                 : "absent (design < 0x0a06)",
         has_rate_cap((int)PIPS_DESIGN_ID(id)) ? "at +0x10, counters +0x30-+0x3c"
                                               : "absent (design < 0x0a07)");
    axi_wr(a + PIPS_DESIGN_ID_OFF, ~id);
    v = axi_rd(a + PIPS_DESIGN_ID_OFF);
    st = win_check(NULL);
    check(v == id && !st, "a write to DESIGN_ID is ignored: still 0x%08x, WIN_STATUS %s", v,
          win_flags(st));
    drain = has_drain_cfg((int)PIPS_DESIGN_ID(id));
    if (drain) {
        const uint64_t r1 = PIPS_AXI_REGFILE + PIPS_BATCH_DRAIN_OFF;
        uint32_t d0 = axi_rd(r1), want;

        st = win_check(NULL);
        if (!check(!st, "reg1 (drain config) at 0x%08" PRIx64 " answers: 0x%08x, drain_depth_cap "
                   "%u (WIN_STATUS %s)", r1, d0, !!(d0 & PIPS_BATCH_DRAIN_DEPTH_CAP),
                   win_flags(st)))
            return;
        /* drain_depth_cap flipped, then back: safe at any time (a running drain keeps its size) */
        for (int i = 0; i < 2; i++) {
            want = i == 0 ? d0 ^ PIPS_BATCH_DRAIN_DEPTH_CAP : d0;
            axi_wr(r1, want);
            v = axi_rd(r1);
            st = win_check(NULL);
            check(((v ^ want) & PIPS_BATCH_DRAIN_DEPTH_CAP) == 0 && !st,
                  "reg1 wrote 0x%08x read 0x%08x (drain_depth_cap %u)%s", want, v,
                  !!(v & PIPS_BATCH_DRAIN_DEPTH_CAP), i == 1 ? " (restored)" : "");
        }
    }
    pb = has_page_batch((int)PIPS_DESIGN_ID(id));
    if (pb) {
        /* reg2/reg3 hold what is written; page_batch_en is left as it is (a mode change waits
         * for an empty batcher), the other fields get a pattern, then everything is restored. */
        for (uint32_t r = PIPS_PB_THR_OFF; r <= PIPS_PB_CFG_OFF; r += 4) {
            uint32_t o = axi_rd(a + r), want;
            st = win_check(NULL);
            if (!check(!st, "reg%u (page batcher) at 0x%08" PRIx64 " answers: 0x%08x (WIN_STATUS %s)",
                       r / 4, a + r, o, win_flags(st)))
                return;
            for (int i = 0; i < 2; i++) {
                want = i ? o : r == PIPS_PB_THR_OFF ? 0x02AA0155u
                                                    : (o & PIPS_PB_EN) | 0x0A5A0000u | (~o & PIPS_PB_CTRL_PUSH_OFF);
                axi_wr(a + r, want);
                v = axi_rd(a + r);
                st = win_check(NULL);
                check(v == want && !st, "reg%u wrote 0x%08x read 0x%08x%s", r / 4, want, v,
                      i ? " (restored)" : "");
            }
        }
        /* Status: reading 0x24 clears it (this test's read starts a new period). */
        v = axi_rd(a + PIPS_PB_STAT_FLAGS_OFF);
        st = win_check(NULL);
        check(!st && !(v & ~0x7u), "status flags at +0x24: 0x%08x (ovf0 %u ovf1 %u stuck %u; bits [31:3] 0)",
              v, !!(v & PIPS_PB_STAT_OVF0), !!(v & PIPS_PB_STAT_OVF1), !!(v & PIPS_PB_STAT_STUCK));
        note("overflow counts 0x%08x, longest MRd wait 0x%08x (cycles, [15:0] in0, [31:16] in1)",
             axi_rd(a + PIPS_PB_STAT_OVF_COUNT_OFF), axi_rd(a + PIPS_PB_STAT_MRD_WAIT_OFF));
    }
    rc = has_rate_cap((int)PIPS_DESIGN_ID(id));
    if (rc) {
        /* reg4 holds what is written: a pattern in the three caps (reserved byte 0), then the
         * original. A cap set for a few microseconds only slows traffic, it never stops it. */
        uint32_t o = axi_rd(a + PIPS_RCAP_OFF), want, c[4];

        st = win_check(NULL);
        if (!check(!st, "reg4 (rate caps) at 0x%08" PRIx64 " answers: 0x%08x (WIN_STATUS %s)",
                   a + PIPS_RCAP_OFF, o, win_flags(st)))
            return;
        for (int i = 0; i < 2; i++) {
            want = i ? o : 0x00A55AC3u;
            axi_wr(a + PIPS_RCAP_OFF, want);
            v = axi_rd(a + PIPS_RCAP_OFF);
            st = win_check(NULL);
            check(v == want && !st, "reg4 wrote 0x%08x read 0x%08x%s", want, v, i ? " (restored)" : "");
        }
        /* Counters: read-only, free-running; a write is ignored. */
        for (int i = 0; i < 4; i++)
            c[i] = axi_rd(a + PIPS_BP_CYCLES_0_OFF + 4u * (uint32_t)i);
        axi_wr(a + PIPS_BP_CYCLES_0_OFF, 0);
        st = win_check(NULL);
        check(!st, "counters at +0x30-+0x3c answer, a write is ignored (WIN_STATUS %s)", win_flags(st));
        note("refused cycles in0 %u in1 %u, rate-cap held in0 %u in1 %u (free-running, wrap)",
             c[0], c[1], c[2], c[3]);
    }
    bad = 0;
    for (uint32_t off = 4; off < 0x40; off += 4)
        if (off != PIPS_DESIGN_ID_OFF && !(drain && off == PIPS_BATCH_DRAIN_OFF) &&
            !(pb && (off == PIPS_PB_THR_OFF || off == PIPS_PB_CFG_OFF ||
                     (off >= PIPS_PB_STAT_FLAGS_OFF && off <= PIPS_PB_STAT_MRD_WAIT_OFF))) &&
            !(rc && (off == PIPS_RCAP_OFF || off >= PIPS_BP_CYCLES_0_OFF)))
            bad += axi_rd(a + off) != 0;
    st = win_check(NULL);
    if (rc)
        check(!bad && !st, "reserved registers 0x14-0x1c read 0 (%u do not, WIN_STATUS %s)",
              bad, win_flags(st));
    else if (pb)
        check(!bad && !st, "reserved registers 0x10-0x1c and 0x30-0x3c read 0 (%u do not, WIN_STATUS %s)",
              bad, win_flags(st));
    else
        check(!bad && !st, "reserved registers 0x%02x-0x1c and 0x24-0x3c read 0 (%u do not, WIN_STATUS "
              "%s)", drain ? 0x08 : 0x04, bad, win_flags(st));
    v = axi_rd(a + 0x40);
    st = win_check(NULL);
    check(v == orig && !st, "0x%08" PRIx64 " repeats reg0: 0x%08x", a + 0x40, v);
}

static void t_dma(void)
{
    const uint64_t d = PIPS_AXI_DMA_LOG;
    uint32_t cr, sr, da, len, st, v, p;

    win_start();
    cr = axi_rd(d + PIPS_DMA_S2MM_DMACR);
    sr = axi_rd(d + PIPS_DMA_S2MM_DMASR);
    da = axi_rd(d + PIPS_DMA_S2MM_DA);
    len = axi_rd(d + PIPS_DMA_S2MM_LENGTH);
    st = win_check(NULL);
    if (!check(st == 0, "log DMA registers at 0x%08" PRIx64 " answer (WIN_STATUS %s)", d,
               win_flags(st)))
        return;
    note("S2MM_DMACR 0x%08x  S2MM_DMASR 0x%08x (%s)", cr, sr, dmasr_flags(sr));
    note("S2MM_DA 0x%08x  S2MM_LENGTH 0x%08x", da, len);
    note("%s", dma_state(sr));
    check(!(sr & DMA_SR_SG_INCLD), "DMASR SGIncld = 0 (direct register mode, as built)");
    check(!!(sr & PIPS_DMA_SR_HALTED) == !(cr & PIPS_DMA_CR_RS),
          "DMASR halted (%u) agrees with DMACR run/stop (%u)", !!(sr & PIPS_DMA_SR_HALTED),
          !!(cr & PIPS_DMA_CR_RS));
    if (sr & DMA_SR_ERRS)
        warnx("error bits from an earlier transfer: %s (log-start resets the DMA)",
              dmasr_flags(sr));
    if (sr & (PIPS_DMA_SR_HALTED | PIPS_DMA_SR_IDLE)) {
        p = (PIPS_VERSION_MINOR(bar_rd32(PIPS_REG_VERSION)) >= 1 ?
             bar_rd32(PIPS_REG_LOG_BASE_LO) : 0) + 0x100;
        axi_wr(d + PIPS_DMA_S2MM_DA, p);
        v = axi_rd(d + PIPS_DMA_S2MM_DA);
        axi_wr(d + PIPS_DMA_S2MM_DA, da);
        st = win_check(NULL);
        check(v == p && !st, "S2MM_DA (0x48) round trip: wrote 0x%08x read 0x%08x (PG021 "
              "offsets)", p, v);
    } else {
        note("S2MM_DA round trip skipped: a transfer is programmed");
    }
}

static void t_ddr(uint64_t t)
{
    uint32_t seed = (uint32_t)time(NULL) * 2654435761u, bad = 0, v, st;
    double t0, tw, tr;

    if (PIPS_VERSION_MINOR(bar_rd32(PIPS_REG_VERSION)) >= 1 && bar_rd32(PIPS_REG_LOG_BYTES)) {
        struct region r = log_region();
        uint64_t end = r.base + log_range(r);
        if (!check(t + 0x4040 <= r.base || t >= end, "test page 0x%" PRIx64 " is outside the "
                   "log region [0x%08x, 0x%" PRIx64 ")", t, r.base, end))
            return;
    }
    if (!check((t & 3) == 0 && t + 0x4040 <= PIPS_AXI_DDR_SIZE, "test page 0x%" PRIx64
               " is aligned and inside DDR", t))
        return;
#define PAT(i) (seed ^ ((uint32_t)(i) * 0x9E3779B9u) ^ (uint32_t)(t + 4 * (i)))
    win_start();
    t0 = now_s();
    for (uint32_t i = 0; i < 1024; i++)
        axi_wr(t + 4 * i, PAT(i));
    tw = now_s() - t0;
    t0 = now_s();
    for (uint32_t i = 0; i < 1024; i++) {
        v = axi_rd(t + 4 * i);
        if (v != PAT(i) && bad++ < 4)
            note("0x%" PRIx64 ": wrote 0x%08x read 0x%08x", t + 4 * i, PAT(i), v);
    }
    tr = now_s() - t0;
    st = win_check(NULL);
    check(bad == 0 && !st, "DDR 4 KB at 0x%" PRIx64 ": %u of 1024 words wrong, WIN_STATUS %s",
          t, bad, win_flags(st));
    note("%.2f us per 32-bit write, %.2f us per 32-bit read", tw / 1024 * 1e6, tr / 1024 * 1e6);
    /* the next 16 KB window page, then alternate pages: WIN_BASE moves every access */
    for (uint32_t i = 0; i < 16; i++)
        axi_wr(t + 0x4000 + 4 * i, ~PAT(i));
    bad = 0;
    for (uint32_t i = 0; i < 16; i++) {
        bad += axi_rd(t + 4 * i) != PAT(i);
        bad += axi_rd(t + 0x4000 + 4 * i) != ~PAT(i);
    }
    st = win_check(NULL);
    check(bad == 0 && !st, "alternating window pages 0x%" PRIx64 " / 0x%" PRIx64 ": %u wrong",
          t, t + 0x4000, bad);
#undef PAT
}

static void t_err(void)
{
    uint32_t v, st;
    uint64_t ea;

    win_start();
    v = axi_rd(UNMAPPED_AXI);
    st = bar_rd32(PIPS_REG_WIN_STATUS);
    ea = win_err_addr();
    check(v == 0xFFFFFFFFu && (st & PIPS_WIN_ST_RD_ERR) && !(st & PIPS_WIN_ST_TIMEOUT) &&
          ea == UNMAPPED_AXI, "read of unmapped 0x%08llx: 0x%08x, WIN_STATUS 0x%08x (%s), "
          "WIN_ERR 0x%" PRIx64, (unsigned long long)UNMAPPED_AXI, v, st, win_flags(st), ea);
    if (st & PIPS_WIN_ST_TIMEOUT)
        note("timeout: no AXI slave answered within ~33 us (expected a fast DECERR)");
    bar_wr32(PIPS_REG_WIN_STATUS, PIPS_WIN_ST_STICKY);
    st = bar_rd32(PIPS_REG_WIN_STATUS);
    check(!(st & PIPS_WIN_ST_STICKY), "WIN_STATUS clears with 0x1f (now 0x%08x)", st);
    axi_wr(UNMAPPED_AXI, 0x12345678);
    st = bar_rd32(PIPS_REG_WIN_STATUS);
    ea = win_err_addr();
    check((st & PIPS_WIN_ST_WR_ERR) && ea == UNMAPPED_AXI,
          "write to unmapped 0x%08llx: WIN_STATUS 0x%08x (%s), WIN_ERR 0x%" PRIx64,
          (unsigned long long)UNMAPPED_AXI, st, win_flags(st), ea);
    bar_wr32(PIPS_REG_WIN_STATUS, PIPS_WIN_ST_STICKY);
    v = axi_rd(PIPS_AXI_REGFILE);
    st = win_check(NULL);
    check(!st, "window works again afterwards (regfile reads 0x%08x)", v);
}

static void t_split(void)
{
    uint32_t v = bar_rd32(PIPS_REG_CQ_SPLIT);

    note("CQ_SPLIT 0x%08x", v);
    if (!check(!!(v & PIPS_SPLIT_PIO_SEEN), "CQ_SPLIT has recorded a BAR0 TLP"))
        return;
    /* The aperture is log2 of the BAR size as the IP is set (1 MB), not the 32 KB on the wire. */
    note("BAR0 hits report BAR ID %u, aperture %u", PIPS_SPLIT_PIO_BAR_ID(v),
         PIPS_SPLIT_PIO_APERTURE(v));
    if (!(v & PIPS_SPLIT_SW_SEEN))
        note("no memory TLP forwarded downstream yet: after traffic, see `pips info`");
    else if (PIPS_SPLIT_SW_BAR_ID(v) == PIPS_SPLIT_PIO_BAR_ID(v) &&
             PIPS_SPLIT_SW_APERTURE(v) == PIPS_SPLIT_PIO_APERTURE(v))
        note("forwarded TLPs report the same: the descriptor cannot tell them from BAR0 hits, so "
             "the split by address stays (PIO_KNOWLEDGE_MAP D4)");
    else
        note("forwarded TLPs report BAR ID %u, aperture %u: unlike BAR0 hits, so the descriptor "
             "could replace the cfg_mgmt BAR poll (D4)", PIPS_SPLIT_SW_BAR_ID(v),
             PIPS_SPLIT_SW_APERTURE(v));
}

static void t_log(void)
{
    struct logres res;
    uint32_t cfg;
    int rc;

    if (PIPS_VERSION_MINOR(bar_rd32(PIPS_REG_VERSION)) < 1 || !bar_rd32(PIPS_REG_LOG_BYTES)) {
        warnx("no log region: skipped");
        return;
    }
    note("an empty recording: log-start, 1 ms, log-stop");
    win_start();
    log_start(1);
    sleep_ms(1);
    cfg = cfg_rd();
    cfg_wr(cfg & ~PIPS_BATCH_LOG_ENABLE);
    rc = log_finish(1000, &res);
    if (!check(rc == 0, "DMA finished: DMASR 0x%08x (%s), %u bytes written", res.dmasr,
               dmasr_flags(res.dmasr), res.bytes))
        return;
    check((uint64_t)res.n_records * 16 + 16 == res.bytes, "trailer: %u records, %u dropped, "
          "stop %s, %u cycles", res.n_records, res.n_dropped, stop_name(res.reason),
          res.duration);
    if (res.n_dropped)
        warnx("%u records dropped: the DMA or DDR could not keep up", res.n_dropped);
    if (res.reason != 1)
        note("stop reason %s: traffic filled the region within 1 ms", stop_name(res.reason));
    note("pips log-dump FILE saves it; pips-log-decode.py FILE decodes it");
}

static int cmd_hwtest(int argc, char **argv)
{
    static const char *steps[] = { "regs", "bram", "regfile", "dma", "ddr", "err", "split", "log" };
    static const char *titles[] = {
        "BAR0 registers", "BAR0 BRAM", "regfile (batcher/logger config) through the window",
        "log DMA registers through the window", "DDR through the window",
        "window error path", "CQ split debug register", "log smoke test (DMA -> DDR)",
    };
    enum { NSTEPS = sizeof steps / sizeof steps[0] };
    uint64_t ddr = DEFAULT_DDR_TEST;
    int want[NSTEPS] = { 0 }, any = 0;

    for (int i = 0; i < argc; i++) {
        int k;
        if (!strcmp(argv[i], "--ddr-addr") && i + 1 < argc) {
            ddr = parse_num(argv[++i], "--ddr-addr");
            continue;
        }
        for (k = 0; k < NSTEPS && strcmp(argv[i], steps[k]); k++)
            ;
        if (k == NSTEPS)
            die("unknown hwtest step '%s' (regs bram regfile dma ddr err split log)", argv[i]);
        want[k] = any = 1;
    }
    printf("hwtest on %s\n", g_bdf);
    for (int k = 0; k < NSTEPS; k++) {
        if (any && !want[k])
            continue;
        printf("\n[%s] %s\n", steps[k], titles[k]);
        switch (k) {
        case 0: t_regs(); break;
        case 1: t_bram(); break;
        case 2: t_regfile(); break;
        case 3: t_dma(); break;
        case 4: t_ddr(ddr); break;
        case 5: t_err(); break;
        case 6: t_split(); break;
        case 7: t_log(); break;
        }
        if (g_fails) {
            printf("\nhwtest: FAIL in step %s (%u of %u checks failed, warnings: %u); later "
                   "steps not run\n", steps[k], g_fails, g_checks, g_warns);
            return 1;
        }
    }
    printf("\nhwtest: PASS (%u checks, warnings: %u)\n", g_checks, g_warns);
    return 0;
}

/* ------------------------------------------------------------ soak */
static uint64_t xorshift(uint64_t *s)
{
    *s ^= *s << 13;
    *s ^= *s >> 7;
    *s ^= *s << 17;
    return *s;
}

static int cmd_soak(uint64_t n)
{
    uint64_t s = (uint64_t)time(NULL) * 0x9E3779B97F4A7C15ull | 1, bad = 0, i;
    double t0 = now_s(), dt;
    uint32_t st;

    printf("soak: %" PRIu64 " random 4/8-byte BRAM write/read pairs\n", n);
    for (i = 0; i < n && bad < 10; i++) {
        uint64_t r = xorshift(&s);
        if (r & 1) {
            uint32_t off = (uint32_t)((r >> 8) % (PIPS_BRAM_SIZE / 8)) * 8;
            uint64_t p = xorshift(&s), q;
            bar_wr64(off, p);
            if ((q = bar_rd64(off)) != p && bad++ < 10)
                printf("  0x%03x: wrote 0x%016" PRIx64 " read 0x%016" PRIx64 "\n", off, p, q);
        } else {
            uint32_t off = (uint32_t)((r >> 8) % (PIPS_BRAM_SIZE / 4)) * 4, p = (uint32_t)(r >> 32), q;
            bar_wr32(off, p);
            if ((q = bar_rd32(off)) != p && bad++ < 10)
                printf("  0x%03x: wrote 0x%08x read 0x%08x\n", off, p, q);
        }
        if (n >= 10 && (i + 1) % (n / 10) == 0)
            printf("  %" PRIu64 " / %" PRIu64 ", %" PRIu64 " mismatches, %.1f s\n", i + 1, n,
                   bad, now_s() - t0);
    }
    dt = now_s() - t0;
    st = bar_rd32(PIPS_REG_PIO_STATUS);
    printf("soak: %s: %" PRIu64 " pairs, %" PRIu64 " mismatches%s, PIO_STATUS 0x%08x, "
           "%.2f us per pair\n", bad || st ? "FAIL" : "PASS", i, bad,
           bad >= 10 ? " (stopped at 10)" : "", st, i ? dt / i * 1e6 : 0.0);
    return bad || st ? 1 : 0;
}

/* ------------------------------------------------------------ background read engine
 * pips_bg_rd_0 at PIPS_AXI_BG (design >= 0x0A08). Register map: pips_regs.h
 * PIPS_BG_*; rules: the FPGA repo's sw_handoff/README.md section 12. Every
 * command that starts the engine stops it on every exit path (bg_owned). */
#define BG_CYCLE_NS 4.0
static int g_bg_owned;                   /* this process started a run: stop it at exit */
static volatile sig_atomic_t g_bg_sig;

static uint32_t bg_rd(uint32_t off) { return axi_rd_ok(PIPS_AXI_BG + off, "engine register read"); }
static void bg_wr(uint32_t off, uint32_t v) { axi_wr_ok(PIPS_AXI_BG + off, v, "engine register write"); }

/* Snapshot counters: LO and HI from the same snapshot. Live 64-bit ones: LO
 * first, it latches HI. */
static uint64_t bg_rd64(uint32_t off)
{
    uint32_t lo = bg_rd(off);
    return lo | (uint64_t)bg_rd(off + 4) << 32;
}

static unsigned bg_state(uint32_t st) { return PIPS_BG_STATE(st); }
static const char *bg_state_name(unsigned s)
{
    static const char *n[] = { "idle", "run", "drain", "start" };
    return n[s & 3];
}

/* Every CTRL write is a start (RUN 1 while idle) or a stop (RUN 0 while
 * running). Writes that are neither (SNAPSHOT, CLEAR, a live ARB/FC_GATE_OFF
 * change) go through here: RUN 0 when idle, RUN 1 while in RUN; in START or
 * DRAIN wait (up to 1 s) for RUN or IDLE first. Should the run have ended in
 * between and the write started a new one (START right after), it is stopped. */
static void bg_ctrl_keep(uint32_t bits)
{
    double t0 = now_s();
    unsigned s;

    bits &= ~PIPS_BG_CTRL_RUN;
    while ((s = bg_state(bg_rd(PIPS_BG_STATUS))) == PIPS_BG_ST_START || s == PIPS_BG_ST_DRAIN) {
        if (now_s() - t0 > 1.0)
            die("engine in %s for 1 s: cannot write CTRL without starting or stopping it", bg_state_name(s));
        sleep_ms(1);
    }
    if (s == PIPS_BG_ST_IDLE) {
        bg_wr(PIPS_BG_CTRL, bits);
        return;
    }
    bg_wr(PIPS_BG_CTRL, bits | PIPS_BG_CTRL_RUN);
    if (bg_state(bg_rd(PIPS_BG_STATUS)) == PIPS_BG_ST_START) {
        bg_wr(PIPS_BG_CTRL, bits);
        fprintf(stderr, "pips: the run ended just as CTRL was written, which started a new one: stopped it\n");
        sleep_ms(2);
    }
}

static int u32_cmp(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

static const char *bg_cfg_name(unsigned c)
{
    static const char *n[] = { "none", "rid not allowed", "ws or stride 0", "random order needs ws a power of two",
                               "table ws > 8192", "read_dw 0/>16 or offset+4*dw crosses 64 B",
                               "max_out 0/>256/> tag window", "seed 0 with random order",
                               "backing not a power of two, or offset != 0 with data check",
                               "first+(ws-1)*stride >= 2^40", "start while not idle",
                               "a table entry names a slot whose rid is 0",
                               "tags quarantined and a latched rid would change" };
    return c < sizeof n / sizeof n[0] ? n[c] : "?";
}

/* The build has the engine: design ID and BG_ID. */
static void bg_check(void)
{
    int id;
    uint32_t bid;

    win_start();
    id = design_id();
    if (id < (int)PIPS_DESIGN_ID_BG)
        die("design 0x%04x has no background read engine (needs >= 0x%04x)", id < 0 ? 0 : id, PIPS_DESIGN_ID_BG);
    bid = bg_rd(PIPS_BG_ID);
    if (bid != PIPS_BG_ID_TEST && bid != PIPS_BG_ID_ENGINE)
        die("BG_ID reads 0x%08x, expected 0x%08x (RIDP) or 0x%08x (BGRD)", bid, PIPS_BG_ID_TEST, PIPS_BG_ID_ENGINE);
}

static void bg_bus(unsigned *pri, unsigned *sec, unsigned *sub)
{
    uint32_t b = bg_rd(PIPS_BG_BUS);

    *pri = b & 0xFF;
    *sec = (b >> 8) & 0xFF;
    *sub = (b >> 16) & 0xFF;
}

/* A requester ID: in0 / port0 (sec:00.0, above in0), in1 / port1 (sec:01.0),
 * usp (pri:00.0), dev0 / dev1 (function 0 of the device below in0 / in1:
 * bus sec+1 / sec+2), BB:DD.F, or a number. 0 or none disarms a slot. */
static uint16_t bg_parse_rid(const char *s)
{
    unsigned pri, sec, sub, b, d, f;

    if (!strcmp(s, "none") || !strcmp(s, "off"))
        return 0;
    bg_bus(&pri, &sec, &sub);
    if (!strcmp(s, "in0") || !strcmp(s, "port0"))
        return PIPS_BG_RID_DSP1(sec);
    if (!strcmp(s, "in1") || !strcmp(s, "port1"))
        return PIPS_BG_RID_DSP0(sec);
    if (!strcmp(s, "usp"))
        return PIPS_BG_RID_USP(pri);
    if (!strcmp(s, "dev0") || !strcmp(s, "dev1"))
        return (uint16_t)(((sec + (s[3] == '0' ? 1u : 2u)) & 0xFF) << 8);
    if (sscanf(s, "%x:%x.%x", &b, &d, &f) == 3 && strchr(s, ':') && b < 256 && d < 32 && f < 8)
        return (uint16_t)(b << 8 | d << 3 | f);
    {
        uint64_t v = parse_num(s, "rid");
        if (v > 0xFFFF)
            die("rid '%s': 16 bits", s);
        return (uint16_t)v;
    }
}

/* What a requester ID is, for printing. */
static const char *bg_rid_name(uint16_t rid, unsigned pri, unsigned sec, unsigned sub)
{
    static char b[4][48];
    static int k;
    char *o = b[k++ & 3];
    unsigned bus = rid >> 8, dev = (rid >> 3) & 31, fn = rid & 7;
    const char *what = "?";

    if (!rid)
        return "none";
    if (rid == PIPS_BG_RID_DSP1(sec)) what = "in0 port";
    else if (rid == PIPS_BG_RID_DSP0(sec)) what = "in1 port";
    else if (rid == PIPS_BG_RID_USP(pri)) what = "usp";
    else if (bus == sec + 1) what = "in0 device";
    else if (bus == sec + 2) what = "in1 device";
    else if (bus > sec && bus <= sub) what = "device";
    snprintf(o, 48, "%02x:%02x.%u(%s)", bus, dev, fn, what);
    return o;
}

static void bg_print_status(uint32_t st)
{
    printf("bg_status=0x%08x bg_state=%s err_stop=%u timeout_seen=%u unexpected_seen=%u cfg_err=%u cfg_code=%u "
           "clearing=%u mismatch_seen=%u count_done=%u table_wr_run=%u clear_refused=%u sink_armed=%u "
           "leak_seen=%u clash_seen=%u quarantined=%u\n", st, bg_state_name(bg_state(st)),
           !!(st & PIPS_BG_STS_ERR_STOP), !!(st & PIPS_BG_STS_TIMEOUT), !!(st & PIPS_BG_STS_UNEXPECTED),
           !!(st & PIPS_BG_STS_CFG_ERR), PIPS_BG_CFG_CODE(st), !!(st & PIPS_BG_STS_CLEARING),
           !!(st & PIPS_BG_STS_MISMATCH), !!(st & PIPS_BG_STS_COUNT_DONE), !!(st & PIPS_BG_STS_TABLE_WR_RUN),
           !!(st & PIPS_BG_STS_CLEAR_REFUSED), !!(st & PIPS_BG_STS_SINK_ARMED), !!(st & PIPS_BG_STS_LEAK),
           !!(st & PIPS_BG_STS_CLASH), PIPS_BG_QUARANTINED(st));
    if (st & PIPS_BG_STS_CFG_ERR)
        printf("# config error %u: %s\n", PIPS_BG_CFG_CODE(st), bg_cfg_name(PIPS_BG_CFG_CODE(st)));
    if (st & PIPS_BG_STS_LEAK)
        printf("# LEAK: a completion for the engine reached a device path. Stop, do not restart, report\n");
    if (st & PIPS_BG_STS_CLASH)
        printf("# CLASH: a device used a tag the engine held (device-ID slot)\n");
}

static int cmd_bg_info(void)
{
    unsigned pri, sec, sub;
    uint32_t caps = bg_rd(PIPS_BG_CAPS), ctrl = bg_rd(PIPS_BG_CTRL), win = bg_rd(PIPS_BG_TAG_WIN);
    uint32_t rid0 = bg_rd(PIPS_BG_RID);

    bg_bus(&pri, &sec, &sub);
    printf("bg_id=0x%08x bg_kind=%s bg_version=0x%08x\n", bg_rd(PIPS_BG_ID),
           bg_rd(PIPS_BG_ID) == PIPS_BG_ID_TEST ? "test" : "engine", bg_rd(PIPS_BG_VERSION));
    printf("bg_caps=0x%08x tags=%u table=%u trace=%u hist_bins=%u np_gating=%u\n", caps, caps & 0x3FF,
           1u << ((caps >> 16) & 15), 1u << ((caps >> 20) & 15), 1u << ((caps >> 24) & 63), !!(caps & (1u << 30)));
    printf("bus_primary=0x%02x bus_secondary=0x%02x bus_subordinate=0x%02x\n", pri, sec, sub);
    printf("rid_in0=0x%04x rid_in1=0x%04x rid_usp=0x%04x rid_dev0=0x%04x rid_dev1=0x%04x\n",
           PIPS_BG_RID_DSP1(sec), PIPS_BG_RID_DSP0(sec), PIPS_BG_RID_USP(pri), (sec + 1) << 8, (sec + 2) << 8);
    bg_print_status(bg_rd(PIPS_BG_STATUS));
    printf("ctrl=0x%08x run=%u stop_on_err=%u arb=%u src=%s order=%s data_check=%u clear_on_start=%u trace=%u "
           "fc_gate_off=%u sink_ridtag=%u\n", ctrl, ctrl & 1, !!(ctrl & PIPS_BG_CTRL_STOP_ON_ERR),
           (ctrl & PIPS_BG_CTRL_ARB_MASK) >> PIPS_BG_CTRL_ARB_SHIFT, ctrl & PIPS_BG_CTRL_SRC_TABLE ? "table" : "pattern",
           ctrl & PIPS_BG_CTRL_ORDER_RANDOM ? "random" : "cyclic", !!(ctrl & PIPS_BG_CTRL_DATA_CHECK),
           !!(ctrl & PIPS_BG_CTRL_CLEAR_ON_START), !!(ctrl & PIPS_BG_CTRL_TRACE_EN), !!(ctrl & PIPS_BG_CTRL_FC_GATE_OFF),
           !!(ctrl & PIPS_BG_CTRL_SINK_RIDTAG));
    printf("rid0=0x%04x rid0_latched=0x%04x # %s\n", rid0 & 0xFFFF, rid0 >> 16, bg_rid_name(rid0 & 0xFFFF, pri, sec, sub));
    for (unsigned n = 1; n <= 3; n++) {
        uint32_t r = bg_rd(PIPS_BG_RID_SLOT(n));
        printf("rid%u=0x%04x rid%u_latched=0x%04x # %s\n", n, r & 0xFFFF, n, r >> 16, bg_rid_name(r & 0xFFFF, pri, sec, sub));
    }
    printf("base=0x%" PRIx64 " first=%u stride=%u ws=%u seed=0x%x offset=%u read_dw=%u\n",
           (uint64_t)bg_rd(PIPS_BG_BASE_HI) << 32 | bg_rd(PIPS_BG_BASE_LO), bg_rd(PIPS_BG_FIRST), bg_rd(PIPS_BG_STRIDE),
           bg_rd(PIPS_BG_WS), bg_rd(PIPS_BG_SEED), bg_rd(PIPS_BG_OFFSET), bg_rd(PIPS_BG_READ_DW));
    printf("interval=%u max_out=%u nph_reserve=%u count=%" PRIu64 " timeout=%u backing=%u hist_shift=%u trace_skip=%u\n",
           bg_rd(PIPS_BG_INTERVAL), bg_rd(PIPS_BG_MAX_OUT), bg_rd(PIPS_BG_NPH_RESERVE),
           (uint64_t)bg_rd(PIPS_BG_COUNT_HI) << 32 | bg_rd(PIPS_BG_COUNT_LO), bg_rd(PIPS_BG_TIMEOUT),
           bg_rd(PIPS_BG_BACKING), bg_rd(PIPS_BG_HIST_SHIFT), bg_rd(PIPS_BG_TRACE_SKIP));
    printf("tag_win=0x%08x tag_win_lo=%u tag_win_hi=%u tag_win_en=%u unsafe=%u\n", win, win & 0xFF, (win >> 8) & 0xFF,
           !!(win & (1u << 16)), bg_rd(PIPS_BG_UNSAFE_KEY) & 1);
    return 0;
}

static int bg_flag(const char *k, const char *v)
{
    if (!strcmp(v, "1") || !strcmp(v, "on") || !strcmp(v, "yes"))
        return 1;
    if (!strcmp(v, "0") || !strcmp(v, "off") || !strcmp(v, "no"))
        return 0;
    die("%s=%s: 0 or 1", k, v);
}

/* bg set K=V...: registers in the order given, CTRL once at the end. The
 * latched ones only while IDLE (the engine reads them at start); interval=,
 * maxout=, nphres=, arb= and fcoff= are live. Returns the keys it took. */
static int bg_set(int argc, char **argv, int quiet)
{
    static const char *live[] = { "interval", "maxout", "nphres", "arb", "fcoff", NULL };
    uint32_t st = bg_rd(PIPS_BG_STATUS), ctrl, ctrl0;
    int idle = bg_state(st) == PIPS_BG_ST_IDLE, n = 0;

    ctrl0 = ctrl = bg_rd(PIPS_BG_CTRL) & ~(PIPS_BG_CTRL_CLEAR | PIPS_BG_CTRL_SNAPSHOT);
    for (int i = 0; i < argc; i++) {
        char k[32], *eq = strchr(argv[i], '=');
        const char *v;
        int is_live = 0;

        if (!eq || eq == argv[i] || (size_t)(eq - argv[i]) >= sizeof k)
            die("bg set: '%s' is not KEY=VALUE", argv[i]);
        snprintf(k, sizeof k, "%.*s", (int)(eq - argv[i]), argv[i]);
        v = eq + 1;
        for (int j = 0; live[j]; j++)
            is_live |= !strcmp(k, live[j]);
        if (!idle && !is_live)
            die("bg set %s: the engine is %s; only interval= maxout= nphres= arb= fcoff= change while it runs",
                k, bg_state_name(bg_state(st)));
        n++;
        if (!strcmp(k, "rid") || !strcmp(k, "rid0"))
            bg_wr(PIPS_BG_RID, bg_parse_rid(v));
        else if (!strcmp(k, "rid1") || !strcmp(k, "rid2") || !strcmp(k, "rid3"))
            bg_wr(PIPS_BG_RID_SLOT(k[3] - '0'), bg_parse_rid(v));
        else if (!strcmp(k, "base")) {
            uint64_t a = parse_num(v, "base");
            if (a & 0xFFF)
                die("base=0x%" PRIx64 ": page aligned", a);
            bg_wr(PIPS_BG_BASE_LO, (uint32_t)a);
            bg_wr(PIPS_BG_BASE_HI, (uint32_t)(a >> 32));
        } else if (!strcmp(k, "first")) bg_wr(PIPS_BG_FIRST, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "stride")) bg_wr(PIPS_BG_STRIDE, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "ws")) bg_wr(PIPS_BG_WS, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "seed")) bg_wr(PIPS_BG_SEED, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "offset")) {
            uint64_t o = parse_num(v, k);
            if (o > 4092 || o % 4)
                die("offset=%s: bytes, a multiple of 4 below 4096", v);
            bg_wr(PIPS_BG_OFFSET, (uint32_t)o);
        } else if (!strcmp(k, "dw")) bg_wr(PIPS_BG_READ_DW, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "interval")) {
            uint64_t x = parse_num(v, k);
            if (x > 0xFFFF)
                die("interval=%s: at most 65535 cycles", v);
            bg_wr(PIPS_BG_INTERVAL, (uint32_t)x);
        } else if (!strcmp(k, "maxout")) bg_wr(PIPS_BG_MAX_OUT, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "nphres")) bg_wr(PIPS_BG_NPH_RESERVE, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "count")) {
            uint64_t c = parse_num(v, k);
            bg_wr(PIPS_BG_COUNT_LO, (uint32_t)c);
            bg_wr(PIPS_BG_COUNT_HI, (uint32_t)(c >> 32));
        } else if (!strcmp(k, "timeout")) bg_wr(PIPS_BG_TIMEOUT, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "timeout_us")) bg_wr(PIPS_BG_TIMEOUT, (uint32_t)(parse_num(v, k) * 250));
        else if (!strcmp(k, "backing")) bg_wr(PIPS_BG_BACKING, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "hshift")) bg_wr(PIPS_BG_HIST_SHIFT, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "tskip")) bg_wr(PIPS_BG_TRACE_SKIP, (uint32_t)parse_num(v, k));
        else if (!strcmp(k, "tagwin")) {
            unsigned lo, hi;
            if (!strcmp(v, "off") || !strcmp(v, "0"))
                bg_wr(PIPS_BG_TAG_WIN, 0);
            else if (sscanf(v, "%u-%u", &lo, &hi) == 2 && lo <= hi && hi < 256)
                bg_wr(PIPS_BG_TAG_WIN, lo | hi << 8 | 1u << 16);
            else
                die("tagwin=%s: LO-HI (0-255, inclusive) or off", v);
        } else if (!strcmp(k, "unsafe")) {
            if (bg_flag(k, v))
                bg_wr(PIPS_BG_UNSAFE_KEY, PIPS_BG_UNSAFE_MAGIC);
        } else if (!strcmp(k, "arb")) {
            unsigned a = !strcmp(v, "idle") ? 0 : !strcmp(v, "rr") ? 1 : !strcmp(v, "engine") ? 2 : (unsigned)parse_num(v, k);
            if (a > 2)
                die("arb=%s: idle (0), rr (1) or engine (2)", v);
            ctrl = (ctrl & ~PIPS_BG_CTRL_ARB_MASK) | a << PIPS_BG_CTRL_ARB_SHIFT;
        } else {
            uint32_t bit = 0;
            int on;
            if (!strcmp(k, "src")) {
                if (strcmp(v, "table") && strcmp(v, "pattern"))
                    die("src=%s: pattern or table", v);
                bit = PIPS_BG_CTRL_SRC_TABLE; on = !strcmp(v, "table");
            } else if (!strcmp(k, "order")) {
                if (strcmp(v, "random") && strcmp(v, "cyclic"))
                    die("order=%s: cyclic or random", v);
                bit = PIPS_BG_CTRL_ORDER_RANDOM; on = !strcmp(v, "random");
            } else {
                static const struct { const char *k; uint32_t b; } fl[] = {
                    { "dcheck", PIPS_BG_CTRL_DATA_CHECK }, { "trace", PIPS_BG_CTRL_TRACE_EN },
                    { "fcoff", PIPS_BG_CTRL_FC_GATE_OFF }, { "ridtag", PIPS_BG_CTRL_SINK_RIDTAG },
                    { "stoponerr", PIPS_BG_CTRL_STOP_ON_ERR }, { "clronstart", PIPS_BG_CTRL_CLEAR_ON_START } };
                for (size_t j = 0; j < sizeof fl / sizeof fl[0]; j++)
                    if (!strcmp(k, fl[j].k))
                        bit = fl[j].b;
                if (!bit)
                    die("bg set: unknown key '%s' (pips bg help)", k);
                on = bg_flag(k, v);
            }
            ctrl = on ? ctrl | bit : ctrl & ~bit;
        }
    }
    if (ctrl != ctrl0)
        bg_ctrl_keep(ctrl);
    if (!quiet)
        printf("# bg set: %d key(s)%s\n", n, ctrl != ctrl0 ? ", CTRL written" : "");
    return n;
}

/* Stop: RUN 0, then wait for IDLE. 0 = idle, -1 = still not idle after ms. */
static int bg_stop(unsigned ms)
{
    double t0 = now_s();
    uint32_t c = bg_rd(PIPS_BG_CTRL) & ~(PIPS_BG_CTRL_CLEAR | PIPS_BG_CTRL_SNAPSHOT | PIPS_BG_CTRL_RUN);

    bg_wr(PIPS_BG_CTRL, c);
    while (bg_state(bg_rd(PIPS_BG_STATUS)) != PIPS_BG_ST_IDLE) {
        if ((now_s() - t0) * 1e3 > ms)
            return -1;
        sleep_ms(1);
    }
    g_bg_owned = 0;
    return 0;
}

static void bg_atexit(void)
{
    static int busy;

    if (!g_bg_owned || busy)
        return;
    busy = 1;
    fprintf(stderr, "pips: stopping the background read engine on exit\n");
    if (bg_stop(3000))
        fprintf(stderr, "pips: the engine is not idle 3 s after stop: pips bg stop; pips bg info\n");
}

static void bg_on_signal(int s) { g_bg_sig = s; }

/* Start: RUN 1 while IDLE, wait out START. Returns the state after it, or -1
 * when the start was refused (config error printed). */
static int bg_start(void)
{
    uint32_t st = bg_rd(PIPS_BG_STATUS), c;
    double t0;

    if (bg_state(st) != PIPS_BG_ST_IDLE)
        die("bg start: the engine is %s (pips bg stop first)", bg_state_name(bg_state(st)));
    c = bg_rd(PIPS_BG_CTRL) & ~(PIPS_BG_CTRL_CLEAR | PIPS_BG_CTRL_SNAPSHOT);
    atexit(bg_atexit);
    g_bg_owned = 1;
    bg_wr(PIPS_BG_CTRL, c | PIPS_BG_CTRL_RUN);
    t0 = now_s();
    while (bg_state(st = bg_rd(PIPS_BG_STATUS)) == PIPS_BG_ST_START) {
        if (now_s() - t0 > 0.5)
            die("bg start: still in START after 500 ms (STATUS 0x%08x)", st);
    }
    if (bg_state(st) == PIPS_BG_ST_IDLE && (st & PIPS_BG_STS_CFG_ERR)) {
        g_bg_owned = 0;
        bg_print_status(st);
        fprintf(stderr, "pips: bg start refused: config error %u (%s)\n", PIPS_BG_CFG_CODE(st),
                bg_cfg_name(PIPS_BG_CFG_CODE(st)));
        return -1;
    }
    if (bg_state(st) == PIPS_BG_ST_IDLE)
        g_bg_owned = 0;                 /* already done (a short COUNT) */
    return (int)bg_state(st);
}

/* The BAR0 lock, given up while a long run waits so other pips calls get in. */
static void lock_drop(void)
{
    if (g_lock_fd >= 0)
        flock(g_lock_fd, LOCK_UN);
}
static void lock_back(void)
{
    if (g_lock_fd < 0)
        return;
    for (int i = 0; flock(g_lock_fd, LOCK_EX | LOCK_NB); i++) {
        if (i == 300)
            die("another pips has held %s for 30 s while a bg run waited", LOCK_FILE);
        sleep_ms(100);
    }
    g_page = UINT64_MAX;                /* WIN_BASE may have moved meanwhile */
}

static void bg_print_counters(void)
{
    uint32_t c = bg_rd(PIPS_BG_CTRL) & ~(PIPS_BG_CTRL_CLEAR | PIPS_BG_CTRL_SNAPSHOT);
    static const struct { const char *n; uint32_t off; } k64[] = {
        { "cycles", PIPS_BG_CYCLES }, { "run_cycles", PIPS_BG_RUN_CYCLES }, { "issued", PIPS_BG_ISSUED },
        { "cpl_sc", PIPS_BG_CPL_SC }, { "cpl_ur", PIPS_BG_CPL_UR }, { "cpl_ca", PIPS_BG_CPL_CA },
        { "cpl_other", PIPS_BG_CPL_OTHER }, { "cpl_poisoned", PIPS_BG_CPL_POISONED },
        { "cpl_malformed", PIPS_BG_CPL_MALFORMED }, { "cpl_unexpected", PIPS_BG_CPL_UNEXPECTED },
        { "timeouts", PIPS_BG_TIMEOUTS }, { "lat_sum", PIPS_BG_LAT_SUM }, { "stall_arb", PIPS_BG_STALL_ARB },
        { "stall_tags", PIPS_BG_STALL_TAGS }, { "stall_fc", PIPS_BG_STALL_FC },
        { "data_mismatch", PIPS_BG_DATA_MISMATCH } };
    uint64_t v[sizeof k64 / sizeof k64[0]];
    uint32_t lmin, lmax, lc, st, cl, ll, tfc, itm;

    bg_ctrl_keep(c | PIPS_BG_CTRL_SNAPSHOT);
    for (size_t i = 0; i < sizeof k64 / sizeof k64[0]; i++) {
        v[i] = bg_rd64(k64[i].off);
        printf("%s=%" PRIu64 "\n", k64[i].n, v[i]);
    }
    lmin = bg_rd(PIPS_BG_LAT_MIN);
    lmax = bg_rd(PIPS_BG_LAT_MAX);
    printf("lat_min=%u\nlat_max=%u\noutstanding=%u\nout_max=%u\n", lmin, lmax, bg_rd(PIPS_BG_OUTSTANDING),
           bg_rd(PIPS_BG_OUT_MAX));
    {
        uint64_t ncpl = v[3] + v[4] + v[5] + v[6];
        double run_s = v[1] * BG_CYCLE_NS * 1e-9;
        printf("lat_mean_ns=%.1f\nlat_min_ns=%.1f\nlat_max_ns=%.1f\nrun_s=%.6f\nissue_rate_mrd_s=%.0f\n",
               ncpl ? (double)v[11] / ncpl * BG_CYCLE_NS : 0.0, lmin == 0xFFFFFFFFu ? 0.0 : lmin * BG_CYCLE_NS,
               lmax * BG_CYCLE_NS, run_s, run_s > 0 ? v[2] / run_s : 0.0);
    }
    lc = bg_rd(PIPS_BG_LAST_CPL);
    printf("last_cpl=0x%08x\nlast_cpl_tag=%u\nlast_cpl_status=%u\nlast_cpl_poisoned=%u\nlast_cpl_err=%u\nlast_cpl_bytes=%u\n",
           lc, lc & 0xFF, (lc >> 8) & 7, !!(lc & (1u << 11)), (lc >> 12) & 15, (lc >> 16) & 0x1FFF);
    printf("last_data=0x%08x\nlast_err_page=%u\nlast_err_seq=%u\n", bg_rd(PIPS_BG_LAST_DATA),
           bg_rd(PIPS_BG_LAST_ERR_PAGE), bg_rd(PIPS_BG_LAST_ERR_SEQ));
    /* test extensions, live */
    printf("leak_cpl=%" PRIu64 "\n", bg_rd64(PIPS_BG_LEAK_CPL));
    ll = bg_rd(PIPS_BG_LEAK_LAST);
    printf("leak_last=0x%08x\nleak_last_rid=0x%04x\nleak_last_tag=%u\nleak_last_path=dsp%u\n", ll, ll & 0xFFFF,
           (ll >> 16) & 0xFF, (ll >> 24) & 1);
    cl = bg_rd(PIPS_BG_CLASH);
    printf("clash=%u\nclash_last_tag=%u\nclash_last_input=in%u\n", cl & 0xFFFF, (cl >> 16) & 0xFF, (cl >> 24) & 1);
    printf("rc_straddle=%u\nrq_straddle=%u\n", bg_rd(PIPS_BG_RC_STRADDLE), bg_rd(PIPS_BG_RQ_STRADDLE));
    tfc = bg_rd(PIPS_BG_TFC);
    printf("tfc=0x%08x\ntfc_present=%u\ntfc_nph_av=%u\ntfc_npd_av=%u\ntfc_nph_min=%u\n", tfc, tfc >> 31, tfc & 15,
           (tfc >> 4) & 15, (tfc >> 8) & 15);
    printf("hol_engine=%" PRIu64 "\nhol_device=%" PRIu64 "\n", bg_rd64(PIPS_BG_HOL_ENGINE), bg_rd64(PIPS_BG_HOL_DEVICE));
    printf("in0_mrd=%" PRIu64 "\nin1_mrd=%" PRIu64 "\n", bg_rd64(PIPS_BG_IN0_MRD), bg_rd64(PIPS_BG_IN1_MRD));
    itm = bg_rd(PIPS_BG_IN_TAG_MAX);
    printf("in0_tag_max=%u\nin1_tag_max=%u\nwin_hits=%u\n", itm & 0xFF, (itm >> 8) & 0xFF, bg_rd(PIPS_BG_WIN_HITS));
    st = bg_rd(PIPS_BG_STATUS);
    bg_print_status(st);
}

/* A 256-bit tag map: the tags as ranges, how many, the largest unused range. */
static void bg_tagmap(const char *name, uint32_t off)
{
    uint32_t w[8];
    char r[1100] = "";
    int n = 0, best_lo = -1, best_n = 0, run_lo = -1;

    for (int i = 0; i < 8; i++)
        w[i] = bg_rd(off + 4u * i);
    for (int t = 0; t <= 256; t++) {
        int set = t < 256 && (w[t >> 5] >> (t & 31) & 1);
        n += set;
        if (set && (t == 0 || !(w[(t - 1) >> 5] >> ((t - 1) & 31) & 1)))
            run_lo = t;
        if (!set && run_lo >= 0) {
            snprintf(r + strlen(r), sizeof r - strlen(r), "%s%d", r[0] ? "," : "", run_lo);
            if (t - 1 > run_lo)
                snprintf(r + strlen(r), sizeof r - strlen(r), "-%d", t - 1);
            run_lo = -1;
        }
    }
    for (int t = 0, lo = -1; t <= 256; t++) {
        int set = t == 256 || (w[t >> 5] >> (t & 31) & 1);
        if (!set && lo < 0)
            lo = t;
        if (set && lo >= 0) {
            if (t - lo > best_n) { best_n = t - lo; best_lo = lo; }
            lo = -1;
        }
    }
    printf("%s_tags=%s\n%s_tags_n=%d\n", name, r[0] ? r : "none", name, n);
    if (best_n)
        printf("%s_free_max=%d-%d\n%s_free_max_n=%d\n", name, best_lo, best_lo + best_n - 1, name, best_n);
    else
        printf("%s_free_max=none\n%s_free_max_n=0\n", name, name);
    printf("%s_map=", name);
    for (int i = 7; i >= 0; i--)
        printf("%08x", w[i]);
    putchar('\n');
}

static int cmd_bg_census(int argc, char **argv)
{
    if (argc == 1 && !strcmp(argv[0], "clear")) {
        bg_wr(PIPS_BG_CENSUS_CTRL, 1);
        printf("# census cleared\n");
        return 0;
    }
    if (argc == 1 && (!strcmp(argv[0], "freeze") || !strcmp(argv[0], "thaw"))) {
        bg_wr(PIPS_BG_CENSUS_CTRL, !strcmp(argv[0], "freeze") ? 2 : 0);
        printf("# census %s\n", argv[0][0] == 'f' ? "frozen" : "counting");
        return 0;
    }
    if (argc)
        die("usage: pips bg census [clear|freeze|thaw]");
    {
        uint32_t itm = bg_rd(PIPS_BG_IN_TAG_MAX);
        printf("in0_mrd=%" PRIu64 "\nin1_mrd=%" PRIu64 "\n", bg_rd64(PIPS_BG_IN0_MRD), bg_rd64(PIPS_BG_IN1_MRD));
        printf("in0_tag_max=%u\nin1_tag_max=%u\nwin_hits=%u\n", itm & 0xFF, (itm >> 8) & 0xFF, bg_rd(PIPS_BG_WIN_HITS));
    }
    bg_tagmap("in0", PIPS_BG_IN0_TAGS);
    bg_tagmap("in1", PIPS_BG_IN1_TAGS);
    bg_tagmap("cpl0", PIPS_BG_CPL0_TAGS);
    bg_tagmap("cpl1", PIPS_BG_CPL1_TAGS);
    return 0;
}

static int cmd_bg_facts(int argc, char **argv)
{
    uint32_t tfc;

    if (argc == 1 && !strcmp(argv[0], "clear")) {
        bg_wr(PIPS_BG_FC_CLEAR, 1);
        printf("# straddle, TFC minimum and head-of-line counters cleared\n");
        return 0;
    }
    if (argc)
        die("usage: pips bg facts [clear]");
    tfc = bg_rd(PIPS_BG_TFC);
    printf("rc_straddle=%u\nrq_straddle=%u\n", bg_rd(PIPS_BG_RC_STRADDLE), bg_rd(PIPS_BG_RQ_STRADDLE));
    printf("tfc=0x%08x\ntfc_present=%u\ntfc_nph_av=%u\ntfc_npd_av=%u\ntfc_nph_min=%u\n", tfc, tfc >> 31, tfc & 15,
           (tfc >> 4) & 15, (tfc >> 8) & 15);
    printf("hol_engine=%" PRIu64 "\nhol_device=%" PRIu64 "\n", bg_rd64(PIPS_BG_HOL_ENGINE), bg_rd64(PIPS_BG_HOL_DEVICE));
    {
        uint64_t lk = bg_rd64(PIPS_BG_LEAK_CPL);
        uint32_t ll = bg_rd(PIPS_BG_LEAK_LAST), cl = bg_rd(PIPS_BG_CLASH);
        printf("leak_cpl=%" PRIu64 "\nleak_last_rid=0x%04x\nleak_last_tag=%u\nleak_last_path=dsp%u\n", lk, ll & 0xFFFF,
               (ll >> 16) & 0xFF, (ll >> 24) & 1);
        printf("clash=%u\nclash_last_tag=%u\nclash_last_input=in%u\n", cl & 0xFFFF, (cl >> 16) & 0xFF, (cl >> 24) & 1);
    }
    return 0;
}

static int cmd_bg_hist(void)
{
    uint32_t sh = bg_rd(PIPS_BG_HIST_SHIFT) & 15;
    uint64_t tot = 0;

    printf("hist_shift=%u\n# bin lo_ns hi_ns count (bin = latency_cycles >> shift, the last bin open-ended)\n", sh);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t c = bg_rd(PIPS_BG_HIST + 4u * i);
        tot += c;
        if (c)
            printf("hist %u %.0f %s%.0f %u\n", i, (double)((uint64_t)i << sh) * BG_CYCLE_NS, i == 63 ? ">" : "",
                   (double)(((uint64_t)(i + 1) << sh)) * BG_CYCLE_NS, c);
    }
    printf("hist_total=%" PRIu64 "\n", tot);
    return 0;
}

/* The latency trace as CSV, and a summary. */
static int cmd_bg_trace(int argc, char **argv)
{
    uint64_t n = argc > 1 ? parse_num(argv[1], "N") : 4096;
    uint32_t skip = bg_rd(PIPS_BG_TRACE_SKIP), *lat;
    uint64_t valid = 0, nlat = 0, tmo = 0, mism = 0, nsc = 0;
    FILE *f;

    if (argc < 1 || argc > 2)
        die("usage: pips bg trace FILE [N]");
    if (n > 4096)
        n = 4096;
    if (!(f = fopen(argv[0], "w")))
        die("%s: %s", argv[0], strerror(errno));
    if (!(lat = malloc(n * sizeof *lat)))
        die("out of memory");
    fprintf(f, "idx,seq,lat_cycles,lat_ns,status,poisoned,timed_out,mismatch\n");
    for (uint64_t i = 0; i < n; i++) {
        uint32_t v = bg_rd(PIPS_BG_TRACE + 4u * (uint32_t)i);
        if (!(v & PIPS_BG_TRACE_VALID))
            continue;
        valid++;
        tmo += !!(v & PIPS_BG_TRACE_TIMED_OUT);
        mism += !!(v & PIPS_BG_TRACE_MISMATCH);
        nsc += PIPS_BG_TRACE_STATUS(v) == 0 && !(v & PIPS_BG_TRACE_TIMED_OUT);
        if (PIPS_BG_TRACE_LAT(v) != 0xFFFF)
            lat[nlat++] = PIPS_BG_TRACE_LAT(v);
        fprintf(f, "%" PRIu64 ",%" PRIu64 ",%u,%.0f,%u,%u,%u,%u\n", i, (uint64_t)skip + i, PIPS_BG_TRACE_LAT(v),
                PIPS_BG_TRACE_LAT(v) * BG_CYCLE_NS, PIPS_BG_TRACE_STATUS(v), !!(v & PIPS_BG_TRACE_POISONED),
                !!(v & PIPS_BG_TRACE_TIMED_OUT), !!(v & PIPS_BG_TRACE_MISMATCH));
    }
    fclose(f);
    printf("trace_file=%s\ntrace_valid=%" PRIu64 "\ntrace_sc=%" PRIu64 "\ntrace_timed_out=%" PRIu64
           "\ntrace_mismatch=%" PRIu64 "\n", argv[0], valid, nsc, tmo, mism);
    if (nlat) {
        qsort(lat, nlat, sizeof *lat, u32_cmp);
        printf("trace_lat_ns_min=%.0f\ntrace_lat_ns_p50=%.0f\ntrace_lat_ns_p90=%.0f\ntrace_lat_ns_p99=%.0f\n"
               "trace_lat_ns_max=%.0f\n", lat[0] * BG_CYCLE_NS, lat[nlat / 2] * BG_CYCLE_NS,
               lat[nlat * 9 / 10] * BG_CYCLE_NS, lat[nlat * 99 / 100] * BG_CYCLE_NS, lat[nlat - 1] * BG_CYCLE_NS);
    }
    free(lat);
    return 0;
}

/* The completion capture ring, oldest first. RC descriptor: DW0 [11:0] lower
 * address, [15:12] error code, [28:16] byte count, [30] request completed;
 * DW1 [10:0] dword count, [13:11] status, [14] poisoned, [31:16] requester ID;
 * DW2 [7:0] tag, [23:8] completer ID. */
static int cmd_bg_capture(int argc, char **argv)
{
    uint32_t wp = bg_rd(PIPS_BG_CAP_WPTR), total = wp >> 8, n = argc ? (uint32_t)parse_num(argv[0], "N") : 64;
    unsigned pri, sec, sub;

    if (n > 64)
        n = 64;
    if (n > total)
        n = total;
    bg_bus(&pri, &sec, &sub);
    printf("cap_written=%u\ncap_shown=%u\n", total, n);
    for (uint32_t k = 0; k < n; k++) {
        uint32_t i = ((wp & 63) + 64 - n + k) & 63, w[8];
        for (int j = 0; j < 8; j++)
            w[j] = bg_rd(PIPS_BG_CAP + 32u * i + 4u * (uint32_t)j);
        printf("cap i=%u seq=%u slot=%u late=%u lat_ns=%.0f rid=0x%04x(%s) tag=%u status=%u poisoned=%u err=%u "
               "bytes=%u dwords=%u req_done=%u lower_addr=0x%03x completer=0x%04x dw0=0x%08x dw1=0x%08x "
               "desc=0x%08x,0x%08x,0x%08x\n",
               i, w[6], w[7] & 3, !!(w[7] & 0x100), w[5] * BG_CYCLE_NS, w[1] >> 16,
               bg_rid_name((uint16_t)(w[1] >> 16), pri, sec, sub), w[2] & 0xFF, (w[1] >> 11) & 7, !!(w[1] & (1u << 14)),
               (w[0] >> 12) & 15, (w[0] >> 16) & 0x1FFF, w[1] & 0x7FF, !!(w[0] & (1u << 30)), w[0] & 0xFFF,
               (w[2] >> 8) & 0xFFFF, w[3], w[4], w[0], w[1], w[2]);
    }
    return 0;
}

/* bg table load FILE: lines "page" or "page:slot" (# comments), entries 0..n-1.
 * bg table show [N]. */
static int cmd_bg_table(int argc, char **argv)
{
    if (argc >= 1 && !strcmp(argv[0], "show")) {
        uint64_t n = argc > 1 ? parse_num(argv[1], "N") : 16;
        for (uint64_t i = 0; i < n && i < 8192; i++) {
            uint32_t v = bg_rd(PIPS_BG_TABLE + 4u * (uint32_t)i);
            printf("table %" PRIu64 " page=%u slot=%u\n", i, v & 0x3FFFFFFFu, v >> 30);
        }
        return 0;
    }
    if (argc == 2 && !strcmp(argv[0], "load")) {
        char line[256];
        uint32_t n = 0, slots = 0;
        FILE *f = fopen(argv[1], "r");

        if (!f)
            die("%s: %s", argv[1], strerror(errno));
        if (bg_state(bg_rd(PIPS_BG_STATUS)) != PIPS_BG_ST_IDLE)
            die("bg table load: the engine is not idle (table writes are ignored outside IDLE)");
        while (fgets(line, sizeof line, f)) {
            char *p = line, *c, *end;
            unsigned long long pg, sl = 0;
            line[strcspn(line, "#\r\n")] = 0;
            while (*p == ' ' || *p == '\t')
                p++;
            if (!*p)
                continue;
            if (n == 8192)
                die("%s: more than 8192 entries", argv[1]);
            errno = 0;
            pg = strtoull(p, &end, 0);
            if (errno || end == p || pg > 0x3FFFFFFFull)
                die("%s: bad page '%s'", argv[1], p);
            if ((c = strchr(p, ':'))) {
                sl = strtoull(c + 1, &end, 0);
                if (sl > 3)
                    die("%s: slot %llu (0-3)", argv[1], sl);
            }
            slots |= 1u << sl;
            bg_wr(PIPS_BG_TABLE + 4u * n, PIPS_BG_TABLE_ENTRY(pg, sl));
            n++;
        }
        fclose(f);
        if (bg_rd(PIPS_BG_STATUS) & PIPS_BG_STS_TABLE_WR_RUN)
            die("bg table load: STATUS says a table write came outside IDLE");
        printf("table_entries=%u\ntable_slots=0x%x\n", n, slots);
        return 0;
    }
    die("usage: pips bg table load FILE | pips bg table show [N]");
}

/* bg run [K=V...] [secs=S] [ms=MS] [stopwin=1]: set, start, wait for the run
 * to end (COUNT reached) or S seconds (then stop), print the counters.
 * SIGINT/SIGTERM stop it; any exit stops it. A leak (STATUS[22]) stops it at
 * once; with stopwin=1 so does a device's read on a tag in the engine's tag
 * window (WIN_HITS rising: the core tracks requests by tag alone, A11).
 * Exit 0 ended normally, 4 an error ended it (ERR_STOP), 5 leak or clash,
 * 6 a device tag in the window (stopwin), 1 refused, 3 not idle after stop. */
static int cmd_bg_run(int argc, char **argv)
{
    char *setv[64];
    int ns = 0, s, leak = 0, beat = 5, stopwin = 0, winhit = 0;
    double secs = 0, ms = 0, t0, last = 0;
    uint32_t st, win0 = 0;
    struct sigaction sa;

    for (int i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "secs=", 5)) secs = atof(argv[i] + 5);
        else if (!strncmp(argv[i], "ms=", 3)) ms = atof(argv[i] + 3);
        else if (!strncmp(argv[i], "beat=", 5)) beat = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "stopwin=", 8)) stopwin = bg_flag("stopwin", argv[i] + 8);
        else if (ns < 64) setv[ns++] = argv[i];
        else die("bg run: too many settings");
    }
    if (ns)
        bg_set(ns, setv, 1);
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = bg_on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    t0 = now_s();
    s = bg_start();
    if (s < 0)
        return 1;
    win0 = bg_rd(PIPS_BG_WIN_HITS);     /* after the start: CLEAR_ON_START may have zeroed it */
    if (secs > 0)
        printf("# bg run: started (%s), stops after %.1f s\n", bg_state_name((unsigned)s), secs);
    else
        printf("# bg run: started (%s), until COUNT%s\n", bg_state_name((unsigned)s), ms > 0 ? " or ms=" : "");
    while (g_bg_owned) {
        double t = now_s() - t0;
        st = bg_rd(PIPS_BG_STATUS);
        if (bg_state(st) == PIPS_BG_ST_IDLE) {
            g_bg_owned = 0;
            break;
        }
        if (st & (PIPS_BG_STS_LEAK | PIPS_BG_STS_CLASH)) {
            leak = 1;
            printf("# bg run: %s seen at %.1f s: stopping now\n", st & PIPS_BG_STS_LEAK ? "LEAK" : "CLASH", t);
            break;
        }
        if (g_bg_sig) {
            printf("# bg run: signal %d at %.1f s: stopping\n", (int)g_bg_sig, t);
            break;
        }
        if (stopwin) {
            uint32_t w = bg_rd(PIPS_BG_WIN_HITS);
            if (w > win0) {
                winhit = 1;
                printf("# bg run: WIN_HITS %u (was %u) at %.1f s: a device used a tag in the engine's window: stopping now\n",
                       w, win0, t);
                break;
            }
        }
        if ((secs > 0 && t >= secs) || (ms > 0 && t * 1e3 >= ms))
            break;
        if (beat > 0 && t - last >= beat) {
            last = t;
            printf("# bg run: %.0f s, %s, outstanding %u, quarantined %u\n", t, bg_state_name(bg_state(st)),
                   bg_rd(PIPS_BG_OUTSTANDING), PIPS_BG_QUARANTINED(st));
        }
        if (t > 0.2) {                  /* long runs: let other pips calls in between polls */
            lock_drop();
            sleep_ms(100);
            lock_back();
        }
    }
    if (g_bg_owned && bg_stop(3000)) {
        bg_print_status(bg_rd(PIPS_BG_STATUS));
        fprintf(stderr, "pips: bg run: the engine is not idle 3 s after stop\n");
        return 3;
    }
    printf("bg_run_s=%.3f\n", now_s() - t0);
    bg_print_counters();
    st = bg_rd(PIPS_BG_STATUS);
    if (leak || (st & (PIPS_BG_STS_LEAK | PIPS_BG_STS_CLASH)))
        return 5;
    if (winhit)
        return 6;
    return st & PIPS_BG_STS_ERR_STOP ? 4 : 0;
}

static int cmd_bg_wait(unsigned ms)
{
    double t0 = now_s(), last = 0;
    uint32_t st;

    while (bg_state(st = bg_rd(PIPS_BG_STATUS)) != PIPS_BG_ST_IDLE) {
        double t = now_s() - t0;
        if (ms && t * 1e3 > ms) {
            bg_print_status(st);
            return 3;
        }
        if (t - last >= 5) {
            last = t;
            printf("# bg wait: %.0f s, %s, outstanding %u\n", t, bg_state_name(bg_state(st)), bg_rd(PIPS_BG_OUTSTANDING));
        }
        lock_drop();
        sleep_ms(20);
        lock_back();
    }
    bg_print_status(st);
    return 0;
}

static int cmd_bg(int argc, char **argv)
{
    const char *c;

    if (argc < 1 || !strcmp(argv[0], "help")) {
        fputs("pips bg info | set K=V... | start | stop [MS] | wait [MS] | run [K=V...] [secs=S] [ms=MS] [beat=S] [stopwin=1]\n"
              "        counters | clear [twice] | hist | trace FILE [N] | capture [N] | census [clear|freeze|thaw]\n"
              "        facts [clear] | table load FILE | table show [N]\n"
              "keys: rid= rid1= rid2= rid3= (in0 in1 usp dev0 dev1 BB:DD.F 0xNNNN none) base= first= stride= ws=\n"
              "      seed= offset= dw= interval= maxout= nphres= count= timeout= timeout_us= backing= hshift= tskip=\n"
              "      tagwin=LO-HI|off unsafe=1 arb=idle|rr|engine src=pattern|table order=cyclic|random\n"
              "      dcheck= trace= fcoff= ridtag= stoponerr= clronstart= (0|1)\n"
              "in0 = the port above input 0 (sec:00.0), in1 = sec:01.0; dev0/dev1 = the device below each\n", stderr);
        return argc < 1 ? 2 : 0;
    }
    bg_check();
    c = argv[0];
    argc--;
    argv++;
    if (!strcmp(c, "info") && !argc) return cmd_bg_info();
    if (!strcmp(c, "set") && argc) { bg_set(argc, argv, 0); return 0; }
    if (!strcmp(c, "start") && !argc) {
        int s = bg_start();
        if (s < 0)
            return 1;
        g_bg_owned = 0;                 /* a bare start leaves it running: the caller owns it */
        bg_print_status(bg_rd(PIPS_BG_STATUS));
        return 0;
    }
    if (!strcmp(c, "stop") && argc <= 1) {
        int r = bg_stop(argc ? (unsigned)parse_num(argv[0], "MS") : 2000);
        bg_print_status(bg_rd(PIPS_BG_STATUS));
        return r ? 3 : 0;
    }
    if (!strcmp(c, "wait") && argc <= 1) return cmd_bg_wait(argc ? (unsigned)parse_num(argv[0], "MS") : 0);
    if (!strcmp(c, "run")) return cmd_bg_run(argc, argv);
    if (!strcmp(c, "counters") && !argc) { bg_print_counters(); return 0; }
    if (!strcmp(c, "clear") && argc <= 1) {
        uint32_t ctl = bg_rd(PIPS_BG_CTRL) & ~(PIPS_BG_CTRL_SNAPSHOT | PIPS_BG_CTRL_CLEAR);
        int times = argc && !strcmp(argv[0], "twice") ? 2 : 1;
        for (int i = 0; i < times; i++) {
            bg_ctrl_keep(ctl | PIPS_BG_CTRL_CLEAR);
            sleep_ms(1);
        }
        bg_print_status(bg_rd(PIPS_BG_STATUS));
        return 0;
    }
    if (!strcmp(c, "hist") && !argc) return cmd_bg_hist();
    if (!strcmp(c, "trace")) return cmd_bg_trace(argc, argv);
    if (!strcmp(c, "capture") && argc <= 1) return cmd_bg_capture(argc, argv);
    if (!strcmp(c, "census")) return cmd_bg_census(argc, argv);
    if (!strcmp(c, "facts")) return cmd_bg_facts(argc, argv);
    if (!strcmp(c, "table")) return cmd_bg_table(argc, argv);
    die("bg %s: unknown or wrong arguments (pips bg help)", c);
}

/* ------------------------------------------------------------ main */
static void usage(void)
{
    fputs("usage: pips [-s BDF] [-f] <command> [args]\n"
          "  info | rd OFF [N] | wr OFF VAL | axi-rd ADDR [N] | axi-wr ADDR VAL\n"
          "  cfg | cfg set depth=N time=N mrd=0|1 log=0|1 raw=VAL cap=0|1 ...\n"
          "        (design >= 0x0a06 also: pb=0|1 pushoff=0|1 quantum=N thr=N thr0=N thr1=N raw2= raw3=)\n"
          "        (design >= 0x0a07 also: rcap=N rcap0=N rcap1=N rcapout=N raw4=; N beats per 256 cycles)\n"
          "  status            page batcher status since the last read (read clears; >= 0x0a06)\n"
          "  counters          refused / rate-cap-held cycles per input (free-running; >= 0x0a07)\n"
          "  dma | dma-reset\n"
          "  log-clear | log-start | log-stop [MS] | log-wait [MS] | log-dump FILE [BYTES]\n"
          "  ddr-dump ADDR BYTES FILE\n"
          "  hwtest [--ddr-addr ADDR] [regs bram regfile dma ddr err split log]\n"
          "  soak [N]\n"
          "  bg help | info | set K=V... | start | stop | wait | run [K=V...] [secs=S] | counters | clear\n"
          "     | hist | trace FILE | capture | census [clear] | facts [clear] | table load FILE   (>= 0x0a08)\n"
          "Header of pips.c has the details.\n", stderr);
    exit(2);
}

int main(int argc, char **argv)
{
    const char *cmd;
    int opt, force = 0, raw;

    setvbuf(stdout, NULL, _IOLBF, 0);
    while ((opt = getopt(argc, argv, "+s:fh")) != -1) {
        switch (opt) {
        case 's': snprintf(g_bdf, sizeof g_bdf, "%s", optarg); break;
        case 'f': force = 1; break;
        default: usage();
        }
    }
    if (optind >= argc)
        usage();
    cmd = argv[optind++];
    argc -= optind;
    argv += optind;
    raw = !strcmp(cmd, "rd") || !strcmp(cmd, "wr");

    take_lock();
    open_bar();
    if (!raw && !force)
        check_id();

    if (!strcmp(cmd, "info") && argc == 0)
        return cmd_info();
    if (!strcmp(cmd, "rd") && (argc == 1 || argc == 2)) {
        uint64_t off = parse_num(argv[0], "OFF"), n = argc == 2 ? parse_num(argv[1], "N") : 1;
        if (off % 4 || off + 4 * n > PIPS_BAR0_SIZE)
            die("OFF must be 4-byte aligned and OFF + 4*N <= 0x8000");
        for (uint64_t i = 0; i < n; i++)
            printf("0x%04" PRIx64 ": 0x%08x\n", off + 4 * i, bar_rd32((uint32_t)(off + 4 * i)));
        return 0;
    }
    if (!strcmp(cmd, "wr") && argc == 2) {
        uint64_t off = parse_num(argv[0], "OFF"), v = parse_num(argv[1], "VAL");
        if (off % 4 || off + 4 > PIPS_BAR0_SIZE || v > 0xFFFFFFFFu)
            die("OFF must be 4-byte aligned below 0x8000, VAL 32 bits");
        bar_wr32((uint32_t)off, (uint32_t)v);
        return 0;
    }
    if (!strcmp(cmd, "axi-rd") && (argc == 1 || argc == 2)) {
        uint64_t a = parse_num(argv[0], "ADDR"), n = argc == 2 ? parse_num(argv[1], "N") : 1;
        win_start();
        for (uint64_t i = 0; i < n; i++)
            printf("0x%08" PRIx64 ": 0x%08x\n", a + 4 * i, axi_rd(a + 4 * i));
        return win_check("axi-rd") ? 1 : 0;
    }
    if (!strcmp(cmd, "axi-wr") && argc == 2) {
        uint64_t a = parse_num(argv[0], "ADDR"), v = parse_num(argv[1], "VAL");
        if (v > 0xFFFFFFFFu)
            die("VAL: 32 bits");
        win_start();
        axi_wr(a, (uint32_t)v);
        return win_check("axi-wr") ? 1 : 0;
    }
    if (!strcmp(cmd, "cfg"))
        return cmd_cfg(argc, argv);
    if (!strcmp(cmd, "status") && argc == 0)
        return cmd_status();
    if (!strcmp(cmd, "counters") && argc == 0)
        return cmd_counters();
    if (!strcmp(cmd, "dma") && argc == 0) {
        win_start();
        dma_print();
        return 0;
    }
    if (!strcmp(cmd, "dma-reset") && argc == 0) {
        win_start();
        dma_reset();
        dma_print();
        return 0;
    }
    if (!strcmp(cmd, "log-clear") && argc == 0)
        return cmd_log_clear();
    if (!strcmp(cmd, "log-start") && argc == 0) {
        win_start();
        log_start(0);
        return 0;
    }
    if ((!strcmp(cmd, "log-stop") || !strcmp(cmd, "log-wait")) && argc <= 1)
        return cmd_log_finish(argc ? (unsigned)parse_num(argv[0], "MS") : 2000,
                              !strcmp(cmd, "log-stop"));
    if (!strcmp(cmd, "log-dump"))
        return cmd_log_dump(argc, argv);
    if (!strcmp(cmd, "ddr-dump") && argc == 3) {
        win_start();
        ddr_dump(parse_num(argv[0], "ADDR"), parse_num(argv[1], "BYTES"), argv[2]);
        return 0;
    }
    if (!strcmp(cmd, "hwtest"))
        return cmd_hwtest(argc, argv);
    if (!strcmp(cmd, "soak") && argc <= 1)
        return cmd_soak(argc ? parse_num(argv[0], "N") : 1000000);
    if (!strcmp(cmd, "bg"))
        return cmd_bg(argc, argv);
    usage();
}
