# Minimal local traffic path

A stripped-down route to "packets are moving between my two boxes", independent
of the SOSP'24 wrappers. No Intel PCM, no MLC, no IOMMU logging, no ddio-bench,
no `sshpass`, no `restart.sh`, no patched kernel.

Once traffic flows reliably, layer the real measurement back on. See
`../../LOCAL-SETUP.md` for the full adaptation worksheet.

## Direction

```
BROADWELL  --- iperf3 senders --->  ICE LAKE
(client)                            (server / receiver / system under test)
```

**Run everything on the Ice Lake.** It drives the Broadwell over SSH. This is the
same direction the upstream scripts use, and it is not arbitrary: the receiver is
where the IOMMU and the hardware counters live.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `config.sh` | — | All tunables. Six required values. |
| `preflight.sh` | Ice Lake | Read-only validation. Changes nothing. |
| `run-traffic.sh` | Ice Lake | Starts receivers, drives senders, reports Gbps. |
| `_remote-client.sh` | Broadwell | Invoked over SSH. Not run by hand. |
| `_common.sh` | both | Shared helpers. Sourced, not executed. |

## Use

```bash
# on the Ice Lake
vim scripts/local/config.sh        # fill in the six REQUIRED values
bash scripts/local/preflight.sh    # fix anything it flags
bash scripts/local/run-traffic.sh  # drive traffic
bash scripts/local/run-traffic.sh 20   # override flow count for one run
```

## Prerequisites

- `iperf3`, `python3`, `taskset` on both machines
- Key-based SSH from the Ice Lake to the Broadwell (`ssh-copy-id`)
- A working data-plane link with an IP on each end, in the same subnet
- Passwordless sudo on both — **only** if `APPLY_NET_TUNING=1`

`preflight.sh` checks all of these and prints the fix for whatever is missing.

## Defaults worth knowing

- `APPLY_NET_TUNING=0` — the first run touches nothing. This separates "can these
  boxes move packets" from "is my tuning right". Turn it on once traffic flows.
- `CCA=cubic`, not the paper's `dctcp`. DCTCP needs ECN marking configured on the
  switch; without it, it behaves badly in ways easily mistaken for a host problem.
- `MTU=1500`. The paper uses 4000, which needs jumbo frames end-to-end including
  the switch, or traffic blackholes.
- `SERVER_CORES` / `CLIENT_CORES` empty means auto-pick cores on the NUMA node
  local to the NIC, skipping core 0 and hyperthread siblings. This matters a lot
  for throughput; the upstream hardcoded `4,8,12,16,20` is specific to the
  authors' machine.

## Reading the output

`run-traffic.sh` reports aggregate Gbps, completed flows, retransmits, link
utilisation and receiver CPU.

If link utilisation is below 70% it says so explicitly. Take that seriously: a
Broadwell sender may simply be unable to fill a 100G link, and a sender-limited
run makes the receiver look idle. That would read as "the IOMMU costs nothing"
when in fact the experiment never reached the regime where address translation
becomes the bottleneck. Raise `NUM_FLOWS` and widen `CLIENT_CORES` until the
number plateaus — that plateau is your real sender ceiling, and every later
comparison has to stay below it.
