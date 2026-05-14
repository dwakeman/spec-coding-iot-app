import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';

import { apiClient, type DeviceSummary } from '../services/api-client';

function formatPercent(value: number | null) {
  return value === null ? '—' : `${value}%`;
}

function formatSignal(value: number | null) {
  return value === null ? '—' : `${value} dBm`;
}

function formatTimestamp(value: string) {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString();
}

function getStatusTone(status: string) {
  switch (status.toLowerCase()) {
    case 'online':
      return 'status-badge status-badge--online';
    case 'warning':
      return 'status-badge status-badge--warning';
    case 'offline':
      return 'status-badge status-badge--offline';
    default:
      return 'status-badge';
  }
}

function getAnomalyStatusTone(status: string | undefined) {
  switch (status) {
    case 'anomalous':
      return 'status-badge status-badge--warning';
    case 'normal':
      return 'status-badge status-badge--online';
    case 'unknown':
      return 'status-badge';
    default:
      return 'status-badge';
  }
}

function getAlertSeverityTone(severity: string | null | undefined) {
  if (!severity) return '';
  
  switch (severity.toLowerCase()) {
    case 'critical':
      return 'status-badge status-badge--offline';
    case 'high':
      return 'status-badge status-badge--warning';
    case 'medium':
      return 'status-badge status-badge--warning';
    case 'low':
      return 'status-badge';
    default:
      return 'status-badge';
  }
}

export function DashboardPage() {
  const [devices, setDevices] = useState<DeviceSummary[]>([]);
  const [siteOptions, setSiteOptions] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isFilterOptionsLoading, setIsFilterOptionsLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();

  const selectedSiteId = searchParams.get('siteId') ?? '';
  const selectedStatus = searchParams.get('status') ?? '';
  const selectedAnomalyStatus = searchParams.get('anomalyStatus') ?? '';

  useEffect(() => {
    let isMounted = true;

    async function loadFilterOptions() {
      setIsFilterOptionsLoading(true);

      try {
        const response = await apiClient.sites.list();

        if (!isMounted) {
          return;
        }

        setSiteOptions(response.data.map((item) => item.siteId));
      } catch {
        if (!isMounted) {
          return;
        }

        setSiteOptions([]);
      } finally {
        if (isMounted) {
          setIsFilterOptionsLoading(false);
        }
      }
    }

    void loadFilterOptions();

    return () => {
      isMounted = false;
    };
  }, []);

  useEffect(() => {
    let isMounted = true;

    async function loadDevices() {
      setIsLoading(true);
      setErrorMessage(null);

      try {
        const response = await apiClient.devices.list({
          siteId: selectedSiteId || undefined,
          status: selectedStatus || undefined,
          anomalyStatus: (selectedAnomalyStatus as 'normal' | 'anomalous' | 'unknown') || undefined,
          includeAlerts: true,
          includeAnomalies: true,
        });

        if (!isMounted) {
          return;
        }

        setDevices(response.data);
      } catch {
        if (!isMounted) {
          return;
        }

        setErrorMessage('Unable to load device health data right now.');
      } finally {
        if (isMounted) {
          setIsLoading(false);
        }
      }
    }

    void loadDevices();

    return () => {
      isMounted = false;
    };
  }, [selectedSiteId, selectedStatus, selectedAnomalyStatus]);

  const summary = useMemo(() => {
    const onlineCount = devices.filter((device) => device.status.toLowerCase() === 'online').length;
    const warningCount = devices.filter(
      (device) => device.status.toLowerCase() === 'warning',
    ).length;
    const offlineCount = devices.filter(
      (device) => device.status.toLowerCase() === 'offline',
    ).length;
    const anomalousCount = devices.filter((device) => device.anomalyStatus === 'anomalous').length;
    const devicesWithAlerts = devices.filter((device) => (device.openAlertCount ?? 0) > 0).length;

    return {
      total: devices.length,
      onlineCount,
      warningCount,
      offlineCount,
      anomalousCount,
      devicesWithAlerts,
    };
  }, [devices]);

  function updateFilter(name: 'siteId' | 'status' | 'anomalyStatus', value: string) {
    const nextParams = new URLSearchParams(searchParams);

    if (value) {
      nextParams.set(name, value);
    } else {
      nextParams.delete(name);
    }

    setSearchParams(nextParams);
  }

  return (
    <section className="page">
      <div className="page-header">
        <div>
          <p className="eyebrow">Dashboard route</p>
          <h2>Fleet overview</h2>
          <p>
            Review current device health, heartbeat recency, battery level, and signal strength
            across the fleet.
          </p>
        </div>
        <span className="status-pill">SHD-009</span>
      </div>

      <div className="card-grid dashboard-summary-grid">
        <article className="card metric-card">
          <p className="metric-card__label">Devices</p>
          <p className="metric-card__value">{summary.total}</p>
        </article>
        <article className="card metric-card">
          <p className="metric-card__label">Online</p>
          <p className="metric-card__value">{summary.onlineCount}</p>
        </article>
        <article className="card metric-card">
          <p className="metric-card__label">Anomalous</p>
          <p className="metric-card__value">{summary.anomalousCount}</p>
        </article>
        <article className="card metric-card">
          <p className="metric-card__label">With Alerts</p>
          <p className="metric-card__value">{summary.devicesWithAlerts}</p>
        </article>
        <article className="card metric-card">
          <p className="metric-card__label">Offline</p>
          <p className="metric-card__value">{summary.offlineCount}</p>
        </article>
      </div>

      <article className="card">
        <div className="section-heading">
          <div>
            <h3>Device list</h3>
            <p>
              Device list requests are loaded from{' '}
              <code>
                {apiClient.devices.listPath({
                  siteId: selectedSiteId || undefined,
                  status: selectedStatus || undefined,
                  anomalyStatus: (selectedAnomalyStatus as 'normal' | 'anomalous' | 'unknown') || undefined,
                  includeAlerts: true,
                  includeAnomalies: true,
                })}
              </code>
              .
            </p>
          </div>
        </div>

        <div className="filter-bar" aria-label="Dashboard filters">
          <label className="filter-field">
            <span className="filter-field__label">Site</span>
            <select
              aria-label="Site filter"
              value={selectedSiteId}
              onChange={(event) => updateFilter('siteId', event.target.value)}
              disabled={isFilterOptionsLoading}
            >
              <option value="">All sites</option>
              {siteOptions.map((siteId) => (
                <option key={siteId} value={siteId}>
                  {siteId}
                </option>
              ))}
            </select>
          </label>

          <label className="filter-field">
            <span className="filter-field__label">Status</span>
            <select
              aria-label="Status filter"
              value={selectedStatus}
              onChange={(event) => updateFilter('status', event.target.value)}
            >
              <option value="">All statuses</option>
              <option value="online">online</option>
              <option value="offline">offline</option>
              <option value="degraded">degraded</option>
              <option value="maintenance">maintenance</option>
            </select>
          </label>

          <label className="filter-field">
            <span className="filter-field__label">Anomaly Status</span>
            <select
              aria-label="Anomaly status filter"
              value={selectedAnomalyStatus}
              onChange={(event) => updateFilter('anomalyStatus', event.target.value)}
            >
              <option value="">All anomaly statuses</option>
              <option value="normal">normal</option>
              <option value="anomalous">anomalous</option>
              <option value="unknown">unknown</option>
            </select>
          </label>
        </div>

        {isLoading ? (
          <div className="empty-state" role="status">
            <p>Loading fleet devices…</p>
          </div>
        ) : null}

        {!isLoading && errorMessage ? (
          <div className="empty-state empty-state--error" role="alert">
            <p>{errorMessage}</p>
          </div>
        ) : null}

        {!isLoading && !errorMessage && devices.length === 0 ? (
          <div className="empty-state">
            <p>No devices are available for the current fleet view.</p>
          </div>
        ) : null}

        {!isLoading && !errorMessage && devices.length > 0 ? (
          <div className="table-wrap">
            <table className="device-table">
              <thead>
                <tr>
                  <th scope="col">Device</th>
                  <th scope="col">Site</th>
                  <th scope="col">Type</th>
                  <th scope="col">Status</th>
                  <th scope="col">Anomaly</th>
                  <th scope="col">Alerts</th>
                  <th scope="col">Battery</th>
                  <th scope="col">Signal</th>
                  <th scope="col">Last heartbeat</th>
                  <th scope="col">Open</th>
                </tr>
              </thead>
              <tbody>
                {devices.map((device) => (
                  <tr key={device.deviceId}>
                    <td>
                      <div className="device-primary">
                        <span className="device-primary__id">{device.deviceId}</span>
                      </div>
                    </td>
                    <td>{device.siteId}</td>
                    <td>{device.deviceType}</td>
                    <td>
                      <span className={getStatusTone(device.status)}>{device.status}</span>
                    </td>
                    <td>
                      {device.anomalyStatus ? (
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                          <span className={getAnomalyStatusTone(device.anomalyStatus)}>
                            {device.anomalyStatus}
                          </span>
                          {device.anomalyMetricCount !== undefined && device.anomalyMetricCount > 0 && (
                            <span style={{ fontSize: '0.875rem', color: '#666' }}>
                              ({device.anomalyMetricCount} metrics)
                            </span>
                          )}
                        </div>
                      ) : (
                        <span>—</span>
                      )}
                    </td>
                    <td>
                      {device.openAlertCount !== undefined && device.openAlertCount > 0 ? (
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                          <span>{device.openAlertCount}</span>
                          {device.highestAlertSeverity && (
                            <span className={getAlertSeverityTone(device.highestAlertSeverity)}>
                              {device.highestAlertSeverity}
                            </span>
                          )}
                        </div>
                      ) : (
                        <span>—</span>
                      )}
                    </td>
                    <td>{formatPercent(device.batteryLevelPct)}</td>
                    <td>{formatSignal(device.signalStrengthDbm)}</td>
                    <td>{formatTimestamp(device.lastHeartbeatAt)}</td>
                    <td>
                      <Link className="action-link action-link--inline" to={`/devices/${device.deviceId}`}>
                        View device
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </article>
    </section>
  );
}

// Made with Bob
