SCRIPT_NAME="setup-envir"

#default values
MTU=4000
# INTF="virbr0"
# IP="192.168.122.1"
TCP_SOCKET_BUF_MB=1
ECN_ENABLED=1
HWPREF_ENABLED=1
RDMA=0
RING_BUFFER_SIZE=1024

help()
{
    echo "Usage: $SCRIPT_NAME 
              [ --intf (interface name, eg. ens2f0) ]
              [ --ip (ip address for the interface) ]
              [ -m | --mtu (MTU size in bytes; default=4000 for TCP, 4096 for RDMA) ] 
              [ -r | --ring-buffer (size of Rx ring buffer. Note: opt must be set to change this)]
              [ --socket-buf (TCP socket buffer size (in MB)) ]
              [ --ecn (Enable ECN support in Linux stack) ]
              [ --hwpref (Enable hardware prefetching) ]
              [ --rdma (=0/1, whether the setup is for running RDMA experiments (MTU offset will be different)) ]
              [ -h | --help  ]"
    exit 2
}

SHORT=m:,r:,h
LONG=mtu:,ring-buffer:,intf:,ip:,socket-buf:,ecn:,hwpref:,rdma:,help
PARSED_OPTS=$(getopt -a -n $SCRIPT_NAME --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$#
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$PARSED_OPTS"

while :;do
  case "$1" in
    -m | --mtu) MTU="$2"; shift 2 ;;
    -r | --ring-buffer) RING_BUFFER_SIZE="$2"; shift 2 ;;
    --intf) INTF="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --socket-buf) TCP_SOCKET_BUF_MB="$2"; shift 2 ;;
    --ecn) ECN_ENABLED="$2"; shift 2 ;;
    --hwpref) HWPREF_ENABLED="$2"; shift 2 ;;
    --rdma) RDMA="$2"; shift 2 ;;
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
