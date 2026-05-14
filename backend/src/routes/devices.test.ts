import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const findByDeviceIdMock = vi.fn();
const listMock = vi.fn();
const listRecentByDeviceIdMock = vi.fn();
const listAlertsByDeviceIdMock = vi.fn();
const listBaselineByDeviceIdMock = vi.fn();

vi.mock('../repositories/device-state-repository.js', () => ({
  deviceStateRepository: {
    findByDeviceId: findByDeviceIdMock,
    list: listMock,
  },
}));

vi.mock('../repositories/readings-repository.js', () => ({
  readingsRepository: {
    listRecentByDeviceId: listRecentByDeviceIdMock,
  },
}));

vi.mock('../repositories/alerts-repository.js', () => ({
  alertsRepository: {
    listByDeviceId: listAlertsByDeviceIdMock,
  },
}));

vi.mock('../repositories/baseline-repository.js', () => ({
  baselineRepository: {
    listByDeviceId: listBaselineByDeviceIdMock,
  },
}));

describe('GET /api/v1/devices', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
    listMock.mockReset();
    listRecentByDeviceIdMock.mockReset();
    listAlertsByDeviceIdMock.mockReset();
    listBaselineByDeviceIdMock.mockReset();
  });

  it('returns a paginated device list with filters', async () => {
    listMock.mockResolvedValue({
      items: [
        {
          deviceId: '550e8400-e29b-41d4-a716-446655440000',
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
        },
      ],
      pagination: {
        page: 2,
        pageSize: 10,
        totalItems: 11,
        totalPages: 2,
      },
    });

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get(
      '/api/v1/devices?siteId=site-a&status=online&page=2&pageSize=10&sort=lastHeartbeat:desc',
    );

    expect(response.status).toBe(200);
    expect(listMock).toHaveBeenCalledWith({
      siteId: 'site-a',
      status: 'online',
      sort: 'lastHeartbeat:desc',
      page: 2,
      pageSize: 10,
    });
    expect(response.body.data).toHaveLength(1);
    expect(response.body.pagination).toEqual({
      page: 2,
      pageSize: 10,
      totalItems: 11,
      totalPages: 2,
    });
  });

  it('returns 422 for an unsupported sort field', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices?sort=deviceId:asc');

    expect(response.status).toBe(422);
    expect(response.body.error.code).toBe('UNPROCESSABLE_ENTITY');
    expect(listMock).not.toHaveBeenCalled();
  });

  it('returns 400 for an invalid page value', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices?page=0');

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(listMock).not.toHaveBeenCalled();
  });

  it('returns 400 for an invalid status filter', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices?status=warning');

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(listMock).not.toHaveBeenCalled();
  });
});

describe('GET /api/v1/devices/:deviceId/readings', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
    listRecentByDeviceIdMock.mockReset();
  });

  it('returns last-hour readings for a valid device id', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listRecentByDeviceIdMock.mockResolvedValue([
      {
        timestamp: '2026-05-13T23:00:00.000Z',
        metricName: 'temperature_c',
        metricValue: '21.5',
        unit: 'C',
        qualityCode: 'good',
      },
    ]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get(
      '/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/readings?windowMinutes=60',
    );

    expect(response.status).toBe(200);
    expect(findByDeviceIdMock).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
    expect(listRecentByDeviceIdMock).toHaveBeenCalledWith({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowMinutes: 60,
    });
    expect(response.body.deviceId).toBe('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.windowMinutes).toBe(60);
    expect(response.body.items).toHaveLength(1);
    expect(response.body.supportedRequirements.requirementIds).toEqual(['REQ-002', 'REQ-008']);
  });

  it('returns an empty readings array when no readings exist', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listRecentByDeviceIdMock.mockResolvedValue([]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/readings');

    expect(response.status).toBe(200);
    expect(response.body.items).toEqual([]);
  });

  it('returns 400 for an invalid readings window', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get(
      '/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/readings?windowMinutes=61',
    );

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(listRecentByDeviceIdMock).not.toHaveBeenCalled();
  });
});

describe('GET /api/v1/devices/:deviceId/baseline', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
    listBaselineByDeviceIdMock.mockReset();
  });

  it('returns baseline metrics for a valid device id', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listBaselineByDeviceIdMock.mockResolvedValue([
      {
        deviceId: '550e8400-e29b-41d4-a716-446655440000',
        metricName: 'temperature_c',
        baselineAvg: '21.5',
        baselineP95: '24.8',
        baselineMin: '18.1',
        baselineMax: '27.3',
        baselineStddev: '1.9',
        sampleCount: 168,
        baselineWindowHoursCovered: 166,
      },
    ]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get(
      '/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/baseline?windowDays=7',
    );

    expect(response.status).toBe(200);
    expect(findByDeviceIdMock).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
    expect(listBaselineByDeviceIdMock).toHaveBeenCalledWith({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowDays: 7,
    });
    expect(response.body.deviceId).toBe('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.windowDays).toBe(7);
    expect(response.body.items).toEqual([
      {
        metricName: 'temperature_c',
        baselineAvg: 21.5,
        baselineP95: 24.8,
        baselineMin: 18.1,
        baselineMax: 27.3,
        baselineStddev: 1.9,
        sampleCount: 168,
        baselineWindowDays: 7,
        baselineWindowHoursCovered: 166,
      },
    ]);
    expect(response.body.supportedRequirements.requirementIds).toEqual([
      'REQ-003',
      'REQ-008',
      'REQ-009',
    ]);
  });

  it('defaults baseline windowDays to 7', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listBaselineByDeviceIdMock.mockResolvedValue([]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/baseline');

    expect(response.status).toBe(200);
    expect(listBaselineByDeviceIdMock).toHaveBeenCalledWith({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowDays: 7,
    });
    expect(response.body.windowDays).toBe(7);
    expect(response.body.items).toEqual([]);
  });

  it('returns 400 for an invalid baseline window', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get(
      '/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/baseline?windowDays=31',
    );

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(listBaselineByDeviceIdMock).not.toHaveBeenCalled();
  });
});

describe('GET /api/v1/devices/:deviceId/alerts', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
    listAlertsByDeviceIdMock.mockReset();
  });

  it('returns device alerts for a valid device id', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listAlertsByDeviceIdMock.mockResolvedValue([
      {
        alertId: 'c25b9f68-f006-46d6-bc04-a6b872520cac',
        raisedAt: '2026-04-22T11:06:00.000Z',
        severity: 'low',
        alertType: 'anomaly',
        metricName: 'accel_rms',
        metricValue: '0.66',
        thresholdValue: '3.0',
        siteId: 'SITE-1006',
        acknowledged: false,
      },
    ]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/alerts');

    expect(response.status).toBe(200);
    expect(findByDeviceIdMock).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
    expect(listAlertsByDeviceIdMock).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.deviceId).toBe('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.items).toHaveLength(1);
    expect(response.body.supportedRequirements.requirementIds).toEqual(['REQ-005', 'REQ-007']);
  });

  it('returns an empty alerts array when no alerts exist', async () => {
    findByDeviceIdMock.mockResolvedValue({ deviceId: '550e8400-e29b-41d4-a716-446655440000' });
    listAlertsByDeviceIdMock.mockResolvedValue([]);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000/alerts');

    expect(response.status).toBe(200);
    expect(response.body.items).toEqual([]);
  });
});

describe('GET /api/v1/devices/:deviceId', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
  });

  it('returns current device state for a valid device id', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
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

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000');

    expect(response.status).toBe(200);
    expect(findByDeviceIdMock).toHaveBeenCalledWith('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.data.deviceId).toBe('550e8400-e29b-41d4-a716-446655440000');
    expect(response.body.data.status).toBe('online');
  });

  it('returns 400 for an invalid uuid', async () => {
    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/not-a-uuid');

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(findByDeviceIdMock).not.toHaveBeenCalled();
  });

  it('returns 404 when the device does not exist', async () => {
    findByDeviceIdMock.mockResolvedValue(null);

    const { createApp } = await import('../app.js');
    const app = createApp();

    const response = await request(app).get('/api/v1/devices/550e8400-e29b-41d4-a716-446655440000');

    expect(response.status).toBe(404);
    expect(response.body.error.code).toBe('NOT_FOUND');
  });
});

// Made with Bob