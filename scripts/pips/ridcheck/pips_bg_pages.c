// SPDX-License-Identifier: GPL-2.0
/*
 * pips_bg_pages: pages for the PIPS background read engine under fallback F3
 * (docs/PIPS-0A08-ASSUMPTION-TEST.md §5.3, test T11): when a switch port's
 * requester ID is NOT translated in the device's domain, give the port its
 * own pages in the port's own DMA domain.
 *
 *   insmod pips_bg_pages.ko dev=0000:b2:00.0 npages=4096 [token=T]
 *   cat /sys/kernel/debug/pips_bg_pages/iovas   # "base 0x...", then "index iova" lines
 *   rmmod pips_bg_pages                          # unmaps and frees
 *
 * Allocates npages pages, maps each with dma_map_page(&port->dev, ...,
 * DMA_TO_DEVICE) (the engine only reads them), then writes into each page's
 * first 8 bytes its index relative to the lowest IOVA, (iova - base) >> 12,
 * which is what the engine's data check compares with (BASE = base, BACKING a
 * power of two above the largest index). Prints the port's domain type: the
 * mapping lands in that domain, so it serves the engine only when the port's
 * group is on its own DMA domain (identity / passthrough: IOVA = physical, no
 * translation at all). Nothing else is touched; the port is not written.
 */
#include <linux/debugfs.h>
#include <linux/dma-mapping.h>
#include <linux/iommu.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>

static char *dev = "";
module_param(dev, charp, 0444);
MODULE_PARM_DESC(dev, "the port (or any function) whose DMA domain gets the pages: DDDD:BB:DD.F");
static unsigned int npages = 4096;
module_param(npages, uint, 0444);
MODULE_PARM_DESC(npages, "pages to map (default 4096, at most 65536)");
static char *token = "";
module_param(token, charp, 0444);
MODULE_PARM_DESC(token, "a string put in every log line, to find them in dmesg");

static struct pci_dev *g_pdev;
static struct page **g_pg;
static dma_addr_t *g_iova;
static unsigned int g_n;
static dma_addr_t g_base;
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

static int iovas_show(struct seq_file *m, void *v)
{
	unsigned int i;

	seq_printf(m, "dev %s\nbase 0x%llx\npages %u\n", pci_name(g_pdev), (unsigned long long)g_base, g_n);
	for (i = 0; i < g_n; i++)
		seq_printf(m, "%llu 0x%llx\n", (unsigned long long)((g_iova[i] - g_base) >> PAGE_SHIFT),
			   (unsigned long long)g_iova[i]);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(iovas);

static void undo(void)
{
	unsigned int i;

	debugfs_remove_recursive(g_dir);
	for (i = 0; i < g_n; i++)
		dma_unmap_page(&g_pdev->dev, g_iova[i], PAGE_SIZE, DMA_TO_DEVICE);
	for (i = 0; g_pg && i < npages; i++)
		if (g_pg[i])
			__free_page(g_pg[i]);
	kvfree(g_pg);
	kvfree(g_iova);
	if (g_pdev)
		pci_dev_put(g_pdev);
}

static int __init pbp_init(void)
{
	unsigned int dom, bus, sl, fn, i;
	dma_addr_t hi = 0;

	if (sscanf(dev, "%x:%x:%x.%x", &dom, &bus, &sl, &fn) != 4 || npages == 0 || npages > 65536) {
		pr_err("pips_bg_pages[%s]: dev=DDDD:BB:DD.F and npages 1..65536 needed\n", token);
		return -EINVAL;
	}
	g_pdev = pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(sl, fn));
	if (!g_pdev) {
		pr_err("pips_bg_pages[%s]: no PCI function %s\n", token, dev);
		return -ENODEV;
	}
	pr_info("pips_bg_pages[%s]: %s group %d domain %s dma_mask 0x%llx\n", token, pci_name(g_pdev),
		g_pdev->dev.iommu_group ? iommu_group_id(g_pdev->dev.iommu_group) : -1,
		dom_type(iommu_get_domain_for_dev(&g_pdev->dev)),
		(unsigned long long)dma_get_mask(&g_pdev->dev));
	g_pg = kvcalloc(npages, sizeof(*g_pg), GFP_KERNEL);
	g_iova = kvcalloc(npages, sizeof(*g_iova), GFP_KERNEL);
	if (!g_pg || !g_iova)
		goto nomem;
	for (i = 0; i < npages; i++) {
		g_pg[i] = alloc_page(GFP_KERNEL | __GFP_ZERO);
		if (!g_pg[i])
			goto nomem;
		g_iova[i] = dma_map_page(&g_pdev->dev, g_pg[i], 0, PAGE_SIZE, DMA_TO_DEVICE);
		if (dma_mapping_error(&g_pdev->dev, g_iova[i])) {
			pr_err("pips_bg_pages[%s]: dma_map_page failed at page %u\n", token, i);
			goto fail;
		}
		g_n = i + 1;
	}
	g_base = g_iova[0];
	for (i = 0; i < g_n; i++) {
		if (g_iova[i] < g_base)
			g_base = g_iova[i];
		if (g_iova[i] > hi)
			hi = g_iova[i];
	}
	for (i = 0; i < g_n; i++) {
		u64 *p = page_address(g_pg[i]);
		p[0] = (g_iova[i] - g_base) >> PAGE_SHIFT;
		dma_sync_single_for_device(&g_pdev->dev, g_iova[i], PAGE_SIZE, DMA_TO_DEVICE);
	}
	g_dir = debugfs_create_dir("pips_bg_pages", NULL);
	debugfs_create_file("iovas", 0400, g_dir, NULL, &iovas_fops);
	pr_info("pips_bg_pages[%s]: %u pages mapped for %s, IOVA 0x%llx-0x%llx (span %llu pages); "
		"each page holds (iova - base) >> 12; list: /sys/kernel/debug/pips_bg_pages/iovas\n",
		token, g_n, pci_name(g_pdev), (unsigned long long)g_base, (unsigned long long)hi,
		(unsigned long long)((hi - g_base) >> PAGE_SHIFT) + 1);
	return 0;
nomem:
	pr_err("pips_bg_pages[%s]: out of memory\n", token);
fail:
	undo();
	return -ENOMEM;
}

static void __exit pbp_exit(void)
{
	pr_info("pips_bg_pages[%s]: unmapping %u pages of %s\n", token, g_n, pci_name(g_pdev));
	undo();
}

module_init(pbp_init);
module_exit(pbp_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("PIPS background read engine: pages in a port's own DMA domain (fallback F3)");
