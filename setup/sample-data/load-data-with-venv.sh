#!/bin/bash
# ============================================================================
# Load Cassandra Data with Python Virtual Environment
# Purpose: Create venv, install dependencies, and load data
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
PYTHON_SCRIPT="${SCRIPT_DIR}/load_cassandra_data.py"

print_header() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if Cassandra is running. Cassandra runs on the rootless podman
# connection while watsonx.data runs rootful, so the default `podman`
# connection depends on which tool was last used. Probe both connections
# (and the default) to find cassandra-workshop, then pin PODMAN_CASSANDRA
# so every subsequent call routes to the right place.
check_cassandra() {
    print_info "Checking Cassandra connection..."
    PODMAN_CASSANDRA=""
    for conn in "" "-c watsonx-workshop" "-c watsonx-workshop-root"; do
        if podman $conn ps --format "{{.Names}}" 2>/dev/null | grep -q "^cassandra-workshop$"; then
            PODMAN_CASSANDRA="podman $conn"
            break
        fi
    done
    if [[ -z "$PODMAN_CASSANDRA" ]]; then
        print_error "Cassandra container is not running"
        print_info "Start it with: podman start cassandra-workshop"
        exit 1
    fi

    # Test connection
    if ! $PODMAN_CASSANDRA exec cassandra-workshop cqlsh -e "DESCRIBE KEYSPACES" &> /dev/null; then
        print_error "Cassandra is not ready yet"
        print_info "Wait a few seconds and try again"
        exit 1
    fi

    print_success "Cassandra is running and accessible (via: ${PODMAN_CASSANDRA})"
    export PODMAN_CASSANDRA
}

# Create virtual environment
setup_venv() {
    print_header "Setting Up Python Virtual Environment"

    # A pre-existing .venv may be partial / corrupt — happens when an earlier
    # run was interrupted, or when python3 existed but python3-venv didn't
    # (Ubuntu default), leaving an empty .venv directory that python won't
    # touch on a re-run. Probe the venv before reusing it; if anything is
    # missing, blow it away and recreate from scratch (cf. issue #72:
    # attendee had to manually `rm -rf setup/sample-data/.venv` between
    # failed runs).
    local venv_python="${VENV_DIR}/bin/python3"
    local venv_ok=0
    if [ -d "$VENV_DIR" ]; then
        if [ -x "$venv_python" ] && "$venv_python" -c 'import pip, ensurepip' &>/dev/null; then
            venv_ok=1
            print_info "Virtual environment already exists and is usable"
        else
            print_info "Existing .venv at $VENV_DIR looks partial/corrupt — recreating"
            rm -rf "$VENV_DIR"
        fi
    fi

    if (( ! venv_ok )); then
        print_info "Creating virtual environment..."
        if ! python3 -m venv "$VENV_DIR"; then
            print_error "python3 -m venv failed"
            print_info "On Ubuntu/Debian: sudo apt-get install -y python3-venv  (then re-run)"
            exit 1
        fi
        print_success "Virtual environment created"
    fi

    # Activate virtual environment
    source "${VENV_DIR}/bin/activate"

    # Upgrade pip
    print_info "Upgrading pip..."
    pip install --quiet --upgrade pip

    # Install dependencies
    print_info "Installing cassandra-driver and pyarrow..."
    pip install --quiet cassandra-driver pyarrow

    print_success "Dependencies installed"
}

# Create schemas
create_schemas() {
    print_header "Creating Cassandra Schemas"
    
    # Create ecommerce schema
    if [ -f "${SCRIPT_DIR}/ecommerce/cassandra_schema.cql" ]; then
        print_info "Creating ecommerce keyspace and tables..."
        ${PODMAN_CASSANDRA:-podman} exec -i cassandra-workshop cqlsh < "${SCRIPT_DIR}/ecommerce/cassandra_schema.cql"
        print_success "Ecommerce schema created"
    fi
    
    # Create IoT schema
    if [ -f "${SCRIPT_DIR}/iot/cassandra_schema.cql" ]; then
        print_info "Creating iot keyspace and tables..."
        ${PODMAN_CASSANDRA:-podman} exec -i cassandra-workshop cqlsh < "${SCRIPT_DIR}/iot/cassandra_schema.cql"
        print_success "IoT schema created"
    fi
    
    # Create financial schema
    if [ -f "${SCRIPT_DIR}/financial/cassandra_schema.cql" ]; then
        print_info "Creating financial keyspace and tables..."
        ${PODMAN_CASSANDRA:-podman} exec -i cassandra-workshop cqlsh < "${SCRIPT_DIR}/financial/cassandra_schema.cql"
        print_success "Financial schema created"
    fi
}

# Generate sample data
generate_data() {
    print_header "Generating Sample Data"
    
    # Activate venv
    source "${VENV_DIR}/bin/activate"
    
    # Check if data generation is needed
    local needs_generation=false
    
    # Check ecommerce data
    if [ ! -d "${SCRIPT_DIR}/ecommerce/generated_data" ] || [ -z "$(ls -A ${SCRIPT_DIR}/ecommerce/generated_data 2>/dev/null)" ]; then
        needs_generation=true
        print_info "Generating ecommerce data..."
        cd "${SCRIPT_DIR}/ecommerce"
        python3 generate_data.py
        cd "${SCRIPT_DIR}"
        print_success "Ecommerce data generated"
    else
        print_info "Ecommerce data already exists"
    fi
    
    # Check IoT data
    if [ ! -d "${SCRIPT_DIR}/iot/generated_data" ] || [ -z "$(ls -A ${SCRIPT_DIR}/iot/generated_data 2>/dev/null)" ]; then
        needs_generation=true
        print_info "Generating IoT data..."
        cd "${SCRIPT_DIR}/iot"
        python3 generate_data.py
        cd "${SCRIPT_DIR}"
        print_success "IoT data generated"
    else
        print_info "IoT data already exists"
    fi
    
    # Check financial data
    if [ ! -d "${SCRIPT_DIR}/financial/generated_data" ] || [ -z "$(ls -A ${SCRIPT_DIR}/financial/generated_data 2>/dev/null)" ]; then
        needs_generation=true
        print_info "Generating financial data..."
        cd "${SCRIPT_DIR}/financial"
        python3 generate_data.py
        cd "${SCRIPT_DIR}"
        print_success "Financial data generated"
    else
        print_info "Financial data already exists"
    fi
    
    if [ "$needs_generation" = false ]; then
        print_success "All sample data already generated"
    fi
}

# Load data
load_data() {
    print_header "Loading Data into Cassandra"
    
    # Activate venv
    source "${VENV_DIR}/bin/activate"
    
    # Run the Python loader
    python3 "$PYTHON_SCRIPT"
}

# Main execution
main() {
    print_header "Cassandra Data Loader with Virtual Environment"
    
    check_cassandra
    setup_venv
    create_schemas
    generate_data
    load_data
    
    print_header "Complete!"
    print_success "All data has been loaded into Cassandra"
    echo
    print_info "Verify with:"
    echo "  podman exec -it cassandra-workshop cqlsh"
    echo "  USE ecommerce; SELECT COUNT(*) FROM customers;"
    echo
}

# Run main
main

# Made with Bob
