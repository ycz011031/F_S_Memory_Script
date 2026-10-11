# pips: host bring-up tool for the PIPS switch. `make` builds it on the
# testbed host (the scripts here also build it on first use). `make check`
# builds a second copy against a software model of BAR0 (pips_sim.c) and runs
# test-sim.sh: no hardware, no root.
CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -std=gnu11

all: pips

pips: pips.c pips_regs.h
	$(CC) $(CFLAGS) -o $@ pips.c

pips-sim: pips.c pips_sim.c pips_regs.h
	$(CC) $(CFLAGS) -DPIPS_SIM -o $@ pips.c pips_sim.c

check: pips-sim
	bash ./test-sim.sh

clean:
	rm -f pips pips-sim

.PHONY: all check clean
