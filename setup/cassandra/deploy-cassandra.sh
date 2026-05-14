#!/bin/bash

# Deploy Apache Cassandra in the same Podman machine as WatsonX Data
# This allows WatsonX Data to federate queries with Cassandra

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Apache Cassandra Deployment for WatsonX Data Workshop${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

# Configuration
CASSANDRA_VERSION="5.0"
CASSANDRA_CONTAINER_NAME="cassandra-workshop"
CASSANDRA_PORT="9042"
CASSANDRA_JMX_PORT="7199"

# On macOS, Podman runs containers inside a Linux VM ("podman machine") and
# we must select the running machine before issuing container commands. On
# native Linux — including WSL2 Ubuntu, which is the supported Windows path —
# Podman runs containers directly and there is no machine to select.
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$OS_TYPE" == "darwin" ]]; then
    PODMAN_MACHINE=$(podman machine list --format "{{if .Running}}{{.Name}}{{end}}" | head -1)

    if [ -z "$PODMAN_MACHINE" ]; then
        echo -e "${RED}Error: No running Podman machine found${NC}"
        echo -e "${YELLOW}Available machines:${NC}"
        podman machine list
        echo
        echo -e "${YELLOW}Start a machine with: podman machine start <machine-name>${NC}"
        exit 1
    fi

    echo -e "${BLUE}Using Podman machine: ${PODMAN_MACHINE}${NC}"

    # Check if Podman machine is running
    echo -e "${YELLOW}Checking Podman machine status...${NC}"
    if ! podman machine list | grep -q "$PODMAN_MACHINE.*Currently running"; then
        echo -e "${RED}Error: Podman machine '$PODMAN_MACHINE' is not running${NC}"
        echo -e "${YELLOW}Start it with: podman machine start $PODMAN_MACHINE${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Podman machine is running${NC}"
    echo

    # Pin the default connection to the *rootful* one. `podman system
    # connection list` exposes two connections per machine (e.g.
    # "watsonx-workshop" rootless and "watsonx-workshop-root" rootful), and
    # Cassandra has to deploy into the same context as watsonx.data (rootful)
    # so they share `ibm-lh-network` and Cassandra advertises a broadcast
    # address watsonx can reach. The previous `default "$PODMAN_MACHINE"`
    # targeted the rootless connection and silently put cassandra in a
    # different network, breaking federation (closes #53).
    if podman system connection list 2>/dev/null | grep -q "${PODMAN_MACHINE}-root"; then
        podman system connection default "${PODMAN_MACHINE}-root" 2>/dev/null || true
    else
        podman system connection default "$PODMAN_MACHINE" 2>/dev/null || true
    fi
else
    PODMAN_MACHINE=""
    echo -e "${BLUE}Detected native Linux Podman (no machine layer)${NC}"
    echo
fi

# Check if Cassandra container already exists
if podman ps -a --format "{{.Names}}" | grep -q "^${CASSANDRA_CONTAINER_NAME}$"; then
    echo -e "${YELLOW}Cassandra container already exists${NC}"
    echo -e "${BLUE}Checking status...${NC}"
    
    if podman ps --format "{{.Names}}" | grep -q "^${CASSANDRA_CONTAINER_NAME}$"; then
        echo -e "${GREEN}✓ Cassandra is already running${NC}"
        echo
        echo -e "${YELLOW}Container details:${NC}"
        podman ps --filter "name=${CASSANDRA_CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo
        echo -e "${BLUE}To restart: podman restart ${CASSANDRA_CONTAINER_NAME}${NC}"
        echo -e "${BLUE}To stop: podman stop ${CASSANDRA_CONTAINER_NAME}${NC}"
        echo -e "${BLUE}To remove: podman rm -f ${CASSANDRA_CONTAINER_NAME}${NC}"
        exit 0
    else
        echo -e "${YELLOW}Starting existing container...${NC}"
        podman start "$CASSANDRA_CONTAINER_NAME"
        echo -e "${GREEN}✓ Cassandra started${NC}"
    fi
else
    # Pull Cassandra image
    echo -e "${YELLOW}Pulling Cassandra ${CASSANDRA_VERSION} image...${NC}"
    echo -e "${BLUE}This may take a few minutes on first run...${NC}"
    
    # Try to pull the image with better error handling
    if ! podman pull docker.io/library/cassandra:${CASSANDRA_VERSION} 2>&1 | tee /tmp/cassandra-pull.log; then
        echo -e "${RED}✗ Failed to pull Cassandra image${NC}"
        echo
        
        # Check if it's a DNS issue
        if grep -q "no such host" /tmp/cassandra-pull.log; then
            echo -e "${YELLOW}⚠️  DNS Resolution Issue Detected${NC}"
            echo
            if [ -n "$PODMAN_MACHINE" ]; then
                echo -e "${BLUE}The Podman machine cannot resolve Docker Hub (registry-1.docker.io)${NC}"
                echo
                echo -e "${YELLOW}Quick Fix:${NC}"
                echo -e "  1. ${BLUE}Restart the Podman machine:${NC}"
                echo -e "     ${GREEN}podman machine stop $PODMAN_MACHINE${NC}"
                echo -e "     ${GREEN}podman machine start $PODMAN_MACHINE${NC}"
                echo
                echo -e "  2. ${BLUE}Then re-run this script${NC}"
                echo
                echo -e "${YELLOW}Alternative Fix (if restart doesn't work):${NC}"
                echo -e "  ${BLUE}Set custom DNS in the Podman machine:${NC}"
                echo -e "     ${GREEN}podman machine ssh $PODMAN_MACHINE${NC}"
                echo -e "     ${GREEN}echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf${NC}"
                echo -e "     ${GREEN}exit${NC}"
                echo
            else
                echo -e "${BLUE}Podman cannot resolve Docker Hub (registry-1.docker.io)${NC}"
                echo
                echo -e "${YELLOW}On Linux / WSL2 this is usually a host DNS or corporate proxy issue:${NC}"
                echo -e "  - Check ${GREEN}/etc/resolv.conf${NC} resolves public hosts (try ${GREEN}getent hosts registry-1.docker.io${NC})"
                echo -e "  - If on a corporate VPN, confirm ${GREEN}registry-1.docker.io${NC} and ${GREEN}cp.icr.io${NC} are reachable"
                echo -e "  - WSL2 only: ${GREEN}wsl --shutdown${NC} from PowerShell, then reopen the distro"
                echo
            fi
        else
            echo -e "${YELLOW}Error details:${NC}"
            tail -10 /tmp/cassandra-pull.log
            echo
        fi
        
        rm -f /tmp/cassandra-pull.log
        exit 1
    fi
    
    rm -f /tmp/cassandra-pull.log
    echo -e "${GREEN}✓ Image pulled${NC}"
    echo

    # Create Cassandra container.
    #
    # `--network ibm-lh-network` is load-bearing: that's the bridge watsonx.data
    # creates and uses. Without it, Cassandra lands on the default `podman`
    # bridge (10.88.0.x) while watsonx is on ibm-lh-network (10.89.0.x). TCP
    # to host.containers.internal:9042 still works for the initial handshake,
    # but the Cassandra driver then asks the server for its broadcast address
    # (the address future requests should target) and gets back 10.88.0.x —
    # which watsonx can't route to. Federation queries then fail with cryptic
    # "no host available" errors. Putting cassandra on the same bridge means
    # it advertises a 10.89.x address that watsonx routes natively.
    echo -e "${YELLOW}Creating Cassandra container...${NC}"
    podman run -d \
        --name "$CASSANDRA_CONTAINER_NAME" \
        --network ibm-lh-network \
        -p ${CASSANDRA_PORT}:9042 \
        -p ${CASSANDRA_JMX_PORT}:7199 \
        -e CASSANDRA_CLUSTER_NAME="WatsonX_Workshop_Cluster" \
        -e CASSANDRA_DC="datacenter1" \
        -e CASSANDRA_RACK="rack1" \
        -e CASSANDRA_ENDPOINT_SNITCH="GossipingPropertyFileSnitch" \
        -e CASSANDRA_NUM_TOKENS="16" \
        -e MAX_HEAP_SIZE="2G" \
        -e HEAP_NEWSIZE="400M" \
        cassandra:${CASSANDRA_VERSION}

    echo -e "${GREEN}✓ Cassandra container created${NC}"
    echo
fi

# Wait for Cassandra to be ready
echo -e "${YELLOW}Waiting for Cassandra to be ready...${NC}"
echo -e "${BLUE}(This may take 30-60 seconds)${NC}"

MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if podman exec "$CASSANDRA_CONTAINER_NAME" cqlsh -e "SELECT cluster_name FROM system.local" &>/dev/null; then
        echo -e "${GREEN}✓ Cassandra is ready!${NC}"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo -n "."
    sleep 2
done
echo

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo -e "${RED}Warning: Cassandra may not be fully ready yet${NC}"
    echo -e "${YELLOW}Check logs with: podman logs ${CASSANDRA_CONTAINER_NAME}${NC}"
fi

# Display connection information
echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cassandra Deployment Complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}Connection Information:${NC}"
echo -e "${BLUE}  Host:${NC} localhost (or host.containers.internal from WatsonX)"
echo -e "${BLUE}  Port:${NC} ${CASSANDRA_PORT}"
echo -e "${BLUE}  Cluster Name:${NC} WatsonX_Workshop_Cluster"
echo -e "${BLUE}  Datacenter:${NC} datacenter1"
echo
echo -e "${YELLOW}Access Cassandra:${NC}"
echo -e "${BLUE}  CQL Shell:${NC} podman exec -it ${CASSANDRA_CONTAINER_NAME} cqlsh"
echo -e "${BLUE}  Check Status:${NC} podman exec ${CASSANDRA_CONTAINER_NAME} nodetool status"
echo
echo -e "${YELLOW}Container Management:${NC}"
echo -e "${BLUE}  View Logs:${NC} podman logs ${CASSANDRA_CONTAINER_NAME}"
echo -e "${BLUE}  Stop:${NC} podman stop ${CASSANDRA_CONTAINER_NAME}"
echo -e "${BLUE}  Start:${NC} podman start ${CASSANDRA_CONTAINER_NAME}"
echo -e "${BLUE}  Remove:${NC} podman rm -f ${CASSANDRA_CONTAINER_NAME}"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "  1. ${GREEN}Run the sample data loader:${NC}"
echo -e "     ${BLUE}./setup/cassandra/load-sample-data.sh${NC}"
echo
echo -e "  2. ${GREEN}Add Cassandra to WatsonX Data:${NC}"
echo -e "     - Open ${BLUE}https://localhost:9443${NC}"
echo -e "     - Go to Infrastructure Manager → Add Component → Cassandra"
echo -e "     - Hostname: ${BLUE}host.containers.internal${NC}"
echo -e "     - Port: ${BLUE}${CASSANDRA_PORT}${NC}"
echo -e "     - No authentication required (default setup)"
echo
echo -e "${GREEN}✓ Ready for the workshop!${NC}"
echo

# Made with Bob
