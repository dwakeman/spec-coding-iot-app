import type { NextFunction, Request, Response } from 'express';

import { CassandraDependencyError } from '../lib/cassandra.js';
import { PrestoDependencyError } from '../lib/presto.js';
import { logger } from '../lib/logger.js';

export class AppError extends Error {
  public readonly statusCode: number;
  public readonly code: string;
  public readonly details?: unknown;

  constructor(params: { message: string; statusCode: number; code: string; details?: unknown }) {
    super(params.message);
    this.name = 'AppError';
    this.statusCode = params.statusCode;
    this.code = params.code;
    this.details = params.details;
  }
}

export function notFoundHandler(req: Request, _res: Response, next: NextFunction) {
  next(
    new AppError({
      message: `Route not found: ${req.method} ${req.originalUrl}`,
      statusCode: 404,
      code: 'NOT_FOUND',
    }),
  );
}

export function errorHandler(
  err: unknown,
  req: Request,
  res: Response,
  _next: NextFunction,
) {
  const appError =
    err instanceof AppError
      ? err
      : err instanceof CassandraDependencyError || err instanceof PrestoDependencyError
        ? new AppError({
            message: err.message,
            statusCode: err.statusCode,
            code: err.code,
            details: err.details,
          })
        : new AppError({
            message: 'Internal server error',
            statusCode: 500,
            code: 'INTERNAL_SERVER_ERROR',
          });

  logger.error(
    {
      err,
      requestId: req.id,
      path: req.originalUrl,
      method: req.method,
      code: appError.code,
    },
    'request failed',
  );

  res.status(appError.statusCode).json({
    error: {
      code: appError.code,
      message: appError.message,
      requestId: req.id ?? 'unknown',
      details: appError.details,
    },
  });
}

// Made with Bob
