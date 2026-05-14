import { Client, types } from 'cassandra-driver';

import { env } from '../config/env.js';
import { logger } from './logger.js';

export class CassandraDependencyError extends Error {
  public readonly code = 'CASSANDRA_UNAVAILABLE';
  public readonly statusCode = 503;
  public readonly details?: unknown;

  constructor(message: string, details?: unknown) {
    super(message);
    this.name = 'CassandraDependencyError';
    this.details = details;
  }
}

const cassandraClient = new Client({
  contactPoints: env.CASSANDRA_CONTACT_POINTS,
  localDataCenter: env.CASSANDRA_DATACENTER,
  keyspace: env.CASSANDRA_KEYSPACE,
  protocolOptions: {
    port: env.CASSANDRA_PORT,
  },
  credentials: {
    username: env.CASSANDRA_USERNAME,
    password: env.CASSANDRA_PASSWORD,
  },
  socketOptions: {
    connectTimeout: env.CASSANDRA_CONNECT_TIMEOUT_MS,
    readTimeout: env.CASSANDRA_REQUEST_TIMEOUT_MS,
  },
});

let isConnected = false;

async function ensureConnected() {
  if (isConnected) {
    return;
  }

  try {
    await cassandraClient.connect();
    isConnected = true;
    logger.info(
      {
        contactPoints: env.CASSANDRA_CONTACT_POINTS,
        keyspace: env.CASSANDRA_KEYSPACE,
        dataCenter: env.CASSANDRA_DATACENTER,
      },
      'cassandra connection established',
    );
  } catch (error) {
    throw new CassandraDependencyError('Failed to connect to Cassandra', error);
  }
}

export async function executeCassandraQuery<T = types.Row>(
  query: string,
  params: unknown[] = [],
) {
  await ensureConnected();

  const startedAt = Date.now();

  try {
    const result = await cassandraClient.execute(query, params, {
      prepare: true,
      readTimeout: env.CASSANDRA_REQUEST_TIMEOUT_MS,
    });

    logger.debug(
      {
        durationMs: Date.now() - startedAt,
        rowLength: result.rowLength,
        query,
      },
      'cassandra query completed',
    );

    return result.rows as T[];
  } catch (error) {
    throw new CassandraDependencyError('Cassandra query execution failed', {
      query,
      error,
    });
  }
}

export async function checkCassandraHealth() {
  const rows = await executeCassandraQuery<{ now: string }>('SELECT now() FROM system.local');
  return {
    status: 'ok' as const,
    contactPoints: env.CASSANDRA_CONTACT_POINTS,
    keyspace: env.CASSANDRA_KEYSPACE,
    rowCount: rows.length,
  };
}

export function getCassandraClient() {
  return cassandraClient;
}

// Made with Bob
