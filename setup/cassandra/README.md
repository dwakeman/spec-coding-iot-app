# Apache Cassandra Setup for WatsonX Data Workshop

This directory contains scripts to deploy and configure Apache Cassandra for use with WatsonX Data federation queries.

## 🎯 Overview

The Cassandra deployment runs in the same Podman machine as WatsonX Data, allowing seamless connectivity for federated queries across Cassandra and Iceberg data sources.

## 📋 Prerequisites

- ✅ WatsonX Data Developer Edition installed and running
- ✅ Podman machine `watsonx-data-dev` is active
- ✅ Ports 9042 (CQL) and 7199 (JMX) available

## 🚀 Quick Start

### 1. Deploy Cassandra

```bash
./setup/cassandra/deploy-cassandra.sh
```

This will:
- Pull Cassandra 5.0 image
- Create and start a Cassandra container
- Configure it for workshop use
- Wait for Cassandra to be ready

**Time:** ~1-2 minutes

### 2. Load Sample Data

```bash
./setup/cassandra/load-sample-data.sh
```

This will:
- Create the `workshop` keyspace
- Create tables for e-commerce, IoT, and financial examples
- Insert sample data
- Verify the data

**Time:** ~30 seconds

### 3. Connect from WatsonX Data

1. Open WatsonX Data UI: https://localhost:9443 (login `ibmlhadmin` / `password`)
2. Go to **Infrastructure Manager** → **Databases** → **Add database** → **Apache Cassandra**
3. Enter connection details:
   - **Display name:** `cassandra_workshop`
   - **Hostname:** `host.containers.internal`
   - **Port:** `9042`
   - **Username:** `cassandra`
   - **Password:** `cassandra`
   - **Catalog name:** `cassandra_catalog`
   - **SSL:** Disabled
4. Click **Test connection**
5. Click **Add** — the catalog is created in the same step.

## 📊 Sample Data Schema

### Keyspace: `workshop`

#### Tables

1. **customers** - Customer information
   - customer_id (UUID, PRIMARY KEY)
   - first_name, last_name, email, phone
   - registration_date, customer_type

2. **products** - Product catalog
   - product_id (UUID, PRIMARY KEY)
   - name, category, price, stock_quantity
   - created_at, updated_at

3. **orders** - Order records
   - order_id (UUID, PRIMARY KEY)
   - customer_id, order_date, total_amount
   - status, shipping_address

4. **order_items** - Order line items
   - order_id, item_id (COMPOSITE PRIMARY KEY)
   - product_id, quantity, unit_price

5. **sensor_readings** - IoT sensor data
   - sensor_id, reading_time (COMPOSITE PRIMARY KEY)
   - temperature, humidity, pressure, location

6. **transactions** - Financial transactions
   - transaction_id (UUID, PRIMARY KEY)
   - account_id, transaction_date, amount
   - transaction_type, description, balance_after

## 🔧 Management Commands

### Access CQL Shell
```bash
podman exec -it cassandra-workshop cqlsh
```

### Check Cluster Status
```bash
podman exec cassandra-workshop nodetool status
```

### View Logs
```bash
podman logs cassandra-workshop
```

### Stop Cassandra
```bash
podman stop cassandra-workshop
```

### Start Cassandra
```bash
podman start cassandra-workshop
```

### Remove Cassandra
```bash
podman rm -f cassandra-workshop
```

## 🔍 Example Queries

### Direct CQL Queries

```bash
# Connect to CQL shell
podman exec -it cassandra-workshop cqlsh

# Query customers
SELECT * FROM workshop.customers;

# Query products by category
SELECT name, price FROM workshop.products WHERE category = 'Electronics' ALLOW FILTERING;

# Query recent sensor readings
SELECT * FROM workshop.sensor_readings WHERE sensor_id = 'sensor-001' LIMIT 10;
```

### Federated Queries (from WatsonX Data)

Once Cassandra is added to WatsonX Data, you can run federated queries:

```sql
-- Query Cassandra data
SELECT * FROM cassandra_catalog.workshop.customers;

-- Join Cassandra with Iceberg data
SELECT 
    c.first_name,
    c.last_name,
    p.name as product_name,
    p.price
FROM cassandra_catalog.workshop.customers c
JOIN iceberg_catalog.sales.orders o ON c.customer_id = o.customer_id
JOIN cassandra_catalog.workshop.products p ON o.product_id = p.product_id;
```

## 🌐 Network Configuration

### Container Networking

The Cassandra container runs in the same Podman machine as WatsonX Data:

- **From your host:** `localhost:9042`
- **From WatsonX containers:** `host.containers.internal:9042`
- **Container name:** `cassandra-workshop`

### Port Mappings

| Service | Container Port | Host Port |
|---------|---------------|-----------|
| CQL Native | 9042 | 9042 |
| JMX | 7199 | 7199 |

## 🔐 Security Notes

**Default Configuration (Workshop Only):**
- ❌ No authentication enabled
- ❌ No SSL/TLS encryption
- ⚠️ **NOT for production use**

For production deployments, enable:
- Authentication (username/password)
- SSL/TLS encryption
- Network security policies
- Proper firewall rules

## 🐛 Troubleshooting

### Cassandra Won't Start

```bash
# Check logs
podman logs cassandra-workshop

# Check if port is in use
lsof -i :9042

# Remove and recreate
podman rm -f cassandra-workshop
./setup/cassandra/deploy-cassandra.sh
```

### Connection Issues from WatsonX

1. Verify Cassandra is running:
   ```bash
   podman ps | grep cassandra
   ```

2. Test connectivity from WatsonX container:
   ```bash
   podman exec ibm-lh-presto nc -zv host.containers.internal 9042
   ```

3. Check Cassandra logs:
   ```bash
   podman logs cassandra-workshop | tail -50
   ```

### Data Not Showing in WatsonX

1. Verify data exists in Cassandra:
   ```bash
   podman exec cassandra-workshop cqlsh -e "SELECT COUNT(*) FROM workshop.customers;"
   ```

2. Check catalog association in WatsonX UI

3. Refresh metadata in WatsonX

## 📚 Additional Resources

- [Apache Cassandra Documentation](https://cassandra.apache.org/doc/latest/)
- [CQL Reference](https://cassandra.apache.org/doc/latest/cql/)
- [WatsonX Data Federation](https://www.ibm.com/docs/en/watsonxdata)

## 🎓 Workshop Exercises

After setup, proceed to the workshop exercises:
- `exercises/01-requirements-exercise.md` — Requirements
- `exercises/02-spec-exercise.md` — Spec (design + OpenAPI)
- `exercises/03-build-exercise.md` — Tasks + build
- `exercises/optional/iceberg-deep-dive.md` — Hour 4 Iceberg menu
- `examples/{ecommerce,iot,financial}/` — per-domain architecture references

---

**Version:** 1.0  
**Last Updated:** 2026-04-14  
**Compatible with:** Cassandra 5.0, WatsonX Data 2.3.x