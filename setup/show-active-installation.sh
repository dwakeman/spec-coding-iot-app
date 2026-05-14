#!/bin/bash
################################################################################
# Show Active WatsonX Data Installation
# Helps identify which installation is currently running
################################################################################

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  WatsonX Data Installation Status${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

# Check if WatsonX Data is running
if ! podman ps --format "{{.Names}}" | grep -q "ibm-lh-presto"; then
    echo -e "${YELLOW}⚠ WatsonX Data is not currently running${NC}"
    echo
    exit 0
fi

echo -e "${GREEN}✓ WatsonX Data is running${NC}"
echo

# Find all installations
INSTALL_BASE="$HOME/Documents/30_OUTILS_LOGICIELS/Installation_Packages/WatsonX_Data_Dev"
if [ -d "$INSTALL_BASE" ]; then
    echo -e "${BLUE}Found installations:${NC}"
    INSTALL_COUNT=0
    for install_dir in "$INSTALL_BASE"/*; do
        if [ -d "$install_dir/ibm-lh-dev" ]; then
            INSTALL_COUNT=$((INSTALL_COUNT + 1))
            INSTALL_NAME=$(basename "$install_dir")
            PRESTO_CLI="$install_dir/ibm-lh-dev/bin/presto-cli"
            
            # Check if this is the most recent
            if [ -f "$PRESTO_CLI" ]; then
                MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$PRESTO_CLI" 2>/dev/null || stat -c "%y" "$PRESTO_CLI" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
                echo -e "  ${CYAN}[$INSTALL_COUNT]${NC} $INSTALL_NAME ${YELLOW}(modified: $MODIFIED)${NC}"
            fi
        fi
    done
    echo
    echo -e "${BLUE}Total installations: $INSTALL_COUNT${NC}"
    echo
fi

# Show the most recent installation
echo -e "${BLUE}Most recent installation:${NC}"
LATEST=$(ls -t "$INSTALL_BASE"/*/ibm-lh-dev/bin/presto-cli 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    LATEST_DIR=$(dirname "$(dirname "$(dirname "$LATEST")")")
    LATEST_NAME=$(basename "$LATEST_DIR")
    echo -e "  ${GREEN}✓ $LATEST_NAME${NC}"
    echo -e "  ${CYAN}Path: $LATEST_DIR${NC}"
    echo
    echo -e "${BLUE}Presto CLI:${NC}"
    echo -e "  ${CYAN}$LATEST${NC}"
else
    echo -e "  ${YELLOW}⚠ No installations found${NC}"
fi

echo
echo -e "${BLUE}Running containers:${NC}"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAME|ibm-lh|lh"

echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo

# Made with Bob
