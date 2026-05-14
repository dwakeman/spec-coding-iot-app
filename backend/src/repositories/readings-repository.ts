import type { types } from 'cassandra-driver';

import { executeCassandraQuery } from '../lib/cassandra.js';

export interface Reading {
  timestamp: string;
  metricName: string;
  metricValue: string;
  unit: string | null;
  qualityCode: string | null;
}

interface ReadingRow extends types.Row {
  reading_timestamp: Date;
  metric_name: string;
  metric_value: { toString(): string } | null;
  unit: string | null;
  quality_code: string | null;
}

export interface ListRecentReadingsParams {
  deviceId: string;
  windowMinutes: number;
  now?: Date;
}

function getHourBucket(date: Date) {
  return new Date(
    Date.UTC(
      date.getUTCFullYear(),
      date.getUTCMonth(),
      date.getUTCDate(),
      date.getUTCHours(),
      0,
      0,
      0,
    ),
  );
}

function mapReadingRow(row: ReadingRow): Reading {
  return {
    timestamp: row.reading_timestamp.toISOString(),
    metricName: row.metric_name,
    metricValue: row.metric_value?.toString() ?? '',
    unit: row.unit,
    qualityCode: row.quality_code,
  };
}

export class ReadingsRepository {
  async listRecentByDeviceId(params: ListRecentReadingsParams) {
    const { deviceId, windowMinutes, now = new Date() } = params;
    const windowStart = new Date(now.getTime() - windowMinutes * 60_000);
    const currentHourBucket = getHourBucket(now);
    const previousHourBucket = new Date(currentHourBucket.getTime() - 60 * 60_000);

    const currentHourRows = await executeCassandraQuery<ReadingRow>(
      `SELECT reading_timestamp, metric_name, metric_value, unit, quality_code
       FROM iot.readings_hot
       WHERE device_id = ? AND reading_bucket_hour = ?`,
      [deviceId, currentHourBucket],
    );

    const previousHourRows =
      previousHourBucket.getTime() === currentHourBucket.getTime()
        ? []
        : await executeCassandraQuery<ReadingRow>(
            `SELECT reading_timestamp, metric_name, metric_value, unit, quality_code
             FROM iot.readings_hot
             WHERE device_id = ? AND reading_bucket_hour = ?`,
            [deviceId, previousHourBucket],
          );

    return [...currentHourRows, ...previousHourRows]
      .filter((row) => row.reading_timestamp.getTime() >= windowStart.getTime())
      .sort((left, right) => right.reading_timestamp.getTime() - left.reading_timestamp.getTime())
      .map(mapReadingRow);
  }
}

export const readingsRepository = new ReadingsRepository();

// Made with Bob