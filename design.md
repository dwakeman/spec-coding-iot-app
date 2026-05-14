# Sensor Health Dashboard Design

## 1. Purpose

This document defines the technical design for the IoT Sensor Health Dashboard described in `requirements.md`. The design is constrained to the actual workshop data model and to a mixed access pattern: the application reads hot operational data directly from Cassandra and reads Iceberg analytical data through the Presto engine in watsonx.data. Federated Cassandra/Iceberg analytical queries may also be executed through Presto when beneficial.

Logical source tables used by the application:
- Cassandra `iot.device_state_current` via direct Cassandra access
- Cassandra `iot.readings_hot` via direct Cassandra access
- Cassandra `iot.alerts_open` via direct Cassandra access
- Iceberg `iceberg_data.iot.hourly_aggregates` via Presto

Optional future-use tables are acknowledged but not part of the starter implementation.

This design focuses on read-only operational workflows that combine hot operational data with cold analytical baseline data using direct Cassandra access for hot reads and Presto for analytics.

## 2. Design Scope

### In Scope
- Fleet dashboard of current device health
- Device detail view
- Last-hour readings per device
- 7-day baseline comparison by metric
- Anomaly flagging
- Open alert context
- Filtering by site, status, and anomaly state
- Read-only backend APIs
- Frontend and backend technical requirements

### Out of Scope
- Alert acknowledgement updates
- Device command execution
- Predictive maintenance
- Weather-based correlation workflows
- Firmware history views
- Maintenance window workflows
- Authentication and authorization implementation
- Background write-back jobs to source systems

## 3. Actual Source Tables and Usage

## 3.1 Cassandra: `iot.device_state_current`
Purpose in app:
- Primary fleet inventory table
- Current device status and health context
- Base dataset for dashboard list and device detail header

Relevant columns:
- `device_id`
- `device_type`
- `device_class`
- `model`
- `firmware_version`
- `status`
- `last_heartbeat`
- `last_reading_value`
- `battery_percent`
- `signal_strength_dbm`
- `site_id`
- `zone`
- `installed_at`
- `updated_at`

Access characteristics:
- Accessed directly from Cassandra by the application
- Primary key lookup semantics remain based on `device_id`
- Secondary-index-backed filtering semantics remain based on `site_id`
- Secondary-index-backed filtering semantics remain based on `status`
- Fleet scans may still be expensive against Cassandra; for starter scope, fleet listing is acceptable for moderate sample data size, but production design would add purpose-built query tables or query-serving projections

## 3.2 Cassandra: `iot.readings_hot`
Purpose in app:
- Last-hour sensor readings for a selected device
- Recent metric samples used in anomaly comparison

Relevant columns:
- `device_id`
- `reading_bucket_hour`
- `reading_timestamp`
- `metric_name`
- `metric_value`
- `unit`
- `quality_code`

Access characteristics:
- Accessed directly from Cassandra by the application
- Partition key is `(device_id, reading_bucket_hour)`
- Efficient queries must constrain `device_id` plus one or more hour buckets
- Since the dashboard needs the last 60 minutes, the backend should query:
  - current hour bucket
  - previous hour bucket
- Results are merged in application code and filtered to the last 60 minutes

## 3.3 Cassandra: `iot.alerts_open`
Purpose in app:
- Alert context for device detail
- Open alert indicators in dashboard list

Relevant columns:
- `device_id`
- `alert_id`
- `raised_at`
- `severity`
- `alert_type`
- `metric_name`
- `metric_value`
- `threshold_value`
- `site_id`
- `acknowledged`

Access characteristics:
- Accessed directly from Cassandra by the application
- Partitioned by `device_id`
- Efficient reads remain device-oriented
- Fleet-wide alert counting is not optimized by schema, so starter implementation should enrich dashboard rows only for currently returned devices rather than attempt unrestricted alert scans

## 3.4 Iceberg: `iceberg_data.iot.hourly_aggregates`
Purpose in app:
- 7-day baseline for device metric comparison
- Input to anomaly calculations
- Device detail baseline panels
- Dashboard anomaly summary by device

Relevant columns:
- `device_id`
- `site_id`
- `device_class`
- `metric_name`
- `hour_start`
- `sample_count`
- `min_value`
- `max_value`
- `avg_value`
- `p95_value`
- `stddev_value`

Access characteristics:
- Queried through Presto / watsonx.data
- Efficient when constrained by:
  - `device_id`
  - time window (`hour_start >= current_timestamp - interval '7' day`)
- Because `device_id` is stored as `VARCHAR` in Iceberg but as UUID in Cassandra, API and backend must normalize the device ID string during joins and comparisons

## 4. Architecture Overview

## 4.1 Logical Components

### Frontend
A single-page dashboard application responsible for:
- fleet list rendering
- filter controls
- anomaly badges
- device detail view
- chart or table rendering for last-hour readings and baseline stats
- error and empty-state messaging

### Backend API
A read-only service responsible for:
- querying Cassandra directly for current state and recent readings
- querying Cassandra directly for open alerts
- querying Presto for Iceberg-backed baseline data
- optionally issuing federated SQL through Presto that joins Cassandra and Iceberg in a single query when beneficial
- computing anomaly summaries
- shaping API responses for frontend use
- applying pagination, sorting, and filtering rules

### Data Sources
- Cassandra as the application-facing store for hot operational data
- Presto / watsonx.data for Iceberg analytical baseline data
- Presto federation for optional Cassandra/Iceberg analytical joins

## 4.2 Recommended Runtime Pattern

For starter simplicity:
- backend queries Cassandra directly for hot operational tables
- backend queries Presto / watsonx.data for Iceberg analytical tables
- backend may issue a federated Presto query when it improves efficiency or simplifies analytical response shaping
- backend joins datasets in memory by `device_id` and `metric_name` when using multiple statements
- frontend never calls Cassandra or Presto directly

Rationale:
- avoids exposing data-source credentials to browser
- preserves low-latency direct access for hot operational reads
- centralizes anomaly logic
- simplifies API contract
- allows analytics to use Iceberg or federated hot+cold SQL when appropriate

## 5. Core Data Access Patterns

## 5.1 Fleet Dashboard List
Primary requirement coverage:
- REQ-001
- REQ-005
- REQ-006
- REQ-008
- REQ-009
- REQ-010

Flow:
1. Query `iot.device_state_current` directly in Cassandra for devices matching requested filters.
2. For each returned device, optionally query `iot.alerts_open` directly in Cassandra by `device_id`.
3. For each returned device, query 7-day baseline summary from `iceberg_data.iot.hourly_aggregates` through Presto.
4. If anomaly evaluation is requested, query recent readings from `iot.readings_hot` directly in Cassandra for current and previous hour buckets.
5. Compute per-device anomaly summary from recent readings vs baseline.
6. Return normalized dashboard rows.

Notes:
- To control backend fan-out, the dashboard endpoint should be paginated.
- Baseline and anomaly enrichment should be limited to the page of devices returned.
- Alert enrichment should be per-page devices only.

## 5.2 Device Detail
Primary requirement coverage:
- REQ-002
- REQ-003
- REQ-004
- REQ-005
- REQ-007
- REQ-008
- REQ-009

Flow:
1. Load `iot.device_state_current` directly from Cassandra by `device_id`.
2. Load `iot.readings_hot` directly from Cassandra using two bucket-hour queries.
3. Load `iot.alerts_open` directly from Cassandra by `device_id`.
4. Load 7-day baseline rows from `iceberg_data.iot.hourly_aggregates` through Presto by `device_id`.
5. Group readings by `metric_name`.
6. Compute anomaly result per metric.
7. Return a single detail payload.

## 5.3 Device Search by Site and Status
Primary requirement coverage:
- REQ-001
- REQ-006

Flow:
1. If `site_id` is provided, query `iot.device_state_current` directly in Cassandra using the `site_id` index.
2. If `status` is provided, query `iot.device_state_current` directly in Cassandra using the `status` index.
3. If both are provided, query one filtered set and post-filter in the backend as needed.
4. Return paginated dashboard rows.

Design note:
Because direct Cassandra access is used for hot data, the practical filtering limits reflect the actual Cassandra schema. This is acceptable for starter data but would need denormalized query tables or serving projections in production.

## 5.4 Baseline Retrieval by Device
Primary requirement coverage:
- REQ-003
- REQ-004
- REQ-009

Presto query shape:
- Filter `hour_start >= current_timestamp - interval '7' day`
- Filter `device_id = :deviceId`
- Group by `device_id, metric_name`
- Aggregate:
  - average of `avg_value`
  - max of `p95_value`
  - min of `min_value`
  - max of `max_value`
  - average of `stddev_value`
  - sum of `sample_count`

Returned baseline per metric:
- baselineAvg
- baselineP95
- baselineMin
- baselineMax
- baselineStddev
- sampleCount
- baselineWindowHoursCovered

## 5.5 Recent Reading Retrieval by Device
Primary requirement coverage:
- REQ-002
- REQ-004
- REQ-008

Cassandra query shape:
- Query current hour bucket by `device_id` and rounded current hour
- Query previous hour bucket by `device_id` and rounded previous hour
- Merge results
- Filter to timestamps in last 60 minutes
- Group by `metric_name`

This design aligns directly with the partition key of `readings_hot`.

## 6. Anomaly Detection Design

## 6.1 Rule Set
Starter rule set for REQ-004:

A metric is flagged `anomalous` when all of the following are true:
1. At least one good or suspect recent reading exists for the metric in the last hour.
2. A 7-day baseline exists from `hourly_aggregates`.
3. The latest recent reading satisfies either:
   - `metric_value > baselineP95`
   - or `abs(metric_value - baselineAvg) > max(2 * baselineStddev, baselineAvg * 0.10)`

If `quality_code = bad`, the reading is excluded from anomaly evaluation but may still be shown in the UI.

If baseline inputs are missing, anomaly status is `unknown`, not `normal`.

## 6.2 Device-Level Rollup
A device is flagged `anomalous` when:
- any metric is anomalous, or
- an open alert of type `anomaly` exists

Device severity rollup:
- `critical` if any critical alert exists
- `high` if any anomalous metric exists and no critical alert exists
- `medium` if device status is `degraded`
- `low` if battery is below configured low-battery threshold
- `normal` otherwise

## 6.3 Missing Data Rules
- No recent readings in last hour: device `dataFreshness = stale`
- No baseline rows for metric: `anomalyStatus = unknown`
- Only bad-quality readings: `anomalyStatus = unknown`
- Missing alerts: return empty array, not null

## 7. API Surface Design

## 7.1 Endpoints
The backend should expose the following endpoints:

1. `GET /api/v1/devices`
   - dashboard list with filtering, sorting, pagination, and optional enrichment

2. `GET /api/v1/devices/{deviceId}`
   - current device state plus summary flags

3. `GET /api/v1/devices/{deviceId}/readings`
   - last-hour readings by device

4. `GET /api/v1/devices/{deviceId}/baseline`
   - 7-day baseline by metric

5. `GET /api/v1/devices/{deviceId}/alerts`
   - open alerts for the device

6. `GET /api/v1/devices/{deviceId}/health`
   - composite detail endpoint returning state, readings, alerts, baseline, and anomaly summary

7. `GET /api/v1/sites`
   - list available site IDs derived from current device state for filter population

## 7.2 Endpoint-to-Requirement Mapping

| Endpoint | Supported REQ IDs |
|---|---|
| `GET /api/v1/devices` | REQ-001, REQ-005, REQ-006, REQ-008, REQ-009, REQ-010, REQ-011 |
| `GET /api/v1/devices/{deviceId}` | REQ-001, REQ-007, REQ-008 |
| `GET /api/v1/devices/{deviceId}/readings` | REQ-002, REQ-008 |
| `GET /api/v1/devices/{deviceId}/baseline` | REQ-003, REQ-008, REQ-009 |
| `GET /api/v1/devices/{deviceId}/alerts` | REQ-005, REQ-007 |
| `GET /api/v1/devices/{deviceId}/health` | REQ-002, REQ-003, REQ-004, REQ-005, REQ-007, REQ-008, REQ-009, REQ-010 |
| `GET /api/v1/sites` | REQ-006, REQ-010 |

## 8. Backend Technical Requirements

## 8.1 Service Responsibilities
The backend shall:
- expose a REST API
- validate UUID path parameters
- validate query parameters for pagination, filters, and sort fields
- connect directly to Cassandra for hot operational reads
- connect to Presto / watsonx.data for Iceberg analytical reads
- support federated Presto analytics when joining Cassandra and Iceberg is beneficial
- normalize numeric and timestamp values into JSON-safe representations
- compute anomaly state in service code
- return consistent error payloads

## 8.2 Data Access Layer
The backend should implement source-appropriate repositories:
- `DeviceStateRepository`
- `ReadingsRepository`
- `AlertsRepository`
- `BaselineRepository`

A shared Cassandra client should access:
- `iot.device_state_current`
- `iot.readings_hot`
- `iot.alerts_open`

A shared Presto client should execute SQL against:
- `iceberg_data.iot.hourly_aggregates`
- and, when needed for federated analytics, the Presto `cassandra` catalog

Current implementation notes:
- the backend authenticates to Presto using HTTP Basic authentication
- credentials are provided through backend environment variables and are never exposed to the browser
- local development may disable TLS certificate verification for the Presto endpoint through `PRESTO_TLS_REJECT_UNAUTHORIZED=false`
- TLS verification bypass is for local/self-signed development only and must remain enabled in non-local environments

A service layer should assemble:
- `DashboardService`
- `DeviceHealthService`

## 8.3 Query Constraints
Backend must respect actual schema constraints:
- `readings_hot` requires bucket-aware reads by `device_id` and `reading_bucket_hour`
- `alerts_open` is best accessed by device
- `hourly_aggregates` should always be filtered by time window and device ID when serving detail endpoints
- fleet-wide baseline computation should be limited to paginated dashboard subsets
- federated Presto joins should be constrained to selective device subsets to avoid broad scans across the Cassandra source

## 8.4 Error Handling
The backend shall return structured errors:
- `400` invalid filter or malformed UUID
- `404` device not found
- `422` unsupported sort field or query combination
- `502` upstream data-source query failure
- `503` transient dependency unavailable

## 8.5 Performance Requirements
Starter targets:
- dashboard list response under 2 seconds for default page size on workshop dataset
- device health detail response under 3 seconds with baseline enrichment
- page size default 25, maximum 100
- request timeout protection on Presto/Iceberg queries

## 8.6 Observability Requirements
Backend should log:
- request ID
- endpoint
- filter set
- Cassandra query timing
- Presto query timing
- target source and table set
- anomaly computation timing
- upstream failure category

## 8.7 Configuration Requirements
Backend configuration should include:
- Cassandra host, port, username, password, keyspace
- Presto base URL / endpoint
- Presto user header value
- Presto basic-auth username and password
- Presto catalog names for federated analytics and Iceberg access
- Presto TLS certificate verification toggle for local/self-signed development only
- page-size defaults
- low-battery threshold
- anomaly threshold tuning values
- request timeout values

## 9. Frontend Technical Requirements

## 9.1 Application Structure
The frontend should implement:
- dashboard page
- filter toolbar
- device table or card list
- anomaly indicator components
- device detail panel/page
- alert list component
- readings time-series or recent-readings table
- baseline comparison summary component
- empty-state and error-state components

## 9.2 Data Fetching Requirements
Frontend should:
- load `/api/v1/sites` at startup for filter values
- load `/api/v1/devices` for dashboard page data
- debounce search/filter changes if free-text search is added later
- load `/api/v1/devices/{deviceId}/health` when a device is selected
- support loading and error states independently for list and detail views

## 9.3 UX Requirements
Frontend shall:
- visually distinguish `online`, `offline`, `degraded`, and `maintenance`
- visually distinguish anomaly status `anomalous`, `normal`, and `unknown`
- show stale/no-data messaging when no readings are present
- show baseline unavailable messaging when historical data is absent
- preserve filter state while navigating between dashboard and device detail
- support responsive layout for laptop-sized screens used in workshop demos

## 9.4 Rendering Requirements
Frontend should display:
- fleet list columns:
  - device ID
  - class
  - model
  - firmware version
  - status
  - site
  - zone
  - battery
  - signal
  - last heartbeat
  - anomaly state
  - open alert count
- device detail sections:
  - current state summary
  - recent readings
  - baseline by metric
  - anomaly explanations
  - open alerts

## 9.5 Frontend Error Handling
Frontend shall handle:
- invalid device route with not-found state
- API dependency errors with retry affordance
- empty datasets without broken UI
- partial enrichment cases where state loads but baseline fails

## 10. Data Contracts

## 10.1 Device Summary
A dashboard device row should contain:
- deviceId
- deviceType
- deviceClass
- model
- firmwareVersion
- status
- lastHeartbeat
- lastReadingValue
- batteryPercent
- signalStrengthDbm
- siteId
- zone
- anomalyStatus
- anomalyMetricCount
- highestAlertSeverity
- openAlertCount
- dataFreshness

## 10.2 Metric Baseline
A device metric baseline should contain:
- metricName
- baselineAvg
- baselineP95
- baselineMin
- baselineMax
- baselineStddev
- sampleCount
- baselineWindowDays

## 10.3 Device Metric Health
A metric health object should contain:
- metricName
- latestReading
- unit
- qualityCode
- recentReadingCount
- anomalyStatus
- anomalyReason
- baseline

## 11. Example Query Designs

## 11.1 Cassandra Device Lookup
```sql
SELECT device_id, device_type, device_class, model, firmware_version, status,
       last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
       site_id, zone, installed_at, updated_at
FROM iot.device_state_current
WHERE device_id = ?;
```

## 11.2 Cassandra Last-Hour Readings
```sql
SELECT device_id, reading_bucket_hour, reading_timestamp, metric_name,
       metric_value, unit, quality_code
FROM iot.readings_hot
WHERE device_id = ?
  AND reading_bucket_hour = ?;
```

Executed twice:
- once for current hour bucket
- once for previous hour bucket

## 11.3 Cassandra Alerts by Device
```sql
SELECT device_id, alert_id, raised_at, severity, alert_type, metric_name,
       metric_value, threshold_value, site_id, acknowledged
FROM iot.alerts_open
WHERE device_id = ?;
```

## 11.4 Iceberg 7-Day Baseline by Device
```sql
SELECT
  device_id,
  metric_name,
  AVG(avg_value)    AS baseline_avg,
  MAX(p95_value)    AS baseline_p95,
  MIN(min_value)    AS baseline_min,
  MAX(max_value)    AS baseline_max,
  AVG(stddev_value) AS baseline_stddev,
  SUM(sample_count) AS sample_count,
  COUNT(*)          AS baseline_window_hours_covered
FROM iceberg_data.iot.hourly_aggregates
WHERE device_id = ?
  AND hour_start >= current_timestamp - INTERVAL '7' DAY
GROUP BY device_id, metric_name;
```

## 12. Delivery Artifacts
This design is paired with:
- `requirements.md`
- `openapi.yaml`

The API contract in `openapi.yaml` should remain aligned with the endpoint and payload shapes described here.