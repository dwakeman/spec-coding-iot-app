import type { types } from 'cassandra-driver';

import type { DeviceState } from '../domain/device-state.js';
import { executeCassandraQuery } from '../lib/cassandra.js';

interface DeviceStateRow extends types.Row {
  device_id: string;
  device_type: string | null;
  device_class: string | null;
  model: string | null;
  firmware_version: string | null;
  status: string;
  last_heartbeat: Date | null;
  last_reading_value: { toString(): string } | null;
  battery_percent: number | null;
  signal_strength_dbm: number | null;
  site_id: string | null;
  zone: string | null;
  installed_at: Date | null;
  updated_at: Date | null;
}

export interface ListDeviceStatesParams {
  siteId?: string;
  status?: string;
  sort?: 'lastHeartbeat:desc';
  page?: number;
  pageSize?: number;
}

export interface ListDeviceStatesResult {
  items: DeviceState[];
  pagination: {
    page: number;
    pageSize: number;
    totalItems: number;
    totalPages: number;
  };
}

function toIsoString(value: Date | null) {
  return value ? value.toISOString() : null;
}

function mapDeviceStateRow(row: DeviceStateRow): DeviceState {
  return {
    deviceId: row.device_id,
    deviceType: row.device_type,
    deviceClass: row.device_class,
    model: row.model,
    firmwareVersion: row.firmware_version,
    status: row.status,
    lastHeartbeat: toIsoString(row.last_heartbeat),
    lastReadingValue: row.last_reading_value?.toString() ?? null,
    batteryPercent: row.battery_percent,
    signalStrengthDbm: row.signal_strength_dbm,
    siteId: row.site_id,
    zone: row.zone,
    installedAt: toIsoString(row.installed_at),
    updatedAt: toIsoString(row.updated_at),
  };
}

export class DeviceStateRepository {
  async listSiteIds() {
    const rows = await executeCassandraQuery<Pick<DeviceStateRow, 'site_id'>>(
      `SELECT site_id
       FROM iot.device_state_current`,
    );

    return [...new Set(rows.map((row) => row.site_id).filter((siteId): siteId is string => Boolean(siteId)))].sort(
      (left, right) => left.localeCompare(right),
    );
  }

  async findByDeviceId(deviceId: string) {
    const rows = await executeCassandraQuery<DeviceStateRow>(
      `SELECT device_id, device_type, device_class, model, firmware_version, status,
              last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
              site_id, zone, installed_at, updated_at
       FROM iot.device_state_current
       WHERE device_id = ?`,
      [deviceId],
    );

    return rows[0] ? mapDeviceStateRow(rows[0]) : null;
  }

  async list(params: ListDeviceStatesParams = {}): Promise<ListDeviceStatesResult> {
    const { siteId, status, sort = 'lastHeartbeat:desc', page = 1, pageSize = 25 } = params;
    let devices: DeviceState[];

    if (siteId && status) {
      const rows = await executeCassandraQuery<DeviceStateRow>(
        `SELECT device_id, device_type, device_class, model, firmware_version, status,
                last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
                site_id, zone, installed_at, updated_at
         FROM iot.device_state_current
         WHERE site_id = ? ALLOW FILTERING`,
        [siteId],
      );

      devices = rows.map(mapDeviceStateRow).filter((row) => row.status === status);
    } else if (siteId) {
      const rows = await executeCassandraQuery<DeviceStateRow>(
        `SELECT device_id, device_type, device_class, model, firmware_version, status,
                last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
                site_id, zone, installed_at, updated_at
         FROM iot.device_state_current
         WHERE site_id = ?`,
        [siteId],
      );

      devices = rows.map(mapDeviceStateRow);
    } else if (status) {
      const rows = await executeCassandraQuery<DeviceStateRow>(
        `SELECT device_id, device_type, device_class, model, firmware_version, status,
                last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
                site_id, zone, installed_at, updated_at
         FROM iot.device_state_current
         WHERE status = ?`,
        [status],
      );

      devices = rows.map(mapDeviceStateRow);
    } else {
      const rows = await executeCassandraQuery<DeviceStateRow>(
        `SELECT device_id, device_type, device_class, model, firmware_version, status,
                last_heartbeat, last_reading_value, battery_percent, signal_strength_dbm,
                site_id, zone, installed_at, updated_at
         FROM iot.device_state_current`,
      );

      devices = rows.map(mapDeviceStateRow);
    }

    const sortedDevices =
      sort === 'lastHeartbeat:desc'
        ? [...devices].sort((left, right) => {
            const leftTime = left.lastHeartbeat ? Date.parse(left.lastHeartbeat) : Number.NEGATIVE_INFINITY;
            const rightTime = right.lastHeartbeat
              ? Date.parse(right.lastHeartbeat)
              : Number.NEGATIVE_INFINITY;

            return rightTime - leftTime;
          })
        : devices;

    const totalItems = sortedDevices.length;
    const totalPages = totalItems === 0 ? 0 : Math.ceil(totalItems / pageSize);
    const startIndex = (page - 1) * pageSize;
    const items = sortedDevices.slice(startIndex, startIndex + pageSize);

    return {
      items,
      pagination: {
        page,
        pageSize,
        totalItems,
        totalPages,
      },
    };
  }
}

export const deviceStateRepository = new DeviceStateRepository();

// Made with Bob