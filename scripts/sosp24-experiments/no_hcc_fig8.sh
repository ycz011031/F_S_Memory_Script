./clean_logs.sh
cd ..

echo "Running mlc0 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment.sh -E "nohcc-mlc0" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores 'none' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py nohcc-mlc0 tput

echo "Running mlc1 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment.sh -E "nohcc-mlc1" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py nohcc-mlc1 tput

echo "Running ml2 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment.sh -E "nohcc-mlc2" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1,2' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py nohcc-mlc2 tput

echo "Running ml3 experiment... this may take a few minutes"
sudo bash run-dctcp-tput-experiment.sh -E "nohcc-mlc3" -M 4000 --num_servers 5 --num_clients 5 -c "4,8,12,16,20" --ring_buffer 256 --buf 1 --mlc_cores '1,2,3' --bandwidth "100g" --server_intf ens2f1np1 > /dev/null 2>&1
python3 report-tput-metrics.py nohcc-mlc3 tput