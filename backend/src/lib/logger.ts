import pino from 'pino';
import type { Options } from 'pino-http';

import { env } from '../config/env.js';

export const logger = pino({
  name: env.SERVICE_NAME,
  level: env.LOG_LEVEL,
});

export const requestLoggerOptions: Options = {
  logger,
  customProps: (req) => ({
    requestId: req.id,
  }),
};

// Made with Bob
