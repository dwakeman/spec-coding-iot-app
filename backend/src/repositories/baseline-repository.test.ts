import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const executePrestoQueryMock = vi.fn();

vi.mock('../lib/presto.js', () => ({
  executePrestoQuery: executePrestoQueryMock,
}));

describe('BaselineRepository', () => {
  beforeEach(() => {
    executePrestoQueryMock.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('queries hourly aggregates through Presto and maps baseline metrics by device', async () => {
    executePrestoQueryMock.mockResolvedValueOnce([
      {
        device_id: '550e8400-e29b-41d4-a716-446655440000',
        metric_name: 'temperature_c',
        baseline_avg: 21.5,
        baseline_p95: 24.3,
        baseline_min: 18.9,
        baseline_max: 26.1,
        baseline_stddev: 1.2,
        sample_count: 168,
        baseline_window_hours_covered: 168,
      },
    ]);

    const { BaselineRepository } = await import('./baseline-repository.js');
    const repository = new BaselineRepository();

    const result = await repository.listByDeviceId({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
    });

    expect(executePrestoQueryMock).toHaveBeenCalledWith(expect.stringContaining("FROM iceberg_data.iot.hourly_aggregates"));
    expect(executePrestoQueryMock).toHaveBeenCalledWith(
      expect.stringContaining("WHERE device_id = '550e8400-e29b-41d4-a716-446655440000'"),
    );
    expect(executePrestoQueryMock).toHaveBeenCalledWith(
      expect.stringContaining("hour_start >= current_timestamp - INTERVAL '7' DAY"),
    );
    expect(result).toEqual([
      {
        deviceId: '550e8400-e29b-41d4-a716-446655440000',
        metricName: 'temperature_c',
        baselineAvg: '21.5',
        baselineP95: '24.3',
        baselineMin: '18.9',
        baselineMax: '26.1',
        baselineStddev: '1.2',
        sampleCount: 168,
        baselineWindowHoursCovered: 168,
      },
    ]);
  });

  it('returns an empty result when no baseline rows are available', async () => {
    executePrestoQueryMock.mockResolvedValueOnce([]);

    const { BaselineRepository } = await import('./baseline-repository.js');
    const repository = new BaselineRepository();

    const result = await repository.listByDeviceId({
      deviceId: '550e8400-e29b-41d4-a716-446655440000',
      windowDays: 3,
    });

    expect(executePrestoQueryMock).toHaveBeenCalledWith(expect.stringContaining("INTERVAL '3' DAY"));
    expect(result).toEqual([]);
  });
});

// Made with Bob