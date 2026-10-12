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

The first line says whether the recording is whole: FULL (it ran until the
region filled), CUT (ended before), either with +DROPS (TLPs lost to logger
FIFO overflow), NO_TRAILER (it never closed), or BAD (file and trailer
disagree; exit status 1). See classify().

The file holds exactly the bytes the DMA wrote, so the trailer is its last
16 bytes. Record format: telemetry_dma_format.md §4 (AXI4-switch repo); field
meanings: axi4_telemetry_decode.md §4, §8. Ports, as wired in pips.tcl:
in0 = requests from downstream port one (10ee:b348), in1 = from downstream
port zero (10ee:b148), out = the batched stream sent to the host.

Records are in end-of-packet order across the three ports. Dropped records
(FIFO overflow) keep their slot in their port's sequence but carry no data.
pkt_gap, pkt_length and payload_dw saturate at 255; saturated values are
counted apart and left out of means and percentiles. The CSV's t_lb column is
a per-port lower bound on time since the first record of that port, in
cycles: the running sum of gap + length (stalls inside a packet are not seen).
"""
import argparse
import collections
import csv
import gzip
import json
import struct
import sys

REC = struct.Struct("<QBBBBBBBB")
TRL = struct.Struct("<IIIBBBB")
KIND_TLP, KIND_DROP, KIND_TRAILER, KIND_PAD = range(4)
PORTS = ("in0", "in1", "out")
PORT_DESC = {"in0": "from downstream port one (b348)",
             "in1": "from downstream port zero (b148)",
             "out": "batched, sent to the host"}
TYPES = ("MRd", "MWr", "IORd", "IOWr", "FetchAdd", "Swap", "CAS", "LockedRd",
         "Cfg0Rd", "Cfg1Rd", "Cfg0Wr", "Cfg1Wr", "Msg", "VendorMsg", "ATSMsg",
         "Rsvd")
AT = ("untranslated", "translation_req", "translated", "reserved")
STOP = {1: "enable_low", 2: "region_full"}
CLOCK_HZ = 250e6                 # upstream user_clk, the logger's clock


def fail(msg):
    sys.exit("pips-log-decode: " + msg)


def load(path, scan):
    """(records, trailer dict or None, pad count, file size, problem or None).
    Records are tuples: (addr, length, gap, type, payload_dw, tag, at, info,
    reserved). Without --scan a file whose last record is no trailer is a
    problem; its records are then walked as --scan does."""
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
    recs = [REC.unpack_from(buf, 16 * i) for i in range(nbody)]
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
    """key: value lines for run-dualssd-experiment.sh's reports. The status is
    text; every other value is a number, which dualssd-results.py collects."""
    t = sm["trailer"] or {}
    lines = [f"status: {sm['status']}",
             f"pips_full: {int(sm['status'].startswith('FULL'))}",
             f"pips_bytes: {sm['bytes']}",
             f"pips_records: {sm['records']}",
             f"pips_dropped: {t.get('n_dropped', 0)}",
             f"pips_duration_us: {sm['duration_us'] or 0:.1f}"]
    for name, p in sm["ports"].items():
        lines += [f"pips_{name}_tlp: {p['tlp']}",
                  f"pips_{name}_mwr_gbps: {p['mwr_gbps'] or 0:.3f}",
                  f"pips_{name}_gap_mean: {p['gap_mean'] if p['gap_mean'] is not None else 0:.2f}"]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    return sorted_vals[min(len(sorted_vals) - 1, int(p / 100 * len(sorted_vals)))]


def mean(vals):
    return sum(vals) / len(vals) if vals else None


def analyse(recs):
    ports = {p: dict(tlp=0, dropped=0, types=collections.Counter(),
                     at=collections.Counter(), payload=collections.Counter(),
                     mwr_bytes=0, mwr_bytes_sat=0, lengths=[], len_sat=0,
                     gaps=[], gap_sat=0, tags=set(), addr={})
             for p in PORTS}
    bad = collections.Counter()
    rows = []
    t_lb = {p: 0 for p in PORTS}
    for i, (addr, length, gap, typ, pdw, tag, at, info, _rsvd) in enumerate(recs):
        kind, port = (info >> 2) & 3, info & 3
        if not info & 0x80 or kind not in (KIND_TLP, KIND_DROP) or port > 2:
            bad[f"info 0x{info:02x}"] += 1
            continue
        name = PORTS[port]
        s = ports[name]
        if kind == KIND_DROP:
            s["dropped"] += 1
            rows.append((i, name, "dropped", "", "", "", "", "", "", "", ""))
            continue
        s["tlp"] += 1
        tname = TYPES[typ & 0xF]
        s["types"][tname] += 1
        s["at"][AT[at & 3]] += 1
        s["tags"].add(tag)
        if length == 255:
            s["len_sat"] += 1
        else:
            s["lengths"].append(length)
        if gap == 255:
            s["gap_sat"] += 1
        else:
            s["gaps"].append(gap)
        if tname == "MWr":
            s["payload"][pdw] += 1
            s["mwr_bytes"] += 4 * pdw
            s["mwr_bytes_sat"] += pdw == 255
        if tname in ("MRd", "MWr"):
            lo, hi = s["addr"].get(tname, (addr, addr))
            s["addr"][tname] = (min(lo, addr), max(hi, addr))
        t_lb[name] += gap + length
        rows.append((i, name, "tlp", tname, f"0x{addr:x}", length, gap, pdw, tag,
                     at & 3, t_lb[name]))
    return ports, bad, rows


def summarise(path, nbytes, recs, trailer, pads, ports, bad):
    dur = trailer["duration_cycles"] if trailer else 0
    secs = dur / CLOCK_HZ if dur else None
    out = dict(file=path, bytes=nbytes, records=len(recs), pad_records=pads,
               trailer=trailer, duration_us=secs * 1e6 if secs else None,
               bad_records=dict(bad), ports={})
    for name in PORTS:
        s = ports[name]
        gaps, lens = sorted(s["gaps"]), sorted(s["lengths"])
        out["ports"][name] = dict(
            description=PORT_DESC[name], tlp=s["tlp"], dropped=s["dropped"],
            types=dict(s["types"].most_common()), at=dict(s["at"].most_common()),
            mwr_payload_dw=dict(sorted(s["payload"].items())),
            mwr_bytes=s["mwr_bytes"], mwr_bytes_saturated=s["mwr_bytes_sat"],
            mwr_gbps=s["mwr_bytes"] * 8 / secs / 1e9 if secs else None,
            tlp_per_us=s["tlp"] / (secs * 1e6) if secs else None,
            len_mean=mean(lens), len_max=lens[-1] if lens else None, len_saturated=s["len_sat"],
            gap_mean=mean(gaps), gap_p50=pct(gaps, 50), gap_p99=pct(gaps, 99),
            gap_saturated=s["gap_sat"], distinct_tags=len(s["tags"]),
            addr_ranges={t: [f"0x{lo:x}", f"0x{hi:x}"] for t, (lo, hi) in s["addr"].items()})
    return out


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def print_summary(sm):
    t = sm["trailer"]
    print(f"log {sm['file']}: {sm['bytes']} bytes, {sm['records']} records")
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
    print(f"{'port':5} {'':33} {'TLPs':>8} {'drop':>6} {'MRd':>8} {'MWr':>8} {'other':>6} "
          f"{'MWr MB':>8} {'MWr Gbps':>8} {'TLP/us':>7} {'beats':>5} {'gap mean/p50/p99 (sat)':>24}")
    for name, p in sm["ports"].items():
        other = p["tlp"] - p["types"].get("MRd", 0) - p["types"].get("MWr", 0)
        gap = (f"{fmt(p['gap_mean'], '.1f')}/{fmt(p['gap_p50'], 'd')}/"
               f"{fmt(p['gap_p99'], 'd')} ({p['gap_saturated']})")
        print(f"{name:5} {p['description']:33} {p['tlp']:8d} {p['dropped']:6d} "
              f"{p['types'].get('MRd', 0):8d} {p['types'].get('MWr', 0):8d} {other:6d} "
              f"{p['mwr_bytes'] / 1e6:8.2f} {fmt(p['mwr_gbps'], '8.2f')} "
              f"{fmt(p['tlp_per_us'], '7.2f')} {fmt(p['len_mean'], '5.1f')} {gap:>24}")
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
    if ins:
        print(f"\nout / (in0 + in1) TLPs: {sm['ports']['out']['tlp']} / {ins} = "
              f"{sm['ports']['out']['tlp'] / ins:.3f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", help="the dump: pips log-dump FILE (.gz is read too)")
    ap.add_argument("--scan", action="store_true",
                    help="no trailer: walk records until one was never written")
    ap.add_argument("--region-bytes", type=lambda s: int(s, 0),
                    help="the log region's size (pips info LOG_BYTES): a FULL log must be "
                         "exactly this long")
    ap.add_argument("--csv", help="one line per record")
    ap.add_argument("--json", help="the summary as JSON")
    ap.add_argument("--rpt", help="status and key numbers as 'key: value' lines")
    a = ap.parse_args()

    recs, trailer, pads, nbytes, problem = load(a.log, a.scan)
    ports, bad, rows = analyse(recs)
    sm = summarise(a.log, nbytes, recs, trailer, pads, ports, bad)
    if trailer:
        drops = sum(p["dropped"] for p in sm["ports"].values())
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
