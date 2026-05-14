import { describe, expect, it } from 'vitest';

import type { MetricBaseline } from '../repositories/baseline-repository.js';
import type { Reading } from '../repositories/readings-repository.js';
import {
  computeDeviceAnomalySummary,
  evaluateDeviceMetricAnomalies,
  evaluateMetricAnomaly,
} from './anomaly-service.js';

describe('evaluateMetricAnomaly', () => {
  const mockBaseline: MetricBaseline = {
    deviceId: 'device-001',
    metricName: 'temperature_c',
    baselineAvg: '20.0',
    baselineP95: '24.0',
    baselineMin: '18.0',
    baselineMax: '26.0',
    baselineStddev: '1.5',
    sampleCount: 168,
    baselineWindowHoursCovered: 168,
  };

  it('returns anomalous when value exceeds baseline P95', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0',
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('anomalous');
    expect(result.anomalyReason).toContain('exceeds baseline P95');
    expect(result.latestReading).toEqual(readings[0]);
  });

  it('returns anomalous when deviation exceeds 2 * stddev', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '24.0', // deviation = 4.0, threshold = max(3.0, 2.0) = 3.0
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('anomalous');
    expect(result.anomalyReason).toContain('Deviation');
    expect(result.anomalyReason).toContain('exceeds threshold');
  });

  it('returns anomalous when deviation exceeds 10% of baseline average', () => {
    const lowStddevBaseline: MetricBaseline = {
      ...mockBaseline,
      baselineAvg: '100.0',
      baselineP95: '120.0',
      baselineStddev: '2.0', // 2 * stddev = 4.0, but 10% of avg = 10.0
    };

    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '112.0', // deviation = 12.0, threshold = max(4.0, 10.0) = 10.0
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: lowStddevBaseline,
    });

    expect(result.anomalyStatus).toBe('anomalous');
    expect(result.anomalyReason).toContain('Deviation');
  });

  it('returns normal when value is within acceptable range', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.5',
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('normal');
    expect(result.anomalyReason).toBeNull();
    expect(result.latestReading).toEqual(readings[0]);
  });

  it('returns unknown when baseline is missing', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.5',
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: null,
    });

    expect(result.anomalyStatus).toBe('unknown');
    expect(result.anomalyReason).toContain('No baseline data available');
    expect(result.baseline).toBeNull();
  });

  it('returns unknown when only bad quality readings exist', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.5',
        unit: 'C',
        qualityCode: 'bad',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('unknown');
    expect(result.anomalyReason).toContain('No good or suspect quality readings');
  });

  it('excludes bad quality readings from anomaly evaluation', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '30.0', // Would be anomalous if considered
        unit: 'C',
        qualityCode: 'bad',
      },
      {
        timestamp: '2026-05-13T23:50:00.000Z',
        metricName: 'temperature_c',
        metricValue: '20.5', // Normal value
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('normal');
    expect(result.latestReading?.metricValue).toBe('20.5');
    expect(result.latestReading?.qualityCode).toBe('good');
  });

  it('uses suspect quality readings for evaluation', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0', // Exceeds P95
        unit: 'C',
        qualityCode: 'suspect',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('anomalous');
    expect(result.latestReading?.qualityCode).toBe('suspect');
  });

  it('uses the most recent good/suspect reading when multiple exist', () => {
    const readings: Reading[] = [
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
        metricValue: '25.0', // Would be anomalous but is older
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const result = evaluateMetricAnomaly({
      metricName: 'temperature_c',
      readings,
      baseline: mockBaseline,
    });

    expect(result.anomalyStatus).toBe('normal');
    expect(result.latestReading?.timestamp).toBe('2026-05-13T23:55:00.000Z');
  });
});

describe('evaluateDeviceMetricAnomalies', () => {
  it('evaluates anomalies for multiple metrics', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0',
        unit: 'C',
        qualityCode: 'good',
      },
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'humidity_pct',
        metricValue: '45.0',
        unit: '%',
        qualityCode: 'good',
      },
    ];

    const baselines: MetricBaseline[] = [
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
      {
        deviceId: 'device-001',
        metricName: 'humidity_pct',
        baselineAvg: '50.0',
        baselineP95: '60.0',
        baselineMin: '40.0',
        baselineMax: '65.0',
        baselineStddev: '3.0',
        sampleCount: 168,
        baselineWindowHoursCovered: 168,
      },
    ];

    const results = evaluateDeviceMetricAnomalies(readings, baselines);

    expect(results).toHaveLength(2);
    expect(results[0].metricName).toBe('temperature_c');
    expect(results[0].anomalyStatus).toBe('anomalous');
    expect(results[1].metricName).toBe('humidity_pct');
    expect(results[1].anomalyStatus).toBe('normal');
  });

  it('handles metrics with no baseline', () => {
    const readings: Reading[] = [
      {
        timestamp: '2026-05-13T23:55:00.000Z',
        metricName: 'temperature_c',
        metricValue: '25.0',
        unit: 'C',
        qualityCode: 'good',
      },
    ];

    const baselines: MetricBaseline[] = [];

    const results = evaluateDeviceMetricAnomalies(readings, baselines);

    expect(results).toHaveLength(1);
    expect(results[0].anomalyStatus).toBe('unknown');
    expect(results[0].anomalyReason).toContain('No baseline data available');
  });

  it('returns empty array when no readings exist', () => {
    const readings: Reading[] = [];
    const baselines: MetricBaseline[] = [];

    const results = evaluateDeviceMetricAnomalies(readings, baselines);

    expect(results).toEqual([]);
  });
});

describe('computeDeviceAnomalySummary', () => {
  it('marks device as anomalous when any metric is anomalous', () => {
    const metricEvaluations = [
      {
        metricName: 'temperature_c',
        anomalyStatus: 'anomalous' as const,
        anomalyReason: 'Exceeds P95',
        latestReading: null,
        baseline: null,
      },
      {
        metricName: 'humidity_pct',
        anomalyStatus: 'normal' as const,
        anomalyReason: null,
        latestReading: null,
        baseline: null,
      },
    ];

    const result = computeDeviceAnomalySummary({
      metricEvaluations,
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.deviceAnomalyStatus).toBe('anomalous');
    expect(result.anomalyMetricCount).toBe(1);
  });

  it('marks device as anomalous when anomaly alert exists', () => {
    const metricEvaluations = [
      {
        metricName: 'temperature_c',
        anomalyStatus: 'normal' as const,
        anomalyReason: null,
        latestReading: null,
        baseline: null,
      },
    ];

    const result = computeDeviceAnomalySummary({
      metricEvaluations,
      alerts: [{ severity: 'medium', alertType: 'anomaly' }],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.deviceAnomalyStatus).toBe('anomalous');
  });

  it('assigns critical severity when critical alert exists', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [{ severity: 'critical', alertType: 'threshold' }],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('critical');
    expect(result.highestAlertSeverity).toBe('critical');
  });

  it('assigns high severity when anomalous metrics exist and no critical alert', () => {
    const metricEvaluations = [
      {
        metricName: 'temperature_c',
        anomalyStatus: 'anomalous' as const,
        anomalyReason: 'Exceeds P95',
        latestReading: null,
        baseline: null,
      },
    ];

    const result = computeDeviceAnomalySummary({
      metricEvaluations,
      alerts: [{ severity: 'low', alertType: 'threshold' }],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('high');
  });

  it('assigns medium severity when device status is degraded', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'degraded',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('medium');
  });

  it('assigns low severity when battery is below threshold', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 15,
      hasRecentReadings: true,
      lowBatteryThreshold: 20,
    });

    expect(result.severity).toBe('low');
  });

  it('assigns normal severity when no issues exist', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('normal');
    expect(result.deviceAnomalyStatus).toBe('normal');
  });

  it('marks data as stale when no recent readings exist', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: false,
    });

    expect(result.dataFreshness).toBe('stale');
  });

  it('marks data as fresh when recent readings exist', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.dataFreshness).toBe('fresh');
  });

  it('counts open alerts correctly', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [
        { severity: 'high', alertType: 'threshold' },
        { severity: 'medium', alertType: 'anomaly' },
        { severity: 'low', alertType: 'connectivity' },
      ],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.openAlertCount).toBe(3);
  });

  it('finds highest alert severity correctly', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [
        { severity: 'low', alertType: 'threshold' },
        { severity: 'high', alertType: 'anomaly' },
        { severity: 'medium', alertType: 'connectivity' },
      ],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.highestAlertSeverity).toBe('high');
  });

  it('returns null for highest alert severity when no alerts exist', () => {
    const result = computeDeviceAnomalySummary({
      metricEvaluations: [],
      alerts: [],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.highestAlertSeverity).toBeNull();
  });

  it('prioritizes critical severity over anomalous metrics', () => {
    const metricEvaluations = [
      {
        metricName: 'temperature_c',
        anomalyStatus: 'anomalous' as const,
        anomalyReason: 'Exceeds P95',
        latestReading: null,
        baseline: null,
      },
    ];

    const result = computeDeviceAnomalySummary({
      metricEvaluations,
      alerts: [{ severity: 'critical', alertType: 'threshold' }],
      deviceStatus: 'online',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('critical');
  });

  it('prioritizes high severity (anomalous metrics) over degraded status', () => {
    const metricEvaluations = [
      {
        metricName: 'temperature_c',
        anomalyStatus: 'anomalous' as const,
        anomalyReason: 'Exceeds P95',
        latestReading: null,
        baseline: null,
      },
    ];

    const result = computeDeviceAnomalySummary({
      metricEvaluations,
      alerts: [],
      deviceStatus: 'degraded',
      batteryPercent: 90,
      hasRecentReadings: true,
    });

    expect(result.severity).toBe('high');
  });
});

// Made with Bob
// REQ-004: Anomaly detection test coverage
// REQ-005: Alert context integration tests
// REQ-008: Missing data handling tests