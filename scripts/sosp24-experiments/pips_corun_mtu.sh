#!/bin/bash

source ../../utils/setup-server.sh

# ./clean_logs.sh
# start_dir=$(pwd)

# ./clean_logs.sh
cd ..

working_dir=$(pwd)
echo "Running mtu experiment... this may take a few minutes"

iommu_on=$(grep -o intel_iommu=on /proc/cmdline)
iommu_config=""
if [ -z $iommu_on ]; then
    iommu_config="iommu-off"
else
    iommu_config="iommu-on"
fi

# ofed_version=$(ofed_info -n)

# pause the frame
# ssh -t $CLIENT_USERNAME@$CLIENT_SSH_IP "sudo ethtool --pause $CLIENT_INTF tx off rx off"

# echo "Disabling pause frames on $SERVER_INTF and $CLIENT_INTF"
# sudo ethtool --pause $SERVER_INTF tx off rx off
# sshpass -p $CLIENT_PWD ssh $CLIENT_USERNAME@$CLIENT_SSH_IP "screen -dmS setup_session bash -c 'sudo ethtool --pause $CLIENT_INTF tx off rx off'"
# sleep 10
# sshpass -p $CLIENT_PWD ssh $CLIENT_USERNAME@$CLIENT_SSH_IP "screen -S \$(screen -list | awk '/\\.setup_session[[:space:]]/ {print \$1}') -X quit"

warmup_time=10

for i in 4000; do
    # for j in 8k 2048k; do # fio block sizes
    for j in 4k; do # fio block sizes
        cd $working_dir
        cur_time=$(date +"%m-%d-%H-%M")
        format_i=$(printf "%04d\n" $i)
        format_j=$(printf "%s\n" $j)
        # exp_name="$(uname -r)-flow${format_i}-${iommu_config}-ofed$(ofed_version)-test2-siyuan"
        # exp_name="$(uname -r)-${iommu_config}-flow-${format_i}-core4-warmup${warmup_time}-leshna"
        exp_name="$(uname -r)-${iommu_config}-mtu-${format_i}-fio-${format_j}"
        echo $exp_name
        exp_name="${exp_name}-990pro"
        bash ./run-ssd-nic-experiment.sh -E "$exp_name" --num_servers 5 --num_clients 5 -c '64,68,70,74,78' --bandwidth '100g' --bs $j --MTU $i
        # sudo bash -c "./run-dctcp-tput-experiment.sh -E '$exp_name' -M 4000 --num_servers $i --num_clients $i -c '0,4,8,12,16' --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth '100g' --server_intf $SERVER_INTF --client_intf $CLIENT_INTF"

    # > /dev/null 2>&1
        python3 report-tput-metrics.py $exp_name tput,drops,acks,iommu,cpu
        cd ../utils/reports/$exp_name

        sudo bash -c "cat /sys/kernel/debug/tracing/trace > iova.log"
        sudo bash -c "rg iperf3 iova.log > iperf_iova.log"
        sudo bash -c "rg 'core: 16' iova.log > iperf_iova_core16.log"
        # sudo bash -c "rg core iova.log > core_iova.log"

        cd $working_dir
        sudo chmod +666 -R ../utils/reports/$exp_name

        # python sosp24-experiments/plot_iova_logging.py \
        #     --exp_folder "../utils/reports/$exp_name" \
        #     --log_file "iova.log"

        python3 sosp24-experiments/count_invalidation.py --dir "../utils/reports/$exp_name" 
    done
    
done
