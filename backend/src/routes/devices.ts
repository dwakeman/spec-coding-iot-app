import { Router } from 'express';
import { validate as isUuid } from 'uuid';

import { AppError } from '../middleware/error-handler.js';
import { alertsRepository } from '../repositories/alerts-repository.js';
import { baselineRepository } from '../repositories/baseline-repository.js';
import { deviceStateRepository } from '../repositories/device-state-repository.js';
import { readingsRepository } from '../repositories/readings-repository.js';
import { getDeviceHealth } from '../services/device-health-service.js';
import { enrichDeviceList } from '../services/device-list-enrichment-service.js';

const allowedSortValues = new Set(['lastHeartbeat:desc']);
const allowedStatuses = new Set(['online', 'offline', 'degraded', 'maintenance']);
const allowedAnomalyStatuses = new Set(['normal', 'anomalous', 'unknown']);

function parsePositiveInteger(value: string | undefined, fallback: number, field: string) {
  if (value === undefined) {
    return fallback;
  }

  const parsed = Number.parseInt(value, 10);

  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new AppError({
      message: `Invalid ${field}. Expected a positive integer.`,
      statusCode: 400,
      code: 'BAD_REQUEST',
      details: {
        [field]: value,
      },
    });
  }

  return parsed;
}

function validateDeviceId(deviceId: string) {
  if (!isUuid(deviceId)) {
    throw new AppError({
      message: 'Invalid deviceId. Expected UUID format.',
      statusCode: 400,
      code: 'BAD_REQUEST',
      details: {
        deviceId,
      },
    });
  }
}

export const devicesRouter = Router();

devicesRouter.get('/v1/devices', async (req, res, next) => {
  const siteId = typeof req.query.siteId === 'string' ? req.query.siteId : undefined;
  const status = typeof req.query.status === 'string' ? req.query.status : undefined;
  const anomalyStatus = typeof req.query.anomalyStatus === 'string' ? req.query.anomalyStatus : undefined;
  const sort = typeof req.query.sort === 'string' ? req.query.sort : 'lastHeartbeat:desc';
  const includeAlerts = req.query.includeAlerts !== 'false';
  const includeAnomalies = req.query.includeAnomalies !== 'false';

  try {
    const page = parsePositiveInteger(
      typeof req.query.page === 'string' ? req.query.page : undefined,
      1,
      'page',
    );
    const pageSize = parsePositiveInteger(
      typeof req.query.pageSize === 'string' ? req.query.pageSize : undefined,
      25,
      'pageSize',
    );

    if (!allowedSortValues.has(sort)) {
      next(
        new AppError({
          message: `Unsupported sort field: ${sort}`,
          statusCode: 422,
          code: 'UNPROCESSABLE_ENTITY',
          details: {
            sort,
            allowed: [...allowedSortValues],
          },
        }),
      );
      return;
    }

    if (status && !allowedStatuses.has(status)) {
      next(
        new AppError({
          message: `Invalid status filter: ${status}`,
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            status,
            allowed: [...allowedStatuses],
          },
        }),
      );
      return;
    }

    if (anomalyStatus && !allowedAnomalyStatuses.has(anomalyStatus)) {
      next(
        new AppError({
          message: `Invalid anomalyStatus filter: ${anomalyStatus}`,
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            anomalyStatus,
            allowed: [...allowedAnomalyStatuses],
          },
        }),
      );
      return;
    }

    const result = await deviceStateRepository.list({
      siteId,
      status,
      sort: 'lastHeartbeat:desc',
      page,
      pageSize,
    });

    // Enrich devices with alerts and anomalies
    const enrichmentMap = await enrichDeviceList({
      devices: result.items,
      includeAlerts,
      includeAnomalies,
    });

    // Map devices to enriched summaries
    let enrichedDevices = result.items.map((device) => {
      const enrichment = enrichmentMap.get(device.deviceId)!;
      const result: any = { ...device };
      
      // Only add alert fields if includeAlerts is true
      if (includeAlerts) {
        result.openAlertCount = enrichment.openAlertCount;
        result.highestAlertSeverity = enrichment.highestAlertSeverity;
      }
      
      // Only add anomaly fields if includeAnomalies is true
      if (includeAnomalies) {
        result.anomalyStatus = enrichment.anomalyStatus;
        result.anomalyMetricCount = enrichment.anomalyMetricCount;
      }
      
      return result;
    });

    // Apply anomaly status filter if specified
    if (anomalyStatus) {
      enrichedDevices = enrichedDevices.filter((d) => d.anomalyStatus === anomalyStatus);
    }

    res.status(200).json({
      data: enrichedDevices,
      pagination: result.pagination,
    });
  } catch (error) {
    next(error);
  }
});

devicesRouter.get('/v1/devices/:deviceId/readings', async (req, res, next) => {
  const { deviceId } = req.params;

  try {
    validateDeviceId(deviceId);

    const windowMinutes = parsePositiveInteger(
      typeof req.query.windowMinutes === 'string' ? req.query.windowMinutes : undefined,
      60,
      'windowMinutes',
    );

    if (windowMinutes > 60) {
      next(
        new AppError({
          message: 'Invalid windowMinutes. Maximum supported value is 60.',
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            windowMinutes,
          },
        }),
      );
      return;
    }

    const device = await deviceStateRepository.findByDeviceId(deviceId);

    if (!device) {
      next(
        new AppError({
          message: `Device not found: ${deviceId}`,
          statusCode: 404,
          code: 'NOT_FOUND',
        }),
      );
      return;
    }

    const readings = await readingsRepository.listRecentByDeviceId({
      deviceId,
      windowMinutes,
    });

    res.status(200).json({
      deviceId,
      windowMinutes,
      items: readings,
      supportedRequirements: {
        requirementIds: ['REQ-002', 'REQ-008'],
      },
    });
  } catch (error) {
    next(error);
  }
});

devicesRouter.get('/v1/devices/:deviceId/baseline', async (req, res, next) => {
  const { deviceId } = req.params;

  try {
    validateDeviceId(deviceId);

    const windowDays = parsePositiveInteger(
      typeof req.query.windowDays === 'string' ? req.query.windowDays : undefined,
      7,
      'windowDays',
    );

    if (windowDays > 30) {
      next(
        new AppError({
          message: 'Invalid windowDays. Maximum supported value is 30.',
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            windowDays,
          },
        }),
      );
      return;
    }

    const device = await deviceStateRepository.findByDeviceId(deviceId);

    if (!device) {
      next(
        new AppError({
          message: `Device not found: ${deviceId}`,
          statusCode: 404,
          code: 'NOT_FOUND',
        }),
      );
      return;
    }

    const items = await baselineRepository.listByDeviceId({
      deviceId,
      windowDays,
    });

    res.status(200).json({
      deviceId,
      windowDays,
      items: items.map((item) => ({
        metricName: item.metricName,
        baselineAvg: item.baselineAvg === '' ? null : Number(item.baselineAvg),
        baselineP95: item.baselineP95 === '' ? null : Number(item.baselineP95),
        baselineMin: item.baselineMin === '' ? null : Number(item.baselineMin),
        baselineMax: item.baselineMax === '' ? null : Number(item.baselineMax),
        baselineStddev: item.baselineStddev === '' ? null : Number(item.baselineStddev),
        sampleCount: item.sampleCount,
        baselineWindowDays: windowDays,
        baselineWindowHoursCovered: item.baselineWindowHoursCovered,
      })),
      supportedRequirements: {
        requirementIds: ['REQ-003', 'REQ-008', 'REQ-009'],
      },
    });
  } catch (error) {
    next(error);
  }
});

devicesRouter.get('/v1/devices/:deviceId/alerts', async (req, res, next) => {
  const { deviceId } = req.params;

  try {
    validateDeviceId(deviceId);

    const device = await deviceStateRepository.findByDeviceId(deviceId);

    if (!device) {
      next(
        new AppError({
          message: `Device not found: ${deviceId}`,
          statusCode: 404,
          code: 'NOT_FOUND',
        }),
      );
      return;
    }

    const alerts = await alertsRepository.listByDeviceId(deviceId);

    res.status(200).json({
      deviceId,
      items: alerts,
      supportedRequirements: {
        requirementIds: ['REQ-005', 'REQ-007'],
      },
    });
  } catch (error) {
    next(error);
  }
});

devicesRouter.get('/v1/devices/:deviceId/health', async (req, res, next) => {
  const { deviceId } = req.params;

  try {
    validateDeviceId(deviceId);

    const windowMinutes = parsePositiveInteger(
      typeof req.query.windowMinutes === 'string' ? req.query.windowMinutes : undefined,
      60,
      'windowMinutes',
    );

    const baselineDays = parsePositiveInteger(
      typeof req.query.baselineDays === 'string' ? req.query.baselineDays : undefined,
      7,
      'baselineDays',
    );

    if (windowMinutes > 60) {
      next(
        new AppError({
          message: 'Invalid windowMinutes. Maximum supported value is 60.',
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            windowMinutes,
          },
        }),
      );
      return;
    }

    if (baselineDays > 30) {
      next(
        new AppError({
          message: 'Invalid baselineDays. Maximum supported value is 30.',
          statusCode: 400,
          code: 'BAD_REQUEST',
          details: {
            baselineDays,
          },
        }),
      );
      return;
    }

    const device = await deviceStateRepository.findByDeviceId(deviceId);

    if (!device) {
      next(
        new AppError({
          message: `Device not found: ${deviceId}`,
          statusCode: 404,
          code: 'NOT_FOUND',
        }),
      );
      return;
    }

    const health = await getDeviceHealth({
      deviceId,
      readingsWindowMinutes: windowMinutes,
      baselineWindowDays: baselineDays,
    });

    if (!health) {
      next(
        new AppError({
          message: `Unable to retrieve health data for device: ${deviceId}`,
          statusCode: 502,
          code: 'BAD_GATEWAY',
        }),
      );
      return;
    }

    res.status(200).json({
      device: health.device,
      summary: health.summary,
      metricHealth: health.metricHealth,
      readings: health.readings,
      alerts: health.alerts,
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
  } catch (error) {
    next(error);
  }
});

devicesRouter.get('/v1/devices/:deviceId', async (req, res, next) => {
  const { deviceId } = req.params;

  try {
    validateDeviceId(deviceId);

    const device = await deviceStateRepository.findByDeviceId(deviceId);

    if (!device) {
      next(
        new AppError({
          message: `Device not found: ${deviceId}`,
          statusCode: 404,
          code: 'NOT_FOUND',
        }),
      );
      return;
    }

    res.status(200).json({
      data: device,
    });
  } catch (error) {
    next(error);
  }
});

// Made with Bob