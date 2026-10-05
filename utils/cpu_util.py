import sys

INPUT_FILE = sys.argv[1]

cpu_util = {}
num_samples = {}

with open(INPUT_FILE) as f1:
    for line in f1:
        elements = line.split()
        # sar prints "12:00:01 AM  3 ... %idle" (9 fields) under a 12-hour
        # locale and "00:00:01  3 ... %idle" (8 fields) under a 24-hour one.
        # Index from the end so both parse; header rows ("CPU") are skipped.
        if (len(elements) in (8, 9) and elements[-7].isdigit()
                and not line.startswith("Average")):
            cpu = int(elements[-7])
            util = float(elements[-1])
            if cpu not in cpu_util:
                cpu_util[cpu] = (100 - util)
                num_samples[cpu] = 1
            else:
                cpu_util[cpu] += (100 - util)
                num_samples[cpu] += 1

total_util = 0
num_cpus = 0
for cpu in cpu_util:
    if num_samples[cpu] != 0:
        cpu_util[cpu] /= num_samples[cpu]
        total_util += cpu_util[cpu]
        num_cpus += 1

print("cpu_utils: ",cpu_util)
print("num_samples: ",num_samples)
print("avg_cpu_util: ",total_util/num_cpus)
