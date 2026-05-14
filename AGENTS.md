# AGENTS.md

This file gives your AI coding agent the context it needs to drive this
workshop. It's read automatically by Claude Code, Cursor, Aider, Codex CLI,
and most other agent tools. If your tool doesn't pick it up automatically,
point your agent at it explicitly: *"read AGENTS.md before we start."*

## What this is

You are about to build a full-stack analytics application on IBM watsonx.data
using only AI-driven coding. The human in the loop steers; the agent (you)
does the typing. The workshop is **non-prescriptive** — there is no answer
key, no scaffolding, no template app, no exercise files in this bundle.
The instructor will guide the attendee through the exercises live, and the
attendee will paste the prompts into the chat with you. Your job is to read
this file, run the installer, and then wait for the first prompt.

The architecture you're aiming at:

- **Transactional tier:** Apache Cassandra 5.0 for hot/operational data.
- **Analytical tier:** Apache Iceberg tables on watsonx.data for historical
  data, queried via Presto.
- **Federation:** Presto unifies Cassandra and Iceberg in single SQL queries.

## Repo layout

- `setup/` — installer + sample data. Run `./setup/install-workshop.sh
  --yes` to provision the environment. The installer is designed to be
  driven by an agent: tagged output (`[STEP N/7]`, `[OK]`, `[INFO]`,
  `[WARN]`, `[FAIL]`, `[TIMING]`, `[PREFLIGHT-RESULT]`, `[REMEDIATION]`)
  makes it grep-friendly, and a final row-count summary confirms a
  healthy install. Per-step durations also append to
  `.workshop-timing.log` at the repo root — useful when an install feels
  slow and you want to see where the time went without re-running.
- `SCHEMAS.md` — **the only artifact handed to you up
  front.** This describes the Cassandra keyspaces and Iceberg schemas with
  enough detail that you can design APIs, queries, and a UI from it. Read
  it before the first exercise prompt arrives.
- `docs/getting-unstuck.md` — a symptom → diagnostic → action playbook.
  When something looks weird, the attendee will point you at this and ask
  you to diagnose and fix.
- `bin/cpdctl` — vendored IBM CLI binary. Don't modify; the installer
  uses it.

## How to work

1. **Run the installer first.** `./setup/install-workshop.sh --yes`. It
   takes ~30 minutes on a cold start. The installer prints a row-count
   summary at the end across every Cassandra keyspace and Iceberg schema —
   use that to confirm health, not ad-hoc probes.
2. **At the end of the installer**, you'll see an `🤖 AGENT — READ THIS
   AND RELAY IT TO THE ATTENDEE` block. Stop and relay the manual
   Cassandra-registration step to the attendee in your own words. Wait
   for them to confirm before continuing.
3. **Read SCHEMAS.md.** It is the spec. The attendee will not hand you a
   PRD, API contract, or UI mock — you produce those during the exercise
   prompts.
4. **Wait for the instructor's prompts.** The workshop runs through
   on-screen prompts that the attendee will paste into the chat. Don't
   pre-empt them; respond by *driving the work*, not by asking the
   attendee to type things themselves.
5. **No manual actions for the attendee, with one exception.** When
   something needs to happen on the filesystem or the shell, *you* do it
   via your tool. The attendee is here to steer and review, not to type
   commands. The one exception: registering Cassandra in the watsonx.data
   UI requires a browser session (no API for it in dev edition), so the
   attendee does that step themselves — you talk them through it.
6. **When stuck, read `docs/getting-unstuck.md` first.** It covers the
   common failure modes (entitlement key issues, port conflicts, podman
   machine state, Cassandra registration mistakes, hallucinated tables,
   federated query timeouts) with the actual diagnostics for each.

## Running on Windows (WSL2)

If the attendee is on Windows, the install runs from inside a WSL2 Ubuntu
shell — never from PowerShell, never from Git Bash, never from `bash`-as-a-
`wsl.exe`-shim. Pre-flight enforces this. If you (the agent) get invoked
from the wrong shell, your job is to redirect, not to try harder.

### Critical: do the whole flow inside WSL2

**Do not download and unzip the bundle on the Windows side and then move
the contents into WSL2.** Field-observed on Win10/Win11 (May 2026): an
agent flow that downloaded the bundle in PowerShell, unzipped with
`Expand-Archive`, then copied into the WSL home corrupted the
encrypted `key.enc` file along the way — three specific bytes got
dropped from the AES-CBC ciphertext during the Windows→WSL transit.
The decrypt then produced a 189-character "JWT" with a malformed
payload that `cp.icr.io` rejected with `invalid username/password`,
and there was no useful diagnostic anywhere upstream.

The reliable shape is **bundle never crosses the boundary as
agent-mediated bytes**. Two ways to achieve that:

1. **Preferred: download & unzip *inside* WSL2 from the start.** Open
   a WSL2 Ubuntu shell (`wsl -d Ubuntu-24.04`), then:

   ```bash
   cd ~
   curl -fsSL -o /tmp/wxd-bundle.zip \
       "https://github.com/<your-gh-user>/wxd-workshop-bundles/releases/latest/download/wxd-workshop.zip"
   unzip -q /tmp/wxd-bundle.zip
   mv wxd-workshop-* wxd-workshop
   cd wxd-workshop
   ```

   `curl` writes raw bytes, `unzip` preserves binary content, the file
   never sees a PowerShell pipeline or a Windows-side file copy. From
   here every subsequent step (decryption, install) runs inside
   WSL2 — no boundary crossings.

2. **Acceptable: download with the browser, then run `setup-windows.cmd`
   *immediately*.** Don't unzip on Windows first; the `.cmd` does it
   by handing the bundle path to `cp -a` inside the WSL distro, which
   preserves binary content. Anything that touches the bundle's bytes
   from the Windows side first is suspect.

The encrypted-key file (`key.enc`) is the load-bearing artifact here:
it's binary, and Windows file-handling tooling has a long history of
applying text-mode transformations to files it doesn't recognize as
binary. If `sha256sum key.enc` (computed in WSL2) doesn't match the
hash the bundle's release notes publish, the bundle was mangled on
the way in — re-fetch via path (1).

### First move on Windows: run `setup-windows.cmd`

The bundle ships a pre-shell bootstrap probe at the bundle root —
`setup-windows.cmd` (a 5-line shim) plus `setup-windows.ps1` (the actual
probe). It exists because pre-flight runs in bash and bash doesn't exist
on Windows yet; this script is the layer pre-flight can't reach.

From a Windows-side shell (PowerShell, cmd, or whatever your tool layer
exposes on Windows), run:

```cmd
setup-windows.cmd
```

The script inspects the host (WSL feature state, distros, virtualization,
admin status, bundle path), does what it can without admin (most importantly:
copies the bundle out of `/mnt/<drive>/` into `~/wxd-workshop` inside WSL),
and emits structured `[WIN-PROBE-*]` tagged output. Read the
`[WIN-PROBE-RESULT] state=…` line and route on it:

- **`state=ready_to_handoff`** — usable distro found, bundle in place. The
  script also emits a `[WIN-PROBE] next_command=wsl.exe -d <distro> -u root
  --cd ~/wxd-workshop -- bash -lc './setup/install-workshop.sh --yes'` line.
  Run that command. From inside the WSL2 shell you're now in, the install
  path is identical to macOS / native Linux — same `[STEP N/7]` output,
  same row-count summary, same `getting-unstuck.md`.

- **`state=blocked_on_admin`** — only seen if the attendee clicked **No**
  on the UAC prompt. By default `setup-windows.cmd` self-elevates via UAC
  when admin is needed (WSL feature missing, or no Ubuntu distro
  registered) and runs `wsl --install -d Ubuntu-24.04 --no-launch` itself
  in the elevated child. Do **not** ask the attendee to open an elevated
  PowerShell or type install commands — re-run `setup-windows.cmd` and
  ask them to click **YES** on the UAC prompt this time. UAC requires a
  human click; that one click is the only thing the human types or
  clicks during install.

- **`state=needs_reboot`** — `wsl --install` enabled the WSL feature for
  the first time, and Windows requires a reboot before Ubuntu can
  register. Ask the attendee to reboot, then re-run `setup-windows.cmd`
  after they're back. (We can't reboot for them.)

- **`state=elevation_failed`** — the elevated `wsl --install` returned
  non-zero. The `[WIN-PROBE] wsl_install_out=…` lines hold the elevated
  child's output (also written to `%TEMP%\wxd-wsl-install.log`); inspect
  them to decide next steps. The `[REMEDIATION]` line covers the common
  "already exists but invisible to this user" elevation-scoping quirk.

- **`state=copy_failed`** — distro found but the bundle copy into WSL home
  hit a permissions or file-lock issue. The `[REMEDIATION]` line gives the
  manual recovery (`cp -a` from inside the Ubuntu app). This is rare; most
  often it means the attendee has the bundle path open in a Windows
  application that's holding a lock.

After `state=ready_to_handoff`, every subsequent command runs inside WSL2.
If your tool layer doesn't auto-route into WSL, prefix bash invocations
with `wsl.exe -d <distro> --cd ~/wxd-workshop --` to keep the context
correct. The bundle on the Windows side becomes a backup copy you can
ignore.

### Fallback decision tree (already in bash, hit a pre-flight `[FAIL]`)

If you didn't run `setup-windows.cmd` and you're already in a bash shell
that pre-flight is rejecting, the original decision tree applies:

- **Pre-flight printed `[FAIL] shell: running under msys_nt... / cygwin / mingw...`.**
  You are in Git Bash or similar. Tell the attendee to open the Ubuntu app
  from their Start menu (or run `wsl -d Ubuntu-24.04` from PowerShell), then
  re-run the workshop from inside that shell. The same files are still there.

- **Pre-flight printed `[FAIL] repo: <path> is on a Windows drive (mounted via 9p) ...`.**
  The bundle was unzipped to `C:\Users\...\Downloads\` or similar, which
  surfaces as `/mnt/c/Users/...` inside WSL2. Container bind-mount writes
  through 9p are 5–10× slower than ext4 — the install will appear to stall.
  Copy the bundle into the attendee's WSL2 home and re-run from there:

  ```bash
  cp -r /mnt/c/Users/<them>/Downloads/wxd-workshop-<version> ~/wxd-workshop
  cd ~/wxd-workshop
  cp /mnt/c/Users/<them>/Downloads/wxd-workshop-<version>/.env .  # if .env was already created
  ./setup/install-workshop.sh --yes
  ```

- **`bash ./setup/install-workshop.sh` from PowerShell says
  `Windows Subsystem for Linux has no installed distributions`** even though
  the attendee believes they installed Ubuntu earlier. This is a WSL
  elevation-scoping quirk: a distro registered from an elevated context
  isn't always visible from a non-elevated one. Don't try to "fix" `bash` —
  abandon it. Tell the attendee to open the Ubuntu app directly. If that
  also fails, walk them through `docs/setup-windows-wsl2.md`'s "wsl --install
  says ... already exists but `wsl --list` is empty" troubleshooting.

- **`wsl --install` succeeds but the distro isn't visible.** Same elevation
  scoping. The recovery sequence is in `docs/setup-windows-wsl2.md`:
  `wsl --shutdown` then `wsl --install Ubuntu --name wxd-ubuntu --web-download --no-launch`,
  retrying from a non-elevated PowerShell.

For initial WSL2 setup (enabling the feature, installing Ubuntu 24.04,
configuring `.wslconfig`, installing Podman inside the distro) walk the
attendee through `docs/setup-windows-wsl2.md` Steps 1–5. After that, the
install path is identical to macOS / native Linux — same `--yes` invocation,
same row-count summary, same `getting-unstuck.md` for failures.

If the attendee's machine is corp-locked (antivirus, VPN, BIOS-disabled
virtualization, Group Policy blocking the Microsoft Store), the
"Troubleshooting (corp Windows specifics)" section of
`docs/setup-windows-wsl2.md` covers the common patterns. Read that before
guessing — the corporate failure modes have specific remediations that are
tedious to rediscover from scratch.

## Common commands

```bash
# Install / reinstall
./setup/install-workshop.sh --yes
./setup/install-workshop.sh --yes --reinstall          # wipe .watsonx-data/ first
./setup/install-workshop.sh --yes --from data          # resume from a step

# Inspect environment
./.watsonx-data/ibm-lh-dev/bin/status --all
podman ps --format '{{.Names}}\t{{.Status}}'
./setup/show-active-installation.sh

# Tear down
./setup/cleanup-all.sh --yes --remove-dirs
```

## Querying Presto — do NOT use `presto-cli`

There is a `bin/presto-cli` wrapper inside `.watsonx-data/ibm-lh-dev/bin/`.
**Don't use it.** It spawns a fresh JVM per invocation, which under
amd64 emulation on Apple Silicon takes 30+ seconds before the query
even starts running and frequently appears to hang. It will eat the
attendee's patience and your context window for no gain.

Two correct ways to run Presto queries:

1. **HTTP API directly** — what backend code (Python/Node/Java) the
   attendee builds will use anyway, via Presto JDBC or the bare HTTP
   protocol. From inside any container in the rootful podman context,
   or from the host, run:

   ```bash
   podman exec ibm-lh-presto curl -k -s -X POST \
     -u "ibmlhadmin:password" \
     -H "X-Presto-User: ibmlhadmin" \
     --data "SELECT count(*) FROM iceberg_data.ecommerce.daily_sales_summary" \
     https://localhost:8443/v1/statement
   ```

   The first response gives you a `nextUri`. Follow it with GETs until
   `nextUri` disappears; result rows arrive in the `data` field.

2. **Watsonx.data Query Workspace UI** — open
   `https://localhost:9443`, click the SQL icon in the left rail.
   Same engine, same speed; this is what the attendee will demo from
   in the workshop.

### What to expect on Apple Silicon

watsonx.data ships amd64-only images. Under qemu on M-series, expect:

- Trivial query (`SELECT 1`): under 1s
- Single-catalog `count(*)`: 5–10s
- Federated join across Cassandra and Iceberg: 15–25s

This is not a bug in the install — it's the cost of running x86_64 JVM
emulated. Intel Macs and Linux/WSL2 attendees see ~3× faster times.

### How to write Presto queries on slow hardware

The expensive thing isn't running queries — it's the **iteration loop**
of writing a half-broken query, running it, hitting a column-name
error, fixing one thing, running it again. Eight rounds of that is two
minutes of staring at the screen. Tactics that keep the loop short:

1. **Front-load schema discovery.** Before writing a JOIN, run
   `DESCRIBE cassandra_catalog.<schema>.<table>` and `DESCRIBE
   iceberg_data.<schema>.<table>` once. Two cheap queries (~6s each)
   beat eight rounds of "column X not found." Keep the column lists
   in your head while you write the query.

2. **Use `LIMIT` while developing.** Presto pushes the limit down past
   the JOIN, so a `LIMIT 5` query runs much faster than the unlimited
   version. Use it while getting the shape right, drop it once the
   query is correct.

3. **Probe JOIN keys before aggregating.** Before writing a six-column
   GROUP BY with three SUMs and an ORDER BY, run
   `SELECT count(*) FROM a JOIN b ON …` to confirm the join cardinality
   is what you expect. If that's wrong, the aggregation is wrong too —
   but the diagnostic query is 5s, not 20s.

4. **Batch related questions into one statement.** If you need top-10
   by revenue *and* count by tier *and* sum by region, write one
   query with three CTEs. One round-trip beats three.

5. **When you hit an error, don't reflex-edit-and-rerun.** Read the
   error message, look back at the DESCRIBE output you already have,
   fix the *whole* query, then run. Each blind retry costs the same
   as a thoughtful one but yields less.

### Hangs vs. slowness

If a query genuinely hangs (no progress, no error after 60s), check
that the Cassandra catalog was registered in the UI — the manual step
the installer's agent-directive block told the attendee to do at the
end of install. An unregistered catalog reference produces a hang in
some Presto code paths instead of a clean error.

## Conventions

- **Sample data is regenerated, not hand-edited.** Files under
  `setup/sample-data/*/generated_data/` are outputs of `generate_data.py`
  scripts. If you need to change them, edit the generator and re-run.
- **CSVs / parquet should not be hand-modified.** Same reason.
- **Repo-local install only.** watsonx.data installs into `.watsonx-data/`
  in the bundle root (gitignored). Don't relocate it.
- **Cassandra access from Presto:** federated queries reach Cassandra at
  `host.containers.internal:9042` with `cassandra` / `cassandra`. The
  catalog inside Presto is named `cassandra_catalog` once the attendee has
  registered it in the watsonx.data UI (the post-install manual step).
- **You may see `linux/amd64 vs linux/arm64` warnings on Apple Silicon.**
  This is expected and harmless — the workshop runs amd64 images under
  emulation.

## Fetching the entitlement key

The watsonx.data installer needs an IBM Container Registry entitlement key
to pull container images from `cp.icr.io`. The bundle ships the key as an
**encrypted file**, `key.enc`, at the bundle root. The instructor displays
the workshop passphrase on the slide; ask the attendee for it.

Decrypt to `.env`. **Run this inside WSL2**, not from PowerShell — see
the "Critical: do the whole flow inside WSL2" subsection above. A
PowerShell pipeline or `Out-File` redirect will silently drop specific
bytes from the openssl output (UTF-16 conversion of binary content),
producing a 189-byte "JWT" that `cp.icr.io` rejects:

```bash
# Single bash subshell — no intermediate variable, no Windows-side
# handling. The decrypted bytes flow openssl → tr → file, all inside
# one Linux process tree. `tr -d '\r\n'` is load-bearing: a trailing
# newline in the key produces `cp.icr.io: invalid username/password`
# from podman login with no other diagnostic.
{ printf 'IBM_ENTITLEMENT_KEY='
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 \
      -in key.enc -pass pass:'<passphrase>' | tr -d '\r\n'
  printf '\n'
} > .env

# Confirm length is 192 — anything less means the .env got corrupted
# despite the precautions and you need to retry.
awk -F= '/^IBM_ENTITLEMENT_KEY=/ {print length($2)}' .env
```

Three rules:

1. **Do not echo the key value back into the chat transcript.** Confirm
   to the attendee that the decrypt succeeded by reporting length +
   first/last 4 characters (e.g. *"got 192-char key, eyJh…Q9p2"*) —
   never the full string. The instructor rotates the entitlement key
   right after the workshop, so there's no value in saving it.
2. **If decryption fails with "bad decrypt" or similar**, the passphrase
   is wrong. Ask the attendee to re-read it from the slide (typos in
   manual transcription are the common case). Don't retry blindly —
   `openssl enc -d` exits non-zero on the first wrong attempt and you'd
   just be guessing.
3. **If `key.enc` isn't present at the bundle root**, the bundle was
   built without `--encrypt-key` (development/test build). Ask the
   attendee for the entitlement key directly.
4. **If `awk` reports a length other than 192**, your decrypt pipeline
   touched Windows-side tooling somewhere. Don't try to patch the
   length — redo the entire bundle download inside WSL2 per the
   "Critical: do the whole flow inside WSL2" subsection. Patching a
   corrupted JWT character-by-character is a debugging dead-end.

Why this is shipped as an encrypted blob rather than fetched from a URL:
GitHub's secret scanner finds IBM entitlement keys in any GitHub-hosted
content (including secret gists) and IBM is a partner, so auto-revoke
fires within hours. The encrypted blob is opaque to scanners; the
passphrase isn't on GitHub anywhere.

## Where to start

After fetching the entitlement key per the section above, run
`./setup/install-workshop.sh --yes`. Read `SCHEMAS.md`
while it runs. After the install completes and the attendee has registered
Cassandra in the UI, wait for the first exercise prompt.
