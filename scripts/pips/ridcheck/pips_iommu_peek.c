// SPDX-License-Identifier: GPL-2.0
/*
 * pips_iommu_peek: read-only check for pips-rid-check.sh. For each pair
 * "PORT=DEV" (a PIPS downstream port and the device below it) it reports
 * whether the kernel has attached both functions to the same IOMMU domain,
 * and for each IOVA given what physical address each function's domain
 * translates it to. The FPGA background read engine (docs/PIPS-BG-READ-ENGINE.md)
 * issues reads under the port's requester ID and relies on exactly this.
 *
 *   insmod pips_iommu_peek.ko token=T pairs=0000:b2:00.0=0000:b3:00.0 iovas=0x4000000000,0x4000001000
 *   dmesg | grep 'pips_iommu_peek\[T\]'; rmmod pips_iommu_peek
 *
 * It changes nothing: no mapping, no attach, no config write. Everything is
 * printed from init; the module stays loaded (doing nothing) until rmmod.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/iommu.h>

static char *pairs = "";
module_param(pairs, charp, 0444);
MODULE_PARM_DESC(pairs, "PORT=DEV[,PORT=DEV]: PCI addresses DDDD:BB:DD.F");
static unsigned long iovas[16];
static int n_iovas;
module_param_array(iovas, ulong, &n_iovas, 0444);
MODULE_PARM_DESC(iovas, "IOVAs to translate through both domains (up to 16)");
static char *token = "x";
module_param(token, charp, 0444);
MODULE_PARM_DESC(token, "marker in every line, to find this run's lines in dmesg");

#define P(fmt, ...) pr_info("pips_iommu_peek[%s]: " fmt "\n", token, ##__VA_ARGS__)

static struct pci_dev *get_pdev(const char *bdf)
{
	unsigned int dom, bus, dev, fn;

	if (sscanf(bdf, "%x:%x:%x.%x", &dom, &bus, &dev, &fn) != 4)
		return NULL;
	return pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(dev, fn));
}

static const char *dtype(struct iommu_domain *d)
{
	if (!d)
		return "none";
	switch (d->type) {
	case IOMMU_DOMAIN_BLOCKED:
		return "blocked";
	case IOMMU_DOMAIN_IDENTITY:
		return "identity";
	case IOMMU_DOMAIN_UNMANAGED:
		return "unmanaged";	/* VFIO's own domain */
	case IOMMU_DOMAIN_DMA:
		return "dma";
#ifdef IOMMU_DOMAIN_DMA_FQ
	case IOMMU_DOMAIN_DMA_FQ:
		return "dma-fq";
#endif
	}
	return "other";
}

static int paging(struct iommu_domain *d)
{
	return d && (d->type == IOMMU_DOMAIN_UNMANAGED || d->type == IOMMU_DOMAIN_DMA
#ifdef IOMMU_DOMAIN_DMA_FQ
		     || d->type == IOMMU_DOMAIN_DMA_FQ
#endif
		);
}

static int group_id(struct device *dev)
{
	struct iommu_group *g = iommu_group_get(dev);
	int id = -1;

	if (g) {
		id = iommu_group_id(g);
		iommu_group_put(g);
	}
	return id;
}

static void one_pair(const char *port_s, const char *dev_s)
{
	struct pci_dev *port = get_pdev(port_s), *dev = get_pdev(dev_s);
	struct iommu_domain *dp, *dd;
	u16 cp = 0, cd = 0;
	int i;

	if (!port || !dev) {
		P("pair %s=%s: ERROR no such PCI device (%s)", port_s, dev_s, port ? dev_s : port_s);
		goto out;
	}
	dp = iommu_get_domain_for_dev(&port->dev);
	dd = iommu_get_domain_for_dev(&dev->dev);
	pci_read_config_word(port, PCI_COMMAND, &cp);
	pci_read_config_word(dev, PCI_COMMAND, &cd);
	P("pair %s=%s: group %d/%d domain %s/%s same_domain=%d port_bme=%d dev_bme=%d",
	  port_s, dev_s, group_id(&port->dev), group_id(&dev->dev), dtype(dp), dtype(dd),
	  dp && dp == dd, !!(cp & PCI_COMMAND_MASTER), !!(cd & PCI_COMMAND_MASTER));
	for (i = 0; i < n_iovas; i++) {
		phys_addr_t pp = paging(dp) ? iommu_iova_to_phys(dp, iovas[i]) : 0;
		phys_addr_t pd = paging(dd) ? iommu_iova_to_phys(dd, iovas[i]) : 0;

		P("pair %s=%s: iova 0x%lx port_phys 0x%llx dev_phys 0x%llx match=%d mapped=%d",
		  port_s, dev_s, iovas[i], (unsigned long long)pp, (unsigned long long)pd,
		  pp == pd, pp != 0 && pd != 0);
	}
out:
	pci_dev_put(port);
	pci_dev_put(dev);
}

static int __init peek_init(void)
{
	char *buf = kstrdup(pairs, GFP_KERNEL), *s, *tok;

	if (!buf)
		return -ENOMEM;
	P("start: %d iova(s)", n_iovas);
	s = buf;
	while ((tok = strsep(&s, ",")) != NULL) {
		char *eq = strchr(tok, '=');

		if (!*tok)
			continue;
		if (!eq) {
			P("pair '%s': ERROR not PORT=DEV", tok);
			continue;
		}
		*eq = 0;
		one_pair(tok, eq + 1);
	}
	kfree(buf);
	P("done");
	return 0;
}

static void __exit peek_exit(void)
{
}

module_init(peek_init);
module_exit(peek_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("PIPS: read-only check that a switch port and its device share an IOMMU domain");
