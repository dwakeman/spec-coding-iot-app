# Workshop Setup on Windows (via WSL2)

This is the canonical setup guide for Windows attendees. The workshop's install scripts are written for Linux/macOS shells; on Windows, you'll run them inside a Linux environment provided by **WSL2** (Windows Subsystem for Linux). Once you're inside WSL2, the workshop install path is identical to the macOS/Linux path — same scripts, same commands, same outcomes.

> **A note on how this workshop expects you to work.** This is a spec-coding workshop: the headline skill we're teaching is **driving development through your AI coding agent** (Claude Code, Cursor, GitHub Copilot, etc.). Apply that framing from minute one. Throughout this guide, when you see *"have your coding agent run X"*, that is the expected mode of operation: paste the command into your agent, ask it to run the command, and ask it to interpret the output and surface anything you should look at. Don't bypass the agent and run things yourself — the workshop is much easier (and more representative of real spec-coding work) when the agent is the primary actor and you are reviewing.

**Time budget.** Plan ~60 minutes of active setup time, plus ~25 minutes of unattended download time during the watsonx.data install.

> [!TIP]
> **Already have WSL2 + Ubuntu set up from a prior project?** Skip Steps 1–3 below and go straight to your unzipped bundle in Windows Explorer. Run `setup-windows.cmd` (double-click, or `setup-windows.cmd` from any Windows shell). The bootstrap probe checks your WSL state, copies the bundle into the WSL2 home directory, and emits `[WIN-PROBE-*]` tagged output your coding agent reads to drive the rest of the install. Most attendees with existing WSL2 will go from "double-click" to "install running in the right place" in under a minute. If the probe reports `state=blocked_on_admin`, you don't have a WSL2 distro yet — come back to Steps 1–3.

---

## Prerequisites

Before you start, confirm:

- **Hardware**: 16 GB RAM minimum (32 GB strongly recommended), 50 GB free disk space on `C:` (WSL2 stores its filesystem on `C:` by default).
- **Windows version**: Windows 11, or Windows 10 build 19041+ (`winver` to check).
- **Virtualization enabled in BIOS/UEFI**. If `wsl --install` later fails with a virtualization error, this is the first thing to check.
- **Local admin rights**, or the ability to enable WSL through your corp self-service portal. WSL install requires admin privileges; running the workshop afterward does not.
- **IBM entitlement key**: get one at [https://myibm.ibm.com/products-services/containerlibrary](https://myibm.ibm.com/products-services/containerlibrary). It's a JWT (~400+ characters). Keep it ready — you'll paste it into a `.env` file in step 5.

---

## Step 1 — Enable WSL2 and install Ubuntu 24.04

In an **administrator** PowerShell (right-click Start → "Windows Terminal (Admin)"):

```powershell
wsl --install -d Ubuntu-24.04
wsl --update
```

The first command enables the WSL feature, downloads the WSL2 kernel, and installs the Ubuntu 24.04 distro. We pin to 24.04 specifically because it ships Podman 4.9 in `apt`, where `host.containers.internal` resolves reliably from inside containers — Ubuntu 22.04's `apt` only has Podman 3.4, which the workshop's pre-flight rejects. It typically requires a reboot. After reboot, an Ubuntu terminal will open the first time and prompt for a UNIX username and password — pick anything; this is the local user inside the Linux distro.

`wsl --update` ensures you're on the current WSL2 kernel.

**Verify**:

```powershell
wsl --list --verbose
```

You should see `Ubuntu-24.04` with `STATE: Running` and `VERSION: 2`.

---

## Step 2 — Configure WSL2 resources (do not skip)

WSL2's defaults give VMs roughly half your host RAM and half your CPUs. watsonx.data needs ~12–16 GB and ~8 CPUs to be responsive. Without this step, the workshop will run, but slowly enough to be frustrating.

Create or edit `%USERPROFILE%\.wslconfig` (in Windows, not inside WSL2). In PowerShell:

```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

Paste:

```ini
[wsl2]
memory=16GB
processors=8
swap=8GB

[experimental]
sparseVhd=true
```

The `sparseVhd=true` line (Windows 11 only — silently ignored on Windows 10) lets the WSL2 ext4.vhdx shrink when files are deleted. Without it, the workshop's ~30 GB of images and data permanently inflate `C:` even after `cleanup-all.sh` runs.

Save, close, then in PowerShell:

```powershell
wsl --shutdown
```

This applies the new limits. The next time you open Ubuntu, WSL2 will boot with the configured resources.

If your laptop has only 16 GB total, set `memory=10GB` here and accept that some Windows-side apps may be tight. Below 10 GB, watsonx.data will not start reliably.

---

## Step 3 — Install Podman inside Ubuntu

Open the **Ubuntu** terminal (Start menu → "Ubuntu 22.04"). Everything from here on happens **inside WSL2**, not in PowerShell.

> **Important — do NOT install Podman Desktop on Windows.** Podman Desktop manages its own WSL distro and exposes `podman` to PowerShell. The workshop's install scripts call `podman` from inside the Ubuntu distro you just set up, and mixing the two is a common source of "podman: command not found" or "no such container" confusion. Use CLI Podman inside Ubuntu, as below. This keeps the Windows install path as close to the macOS/Linux path as possible.

In the Ubuntu terminal:

```bash
sudo apt-get update
sudo apt-get install -y podman
podman --version
```

You should see `podman version 4.9.x` or higher. (If you see 3.x, you're on Ubuntu 22.04 — go back to Step 1 and install Ubuntu-24.04 instead. The workshop's pre-flight requires Podman ≥ 4.0.)

> **WSL2 + systemd note.** The workshop's pre-flight occasionally suggests `systemctl --user restart podman.socket` as a remediation. That only works if systemd is the init system in your distro — Ubuntu 24.04 enables it by default, but if you ever see "system has not been booted with systemd as init system" you can re-enable it by adding `[boot]\nsystemd=true` to `/etc/wsl.conf` (inside WSL2) and running `wsl --shutdown` from PowerShell.

---

## Step 4 — Clone the workshop repo (inside WSL2 home, not `/mnt/c/...`)

> **Performance trap.** Cloning the repo onto a Windows drive (`/mnt/c/Users/...`) makes every file operation 5–10× slower because of the cross-filesystem boundary. Always clone into the **WSL2 home directory** (`~`). The workshop's pre-flight (`./setup/preflight.sh`) now enforces this — running the installer from `/mnt/...` will fail fast with a remediation message.

In the Ubuntu terminal:

```bash
cd ~
git clone <repo-url> wxd-spec-coding
cd wxd-spec-coding
```

(Replace `<repo-url>` with the workshop's git URL.)

If `git` isn't installed, `sudo apt-get install -y git` first.

---

## Step 5 — Set the entitlement key

Still in the Ubuntu terminal, with your working directory at the repo root:

```bash
echo 'IBM_ENTITLEMENT_KEY=paste-your-key-here' > .env
```

Replace `paste-your-key-here` with the JWT from [the IBM Container Library](https://myibm.ibm.com/products-services/containerlibrary). The repo's `.gitignore` already excludes `.env`, so the key won't end up in git.

---

## Step 6 — Run the installer through your coding agent

> [!IMPORTANT]
> **You must be in the Ubuntu (WSL2) shell to run the installer.** Not Git Bash. Not `bash` from PowerShell (that resolves to a `wsl.exe` shim and dies with `Windows Subsystem for Linux has no installed distributions` if your distro is in a different elevation context). Not MSYS2 or Cygwin. Open the **Ubuntu** app from the Start menu, or run `wsl -d Ubuntu-24.04` in PowerShell — you should see a prompt like `root@hostname:~/wxd-spec-coding#`. The workshop's pre-flight will `[FAIL]` immediately and refuse to proceed if it detects Git Bash / MSYS / Cygwin, so if you find yourself with a `[FAIL] shell: running under msys_nt...` line, you're in the wrong shell.

Open your coding agent in this directory (e.g. `claude` for Claude Code, or open the folder in Cursor / VS Code with Copilot). **Have your coding agent run the installer**:

> "Please run `./setup/install-workshop.sh --yes` and watch its progress. Tell me about any `[FAIL]` or `[WARN]` lines and confirm you see the row-count summary table at the end."

That's the workshop's preferred interaction model — your agent runs the script, monitors the tagged output (`[STEP N/7]`, `[OK]`, `[INFO]`, `[WARN]`, `[FAIL]`), and surfaces anything you need to look at. Your job is to read its summary and make decisions.

The installer will:
1. Verify Podman is installed
2. Install watsonx.data Developer Edition into `.watsonx-data/` inside the repo (~20 minutes; this is the long step)
3. Deploy Cassandra 5.0 in a Podman container
4. Generate sample data and load it into Cassandra
5. Create Iceberg tables in watsonx.data
6. Print a row-count summary table — every keyspace and Iceberg schema, with row counts. **This table is the green-light signal.** If everything has the expected row counts, you're done.

If the run dies partway, your agent can resume without redoing the slow parts:

> "Please re-run with `--yes --from data` to resume from the data-loading step."

(Valid `--from` values: `prereqs`, `watsonx`, `cassandra`, `data`, `iceberg`, `summary`.)

---

## Step 7 — Verify access from Windows

The watsonx.data web UI is exposed on `localhost` from WSL2's perspective, which Windows transparently forwards. Open your **Windows** browser:

- **watsonx.data UI**: [https://localhost:9443](https://localhost:9443)
- **Login**: `ibmlhadmin` / `password`
- You'll see a self-signed-cert warning — click **Advanced → Proceed to localhost (unsafe)**. This is safe for a local-only dev install.

**Cassandra connectivity**:
- From inside WSL2: `host.containers.internal:9042`, user `cassandra`, password `cassandra`.
- From Windows directly: `localhost:9042`.

If you can log into the watsonx.data UI and see the catalogs in the sidebar, the install is complete.

---

## Troubleshooting (corp Windows specifics)

These are the failure modes most likely to bite a corp-imaged Windows laptop. The list will grow as we get feedback from real installs.

### `bash` says "Windows Subsystem for Linux has no installed distributions"

You ran `bash ./setup/install-workshop.sh --yes` from PowerShell or `cmd`, and got `Windows Subsystem for Linux has no installed distributions` even though you ran `wsl --install -d Ubuntu-24.04` earlier.

This happens when WSL was installed from an elevated context but you're querying from a non-elevated one (or vice versa) — they have separate distro registries until you explicitly link them. It's not specific to this workshop; it's a WSL elevation-scoping behavior.

The fix is to **stop using `bash` from PowerShell entirely.** That shortcut resolves to a `wsl.exe` shim and is sensitive to which user/elevation context the distro was installed under. Open the **Ubuntu app** directly from the Start menu (or run `wsl -d Ubuntu-24.04` in a non-elevated PowerShell). You should land at a Linux prompt like `root@hostname:~#`. From *that* shell, navigate to the repo and run `./setup/install-workshop.sh --yes`.

### `wsl --install` says "A distribution with the supplied name already exists" but `wsl --list` is empty

Same elevation-scoping issue: an earlier (possibly elevated) `wsl --install` partially registered the distro at the OS level, but it's not visible to your current user context.

Recovery sequence (run from PowerShell):

```powershell
# Force-stop everything WSL is doing and clear in-flight state
wsl.exe --shutdown

# Re-install with an explicit fresh name and the web-download path,
# bypassing the Microsoft Store mirror that may be misbehaving.
wsl.exe --install Ubuntu --name wxd-ubuntu --web-download --no-launch

# Confirm visibility
wsl.exe --list --verbose
```

If you still don't see your distro from a non-elevated PowerShell, the elevation-scoped registration is sticky — open a non-elevated PowerShell and run `wsl --install -d Ubuntu-24.04` *from that context*. Whichever elevation context successfully completes the install is the one that owns the distro afterward.

If you've ended up with multiple half-registered Ubuntu distros, list them with `wsl --list --verbose` from each context and `wsl --unregister <name>` the duplicates before retrying.

### `WslRegisterDistribution failed` or "Virtual Machine Platform not enabled"

Virtualization is disabled in BIOS/UEFI, or required Windows features are off.

- In an admin PowerShell:
  ```powershell
  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
  ```
- Reboot.
- If still failing, reboot into BIOS/UEFI and enable **Intel VT-x** / **AMD-V** virtualization. On corp-locked BIOS, this may require IT.

### Antivirus blocking Podman or WSL file ops

CrowdStrike, SentinelOne, McAfee, and similar agents sometimes flag the container storage layer or quarantine `vmmem.exe`. Symptoms: `podman pull` hangs, container creation fails with permission errors, WSL2 startup is unusually slow.

If you can't disable the agent, ask your IT team to add exclusions for:
- `\\wsl$\Ubuntu-24.04\` (or your distro path)
- `%LOCALAPPDATA%\Packages\CanonicalGroupLimited.Ubuntu*`
- Inside WSL2: `/var/lib/containers/`

### Group policy blocking Microsoft Store / WSL distro install

If `wsl --install -d Ubuntu-24.04` fails because the Store is blocked:

- Download the Ubuntu 22.04 `.appx` package from Microsoft and install it via PowerShell:
  ```powershell
  Add-AppxPackage -Path .\Ubuntu-24.04.appx
  ```
- Or ask your IT team to push WSL through corp deployment (Intune / SCCM).

### Corp VPN blocking the Podman pulls

If `podman pull cp.icr.io/...` or `podman pull docker.io/library/cassandra` hangs or fails with TLS errors, your corp VPN may be MITM'ing the traffic.

- Confirm by disconnecting the VPN and retrying the pull. If it succeeds, VPN is the issue.
- Ask your IT team to add `cp.icr.io`, `docker.io`, and `registry-1.docker.io` to the proxy bypass / split-tunnel list.
- As a workaround, run the long install step (`--from watsonx`) off-VPN, then reconnect.

### Hyper-V conflict with VirtualBox / VMware

If you have VirtualBox or VMware Workstation installed, WSL2 may fail to start because Hyper-V and these hypervisors conflict at the BIOS level on older systems. On Windows 10 build 19041+ this is mostly resolved, but if you see issues:

- Disable VirtualBox/VMware temporarily, or use their Hyper-V-aware modes.

### `localhost:9443` not responding from Windows browser

Modern WSL2 forwards `localhost` automatically. If it's not working:

- From PowerShell: `wsl --shutdown`, then re-open Ubuntu and re-run `./setup/install-workshop.sh --yes --from summary` (just to verify services are up).
- Check `%USERPROFILE%\.wslconfig` doesn't have `[wsl2]\nlocalhostForwarding=false` — it should be the default `true`.

### Port already in use (9443, 9042, 8443)

Another process on Windows is bound to the port.

- In PowerShell:
  ```powershell
  netstat -ano | findstr :9443
  taskkill /PID <PID> /F
  ```

### Slow performance after a fresh install

Two common causes:

1. **Cloned the repo on `/mnt/c/...`** — re-clone into `~/wxd-spec-coding` inside WSL2 home (Step 4).
2. **Insufficient WSL2 resources** — re-check `%USERPROFILE%\.wslconfig` (Step 2) and run `wsl --shutdown`.

### `Self-signed certificate` browser warning

Expected. The watsonx.data UI uses a self-signed cert for local development. Click through the "Advanced → Proceed" warning. This is safe for `localhost` only.

---

## Cleanup

When you're done with the workshop and want to free disk space:

Have your coding agent run the cleanup script for you:

> "Please run `./setup/cleanup-all.sh --yes --remove-dirs` and confirm everything is removed."

This stops and removes all workshop containers, images, and the `.watsonx-data/` directory.

If you also want to remove the entire WSL2 distro:

```powershell
wsl --unregister Ubuntu-24.04
```

This deletes the distro and everything in it. Irreversible — make sure you don't have other work in this distro.

---

## What's different from macOS/Linux

Almost nothing. The only Windows-specific steps are 1–3 (enabling WSL2, configuring its resources, installing Podman inside it). From Step 4 onward — clone, `.env`, `./setup/install-workshop.sh --yes`, browser at `localhost:9443` — every step is identical to a native macOS or Linux install.

That's intentional: keeping the Windows path as close to the canonical path as possible means the same coding-agent prompts, the same troubleshooting, and the same instructor guidance work for everyone.

Two small things `install-workshop.sh` does differently when it detects WSL2 (visible in the script's `[INFO]` lines, not anything you need to do manually):

- **Routes the watsonx.data install to the "direct" extraction method** (`setup/watsonx-data/install-watsonx-data-direct.sh`). It does an image pull plus a host-side `tar` extraction instead of bind-mounting `.watsonx-data/` into a container during install. Bind-mounted writes through 9p are pathologically slow on WSL2; the direct method sidesteps that entirely.
- **Skips the `podman machine` setup**, which doesn't exist on Linux/WSL2 — Podman runs directly inside the distro.
