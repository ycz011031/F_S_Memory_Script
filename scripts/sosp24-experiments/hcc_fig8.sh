# same 3 experiments of MLC increase bandwidth contention
# need to be careful how I present breakdown of the 3 configurations:
# IOMMU Off (top plot), Linux + IOMMU On (bottom), Linux + IOMMU On + F&S (bottom)
./clean_logs.sh
cd ..

echo "Running hostcc mlc0 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment-hcc.sh -E "hcc-mlc0" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py hcc-mlc0 tput

echo "Running hostcc mlc1 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment-hcc.sh -E "hcc-mlc1" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py hcc-mlc1 tput

echo "Running hostcc mlc2 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment-hcc.sh -E "hcc-mlc2" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1,2' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py hcc-mlc2 tput

echo "Running hostcc mlc3 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment-hcc.sh -E "hcc-mlc3" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1,2,3' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py hcc-mlc3 tput
