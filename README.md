# AWS Region Latency Checker

A high-precision Bash script designed to identify the fastest AWS regions from your current network location. It uses a multi-phase approach and smart retry logic to ensure accurate results even for regions with strict ICMP filtering.

## Features

- **Smart Multi-Service Check**: Prioritizes **DynamoDB** endpoints (often faster and more stable) with a fallback to **EC2** endpoints.
- **Dynamic Region Discovery**: Automatically fetches the latest regions from the **AWS CLI** and the official **Botocore (AWS SDK)** database.
- **Two-Phase Analysis**:
    - **Phase 1 (General Scan)**: Quickly scans all known AWS regions with a 3+3 retry strategy (3x DynamoDB, then 3x EC2).
    - **Phase 2 (Refinement)**: Re-tests the **Top 5** fastest regions using a 3-ping average to eliminate jitter and ensure the highest precision.
- **Human-Readable Geography**: Maps region IDs (e.g., `eu-central-1`) to friendly names (e.g., `Germany, Frankfurt`) using an internal database and AWS CLI metadata.
- **Automation Ready**: Outputs the final winning region ID in a clean format at the end, making it easy to use in other scripts.
- **High Compatibility**: Uses `LC_NUMERIC=C` to ensure correct decimal formatting across different system locales.

## Requirements

- `bash`
- `curl`
- `ping`
- `awk`
- `sed`
- `aws` CLI (Optional, but recommended for the most up-to-date geography names)

## Installation

### Method 1: Git Clone (Recommended)
```bash
git clone https://github.com/dobkevich/aws-ping.git
cd aws-ping
chmod +x aws-ping.sh
```

### Method 2: Direct Run (One-liner)
Run the script directly from the web without local installation:
```bash
curl -sL https://raw.githubusercontent.com/dobkevich/aws-ping/main/aws-ping.sh | bash
```

## Usage

Run the script directly from your terminal:
```bash
./aws-ping.sh
```

### Script Output
1. **Header**: Tool identification.
2. **Region Fetching**: Status of external data integration.
3. **Phase 1**: Real-time progress of the initial scan.
4. **Phase 2**: Detailed refinement of the top 5 candidates.
5. **Final Table**: All regions sorted by average latency (fastest first).
6. **Winner**: The ID of the region with the least latency.

## Logic Overview

- **Timeout**: Strictly set to 5 seconds per packet to keep the scan efficient.
- **Failover**: If a region blocks ICMP on DynamoDB, the script immediately attempts the EC2 endpoint.
- **Sorting**: All results are sorted numerically by latency. Regions that timeout are pushed to the bottom.

## Example Output

```text
FINAL RESULTS (Sorted by Latency):
----------------------------------------------------------------------------
Region Name                      Region ID                 Avg Latency    
----------------------------------------------------------------------------
Switzerland, Zurich              eu-central-2              50.293 ms      
Germany, Frankfurt               eu-central-1              53.152 ms      
...
Least Latency:
eu-central-2
```
