import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const executeCassandraQueryMock = vi.fn();

vi.mock('../lib/cassandra.js', () => ({
  executeCassandraQuery: executeCassandraQueryMock,
}));

describe('ReadingsRepository', () => {
  beforeEach(() => {
    executeCassandraQueryMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('queries current and previous hour buckets, filters to the last 60 minutes, and sorts by recency', async () => {
    executeCassandraQueryMock
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T23:55:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '22.1' },
          unit: 'C',
          quality_code: 'good',
        },
        {
          reading_timestamp: new Date('2026-05-13T23:10:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '21.5' },
          unit: 'C',
          quality_code: 'suspect',
        },
      ])
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T22:59:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '21.2' },
          unit: 'C',
          quality_code: 'good',
        },
        {
          reading_timestamp: new Date('2026-05-13T22:40:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '20.8' },
          unit: 'C',
          quality_code: 'bad',
        },
      ]);

    const { ReadingsRepository } = await import('./readings-repository.js');
    const repository = new ReadingsRepository();

    const result = await repository.listRecentByDeviceId({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowMinutes: 60,
      now: new Date('2026-05-13T23:59:00.000Z'),
    });

    expect(executeCassandraQueryMock).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining('WHERE device_id = ? AND reading_bucket_hour = ?'),
      ['550e8400-e29b-41d4-a716-446655440000', new Date('2026-05-13T23:00:00.000Z')],
    );
    expect(executeCassandraQueryMock).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining('WHERE device_id = ? AND reading_bucket_hour = ?'),
      ['550e8400-e29b-41d4-a716-446655440000', new Date('2026-05-13T22:00:00.000Z')],
    );
    expect(result).toEqual([
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '22.1',
        unit: 'C',
        qualityCode: 'good',
      },
      {
        timestamp: '2026-05-13T23:10:00.000Z',
        metricName: 'temperature_c',
        metricValue: '21.5',
        unit: 'C',
        qualityCode: 'suspect',
      },
      {
        timestamp: '2026-05-13T22:59:00.000Z',
        metricName: 'temperature_c',
        metricValue: '21.2',
        unit: 'C',
        qualityCode: 'good',
      },
    ]);
  });

  it('preserves quality_code for all readings including bad quality', async () => {
    executeCassandraQueryMock
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T23:55:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '22.1' },
          unit: 'C',
          quality_code: 'good',
        },
      ])
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T23:10:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '19.8' },
          unit: 'C',
          quality_code: 'bad',
        },
        {
          reading_timestamp: new Date('2026-05-13T23:05:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '20.1' },
          unit: 'C',
          quality_code: 'suspect',
        },
      ]);

    const { ReadingsRepository } = await import('./readings-repository.js');
    const repository = new ReadingsRepository();

    const result = await repository.listRecentByDeviceId({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowMinutes: 60,
      now: new Date('2026-05-13T23:59:00.000Z'),
    });

    expect(result).toHaveLength(3);
    expect(result[0].qualityCode).toBe('good');
    expect(result[1].qualityCode).toBe('bad');
    expect(result[2].qualityCode).toBe('suspect');
  });

  it('returns readings in descending timestamp order (most recent first)', async () => {
    executeCassandraQueryMock
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T23:10:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '21.0' },
          unit: 'C',
          quality_code: 'good',
        },
        {
          reading_timestamp: new Date('2026-05-13T23:55:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '22.1' },
          unit: 'C',
          quality_code: 'good',
        },
      ])
      .mockResolvedValueOnce([
        {
          reading_timestamp: new Date('2026-05-13T23:30:00.000Z'),
          metric_name: 'temperature_c',
          metric_value: { toString: () => '20.5' },
          unit: 'C',
          quality_code: 'good',
        },
      ]);

    const { ReadingsRepository } = await import('./readings-repository.js');
    const repository = new ReadingsRepository();

    const result = await repository.listRecentByDeviceId({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowMinutes: 60,
      now: new Date('2026-05-13T23:59:00.000Z'),
    });

    expect(result).toHaveLength(3);
    expect(result[0].timestamp).toBe('2026-05-13T23:55:00.000Z');
    expect(result[1].timestamp).toBe('2026-05-13T23:30:00.000Z');
    expect(result[2].timestamp).toBe('2026-05-13T23:10:00.000Z');
  });
});

// Made with Bob
// REQ-002: Last-hour readings with quality_code preservation
// REQ-008: Data freshness and ordering