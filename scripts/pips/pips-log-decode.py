#!/usr/bin/env python3
"""Decode a PIPS TLP log: the DDR region the log DMA wrote, as saved by
`pips log-dump` (or XSCT `pips_log_dump`).

    pips-log-decode.py log.bin                         summary to stdout
    pips-log-decode.py log.bin --csv log.csv --json log-summary.json
    pips-log-decode.py log.bin.gz --region-bytes 0x400000 --rpt pips-log.rpt
    pips-log-decode.py region.bin --scan               the DMA never finished:
                                                       no trailer, so walk the
                                                       records until one was
                                                       never written
    pips-log-decode.py log.bin --design-id 0x0a04      say which build wrote it

The first line says whether the recording is whole: FULL (it ran until the
region filled), CUT (ended before), either with +DROPS (TLPs lost to logger
FIFO overflow), NO_TRAILER (it never closed), or BAD (file and trailer
disagree; exit status 1). See classify().

Design ID. The record format depends on the FPGA build that wrote the log,
and the data cannot tell (the trailer is the same in both), so the build's
design ID picks the decoder (FORMATS). It is taken from, in order: the
--design-id option; "-id<XXXX>" in the file name (pips-log-id0a04.bin.gz, as
the scripts name logs from design 0x0a02 on); a "design_id=" line in a `pips
cfg` readout in the same folder (pips-cfg.txt, cfg-before.txt, cfg-run.txt or
cfg.txt). With none of them the log is from before design IDs were recorded
and is read in that encoding, v1. Every output names the design ID and format
it used: the summary's second line, the JSON, the .rpt, the CSV's first line.

  v1  (before 0x0a04) records for three ports in end-of-packet order: in0 =
      requests from downstream port one (10ee:b348), in1 = from downstream
      port zero (10ee:b148), out = the batched stream sent to the host.
      pkt_tag at 0x0c, AT at 0x0d.
  v2  (0x0a04 on) one record per TLP leaving the batcher, in the order they
      left; port = the input it came in on (in0, in1, as above). pkt_wait at
      0x0c (u16): cycles from its SOP on the input to its SOP on the output,
      65535 = at least that. pkt_tag at 0x0f, AT in pkt_type[5:4]. Here the
      in0 and in1 rows are each input's TLPs as they left, out is all of them.

Record format: telemetry_dma_format.md §4 (AXI4-switch repo); field meanings:
axi4_telemetry_decode.md §4, §8. Dropped records (FIFO overflow) keep their
slot but carry no data. pkt_gap, pkt_length and payload_dw saturate at 255;
saturated values are counted apart and left out of means and percentiles, as
are saturated pkt_wait values. CSV, v1: t_lb is a per-port lower bound on
time since the first record of that port, in cycles: the running sum of gap +
length (stalls inside a packet are not seen). CSV, v2: out_sop and in_sop
rebuild the timeline (telemetry_dma_format.md §4.3) from the first record's
output SOP = 0; seg goes up after each saturated gap or dropped record, where
later times become lower bounds.
"""
import argparse
import collections
import csv
import gzip
import json
import os
import re
import struct
import sys

REC_V1 = struct.Struct("<QBBBBBBBB")   # addr, length, gap, type, payload_dw, tag, at, info, 0
REC_V2 = struct.Struct("<QBBBBHBB")    # addr, length, gap, pkt_type, payload_dw, wait, info, tag
TRL = struct.Struct("<IIIBBBB")
KIND_TLP, KIND_DROP, KIND_TRAILER, KIND_PAD = range(4)
PORTS = ("in0", "in1", "out")
PORT_DESC = {
    "v1": {"in0": "from downstream port one (b348)",
           "in1": "from downstream port zero (b148)",
           "out": "batched, sent to the host"},
    "v2": {"in0": "from downstream port one (b348), as sent",
           "in1": "from downstream port zero (b148), as sent",
           "out": "all, as sent to the host"},
}
TYPES = ("MRd", "MWr", "IORd", "IOWr", "FetchAdd", "Swap", "CAS", "LockedRd",
         "Cfg0Rd", "Cfg1Rd", "Cfg0Wr", "Cfg1Wr", "Msg", "VendorMsg", "ATSMsg",
         "Rsvd")
AT = ("untranslated", "translation_req", "translated", "reserved")
STOP = {1: "enable_low", 2: "region_full"}
CLOCK_HZ = 250e6                 # upstream user_clk, the logger's clock
WAIT_SAT = 65535

# Record format by the design ID of the build that wrote the log: (first
# design ID, format), newest first. A build with a new format is one more line
# here plus its branch in load() and analyse().
FORMATS = ((0x0A04, "v2"), (0x0000, "v1"))
ID_IN_NAME = re.compile(r"-id([0-9a-fA-F]{4})(?=[.-])")
CFG_FILES = ("pips-cfg.txt", "cfg-before.txt", "cfg-run.txt", "cfg.txt")


def fail(msg):
    sys.exit("pips-log-decode: " + msg)


def format_of(design):
    """The record format a build writes; None (no design ID) is v1."""
    if design is None:
        return "v1"
    for first, name in FORMATS:
        if design >= first:
            return name
    return "v1"


def parse_design(s):
    """'0x0a04', '0a04' or 'none' -> int or None."""
    s = str(s).strip().lower()
    if s in ("none", "", "unknown", "?"):
        return None
    try:
        return int(s, 16) & 0xFFFF
    except ValueError:
        fail(f"--design-id: '{s}' is not a hex design ID or none")


def detect(path, design=None):
    """Which build wrote a log, and so its format: dict(design_id (int or None),
    design ('0x0a04' or 'none'), format, source). See the module help."""
    if design is not None:
        d, src = parse_design(design), "--design-id"
    else:
        d, src = None, "none found: the encoding from before design IDs"
        m = ID_IN_NAME.search(os.path.basename(path))
        if m:
            d, src = int(m.group(1), 16), "file name"
        else:
            folder = os.path.dirname(os.path.abspath(path))
            for name in CFG_FILES:
                try:
                    with open(os.path.join(folder, name)) as f:
                        ids = [l.split("=", 1)[1].strip() for l in f if l.startswith("design_id=")]
                except OSError:
                    continue
                if ids:
                    d, src = parse_design(ids[0]), name
                    break
    return dict(design_id=d, design="none" if d is None else f"0x{d:04x}",
                format=format_of(d), source=src)


def load(path, scan, fmt=None):
    """(records, trailer dict or None, pad count, file size, problem or None).
    fmt: 'v1' or 'v2', or None to detect() it. Records are tuples in the same
    shape for every format: (addr, length, gap, type, payload_dw, tag, at,
    info, wait); wait is None in v1. Without --scan a file whose last record
    is no trailer is a problem; its records are then walked as --scan does."""
    if fmt is None:
        fmt = detect(path)["format"]
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as f:
        buf = f.read()
    if len(buf) < 16 or len(buf) % 16:
        fail(f"{path}: {len(buf)} bytes, expected a non-zero multiple of 16")
    nslots = len(buf) // 16
    trailer, problem = None, None
    if not scan:
        trailer = TRL.unpack_from(buf, len(buf) - 16)
        if trailer[5] != 0x88:
            problem = f"the last record is not a trailer (info 0x{trailer[5]:02x})"
        elif trailer[0] > nslots - 1:
            problem = f"the trailer says {trailer[0]} records, the file has room for {nslots - 1}"
        if problem:
            trailer, scan = None, True
        else:
            nbody, end = trailer[0], nslots - 1
    if scan:
        n = 0
        while n < nslots:
            info = buf[16 * n + 14]
            if not info & 0x80:
                break                                   # never written
            if (info >> 2) & 3 == KIND_TRAILER:
                trailer = TRL.unpack_from(buf, 16 * n)
                break
            n += 1
        nbody, end = n, n
    if fmt == "v2":
        recs = [(a, ln, g, t & 0xF, pdw, tag, (t >> 4) & 3, info, w)
                for a, ln, g, t, pdw, w, info, tag in
                (REC_V2.unpack_from(buf, 16 * i) for i in range(nbody))]
    else:
        recs = [r[:8] + (None,) for r in (REC_V1.unpack_from(buf, 16 * i) for i in range(nbody))]
    pads = sum(1 for i in range(nbody, end) if buf[16 * i + 14] == 0x8C)
    if trailer:
        trailer = dict(n_records=trailer[0], n_dropped=trailer[1],
                       duration_cycles=trailer[2],
                       stop_reason=STOP.get(trailer[3], f"unknown({trailer[3]})"))
    return recs, trailer, pads, len(buf), problem


def classify(sm, problem, region_bytes):
    """Whether the recording is whole: (status, why).
      FULL        it ran until the region filled: region_bytes of records + trailer
      CUT         it was ended (log_enable low) before the region filled
      +DROPS      some TLPs were lost to logger FIFO overflow (holes, per port)
      NO_TRAILER  the recording never closed: the DMA did not finish
      BAD         the file and its trailer disagree"""
    t = sm["trailer"]
    if problem:
        return "BAD", problem
    if not t:
        return "NO_TRAILER", "no trailer: the recording did not close (DMA not finished)"
    if sm["bad_records"]:
        return "BAD", f"unexpected records: {sm['bad_records']}"
    if t["stop_reason"] == "region_full":
        if region_bytes and sm["bytes"] != region_bytes:
            return "BAD", f"region full, but {sm['bytes']} bytes, not {region_bytes}"
        status, why = "FULL", "ran until the region filled"
    elif t["stop_reason"] == "enable_low":
        status, why = "CUT", "ended (log_enable low) before the region filled"
    else:
        return "BAD", f"stop reason {t['stop_reason']}"
    if t["n_dropped"]:
        status += "+DROPS"
        why += f"; {t['n_dropped']} TLP records dropped (logger FIFO overflow)"
    return status, why


def write_rpt(path, sm):
    """key: value lines for the runners' reports. The status, design ID and
    format are text; every other value is a number, which the results
    scripts collect."""
    t = sm["trailer"] or {}
    lines = [f"status: {sm['status']}",
             f"design_id: {sm['design_id']}",
             f"log_format: {sm['log_format']}",
             f"pips_full: {int(sm['status'].startswith('FULL'))}",
             f"pips_bytes: {sm['bytes']}",
             f"pips_records: {sm['records']}",
             f"pips_dropped: {t.get('n_dropped', 0)}",
             f"pips_duration_us: {sm['duration_us'] or 0:.1f}"]
    for name, p in sm["ports"].items():
        lines += [f"pips_{name}_tlp: {p['tlp']}",
                  f"pips_{name}_mwr_gbps: {p['mwr_gbps'] or 0:.3f}",
                  f"pips_{name}_gap_mean: {p['gap_mean'] if p['gap_mean'] is not None else 0:.2f}"]
        if sm["log_format"] != "v1":
            for k in ("wait_mean", "wait_p50", "wait_p99"):
                lines.append(f"pips_{name}_{k}: {p[k] if p[k] is not None else 0:.1f}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    return sorted_vals[min(len(sorted_vals) - 1, int(p / 100 * len(sorted_vals)))]


def mean(vals):
    return sum(vals) / len(vals) if vals else None


def analyse(recs, fmt="v1"):
    """Per-port statistics, unexpected records, and the CSV rows. v1: each
    record counts for its port. v2: each record counts for its input port
    and for out; gaps (measured on the output) only for out."""
    v2 = fmt == "v2"
    ports = {p: dict(tlp=0, dropped=0, types=collections.Counter(),
                     at=collections.Counter(), payload=collections.Counter(),
                     mwr_bytes=0, mwr_bytes_sat=0, lengths=[], len_sat=0,
                     gaps=[], gap_sat=0, tags=set(), addr={}, waits=[], wait_sat=0)
             for p in PORTS}
    bad = collections.Counter()
    rows = []
    t_lb = {p: 0 for p in PORTS}
    out_eop, seg = None, 0                          # v2 timeline
    for i, (addr, length, gap, typ, pdw, tag, at, info, wait) in enumerate(recs):
        kind, port = (info >> 2) & 3, info & 3
        if not info & 0x80 or kind not in (KIND_TLP, KIND_DROP) or port > (1 if v2 else 2):
            bad[f"info 0x{info:02x}"] += 1
            continue
        name = PORTS[port]
        names = (name, "out") if v2 else (name,)
        if kind == KIND_DROP:
            for n in names:
                ports[n]["dropped"] += 1
            if v2:
                seg += 1                            # no gap or length: times after it are bounds
                rows.append((i, name, "dropped") + ("",) * 10 + (seg,))
            else:
                rows.append((i, name, "dropped", "", "", "", "", "", "", "", ""))
            continue
        tname = TYPES[typ & 0xF]
        for n in names:
            s = ports[n]
            s["tlp"] += 1
            s["types"][tname] += 1
            s["at"][AT[at & 3]] += 1
            s["tags"].add(tag)
            if length == 255:
                s["len_sat"] += 1
            else:
                s["lengths"].append(length)
            if not v2 or n == "out":
                if gap == 255:
                    s["gap_sat"] += 1
                else:
                    s["gaps"].append(gap)
            if v2:
                if wait == WAIT_SAT:
                    s["wait_sat"] += 1
                else:
                    s["waits"].append(wait)
            if tname == "MWr":
                s["payload"][pdw] += 1
                s["mwr_bytes"] += 4 * pdw
                s["mwr_bytes_sat"] += pdw == 255
            if tname in ("MRd", "MWr"):
                lo, hi = s["addr"].get(tname, (addr, addr))
                s["addr"][tname] = (min(lo, addr), max(hi, addr))
        if v2:
            if out_eop is None:
                out_sop = 0
            else:
                out_sop = out_eop + 1 + gap
                seg += gap == 255
            out_eop = out_sop + length - 1
            rows.append((i, name, "tlp", tname, f"0x{addr:x}", length, gap, pdw, tag,
                         at & 3, wait, out_sop, out_sop - wait, seg))
        else:
            t_lb[name] += gap + length
            rows.append((i, name, "tlp", tname, f"0x{addr:x}", length, gap, pdw, tag,
                         at & 3, t_lb[name]))
    return ports, bad, rows


def summarise(path, nbytes, recs, trailer, pads, ports, bad, fi):
    dur = trailer["duration_cycles"] if trailer else 0
    secs = dur / CLOCK_HZ if dur else None
    out = dict(file=path, design_id=fi["design"], log_format=fi["format"],
               design_source=fi["source"], bytes=nbytes, records=len(recs), pad_records=pads,
               trailer=trailer, duration_us=secs * 1e6 if secs else None,
               bad_records=dict(bad), ports={})
    for name in PORTS:
        s = ports[name]
        gaps, lens, waits = sorted(s["gaps"]), sorted(s["lengths"]), sorted(s["waits"])
        v2 = fi["format"] == "v2"
        out["ports"][name] = dict(
            description=PORT_DESC[fi["format"]][name], tlp=s["tlp"], dropped=s["dropped"],
            types=dict(s["types"].most_common()), at=dict(s["at"].most_common()),
            mwr_payload_dw=dict(sorted(s["payload"].items())),
            mwr_bytes=s["mwr_bytes"], mwr_bytes_saturated=s["mwr_bytes_sat"],
            mwr_gbps=s["mwr_bytes"] * 8 / secs / 1e9 if secs else None,
            tlp_per_us=s["tlp"] / (secs * 1e6) if secs else None,
            len_mean=mean(lens), len_max=lens[-1] if lens else None, len_saturated=s["len_sat"],
            gap_mean=mean(gaps), gap_p50=pct(gaps, 50), gap_p99=pct(gaps, 99),
            gap_saturated=s["gap_sat"], distinct_tags=len(s["tags"]),
            wait_mean=mean(waits) if v2 else None, wait_p50=pct(waits, 50) if v2 else None,
            wait_p99=pct(waits, 99) if v2 else None,
            wait_max=(WAIT_SAT if s["wait_sat"] else waits[-1] if waits else None) if v2 else None,
            wait_saturated=s["wait_sat"] if v2 else None,
            addr_ranges={t: [f"0x{lo:x}", f"0x{hi:x}"] for t, (lo, hi) in s["addr"].items()})
    return out


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def print_summary(sm):
    t = sm["trailer"]
    print(f"log {sm['file']}: {sm['bytes']} bytes, {sm['records']} records")
    print(f"  design {sm['design_id']}, record format {sm['log_format']} "
          f"(design ID from: {sm['design_source']})")
    if t:
        print(f"  trailer: {t['n_records']} records, {t['n_dropped']} dropped, stop "
              f"{t['stop_reason']}, {t['duration_cycles']} cycles = "
              f"{fmt(sm['duration_us'], '.1f')} us at {CLOCK_HZ / 1e6:.0f} MHz")
    else:
        print("  no trailer (--scan): the recording did not close")
    if sm["pad_records"]:
        print(f"  {sm['pad_records']} pad records before the trailer")
    if sm["bad_records"]:
        print(f"  UNEXPECTED records: {sm['bad_records']}")
    print()
    print(f"{'port':5} {'':42} {'TLPs':>8} {'drop':>6} {'MRd':>8} {'MWr':>8} {'other':>6} "
          f"{'MWr MB':>8} {'MWr Gbps':>8} {'TLP/us':>7} {'beats':>5} {'gap mean/p50/p99 (sat)':>24}")
    for name, p in sm["ports"].items():
        other = p["tlp"] - p["types"].get("MRd", 0) - p["types"].get("MWr", 0)
        gap = (f"{fmt(p['gap_mean'], '.1f')}/{fmt(p['gap_p50'], 'd')}/"
               f"{fmt(p['gap_p99'], 'd')} ({p['gap_saturated']})")
        print(f"{name:5} {p['description']:42} {p['tlp']:8d} {p['dropped']:6d} "
              f"{p['types'].get('MRd', 0):8d} {p['types'].get('MWr', 0):8d} {other:6d} "
              f"{p['mwr_bytes'] / 1e6:8.2f} {fmt(p['mwr_gbps'], '8.2f')} "
              f"{fmt(p['tlp_per_us'], '7.2f')} {fmt(p['len_mean'], '5.1f')} {gap:>24}")
    if sm["log_format"] == "v2":
        print()
        print(f"{'port':5} {'time in the batcher, cycles: mean/p50/p99/max (sat)':>52} {'us mean/p99':>14}")
        for name, p in sm["ports"].items():
            if not p["tlp"]:
                continue
            w = (f"{fmt(p['wait_mean'], '.1f')}/{fmt(p['wait_p50'], 'd')}/{fmt(p['wait_p99'], 'd')}/"
                 f"{fmt(p['wait_max'], 'd')} ({p['wait_saturated']})")
            us = (f"{fmt(p['wait_mean'] and p['wait_mean'] / CLOCK_HZ * 1e6, '.2f')}/"
                  f"{fmt(p['wait_p99'] and p['wait_p99'] / CLOCK_HZ * 1e6, '.2f')}")
            print(f"{name:5} {w:>52} {us:>14}")
    print()
    for name, p in sm["ports"].items():
        if not p["tlp"]:
            continue
        print(f"{name}: types {p['types']}  AT {p['at']}  distinct tags {p['distinct_tags']}")
        if p["mwr_payload_dw"]:
            top = sorted(p["mwr_payload_dw"].items(), key=lambda kv: -kv[1])[:6]
            print("     MWr payload DW (top): " + ", ".join(f"{dw}:{n}" for dw, n in top)
                  + (f"  ({p['mwr_bytes_saturated']} at 255 = >=1020 B)"
                     if p["mwr_bytes_saturated"] else ""))
        for typ, (lo, hi) in p["addr_ranges"].items():
            print(f"     {typ} addresses {lo} .. {hi}")
    ins = sm["ports"]["in0"]["tlp"] + sm["ports"]["in1"]["tlp"]
    if sm["log_format"] == "v1" and ins:
        print(f"\nout / (in0 + in1) TLPs: {sm['ports']['out']['tlp']} / {ins} = "
              f"{sm['ports']['out']['tlp'] / ins:.3f}")
        if not sm["ports"]["out"]["tlp"] and not sm["ports"]["out"]["dropped"]:
            print("NOTE: no out records. A log from design 0x0a04 or later (format v2) read as v1"
                  " looks like this: give its design ID (--design-id)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", help="the dump: pips log-dump FILE (.gz is read too)")
    ap.add_argument("--scan", action="store_true",
                    help="no trailer: walk records until one was never written")
    ap.add_argument("--region-bytes", type=lambda s: int(s, 0),
                    help="the log region's size (pips info LOG_BYTES): a FULL log must be "
                         "exactly this long")
    ap.add_argument("--design-id", metavar="ID",
                    help="the design ID of the build that wrote the log (0x0a04, or none), "
                         "instead of finding it (see Design ID in --help)")
    ap.add_argument("--csv", help="one line per record, after a '# design_id=' line")
    ap.add_argument("--json", help="the summary as JSON")
    ap.add_argument("--rpt", help="status and key numbers as 'key: value' lines")
    a = ap.parse_args()
    fi = detect(a.log, a.design_id)

    recs, trailer, pads, nbytes, problem = load(a.log, a.scan, fi["format"])
    ports, bad, rows = analyse(recs, fi["format"])
    sm = summarise(a.log, nbytes, recs, trailer, pads, ports, bad, fi)
    if trailer:
        drops = sum(sm["ports"][p]["dropped"] for p in ("in0", "in1", "out")
                    if fi["format"] == "v1" or p == "out")
        if drops != trailer["n_dropped"]:
            sm["bad_records"]["dropped_count_mismatch"] = f"{drops} vs trailer {trailer['n_dropped']}"
    sm["status"], sm["status_why"] = classify(sm, problem, a.region_bytes)
    print(f"status: {sm['status']}: {sm['status_why']}")
    print_summary(sm)
    if a.rpt:
        write_rpt(a.rpt, sm)
    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow((f"# design_id={sm['design_id']} log_format={sm['log_format']} "
                        f"(design ID from: {sm['design_source']})",))
            if fi["format"] == "v2":
                w.writerow(("idx", "port", "kind", "type", "addr", "len_beats", "gap", "payload_dw",
                            "tag", "at", "wait", "out_sop", "in_sop", "seg"))
            else:
                w.writerow(("idx", "port", "kind", "type", "addr", "len_beats", "gap", "payload_dw",
                            "tag", "at", "t_lb"))
            w.writerows(rows)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(sm, f, indent=1)
            f.write("\n")
    return 1 if sm["status"] == "BAD" else 0


if __name__ == "__main__":
    sys.exit(main())
