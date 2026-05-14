# Federated Query Analysis (SHD-030)

This document evaluates whether any analytical queries in the Sensor Health Dashboard should use federated Presto queries (joining Cassandra and Iceberg in a single SQL statement) instead of application-side joins.

## Current Architecture

### Application-Side Join Pattern

All current analytical queries use **application-side joins**:

1. **Device Health Service** (`backend/src/services/device-health-service.ts`):
   - Loads device state from Cassandra
   - Loads readings from Cassandra (hot data)
   - Loads alerts from Cassandra (hot data)
   - Loads baselines from Iceberg via Presto (cold data)
   - Joins data in application memory
   - Computes anomalies in application code

2. **Device List Enrichment Service** (`backend/src/services/device-list-enrichment-service.ts`):
   - Loads device list from Cassandra
   - For each device (in parallel):
     - Loads alerts from Cassandra
     - Loads readings from Cassandra
     - Loads baselines from Iceberg via Presto
   - Joins data in application memory
   - Computes anomalies in application code

3. **Baseline Repository** (`backend/src/repositories/baseline-repository.ts`):
   - Queries Iceberg `hourly_aggregates` via Presto
   - Aggregates 7-day baseline per device/metric
   - Returns to application for comparison

### Why Application-Side Joins Were Chosen

1. **Hot operational reads are fast** (<100ms from Cassandra)
2. **Anomaly logic is complex** (two-rule evaluation, quality code filtering)
3. **Graceful degradation** (partial data when sources fail)
4. **Bounded scope** (single device or paginated device list)
5. **Testability** (unit tests for anomaly logic)

## Available Federated Query Patterns

The workshop provides three example federated queries in `setup/sample-data/iot/federation_queries.sql`:

### Query 1: Triage Open Alerts with Historical Baseline + Weather
```sql
-- Joins:
-- - cassandra_catalog.iot.alerts_open (hot)
-- - cassandra_catalog.iot.device_state_current (hot)
-- - iceberg_data.iot.hourly_aggregates (cold, 14-day window)
-- - iceberg_data.iot.weather_by_location (cold, external feed)
-- 
-- Returns: Top 25 alerts with baseline comparison and weather context
```

**Characteristics:**
- Scans ALL open alerts (unbounded hot source)
- Joins to 14-day Iceberg aggregates
- Adds external weather data
- Sorts by severity and anomaly magnitude
- LIMIT 25

### Query 2: Degraded Devices with Deteriorating Trend
```sql
-- Joins:
-- - cassandra_catalog.iot.device_state_current (hot, filtered to degraded/maintenance)
-- - iceberg_data.iot.hourly_aggregates (cold, 3-day and 14-day windows)
--
-- Returns: Top 30 degraded devices with trend analysis
```

**Characteristics:**
- Filters hot source to degraded/maintenance status only
- Computes 3-day vs 14-day trend in SQL
- Bounded by device status filter
- LIMIT 30

### Query 3: Site Health - Current vs Historical Uptime
```sql
-- Joins:
-- - cassandra_catalog.iot.device_state_current (hot, aggregated by site)
-- - iceberg_data.iot.daily_site_summary (cold, 30-day window)
--
-- Returns: Top 20 sites with uptime regression
```

**Characteristics:**
- Aggregates hot source by site (small cardinality)
- Joins to 30-day site summaries
- No per-device detail
- LIMIT 20

## Evaluation Against Current Use Cases

### Use Case 1: Device Detail Page (Composite Health Endpoint)

**Current:** Application-side join
- Load device state (1 device)
- Load readings (1 device, last 60 minutes)
- Load alerts (1 device)
- Load baseline (1 device, 7 days)
- Compute anomalies in application

**Federated Alternative:**
```sql
-- Hypothetical federated query
SELECT 
  d.device_id, d.status, d.battery_percent,
  r.metric_name, r.metric_value, r.timestamp,
  b.baseline_avg, b.baseline_p95, b.baseline_stddev,
  a.severity, a.alert_type
FROM cassandra_catalog.iot.device_state_current d
LEFT JOIN cassandra_catalog.iot.readings_hot r 
  ON r.device_id = d.device_id 
  AND r.hour_bucket >= current_timestamp - INTERVAL '1' HOUR
LEFT JOIN iceberg_data.iot.hourly_aggregates b
  ON b.device_id = CAST(d.device_id AS VARCHAR)
  AND b.hour_start >= current_timestamp - INTERVAL '7' DAY
LEFT JOIN cassandra_catalog.iot.alerts_open a
  ON a.device_id = d.device_id
WHERE d.device_id = '<uuid>'
```

**Analysis:**

❌ **DO NOT USE FEDERATED QUERY**

**Reasons:**
1. **Anomaly logic cannot move to SQL** - Two-rule evaluation with quality code filtering is complex and tested in application code
2. **No performance gain** - Single device scope is already fast (application-side: ~200ms total, federated: ~15-25s on Apple Silicon)
3. **Loses graceful degradation** - Federated query fails atomically; application-side can return partial data
4. **Loses testability** - Anomaly logic in SQL is harder to unit test
5. **Presto is slower than parallel Cassandra queries** - Even for single device

**Decision:** Keep application-side join

---

### Use Case 2: Dashboard List Enrichment

**Current:** Application-side join
- Load device list (paginated, e.g., 25 devices)
- For each device in parallel:
  - Load alerts
  - Load readings
  - Load baseline
- Compute anomalies per device
- Filter by anomaly status if requested

**Federated Alternative:**
```sql
-- Hypothetical federated query
WITH device_page AS (
  SELECT device_id, status, battery_percent, site_id
  FROM cassandra_catalog.iot.device_state_current
  WHERE site_id = '<site>' AND status = '<status>'
  ORDER BY last_heartbeat DESC
  LIMIT 25 OFFSET <offset>
)
SELECT 
  d.device_id,
  COUNT(DISTINCT r.metric_name) AS metric_count,
  COUNT(DISTINCT a.alert_id) AS alert_count,
  MAX(a.severity) AS highest_severity,
  -- ... baseline aggregations
FROM device_page d
LEFT JOIN cassandra_catalog.iot.readings_hot r ...
LEFT JOIN cassandra_catalog.iot.alerts_open a ...
LEFT JOIN iceberg_data.iot.hourly_aggregates b ...
GROUP BY d.device_id
```

**Analysis:**

❌ **DO NOT USE FEDERATED QUERY**

**Reasons:**
1. **Anomaly computation still needs application code** - Cannot express two-rule anomaly logic in SQL
2. **Pagination is already bounded** - 25 devices per page is a small scope
3. **Parallel application queries are faster** - 25 parallel Cassandra queries (each <100ms) complete in ~100ms total; federated query takes 15-25s
4. **Loses filter flexibility** - Anomaly status filter requires computing anomalies first, then filtering
5. **Loses graceful degradation** - Per-device error handling is better in application code

**Decision:** Keep application-side join

---

### Use Case 3: Alert Triage Dashboard (Hypothetical Future Feature)

**Scenario:** Operations team wants a "top alerts to investigate" view that shows:
- All open critical/high alerts
- Each alert's metric value vs 14-day baseline
- Weather conditions at alert time
- Sorted by anomaly magnitude

**This matches Federation Query 1 from the workshop examples.**

**Federated Query:**
```sql
-- From federation_queries.sql Query 1
WITH baseline_p95 AS (
  SELECT device_id, metric_name, MAX(p95_value) AS baseline_p95
  FROM iceberg_data.iot.hourly_aggregates
  WHERE hour_start >= current_date - INTERVAL '14' DAY
  GROUP BY device_id, metric_name
)
SELECT
  a.severity, a.alert_type, a.metric_name, a.metric_value,
  b.baseline_p95,
  (a.metric_value - b.baseline_p95) / NULLIF(b.baseline_p95, 0) AS pct_over_baseline,
  w.temperature_c, w.conditions
FROM cassandra_catalog.iot.alerts_open a
JOIN cassandra_catalog.iot.device_state_current d ON d.device_id = a.device_id
LEFT JOIN baseline_p95 b ON b.device_id = CAST(a.device_id AS VARCHAR)
LEFT JOIN iceberg_data.iot.weather_by_location w ON w.site_id = a.site_id
WHERE a.acknowledged = false
ORDER BY pct_over_baseline DESC NULLS LAST
LIMIT 25
```

**Analysis:**

⚠️ **CONDITIONAL USE - NOT IMPLEMENTED IN STARTER APP**

**Reasons to consider:**
1. **Analytical use case** - Not a hot operational read
2. **Broad scan acceptable** - Operations team expects slower query
3. **SQL can express the logic** - Simple baseline comparison, no complex rules
4. **External data enrichment** - Weather data only in Iceberg
5. **Result set is small** - LIMIT 25

**Reasons NOT to implement in starter app:**
1. **Out of scope** - Requirements don't include alert triage dashboard
2. **Slow on Apple Silicon** - 15-25s query time is poor UX
3. **Current alert endpoint is sufficient** - Per-device alerts are fast
4. **No weather data requirement** - REQ-005 doesn't mention weather

**Decision:** Do NOT implement (out of scope for starter app)

**Future consideration:** If alert triage dashboard is added AND deployed on Intel/Linux (faster Presto), this would be a good federated query candidate.

---

### Use Case 4: Site Health Dashboard (Hypothetical Future Feature)

**Scenario:** Operations team wants a "site health overview" showing:
- Current device counts and online percentage per site
- 30-day historical uptime average per site
- Sites with significant uptime regression

**This matches Federation Query 3 from the workshop examples.**

**Federated Query:**
```sql
-- From federation_queries.sql Query 3
WITH site_live AS (
  SELECT site_id, COUNT(*) AS live_device_count,
         SUM(CASE WHEN status = 'online' THEN 1 ELSE 0 END) AS online_count
  FROM cassandra_catalog.iot.device_state_current
  GROUP BY site_id
)
SELECT
  l.site_id, l.live_device_count, l.online_count,
  100.0 * l.online_count / l.live_device_count AS current_online_pct,
  h.avg_uptime_30d
FROM site_live l
LEFT JOIN iceberg_data.iot.daily_site_summary h ON h.site_id = l.site_id
ORDER BY (h.avg_uptime_30d - current_online_pct) DESC
LIMIT 20
```

**Analysis:**

⚠️ **CONDITIONAL USE - NOT IMPLEMENTED IN STARTER APP**

**Reasons to consider:**
1. **Analytical use case** - Site-level aggregation, not device-level
2. **Small cardinality** - Sites are few (10-50 typical)
3. **SQL can express the logic** - Simple aggregation and comparison
4. **No complex anomaly rules** - Just uptime percentage comparison

**Reasons NOT to implement in starter app:**
1. **Out of scope** - Requirements focus on device-level monitoring (REQ-001, REQ-007)
2. **No site dashboard requirement** - REQ-006 only mentions site filter, not site dashboard
3. **Current sites endpoint is sufficient** - Returns site list for filtering

**Decision:** Do NOT implement (out of scope for starter app)

**Future consideration:** If site health dashboard is added, this would be a good federated query candidate.

---

## Summary and Recommendations

### Decision Matrix

| Use Case | Current Approach | Federated Alternative | Decision | Rationale |
|----------|------------------|----------------------|----------|-----------|
| Device Detail (Composite Health) | Application-side join | Federated query | ❌ **Keep application-side** | Anomaly logic too complex for SQL; no performance gain; loses graceful degradation |
| Dashboard List Enrichment | Application-side join | Federated query | ❌ **Keep application-side** | Parallel queries faster; bounded scope; anomaly logic in application |
| Alert Triage Dashboard | N/A (not implemented) | Federated query | ⚠️ **Out of scope** | Good candidate for future, but not in starter app requirements |
| Site Health Dashboard | N/A (not implemented) | Federated query | ⚠️ **Out of scope** | Good candidate for future, but not in starter app requirements |

### Key Principles Applied

1. **Hot operational reads stay direct-Cassandra** - All device state, readings, and alerts queries remain direct Cassandra access
2. **Anomaly logic stays in application** - Complex two-rule evaluation with quality code filtering cannot move to SQL
3. **Bounded scope is already fast** - Single device or paginated list (25 devices) is fast with application-side joins
4. **Graceful degradation is valuable** - Partial data on source failure is better than atomic failure
5. **Federated queries are for analytical use cases** - Alert triage and site health dashboards would benefit, but are out of scope

### No Changes Required

**All current analytical queries should remain application-side joins.**

No federated queries will be introduced in the starter app because:
- Current use cases are bounded to single device or small paginated lists
- Anomaly detection logic is too complex for SQL
- Application-side joins are faster for bounded scopes
- Graceful degradation is more valuable than atomic federated queries
- Requirements don't include analytical dashboards that would benefit from federation

### Future Considerations

If the application is extended beyond the starter scope, these would be good federated query candidates:

1. **Alert Triage Dashboard** - Broad scan of all open alerts with baseline comparison and weather context
2. **Site Health Dashboard** - Site-level aggregation with historical comparison
3. **Trend Analysis** - Degraded devices with 3-day vs 14-day trend analysis

All three match the workshop's example federated queries and would benefit from SQL-side joins when:
- Deployed on Intel/Linux (faster Presto performance)
- Analytical use case (slower query acceptable)
- Broad scan or aggregation (not bounded to single device)
- Simple comparison logic (no complex anomaly rules)

---

## Compliance with Acceptance Criteria

✅ **Decision is documented for each candidate analytical path**
- Device detail: Keep application-side
- Dashboard enrichment: Keep application-side
- Alert triage: Out of scope (future consideration)
- Site health: Out of scope (future consideration)

✅ **Any federated query introduced is bounded to selected devices or paginated subsets**
- N/A - No federated queries introduced

✅ **No broad hot-source scan is introduced**
- All hot reads remain bounded to single device or paginated list

✅ **Core hot operational endpoints remain direct-Cassandra reads**
- Device state: Direct Cassandra
- Readings: Direct Cassandra
- Alerts: Direct Cassandra
- Baseline: Presto (cold data only)

---

**Related Requirements:**
- REQ-003: Baseline comparison (application-side join)
- REQ-004: Anomaly detection (application logic)
- REQ-009: Hot + cold data federation (application-side join)
- REQ-011: Performance and scalability (bounded queries)

**Related Tickets:**
- SHD-020: Anomaly evaluation service (application logic)
- SHD-023: Composite health service (application-side join)
- SHD-030: Evaluate selective federated analytics usage (this document)