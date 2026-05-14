-- ============================================================================
-- IoT Federation Queries
--
-- Cassandra: live device state, last-24h hot readings, open alerts.
-- Iceberg:   historical readings archive, hourly aggregates, daily site
--            summaries, failure history, firmware history, external
--            weather feed per site.
--
-- Prerequisites:
--   1. cassandra_catalog is registered in watsonx.data
--   2. ./setup/sample-data/load-iceberg-data.sh has run for iot
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Query 1 — Triage open alerts with historical baseline + weather
--
-- For every OPEN alert (Cassandra), compare the alerting metric value
-- against the device's own p95 baseline over the last 14 days (Iceberg
-- hourly_aggregates), AND the weather at the device's site at the time
-- the alert raised (Iceberg external feed).
-- Lets an operator classify an alert in one query as:
--   - real anomaly (value >> baseline, weather uncorrelated)
--   - seasonal/weather (value elevated but weather explains it)
--   - trend (value approaching baseline drift — look at recent days)
-- ----------------------------------------------------------------------------
WITH baseline_p95 AS (
    SELECT
        device_id,
        metric_name,
        MAX(p95_value) AS baseline_p95,
        AVG(avg_value) AS baseline_avg
    FROM iceberg_data.iot.hourly_aggregates
    WHERE hour_start >= current_date - INTERVAL '14' DAY
    GROUP BY device_id, metric_name
),
recent_weather AS (
    SELECT
        site_id,
        observation_time,
        temperature_c,
        humidity_pct,
        conditions,
        ROW_NUMBER() OVER (
            PARTITION BY site_id
            ORDER BY observation_time DESC
        ) AS rn
    FROM iceberg_data.iot.weather_by_location
)
SELECT
    a.severity,
    a.alert_type,
    d.device_class,
    d.model,
    a.site_id,
    d.zone,
    a.metric_name,
    a.metric_value                                     AS alert_value,
    ROUND(b.baseline_p95, 2)                           AS baseline_p95,
    ROUND(b.baseline_avg, 2)                           AS baseline_avg,
    ROUND((a.metric_value - b.baseline_p95) /
          NULLIF(b.baseline_p95, 0), 3)                AS pct_over_baseline,
    w.temperature_c                                    AS site_temp_c,
    w.humidity_pct                                     AS site_humidity,
    w.conditions                                       AS site_weather
FROM cassandra_catalog.iot.alerts_open a
JOIN cassandra_catalog.iot.device_state_current d
  ON d.device_id = a.device_id
LEFT JOIN baseline_p95 b
  ON b.device_id = CAST(a.device_id AS VARCHAR)
 AND b.metric_name = a.metric_name
LEFT JOIN recent_weather w
  ON w.site_id = a.site_id AND w.rn = 1
WHERE a.acknowledged = false
ORDER BY
    CASE a.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                    WHEN 'medium' THEN 3 ELSE 4 END,
    pct_over_baseline DESC NULLS LAST
LIMIT 25;


-- ----------------------------------------------------------------------------
-- Query 2 — Degraded devices with deteriorating trend
--
-- Devices currently marked DEGRADED (Cassandra) joined against the last
-- 14 days of hourly aggregates (Iceberg). Surface devices where the
-- trailing 3-day average is meaningfully worse than the trailing 14-day
-- average — a deterioration pattern worth dispatching on.
-- ----------------------------------------------------------------------------
WITH last_3d_avg AS (
    SELECT device_id, metric_name,
           AVG(avg_value) AS avg_3d
    FROM iceberg_data.iot.hourly_aggregates
    WHERE hour_start >= current_date - INTERVAL '3' DAY
    GROUP BY device_id, metric_name
),
last_14d_avg AS (
    SELECT device_id, metric_name,
           AVG(avg_value) AS avg_14d
    FROM iceberg_data.iot.hourly_aggregates
    WHERE hour_start >= current_date - INTERVAL '14' DAY
    GROUP BY device_id, metric_name
)
SELECT
    d.device_id,
    d.site_id,
    d.zone,
    d.device_class,
    d.status,
    d.battery_percent,
    last_3d.metric_name,
    ROUND(last_3d.avg_3d, 2)  AS avg_3d,
    ROUND(last_14d.avg_14d, 2) AS avg_14d,
    ROUND((last_3d.avg_3d - last_14d.avg_14d) /
          NULLIF(last_14d.avg_14d, 0), 3) AS delta_pct
FROM cassandra_catalog.iot.device_state_current d
JOIN last_3d_avg last_3d
  ON last_3d.device_id = CAST(d.device_id AS VARCHAR)
JOIN last_14d_avg last_14d
  ON last_14d.device_id = last_3d.device_id
 AND last_14d.metric_name = last_3d.metric_name
WHERE d.status IN ('degraded', 'maintenance')
  AND ABS((last_3d.avg_3d - last_14d.avg_14d) /
          NULLIF(last_14d.avg_14d, 0)) > 0.10
ORDER BY ABS(delta_pct) DESC
LIMIT 30;


-- ----------------------------------------------------------------------------
-- Query 3 — Site health: current vs. historical uptime
--
-- Per site: current device count & online rate (Cassandra) vs. the 30-day
-- rolling average uptime (Iceberg daily_site_summary). Spots sites that
-- have regressed below their own historical norm.
-- ----------------------------------------------------------------------------
WITH site_live AS (
    SELECT
        site_id,
        COUNT(*)                                          AS live_device_count,
        SUM(CASE WHEN status = 'online' THEN 1 ELSE 0 END) AS online_count,
        SUM(CASE WHEN status = 'degraded' THEN 1 ELSE 0 END) AS degraded_count,
        SUM(CASE WHEN status = 'offline' THEN 1 ELSE 0 END)  AS offline_count
    FROM cassandra_catalog.iot.device_state_current
    GROUP BY site_id
),
site_30d AS (
    SELECT
        site_id,
        AVG(uptime_pct)     AS avg_uptime_30d,
        AVG(avg_battery_pct) AS avg_battery_30d,
        SUM(alerts_critical) AS critical_alerts_30d
    FROM iceberg_data.iot.daily_site_summary
    WHERE summary_date >= current_date - INTERVAL '30' DAY
    GROUP BY site_id
)
SELECT
    l.site_id,
    l.live_device_count,
    l.online_count,
    l.degraded_count,
    l.offline_count,
    ROUND(100.0 * l.online_count / l.live_device_count, 2) AS current_online_pct,
    ROUND(h.avg_uptime_30d, 2)                             AS historical_uptime_30d,
    ROUND(h.avg_battery_30d, 2)                            AS historical_battery_30d,
    h.critical_alerts_30d
FROM site_live l
LEFT JOIN site_30d h ON h.site_id = l.site_id
ORDER BY (h.avg_uptime_30d - 100.0 * l.online_count / l.live_device_count) DESC
LIMIT 20;
