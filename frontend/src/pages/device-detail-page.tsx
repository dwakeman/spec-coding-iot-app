import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';

import {
  apiClient,
  type DeviceAlert,
  type DeviceDetail,
  type DeviceHealthResponse,
  type DeviceHealthSummary,
  type DeviceReading,
  type MetricHealth,
} from '../services/api-client';

function formatTimestamp(value: string | null | undefined) {
  if (!value) {
    return '—';
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString();
}

function formatValue(value: string | number | null | undefined, suffix?: string) {
  if (value === null || value === undefined || value === '') {
    return '—';
  }

  return suffix ? `${value} ${suffix}` : String(value);
}

function getStatusTone(status: string) {
  switch (status.toLowerCase()) {
    case 'online':
      return 'status-badge status-badge--online';
    case 'warning':
    case 'degraded':
    case 'maintenance':
      return 'status-badge status-badge--warning';
    case 'offline':
      return 'status-badge status-badge--offline';
    default:
      return 'status-badge';
  }
}

function getAnomalyStatusTone(status: string) {
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

function getSeverityTone(severity: string | null) {
  if (!severity) return 'status-badge';
  
  switch (severity.toLowerCase()) {
    case 'critical':
      return 'status-badge status-badge--offline';
    case 'high':
      return 'status-badge status-badge--warning';
    case 'medium':
      return 'status-badge status-badge--warning';
    case 'low':
      return 'status-badge';
    case 'normal':
      return 'status-badge status-badge--online';
    default:
      return 'status-badge';
  }
}

export function DeviceDetailPage() {
  const { deviceId = 'unknown-device' } = useParams();

  const [healthData, setHealthData] = useState<DeviceHealthResponse | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let isMounted = true;

    async function loadDeviceHealth() {
      setIsLoading(true);
      setErrorMessage(null);

      try {
        const response = await apiClient.devices.health(deviceId);

        if (!isMounted) {
          return;
        }

        setHealthData(response);
      } catch {
        if (!isMounted) {
          return;
        }

        setErrorMessage('Unable to load device detail right now.');
      } finally {
        if (isMounted) {
          setIsLoading(false);
        }
      }
    }

    void loadDeviceHealth();

    return () => {
      isMounted = false;
    };
  }, [deviceId]);

  const device = healthData?.device ?? null;
  const summary = healthData?.summary ?? null;
  const metricHealth = healthData?.metricHealth ?? [];
  const readings = healthData?.readings ?? [];
  const alerts = healthData?.alerts ?? [];

  const latestReading = useMemo(() => readings[0] ?? null, [readings]);

  return (
    <section className="page">
      <div className="page-header">
        <div>
          <p className="eyebrow">Device detail route</p>
          <h2>Device detail</h2>
          <p>
            Review current state, recent readings, baseline context, and open alerts for{' '}
            <code>{deviceId}</code>.
          </p>
        </div>
        <span className="status-pill">SHD-018</span>
      </div>

      <article className="card">
        <div className="section-heading">
          <div>
            <h3>Data source</h3>
            <p>Composite health endpoint provides unified device health with anomaly detection.</p>
          </div>
        </div>

        <ul className="feature-list">
          <li>
            Composite health: <code>{apiClient.devices.healthPath(deviceId)}</code>
          </li>
        </ul>
      </article>

      {isLoading ? (
        <div className="empty-state" role="status">
          <p>Loading device detail…</p>
        </div>
      ) : null}

      {!isLoading && errorMessage ? (
        <div className="empty-state empty-state--error" role="alert">
          <p>{errorMessage}</p>
        </div>
      ) : null}

      {!isLoading && !errorMessage && device ? (
        <>
          <div className="card-grid">
            <article className="card">
              <div className="section-heading">
                <div>
                  <h3>Current device state</h3>
                  <p>Operational snapshot from the current device state source.</p>
                </div>
              </div>

              <dl className="detail-grid">
                <div>
                  <dt>Device ID</dt>
                  <dd>{device.deviceId}</dd>
                </div>
                <div>
                  <dt>Status</dt>
                  <dd>
                    <span className={getStatusTone(device.status)}>{device.status}</span>
                  </dd>
                </div>
                <div>
                  <dt>Type</dt>
                  <dd>{device.deviceType}</dd>
                </div>
                <div>
                  <dt>Class</dt>
                  <dd>{device.deviceClass}</dd>
                </div>
                <div>
                  <dt>Model</dt>
                  <dd>{device.model}</dd>
                </div>
                <div>
                  <dt>Firmware</dt>
                  <dd>{device.firmwareVersion}</dd>
                </div>
                <div>
                  <dt>Site</dt>
                  <dd>{device.siteId}</dd>
                </div>
                <div>
                  <dt>Zone</dt>
                  <dd>{device.zone}</dd>
                </div>
                <div>
                  <dt>Battery</dt>
                  <dd>{formatValue(device.batteryPercent, '%')}</dd>
                </div>
                <div>
                  <dt>Signal</dt>
                  <dd>{formatValue(device.signalStrengthDbm, 'dBm')}</dd>
                </div>
                <div>
                  <dt>Last heartbeat</dt>
                  <dd>{formatTimestamp(device.lastHeartbeat)}</dd>
                </div>
                <div>
                  <dt>Last reading</dt>
                  <dd>{formatValue(device.lastReadingValue)}</dd>
                </div>
              </dl>
            </article>

            <article className="card">
              <div className="section-heading">
                <div>
                  <h3>Health Summary</h3>
                  <p>Composite health status with anomaly detection and alert context.</p>
                </div>
              </div>

              {summary && (
                <dl className="detail-grid">
                  <div>
                    <dt>Device Anomaly Status</dt>
                    <dd>
                      <span className={getAnomalyStatusTone(summary.deviceAnomalyStatus)}>
                        {summary.deviceAnomalyStatus}
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt>Anomalous Metrics</dt>
                    <dd>{summary.anomalyMetricCount}</dd>
                  </div>
                  <div>
                    <dt>Severity</dt>
                    <dd>
                      <span className={getSeverityTone(summary.severity)}>
                        {summary.severity}
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt>Data Freshness</dt>
                    <dd>{summary.dataFreshness}</dd>
                  </div>
                  <div>
                    <dt>Open Alerts</dt>
                    <dd>{summary.openAlertCount}</dd>
                  </div>
                  <div>
                    <dt>Highest Alert Severity</dt>
                    <dd>
                      <span className={getSeverityTone(summary.highestAlertSeverity)}>
                        {summary.highestAlertSeverity ?? '—'}
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt>Recent Readings</dt>
                    <dd>{readings.length}</dd>
                  </div>
                  <div>
                    <dt>Latest Reading</dt>
                    <dd>{latestReading ? formatValue(latestReading.metricValue, latestReading.unit) : '—'}</dd>
                  </div>
                  <div>
                    <dt>Installed</dt>
                    <dd>{formatTimestamp(device.installedAt)}</dd>
                  </div>
                </dl>
              )}

              <Link className="action-link" to="/">
                Back to dashboard
              </Link>
            </article>
          </div>

          <div className="card-grid">
            <article className="card">
              <div className="section-heading">
                <div>
                  <h3>Last-hour readings</h3>
                  <p>Recent measurements for the selected device.</p>
                </div>
              </div>

              {readings.length === 0 ? (
                <div className="empty-state">
                  <p>No recent readings are available for this device.</p>
                </div>
              ) : (
                <div className="table-wrap">
                  <table className="device-table">
                    <thead>
                      <tr>
                        <th scope="col">Timestamp</th>
                        <th scope="col">Metric</th>
                        <th scope="col">Value</th>
                        <th scope="col">Unit</th>
                        <th scope="col">Quality</th>
                      </tr>
                    </thead>
                    <tbody>
                      {readings.map((reading) => (
                        <tr key={`${reading.timestamp}-${reading.metricName}`}>
                          <td>{formatTimestamp(reading.timestamp)}</td>
                          <td>{reading.metricName}</td>
                          <td>{formatValue(reading.metricValue)}</td>
                          <td>{reading.unit}</td>
                          <td>{reading.qualityCode}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </article>

            <article className="card">
              <div className="section-heading">
                <div>
                  <h3>Metric Health</h3>
                  <p>Per-metric anomaly detection with baseline comparison.</p>
                </div>
              </div>

              {metricHealth.length === 0 ? (
                <div className="empty-state">
                  <p>No metric health data is available for this device.</p>
                </div>
              ) : (
                <div className="table-wrap">
                  <table className="device-table">
                    <thead>
                      <tr>
                        <th scope="col">Metric</th>
                        <th scope="col">Anomaly Status</th>
                        <th scope="col">Latest Value</th>
                        <th scope="col">Baseline Avg</th>
                        <th scope="col">Baseline P95</th>
                        <th scope="col">Reading Count</th>
                        <th scope="col">Reason</th>
                      </tr>
                    </thead>
                    <tbody>
                      {metricHealth.map((metric) => (
                        <tr key={metric.metricName}>
                          <td>{metric.metricName}</td>
                          <td>
                            <span className={getAnomalyStatusTone(metric.anomalyStatus)}>
                              {metric.anomalyStatus}
                            </span>
                          </td>
                          <td>
                            {metric.latestReading
                              ? formatValue(metric.latestReading.metricValue, metric.latestReading.unit)
                              : '—'}
                          </td>
                          <td>{metric.baseline ? formatValue(metric.baseline.baselineAvg) : '—'}</td>
                          <td>{metric.baseline ? formatValue(metric.baseline.baselineP95) : '—'}</td>
                          <td>{metric.recentReadingCount}</td>
                          <td style={{ fontSize: '0.875rem', color: '#666' }}>
                            {metric.anomalyReason ?? '—'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </article>
          </div>

          <article className="card">
            <div className="section-heading">
              <div>
                <h3>Open alerts</h3>
                <p>Outstanding alert context for device investigation.</p>
              </div>
            </div>

            {alerts.length === 0 ? (
              <div className="empty-state">
                <p>No open alerts are currently active for this device.</p>
              </div>
            ) : (
              <div className="table-wrap">
                <table className="device-table">
                  <thead>
                    <tr>
                      <th scope="col">Raised</th>
                      <th scope="col">Severity</th>
                      <th scope="col">Type</th>
                      <th scope="col">Metric</th>
                      <th scope="col">Value</th>
                      <th scope="col">Threshold</th>
                      <th scope="col">Acknowledged</th>
                    </tr>
                  </thead>
                  <tbody>
                    {alerts.map((alert) => (
                      <tr key={alert.alertId}>
                        <td>{formatTimestamp(alert.raisedAt)}</td>
                        <td>{alert.severity}</td>
                        <td>{alert.alertType}</td>
                        <td>{alert.metricName ?? '—'}</td>
                        <td>{formatValue(alert.metricValue)}</td>
                        <td>{formatValue(alert.thresholdValue)}</td>
                        <td>{alert.acknowledged ? 'yes' : 'no'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </article>
        </>
      ) : null}
    </section>
  );
}

// Made with Bob
