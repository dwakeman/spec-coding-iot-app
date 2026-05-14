#!/bin/bash

# Complete cleanup script for WatsonX Data and Cassandra workshop environment
# WARNING: This will remove ALL containers, images, machines, and data

set -e

# Non-interactive controls (flags override env vars override defaults).
# Keeping this parser inline so the script has no new deps.
WORKSHOP_YES="${WORKSHOP_YES:-0}"         # 1 = skip "type yes" confirmation
REMOVE_DIRS_FLAG="${WORKSHOP_REMOVE_DIRS:-}"  # y|n if set; prompts otherwise
while (( $# > 0 )); do
    case "$1" in
        --yes|-y)            WORKSHOP_YES=1 ;;
        --remove-dirs)       REMOVE_DIRS_FLAG=y ;;
        --keep-dirs)         REMOVE_DIRS_FLAG=n ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [options]

Tear down the workshop environment — containers, images, podman machines,
and (optionally) install directories.

Options:
  --yes, -y         Non-interactive: skip "type yes" confirmation.
  --remove-dirs     Also remove detected install directories (no prompt).
  --keep-dirs       Keep install directories (no prompt).
  -h, --help        Show this help.

Env vars: WORKSHOP_YES=1, WORKSHOP_REMOVE_DIRS=y|n.
EOF
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}  ⚠️  COMPLETE ENVIRONMENT CLEANUP${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}This script will remove:${NC}"
echo -e "  ${RED}✗${NC} All Podman containers (WatsonX Data, Cassandra)"
echo -e "  ${RED}✗${NC} All Podman images (including WatsonX Data images)"
echo -e "  ${RED}✗${NC} All Podman machines (wxd-workshop-cluster, watsonx-data-dev)"
echo -e "  ${RED}✗${NC} Installation directories"
echo -e "  ${RED}✗${NC} All workshop data"
echo
echo -e "${RED}⚠️  THIS CANNOT BE UNDONE!${NC}"
echo
if [[ "$WORKSHOP_YES" == "1" ]]; then
    echo -e "${BLUE}--yes: proceeding with cleanup${NC}"
elif [[ -t 0 ]]; then
    read -p "Are you sure you want to continue? Type 'yes' to proceed: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Cleanup cancelled${NC}"
        exit 0
    fi
else
    echo -e "${RED}Refusing to run non-interactively without --yes. Aborting.${NC}" >&2
    exit 1
fi

echo
echo -e "${BLUE}Starting cleanup...${NC}"
# Step 0: Kill any running data generation processes
echo -e "${YELLOW}Step 0/6: Checking for running data generation processes...${NC}"
if pgrep -f "generate_data.py" > /dev/null; then
    echo -e "${YELLOW}Found running data generation processes. Terminating...${NC}"
    pkill -f "generate_data.py" || true
    sleep 2
    # Force kill if still running
    if pgrep -f "generate_data.py" > /dev/null; then
        echo -e "${YELLOW}Force killing stubborn processes...${NC}"
        pkill -9 -f "generate_data.py" || true
    fi
    echo -e "${GREEN}✓ Data generation processes terminated${NC}"
else
    echo -e "${GREEN}✓ No running data generation processes found${NC}"
fi
echo

echo

# Step 1: Remove all containers (force-kill in one step — no point
# waiting on graceful shutdowns for a machine we're about to destroy).
echo -e "${YELLOW}Step 1/6: Removing containers...${NC}"
CONTAINERS=$(podman ps -aq 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
    echo -e "${BLUE}Found containers to remove${NC}"
    podman rm -f --time=0 $(podman ps -aq) >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ Containers removed${NC}"
else
    echo -e "${BLUE}No containers to remove${NC}"
fi
echo

# Step 2: Remove all images
echo -e "${YELLOW}Step 2/6: Removing all Podman images...${NC}"
IMAGES=$(podman images -q 2>/dev/null || true)
if [ -n "$IMAGES" ]; then
    echo -e "${BLUE}Removing images (this may take a moment)...${NC}"
    podman rmi -f $(podman images -q) 2>/dev/null || true
    echo -e "${GREEN}✓ Images removed${NC}"
else
    echo -e "${BLUE}No images to remove${NC}"
fi
echo

# Step 3: Stop and remove ALL Podman machines
echo -e "${YELLOW}Step 3/6: Removing Podman machines...${NC}"

# Get all machines (strip the * indicator for currently running machine)
ALL_MACHINES=$(podman machine list --format "{{.Name}}" 2>/dev/null | sed 's/\*$//' || true)

if [ -n "$ALL_MACHINES" ]; then
    echo -e "${BLUE}Found Podman machines:${NC}"
    echo "$ALL_MACHINES" | while read -r machine; do
        [ -n "$machine" ] && echo -e "  ${RED}✗ $machine${NC}"
    done
    echo
    
    # Remove all machines (user already confirmed with initial 'yes' prompt)
    echo "$ALL_MACHINES" | while read -r machine; do
        # Skip empty lines
        [ -z "$machine" ] && continue
        
        echo -e "${BLUE}Stopping machine: $machine${NC}"
        podman machine stop "$machine" 2>/dev/null || true
        sleep 2
        echo -e "${BLUE}Removing machine: $machine${NC}"
        podman machine rm -f "$machine" 2>/dev/null || true
        sleep 1
    done
    echo -e "${GREEN}✓ All Podman machines removed${NC}"
else
    echo -e "${BLUE}No Podman machines found${NC}"
fi
echo

# Step 4: Clean up Podman system
echo -e "${YELLOW}Step 4/6: Cleaning Podman system...${NC}"
podman system prune -a -f --volumes 2>/dev/null || true
echo -e "${GREEN}✓ Podman system cleaned${NC}"
echo

# Step 5: Remove installation directories
echo -e "${YELLOW}Step 5/6: Removing installation directories...${NC}"

# Try to find installation directories dynamically
INSTALL_DIRS=()

# Check for repository-local installation (new simplified approach)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -d "$REPO_ROOT/.watsonx-data" ]; then
    INSTALL_DIRS+=("$REPO_ROOT/.watsonx-data")
    echo -e "${BLUE}Found repository installation: $REPO_ROOT/.watsonx-data${NC}"
fi

# Check for LH_ROOT_DIR environment variable
if [ -n "$LH_ROOT_DIR" ] && [ -d "$LH_ROOT_DIR" ]; then
    INSTALL_DIRS+=("$LH_ROOT_DIR")
    echo -e "${BLUE}Found LH_ROOT_DIR: $LH_ROOT_DIR${NC}"
fi

# Check for LH_CLIENT_ROOT_DIR environment variable
if [ -n "$LH_CLIENT_ROOT_DIR" ] && [ -d "$LH_CLIENT_ROOT_DIR" ]; then
    INSTALL_DIRS+=("$LH_CLIENT_ROOT_DIR")
    echo -e "${BLUE}Found LH_CLIENT_ROOT_DIR: $LH_CLIENT_ROOT_DIR${NC}"
fi

# Search common installation locations if env vars not set
if [ ${#INSTALL_DIRS[@]} -eq 0 ]; then
    echo -e "${BLUE}Searching for installation directories...${NC}"
    
    # Common base directories to search
    SEARCH_DIRS=(
        "$HOME/ibm"
        "$HOME/Documents"
        "$HOME/Downloads"
        "/opt/ibm"
        "/usr/local/ibm"
    )
    
    for base_dir in "${SEARCH_DIRS[@]}"; do
        if [ -d "$base_dir" ]; then
            # Look for watsonx-data directories (increased depth to 6 to catch nested installations)
            find "$base_dir" -maxdepth 6 -type d \( -name "*watsonx*data*" -o -name "*ibm-lh*" -o -name "WatsonX*" \) 2>/dev/null | while read -r dir; do
                # Only include directories that contain ibm-lh-dev (actual installations)
                if [ -d "$dir/ibm-lh-dev" ] || [ -d "$dir" ] && [[ "$dir" == *"WatsonX_Data_Dev"* ]]; then
                    INSTALL_DIRS+=("$dir")
                    echo -e "${BLUE}Found: $dir${NC}"
                fi
            done
        fi
    done
    
    # Also specifically check for the common installation pattern
    COMMON_INSTALL_BASE="$HOME/Documents/30_OUTILS_LOGICIELS/Installation_Packages/WatsonX_Data_Dev"
    if [ -d "$COMMON_INSTALL_BASE" ]; then
        echo -e "${BLUE}Checking common installation location: $COMMON_INSTALL_BASE${NC}"
        for install_dir in "$COMMON_INSTALL_BASE"/*; do
            if [ -d "$install_dir/ibm-lh-dev" ]; then
                INSTALL_DIRS+=("$install_dir")
                echo -e "${BLUE}Found installation: $install_dir${NC}"
            fi
        done
    fi
fi

# Remove found directories
if [ ${#INSTALL_DIRS[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}The following directories will be removed:${NC}"
    for dir in "${INSTALL_DIRS[@]}"; do
        echo -e "  ${RED}✗${NC} $dir"
    done
    echo
    if [[ -n "$REMOVE_DIRS_FLAG" ]]; then
        REMOVE_DIRS="$REMOVE_DIRS_FLAG"
        echo -e "${BLUE}Using --${REMOVE_DIRS_FLAG}emove-dirs from command line: $REMOVE_DIRS${NC}"
    elif [[ -t 0 ]]; then
        read -p "Remove these directories? (y/n): " REMOVE_DIRS
    else
        # Non-interactive without an explicit flag: safer default is keep.
        REMOVE_DIRS=n
        echo -e "${YELLOW}Non-interactive: keeping directories (pass --remove-dirs to wipe)${NC}"
    fi

    if [ "$REMOVE_DIRS" = "y" ] || [ "$REMOVE_DIRS" = "Y" ]; then
        for dir in "${INSTALL_DIRS[@]}"; do
            if [ -d "$dir" ]; then
                echo -e "${BLUE}Removing: $dir${NC}"
                rm -rf "$dir"
            fi
        done
        echo -e "${GREEN}✓ Installation directories removed${NC}"
    else
        echo -e "${YELLOW}Skipped directory removal${NC}"
    fi
else
    echo -e "${BLUE}No installation directories found${NC}"
fi
echo

# Step 6: Remove temporary files + the workshop-install marker
echo -e "${YELLOW}Step 6/6: Removing temporary files...${NC}"
rm -rf /tmp/opt 2>/dev/null || true
rm -rf /tmp/pkg.tar 2>/dev/null || true
rm -f "$REPO_ROOT/.workshop-installed" 2>/dev/null || true
echo -e "${GREEN}✓ Temporary files removed${NC}"
echo

# Note: Self-signed certificate is left in place for future use
# Users can manually remove it if needed with:
# sudo security delete-certificate -c 'localhost' /Library/Keychains/System.keychain
echo

# Summary
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Cleanup Complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${YELLOW}What was removed:${NC}"
echo -e "  ${GREEN}✓${NC} All containers stopped and removed"
echo -e "  ${GREEN}✓${NC} All Podman images removed"
echo -e "  ${GREEN}✓${NC} Podman machines removed"
echo -e "  ${GREEN}✓${NC} Installation directories cleaned"
echo -e "  ${GREEN}✓${NC} Temporary files removed"
echo

echo -e "${YELLOW}What remains:${NC}"
echo -e "  ${BLUE}•${NC} Podman application (still installed)"
echo -e "  ${BLUE}•${NC} Workshop scripts in: $(pwd)"
echo -e "  ${BLUE}•${NC} .env file with entitlement key"
echo

echo -e "${YELLOW}To reinstall:${NC}"
echo -e "  ${BLUE}Run:${NC} ./setup/install-workshop.sh"
echo

echo -e "${GREEN}✓ Environment is clean!${NC}"
echo

# Made with Bob
