SCRIPT_NAME="setup-bare-metal"

#default values
MTU=4000
DDIO_ENABLED=1
# DEP_DIR="/users/Leshna"
# INTF="eno12409np1"
# IP="10.10.1.2"
# NIC_BUS="0x9a"
TCP_OPTIMIZATION_ENABLED=1
TCP_SOCKET_BUF_MB=1
ECN_ENABLED=1
HWPREF_ENABLED=1
RDMA=0
PFC_ENABLED=0
RING_BUFFER_SIZE=1024

help()
{
    echo "Usage: $SCRIPT_NAME 
              [ --dep (path to dependencies directories)]
              [ --intf (interface name, eg. ens2f0) ]
              [ --ip (ip address for the interface) ]
	      [ --nic-bus (NIC's PCI bus number) ]
              [ -m | --mtu (MTU size in bytes; default=4000 for TCP, 4096 for RDMA) ] 
              [ -d | --ddio (=0/1, whether DDIO should be disabled/enabled; default=0) ]
              [ -r | --ring-buffer (size of Rx ring buffer. Note: opt must be set to change this)]
              [ --opt (enable TCP optimization TSO,GRO,aRFS) ]
              [ --socket-buf (TCP socket buffer size (in MB)) ]
              [ --ecn (Enable ECN support in Linux stack) ]
              [ --hwpref (Enable hardware prefetching) ]
              [ --rdma (=0/1, whether the setup is for running RDMA experiments (MTU offset will be different)) ]
              [ --pfc (=0/1, disable or enable PFC) ]
              [ -h | --help  ]"
    exit 2
}

SHORT=m:,d:,r:,h
LONG=dep:,nic-bus:,mtu:,ddio:,ring-buffer:,intf:,ip:,opt:,socket-buf:,ecn:,hwpref:,rdma:,pfc:,help
PARSED_OPTS=$(getopt -a -n $SCRIPT_NAME --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$#
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$PARSED_OPTS"

while :;do
  case "$1" in
    --dep) DEP_DIR="$2"; shift 2 ;;
    --nic-bus) NIC_BUS="$2"; shift 2 ;;
    -m | --mtu) MTU="$2"; shift 2 ;;
    -d | --ddio) DDIO_ENABLED="$2"; shift 2 ;;
    -r | --ring-buffer) RING_BUFFER_SIZE="$2"; shift 2 ;;
    --intf) INTF="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --opt) TCP_OPTIMIZATION_ENABLED="$2"; shift 2 ;;
    --socket-buf) TCP_SOCKET_BUF_MB="$2"; shift 2 ;;
    --ecn) ECN_ENABLED="$2"; shift 2 ;;
    --hwpref) HWPREF_ENABLED="$2"; shift 2 ;;
    --rdma) RDMA="$2"; shift 2 ;;
    --pfc) PFC_ENABLED="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

log_info() {
    echo "[INFO] - $1"
}

if [ "$RDMA" -eq 1 ]; then
  log_info "Configuring MTU according to RDMA supported values..."
  MTU=$(($MTU + 96))
  if [ "$MTU" -lt 1280 ]; then
      log_info "Requested physical MTU size is $MTU, updating to 1280"
      MTU=1280
  fi
  log_info "MTU configured to $MTU"
fi

# setup the interface
log_info "Setting up the interface $INTF..."
ifconfig $INTF up
ifconfig $INTF $IP
ifconfig $INTF mtu $MTU

#disable TCP buffer auto-tuning, and set the buffer size to the specified size
log_info "Setting up the socket buffer size to be ${TCP_SOCKET_BUF_MB}MB"
echo 0 > /proc/sys/net/ipv4/tcp_moderate_rcvbuf 
#Set TCP receive buffer size to be 1MB (other 1MB is for the application buffer)
echo "$(($TCP_SOCKET_BUF_MB * 2000000)) $(($TCP_SOCKET_BUF_MB * 2000000)) $(($TCP_SOCKET_BUF_MB * 2000000))" > /proc/sys/net/ipv4/tcp_rmem 
#Set TCP send buffer size to be 1MB
echo "$(($TCP_SOCKET_BUF_MB * 1000000)) $(($TCP_SOCKET_BUF_MB * 1000000)) $(($TCP_SOCKET_BUF_MB * 1000000))" > /proc/sys/net/ipv4/tcp_wmem

#Enable TCP ECN support at the senders/receivers
if [ "$ECN_ENABLED" = 1 ]; then
    log_info "Enabling ECN support..."
    echo 1 > /proc/sys/net/ipv4/tcp_ecn
fi

#Enable aRFS, TSO, GRO for the interface
if [ "$TCP_OPTIMIZATION_ENABLED" -eq 1 ]; then
    cd ${DEP_DIR}/Understanding-network-stack-overheads-SIGCOMM-2021
    log_info "Enabling TCP optimizations (TSO, GRO, aRFS)..."
    sudo python3 network_setup.py $INTF --arfs --mtu $MTU --sock-size --tso --gro --ring-buffer $RING_BUFFER_SIZE
    cd -
fi


#Enable/disable DDIO
cd ${DEP_DIR}/ddio-bench/
if [ "$DDIO_ENABLED" -eq 1 ]; then
    log_info "Enabling DDIO..."
    sudo ./ddio-tool -b $NIC_BUS enable
else
    log_info "Disabling DDIO..."
    sudo ./ddio-tool -b $NIC_BUS disable
fi
cd -


#Enable prefetching
if [ "$HWPREF_ENABLED" -eq 1 ]; then
    log_info "Enabling hardware prefetching..."
    modprobe msr
    wrmsr -a 0x1a4 0
else
    log_info "Disabling hardware prefetching..."
    modprobe msr
    wrmsr -a 0x1a4 1
fi

#Enable PFC (on QoS 0)
if [ "$PFC_ENABLED" -eq 1 ]
then
    log_info "Enabling PFC..."
    # mlnx_qos -i $INTF --pfc 1,0,0,0,0,0,0,0
    sudo lldptool -T -i $INTF -V PFC willing=no enabled=0
    tc_wrap.py -i $INTF
    tc_wrap.py -i $INTF -u 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

    # To enable on other QoS, modify the above code accordingly
    # For eg., to enable PFC on QoS 1 or 2 us the code below

    # Qos 1
    #  mlnx_qos -i $INTF --pfc 0,1,0,0,0,0,0,0
    #  tc_wrap.py -i $INTF
    #  tc_wrap.py -i $INTF -u 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1

    # Qos 2
    # mlnx_qos -i $INTF --pfc 0,0,1,0,0,0,0,0
    # tc_wrap.py -i $INTF
    # tc_wrap.py -i $INTF -u 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
else
    log_info "Disabling PFC..."
    sudo lldptool -T -i $INTF -V PFC willing=no enabled=
    # sudo mlnx_qos -i $INTF --pfc 0,0,0,0,0,0,0,0
fi

