#requires -version 5
<#
.SYNOPSIS
    Bootstrap probe for Windows attendees of the watsonx.data + Cassandra
    workshop. Reports environment state in [WIN-PROBE-*] tagged lines that
    the driving AI agent reads to decide next steps.

.DESCRIPTION
    The workshop's install scripts only run inside a WSL2 Ubuntu shell.
    This script is the pre-shell layer that pre-flight can't reach (because
    pre-flight runs in bash, which doesn't exist on Windows yet).

    What it does without admin:
      - Inspects WSL feature state, registered distros, default distro,
        virtualization, admin status, and the bundle's path.
      - Picks a usable distro (prefers Ubuntu-24.04, falls back to Ubuntu,
        then default, then any).
      - If the bundle lives on /mnt/<drive>/, copies it into ~/wxd-workshop
        inside WSL so the install doesn't run through the slow 9p layer.
      - Emits a `next_command=...` line the agent can run to enter the
        WSL2 shell with the bundle in place and continue the install.

    What it does WITH admin (via auto-elevation):
      - When the WSL feature is missing or no Ubuntu distro is registered,
        the script self-elevates via UAC (`Start-Process -Verb RunAs`) and
        runs `wsl --install -d Ubuntu-24.04 --no-launch` in the elevated
        child. The attendee's only action is clicking "Yes" on the UAC
        prompt; the agent does not need to dictate commands for the human
        to type. After the elevated install returns, the script re-probes
        and emits its final state.

    What it can NOT do:
      - Reboot the machine. When `wsl --install` enables the feature for
        the first time, Windows requires a reboot before the distro is
        usable. The script reports state=needs_reboot in that case.
      - Bypass UAC silently. The user must click "Yes" on the UAC prompt;
        this is a Windows security feature, not something we engineer
        around. With `-NoElevate`, the script skips elevation and reports
        state=blocked_on_admin instead (used internally to prevent
        recursion when running inside an elevated child).

.OUTPUTS
    Tagged stdout lines:
      [WIN-PROBE] key=value           — observed state, one fact per line
      [WIN-PROBE-ACTION] description  — action being taken or required
      [WIN-PROBE-RESULT] state=<id>   — terminal classification (one line)
      [REMEDIATION] description       — manual recovery step (when blocked)

    Exit codes:
      0  ready_to_handoff
      2  blocked_on_admin           (only when -NoElevate is set or the
                                     user denied UAC)
      3  copy_failed (or other recoverable runtime failure)
      4  needs_reboot               (WSL feature was just enabled; reboot
                                     required before Ubuntu can register)
      5  elevation_failed           (UAC was denied or the elevated
                                     install returned a non-zero exit)
      1  unexpected error
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    # Internal: prevent recursive elevation. The elevated child invokes
    # `wsl --install` directly, not this script — but if a future change
    # ever has the elevated child re-enter setup-windows.ps1, this guard
    # keeps it from looping.
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

# ----- Output helpers ---------------------------------------------------
# Tagged lines go to the output stream (greppable; agents read these).
# Decorative banners go to the host UI (humans see them, agents capture
# them too on a console). Keep tagged lines free of color so a `grep`
# in the captured stream stays clean.
function Probe     ([string]$m) { Write-Output "[WIN-PROBE] $m" }
function Action    ([string]$m) { Write-Output "[WIN-PROBE-ACTION] $m" }
function ProbeRes  ([string]$m) { Write-Output "[WIN-PROBE-RESULT] $m" }
function Remediate ([string]$m) { Write-Output "[REMEDIATION] $m" }

function Invoke-WslInstallElevated {
    <#
    Self-elevate via UAC and run `wsl --install -d Ubuntu-24.04 --no-launch`
    in the elevated child. The attendee clicks "Yes" on the UAC prompt;
    no human typing required. Returns a hashtable describing the result so
    the caller can decide whether to re-probe, declare needs_reboot, or
    surface a failure.

    Why a child PowerShell instead of `Start-Process wsl.exe -Verb RunAs`:
      - We want stdout from `wsl --install` for the agent's log, but
        `-Verb RunAs` blocks `-RedirectStandardOutput`. Routing through a
        PowerShell child lets us redirect inside the child to a temp log
        the parent reads after Wait returns.
      - `wsl --install` enables the WSL feature when it's missing, which
        is exactly the path that requires admin. One command covers both
        the "feature off" and "no distro registered" branches.
    #>

    $logPath = Join-Path $env:TEMP 'wxd-wsl-install.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }

    # Build the elevated child's command. Single-quote the script so the
    # parent's variables don't interpolate; the child writes its own log.
    # *>&1 captures all streams; the trailing EXITCODE line is what the
    # parent parses.
    $childScript = @"
`$ErrorActionPreference = 'Continue'
`$log = '$logPath'
try {
    wsl.exe --install -d Ubuntu-24.04 --no-launch *>&1 | Tee-Object -FilePath `$log -Append
    "EXITCODE=`$LASTEXITCODE" | Add-Content -Path `$log
} catch {
    `$_ | Out-String | Add-Content -Path `$log
    "EXITCODE=1" | Add-Content -Path `$log
}
"@

    Action 'elevating: invoking UAC for `wsl --install -d Ubuntu-24.04 --no-launch`'
    if (-not $Quiet) {
        Write-Host "  → A UAC prompt will appear. Click YES to allow the WSL install." -ForegroundColor Yellow
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $childScript `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        # Most common cause: user clicked "No" on UAC. The exception
        # message is "The operation was canceled by the user."
        return @{ ok = $false; reason = 'uac_denied'; detail = $_.Exception.Message }
    }

    if (-not (Test-Path $logPath)) {
        return @{ ok = $false; reason = 'no_log'; detail = 'Elevated child wrote no log file.' }
    }

    $logLines = Get-Content -Path $logPath -ErrorAction SilentlyContinue
    $exitLine = $logLines | Where-Object { $_ -match '^EXITCODE=' } | Select-Object -Last 1
    $childExit = if ($exitLine -match 'EXITCODE=(\d+)') { [int]$matches[1] } else { -1 }

    # Surface the elevated child's output to the agent's log, one tagged
    # line per source line so multi-line output stays grep-friendly.
    foreach ($l in $logLines) {
        if ($l -match '\S' -and $l -notmatch '^EXITCODE=') {
            Probe "wsl_install_out=$($l -replace '[\r\n]+',' ')"
        }
    }
    Probe "wsl_install_exit=$childExit"

    return @{ ok = ($childExit -eq 0); reason = if ($childExit -eq 0) { 'ok' } else { 'install_failed' }; exit = $childExit; log = $logPath }
}

function Get-RegisteredDistros {
    # Re-runs the `wsl --list --verbose` parse. Used after elevation to
    # detect whether Ubuntu-24.04 became visible. Same UTF-16 dance as
    # the inline block above; factored out so the post-install re-probe
    # doesn't drift from the initial probe.
    $found = @()
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $found }
    $prevEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $raw = & wsl.exe --list --verbose 2>&1 | Out-String
    } catch {
        return $found
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }
    $raw = $raw -replace "`0", ''
    $headerSeen = $false
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not ($line -match '\S')) { continue }
        if (-not $headerSeen) {
            if ($line -match 'NAME\s+STATE\s+VERSION') { $headerSeen = $true }
            continue
        }
        if ($line -match '^(\*?)\s*(\S+)\s+(\S+)\s+(\S+)') {
            $found += [PSCustomObject]@{
                Name    = $matches[2]
                State   = $matches[3]
                Version = $matches[4]
                Default = ($matches[1] -eq '*')
            }
        }
    }
    return $found
}

function Banner($msg) {
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "===============================================================" -ForegroundColor Blue
        Write-Host "  $msg" -ForegroundColor Cyan
        Write-Host "===============================================================" -ForegroundColor Blue
        Write-Host ""
    }
}

Banner "[SETUP-WINDOWS] Probing Windows host for WSL2 readiness"

# ----- OS info ----------------------------------------------------------
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Probe "os=$($os.Caption) (build $($os.BuildNumber))"
} catch {
    # Win32_OperatingSystem can be blocked on lockdown configs (cf. issue
    # #72 field report). Fall back to env vars so we still report something.
    Probe "os=$($env:OS) (Win32_OperatingSystem query blocked)"
}

# ----- Admin state ------------------------------------------------------
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Probe "is_admin=$isAdmin"

# ----- Virtualization ---------------------------------------------------
try {
    $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $virt = if ($cpu.VirtualizationFirmwareEnabled) { 'enabled' } else { 'disabled' }
} catch {
    $virt = 'unknown (Win32_Processor query blocked)'
}
Probe "virtualization=$virt"

# ----- WSL feature state ------------------------------------------------
$wslFeature = 'unknown'
try {
    $feat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop
    $wslFeature = if ($feat.State -eq 'Enabled') { 'enabled' } else { 'disabled' }
} catch {
    # Get-WindowsOptionalFeature requires admin. Probe by command presence.
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $wslFeature = 'present (wsl.exe in PATH; feature query needs admin)'
    } else {
        $wslFeature = 'absent (wsl.exe not in PATH)'
    }
}
Probe "wsl_feature=$wslFeature"

# ----- WSL distros ------------------------------------------------------
# `wsl --list --verbose` emits UTF-16 LE; PowerShell's default OEM/UTF-8
# decoding produces a string riddled with NULs. Switch the console output
# encoding to Unicode for the duration of the call.
$distros       = @()
$defaultDistro = $null
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $prevEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $raw = & wsl.exe --list --verbose 2>&1 | Out-String
    } catch {
        Probe "wsl_list_error=$($_.Exception.Message -replace '[\r\n]+',' ')"
        $raw = ''
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }
    # Strip stray NULs in case encoding handling didn't catch everything.
    $raw = $raw -replace "`0", ''
    $headerSeen = $false
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not ($line -match '\S')) { continue }
        if (-not $headerSeen) {
            if ($line -match 'NAME\s+STATE\s+VERSION') { $headerSeen = $true }
            continue
        }
        # Format: "* Ubuntu-24.04    Running    2"  (asterisk marks default)
        if ($line -match '^(\*?)\s*(\S+)\s+(\S+)\s+(\S+)') {
            $isDefault = ($matches[1] -eq '*')
            $distros += [PSCustomObject]@{
                Name    = $matches[2]
                State   = $matches[3]
                Version = $matches[4]
                Default = $isDefault
            }
            if ($isDefault) { $defaultDistro = $matches[2] }
        }
    }
}

if ($distros.Count -eq 0) {
    Probe "wsl_distros=(none)"
    Probe "default_distro=(none)"
} else {
    $summary = ($distros | ForEach-Object { "$($_.Name)|$($_.State)|$($_.Version)" }) -join ';'
    Probe "wsl_distros=$summary"
    Probe "default_distro=$(if ($defaultDistro) { $defaultDistro } else { '(none set)' })"
}

# ----- Bundle path ------------------------------------------------------
$nativeBundle = $PSScriptRoot
if (-not $nativeBundle) {
    $nativeBundle = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Probe "bundle_native=$nativeBundle"

# Convert C:\Users\foo\Downloads\bundle -> /mnt/c/Users/foo/Downloads/bundle.
# Done imperatively rather than with a -replace script-block callback —
# script-block replacements require PowerShell 6+, and Windows ships with
# 5.1 by default. We can't assume PS7 on attendee machines.
if ($nativeBundle -match '^([A-Za-z]):(.*)$') {
    $driveLetter = $matches[1].ToLower()
    $rest        = $matches[2] -replace '\\', '/'
    $bundleWsl   = "/mnt/$driveLetter$rest"
} else {
    $bundleWsl = $nativeBundle -replace '\\', '/'
}
Probe "bundle_wsl_path=$bundleWsl"

# ----- Pick a working distro --------------------------------------------
# Prefer Ubuntu-24.04 (workshop default), fall back to Ubuntu, then
# wxd-ubuntu (the recovery name from setup-windows-wsl2.md), then default,
# then any registered distro.
$workingDistro = $null
foreach ($pref in @('Ubuntu-24.04', 'Ubuntu', 'wxd-ubuntu')) {
    $hit = $distros | Where-Object { $_.Name -eq $pref } | Select-Object -First 1
    if ($hit) { $workingDistro = $hit; break }
}
if (-not $workingDistro -and $defaultDistro) {
    $workingDistro = $distros | Where-Object { $_.Name -eq $defaultDistro } | Select-Object -First 1
}
if (-not $workingDistro -and $distros.Count -gt 0) {
    $workingDistro = $distros[0]
}

# ----- Decide -----------------------------------------------------------
# When admin is required, self-elevate via UAC rather than asking the
# attendee to open an elevated PowerShell and type `wsl --install` by
# hand. The attendee clicks YES on the UAC prompt; the agent does the
# rest. -NoElevate suppresses this (used by callers that explicitly
# want probe-only behavior).

$needsWslInstall = $false
$needsWslReason  = $null
if ($wslFeature -eq 'absent (wsl.exe not in PATH)') {
    $needsWslInstall = $true
    $needsWslReason  = 'wsl_feature_missing'
} elseif (-not $workingDistro) {
    $needsWslInstall = $true
    $needsWslReason  = 'no_distro_registered'
}

if ($needsWslInstall) {
    Probe "needs_wsl_install_reason=$needsWslReason"

    if ($NoElevate) {
        Action "needs_admin: would run `wsl --install -d Ubuntu-24.04 --no-launch` but -NoElevate is set"
        ProbeRes "state=blocked_on_admin"
        Remediate "Re-run setup-windows.cmd without -NoElevate to auto-elevate via UAC, or run `wsl --install -d Ubuntu-24.04 --no-launch` from an elevated PowerShell manually."
        exit 2
    }

    $result = Invoke-WslInstallElevated

    if (-not $result.ok) {
        switch ($result.reason) {
            'uac_denied' {
                Action "elevation denied: user clicked No on UAC"
                ProbeRes "state=blocked_on_admin"
                Remediate "The attendee declined the UAC prompt. Re-run setup-windows.cmd and click YES when Windows asks for permission to install WSL."
                exit 2
            }
            default {
                Action "elevated wsl --install failed (exit=$($result.exit))"
                ProbeRes "state=elevation_failed"
                Remediate "Inspect the elevated install log at $($result.log). If it reports 'already exists' but the distro is invisible (elevation-scoping quirk), the agent can retry with: wsl.exe --shutdown ; wsl --install Ubuntu --name wxd-ubuntu --web-download --no-launch (still requires UAC)."
                exit 5
            }
        }
    }

    # Elevated install returned success. Re-probe distros to see whether
    # Ubuntu-24.04 became visible. If wsl_feature was off before the
    # install, Windows almost always demands a reboot before the new
    # distro is usable — that's the needs_reboot path.
    Probe "elevated_install_ok=true"
    $distros       = Get-RegisteredDistros
    $defaultDistro = ($distros | Where-Object { $_.Default } | Select-Object -First 1).Name
    if ($distros.Count -eq 0) {
        $summary = '(none)'
    } else {
        $summary = ($distros | ForEach-Object { "$($_.Name)|$($_.State)|$($_.Version)" }) -join ';'
    }
    Probe "wsl_distros_after_install=$summary"

    $workingDistro = $null
    foreach ($pref in @('Ubuntu-24.04', 'Ubuntu', 'wxd-ubuntu')) {
        $hit = $distros | Where-Object { $_.Name -eq $pref } | Select-Object -First 1
        if ($hit) { $workingDistro = $hit; break }
    }
    if (-not $workingDistro -and $defaultDistro) {
        $workingDistro = $distros | Where-Object { $_.Name -eq $defaultDistro } | Select-Object -First 1
    }
    if (-not $workingDistro -and $distros.Count -gt 0) {
        $workingDistro = $distros[0]
    }

    if (-not $workingDistro) {
        # Most likely: the WSL feature was just enabled and Windows
        # needs a reboot before the distro registers. We can't reboot
        # for the user.
        Action "wsl --install succeeded but no distro is registered yet — reboot required"
        ProbeRes "state=needs_reboot"
        Remediate "Windows just enabled the WSL feature; a reboot is required before Ubuntu can register. The agent should ask the attendee to reboot, then re-run setup-windows.cmd."
        exit 4
    }
}

# Pull the distro name into a local; PS 5.1 can mis-parse `$obj.Prop` in
# external-command argument position, so a plain variable is safer.
$distroName = $workingDistro.Name
Probe "selected_distro=$distroName"

# ----- Copy bundle into WSL home if it lives on /mnt/<drive>/ ----------
$wslTarget = '~/wxd-workshop'
if ($bundleWsl -match '^/mnt/[a-z]/') {
    Action "copy_bundle_to_wsl_home (from $bundleWsl to $wslTarget in $distroName)"
    # cp -a preserves permissions and dotfiles; trailing /. copies contents
    # rather than the directory itself, idempotently overwriting any prior
    # copy without removing files (e.g. .env or .watsonx-data) that exist
    # only on the destination.
    $cpCmd = "set -e; mkdir -p $wslTarget; cp -a `"$bundleWsl/.`" $wslTarget/; echo COPIED"
    $cpOut = & wsl.exe -d $distroName -u root -- bash -lc $cpCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Action "copy_failed exit=$LASTEXITCODE output=$($cpOut -join ' ')"
        ProbeRes "state=copy_failed"
        Remediate "Open the Ubuntu app and run manually: cp -a '$bundleWsl/.' '$wslTarget/' ; cd '$wslTarget' ; ./setup/install-workshop.sh --yes"
        exit 3
    }
    Probe "bundle_copied_to=$wslTarget"
} else {
    Probe "bundle_copied_to=(already off /mnt/<drive>; no copy needed)"
}

# ----- Emit handoff -----------------------------------------------------
ProbeRes "state=ready_to_handoff"
Probe "next_command=wsl.exe -d $distroName -u root --cd $wslTarget -- bash -lc './setup/install-workshop.sh --yes'"

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Ready. The driving agent should now run the next_command above to" -ForegroundColor Green
    Write-Host "enter the WSL2 Ubuntu shell with the bundle in place. From there the" -ForegroundColor Green
    Write-Host "install path is identical to macOS / native Linux." -ForegroundColor Green
    Write-Host ""
}

exit 0
