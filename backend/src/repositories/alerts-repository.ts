import type { types } from 'cassandra-driver';

import { executeCassandraQuery } from '../lib/cassandra.js';

export interface DeviceAlert {
  alertId: string;
  raisedAt: string | null;
  severity: string;
  alertType: string;
  metricName: string | null;
  metricValue: string | null;
  thresholdValue: string | null;
  siteId: string | null;
  acknowledged: boolean;
}

interface AlertRow extends types.Row {
  alert_id: string;
  raised_at: Date | null;
  severity: string;
  alert_type: string;
  metric_name: string | null;
  metric_value: { toString(): string } | null;
  threshold_value: { toString(): string } | null;
  site_id: string | null;
  acknowledged: boolean;
}

function toIsoString(value: Date | null) {
  return value ? value.toISOString() : null;
}

function mapAlertRow(row: AlertRow): DeviceAlert {
  return {
    alertId: row.alert_id,
    raisedAt: toIsoString(row.raised_at),
    severity: row.severity,
    alertType: row.alert_type,
    metricName: row.metric_name,
    metricValue: row.metric_value?.toString() ?? null,
    thresholdValue: row.threshold_value?.toString() ?? null,
    siteId: row.site_id,
    acknowledged: row.acknowledged,
  };
}

export class AlertsRepository {
  async listByDeviceId(deviceId: string) {
    const rows = await executeCassandraQuery<AlertRow>(
      `SELECT alert_id, raised_at, severity, alert_type, metric_name,
              metric_value, threshold_value, site_id, acknowledged
       FROM iot.alerts_open
       WHERE device_id = ?`,
      [deviceId],
    );

    return rows.map(mapAlertRow);
  }
}

export const alertsRepository = new AlertsRepository();

// Made with Bob