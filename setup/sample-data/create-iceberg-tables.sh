#!/bin/bash
################################################################################
# Create Iceberg Tables in WatsonX Data
# This script creates Iceberg analytics tables after Cassandra is registered
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Presto CLI path - try repository installation first, then fall back to old locations
PRESTO_CLI=""
POSSIBLE_LOCATIONS=(
    "$REPO_ROOT/.watsonx-data/ibm-lh-dev/bin/presto-cli"
    "$HOME/.local/watsonx-data/ibm-lh-dev/bin/presto-cli"
)

for location in "${POSSIBLE_LOCATIONS[@]}"; do
    if [ -f "$location" ]; then
        PRESTO_CLI="$location"
        break
    fi
done

echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Creating Iceberg Tables in WatsonX Data${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

# Check if Presto CLI exists
if [ ! -f "$PRESTO_CLI" ]; then
    echo -e "${RED}✗ Presto CLI not found at: $PRESTO_CLI${NC}"
    echo
    echo -e "${YELLOW}Please update the PRESTO_CLI variable in this script with the correct path.${NC}"
    echo -e "${YELLOW}Find it with: find ~/Documents -name presto-cli -type f 2>/dev/null${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found Presto CLI${NC}"
echo

# Check if Presto is running — wxd installs under the rootful podman connection,
# so check both rootless (default) and rootful (watsonx-workshop-root).
if ! { podman ps --format "{{.Names}}" 2>/dev/null; \
       podman --connection watsonx-workshop-root ps --format "{{.Names}}" 2>/dev/null; } | grep -q "ibm-lh-presto"; then
    echo -e "${RED}✗ WatsonX Data Presto is not running${NC}"
    echo -e "${YELLOW}Please start WatsonX Data first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ WatsonX Data Presto is running${NC}"
echo

# The presto-cli wrapper runs inside a container, so host file paths aren't
# visible unless we mount them. LH_SANDBOX_DIR mounts the given host path at
# the same path inside the container (see ibm-lh-dev/bin/common-utils.sh).
export LH_SANDBOX_DIR="$REPO_ROOT"

# The wrapper shells into the rootful podman connection; make sure that's
# the default so wxd's ibm-lh-network is reachable.
if command -v podman &>/dev/null; then
    if podman system connection list 2>/dev/null | grep -q "watsonx-workshop-root"; then
        podman system connection default watsonx-workshop-root >/dev/null 2>&1 || true
    fi
fi

# Function to create tables for a dataset
create_dataset_tables() {
    local dataset=$1
    local sql_file="$SCRIPT_DIR/$dataset/iceberg_schema.sql"

    if [ ! -f "$sql_file" ]; then
        echo -e "${YELLOW}⚠ SQL file not found: $sql_file${NC}"
        return 1
    fi

    echo -e "${BLUE}Creating $dataset Iceberg tables...${NC}"

    # Use an absolute path so the in-container view resolves under LH_SANDBOX_DIR.
    if "$PRESTO_CLI" --file "$sql_file"; then
        echo -e "${GREEN}✓ $dataset tables created successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to create $dataset tables${NC}"
        return 1
    fi
}

# Create tables for each dataset
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Creating E-commerce Tables${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
create_dataset_tables "ecommerce"
echo

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Creating IoT Tables${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
create_dataset_tables "iot"
echo

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Creating Financial Tables${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
create_dataset_tables "financial"
echo

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Iceberg table creation complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}Note:${NC} These Iceberg tables are standalone — they do not depend"
echo -e "on Cassandra. To run federated queries joining Cassandra and Iceberg,"
echo -e "you'll also need to register Cassandra in the WatsonX Data UI."
echo

# Made with Bob
