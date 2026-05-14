import type { MetricBaseline } from '../repositories/baseline-repository.js';
import type { Reading } from '../repositories/readings-repository.js';

export type AnomalyStatus = 'normal' | 'anomalous' | 'unknown';

export interface MetricAnomalyEvaluation {
  metricName: string;
  anomalyStatus: AnomalyStatus;
  anomalyReason: string | null;
  latestReading: Reading | null;
  baseline: MetricBaseline | null;
}

export interface EvaluateMetricAnomalyParams {
  metricName: string;
  readings: Reading[];
  baseline: MetricBaseline | null;
}

/**
 * Evaluates anomaly status for a single metric based on recent readings and baseline.
 * 
 * Rules from design.md:
 * - A metric is anomalous when:
 *   1. At least one good/suspect reading exists
 *   2. A 7-day baseline exists
 *   3. Latest reading satisfies either:
 *      - metric_value > baselineP95
 *      - abs(metric_value - baselineAvg) > max(2 * baselineStddev, baselineAvg * 0.10)
 * 
 * - Bad quality readings are excluded from evaluation
 * - Missing baseline → unknown
 * - Only bad quality readings → unknown
 * 
 * @param params - Metric name, readings, and baseline
 * @returns Anomaly evaluation result
 */
export function evaluateMetricAnomaly(params: EvaluateMetricAnomalyParams): MetricAnomalyEvaluation {
  const { metricName, readings, baseline } = params;

  // Filter out bad quality readings
  const goodOrSuspectReadings = readings.filter(
    (r) => r.metricName === metricName && r.qualityCode !== 'bad',
  );

  // If no baseline exists, status is unknown
  if (!baseline) {
    return {
      metricName,
      anomalyStatus: 'unknown',
      anomalyReason: 'No baseline data available for comparison',
      latestReading: readings.find((r) => r.metricName === metricName) ?? null,
      baseline: null,
    };
  }

  // If no good/suspect readings exist, status is unknown
  if (goodOrSuspectReadings.length === 0) {
    return {
      metricName,
      anomalyStatus: 'unknown',
      anomalyReason: 'No good or suspect quality readings available',
      latestReading: readings.find((r) => r.metricName === metricName) ?? null,
      baseline,
    };
  }

  // Get the latest good/suspect reading (readings are already sorted by timestamp desc)
  const latestReading = goodOrSuspectReadings[0];
  const metricValue = parseFloat(latestReading.metricValue);
  const baselineAvg = parseFloat(baseline.baselineAvg);
  const baselineP95 = parseFloat(baseline.baselineP95);
  const baselineStddev = parseFloat(baseline.baselineStddev);

  // Rule 1: Check if value exceeds p95
  if (metricValue > baselineP95) {
    return {
      metricName,
      anomalyStatus: 'anomalous',
      anomalyReason: `Value ${metricValue.toFixed(2)} exceeds baseline P95 (${baselineP95.toFixed(2)})`,
      latestReading,
      baseline,
    };
  }

  // Rule 2: Check if deviation exceeds threshold
  const deviation = Math.abs(metricValue - baselineAvg);
  const deviationThreshold = Math.max(2 * baselineStddev, baselineAvg * 0.1);

  if (deviation > deviationThreshold) {
    return {
      metricName,
      anomalyStatus: 'anomalous',
      anomalyReason: `Deviation ${deviation.toFixed(2)} exceeds threshold ${deviationThreshold.toFixed(2)} (baseline avg: ${baselineAvg.toFixed(2)})`,
      latestReading,
      baseline,
    };
  }

  // No anomaly detected
  return {
    metricName,
    anomalyStatus: 'normal',
    anomalyReason: null,
    latestReading,
    baseline,
  };
}

/**
 * Evaluates anomalies for all metrics in a device's readings.
 * 
 * @param readings - All recent readings for the device
 * @param baselines - Baseline data for each metric
 * @returns Array of metric anomaly evaluations
 */
export function evaluateDeviceMetricAnomalies(
  readings: Reading[],
  baselines: MetricBaseline[],
): MetricAnomalyEvaluation[] {
  // Get unique metric names from readings
  const metricNames = Array.from(new Set(readings.map((r) => r.metricName)));

  // Evaluate each metric
  return metricNames.map((metricName) => {
    const metricReadings = readings.filter((r) => r.metricName === metricName);
    const baseline = baselines.find((b) => b.metricName === metricName) ?? null;

    return evaluateMetricAnomaly({
      metricName,
      readings: metricReadings,
      baseline,
    });
  });
}

export type DeviceSeverity = 'critical' | 'high' | 'medium' | 'low' | 'normal';
export type DataFreshness = 'fresh' | 'stale';

export interface DeviceAnomalySummary {
  deviceAnomalyStatus: AnomalyStatus;
  anomalyMetricCount: number;
  severity: DeviceSeverity;
  dataFreshness: DataFreshness;
  highestAlertSeverity: string | null;
  openAlertCount: number;
}

export interface ComputeDeviceAnomalySummaryParams {
  metricEvaluations: MetricAnomalyEvaluation[];
  alerts: Array<{ severity: string; alertType: string }>;
  deviceStatus: string;
  batteryPercent: number | null;
  hasRecentReadings: boolean;
  lowBatteryThreshold?: number;
}

/**
 * Computes device-level anomaly summary from metric evaluations and alerts.
 *
 * Rules from design.md:
 * - Device is anomalous when any metric is anomalous OR an anomaly alert exists
 * - Severity rollup:
 *   - critical: any critical alert
 *   - high: any anomalous metric and no critical alert
 *   - medium: device status is degraded
 *   - low: battery below threshold
 *   - normal: otherwise
 * - Data freshness: stale if no recent readings
 *
 * @param params - Metric evaluations, alerts, device state
 * @returns Device anomaly summary
 */
export function computeDeviceAnomalySummary(
  params: ComputeDeviceAnomalySummaryParams,
): DeviceAnomalySummary {
  const {
    metricEvaluations,
    alerts,
    deviceStatus,
    batteryPercent,
    hasRecentReadings,
    lowBatteryThreshold = 20,
  } = params;

  // Count anomalous metrics
  const anomalousMetrics = metricEvaluations.filter((e) => e.anomalyStatus === 'anomalous');
  const anomalyMetricCount = anomalousMetrics.length;

  // Check for anomaly alerts
  const hasAnomalyAlert = alerts.some((a) => a.alertType === 'anomaly');

  // Device is anomalous if any metric is anomalous OR an anomaly alert exists
  const deviceAnomalyStatus: AnomalyStatus =
    anomalyMetricCount > 0 || hasAnomalyAlert ? 'anomalous' : 'normal';

  // Determine data freshness
  const dataFreshness: DataFreshness = hasRecentReadings ? 'fresh' : 'stale';

  // Find highest alert severity
  const severityOrder = ['critical', 'high', 'medium', 'low'];
  let highestAlertSeverity: string | null = null;
  
  for (const sev of severityOrder) {
    if (alerts.some((a) => a.severity === sev)) {
      highestAlertSeverity = sev;
      break;
    }
  }

  // Compute device severity rollup
  let severity: DeviceSeverity = 'normal';

  if (alerts.some((a) => a.severity === 'critical')) {
    severity = 'critical';
  } else if (anomalyMetricCount > 0) {
    severity = 'high';
  } else if (deviceStatus === 'degraded') {
    severity = 'medium';
  } else if (batteryPercent !== null && batteryPercent < lowBatteryThreshold) {
    severity = 'low';
  }

  return {
    deviceAnomalyStatus,
    anomalyMetricCount,
    severity,
    dataFreshness,
    highestAlertSeverity,
    openAlertCount: alerts.length,
  };
}

// Made with Bob
// REQ-004: Anomaly detection logic
// REQ-005: Alert context integration
// REQ-008: Missing data handling
// REQ-009: Hot + cold data comparison