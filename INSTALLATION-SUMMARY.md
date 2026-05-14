# Workshop Environment Installation Summary

**Installation Date:** 2026-05-14  
**Total Installation Time:** 11 minutes 2 seconds  
**Status:** ✅ Complete and Operational

---

## 🎯 What's Installed

### 1. WatsonX Data Developer Edition

**Access Information:**
- **Web UI:** https://localhost:9443
- **Username:** `ibmlhadmin`
- **Password:** `password`

**Container Status:** All 11 containers running
- ibm-lh-minio
- ibm-lh-postgres
- lhconsole-api
- lhconsole-ams
- ibm-lh-mds-rest
- ibm-lh-mds-thrift
- ibm-lh-presto
- ibm-lh-validator
- lhconsole-nodeclient-svc
- lhingestion-api
- lhconsole-ui

**Installation Location:**
```
/Users/dwakeman/git/spec-coding-iot-app/.watsonx-data
```

---

### 2. Apache Cassandra 5.0

**Connection Details:**
- **Host:** `localhost` (or `host.containers.internal` from containers)
- **Port:** `9042`
- **Cluster Name:** `WatsonX_Workshop_Cluster`
- **Datacenter:** `datacenter1`
- **Username:** `cassandra`
- **Password:** `cassandra`

**Container Name:** `cassandra-workshop`

---

### 3. Cassandra Catalog Registration

**Catalog Configuration:**
- **Display Name:** `cassandra_workshop`
- **Catalog Name:** `cassandra_catalog`
- **Database Type:** Apache Cassandra
- **Status:** ✅ Registered in WatsonX Data UI

---

## 📊 Data Loaded

### Cassandra Keyspaces (Hot/Operational Data)

#### **ecommerce** keyspace - 5,550 rows
| Table | Rows |
|-------|------|
| active_carts | 630 |
| customers | 1,000 |
| inventory_ledger_recent | 1,106 |
| live_sessions | 800 |
| order_items_inflight | 1,014 |
| orders_inflight | 400 |
| products | 200 |
| reviews_recent | 400 |

#### **iot** keyspace - 5,215 rows
| Table | Rows |
|-------|------|
| alerts_open | 45 |
| device_events_recent | 800 |
| device_state_current | 300 |
| readings_hot | 3,770 |
| topology_current | 300 |

#### **financial** keyspace - 7,536 rows
| Table | Rows |
|-------|------|
| accounts | 1,184 |
| card_status_current | 687 |
| card_transactions_recent | 4,600 |
| customers | 800 |
| fraud_alerts_open | 35 |
| transactions_authorizing | 150 |
| transfers_pending | 80 |

**Total Cassandra Rows:** 18,301

---

### Iceberg Tables (Historical/Analytical Data)

#### **iceberg_data.ecommerce** - 8 tables
- cohort_retention
- competitor_prices_weekly
- customer_ltv_monthly
- daily_sales_summary
- marketing_attribution
- order_items_archive
- orders_archive
- product_performance_weekly

**Approximate Rows:** 46,000+

#### **iceberg_data.iot** - 7 tables
- daily_site_summary
- failure_history
- firmware_deployment_history
- hourly_aggregates
- maintenance_windows
- readings_archive
- weather_by_location

**Approximate Rows:** 53,000+

#### **iceberg_data.financial** - 7 tables
- account_statements_monthly
- fraud_training_labels
- market_data_daily
- portfolio_metrics_daily
- regulatory_filings
- risk_assessment_history
- transactions_archive

**Approximate Rows:** 28,000+

**Total Iceberg Rows:** 127,000+

---

## 🔧 Useful Commands

### WatsonX Data Management

```bash
# Check status of all services
./.watsonx-data/ibm-lh-dev/bin/status --all

# Stop WatsonX Data
./.watsonx-data/ibm-lh-dev/bin/stop

# Start WatsonX Data
./.watsonx-data/ibm-lh-dev/bin/start

# View installation details
./setup/show-active-installation.sh
```

### Cassandra Management

```bash
# Check Cassandra status
podman ps | grep cassandra

# Access CQL shell
podman exec -it cassandra-workshop cqlsh

# View Cassandra logs
podman logs cassandra-workshop

# Check node status
podman exec cassandra-workshop nodetool status

# Stop Cassandra
podman stop cassandra-workshop

# Start Cassandra
podman start cassandra-workshop
```

### Data Exploration

```bash
# Connect to Cassandra and explore
podman exec -it cassandra-workshop cqlsh
DESCRIBE KEYSPACES;
USE ecommerce;
DESCRIBE TABLES;
SELECT * FROM customers LIMIT 5;
```

### Complete Cleanup (if needed)

```bash
# Remove everything and start fresh
./setup/cleanup-all.sh --yes --remove-dirs
```

---

## 🔍 Query Examples

### Query Cassandra (Hot Data)

```sql
-- From WatsonX Data Query Workspace
SELECT * FROM cassandra_catalog.iot.device_state_current LIMIT 10;
SELECT * FROM cassandra_catalog.ecommerce.customers LIMIT 10;
SELECT * FROM cassandra_catalog.financial.accounts LIMIT 10;
```

### Query Iceberg (Historical Data)

```sql
-- From WatsonX Data Query Workspace
SELECT * FROM iceberg_data.iot.readings_archive LIMIT 10;
SELECT * FROM iceberg_data.ecommerce.orders_archive LIMIT 10;
SELECT * FROM iceberg_data.financial.transactions_archive LIMIT 10;
```

### Federated Queries (Join Cassandra + Iceberg)

```sql
-- Join hot device state with historical readings
SELECT 
    c.device_id,
    c.status,
    c.last_seen,
    COUNT(i.reading_id) as historical_reading_count
FROM cassandra_catalog.iot.device_state_current c
LEFT JOIN iceberg_data.iot.readings_archive i 
    ON c.device_id = i.device_id
GROUP BY c.device_id, c.status, c.last_seen
LIMIT 20;
```

---

## 📝 Environment Configuration

### .env File Location
```
/Users/dwakeman/git/spec-coding-iot-app/.env
```

### Key Environment Variables

```bash
# IBM Entitlement Key (configured)
IBM_ENTITLEMENT_KEY=<configured>

# Backend Service
PORT=3000
SERVICE_NAME=sensor-health-dashboard-backend
LOG_LEVEL=info

# Cassandra Connection
CASSANDRA_CONTACT_POINTS=127.0.0.1
CASSANDRA_PORT=9042
CASSANDRA_DATACENTER=datacenter1
CASSANDRA_KEYSPACE=iot
CASSANDRA_USERNAME=cassandra
CASSANDRA_PASSWORD=cassandra

# Presto / WatsonX Data Connection
PRESTO_BASE_URL=https://localhost:8443
PRESTO_CATALOG=iceberg_data
PRESTO_SCHEMA=iot
PRESTO_USER=ibmlhadmin
PRESTO_USERNAME=ibmlhadmin
PRESTO_PASSWORD=password
PRESTO_TLS_REJECT_UNAUTHORIZED=false
```

---

## 🚀 Next Steps

1. **Access the WatsonX Data UI**
   - Open https://localhost:9443
   - Login with ibmlhadmin / password
   - Explore Query Workspace

2. **Verify Data**
   - Run sample queries in Query Workspace
   - Check both Cassandra and Iceberg catalogs
   - Test federated queries

3. **Start Building**
   - Wait for instructor's prompts
   - Begin AI-driven coding exercises
   - Build the analytics application

4. **Reference Documentation**
   - `SCHEMAS.md` - Complete schema reference
   - `docs/getting-unstuck.md` - Troubleshooting guide
   - `AGENTS.md` - Workshop context for AI agents

---

## ⚠️ Important Notes

- **Platform:** Running on macOS with Apple Silicon (ARM64)
- **Emulation:** WatsonX Data images run under amd64 emulation (expected warnings)
- **Performance:** Queries may be slower on Apple Silicon due to emulation
- **Ports:** 9443 (WatsonX UI), 8443 (Presto), 9042 (Cassandra)
- **Network:** Containers use `host.containers.internal` to reach host services

---

## 📚 Additional Resources

- **Workshop Repository:** `/Users/dwakeman/git/spec-coding-iot-app`
- **Sample Data Scripts:** `./setup/sample-data/`
- **Cassandra Setup:** `./setup/cassandra/`
- **Documentation:** `./docs/`

---

**Installation completed successfully on 2026-05-14 at 11:03 AM CDT**

*This environment is ready for the WatsonX Data + Cassandra workshop!* 🎉