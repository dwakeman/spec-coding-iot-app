#!/bin/bash
################################################################################
# WatsonX Data Direct Installation (Apple Silicon Optimized)
# Purpose: Foolproof installation that avoids container download issues
# Method: Direct download from IBM, no toolbox container needed
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Installation directory
WATSONX_INSTALL_DIR="${REPO_ROOT}/.watsonx-data"

# WatsonX Data configuration
WATSONX_MACHINE_NAME="watsonx-workshop"
WATSONX_CPUS=8
WATSONX_MEMORY=16384
WATSONX_DISK=200

# IBM Registry
IBM_ICR_IO="cp.icr.io"
PROD_USER="cp"

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
    
    if ! command -v podman &> /dev/null; then
        local install_hint
        case "$(uname -s)" in
            Darwin) install_hint="brew install podman" ;;
            Linux)
                if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                    install_hint="sudo apt-get update && sudo apt-get install -y podman   (run inside your WSL2 distro)"
                elif [[ -f /etc/debian_version ]]; then
                    install_hint="sudo apt-get update && sudo apt-get install -y podman"
                elif [[ -f /etc/redhat-release ]]; then
                    install_hint="sudo yum install -y podman"
                else
                    install_hint="see https://podman.io/getting-started/installation"
                fi
                ;;
            *) install_hint="see https://podman.io/getting-started/installation" ;;
        esac
        error "Podman is not installed. Install with: $install_hint"
    fi
    
    PODMAN_VERSION=$(podman --version | awk '{print $3}')
    log "✓ Podman is installed (version $PODMAN_VERSION)"
    
    # Detect by setup/install-workshop.sh + setup/sample-data/ — present in
    # both the instructor repo and the attendee bundle. README.md and
    # exercises/ are instructor-only as of v1.1.0.
    if [ ! -x "$REPO_ROOT/setup/install-workshop.sh" ] || [ ! -d "$REPO_ROOT/setup/sample-data" ]; then
        error "This script must be run from the workshop root (expected setup/install-workshop.sh and setup/sample-data/)"
    fi
    
    log "✓ Running from workshop repository: $REPO_ROOT"
}

################################################################################
# Get IBM Entitlement Key
################################################################################

get_ibm_entitlement_key() {
    print_header "IBM Entitlement Key"
    
    # Accept either IBM_ENTITLEMENT_KEY or WATSONX_ENTITLEMENT_KEY from env
    if [[ -n "$IBM_ENTITLEMENT_KEY" ]]; then
        info "✓ IBM entitlement key found in environment (IBM_ENTITLEMENT_KEY)"
        return 0
    fi
    if [[ -n "$WATSONX_ENTITLEMENT_KEY" ]]; then
        info "✓ IBM entitlement key found in environment (WATSONX_ENTITLEMENT_KEY)"
        export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
        return 0
    fi

    # Source .env if present, then re-check under either name
    if [ -f "$REPO_ROOT/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "$REPO_ROOT/.env"
        set +a
        if [[ -n "$IBM_ENTITLEMENT_KEY" ]]; then
            info "✓ IBM entitlement key loaded from .env (IBM_ENTITLEMENT_KEY)"
            return 0
        fi
        if [[ -n "$WATSONX_ENTITLEMENT_KEY" ]]; then
            info "✓ IBM entitlement key loaded from .env (WATSONX_ENTITLEMENT_KEY)"
            export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
            return 0
        fi
    fi
    
    # No key found. Fail fast when stdin isn't a TTY so agents get a clear error
    # instead of hanging on a prompt.
    if [[ "${WORKSHOP_YES:-0}" == "1" || ! -t 0 ]]; then
        error "IBM entitlement key missing. Set IBM_ENTITLEMENT_KEY (or WATSONX_ENTITLEMENT_KEY) in .env or env. Get one at https://myibm.ibm.com/products-services/containerlibrary"
    fi

    echo
    warn "IBM Entitlement Key Required"
    echo
    info "Get your key from: https://myibm.ibm.com/products-services/containerlibrary"
    echo
    echo -n -e "${YELLOW}Enter your IBM entitlement key: ${NC}"
    read -r entitlement_key

    if [[ -z "$entitlement_key" || ${#entitlement_key} -lt 50 ]]; then
        error "Invalid entitlement key (too short)"
    fi
    
    export IBM_ENTITLEMENT_KEY="$entitlement_key"
    
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "WATSONX_ENTITLEMENT_KEY=$entitlement_key" > "$REPO_ROOT/.env"
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
            choice=1; info "--reinstall: removing existing install"
        elif [[ "${WORKSHOP_YES:-0}" == "1" ]]; then
            choice=2; info "--yes: reusing existing install (pass --reinstall to wipe)"
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
                return 0
                ;;
            2)
                log "Using existing installation"
                return 1
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

    return 0
}

################################################################################
# Setup Podman Machine
################################################################################

setup_podman_machine() {
    print_header "Setting Up Podman Machine"

    # If our specific machine exists, reconcile it to the resources/rootful
    # state we need before starting. `podman machine init`'s --cpus/--memory/
    # --disk-size only apply at creation, so a pre-existing machine (e.g. one
    # created manually after a cleanup) keeps podman defaults (~2GB RAM) and
    # watsonx.data's mds-rest/mds-thrift then OOM-kill. Rootful is required on
    # macOS so Presto's auth-init chmod on bind-mounted scripts succeeds —
    # without it Presto crashes with "authenticator was not loaded".
    if podman machine list 2>/dev/null | grep -q "$WATSONX_MACHINE_NAME"; then
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
        return 0
    fi
    
    # No existing machine - need to create one with retry logic
    log "Creating Podman machine '$WATSONX_MACHINE_NAME'..."
    log "Configuration: ${WATSONX_CPUS} CPUs, ${WATSONX_MEMORY}MB RAM, ${WATSONX_DISK}GB disk"
    
    MAX_RETRIES=5
    RETRY_COUNT=0
    WAIT_TIME=10
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if [ $RETRY_COUNT -gt 0 ]; then
            warn "Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES - Retrying in ${WAIT_TIME} seconds..."
            sleep $WAIT_TIME
            WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
        fi
        
        log "Attempting to create Podman machine..."
        
        # Capture output and check exit code
        if podman machine init \
            --cpus "$WATSONX_CPUS" \
            --memory "$WATSONX_MEMORY" \
            --disk-size "$WATSONX_DISK" \
            --rootful \
            "$WATSONX_MACHINE_NAME" 2>&1 | tee /tmp/podman-init.log && \
           podman machine list 2>/dev/null | grep -q "$WATSONX_MACHINE_NAME"; then
            
            log "✓ Podman machine created successfully"
            podman machine start "$WATSONX_MACHINE_NAME"
            log "✓ Podman machine started"
            return 0
        fi
        
        # Machine creation failed
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if grep -q "502 Bad Gateway\|Bad Gateway\|timeout\|network\|HTTP status" /tmp/podman-init.log; then
            warn "Network issue detected with quay.io registry"
        fi
        
        # Clean up failed attempt
        podman machine rm -f "$WATSONX_MACHINE_NAME" 2>/dev/null || true
    done
    
    # All retries failed
    echo
    error "Failed to create Podman machine after $MAX_RETRIES attempts.

This is likely due to temporary network issues with quay.io.

You can:
1. Wait a few minutes and run this script again
2. Create the machine manually:
   podman machine init --cpus 8 --memory 16384 --disk-size 200 --rootful watsonx-workshop
   podman machine start watsonx-workshop
   Then run this script again"
}

################################################################################
# Download WatsonX Data (Direct Method)
################################################################################

download_watsonx_data() {
    print_header "Downloading WatsonX Data"
    
    mkdir -p "$WATSONX_INSTALL_DIR"
    
    log "Installation directory: $WATSONX_INSTALL_DIR"
    
    # Login to IBM registry. If this fails, the most common cause (by a wide
    # margin) is a stale or wrong-type entitlement key, so steer the user
    # there instead of surfacing a generic "invalid username/password".
    log "Logging into IBM Container Registry..."
    if ! echo "$IBM_ENTITLEMENT_KEY" | podman login -u "$PROD_USER" --password-stdin "$IBM_ICR_IO"; then
        echo
        error "Login to $IBM_ICR_IO failed.

  This usually means your IBM_ENTITLEMENT_KEY is invalid, expired, or the
  wrong type. Note:
    • The container-registry key (what cp.icr.io wants) is NOT the same as
      a watsonx SaaS token or IBM Cloud API key.
    • Get (or rotate) the right key at:
        https://myibm.ibm.com/products-services/containerlibrary
    • Put it in .env as either IBM_ENTITLEMENT_KEY=... or
      WATSONX_ENTITLEMENT_KEY=... (one line, no line break inside the key)."
    fi
    
    # Download using a simpler, more reliable method
    log "Downloading WatsonX Data package..."
    log "Method: image pull + host-side tar extraction (avoids slow bind-mount writes during install)"
    echo
    info "Estimated time: 5-10 minutes"
    echo
    
    # Pull the image first (this shows progress)
    log "Step 1/3: Pulling toolbox image..."
    podman pull cp.icr.io/cpopen/watsonx-data/ibm-lakehouse-toolbox:latest
    
    # Create a temporary container
    log "Step 2/3: Creating temporary container..."
    CONTAINER_ID=$(podman create cp.icr.io/cpopen/watsonx-data/ibm-lakehouse-toolbox:latest)
    
    # Copy files out
    log "Step 3/3: Extracting files..."
    TEMP_DIR=$(mktemp -d)
    podman cp "${CONTAINER_ID}:/opt" "$TEMP_DIR/"
    
    # Clean up container
    podman rm "$CONTAINER_ID"
    
    # Extract the developer package
    log "Extracting developer package..."
    TARBALL=$(find "$TEMP_DIR/opt/dev" -name "ibm-lh-dev-*.tgz" | head -1)
    
    if [ -z "$TARBALL" ]; then
        error "Could not find developer package in downloaded files"
    fi
    
    tar -xzf "$TARBALL" -C "$WATSONX_INSTALL_DIR"

    # Clean up temp directory
    rm -rf "$TEMP_DIR"

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

    log "✓ WatsonX Data downloaded and extracted successfully"
}

################################################################################
# Prune Unused Images (workshop optimization)
#
# IBM's setup.sh unconditionally pulls ibm-lh-prestissimo (C++ Velox engine)
# and ibm-lh-milvus (vector DB), even though neither starts by default. The
# workshop uses Java Presto for all federation and never touches Milvus, so
# we comment those pulls out to save ~3-5GB of download + disk per attendee.
################################################################################

prune_unused_images() {
    print_header "Pruning Unused Images (Prestissimo, Milvus)"

    # Both 'setup' (the wrapper actually invoked) AND 'setup.sh' define
    # their own pull_all(). We have to patch both.
    local targets=(
        "$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/setup"
        "$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/setup.sh"
    )

    local patched=0
    for f in "${targets[@]}"; do
        if [ ! -f "$f" ]; then
            warn "$(basename "$f") not found — skipping"
            continue
        fi
        sed -i.bak \
            -e 's|^    pull_image ibm-lh-prestissimo|    # pull_image ibm-lh-prestissimo  # workshop: Java Presto only|' \
            -e 's|^    pull_image ibm-lh-milvus|    # pull_image ibm-lh-milvus  # workshop: no vector DB|' \
            "$f"
        patched=$((patched + 1))
    done

    log "✓ Pruned prestissimo and milvus from pull list ($patched file(s) patched)"
}

################################################################################
# Configure WatsonX Data
################################################################################

configure_watsonx_data() {
    print_header "Configuring WatsonX Data"
    
    log "Setting up cluster configuration with IBM Container Registry..."
    
    # Use the correct IBM registry path (cp not cpopen)
    "$WATSONX_INSTALL_DIR/ibm-lh-dev/bin/setup" \
        --license_acceptance=y \
        --runtime=podman \
        --registry=cp.icr.io/cp/watsonx-data \
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
    print_header "WatsonX Data Direct Installation"

    info "Method: image pull + host-side tar extraction (avoids slow container bind-mount writes during install)"
    info "Location: $WATSONX_INSTALL_DIR"
    echo
    
    check_prerequisites
    get_ibm_entitlement_key
    
    if check_existing_installation; then
        # podman machine layer only exists on macOS. Native Linux talks to the
        # podman socket directly; WSL2 runs podman inside the distro with no
        # machine. Skipping there avoids `Error: cannot list machines: ...`
        # when this installer is selected on those platforms.
        if [[ "$(uname -s)" == "Darwin" ]]; then
            setup_podman_machine
        else
            log "Skipping podman machine setup (not macOS — no machine layer to manage)"
        fi
        download_watsonx_data
        prune_unused_images
        configure_watsonx_data
        start_watsonx_data
    fi
    
    display_access_info
    
    log "✨ Installation complete!"
}

# Run main function
main

# Made with Bob