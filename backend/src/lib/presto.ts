import { Agent } from 'node:https';

import { env } from '../config/env.js';
import { logger } from './logger.js';

export class PrestoDependencyError extends Error {
  public readonly code = 'PRESTO_UNAVAILABLE';
  public readonly statusCode = 503;
  public readonly details?: unknown;

  constructor(message: string, details?: unknown) {
    super(message);
    this.name = 'PrestoDependencyError';
    this.details = details;
  }
}

interface PrestoQueryResponse {
  id?: string;
  nextUri?: string;
  columns?: Array<{
    name: string;
    type: string;
  }>;
  data?: unknown[][];
  error?: {
    message?: string;
    errorCode?: number;
    errorName?: string;
    errorType?: string;
  };
}

function buildBasicAuthorizationHeader() {
  const encodedCredentials = Buffer.from(`${env.PRESTO_USERNAME}:${env.PRESTO_PASSWORD}`, 'utf8').toString('base64');

  return `Basic ${encodedCredentials}`;
}

function buildPrestoHeaders() {
  return {
    Authorization: buildBasicAuthorizationHeader(),
    'X-Presto-User': env.PRESTO_USER,
    'X-Presto-Catalog': env.PRESTO_CATALOG,
    'X-Presto-Schema': env.PRESTO_SCHEMA,
    'Content-Type': 'text/plain',
    Accept: 'application/json',
  };
}

async function readResponseBodySafely(response: Response) {
  try {
    return await response.text();
  } catch {
    return '[unavailable]';
  }
}

function normalizeUnknownError(error: unknown) {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack,
      cause: error.cause,
    };
  }

  return {
    value: error,
  };
}

const prestoHttpsAgent = new Agent({
  rejectUnauthorized: env.PRESTO_TLS_REJECT_UNAUTHORIZED,
});

async function fetchWithTimeout(url: string, init: RequestInit) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.PRESTO_REQUEST_TIMEOUT_MS);

  try {
    return await fetch(url, {
      ...init,
      signal: controller.signal,
      dispatcher: prestoHttpsAgent,
    } as RequestInit & { dispatcher: Agent });
  } catch (error) {
    throw new PrestoDependencyError('Presto network request failed', {
      url,
      method: init.method ?? 'GET',
      timeoutMs: env.PRESTO_REQUEST_TIMEOUT_MS,
      tlsRejectUnauthorized: env.PRESTO_TLS_REJECT_UNAUTHORIZED,
      error: normalizeUnknownError(error),
    });
  } finally {
    clearTimeout(timeout);
  }
}

function mapRows<T>(response: PrestoQueryResponse): T[] {
  if (!response.columns?.length || !response.data?.length) {
    return [];
  }

  return response.data.map((row) => {
    const mappedRow = response.columns!.reduce<Record<string, unknown>>((accumulator, column, index) => {
      accumulator[column.name] = row[index] ?? null;
      return accumulator;
    }, {});

    return mappedRow as T;
  });
}

export async function executePrestoQuery<T = Record<string, unknown>>(query: string): Promise<T[]> {
  const startedAt = Date.now();
  let response: PrestoQueryResponse | null = null;

  try {
    const initialResponse = await fetchWithTimeout(`${env.PRESTO_BASE_URL}/v1/statement`, {
      method: 'POST',
      headers: buildPrestoHeaders(),
      body: query,
    });

    if (!initialResponse.ok) {
      throw new PrestoDependencyError('Presto query request failed', {
        url: `${env.PRESTO_BASE_URL}/v1/statement`,
        status: initialResponse.status,
        statusText: initialResponse.statusText,
        body: await readResponseBodySafely(initialResponse),
      });
    }

    const initialResponseBody = await readResponseBodySafely(initialResponse);

    try {
      response = JSON.parse(initialResponseBody) as PrestoQueryResponse;
    } catch {
      throw new PrestoDependencyError('Presto returned a non-JSON initial response', {
        url: `${env.PRESTO_BASE_URL}/v1/statement`,
        body: initialResponseBody,
      });
    }

    while (response?.nextUri) {
      if (response.error) {
        throw new PrestoDependencyError('Presto query execution failed', response.error);
      }

      const nextResponse = await fetchWithTimeout(response.nextUri, {
        method: 'GET',
        headers: buildPrestoHeaders(),
      });

      if (!nextResponse.ok) {
        throw new PrestoDependencyError('Presto query polling failed', {
          url: response.nextUri,
          status: nextResponse.status,
          statusText: nextResponse.statusText,
          body: await readResponseBodySafely(nextResponse),
        });
      }

      const nextResponseBody = await readResponseBodySafely(nextResponse);

      try {
        response = JSON.parse(nextResponseBody) as PrestoQueryResponse;
      } catch {
        throw new PrestoDependencyError('Presto returned a non-JSON polling response', {
          url: response.nextUri,
          body: nextResponseBody,
        });
      }
    }

    if (response?.error) {
      throw new PrestoDependencyError('Presto query execution failed', response.error);
    }

    const rows = mapRows<T>(response ?? {});

    logger.debug(
      {
        durationMs: Date.now() - startedAt,
        rowLength: rows.length,
        query,
      },
      'presto query completed',
    );

    return rows;
  } catch (error) {
    if (error instanceof PrestoDependencyError) {
      throw error;
    }

    throw new PrestoDependencyError('Presto query execution failed', {
      query,
      error: normalizeUnknownError(error),
    });
  }
}

export async function checkPrestoHealth() {
  const rows = await executePrestoQuery<{ now: string }>('SELECT now() AS now');

  return {
    status: 'ok' as const,
    baseUrl: env.PRESTO_BASE_URL,
    catalog: env.PRESTO_CATALOG,
    schema: env.PRESTO_SCHEMA,
    rowCount: rows.length,
  };
}

// Made with Bob