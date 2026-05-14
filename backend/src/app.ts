import express from 'express';
import { pinoHttp } from 'pino-http';

import { requestLoggerOptions } from './lib/logger.js';
import { errorHandler, notFoundHandler } from './middleware/error-handler.js';
import { requestIdMiddleware } from './middleware/request-id.js';
import { devicesRouter } from './routes/devices.js';
import { healthRouter } from './routes/health.js';
import { sitesRouter } from './routes/sites.js';

export function createApp() {
  const app = express();

  app.disable('x-powered-by');
  app.use(express.json());
  app.use(requestIdMiddleware);
  app.use(pinoHttp(requestLoggerOptions));

  app.get('/health', (_req, res) => {
    res.status(200).json({
      status: 'ok',
      service: 'sensor-health-dashboard-backend',
    });
  });

  app.use('/api', healthRouter);
  app.use('/api', devicesRouter);
  app.use('/api', sitesRouter);
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

// Made with Bob
