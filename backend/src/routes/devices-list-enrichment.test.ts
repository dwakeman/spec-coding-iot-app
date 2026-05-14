import { describe, it, expect, beforeEach, vi } from 'vitest';

const listMock = vi.fn();
const listAlertsByDeviceIdMock = vi.fn();
const listRecentByDeviceIdMock = vi.fn();
const listBaselineByDeviceIdMock = vi.fn();

vi.mock('../repositories/device-state-repository.js', () => ({
  deviceStateRepository: {
    list: listMock,
  },
}));

vi.mock('../repositories/alerts-repository.js', () => ({
  alertsRepository: {
    listByDeviceId: listAlertsByDeviceIdMock,
  },
}));

vi.mock('../repositories/readings-repository.js', () => ({
  readingsRepository: {
    listRecentByDeviceId: listRecentByDeviceIdMock,
  },
}));

vi.mock('../repositories/baseline-repository.js', () => ({
  baselineRepository: {
    listByDeviceId: listBaselineByDeviceIdMock,
  },
}));

describe('GET /api/v1/devices - enrichment with alerts and anomalies', () => {
  beforeEach(() => {
    listMock.mockReset();
    listAlertsByDeviceIdMock.mockReset();
    listRecentByDeviceIdMock.mockReset();
    listBaselineByDeviceIdMock.mockReset();
  });

  describe('alert enrichment', () => {
    it('should enrich devices with alert summary when includeAlerts=true', async () => {
      // Mock device list
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
          {
            deviceId: 'dev-002',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 2,
          totalPages: 1,
        },
      });

      // Mock alerts for dev-001 (2 critical, 1 high)
      listAlertsByDeviceIdMock.mockImplementation(async (deviceId: string) => {
        if (deviceId === 'dev-001') {
          return [
            {
              alertId: 'alert-1',
              severity: 'critical',
              alertType: 'threshold_exceeded',
              raisedAt: '2026-05-14T09:00:00.000Z',
              acknowledged: false,
            },
            {
              alertId: 'alert-2',
              severity: 'critical',
              alertType: 'threshold_exceeded',
              raisedAt: '2026-05-14T09:30:00.000Z',
              acknowledged: false,
            },
            {
              alertId: 'alert-3',
              severity: 'high',
              alertType: 'threshold_exceeded',
              raisedAt: '2026-05-14T09:45:00.000Z',
              acknowledged: false,
            },
          ];
        }
        return [];
      });

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAlerts=true').expect(200);

      expect(response.body.data).toHaveLength(2);

      // dev-001 should have alert enrichment
      const dev001 = response.body.data.find((d: any) => d.deviceId === 'dev-001');
      expect(dev001.openAlertCount).toBe(3);
      expect(dev001.highestAlertSeverity).toBe('critical');

      // dev-002 should have no alerts
      const dev002 = response.body.data.find((d: any) => d.deviceId === 'dev-002');
      expect(dev002.openAlertCount).toBe(0);
      expect(dev002.highestAlertSeverity).toBeNull();
    });

    it('should not include alert fields when includeAlerts=false', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAlerts=false').expect(200);

      expect(response.body.data[0]).not.toHaveProperty('openAlertCount');
      expect(response.body.data[0]).not.toHaveProperty('highestAlertSeverity');
    });

    it('should handle alert loading failures gracefully', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      // Simulate alert loading failure
      listAlertsByDeviceIdMock.mockRejectedValue(new Error('Cassandra connection failed'));

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAlerts=true').expect(200);

      // Should still return devices, but without alert enrichment
      expect(response.body.data).toHaveLength(1);
      expect(response.body.data[0].openAlertCount).toBe(0);
      expect(response.body.data[0].highestAlertSeverity).toBeNull();
    });
  });

  describe('anomaly enrichment', () => {
    it('should enrich devices with anomaly summary when includeAnomalies=true', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      // Mock readings with anomalies
      listRecentByDeviceIdMock.mockResolvedValue([
        {
          timestamp: '2026-05-14T09:55:00.000Z',
          metricName: 'temperature_c',
          metricValue: '95.0',
          qualityCode: 'good',
          unit: 'C',
        },
        {
          timestamp: '2026-05-14T09:55:00.000Z',
          metricName: 'pressure_psi',
          metricValue: '150.0',
          qualityCode: 'good',
          unit: 'psi',
        },
      ]);

      // Mock baselines showing temperature is anomalous
      listBaselineByDeviceIdMock.mockResolvedValue([
        {
          deviceId: 'dev-001',
          metricName: 'temperature_c',
          baselineAvg: '70.0',
          baselineMin: '65.0',
          baselineMax: '75.0',
          baselineStddev: '2.0',
          baselineP95: '74.0',
          sampleCount: 100,
          baselineWindowHoursCovered: 168,
        },
        {
          deviceId: 'dev-001',
          metricName: 'pressure_psi',
          baselineAvg: '100.0',
          baselineMin: '95.0',
          baselineMax: '105.0',
          baselineStddev: '2.0',
          baselineP95: '104.0',
          sampleCount: 100,
          baselineWindowHoursCovered: 168,
        },
      ]);

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAnomalies=true').expect(200);

      expect(response.body.data).toHaveLength(1);
      const device = response.body.data[0];

      // Temperature is anomalous (95 > p95=74 and > avg+2*stddev=74)
      // Pressure is anomalous (150 > p95=104 and > avg+2*stddev=104)
      expect(device.anomalyStatus).toBe('anomalous');
      expect(device.anomalyMetricCount).toBe(2);
    });

    it('should mark device as normal when no anomalies detected', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      listRecentByDeviceIdMock.mockResolvedValue([
        {
          timestamp: '2026-05-14T09:55:00.000Z',
          metricName: 'temperature_c',
          metricValue: '70.0',
          qualityCode: 'good',
          unit: 'C',
        },
      ]);

      listBaselineByDeviceIdMock.mockResolvedValue([
        {
          deviceId: 'dev-001',
          metricName: 'temperature_c',
          baselineAvg: '70.0',
          baselineMin: '65.0',
          baselineMax: '75.0',
          baselineStddev: '2.0',
          baselineP95: '74.0',
          sampleCount: 100,
          baselineWindowHoursCovered: 168,
        },
      ]);

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAnomalies=true').expect(200);

      const device = response.body.data[0];
      expect(device.anomalyStatus).toBe('normal');
      expect(device.anomalyMetricCount).toBe(0);
    });

    it('should mark device as unknown when no recent readings', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      listRecentByDeviceIdMock.mockResolvedValue([]);
      listBaselineByDeviceIdMock.mockResolvedValue([]);

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAnomalies=true').expect(200);

      const device = response.body.data[0];
      expect(device.anomalyStatus).toBe('unknown');
      expect(device.anomalyMetricCount).toBe(0);
    });

    it('should not include anomaly fields when includeAnomalies=false', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?includeAnomalies=false').expect(200);

      expect(response.body.data[0]).not.toHaveProperty('anomalyStatus');
      expect(response.body.data[0]).not.toHaveProperty('anomalyMetricCount');
    });
  });

  describe('anomaly status filtering', () => {
    beforeEach(() => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
          {
            deviceId: 'dev-002',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
          {
            deviceId: 'dev-003',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 3,
          totalPages: 1,
        },
      });

      // dev-001: anomalous
      listRecentByDeviceIdMock.mockImplementation(async (params: any) => {
        if (params.deviceId === 'dev-001') {
          return [
            {
              timestamp: '2026-05-14T09:55:00.000Z',
              metricName: 'temperature_c',
              metricValue: '95.0',
              qualityCode: 'good',
              unit: 'C',
            },
          ];
        }
        if (params.deviceId === 'dev-002') {
          return [
            {
              timestamp: '2026-05-14T09:55:00.000Z',
              metricName: 'temperature_c',
              metricValue: '70.0',
              qualityCode: 'good',
              unit: 'C',
            },
          ];
        }
        // dev-003: no readings (stale)
        return [];
      });

      listBaselineByDeviceIdMock.mockImplementation(async (params: any) => {
        if (params.deviceId === 'dev-001' || params.deviceId === 'dev-002') {
          return [
            {
              deviceId: params.deviceId,
              metricName: 'temperature_c',
              baselineAvg: '70.0',
              baselineMin: '65.0',
              baselineMax: '75.0',
              baselineStddev: '2.0',
              baselineP95: '74.0',
              sampleCount: 100,
              baselineWindowHoursCovered: 168,
            },
          ];
        }
        return [];
      });
    });

    it('should filter devices by anomalyStatus=anomalous', async () => {
      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app)
        .get('/api/v1/devices?anomalyStatus=anomalous&includeAnomalies=true')
        .expect(200);

      expect(response.body.data).toHaveLength(1);
      expect(response.body.data[0].deviceId).toBe('dev-001');
      expect(response.body.data[0].anomalyStatus).toBe('anomalous');
    });

    it('should filter devices by anomalyStatus=normal', async () => {
      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app)
        .get('/api/v1/devices?anomalyStatus=normal&includeAnomalies=true')
        .expect(200);

      expect(response.body.data).toHaveLength(1);
      expect(response.body.data[0].deviceId).toBe('dev-002');
      expect(response.body.data[0].anomalyStatus).toBe('normal');
    });

    it('should filter devices by anomalyStatus=unknown', async () => {
      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app)
        .get('/api/v1/devices?anomalyStatus=unknown&includeAnomalies=true')
        .expect(200);

      expect(response.body.data).toHaveLength(1);
      expect(response.body.data[0].deviceId).toBe('dev-003');
      expect(response.body.data[0].anomalyStatus).toBe('unknown');
    });

    it('should reject invalid anomalyStatus values', async () => {
      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?anomalyStatus=invalid').expect(400);

      expect(response.body.error.code).toBe('BAD_REQUEST');
      expect(response.body.error.message).toContain('Invalid anomalyStatus filter');
    });

    it('should auto-enable includeAnomalies when anomalyStatus filter is used', async () => {
      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app).get('/api/v1/devices?anomalyStatus=anomalous').expect(200);

      // Should still compute and filter by anomaly status
      expect(response.body.data).toHaveLength(1);
      expect(response.body.data[0].deviceId).toBe('dev-001');
    });
  });

  describe('combined enrichment', () => {
    it('should enrich with both alerts and anomalies when both flags are true', async () => {
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-001',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 1,
          pageSize: 10,
          totalItems: 1,
          totalPages: 1,
        },
      });

      listAlertsByDeviceIdMock.mockResolvedValue([
        {
          alertId: 'alert-1',
          severity: 'high',
          alertType: 'threshold_exceeded',
          raisedAt: '2026-05-14T09:00:00.000Z',
          acknowledged: false,
        },
      ]);

      listRecentByDeviceIdMock.mockResolvedValue([
        {
          timestamp: '2026-05-14T09:55:00.000Z',
          metricName: 'temperature_c',
          metricValue: '95.0',
          qualityCode: 'good',
          unit: 'C',
        },
      ]);

      listBaselineByDeviceIdMock.mockResolvedValue([
        {
          deviceId: 'dev-001',
          metricName: 'temperature_c',
          baselineAvg: '70.0',
          baselineMin: '65.0',
          baselineMax: '75.0',
          baselineStddev: '2.0',
          baselineP95: '74.0',
          sampleCount: 100,
          baselineWindowHoursCovered: 168,
        },
      ]);

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      const response = await request(app)
        .get('/api/v1/devices?includeAlerts=true&includeAnomalies=true')
        .expect(200);

      const device = response.body.data[0];

      // Alert enrichment
      expect(device.openAlertCount).toBe(1);
      expect(device.highestAlertSeverity).toBe('high');

      // Anomaly enrichment
      expect(device.anomalyStatus).toBe('anomalous');
      expect(device.anomalyMetricCount).toBe(1);
    });
  });

  describe('pagination with enrichment', () => {
    it('should only enrich devices in the current page', async () => {
      // Return page 2 with 2 devices
      listMock.mockResolvedValue({
        items: [
          {
            deviceId: 'dev-011',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
          {
            deviceId: 'dev-012',
            siteId: 'site-a',
            deviceType: 'sensor',
            status: 'online',
            firmwareVersion: '1.0.0',
            lastHeartbeat: '2026-05-14T10:00:00.000Z',
          },
        ],
        pagination: {
          page: 2,
          pageSize: 10,
          totalItems: 25,
          totalPages: 3,
        },
      });

      listAlertsByDeviceIdMock.mockResolvedValue([]);
      listRecentByDeviceIdMock.mockResolvedValue([]);
      listBaselineByDeviceIdMock.mockResolvedValue([]);

      const { createApp } = await import('../app.js');
      const app = createApp();
      const request = (await import('supertest')).default;

      await request(app)
        .get('/api/v1/devices?page=2&pageSize=10&includeAlerts=true&includeAnomalies=true')
        .expect(200);

      // Should only call enrichment for the 2 devices on page 2
      expect(listAlertsByDeviceIdMock).toHaveBeenCalledTimes(2);
      expect(listRecentByDeviceIdMock).toHaveBeenCalledTimes(2);
      expect(listBaselineByDeviceIdMock).toHaveBeenCalledTimes(2);
    });
  });
});

// Made with Bob
// REQ-004: Device list enrichment with alerts and anomalies
// REQ-007: Anomaly status filtering
