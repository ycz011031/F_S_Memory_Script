import sys
import numpy as np
import statistics
import subprocess

EXP_NAME = sys.argv[1]
NUM_RUNS = int(sys.argv[2])
COLLECT_MLC_TPUT = int(sys.argv[3])

FILE_NAME = "../utils/reports/" + EXP_NAME
print("Collecting throughput metrics for experiment:", EXP_NAME, "with", NUM_RUNS, "runs and MLC throughput collection set to", COLLECT_MLC_TPUT)
command = 'mkdir -p ' + FILE_NAME
result = subprocess.run(command, shell=True, capture_output=True, text=True)

print("Collecting throughput stats from all runs and storing to", FILE_NAME + '/tput_metrics.dat')

net_tputs = []
retx_rates = []
sent_packets = []
mem_bws = []
pcie_wr_tput = []
iotlb_hits = []
iotlb_misses = []
ctxt_misses = []
l1_miss = []
l2_miss = []
l3_miss = []
mem_read = []
cpu_utils = []
mlc_tputs = []

for i in range(NUM_RUNS):
    with open(FILE_NAME + '-RUN-server-' + str(i) + '/iperf.bw.rpt') as f1:
        for line in f1:
            tput = float(line.split()[-1])
            if (tput > 0):
                net_tputs.append(tput)
            break

    with open(FILE_NAME + '-RUN-server-' + str(i) + '/retx.rpt') as f1:
        for line in f1:
            line_str = line.split()
            if (line_str[0] == 'Retx_percent:'):  # always come last so we can break
                retx_pct = float(line_str[-1])
                if (retx_pct >= 0):
                    retx_rates.append(retx_pct)
                break
            elif (line_str[0] == "Recv:"):
                sent = float(line_str[-1])
                sent_packets.append(sent)

    with open(FILE_NAME + '-RUN-server-' + str(i) + '/membw.rpt') as f1:
        try:
            for line in f1:
                line_str = line.split()
                if (line_str[0] != 'Node1_total_bw:'):
                    continue
                else:
                    membw = float(line_str[-1])
                    if (membw >= 0):
                        mem_bws.append(membw)
                    break
        except Exception as e:
            mem_bws.append(0)

    with open(FILE_NAME + '-RUN-server-' + str(i) + '/cpu_util.rpt') as f1:
        for line in f1:
            line_str = line.split()
            if (line_str[0] != 'avg_cpu_util:'):
                continue
            else:
                cpu_util = float(line_str[-1])
                if (cpu_util >= 0):
                    cpu_utils.append(cpu_util)
                break
    try: 
        with open(FILE_NAME + '-RUN-server-' + str(i) + '/pcie.rpt') as f1:
            for line in f1:
                line_str = line.split()
                if (line_str[0] == 'PCIe_wr_tput:'):
                    pcie_tput = float(line_str[-1])
                    if (pcie_tput >= 0):
                        pcie_wr_tput.append(pcie_tput)
                elif (line_str[0] == 'IOTLB_hits:'):
                    iotlb_hits_ = float(line_str[-1])
                    iotlb_hits.append(iotlb_hits_)
                elif (line_str[0] == 'IOTLB_misses:'):
                    iotlb_misses_ = float(line_str[-1])
                    iotlb_misses.append(iotlb_misses_)
                elif (line_str[0] == 'CTXT_Miss:'):
                    ctxt_misses_ = float(line_str[-1])
                    ctxt_misses.append(ctxt_misses_)
                elif (line_str[0] == 'L1_Miss:'):
                    l1_misses_ = float(line_str[-1])
                    l1_miss.append(l1_misses_)
                elif (line_str[0] == 'L2_Miss:'):
                    l2_misses_ = float(line_str[-1])
                    l2_miss.append(l2_misses_)
                elif (line_str[0] == 'L3_Miss:'):
                    l3_misses_ = float(line_str[-1])
                    l3_miss.append(l3_misses_)
                elif (line_str[0] == 'Mem_Read:'):
                    mem_read_ = float(line_str[-1])
                    mem_read.append(mem_read_)
    except Exception as e:
        pcie_wr_tput.append(0) 
        iotlb_hits.append(0)
        iotlb_misses.append(0)
        ctxt_misses.append(0) 
        l1_miss.append(0)
        l2_miss.append(0)
        l3_miss.append(0)
        mem_read.append(0)

    if (COLLECT_MLC_TPUT > 0 and False):
        with open(FILE_NAME + '-MLCRUN-' + str(i) + '/mlc.log') as f1:
            for line in f1:
                if line.startswith(' 00000'):
                    tput = float(line.split()[-1])
                    if (tput >= 0):
                        mlc_tputs.append(tput)
                    break


net_tput_mean = statistics.mean(net_tputs)
# the -client and randread runners skip the retx scp, so these can be empty
retx_rate_mean = statistics.mean(retx_rates) if retx_rates else 0
sent_packets_mean = statistics.mean(sent_packets) if sent_packets else 0
mem_bw_mean = statistics.mean(mem_bws)
pcie_wr_tput_mean = statistics.mean(pcie_wr_tput)
iotlb_hits_mean = statistics.mean(iotlb_hits)
iotlb_misses_mean = statistics.mean(iotlb_misses)
ctxt_misses_mean = statistics.mean(ctxt_misses)
l1_misses_mean = statistics.mean(l1_miss)
l2_misses_mean = statistics.mean(l2_miss)
l3_misses_mean = statistics.mean(l3_miss)
mem_read_mean = statistics.mean(mem_read)
cpu_utils_mean = statistics.mean(cpu_utils)

if NUM_RUNS > 1:
    net_tput_stddev = statistics.stdev(net_tputs)
    mem_bw_stddev = statistics.stdev(mem_bws)
    retx_rate_stddev = statistics.stdev(retx_rates)
    sent_packets_stddev = statistics.stdev(sent_packets)
    pcie_wr_tput_stddev = statistics.stdev(pcie_wr_tput)
    iotlb_hits_stddev = statistics.stdev(iotlb_hits)
    iotlb_misses_stddev = statistics.stdev(iotlb_misses)
    ctxt_misses_stddev = statistics.stdev(ctxt_misses)
    l1_misses_stddev = statistics.stdev(l1_miss)
    l2_misses_stddev = statistics.stdev(l2_miss)
    l3_misses_stddev = statistics.stdev(l3_miss)
    mem_read_stddev = statistics.stdev(mem_read)
    cpu_utils_stddev = statistics.stdev(cpu_utils)
else:
    net_tput_stddev = 0
    mem_bw_stddev = 0
    retx_rate_stddev = 0
    sent_packets_stddev = 0
    pcie_wr_tput_stddev = 0
    iotlb_hits_stddev = 0
    iotlb_misses_stddev = 0
    ctxt_misses_stddev = 0
    l1_misses_stddev = 0
    l2_misses_stddev = 0
    l3_misses_stddev = 0
    mem_read_stddev = 0
    cpu_utils_stddev = 0

mlc_tput_mean = 0
mlc_tput_stddev = 0

if (COLLECT_MLC_TPUT > 0):
    mlc_tput_mean = statistics.mean(mlc_tputs)
    if NUM_RUNS > 1:
        mlc_tput_stddev = statistics.stdev(mlc_tputs)
    else:
        mlc_tput_stddev = 0

# TODO: convert to tuple list and use zip with unpacking to make it cleaner to read and less error prone
output_list = [("cpu_utils_mean", cpu_utils_mean), ("cpu_utils_stddev", cpu_utils_stddev), ("net_tput_mean", net_tput_mean), ("net_tput_stddev", net_tput_stddev),
               ("retx_rate_mean", retx_rate_mean), ("retx_rate_stddev", retx_rate_stddev),
               ("mem_bw_mean", mem_bw_mean), ("mem_bw_stddev", mem_bw_stddev), ("pcie_wr_tput_mean", pcie_wr_tput_mean),
               ("pcie_wr_tput_stddev", pcie_wr_tput_stddev), ("iotlb_hits_mean", iotlb_hits_mean), ("iotlb_hits_stddev", iotlb_hits_stddev), 
               ("iotlb_misses_mean", iotlb_misses_mean), ("iotlb_misses_stddev", iotlb_misses_stddev), ("ctxt_misses_mean", ctxt_misses_mean),
               ("ctxt_misses_stddev", ctxt_misses_stddev), ("l1_misses_mean", l1_misses_mean), ("l1_misses_stddev", l1_misses_stddev), 
               ("l2_misses_mean", l2_misses_mean), ("l2_misses_stddev", l2_misses_stddev), ("l3_misses_mean", l3_misses_mean), 
               ("l3_misses_stddev", l3_misses_stddev), ("mem_read_mean", mem_read_mean), ("mem_read_stddev", mem_read_stddev), 
               ("mlc_tput_mean", mlc_tput_mean), ("mlc_tput_stddev", mlc_tput_stddev), ("sent_packets_mean", sent_packets_mean), 
               ("sent_packets_stddev", sent_packets_stddev)]

headers, outputs = zip(*output_list)
headers = ",".join(headers) 
outputs = list(outputs)


# Save array to DAT file
np.savetxt(FILE_NAME + '/tput_metrics.dat',
           [outputs], delimiter=",", header=headers, comments='', fmt='%.10f')
