const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? '/api/v1';

function normalizePath(path: string) {
  if (API_BASE_URL.endsWith('/')) {
    return `${API_BASE_URL.slice(0, -1)}${path}`;
  }

  return `${API_BASE_URL}${path}`;
}

async function requestJson<T>(path: string, query?: URLSearchParams): Promise<T> {
  const normalizedPath = normalizePath(path);
  const requestUrl =
    query && query.toString().length > 0 ? `${normalizedPath}?${query.toString()}` : normalizedPath;

  const response = await fetch(requestUrl, {
    headers: {
      Accept: 'application/json',
    },
  });

  if (!response.ok) {
    throw new Error(`Request failed with status ${response.status}`);
  }

  return (await response.json()) as T;
}

export interface DeviceSummary {
  deviceId: string;
  siteId: string;
  deviceType: string;
  status: string;
  batteryLevelPct: number | null;
  signalStrengthDbm: number | null;
  lastHeartbeatAt: string;
  // Alert enrichment (when includeAlerts=true)
  openAlertCount?: number;
  highestAlertSeverity?: string | null;
  // Anomaly enrichment (when includeAnomalies=true)
  anomalyStatus?: 'normal' | 'anomalous' | 'unknown';
  anomalyMetricCount?: number;
}

export interface DeviceListResponse {
  data: DeviceSummary[];
  pagination: {
    page: number;
    pageSize: number;
    totalItems: number;
    totalPages: number;
  };
}

export interface DeviceDetail {
  deviceId: string;
  deviceType: string;
  deviceClass: string;
  model: string;
  firmwareVersion: string;
  status: string;
  lastHeartbeat: string;
  lastReadingValue: string | number | null;
  batteryPercent: number | null;
  signalStrengthDbm: number | null;
  siteId: string;
  zone: string;
  installedAt: string | null;
  updatedAt: string | null;
}

export interface DeviceDetailResponse {
  data: DeviceDetail;
}

export interface DeviceReading {
  timestamp: string;
  metricName: string;
  metricValue: string | number;
  unit: string;
  qualityCode: string;
}

export interface DeviceReadingsResponse {
  deviceId: string;
  windowMinutes: number;
  items: DeviceReading[];
}

export interface DeviceBaseline {
  metricName: string;
  baselineAvg: number | null;
  baselineP95: number | null;
  baselineMin: number | null;
  baselineMax: number | null;
  baselineStddev: number | null;
  sampleCount: number;
  baselineWindowDays: number;
  baselineWindowHoursCovered: number;
}

export interface DeviceBaselineResponse {
  deviceId: string;
  windowDays: number;
  items: DeviceBaseline[];
}

export interface DeviceAlert {
  alertId: string;
  raisedAt: string;
  severity: string;
  alertType: string;
  metricName?: string | null;
  metricValue?: string | number | null;
  thresholdValue?: string | number | null;
  siteId: string;
  acknowledged: boolean;
}

export interface DeviceAlertsResponse {
  deviceId: string;
  items: DeviceAlert[];
}

export interface MetricHealth {
  metricName: string;
  anomalyStatus: 'normal' | 'anomalous' | 'unknown';
  anomalyReason: string | null;
  latestReading: DeviceReading | null;
  baseline: DeviceBaseline | null;
  recentReadingCount: number;
}

export interface DeviceHealthSummary {
  deviceAnomalyStatus: 'normal' | 'anomalous' | 'unknown';
  anomalyMetricCount: number;
  severity: 'critical' | 'high' | 'medium' | 'low' | 'normal' | null;
  dataFreshness: 'fresh' | 'stale';
  highestAlertSeverity: string | null;
  openAlertCount: number;
}

export interface DeviceHealthResponse {
  device: DeviceDetail;
  summary: DeviceHealthSummary;
  metricHealth: MetricHealth[];
  readings: DeviceReading[];
  alerts: DeviceAlert[];
}

export interface SiteListResponse {
  data: Array<{
    siteId: string;
  }>;
}

export interface DeviceListFilters {
  siteId?: string;
  status?: string;
  anomalyStatus?: 'normal' | 'anomalous' | 'unknown';
  includeAlerts?: boolean;
  includeAnomalies?: boolean;
}

export const apiClient = {
  devices: {
    listPath(filters?: DeviceListFilters) {
      const query = new URLSearchParams();

      if (filters?.siteId) {
        query.set('siteId', filters.siteId);
      }

      if (filters?.status) {
        query.set('status', filters.status);
      }

      if (filters?.anomalyStatus) {
        query.set('anomalyStatus', filters.anomalyStatus);
      }

      if (filters?.includeAlerts !== undefined) {
        query.set('includeAlerts', String(filters.includeAlerts));
      }

      if (filters?.includeAnomalies !== undefined) {
        query.set('includeAnomalies', String(filters.includeAnomalies));
      }

      const normalizedPath = normalizePath('/devices');

      return query.toString().length > 0 ? `${normalizedPath}?${query.toString()}` : normalizedPath;
    },
    list(filters?: DeviceListFilters) {
      const query = new URLSearchParams();

      if (filters?.siteId) {
        query.set('siteId', filters.siteId);
      }

      if (filters?.status) {
        query.set('status', filters.status);
      }

      if (filters?.anomalyStatus) {
        query.set('anomalyStatus', filters.anomalyStatus);
      }

      if (filters?.includeAlerts !== undefined) {
        query.set('includeAlerts', String(filters.includeAlerts));
      }

      if (filters?.includeAnomalies !== undefined) {
        query.set('includeAnomalies', String(filters.includeAnomalies));
      }

      return requestJson<DeviceListResponse>('/devices', query);
    },
    detailPath(deviceId: string) {
      return normalizePath(`/devices/${deviceId}`);
    },
    detail(deviceId: string) {
      return requestJson<DeviceDetailResponse>(`/devices/${deviceId}`);
    },
    readingsPath(deviceId: string) {
      return normalizePath(`/devices/${deviceId}/readings`);
    },
    readings(deviceId: string) {
      return requestJson<DeviceReadingsResponse>(`/devices/${deviceId}/readings`);
    },
    baselinePath(deviceId: string) {
      return normalizePath(`/devices/${deviceId}/baseline`);
    },
    baseline(deviceId: string) {
      return requestJson<DeviceBaselineResponse>(`/devices/${deviceId}/baseline`);
    },
    alertsPath(deviceId: string) {
      return normalizePath(`/devices/${deviceId}/alerts`);
    },
    alerts(deviceId: string) {
      return requestJson<DeviceAlertsResponse>(`/devices/${deviceId}/alerts`);
    },
    healthPath(deviceId: string) {
      return normalizePath(`/devices/${deviceId}/health`);
    },
    health(deviceId: string) {
      return requestJson<DeviceHealthResponse>(`/devices/${deviceId}/health`);
    },
  },
  sites: {
    listPath() {
      return normalizePath('/sites');
    },
    list() {
      return requestJson<SiteListResponse>('/sites');
    },
  },
};

// Made with Bob
