import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import request from 'supertest';

const executeCassandraQueryMock = vi.fn();
const findByDeviceIdMock = vi.fn();
const listMock = vi.fn();
const listSiteIdsMock = vi.fn();

vi.mock('../lib/cassandra.js', () => ({
  executeCassandraQuery: executeCassandraQueryMock,
}));

vi.mock('../repositories/device-state-repository.js', async () => {
  const actual = await vi.importActual<typeof import('./device-state-repository.js')>(
    './device-state-repository.js',
  );

  return {
    ...actual,
    deviceStateRepository: {
      findByDeviceId: findByDeviceIdMock,
      list: listMock,
      listSiteIds: listSiteIdsMock,
    },
  };
});

describe('DeviceStateRepository', () => {
  beforeEach(() => {
    executeCassandraQueryMock.mockReset();
    findByDeviceIdMock.mockReset();
    listMock.mockReset();
    listSiteIdsMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('returns distinct non-null site ids in sorted order', async () => {
    executeCassandraQueryMock.mockResolvedValue([
      { site_id: 'site-b' },
      { site_id: 'site-a' },
      { site_id: null },
      { site_id: 'site-a' },
    ]);

    const { DeviceStateRepository } = await import('./device-state-repository.js');
    const repository = new DeviceStateRepository();

    const result = await repository.listSiteIds();

    expect(executeCassandraQueryMock).toHaveBeenCalledWith(expect.stringContaining('SELECT site_id'));
    expect(result).toEqual(['site-a', 'site-b']);
  });

  it('maps a device lookup by device_id', async () => {
    executeCassandraQueryMock.mockResolvedValue([
      {
        device_id: 'device-1',
        device_type: 'sensor',
        device_class: 'temperature',
        model: 'T-1000',
        firmware_version: '1.2.3',
        status: 'online',
        last_heartbeat: new Date('2026-05-13T23:00:00.000Z'),
        last_reading_value: { toString: () => '21.5' },
        battery_percent: 93,
        signal_strength_dbm: -66,
        site_id: 'site-a',
        zone: 'north',
        installed_at: new Date('2026-01-01T00:00:00.000Z'),
        updated_at: new Date('2026-05-13T23:05:00.000Z'),
      },
    ]);

    const { DeviceStateRepository } = await import('./device-state-repository.js');
    const repository = new DeviceStateRepository();

    const result = await repository.findByDeviceId('device-1');

    expect(executeCassandraQueryMock).toHaveBeenCalledWith(expect.stringContaining('WHERE device_id = ?'), [
      'device-1',
    ]);
    expect(result).toEqual({
      deviceId: 'device-1',
      deviceType: 'sensor',
      deviceClass: 'temperature',
      model: 'T-1000',
      firmwareVersion: '1.2.3',
      status: 'online',
      lastHeartbeat: '2026-05-13T23:00:00.000Z',
      lastReadingValue: '21.5',
      batteryPercent: 93,
      signalStrengthDbm: -66,
      siteId: 'site-a',
      zone: 'north',
      installedAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-05-13T23:05:00.000Z',
    });
  });

  it('filters by site and status with pagination metadata', async () => {
    executeCassandraQueryMock.mockResolvedValue([
      {
        device_id: 'device-1',
        device_type: 'sensor',
        device_class: 'temperature',
        model: 'T-1000',
        firmware_version: '1.2.3',
        status: 'online',
        last_heartbeat: null,
        last_reading_value: null,
        battery_percent: 93,
        signal_strength_dbm: -66,
        site_id: 'site-a',
        zone: 'north',
        installed_at: null,
        updated_at: null,
      },
      {
        device_id: 'device-2',
        device_type: 'sensor',
        device_class: 'temperature',
        model: 'T-2000',
        firmware_version: '1.2.4',
        status: 'offline',
        last_heartbeat: null,
        last_reading_value: null,
        battery_percent: 55,
        signal_strength_dbm: -80,
        site_id: 'site-a',
        zone: 'south',
        installed_at: null,
        updated_at: null,
      },
    ]);

    const { DeviceStateRepository } = await import('./device-state-repository.js');
    const repository = new DeviceStateRepository();

    const result = await repository.list({
      siteId: 'site-a',
      status: 'offline',
      page: 1,
      pageSize: 25,
    });

    expect(executeCassandraQueryMock).toHaveBeenCalledWith(
      expect.stringContaining('WHERE site_id = ? ALLOW FILTERING'),
      ['site-a'],
    );
    expect(result.items).toHaveLength(1);
    expect(result.items[0]?.deviceId).toBe('device-2');
    expect(result.items[0]?.status).toBe('offline');
    expect(result.pagination).toEqual({
      page: 1,
      pageSize: 25,
      totalItems: 1,
      totalPages: 1,
    });
  });
});

describe('GET /api/v1/sites', () => {
  beforeEach(() => {
    listSiteIdsMock.mockReset();
  });

  it('returns site metadata items from current device state', async () => {
    listSiteIdsMock.mockResolvedValue(['site-a', 'site-b']);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/sites');

    expect(response.status).toBe(200);
    expect(listSiteIdsMock).toHaveBeenCalled();
    expect(response.body).toEqual({
      data: [
        { siteId: 'site-a' },
        { siteId: 'site-b' },
      ],
    });
  });
});

// Made with Bob