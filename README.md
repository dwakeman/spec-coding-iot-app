# Sensor Health Dashboard

A full-stack IoT device monitoring application built using **spec-coding** methodology with IBM watsonx.data, demonstrating federated analytics across hot operational data (Apache Cassandra) and cold historical data (Apache Iceberg).

![Status](https://img.shields.io/badge/status-demo%20ready-success)
![Tests](https://img.shields.io/badge/tests-90%2F90%20passing-success)
![Requirements](https://img.shields.io/badge/requirements-11%2F11%20implemented-success)

---

## 🎯 What This Application Does


_**Note: Full documentation for this application (including the methodology used to create it) can be found [here](https://dwakeman.github.io/spec-coding-iot-app).**_


The Sensor Health Dashboard helps operations teams monitor IoT device fleets by:

- **Real-time monitoring** of device status, battery levels, and signal strength
- **Anomaly detection** comparing recent readings against 7-day historical baselines
- **Alert management** surfacing open critical/high/medium/low severity alerts
- **Fleet-wide visibility** with filtering by site, status, and anomaly state
- **Device investigation** providing complete health context in a single view

### Key Features

✅ **Hot operational reads** from Cassandra (device state, last-hour readings, open alerts)  
✅ **Cold analytical queries** from Iceberg via Presto (7-day baseline statistics)  
✅ **Intelligent anomaly detection** using P95 thresholds and standard deviation rules  
✅ **Graceful degradation** when data sources are unavailable  
✅ **Comprehensive observability** with request tracing and query timing

---

## 🏗️ Architecture

### Technology Stack

**Backend:**
- Node.js + TypeScript + Express
- Direct Cassandra access for hot operational data
- Presto/watsonx.data for Iceberg analytics
- Structured logging with Pino

**Frontend:**
- React + TypeScript + Vite
- React Router for navigation
- Responsive dashboard and detail views

**Data Layer:**
- **Apache Cassandra 5.0** - Hot operational data (device state, readings, alerts)
- **Apache Iceberg** - Historical analytical data (hourly aggregates, baselines)
- **IBM watsonx.data** - Unified query engine (Presto) with catalog federation

### Data Access Patterns

```
┌─────────────────────────────────────────────────────────────┐
│                    Frontend (React)                         │
└────────────────────────┬────────────────────────────────────┘
                         │ REST API
┌────────────────────────▼────────────────────────────────────┐
│              Backend (Node.js/Express)                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Composite Health Service (Application-side joins)   │  │
│  └──────────────┬───────────────────────┬─────────────┬─┘  │
│                 │                       │             │     │
│    ┌────────────▼──────────┐  ┌────────▼──────┐  ┌──▼───┐ │
│    │ Device State Repo     │  │ Readings Repo │  │Alerts│ │
│    │ (Cassandra direct)    │  │(Cassandra)    │  │ Repo │ │
│    └───────────────────────┘  └───────────────┘  └──────┘ │
│                                                             │
│    ┌────────────────────────────────────────────────────┐  │
│    │ Baseline Repository (Presto → Iceberg)             │  │
│    └────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
┌───────▼────────┐              ┌─────────▼──────────┐
│   Cassandra    │              │  watsonx.data      │
│   (Hot Data)   │              │  Presto → Iceberg  │
│                │              │  (Cold Analytics)  │
│ • device_state │              │ • hourly_aggregates│
│ • readings_hot │              │ • baselines        │
│ • alerts_open  │              │                    │
└────────────────┘              └────────────────────┘
```

**Design Decision:** Application-side joins preferred over federated Presto queries for bounded scopes (single device or 25-device pages) to enable graceful degradation and faster hot reads. See `docs/federated-query-analysis.md` for detailed rationale.

---

## 📋 Spec-Coding Development Process

This application was built using **spec-coding** methodology, where an AI coding agent (Claude Code) drove the entire implementation from specifications to production-ready code.

### The Spec-Coding Workflow

1. **Requirements First** (`requirements.md`)
   - 11 functional requirements defined upfront
   - 3 user personas (Operations Analyst, Site Reliability Lead, Support Engineer)
   - 3 primary user flows documented

2. **Technical Design** (`design.md`)
   - Data access patterns specified
   - API contracts defined (OpenAPI)
   - Anomaly detection rules documented
   - Architecture decisions recorded

3. **Sprint Planning** (`sprint-board.md`)
   - 32 tickets across 4 sprints
   - Each ticket maps to specific requirements
   - Acceptance criteria defined per ticket
   - Definition of done established

4. **AI-Driven Implementation**
   - Agent read specs and generated code
   - Test-driven development (90 automated tests)
   - Iterative refinement based on test results
   - Documentation generated alongside code

5. **Verification** (`docs/requirements-traceability-matrix.md`)
   - Every requirement traced to tests
   - 100% requirement coverage achieved
   - Demo readiness confirmed

### Key Artifacts

| Document | Purpose | Status |
|----------|---------|--------|
| `requirements.md` | Functional requirements (REQ-001 through REQ-011) | ✅ Complete |
| `design.md` | Technical design and architecture decisions | ✅ Complete |
| `openapi.yaml` | API contract specification | ✅ Complete |
| `sprint-board.md` | Sprint planning with 32 tickets | ✅ All tickets done |
| `todo.md` | Development task tracking | ✅ Complete |
| `docs/requirements-traceability-matrix.md` | Test coverage by requirement | ✅ 90 tests |
| `docs/demo-readiness.md` | Demo preparation guide | ✅ Ready |
| `FINAL-DEMO-READINESS-REPORT.md` | Comprehensive verification | ✅ All passing |

### Why Spec-Coding Works

**Benefits demonstrated in this project:**

✅ **Clear requirements** → No scope creep, focused implementation  
✅ **Upfront design** → Consistent architecture, no major refactors  
✅ **Test-driven** → 90/90 tests passing, high confidence  
✅ **Traceable** → Every line of code maps to a requirement  
✅ **Documented** → Comprehensive docs generated during development  
✅ **Maintainable** → Future developers can understand the "why" behind decisions

---

## 🚀 Quick Start

### Prerequisites

- **Workshop Environment Installed** (see `INSTALLATION-SUMMARY.md`)
  - IBM watsonx.data Developer Edition
  - Apache Cassandra 5.0
  - Sample IoT data loaded
- Node.js 18+ and npm

### Installation

```bash
# Clone the repository
git clone https://github.com/dwakeman/spec-coding-iot-app.git
cd spec-coding-iot-app

# Install backend dependencies
cd backend
npm install

# Install frontend dependencies
cd ../frontend
npm install
```

### Configuration

Create a `.env` file in the project root (copy from `.env.example`):

```bash
# Cassandra (hot operational data)
CASSANDRA_CONTACT_POINTS=127.0.0.1
CASSANDRA_PORT=9042
CASSANDRA_KEYSPACE=iot
CASSANDRA_USERNAME=cassandra
CASSANDRA_PASSWORD=cassandra

# Presto / watsonx.data (cold analytical data)
PRESTO_BASE_URL=https://localhost:8443
PRESTO_CATALOG=iceberg_data
PRESTO_SCHEMA=iot
PRESTO_USERNAME=ibmlhadmin
PRESTO_PASSWORD=password
PRESTO_TLS_REJECT_UNAUTHORIZED=false

# Backend service
PORT=3000
LOG_LEVEL=info
```

### Running the Application

**Terminal 1 - Backend:**
```bash
cd backend
npm run dev
```

**Terminal 2 - Frontend:**
```bash
cd frontend
npm run dev
```

**Access the application:**
- Frontend: http://localhost:5173
- Backend API: http://localhost:3000
- Health check: http://localhost:3000/api/health

---

## 🧪 Testing

### Run All Tests

```bash
# Backend tests (84 tests)
cd backend
npm test

# Frontend tests (6 tests)
cd frontend
npm test
```

### Test Coverage by Requirement

| Requirement | Description | Tests | Status |
|-------------|-------------|-------|--------|
| REQ-001 | Device inventory | 5 | ✅ |
| REQ-002 | Last-hour readings | 6 | ✅ |
| REQ-003 | 7-day baseline | 5 | ✅ |
| REQ-004 | Anomaly detection | 42 | ✅ |
| REQ-005 | Open alerts | 8 | ✅ |
| REQ-006 | Filtering/prioritization | 9 | ✅ |
| REQ-007 | Device detail context | 9 | ✅ |
| REQ-008 | Data freshness/missing data | 13 | ✅ |
| REQ-009 | Federated hot+cold access | 7 | ✅ |
| REQ-010 | Actionable triage information | 28 | ✅ |
| REQ-011 | Starter app suitability | All | ✅ |

**Total: 90/90 tests passing (100% pass rate)**

See `docs/requirements-traceability-matrix.md` for detailed test-to-requirement mapping.

---

## 📚 API Documentation

### Endpoints

**Device Management:**
- `GET /api/v1/devices` - List devices with filters and enrichment
- `GET /api/v1/devices/:id` - Get single device state
- `GET /api/v1/devices/:id/health` - Get composite device health (recommended)

**Device Data:**
- `GET /api/v1/devices/:id/readings` - Last-hour readings
- `GET /api/v1/devices/:id/alerts` - Open alerts
- `GET /api/v1/devices/:id/baseline` - 7-day baseline statistics

**Metadata:**
- `GET /api/v1/sites` - List available sites
- `GET /api/health` - Service health check

### Example: Composite Health Endpoint

```bash
curl http://localhost:3000/api/v1/devices/{device-id}/health
```

**Response includes:**
- Device state (status, battery, signal, location)
- Health summary (anomaly status, severity, data freshness)
- Metric health (per-metric anomaly detection with reasons)
- Recent readings (last hour)
- Open alerts (with severity and context)

See `openapi.yaml` for complete API specification.

---

## 🎨 User Interface

### Dashboard View

- **Fleet overview** with summary metrics (total devices, online, anomalous, with alerts, offline)
- **Device list** with status badges, anomaly indicators, and alert counts
- **Filters** for site, status, and anomaly state
- **Sortable columns** for rapid triage
- **Direct navigation** to device details

### Device Detail View

- **Health Summary** card (anomaly status, severity, data freshness, alert count)
- **Metric Health** table (per-metric anomaly status, latest reading, 7-day baseline, anomaly reason)
- **Recent Readings** section (last hour of sensor data with quality codes)
- **Open Alerts** section (severity, type, metric context, raised timestamp)

---

## 📖 Documentation

### Core Documentation
- `requirements.md` - Functional requirements and user flows
- `design.md` - Technical design and architecture
- `openapi.yaml` - API contract specification
- `SCHEMAS.md` - Data model reference (workshop-provided)

### Operational Documentation
- `docs/requirements-traceability-matrix.md` - Test coverage by requirement
- `docs/observability-and-resilience.md` - Logging, timeouts, error handling
- `docs/federated-query-analysis.md` - Data access pattern decisions
- `docs/demo-readiness.md` - Demo preparation guide
- `INSTALLATION-SUMMARY.md` - Workshop environment details
- `FINAL-DEMO-READINESS-REPORT.md` - Comprehensive verification report

### Development Documentation
- `sprint-board.md` - Sprint planning (32 tickets across 4 sprints)
- `todo.md` - Development task tracking
- `PROJECT-SUMMARY.md` - Project overview

---

## 🔍 Key Design Decisions

### 1. Application-Side Joins vs. Federated Queries

**Decision:** Use application-side joins for bounded scopes (single device or 25-device pages)

**Rationale:**
- Enables graceful degradation when Presto is slow or unavailable
- Keeps hot operational reads fast via direct Cassandra access
- Anomaly logic too complex for SQL (two-rule evaluation, quality code filtering)
- Parallel queries for 25 devices faster than single federated query on Apple Silicon

See `docs/federated-query-analysis.md` for detailed analysis.

### 2. No Automatic Retries

**Decision:** Fail fast for both hot reads and slow analytics

**Rationale:**
- Hot operational reads should be fast (<100ms) - retries add latency
- Slow analytical queries (15-25s on Apple Silicon) - retries compound delays
- Graceful degradation preferred over blocking retries
- Structured errors enable client-side retry logic if needed

See `docs/observability-and-resilience.md` for implementation details.

### 3. Composite Health Endpoint

**Decision:** Single `/devices/:id/health` endpoint instead of multiple calls

**Rationale:**
- Reduces client-side complexity (1 call vs. 4)
- Enables parallel data loading on backend
- Provides complete investigation context in one response
- Supports partial enrichment when sources fail

---

## 🚧 Known Limitations

### Performance on Apple Silicon
- **Presto queries:** 15-25 seconds (amd64 emulation via Rosetta)
- **Cassandra queries:** <100ms (native ARM64)
- **Mitigation:** Application-side joins keep hot reads fast

### Data Freshness
- **Readings:** Last 24 hours only (hot window in `readings_hot`)
- **Baseline:** 7-day window (configurable up to 30 days)
- **Rationale:** Starter app scope, not long-term historical analysis

### Scalability
- **Dashboard pagination:** 25 devices per page
- **Enrichment:** Parallel queries per device
- **Limitation:** Not optimized for 10,000+ device fleets
- **Rationale:** Starter app, not production-scale system

### No Real-Time Updates
- **Refresh:** Manual page reload
- **No WebSockets/SSE:** Not implemented
- **Rationale:** Read-only starter app

---

## 🤝 Contributing

This is a demonstration application built for the IBM watsonx.data workshop. While it's not actively maintained for production use, the spec-coding methodology and architecture patterns are designed to be educational references.

### Learning from This Project

**For developers:**
- Study the spec-coding workflow (requirements → design → implementation)
- Review the test-driven development approach
- Examine the federated data access patterns
- Learn from the architecture decision records

**For architects:**
- Analyze the hot/cold data separation strategy
- Review the graceful degradation patterns
- Study the observability implementation
- Examine the API design principles

---

## 📄 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- **IBM watsonx.data** team for the workshop environment and sample data
- **Claude Code (IBM Bob)** for AI-driven implementation
- **Spec-coding methodology** for enabling rapid, high-quality development

---

## 📞 Support

For questions about:
- **The application:** Review the documentation in `docs/`
- **Workshop setup:** See `INSTALLATION-SUMMARY.md` and `docs/getting-unstuck.md`
- **Spec-coding methodology:** Study the artifacts in `requirements.md`, `design.md`, and `sprint-board.md`

---

**Built with spec-coding methodology using IBM Bob (Claude Code) • 2026**
