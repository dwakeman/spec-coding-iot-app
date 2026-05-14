#!/bin/bash

################################################################################
# WatsonX Data + Cassandra Workshop - Unified Installation Script
################################################################################
# 
# This script provides a seamless, one-command installation experience for:
# - WatsonX Data Developer Edition
# - Apache Cassandra 5.0
# - Sample data (e-commerce, IoT, financial)
# - Complete workshop environment
#
# Usage: ./setup/install-workshop.sh
#
# Author: Workshop Team
# Date: 2026-04-15
################################################################################

set -e  # Exit on error

# Colors for output (disabled when stdout is not a TTY so logs stay greppable)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; NC=''
fi

# Progress tracking
TOTAL_STEPS=7
CURRENT_STEP=0

# Non-interactive controls (env vars; flags parsed in main() set these too)
WORKSHOP_YES="${WORKSHOP_YES:-0}"           # 1 = skip all confirmation prompts
WORKSHOP_REINSTALL="${WORKSHOP_REINSTALL:-0}" # 1 = remove existing .watsonx-data
WORKSHOP_FROM="${WORKSHOP_FROM:-prereqs}"   # resume from: prereqs|watsonx|cassandra|data|iceberg|summary
WORKSHOP_NO_SUMMARY="${WORKSHOP_NO_SUMMARY:-0}"
WORKSHOP_SKIP_PREFLIGHT="${WORKSHOP_SKIP_PREFLIGHT:-0}"  # 1 = bypass ./setup/preflight.sh (emergency override)
# Accept WATSONX_ENTITLEMENT_KEY as an alias for IBM_ENTITLEMENT_KEY so a single
# .env works for both the workshop wrapper and the sub-installers.
if [[ -z "${IBM_ENTITLEMENT_KEY:-}" && -n "${WATSONX_ENTITLEMENT_KEY:-}" ]]; then
    export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
fi

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[STEP $CURRENT_STEP/$TOTAL_STEPS] $1${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Tagged log helpers. Every line starts with a fixed prefix so external
# monitors (and agents like Claude) can filter progress cleanly with one grep.
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }

# Skip check: honors WORKSHOP_FROM so a failed run can be resumed without
# re-doing expensive steps. Each step has an id; steps before the target id
# are skipped.
declare -a STEP_IDS=(prereqs watsonx cassandra data iceberg register summary)
step_enabled() {
    local id="$1" from="$WORKSHOP_FROM" i from_idx id_idx
    from_idx=-1; id_idx=-1
    for i in "${!STEP_IDS[@]}"; do
        [[ "${STEP_IDS[$i]}" == "$from" ]] && from_idx=$i
        [[ "${STEP_IDS[$i]}" == "$id" ]] && id_idx=$i
    done
    if (( from_idx < 0 )); then
        log_error "Unknown --from value: $from (valid: ${STEP_IDS[*]})"
        exit 2
    fi
    (( id_idx >= from_idx ))
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Wrap a step function with timing. Emits one [TIMING] line to stdout
# (greppable alongside [STEP N/7] / [OK] / [INFO]) and appends a per-step
# line to .workshop-timing.log so a slow run can be diagnosed by reading
# one file. Step functions that fail with `exit 1` short-circuit the wrapper
# and won't appear in the log — that's fine; the user has a bigger problem
# than missing timing if a step exits.
# Usage: time_step <step-id> <function-name>
time_step() {
    local id="$1" fn="$2"
    local start end elapsed
    start=$(date +%s)
    "$fn"
    local rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    echo
    echo -e "${BLUE}[TIMING]${NC} step=$id seconds=$elapsed ($((elapsed / 60))m $((elapsed % 60))s)"
    printf '%s step=%-10s seconds=%5d  (%dm %ds)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$id" "$elapsed" \
        "$((elapsed / 60))" "$((elapsed % 60))" >> .workshop-timing.log 2>/dev/null || true
    return $rc
}

################################################################################
# Step 1: Check Prerequisites and Install Podman if Needed
################################################################################

check_and_install_podman() {
    print_step "Checking Prerequisites"
    
    # Detect OS
    OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
    log_info "Detected OS: $OS_TYPE"
    
    # Check if Podman is installed
    if command -v podman &> /dev/null; then
        PODMAN_VERSION=$(podman --version | awk '{print $3}')
        log_success "Podman is already installed (version $PODMAN_VERSION)"
        return 0
    fi
    
    log_warn "Podman is not installed"
    echo
    if [[ "$WORKSHOP_YES" == "1" ]]; then
        INSTALL_PODMAN=y
        log_info "--yes: proceeding with Podman install"
    elif [[ -t 0 ]]; then
        read -p "Would you like to install Podman now? (y/n): " INSTALL_PODMAN
    else
        log_error "Podman not installed and stdin is not a TTY. Re-run with --yes or install Podman first."
        exit 1
    fi

    if [[ "$INSTALL_PODMAN" != "y" && "$INSTALL_PODMAN" != "Y" ]]; then
        log_error "Podman is required for this workshop"
        echo
        echo "Please install Podman manually:"
        case "$OS_TYPE" in
            darwin)
                echo "  brew install podman"
                ;;
            linux)
                echo "  # Ubuntu/Debian:"
                echo "  sudo apt-get update && sudo apt-get install -y podman"
                echo
                echo "  # RHEL/CentOS/Fedora:"
                echo "  sudo yum install -y podman"
                ;;
            *)
                echo "  Visit: https://podman.io/getting-started/installation"
                ;;
        esac
        exit 1
    fi
    
    echo
    log_info "Installing Podman..."
    
    case "$OS_TYPE" in
        darwin)
            # macOS installation
            if command -v brew &> /dev/null; then
                log_info "Installing Podman via Homebrew..."
                brew install podman
                log_success "Podman installed successfully"
            else
                log_error "Homebrew is not installed"
                echo "Please install Homebrew first: https://brew.sh"
                exit 1
            fi
            ;;
        linux)
            # Linux installation
            if [ -f /etc/debian_version ]; then
                # Debian/Ubuntu
                log_info "Installing Podman on Debian/Ubuntu..."
                sudo apt-get update
                sudo apt-get install -y podman
                log_success "Podman installed successfully"
            elif [ -f /etc/redhat-release ]; then
                # RHEL/CentOS/Fedora
                log_info "Installing Podman on RHEL/CentOS/Fedora..."
                sudo yum install -y podman
                log_success "Podman installed successfully"
            else
                log_error "Unsupported Linux distribution"
                echo "Please install Podman manually: https://podman.io/getting-started/installation"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported operating system: $OS_TYPE"
            echo "Please install Podman manually: https://podman.io/getting-started/installation"
            exit 1
            ;;
    esac
    
    # Verify installation
    if command -v podman &> /dev/null; then
        PODMAN_VERSION=$(podman --version | awk '{print $3}')
        log_success "Podman $PODMAN_VERSION installed and ready"
    else
        log_error "Podman installation failed"
        exit 1
    fi
}

################################################################################
# Step 2: Install WatsonX Data Developer Edition
################################################################################

install_watsonx_data() {
    print_step "Installing WatsonX Data Developer Edition"
    
    log_info "This will take 20-30 minutes depending on your internet speed..."
    log_info "Installation will be in: $(pwd)/.watsonx-data"
    echo
    
    # Check if installation script exists
    if [ ! -f "setup/watsonx-data/install-watsonx-data.sh" ]; then
        log_error "WatsonX Data installation script not found"
        exit 1
    fi
    
    # Make script executable
    chmod +x setup/watsonx-data/install-watsonx-data.sh
    
    # Choose installer:
    #   direct  — image pull + host-side tar extraction. Avoids the slow
    #             container-bind-mount path during install.
    #             Used on ARM64 (the original Apple Silicon case) and on WSL2
    #             (where the standard bind-mount path runs through 9p and
    #             turns the 30-min install into a 90+ minute crawl when the
    #             repo is on /mnt/<drive>/).
    #   standard — runs `get-ibm-lh-dev` inside the toolbox container with a
    #             bind-mount back to .watsonx-data/. Fastest on native Linux
    #             ext4 / macOS APFS, pathological on WSL2 with /mnt paths.
    ARCH=$(uname -m)
    IS_WSL2=0
    if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        IS_WSL2=1
    fi
    if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
        log_info "Detected Apple Silicon (ARM64) — using direct installer"
        INSTALL_SCRIPT="./setup/watsonx-data/install-watsonx-data-direct.sh"
    elif (( IS_WSL2 )); then
        log_info "Detected WSL2 — using direct installer (avoids slow 9p bind-mount during install)"
        INSTALL_SCRIPT="./setup/watsonx-data/install-watsonx-data-direct.sh"
    else
        log_info "Detected Intel/AMD (x86_64) — using standard installer"
        INSTALL_SCRIPT="./setup/watsonx-data/install-watsonx-data.sh"
    fi
    
    # Run installation
    log_info "Starting WatsonX Data installation..."
    echo
    
    if $INSTALL_SCRIPT; then
        log_success "WatsonX Data installed successfully"
    else
        log_error "WatsonX Data installation failed"
        exit 1
    fi
    
    # Wait for services to be fully ready
    log_info "Waiting for WatsonX Data services to be ready..."
    sleep 10
    
    # Verify web interface is accessible
    MAX_RETRIES=30
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if curl -k -s "https://localhost:9443/lakehouse/api/v3/ready" 2>/dev/null | grep -q "Lakehouse Console Server is up"; then
            log_success "WatsonX Data is ready and accessible"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo -n "."
        sleep 2
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        log_warn "Could not verify WatsonX Data readiness, but continuing..."
    fi
}

################################################################################
# Step 3: Deploy Apache Cassandra
################################################################################

deploy_cassandra() {
    print_step "Deploying Apache Cassandra 5.0"
    
    # Check if deployment script exists
    if [ ! -f "setup/cassandra/deploy-cassandra.sh" ]; then
        log_error "Cassandra deployment script not found"
        exit 1
    fi
    
    # Make script executable
    chmod +x setup/cassandra/deploy-cassandra.sh
    
    # Run deployment
    log_info "Deploying Cassandra container..."
    echo
    
    if ./setup/cassandra/deploy-cassandra.sh; then
        log_success "Cassandra deployed successfully"
    else
        log_error "Cassandra deployment failed"
        exit 1
    fi
    
    # Sample-data loader creates its own keyspaces (ecommerce / iot / financial),
    # so no generic 'workshop' keyspace is needed here.
    sleep 5
}

################################################################################
# Step 4: Generate and Load Sample Data
################################################################################

load_sample_data() {
    print_step "Generating and Loading Sample Data"
    
    log_info "This will create realistic sample data and load it into Cassandra..."
    echo
    
    # Check if Python is available
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Use the new Python-based data loader with virtual environment
    log_info "Loading sample data using Python loader..."
    if [ -f "setup/sample-data/load-data-with-venv.sh" ]; then
        bash setup/sample-data/load-data-with-venv.sh
        if [ $? -eq 0 ]; then
            log_success "Sample data loaded successfully"
        else
            log_error "Failed to load sample data"
            exit 1
        fi
    else
        log_error "Data loader script not found"
        exit 1
    fi
}

################################################################################
# Step 4.5: Create Iceberg Tables
################################################################################

create_iceberg_tables() {
    print_step "Creating Iceberg Tables + Loading Iceberg Data"

    local PRESTO_CLI="./.watsonx-data/ibm-lh-dev/bin/presto-cli"
    local VENV_PY="./setup/sample-data/.venv/bin/python3"

    if [ ! -f "$PRESTO_CLI" ]; then
        log_warn "Presto CLI not found at $PRESTO_CLI — skipping"
        log_info "Re-run manually: ./setup/sample-data/create-iceberg-tables.sh && $VENV_PY ./setup/sample-data/load-iceberg-data.py"
        return 0
    fi

    log_info "Waiting for Presto to be fully ready..."
    sleep 15

    log_info "Creating Iceberg schemas (22 tables across 3 domains)..."
    if ! ./setup/sample-data/create-iceberg-tables.sh; then
        log_warn "Iceberg schema creation had errors — see output above"
        log_info "You can re-run with: ./setup/sample-data/create-iceberg-tables.sh"
        return 0
    fi
    log_success "Iceberg schemas created"

    if [ ! -x "$VENV_PY" ]; then
        log_warn "Python venv not found at $VENV_PY — skipping Iceberg data load"
        log_info "The load-data step (step 4) creates this venv. If you ran the installer"
        log_info "in a different order, run it manually then:"
        log_info "  $VENV_PY ./setup/sample-data/load-iceberg-data.py"
        return 0
    fi

    log_info "Loading Iceberg data (parquet → Hive staging → Iceberg)..."
    echo
    if "$VENV_PY" ./setup/sample-data/load-iceberg-data.py; then
        log_success "Iceberg data loaded"
    else
        log_warn "Iceberg data load had errors — see output above"
        log_info "You can re-run with: $VENV_PY ./setup/sample-data/load-iceberg-data.py"
    fi
}

################################################################################
# Step 5: Display Cassandra Registration Instructions
################################################################################

show_registration_instructions() {
    print_step "Cassandra Registration Instructions"
    
    echo -e "${CYAN}WatsonX Data Developer Edition requires manual database registration."
    echo -e "Please follow these steps to complete the setup:${NC}"
    echo
    echo -e "${GREEN}1. Open WatsonX Data UI:${NC}"
    echo -e "   ${BLUE}https://localhost:9443${NC}"
    echo
    echo -e "${GREEN}2. Login with:${NC}"
    echo -e "   Username: ${CYAN}ibmlhadmin${NC}"
    echo -e "   Password: ${CYAN}password${NC}"
    echo
    echo -e "${GREEN}3. Navigate to:${NC}"
    echo -e "   ${CYAN}Infrastructure Manager${NC} → ${CYAN}Databases${NC}"
    echo
    echo -e "${GREEN}4. Click 'Add database' and enter:${NC}"
    echo -e "   ${YELLOW}Display name:${NC}     ${CYAN}cassandra_workshop${NC}"
    echo -e "   ${YELLOW}Database type:${NC}    ${CYAN}Apache Cassandra${NC}"
    echo -e "   ${YELLOW}Hostname:${NC}         ${CYAN}host.containers.internal${NC}"
    echo -e "   ${YELLOW}Port:${NC}             ${CYAN}9042${NC}"
    echo -e "   ${YELLOW}Username:${NC}         ${CYAN}cassandra${NC}"
    echo -e "   ${YELLOW}Password:${NC}         ${CYAN}cassandra${NC}"
    echo -e "   ${YELLOW}Catalog name:${NC}     ${CYAN}cassandra_catalog${NC}"
    echo
    echo -e "${GREEN}5. Click 'Test connection' then 'Add'${NC}"
    echo
    echo -e "${GREEN}6. (If needed) Re-create Iceberg Tables:${NC}"
    echo -e "   ${CYAN}./setup/sample-data/create-iceberg-tables.sh${NC}"
    echo
    echo -e "   ${YELLOW}Note:${NC} Iceberg tables are independent of Cassandra registration."
    echo -e "   They are already created during install. Registering Cassandra enables"
    echo -e "   federated queries that join cassandra_catalog with iceberg_data."
    echo
    echo -e "${BLUE}This takes about 2-3 minutes and helps you learn the WatsonX Data UI!${NC}"
    echo
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}🤖 AGENT — READ THIS AND RELAY IT TO THE ATTENDEE${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "The install is done, but ${YELLOW}one manual step remains${NC} that only"
    echo -e "the attendee can do (it requires a browser session in the watsonx.data"
    echo -e "UI). You cannot complete this step yourself."
    echo
    echo -e "Stop here and tell the attendee, in your own words:"
    echo
    echo -e "  ${CYAN}\"Open ${BLUE}https://localhost:9443${CYAN} in your browser, log in${NC}"
    echo -e "  ${CYAN} as ${YELLOW}ibmlhadmin / password${CYAN}, then go to:${NC}"
    echo -e "  ${CYAN}   Infrastructure Manager → Databases → Add database${NC}"
    echo -e "  ${CYAN} Pick ${YELLOW}Apache Cassandra${CYAN} and enter exactly:${NC}"
    echo -e "  ${CYAN}   Display name:  cassandra_workshop${NC}"
    echo -e "  ${CYAN}   Hostname:      host.containers.internal${NC}"
    echo -e "  ${CYAN}   Port:          9042${NC}"
    echo -e "  ${CYAN}   Username:      cassandra${NC}"
    echo -e "  ${CYAN}   Password:      cassandra${NC}"
    echo -e "  ${CYAN}   Catalog name:  cassandra_catalog${NC}"
    echo -e "  ${CYAN} Click ${YELLOW}Test connection${CYAN}, then ${YELLOW}Add${CYAN}.${NC}"
    echo -e "  ${CYAN} The catalog wires up in the same form — no separate associate step.\"${NC}"
    echo
    echo -e "Wait for the attendee to confirm they've done this before continuing"
    echo -e "with the workshop. If they say they hit an issue, read"
    echo -e "${CYAN}docs/getting-unstuck.md${NC} (\"Cassandra registration\" section) and walk"
    echo -e "them through the diagnostics."
    echo
}

################################################################################
# Step 6: Display Success Summary
################################################################################

show_success_summary() {
    print_step "Installation Complete!"
    
    echo -e "${GREEN}🎉 Congratulations! Your workshop environment is ready!${NC}"
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}What's Installed:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${GREEN}✓${NC} WatsonX Data Developer Edition"
    echo -e "    ${BLUE}→${NC} Web UI: https://localhost:9443"
    echo -e "    ${BLUE}→${NC} Username: ibmlhadmin"
    echo -e "    ${BLUE}→${NC} Password: password"
    echo
    echo -e "  ${GREEN}✓${NC} Apache Cassandra 5.0"
    echo -e "    ${BLUE}→${NC} Host: host.containers.internal"
    echo -e "    ${BLUE}→${NC} Port: 9042"
    echo -e "    ${BLUE}→${NC} Keyspaces: ecommerce, iot, financial"
    echo
    echo -e "  ${GREEN}✓${NC} Sample Data Loaded"
    echo -e "    ${BLUE}→${NC} E-commerce (customers, orders, products)"
    echo -e "    ${BLUE}→${NC} IoT (sensor readings, devices)"
    echo -e "    ${BLUE}→${NC} Financial (transactions, accounts)"
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${MAGENTA}1.${NC} ${GREEN}Register Cassandra${NC} (see instructions above)"
    echo
    echo -e "  ${MAGENTA}2.${NC} ${GREEN}Explore the Data:${NC}"
    echo -e "     ${BLUE}podman exec -it cassandra-workshop cqlsh${NC}"
    echo -e "     ${BLUE}DESCRIBE KEYSPACES;${NC}"
    echo -e "     ${BLUE}USE ecommerce;${NC}"
    echo -e "     ${BLUE}DESCRIBE TABLES;${NC}"
    echo -e "     ${BLUE}SELECT * FROM customers LIMIT 5;${NC}"
    echo
    echo -e "  ${MAGENTA}3.${NC} ${GREEN}Run Federated Queries:${NC}"
    echo -e "     Open Query Workspace in WatsonX Data UI"
    echo -e "     Try: ${BLUE}SELECT * FROM cassandra_catalog.ecommerce.customers LIMIT 10;${NC}"
    echo
    echo -e "  ${MAGENTA}4.${NC} ${GREEN}Start Building:${NC}"
    echo -e "     Wait for the instructor's on-screen prompts."
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${BLUE}# Check WatsonX Data status${NC}"
    echo -e "  \$LH_ROOT_DIR/ibm-lh-dev/bin/status --all"
    echo
    echo -e "  ${BLUE}# Check Cassandra status${NC}"
    echo -e "  podman ps | grep cassandra"
    echo
    echo -e "  ${BLUE}# View Cassandra logs${NC}"
    echo -e "  podman logs cassandra-workshop"
    echo
    echo -e "  ${BLUE}# Restart services${NC}"
    echo -e "  \$LH_ROOT_DIR/ibm-lh-dev/bin/stop && \$LH_ROOT_DIR/ibm-lh-dev/bin/start"
    echo
    echo -e "  ${BLUE}# Complete cleanup (if needed)${NC}"
    echo -e "  ./setup/cleanup-all.sh"
    echo
    echo -e "${GREEN}Happy coding! 🚀${NC}"
    echo
}

################################################################################
# Usage / Arg Parsing
################################################################################

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Installs the full watsonx.data + Cassandra workshop environment.

Options:
  --yes, -y             Non-interactive: skip all "are you sure?" prompts.
                        (Equivalent to: WORKSHOP_YES=1)
  --reinstall           If .watsonx-data/ already exists, remove it and
                        install fresh. Without this, a prior install is reused.
                        (Equivalent to: WORKSHOP_REINSTALL=1)
  --from <step>         Resume installation starting at <step>. Useful when an
                        earlier step already succeeded. Valid steps:
                          prereqs (default) | watsonx | cassandra | data |
                          iceberg | register | summary
                        (Equivalent to: WORKSHOP_FROM=<step>)
  --no-summary          Skip the end-of-run summary (row counts).
  --skip-preflight      Skip the ./setup/preflight.sh checks that run by
                        default at the start. Emergency override only —
                        you'll see a [WARN] line in the install output.
                        (Equivalent to: WORKSHOP_SKIP_PREFLIGHT=1)
  -h, --help            Show this help.

Environment variables:
  IBM_ENTITLEMENT_KEY       IBM Container Registry entitlement key (required).
  WATSONX_ENTITLEMENT_KEY   Accepted as an alias for IBM_ENTITLEMENT_KEY.
  WORKSHOP_YES / WORKSHOP_REINSTALL / WORKSHOP_FROM / WORKSHOP_NO_SUMMARY /
  WORKSHOP_SKIP_PREFLIGHT   Equivalents of the flags above.

Examples:
  # Fully non-interactive fresh install (typical CI / agent run):
  WORKSHOP_YES=1 WORKSHOP_REINSTALL=1 ./setup/install-workshop.sh

  # Data load died; pick up from there without reinstalling watsonx/cassandra:
  ./setup/install-workshop.sh --yes --from data
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --yes|-y)       WORKSHOP_YES=1 ;;
            --reinstall)    WORKSHOP_REINSTALL=1 ;;
            --from)         WORKSHOP_FROM="${2:?--from requires a step name}"; shift ;;
            --from=*)       WORKSHOP_FROM="${1#--from=}" ;;
            --no-summary)   WORKSHOP_NO_SUMMARY=1 ;;
            --skip-preflight) WORKSHOP_SKIP_PREFLIGHT=1 ;;
            -h|--help)      show_usage; exit 0 ;;
            *)              log_error "Unknown argument: $1"; show_usage; exit 2 ;;
        esac
        shift
    done
    # Validate --from up front so a typo fails before the 30-minute install.
    local valid=0 s
    for s in "${STEP_IDS[@]}"; do [[ "$WORKSHOP_FROM" == "$s" ]] && valid=1 && break; done
    if (( ! valid )); then
        log_error "Invalid --from value: $WORKSHOP_FROM (valid: ${STEP_IDS[*]})"
        exit 2
    fi
    export WORKSHOP_YES WORKSHOP_REINSTALL WORKSHOP_FROM WORKSHOP_NO_SUMMARY WORKSHOP_SKIP_PREFLIGHT
}

################################################################################
# End-of-run Summary (row counts across Cassandra + Iceberg)
################################################################################

show_summary() {
    [[ "$WORKSHOP_NO_SUMMARY" == "1" ]] && return 0
    # The summary is best-effort diagnostic output: a flaky cqlsh / presto-cli
    # call (common on a freshly-started cluster) must not turn a successful
    # install into exit 1. Disable errexit for the duration of this function
    # and restore the prior state on exit.
    local _prior_errexit=0
    [[ $- == *e* ]] && _prior_errexit=1
    set +e
    _restore_errexit() { (( _prior_errexit )) && set -e; }
    print_header "Workshop Environment Summary"
    echo -e "${CYAN}Cassandra keyspaces:${NC}"
    # Find the podman connection that can see cassandra-workshop. On macOS,
    # `watsonx-workshop` (rootless) and `watsonx-workshop-root` (rootful) are
    # the two connections the machine init creates, and wxd + cassandra live
    # in the rootful one. On Linux/WSL2 there is no machine and no named
    # connection — bare `podman` (no -c) talks to the local socket directly.
    # Probe in preference order until we find the container.
    local cassandra_podman="" cassandra_ok=0
    for cand in "" "-c watsonx-workshop-root" "-c watsonx-workshop"; do
        if podman $cand ps --format '{{.Names}}' 2>/dev/null | grep -q '^cassandra-workshop$'; then
            cassandra_podman="podman $cand"
            cassandra_ok=1
            break
        fi
    done
    if (( cassandra_ok )); then
        for ks in ecommerce iot financial; do
            echo -e "  ${BLUE}$ks${NC}"
            # Materialize the table list first so the inner cqlsh per-table
            # doesn't consume the outer loop's stdin.
            local tables
            tables=$($cassandra_podman exec -i cassandra-workshop cqlsh \
                -u cassandra -p cassandra -e \
                "SELECT table_name FROM system_schema.tables WHERE keyspace_name='$ks';" \
                </dev/null 2>/dev/null | awk 'NR>3 && NF==1 {print $1}')
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                local cnt
                cnt=$($cassandra_podman exec -i cassandra-workshop cqlsh \
                    -u cassandra -p cassandra -e "SELECT COUNT(*) FROM $ks.$tbl;" \
                    </dev/null 2>/dev/null | awk 'NR==4 {print $1}')
                printf "    %-32s %s\n" "$tbl" "${cnt:-?}"
            done <<< "$tables"
        done
    else
        log_warn "cassandra-workshop container not running — skipping Cassandra counts"
    fi

    echo
    echo -e "${CYAN}Iceberg schemas (iceberg_data catalog):${NC}"
    # Use the Presto HTTP API instead of presto-cli. Per
    # setup/release/AGENTS-attendee.md, presto-cli spawns a fresh JVM per
    # invocation (30+ seconds under amd64 emulation) and frequently appears
    # to hang. The summary ran presto-cli once per Iceberg table (~22 tables
    # × cold-start), which timed out at 15 min on Win11/WSL2 (issue #74)
    # and was painfully slow on macOS too (issue #57). HTTP returns each
    # count in 1-3 seconds.
    if ! python3 - <<'PY'
import base64, json, ssl, sys, time, urllib.error, urllib.request

ENDPOINT = "https://localhost:8443/v1/statement"
USER, PW = "ibmlhadmin", "password"
SCHEMAS = ["ecommerce", "iot", "financial"]
TIMEOUT = 30  # seconds per HTTP request

USE_COLOR = sys.stdout.isatty()
BLUE = "\033[0;34m" if USE_COLOR else ""
NC = "\033[0m" if USE_COLOR else ""

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
auth = base64.b64encode(f"{USER}:{PW}".encode()).decode()
HEADERS = {"Authorization": f"Basic {auth}", "X-Presto-User": USER}


def query(sql, schema):
    """Run one Presto statement; return all result rows as a list of lists."""
    h = dict(HEADERS, **{"X-Presto-Catalog": "iceberg_data",
                          "X-Presto-Schema": schema})
    req = urllib.request.Request(ENDPOINT, data=sql.encode(),
                                  headers=h, method="POST")
    rsp = json.loads(urllib.request.urlopen(req, context=ctx,
                                             timeout=TIMEOUT).read())
    rows = []
    while True:
        rows.extend(rsp.get("data") or [])
        nxt = rsp.get("nextUri")
        if not nxt:
            break
        if rsp.get("stats", {}).get("state") in ("QUEUED", "PLANNING"):
            time.sleep(0.1)
        rsp = json.loads(urllib.request.urlopen(
            urllib.request.Request(nxt, headers=HEADERS),
            context=ctx, timeout=TIMEOUT,
        ).read())
    if "error" in rsp:
        raise RuntimeError(rsp["error"].get("message", "presto error"))
    return rows


for schema in SCHEMAS:
    print(f"  {BLUE}{schema}{NC}")
    try:
        tables = query(
            "SELECT table_name FROM information_schema.tables "
            f"WHERE table_schema='{schema}' ORDER BY table_name",
            schema,
        )
    except (urllib.error.URLError, RuntimeError, OSError) as e:
        print(f"    (could not list tables: {e})")
        continue
    for row in tables:
        tbl = row[0]
        try:
            r = query(f"SELECT COUNT(*) FROM {tbl}", schema)
            cnt = r[0][0] if r else "?"
        except (urllib.error.URLError, RuntimeError, OSError) as e:
            cnt = f"err: {e}"
        print(f"    {tbl:<32} {cnt}")
PY
    then
        log_warn "Iceberg summary failed — Presto may not be ready at https://localhost:8443"
    fi
    echo
    [[ $cassandra_ok -eq 1 ]] && log_success "Environment is up and reachable."
    _restore_errexit
}

################################################################################
# Main Installation Flow
################################################################################

main() {
    parse_args "$@"

    # Detect and adjust working directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

    # Check if we're in the setup directory or parent directory
    if [[ "$SCRIPT_DIR" == */setup ]]; then
        # Script is in setup/, so we need to go up one level
        cd "$SCRIPT_DIR/.."
        log_info "Adjusting working directory to: $(pwd)"
    elif [[ -d "$SCRIPT_DIR/setup" ]]; then
        # Script is in parent directory, already correct
        cd "$SCRIPT_DIR"
    else
        log_error "Cannot determine correct working directory"
        exit 1
    fi

    # Verify we're in the correct location
    if [[ ! -d "setup/watsonx-data" ]] || [[ ! -d "setup/cassandra" ]]; then
        log_error "Required directories not found. Please run from the workshop root directory."
        exit 1
    fi

    # Load .env so sub-installers see the entitlement key without the caller
    # having to export it. We do this after chdir so we look in repo root.
    if [[ -f .env ]]; then
        set -a; source .env; set +a
        [[ -z "${IBM_ENTITLEMENT_KEY:-}" && -n "${WATSONX_ENTITLEMENT_KEY:-}" ]] && \
            export IBM_ENTITLEMENT_KEY="$WATSONX_ENTITLEMENT_KEY"
        log_info "Loaded .env (entitlement key: $([[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && echo present || echo missing))"
    fi

    # Record start time
    START_TIME=$(date +%s)
    START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Append a header to the per-step timing log so multiple runs are
    # distinguishable. Platform line is included to make WSL2 vs macOS vs
    # native Linux runs easy to triage when comparing logs across attendees.
    {
        echo "# ======================================================================"
        echo "# Install run started: $START_TIMESTAMP"
        [[ "$WORKSHOP_FROM" != "prereqs" ]] && echo "# Resuming from: $WORKSHOP_FROM"
        echo "# Working dir: $PWD"
        if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
            echo "# Platform: WSL2 ($(uname -m))"
        else
            echo "# Platform: $(uname -s) $(uname -m)"
        fi
        echo "# ----------------------------------------------------------------------"
    } >> .workshop-timing.log 2>/dev/null || true

    print_header "WatsonX Data + Cassandra Workshop Installation"

    echo -e "${CYAN}This script will install and configure:${NC}"
    echo -e "  • WatsonX Data Developer Edition"
    echo -e "  • Apache Cassandra 5.0"
    echo -e "  • Sample datasets (e-commerce, IoT, financial)"
    echo -e "  • Iceberg tables for analytics"
    echo -e "  • Complete workshop environment"
    echo
    echo -e "${YELLOW}Estimated time: 30-40 minutes${NC}"
    echo -e "${YELLOW}Required: IBM Entitlement Key${NC}"
    if [[ "$WORKSHOP_FROM" != "prereqs" ]]; then
        echo
        log_info "Resuming from step: $WORKSHOP_FROM"
    fi
    echo
    if [[ "$WORKSHOP_YES" != "1" && -t 0 ]]; then
        read -p "Press Enter to continue or Ctrl+C to cancel..."
    fi

    # On macOS, refuse to run if the workshop directory is outside $HOME.
    # The rootful applehv podman machine only mounts $HOME from the macOS host,
    # so a bundle extracted to /tmp, /Volumes/<external>, or any other path
    # outside ~ produces a confusing failure in step 2/7 ("statfs ... no such
    # file or directory") because watsonx.data containers can't see their own
    # bind-mounted state. Fail fast with a clear message instead.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        case "$PWD" in
            "$HOME"|"$HOME"/*) ;;
            *)
                log_error "The workshop must run from a path under your home directory (\$HOME=$HOME)."
                log_error "Current directory ($PWD) is outside \$HOME. The rootful podman VM only"
                log_error "mounts \$HOME, so the install will fail at step 2/7 with a 'statfs' error."
                log_error "Move (or re-extract) the workshop bundle into ~/Downloads, ~/Desktop, or anywhere under ~ and re-run."
                exit 1
                ;;
        esac
    fi

    # On macOS, ensure a podman machine exists and is running before pre-flight.
    # Pre-flight requires a healthy machine to probe the daemon and run a test
    # pull, but a brand-new (or post-cleanup) host has no machine yet. Without
    # this, every cold-start install hit a confusing pre-flight FAIL whose only
    # remediation was to copy/paste a `podman machine init --rootful` command.
    # The installer's own setup_podman_machine (in install-watsonx-data*.sh)
    # does this later, but pre-flight runs first — so we bootstrap here.
    # Linux/WSL2 has no podman machine concept; this is a no-op there.
    if [[ "$(uname -s)" == "Darwin" && "$WORKSHOP_SKIP_PREFLIGHT" != "1" ]]; then
        if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
            local machine_name="watsonx-workshop"
            if podman machine list 2>/dev/null | grep -q "$machine_name"; then
                log_info "Starting existing podman machine '$machine_name' before pre-flight..."
                podman machine start "$machine_name"
            else
                log_info "No podman machine found; creating '$machine_name' (rootful, 8 CPU, 16 GB RAM, 200 GB disk) before pre-flight..."
                log_info "First-time machine creation downloads the VM OS image (~600 MB); please wait."
                podman machine init --rootful --cpus 8 --memory 16384 --disk-size 200 "$machine_name"
                podman machine start "$machine_name"
            fi
            log_success "Podman machine ready"
            echo
        fi

        # Pin the default podman connection to rootful. `podman machine init
        # --rootful` does this at creation, but the default can drift to
        # rootless during normal use (any explicit `podman --connection
        # watsonx-workshop ...` call has been observed to flip it). When that
        # happens, every bare `podman` invocation in the install scripts goes
        # to the rootless namespace, while watsonx.data lives in rootful — so
        # cassandra ends up in a different network than watsonx, federation
        # breaks, and diagnostics get very confusing very fast. Pin every run.
        if podman system connection list 2>/dev/null | grep -q "watsonx-workshop-root"; then
            podman system connection default watsonx-workshop-root >/dev/null 2>&1 || true
        fi
    fi

    # Pre-flight checks (always run unless explicitly skipped). Catches the
    # cheap-but-painful failures — bad entitlement key, port conflicts, podman
    # not healthy — before the 20-minute watsonx download. Not gated by
    # --from: even a resumed run wants these checks (host may have changed,
    # ports may now conflict, podman socket may be stale).
    if [[ "$WORKSHOP_SKIP_PREFLIGHT" == "1" ]]; then
        log_warn "Pre-flight checks skipped (--skip-preflight). You're flying blind; install may fail late on issues pre-flight would have caught early."
    elif [[ -x ./setup/preflight.sh ]]; then
        if ./setup/preflight.sh; then
            log_success "Pre-flight checks passed"
        else
            echo
            log_error "Pre-flight checks failed. See [REMEDIATION] above."
            if [[ "$WORKSHOP_YES" == "1" || ! -t 0 ]]; then
                log_info "Re-run with --skip-preflight to bypass (not recommended)."
                exit 1
            fi
            read -p "Continue anyway? [y/N] " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                log_info "Aborted. Fix the issues above and re-run, or use --skip-preflight to bypass."
                exit 1
            fi
            log_warn "Continuing despite pre-flight failures."
        fi
    else
        log_warn "setup/preflight.sh not found or not executable; skipping pre-flight checks"
    fi

    # Execute installation steps (gated by --from). Each step is wrapped in
    # time_step so per-step duration is captured to .workshop-timing.log,
    # making "where did the hour go?" a single grep instead of guesswork.
    step_enabled prereqs   && time_step prereqs   check_and_install_podman
    step_enabled watsonx   && time_step watsonx   install_watsonx_data
    step_enabled cassandra && time_step cassandra deploy_cassandra
    step_enabled data      && time_step data      load_sample_data
    step_enabled iceberg   && time_step iceberg   create_iceberg_tables
    step_enabled register  && time_step register  show_registration_instructions
    step_enabled summary   && time_step summary   show_success_summary

    show_summary
    
    # Calculate elapsed time
    END_TIME=$(date +%s)
    END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED=$((END_TIME - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    
    # Save installation details
    cat > .workshop-installed << EOF
Installation Start: ${START_TIMESTAMP}
Installation End:   ${END_TIMESTAMP}
Total Time:         ${MINUTES}m ${SECONDS}s
EOF
    
    echo
    log_success "Total installation time: ${MINUTES}m ${SECONDS}s"
}

# Run main installation
main "$@"

# Made with ❤️ by Bob

# Made with Bob
