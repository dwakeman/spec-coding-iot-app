import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const findByDeviceIdMock = vi.fn();
const listRecentByDeviceIdMock = vi.fn();
const listAlertsByDeviceIdMock = vi.fn();
const listBaselineByDeviceIdMock = vi.fn();

vi.mock('../repositories/device-state-repository.js', () => ({
  deviceStateRepository: {
    findByDeviceId: findByDeviceIdMock,
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

describe('getDeviceHealth', () => {
  beforeEach(() => {
    findByDeviceIdMock.mockReset();
    listRecentByDeviceIdMock.mockReset();
    listAlertsByDeviceIdMock.mockReset();
    listBaselineByDeviceIdMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('returns null when device does not exist', async () => {
    findByDeviceIdMock.mockResolvedValue(null);

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'unknown-device' });

    expect(result).toBeNull();
  });

  it('composes complete device health with all data sources', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      deviceType: 'sensor',
      deviceClass: 'temperature',
      model: 'T-1000',
      status: 'online',
      batteryPercent: 90,
      lastHeartbeat: '2026-05-13T23:00:00.000Z',
      siteId: 'site-a',
      zone: 'north',
    });

    listRecentByDeviceIdMock.mockResolvedValue([
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0',
        unit: 'C',
        qualityCode: 'good',
      },
    ]);

    listAlertsByDeviceIdMock.mockResolvedValue([
      {
        alertId: 'alert-001',
        severity: 'medium',
        alertType: 'threshold',
        raisedAt: '2026-05-13T23:50:00.000Z',
      },
    ]);

    listBaselineByDeviceIdMock.mockResolvedValue([
      {
        deviceId: 'device-001',
        metricName: 'temperature_c',
        baselineAvg: '20.0',
        baselineP95: '24.0',
        baselineMin: '18.0',
        baselineMax: '26.0',
        baselineStddev: '1.5',
        sampleCount: 168,
        baselineWindowHoursCovered: 168,
      },
    ]);

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'device-001' });

    expect(result).not.toBeNull();
    expect(result?.device.deviceId).toBe('device-001');
    expect(result?.readings).toHaveLength(1);
    expect(result?.alerts).toHaveLength(1);
    expect(result?.metricHealth).toHaveLength(1);
    expect(result?.metricHealth[0].metricName).toBe('temperature_c');
    expect(result?.metricHealth[0].anomalyStatus).toBe('anomalous');
    expect(result?.summary.deviceAnomalyStatus).toBe('anomalous');
    expect(result?.summary.severity).toBe('high');
  });

  it('handles partial enrichment when readings fail', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      status: 'online',
      batteryPercent: 90,
    });

    listRecentByDeviceIdMock.mockRejectedValue(new Error('Cassandra timeout'));
    listAlertsByDeviceIdMock.mockResolvedValue([]);
    listBaselineByDeviceIdMock.mockResolvedValue([]);

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'device-001' });

    expect(result).not.toBeNull();
    expect(result?.readings).toEqual([]);
    expect(result?.summary.dataFreshness).toBe('stale');
  });

  it('handles partial enrichment when alerts fail', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      status: 'online',
      batteryPercent: 90,
    });

    listRecentByDeviceIdMock.mockResolvedValue([]);
    listAlertsByDeviceIdMock.mockRejectedValue(new Error('Cassandra timeout'));
    listBaselineByDeviceIdMock.mockResolvedValue([]);

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'device-001' });

    expect(result).not.toBeNull();
    expect(result?.alerts).toEqual([]);
    expect(result?.summary.openAlertCount).toBe(0);
  });

  it('handles partial enrichment when baseline fails', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      status: 'online',
      batteryPercent: 90,
    });

    listRecentByDeviceIdMock.mockResolvedValue([
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0',
        unit: 'C',
        qualityCode: 'good',
      },
    ]);
    listAlertsByDeviceIdMock.mockResolvedValue([]);
    listBaselineByDeviceIdMock.mockRejectedValue(new Error('Presto timeout'));

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'device-001' });

    expect(result).not.toBeNull();
    expect(result?.metricHealth).toHaveLength(1);
    expect(result?.metricHealth[0].anomalyStatus).toBe('unknown');
    expect(result?.metricHealth[0].baseline).toBeNull();
  });

  it('includes metric health with reading counts', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      status: 'online',
      batteryPercent: 90,
    });

    listRecentByDeviceIdMock.mockResolvedValue([
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.5',
        unit: 'C',
        qualityCode: 'good',
      },
      {
        timestamp: '2026-05-13T23:50:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.3',
        unit: 'C',
        qualityCode: 'good',
      },
      {
        timestamp: '2026-05-13T23:45:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.1',
        unit: 'C',
        qualityCode: 'good',
      },
    ]);

    listAlertsByDeviceIdMock.mockResolvedValue([]);
    listBaselineByDeviceIdMock.mockResolvedValue([
      {
        deviceId: 'device-001',
        metricName: 'temperature_c',
        baselineAvg: '20.0',
        baselineP95: '24.0',
        baselineMin: '18.0',
        baselineMax: '26.0',
        baselineStddev: '1.5',
        sampleCount: 168,
        baselineWindowHoursCovered: 168,
      },
    ]);

    const { getDeviceHealth } = await import('./device-health-service.js');
    const result = await getDeviceHealth({ deviceId: 'device-001' });

    expect(result?.metricHealth[0].recentReadingCount).toBe(3);
    expect(result?.metricHealth[0].latestReading?.metricValue).toBe('20.5');
  });

  it('uses custom window parameters', async () => {
    findByDeviceIdMock.mockResolvedValue({
      deviceId: 'device-001',
      status: 'online',
      batteryPercent: 90,
    });

    listRecentByDeviceIdMock.mockResolvedValue([]);
    listAlertsByDeviceIdMock.mockResolvedValue([]);
    listBaselineByDeviceIdMock.mockResolvedValue([]);

    const { getDeviceHealth } = await import('./device-health-service.js');
    await getDeviceHealth({
      deviceId: 'device-001',
      readingsWindowMinutes: 30,
      baselineWindowDays: 14,
      lowBatteryThreshold: 15,
    });

    expect(listRecentByDeviceIdMock).toHaveBeenCalledWith({
      deviceId: 'device-001',
      windowMinutes: 30,
    });

    expect(listBaselineByDeviceIdMock).toHaveBeenCalledWith({
      deviceId: 'device-001',
      windowDays: 14,
    });
  });
});

// Made with Bob
// REQ-007: Device detail composition tests
// REQ-008: Partial enrichment handling tests