/*
 * alias-nvme: NVMe read load through VFIO with every data page at an IOVA the
 * pattern chose (alias_common.h): the in-house replacement for fio in the
 * drive campaign.
 *
 * The kernel's nvme driver maps each I/O's buffer on submit and unmaps it on
 * completion, and its IOVA allocator, not the test, decides the addresses.
 * Here the drive is bound to vfio-pci (alias-vfio.sh bind) and this program
 * is its driver: it maps the pattern's region ONCE at a fixed IOVA base
 * (--iova-base, default 1 << 38, aligned far above any region's size, so page
 * k is IOVA page base + k with the low bits = k), then reads with polled
 * queues, each 4 KiB of each read landing on the next pattern page (one PRP
 * entry per page). Nothing is mapped or unmapped while it runs, so the
 * IOTLB misses come from the pattern alone. The drive's own domain is VFIO's
 * (translated in every IOMMU mode the kernel booted with but off; pt too).
 *
 * READ-ONLY: the only commands it ever builds are Identify, Set Features
 * (number of queues), Create/Delete I/O SQ/CQ and Read; nvme_submit refuses
 * anything else and aborts. The drives hold data.
 *
 *   sudo alias-nvme --dev 0000:65:00.0=logs/run/fio-ssd0 --dev 0000:66:00.0=logs/run/fio-ssd1 \
 *        --queues 4 --qd 32 --bs 4096 --cpus 36,37,38,39/45,46,47,48 \
 *        --ws 32 --stride 512 --warm 10 --seconds 120
 *
 * Options:
 *   --dev BDF=PREFIX     a drive (bound to vfio-pci) and its output prefix:
 *                        queue q writes PREFIX-q.json, PREFIX-q_iops.1.log; up to 2
 *   --serial S[,S]       refuse unless each drive's Identify serial is this
 *   --queues N[,N]       I/O queue pairs per drive (default 4), one thread each
 *   --cpus L[/L]         per drive, the CPUs its queue threads run on, round robin
 *   --qd N               reads in flight per queue (default 32)
 *   --bs BYTES           bytes per read (default 4096, a multiple of 4096); past
 *                        the drive's MDTS one read is several commands, counted once
 *   --lba rand|seq       where on the namespace (default rand, aligned to bs)
 *   --nsid N             namespace (default 1)
 *   --ws --stride --first --order --seed --page-list --backing-pages: the pattern
 *   --iova-base A        IOVA of region page 0 (default 0x4000000000)
 *   --warm S --seconds S warm-up, then measure (0 = until SIGINT/TERM)
 *   --heartbeat S --ready-file PATH (touched when every queue is loaded)
 *   --exit-steps S       seconds between the release steps (default 1). The
 *                        drives are always given back one step at a time, a line
 *                        before and after each: bus master off, VFIO_DEVICE_RESET
 *                        (the open path's FLR), BAR unmap, device close (vfio-pci's
 *                        release: FLR, config restore, D3hot), group detach (IOMMU
 *                        domain detach, unmap, unpin), container close. ~17 s.
 *                        Why: on bigserver (11-05) closing the 990 EVO Plus (it
 *                        claims Immediate Readiness, so 5.15 restores its config
 *                        right after the release FLR) froze the host 3 times out
 *                        of 3, and once left the PIPS FPGA unprogrammed; with the
 *                        open path's reset first it released cleanly.
 *                        Before the steps: a normal NVMe shutdown (CC.SHN) per
 *                        drive, then --exit-settle S (default 10) seconds: the
 *                        reset-first exit still froze once (b4's own reset, ~10 s
 *                        after an abrupt CC.EN=0); the resets at open, after the
 *                        nvme driver's shutdown, never did. ~27 s in all.
 *   --exit-d3            before the reset, D3hot and back to D0 (PMCSR), as the
 *                        drive goes at open (where b4's resets never froze)
 *   --exit-unsafe        the old exit: no reset first, everything closed at exit
 *                        (only to reproduce the freeze)
 *   --exit-reverse       two drives: release the second --dev first
 *   An error exit (die) also resets every open drive before closing it.
 *   --hold DIR           hold mode: open and set up the drives once, then run
 *                        loads on command and NEVER release them (no reset of
 *                        b4 after a load: the freeze; HANDOFF §8). A command is
 *                        one line written to DIR/cmd (write DIR/cmd.tmp, then
 *                        rename): "load NAME MASK WS STRIDE ORDER WARM SECONDS
 *                        OUTDIR" (MASK bit i = the i-th --dev; outputs
 *                        OUTDIR/fio-ssd<i>-<queue>.json and _iops.1.log). The
 *                        holder writes DIR/state, DIR/alive (each second: epoch
 *                        ms, pid, load|idle), DIR/done and DIR/done.<n> ("<n>
 *                        NAME ok|FAILED"). Between loads the queues stay and only
 *                        the IOMMU region is remapped for a new pattern. SIGINT /
 *                        SIGTERM stop a load, never the holder. On a fatal error
 *                        it stops writing DIR/alive and waits for ever, drives
 *                        held (a watchdog then resets the host). End: reboot
 *                        with "sync; systemctl reboot -ff" (no process is
 *                        stopped, so nothing is released).
 * Exit: 0 done, 2 usage/setup, 3 a read failed (the run is not valid).
 */
#include "alias_common.h"

#include <dirent.h>
#include <fcntl.h>
#include <linux/vfio.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#define MAXDEV 2
#define MAXQ 64
#define AQ_DEPTH 32
#define CTRL_IOVA 0x10000000ull       /* queues, PRP lists, identify: from 256 MiB up */
#define CTRL_IOVA_END 0xfee00000ull    /* x86 MSI window */

struct ctr {                           /* a VFIO container: one IOMMU domain */
    int fd, set;
    uint64_t next_iova;
};

struct drive;
struct ioq {
    struct drive *d;
    int qid, cpu, idx;
    uint8_t *sq;
    volatile uint8_t *cq;
    uint64_t sq_io, cq_io;
    uint32_t qs, sqt, cqh, phase;
    volatile uint32_t *sqdb, *cqdb;
    uint64_t *prp_va;                  /* qd * k PRP list pages */
    uint64_t prp_io;
    uint64_t *t0;
    uint16_t *left;
    uint64_t rng, seqlba, inflight;
    struct alias_cursor cur;
    struct alias_stats st;
    struct alias_out out;
    int err;
    volatile int live;
    pthread_t th;
};

struct drive {
    char bdf[32], prefix[512], serial[32], model[48], want_serial[32], cpus[512];
    int idx, group, gfd, dfd, nq;
    struct ctr *ct;
    volatile uint8_t *bar;
    uint64_t bar_off, bar_size;
    uint64_t cap, to_ms, nsze, maxxfer, data_iova, shn_ms;
    uint32_t dstrd, mqes, nsid, lba;
    uint8_t *asq;
    volatile uint8_t *acq;
    uint64_t asq_io, acq_io;
    uint32_t atail, ahead, aphase;
    uint16_t acid;
    uint8_t *idbuf;
    uint64_t idbuf_io;
    struct ioq *q;
};

static struct alias_pattern g_pat;
static struct drive g_dev[MAXDEV];
static int g_ndev;
static struct ctr g_ctr[MAXDEV];
static int g_nctr;
static uint64_t g_bs = 4096, g_cmd, g_backing, g_iova_base = 0x4000000000ull;
static uint32_t g_qd = 32, g_k, g_nsid = 1;
static int g_lba_rand = 1;
static volatile int g_measure, g_stopping;
static int g_exit_rev, g_exit_reset = 1;

/* ------------------------------------------------------------ registers */
static uint32_t rd32(struct drive *d, uint32_t off)
{
    if (d->bar)
        return *(volatile uint32_t *)(d->bar + off);
    uint32_t v = 0xffffffff;
    if (pread(d->dfd, &v, 4, (off_t)(d->bar_off + off)) != 4)
        die("%s: BAR0 read at 0x%x failed", d->bdf, off);
    return v;
}

static void wr32(struct drive *d, uint32_t off, uint32_t v)
{
    if (d->bar) {
        *(volatile uint32_t *)(d->bar + off) = v;
        return;
    }
    if (pwrite(d->dfd, &v, 4, (off_t)(d->bar_off + off)) != 4)
        die("%s: BAR0 write at 0x%x failed", d->bdf, off);
}

static uint64_t rd64(struct drive *d, uint32_t off)
{
    return (uint64_t)rd32(d, off) | ((uint64_t)rd32(d, off + 4) << 32);
}

static void wr64(struct drive *d, uint32_t off, uint64_t v)
{
    wr32(d, off, (uint32_t)v);
    wr32(d, off + 4, (uint32_t)(v >> 32));
}

static uint32_t db_off(struct drive *d, int qid, int cq)
{
    return 0x1000u + (uint32_t)(2 * qid + cq) * (4u << d->dstrd);
}

static void ring(struct drive *d, volatile uint32_t *db, uint32_t off, uint32_t v)
{
    __atomic_thread_fence(__ATOMIC_SEQ_CST);   /* queue entries before the doorbell */
    if (db)
        *db = v;
    else
        wr32(d, off, v);
}

/* ------------------------------------------------------------ VFIO */
static int sysfs_link_base(const char *path, char *out, size_t n)
{
    char buf[512];
    ssize_t k = readlink(path, buf, sizeof(buf) - 1);
    if (k < 0)
        return -1;
    buf[k] = 0;
    const char *b = strrchr(buf, '/');
    snprintf(out, n, "%s", b ? b + 1 : buf);
    return 0;
}

static void dma_map(struct ctr *ct, void *va, uint64_t iova, uint64_t size)
{
    struct vfio_iommu_type1_dma_map m;
    memset(&m, 0, sizeof(m));
    m.argsz = sizeof(m);
    m.flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE;
    m.vaddr = (uint64_t)(uintptr_t)va;
    m.iova = iova;
    m.size = size;
    if (ioctl(ct->fd, VFIO_IOMMU_MAP_DMA, &m))
        die("VFIO map of %" PRIu64 " bytes at IOVA 0x%" PRIx64 ": %s", size, iova, strerror(errno));
}

static void *dma_alloc(struct ctr *ct, uint64_t size, uint64_t *iova)
{
    size = (size + ALIAS_PAGE - 1) & ~(ALIAS_PAGE - 1);
    void *va = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (va == MAP_FAILED)
        die("mmap %" PRIu64 " bytes: %s", size, strerror(errno));
    memset(va, 0, size);
    if (ct->next_iova + size > CTRL_IOVA_END)
        die("control IOVA space used up");
    *iova = ct->next_iova;
    ct->next_iova += size;
    dma_map(ct, va, *iova, size);
    return va;
}

static void vfio_open(struct drive *d)
{
    char path[256], v[128];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/driver", d->bdf);
    if (sysfs_link_base(path, v, sizeof(v)) || strcmp(v, "vfio-pci"))
        die("%s is bound to %s, not vfio-pci: bash scripts/pips/alias/alias-vfio.sh bind %s",
            d->bdf, sysfs_link_base(path, v, sizeof(v)) ? "no driver" : v, d->bdf);
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/iommu_group", d->bdf);
    if (sysfs_link_base(path, v, sizeof(v)))
        die("%s has no IOMMU group: the IOMMU is off (VFIO needs it on; pt is fine)", d->bdf);
    d->group = atoi(v);
    for (int i = 0; i < d->idx; i++)      /* two drives in one group share it */
        if (g_dev[i].group == d->group) {
            d->ct = g_dev[i].ct;
            d->gfd = g_dev[i].gfd;
        }
    if (!d->ct) {
        struct ctr *ct = &g_ctr[g_nctr++];
        ct->fd = open("/dev/vfio/vfio", O_RDWR);
        if (ct->fd < 0)
            die("/dev/vfio/vfio: %s (modprobe vfio-pci; run as root)", strerror(errno));
        if (ioctl(ct->fd, VFIO_GET_API_VERSION) != VFIO_API_VERSION)
            die("VFIO API version mismatch");
        ct->next_iova = CTRL_IOVA;
        snprintf(path, sizeof(path), "/dev/vfio/%d", d->group);
        d->gfd = open(path, O_RDWR);
        if (d->gfd < 0)
            die("%s: %s%s", path, strerror(errno),
                errno == EBUSY ? " (another process has this group open)" : "");
        struct vfio_group_status gs = { .argsz = sizeof(gs) };
        ioctl(d->gfd, VFIO_GROUP_GET_STATUS, &gs);
        if (!(gs.flags & VFIO_GROUP_FLAGS_VIABLE))
            die("IOMMU group %d of %s is not viable: every device in it must be bound to vfio-pci "
                "(ls /sys/kernel/iommu_groups/%d/devices; alias-vfio.sh status)", d->group, d->bdf, d->group);
        if (ioctl(d->gfd, VFIO_GROUP_SET_CONTAINER, &ct->fd))
            die("VFIO_GROUP_SET_CONTAINER: %s", strerror(errno));
        int type = ioctl(ct->fd, VFIO_CHECK_EXTENSION, VFIO_TYPE1v2_IOMMU) ? VFIO_TYPE1v2_IOMMU : VFIO_TYPE1_IOMMU;
        /* type1 refuses a host without interrupt remapping (EPERM) unless
         * allow_unsafe_interrupts; this tool polls and never uses interrupts */
        if (ioctl(ct->fd, VFIO_SET_IOMMU, type))
            die("VFIO_SET_IOMMU: %s%s", strerror(errno), errno == EPERM ?
                " (no interrupt remapping? dmesg | grep -i remapping; this tool uses no interrupts, so "
                "'sudo modprobe -r vfio_pci vfio_iommu_type1; sudo modprobe vfio_iommu_type1 "
                "allow_unsafe_interrupts=1' is safe here)" : "");
        ct->set = 1;
        d->ct = ct;
    }
    d->dfd = ioctl(d->gfd, VFIO_GROUP_GET_DEVICE_FD, d->bdf);
    if (d->dfd < 0)
        die("VFIO_GROUP_GET_DEVICE_FD %s: %s", d->bdf, strerror(errno));

    struct vfio_region_info ri = { .argsz = sizeof(ri), .index = VFIO_PCI_BAR0_REGION_INDEX };
    if (ioctl(d->dfd, VFIO_DEVICE_GET_REGION_INFO, &ri) || ri.size < 0x2000)
        die("%s: BAR0 region info", d->bdf);
    d->bar_off = ri.offset;
    d->bar_size = ri.size;
    if (ri.flags & VFIO_REGION_INFO_FLAG_MMAP) {
        void *p = mmap(NULL, ri.size, PROT_READ | PROT_WRITE, MAP_SHARED, d->dfd, (off_t)ri.offset);
        if (p != MAP_FAILED)
            d->bar = p;
    }
    if (!d->bar)
        fprintf(stderr, "WARNING: %s: BAR0 not mappable, using pread/pwrite (slow doorbells)\n", d->bdf);

    /* memory space and bus master on */
    struct vfio_region_info ci = { .argsz = sizeof(ci), .index = VFIO_PCI_CONFIG_REGION_INDEX };
    uint16_t cmd = 0;
    if (ioctl(d->dfd, VFIO_DEVICE_GET_REGION_INFO, &ci) ||
        pread(d->dfd, &cmd, 2, (off_t)(ci.offset + 4)) != 2)
        die("%s: config space", d->bdf);
    cmd |= 0x0006;
    if (pwrite(d->dfd, &cmd, 2, (off_t)(ci.offset + 4)) != 2)
        die("%s: set bus master", d->bdf);
}

/* ------------------------------------------------------------ NVMe */
struct sqe { uint32_t dw[16]; };

/* The whitelist: nothing that writes, formats, sanitizes or changes the drive. */
static void sqe_check(const struct sqe *e, int admin)
{
    uint8_t opc = (uint8_t)e->dw[0];
    int ok = admin ? (opc == 0x00 || opc == 0x01 || opc == 0x04 || opc == 0x05 || opc == 0x06 ||
                      (opc == 0x09 && (e->dw[10] & 0xff) == 0x07))
                   : opc == 0x02;
    if (!ok) {
        fprintf(stderr, "FATAL: refusing NVMe %s opcode 0x%02x: this tool only reads\n",
                admin ? "admin" : "I/O", opc);
        abort();
    }
}

static void wait_rdy(struct drive *d, int want)
{
    uint64_t t0 = now_ns(), lim = (d->to_ms ? d->to_ms : 5000) * 1000000ull;
    for (;;) {
        uint32_t s = rd32(d, 0x1c);
        if (s == 0xffffffff)
            die("%s: CSTS reads 0xffffffff (the drive or the switch stopped answering)", d->bdf);
        if (want && (s & 2))
            die("%s: controller fatal status (CSTS 0x%x)", d->bdf, s);
        if ((s & 1) == (uint32_t)want)
            return;
        if (now_ns() - t0 > lim)
            die("%s: CSTS.RDY did not become %d in %" PRIu64 " ms", d->bdf, want, d->to_ms);
        usleep(1000);
    }
}

static uint32_t admin(struct drive *d, struct sqe *e)
{
    sqe_check(e, 1);
    e->dw[0] = (e->dw[0] & 0xffff) | ((uint32_t)d->acid++ << 16);
    memcpy(d->asq + d->atail * 64, e, 64);
    d->atail = (d->atail + 1) % AQ_DEPTH;
    ring(d, NULL, db_off(d, 0, 0), d->atail);
    uint64_t t0 = now_ns();
    for (;;) {
        volatile uint32_t *c = (volatile uint32_t *)(d->acq + d->ahead * 16);
        uint32_t dw3 = c[3];
        if (((dw3 >> 16) & 1) == d->aphase) {
            uint32_t dw0 = c[0], st = (dw3 >> 17) & 0x7fff;
            d->ahead = (d->ahead + 1) % AQ_DEPTH;
            if (!d->ahead)
                d->aphase ^= 1;
            ring(d, NULL, db_off(d, 0, 1), d->ahead);
            if (st)
                die("%s: admin opcode 0x%02x failed: SCT %u SC 0x%02x", d->bdf, e->dw[0] & 0xff,
                    (st >> 8) & 7, st & 0xff);
            return dw0;
        }
        if (now_ns() - t0 > 10000000000ull)
            die("%s: admin opcode 0x%02x: no completion in 10 s", d->bdf, e->dw[0] & 0xff);
    }
}

static void trim_copy(char *dst, const uint8_t *src, size_t n)
{
    memcpy(dst, src, n);
    dst[n] = 0;
    for (size_t i = n; i > 0 && (dst[i - 1] == ' ' || !dst[i - 1]); i--)
        dst[i - 1] = 0;
}

static void nvme_init(struct drive *d)
{
    d->cap = rd64(d, 0x0);
    if (d->cap == ~0ull)
        die("%s: CAP reads all ones", d->bdf);
    d->mqes = (uint32_t)(d->cap & 0xffff) + 1;
    d->dstrd = (uint32_t)(d->cap >> 32) & 0xf;
    d->to_ms = ((d->cap >> 24) & 0xff) * 500;
    if ((d->cap >> 48) & 0xf)
        die("%s: MPSMIN above 4 KiB", d->bdf);
    if (d->bar && d->bar_size < db_off(d, MAXQ, 1) + 4)
        die("%s: BAR0 too small for %d queues' doorbells", d->bdf, MAXQ);
    uint32_t cc = rd32(d, 0x14);
    if (cc & 1)
        wr32(d, 0x14, cc & ~1u);          /* a controller reset: no data changes */
    wait_rdy(d, 0);
    d->asq = dma_alloc(d->ct, AQ_DEPTH * 64, &d->asq_io);
    d->acq = dma_alloc(d->ct, AQ_DEPTH * 16, &d->acq_io);
    d->idbuf = dma_alloc(d->ct, 4096, &d->idbuf_io);
    d->atail = d->ahead = 0;
    d->aphase = 1;
    wr32(d, 0x24, ((AQ_DEPTH - 1) << 16) | (AQ_DEPTH - 1));
    wr64(d, 0x28, d->asq_io);
    wr64(d, 0x30, d->acq_io);
    wr32(d, 0x14, (4u << 20) | (6u << 16) | 1u);   /* IOCQES 16 B, IOSQES 64 B, MPS 4 KiB, EN */
    wait_rdy(d, 1);

    struct sqe e;
    memset(&e, 0, sizeof(e));
    e.dw[0] = 0x06; e.dw[6] = (uint32_t)d->idbuf_io; e.dw[7] = (uint32_t)(d->idbuf_io >> 32); e.dw[10] = 1;
    admin(d, &e);
    trim_copy(d->serial, d->idbuf + 4, 20);
    trim_copy(d->model, d->idbuf + 24, 40);
    uint32_t rtd3e;                          /* resume/entry latency, us: the shutdown's limit */
    memcpy(&rtd3e, d->idbuf + 88, 4);
    d->shn_ms = rtd3e / 1000 < 5000 ? 5000 : rtd3e / 1000 > 30000 ? 30000 : rtd3e / 1000;
    uint8_t mdts = d->idbuf[77];
    d->maxxfer = mdts ? (4096ull << mdts) : (2u << 20);
    if (d->maxxfer > (2u << 20))
        d->maxxfer = 2u << 20;               /* one PRP list page */
    if (d->want_serial[0] && strcmp(d->want_serial, d->serial))
        die("%s: serial is '%s', not '%s' (--serial): wrong drive?", d->bdf, d->serial, d->want_serial);

    memset(&e, 0, sizeof(e));
    e.dw[0] = 0x06; e.dw[1] = d->nsid; e.dw[6] = (uint32_t)d->idbuf_io; e.dw[7] = (uint32_t)(d->idbuf_io >> 32);
    admin(d, &e);
    memcpy(&d->nsze, d->idbuf, 8);
    uint8_t flbas = d->idbuf[26];
    uint32_t lbaf;
    memcpy(&lbaf, d->idbuf + 128 + 4 * (flbas & 0xf), 4);
    if (!d->nsze)
        die("%s: namespace %u is not active", d->bdf, d->nsid);
    if ((lbaf & 0xffff) && (flbas & 0x10))
        die("%s: namespace %u has extended-LBA metadata (not supported)", d->bdf, d->nsid);
    d->lba = 1u << ((lbaf >> 16) & 0xff);
    if (d->lba > 4096)
        die("%s: LBA size %u above 4096", d->bdf, d->lba);

    memset(&e, 0, sizeof(e));
    e.dw[0] = 0x09; e.dw[10] = 0x07; e.dw[11] = ((uint32_t)(d->nq - 1) << 16) | (uint32_t)(d->nq - 1);
    uint32_t got = admin(d, &e);
    if ((int)(got & 0xffff) + 1 < d->nq || (int)(got >> 16) + 1 < d->nq)
        die("%s: the drive grants %u/%u I/O queues, %d asked", d->bdf, (got & 0xffff) + 1, (got >> 16) + 1, d->nq);
    printf("alias-nvme: %s %s (serial %s): ns %u %" PRIu64 " x %u B, MDTS %" PRIu64 " KiB, MQES %u, "
           "DSTRD %u, group %d\n", d->bdf, d->model, d->serial, d->nsid, d->nsze, d->lba,
           d->maxxfer >> 10, d->mqes, d->dstrd, d->group);
}

static void queues_create(struct drive *d)
{
    uint32_t need = g_qd * g_k + 1;
    if (need > d->mqes || g_qd * g_k > 65535)
        die("%s: --qd %u x %u command(s) per read needs %u queue entries, the drive has %u",
            d->bdf, g_qd, g_k, need, d->mqes);
    d->q = calloc((size_t)d->nq, sizeof(*d->q));
    if (!d->q)
        die("out of memory");
    for (int i = 0; i < d->nq; i++) {
        struct ioq *q = &d->q[i];
        q->d = d; q->idx = i; q->qid = i + 1; q->qs = need; q->phase = 1;
        q->sq = dma_alloc(d->ct, (uint64_t)q->qs * 64, &q->sq_io);
        q->cq = dma_alloc(d->ct, (uint64_t)q->qs * 16, &q->cq_io);
        if (g_cmd / ALIAS_PAGE > 2)
            q->prp_va = dma_alloc(d->ct, (uint64_t)g_qd * g_k * ALIAS_PAGE, &q->prp_io);
        q->t0 = calloc(g_qd, sizeof(*q->t0));
        q->left = calloc(g_qd, sizeof(*q->left));
        if (!q->t0 || !q->left)
            die("out of memory");
        if (d->bar) {
            q->sqdb = (volatile uint32_t *)(d->bar + db_off(d, q->qid, 0));
            q->cqdb = (volatile uint32_t *)(d->bar + db_off(d, q->qid, 1));
        }
        struct sqe e;
        memset(&e, 0, sizeof(e));
        e.dw[0] = 0x05; e.dw[6] = (uint32_t)q->cq_io; e.dw[7] = (uint32_t)(q->cq_io >> 32);
        e.dw[10] = ((q->qs - 1) << 16) | (uint32_t)q->qid; e.dw[11] = 1;          /* PC, no interrupts */
        admin(d, &e);
        memset(&e, 0, sizeof(e));
        e.dw[0] = 0x01; e.dw[6] = (uint32_t)q->sq_io; e.dw[7] = (uint32_t)(q->sq_io >> 32);
        e.dw[10] = ((q->qs - 1) << 16) | (uint32_t)q->qid; e.dw[11] = ((uint32_t)q->qid << 16) | 1;
        admin(d, &e);
    }
}

static void nvme_teardown(struct drive *d)
{
    struct sqe e;
    for (int i = 0; d->q && i < d->nq; i++) {
        memset(&e, 0, sizeof(e)); e.dw[0] = 0x00; e.dw[10] = (uint32_t)d->q[i].qid; admin(d, &e);
        memset(&e, 0, sizeof(e)); e.dw[0] = 0x04; e.dw[10] = (uint32_t)d->q[i].qid; admin(d, &e);
    }
    /* A normal shutdown (CC.SHN = 01, wait for CSTS.SHST = 10), as the nvme
     * driver does before it lets go of a drive, then CC.EN=0. The drive's
     * FLR at release froze bigserver after an abrupt CC.EN=0 (11-05); after
     * the nvme driver's shutdown it never did. No user data changes. */
    uint64_t t0 = now_ns();
    wr32(d, 0x14, (rd32(d, 0x14) & ~(3u << 14)) | (1u << 14));
    for (;;) {
        uint32_t s = rd32(d, 0x1c);
        if (s == 0xffffffff)
            die("%s: CSTS reads 0xffffffff during shutdown", d->bdf);
        if (((s >> 2) & 3) == 2) {
            printf("alias-nvme: %s: shutdown complete in %.0f ms\n", d->bdf, (double)(now_ns() - t0) / 1e6);
            break;
        }
        if (now_ns() - t0 > d->shn_ms * 1000000ull) {
            printf("alias-nvme: %s: WARNING: shutdown not complete after %" PRIu64 " ms (CSTS 0x%x)\n",
                   d->bdf, d->shn_ms, s);
            break;
        }
        usleep(1000);
    }
    wr32(d, 0x14, rd32(d, 0x14) & ~1u);
    wait_rdy(d, 0);
}

/* The region: the pattern's span at data_iova, repeating the backing. Chunks
 * of the backing's size when that is few mappings, else the pattern's pages. */
static void map_data(struct drive *d, const struct alias_backing *b)
{
    uint64_t span = g_pat.span, chunks = (span + b->pages - 1) / b->pages;
    int same = 0;
    for (int i = 0; i < d->idx; i++)
        if (g_dev[i].ct == d->ct && g_dev[i].data_iova == d->data_iova)
            same = 1;
    if (same)
        return;                           /* the other drive mapped it in this domain */
    if (chunks <= ALIAS_MAX_CHUNKS / MAXDEV) {
        for (uint64_t c = 0; c < chunks; c++) {
            uint64_t n = span - c * b->pages < b->pages ? span - c * b->pages : b->pages;
            dma_map(d->ct, b->va, d->data_iova + c * b->pages * ALIAS_PAGE, n * ALIAS_PAGE);
        }
        printf("alias-nvme: %s: region IOVA 0x%" PRIx64 "-0x%" PRIx64 " in %" PRIu64 " mapping(s) of %"
               PRIu64 " backing pages\n", d->bdf, d->data_iova, d->data_iova + span * ALIAS_PAGE, chunks, b->pages);
        return;
    }
    uint64_t *pg = malloc(g_pat.ws * sizeof(*pg)), n = 0;
    if (!pg)
        die("out of memory");
    memcpy(pg, g_pat.page, g_pat.ws * sizeof(*pg));
    for (uint64_t i = 1; i < g_pat.ws; i++)            /* insertion sort is fine at these sizes */
        for (uint64_t j = i; j > 0 && pg[j - 1] > pg[j]; j--) {
            uint64_t t = pg[j]; pg[j] = pg[j - 1]; pg[j - 1] = t;
        }
    for (uint64_t i = 0; i < g_pat.ws; i++)
        if (!i || pg[i] != pg[i - 1])
            pg[n++] = pg[i];
    if (n > ALIAS_MAX_CHUNKS / MAXDEV)
        die("%" PRIu64 " distinct pages over a span of %" PRIu64 ": too many VFIO mappings; "
            "raise --backing-pages or shrink the pattern", n, span);
    for (uint64_t i = 0; i < n; i++)
        dma_map(d->ct, b->va + (pg[i] % b->pages) * ALIAS_PAGE, d->data_iova + pg[i] * ALIAS_PAGE, ALIAS_PAGE);
    printf("alias-nvme: %s: %" PRIu64 " pattern pages mapped one by one at IOVA base 0x%" PRIx64 "\n",
           d->bdf, n, d->data_iova);
    free(pg);
}

/* ------------------------------------------------------------ I/O */
static void io_submit(struct ioq *q, uint32_t io)
{
    struct drive *d = q->d;
    uint64_t bpio = g_bs / d->lba, bpcmd = g_cmd / d->lba, slba;
    if (g_lba_rand) {
        slba = (xorshift(&q->rng) % (d->nsze / bpio)) * bpio;
    } else {
        slba = q->seqlba;
        q->seqlba += bpio;
        if (q->seqlba + bpio > d->nsze)
            q->seqlba = 0;
    }
    uint32_t np = (uint32_t)(g_cmd / ALIAS_PAGE);
    for (uint32_t s = 0; s < g_k; s++) {
        uint32_t cid = io * g_k + s;
        struct sqe e;
        memset(&e, 0, sizeof(e));
        e.dw[0] = 0x02 | (cid << 16);
        e.dw[1] = d->nsid;
        uint64_t p0 = d->data_iova + pattern_next(&g_pat, &q->cur) * ALIAS_PAGE, p1 = 0;
        if (np == 2) {
            p1 = d->data_iova + pattern_next(&g_pat, &q->cur) * ALIAS_PAGE;
        } else if (np > 2) {
            uint64_t *l = q->prp_va + (uint64_t)cid * (ALIAS_PAGE / 8);
            for (uint32_t j = 1; j < np; j++)
                l[j - 1] = d->data_iova + pattern_next(&g_pat, &q->cur) * ALIAS_PAGE;
            p1 = q->prp_io + (uint64_t)cid * ALIAS_PAGE;
        }
        e.dw[6] = (uint32_t)p0; e.dw[7] = (uint32_t)(p0 >> 32);
        e.dw[8] = (uint32_t)p1; e.dw[9] = (uint32_t)(p1 >> 32);
        uint64_t lba = slba + s * bpcmd;
        e.dw[10] = (uint32_t)lba; e.dw[11] = (uint32_t)(lba >> 32);
        e.dw[12] = (uint32_t)(bpcmd - 1);
        sqe_check(&e, 0);
        memcpy(q->sq + (uint64_t)q->sqt * 64, &e, 64);
        q->sqt = (q->sqt + 1) % q->qs;
    }
    q->left[io] = (uint16_t)g_k;
    q->t0[io] = now_ns();
    q->inflight++;
}

static void *io_thread(void *arg)
{
    struct ioq *q = arg;
    struct drive *d = q->d;
    pin_cpu(q->cpu);
    cursor_init(&g_pat, &q->cur, (uint64_t)q->idx, (uint64_t)d->nq);
    q->cur.rng ^= (uint64_t)(d->idx + 1) * 0x94D049BB133111EBull;
    q->rng = (uint64_t)(d->idx + 1) * 0x9E3779B97F4A7C15ull ^ (uint64_t)(q->idx + 1) * 0xBF58476D1CE4E5B9ull;
    q->seqlba = (d->nsze / (uint64_t)d->nq) * (uint64_t)q->idx / (g_bs / d->lba) * (g_bs / d->lba);
    for (uint32_t i = 0; i < g_qd; i++)
        io_submit(q, i);
    ring(d, q->sqdb, db_off(d, q->qid, 0), q->sqt);
    q->live = 1;
    uint64_t drain_until = 0;
    for (;;) {
        int got = 0, sub = 0;
        for (;;) {
            volatile uint32_t *c = (volatile uint32_t *)(q->cq + (uint64_t)q->cqh * 16);
            uint32_t dw3 = c[3];
            if (((dw3 >> 16) & 1) != q->phase)
                break;
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            uint32_t cid = dw3 & 0xffff, st = (dw3 >> 17) & 0x7fff, io = cid / g_k;
            if (st && !q->err) {
                fprintf(stderr, "ERROR: %s queue %d: read failed, SCT %u SC 0x%02x (cid %u)\n",
                        d->bdf, q->qid, (st >> 8) & 7, st & 0xff, cid);
                q->err = 1;
            }
            if (io < g_qd && q->left[io] && --q->left[io] == 0) {
                q->inflight--;
                if (!st)
                    stats_add(&q->st, g_bs, now_ns() - q->t0[io], g_measure);
                if (!g_stopping && !q->err) {
                    io_submit(q, io);
                    sub = 1;
                }
            }
            if (++q->cqh == q->qs) {
                q->cqh = 0;
                q->phase ^= 1;
            }
            got++;
        }
        if (got)
            ring(d, q->cqdb, db_off(d, q->qid, 1), q->cqh);
        if (sub)
            ring(d, q->sqdb, db_off(d, q->qid, 0), q->sqt);
        if (g_stopping || q->err) {
            uint64_t t = now_ns();
            if (!drain_until)
                drain_until = t + 5000000000ull;
            if (!q->inflight || t > drain_until)
                break;
        }
    }
    if (q->inflight)
        fprintf(stderr, "WARNING: %s queue %d: %" PRIu64 " read(s) still in flight after 5 s\n",
                d->bdf, q->qid, q->inflight);
    return NULL;
}

/* ------------------------------------------------------------ main */
static void touch(const char *path)
{
    FILE *f = path ? fopen(path, "w") : NULL;
    if (f) {
        fprintf(f, "%d\n", (int)getpid());
        fclose(f);
    }
}

static int cpu_of(const char *list, int k)
{
    int cpus[256], n = 0;
    char buf[512];
    snprintf(buf, sizeof(buf), "%s", list);
    for (char *t = strtok(buf, ","); t && n < 256; t = strtok(NULL, ","))
        cpus[n++] = atoi(t);
    return n ? cpus[k % n] : -1;
}

/* --exit-steps: what exit() does at once, one step at a time, each announced
 * 1 s before it starts (stdout is line-buffered; the hang test timestamps and
 * syncs each line, which takes ms: an action right after its line could freeze
 * the host before the line is on disk, as on 11-05 20:21). */
static void step_pause(double s)
{
    struct timespec ts = { (time_t)s, (long)((s - (double)(time_t)s) * 1e9) };
    while (nanosleep(&ts, &ts) && errno == EINTR)
        ;
}

static void step_say(const char *what, const char *bdf)
{
    char path[160], st[32] = "?";
    if (bdf) {
        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/power_state", bdf);
        FILE *f = fopen(path, "r");
        if (f) {
            if (fgets(st, sizeof(st), f))
                st[strcspn(st, "\n")] = 0;
            fclose(f);
        }
        printf("alias-nvme: exit step: %s %s (power_state %s)\n", what, bdf, st);
    } else
        printf("alias-nvme: exit step: %s\n", what);
}

/* ------------------------------------------------------------ hold mode */
static const char *g_hold;
static volatile int g_dead;

/* DIR/name, written whole (tmp, fsync, rename): readers never see half a file */
static void hold_write(const char *name, const char *text)
{
    char path[700], tmp[720];
    snprintf(path, sizeof(path), "%s/%s", g_hold, name);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f)
        return;
    fputs(text, f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    rename(tmp, path);
}

static void hold_alive(void)
{
    if (!g_hold || g_dead)
        return;
    char b[160];
    snprintf(b, sizeof(b), "%" PRIu64 " %d %s\n", epoch_ms(), (int)getpid(), g_measure ? "load" : "idle");
    hold_write("alive", b);
}

/* die() and any other exit() with drives still open: the open path's reset
 * first, then close, so the kernel's release never runs the bare FLR. */
static volatile int g_released;
static void release_on_exit(void)
{
    if (g_hold && !g_released) {
        /* Never release in hold mode: hold the drives and go quiet, so the
         * heartbeat goes stale and the watchdog resets the host. */
        g_dead = 1;
        hold_write("state", "dead: a fatal error; drives held, not released; reboot to end\n");
        fprintf(stderr, "alias-nvme: hold: fatal error: NOT releasing the drives (a release resets b4, "
                        "which froze bigserver); reboot to end\n");
        for (;;)
            pause();
    }
    if (g_released || !g_exit_reset)
        return;
    g_released = 1;
    g_stopping = 1;
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        if (d->dfd <= 0)
            continue;
        fprintf(stderr, "alias-nvme: exit with %s open: VFIO_DEVICE_RESET, then close\n", d->bdf);
        if (ioctl(d->dfd, VFIO_DEVICE_RESET))
            fprintf(stderr, "alias-nvme: %s: VFIO_DEVICE_RESET: %s\n", d->bdf, strerror(errno));
        step_pause(0.5);
        close(d->dfd);
        d->dfd = -1;
    }
}

static double g_exit_settle = 10;
static int g_exit_d3;

/* PMCSR power state (0 = D0, 3 = D3hot) through VFIO's config region, which
 * hands it to the kernel (vfio_pci_set_power_state: the delays included). */
static void pm_set(struct drive *d, int state)
{
    struct vfio_region_info ci = { .argsz = sizeof(ci), .index = VFIO_PCI_CONFIG_REGION_INDEX };
    uint8_t pos = 0, id = 0;
    uint16_t st = 0, csr = 0;
    if (ioctl(d->dfd, VFIO_DEVICE_GET_REGION_INFO, &ci) ||
        pread(d->dfd, &st, 2, (off_t)(ci.offset + 6)) != 2 || !(st & 0x10) ||
        pread(d->dfd, &pos, 1, (off_t)(ci.offset + 0x34)) != 1) {
        printf("alias-nvme: exit step: %s: no capability list\n", d->bdf);
        return;
    }
    for (int n = 0; pos >= 0x40 && n < 48; n++) {
        if (pread(d->dfd, &id, 1, (off_t)(ci.offset + pos)) != 1)
            break;
        if (id == 0x01)
            break;
        if (pread(d->dfd, &pos, 1, (off_t)(ci.offset + pos + 1)) != 1)
            break;
    }
    if (id != 0x01 || pread(d->dfd, &csr, 2, (off_t)(ci.offset + pos + 4)) != 2) {
        printf("alias-nvme: exit step: %s: no PM capability\n", d->bdf);
        return;
    }
    csr = (uint16_t)((csr & ~3u) | (unsigned)state);
    if (pwrite(d->dfd, &csr, 2, (off_t)(ci.offset + pos + 4)) != 2)
        printf("alias-nvme: exit step: %s: PMCSR write: %s\n", d->bdf, strerror(errno));
    step_pause(0.05);
}
static void exit_steps(double pause)
{
    step_say("drives shut down; settling before the resets ...", NULL);
    step_pause(g_exit_settle);
    if (g_exit_rev && g_ndev == 2) {                 /* --exit-reverse: last drive first */
        struct drive t = g_dev[0];
        g_dev[0] = g_dev[1];
        g_dev[1] = t;
        printf("alias-nvme: exit step: releasing in reverse order (%s first)\n", g_dev[0].bdf);
    }
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        struct vfio_region_info ci = { .argsz = sizeof(ci), .index = VFIO_PCI_CONFIG_REGION_INDEX };
        uint16_t cmd = 0;
        step_pause(pause);
        step_say("bus master off (config write) ...", d->bdf);
        step_pause(1.0);
        if (!ioctl(d->dfd, VFIO_DEVICE_GET_REGION_INFO, &ci) && pread(d->dfd, &cmd, 2, (off_t)(ci.offset + 4)) == 2) {
            cmd &= (uint16_t)~0x0004;
            if (pwrite(d->dfd, &cmd, 2, (off_t)(ci.offset + 4)) != 2)
                printf("alias-nvme: exit step: %s: config write failed: %s\n", d->bdf, strerror(errno));
        }
        step_say("bus master off done", d->bdf);
        if (g_exit_d3) {
            /* At open the drive comes out of D3hot (vfio-pci's idle state)
             * right before its FLR, and b4's resets there never froze; at
             * exit it has been in D0 all along. Same here: D3hot, then D0. */
            step_pause(pause);
            step_say("D3hot via PMCSR (config write) ...", d->bdf);
            step_pause(1.0);
            pm_set(d, 3);
            step_say("in D3hot", d->bdf);
            step_pause(pause);
            step_say("D0 via PMCSR ...", d->bdf);
            step_pause(1.0);
            pm_set(d, 0);
            step_say("back in D0", d->bdf);
        }
        if (g_exit_reset) {
            /* The open path's reset (pci_try_reset_function: save, command
             * register cleared, FLR, restore), which works on both drives,
             * before the release path's (FLR on an enabled device, then the
             * config restore at once when the drive claims Immediate
             * Readiness: b4, where the host froze on 11-05). */
            step_pause(pause);
            step_say("VFIO_DEVICE_RESET (FLR the way open does it) ...", d->bdf);
            step_pause(1.0);
            if (ioctl(d->dfd, VFIO_DEVICE_RESET))
                printf("alias-nvme: exit step: %s: VFIO_DEVICE_RESET: %s\n", d->bdf, strerror(errno));
            step_say("VFIO_DEVICE_RESET done", d->bdf);
        }
        step_pause(pause);
        if (d->bar) {
            munmap((void *)d->bar, d->bar_size);
            d->bar = NULL;
        }
        step_say("BAR0 unmapped; closing the device fd (vfio-pci release: FLR, config restore, D3hot) ...", d->bdf);
        step_pause(1.0);
        close(d->dfd);
        d->dfd = -1;
        step_say("device fd closed", d->bdf);
    }
    for (int c = 0; c < g_nctr; c++) {
        step_pause(pause);
        for (int i = 0; i < g_ndev; i++) {
            struct drive *d = &g_dev[i];
            if (d->ct != &g_ctr[c] || d->gfd < 0)
                continue;
            step_say("group detach (IOMMU domain detach, unmap and unpin all) ...", d->bdf);
            step_pause(1.0);
            if (ioctl(d->gfd, VFIO_GROUP_UNSET_CONTAINER))
                printf("alias-nvme: exit step: VFIO_GROUP_UNSET_CONTAINER: %s\n", strerror(errno));
            close(d->gfd);
            for (int j = i + 1; j < g_ndev; j++)      /* a shared group closes once */
                if (g_dev[j].gfd == d->gfd)
                    g_dev[j].gfd = -1;
            d->gfd = -1;
            step_say("group detached and closed", d->bdf);
        }
        close(g_ctr[c].fd);
        step_say("container closed", NULL);
    }
    step_pause(pause);
    step_say("all released; exiting", NULL);
}

/* ------------------------------------------------------------ one load */
static struct alias_backing g_bk;
static int g_hb = 5;

/* The drives in mask (bit i = --dev i): fresh outputs at prefix[i]-<queue>, a
 * warm-up, secs measured (0: until a stop signal), every queue drained. The
 * queues, the controller and the region stay as they are. */
static int run_load(unsigned mask, char prefix[][512], double warm, double secs, const char *ready,
                    void (*each_second)(void))
{
    g_measure = 0;
    g_stopping = 0;
    for (int i = 0; i < g_ndev; i++) {
        if (!(mask >> i & 1))
            continue;
        for (int k = 0; k < g_dev[i].nq; k++) {
            struct ioq *q = &g_dev[i].q[k];
            char pre[600], name[64];
            if (q->inflight)
                fprintf(stderr, "WARNING: %s queue %d: %" PRIu64 " read(s) of the last load never completed\n",
                        g_dev[i].bdf, q->qid, q->inflight);
            memset(&q->st, 0, sizeof(q->st));
            memset(q->left, 0, g_qd * sizeof(*q->left));
            q->err = 0;
            q->live = 0;
            q->inflight = 0;
            snprintf(pre, sizeof(pre), "%s-%d", prefix[i], k);
            snprintf(name, sizeof(name), "alias_%d_%d", i, k);
            out_open(&q->out, pre, name);
            q->cpu = g_dev[i].cpus[0] ? cpu_of(g_dev[i].cpus, k) : -1;
            if (pthread_create(&q->th, NULL, io_thread, q))
                die("pthread_create");
        }
    }
    uint64_t t0 = now_ns();
    for (int i = 0; i < g_ndev; i++)
        for (int k = 0; (mask >> i & 1) && k < g_dev[i].nq; k++)
            while (!g_dev[i].q[k].live) {
                if (now_ns() - t0 > 10000000000ull)
                    die("queue threads did not start in 10 s");
                usleep(1000);
            }
    touch(ready);
    printf("alias-nvme: READY, every queue loaded\n");

    int err = 0;
    uint64_t t_start = now_ns(), next_hb = (uint64_t)g_hb;
    for (uint64_t el = 1;; el++) {
        sleep_until(t_start + el * 1000000000ull);
        if (!g_measure && (double)(now_ns() - t_start) / 1e9 >= warm) {
            for (int i = 0; i < g_ndev; i++)
                for (int k = 0; (mask >> i & 1) && k < g_dev[i].nq; k++)
                    out_start(&g_dev[i].q[k].out, &g_dev[i].q[k].st);
            g_measure = 1;
        }
        double sum[MAXDEV] = { 0 };
        for (int i = 0; i < g_ndev; i++)
            for (int k = 0; (mask >> i & 1) && k < g_dev[i].nq; k++) {
                sum[i] += out_sample(&g_dev[i].q[k].out, &g_dev[i].q[k].st, g_bs);
                err |= g_dev[i].q[k].err;
            }
        if (each_second)
            each_second();
        if (el >= next_hb) {
            printf("alias-nvme: t=%" PRIu64 "s %s", el, g_measure ? "measuring" : "warming");
            for (int i = 0; i < g_ndev; i++)
                if (mask >> i & 1)
                    printf(" | %s %.1f kIOPS %.2f GB/s", g_dev[i].bdf, sum[i] / 1e3, sum[i] * (double)g_bs / 1e9);
            printf("\n");
            next_hb += (uint64_t)g_hb;
        }
        if (g_stop || err || (secs > 0 && (double)(now_ns() - t_start) / 1e9 >= warm + secs))
            break;
    }
    g_stopping = 1;
    for (int i = 0; i < g_ndev; i++)
        for (int k = 0; (mask >> i & 1) && k < g_dev[i].nq; k++) {
            pthread_join(g_dev[i].q[k].th, NULL);
            err |= g_dev[i].q[k].err;
        }
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        if (!(mask >> i & 1))
            continue;
        double iops = 0, lat = 0, n = 0;
        for (int k = 0; k < d->nq; k++) {
            struct ioq *q = &d->q[k];
            char extra[1200];
            snprintf(extra, sizeof(extra),
                     "\"tool\": \"alias-nvme\", \"bdf\": \"%s\", \"serial\": \"%s\", \"model\": \"%s\", "
                     "\"queue\": %d, \"cpu\": %d, \"qd\": %u, \"bs\": %" PRIu64 ", \"cmd_bytes\": %" PRIu64
                     ", \"lba\": \"%s\", \"ws\": %" PRIu64 ", \"stride\": %" PRIu64 ", \"first\": %" PRIu64
                     ", \"order\": \"%s\", \"span_pages\": %" PRIu64 ", \"backing_pages\": %" PRIu64
                     ", \"iova_base\": \"0x%" PRIx64 "\", \"group\": %d, \"page_list\": \"%s\", \"hold\": %d",
                     d->bdf, d->serial, d->model, q->qid, q->cpu, g_qd, g_bs, g_cmd,
                     g_lba_rand ? "rand" : "seq", g_pat.ws, g_pat.stride, g_pat.first,
                     order_name(g_pat.order), g_pat.span, g_bk.pages, d->data_iova, d->group,
                     g_pat.list_path ? g_pat.list_path : "", g_hold ? 1 : 0);
            out_close(&q->out, &q->st, extra, q->err);
            double sec = q->out.started ? (double)(now_ns() - q->out.start_ns) / 1e9 : 0;
            iops += sec ? (double)(q->st.ios - q->out.ios0) / sec : 0;
            lat += (double)q->st.lat_sum_ns;
            n += (double)q->st.lat_n;
        }
        printf("alias-nvme: %s done: %.1f kIOPS, %.2f GB/s, mean %.1f us%s\n", d->bdf, iops / 1e3,
               iops * (double)g_bs / 1e9, n ? lat / n / 1e3 : 0, err ? " (FAILED)" : "");
    }
    g_stopping = 0;
    g_measure = 0;
    return err;
}

/* A new pattern between loads: unmap the region in every domain, a new
 * backing, map the new region. The device is not touched. */
static void pattern_switch(uint64_t ws, uint64_t stride, const char *order)
{
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        int dup = 0;
        for (int j = 0; j < i; j++)
            if (g_dev[j].ct == d->ct && g_dev[j].data_iova == d->data_iova)
                dup = 1;
        if (dup)
            continue;
        struct vfio_iommu_type1_dma_unmap u;
        memset(&u, 0, sizeof(u));
        u.argsz = sizeof(u);
        u.iova = d->data_iova;
        u.size = g_pat.span * ALIAS_PAGE;
        if (ioctl(d->ct->fd, VFIO_IOMMU_UNMAP_DMA, &u))
            die("%s: VFIO unmap of the region: %s", d->bdf, strerror(errno));
    }
    munmap(g_bk.va, g_bk.pages * ALIAS_PAGE);
    close(g_bk.fd);
    free(g_pat.page);
    g_pat.page = NULL;
    g_pat.list_path = NULL;
    g_pat.ws = ws;
    g_pat.stride = stride;
    g_pat.order = parse_order(order);
    pattern_build(&g_pat);
    pattern_print(&g_pat, stdout, "alias-nvme");
    backing_create(&g_bk, g_backing ? g_backing : backing_default(g_pat.span));
    for (int i = 0; i < g_ndev; i++) {
        if (g_dev[i].data_iova != g_iova_base && g_pat.span * ALIAS_PAGE > (1ull << 40))
            die("two drives in one IOMMU group need spans under 1 TiB");
        map_data(&g_dev[i], &g_bk);
    }
}

static void hold_loop(void)
{
    char b[300];
    snprintf(b, sizeof(b), "ready %d\n", (int)getpid());
    hold_write("state", b);
    printf("alias-nvme: HOLD %s: drives open, waiting for commands in %s/cmd; SIGINT/SIGTERM stop a load, "
           "never the holder; end with: sync; systemctl reboot -ff\n", g_hold, g_hold);
    for (unsigned n = 1;;) {
        hold_alive();
        g_stop = 0;
        char path[700], line[1200];
        snprintf(path, sizeof(path), "%s/cmd", g_hold);
        FILE *f = fopen(path, "r");
        if (!f) {
            step_pause(0.25);
            continue;
        }
        if (!fgets(line, sizeof(line), f))
            line[0] = 0;
        fclose(f);
        char taken[720];
        snprintf(taken, sizeof(taken), "%s/cmd.%u", g_hold, n);
        rename(path, taken);
        char name[128], ord[32], outdir[600];
        unsigned mask = 0;
        unsigned long long ws = 0, stride = 0;
        double warm = 0, secs = 0;
        if (sscanf(line, "load %127s %u %llu %llu %31s %lf %lf %599s", name, &mask, &ws, &stride, ord,
                   &warm, &secs, outdir) != 8 || !(mask & ((1u << g_ndev) - 1)) || !ws || !stride || secs <= 0) {
            line[strcspn(line, "\n")] = 0;
            printf("alias-nvme: hold: command %u not understood: '%s'\n", n, line);
            snprintf(b, sizeof(b), "%u bad-command\n", n);
        } else {
            printf("alias-nvme: hold: load %u '%s': drives 0x%x, ws %llu stride %llu %s, warm %.0f s, %.0f s, into %s\n",
                   n, name, mask, ws, stride, ord, warm, secs, outdir);
            if (ws != g_pat.ws || stride != g_pat.stride || parse_order(ord) != g_pat.order)
                pattern_switch(ws, stride, ord);
            char pre[MAXDEV][512];
            for (int i = 0; i < g_ndev; i++)
                snprintf(pre[i], sizeof(pre[i]), "%s/fio-ssd%d", outdir, i);
            int err = run_load(mask & ((1u << g_ndev) - 1), pre, warm, secs, NULL, hold_alive);
            snprintf(b, sizeof(b), "%u %s %s\n", n, name, err ? "FAILED" : "ok");
            printf("alias-nvme: hold: load %u '%s' %s; idle, drives held\n", n, name, err ? "FAILED" : "done");
        }
        char dn[32];
        snprintf(dn, sizeof(dn), "done.%u", n);
        hold_write(dn, b);
        hold_write("done", b);
        n++;
    }
}

static void usage(void)
{
    puts("sudo alias-nvme --dev BDF=PREFIX [--dev BDF=PREFIX] [--serial S[,S]] [--queues N[,N]]\n"
         "     [--cpus L[/L]] [--qd N] [--bs B] [--lba rand|seq] [--nsid N]\n"
         "     [--ws N] [--stride N] [--first N] [--order cyclic|shuffle|random] [--seed N]\n"
         "     [--page-list PATH] [--backing-pages N] [--iova-base A]\n"
         "     [--warm S] [--seconds S] [--heartbeat S] [--ready-file PATH] [--exit-steps S] [--exit-settle S] [--exit-d3] [--exit-reverse] [--exit-unsafe]\n"
         "     [--hold DIR]\n"
         "(the comment at the top of alias-nvme.c says what each does)");
}

int main(int argc, char **argv)
{
    const char *queues = "4", *cpus = "", *serials = "", *ready = NULL;
    double warm = 0, secs = 0, exit_pause = 1;
    int hb = 5;
    pattern_defaults(&g_pat);
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
#define ARG(s) (!strcmp(a, s) && v && ++i)
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
        else if (!strcmp(a, "--exit-reverse")) g_exit_rev = 1;
        else if (!strcmp(a, "--exit-reset")) g_exit_reset = 1;     /* the default now */
        else if (!strcmp(a, "--exit-unsafe")) g_exit_reset = 0;
        else if (ARG("--exit-settle")) g_exit_settle = atof(v);
        else if (!strcmp(a, "--exit-d3")) g_exit_d3 = 1;
        else if (ARG("--dev")) {
            if (g_ndev == MAXDEV)
                die("at most %d drives", MAXDEV);
            struct drive *d = &g_dev[g_ndev];
            const char *eq = strchr(v, '=');
            if (!eq || eq == v || !eq[1])
                die("--dev BDF=PREFIX, not '%s'", v);
            snprintf(d->bdf, sizeof(d->bdf), "%.*s", (int)(eq - v), v);
            snprintf(d->prefix, sizeof(d->prefix), "%s", eq + 1);
            d->idx = g_ndev++;
        }
        else if (ARG("--serial")) serials = v;
        else if (ARG("--queues")) queues = v;
        else if (ARG("--cpus")) cpus = v;
        else if (ARG("--qd")) g_qd = (uint32_t)parse_u64(a, v);
        else if (ARG("--bs")) g_bs = parse_u64(a, v);
        else if (ARG("--lba")) {
            if (!strcmp(v, "rand")) g_lba_rand = 1;
            else if (!strcmp(v, "seq")) g_lba_rand = 0;
            else die("--lba rand or seq");
        }
        else if (ARG("--nsid")) g_nsid = (uint32_t)parse_u64(a, v);
        else if (ARG("--ws")) g_pat.ws = parse_u64(a, v);
        else if (ARG("--stride")) g_pat.stride = parse_u64(a, v);
        else if (ARG("--first")) g_pat.first = parse_u64(a, v);
        else if (ARG("--order")) g_pat.order = parse_order(v);
        else if (ARG("--seed")) g_pat.seed = parse_u64(a, v);
        else if (ARG("--page-list")) g_pat.list_path = v;
        else if (ARG("--backing-pages")) g_backing = parse_u64(a, v);
        else if (ARG("--iova-base")) g_iova_base = parse_u64(a, v);
        else if (ARG("--warm")) warm = atof(v);
        else if (ARG("--seconds")) secs = atof(v);
        else if (ARG("--heartbeat")) hb = (int)parse_u64(a, v);
        else if (ARG("--ready-file")) ready = v;
        else if (ARG("--exit-steps")) exit_pause = atof(v);
        else if (ARG("--hold")) g_hold = v;
        else { usage(); die("unknown or incomplete option '%s'", a); }
#undef ARG
    }
    if (!g_ndev)
        die("--dev BDF=PREFIX is required");
    if (!g_qd || !g_bs || g_bs % ALIAS_PAGE)
        die("--qd at least 1, --bs a multiple of 4096");
    if (g_iova_base % (1ull << 30))
        die("--iova-base must be 1 GiB aligned");
    if (hb < 1) hb = 1;
    g_hb = hb;
    {   /* per-drive lists: "a,b" or "a/b" style */
        char qb[128], cb[1024], sb[256];
        snprintf(qb, sizeof(qb), "%s", queues);
        snprintf(cb, sizeof(cb), "%s", cpus);
        snprintf(sb, sizeof(sb), "%s", serials);
        char *qs[MAXDEV] = { 0 }, *cs[MAXDEV] = { 0 }, *ss[MAXDEV] = { 0 }, *sv;
        int n = 0;
        for (char *t = strtok_r(qb, ",", &sv); t && n < MAXDEV; t = strtok_r(NULL, ",", &sv)) qs[n++] = t;
        n = 0;
        for (char *t = strtok_r(cb, "/", &sv); t && n < MAXDEV; t = strtok_r(NULL, "/", &sv)) cs[n++] = t;
        n = 0;
        for (char *t = strtok_r(sb, ",", &sv); t && n < MAXDEV; t = strtok_r(NULL, ",", &sv)) ss[n++] = t;
        for (int i = 0; i < g_ndev; i++) {
            struct drive *d = &g_dev[i];
            d->nq = atoi(qs[i] ? qs[i] : qs[0]);
            if (d->nq < 1 || d->nq > MAXQ)
                die("--queues: 1 to %d per drive", MAXQ);
            snprintf(d->cpus, sizeof(d->cpus), "%s", cs[i] ? cs[i] : "");
            if (ss[i])
                snprintf(d->want_serial, sizeof(d->want_serial), "%s", ss[i]);
            d->nsid = g_nsid;
        }
    }
    stop_on_signals();
    if (g_hold) {                         /* a closed ssh session must not end the holder */
        signal(SIGHUP, SIG_IGN);
        signal(SIGQUIT, SIG_IGN);
    }
    pattern_build(&g_pat);
    pattern_print(&g_pat, stdout, "alias-nvme");
    backing_create(&g_bk, g_backing ? g_backing : backing_default(g_pat.span));

    atexit(release_on_exit);
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        vfio_open(d);
        nvme_init(d);
        if (g_bs % d->lba)
            die("--bs %" PRIu64 " is not a multiple of %s's LBA size %u", g_bs, d->bdf, d->lba);
    }
    /* one command per read when MDTS allows, else the largest power of two that divides bs */
    g_cmd = g_bs;
    for (int i = 0; i < g_ndev; i++)
        while (g_cmd > g_dev[i].maxxfer || g_bs % g_cmd)
            g_cmd /= 2;
    if (g_cmd < ALIAS_PAGE)
        die("cannot split --bs %" PRIu64 " into commands of whole pages", g_bs);
    g_k = (uint32_t)(g_bs / g_cmd);
    for (int i = 0; i < g_ndev; i++) {
        struct drive *d = &g_dev[i];
        /* separate domains reuse the same IOVAs; drives sharing one domain sit 1 TiB apart */
        d->data_iova = g_iova_base;
        for (int j = 0; j < i; j++)
            if (g_dev[j].ct == d->ct)
                d->data_iova = g_dev[j].data_iova + (1ull << 40);
        if (d->data_iova != g_iova_base && g_pat.span * ALIAS_PAGE > (1ull << 40))
            die("two drives in one IOMMU group need spans under 1 TiB");
        map_data(d, &g_bk);
        queues_create(d);
    }
    printf("alias-nvme: %d drive(s), bs %" PRIu64 " = %u command(s) of %" PRIu64 " KiB, qd %u, lba %s, "
           "backing %" PRIu64 " pages\n", g_ndev, g_bs, g_k, g_cmd >> 10, g_qd,
           g_lba_rand ? "rand" : "seq", g_bk.pages);

    if (g_hold)
        hold_loop();                      /* never returns */
    char pre[MAXDEV][512];
    for (int i = 0; i < g_ndev; i++)
        snprintf(pre[i], sizeof(pre[i]), "%s", g_dev[i].prefix);
    int err = run_load((1u << g_ndev) - 1, pre, warm, secs, ready, NULL);
    for (int i = 0; i < g_ndev; i++)
        nvme_teardown(&g_dev[i]);
    printf("alias-nvme: controllers disabled; rebind with alias-vfio.sh restore\n");
    if (g_exit_reset)
        exit_steps(exit_pause);
    g_released = 1;                       /* --exit-unsafe: the kernel closes at exit */
    return err ? 3 : 0;
}
