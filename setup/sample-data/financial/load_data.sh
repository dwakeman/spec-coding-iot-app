#!/bin/bash
# ============================================================================
# Financial Analytics Data Loading Script
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
    
    print_info "Generating financial data..."
    print_warning "This may take 10-15 minutes for 5M transactions..."
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
        COPY financial.customers (
            customer_id, customer_type, first_name, last_name, business_name,
            email, phone, date_of_birth, tax_id, street_address, city, state,
            zip_code, country, kyc_status, kyc_verified_date, risk_rating,
            total_accounts, total_balance, credit_score, status, created_at,
            updated_at, last_login, pep_status, sanctions_check_date, aml_risk_score
        ) FROM '${DATA_DIR}/customers.csv' WITH HEADER=TRUE;
    "
    print_success "Customers loaded"
    
    # Load accounts
    print_info "Loading accounts..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY financial.accounts (
            account_id, customer_id, account_number, account_type, account_subtype,
            currency, current_balance, available_balance, pending_balance,
            credit_limit, interest_rate, annual_fee, overdraft_limit, status,
            opened_date, closed_date, last_transaction_date, branch_id,
            account_officer, created_at, updated_at
        ) FROM '${DATA_DIR}/accounts.csv' WITH HEADER=TRUE;
    "
    print_success "Accounts loaded"
    
    # Load transactions (may be split into multiple files)
    print_info "Loading transactions..."
    print_warning "This may take 15-20 minutes for large datasets..."
    
    for trans_file in ${DATA_DIR}/transactions*.csv; do
        if [ -f "$trans_file" ]; then
            filename=$(basename "$trans_file")
            print_info "  Loading $filename..."
            
            cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
                COPY financial.transactions (
                    account_id, transaction_date, transaction_id, transaction_timestamp,
                    transaction_type, transaction_category, amount, currency,
                    balance_before, balance_after, from_account_id, to_account_id,
                    merchant_name, merchant_category, location_city, location_state,
                    location_country, latitude, longitude, channel, device_id,
                    ip_address, status, authorization_code, fraud_score, is_flagged,
                    description, reference_number, created_at
                ) FROM '$trans_file' WITH HEADER=TRUE;
            "
        fi
    done
    print_success "Transactions loaded"
    
    # Load fraud alerts
    print_info "Loading fraud alerts..."
    if [ -f "${DATA_DIR}/fraud_alerts.csv" ]; then
        cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
            COPY financial.fraud_alerts (
                account_id, alert_date, alert_id, alert_timestamp, customer_id,
                transaction_id, alert_type, severity, fraud_score, reason,
                rule_triggered, transaction_amount, transaction_type, merchant_name,
                location, status, reviewed_by, reviewed_at, resolution,
                account_frozen, card_blocked, customer_notified, created_at, updated_at
            ) FROM '${DATA_DIR}/fraud_alerts.csv' WITH HEADER=TRUE;
        "
        print_success "Fraud alerts loaded"
    else
        print_warning "No fraud_alerts.csv file found, skipping"
    fi
    
    print_success "All Cassandra data loaded successfully"
}

# ============================================================================
# Iceberg Loading
# ============================================================================

load_iceberg_schema() {
    print_header "STEP 4: Create Iceberg Schema"
    
    print_info "Creating Iceberg tables via Presto..."
    
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
    print_warning "This process may take 20-30 minutes for large datasets..."
    
    # Create a temporary SQL file for data loading
    cat > "${SCRIPT_DIR}/load_iceberg_data.sql" << 'EOF'
-- Load transaction_fact from Cassandra transactions
INSERT INTO iceberg_data.financial.transaction_fact
SELECT 
    CAST(t.transaction_id AS VARCHAR) as transaction_id,
    CAST(t.account_id AS VARCHAR) as account_id,
    CAST(a.customer_id AS VARCHAR) as customer_id,
    
    t.transaction_timestamp,
    CAST(t.transaction_date AS DATE) as transaction_date,
    YEAR(t.transaction_date) as transaction_year,
    MONTH(t.transaction_date) as transaction_month,
    DAY(t.transaction_date) as transaction_day,
    HOUR(t.transaction_timestamp) as transaction_hour,
    DAY_OF_WEEK(t.transaction_date) as day_of_week,
    DAY_OF_MONTH(t.transaction_date) as day_of_month,
    WEEK_OF_YEAR(t.transaction_date) as week_of_year,
    QUARTER(t.transaction_date) as quarter,
    
    t.transaction_type,
    t.transaction_category,
    t.amount,
    t.currency,
    
    t.balance_before,
    t.balance_after,
    t.balance_after - t.balance_before as balance_change,
    
    a.account_type,
    a.account_subtype,
    
    c.customer_type,
    c.risk_rating as customer_risk_rating,
    CASE 
        WHEN c.total_balance > 100000 THEN 'high_value'
        WHEN c.total_balance > 10000 THEN 'medium_value'
        ELSE 'standard'
    END as customer_segment,
    
    t.from_account_id,
    t.to_account_id,
    t.merchant_name,
    t.merchant_category,
    NULL as merchant_category_code,
    
    t.location_city,
    t.location_state,
    t.location_country,
    t.latitude,
    t.longitude,
    
    t.channel,
    t.device_id,
    CASE 
        WHEN t.channel IN ('mobile', 'online') THEN 'digital'
        ELSE 'physical'
    END as device_type,
    
    t.status,
    t.status = 'completed' as is_completed,
    false as is_reversed,
    t.is_flagged,
    
    t.fraud_score,
    t.fraud_score > 0.7 as is_fraud,
    CASE 
        WHEN t.fraud_score > 0.8 THEN 'high_risk'
        WHEN t.fraud_score > 0.5 THEN 'medium_risk'
        ELSE 'low_risk'
    END as fraud_type,
    
    t.amount > 10000 as is_large_cash,
    false as is_structured,
    t.fraud_score > 0.8 as requires_sar,
    
    DAY_OF_WEEK(t.transaction_date) IN (6, 7) as is_weekend,
    HOUR(t.transaction_timestamp) BETWEEN 9 AND 17 as is_business_hours,
    t.location_country != 'USA' as is_cross_border,
    false as is_high_risk_merchant,
    
    t.created_at
FROM cassandra_catalog.financial.transactions t
JOIN cassandra_catalog.financial.accounts a ON t.account_id = a.account_id
JOIN cassandra_catalog.financial.customers c ON a.customer_id = c.customer_id
WHERE t.transaction_date < CURRENT_DATE;

-- Load account_dim
INSERT INTO iceberg_data.financial.account_dim
SELECT 
    ROW_NUMBER() OVER (ORDER BY account_id) as account_key,
    CAST(account_id AS VARCHAR) as account_id,
    CAST(customer_id AS VARCHAR) as customer_id,
    
    account_number,
    account_type,
    account_subtype,
    currency,
    
    current_balance,
    available_balance,
    credit_limit,
    
    0 as total_deposits,
    0 as total_withdrawals,
    0 as total_fees_paid,
    0 as total_interest_earned,
    0 as transaction_count,
    0 as avg_transaction_amount,
    
    CAST(DATE_DIFF('day', opened_date, CURRENT_DATE) AS INTEGER) as days_since_opened,
    CAST(DATE_DIFF('day', last_transaction_date, CURRENT_DATE) AS INTEGER) as days_since_last_transaction,
    current_balance as monthly_avg_balance,
    0.0 as balance_volatility,
    
    0 as overdraft_count,
    0 as nsf_count,
    0 as fraud_alert_count,
    0.1 as risk_score,
    
    0 as lifetime_fees,
    0 as lifetime_interest,
    0 as estimated_profitability,
    
    status,
    opened_date,
    closed_date,
    status = 'active' as is_active,
    
    CAST(created_at AS DATE) as effective_date,
    DATE '9999-12-31' as end_date,
    true as is_current,
    
    created_at,
    updated_at
FROM cassandra_catalog.financial.accounts;

-- Load customer_dim
INSERT INTO iceberg_data.financial.customer_dim
SELECT 
    ROW_NUMBER() OVER (ORDER BY customer_id) as customer_key,
    CAST(customer_id AS VARCHAR) as customer_id,
    
    customer_type,
    first_name,
    last_name,
    business_name,
    
    NULL as age_group,
    city,
    state,
    country,
    
    total_accounts,
    total_accounts as active_accounts,
    total_balance,
    credit_score,
    
    0 as total_transactions,
    0 as avg_transaction_amount,
    NULL as preferred_channel,
    NULL as preferred_transaction_type,
    
    CAST(DATE_DIFF('day', CAST(created_at AS DATE), CURRENT_DATE) AS INTEGER) as relationship_length_days,
    total_accounts as products_held,
    0.5 as cross_sell_score,
    
    risk_rating,
    aml_risk_score,
    0 as fraud_incidents,
    kyc_status,
    pep_status,
    
    kyc_verified_date,
    sanctions_check_date,
    risk_rating = 'high' as requires_enhanced_dd,
    
    total_balance as lifetime_value,
    total_balance * 0.02 as estimated_annual_revenue,
    CASE 
        WHEN total_balance > 100000 THEN 'high_value'
        WHEN total_balance > 10000 THEN 'medium_value'
        ELSE 'standard'
    END as customer_segment,
    
    status,
    CAST(created_at AS DATE) as customer_since,
    CAST(last_login AS DATE) as last_contact_date,
    
    CAST(created_at AS DATE) as effective_date,
    DATE '9999-12-31' as end_date,
    true as is_current,
    
    created_at,
    updated_at
FROM cassandra_catalog.financial.customers;
EOF
    
    if check_command "presto-cli"; then
        print_info "Loading transaction_fact (this will take a while)..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 200 'INSERT INTO iceberg_data.financial.transaction_fact' ${SCRIPT_DIR}/load_iceberg_data.sql | sed '/^$/q')"
        
        print_info "Loading account_dim..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 100 'INSERT INTO iceberg_data.financial.account_dim' ${SCRIPT_DIR}/load_iceberg_data.sql | sed '/^$/q')"
        
        print_info "Loading customer_dim..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 100 'INSERT INTO iceberg_data.financial.customer_dim' ${SCRIPT_DIR}/load_iceberg_data.sql)"
        
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
    CUSTOMER_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM financial.customers;" | grep -oP '\d+' | head -1)
    print_info "Customers: ${CUSTOMER_COUNT}"
    
    # Count accounts
    ACCOUNT_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM financial.accounts;" | grep -oP '\d+' | head -1)
    print_info "Accounts: ${ACCOUNT_COUNT}"
    
    # Count transactions
    TRANSACTION_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM financial.transactions;" | grep -oP '\d+' | head -1)
    print_info "Transactions: ${TRANSACTION_COUNT}"
    
    # Count fraud alerts
    ALERT_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM financial.fraud_alerts;" | grep -oP '\d+' | head -1)
    print_info "Fraud Alerts: ${ALERT_COUNT}"
    
    print_success "Data verification complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "FINANCIAL ANALYTICS DATA LOADING"
    
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
    print_success "Financial analytics sample data has been loaded successfully!"
    print_info ""
    print_info "Next steps:"
    print_info "  1. Explore the data using federation_queries.sql"
    print_info "  2. Try fraud detection queries"
    print_info "  3. Build your own financial analytics application"
    print_info ""
    print_info "Sample queries:"
    print_info "  - Customer accounts: SELECT * FROM financial.accounts_by_customer WHERE customer_id = ?;"
    print_info "  - Recent transactions: SELECT * FROM financial.transactions WHERE account_id = ? AND transaction_date >= CURRENT_DATE - 7;"
    print_info "  - Active fraud alerts: SELECT * FROM financial.active_fraud_alerts WHERE status = 'new';"
}

# Run main function
main "$@"

# Made with Bob
