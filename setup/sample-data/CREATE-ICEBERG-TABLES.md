# Creating Iceberg Tables in WatsonX Data

## Quick Guide

Since you've already registered Cassandra, you can now create the Iceberg tables for analytics using the WatsonX Data Query Workspace.

## Steps

### 1. Open Query Workspace

1. Go to https://localhost:9443
2. Login with `ibmlhadmin` / `password`
3. Click on **Query workspace** in the left navigation

### 2. Create E-commerce Iceberg Schema

Copy and paste this into the query editor and run:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg_data.ecommerce
WITH (location = 's3a://iceberg-bucket/ecommerce');
```

### 3. Create E-commerce Tables

Then run each of these table creation statements (from `setup/sample-data/ecommerce/iceberg_schema.sql`):

**Sales Fact Table:**
```sql
USE iceberg_data.ecommerce;

CREATE TABLE IF NOT EXISTS sales_fact (
    sale_id VARCHAR,
    order_id VARCHAR,
    order_date DATE,
    order_timestamp TIMESTAMP(6),
    order_year INTEGER,
    order_month INTEGER,
    order_day INTEGER,
    order_day_of_week INTEGER,
    order_quarter INTEGER,
    customer_id VARCHAR,
    customer_email VARCHAR,
    customer_name VARCHAR,
    customer_loyalty_tier VARCHAR,
    customer_segment VARCHAR,
    product_id VARCHAR,
    product_sku VARCHAR,
    product_name VARCHAR,
    product_category VARCHAR,
    product_subcategory VARCHAR,
    product_brand VARCHAR,
    quantity INTEGER,
    unit_price DECIMAL(10,2),
    discount_amount DECIMAL(10,2),
    tax_amount DECIMAL(10,2),
    line_total DECIMAL(10,2),
    order_subtotal DECIMAL(10,2),
    order_tax DECIMAL(10,2),
    order_shipping DECIMAL(10,2),
    order_discount DECIMAL(10,2),
    order_total DECIMAL(10,2),
    order_status VARCHAR,
    payment_method VARCHAR,
    payment_status VARCHAR,
    shipping_country VARCHAR,
    shipping_state VARCHAR,
    shipping_city VARCHAR,
    is_first_purchase BOOLEAN,
    is_returned BOOLEAN,
    is_discounted BOOLEAN,
    created_at TIMESTAMP(6),
    updated_at TIMESTAMP(6)
)
PARTITIONED BY (order_year, order_month)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['order_year', 'order_month'],
    sorted_by = ARRAY['order_date', 'order_timestamp']
);
```

### 4. Repeat for IoT and Financial

Create schemas and tables for the other datasets:

**IoT Schema:**
```sql
CREATE SCHEMA IF NOT EXISTS iceberg_data.iot
WITH (location = 's3a://iceberg-bucket/iot');
```

**Financial Schema:**
```sql
CREATE SCHEMA IF NOT EXISTS iceberg_data.financial
WITH (location = 's3a://iceberg-bucket/financial');
```

Then create the tables from:
- `setup/sample-data/iot/iceberg_schema.sql`
- `setup/sample-data/financial/iceberg_schema.sql`

## Alternative: Use the SQL Files Directly

If you prefer, you can copy the entire contents of each SQL file and paste into the Query Workspace:

1. **E-commerce**: `setup/sample-data/ecommerce/iceberg_schema.sql`
2. **IoT**: `setup/sample-data/iot/iceberg_schema.sql`
3. **Financial**: `setup/sample-data/financial/iceberg_schema.sql`

Just skip the commented-out sample queries at the end of each file.

## Verify Tables Were Created

Run this query to see your new Iceberg tables:

```sql
SHOW TABLES FROM iceberg_data.ecommerce;
SHOW TABLES FROM iceberg_data.iot;
SHOW TABLES FROM iceberg_data.financial;
```

## Next Steps

Once the tables are created, you can:

1. **Run Federation Queries** - Query across Cassandra and Iceberg:
   ```sql
   SELECT c.email, c.first_name, COUNT(o.order_id) as order_count
   FROM cassandra_catalog.workshop.customers c
   LEFT JOIN iceberg_data.ecommerce.sales_fact o ON c.customer_id = o.customer_id
   GROUP BY c.email, c.first_name
   LIMIT 10;
   ```

2. **Load Data into Iceberg** - Use INSERT INTO SELECT to copy data from Cassandra to Iceberg for analytics

## Troubleshooting

If you get errors about the catalog not existing:
1. Make sure you're connected to the `iceberg_data` catalog in the Query Workspace
2. Check that MinIO storage is running: `podman ps | grep minio`
3. Verify the catalog exists in Infrastructure Manager → Catalogs

---

**Made with ❤️ for your workshop**