#!/bin/bash

# Complete automated setup: Deploy Cassandra, load data, and register with WatsonX Data
# One-command workshop setup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Complete Cassandra Workshop Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}This script will:${NC}"
echo -e "  1. Deploy Cassandra container"
echo -e "  2. Load sample workshop data"
echo -e "  3. Register with WatsonX Data"
echo -e "  4. Create catalog"
echo
echo -e "${YELLOW}Estimated time: 2-3 minutes${NC}"
echo
read -p "Press Enter to continue or Ctrl+C to cancel..."
echo

# Step 1: Deploy Cassandra
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 1/3: Deploying Cassandra${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
"$SCRIPT_DIR/deploy-cassandra.sh"
echo

# Step 2: Load sample data
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 2/3: Loading Sample Data${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
"$SCRIPT_DIR/load-sample-data.sh"
echo

# Step 3: Register with WatsonX Data
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 3/3: Registering with WatsonX Data${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
"$SCRIPT_DIR/register-with-watsonx.sh"
echo

# Final summary
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  🎉 Complete Setup Finished!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}What's Ready:${NC}"
echo -e "  ${GREEN}✓${NC} Cassandra 5.0 running"
echo -e "  ${GREEN}✓${NC} Sample data loaded (6 tables)"
echo -e "  ${GREEN}✓${NC} Registered with WatsonX Data"
echo -e "  ${GREEN}✓${NC} Catalog created"
echo
echo -e "${YELLOW}Quick Test Query:${NC}"
echo -e "  ${BLUE}Open WatsonX Data UI: https://localhost:9443${NC}"
echo -e "  ${BLUE}Go to Query Workspace${NC}"
echo -e "  ${BLUE}Run: SELECT * FROM cassandra_catalog.workshop.customers;${NC}"
echo
echo -e "${YELLOW}Available Tables:${NC}"
echo -e "  ${BLUE}• customers${NC} - Customer information"
echo -e "  ${BLUE}• products${NC} - Product catalog"
echo -e "  ${BLUE}• orders${NC} - Order records"
echo -e "  ${BLUE}• order_items${NC} - Order line items"
echo -e "  ${BLUE}• sensor_readings${NC} - IoT sensor data"
echo -e "  ${BLUE}• transactions${NC} - Financial transactions"
echo
echo -e "${YELLOW}Management Commands:${NC}"
echo -e "  ${BLUE}CQL Shell:${NC} podman exec -it cassandra-workshop cqlsh -u cassandra -p cassandra"
echo -e "  ${BLUE}Stop:${NC} podman stop cassandra-workshop"
echo -e "  ${BLUE}Start:${NC} podman start cassandra-workshop"
echo -e "  ${BLUE}Logs:${NC} podman logs cassandra-workshop"
echo
echo -e "${GREEN}✓ Ready for the workshop!${NC}"
echo

# Made with Bob
