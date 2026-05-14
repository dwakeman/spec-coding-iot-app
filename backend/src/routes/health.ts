import { Router } from 'express';

import { checkCassandraHealth } from '../lib/cassandra.js';
import { checkPrestoHealth } from '../lib/presto.js';
import { AppError } from '../middleware/error-handler.js';

export const healthRouter = Router();

healthRouter.get('/health', (_req, res) => {
  res.status(200).json({
    status: 'ok',
  });
});

healthRouter.get('/health/dependencies', async (_req, res, next) => {
  try {
    const [cassandra, presto] = await Promise.all([checkCassandraHealth(), checkPrestoHealth()]);

    res.status(200).json({
      status: 'ok',
      dependencies: {
        cassandra,
        presto,
      },
    });
  } catch (error) {
    next(
      error instanceof Error
        ? error
        : new AppError({
            message: 'Failed to evaluate dependency health',
            statusCode: 503,
            code: 'DEPENDENCY_UNAVAILABLE',
            details: error,
          }),
    );
  }
});

// Made with Bob
