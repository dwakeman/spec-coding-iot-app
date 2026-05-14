export type DeviceOperationalStatus = 'online' | 'offline' | 'degraded' | 'maintenance';

export interface DeviceState {
  deviceId: string;
  deviceType: string | null;
  deviceClass: string | null;
  model: string | null;
  firmwareVersion: string | null;
  status: DeviceOperationalStatus | string;
  lastHeartbeat: string | null;
  lastReadingValue: string | null;
  batteryPercent: number | null;
  signalStrengthDbm: number | null;
  siteId: string | null;
  zone: string | null;
  installedAt: string | null;
  updatedAt: string | null;
}

// Made with Bob