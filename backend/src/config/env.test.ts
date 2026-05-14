import { describe, expect, it } from 'vitest';

import { env } from './env.js';

describe('environment configuration', () => {
  it('loads Cassandra and Presto connectivity settings', () => {
    expect(env.CASSANDRA_CONTACT_POINTS.length).toBeGreaterThan(0);
    expect(env.CASSANDRA_PORT).toBeGreaterThan(0);
    expect(env.CASSANDRA_DATACENTER.length).toBeGreaterThan(0);
    expect(env.CASSANDRA_KEYSPACE).toBe('iot');
    expect(env.CASSANDRA_USERNAME.length).toBeGreaterThan(0);
    expect(env.CASSANDRA_PASSWORD.length).toBeGreaterThan(0);

    expect(env.PRESTO_BASE_URL).toBe('https://localhost:8443');
    expect(env.PRESTO_CATALOG).toBe('iceberg_data');
    expect(env.PRESTO_SCHEMA).toBe('iot');
    expect(env.PRESTO_USER).toBe('test-presto-user');
    expect(env.PRESTO_USERNAME).toBe('test-presto-user');
    expect(env.PRESTO_PASSWORD).toBe('test-presto-password');
    expect(env.PRESTO_TLS_REJECT_UNAUTHORIZED).toBe(true);
    expect(env.PRESTO_REQUEST_TIMEOUT_MS).toBe(10000);
  });
});

// Made with Bob
