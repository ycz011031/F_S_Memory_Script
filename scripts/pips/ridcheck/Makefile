# Out-of-tree build of the ridcheck modules for the running kernel. The scripts
# copy this folder into their output folder and build there (nothing is written
# here). MODS picks the modules: pips_iommu_peek (pips-rid-check.sh --module),
# pips_bg_pages (pips-rid-live.sh T11, fallback F3).
MODS ?= pips_iommu_peek
obj-m := $(addsuffix .o,$(MODS))
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
