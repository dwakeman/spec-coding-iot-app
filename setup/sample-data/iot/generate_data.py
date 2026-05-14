#!/usr/bin/env python3
"""
IoT Sample Data Generator

Cassandra holds current device state, last 24h of sensor readings, open alerts,
last-7d device events, and current topology. Iceberg holds the historical
readings archive, hourly aggregates, per-site daily rollups, failure training
labels, firmware deployment history, maintenance windows, and an external
weather feed.

Predictive-maintenance signals
------------------------------
Sensor data and failure history are coupled so the predictive-maintenance
workshop can find a real signal:

  Pre-failure drift  A subset of devices in the readings_archive sample
                     experience a "drift event" — a failure 1–5 days ago
                     preceded by a 72h window in which the primary metric
                     trends out of normal range, sharpening to a push past
                     the typical high in the final 12h. These show up as
                     `failure_history` rows with `predicted_12h_prior=True`.

  Diurnal cycle      `readings_archive` and `hourly_aggregates` follow a
                     24h cycle per device class — energy/temperature/
                     occupancy peak in the afternoon, humidity dips during
                     business hours — instead of uniform random.

  Firmware regression Devices on firmware "1.4.0" fail at roughly 3× the
                     baseline rate, so `failure_history JOIN
                     firmware_deployment_history` shows a real cohort.
"""
from __future__ import annotations

import csv
import math
import random
import sys
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _arrow_helpers import write_parquet  # type: ignore  # noqa: E402

# Sizing — tuned for fast Iceberg ingest (each INSERT batch < 1MB query text).
DEVICES_COUNT = 300
SITES_COUNT = 15

READINGS_HOT_DEVICES = 80
READINGS_HOT_PER_DEVICE = 24
ALERTS_OPEN_COUNT = 45
RECENT_EVENTS_COUNT = 800

ARCHIVE_DEVICES = 25          # sample for historical readings
ARCHIVE_DAYS = 7              # 7d × 12 half-hour slots × 2 metrics = 4200/dev-class, ~5K rows
ARCHIVE_SLOTS_PER_DAY = 12
HOURLY_AGG_DEVICES = 30
HOURLY_AGG_DAYS = 14          # 30 × 14 × 24 × 2 = ~20K rows → 8 batches
DAILY_SUMMARY_DAYS = 60
FAILURE_COUNT = 80
FIRMWARE_PER_DEVICE = 2
MAINTENANCE_WINDOWS = 50
WEATHER_DAYS = 14             # 15 sites × 14 × 24 = ~5K rows


OUTPUT_DIR = Path(__file__).parent / "generated_data"
CASS_DIR = OUTPUT_DIR / "cassandra"
ICEBERG_DIR = OUTPUT_DIR / "iceberg"

TODAY = date(2026, 4, 23)
NOW_TS = datetime(2026, 4, 23, 9, 0, 0)

DEVICE_CLASSES = {
    # class -> (metric_names, unit, (min, max) typical range)
    "temperature": [("ambient_c", "C", -10.0, 45.0), ("surface_c", "C", -10.0, 80.0)],
    "humidity":    [("relative_humidity", "%", 5.0, 95.0), ("dew_point_c", "C", -15.0, 30.0)],
    "pressure":    [("pressure_hpa", "hPa", 950.0, 1050.0), ("delta_hpa", "hPa", -5.0, 5.0)],
    "vibration":   [("accel_rms", "g", 0.0, 3.0), ("peak_g", "g", 0.0, 5.0)],
    "energy":      [("active_power_kw", "kW", 0.0, 250.0), ("voltage", "V", 210.0, 245.0)],
    "presence":    [("occupancy_pct", "%", 0.0, 100.0), ("count", "n", 0, 300)],
}
DEVICE_TYPES = ["sensor", "gateway", "actuator", "camera"]
FAILURE_TYPES = ["hardware", "firmware", "network", "power", "sensor_drift"]
FIRMWARE_VERSIONS = ["1.2.0", "1.3.1", "1.4.0", "1.5.2", "2.0.0"]
ROLLOUT_WAVES = ["canary", "early", "general"]
CONDITIONS = ["clear", "cloudy", "rain", "snow", "storm"]
CONDITION_WEIGHTS = [0.45, 0.30, 0.15, 0.05, 0.05]
EVENT_TYPES = ["boot", "shutdown", "config_change", "command", "error"]
ALERT_SEVERITIES = ["low", "medium", "high", "critical"]
ALERT_SEVERITY_WEIGHTS = [0.45, 0.30, 0.18, 0.07]
ALERT_TYPES = ["threshold", "anomaly", "offline", "battery_low"]

random.seed(42)

# --- predictive-maintenance signal overlays (see module docstring) -------

# device_class -> (peak_hour_24h, amplitude_fraction_of_range)
DIURNAL_PROFILES = {
    "temperature": (15, 0.50),  # peaks mid-afternoon
    "humidity":    ( 5, 0.30),  # peaks pre-dawn (inverse of temp)
    "pressure":    (12, 0.05),  # essentially flat
    "vibration":   (14, 0.40),  # peaks during business hours
    "energy":      (15, 0.60),  # peaks afternoon load
    "presence":    (12, 0.80),  # peaks midday
}

DRIFT_FIRMWARE = "1.4.0"
FIRMWARE_REGRESSION_FACTOR = 3.0
DRIFT_EVENT_COUNT = 12          # ~half of ARCHIVE_DEVICES
DRIFT_WINDOW_HOURS = 72         # window over which the metric trends abnormal
DRIFT_FINAL_PUSH_HOURS = 12     # within this final window, push past typical high

# Populated by _setup_drift_events() before readings_archive / failure_history.
DRIFT_EVENTS: dict[str, tuple[datetime, int]] = {}
_iot_signal_rng = random.Random(20260423)

def _diurnal_target(dclass: str, hour: int, lo: float, hi: float) -> float:
    peak, amp = DIURNAL_PROFILES.get(dclass, (12, 0.10))
    mid = (lo + hi) / 2.0
    half_range = (hi - lo) / 2.0
    return mid + half_range * amp * math.cos(2 * math.pi * (hour - peak) / 24.0)

def _drift_factor(t: datetime, failure_ts: datetime) -> float:
    """0 outside [failure-72h, failure]; ramps 0→1 across [72h..12h] before
    failure; 1.0→1.5 across the final 12h to push the metric above typical."""
    if t > failure_ts:
        return 0.0
    hours_before = (failure_ts - t).total_seconds() / 3600.0
    if hours_before > DRIFT_WINDOW_HOURS:
        return 0.0
    if hours_before > DRIFT_FINAL_PUSH_HOURS:
        return (DRIFT_WINDOW_HOURS - hours_before) / (DRIFT_WINDOW_HOURS - DRIFT_FINAL_PUSH_HOURS)
    return 1.0 + (DRIFT_FINAL_PUSH_HOURS - hours_before) / DRIFT_FINAL_PUSH_HOURS * 0.5

def _setup_drift_events(archive_sample: list[dict]) -> None:
    """Pick devices from the readings_archive sample to fail in the next 5
    days with a visible 72h pre-failure drift in metric index 0."""
    DRIFT_EVENTS.clear()
    n = min(DRIFT_EVENT_COUNT, len(archive_sample))
    chosen = _iot_signal_rng.sample(archive_sample, n)
    for d in chosen:
        days_back = _iot_signal_rng.randint(1, 5)
        hour = _iot_signal_rng.randint(0, 23)
        failure_ts = datetime.combine(TODAY - timedelta(days=days_back),
                                      datetime.min.time()) + timedelta(hours=hour)
        DRIFT_EVENTS[d["device_id"]] = (failure_ts, 0)

def _print_drift_calendar(devices_by_id: dict[str, dict]) -> None:
    print("Encoded drift events (device → failure timestamp / class):")
    for did, (ts, _idx) in DRIFT_EVENTS.items():
        d = devices_by_id[did]
        print(f"  {did[:8]}…  {ts.isoformat()}  {d['device_class']:<11}  fw={d['firmware_version']}")

# --- helpers --------------------------------------------------------------
def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)

def pick(pool, weights=None):
    return random.choices(pool, weights=weights, k=1)[0] if weights else random.choice(pool)

# --- pools ----------------------------------------------------------------
def generate_sites():
    sites = []
    for i in range(SITES_COUNT):
        sites.append({
            "site_id": f"SITE-{1000 + i}",
            "name": f"Site {i+1}",
            "city": pick(["Chicago", "Dallas", "Denver", "Atlanta", "Seattle", "Boston", "Miami",
                          "Portland", "Phoenix", "Minneapolis", "Detroit", "Kansas City"]),
            "country": "USA",
        })
    return sites

def generate_devices(sites):
    devices = []
    class_keys = list(DEVICE_CLASSES.keys())
    gateways_by_site = defaultdict(list)
    for site in sites:
        # 3-5 gateways per site
        for _ in range(random.randint(3, 5)):
            gateways_by_site[site["site_id"]].append(str(uuid.uuid4()))
    for i in range(DEVICES_COUNT):
        site = pick(sites)
        gateway_id = pick(gateways_by_site[site["site_id"]])
        dclass = pick(class_keys)
        dtype = "sensor" if random.random() < 0.75 else pick(DEVICE_TYPES[1:])
        installed = NOW_TS - timedelta(days=random.randint(30, 1200))
        fw = pick(FIRMWARE_VERSIONS)
        status = pick(["online", "online", "online", "online", "offline", "degraded", "maintenance"])
        last_beat = NOW_TS - timedelta(minutes=random.randint(0, 30 if status == "online" else 60*24*7))
        devices.append({
            "device_id": str(uuid.uuid4()),
            "device_type": dtype,
            "device_class": dclass,
            "model": f"{dclass[:4].upper()}-{random.randint(100,999)}",
            "firmware_version": fw,
            "status": status,
            "last_heartbeat": last_beat,
            "last_reading_value": Decimal(str(round(random.uniform(*_rng(dclass, 0)[:2]), 2))),
            "battery_percent": random.randint(10, 100),
            "signal_strength_dbm": -random.randint(40, 90),
            "site_id": site["site_id"],
            "zone": pick(["Zone-A", "Zone-B", "Zone-C", "Zone-D", "Floor-1", "Floor-2", "Roof", "Basement"]),
            "installed_at": installed,
            "updated_at": NOW_TS - timedelta(minutes=random.randint(0, 720)),
            "gateway_id": gateway_id,
            "ip_address": f"10.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(1,254)}",
        })
    return devices

def _rng(dclass, metric_idx):
    """Return (min_typical, max_typical, metric_name, unit) for a device_class and metric index."""
    metrics = DEVICE_CLASSES[dclass]
    name, unit, lo, hi = metrics[metric_idx]
    return (lo, hi, name, unit)

# --- Cassandra hot tables -------------------------------------------------
def generate_readings_hot(devices):
    rows = []
    sampled = random.sample([d for d in devices if d["status"] == "online"],
                             min(READINGS_HOT_DEVICES, sum(1 for d in devices if d["status"]=="online")))
    for d in sampled:
        metrics = DEVICE_CLASSES[d["device_class"]]
        for m_idx, (mname, unit, lo, hi) in enumerate(metrics):
            for k in range(READINGS_HOT_PER_DEVICE):
                t = NOW_TS - timedelta(minutes=random.randint(0, 1440))
                hour_bucket = t.replace(minute=0, second=0, microsecond=0)
                val = round(random.uniform(lo, hi), 2)
                rows.append({
                    "device_id": d["device_id"],
                    "reading_bucket_hour": hour_bucket,
                    "reading_timestamp": t,
                    "metric_name": mname,
                    "metric_value": Decimal(str(val)),
                    "unit": unit,
                    "quality_code": pick(["good","good","good","good","suspect","bad"]),
                })
    return rows

def generate_alerts_open(devices):
    rows = []
    for _ in range(ALERTS_OPEN_COUNT):
        d = pick(devices)
        metrics = DEVICE_CLASSES[d["device_class"]]
        mname, unit, lo, hi = metrics[0]
        val = round(random.uniform(lo, hi * 1.5), 2)
        rows.append({
            "device_id": d["device_id"],
            "alert_id": str(uuid.uuid4()),
            "raised_at": NOW_TS - timedelta(minutes=random.randint(5, 1440)),
            "severity": pick(ALERT_SEVERITIES, ALERT_SEVERITY_WEIGHTS),
            "alert_type": pick(ALERT_TYPES),
            "metric_name": mname,
            "metric_value": Decimal(str(val)),
            "threshold_value": Decimal(str(round(hi, 2))),
            "site_id": d["site_id"],
            "acknowledged": random.random() < 0.10,
        })
    return rows

def generate_device_events_recent(devices):
    rows = []
    for _ in range(RECENT_EVENTS_COUNT):
        d = pick(devices)
        dt = TODAY - timedelta(days=random.randint(0, 7))
        rows.append({
            "device_id": d["device_id"],
            "event_date": dt,
            "event_id": str(uuid.uuid1()),
            "event_type": pick(EVENT_TYPES, [0.25, 0.15, 0.20, 0.25, 0.15]),
            "event_source": pick(["cloud", "local", "user"]),
            "payload": pick(["ok", "config applied", "command acknowledged", "sensor calibrated",
                             "network reconnected", "self-test passed"]),
            "created_at": datetime.combine(dt, datetime.min.time()) + timedelta(
                hours=random.randint(0,23), minutes=random.randint(0,59)),
        })
    return rows

# --- Iceberg historical/analytical/external -------------------------------
def generate_readings_archive(sampled):
    rows = []
    for d in sampled:
        metrics = DEVICE_CLASSES[d["device_class"]]
        drift = DRIFT_EVENTS.get(d["device_id"])
        for day_back in range(1, ARCHIVE_DAYS + 1):
            base_dt = TODAY - timedelta(days=day_back)
            step_minutes = (24 * 60) // ARCHIVE_SLOTS_PER_DAY
            for slot in range(0, ARCHIVE_SLOTS_PER_DAY):
                t = datetime.combine(base_dt, datetime.min.time()) + timedelta(minutes=step_minutes * slot)
                for m_idx, (mname, unit, lo, hi) in enumerate(metrics):
                    target = _diurnal_target(d["device_class"], t.hour, lo, hi)
                    if drift is not None and drift[1] == m_idx:
                        f = _drift_factor(t, drift[0])
                        if 0 < f <= 1.0:
                            target = target + (hi - target) * f
                        elif f > 1.0:
                            target = hi * (1.0 + (f - 1.0) * 0.2)
                    jitter = (hi - lo) * 0.05
                    val = round(target + random.uniform(-jitter, jitter), 2)
                    rows.append({
                        "device_id": d["device_id"],
                        "reading_date": base_dt,
                        "reading_year": base_dt.year, "reading_month": base_dt.month,
                        "reading_timestamp": t,
                        "device_class": d["device_class"],
                        "site_id": d["site_id"],
                        "metric_name": mname,
                        "metric_value": Decimal(str(val)),
                        "unit": unit,
                        "quality_code": pick(["good","good","good","suspect"]),
                    })
    return rows

def derive_hourly_aggregates(devices):
    """Generate hourly aggregates directly rather than computing from readings_archive,
    since archive may be sparse. Synthetic but shape-correct."""
    rows = []
    sampled = random.sample(devices, min(HOURLY_AGG_DEVICES, len(devices)))
    for d in sampled:
        metrics = DEVICE_CLASSES[d["device_class"]]
        for day_back in range(1, HOURLY_AGG_DAYS + 1):
            dt = TODAY - timedelta(days=day_back)
            for hour in range(0, 24):
                hs = datetime.combine(dt, datetime.min.time()) + timedelta(hours=hour)
                for (mname, unit, lo, hi) in metrics:
                    target = _diurnal_target(d["device_class"], hs.hour, lo, hi)
                    sigma = (hi - lo) * 0.10
                    samples = [max(lo, min(hi, target + random.uniform(-sigma, sigma)))
                               for _ in range(random.randint(20, 60))]
                    mn, mx = min(samples), max(samples)
                    avg = sum(samples) / len(samples)
                    samples.sort()
                    p95 = samples[int(len(samples) * 0.95) - 1]
                    # rough stddev
                    var = sum((x - avg) ** 2 for x in samples) / len(samples)
                    sd = var ** 0.5
                    rows.append({
                        "device_id": d["device_id"],
                        "site_id": d["site_id"],
                        "device_class": d["device_class"],
                        "metric_name": mname,
                        "hour_start": hs,
                        "hour_year": hs.year, "hour_month": hs.month,
                        "sample_count": len(samples),
                        "min_value": Decimal(str(round(mn, 4))),
                        "max_value": Decimal(str(round(mx, 4))),
                        "avg_value": Decimal(str(round(avg, 4))),
                        "p95_value": Decimal(str(round(p95, 4))),
                        "stddev_value": Decimal(str(round(sd, 4))),
                    })
    return rows

def generate_daily_site_summary(sites, devices):
    by_site = defaultdict(list)
    for d in devices: by_site[d["site_id"]].append(d)
    rows = []
    for site in sites:
        devs = by_site[site["site_id"]]
        for day_back in range(1, DAILY_SUMMARY_DAYS + 1):
            dt = TODAY - timedelta(days=day_back)
            online_avg = round(len(devs) * random.uniform(0.85, 0.99), 2)
            degraded_avg = round(len(devs) * random.uniform(0.01, 0.08), 2)
            alerts = random.randint(0, max(1, len(devs) // 10))
            critical = random.randint(0, max(0, alerts // 5))
            rows.append({
                "site_id": site["site_id"], "summary_date": dt,
                "summary_year": dt.year, "summary_month": dt.month,
                "device_count": len(devs),
                "devices_online_avg": Decimal(str(online_avg)),
                "devices_degraded_avg": Decimal(str(degraded_avg)),
                "readings_received": len(devs) * random.randint(1000, 3000),
                "alerts_raised": alerts, "alerts_critical": critical,
                "uptime_pct": Decimal(str(round(random.uniform(97.0, 99.95), 2))),
                "avg_battery_pct": Decimal(str(round(random.uniform(60.0, 95.0), 2))),
            })
    return rows

def generate_failure_history(devices):
    rows = []
    by_id = {d["device_id"]: d for d in devices}

    # Emit one failure per drift event so the predictive-maintenance narrative
    # is internally consistent: readings_archive shows the drift, and this row
    # is what the model is supposed to predict.
    for did, (failure_ts, _midx) in DRIFT_EVENTS.items():
        d = by_id[did]
        rows.append({
            "failure_id": str(uuid.uuid4()),
            "device_id": did, "site_id": d["site_id"],
            "device_class": d["device_class"],
            "failure_timestamp": failure_ts,
            "failure_year": failure_ts.year, "failure_month": failure_ts.month,
            "failure_type": pick(FAILURE_TYPES, [0.30, 0.15, 0.25, 0.15, 0.15]),
            "root_cause": pick(["sensor drift", "calibration drift", "component wear", "environment"]),
            "downtime_minutes": random.randint(60, 1440),
            "days_since_install": (failure_ts.date() - d["installed_at"].date()).days,
            "firmware_version": d["firmware_version"],
            "predicted_12h_prior": True,
        })

    # Fill remaining failures with firmware-weighted device picks so devices on
    # DRIFT_FIRMWARE fail at roughly FIRMWARE_REGRESSION_FACTOR× the baseline.
    weights = [FIRMWARE_REGRESSION_FACTOR if d["firmware_version"] == DRIFT_FIRMWARE else 1.0
               for d in devices]
    for _ in range(FAILURE_COUNT - len(rows)):
        d = random.choices(devices, weights=weights, k=1)[0]
        ts = NOW_TS - timedelta(days=random.randint(1, 365), hours=random.randint(0,23))
        rows.append({
            "failure_id": str(uuid.uuid4()),
            "device_id": d["device_id"], "site_id": d["site_id"],
            "device_class": d["device_class"],
            "failure_timestamp": ts,
            "failure_year": ts.year, "failure_month": ts.month,
            "failure_type": pick(FAILURE_TYPES, [0.30, 0.15, 0.25, 0.15, 0.15]),
            "root_cause": pick(["component wear", "firmware bug", "network loss",
                                "power surge", "calibration drift", "environment"]),
            "downtime_minutes": random.randint(5, 1440),
            "days_since_install": (ts.date() - d["installed_at"].date()).days,
            "firmware_version": d["firmware_version"],
            "predicted_12h_prior": random.random() < 0.20,
        })
    return rows

def generate_firmware_history(devices):
    rows = []
    for d in devices:
        deployed = d["installed_at"] + timedelta(days=random.randint(0, 60))
        versions = random.sample(FIRMWARE_VERSIONS, FIRMWARE_PER_DEVICE)
        prev_retired = None
        for idx, v in enumerate(versions):
            deployed_at = deployed + timedelta(days=idx * random.randint(90, 180))
            if deployed_at > NOW_TS: break
            retired_at = (deployed_at + timedelta(days=random.randint(120, 400))) if idx < len(versions) - 1 else None
            if retired_at and retired_at > NOW_TS: retired_at = None
            rows.append({
                "device_id": d["device_id"],
                "firmware_version": v,
                "deployed_at": deployed_at,
                "deployed_year": deployed_at.year,
                "retired_at": retired_at,
                "rollout_wave": pick(ROLLOUT_WAVES, [0.10, 0.25, 0.65]),
                "deployed_by": pick(["ops-svc", "fleet-mgr", "sre-bot"]),
                "success": random.random() < 0.97,
                "rollback_reason": None if random.random() < 0.96 else pick(
                    ["high error rate", "battery drain", "connectivity regression"]),
            })
    return rows

def generate_maintenance_windows(sites, devices):
    by_site = defaultdict(list)
    for d in devices: by_site[d["site_id"]].append(d)
    rows = []
    for _ in range(MAINTENANCE_WINDOWS):
        site = pick(sites)
        ws = NOW_TS - timedelta(days=random.randint(1, 360), hours=random.randint(0,23))
        we = ws + timedelta(minutes=random.randint(15, 600))
        rows.append({
            "window_id": str(uuid.uuid4()),
            "site_id": site["site_id"],
            "window_start": ws, "window_end": we,
            "window_year": ws.year, "window_month": ws.month,
            "window_type": pick(["planned", "unplanned"], [0.70, 0.30]),
            "reason": pick(["quarterly maintenance", "network upgrade", "power failure",
                            "firmware rollout", "cooling system", "hvac service"]),
            "devices_affected": random.randint(1, max(1, len(by_site[site["site_id"]]))),
            "downtime_minutes": int((we - ws).total_seconds() / 60),
        })
    return rows

def generate_weather(sites):
    rows = []
    for site in sites:
        for day_back in range(1, WEATHER_DAYS + 1):
            dt = TODAY - timedelta(days=day_back)
            base_temp = round(random.uniform(-5, 30), 1)
            for hour in range(0, 24):
                t = datetime.combine(dt, datetime.min.time()) + timedelta(hours=hour)
                # gentle diurnal shift
                temp = round(base_temp + 5 * random.uniform(-1, 1) + (2 if 10 <= hour <= 16 else 0), 2)
                rows.append({
                    "site_id": site["site_id"],
                    "observation_time": t,
                    "observation_year": t.year, "observation_month": t.month,
                    "temperature_c": Decimal(str(temp)),
                    "humidity_pct": Decimal(str(round(random.uniform(20, 95), 2))),
                    "pressure_hpa": Decimal(str(round(random.uniform(980, 1030), 2))),
                    "wind_speed_mps": Decimal(str(round(random.uniform(0, 18), 2))),
                    "precipitation_mm": Decimal(str(round(random.uniform(0, 5) if random.random() < 0.2 else 0, 2))),
                    "conditions": pick(CONDITIONS, CONDITION_WEIGHTS),
                    "source": "NOAA_partner_feed",
                })
    return rows

# --- writers --------------------------------------------------------------
def write_cassandra_csvs(devices, readings_hot, alerts_open, events_recent):
    write_csv(CASS_DIR / "device_state_current.csv",
        ["device_id","device_type","device_class","model","firmware_version","status",
         "last_heartbeat","last_reading_value","battery_percent","signal_strength_dbm",
         "site_id","zone","installed_at","updated_at"],
        [[d["device_id"], d["device_type"], d["device_class"], d["model"], d["firmware_version"],
          d["status"], d["last_heartbeat"].isoformat(), str(d["last_reading_value"]),
          d["battery_percent"], d["signal_strength_dbm"], d["site_id"], d["zone"],
          d["installed_at"].isoformat(), d["updated_at"].isoformat()] for d in devices])

    write_csv(CASS_DIR / "topology_current.csv",
        ["site_id","gateway_id","device_id","zone","installed_at","ip_address"],
        [[d["site_id"], d["gateway_id"], d["device_id"], d["zone"],
          d["installed_at"].isoformat(), d["ip_address"]] for d in devices])

    write_csv(CASS_DIR / "readings_hot.csv",
        ["device_id","reading_bucket_hour","reading_timestamp","metric_name","metric_value",
         "unit","quality_code"],
        [[r["device_id"], r["reading_bucket_hour"].isoformat(),
          r["reading_timestamp"].isoformat(), r["metric_name"],
          str(r["metric_value"]), r["unit"], r["quality_code"]] for r in readings_hot])

    write_csv(CASS_DIR / "alerts_open.csv",
        ["device_id","alert_id","raised_at","severity","alert_type","metric_name",
         "metric_value","threshold_value","site_id","acknowledged"],
        [[r["device_id"], r["alert_id"], r["raised_at"].isoformat(), r["severity"],
          r["alert_type"], r["metric_name"], str(r["metric_value"]),
          str(r["threshold_value"]), r["site_id"], r["acknowledged"]] for r in alerts_open])

    write_csv(CASS_DIR / "device_events_recent.csv",
        ["device_id","event_date","event_id","event_type","event_source","payload","created_at"],
        [[r["device_id"], r["event_date"].isoformat(), r["event_id"], r["event_type"],
          r["event_source"], r["payload"], r["created_at"].isoformat()] for r in events_recent])

def write_iceberg_parquet(readings_archive, hourly_agg, daily_summary, failure_hist,
                          firmware_hist, maintenance, weather):
    write_parquet(ICEBERG_DIR / "readings_archive.parquet",
        [("device_id","str"),("reading_date","date"),("reading_year","int"),
         ("reading_month","int"),("reading_timestamp","ts"),("device_class","str"),
         ("site_id","str"),("metric_name","str"),("metric_value","float"),
         ("unit","str"),("quality_code","str")],
        readings_archive)

    write_parquet(ICEBERG_DIR / "hourly_aggregates.parquet",
        [("device_id","str"),("site_id","str"),("device_class","str"),
         ("metric_name","str"),("hour_start","ts"),("hour_year","int"),
         ("hour_month","int"),("sample_count","int"),
         ("min_value","float"),("max_value","float"),("avg_value","float"),
         ("p95_value","float"),("stddev_value","float")],
        hourly_agg)

    write_parquet(ICEBERG_DIR / "daily_site_summary.parquet",
        [("site_id","str"),("summary_date","date"),("summary_year","int"),
         ("summary_month","int"),("device_count","int"),
         ("devices_online_avg","float"),("devices_degraded_avg","float"),
         ("readings_received","int"),("alerts_raised","int"),("alerts_critical","int"),
         ("uptime_pct","float"),("avg_battery_pct","float")],
        daily_summary)

    write_parquet(ICEBERG_DIR / "failure_history.parquet",
        [("failure_id","str"),("device_id","str"),("site_id","str"),
         ("device_class","str"),("failure_timestamp","ts"),
         ("failure_year","int"),("failure_month","int"),
         ("failure_type","str"),("root_cause","str"),
         ("downtime_minutes","int"),("days_since_install","int"),
         ("firmware_version","str"),("predicted_12h_prior","bool")],
        failure_hist)

    write_parquet(ICEBERG_DIR / "firmware_deployment_history.parquet",
        [("device_id","str"),("firmware_version","str"),("deployed_at","ts"),
         ("deployed_year","int"),("retired_at","ts"),("rollout_wave","str"),
         ("deployed_by","str"),("success","bool"),("rollback_reason","str")],
        firmware_hist)

    write_parquet(ICEBERG_DIR / "maintenance_windows.parquet",
        [("window_id","str"),("site_id","str"),("window_start","ts"),
         ("window_end","ts"),("window_year","int"),("window_month","int"),
         ("window_type","str"),("reason","str"),
         ("devices_affected","int"),("downtime_minutes","int")],
        maintenance)

    write_parquet(ICEBERG_DIR / "weather_by_location.parquet",
        [("site_id","str"),("observation_time","ts"),
         ("observation_year","int"),("observation_month","int"),
         ("temperature_c","float"),("humidity_pct","float"),
         ("pressure_hpa","float"),("wind_speed_mps","float"),
         ("precipitation_mm","float"),("conditions","str"),("source","str")],
        weather)

# --- main -----------------------------------------------------------------
def main():
    print("Generating IoT sample data...")
    CASS_DIR.mkdir(parents=True, exist_ok=True)
    ICEBERG_DIR.mkdir(parents=True, exist_ok=True)

    print("  Sites..."); sites = generate_sites()
    print("  Devices..."); devices = generate_devices(sites)
    print("  Readings hot (24h)..."); readings_hot = generate_readings_hot(devices)
    print("  Alerts open..."); alerts_open = generate_alerts_open(devices)
    print("  Device events recent..."); events_recent = generate_device_events_recent(devices)

    # Pre-sample devices for readings_archive so drift events can be pinned to
    # devices whose readings will actually appear in the archive.
    archive_sample = random.sample(devices, min(ARCHIVE_DEVICES, len(devices)))
    _setup_drift_events(archive_sample)

    print("  Readings archive..."); readings_archive = generate_readings_archive(archive_sample)
    print("  Hourly aggregates..."); hourly_agg = derive_hourly_aggregates(devices)
    print("  Daily site summary..."); daily_summary = generate_daily_site_summary(sites, devices)
    print("  Failure history..."); failure_hist = generate_failure_history(devices)
    print("  Firmware history..."); firmware_hist = generate_firmware_history(devices)
    print("  Maintenance windows..."); maintenance = generate_maintenance_windows(sites, devices)
    print("  Weather feed..."); weather = generate_weather(sites)

    print("Writing Cassandra CSVs...")
    write_cassandra_csvs(devices, readings_hot, alerts_open, events_recent)
    print("Writing Iceberg Parquet files...")
    write_iceberg_parquet(readings_archive, hourly_agg, daily_summary, failure_hist,
                          firmware_hist, maintenance, weather)

    print()
    print("Done. Summary:")
    print(f"  Sites:                 {len(sites):>7}")
    print(f"  Devices:               {len(devices):>7}")
    print(f"  Readings hot (24h):    {len(readings_hot):>7}")
    print(f"  Alerts open:           {len(alerts_open):>7}")
    print(f"  Device events (7d):    {len(events_recent):>7}")
    print(f"  Readings archive:      {len(readings_archive):>7}")
    print(f"  Hourly aggregates:     {len(hourly_agg):>7}")
    print(f"  Daily site summary:    {len(daily_summary):>7}")
    print(f"  Failure history:       {len(failure_hist):>7}")
    print(f"  Firmware deployments:  {len(firmware_hist):>7}")
    print(f"  Maintenance windows:   {len(maintenance):>7}")
    print(f"  Weather observations:  {len(weather):>7}")
    print()
    print(f"Cassandra CSVs  → {CASS_DIR}")
    print(f"Iceberg SQL     → {ICEBERG_DIR}")
    print()
    _print_drift_calendar({d["device_id"]: d for d in devices})

if __name__ == "__main__":
    main()
