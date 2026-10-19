# Reading one PIPS sweep's logs, and nothing else

The hosts keep every run ever made in `utils/logs/`, `utils/reports/` and `~`:
two builds' worth of PIPS sweeps, bring-up logs, datapath checks, sweeps
without the switch. Folder names overlap (`dualssd-pips-strict-1-…` has been
used for two builds), and a numbered name is reused once its results leave
`~`. So a parser must never decide what belongs to a sweep by globbing names.

From 2026-10-17 every PIPS sweep (`dualssd_pips_sweep.sh`,
`dualnic_pips_sweep.sh`) gives itself a **sweep ID**, stamps it into every run
it makes, and lists every run in a **manifest**. Read the manifest; check the
ID; ignore everything else.

## The sweep ID

`<sweep name>@<short host name>@<start time YYYYmmdd-HHMMSS>`, for example
`dualssd-pips-strict-dsweep1@bigserver@20261017-101500`. One per sweep, set
when it starts. Name, host and start time together are unique, even when a
name is reused.

| Where | File | What |
|---|---|---|
| the sweep's folder | `utils/logs/<name>/sweep-id.txt` | `sweep_id=`, `sweep=`, `kind=` (ssd or nic), `host=`, `design_id=`, `started=`, `manifest=` |
| the manifest | `utils/logs/<name>/manifest.tsv`, copied to `~/<name>.manifest.tsv` | `# sweep_id=` in the header, and column 1 of every row |
| each run's log folder | `<run folder>/sweep-id.txt` | `sweep_id=`, `sweep=`, `sweep_setting=` (`<name>-id<XXXX>-<setting>`), `setting=`, `point=`, `run=`, `started=` |
| each run's report | `utils/reports/<run>/pips-log.rpt` | a `sweep_id: …` line |
| each result record | `~/<name>-id<XXXX>-<setting>.jsonl` | `pips_sweep_id`, `pips_sweep` |
| the sweep summary | `~/<name>.txt` | a `sweep_id=` line, third from the top |

**A run folder without `sweep-id.txt` is not part of any sweep from
2026-10-17 on.** Every earlier run lacks it.

## The manifest

Tab-separated text. Lines starting with `#` are the header (`# key=value`),
then one row of column names, then one row per run in the order the runs
ended. Rows are appended as each run's TLP log is collected, so a sweep that
was stopped still has a manifest of what it finished.

Header keys: `sweep_id`, `sweep`, `kind` (`ssd` or `nic`), `host`,
`design_id`, `started`, `repo_revision`, and one
`setting_sweep=<name>-id<XXXX>-<setting> results=<path of its .jsonl>` per
setting, in run order.

| Column | Content |
|---|---|
| `sweep_id` | the sweep ID; the same in every row |
| `setting` | the batcher setting the switch reported at the run's start, `d<depth>t<time>[m1][c1]` |
| `point` | drives: `4k-j8-both`, `4k-j2+16-both` (uneven co-run), `datapath-4k-j1`; NICs: `uncapped-f5-both`, `uncapped-f5-datapath` |
| `role` | `point` (a measured point) or `datapath` (a check before a setting's sweep; leave it out) |
| `run` | the run's name, the last part of its log folder |
| `log_dir` | the run's log folder, relative to the repo root on that host |
| `report_dir` | its report folder (holds `pips-log.rpt`), relative too |
| `tlp_log` | the TLP log, `<log_dir>/pips-log-id<XXXX>.bin.gz`; empty if none was dumped |
| `status` | `FULL`, `CUT`, `+DROPS`, `NO_TRAILER`, `BAD` or `FAILED` (PIO-MANUAL.md §8.8) |
| `design_id` | the FPGA build, e.g. `0x0a04`; it picks the log's record format (v2 from `0x0a04`) |
| `finished` | when the row was written, host local time |

A run that died before its TLP log was collected has a folder with
`sweep-id.txt` but no manifest row. A run the runner dropped after collecting
its log (on bigserver: `pcm-iio` logged no rows, 20 runs at 4 KiB on 10-15/16)
has its row and its TLP log but no JSONL record: join rows to records on
setting and point, and expect some rows without one.

## Rules for a parser

1. **Take the manifest as the input** (`~/<name>.manifest.tsv`), not a folder
   to search.
2. Read `sweep_id` from the header and keep only rows whose first column
   equals it (they all should; warn if not).
3. Leave out `role` = `datapath`.
4. Use `status` = `FULL`; count and report the others, don't drop them silently.
5. Paths are relative to the repo root on the host the sweep ran on
   (`~/F_S_Memory_Script` on bigserver and icx). On a copy, prefix wherever
   the copy's `utils/` sits.
6. Results: read the `.jsonl` files the header names and keep the records whose
   `pips_sweep_id` equals the sweep ID.
7. Decode with the design ID: from `-id<XXXX>` in `tlp_log`'s name, or pass
   the manifest's `design_id` as `--design-id` (`pips-log-decode.py --help`).
8. Without a manifest (only folders were copied), accept a run folder only if
   its `sweep-id.txt` carries the sweep ID. Never infer membership from the
   folder name alone.
9. When copying results off a host, copy the manifest and keep each run's
   `sweep-id.txt`.

```python
def read_manifest(path):
    """-> (header dict, list of row dicts), this sweep's measured runs only."""
    head, cols, rows = {}, None, []
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("# "):
            k, sep, v = line[2:].partition("=")
            if sep and " " not in k:
                head.setdefault(k, v)
        elif cols is None:
            cols = line.split("\t")
        elif line:
            rows.append(dict(zip(cols, line.split("\t"))))
    sid = head["sweep_id"]
    return head, [r for r in rows if r["sweep_id"] == sid and r["role"] == "point"]
```

```bash
# the FULL TLP logs of a sweep, one per line
awk -F'\t' '!/^#/ && $1 != "sweep_id" && $4 == "point" && $9 == "FULL" { print $8 }' ~/<name>.manifest.tsv
```

`pips-seq-grab.sh --manifest ~/<name>.manifest.tsv` already reads a sweep this
way. `pips-traffic.py`, `pips-addr-pattern.py` and `pips-mwr-sizes.py` take
folders: give them the `log_dir`s from the manifest, not `utils/logs`.

## Names, for people

- **Sweep:** `<kind>-pips-<iommu>-<label>` with `--tag LABEL` (letters and
  digits, not shaped like a setting or design tag), else `-<N>`, the first
  number with no results in `~`. Use a new label per campaign.
- **Per setting:** `<name>-id<XXXX>-<setting>`, e.g.
  `dualssd-pips-strict-dsweep1-id0a05-d8t106c1`.
- **Run folders:** drives `utils/logs/<name>-id<XXXX>-<setting>/<point>-RUN-<j>/`,
  NICs `utils/logs/<name>-id<XXXX>-<setting>-<point>-RUN-server-<j>/`.
- **Settings:** `d8t106c1` = depth 8, time 106 cycles (4 ns each), drain cap
  on; `m1` = `batch_mrd` on. No `c1` = cap off.

## The 10-17 depth sweep

Strict, design `0x0a05` (0x0a04 with 512-beat batching FIFOs; the sweep was
planned on 0x0a04 and ran on the newer build), cap on only, eight settings in
this order:
`d1t0c1 d2t22c1 d4t50c1 d8t106c1 d16t218c1 d24t255c1 d36t255c1 d64t255c1`
(why these times: HANDOFF §8, "Depth sweep").

| | Drives (bigserver) | NICs (icx) |
|---|---|---|
| sweep | `dualssd-pips-strict-dsweep1` | `dualnic-pips-strict-dsweep1` |
| points per setting | 90: 5 block sizes × 18 co-runs | 4: 5, 10, 15, 30 flows per NIC, both NICs |
| datapath checks | one per setting (8) | one, before `d1t0c1` only |
| manifest rows | 728, of them 720 points | 33, of them 32 points |
| ran (10-17/18) | 702 of 720 points, all logs FULL (18 dropped at 4 KiB for missing `pcm-iio` rows) | 22 of 32 points + the datapath check: stopped during `d24t255c1` (after f10) when the switch stopped answering; `d24` f15/f30, `d36`, `d64` not run |

The NIC sweep's missing settings go in a new sweep (`--tag dsweep1b`), not
under `dsweep1`: its manifest and sweep ID stay as they ended. A page-order
grab of `dsweep1` reads its manifest and so takes the 22 NIC runs that have a
log (`pips-seq-grab.sh --manifest`).
If the hosts are booted with the IOMMU off, `strict` reads `off` in the names.

## Earlier runs on the hosts (none has a sweep ID)

- bigserver: `dualssd-pips-{off,strict}-1-{d1t0,d4t22,d8t22,d16t64}` (design
  `0x0a02`, v1 logs, 10-13); `dualssd-pips-strict-1-id0a04-*` (`0x0a04`,
  10-15/16); `pips-fio-*` (bring-up, one with design "none"); `dualssd-sweep-*`,
  `dualssd-xsweep-*`, `dualssd-bssweep-*` (no TLP logs); every sweep's
  `datapath-*` runs.
- icx: `dualnic-pips-strict-1-id0a04-*-RUN-server-0` (10-15/16, with one-NIC
  runs and datapath checks); `dnflows-*`, `dualnic-flowsweep-*` (no switch).
- `~` on both: `seq-*` page-order grabs, `traffic*` reports. The grabs from
  before 2026-10-19 (`seq-dualssd-0a04-arr`, `seq-dualnic-0a04-arr`) ran the
  batcher model without the uplink limit (`pips-page-seq.py --link`) or the
  grant gap; regrab with `pips-analyze.sh` (one run per host, both designs,
  its own output name).
