# Sensor Health Dashboard Implementation Plan

## Planning Principles

- Build to `requirements.md` and `design.md` only.
- Use direct Cassandra access for hot operational reads.
- Use Presto in watsonx.data for Iceberg reads and selective federated Cassandra/Iceberg analytics.
- Preserve source-of-truth semantics:
  - hot operational data comes from Cassandra tables
  - analytical baseline data comes from Iceberg tables
- Use direct reads from hot Cassandra tables for operational endpoints:
  - `iot.device_state_current`
  - `iot.readings_hot`
  - `iot.alerts_open`
- Use federated Iceberg/Cassandra access patterns for analytics and anomaly workflows when needed:
  - compare Cassandra hot readings with `iceberg_data.iot.hourly_aggregates`
  - optionally join Cassandra-backed and Iceberg-backed datasets in Presto for selective analytical queries
- Keep implementation read-only.
- Keep test coverage traceable to requirement IDs.

---

## Phase 0 - Project Setup and Delivery Strategy

- [ ] Confirm application stack and project layout for frontend and backend.
- [ ] Create backend service skeleton with REST routing for all endpoints in `openapi.yaml`.
- [ ] Create frontend application skeleton with dashboard page, detail view shell, and shared API client.
- [ ] Add environment configuration for:
  - Cassandra host
  - Cassandra port
  - Cassandra username
  - Cassandra password
  - Cassandra keyspace
  - Presto endpoint
  - Presto bearer token
  - Presto catalog names for Iceberg and optional federated analytics
  - page-size defaults
  - anomaly thresholds
  - low-battery threshold
  - request timeouts
- [ ] Add shared domain model package or module for:
  - device summary
  - reading
  - baseline
  - alert
  - metric health
  - error response
- [ ] Add linting, formatting, and test tooling.
- [ ] Add request logging, request ID propagation, and error middleware.

### Tests
- [ ] Verify app boots with required environment variables.
- [ ] Verify misconfiguration surfaces startup validation errors.
- [ ] Verify API returns standardized error shape for unhandled failures.

### Requirement Trace
- REQ-010
- REQ-011

---

## Phase 1 - Data Access Foundation

### Goal
Create a mixed data access layer that uses direct Cassandra for hot operational reads and Presto for Iceberg-backed analytics and optional federated analytics.

### Tasks
- [ ] Implement a shared Cassandra client abstraction for operational reads.
- [ ] Implement Cassandra execution helpers for:
  - prepared statements
  - timeout handling
  - retry policy for transient connection failures
  - row-to-domain mapping
- [ ] Implement a shared Presto client abstraction for authenticated analytical SQL execution.
- [ ] Implement Presto execution helpers for:
  - parameter binding / safe interpolation strategy
  - timeout handling
  - retry policy for transient upstream failures
  - row-to-domain mapping
- [ ] Implement repository modules:
  - `DeviceStateRepository`
  - `ReadingsRepository`
  - `AlertsRepository`
  - `BaselineRepository`
- [ ] Encode source-specific query rules in repositories:
  - `device_state_current` queried from Cassandra `iot.device_state_current`
  - `readings_hot` queried from Cassandra `iot.readings_hot`
  - `alerts_open` queried from Cassandra `iot.alerts_open`
  - `hourly_aggregates` queried through Presto from `iceberg_data.iot.hourly_aggregates`
- [ ] Normalize `device_id` handling across sources:
  - UUID in API/domain
  - UUID in Cassandra driver calls
  - string/SQL-compatible comparisons in Presto queries
- [ ] Implement mapping for decimal/timestamp values into JSON-safe types.

### Data Read Rules
- [ ] Hot reads must come directly from Cassandra tables, not from Iceberg substitutes.
- [ ] Baseline and anomaly analytics must use Iceberg `hourly_aggregates`.
- [ ] Federated analytical queries may combine Cassandra-backed hot data with Iceberg baseline data only for selective device scopes.

### Tests
- [ ] Repository unit tests for row mapping of each source table.
- [ ] Query-builder tests for:
  - Cassandra device lookup
  - Cassandra last-hour readings using current + previous bucket
  - Cassandra alerts by device
  - Presto 7-day baseline SQL
- [ ] Integration tests against mocked/stubbed Cassandra and Presto responses for success, timeout, empty result, and upstream failure cases.
- [ ] Test that hot-data repositories use Cassandra clients directly.
- [ ] Test that baseline/analytical repositories use Presto.

### Requirement Trace
- REQ-002
- REQ-003
- REQ-005
- REQ-009
- REQ-011

---

## Phase 2 - Device State and Fleet Listing API

### Goal
Implement the dashboard list and device metadata endpoints.

### Tasks
- [ ] Implement `GET /api/v1/devices`.
- [ ] Implement `GET /api/v1/devices/{deviceId}`.
- [ ] Implement `GET /api/v1/sites`.
- [ ] Add request validation for:
  - `deviceId`
  - `siteId`
  - `status`
  - `page`
  - `pageSize`
  - `sort`
  - `anomalyStatus`
- [ ] Implement pagination defaults and limits.
- [ ] Implement dashboard sort support for allowed fields only.
- [ ] Implement device-state query filtering by:
  - site
  - status
- [ ] Implement site list extraction from current device state.
- [ ] Add data freshness classification from `last_heartbeat`.

### Data Access Notes
- [ ] `GET /api/v1/devices` must read current inventory from Cassandra `iot.device_state_current`.
- [ ] `GET /api/v1/devices/{deviceId}` must read current device state from Cassandra `iot.device_state_current`.
- [ ] `GET /api/v1/sites` should derive site values from current device state rather than analytical rollups.

### Tests
- [ ] API tests for valid and invalid UUID handling.
- [ ] API tests for site and status filters.
- [ ] API tests for pagination metadata.
- [ ] API tests for unsupported sort returning `422`.
- [ ] API tests for `404` when device does not exist.
- [ ] API tests that required device fields are present in list and detail responses.
- [ ] API tests that `offline`, `degraded`, and `maintenance` statuses are surfaced distinctly.

### Requirement Trace
- REQ-001
- REQ-006
- REQ-008
- REQ-010
- REQ-011

---

## Phase 3 - Last-Hour Readings API

### Goal
Implement operational recent-reading retrieval aligned to the actual hot-table partitioning.

### Tasks
- [ ] Implement `GET /api/v1/devices/{deviceId}/readings`.
- [ ] Build bucket calculation helper for:
  - current hour bucket
  - previous hour bucket
- [ ] Query Cassandra `iot.readings_hot` for both buckets.
- [ ] Merge and filter readings to last 60 minutes.
- [ ] Sort readings by descending `reading_timestamp`.
- [ ] Group readings by `metric_name` where needed for higher-level services.
- [ ] Surface no-data condition when no recent readings are found.
- [ ] Preserve `quality_code` in all response models.

### Data Access Notes
- [ ] Do not use Iceberg `readings_archive` for last-hour operational reads.
- [ ] Keep the access pattern aligned to Cassandra partition semantics for direct hot-data reads.

### Tests
- [ ] Unit tests for bucket calculation around hour boundaries.
- [ ] Unit tests for merge/filter logic across two bucket queries.
- [ ] API tests returning readings within the last 60 minutes only.
- [ ] API tests verifying fields:
  - `reading_timestamp`
  - `metric_name`
  - `metric_value`
  - `unit`
  - `quality_code`
- [ ] API tests for no-data response semantics.
- [ ] API tests verifying descending timestamp ordering.

### Requirement Trace
- REQ-002
- REQ-007
- REQ-008
- REQ-009

---

## Phase 4 - Baseline and Analytical Comparison API

### Goal
Implement 7-day baseline retrieval from Iceberg and support analytical comparison against hot readings.

### Tasks
- [ ] Implement `GET /api/v1/devices/{deviceId}/baseline`.
- [ ] Implement baseline aggregation query against `iceberg_data.iot.hourly_aggregates`.
- [ ] Aggregate baseline metrics per `metric_name`:
  - average average
  - max p95
  - min min
  - max max
  - average stddev
  - sample count
  - hours covered
- [ ] Label baseline window metadata in the response.
- [ ] Handle baseline-not-available conditions cleanly.
- [ ] Define a federated analytical query option for selective device scopes where combining hot readings and baseline in one Presto query is beneficial.
- [ ] Document when to prefer:
  - separate hot + cold queries with application-side join
  - selective federated Presto query for analytics

### Data Access Notes
- [ ] Historical baseline must come from Iceberg `hourly_aggregates`.
- [ ] Analytics may combine:
  - hot readings from Cassandra `iot.readings_hot`
  - device context from Cassandra `iot.device_state_current`
  - baseline from `iceberg_data.iot.hourly_aggregates`
- [ ] Federated analytical queries must be limited to selected devices or paginated subsets to avoid broad scans.

### Tests
- [ ] Unit tests for baseline aggregation mapping.
- [ ] API tests verifying default baseline window of 7 days.
- [ ] API tests verifying baseline response contains at least one historical statistic per metric.
- [ ] API tests for missing baseline rows.
- [ ] Query tests confirming analytics use Iceberg baseline data, not only hot data.
- [ ] Test selective federated query behavior for a limited set of device IDs.

### Requirement Trace
- REQ-003
- REQ-008
- REQ-009
- REQ-011

---

## Phase 5 - Alerts API and Alert Enrichment

### Goal
Implement device alert retrieval and dashboard alert summaries.

### Tasks
- [ ] Implement `GET /api/v1/devices/{deviceId}/alerts`.
- [ ] Query Cassandra `iot.alerts_open` by `device_id`.
- [ ] Map alert fields:
  - alert ID
  - raised time
  - severity
  - alert type
  - metric name
  - metric value
  - threshold value
  - site ID
  - acknowledged
- [ ] Add alert summary enrichment for dashboard rows:
  - open alert count
  - highest alert severity
- [ ] Keep fleet-level enrichment page-scoped only.

### Data Access Notes
- [ ] Alert reads are hot operational reads and must come from Cassandra-backed `alerts_open`.
- [ ] Do not substitute analytical alert counts from `daily_site_summary` for device alert detail.

### Tests
- [ ] API tests for empty alert list response.
- [ ] API tests verifying alert fields and acknowledged status.
- [ ] API tests verifying dashboard alert count enrichment.
- [ ] API tests verifying severity rollup logic.
- [ ] Tests ensuring enrichment is limited to currently requested device page.

### Requirement Trace
- REQ-005
- REQ-007
- REQ-008
- REQ-009

---

## Phase 6 - Anomaly Detection Service

### Goal
Implement per-metric and per-device anomaly evaluation based on hot readings plus 7-day baseline.

### Tasks
- [ ] Implement anomaly evaluation service using:
  - latest recent reading from hot data
  - baseline average
  - baseline p95
  - baseline stddev
- [ ] Implement documented starter rules from `design.md`:
  - latest reading > baseline p95
  - or deviation > `max(2 * stddev, 10% of baseline average)`
- [ ] Exclude `quality_code = bad` from anomaly computation while still exposing the reading.
- [ ] Mark anomaly state as `unknown` when baseline inputs are unavailable.
- [ ] Roll up device anomaly state from per-metric anomalies and alert context.
- [ ] Support anomaly filtering on dashboard endpoint.

### Data Access Notes
- [ ] Anomaly detection is an analytical workflow using:
  - direct Cassandra hot readings for recent values
  - Iceberg-backed baseline data for historical comparison
- [ ] Prefer application-side computation after selective reads.
- [ ] Consider federated Presto analytical SQL only for tightly bounded dashboard pages or selected device IDs.

### Tests
- [ ] Unit tests for normal / anomalous / unknown metric outcomes.
- [ ] Unit tests for bad-quality reading exclusion.
- [ ] Unit tests for device rollup severity logic.
- [ ] API tests verifying anomalous devices are visibly represented in response payloads.
- [ ] API tests verifying metrics are not marked anomalous when required comparison inputs are missing.
- [ ] API tests verifying anomaly filter behavior on `GET /api/v1/devices`.

### Requirement Trace
- REQ-004
- REQ-006
- REQ-008
- REQ-009
- REQ-010

---

## Phase 7 - Composite Device Health Endpoint

### Goal
Implement the single device-health endpoint used by the detail experience.

### Tasks
- [ ] Implement `GET /api/v1/devices/{deviceId}/health`.
- [ ] Compose:
  - current device state
  - recent readings
  - baseline metrics
  - open alerts
  - metric health objects
  - device health summary
- [ ] Ensure partial-source behavior is handled gracefully:
  - state present, baseline unavailable
  - state present, readings unavailable
  - alerts unavailable due to upstream issues
- [ ] Return consistent error behavior for:
  - malformed UUID
  - not found
  - upstream Presto/source failure

### Tests
- [ ] API tests for fully populated composite response.
- [ ] API tests for partial enrichment with baseline unavailable.
- [ ] API tests for partial enrichment with no recent readings.
- [ ] API tests for empty alerts array.
- [ ] API tests for `404` and `502/503` behavior.

### Requirement Trace
- REQ-002
- REQ-003
- REQ-004
- REQ-005
- REQ-007
- REQ-008
- REQ-009
- REQ-010

---

## Phase 8 - Frontend Dashboard Experience

### Goal
Build the main operational dashboard aligned to personas and user flows.

### Tasks
- [ ] Implement dashboard page layout.
- [ ] Implement filter toolbar for:
  - site
  - status
  - anomaly state
- [ ] Implement fleet device table or cards with:
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
- [ ] Implement list sorting UX aligned to supported backend sort fields.
- [ ] Implement visual status badges for:
  - online
  - offline
  - degraded
  - maintenance
- [ ] Implement anomaly badges for:
  - anomalous
  - normal
  - unknown
- [ ] Implement stale/no-data indicators.
- [ ] Preserve filter state during navigation.

### Tests
- [ ] Component tests for filter interactions and query parameter propagation.
- [ ] Component tests for status/anomaly badge rendering.
- [ ] Component tests for empty state and error state rendering.
- [ ] UI tests for selecting a device from dashboard and opening detail view.
- [ ] UI tests for maintaining filter state while navigating.

### Requirement Trace
- REQ-001
- REQ-006
- REQ-008
- REQ-010

---

## Phase 9 - Frontend Device Detail Experience

### Goal
Build the drill-down device investigation workflow.

### Tasks
- [ ] Implement device detail panel/page.
- [ ] Render current device state summary.
- [ ] Render recent readings table or chart.
- [ ] Render baseline-by-metric summary.
- [ ] Render anomaly explanations by metric.
- [ ] Render open alerts section.
- [ ] Render clear empty states for:
  - no recent readings
  - no alerts
  - no baseline available
- [ ] Add retry affordances for transient API failures.

### Tests
- [ ] Component tests for rendering device state summary fields.
- [ ] Component tests for readings rendering and ordering.
- [ ] Component tests for baseline unavailable messaging.
- [ ] Component tests for alert rendering.
- [ ] UI tests for full device investigation flow from dashboard to detail.

### Requirement Trace
- REQ-002
- REQ-003
- REQ-004
- REQ-005
- REQ-007
- REQ-008
- REQ-010

---

## Phase 10 - Error Handling, Observability, and Performance Hardening

### Goal
Complete operational readiness for starter-scope delivery.

### Tasks
- [ ] Standardize API error payloads for:
  - `400`
  - `404`
  - `422`
  - `502`
  - `503`
- [ ] Add request-level logging for:
  - request ID
  - endpoint
  - filters
  - query timing
  - target catalog/table set
  - anomaly computation timing
- [ ] Add timeout protection and retry policy for Cassandra and Presto calls.
- [ ] Add pagination guardrails to prevent oversized analytical workloads.
- [ ] Review selective federated query use to ensure no wide hot-source scans.
- [ ] Validate that all implemented functionality remains read-only.

### Tests
- [ ] API tests for every documented error response.
- [ ] Observability tests or assertions for request logging hooks.
- [ ] Performance test for default dashboard page target.
- [ ] Performance test for device detail target.
- [ ] Regression test ensuring no write operations are issued.

### Requirement Trace
- REQ-008
- REQ-010
- REQ-011

---

## Requirement-to-Test Matrix

### REQ-001
- [ ] Test dashboard list returns current device inventory fields from `device_state_current`.
- [ ] Test device detail returns current device state.
- [ ] Test unhealthy statuses are distinct in API and UI.

### REQ-002
- [ ] Test last-hour readings endpoint reads from `readings_hot`.
- [ ] Test only most recent 60 minutes are shown.
- [ ] Test reading fields and descending ordering.
- [ ] Test no-data state.

### REQ-003
- [ ] Test baseline endpoint uses `hourly_aggregates`.
- [ ] Test default 7-day window.
- [ ] Test baseline stats appear per metric.
- [ ] Test baseline unavailable state.

### REQ-004
- [ ] Test anomaly computation against documented rules.
- [ ] Test anomaly flags on metric and device outputs.
- [ ] Test missing baseline inputs yield `unknown`, not false anomaly.

### REQ-005
- [ ] Test alerts endpoint reads from `alerts_open`.
- [ ] Test alert fields and acknowledged state.
- [ ] Test dashboard alert indicators.

### REQ-006
- [ ] Test filtering by `site_id`.
- [ ] Test filtering by `status`.
- [ ] Test anomaly filtering.
- [ ] Test supported sort behavior and unsupported sort errors.

### REQ-007
- [ ] Test detail endpoint/view contains state, last-hour readings, baseline, and alerts.

### REQ-008
- [ ] Test stale heartbeat and no-recent-readings states.
- [ ] Test missing baseline messaging.
- [ ] Test empty states are explicit, not blank.

### REQ-009
- [ ] Test hot operational reads come directly from Cassandra-backed tables.
- [ ] Test analytical baseline reads come from Iceberg through Presto.
- [ ] Test analytical comparison combines hot and cold data.
- [ ] Test federated analytics, when used, run through Presto.

### REQ-010
- [ ] Test primary dashboard highlights anomalous/unhealthy devices.
- [ ] Test labels and visual states are consistent across list and detail views.

### REQ-011
- [ ] Test implementation stays within read-only starter scope.
- [ ] Test only documented workshop tables are required.
- [ ] Test no extra ingestion or pipeline dependencies are introduced.

---

## Final Delivery Checklist

- [ ] Backend endpoints implemented per `openapi.yaml`.
- [ ] Frontend flows implemented for dashboard and device detail.
- [ ] Direct Cassandra hot-data access path implemented.
- [ ] Hot reads sourced from Cassandra-backed tables.
- [ ] Analytics sourced from Iceberg and selective federated Presto queries.
- [ ] Requirement traceability retained in tests.
- [ ] Out-of-scope items not implemented.
- [ ] Documentation updated if implementation decisions differ from plan.