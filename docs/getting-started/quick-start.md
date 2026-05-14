# Quick Start

Get the Sensor Health Dashboard running in 5 minutes.

## Prerequisites Check

Ensure you have:

- [x] Workshop environment installed (watsonx.data + Cassandra)
- [x] Node.js 18+ and npm installed
- [x] Sample IoT data loaded

!!! tip "First Time Setup"
    If you haven't set up the workshop environment yet, see the [Installation Guide](installation.md) first.

## Step 1: Clone the Repository

```bash
git clone https://github.com/dwakeman/spec-coding-iot-app.git
cd spec-coding-iot-app
```

## Step 2: Install Dependencies

=== "Backend"

    ```bash
    cd backend
    npm install
    ```

=== "Frontend"

    ```bash
    cd frontend
    npm install
    ```

## Step 3: Configure Environment

Create a `.env` file in the project root:

```bash
cp .env.example .env
```

The default configuration should work for the workshop environment:

```bash title=".env"
# Cassandra (hot operational data)
CASSANDRA_CONTACT_POINTS=127.0.0.1
CASSANDRA_PORT=9042
CASSANDRA_KEYSPACE=iot
CASSANDRA_USERNAME=cassandra
CASSANDRA_PASSWORD=cassandra

# Presto / watsonx.data (cold analytical data)
PRESTO_BASE_URL=https://localhost:8443
PRESTO_CATALOG=iceberg_data
PRESTO_SCHEMA=iot
PRESTO_USERNAME=ibmlhadmin
PRESTO_PASSWORD=password
PRESTO_TLS_REJECT_UNAUTHORIZED=false

# Backend service
PORT=3000
LOG_LEVEL=info
```

!!! warning "TLS Certificate Verification"
    `PRESTO_TLS_REJECT_UNAUTHORIZED=false` is for local development only. Enable TLS verification in production.

## Step 4: Start the Application

Open two terminal windows:

=== "Terminal 1: Backend"

    ```bash
    cd backend
    npm run dev
    ```

    You should see:
    ```
    [INFO] Server listening on port 3000
    [INFO] Cassandra connected
    ```

=== "Terminal 2: Frontend"

    ```bash
    cd frontend
    npm run dev
    ```

    You should see:
    ```
    VITE v5.x.x  ready in xxx ms
    ➜  Local:   http://localhost:5173/
    ```

## Step 5: Access the Dashboard

Open your browser and navigate to:

- **Frontend:** [http://localhost:5173](http://localhost:5173)
- **Backend API:** [http://localhost:3000](http://localhost:3000)
- **Health Check:** [http://localhost:3000/api/health](http://localhost:3000/api/health)

## Verify It's Working

### Check the Dashboard

You should see:

1. **Fleet summary** with device counts
2. **Device list** with status indicators
3. **Filter controls** for site and status
4. **Anomaly badges** on devices with unusual readings

### Check a Device Detail

1. Click on any device in the list
2. You should see:
    - Device state (status, battery, signal)
    - Recent readings (last hour)
    - 7-day baseline comparison
    - Open alerts (if any)
    - Anomaly indicators per metric

### Check the API

```bash
# Health check
curl http://localhost:3000/api/health

# List devices
curl http://localhost:3000/api/v1/devices

# Get device health
curl http://localhost:3000/api/v1/devices/{device-id}/health
```

## Troubleshooting

### Backend won't start

**Symptom:** Connection errors to Cassandra or Presto

**Solution:**

1. Verify workshop environment is running:
   ```bash
   ./.watsonx-data/ibm-lh-dev/bin/status --all
   ```

2. Check Cassandra is accessible:
   ```bash
   podman exec cassandra cqlsh -e "DESCRIBE KEYSPACES;"
   ```

3. See [Troubleshooting Guide](../operations/troubleshooting.md) for more help

### Frontend shows "No devices found"

**Symptom:** Empty dashboard despite backend running

**Solution:**

1. Check backend logs for errors
2. Verify sample data was loaded:
   ```bash
   ./setup/show-active-installation.sh
   ```
3. Check API directly:
   ```bash
   curl http://localhost:3000/api/v1/devices
   ```

### Slow Presto queries

**Symptom:** Device detail takes 15-25 seconds to load

**Expected on Apple Silicon:** This is normal due to amd64 emulation. See [Performance](../operations/performance.md) for details.

## Next Steps

Now that you have the app running:

1. [Explore the Dashboard](../user-guide/dashboard.md) - Learn the UI features
2. [Understand the Architecture](../architecture/overview.md) - See how it works
3. [Review the API](../api/overview.md) - Integrate with your own code
4. [Run the Tests](../development/testing.md) - Verify everything works

## Running Tests

=== "Backend Tests"

    ```bash
    cd backend
    npm test
    ```

    Expected: **84/84 tests passing**

=== "Frontend Tests"

    ```bash
    cd frontend
    npm test
    ```

    Expected: **6/6 tests passing**

---

**Ready to dive deeper?** Check out the [Configuration Guide](configuration.md) to customize the application.