import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { AppShell } from './App';
import { DeviceDetailPage } from './pages/device-detail-page';
import { DashboardPage } from './pages/dashboard-page';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('frontend routes', () => {
  it('renders the dashboard device list from API data and applies filters', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);

      if (url === '/api/v1/sites') {
        return {
          ok: true,
          json: async () => ({
            data: [{ siteId: 'site-a' }, { siteId: 'site-b' }],
          }),
        } as Response;
      }

      if (url.startsWith('/api/v1/devices?') || url === '/api/v1/devices') {
        // Parse query params to determine which devices to return
        const urlObj = new URL(url, 'http://localhost');
        const siteId = urlObj.searchParams.get('siteId');
        const status = urlObj.searchParams.get('status');
        
        let devices = [
          {
            deviceId: 'device-001',
            siteId: 'site-a',
            deviceType: 'thermostat',
            status: 'online',
            batteryLevelPct: 92,
            signalStrengthDbm: -67,
            lastHeartbeatAt: '2026-05-13T18:00:00.000Z',
            anomalyStatus: 'normal' as const,
            anomalyMetricCount: 0,
            openAlertCount: 0,
            highestAlertSeverity: null,
          },
          {
            deviceId: 'device-002',
            siteId: 'site-b',
            deviceType: 'pump-sensor',
            status: 'offline',
            batteryLevelPct: null,
            signalStrengthDbm: null,
            lastHeartbeatAt: '2026-05-13T17:30:00.000Z',
            anomalyStatus: 'unknown' as const,
            anomalyMetricCount: 0,
            openAlertCount: 0,
            highestAlertSeverity: null,
          },
        ];

        // Apply filters
        if (siteId) {
          devices = devices.filter(d => d.siteId === siteId);
        }
        if (status) {
          devices = devices.filter(d => d.status === status);
        }

        return {
          ok: true,
          json: async () => ({
            data: devices,
            pagination: {
              page: 1,
              pageSize: 25,
              totalItems: devices.length,
              totalPages: 1,
            },
          }),
        } as Response;
      }

      throw new Error(`Unhandled fetch URL: ${url}`);
    });

    render(
      <MemoryRouter initialEntries={['/']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route index element={<DashboardPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByRole('heading', { name: /sensor health dashboard/i })).toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent(/loading fleet devices/i);

    await waitFor(() => {
      expect(screen.getByText('device-001')).toBeInTheDocument();
    });

    expect(screen.getByText('device-002')).toBeInTheDocument();
    expect(screen.getByText('thermostat')).toBeInTheDocument();
    expect(screen.getByText('pump-sensor')).toBeInTheDocument();
    expect(screen.getByText('92%')).toBeInTheDocument();
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText(/^site filter$/i), {
      target: { value: 'site-a' },
    });

    await waitFor(() => {
      expect(screen.getByDisplayValue('site-a')).toBeInTheDocument();
    });

    fireEvent.change(screen.getByLabelText(/^status filter$/i), {
      target: { value: 'online' },
    });

    await waitFor(() => {
      expect(screen.getByDisplayValue('online')).toBeInTheDocument();
    });

    expect(fetchMock).toHaveBeenCalledWith('/api/v1/sites', {
      headers: {
        Accept: 'application/json',
      },
    });
    // Verify fetch was called with the expected URLs (with enrichment params)
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/devices'),
      expect.objectContaining({
        headers: {
          Accept: 'application/json',
        },
      })
    );

    const deviceLinks = screen.getAllByRole('link', { name: /view device/i });

    expect(deviceLinks).toHaveLength(1);
    expect(deviceLinks[0]).toHaveAttribute('href', '/devices/device-001');
  });

  it('renders an explicit dashboard error state when the device request fails', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);

      if (url === '/api/v1/sites') {
        return {
          ok: true,
          json: async () => ({
            data: [{ siteId: 'site-a' }],
          }),
        } as Response;
      }

      throw new Error('network failure');
    });

    render(
      <MemoryRouter initialEntries={['/']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route index element={<DashboardPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent(
        /unable to load device health data right now/i,
      );
    });
  });

  it('renders the device detail shell with composite health data', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);

      if (url.startsWith('/api/v1/devices/device-123/health')) {
        return {
          ok: true,
          json: async () => ({
            device: {
              deviceId: 'device-123',
              deviceType: 'sensor',
              deviceClass: 'temperature',
              model: 'TEMP-100',
              firmwareVersion: '1.0.4',
              status: 'online',
              lastHeartbeat: '2026-05-13T18:00:00.000Z',
              lastReadingValue: '21.3',
              batteryPercent: 88,
              signalStrengthDbm: -61,
              siteId: 'site-a',
              zone: 'north',
              installedAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-05-13T18:05:00.000Z',
            },
            summary: {
              deviceAnomalyStatus: 'anomalous',
              anomalyMetricCount: 1,
              severity: 'medium',
              dataFreshness: 'fresh',
              openAlertCount: 1,
              highestAlertSeverity: 'medium',
            },
            metricHealth: [
              {
                metricName: 'temperature_c',
                anomalyStatus: 'anomalous',
                anomalyReason: 'Value 21.3 exceeds baseline P95 (20.4)',
                latestReading: {
                  timestamp: '2026-05-13T18:00:00.000Z',
                  metricValue: '21.3',
                  unit: 'C',
                  qualityCode: 'good',
                },
                baseline: {
                  baselineAvg: 20.4,
                  baselineP95: 24.6,
                  baselineMin: 18.2,
                  baselineMax: 26.1,
                  baselineStddev: 1.3,
                  sampleCount: 168,
                  baselineWindowDays: 7,
                  baselineWindowHoursCovered: 166,
                },
                recentReadingCount: 12,
              },
            ],
            readings: [
              {
                timestamp: '2026-05-13T18:00:00.000Z',
                metricName: 'temperature_c',
                metricValue: '21.3',
                unit: 'C',
                qualityCode: 'good',
              },
            ],
            alerts: [
              {
                alertId: 'alert-001',
                raisedAt: '2026-05-13T17:58:00.000Z',
                severity: 'medium',
                alertType: 'threshold',
                metricName: 'temperature_c',
                metricValue: '21.3',
                thresholdValue: '25.0',
                siteId: 'site-a',
                acknowledged: false,
              },
            ],
          }),
        } as Response;
      }

      throw new Error(`Unhandled fetch URL: ${url}`);
    });

    render(
      <MemoryRouter initialEntries={['/devices/device-123']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route path="devices/:deviceId" element={<DeviceDetailPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByRole('status')).toHaveTextContent(/loading device detail/i);

    await waitFor(() => {
      expect(screen.getByRole('heading', { name: /device detail/i })).toBeInTheDocument();
    });

    expect(screen.getByText('Current device state')).toBeInTheDocument();
    expect(screen.getByText('Health Summary')).toBeInTheDocument();
    expect(screen.getByText('Last-hour readings')).toBeInTheDocument();
    expect(screen.getByText('Metric Health')).toBeInTheDocument();
    expect(screen.getAllByText('Open alerts').length).toBeGreaterThan(0);
    expect(screen.getByText('TEMP-100')).toBeInTheDocument();
    expect(screen.getAllByText('temperature_c').length).toBeGreaterThan(0);
    expect(screen.getByText('threshold')).toBeInTheDocument();
    expect(screen.getAllByText('anomalous').length).toBeGreaterThan(0);
    expect(screen.getByText('Value 21.3 exceeds baseline P95 (20.4)')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /back to dashboard/i })).toHaveAttribute('href', '/');

    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/devices/device-123/health'),
      {
        headers: {
          Accept: 'application/json',
        },
      }
    );
  });

  it('renders an explicit detail error state when device detail requests fail', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('network failure'));

    render(
      <MemoryRouter initialEntries={['/devices/device-123']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route path="devices/:deviceId" element={<DeviceDetailPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent(/unable to load device detail right now/i);
    });
  });

  it('renders explicit empty state messaging when no readings are available', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);

      if (url.startsWith('/api/v1/devices/device-123/health')) {
        return {
          ok: true,
          json: async () => ({
            device: {
              deviceId: 'device-123',
              deviceType: 'sensor',
              status: 'online',
              lastHeartbeat: '2026-05-13T18:00:00.000Z',
              siteId: 'site-a',
              zone: 'north',
            },
            summary: {
              deviceAnomalyStatus: 'unknown',
              anomalyMetricCount: 0,
              severity: 'normal',
              dataFreshness: 'stale',
              openAlertCount: 0,
              highestAlertSeverity: null,
            },
            metricHealth: [],
            readings: [],
            alerts: [],
          }),
        } as Response;
      }

      throw new Error(`Unhandled fetch URL: ${url}`);
    });

    render(
      <MemoryRouter initialEntries={['/devices/device-123']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route path="devices/:deviceId" element={<DeviceDetailPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(screen.getByText(/no recent readings are available for this device/i)).toBeInTheDocument();
    });

    expect(screen.getByText(/no metric health data is available for this device/i)).toBeInTheDocument();
    expect(screen.getByText(/no open alerts are currently active for this device/i)).toBeInTheDocument();
  });

  it('verifies readings table displays in descending timestamp order', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);

      if (url.startsWith('/api/v1/devices/device-123/health')) {
        return {
          ok: true,
          json: async () => ({
            device: {
              deviceId: 'device-123',
              status: 'online',
            },
            summary: {
              deviceAnomalyStatus: 'normal',
              anomalyMetricCount: 0,
              severity: 'normal',
              dataFreshness: 'fresh',
              openAlertCount: 0,
              highestAlertSeverity: null,
            },
            metricHealth: [],
            readings: [
              {
                timestamp: '2026-05-13T18:00:00.000Z',
                metricName: 'temperature_c',
                metricValue: '22.1',
                unit: 'C',
                qualityCode: 'good',
              },
              {
                timestamp: '2026-05-13T17:45:00.000Z',
                metricName: 'temperature_c',
                metricValue: '21.8',
                unit: 'C',
                qualityCode: 'good',
              },
              {
                timestamp: '2026-05-13T17:30:00.000Z',
                metricName: 'temperature_c',
                metricValue: '21.5',
                unit: 'C',
                qualityCode: 'suspect',
              },
            ],
            alerts: [],
          }),
        } as Response;
      }

      throw new Error(`Unhandled fetch URL: ${url}`);
    });

    render(
      <MemoryRouter initialEntries={['/devices/device-123']}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route path="devices/:deviceId" element={<DeviceDetailPage />} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(screen.getByText('22.1')).toBeInTheDocument();
    });

    const rows = screen.getAllByRole('row');
    const dataRows = rows.slice(1);

    // Verify readings are in descending timestamp order (most recent first)
    expect(dataRows[0]).toHaveTextContent('22.1');
    expect(dataRows[0]).toHaveTextContent('good');
    expect(dataRows[1]).toHaveTextContent('21.8');
    expect(dataRows[1]).toHaveTextContent('good');
    expect(dataRows[2]).toHaveTextContent('21.5');
    expect(dataRows[2]).toHaveTextContent('suspect');
    
    // Verify the order by checking metric values appear in expected sequence
    const metricValues = Array.from(dataRows).map(row =>
      row.textContent?.match(/\d+\.\d+/)?.[0]
    );
    expect(metricValues).toEqual(['22.1', '21.8', '21.5']);
  });
});

// Made with Bob
// REQ-002: Last-hour readings display
// REQ-003: 7-day baseline comparison
// REQ-005: Open alerts context
// REQ-007: Device detail view
// REQ-008: Data freshness and missing data handling
