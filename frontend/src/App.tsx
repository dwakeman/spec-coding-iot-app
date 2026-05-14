import { NavLink, Outlet } from 'react-router-dom';

import './App.css';

export function AppShell() {
  return (
    <div className="app-shell">
      <header className="topbar">
        <div>
          <p className="eyebrow">Starter application</p>
          <h1>Sensor Health Dashboard</h1>
          <p className="subtitle">
            Monitor fleet health, recent readings, and anomaly workflows for IoT devices.
          </p>
        </div>

        <nav className="topnav" aria-label="Primary">
          <NavLink
            to="/"
            end
            className={({ isActive }) => (isActive ? 'nav-link nav-link--active' : 'nav-link')}
          >
            Dashboard
          </NavLink>
          <NavLink
            to="/devices/demo-device"
            className={({ isActive }) => (isActive ? 'nav-link nav-link--active' : 'nav-link')}
          >
            Device detail
          </NavLink>
        </nav>
      </header>

      <main className="main-content">
        <Outlet />
      </main>
    </div>
  );
}

// Made with Bob
