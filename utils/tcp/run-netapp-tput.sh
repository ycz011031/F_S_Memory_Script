#!/bin/bash
source ../setup-server.sh

SCRIPT_NAME="run-netapp-tput"

#default values
MODE="client"
OUT_DIR="tcptest"
SERVER_IP=$SERVER_NIC_IP
CPU_MASK="40,41,42,43,44"
CPU_MASK_CLIENT="0,2,4,6,8"
NUM_SERVERS=1
NUM_CLIENTS=1
PORT=3000
BANDWIDTH="100g"

help()
{
    echo "Usage: $SCRIPT_NAME [ --mode (=client/server) ]
               [ -o | --outdir (output directory to store the application stats log; default='test')]
               [ -S | --num_servers (number of server instances)]
               [ -C | --num_clients (number of client instances, only use this option at client)]
               [ -p | --port (port number for the first connection) ]
               [ -a | --addr (ip address of the server, only use this option at client) ]
               [ -c | --cores (comma separated cpu core values to run the clients/servers at, for eg., cpu=4,8,12,16; if the number of clients/servers > the number of input cpu cores, the clients/servers will round-robin over the provided input cores; recommended to run on NUMA node local to the NIC for maximum performance) ]
               [ -l | --client_cores (comma separated client cpu core values to run the clients/servers at, for eg., cpu=4,8,12,16; if the number of clients/servers > the number of input cpu cores, the clients/servers will round-robin over the provided input cores; recommended to run on NUMA node local to the NIC for maximum performance) ]
               [ -b | --bandwidth (bandwidth to send at in bits/sec)]
               [ -h | --help  ]"
    exit 2
}

SHORT=m:,o:,S:,C:,p:,a:,c:,l:,b:h
LONG=mode:,outdir:,num_servers:,num_clients:,port:,addr:,cores:,client_cores:,bandwidth:,help
OPTS=$(getopt -a -n run-netapp-tput --options $SHORT --longoptions $LONG -- "$@")
VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$OPTS"

while :
do
  case "$1" in
    -m | --mode )
      MODE="$2"
      shift 2
      ;;
    -o | --outdir )
      OUT_DIR="$2"
      shift 2
      ;;
    -S | --num_servers )
      NUM_SERVERS="$2"
      shift 2
      ;;
    -C | --num_clients )
      NUM_CLIENTS="$2"
      shift 2
      ;;
    -p | --port )
      PORT="$2"
      shift 2
      ;;
    -a | --addr )
      SERVER_IP="$2"
      shift 2
      ;;
    -c | --cores )
      CPU_MASK="$2"
      shift 2
      ;;
    -l | --client_cores )
      CPU_MASK_CLIENT="$2"
      shift 2
      ;;
    -b | --bandwidth )
      BANDWIDTH="$2"
      shift 2
      ;;
    -h | --help)
      help
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      ;;
  esac
done

echo "Running $SCRIPT_NAME with the following parameters: 
  Mode: $MODE
  Output Directory: $OUT_DIR
  Server IP: $SERVER_IP
  Number of Servers: $NUM_SERVERS
  Number of Clients: $NUM_CLIENTS
  Port: $PORT
  CPU Mask: $CPU_MASK
  Bandwidth: $BANDWIDTH"

IFS=',' read -ra core_values <<< $CPU_MASK
IFS=',' read -ra core_values_client <<< $CPU_MASK_CLIENT

mkdir -p ../reports #Directory to store collected logs
# mkdir -p ../reports/$OUT_DIR #Directory to store collected logs
if [ ! -d "../reports/$OUT_DIR" ]; then
    mkdir -p "../reports/$OUT_DIR"
    echo "Directory '../reports/$OUT_DIR' created."
else
    echo "Directory '../reports/$OUT_DIR' already exists."
fi
mkdir -p ../logs #Directory to store collected logs
# mkdir -p ../logs/$OUT_DIR #Directory to store collected logs
if [ ! -d "../logs/$OUT_DIR" ]; then
    mkdir -p "../logs/$OUT_DIR"
    echo "Directory '../logs/$OUT_DIR' created."
else
    echo "Directory '../logs/$OUT_DIR' already exists."
fi
rm -f ../logs/$OUT_DIR/iperf.bw.log

function collect_stats() {
  echo "Collecting app throughput for TCP server..."
  echo "Avg_iperf_tput: " $(cat ../logs/$OUT_DIR/iperf.bw.log | grep "30.*-60.*" | awk  '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }') > ../reports/$OUT_DIR/iperf.bw.rpt
}

counter=0
if [ "$MODE" = "server" ]; then
    sudo pkill -9 -f iperf #kill existing iperf servers/clients
    sleep 1
    while [ $counter -lt $NUM_SERVERS ]; do
        index=$(( counter % ${#core_values[@]} ))
        core=${core_values[index]}
        log_path=$DEP_DIR/Fast-and-Safe-IO-Memory-Protection/utils/logs/$OUT_DIR/iperf.bw.log
        echo "Starting server $counter on core $core, log path: $log_path"
        sudo taskset -c $core nice -n -20 iperf3 -s --port $(($PORT + $counter)) -i 30 -f m --logfile $log_path &
        # sudo taskset -c $core nice -n -20 iperf3 -s --port $(($PORT + $counter)) -i 30 -f m --logfile ../logs/$OUT_DIR/iperf.bw.log &
        ((counter++))
    done
    echo "waiting for few minutes before collecting stats..."
    sleep 80
    echo "collecting stats..."
    collect_stats
elif [ "$MODE" = "client" ]; then
    sudo pkill -9 -f iperf #kill existing iperf servers/clients
    sleep 1
    while [ $counter -lt $NUM_CLIENTS ]; do
        index=$(( counter % ${#core_values_client[@]} ))
        core=${core_values_client[index]}
        log_path=$DEP_DIR/Fast-and-Safe-IO-Memory-Protection/utils/logs/$OUT_DIR/iperf.bw.log
        echo "Starting client $counter on core $core"
        sudo taskset -c $core nice -n -20 iperf3 -c $SERVER_IP --port $(($PORT+$(($counter%$NUM_SERVERS)))) -i 30 -f m --logfile $log_path -t 10000 -C dctcp -b $BANDWIDTH &
        ((counter++))
    done
else
    echo "incorrect argument specified"
    help
fi