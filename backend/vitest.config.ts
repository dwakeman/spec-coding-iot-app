import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    globals: true,
    include: ['src/**/*.test.ts'],
    env: {
      CASSANDRA_CONTACT_POINTS: '127.0.0.1',
      CASSANDRA_PORT: '9042',
      CASSANDRA_DATACENTER: 'datacenter1',
      CASSANDRA_KEYSPACE: 'iot',
      CASSANDRA_USERNAME: 'test-user',
      CASSANDRA_PASSWORD: 'test-password',
      CASSANDRA_CONNECT_TIMEOUT_MS: '5000',
      CASSANDRA_REQUEST_TIMEOUT_MS: '5000',
      PRESTO_BASE_URL: 'https://localhost:8443',
      PRESTO_CATALOG: 'iceberg_data',
      PRESTO_SCHEMA: 'iot',
      PRESTO_USER: 'test-presto-user',
      PRESTO_USERNAME: 'test-presto-user',
      PRESTO_PASSWORD: 'test-presto-password',
      PRESTO_TLS_REJECT_UNAUTHORIZED: 'true',
      PRESTO_REQUEST_TIMEOUT_MS: '10000',
    },
  },
});

// Made with Bob
