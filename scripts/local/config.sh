#!/bin/bash
# Local testbed config. Sourced by preflight.sh and run-traffic.sh.
#
# Topology (see LOCAL-SETUP.md Part 0):
#   ICE LAKE  = server / receiver = where you run these scripts
#   BROADWELL = client / sender   = reached over ssh, never logged into by hand
#
# ONLY THE SIX VALUES IN "REQUIRED" NEED FILLING IN TO GET TRAFFIC FLOWING.

# ------------------------------------------------------------------ REQUIRED
# Ice Lake: the NIC facing the Broadwell, and its IP on that link.
#   find it with:  ip -br addr        or  bash scripts/collect-setup-info.sh
SERVER_INTF=""
SERVER_IP=""

# Broadwell: same two facts.
CLIENT_INTF=""
CLIENT_IP=""

# How the Ice Lake reaches the Broadwell over SSH. This is often a management
# hostname/IP that is NOT the data-plane CLIENT_IP above. Using CLIENT_IP here
# is fine if that is the only link between them.
SSH_HOST=""
SSH_USER=""

# ------------------------------------------------------------------ WORKLOAD
NUM_FLOWS=5            # parallel iperf3 connections
DURATION=20            # seconds of measured traffic
BASE_PORT=3000         # ports BASE_PORT .. BASE_PORT+NUM_FLOWS-1
BANDWIDTH=0            # per-flow cap in bits/sec; 0 = unlimited
CCA="cubic"            # congestion control on the SENDER.
                       #   cubic = safe default, works anywhere
                       #   dctcp = what the paper uses, but needs ECN marking
                       #           configured on the switch or it misbehaves

# CPU pinning. Leave empty to auto-pick cores on the NUMA node local to the
# NIC (strongly recommended, and what the paper does). Override with an
# explicit list like "4,8,12,16,20" if you want to match upstream exactly.
SERVER_CORES=""
CLIENT_CORES=""

# ------------------------------------------------------------- SYSTEM TUNING
# 0 = touch NOTHING on either machine. Start here: it isolates "can these two
#     boxes move packets" from "is my tuning correct".
# 1 = apply MTU / ring buffer / socket buffer below. Needs passwordless sudo
#     on both machines.
APPLY_NET_TUNING=0

MTU=1500               # 4000 (the paper's value) needs jumbo frames enabled
                       # end-to-end INCLUDING the switch, or everything blackholes
RING_BUFFER=""         # e.g. 256 ; empty = leave the driver default alone
SOCK_BUF_MB=1          # TCP socket buffer; also disables rcvbuf autotuning

# ------------------------------------------------------------------ INTERNAL
# Absolute path to this repo. Must resolve to the SAME path on both machines,
# because the remote command is built here and executed there. "auto" derives
# it from this file's location.
REPO_DIR="auto"

# Where results land (relative to repo root).
OUT_DIR="utils/logs/local"

# SSH options. BatchMode makes a missing key fail fast instead of hanging on a
# password prompt.
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
