import type { DeviceState } from '../domain/device-state.js';
import type { DeviceAlert } from '../repositories/alerts-repository.js';
import { alertsRepository } from '../repositories/alerts-repository.js';
import type { MetricBaseline } from '../repositories/baseline-repository.js';
import { baselineRepository } from '../repositories/baseline-repository.js';
import type { Reading } from '../repositories/readings-repository.js';
import { readingsRepository } from '../repositories/readings-repository.js';
import {
  computeDeviceAnomalySummary,
  evaluateDeviceMetricAnomalies,
  type AnomalyStatus,
} from './anomaly-service.js';

export interface DeviceSummaryEnrichment {
  deviceId: string;
  anomalyStatus: AnomalyStatus;
  anomalyMetricCount: number;
  highestAlertSeverity: string | null;
  openAlertCount: number;
}

export interface EnrichDeviceListParams {
  devices: DeviceState[];
  includeAlerts?: boolean;
  includeAnomalies?: boolean;
  readingsWindowMinutes?: number;
  baselineWindowDays?: number;
}

/**
 * Enriches a list of devices with alert and anomaly summaries.
 * 
 * This service loads alerts, readings, and baselines for the given devices
 * in parallel, then computes anomaly summaries for each device.
 * 
 * @param params - Devices to enrich and enrichment options
 * @returns Map of deviceId to enrichment data
 */
export async function enrichDeviceList(
  params: EnrichDeviceListParams,
): Promise<Map<string, DeviceSummaryEnrichment>> {
  const {
    devices,
    includeAlerts = true,
    includeAnomalies = true,
    readingsWindowMinutes = 60,
    baselineWindowDays = 7,
  } = params;

  const deviceIds = devices.map((d) => d.deviceId);
  const enrichmentMap = new Map<string, DeviceSummaryEnrichment>();

  // Initialize with defaults
  for (const device of devices) {
    enrichmentMap.set(device.deviceId, {
      deviceId: device.deviceId,
      anomalyStatus: 'unknown',
      anomalyMetricCount: 0,
      highestAlertSeverity: null,
      openAlertCount: 0,
    });
  }

  // Load data in parallel
  const [alertsMap, readingsMap, baselinesMap] = await Promise.all([
    includeAlerts ? loadAlertsForDevices(deviceIds) : Promise.resolve(new Map()),
    includeAnomalies ? loadReadingsForDevices(deviceIds, readingsWindowMinutes) : Promise.resolve(new Map()),
    includeAnomalies ? loadBaselinesForDevices(deviceIds, baselineWindowDays) : Promise.resolve(new Map()),
  ]);

  // Enrich each device
  for (const device of devices) {
    const enrichment = enrichmentMap.get(device.deviceId)!;

    // Add alert enrichment
    if (includeAlerts) {
      const alerts = alertsMap.get(device.deviceId) || [];
      enrichment.openAlertCount = alerts.length;
      
      if (alerts.length > 0) {
        const severities = alerts.map((a) => a.severity);
        enrichment.highestAlertSeverity = getHighestSeverity(severities);
      }
    }

    // Add anomaly enrichment
    if (includeAnomalies) {
      const readings = readingsMap.get(device.deviceId) || [];
      const baselines = baselinesMap.get(device.deviceId) || [];
      const alerts = alertsMap.get(device.deviceId) || [];

      if (readings.length > 0 || baselines.length > 0) {
        const metricEvaluations = evaluateDeviceMetricAnomalies(readings, baselines);
        const anomalySummary = computeDeviceAnomalySummary({
          metricEvaluations,
          alerts,
          deviceStatus: device.status,
          batteryPercent: device.batteryPercent,
          hasRecentReadings: readings.length > 0,
        });

        enrichment.anomalyStatus = anomalySummary.deviceAnomalyStatus;
        enrichment.anomalyMetricCount = anomalySummary.anomalyMetricCount;
      }
    }
  }

  return enrichmentMap;
}

/**
 * Loads alerts for multiple devices in parallel.
 */
async function loadAlertsForDevices(deviceIds: string[]) {
  const alertsMap = new Map<string, DeviceAlert[]>();

  const results = await Promise.allSettled(
    deviceIds.map(async (deviceId) => {
      const alerts = await alertsRepository.listByDeviceId(deviceId);
      return { deviceId, alerts };
    }),
  );

  for (const result of results) {
    if (result.status === 'fulfilled') {
      alertsMap.set(result.value.deviceId, result.value.alerts);
    }
  }

  return alertsMap;
}

/**
 * Loads recent readings for multiple devices in parallel.
 */
async function loadReadingsForDevices(deviceIds: string[], windowMinutes: number) {
  const readingsMap = new Map<string, Reading[]>();

  const results = await Promise.allSettled(
    deviceIds.map(async (deviceId) => {
      const readings = await readingsRepository.listRecentByDeviceId({
        deviceId,
        windowMinutes,
      });
      return { deviceId, readings };
    }),
  );

  for (const result of results) {
    if (result.status === 'fulfilled') {
      readingsMap.set(result.value.deviceId, result.value.readings);
    }
  }

  return readingsMap;
}

/**
 * Loads baselines for multiple devices in parallel.
 */
async function loadBaselinesForDevices(deviceIds: string[], windowDays: number) {
  const baselinesMap = new Map<string, MetricBaseline[]>();

  const results = await Promise.allSettled(
    deviceIds.map(async (deviceId) => {
      const baselines = await baselineRepository.listByDeviceId({
        deviceId,
        windowDays,
      });
      return { deviceId, baselines };
    }),
  );

  for (const result of results) {
    if (result.status === 'fulfilled') {
      baselinesMap.set(result.value.deviceId, result.value.baselines);
    }
  }

  return baselinesMap;
}

/**
 * Determines the highest severity from a list of alert severities.
 * Order: critical > high > medium > low
 */
function getHighestSeverity(severities: string[]): string {
  const order = ['critical', 'high', 'medium', 'low'];
  
  for (const severity of order) {
    if (severities.includes(severity)) {
      return severity;
    }
  }
  
  return severities[0] || 'low';
}

// Made with Bob
