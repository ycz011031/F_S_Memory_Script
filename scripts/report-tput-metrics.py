import os
import sys
import numpy as np

# Check if the directory argument is provided
if len(sys.argv) != 3:
    print("Usage: python script.py <exp_name> <metrics>")
    sys.exit(1)

# Get the directory where the script is located and change directory
script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
os.chdir(script_dir)

# Get the filename from the user
exp_name = sys.argv[1]
metrics_arg = sys.argv[2]
metrics = metrics_arg.split(",")
metrics = list(map(str.lower, metrics))

# Combine the base path with the filename
full_path = os.path.join("../utils/reports/", exp_name, "tput_metrics.dat")

results = np.genfromtxt(full_path, dtype=float, delimiter=',', names=True)

# -------- Print out metrics from paper ----------- #


def misses_per_page(misses, tput_mean):
    # a bit of a round-a-bout way from when I used per desc, but it works so not touching it!
    mbs_per_second = tput_mean * 125
    descriptors_per_second = mbs_per_second * 4 
    misses_per_page = misses / descriptors_per_second
    # GETTING MISSES PER PAGE
    misses_per_page = misses_per_page / 64
    return misses_per_page


tput = results['net_tput_mean']
sent_packets = results['sent_packets_mean']/20
drop_rate = results["retx_rate_mean"]
cpu = results["cpu_utils_mean"]

acks_page = misses_per_page(sent_packets, tput)
iotlb_miss_page = misses_per_page(results['iotlb_misses_mean'], tput)
l1_miss_page = misses_per_page(results['l1_misses_mean'], tput)
l2_miss_page = misses_per_page(results['l2_misses_mean'], tput)
l3_miss_page = misses_per_page(results['l3_misses_mean'], tput)

print(f"------- {exp_name} Run Metrics -------")

if "tput" in metrics or "all" in metrics:
    print(f"Throughput: {tput}")
if "cpu" in metrics or "all" in metrics:
    print(f"CPU Util: {cpu}")
if "drops" in metrics or "all" in metrics:
    print(f"Drop rate: {drop_rate}")
if "acks" in metrics or "all" in metrics:
    print(f"Acks per page: {acks_page}")
if "iommu" in metrics or "all" in metrics:
    # Per page, on ICX (family 6 model 106). Only IOTLB is a miss count; the
    # other three are page-walk-cache HITS bucketed by page size, not L1/L2/L3
    # misses. The underlying .dat columns keep their historical names.
    print(f"Per page:")
    print(f"\tIOTLB misses    : {iotlb_miss_page}")
    print(f"\tPWC 512G hits   : {l1_miss_page}")
    print(f"\tPWC 1G hits     : {l2_miss_page}")
    print(f"\tPWC 2M hits     : {l3_miss_page}")

if (not results['net_tput_stddev']):
    print("")
    exit()

print(f"------- {exp_name} Run Metrics stddev -------")
if "tput" in metrics or "all" in metrics:
    print(f"Throughput: {results['net_tput_stddev']}")
if "cpu" in metrics or "all" in metrics:
    print(f"CPU Util: {results['cpu_utils_stddev']}")
if "drops" in metrics or "all" in metrics:
    print(f"Drop rate: {results['retx_rate_stddev']}")
if "acks" in metrics or "all" in metrics:
    print(f"Acks per page: {misses_per_page(results['sent_packets_stddev'], tput)}")
if "iommu" in metrics or "all" in metrics:
    print(f"Per page:")
    print(f"\tIOTLB misses    : {misses_per_page(results['iotlb_misses_stddev'],tput)}")
    print(f"\tPWC 512G hits   : {misses_per_page(results['l1_misses_stddev'],tput)}")
    print(f"\tPWC 1G hits     : {misses_per_page(results['l2_misses_stddev'],tput)}")
    print(f"\tPWC 2M hits     : {misses_per_page(results['l3_misses_stddev'],tput)}")
print("")
