#!/bin/bash

# deploy-zones.sh - Deploy generated zone files and configuration to BIND
# This script requires sudo privileges to copy files and restart services
# 
# Usage: sudo ./deploy-zones.sh <config_file> <zone_file1> [zone_file2 ...] [-- <slave_ip> <slave_config>]
# 
# Master deployment:
#   sudo ./deploy-zones.sh khms-zones.conf 10.in-addr.arpa.zone 168.192.in-addr.arpa.zone ...
# 
# Master + Slave deployment:
#   sudo ./deploy-zones.sh khms-zones.conf 10.in-addr.arpa.zone ... -- 10.18.0.1 khms-zones.conf.tmp

set -e

# Parse arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <config_file> <zone_file1> [zone_file2 ...] [-- <slave_ip> <slave_config>]" >&2
    exit 1
fi

# Get the current working directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Change to working directory
cd "$SCRIPT_DIR"

# Separate master files from optional slave files
MASTER_FILES=()
SLAVE_IP=""
SLAVE_CONFIG=""

# Process arguments until we find "--" separator
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        shift
        if [[ $# -lt 2 ]]; then
            echo "Error: Slave deployment requires IP address and config file" >&2
            exit 1
        fi
        SLAVE_IP="$1"
        SLAVE_CONFIG="$2"
        break
    else
        MASTER_FILES+=("$arg")
        shift
    fi
done

echo "========================================="
echo "Deploying BIND configuration and zones..."
echo "========================================="

# Validate master files exist
echo "Validating master files..."
for file in "${MASTER_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: File not found: $file" >&2
        exit 1
    fi
done

# Copy all master files to parent directory
echo "Copying master files to $PARENT_DIR..."
for file in "${MASTER_FILES[@]}"; do
    echo "  Copying: $file"
    cp -av "$file" "$PARENT_DIR/"
done

# Restart BIND9 on master
echo ""
echo "Restarting BIND9 on master..."
systemctl restart bind9
systemctl status bind9

# Optional: Deploy to slave server
if [[ -n "$SLAVE_IP" && -n "$SLAVE_CONFIG" ]]; then
    echo ""
    echo "========================================="
    echo "Deploying to slave server: $SLAVE_IP"
    echo "========================================="

    if [[ ! -f "$SLAVE_CONFIG" ]]; then
        echo "Error: Slave config file not found: $SLAVE_CONFIG" >&2
        exit 1
    fi

    echo "Copying slave config to $SLAVE_IP:/etc/bind/"
    scp -p "$SLAVE_CONFIG" "root@$SLAVE_IP:/etc/bind/"

    echo "Comparing and updating slave configuration..."
    MASTER_BASENAME=$(basename "${MASTER_FILES[0]}")
    SLAVE_BASENAME=$(basename "$SLAVE_CONFIG")
    
    # Compare and update config on slave if different
    ssh "root@$SLAVE_IP" \
        "cmp -s /etc/bind/$SLAVE_BASENAME /etc/bind/$MASTER_BASENAME || \
         mv -v --backup=numbered /etc/bind/$SLAVE_BASENAME /etc/bind/$MASTER_BASENAME"

    echo "Restarting BIND9 on slave..."
    ssh "root@$SLAVE_IP" systemctl restart bind9
    ssh "root@$SLAVE_IP" systemctl status bind9
fi

echo ""
echo "========================================="
echo "Deployment complete!"
echo "========================================="
