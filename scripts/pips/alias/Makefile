# The in-house load generators of the alias campaign (README.md):
#   alias-nvme  NVMe reads through VFIO (bigserver; needs linux/vfio.h)
#   alias-rdma  RDMA READs (icx and styx; needs libibverbs-dev)
# Binaries go to build/<host>/ so one checkout on shared storage serves every
# host (git-ignored). `make nvme` / `make rdma` build one; alias-run.sh builds
# the one it is asked for on first use.
HOST ?= $(shell hostname -s 2>/dev/null || hostname)
B ?= build/$(HOST)
CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -std=gnu11

all: nvme rdma
nvme: $(B)/alias-nvme
rdma: $(B)/alias-rdma

$(B)/alias-nvme: alias-nvme.c alias_common.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ alias-nvme.c -lpthread

$(B)/alias-rdma: alias-rdma.c alias_common.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ alias-rdma.c -libverbs

clean:
	rm -rf build

.PHONY: all nvme rdma clean
