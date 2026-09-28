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
    sudo taskset -c 15 $PCM_DIR/build/bin/pcm-iio 1 -csv=logs/$OUT_DIR/pcie.csv &
}

function parse_pciebw() {
    #TODO: make more general, parse PCIe bandwidth for any given socket and IIO stack
    echo "PCIe_wr_tput: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $6/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum / n * 8 ; }') > reports/$OUT_DIR/pcie.rpt
    echo "PCIe_rd_tput: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $7/1000000000.0; n++ } END { if (n > 0) printf "%0.3f", sum / n * 8 ; }') >> reports/$OUT_DIR/pcie.rpt
    echo "IOTLB_hits: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $10; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "IOTLB_misses: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $11; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "CTXT_Miss: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $12; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "L1_Miss: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $13; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "L2_Miss: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $14; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "L3_Miss: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $15; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
    echo "Mem_Read: " $(cat logs/$OUT_DIR/pcie.csv | grep "$PCIE_PATTERN" | awk -F ',' '{ sum += $16; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> reports/$OUT_DIR/pcie.rpt
}

function dump_membw() {
    sudo modprobe msr
    sudo taskset -c 15 $PCM_DIR/build/bin/pcm-memory 1 -columns=5
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
      sudo pkill -9 -f "sar"
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
  sudo pkill -9 -f "pcm"
  parse_pciebw
fi

if [ "$MEMBW_REPORTING" -eq 1 ]; then
  echo "Collecting Memory bandwidth..."
  dump_membw > logs/$OUT_DIR/membw.log &
  sleep 30
  sleep $DURATION_S
  sudo pkill -9 -f "pcm"
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