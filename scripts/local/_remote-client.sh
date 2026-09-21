#!/bin/bash
# Runs ON THE CLIENT (Broadwell), invoked over ssh by run-traffic.sh.
# Launches N iperf3 senders, waits for them, prints a machine-readable summary.
#
# argv: server_ip num_flows base_port duration cca bandwidth cores client_intf
set -u

SERVER_IP="$1"; NUM_FLOWS="$2"; BASE_PORT="$3"; DURATION="$4"
CCA="$5"; BANDWIDTH="$6"; CORES="$7"; CLIENT_INTF="$8"

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/_common.sh"

# Auto-pick NUMA-local cores if the caller did not specify.
if [ "$CORES" = "auto" ] || [ -z "$CORES" ]; then
    CORES=$(pick_cores "$CLIENT_INTF" "$NUM_FLOWS")
fi
IFS=',' read -ra CORE_LIST <<< "$CORES"

WORK=$(mktemp -d /tmp/fands-client.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "CLIENT_CORES $CORES"
echo "CLIENT_HOST $(hostname)"

pids=()
for ((i = 0; i < NUM_FLOWS; i++)); do
    core=${CORE_LIST[$((i % ${#CORE_LIST[@]}))]}
    port=$((BASE_PORT + i))
    args=(-c "$SERVER_IP" -p "$port" -t "$DURATION" -C "$CCA" --json)
    [ "$BANDWIDTH" != "0" ] && args+=(-b "$BANDWIDTH")
    taskset -c "$core" iperf3 "${args[@]}" > "$WORK/flow-$i.json" 2>"$WORK/flow-$i.err" &
    pids+=($!)
done

fail=0
for p in "${pids[@]}"; do wait "$p" || fail=$((fail+1)); done
[ "$fail" -gt 0 ] && echo "CLIENT_FAILED_FLOWS $fail"

# Emit per-flow and aggregate receiver-side throughput.
python3 - "$WORK" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
total = 0.0
retrans = 0
n = 0
for f in sorted(glob.glob(os.path.join(d, "flow-*.json"))):
    try:
        with open(f) as fh:
            j = json.load(fh)
        end = j["end"]
        bps = end.get("sum_received", end.get("sum_sent", {})).get("bits_per_second", 0.0)
        rt = end.get("sum_sent", {}).get("retransmits", 0) or 0
        total += bps
        retrans += rt
        n += 1
        print("FLOW %s %.0f" % (os.path.basename(f).split('-')[1].split('.')[0], bps))
    except Exception as e:
        print("FLOW_ERROR %s %s" % (os.path.basename(f), e))
print("FLOWS_OK %d" % n)
print("TOTAL_BPS %.0f" % total)
print("TOTAL_GBPS %.3f" % (total / 1e9))
print("RETRANSMITS %d" % retrans)
PY

# Surface any stderr so failures are not silent.
for e in "$WORK"/flow-*.err; do
    [ -s "$e" ] && { echo "CLIENT_STDERR $(basename "$e"):"; sed 's/^/  /' "$e"; }
done
exit 0
