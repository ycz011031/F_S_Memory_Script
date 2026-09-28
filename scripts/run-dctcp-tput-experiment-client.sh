#!/bin/bash

source ../utils/setup-server.sh

help()
{
    echo "Usage: run-rdma-tput-experiment
               [ -H | --home (home directory)]
               [ -S | --server (ip address of the server)]
               [ --server_intf (interface name for the server, for eg., ens2f0)]
               [ --num_servers (number of servers)]
               [ -C | --client (ip address of the client)]
               [ --client_intf (interface name for the client, for eg., ens2f0)]
               [ --num_clients (number of clients)]
               [ -E | --exp (experiment name, this name will be used to create output directories; default='rdma-test')]
               [ -M | --MTU (=256/512/1024/2048/4096; MTU size used;default=4096) ]
               [ -d | --ddio (=0/1, whether DDIO is disabled or enabled) ]
               [ -c | --cpu_mask (comma separated CPU mask to run the app on, recommended to run on NUMA node local to the NIC for maximum performance; default=0) ]
               [ -b | --bandwidth (bandwidth to send at in bits/sec)]
               [ --mlc_cores (comma separated values for MLC cores, for eg., '1,2,3' for using cores 1,2 and 3. Use 'none' to skip running MLC.) ]
               [ --ring_buffer (size of NIC Rx buffer)]
               [ --buf (TCP socket buffer size (in MB))]
               [ -h | --help  ]"
    exit 2
}

SHORT=H:,S:,C:,E:,M:,d:,c:,b:,h
LONG=home:,server:,client:,num_servers:,num_clients:,server_intf:,client_intf:,exp:,txn:,MTU:,size:,ddio:,cpu_mask:,mlc_cores:,ring_buffer:,bandwidth:,buf:,help
OPTS=$(getopt -a -n run-rdma-tput-experiment --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

#default values
exp="benny-test"
server=$SERVER_NIC_IP
client=$CLIENT_NIC_IP
server_intf=$SERVER_INTF
client_intf=$CLIENT_INTF
num_servers=1
num_clients=1
init_port=3000
ddio=0
mtu=4000
dur=120
cpu_mask="0,2,4,6,8,10,12,14,16,18"
client_cpu_mask=$cpu_mask
mlc_cores="none"
mlc_dur=100
ring_buffer=1024
buf=1
bandwidth="100g"
num_runs=1
home=$DEP_DIR
setup_dir=$home/Fast-and-Safe-IO-Memory-Protection/utils
exp_dir=$home/Fast-and-Safe-IO-Memory-Protection/utils/tcp
mlc_dir=$home/mlc/Linux


uname=$CLIENT_USERNAME
ssh_hostname=$CLIENT_SSH_IP
password=$CLIENT_PWD


while :
do
  case "$1" in
    -H | --home )
      home="$2"
      shift 2
      ;;
    -E | --exp )
      exp="$2"
      shift 2
      ;;
    -S | --server )
      server="$2"
      shift 2
      ;;
    --num_servers )
      num_servers="$2"
      shift 2
      ;;
     --server_intf )
      server_intf="$2"
      shift 2
      ;;
    -C | --client )
      client="$2"
      shift 2
      ;;
    --num_clients )
      num_clients="$2"
      shift 2
      ;;
     --client_intf )
      client_intf="$2"
      shift 2
      ;;
    -M | --MTU )
      mtu="$2"
      shift 2
      ;;
    -d | --ddio )
      ddio="$2"
      shift 2
      ;;
    -c | --cpu_mask )
      cpu_mask="$2"
      shift 2
      ;;
    --mlc_cores )
      mlc_cores="$2"
      shift 2
      ;;
    --ring_buffer )
      ring_buffer="$2"
      shift 2
      ;;
    --buf )
      buf="$2"
      shift 2
      ;;
    -b | --bandwidth )
      bandwidth="$2"
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


# Function to display the progress bar
function progress_bar() {
    local duration=$1
    local interval=$2

    for ((i = 0; i <= duration; i += interval)); do
        local progress=$((i * 100 / duration))
        local bar_length=$((progress / 2))
        local bar=$(printf "%-${bar_length}s" "=")
        printf "[%-${bar_length}s] %d%%" "$bar" "$progress"
        sleep "$interval"
        printf "\r"
    done
    printf "[%-${duration}s] %d%%\n" "$(printf "%-${duration}s" "=")" "100"
}

function cleanup() {
    sudo pkill -9 -f loaded_latency
    sudo pkill -9 -f iperf
    rm -f $home/hostCC/utils/out.perf-folded
    rm -f $home/hostCC/utils/perf.data
    sshpass -p $password ssh $uname@$ssh_hostname 'screen -S $(screen -list | awk "/\\.client_session\t/ {print \$1}") -X quit'
    sshpass -p $password ssh $uname@$ssh_hostname 'screen -S $(screen -list | awk "/\\.logging_session\t/ {print \$1}") -X quit'
    sshpass -p $password ssh $uname@$ssh_hostname 'screen -wipe'
    sshpass -p $password ssh $uname@$ssh_hostname 'sudo pkill -9 -f iperf'
    ## IOVA logging
    sudo echo 0 > /sys/kernel/debug/tracing/tracing_on
    sudo echo 0 > /sys/kernel/debug/tracing/options/overwrite
    sudo echo 5000 > /sys/kernel/debug/tracing/buffer_size_kb
    # reset interface
    # sudo ip link set $server_intf down
    # sleep 2
    # sudo ip link set $server_intf up
    # sleep 2
    # sudo bash /home/benny/restart.sh
}


#first run very long running MLC app, to find out network tput
for ((j = 0; j < $num_runs; j += 1)); do
  echo "running instance $j"

  OUT_DIR="$exp-RUN-server-$j"
  mkdir -p ../utils/reports #Directory to store collected logs
  # mkdir -p ../reports/$OUT_DIR #Directory to store collected logs
  if [ ! -d "../utils/reports/$OUT_DIR" ]; then
      mkdir -p "../utils/reports/$OUT_DIR"
      echo "Directory '../utils/reports/$OUT_DIR' created."
  else
      echo "Directory '../utils/reports/$OUT_DIR' already exists."
      rm -r "../utils/reports/$OUT_DIR"
      mkdir -p "../utils/reports/$OUT_DIR"
      echo "Directory '../utils/reports/$OUT_DIR' recreated."
  fi
  mkdir -p ../utils/logs #Directory to store collected logs
  # mkdir -p ../logs/$OUT_DIR #Directory to store collected logs
  if [ ! -d "../utils/logs/$OUT_DIR" ]; then
      mkdir -p "../utils/logs/$OUT_DIR"
      echo "Directory '../utils/logs/$OUT_DIR' created."
  else
      echo "Directory '../utils/logs/$OUT_DIR' already exists."
      rm -r "../utils/logs/$OUT_DIR"
      mkdir -p "../utils/logs/$OUT_DIR"
      echo "Directory '../utils/logs/$OUT_DIR' recreated."
  fi

  #### pre-run cleanup -- kill any existing clients/screen sessions
  # cleanup

  #### start MLC
  if [ "$mlc_cores" = "none" ]; then
      echo "No MLC instance used..."
      # Perform actions for "none" input
  else
      echo "starting MLC..."
      $mlc_dir/mlc --loaded_latency -T -d0 -e -k$mlc_cores -j0 -b1g -t10000 -W2 &> mlc.log &
      ## wait until MLC starts sending memory traffic at full rate
      echo "waiting for MLC for start..."
      progress_bar 30 1
  fi

  #### setup and start servers
  echo "setting up server config..."
  # sudo bash /home/benny/restart.sh
  cd $setup_dir
  sudo bash setup-envir.sh -i $server_intf -a $server -m $mtu --ring_buffer $ring_buffer --buf $buf
  sleep 5
  # cd -

  echo "starting server instances..."
  echo "starting server session on $ssh_hostname, username: $uname, password: $password"
  sshpass -p $password ssh $uname@$ssh_hostname 'screen -dmS client_session bash -c "cd '$setup_dir'; sudo bash '$setup_dir'/setup-envir.sh -i '$client_intf' -a '$client' -m '$mtu' --ring_buffer '$ring_buffer' --buf '$buf'; sleep 5; cd '$exp_dir'; sudo bash '$exp_dir'/run-netapp-tput.sh -m server -a '$server' -C '$num_clients' -S '$num_servers' -o '$exp'-RUN-client-'$j' -p '$init_port' -c '$client_cpu_mask' -b '$bandwidth'; exec bash"'
  sleep 10

  #### setup and start clients
  echo "setting up and starting clients..."
  cd $exp_dir
  echo "Running command: sudo bash run-netapp-tput.sh -m client -C $num_clients -S $num_servers -o $exp-RUN-server-$j -p $init_port -l $cpu_mask -a $CLIENT_NIC_IP -b $bandwidth"
  sudo bash run-netapp-tput.sh -m client -C $num_clients -S $num_servers -o $exp-RUN-server-$j -p $init_port -l $cpu_mask -a $CLIENT_NIC_IP -b $bandwidth &
  sleep 2
  cd -
  
  echo "turning on IOVA logging via ftrace"
  sudo echo > /sys/kernel/debug/tracing/trace
  sudo echo 1 > /sys/kernel/debug/tracing/tracing_on


  #### warmup
  echo "warming up iperf..."
  progress_bar 10 1

  #record stats
  ##start sender side logging
  echo "starting logging at client..."
  sshpass -p $password ssh $uname@$ssh_hostname 'screen -dmS logging_session bash -c "cd '$setup_dir'; sudo bash '$setup_dir'/record-host-metrics.sh -f 0 -t 1 --intf '$client_intf' -o '$exp-RUN-client-$j' --type 0 --cpu-util 1 --retx 1 --pcie 0 --membw 0 --dur '$dur' --cores '$client_cpu_mask' ; exec bash"'

  ##start receiver side logging
  echo "starting logging at server..."
  cd $setup_dir
  sudo bash record-host-metrics.sh -f 0 --iio 1 -t 1 --intf $server_intf -o $exp-RUN-server-$j --type 0 --cpu-util 1 --pcie 1 --membw 1 --dur $dur --cores $cpu_mask --retx 1 --bw 1
  echo "done logging..."
  cd -

  #transfer sender-side info back to receiver
#   sshpass -p $password scp $uname@$ssh_hostname:$setup_dir/reports/$exp-RUN-client-$j/retx.rpt $setup_dir/reports/$exp-RUN-server-$j/retx.rpt

  sleep 20

  # Get FIO PID
  sudo killall fio
  sleep 5
  # FIO_PID=$(cat /tmp/fio_pid.txt)
  # echo "Killing FIO process with PID: $FIO_PID"
  # sudo kill -2 $FIO_PID

  #post-run cleanup
  cleanup
done

if [ "$mlc_cores" = "none" ]; then
    echo "No MLC instance used... Skipping MLC throughput collection"
else
    echo "MLC cores detected.. Still skipping MLC throughput collection"
   # #now run very long network app, to find out MLC tput
   # for ((j = 0; j < $num_runs; j += 1)); do
   # echo "running instance $j"

   # #### pre-run cleanup -- kill any existing clients/screen sessions
   # cleanup

   # #### setup and start servers
   # echo "setting up server config..."
   # cd $setup_dir
   # sudo bash setup-envir.sh -i $server_intf -a $server -m $mtu -d $ddio --ring_buffer $ring_buffer --buf $buf -f 1 -r 0 -p 0 -e 0 -o 1
   # cd -

   # echo "starting server instances..."
   # cd $exp_dir
   # sudo bash run-netapp-tput.sh -m server -S $num_servers -o $exp-MLCRUN-$j -p $init_port -c $cpu_mask &
   # sleep 2
   # cd -

   # #### setup and start clients
   # echo "setting up and starting clients..."
   # sshpass -p $password ssh $uname@$ssh_hostname 'screen -dmS client_session sudo bash -c "cd '$setup_dir'; sudo bash setup-envir.sh -i '$client_intf' -a '$client' -m '$mtu' -d '$ddio' --ring_buffer '$ring_buffer' --buf '$buf' -f 1 -r 0 -p 0 -e 0 -o 1; cd '$exp_dir'; sudo bash run-netapp-tput.sh -m client -a '$server' -C '$num_clients' -S '$num_servers' -o '$exp'-MLCRUN-'$j' -p '$init_port' -c '$cpu_mask' -b '$bandwidth'; exec bash"'

   # #### start MLC
   # echo "starting MLC..."
   # $mlc_dir/mlc --loaded_latency -T -d0 -e -k$mlc_cores -j0 -b1g -t$mlc_dur -W2 &> $setup_dir/reports/$exp-MLCRUN-$j/mlc.log &
   # ## wait until MLC starts sending memory traffic at full rate
   # sleep 30
   # echo "Running MLC..."
   # progress_bar $mlc_dur 1

   # #post-run cleanup
   # cleanup
   # done
fi

#collect info from all runs
cd $home/Fast-and-Safe-IO-Memory-Protection/scripts
if [ "$mlc_cores" = "none" ]; then
    sudo python3 collect-tput-stats.py $exp $num_runs 0
else
    sudo python3 collect-tput-stats.py $exp $num_runs 1
fi


