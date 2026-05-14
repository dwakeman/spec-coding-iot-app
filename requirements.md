# Sensor Health Dashboard Requirements

## 1. Overview

The Sensor Health Dashboard is a starter application for monitoring IoT device health using both hot operational data in Cassandra and historical analytical data in Iceberg. The application will help operations users quickly identify devices with unusual behavior by combining current device state and last-hour sensor readings with a 7-day historical baseline.

The dashboard is intended to support rapid triage of device health issues across sites, zones, and device classes. It focuses on visibility, anomaly flagging, and operational prioritization rather than automated remediation.

## 2. Goals

- Provide a per-device operational view of recent sensor behavior.
- Show last-hour readings for devices using hot data.
- Compare recent readings against a 7-day historical baseline.
- Flag anomalies and unusual device conditions for operator review.
- Surface enough device context to support initial triage.

## 3. Personas

### Persona 1: Operations Analyst
An operations analyst monitors fleets of IoT devices across multiple sites. They need to quickly identify devices that may be unhealthy, understand what changed, and decide whether to escalate for field or engineering action.

### Persona 2: Site Reliability Lead
A site reliability lead oversees device performance for one or more facilities. They need a site-level operational view and want to identify degraded patterns, batteries running low, connectivity issues, and devices whose recent readings differ materially from historical norms.

### Persona 3: Support Engineer
A support engineer investigates specific device issues after they have been flagged. They need recent readings, device state, open-alert context, and baseline comparison data to determine whether a flagged condition is likely real, transient, or environmentally influenced.

## 4. User Flows

### Flow 1: Review anomalous devices
1. The user opens the dashboard.
2. The application displays devices with current status and anomaly indicators.
3. The user sorts or filters to focus on anomalous, degraded, or offline devices.
4. The user selects a device.
5. The application shows the device's last-hour readings and a comparison against its 7-day baseline by metric.
6. The user decides whether the condition needs escalation or continued monitoring.

### Flow 2: Investigate a device in context
1. The user searches for a known device ID or browses by site.
2. The application displays current device state, including status, battery, signal strength, site, and zone.
3. The application shows recent readings and any anomaly flags for that device.
4. The application presents relevant open alerts if they exist.
5. The user uses the information to assess whether the device is behaving normally relative to recent history.

### Flow 3: Triage site health during active monitoring
1. The user filters the dashboard to a specific site.
2. The application lists devices at that site with recent health indicators.
3. The user identifies devices with unusual readings, low battery, weak signal, or degraded/offline status.
4. The user drills into one or more devices for detailed review.
5. The user prioritizes investigation based on severity and operational impact.

## 5. Functional Requirements

### REQ-001: Dashboard shall display current device inventory with health context
The application shall provide a dashboard view listing devices and key health fields derived from current operational data.

#### Acceptance Criteria
- The dashboard lists devices using current records from `device_state_current`.
- Each listed device includes, at minimum: `device_id`, `device_class`, `model`, `firmware_version`, `status`, `last_heartbeat`, `battery_percent`, `signal_strength_dbm`, `site_id`, and `zone`.
- The dashboard supports viewing devices across the fleet without requiring the user to inspect one device at a time.
- Devices with status values such as `offline`, `degraded`, or `maintenance` are visually distinguishable from `online` devices.

### REQ-002: Dashboard shall show last-hour readings per device
The application shall display recent sensor readings for each device using the hot-window readings data.

#### Acceptance Criteria
- For a selected device, the application retrieves readings from `readings_hot`.
- The application limits the displayed operational reading window to the most recent 60 minutes available.
- Each reading shown includes `reading_timestamp`, `metric_name`, `metric_value`, `unit`, and `quality_code`.
- Readings are displayed in descending timestamp order or in a time-series view that clearly preserves recency.
- If no readings are available in the last hour, the application shows a clear no-data state.

### REQ-003: Dashboard shall compare recent readings to a 7-day baseline
The application shall compare current or recent readings against a historical baseline derived from Iceberg analytical data.

#### Acceptance Criteria
- The baseline is derived from `hourly_aggregates`.
- The application uses a 7-day historical window for baseline comparison.
- For each metric shown for a device, the application presents at least one baseline statistic derived from historical data, such as average, p95, min/max range, or standard deviation.
- The application clearly labels which values are current/recent and which values represent the historical baseline.
- If baseline data is unavailable for a device or metric, the application indicates that baseline comparison is unavailable instead of showing misleading values.

### REQ-004: Dashboard shall flag anomalous readings versus baseline
The application shall identify and visibly flag devices or metrics whose recent readings differ materially from the 7-day baseline.

#### Acceptance Criteria
- The application computes anomaly status by comparing recent readings from `readings_hot` with baseline values from `hourly_aggregates`.
- At least one explicit anomaly rule is implemented and documented in the application behavior, such as exceeding a historical p95 threshold, deviating from average by a defined percentage, or exceeding a standard deviation threshold.
- An anomaly flag is associated with the relevant device and metric.
- The dashboard visually distinguishes anomalous devices from devices within normal bounds.
- The application does not mark a reading as anomalous when required comparison inputs are missing.

### REQ-005: Dashboard shall include open-alert context
The application shall surface active alert information to support device triage.

#### Acceptance Criteria
- For devices with active alerts, the application retrieves data from `alerts_open`.
- The application shows alert severity, alert type, raised time, metric name, and metric value when available.
- Devices with one or more unacknowledged alerts are identifiable in the dashboard view.
- The device detail view shows whether alerts are acknowledged or unacknowledged when that information is present.

### REQ-006: Dashboard shall support filtering and prioritization
The application shall help users narrow the device list to operationally relevant subsets.

#### Acceptance Criteria
- Users can filter the dashboard by `site_id`.
- Users can filter the dashboard by device `status`.
- Users can filter or focus on anomalous devices.
- Users can sort or prioritize devices using at least one operational signal such as anomaly state, alert severity, battery level, or signal strength.
- Filtering updates the visible device list without requiring a manual page refresh.

### REQ-007: Dashboard shall provide device detail context for investigation
The application shall offer a drill-down view for a single device.

#### Acceptance Criteria
- Selecting a device opens a detail view or expanded panel for that device.
- The detail view includes current device state from `device_state_current`.
- The detail view includes the last-hour readings from `readings_hot`.
- The detail view includes the 7-day baseline comparison for each displayed metric.
- The detail view includes open-alert context when alerts exist for the device.

### REQ-008: Dashboard shall handle data freshness and missing data clearly
The application shall communicate when data may be stale, incomplete, or absent.

#### Acceptance Criteria
- The application shows the most recent heartbeat timestamp for each device.
- The application indicates when a device has no recent readings in the last hour.
- The application indicates when historical baseline data is not available.
- The application does not display blank tables or unexplained empty visualizations when source data is missing.
- The application uses clear user-facing messaging for stale or unavailable data states.

### REQ-009: Dashboard shall support federated hot-plus-cold data access
The application shall be designed around reading operational and analytical data together.

#### Acceptance Criteria
- The application uses Cassandra-backed operational tables for current state, recent readings, and open alerts.
- The application uses Iceberg-backed data for historical baseline comparison.
- The application may access hot operational data directly from Cassandra.
- The application uses Presto in watsonx.data for Iceberg access and for any federated Cassandra/Iceberg analytical queries.
- The user experience presents hot and cold data as a unified workflow rather than separate disconnected screens.
- The baseline comparison and anomaly flagging cannot rely solely on hot operational tables.

## 6. Non-Functional Requirements

### REQ-010: The application shall present actionable information for rapid triage
The application shall emphasize clarity and operational usability for first-level investigation.

#### Acceptance Criteria
- The primary dashboard view highlights anomalous or unhealthy devices without requiring deep navigation.
- Labels and field names use operator-friendly wording.
- Visual indicators for anomaly or degraded health are consistently applied across list and detail views.
- The dashboard can be understood by a first-time operator without requiring knowledge of the underlying schema.

### REQ-011: The application shall be suitable as a starter application
The application shall remain appropriately scoped for a workshop-style starter implementation.

#### Acceptance Criteria
- The requirements can be implemented with the existing IoT sample tables described in the schema documentation.
- The application does not require creating new upstream data pipelines or modifying provided source datasets.
- The application focuses on read-oriented workflows over complex administrative workflows.
- The application scope remains centered on sensor health visibility and baseline comparison.

## 7. Explicitly Out of Scope

The following items are explicitly out of scope for this starter application:

- Predictive maintenance modeling using `failure_history`.
- Firmware rollout management or deployment controls using `firmware_deployment_history`.
- Maintenance scheduling or outage planning using `maintenance_windows`.
- Weather-correlation analysis using `weather_by_location`, beyond any future extension.
- Write-back workflows such as acknowledging alerts, editing device metadata, or changing device status.
- Automated remediation actions such as rebooting devices or issuing device commands.
- Long-term historical exploration beyond the dashboard’s 7-day baseline comparison use case.
- Advanced multi-site executive reporting based on `daily_site_summary`.
- Authentication, authorization, and role-based access control design.
- Notification delivery via email, SMS, pager, or incident management tools.
- ML model training, scoring pipelines, or root-cause inference.

## 8. Notes and Assumptions

- Hot operational device state is sourced from Cassandra tables including `device_state_current`, `readings_hot`, and `alerts_open`.
- Historical baseline data is sourced from Iceberg, primarily `hourly_aggregates`.
- Hot operational reads may use direct Cassandra access.
- Iceberg access uses the Presto engine in watsonx.data.
- Federated Cassandra/Iceberg analytical queries, when needed, use Presto in watsonx.data.
- The intended baseline comparison window is 7 days, even though sample federation queries also demonstrate 14-day and 30-day analytical comparisons for related use cases.
- A device may expose one or more metrics, and anomaly evaluation may occur at the metric level.
- Quality codes on readings should be shown to users so suspect or bad readings are not interpreted as equivalent to good readings without context.