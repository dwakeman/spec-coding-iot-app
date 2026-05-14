import type { DeviceState } from '../domain/device-state.js';
import type { DeviceAlert } from '../repositories/alerts-repository.js';
import { alertsRepository } from '../repositories/alerts-repository.js';
import type { MetricBaseline } from '../repositories/baseline-repository.js';
import { baselineRepository } from '../repositories/baseline-repository.js';
import { deviceStateRepository } from '../repositories/device-state-repository.js';
import type { Reading } from '../repositories/readings-repository.js';
import { readingsRepository } from '../repositories/readings-repository.js';
import {
  computeDeviceAnomalySummary,
  evaluateDeviceMetricAnomalies,
  type DeviceAnomalySummary,
  type MetricAnomalyEvaluation,
} from './anomaly-service.js';

export interface MetricHealth {
  metricName: string;
  latestReading: Reading | null;
  unit: string | null;
  qualityCode: string | null;
  recentReadingCount: number;
  anomalyStatus: 'normal' | 'anomalous' | 'unknown';
  anomalyReason: string | null;
  baseline: MetricBaseline | null;
}

export interface DeviceHealthSummary {
  device: DeviceState;
  summary: DeviceAnomalySummary;
  metricHealth: MetricHealth[];
  readings: Reading[];
  alerts: DeviceAlert[];
}

export interface GetDeviceHealthParams {
  deviceId: string;
  readingsWindowMinutes?: number;
  baselineWindowDays?: number;
  lowBatteryThreshold?: number;
}

/**
 * Composes complete device health information from multiple sources.
 * 
 * Combines:
 * - Current device state (Cassandra)
 * - Recent readings (Cassandra)
 * - Open alerts (Cassandra)
 * - Baseline metrics (Iceberg via Presto)
 * - Anomaly evaluations (computed)
 * 
 * Handles partial enrichment gracefully when some data sources are unavailable.
 * 
 * @param params - Device ID and optional window parameters
 * @returns Complete device health summary
 */
export async function getDeviceHealth(params: GetDeviceHealthParams): Promise<DeviceHealthSummary | null> {
  const {
    deviceId,
    readingsWindowMinutes = 60,
    baselineWindowDays = 7,
    lowBatteryThreshold = 20,
  } = params;

  // Load device state (required)
  const device = await deviceStateRepository.findByDeviceId(deviceId);
  if (!device) {
    return null;
  }

  // Load all data sources in parallel (best effort)
  const [readings, alerts, baselines] = await Promise.all([
    readingsRepository.listRecentByDeviceId({
      deviceId,
      windowMinutes: readingsWindowMinutes,
    }).catch(() => [] as Reading[]),
    
    alertsRepository.listByDeviceId(deviceId).catch(() => [] as DeviceAlert[]),
    
    baselineRepository.listByDeviceId({
      deviceId,
      windowDays: baselineWindowDays,
    }).catch(() => [] as MetricBaseline[]),
  ]);

  // Evaluate anomalies for each metric
  const metricEvaluations = evaluateDeviceMetricAnomalies(readings, baselines);

  // Compute device-level anomaly summary
  const summary = computeDeviceAnomalySummary({
    metricEvaluations,
    alerts,
    deviceStatus: device.status,
    batteryPercent: device.batteryPercent,
    hasRecentReadings: readings.length > 0,
    lowBatteryThreshold,
  });

  // Build metric health objects
  const metricHealth: MetricHealth[] = metricEvaluations.map((evaluation) => {
    const metricReadings = readings.filter((r) => r.metricName === evaluation.metricName);
    const latestReading = evaluation.latestReading;

    return {
      metricName: evaluation.metricName,
      latestReading,
      unit: latestReading?.unit ?? null,
      qualityCode: latestReading?.qualityCode ?? null,
      recentReadingCount: metricReadings.length,
      anomalyStatus: evaluation.anomalyStatus,
      anomalyReason: evaluation.anomalyReason,
      baseline: evaluation.baseline,
    };
  });

  return {
    device,
    summary,
    metricHealth,
    readings,
    alerts,
  };
}

// Made with Bob
// REQ-002: Recent readings integration
// REQ-003: Baseline comparison
// REQ-004: Anomaly detection
// REQ-005: Alert context
// REQ-007: Device detail composition
// REQ-008: Missing data handling
// REQ-009: Hot + cold data federation