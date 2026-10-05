#!/bin/bash
source setup-server.sh

#default values
SCRIPT_NAME="record-host-metrics"

# DEP_DIR="/home/schai"
OUT_DIR="test"
DURATION_S=30
TYPE=1
CPU_UTIL_REPORTING=1  
CPU_MASK=0
RETX_REPORTING=1
TCP_LOG_REPORTING=0
FLAMEGRAPH_REPORTING=0
BANDWIDTH_REPORTING=1
PCIE_REPORTING=1
MEMBW_REPORTING=1
IIO_REPORTING=0
PFC_REPORTING=0
# INTF=enp8s0
PCIE_PATTERN="Socket1,IIO Stack 0 - PCIe0,Part0"

# Where pcm-iio / pcm-memory live, and the core they run on. Defaults are icx's
# (a source build under PCM_DIR, core 15); setup-server.sh can override both,
# e.g. bigserver uses an installed PCM in /usr/local/bin.
PCM_BIN="${PCM_BIN:-$PCM_DIR/build/bin}"
PCM_CORE="${PCM_CORE:-15}"

# Selects the pcm-iio CSV layout parse_pciebw* expects (opCode-6-<model>.txt).
CPU_MODEL=$(awk -F: '/^model[[:space:]]*:/ { gsub(/ /, "", $2); print $2; exit }' /proc/cpuinfo)

cur_dir=$PWD

help()
{
    echo "Usage: $SCRIPT_NAME [ --dep (dependency directory)]
               [ -o | --outdir (name of the output directory which will store the records; default=test) ] 
               [ --dur (duration in seconds to record each metric; default=30s) ] 
               [ --cpu-util (=0/1, disable/enable recording cpu utilization) ) ] 
               [ -c | --cores (comma separated values of cpu cores to log utilization, eg., '0,4,8,12') ) ] 
               [ --retx (=0/1, disable/enable recording retransmission rate (should be done at TCP senders) ) ] 
               [ --tcplog (=0/1, disable/enable recording TCP log (should be done at TCP senders) ) ] 
               [ --bw (=0/1, disable/enable recording app-level bandwidth ) ] 
               [ -f | --flame (=0/1, disable/enable recording flamegraph (for cores specified via -C/--cores option) ) ] 
               [ --pcie (=0/1, disable/enable recording PCIe bandwidth) ] 
               [ --membw (=0/1, disable/enable recording memory bandwidth) ] 
               [ --iio (=0/1, disable/enable recording IIO occupancy) ] 
               [ --pfc (=0/1, disable/enable recording PFC pause triggers) ] 
               [ --intf (interface name, over which to record PFC triggers) ] 
               [ -t | --type (=0/1, experiment type -- 0 for TCP, 1 for RDMA) ]
	       [ --pattern ] 
               [ -h | --help  ]"
    exit 2
}

SHORT=o:,c:,f:,t:,h
LONG=dep:,outdir:,dur:,cpu-util:,cores:,retx:,tcplog:,bw:,flame:,pcie:,membw:,iio:,pfc:,intf:,type:,pattern:,help
OPTS=$(getopt -a -n $SCRIPT_NAME --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$OPTS"

#TODO: add input config file to specify NUMA node and PCIe slot for PCIe, MemBW and IIO occupancy logging
while :; do
  case "$1" in
     --dep) DEP_DIR="$2"; shift 2 ;;
    -o | --outdir) OUT_DIR="$2"; shift 2 ;;
    --dur) DURATION_S="$2"; shift 2 ;;
    --cpu-util) CPU_UTIL_REPORTING="$2"; shift 2 ;; 
    -c | --cores) CPU_MASK="$2"; shift 2 ;;
    --retx) RETX_REPORTING="$2"; shift 2 ;;
    --tcplog) TCP_LOG_REPORTING="$2"; shift 2 ;;
    --bw) BANDWIDTH_REPORTING="$2"; shift 2 ;;
    -f | --flame) FLAMEGRAPH_REPORTING="$2"; shift 2 ;;
    --pcie) PCIE_REPORTING="$2"; shift 2 ;;
    --membw) MEMBW_REPORTING="$2"; shift 2 ;;
    --iio) IIO_REPORTING="$2"; shift 2 ;;
    --pfc) PFC_REPORTING="$2"; shift 2 ;;
    --intf) INTF="$2"; shift 2 ;;
    --pattern) PCIE_PATTERN="$2"; shift 2 ;;
    -t | --type) TYPE="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

mkdir -p logs #Directory to store collected logs
mkdir -p logs/$OUT_DIR #Directory to store collected logs
mkdir -p reports #Directory to store parsed metrics
mkdir -p reports/$OUT_DIR #Directory to store parsed metrics

function dump_netstat() {
    local SLEEP_TIME=$1

    echo "Before measurement"
    netstat -s
    echo "Sleeping..."
    sleep $SLEEP_TIME
    echo "After measurement"
    netstat -s
}

function dump_pciebw() {
    sudo modprobe msr
    # The CSV holds every stack's counters each second; pcm-iio.out keeps the
    # version banner and any warning, which otherwise only reach the terminal.
    sudo taskset -c $PCM_CORE $PCM_BIN/pcm-iio 1 -csv=logs/$OUT_DIR/pcie.csv \
        > logs/$OUT_DIR/pcm-iio.out 2>&1 &
}

# ICX (family 6, model 106) pcm-iio CSV layout, from opCode-6-106.txt:
#
#   1 Date  2 Time  3 Socket  4 Name  5 Part
#   6 IB write        7 IB read       8 OB read   9 OB write
#  10 IOTLB Lookup   11 IOTLB Miss   12 Ctxt Cache Hit
#  13 512G Cache Hit 14 1G Cache Hit 15 2M Cache Hit  16 4K Cache Hit
#  17 IOMMU Mem Access
#
# The column OFFSETS below are correct for ICX. The names this function used to
# write were inherited from the Skylake opCode-85.txt event set and did not
# match: what was emitted as L1/L2/L3_Miss is really 512G/1G/2M page-walk-cache
# HITS, CTXT_Miss is really a Ctxt Cache HIT, Mem_Read is really 4K Cache Hit,
# and IOTLB_hits is really IOTLB Lookup (= hits + misses). Only IOTLB_misses and
# the two bandwidth columns were ever named correctly.
#
# Correct names are written first. The old names are then written as aliases so
# existing parsers and plot scripts keep working on new runs; they are marked
# LEGACY and should not be used in new analysis.

_pcie_avg() {   # <column> -> mean over samples, 0 if no rows matched
    grep "$PCIE_PATTERN" "logs/$OUT_DIR/pcie.csv" 2>/dev/null \
      | awk -F ',' -v c="$1" \
            '{ sum += $c; n++ } END { if (n > 0) printf "%.3f", sum/n; else printf "0" }'
}

_pcie_gbps() {  # <column> -> mean bytes/s converted to Gb/s, 0 if no rows
    grep "$PCIE_PATTERN" "logs/$OUT_DIR/pcie.csv" 2>/dev/null \
      | awk -F ',' -v c="$1" \
            '{ sum += $c/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum/n*8; else printf "0" }'
}

function parse_pciebw() {
    local R="reports/$OUT_DIR/pcie.rpt"

    if ! grep -q "$PCIE_PATTERN" "logs/$OUT_DIR/pcie.csv" 2>/dev/null; then
        echo "WARNING: PCIE_PATTERN '$PCIE_PATTERN' matched no rows in pcie.csv." >&2
        echo "         Every PCIe/IOMMU metric will be 0. Check the pattern with" >&2
        echo "         utils/discover-pcie-topology.sh (section 3)." >&2
    fi

    local lookups misses
    lookups=$(_pcie_avg 10)
    misses=$(_pcie_avg 11)

    {
        echo "PCIe_wr_tput: $(_pcie_gbps 6)"
        echo "PCIe_rd_tput: $(_pcie_gbps 7)"

        # --- correctly named ICX counters ---
        echo "IOTLB_lookups: $lookups"
        echo "IOTLB_misses: $misses"
        # Lookup - Miss. The hardware exposes no direct IOTLB-hit counter here.
        echo "IOTLB_hits_derived: $(awk -v l="$lookups" -v m="$misses" \
            'BEGIN{ d=l-m; if (d<0) d=0; printf "%.3f", d }')"
        echo "CTXT_cache_hits: $(_pcie_avg 12)"
        echo "PWC_512G_hits: $(_pcie_avg 13)"
        echo "PWC_1G_hits: $(_pcie_avg 14)"
        echo "PWC_2M_hits: $(_pcie_avg 15)"
        echo "PWC_4K_hits: $(_pcie_avg 16)"
        echo "IOMMU_mem_access: $(_pcie_avg 17)"

        # --- LEGACY aliases: names are wrong, kept only for old consumers ---
        echo "IOTLB_hits: $lookups"
        echo "CTXT_Miss: $(_pcie_avg 12)"
        echo "L1_Miss: $(_pcie_avg 13)"
        echo "L2_Miss: $(_pcie_avg 14)"
        echo "L3_Miss: $(_pcie_avg 15)"
        echo "Mem_Read: $(_pcie_avg 16)"
    } > "$R"
}

# SKX / CLX (family 6, model 85) pcm-iio CSV layout, from opCode-6-85.txt --
# the paper's own event set, so on this CPU the paper's names are the right
# ones and are written as-is:
#
#   1 Date  2 Time  3 Socket  4 Name  5 Part
#   6 IB write   7 IB read   8 OB read   9 OB write
#  10 IOTLB Hit 11 IOTLB Miss 12 VT-d CTXT Miss
#  13 VT-d L1 Miss 14 VT-d L2 Miss 15 VT-d L3 Miss 16 VT-d Mem Read
#
# Columns are looked up by name in the CSV header, with the positions above as
# the fallback, so a different event file cannot silently shift them the way
# the Ice Lake file once did.
#
# Bandwidth is per Part, so it comes from PCIE_PATTERN's row. The VT-d events
# are per stack (vname=Total) and pcm-iio prints them on the stack's Part0 row
# whatever Part the device is on, so they come from that row.

_skx_col() {    # <event name> <fallback column> -> column number
    local c
    c=$(awk -F ',' -v n="$1" '$1 == "Date" {
            for (i = 1; i <= NF; i++) { f = $i; gsub(/^ +| +$/, "", f); if (f == n) { print i; exit } }
            exit }' "logs/$OUT_DIR/pcie.csv" 2>/dev/null)
    if [ -z "$c" ] && grep -q '^Date,' "logs/$OUT_DIR/pcie.csv" 2>/dev/null; then
        echo "WARNING: pcie.csv header has no '$1' column; assuming column $2." >&2
    fi
    echo "${c:-$2}"
}

_skx_avg() {    # <row pattern> <column> -> mean over samples, 0 if no rows matched
    grep "$1" "logs/$OUT_DIR/pcie.csv" 2>/dev/null \
      | awk -F ',' -v c="$2" \
            '{ sum += $c; n++ } END { if (n > 0) printf "%.3f", sum/n; else printf "0" }'
}

_skx_gbps() {   # <row pattern> <column> -> mean bytes/s converted to Gb/s
    grep "$1" "logs/$OUT_DIR/pcie.csv" 2>/dev/null \
      | awk -F ',' -v c="$2" \
            '{ sum += $c/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum/n*8; else printf "0" }'
}

function parse_pciebw_skx() {
    local R="reports/$OUT_DIR/pcie.rpt"
    local vtd
    vtd=$(printf '%s' "$PCIE_PATTERN" | sed 's/Part[0-9].*$/Part0/')

    if ! grep -q "$PCIE_PATTERN" "logs/$OUT_DIR/pcie.csv" 2>/dev/null; then
        echo "WARNING: PCIE_PATTERN '$PCIE_PATTERN' matched no rows in pcie.csv." >&2
        echo "         Every PCIe/IOMMU metric will be 0. Find the right row with" >&2
        echo "         sudo bash utils/discover-ssd-pcie.sh" >&2
    fi

    {
        echo "cpu_model: 85"
        echo "PCIe_wr_tput: $(_skx_gbps "$PCIE_PATTERN" "$(_skx_col 'IB write' 6)")"
        echo "PCIe_rd_tput: $(_skx_gbps "$PCIE_PATTERN" "$(_skx_col 'IB read' 7)")"
        echo "IOTLB_hits: $(_skx_avg "$vtd" "$(_skx_col 'IOTLB Hit' 10)")"
        echo "IOTLB_misses: $(_skx_avg "$vtd" "$(_skx_col 'IOTLB Miss' 11)")"
        echo "CTXT_Miss: $(_skx_avg "$vtd" "$(_skx_col 'VT-d CTXT Miss' 12)")"
        echo "L1_Miss: $(_skx_avg "$vtd" "$(_skx_col 'VT-d L1 Miss' 13)")"
        echo "L2_Miss: $(_skx_avg "$vtd" "$(_skx_col 'VT-d L2 Miss' 14)")"
        echo "L3_Miss: $(_skx_avg "$vtd" "$(_skx_col 'VT-d L3 Miss' 15)")"
        echo "Mem_Read: $(_skx_avg "$vtd" "$(_skx_col 'VT-d Mem Read' 16)")"
    } > "$R"
}

function dump_membw() {
    sudo modprobe msr
    sudo taskset -c $PCM_CORE $PCM_BIN/pcm-memory 1 -columns=5
}

function parse_membw() {
    #TODO: make more general, parse memory bandwidth for any given number of sockets
    echo "Node0_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Mem Read" | awk '{ sum += $8; n++ } END { if (n > 0) printf "%f\n", sum / n; }') > reports/$OUT_DIR/membw.rpt
    echo "Node0_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Mem Write" | awk '{ sum += $7; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node0_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Memory" | awk '{ sum += $6; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Mem Read" | awk '{ sum += $16; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Mem Write" | awk '{ sum += $14; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Memory" | awk '{ sum += $12; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node2_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Mem Read" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node2_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Mem Write" | awk '{ sum += $21; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node2_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Memory" | awk '{ sum += $18; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Mem Read" | awk '{ sum += $32; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Mem Write" | awk '{ sum += $28; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Memory" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
}

function collect_pfc() {
    #assuming PFC is enabled for QoS 0
    sudo ethtool -S $INTF | grep pause > logs/$OUT_DIR/pause.before.log
    sleep $DURATION_S
    sudo ethtool -S $INTF | grep pause > logs/$OUT_DIR/pause.after.log

    pause_before=$(cat logs/$OUT_DIR/pause.before.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_before=$(cat logs/$OUT_DIR/pause.before.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')
    pause_after=$(cat logs/$OUT_DIR/pause.after.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_after=$(cat logs/$OUT_DIR/pause.after.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')

    echo "pauses_before: "$pause_before > logs/$OUT_DIR/pause.log
    echo "pause_duration_before: "$pause_duration_before >> logs/$OUT_DIR/pause.log
    echo "pauses_after: "$pause_after >> logs/$OUT_DIR/pause.log
    echo "pause_duration_after: "$pause_duration_after >> logs/$OUT_DIR/pause.log

    # echo $pause_before, $pause_after
    echo "print(($pause_after - $pause_before)/$DURATION_S)" | lua > reports/$OUT_DIR/pause.rpt

    # echo $pause_duration_before, $pause_duration_after
    echo "print(($pause_duration_after - $pause_duration_before)/$DURATION_S)" | lua >> reports/$OUT_DIR/pause.rpt
}

function compile_if_needed() {
    local source_file=$1
    local executable=$2

    # Check if the executable exists and if the source file is newer
    if [ ! -f "$executable" ] || [ "$source_file" -nt "$executable" ]; then
        echo "Compiling $source_file..."
        gcc -o "$executable" "$source_file"
        if [ $? -eq 0 ]; then
            echo "Compilation successful."
        else
            echo "Compilation failed."
        fi
    else
        echo "No need to recompile."
    fi
}

if [ "$TYPE" -eq 0 ]; then
    echo "Collecting TCP experiment metrics..."

    if [ "$CPU_UTIL_REPORTING" -eq 1 ]; then
      echo "Collecting CPU utilization for cores $CPU_MASK..." 
      sar -P $CPU_MASK 1 1000 > logs/$OUT_DIR/cpu_util.log &
      echo "Recording for $DURATION_S seconds..."
      sleep $DURATION_S
      sudo pkill -9 -x sar
      python3 cpu_util.py logs/$OUT_DIR/cpu_util.log > reports/$OUT_DIR/cpu_util.rpt
    fi

    if [ "$BANDWIDTH_REPORTING" -eq 1 ]; then
      echo "Collecting app bandwidth..."
      echo "Avg_iperf_tput: " $(cat logs/$OUT_DIR/iperf.bw.log | grep "60.*-90.*" | awk  '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }') > reports/$OUT_DIR/iperf.bw.rpt
    fi

    if [ "$RETX_REPORTING" -eq 1 ]; then
      echo "Collecting retransmission rate..."
      dump_netstat $DURATION_S > logs/$OUT_DIR/retx.log
      cat logs/$OUT_DIR/retx.log | grep -E "segment|TCPLostRetransmit" > retx.out
      python3 print_retx_rate.py retx.out $DURATION_S > reports/$OUT_DIR/retx.rpt
    fi

    if [ "$TCP_LOG_REPORTING" -eq 1 ]; then
      echo "Collecting tcplog..."
      cd /sys/kernel/debug/tracing
      echo > trace
      echo 1 > events/tcp/tcp_probe/enable
      sleep 2
      echo 0 > events/tcp/tcp_probe/enable
      sleep 2
      cp trace $cur_dir/logs/$OUT_DIR/tcp.trace.log
      echo > trace
      cd -
      python3 parse_tcplog.py $OUT_DIR
    fi
elif [ "$TYPE" -eq 1 ]; then
  echo "Collecting RDMA experiment metrics..."
  
  if [ "$PFC_REPORTING" -eq 1 ]; then
    echo "Collecting PFC triggers at RDMA server..."
    collect_pfc
  fi
else
  echo "Incorrect type..."
  help
fi

if [ "$PCIE_REPORTING" -eq 1 ]; then
  echo "Collecting PCIe bandwidth..."
  dump_pciebw
  sleep $DURATION_S
  sudo pkill -9 pcm
  if [ "$CPU_MODEL" = "85" ]; then parse_pciebw_skx; else parse_pciebw; fi
fi

if [ "$MEMBW_REPORTING" -eq 1 ]; then
  echo "Collecting Memory bandwidth..."
  dump_membw > logs/$OUT_DIR/membw.log 2>&1 &
  sleep 30
  sleep $DURATION_S
  sudo pkill -9 pcm
  parse_membw
fi

if [ "$IIO_REPORTING" -eq 1 ]; then
  echo "Collecting IIO occupancy..."
  compile_if_needed collect_iio_occ.c collect_iio_occ
  taskset -c 14 ./collect_iio_occ &
  sleep 5
  sudo pkill -2 -f collect_iio_occ
  sleep 5
  mv iio.log logs/$OUT_DIR/iio.log
  #TODO: make more generic and add a parser to create report for iio occupancy logging from userspace
fi

if [ "$FLAMEGRAPH_REPORTING" -eq 1 ]; then
    sudo rm -f out.perf-folded
    echo "Creating Flame Graph..."
    sudo perf record -C $CPU_MASK -g -F 99 -- sleep $DURATION_S
    sudo perf script | $DEP_DIR/FlameGraph/stackcollapse-perf.pl > out.perf-folded
    sudo $DEP_DIR/FlameGraph/flamegraph.pl out.perf-folded > logs/$OUT_DIR/perf-kernel-flame.svg
    # also collect cache miss rates
    sudo perf stat -C $CPU_MASK -e LLC-load,LLC-load-misses,l2_rqsts.all_demand_miss,l2_rqsts.all_demand_references -o logs/$OUT_DIR/llc.miss.log sleep 2
    #loadmisses=$(cat logs/$4/$3/llc.miss.log | grep "LLC-load-misses" | awk '{ printf $1 }')
    #loads=$(cat logs/$4/$3/llc.miss.log | grep "LLC-load " | awk '{ printf $1 }')
fi