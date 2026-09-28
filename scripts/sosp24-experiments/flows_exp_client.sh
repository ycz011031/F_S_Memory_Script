#!/bin/bash

source ../../utils/setup-server.sh

# ./clean_logs.sh
# start_dir=$(pwd)

# ./clean_logs.sh
cd ..

working_dir=$(pwd)
echo "Running flow5 experiment... this may take a few minutes"


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

# 5 10 20 40
for i in 5; do
    for j in $(seq 1 1 1) # start from 1, increment by 2 until 10
    do
        cd $working_dir
        cur_time=$(date +"%m-%d-%H-%M")
        format_i=$(printf "%02d\n" $i)
        # exp_name="$(uname -r)-flow${format_i}-${iommu_config}-ofed$(ofed_version)-test2-siyuan"
        # exp_name="$(uname -r)-${iommu_config}-flow-${format_i}-core4-warmup${warmup_time}-leshna"
        exp_name="$(uname -r)-${iommu_config}-flow-${format_i}-test"
        echo $exp_name
        exp_name="${exp_name}-pips-client-6.12"
        bash ./run-dctcp-tput-experiment-client.sh -E "$exp_name" --num_servers $i --num_clients $i -c '56,58,60,62,64,68,70,74,76,78' --bandwidth '100g'
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

    sleep 60
    
done

# sudo bash run-dctcp-tput-experiment.sh -E "flow5-iommu-on" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" \
#     --server_intf ens2f0np0 --client_intf ens2f0
# # > /dev/null 2>&1
# python3 report-tput-metrics.py flow5 tput,drops,acks,iommu,cpu

# echo "Running flow10 experiment... this may take a few minutes"
# sudo bash run-dctcp-tput-experiment.sh -E "flow10" -M 4000 --num_servers 10 --num_clients 10 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
# python3 report-tput-metrics.py flow10 tput,drops,acks,iommu,cpu

# echo "Running flow20 experiment... this may take a few minutes"
# sudo bash run-dctcp-tput-experiment.sh -E "flow20" -M 4000 --num_servers 20 --num_clients 20 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
# python3 report-tput-metrics.py flow20 tput,drops,acks,iommu,cpu

# echo "Running flow40 experiment... this may take a few minutes"
# sudo bash run-dctcp-tput-experiment.sh -E "flow40" -M 4000 --num_servers 40 --num_clients 40 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
# python3 report-tput-metrics.py flow40 tput,drops,acks,iommu,cpu
