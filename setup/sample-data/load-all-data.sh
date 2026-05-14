#!/bin/bash
# ============================================================================
# Unified Data Loading Script for Containerized Cassandra
# Purpose: Load all sample data into Cassandra running in Podman container
# ============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CASSANDRA_CONTAINER="${CASSANDRA_CONTAINER:-cassandra-workshop}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Helper Functions
# ============================================================================

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

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Execute cqlsh command inside container
cqlsh_exec() {
    podman exec "$CASSANDRA_CONTAINER" cqlsh -e "$1"
}

# Execute cqlsh with file inside container
cqlsh_file() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    
    # Copy file into container
    podman cp "$file_path" "$CASSANDRA_CONTAINER:/tmp/$file_name"
    
    # Execute it
    podman exec "$CASSANDRA_CONTAINER" cqlsh -f "/tmp/$file_name"
    
    # Clean up
    podman exec "$CASSANDRA_CONTAINER" rm "/tmp/$file_name"
}

# ============================================================================
# Check Prerequisites
# ============================================================================

check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check if Cassandra container is running
    if ! podman ps --format "{{.Names}}" | grep -q "^${CASSANDRA_CONTAINER}$"; then
        print_error "Cassandra container '${CASSANDRA_CONTAINER}' is not running"
        print_info "Start it with: podman start ${CASSANDRA_CONTAINER}"
        exit 1
    fi
    
    # Check if Python is available
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Check if Cassandra is ready
    if ! cqlsh_exec "DESCRIBE KEYSPACES" &> /dev/null; then
        print_error "Cassandra is not ready yet"
        print_info "Wait a few seconds and try again"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# ============================================================================
# Load Dataset
# ============================================================================

load_dataset() {
    local dataset_name="$1"
    local dataset_dir="${SCRIPT_DIR}/${dataset_name}"
    
    print_header "Loading ${dataset_name} Data"
    
    # Step 1: Generate data
    print_info "Generating sample data..."
    cd "$dataset_dir"
    python3 generate_data.py
    if [ $? -ne 0 ]; then
        print_error "Data generation failed"
        return 1
    fi
    print_success "Data generated"
    
    # Step 2: Create schema
    print_info "Creating Cassandra schema..."
    cqlsh_file "${dataset_dir}/cassandra_schema.cql"
    if [ $? -ne 0 ]; then
        print_error "Schema creation failed"
        return 1
    fi
    print_success "Schema created"
    
    # Step 3: Load data using Python script inside container
    print_info "Loading data into Cassandra..."
    
    # Copy Python script and data into container
    podman cp "${dataset_dir}/generate_data.py" "$CASSANDRA_CONTAINER:/tmp/"
    podman cp "${dataset_dir}/generated_data" "$CASSANDRA_CONTAINER:/tmp/"
    
    # Install cassandra-driver in container if needed
    podman exec "$CASSANDRA_CONTAINER" bash -c "pip3 install --quiet cassandra-driver 2>/dev/null || true"
    
    # Create a simple loader script
    cat > "/tmp/load_${dataset_name}.py" << 'PYEOF'
from cassandra.cluster import Cluster
import csv
import os
import sys
from uuid import UUID

# Connect to Cassandra
cluster = Cluster(['127.0.0.1'])
session = cluster.connect()

# Get dataset name from args
dataset = sys.argv[1] if len(sys.argv) > 1 else 'ecommerce'
data_dir = '/tmp/generated_data'

# Use the appropriate keyspace
if dataset == 'ecommerce':
    session.set_keyspace('ecommerce')
elif dataset == 'iot':
    session.set_keyspace('iot')
elif dataset == 'financial':
    session.set_keyspace('financial')

print(f"Loading {dataset} data from {data_dir}")

# Load CSV files
for csv_file in os.listdir(data_dir):
    if not csv_file.endswith('.csv'):
        continue
    
    table_name = csv_file.replace('.csv', '')
    file_path = os.path.join(data_dir, csv_file)
    
    print(f"Loading {table_name}...")
    
    with open(file_path, 'r') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        
        if not rows:
            print(f"  No data in {csv_file}")
            continue
        
        # Build INSERT statement
        columns = list(rows[0].keys())
        placeholders = ', '.join(['?' for _ in columns])
        insert_stmt = f"INSERT INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders})"
        prepared = session.prepare(insert_stmt)
        
        # Insert rows
        count = 0
        for row in rows:
            values = []
            for col in columns:
                val = row[col]
                # Handle empty strings
                if val == '':
                    values.append(None)
                # Handle booleans
                elif val.lower() in ('true', 'false'):
                    values.append(val.lower() == 'true')
                # Handle numbers
                elif val.replace('.', '').replace('-', '').isdigit():
                    if '.' in val:
                        values.append(float(val))
                    else:
                        values.append(int(val))
                else:
                    values.append(val)
            
            try:
                session.execute(prepared, values)
                count += 1
            except Exception as e:
                print(f"  Error inserting row: {e}")
                continue
        
        print(f"  Loaded {count} rows into {table_name}")

cluster.shutdown()
print(f"{dataset} data loading complete!")
PYEOF
    
    # Copy loader script into container
    podman cp "/tmp/load_${dataset_name}.py" "$CASSANDRA_CONTAINER:/tmp/loader.py"
    
    # Run the loader
    podman exec "$CASSANDRA_CONTAINER" python3 /tmp/loader.py "$dataset_name"
    
    if [ $? -ne 0 ]; then
        print_error "Data loading failed"
        return 1
    fi
    
    # Clean up
    podman exec "$CASSANDRA_CONTAINER" rm -rf /tmp/generated_data /tmp/generate_data.py /tmp/loader.py
    rm "/tmp/load_${dataset_name}.py"
    
    print_success "${dataset_name} data loaded successfully"
    cd "$SCRIPT_DIR"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "Loading All Sample Data"
    
    check_prerequisites
    
    # Load each dataset
    load_dataset "ecommerce"
    load_dataset "iot"
    load_dataset "financial"
    
    print_header "Data Loading Complete!"
    print_success "All sample data has been loaded into Cassandra"
    echo
    print_info "Verify with:"
    echo "  podman exec -it ${CASSANDRA_CONTAINER} cqlsh"
    echo "  USE ecommerce; DESCRIBE TABLES; SELECT COUNT(*) FROM customers;"
    echo
}

# Run main function
main

# Made with Bob
