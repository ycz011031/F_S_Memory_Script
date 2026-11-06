# Out-of-tree build of pips_iommu_peek.ko for the running kernel. pips-rid-check.sh
# copies this folder into its output folder and builds there (nothing is written here).
obj-m := pips_iommu_peek.o
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
