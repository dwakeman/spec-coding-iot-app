#!/bin/bash
################################################################################
# Simplified WatsonX Data Developer Edition Installation
# Purpose: Workshop-focused installation with minimal complexity
# Installation Location: Inside the workshop repository
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get the repository root (where the script is being run from)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Installation directory - inside the repository
WATSONX_INSTALL_DIR="${REPO_ROOT}/.watsonx-data"

# WatsonX Data configuration
WATSONX_MACHINE_NAME="watsonx-workshop"
WATSONX_CPUS=8
WATSONX_MEMORY=16384  # 16GB
WATSONX_DISK=200      # 200GB

# Docker registry
IBM_LH_TOOLBOX="cp.icr.io/cpopen/watsonx-data/ibm-lakehouse-toolbox:latest"
LH_REGISTRY="cp.icr.io/cp/watsonx-data"
PROD_USER="cp"
IBM_ICR_IO="cp.icr.io"

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

print_header() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

################################################################################
# Check Prerequisites
################################################################################

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if Podman is installed
    if ! command -v podman &> /dev/null; then
        error "Podman is not installed. Please install it first with: brew install podman"
    fi
    
    PODMAN_VERSION=$(podman --version | awk '{print $3}')
    log "✓ Podman is installed (version $PODMAN_VERSION)"
    
    # Check if we're in the right directory
    # Detect by setup/install-workshop.sh + setup/sample-data/ — present in
    # both the instructor repo and the attendee bundle. README.md and
    # exercises/ are instructor-only as of v1.1.0.
    if [ ! -x "$REPO_ROOT/setup/install-workshop.sh" ] || [ ! -d "$REPO_ROOT/setup/sample-data" ]; then
        error "This script must be run from the workshop root (expected setup/install-workshop.sh and setup/sample-data/)"
    fi
    
    log "✓ Running from workshop repository: $REPO_ROOT"
}

################################################################################
# Check IBM Entitlement Key
################################################################################

check_ibm_entitlement_key() {
    print_header "IBM Entitlement Key"

    # Accept either IBM_ENTITLEMENT_KEY or WATSONX_ENTITLEMENT_KEY from env.
    if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
        info "✓ IBM entitlement key found in environment (IBM_ENTITLEMENT_KEY)"
        return 0
    fi
    if [[ -n "${WATSONX_ENTITLEMENT_KEY:-}" ]]; then
        info "✓ IBM entitlement key found in environment (WATSONX_ENTITLEMENT_KEY)"
        export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
        return 0
    fi

    # Check in .env file — accept either key name.
    if [[ -f "$REPO_ROOT/.env" ]]; then
        set -a; source "$REPO_ROOT/.env"; set +a
        if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
            info "✓ IBM entitlement key loaded from .env (IBM_ENTITLEMENT_KEY)"
            return 0
        fi
        if [[ -n "${WATSONX_ENTITLEMENT_KEY:-}" ]]; then
            info "✓ IBM entitlement key loaded from .env (WATSONX_ENTITLEMENT_KEY)"
            export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
            return 0
        fi
    fi

    # No key found. In a non-interactive run, fail fast with actionable guidance.
    if [[ "${WORKSHOP_YES:-0}" == "1" || ! -t 0 ]]; then
        error "IBM entitlement key missing. Set IBM_ENTITLEMENT_KEY (or WATSONX_ENTITLEMENT_KEY) in .env or env. Get one at https://myibm.ibm.com/products-services/containerlibrary"
    fi

    # Interactive prompt.
    echo
    warn "IBM Entitlement Key Required"
    info "Get your key from: https://myibm.ibm.com/products-services/containerlibrary"
    echo -n -e "${YELLOW}Enter your IBM entitlement key: ${NC}"
    read -r entitlement_key

    if [[ -z "$entitlement_key" || ${#entitlement_key} -lt 50 ]]; then
        error "Invalid entitlement key (too short)"
    fi

    export IBM_ENTITLEMENT_KEY="$entitlement_key"
    if [[ ! -f "$REPO_ROOT/.env" ]]; then
        echo "IBM_ENTITLEMENT_KEY=$entitlement_key" > "$REPO_ROOT/.env"
        log "✓ Saved entitlement key to .env file"
    fi
}

################################################################################
# Check Existing Installation
################################################################################

check_existing_installation() {
    print_header "Checking Existing Installation"

    if [ -d "$WATSONX_INSTALL_DIR" ]; then
        warn "WatsonX Data is already installed at: $WATSONX_INSTALL_DIR"

        local choice=""
        if [[ "${WORKSHOP_REINSTALL:-0}" == "1" ]]; then
            choice=1
            info "--reinstall: removing existing install"
        elif [[ "${WORKSHOP_YES:-0}" == "1" ]]; then
            # --yes without --reinstall means "keep what's there"
            choice=2
            info "--yes: reusing existing install (pass --reinstall to wipe)"
        elif [[ ! -t 0 ]]; then
            error "Existing install detected and stdin is not a TTY. Re-run with --reinstall to wipe or --yes to reuse."
        else
            echo
            echo -e "${YELLOW}What would you like to do?${NC}"
            echo -e "  ${BLUE}[1]${NC} Remove and reinstall (clean install)"
            echo -e "  ${BLUE}[2]${NC} Use existing installation"
            echo -e "  ${BLUE}[3]${NC} Cancel"
            echo
            echo -n -e "${YELLOW}Your choice [1/2/3]: ${NC}"
            read -r choice
        fi

        case "$choice" in
            1)
                log "Removing existing installation..."
                rm -rf "$WATSONX_INSTALL_DIR"
                log "✓ Existing installation removed"
                ;;
            2)
                log "Using existing installation"
                export LH_ROOT_DIR="$WATSONX_INSTALL_DIR"
                return 1  # Skip installation
                ;;
            3)
                info "Installation cancelled"
                exit 0
                ;;
            *)
                error "Invalid choice: '$choice'"
                ;;
        esac
    fi

    return 0  # Proceed with installation
}

################################################################################
# Setup Podman Machine
################################################################################

setup_podman_machine() {
    # On native Linux (and WSL2 Ubuntu, which IS native Linux from podman's
    # perspective), Podman runs containers directly — there's no VM layer to
    # manage. `podman machine` is a macOS/Windows-Desktop concept. Skip this
    # whole step on Linux to avoid creating an unnecessary nested VM.
    OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [[ "$OS_TYPE" != "darwin" ]]; then
        print_header "Skipping Podman Machine Setup (native Linux Podman)"
        log "Detected $OS_TYPE; running containers directly without a podman machine"
        return 0
    fi

    print_header "Setting Up Podman Machine"

    # Check if machine exists
    if podman machine list 2>/dev/null | grep -q "$WATSONX_MACHINE_NAME"; then
        # Reconcile any existing machine to the resources/rootful state we need.
        # `podman machine init`'s --cpus/--memory/--disk-size only apply at
        # creation; a pre-existing machine (e.g. one created manually after a
        # cleanup) keeps podman's tiny defaults (~2GB RAM), and watsonx.data's
        # mds-rest/mds-thrift then OOM-kill (exit 137). Rootful is required on
        # macOS so Presto's auth-init chmod on bind-mounted scripts succeeds —
        # without it Presto crashes with "authenticator was not loaded".
        local cur_mem cur_cpus cur_disk cur_rootful needs_set=0
        cur_mem=$(podman machine inspect "$WATSONX_MACHINE_NAME" --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)
        cur_cpus=$(podman machine inspect "$WATSONX_MACHINE_NAME" --format '{{.Resources.CPUs}}' 2>/dev/null || echo 0)
        cur_disk=$(podman machine inspect "$WATSONX_MACHINE_NAME" --format '{{.Resources.DiskSize}}' 2>/dev/null || echo 0)
        cur_rootful=$(podman machine inspect "$WATSONX_MACHINE_NAME" --format '{{.Rootful}}' 2>/dev/null || echo false)
        local set_args=()
        if [[ "$cur_rootful" != "true" ]]; then set_args+=(--rootful); needs_set=1; fi
        if (( cur_mem  < WATSONX_MEMORY )); then set_args+=(--memory  "$WATSONX_MEMORY"); needs_set=1; fi
        if (( cur_cpus < WATSONX_CPUS   )); then set_args+=(--cpus    "$WATSONX_CPUS");   needs_set=1; fi
        if (( cur_disk < WATSONX_DISK   )); then set_args+=(--disk-size "$WATSONX_DISK"); needs_set=1; fi
        if (( needs_set )); then
            log "Reconfiguring podman machine '$WATSONX_MACHINE_NAME' (current: ${cur_mem}MB / ${cur_cpus} CPUs / ${cur_disk}GB / rootful=${cur_rootful}) → ${WATSONX_MEMORY}MB / ${WATSONX_CPUS} CPUs / ${WATSONX_DISK}GB / rootful"
            podman machine stop "$WATSONX_MACHINE_NAME" 2>/dev/null || true
            podman machine set "${set_args[@]}" "$WATSONX_MACHINE_NAME"
            podman machine start "$WATSONX_MACHINE_NAME"
            log "✓ Podman machine reconfigured and started"
        elif podman machine list | grep "$WATSONX_MACHINE_NAME" | grep -q "Currently running"; then
            log "✓ Podman machine '$WATSONX_MACHINE_NAME' is already running"
        else
            log "Starting Podman machine '$WATSONX_MACHINE_NAME'..."
            podman machine start "$WATSONX_MACHINE_NAME"
            log "✓ Podman machine started"
        fi
    else
        log "Creating Podman machine '$WATSONX_MACHINE_NAME'..."
        log "Configuration: ${WATSONX_CPUS} CPUs, ${WATSONX_MEMORY}MB RAM, ${WATSONX_DISK}GB disk"
        
        podman machine init \
            --cpus "$WATSONX_CPUS" \
            --memory "$WATSONX_MEMORY" \
            --disk-size "$WATSONX_DISK" \
            --rootful \
            "$WATSONX_MACHINE_NAME"
        
        podman machine start "$WATSONX_MACHINE_NAME"
        log "✓ Podman machine created and started"
    fi
}

################################################################################
# Download and Install WatsonX Data
################################################################################

install_watsonx_data() {
    print_header "Installing WatsonX Data"
    
    # Create installation directory
    mkdir -p "$WATSONX_INSTALL_DIR"
    export LH_ROOT_DIR="$WATSONX_INSTALL_DIR"
    
    log "Installation directory: $WATSONX_INSTALL_DIR"
    
    # Login to IBM registry
    log "Logging into IBM Container Registry..."
    echo "$IBM_ENTITLEMENT_KEY" | podman login -u "$PROD_USER" --password-stdin "$IBM_ICR_IO"
    
    # Download developer package
    log "Downloading WatsonX Data developer package..."
    log "This may take 10-20 minutes depending on your internet speed..."
    echo
    info "Note: You may see a platform warning (linux/amd64 vs linux/arm64) - this is normal and harmless"
    info "The download is large (~2-3GB) - please be patient..."
    echo
    
    # Start progress indicator in background
    (
        sleep 30  # Wait 30 seconds before showing progress
        elapsed=30
        while kill -0 $$ 2>/dev/null; do
            echo -e "${BLUE}[$(date +'%H:%M:%S')] Still downloading... (${elapsed}s elapsed)${NC}"
            sleep 30
            elapsed=$((elapsed + 30))
        done
    ) &
    PROGRESS_PID=$!
    
    # Run the download
    podman run --rm \
        -e LICENSE=accept \
        -v "$WATSONX_INSTALL_DIR:/output:z" \
        "$IBM_LH_TOOLBOX" \
        get-ibm-lh-dev
    
    # Stop progress indicator
    kill $PROGRESS_PID 2>/dev/null || true
    wait $PROGRESS_PID 2>/dev/null || true
    
    # Extract package
    log "Extracting package..."
    cd /tmp
    tar -xf /tmp/pkg.tar -C /tmp
    tar -xf /tmp/opt/dev/ibm-lh-dev-*.tgz -C "$WATSONX_INSTALL_DIR"
    rm -rf /tmp/opt /tmp/pkg.tar

    # Patch the bundled common-utils.sh to add `:U` to bind-mount mode — but
    # only on macOS. On macOS the host filesystem reaches containers via
    # virtiofs, and chmod on bind-mounted scripts fails ("Operation not
    # permitted") without `:U`. That breaks Presto's auth init
    # (init-usermgmt.sh can't chmod pbkdf2_utils.py) and Presto then crashes
    # with "authenticator was not loaded". `:U` makes podman chown the mount
    # tree to the container UID before mounting.
    #
    # On Linux/WSL2 `:U` is actively harmful: it chowns the host bind-mount
    # tree to the container's UID, which clobbers the Postgres data directory's
    # permissions and the metastore fails to come up. So this patch must be
    # macOS-only — the earlier "harmless on native Linux" comment was wrong
    # (cf. issue #72 field report).
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local cu="$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/common-utils.sh"
        if [[ -f "$cu" ]] && grep -qE '^[[:space:]]*mnt_mode=":z"$' "$cu"; then
            sed -i.bak -E 's|^([[:space:]]*)mnt_mode=":z"$|\1mnt_mode=":z,U"|' "$cu"
            rm -f "${cu}.bak"
            log "✓ Patched bin/common-utils.sh (mnt_mode → :z,U) for macOS bind-mount chmod"
        fi
    fi

    log "✓ WatsonX Data installed successfully"
}

################################################################################
# Configure WatsonX Data
################################################################################

configure_watsonx_data() {
    print_header "Configuring WatsonX Data"
    
    log "Setting up cluster configuration..."
    "$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/setup" \
        --license_acceptance=y \
        --runtime=podman \
        --password=Admin123!
    
    log "✓ Configuration complete"
}

################################################################################
# Start WatsonX Data
################################################################################

start_watsonx_data() {
    print_header "Starting WatsonX Data"
    
    log "Starting containers..."
    "$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/start"
    
    log "✓ Containers started"
    
    # Wait a bit for services to initialize
    log "Waiting for services to initialize..."
    sleep 10
}

################################################################################
# Display Access Information
################################################################################

display_access_info() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}✓ WatsonX Data is now running!${NC}"
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Access Information${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Web Console:${NC}"
    echo -e "  URL:      ${CYAN}https://localhost:9443${NC}"
    echo -e "  Username: ${CYAN}ibmlhadmin${NC}"
    echo -e "  Password: ${CYAN}password${NC}"
    echo
    echo -e "${YELLOW}Installation Location:${NC}"
    echo -e "  ${CYAN}$WATSONX_INSTALL_DIR${NC}"
    echo
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo -e "  Stop:     ${CYAN}$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/stop${NC}"
    echo -e "  Start:    ${CYAN}$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/start${NC}"
    echo -e "  Status:   ${CYAN}$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/status --all${NC}"
    echo -e "  Presto:   ${CYAN}$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/presto-cli${NC}"
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Open the web console at https://localhost:9443"
    echo -e "  2. Register Cassandra (see setup/cassandra/README.md)"
    echo -e "  3. Create Iceberg tables (run ./setup/sample-data/create-iceberg-tables.sh)"
    echo
}

################################################################################
# Main Installation Flow
################################################################################

main() {
    print_header "WatsonX Data Workshop Installation"
    
    info "This will install WatsonX Data inside your workshop repository"
    info "Location: $WATSONX_INSTALL_DIR"
    echo
    
    check_prerequisites
    check_ibm_entitlement_key
    
    if check_existing_installation; then
        setup_podman_machine
        install_watsonx_data
        configure_watsonx_data
        start_watsonx_data
    fi
    
    display_access_info
    
    log "✨ Installation complete!"
}

# Run main function
main

# Made with Bob