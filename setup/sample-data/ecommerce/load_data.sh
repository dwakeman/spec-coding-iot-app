#!/bin/bash
# ============================================================================
# E-commerce Data Loading Script
# Purpose: Load generated sample data into Cassandra and Iceberg tables
# ============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/generated_data"
CASSANDRA_HOST="${CASSANDRA_HOST:-localhost}"
CASSANDRA_PORT="${CASSANDRA_PORT:-9042}"
PRESTO_HOST="${PRESTO_HOST:-localhost}"
PRESTO_PORT="${PRESTO_PORT:-8080}"
PRESTO_CATALOG="${PRESTO_CATALOG:-iceberg_data}"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "${BLUE}============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================================${NC}"
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

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 is not installed or not in PATH"
        return 1
    fi
    return 0
}

check_cassandra_connection() {
    print_info "Checking Cassandra connection..."
    if cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "DESCRIBE KEYSPACES" &> /dev/null; then
        print_success "Cassandra is accessible"
        return 0
    else
        print_error "Cannot connect to Cassandra at ${CASSANDRA_HOST}:${CASSANDRA_PORT}"
        return 1
    fi
}

check_presto_connection() {
    print_info "Checking Presto connection..."
    if curl -s "http://${PRESTO_HOST}:${PRESTO_PORT}/v1/info" &> /dev/null; then
        print_success "Presto is accessible"
        return 0
    else
        print_error "Cannot connect to Presto at ${PRESTO_HOST}:${PRESTO_PORT}"
        return 1
    fi
}

# ============================================================================
# Data Generation
# ============================================================================

generate_data() {
    print_header "STEP 1: Generate Sample Data"
    
    if [ -d "${DATA_DIR}" ] && [ "$(ls -A ${DATA_DIR})" ]; then
        print_warning "Data directory already exists with files"
        read -p "Do you want to regenerate data? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping data generation"
            return 0
        fi
        rm -rf "${DATA_DIR}"
    fi
    
    print_info "Generating sample data..."
    cd "${SCRIPT_DIR}"
    python3 generate_data.py
    
    if [ $? -eq 0 ]; then
        print_success "Data generation complete"
        return 0
    else
        print_error "Data generation failed"
        return 1
    fi
}

# ============================================================================
# Cassandra Loading
# ============================================================================

load_cassandra_schema() {
    print_header "STEP 2: Create Cassandra Schema"
    
    print_info "Creating keyspace and tables..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -f "${SCRIPT_DIR}/cassandra_schema.cql"
    
    if [ $? -eq 0 ]; then
        print_success "Cassandra schema created"
        return 0
    else
        print_error "Failed to create Cassandra schema"
        return 1
    fi
}

load_cassandra_data() {
    print_header "STEP 3: Load Data into Cassandra"
    
    # Load customers
    print_info "Loading customers..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY ecommerce.customers (
            customer_id, email, first_name, last_name, phone, created_at, 
            last_login, account_status, loyalty_tier, total_orders, 
            lifetime_value, preferred_payment_method, shipping_address_street,
            shipping_address_city, shipping_address_state, shipping_address_zip,
            shipping_address_country, marketing_opt_in, updated_at
        ) FROM '${DATA_DIR}/customers.csv' WITH HEADER=TRUE;
    "
    print_success "Customers loaded"
    
    # Load products
    print_info "Loading products..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY ecommerce.products (
            product_id, sku, name, description, category, subcategory, brand,
            price, cost, currency, stock_quantity, reorder_level, weight_kg,
            dimensions_cm, is_active, created_at, updated_at, image_url,
            rating_avg, rating_count
        ) FROM '${DATA_DIR}/products.csv' WITH HEADER=TRUE;
    "
    print_success "Products loaded"
    
    # Load orders
    print_info "Loading orders..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY ecommerce.orders (
            customer_id, order_date, order_id, order_timestamp, order_status,
            payment_method, payment_status, subtotal, tax_amount, shipping_cost,
            discount_amount, total_amount, currency, shipping_address_street,
            shipping_address_city, shipping_address_state, shipping_address_zip,
            shipping_address_country, tracking_number, estimated_delivery_date,
            actual_delivery_date, notes, created_at, updated_at
        ) FROM '${DATA_DIR}/orders.csv' WITH HEADER=TRUE;
    "
    print_success "Orders loaded"
    
    # Load order items
    print_info "Loading order items..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY ecommerce.order_items (
            order_id, item_sequence, product_id, product_name, product_sku,
            quantity, unit_price, discount_amount, tax_amount, line_total, currency
        ) FROM '${DATA_DIR}/order_items.csv' WITH HEADER=TRUE;
    "
    print_success "Order items loaded"
    
    print_success "All Cassandra data loaded successfully"
}

# ============================================================================
# Iceberg Loading
# ============================================================================

load_iceberg_schema() {
    print_header "STEP 4: Create Iceberg Schema"
    
    print_info "Creating Iceberg tables via Presto..."
    
    # Note: This requires presto-cli to be installed
    if ! check_command "presto-cli"; then
        print_warning "presto-cli not found. Please create Iceberg tables manually using:"
        print_info "  ${SCRIPT_DIR}/iceberg_schema.sql"
        return 1
    fi
    
    presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
        --file "${SCRIPT_DIR}/iceberg_schema.sql"
    
    if [ $? -eq 0 ]; then
        print_success "Iceberg schema created"
        return 0
    else
        print_error "Failed to create Iceberg schema"
        return 1
    fi
}

load_iceberg_data() {
    print_header "STEP 5: Load Data into Iceberg Tables"
    
    print_info "Loading data from Cassandra to Iceberg via Presto..."
    
    # Create a temporary SQL file for data loading
    cat > "${SCRIPT_DIR}/load_iceberg_data.sql" << 'EOF'
-- Load sales_fact from Cassandra orders and order_items
INSERT INTO iceberg_data.ecommerce.sales_fact
SELECT 
    CAST(uuid() AS VARCHAR) as sale_id,
    CAST(o.order_id AS VARCHAR) as order_id,
    o.order_date,
    o.order_timestamp,
    YEAR(o.order_date) as order_year,
    MONTH(o.order_date) as order_month,
    DAY(o.order_date) as order_day,
    DAY_OF_WEEK(o.order_date) as order_day_of_week,
    QUARTER(o.order_date) as order_quarter,
    
    CAST(o.customer_id AS VARCHAR) as customer_id,
    c.email as customer_email,
    c.first_name || ' ' || c.last_name as customer_name,
    c.loyalty_tier as customer_loyalty_tier,
    CASE 
        WHEN c.lifetime_value > 5000 THEN 'high_value'
        WHEN c.lifetime_value > 1000 THEN 'regular'
        ELSE 'low_value'
    END as customer_segment,
    
    CAST(oi.product_id AS VARCHAR) as product_id,
    oi.product_sku,
    oi.product_name,
    p.category as product_category,
    p.subcategory as product_subcategory,
    p.brand as product_brand,
    
    oi.quantity,
    oi.unit_price,
    oi.discount_amount,
    oi.tax_amount,
    oi.line_total,
    
    o.subtotal as order_subtotal,
    o.tax_amount as order_tax,
    o.shipping_cost as order_shipping,
    o.discount_amount as order_discount,
    o.total_amount as order_total,
    
    o.order_status,
    o.payment_method,
    o.payment_status,
    o.shipping_address_country as shipping_country,
    o.shipping_address_state as shipping_state,
    o.shipping_address_city as shipping_city,
    
    (c.total_orders = 1) as is_first_purchase,
    (o.order_status = 'returned') as is_returned,
    (oi.discount_amount > 0) as is_discounted,
    
    o.created_at,
    o.updated_at
FROM cassandra_catalog.ecommerce.orders o
JOIN cassandra_catalog.ecommerce.order_items oi ON o.order_id = oi.order_id
JOIN cassandra_catalog.ecommerce.customers c ON o.customer_id = c.customer_id
JOIN cassandra_catalog.ecommerce.products p ON oi.product_id = p.product_id
WHERE o.order_status IN ('delivered', 'returned');

-- Load customer_dim
INSERT INTO iceberg_data.ecommerce.customer_dim
SELECT 
    ROW_NUMBER() OVER (ORDER BY customer_id) as customer_key,
    CAST(customer_id AS VARCHAR) as customer_id,
    email,
    first_name,
    last_name,
    first_name || ' ' || last_name as full_name,
    phone,
    NULL as age_group,
    NULL as gender,
    shipping_address_street,
    shipping_address_city,
    shipping_address_state,
    shipping_address_zip,
    shipping_address_country,
    total_orders,
    total_orders * 3 as total_items_purchased,
    lifetime_value,
    CASE WHEN total_orders > 0 THEN lifetime_value / total_orders ELSE 0 END as average_order_value,
    NULL as days_since_first_order,
    NULL as days_since_last_order,
    loyalty_tier,
    CASE 
        WHEN lifetime_value > 5000 THEN 'high_value'
        WHEN lifetime_value > 1000 THEN 'regular'
        WHEN total_orders = 0 THEN 'new'
        ELSE 'low_value'
    END as customer_segment,
    NULL as rfm_score,
    NULL as preferred_category,
    preferred_payment_method,
    marketing_opt_in,
    CAST(created_at AS DATE) as effective_date,
    DATE '9999-12-31' as end_date,
    true as is_current,
    created_at,
    updated_at
FROM cassandra_catalog.ecommerce.customers;

-- Load product_dim
INSERT INTO iceberg_data.ecommerce.product_dim
SELECT 
    ROW_NUMBER() OVER (ORDER BY product_id) as product_key,
    CAST(product_id AS VARCHAR) as product_id,
    sku,
    name,
    description,
    category,
    subcategory,
    brand,
    price as current_price,
    cost,
    CASE WHEN cost > 0 THEN ((price - cost) / price * 100) ELSE 0 END as margin_percent,
    weight_kg,
    dimensions_cm,
    0 as total_units_sold,
    0 as total_revenue,
    rating_avg as average_rating,
    rating_count as review_count,
    0 as return_rate,
    stock_quantity as current_stock,
    reorder_level,
    0 as days_out_of_stock,
    is_active,
    NULL as discontinuation_date,
    CAST(created_at AS DATE) as effective_date,
    DATE '9999-12-31' as end_date,
    true as is_current,
    created_at,
    updated_at
FROM cassandra_catalog.ecommerce.products;
EOF
    
    if check_command "presto-cli"; then
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --file "${SCRIPT_DIR}/load_iceberg_data.sql"
        
        if [ $? -eq 0 ]; then
            print_success "Iceberg data loaded"
            rm "${SCRIPT_DIR}/load_iceberg_data.sql"
            return 0
        else
            print_error "Failed to load Iceberg data"
            return 1
        fi
    else
        print_warning "presto-cli not found. Please load data manually using:"
        print_info "  ${SCRIPT_DIR}/load_iceberg_data.sql"
        return 1
    fi
}

# ============================================================================
# Verification
# ============================================================================

verify_data() {
    print_header "STEP 6: Verify Data Loading"
    
    print_info "Verifying Cassandra data..."
    
    # Count customers
    CUSTOMER_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM ecommerce.customers;" | grep -oP '\d+' | head -1)
    print_info "Customers: ${CUSTOMER_COUNT}"
    
    # Count products
    PRODUCT_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM ecommerce.products;" | grep -oP '\d+' | head -1)
    print_info "Products: ${PRODUCT_COUNT}"
    
    # Count orders
    ORDER_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM ecommerce.orders;" | grep -oP '\d+' | head -1)
    print_info "Orders: ${ORDER_COUNT}"
    
    print_success "Data verification complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "E-COMMERCE DATA LOADING"
    
    # Check prerequisites
    print_info "Checking prerequisites..."
    check_command "python3" || exit 1
    check_command "cqlsh" || exit 1
    
    # Check connections
    check_cassandra_connection || exit 1
    check_presto_connection || print_warning "Presto not accessible - Iceberg loading will be skipped"
    
    # Execute loading steps
    generate_data || exit 1
    load_cassandra_schema || exit 1
    load_cassandra_data || exit 1
    
    # Iceberg loading (optional if Presto not available)
    if check_presto_connection; then
        load_iceberg_schema
        load_iceberg_data
    fi
    
    verify_data
    
    print_header "DATA LOADING COMPLETE"
    print_success "E-commerce sample data has been loaded successfully!"
    print_info ""
    print_info "Next steps:"
    print_info "  1. Explore the data using federation_queries.sql"
    print_info "  2. Try the workshop exercises"
    print_info "  3. Build your own analytics application"
}

# Run main function
main "$@"

# Made with Bob
