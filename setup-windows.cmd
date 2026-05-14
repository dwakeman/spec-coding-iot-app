@echo off
REM ========================================================================
REM setup-windows.cmd — Windows entry point for the workshop install.
REM
REM This is a 5-line shim. The actual work is in setup-windows.ps1.
REM
REM Why this exists:
REM   - .ps1 files don't double-click-execute on Windows by default
REM     (security default opens them in Notepad). .cmd files do.
REM   - Corp execution-policy may block .ps1 invocation; -ExecutionPolicy
REM     Bypass scoped to this Process is the Microsoft-blessed escape
REM     hatch and doesn't change the user's persistent policy.
REM   - %~dp0 is the directory this .cmd lives in (with trailing slash),
REM     so the script works whether double-clicked from Explorer or
REM     run from any cwd.
REM
REM Usage:
REM   setup-windows.cmd               # probe and emit [WIN-PROBE-*] output
REM   setup-windows.cmd -Quiet        # suppress decorative banner
REM ========================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
exit /b %ERRORLEVEL%
