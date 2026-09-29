#!/bin/bash

source ../setup-server.sh

help()
{
    echo "Usage: run-ssdapp
               [ -H | --home (home directory)]
               [ -E | --exp (experiment name, this name will be used to create output directories; default='rdma-test')]
               [ -o | --outdir (name of the output directory which will store the records; default=test) ] 
               [ -c | --cpu_mask (comma separated CPU mask to run the app on, recommended to run on NUMA node local to the NIC for maximum performance; default=0) ]
               [ --bs (FIO Block Size in bytes, default=4k)]
               [ --iodepth (FIO I/O depth, default=1)]
               [ --rw (FIO test type, default=read)]
               [ --submit_batch (FIO submit batch size, default=1)]
               [ --comp_batch (FIO min completion batch size, default=1)]
               [ --t | --num_threads (number of threads to use, default=1)]
               [ -h | --help  ]"
    exit 2
}

SHORT=H:,E:,o:,c:,t:,h
LONG=home:,exp:,outdir:,cpu_mask:,bs:,iodepth:,rw:,submit_batch:,comp_batch:,num_threads:,help
OPTS=$(getopt -a -n run-ssdapp --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

#default values
CPU_MASK="64-79"
HOME=$DEP_DIR
EXP="fio-test"
OUT_DIR="/tmp/fio-test"
SETUP_DIR=$HOME/Fast-and-Safe-IO-Memory-Protection/utils
EXP_DIR=$HOME/Fast-and-Safe-IO-Memory-Protection/utils/fio
MLC_DIR=$HOME/mlc/Linux

fio_template="$EXP_DIR/jobfiles/bs_rw_logging.fio"

# FIO default parameters
DEVICE="/dev/nvme0n1" # nvme0
BS=4k
IODEPTH=8
RW="randread"
SUBMIT_BATCH=4
COMP_BATCH=4
NUM_THREADS=8
IOENGINE="libaio"
DIRECT=1
RANDREPEAT=0           # decorrelate random sequences
NORANDOMMAP=1          # independent random accesses per job
LOG_AVG_MSEC=1000      # 1s log interval for *_bw/lat logs
RUNTIME=1200          # run time of 20 minutes


UNAME=$CLIENT_USERNAME
SSH_HOSTNAME=$CLIENT_SSH_IP
PASSWORD=$CLIENT_PWD

core_values=(40 45 51 57 63 69 73 79) # nvme0
# Per-thread slice assignment (GiB)
BASE_OFFSET_GIB=512      # first thread starts at 512 GiB
SLICE_SIZE_GIB=32       # each thread gets 32 GiB

########################################
# Derived / checks
########################################
if (( ${#core_values[@]} < NUM_THREADS )); then
  echo "ERROR: core_values has only ${#core_values[@]} entries but NUM_THREADS=$NUM_THREADS" >&2
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "ERROR: $DEVICE is not a block device." >&2
  exit 1
fi

GIB=$((1024*1024*1024))
BASE_OFFSET_BYTES=$((BASE_OFFSET_GIB * GIB))
SLICE_SIZE_BYTES=$((SLICE_SIZE_GIB * GIB))
TOTAL_REQUIRED_BYTES=$((BASE_OFFSET_BYTES + NUM_THREADS * SLICE_SIZE_BYTES))

DEVICE_SIZE_BYTES=$(blockdev --getsize64 "$DEVICE")
if (( TOTAL_REQUIRED_BYTES > DEVICE_SIZE_BYTES )); then
  echo "ERROR: Need $(numfmt --to=iec $TOTAL_REQUIRED_BYTES) but device size is $(numfmt --to=iec $DEVICE_SIZE_BYTES)." >&2
  echo "Reduce NUM_THREADS or SLICE_SIZE_GIB, or increase BASE_OFFSET_GIB." >&2
  exit 1
fi


while :
do
  case "$1" in
    -H | --home ) HOME="$2"; shift 2 ;;
    -E | --exp ) EXP="$2"; shift 2 ;;
    -o | --outdir) OUT_DIR="$2"; shift 2 ;;
    -c | --cpu_mask ) CPU_MASK="$2"; shift 2 ;;
    --bs ) BS="$2"; shift 2 ;;
    --iodepth ) IODEPTH="$2"; shift 2 ;;
    --rw ) RW="$2"; shift 2 ;;
    --submit_batch ) SUBMIT_BATCH="$2"; shift 2 ;;
    --comp_batch ) COMP_BATCH="$2"; shift 2 ;;
    -t | --num_threads ) NUM_THREADS="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done



# export SIZE=$BS
# export IODEPTH=$IODEPTH
echo "Running $RW test with block size $BS..."
# Generate a concrete .fio file for this test
fio_jobfile="/tmp/ladio_${RW}_${BS}_logging.fio"
log_path=$DEP_DIR/Fast-and-Safe-IO-Memory-Protection/utils/logs/$OUT_DIR
# if [ ! -d "$log_path" ]; then
#     mkdir -p "$log_path"
#     echo "Directory '$log_path' created."
# else
#     echo "Directory '$log_path' already exists."
#     rm -r "$log_path"
#     mkdir -p "$log_path"
#     echo "Directory '$log_path' recreated."
# fi
sed "s|\${SIZE}|$BS|g; s|\${IODEPTH}|$IODEPTH|g; s|\${RW}|$RW|g; s|\${OUT_DIR}|$log_path|g; s|\${SUBMIT_BATCH}|$SUBMIT_BATCH|g; s|\${COMP_BATCH}|$COMP_BATCH|g; s|\${NUM_THREADS}|$NUM_THREADS|g; s|\${CPU_MASK}|$CPU_MASK|g;" "$fio_template" > "$fio_jobfile"


for ((idx=0; idx<NUM_THREADS; idx++)); do
  core=${core_values[idx]}
  job_offset_bytes=$(( BASE_OFFSET_BYTES + idx * SLICE_SIZE_BYTES ))

  out_txt="${log_path}/rr${idx}_bs${bs}.out"
  out_json="${log_path}/rr${idx}_bs${bs}.json"
  bw_log="${log_path}/bw_rr${idx}_bs${bs}"
  lat_log="${log_path}/lat_rr${idx}_bs${bs}"

  echo "  -> rr${idx}: core ${core}, offset $(numfmt --to=iec $job_offset_bytes), size ${SLICE_SIZE_GIB}GiB"
  taskset -c "${core}" fio \
    --name="rr${idx}" \
    --filename="${DEVICE}" \
    --rw=randread \
    --bs="${BS}" \
    --time_based=1 --runtime="${RUNTIME}" --direct="${DIRECT}" \
    --ioengine="${IOENGINE}" --iodepth="${IODEPTH}" --numjobs=1 \
    --offset="${job_offset_bytes}" --size="${SLICE_SIZE_BYTES}" \
    --group_reporting=1 --eta=never \
    --output-format=json --output="${out_json}" \
    --iodepth_batch=8 --iodepth_batch_submit=8 \
    --iodepth_batch_complete_min=8 --iodepth_batch_complete_max=64 \
    --cpus_allowed="${core}" --cpus_allowed_policy=split \
    > "${out_txt}" 2>&1 &
    # --randrepeat="${RANDREPEAT}" --norandommap="${NORANDOMMAP}" \
    # --log_avg_msec="${LOG_AVG_MSEC}" \
    # --write_bw_log="${bw_log}" \
    # --write_lat_log="${lat_log}" \
done
