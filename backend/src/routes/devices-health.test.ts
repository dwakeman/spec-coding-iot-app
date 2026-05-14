import { beforeEach, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import express, { type Express } from 'express';

import { devicesRouter } from './devices.js';
import { errorHandler } from '../middleware/error-handler.js';
import { deviceStateRepository } from '../repositories/device-state-repository.js';
import * as deviceHealthService from '../services/device-health-service.js';
import type { DeviceState } from '../domain/device-state.js';

vi.mock('../repositories/device-state-repository.js');
vi.mock('../services/device-health-service.js');

function createMockDevice(deviceId: string, status: 'online' | 'offline' | 'degraded' | 'maintenance' = 'online'): DeviceState {
  return {
    deviceId,
    siteId: 'site-001',
    deviceType: 'sensor',
    deviceClass: 'environmental',
    model: 'ENV-2000',
    status,
    firmwareVersion: '2.1.0',
    lastHeartbeat: '2024-01-15T10:30:00Z',
    lastReadingValue: '22.5',
    batteryPercent: 85,
    signalStrengthDbm: -65,
    zone: 'zone-a',
    installedAt: '2024-01-01T00:00:00Z',
    updatedAt: '2024-01-15T10:30:00Z',
  };
}

describe('GET /v1/devices/:deviceId/health', () => {
  let app: Express;

  beforeEach(() => {
    vi.clearAllMocks();
    app = express();
    app.use('/api', devicesRouter);
    app.use(errorHandler);
  });

  it('returns composite health for a valid device with default parameters', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId);

    const mockHealth = {
      device: mockDevice,
      summary: {
        deviceAnomalyStatus: 'normal' as const,
        anomalyMetricCount: 0,
        severity: 'normal' as const,
        dataFreshness: 'fresh' as const,
        highestAlertSeverity: null,
        openAlertCount: 0,
      },
      metricHealth: [
        {
          metricName: 'temperature',
          latestReading: {
            timestamp: '2024-01-15T10:25:00.000Z',
            metricName: 'temperature',
            metricValue: '22.5',
            unit: 'C',
            qualityCode: 'good',
          },
          unit: 'C',
          qualityCode: 'good' as const,
          recentReadingCount: 12,
          anomalyStatus: 'normal' as const,
          anomalyReason: null,
          baseline: {
            deviceId,
            metricName: 'temperature',
            baselineAvg: '21.8',
            baselineP95: '24.2',
            baselineMin: '18.5',
            baselineMax: '25.1',
            baselineStddev: '1.2',
            sampleCount: 168,
            baselineWindowHoursCovered: 168,
          },
        },
      ],
      readings: [
        {
          timestamp: '2024-01-15T10:25:00.000Z',
          metricName: 'temperature',
          metricValue: '22.5',
          unit: 'C',
          qualityCode: 'good',
        },
      ],
      alerts: [],
    };

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);
    vi.mocked(deviceHealthService.getDeviceHealth).mockResolvedValue(mockHealth);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health`);

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      device: mockDevice,
      summary: mockHealth.summary,
      metricHealth: mockHealth.metricHealth,
      readings: mockHealth.readings,
      alerts: mockHealth.alerts,
      supportedRequirements: {
        requirementIds: [
          'REQ-002',
          'REQ-003',
          'REQ-004',
          'REQ-005',
          'REQ-007',
          'REQ-008',
          'REQ-009',
          'REQ-010',
        ],
      },
    });

    expect(deviceHealthService.getDeviceHealth).toHaveBeenCalledWith({
      deviceId,
      readingsWindowMinutes: 60,
      baselineWindowDays: 7,
    });
  });

  it('accepts custom windowMinutes and baselineDays parameters', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId);

    const mockHealth = {
      device: mockDevice,
      summary: {
        deviceAnomalyStatus: 'normal' as const,
        anomalyMetricCount: 0,
        severity: 'normal' as const,
        dataFreshness: 'fresh' as const,
        highestAlertSeverity: null,
        openAlertCount: 0,
      },
      metricHealth: [],
      readings: [],
      alerts: [],
    };

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);
    vi.mocked(deviceHealthService.getDeviceHealth).mockResolvedValue(mockHealth);

    const response = await request(app).get(
      `/api/v1/devices/${deviceId}/health?windowMinutes=30&baselineDays=14`,
    );

    expect(response.status).toBe(200);
    expect(deviceHealthService.getDeviceHealth).toHaveBeenCalledWith({
      deviceId,
      readingsWindowMinutes: 30,
      baselineWindowDays: 14,
    });
  });

  it('returns 400 for invalid deviceId format', async () => {
    const response = await request(app).get('/api/v1/devices/not-a-uuid/health');

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(response.body.error.message).toContain('Invalid deviceId');
  });

  it('returns 400 for windowMinutes exceeding maximum', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId);

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health?windowMinutes=120`);

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(response.body.error.message).toContain('Invalid windowMinutes');
  });

  it('returns 400 for baselineDays exceeding maximum', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId);

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health?baselineDays=45`);

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('BAD_REQUEST');
    expect(response.body.error.message).toContain('Invalid baselineDays');
  });

  it('returns 404 when device does not exist', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(null);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health`);

    expect(response.status).toBe(404);
    expect(response.body.error.code).toBe('NOT_FOUND');
    expect(response.body.error.message).toContain('Device not found');
  });

  it('returns 502 when health service returns null', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId);

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);
    vi.mocked(deviceHealthService.getDeviceHealth).mockResolvedValue(null);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health`);

    expect(response.status).toBe(502);
    expect(response.body.error.code).toBe('BAD_GATEWAY');
    expect(response.body.error.message).toContain('Unable to retrieve health data');
  });

  it('returns composite health with anomalies and alerts', async () => {
    const deviceId = '550e8400-e29b-41d4-a716-446655440000';
    const mockDevice = createMockDevice(deviceId, 'degraded');

    const mockHealth = {
      device: mockDevice,
      summary: {
        deviceAnomalyStatus: 'anomalous' as const,
        anomalyMetricCount: 2,
        severity: 'high' as const,
        dataFreshness: 'fresh' as const,
        highestAlertSeverity: 'high',
        openAlertCount: 1,
      },
      metricHealth: [
        {
          metricName: 'temperature',
          latestReading: {
            timestamp: '2024-01-15T10:25:00.000Z',
            metricName: 'temperature',
            metricValue: '35.2',
            unit: 'C',
            qualityCode: 'good',
          },
          unit: 'C',
          qualityCode: 'good',
          recentReadingCount: 12,
          anomalyStatus: 'anomalous' as const,
          anomalyReason: 'Value 35.2 exceeds baseline P95 (24.2)',
          baseline: {
            deviceId,
            metricName: 'temperature',
            baselineAvg: '21.8',
            baselineP95: '24.2',
            baselineMin: '18.5',
            baselineMax: '25.1',
            baselineStddev: '1.2',
            sampleCount: 168,
            baselineWindowHoursCovered: 168,
          },
        },
        {
          metricName: 'pressure',
          latestReading: {
            timestamp: '2024-01-15T10:25:00.000Z',
            metricName: 'pressure',
            metricValue: '1050.5',
            unit: 'hPa',
            qualityCode: 'good',
          },
          unit: 'hPa',
          qualityCode: 'good',
          recentReadingCount: 12,
          anomalyStatus: 'anomalous' as const,
          anomalyReason: 'Deviation from baseline avg exceeds 2 stddev threshold',
          baseline: {
            deviceId,
            metricName: 'pressure',
            baselineAvg: '1013.2',
            baselineP95: '1020.5',
            baselineMin: '1005.0',
            baselineMax: '1022.0',
            baselineStddev: '5.2',
            sampleCount: 168,
            baselineWindowHoursCovered: 168,
          },
        },
      ],
      readings: [
        {
          timestamp: '2024-01-15T10:25:00.000Z',
          metricName: 'temperature',
          metricValue: '35.2',
          unit: 'C',
          qualityCode: 'good',
        },
        {
          timestamp: '2024-01-15T10:25:00.000Z',
          metricName: 'pressure',
          metricValue: '1050.5',
          unit: 'hPa',
          qualityCode: 'good',
        },
      ],
      alerts: [
        {
          alertId: '123e4567-e89b-12d3-a456-426614174000',
          deviceId,
          raisedAt: '2024-01-15T10:15:00.000Z',
          severity: 'high',
          alertType: 'threshold_breach',
          metricName: 'temperature',
          metricValue: '35.2',
          thresholdValue: '30.0',
          siteId: 'site-001',
          acknowledged: false,
        },
      ],
    };

    vi.mocked(deviceStateRepository.findByDeviceId).mockResolvedValue(mockDevice);
    vi.mocked(deviceHealthService.getDeviceHealth).mockResolvedValue(mockHealth);

    const response = await request(app).get(`/api/v1/devices/${deviceId}/health`);

    expect(response.status).toBe(200);
    expect(response.body.summary.deviceAnomalyStatus).toBe('anomalous');
    expect(response.body.summary.anomalyMetricCount).toBe(2);
    expect(response.body.summary.openAlertCount).toBe(1);
    expect(response.body.metricHealth).toHaveLength(2);
    expect(response.body.alerts).toHaveLength(1);
  });
});

// Made with Bob
