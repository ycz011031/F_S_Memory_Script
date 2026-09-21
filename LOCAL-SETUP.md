# Local testbed adaptation worksheet

The upstream scripts are hardwired to the authors' Cornell testbed (user `benny`,
host `genie04.cs.cornell.edu`, IPs `192.168.11.116/117`, a 4-socket Cascade Lake
receiver, `/home/benny` everywhere). This file collects what is needed to retarget
them at a local Ice Lake + Broadwell pair.

**Fill in Parts B, C and D. Part A is a paste of a script's output.**

---

## Part 0 — Role assignment (already decided, listed so it is unambiguous)

```
   +---------------------------+                      +---------------------------+
   |  BROADWELL                |                      |  ICE LAKE                 |
   |  role: CLIENT / SENDER    |   iperf3 bulk TCP    |  role: SERVER / RECEIVER  |
   |                           |  ----------------->  |                           |
   |  - iperf3 -c              |                      |  - iperf3 -s              |
   |  - netserver              |  <-----------------  |  - netperf (TCP_RR)       |
   |  - sar, netstat (retx)    |   netperf RPCs       |  - Intel PCM (IOMMU ctrs) |
   |  - NO PCM, NO IOMMU       |                      |  - Intel MLC              |
   |                           |                      |  - IOMMU ON (the SUT)     |
   +---------------------------+                      +---------------------------+
                  ^                                                |
                  |            ssh + scp, driven by the            |
                  +----------------- receiver ---------------------+

   YOU LAUNCH THE EXPERIMENTS ON THE ICE LAKE.
   It SSHes out to the Broadwell. You never log into the Broadwell by hand.
```

Why: every uarch-sensitive measurement runs on the receiver. The driver calls
`record-host-metrics.sh --pcie 1 --membw 1` locally and `--pcie 0 --membw 0`
over SSH. The Ice Lake is the system under test; the Broadwell only generates load.

The **patched netperf** (`utils/tcp/netperf-logging.diff`) is needed on *both*
machines: `netserver` runs on the Broadwell, `netperf` on the Ice Lake.

---

## Part A — Automated survey (paste output)

Run on **both** machines, from the repo's `scripts/` directory:

```bash
bash collect-setup-info.sh                  # auto-detects the fastest NIC
bash collect-setup-info.sh ens2f1np1        # or name the interface explicitly
sudo bash collect-setup-info.sh             # as root, for the dmesg IOMMU lines
```

It is read-only and changes nothing.

### A1. Ice Lake (receiver) output

```
<paste here>
```

### A2. Broadwell (sender) output

```
<paste here>
```

---

## Part B — Things the survey cannot answer

### B1. SSH from Ice Lake to Broadwell

| Item | Value |
|---|---|
| Hostname/IP to SSH to (control plane, may differ from the data-plane IP) | |
| SSH username on the Broadwell | |
| Key-based auth working from Ice Lake? (`ssh user@host true`) | yes / no |
| Passwordless `sudo` on the Broadwell? | yes / no |

Two hard requirements, both from [run-dctcp-tput-experiment.sh:227](scripts/run-dctcp-tput-experiment.sh#L227):

1. **Passwordless sudo on the Broadwell.** The driver runs
   `ssh` then `screen -dmS` then `sudo bash -c ...`. That path has no TTY, so a
   sudo password prompt cannot be answered and the client silently never starts.
   Fix: `echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/fands`
2. **Key-based SSH.** Upstream uses `sshpass -p benny` with a plaintext password
   in the script. I will replace that with plain `ssh`/`scp` using keys unless you
   want the password path kept. Set up with:
   `ssh-keygen -t ed25519 && ssh-copy-id user@broadwell`

### B2. Filesystem paths

Upstream computes `$setup_dir` on the **receiver**, then ships that absolute path
over SSH to run on the **sender**. So today the repo must sit at an *identical*
absolute path on both machines.

| Item | Ice Lake | Broadwell |
|---|---|---|
| Home directory (`echo $HOME`) | | |
| Absolute path to this repo | | |
| Are those two repo paths identical? | yes / no | |

If they cannot be identical, say so and I will split the variable into
`server_repo_dir` / `client_repo_dir`.

### B3. Helper tool locations (only if not at the default the survey checks)

| Tool | Default the scripts assume | Actual path on Ice Lake |
|---|---|---|
| Intel PCM | `$HOME/pcm/build/bin/` | |
| Intel MLC | `$HOME/mlc/Linux/mlc` | |
| ddio-bench | `$HOME/ddio-bench/change-ddio-{on,off}` | |
| terabit profiling repo | `$HOME/terabit-network-stack-profiling/` | |
| hostCC (Fig 8 only) | `$HOME/hostCC/src` | |

Note the upstream naming mismatch: `utils/README.md` says to clone
`Understanding-network-stack-overheads-SIGCOMM-2021`, but
[setup-envir.sh:146](utils/setup-envir.sh#L146) changes into
`$home/terabit-network-stack-profiling/`. Tell me which name you used.

### B4. `restart.sh`

`cleanup()` calls `sudo bash /home/benny/restart.sh` at
[run-dctcp-tput-experiment.sh:185](scripts/run-dctcp-tput-experiment.sh#L185) and
[:210](scripts/run-dctcp-tput-experiment.sh#L210), but that file is not in the repo.
The surrounding code already bounces the interface, so its purpose is unclear
(likely an IRQ-affinity re-pin or a driver reload).

Pick one:

- [ ] make it a no-op
- [ ] reload the NIC driver (`modprobe -r mlx5_core` then `modprobe mlx5_core`)
- [ ] I have my own, path: `________`

### B5. Scope

| Question | Answer |
|---|---|
| Which figures do you want working? (2/3 = flows + ringbuffer, 7 = latency, 8 = hostCC + MLC) | |
| Run the hostCC variant (`hcc_fig8.sh`)? Needs the separate hostCC repo built against your kernel. | yes / no |
| Do you have Intel MLC installed? (needed for the Fig 8 contention sweep) | yes / no |
| Number of repeats per data point (upstream `num_runs=1`, so stddev is always 0) | |

### B6. Core budget

The scripts pin to *fixed, hardcoded* core IDs. Confirm these exist, or give
replacements. `lscpu -p=CPU,NODE` in Part A tells us which cores are NUMA-local
to the NIC, which is what matters for throughput.

| Purpose | Upstream value | Needs | Your value |
|---|---|---|---|
| iperf3 workers, both hosts (`cpu_mask`) | `4,8,12,16,20` | NUMA-local to NIC on *both* | |
| netperf/netserver core (`lat_app_core`) | `20` | at least 21 logical CPUs | |
| PCM pinning ([record-host-metrics.sh:153](utils/record-host-metrics.sh#L153), [:171](utils/record-host-metrics.sh#L171)) | `31` | at least 32 logical CPUs on Ice Lake | |
| IIO occupancy ([:317](utils/record-host-metrics.sh#L317)) | `28` | Ice Lake only | (being removed) |

A single-socket 8c/16t Broadwell has no core 20 and `taskset` will fail.

---

## Part C — The PCM / IOMMU counter layout (most important item)

This is the one that silently produces *wrong numbers* rather than failing.

[record-host-metrics.sh:158-166](utils/record-host-metrics.sh#L158-L166) extracts
IOMMU stats by hardcoded CSV column (`$8` through `$14`) after grepping the literal
string `Socket0,IIO Stack 2 - PCIe1,Part0`. Both were written for
`opCode-85.txt` (Cascade Lake). Your Ice Lake loads `opCode-106.txt`, which
exposes a **different event set with different semantics**:

| Slot | opCode-85 (paper) | opCode-106 (your Ice Lake) |
|---|---|---|
| 1 | IOTLB Hit | IOTLB **Lookup** |
| 2 | IOTLB Miss | IOTLB Miss |
| 3 | VT-d CTXT **Miss** | Ctxt Cache **Hit** |
| 4 | VT-d L1 Miss | **512G** Cache Hit |
| 5 | VT-d L2 Miss | **1G** Cache Hit |
| 6 | VT-d L3 Miss | **2M** Cache Hit |
| 7 | VT-d Mem Read | **4K** Cache Hit |

Ice Lake reports page-walk-cache *hits bucketed by page size*; Cascade Lake
reported *misses by walk level*. Unpatched, `report-tput-metrics.py ... iommu`
will print "L1/L2/L3 misses" that are really 512G/1G/2M **hits**.

### What to run (on the Ice Lake, after building PCM)

```bash
cd <repo>/utils                      # pcm-iio picks up opCode-*.txt from CWD
sudo modprobe msr
sudo ~/pcm/build/bin/pcm-iio 1 -csv=/tmp/pcie-probe.csv &
sleep 5; sudo pkill -f pcm-iio

head -5 /tmp/pcie-probe.csv          # <-- I need this: the header rows
grep -c . /tmp/pcie-probe.csv
cut -d, -f1-3 /tmp/pcie-probe.csv | sort -u | head -40   # <-- and the stack labels
```

Ideally run it **while traffic is flowing** so the counters are non-zero.

### C1. Paste `head -5 /tmp/pcie-probe.csv`

```
<paste here>
```

### C2. Paste the unique `Socket,Stack,Part` labels

```
<paste here>
```

### C3. Which of those rows corresponds to your NIC's PCIe slot?

Cross-reference with the NIC's PCI address and NUMA node from Part A.

```
<answer here>
```

With C1 through C3 I will rewrite `parse_pciebw` to resolve columns **by header
name** instead of by fixed index, so it self-adapts to whichever opCode file the
CPU loads, and emits correctly-labelled Ice Lake metrics.

---

## Part D — Confirm the derived config

Once A through C are in, I will generate a single `config.sh` sourced by every
script. This table is what it will contain; it is here so you can sanity-check it.

| Variable | Value |
|---|---|
| `server` (Ice Lake data-plane IP) | |
| `server_intf` | |
| `client` (Broadwell data-plane IP) | |
| `client_intf` | |
| `ssh_host` (Broadwell control-plane) | |
| `ssh_user` | |
| `repo_dir` | |
| `pcm_dir` / `mlc_dir` / `ddio_dir` / `terabit_dir` | |
| `cpu_mask` / `lat_app_core` / `pcm_core` | |
| `pcie_csv_key` (the `Socket,Stack,Part` string) | |
| `mtu` / `ring_buffer` / `buf` / `bandwidth` | |

---

## Appendix — Changes planned once the above is filled in

1. **`config.sh`** — single source of truth; delete the hardcoded blocks at
   [run-dctcp-tput-experiment.sh:38-70](scripts/run-dctcp-tput-experiment.sh#L38-L70)
   and the twins in the latency and hcc drivers.
2. **`parse_pciebw` by header name**, not column index (Part C). The correctness fix.
3. **Drop `sshpass`**, use key-based `ssh`/`scp`; remove the plaintext password.
4. **Add the missing `clean_logs.sh`** — called by four wrappers, absent from git.
5. **Neutralise `restart.sh`** per B4.
6. **Disable `collect_iio_occ`** (`-I 1` becomes `-I 0`). It hardcodes Skylake MSRs
   (`0x0A48`/`0x0A41`) and Skylake VT-d encodings in
   [collect_iio_occ.c:22-30](utils/collect_iio_occ.c#L22-L30), so it reads garbage on
   Ice Lake. Harmless to remove: `iio.log` is never parsed
   ([record-host-metrics.sh:322](utils/record-host-metrics.sh#L322) has the TODO).
7. **Guard `parse_membw`** for a 2-socket box (upstream greps NODE 0 through 3).
8. **Interface name out of the wrappers** — `ens2f1np1` is repeated in all five.
9. **Sender-saturation preflight** — a check that the Broadwell can actually fill
   the link, so a slow sender is not mistaken for "the IOMMU is free".
