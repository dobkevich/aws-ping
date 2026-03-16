#!/bin/bash

# Force numeric locale to C to ensure dot notation for decimals across all systems
export LC_NUMERIC=C

# --- HEADER ---
echo "============================================================================"
echo "AWS Region Latency Tool - Finding the fastest AWS location for your network"
echo "============================================================================"

# --- 1. INTERNAL STATIC REGIONS MAP (Fallback & Naming) ---
# Format: "id:Country, City"
STATIC_DATA=(
    "us-east-1:USA, N. Virginia"
    "us-east-2:USA, Ohio"
    "us-west-1:USA, N. California"
    "us-west-2:USA, Oregon"
    "af-south-1:S. Africa, Cape Town"
    "ap-east-1:China, Hong Kong"
    "ap-east-2:China, Taiwan"
    "ap-south-1:India, Mumbai"
    "ap-south-2:India, Hyderabad"
    "ap-northeast-1:Japan, Tokyo"
    "ap-northeast-2:S. Korea, Seoul"
    "ap-northeast-3:Japan, Osaka"
    "ap-southeast-1:Singapore"
    "ap-southeast-2:Australia, Sydney"
    "ap-southeast-3:Indonesia, Jakarta"
    "ap-southeast-4:Australia, Melbourne"
    "ap-southeast-5:Malaysia, Kuala Lumpur"
    "ap-southeast-6:New Zealand, Auckland"
    "ap-southeast-7:Thailand, Bangkok"
    "ca-central-1:Canada, Montreal"
    "ca-west-1:Canada, Calgary"
    "eu-central-1:Germany, Frankfurt"
    "eu-central-2:Switzerland, Zurich"
    "eu-north-1:Sweden, Stockholm"
    "eu-south-1:Italy, Milan"
    "eu-south-2:Spain, Madrid"
    "eu-west-1:Ireland, Dublin"
    "eu-west-2:UK, London"
    "eu-west-3:France, Paris"
    "me-central-1:UAE, Dubai"
    "me-south-1:Bahrain, Manama"
    "mx-central-1:Mexico, Queretaro"
    "sa-east-1:Brazil, Sao Paulo"
    "il-central-1:Israel, Tel Aviv"
    "cn-north-1:China, Beijing"
    "cn-northwest-1:China, Ningxia"
    "us-gov-east-1:USA, GovCloud East"
    "us-gov-west-1:USA, GovCloud West"
)

# --- 2. FETCH LATEST EXTERNAL DATA ---
echo "Fetching latest region data (AWS CLI + Botocore)..."
MAP_FILE=$(mktemp)

AWS_OUT=$(aws ec2 describe-regions --all-regions --output text 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$AWS_OUT" ]; then
    echo "$AWS_OUT" | awk '/REGIONS/ {id=$NF} /GEOGRAPHY/ {sub(/GEOGRAPHY[ \t]+/, ""); print id "|" $0}' | sed 's/[ \t]*$//' > "$MAP_FILE"
    echo "✓ AWS CLI data integrated."
else
    echo "! AWS CLI failed or not configured. Using internal naming database."
fi

BOTO_REGIONS=$(curl -s "https://raw.githubusercontent.com/boto/botocore/master/botocore/data/endpoints.json" | \
    grep -oP '"[a-z]{2}-[a-z]+-[0-9]+"' | sed 's/"//g')

STATIC_IDS=$(for item in "${STATIC_DATA[@]}"; do echo "${item%%:*}"; done)
FILE_REGIONS=$(awk -F'|' '{print $1}' "$MAP_FILE")
REGIONS_RAW=$(echo -e "$STATIC_IDS\n$BOTO_REGIONS\n$FILE_REGIONS" | sort -u | grep -v "^$")

get_region_name() {
    local id=$1
    for item in "${STATIC_DATA[@]}"; do
        if [[ "${item%%:*}" == "$id" ]]; then echo "${item#*:}"; return; fi
    done
    local name=$(grep "^$id|" "$MAP_FILE" | cut -d'|' -f2)
    if [ -n "$name" ]; then echo "$name"; return; fi
    echo ""
}

# --- 3. PING LOGIC ---
try_ping() {
    local endpoint=$1
    local output=$(ping -c 1 -W 5 -q "$endpoint" 2>/dev/null)
    local val=$(echo "$output" | tail -1 | awk -F '/' '{print $5}')
    if [[ -n "$val" && "$val" =~ ^[0-9] ]]; then
        echo "$val"
        return 0
    fi
    return 1
}

RESULT_DATA=$(mktemp)
COUNT=$(echo "$REGIONS_RAW" | wc -l)
SEPARATOR="----------------------------------------------------------------------------"

# Phase 1 header with a blank line before
echo ""
echo "Phase 1: Initial scan of $COUNT regions (DynamoDB priority)..."

for REGION_ID in $REGIONS_RAW; do
    REGION_ID=$(echo "$REGION_ID" | tr -d '[:space:]')
    REGION_NAME=$(get_region_name "$REGION_ID")
    LATENCY=""
    
    printf "→ %-15s " "$REGION_ID"
    
    # Try DynamoDB first
    LATENCY=$(try_ping "dynamodb.${REGION_ID}.amazonaws.com")
    if [ $? -ne 0 ]; then
        printf "(Retrying DynamoDB: " >&2
        for i in {1..2}; do
            printf "%d/2... " "$i" >&2
            LATENCY=$(try_ping "dynamodb.${REGION_ID}.amazonaws.com")
            [ $? -eq 0 ] && break
        done
        if [ -n "$LATENCY" ]; then printf "OK) " >&2; else printf "FAIL) " >&2; fi
    fi

    # Try EC2 fallback
    if [ -z "$LATENCY" ]; then
        printf "| trying EC2 fallback: " >&2
        for i in {1..3}; do
            printf "%d/3... " "$i" >&2
            LATENCY=$(try_ping "ec2.${REGION_ID}.amazonaws.com")
            [ $? -eq 0 ] && break
        done
        if [ -n "$LATENCY" ]; then printf "OK " >&2; else printf "FAIL " >&2; fi
    fi

    if [ -n "$LATENCY" ]; then
        echo "✓ ${LATENCY} ms"
        echo "${LATENCY}|${REGION_NAME}|${REGION_ID}" >> "$RESULT_DATA"
    else
        echo "✗ Timeout"
        echo "9999|${REGION_NAME}|${REGION_ID}" >> "$RESULT_DATA"
    fi
done

# --- 4. PHASE 2: REFINE TOP 5 ---
echo ""
echo "Phase 2: Refining top 5 regions (3-ping average)..."
TOP_5=$(sort -n -t'|' -k1 "$RESULT_DATA" | grep -v "^9999" | head -n 5)

if [ -n "$TOP_5" ]; then
    while IFS='|' read -r old_lat name id; do
        printf "  Refining %-15s (%s)... " "$id" "$name"
        
        # Determine which service to use for refinement (DynamoDB priority)
        ENDPOINT="dynamodb.${id}.amazonaws.com"
        ping -c 1 -W 2 -q "$ENDPOINT" >/dev/null 2>&1 || ENDPOINT="ec2.${id}.amazonaws.com"
        
        SUM=0
        SUCCESS_COUNT=0
        for i in {1..3}; do
            VAL=$(try_ping "$ENDPOINT")
            if [ $? -eq 0 ]; then
                SUM=$(awk "BEGIN {print $SUM + $VAL}")
                ((SUCCESS_COUNT++))
            fi
        done
        
        if [ $SUCCESS_COUNT -gt 0 ]; then
            AVG=$(awk "BEGIN {print $SUM / $SUCCESS_COUNT}")
            # Replace old result in data file
            sed -i "/|$id$/d" "$RESULT_DATA"
            echo "$AVG|$name|$id" >> "$RESULT_DATA"
            printf "New Avg: %.3f ms\n" "$AVG"
        else
            printf "Failed during refinement.\n"
        fi
    done <<< "$TOP_5"
fi

# --- 5. FINAL REPORT ---
echo ""
echo "FINAL RESULTS (Sorted by Latency):"
echo "$SEPARATOR"
printf "%-32s %-25s %-15s\n" "Region Name" "Region ID" "Avg Latency"
echo "$SEPARATOR"

sort -n -t'|' -k1 "$RESULT_DATA" | while IFS='|' read -r latency name id; do
    if [ "$latency" == "9999" ]; then
        printf "%-32s %-25s %-15s\n" "$name" "$id" "Timeout"
    else
        printf "%-32s %-25s %-15s\n" "$name" "$id" "$(printf "%.3f" "$latency") ms"
    fi
done

echo "$SEPARATOR"
WINNER=$(sort -n -t'|' -k1 "$RESULT_DATA" | head -n 1 | cut -d'|' -f3)
echo "Least Latency:"
echo "$WINNER"

# Cleanup
rm "$RESULT_DATA" "$MAP_FILE"
