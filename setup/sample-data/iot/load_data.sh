#!/bin/bash
# ============================================================================
# IoT Sensor Analytics Data Loading Script
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
    
    print_info "Generating IoT sensor data..."
    print_info "This may take several minutes for large datasets..."
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
    
    # Load devices
    print_info "Loading devices..."
    cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
        COPY iot.devices (
            device_id, device_name, device_type, manufacturer, model, 
            firmware_version, location_name, location_building, location_floor,
            location_room, latitude, longitude, status, last_seen,
            last_reading_timestamp, sampling_interval_seconds, 
            reporting_interval_seconds, alert_threshold_min, alert_threshold_max,
            installation_date, last_maintenance_date, next_maintenance_date,
            warranty_expiry_date, total_readings, uptime_percentage,
            battery_level, signal_strength, created_at, updated_at
        ) FROM '${DATA_DIR}/devices.csv' WITH HEADER=TRUE;
    "
    print_success "Devices loaded"
    
    # Load sensor readings (may be split into multiple files)
    print_info "Loading sensor readings..."
    for readings_file in ${DATA_DIR}/sensor_readings*.csv; do
        if [ -f "$readings_file" ]; then
            filename=$(basename "$readings_file")
            print_info "  Loading $filename..."
            
            cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
                COPY iot.sensor_readings (
                    device_id, reading_date, reading_timestamp, reading_id,
                    temperature, humidity, pressure, motion_detected, energy_kwh,
                    co2_ppm, pm25_ugm3, voc_ppb, water_flow_lpm, vibration_hz,
                    light_lux, gps_latitude, gps_longitude, gps_altitude, gps_speed,
                    signal_strength, battery_level, data_quality, sequence_number
                ) FROM '$readings_file' WITH HEADER=TRUE;
            "
        fi
    done
    print_success "Sensor readings loaded"
    
    # Load alerts
    print_info "Loading alerts..."
    if [ -f "${DATA_DIR}/alerts.csv" ]; then
        cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "
            COPY iot.alerts (
                device_id, alert_date, alert_id, alert_timestamp, alert_type,
                severity, status, metric_name, metric_value, threshold_value,
                title, description, acknowledged_by, acknowledged_at,
                resolved_by, resolved_at, resolution_notes, notification_sent,
                notification_channels, created_at, updated_at
            ) FROM '${DATA_DIR}/alerts.csv' WITH HEADER=TRUE;
        "
        print_success "Alerts loaded"
    else
        print_warning "No alerts.csv file found, skipping"
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
    print_info "This process may take several minutes..."
    
    # Create a temporary SQL file for data loading
    cat > "${SCRIPT_DIR}/load_iceberg_data.sql" << 'EOF'
-- Load metrics_fact from Cassandra sensor_readings
INSERT INTO iceberg_data.iot.metrics_fact
SELECT 
    CAST(sr.reading_id AS VARCHAR) as reading_id,
    CAST(sr.device_id AS VARCHAR) as device_id,
    
    sr.reading_timestamp,
    CAST(sr.reading_date AS DATE) as reading_date,
    YEAR(sr.reading_date) as reading_year,
    MONTH(sr.reading_date) as reading_month,
    DAY(sr.reading_date) as reading_day,
    HOUR(sr.reading_timestamp) as reading_hour,
    MINUTE(sr.reading_timestamp) as reading_minute,
    DAY_OF_WEEK(sr.reading_date) as day_of_week,
    
    d.device_name,
    d.device_type,
    d.manufacturer,
    d.model,
    
    d.location_name,
    d.location_building,
    d.location_floor,
    d.location_room,
    d.latitude,
    d.longitude,
    
    sr.temperature,
    sr.humidity,
    sr.pressure,
    sr.motion_detected,
    sr.energy_kwh,
    sr.co2_ppm,
    sr.pm25_ugm3,
    sr.voc_ppb,
    sr.water_flow_lpm,
    sr.vibration_hz,
    sr.light_lux,
    
    sr.gps_latitude,
    sr.gps_longitude,
    sr.gps_altitude,
    sr.gps_speed,
    
    sr.signal_strength,
    sr.battery_level,
    sr.data_quality,
    
    sr.temperature as temperature_celsius,
    CASE WHEN sr.temperature IS NOT NULL 
         THEN sr.temperature * 9.0 / 5.0 + 32 
         ELSE NULL END as temperature_fahrenheit,
    false as is_anomaly,
    0.0 as anomaly_score,
    
    sr.sequence_number,
    sr.reading_timestamp as created_at
FROM cassandra_catalog.iot.sensor_readings sr
JOIN cassandra_catalog.iot.devices d ON sr.device_id = d.device_id
WHERE sr.reading_date < CURRENT_DATE;  -- Only load historical data

-- Load device_dim
INSERT INTO iceberg_data.iot.device_dim
SELECT 
    ROW_NUMBER() OVER (ORDER BY device_id) as device_key,
    CAST(device_id AS VARCHAR) as device_id,
    
    device_name,
    device_type,
    manufacturer,
    model,
    firmware_version,
    
    location_name,
    location_building,
    location_floor,
    location_room,
    latitude,
    longitude,
    
    installation_date,
    warranty_expiry_date,
    
    total_readings,
    uptime_percentage as avg_uptime_percentage,
    0 as total_downtime_hours,
    battery_level as avg_battery_level,
    signal_strength as avg_signal_strength,
    
    0 as error_count,
    0 as warning_count,
    0 as alert_count,
    0 as maintenance_count,
    
    85.0 as data_quality_score,
    0.02 as anomaly_rate,
    
    status as current_status,
    last_seen,
    CAST(DATE_DIFF('day', last_maintenance_date, CURRENT_DATE) AS INTEGER) as days_since_last_maintenance,
    
    CAST(created_at AS DATE) as effective_date,
    DATE '9999-12-31' as end_date,
    true as is_current,
    
    created_at,
    updated_at
FROM cassandra_catalog.iot.devices;

-- Load hourly_aggregates (sample - would normally be computed from metrics_fact)
INSERT INTO iceberg_data.iot.hourly_aggregates
SELECT 
    CAST(d.device_id AS VARCHAR) as device_id,
    DATE_TRUNC('hour', sr.reading_timestamp) as aggregate_timestamp,
    YEAR(sr.reading_date) as aggregate_year,
    MONTH(sr.reading_date) as aggregate_month,
    DAY(sr.reading_date) as aggregate_day,
    HOUR(sr.reading_timestamp) as aggregate_hour,
    
    d.device_type,
    d.location_building,
    d.location_floor,
    
    COUNT(*) as reading_count,
    4 as expected_reading_count,  -- 4 readings per hour at 15-min intervals
    GREATEST(0, 4 - COUNT(*)) as missing_reading_count,
    
    AVG(sr.temperature) as avg_temperature,
    MIN(sr.temperature) as min_temperature,
    MAX(sr.temperature) as max_temperature,
    STDDEV(sr.temperature) as stddev_temperature,
    
    AVG(sr.humidity) as avg_humidity,
    MIN(sr.humidity) as min_humidity,
    MAX(sr.humidity) as max_humidity,
    
    AVG(sr.pressure) as avg_pressure,
    MIN(sr.pressure) as min_pressure,
    MAX(sr.pressure) as max_pressure,
    
    SUM(sr.energy_kwh) as total_energy_kwh,
    AVG(sr.energy_kwh) as avg_power_kw,
    MAX(sr.energy_kwh) as peak_power_kw,
    
    AVG(sr.co2_ppm) as avg_co2_ppm,
    MAX(sr.co2_ppm) as max_co2_ppm,
    AVG(sr.pm25_ugm3) as avg_pm25_ugm3,
    MAX(sr.pm25_ugm3) as max_pm25_ugm3,
    AVG(sr.voc_ppb) as avg_voc_ppb,
    
    SUM(CASE WHEN sr.motion_detected THEN 1 ELSE 0 END) as motion_events,
    SUM(CASE WHEN sr.motion_detected THEN 15 ELSE 0 END) as motion_duration_minutes,
    
    SUM(sr.water_flow_lpm * 15) as total_water_flow_liters,
    AVG(sr.water_flow_lpm) as avg_flow_rate_lpm,
    
    AVG(sr.signal_strength) as avg_signal_strength,
    MIN(sr.signal_strength) as min_signal_strength,
    AVG(sr.battery_level) as avg_battery_level,
    MIN(sr.battery_level) as min_battery_level,
    
    0 as anomaly_count,
    0.0 as anomaly_rate,
    
    MAX(sr.reading_timestamp) as created_at
FROM cassandra_catalog.iot.sensor_readings sr
JOIN cassandra_catalog.iot.devices d ON sr.device_id = d.device_id
WHERE sr.reading_date < CURRENT_DATE
GROUP BY 
    d.device_id, DATE_TRUNC('hour', sr.reading_timestamp),
    YEAR(sr.reading_date), MONTH(sr.reading_date), DAY(sr.reading_date),
    HOUR(sr.reading_timestamp), d.device_type, d.location_building, d.location_floor;
EOF
    
    if check_command "presto-cli"; then
        print_info "Loading metrics_fact..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 100 'INSERT INTO iceberg_data.iot.metrics_fact' ${SCRIPT_DIR}/load_iceberg_data.sql | sed '/^$/q')"
        
        print_info "Loading device_dim..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 100 'INSERT INTO iceberg_data.iot.device_dim' ${SCRIPT_DIR}/load_iceberg_data.sql | sed '/^$/q')"
        
        print_info "Loading hourly_aggregates..."
        presto-cli --server ${PRESTO_HOST}:${PRESTO_PORT} --catalog ${PRESTO_CATALOG} \
            --execute "$(grep -A 100 'INSERT INTO iceberg_data.iot.hourly_aggregates' ${SCRIPT_DIR}/load_iceberg_data.sql)"
        
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
    
    # Count devices
    DEVICE_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM iot.devices;" | grep -oP '\d+' | head -1)
    print_info "Devices: ${DEVICE_COUNT}"
    
    # Count readings
    READING_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM iot.sensor_readings;" | grep -oP '\d+' | head -1)
    print_info "Sensor Readings: ${READING_COUNT}"
    
    # Count alerts
    ALERT_COUNT=$(cqlsh ${CASSANDRA_HOST} ${CASSANDRA_PORT} -e "SELECT COUNT(*) FROM iot.alerts;" | grep -oP '\d+' | head -1)
    print_info "Alerts: ${ALERT_COUNT}"
    
    print_success "Data verification complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "IOT SENSOR ANALYTICS DATA LOADING"
    
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
    print_success "IoT sensor analytics sample data has been loaded successfully!"
    print_info ""
    print_info "Next steps:"
    print_info "  1. Explore the data using federation_queries.sql"
    print_info "  2. Try the workshop exercises"
    print_info "  3. Build your own IoT analytics application"
    print_info ""
    print_info "Sample queries:"
    print_info "  - Real-time device status: SELECT * FROM iot.devices WHERE status = 'online';"
    print_info "  - Recent readings: SELECT * FROM iot.sensor_readings WHERE reading_date = CURRENT_DATE LIMIT 10;"
    print_info "  - Active alerts: SELECT * FROM iot.alerts WHERE alert_date >= CURRENT_DATE - 1;"
}

# Run main function
main "$@"

# Made with Bob
