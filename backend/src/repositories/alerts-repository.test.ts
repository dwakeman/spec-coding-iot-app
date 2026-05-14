import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const executeCassandraQueryMock = vi.fn();

vi.mock('../lib/cassandra.js', () => ({
  executeCassandraQuery: executeCassandraQueryMock,
}));

describe('AlertsRepository', () => {
  beforeEach(() => {
    executeCassandraQueryMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('maps device alerts from alerts_open', async () => {
    executeCassandraQueryMock.mockResolvedValue([
      {
        alert_id: 'c25b9f68-f006-46d6-bc04-a6b872520cac',
        raised_at: new Date('2026-04-22T11:06:00.000Z'),
        severity: 'low',
        alert_type: 'anomaly',
        metric_name: 'accel_rms',
        metric_value: { toString: () => '0.66' },
        threshold_value: { toString: () => '3.0' },
        site_id: 'SITE-1006',
        acknowledged: false,
      },
    ]);

    const { AlertsRepository } = await import('./alerts-repository.js');
    const repository = new AlertsRepository();

    const result = await repository.listByDeviceId('550e8400-e29b-41d4-a716-446655440000');

    expect(executeCassandraQueryMock).toHaveBeenCalledWith(
      expect.stringContaining('FROM iot.alerts_open'),
      ['550e8400-e29b-41d4-a716-446655440000'],
    );
    expect(result).toEqual([
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
  });

  it('returns an empty array when no alerts exist', async () => {
    executeCassandraQueryMock.mockResolvedValue([]);

    const { AlertsRepository } = await import('./alerts-repository.js');
    const repository = new AlertsRepository();

    const result = await repository.listByDeviceId('550e8400-e29b-41d4-a716-446655440000');

    expect(result).toEqual([]);
  });
});

// Made with Bob