# Observability and Resilience

This document describes the observability and resilience patterns implemented in the Sensor Health Dashboard backend.

## Observability (SHD-028)

### Request Tracing

**Request IDs:**
- Every request gets a unique request ID (UUID)
- Accepts `x-request-id` header from clients or generates new UUID
- Request ID included in all logs and error responses
- Implementation: `backend/src/middleware/request-id.ts`

**Request Logging:**
- All HTTP requests/responses logged via `pino-http`
- Logs include: method, path, status code, duration, request ID
- Implementation: `backend/src/app.ts` (line 17)

### Query Timing

**Cassandra Queries:**
- Every query logs execution duration at debug level
- Log includes: `durationMs`, `rowLength`, `query`
- Implementation: `backend/src/lib/cassandra.ts` (lines 72-79)

**Presto Queries:**
- Every query logs execution duration at debug level
- Log includes: `durationMs`, `rowLength`, `query`
- Implementation: `backend/src/lib/presto.ts` (lines 184-191)

### Structured Logging

**Logger Configuration:**
- Pino structured JSON logger
- Configurable log level via `LOG_LEVEL` environment variable
- Service name included in all logs
- Implementation: `backend/src/lib/logger.ts`

**Log Levels:**
- `info`: Service startup, connection establishment
- `debug`: Query timing, detailed operation logs
- `error`: Request failures, dependency errors

### Dependency Error Categorization

**Cassandra Errors:**
- Custom `CassandraDependencyError` class
- Error code: `CASSANDRA_UNAVAILABLE`
- HTTP status: 503 Service Unavailable
- Includes structured `details` field with diagnostic context

**Presto Errors:**
- Custom `PrestoDependencyError` class
- Error code: `PRESTO_UNAVAILABLE`
- HTTP status: 503 Service Unavailable
- Includes structured `details` field with diagnostic context

**Error Response Format:**
```json
{
  "error": {
    "code": "CASSANDRA_UNAVAILABLE",
    "message": "Cassandra query execution failed",
    "requestId": "550e8400-e29b-41d4-a716-446655440000",
    "details": {
      "query": "SELECT * FROM ...",
      "error": { ... }
    }
  }
}
```

### Secret Protection

**What is NOT logged:**
- Passwords
- API tokens
- Database credentials
- Authorization headers

**What IS logged:**
- Connection endpoints (host, port)
- Keyspace/schema names
- Query text (no parameter values)
- Error messages and stack traces

## Resilience (SHD-029)

### Timeout Configuration

**Cassandra Timeouts:**
- Connection timeout: `CASSANDRA_CONNECT_TIMEOUT_MS` (default: 5000ms)
- Read timeout: `CASSANDRA_REQUEST_TIMEOUT_MS` (default: 12000ms)
- Configured per query execution
- Implementation: `backend/src/lib/cassandra.ts` (lines 30-31, 69)

**Presto Timeouts:**
- Request timeout: `PRESTO_REQUEST_TIMEOUT_MS` (default: 30000ms)
- Implemented via `AbortController`
- Applies to both initial query submission and result polling
- Implementation: `backend/src/lib/presto.ts` (lines 79-80)

### Error Handling

**Structured Error Propagation:**
- All dependency failures throw typed errors
- Error middleware catches and standardizes responses
- Consistent HTTP status codes across all endpoints
- Implementation: `backend/src/middleware/error-handler.ts`

**Error Middleware Flow:**
1. Catch all errors (typed and untyped)
2. Map to `AppError` with consistent structure
3. Log error with request context
4. Return standardized JSON error response

### Retry Strategy

**Design Decision: No Automatic Retries**

We intentionally do NOT implement automatic retries for the following reasons:

**Cassandra (Hot Operational Data):**
- ✅ Fast queries (<100ms typical)
- ❌ Retrying amplifies load during outages
- ✅ Better to fail fast and alert
- ✅ Driver has built-in connection pooling and reconnection
- ✅ Transient failures are rare with proper infrastructure

**Presto (Cold Analytical Data):**
- ✅ Slow queries (seconds to minutes)
- ❌ Retrying wastes resources
- ✅ Better to fail and let user retry manually
- ✅ Analytical queries are not time-critical
- ✅ Transient failures are rare for batch analytics

**Alternative: Graceful Degradation**

Instead of retries, we use graceful degradation:

1. **Composite Health Service** (`backend/src/services/device-health-service.ts`):
   - Loads data from multiple sources in parallel
   - Catches errors from individual sources
   - Returns partial data when some sources fail
   - Example: If baseline fails, still returns device state, readings, and alerts

2. **Dashboard Enrichment** (`backend/src/services/device-list-enrichment-service.ts`):
   - Enriches device list with alerts and anomalies
   - Catches errors per-device and continues
   - Returns best-effort enrichment

3. **Frontend Handling**:
   - UI shows appropriate empty states for missing data
   - Error states don't break page layout
   - Users can manually retry via page refresh

### Bounded Behavior

**All operations are bounded:**
- Timeouts prevent indefinite hangs
- No unbounded retry loops
- Connection pools have size limits
- Query results are paginated

**Safe Failure:**
- Errors don't cascade to other requests
- Failed queries don't affect connection pool
- Partial failures don't break entire response
- Error responses are always valid JSON

## Configuration

All timeout and connection settings are configurable via environment variables:

```bash
# Cassandra
CASSANDRA_CONNECT_TIMEOUT_MS=5000
CASSANDRA_REQUEST_TIMEOUT_MS=12000

# Presto
PRESTO_REQUEST_TIMEOUT_MS=30000

# Logging
LOG_LEVEL=info  # or debug, warn, error
```

## Monitoring Recommendations

**Key Metrics to Monitor:**
1. Request duration (p50, p95, p99)
2. Cassandra query duration
3. Presto query duration
4. Error rate by error code
5. Dependency availability (Cassandra, Presto)

**Alert Thresholds:**
- Error rate > 5% for 5 minutes
- Cassandra query duration p95 > 1 second
- Presto query duration p95 > 60 seconds
- Dependency unavailable for > 1 minute

## Testing

**Observability Testing:**
- Request IDs are generated and propagated
- Logs include structured context
- Query timing is measured and logged

**Resilience Testing:**
- Timeout handling (mock slow responses)
- Error propagation (mock dependency failures)
- Partial failure handling (mock individual source failures)
- Error response consistency

## Future Enhancements

**Potential additions (out of scope for starter app):**
- Circuit breaker pattern for repeated failures
- Exponential backoff retries for specific error types
- Distributed tracing (OpenTelemetry)
- Metrics export (Prometheus)
- Health check endpoints with dependency status
- Rate limiting and throttling

---

**Related Requirements:**
- REQ-008: Data quality and error handling
- REQ-010: Performance and scalability
- REQ-011: Observability and monitoring

**Related Tickets:**
- SHD-028: Add structured observability and query timing
- SHD-029: Add resilience for dependency failures