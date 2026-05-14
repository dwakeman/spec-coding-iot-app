import type { NextFunction, Request, Response } from 'express';
import { randomUUID } from 'node:crypto';

export function requestIdMiddleware(req: Request, res: Response, next: NextFunction) {
  const requestId = req.header('x-request-id') ?? randomUUID();

  req.id = requestId;
  res.setHeader('x-request-id', requestId);

  next();
}

// Made with Bob
