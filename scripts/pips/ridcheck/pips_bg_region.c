// SPDX-License-Identifier: GPL-2.0
/*
 * pips_bg_region: a contiguous IOVA region in a device's own DMA domain, for
 * the PIPS background read engine while the device stays on its kernel driver
 * (pips-campaign.sh --bg, the native half: drives on nvme, IOMMU strict).
 *
 *   insmod pips_bg_region.ko dev=0000:b3:00.0[,0000:b4:00.0] npages=65536 backing=4096 [token=T]
 *   cat /sys/kernel/debug/pips_bg_region/regions   # one line per device:
 *       "dev 0000:b3:00.0 base 0x... pages 65536 backing 4096 domain dma contig 1"
 *   rmmod pips_bg_region                            # unmaps (one IOTLB invalidation) and frees
 *
 * Per device: `backing` pages (a power of two), page j holding j in its first
 * 8 bytes, and a scatterlist of `npages` page-sized entries, entry k on
 * backing page k mod backing, mapped with ONE dma_map_sg(&dev->dev, ...,
 * DMA_TO_DEVICE) call: the IOMMU DMA layer puts a whole list in one IOVA
 * allocation, so region page k sits at base + k * 4 KiB and holds k mod
 * backing, which is what the engine's data check (BACKING = backing) expects.
 * The module checks that the mapped segments are contiguous and refuses to
 * load otherwise. Read-only for the device (DMA_TO_DEVICE: no write
 * permission in the IOMMU). The mapping is the device's driver's domain (the
 * group's default domain, shared with the switch port above the device: same
 * IOMMU group, assumption A1), so the engine's reads under the port's
 * requester ID translate here. Nothing else is touched: the device is not
 * written, its driver keeps running.
 */
#include <linux/debugfs.h>
#include <linux/dma-mapping.h>
#include <linux/iommu.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/string.h>

#define MAXDEV 2

static char *dev = "";
module_param(dev, charp, 0444);
MODULE_PARM_DESC(dev, "the device(s) whose DMA domain gets a region: DDDD:BB:DD.F[,DDDD:BB:DD.F]");
static unsigned int npages = 65536;
module_param(npages, uint, 0444);
MODULE_PARM_DESC(npages, "region pages per device (default 65536 = 256 MiB, at most 262144)");
static unsigned int backing = 4096;
module_param(backing, uint, 0444);
MODULE_PARM_DESC(backing, "distinct physical pages behind a region, a power of two (default 4096)");
static char *token = "";
module_param(token, charp, 0444);
MODULE_PARM_DESC(token, "a string put in every log line, to find them in dmesg");

struct region {
	struct pci_dev *pdev;
	struct page **pg;
	struct sg_table sgt;
	int sg_alloc, nents;
	dma_addr_t base;
	int contig;
};
static struct region g_r[MAXDEV];
static int g_n;
static struct dentry *g_dir;

static const char *dom_type(struct iommu_domain *d)
{
	if (!d)
		return "none";
	switch (d->type) {
	case IOMMU_DOMAIN_BLOCKED: return "blocked";
	case IOMMU_DOMAIN_IDENTITY: return "identity";
	case IOMMU_DOMAIN_UNMANAGED: return "unmanaged";
	case IOMMU_DOMAIN_DMA: return "dma";
#ifdef IOMMU_DOMAIN_DMA_FQ
	case IOMMU_DOMAIN_DMA_FQ: return "dma-fq";
#endif
	default: return "other";
	}
}

static int regions_show(struct seq_file *m, void *v)
{
	int i;

	for (i = 0; i < g_n; i++)
		seq_printf(m, "dev %s base 0x%llx pages %u backing %u domain %s contig %d\n", pci_name(g_r[i].pdev),
			   (unsigned long long)g_r[i].base, npages, backing,
			   dom_type(iommu_get_domain_for_dev(&g_r[i].pdev->dev)), g_r[i].contig);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(regions);

static void region_free(struct region *r)
{
	unsigned int j;

	if (r->nents > 0)
		dma_unmap_sg(&r->pdev->dev, r->sgt.sgl, npages, DMA_TO_DEVICE);
	r->nents = 0;
	if (r->sg_alloc)
		sg_free_table(&r->sgt);
	r->sg_alloc = 0;
	for (j = 0; r->pg && j < backing; j++)
		if (r->pg[j])
			__free_page(r->pg[j]);
	kvfree(r->pg);
	r->pg = NULL;
	if (r->pdev)
		pci_dev_put(r->pdev);
	r->pdev = NULL;
}

static void undo(void)
{
	int i;

	debugfs_remove_recursive(g_dir);
	g_dir = NULL;
	for (i = 0; i < MAXDEV; i++)
		region_free(&g_r[i]);
}

static int region_make(struct region *r, const char *bdf)
{
	unsigned int dom, bus, sl, fn, j, k;
	struct scatterlist *s;
	dma_addr_t want;
	int ret;

	if (sscanf(bdf, "%x:%x:%x.%x", &dom, &bus, &sl, &fn) != 4) {
		pr_err("pips_bg_region[%s]: '%s' is not DDDD:BB:DD.F\n", token, bdf);
		return -EINVAL;
	}
	r->pdev = pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(sl, fn));
	if (!r->pdev) {
		pr_err("pips_bg_region[%s]: no PCI function %s\n", token, bdf);
		return -ENODEV;
	}
	pr_info("pips_bg_region[%s]: %s driver %s group %d domain %s dma_mask 0x%llx\n", token, pci_name(r->pdev),
		r->pdev->dev.driver ? r->pdev->dev.driver->name : "none",
		r->pdev->dev.iommu_group ? iommu_group_id(r->pdev->dev.iommu_group) : -1,
		dom_type(iommu_get_domain_for_dev(&r->pdev->dev)), (unsigned long long)dma_get_mask(&r->pdev->dev));
	r->pg = kvcalloc(backing, sizeof(*r->pg), GFP_KERNEL);
	if (!r->pg)
		return -ENOMEM;
	for (j = 0; j < backing; j++) {
		u64 *p;

		r->pg[j] = alloc_page(GFP_KERNEL | __GFP_ZERO);
		if (!r->pg[j])
			return -ENOMEM;
		p = page_address(r->pg[j]);
		p[0] = j;
	}
	ret = sg_alloc_table(&r->sgt, npages, GFP_KERNEL);
	if (ret)
		return ret;
	r->sg_alloc = 1;
	for_each_sg(r->sgt.sgl, s, npages, k)
		sg_set_page(s, r->pg[k & (backing - 1)], PAGE_SIZE, 0);
	r->nents = dma_map_sg(&r->pdev->dev, r->sgt.sgl, npages, DMA_TO_DEVICE);
	if (r->nents <= 0) {
		pr_err("pips_bg_region[%s]: %s: dma_map_sg of %u pages failed\n", token, pci_name(r->pdev), npages);
		r->nents = 0;
		return -ENOMEM;
	}
	/* contiguous: every mapped segment starts where the one before ended */
	r->base = sg_dma_address(r->sgt.sgl);
	want = r->base;
	r->contig = 1;
	for_each_sg(r->sgt.sgl, s, r->nents, k) {
		if (sg_dma_address(s) != want) {
			r->contig = 0;
			break;
		}
		want += sg_dma_len(s);
	}
	if (want != r->base + (dma_addr_t)npages * PAGE_SIZE)
		r->contig = 0;
	if (!r->contig || (r->base & (PAGE_SIZE - 1))) {
		pr_err("pips_bg_region[%s]: %s: the mapping is not one contiguous page-aligned range (base 0x%llx, "
		       "%d segments, ends 0x%llx): no region\n", token, pci_name(r->pdev), (unsigned long long)r->base,
		       r->nents, (unsigned long long)want);
		return -EINVAL;
	}
	pr_info("pips_bg_region[%s]: %s: %u pages at IOVA 0x%llx-0x%llx (%d segments), backing %u pages, "
		"page k holds k mod %u\n", token, pci_name(r->pdev), npages, (unsigned long long)r->base,
		(unsigned long long)want, r->nents, backing, backing);
	return 0;
}

static int __init pbr_init(void)
{
	char buf[128], *p, *t;
	int ret;

	if (npages == 0 || npages > 262144 || backing == 0 || backing > 65536 || (backing & (backing - 1)) ||
	    backing > npages) {
		pr_err("pips_bg_region[%s]: npages 1..262144 and backing a power of two up to 65536 and npages\n", token);
		return -EINVAL;
	}
	strscpy(buf, dev, sizeof(buf));
	p = buf;
	while ((t = strsep(&p, ",")) != NULL) {
		if (!*t)
			continue;
		if (g_n == MAXDEV) {
			pr_err("pips_bg_region[%s]: at most %d devices\n", token, MAXDEV);
			undo();
			return -EINVAL;
		}
		ret = region_make(&g_r[g_n++], t);
		if (ret) {
			undo();
			return ret;
		}
	}
	if (!g_n) {
		pr_err("pips_bg_region[%s]: dev=DDDD:BB:DD.F[,DDDD:BB:DD.F] needed\n", token);
		return -EINVAL;
	}
	g_dir = debugfs_create_dir("pips_bg_region", NULL);
	debugfs_create_file("regions", 0400, g_dir, NULL, &regions_fops);
	return 0;
}

static void __exit pbr_exit(void)
{
	pr_info("pips_bg_region[%s]: unmapping %d region(s)\n", token, g_n);
	undo();
}

module_init(pbr_init);
module_exit(pbr_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("PIPS background read engine: a contiguous IOVA region in a device's own DMA domain");
