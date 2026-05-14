import { executePrestoQuery } from '../lib/presto.js';

export interface MetricBaseline {
  deviceId: string;
  metricName: string;
  baselineAvg: string;
  baselineP95: string;
  baselineMin: string;
  baselineMax: string;
  baselineStddev: string;
  sampleCount: number;
  baselineWindowHoursCovered: number;
}

interface BaselineRow {
  device_id: string | null;
  metric_name: string | null;
  baseline_avg: string | number | null;
  baseline_p95: string | number | null;
  baseline_min: string | number | null;
  baseline_max: string | number | null;
  baseline_stddev: string | number | null;
  sample_count: string | number | null;
  baseline_window_hours_covered: string | number | null;
}

export interface ListBaselineByDeviceIdParams {
  deviceId: string;
  windowDays?: number;
}

function toMetricValue(value: string | number | null) {
  return value === null || value === undefined ? '' : String(value);
}

function toInteger(value: string | number | null) {
  if (typeof value === 'number') {
    return value;
  }

  if (typeof value === 'string' && value.length > 0) {
    return Number.parseInt(value, 10);
  }

  return 0;
}

function escapeSqlLiteral(value: string) {
  return value.replaceAll("'", "''");
}

function mapBaselineRow(row: BaselineRow): MetricBaseline {
  return {
    deviceId: row.device_id ?? '',
    metricName: row.metric_name ?? '',
    baselineAvg: toMetricValue(row.baseline_avg),
    baselineP95: toMetricValue(row.baseline_p95),
    baselineMin: toMetricValue(row.baseline_min),
    baselineMax: toMetricValue(row.baseline_max),
    baselineStddev: toMetricValue(row.baseline_stddev),
    sampleCount: toInteger(row.sample_count),
    baselineWindowHoursCovered: toInteger(row.baseline_window_hours_covered),
  };
}

export class BaselineRepository {
  async listByDeviceId(params: ListBaselineByDeviceIdParams) {
    const { deviceId, windowDays = 7 } = params;

    const escapedDeviceId = escapeSqlLiteral(deviceId);
    const query = `
      SELECT
        device_id,
        metric_name,
        CAST(AVG(avg_value) AS DOUBLE) AS baseline_avg,
        CAST(MAX(p95_value) AS DOUBLE) AS baseline_p95,
        CAST(MIN(min_value) AS DOUBLE) AS baseline_min,
        CAST(MAX(max_value) AS DOUBLE) AS baseline_max,
        CAST(AVG(stddev_value) AS DOUBLE) AS baseline_stddev,
        CAST(SUM(sample_count) AS BIGINT) AS sample_count,
        CAST(COUNT(*) AS BIGINT) AS baseline_window_hours_covered
      FROM iceberg_data.iot.hourly_aggregates
      WHERE device_id = '${escapedDeviceId}'
        AND hour_start >= current_timestamp - INTERVAL '${windowDays}' DAY
      GROUP BY device_id, metric_name
      ORDER BY metric_name ASC
    `.trim();

    const rows = await executePrestoQuery<BaselineRow>(query);

    return rows.map(mapBaselineRow);
  }
}

export const baselineRepository = new BaselineRepository();

// Made with Bob