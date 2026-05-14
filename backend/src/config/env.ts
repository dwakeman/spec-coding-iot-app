import { fileURLToPath } from 'node:url';
import path from 'node:path';

import dotenv from 'dotenv';
import { z } from 'zod';

const currentFilePath = fileURLToPath(import.meta.url);
const currentDirectoryPath = path.dirname(currentFilePath);
const projectRootEnvPath = path.resolve(currentDirectoryPath, '../../../.env');

dotenv.config({ path: projectRootEnvPath });

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  SERVICE_NAME: z.string().min(1).default('sensor-health-dashboard-backend'),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  CASSANDRA_CONTACT_POINTS: z
    .string()
    .min(1)
    .transform((value) =>
      value
        .split(',')
        .map((entry) => entry.trim())
        .filter(Boolean),
    ),
  CASSANDRA_PORT: z.coerce.number().int().positive().default(9042),
  CASSANDRA_DATACENTER: z.string().min(1),
  CASSANDRA_KEYSPACE: z.string().min(1),
  CASSANDRA_USERNAME: z.string().min(1),
  CASSANDRA_PASSWORD: z.string().min(1),
  CASSANDRA_CONNECT_TIMEOUT_MS: z.coerce.number().int().positive().default(5000),
  CASSANDRA_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(5000),
  PRESTO_BASE_URL: z.string().url(),
  PRESTO_CATALOG: z.string().min(1),
  PRESTO_SCHEMA: z.string().min(1),
  PRESTO_USER: z.string().min(1),
  PRESTO_USERNAME: z.string().min(1),
  PRESTO_PASSWORD: z.string().min(1),
  PRESTO_TLS_REJECT_UNAUTHORIZED: z
    .enum(['true', 'false'])
    .default('true')
    .transform((value) => value === 'true'),
  PRESTO_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(10000),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
  const formatted = parsed.error.flatten().fieldErrors;
  throw new Error(`Invalid environment configuration: ${JSON.stringify(formatted)}`);
}

export const env = parsed.data;

// Made with Bob
