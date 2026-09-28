


def count_invalidation(file: str) -> dict:
    """
    iperf3-14236   [004] b..2.   484.455404: intel_iommu_iotlb_sync_map: intel_iommu_iotlb_sync_map: core: 4, iova: cc990000 size: 0x1000
    iperf3-14236   [004] b..2.   484.455407: mlx5e_xmit: TX map: mlx5e_dma_push_with_log: core: 4, size: 66, addr: cc9904fe
    iperf3-14236   [004] ..s1.   484.455411: mlx5e_tx_wi_dma_unmap.isra.0: TX unmap: mlx5e_tx_dma_unmap: core: 4, size: 66, addr: cc9904fe
    iperf3-14236   [004] ..s1.   484.455413: mlx5e_page_dma_unmap: RX unmap: mlx5e_page_dma_unmap: core: 4, iova=f5dff000 pfn=400138
    iperf3-14236   [004] ..s1.   484.455415: mlx5e_page_dma_unmap: RX unmap: mlx5e_page_dma_unmap: core: 4, iova=f2607000 pfn=3e765d
    iperf3-14236   [004] ..s1.   484.455416: mlx5e_page_dma_unmap: RX unmap: mlx5e_page_dma_unmap: core: 4, iova=ece5a000 pfn=3f4915
    iperf3-14236   [004] ..s1.   484.455417: mlx5e_page_dma_unmap: RX unmap: mlx5e_page_dma_unmap: core: 4, iova=ecb0f000 pfn=3fa2a3
    """
    
    count_dict = {
        "total": 0,

        "RX map": 0,
        "RX unmap": 0,
        "TX map": 0,
        "TX unmap": 0,
        
        "page_pool_put_unrefed_page": 0,
        "recycle_in_cache": 0,
    
        "start_time": -1.0,
        "end_time": -1.0,

        "total_per_sec" : 0.0,
        "RX map_per_sec": 0.0,
        "RX unmap_per_sec": 0.0,
        "TX map_per_sec": 0.0,
        "TX unmap_per_sec": 0.0,
    }
    
    with open(file, "r") as f:
        for line in f:
            line = line.strip()
            operation_happens = False
            if line:
                # Check if the line contains "RX map" or "TX map"
                if "RX map" in line:
                    count_dict["RX map"] += 1
                    operation_happens = True
                elif "TX map" in line:
                    count_dict["TX map"] += 1
                    operation_happens = True
                elif "RX unmap" in line:
                    count_dict["RX unmap"] += 1
                    operation_happens = True
                elif "TX unmap" in line:
                    count_dict["TX unmap"] += 1
                    operation_happens = True
                elif "page_pool_put_unrefed_page" in line:
                    count_dict["page_pool_put_unrefed_page"] += 1
                    operation_happens = True
                elif "page_pool_recycle_in_cache" in line:
                    count_dict["recycle_in_cache"] += 1
                    operation_happens = True
                
                
                if operation_happens:
                    # Extract the time from the line
                    time_str = line.split()[3].strip()[:-1]
                    time_val = float(time_str)
                    
                    # Update start and end times
                    if count_dict["start_time"] < 0.0 or time_val < count_dict["start_time"]:
                        count_dict["start_time"] = time_val
                    if time_val > count_dict["end_time"]:
                        count_dict["end_time"] = time_val
                
    
    
    count_dict["total"] = count_dict["RX map"] + count_dict["TX map"] + count_dict["RX unmap"] + count_dict["TX unmap"]
        
    # Calculate per second rate
    duration_sec = count_dict["end_time"] - count_dict["start_time"]
    if duration_sec > 0:
        count_dict["total_per_sec"] = count_dict["total"] / duration_sec
        count_dict["RX map_per_sec"] = count_dict["RX map"] / duration_sec
        count_dict["RX unmap_per_sec"] = count_dict["RX unmap"] / duration_sec
        count_dict["TX map_per_sec"] = count_dict["TX map"] / duration_sec
        count_dict["TX unmap_per_sec"] = count_dict["TX unmap"] / duration_sec
        
    return count_dict


def save_to_csv(stat_dict: dict, file: str):
    """
    Save the statistics to a CSV file.
    """
    import csv

    with open(file, "w", newline="") as csvfile:
        fieldnames = stat_dict.keys()
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        writer.writerow(stat_dict)

if __name__ == "__main__":
    import argparse
    import os
    import sys
    import time

    parser = argparse.ArgumentParser(
        description="Count the number of invalidations in a given directory."
    )
    parser.add_argument(
        "--dir",
        type=str,
        default=".",
        help="Directory to count invalidations in (default: current directory)",
    )
    
    args = parser.parse_args()
    
    stat_dict = count_invalidation(os.path.join(args.dir, "iova.log"))
    
    print(stat_dict)
    
    count_path = os.path.join(args.dir, "invalidation_count.csv")
    
    save_to_csv(stat_dict, count_path)
    print(f"Saved to {count_path}")