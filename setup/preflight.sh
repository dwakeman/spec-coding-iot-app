#!/usr/bin/env bash
###############################################################################
# Workshop pre-install checks
#
# Validates that the host is ready for ./setup/install-workshop.sh to succeed.
# Three required checks (per #24 Milestone 3):
#   1. Podman state — installed, version >= 4.0, daemon reachable, optional
#      machine running on macOS, test pull from docker.io.
#   2. Port conflicts — 9443, 9042, 8443. If a workshop container already
#      holds the port, that's reported as OK (workshop already running).
#   3. Entitlement key — present, JWT-shaped, AND a live login probe against
#      cp.icr.io that exits in <15s vs the 20-min discover-on-image-pull path.
#
# Plus minor sanity checks: curl, python3, .env, run-from-repo-root.
#
# Output is tagged so a coding agent can grep:
#   [OK] / [WARN] / [FAIL] / [INFO] per-check
#   [PREFLIGHT-RESULT] pass=N warn=N fail=N        single-line summary
#   [REMEDIATION] ...                              actionable fixes per FAIL
#
# Exit codes:
#   0  all green or warnings only
#   1  at least one FAIL
#   2  internal error (e.g. unable to detect ports at all)
###############################################################################

set -uo pipefail

# Colors (off when stdout isn't a TTY so log scrapes stay clean)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

QUIET=0
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            cat <<EOF
Usage: ./setup/preflight.sh [--quiet]

Validates that the host is ready to run ./setup/install-workshop.sh.

Options:
  --quiet, -q   Print only the [PREFLIGHT-RESULT] summary line.
  --help, -h    Show this help.

Exit code: 0 on pass (or warnings only), 1 on any failure.

To run as part of an install: install-workshop.sh calls this automatically
before its first step. Use this script directly to re-check after fixing
an issue, without re-running the whole installer.
EOF
            exit 0
            ;;
    esac
done

PASS=0; WARN=0; FAIL=0
REMEDIATION=()

ok()   { (( QUIET )) || echo "${GREEN}[OK]${NC}   $*"; PASS=$((PASS+1)); }
warn() { (( QUIET )) || echo "${YELLOW}[WARN]${NC} $*"; WARN=$((WARN+1)); }
fail() { (( QUIET )) || echo "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }
info() { (( QUIET )) || echo "${BLUE}[INFO]${NC} $*"; }
remediate() { REMEDIATION+=("$*"); }

OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')

###############################################################################
# Header
###############################################################################
if (( ! QUIET )); then
    echo
    echo "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo "  ${CYAN}[PREFLIGHT] Workshop pre-install checks${NC}"
    echo "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
fi

###############################################################################
# Shell environment sanity (fail fast before any podman / python check)
###############################################################################
# Git Bash, MSYS, and Cygwin on Windows give an attendee a bash shell with
# curl and git, but no podman, no python3-venv, and no Linux container
# runtime. If we let preflight continue from that shell the attendee gets
# a flood of confusing follow-on failures (podman: not installed, with
# remediation 'sudo apt-get install -y podman' on a non-Linux box). Cut it
# off here with a redirect to WSL2 instead.
case "$OS_TYPE" in
    mingw*|msys*|cygwin*)
        fail "shell: running under $OS_TYPE (Windows Git Bash / MSYS / Cygwin) — workshop scripts require WSL2 Ubuntu, not Git Bash"
        remediate "The workshop must run inside WSL2 Ubuntu, not Git Bash. See docs/setup-windows-wsl2.md: install Ubuntu 24.04 with 'wsl --install -d Ubuntu-24.04' (admin PowerShell), then re-clone the repo under your WSL2 home and run the workshop from the Ubuntu shell."
        echo
        echo "[PREFLIGHT-RESULT] pass=$PASS warn=$WARN fail=$FAIL"
        if (( ! QUIET )); then
            echo
            echo "${YELLOW}[REMEDIATION]${NC}"
            for item in "${REMEDIATION[@]}"; do echo "  - $item"; done
            echo
        fi
        exit 1
        ;;
esac

###############################################################################
# Run-from-repo-root sanity
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Check for files that exist in *both* the instructor repo and the attendee
# bundle. README.md and exercises/ are instructor-only — the bundle ships
# bare-bones — so they can't be the marker. install-workshop.sh and the
# manifest of the bundler itself are present everywhere.
if [[ ! -x setup/install-workshop.sh || ! -d setup/sample-data ]]; then
    fail "repo: not running from workshop root (expected setup/install-workshop.sh and setup/sample-data/)"
    remediate "cd into the workshop directory (the one containing setup/) and re-run."
else
    ok "repo: running from workshop root ($REPO_ROOT)"
fi

# WSL2: a repo placed under /mnt/<drive>/... lives on Windows NTFS surfaced
# into the Linux distro through 9p. Container bind-mount writes during the
# watsonx.data install then translate to thousands of cross-filesystem RPCs,
# turning the documented 30-min install into 90+ minutes of silent crawling.
# docs/setup-windows-wsl2.md tells attendees to clone under ~/, but the
# warning is easy to miss when downloading a workshop bundle into Downloads/.
# Catch it here before the long install runs.
if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    case "$REPO_ROOT" in
        /mnt/*)
            fail "repo: $REPO_ROOT is on a Windows drive (mounted via 9p) — installs run 5-10x slower from /mnt/<drive>/"
            remediate "Move the workshop under your WSL2 home and re-run from there: cp -r '$REPO_ROOT' ~/wxd-workshop && cd ~/wxd-workshop && ./setup/preflight.sh   (or fresh-clone with: cd ~ && git clone <repo-url> wxd-workshop). Re-create .env in the new location if needed."
            ;;
    esac
fi

###############################################################################
# Check 1: Podman
###############################################################################
PODMAN_OK=0
if ! command -v podman &>/dev/null; then
    fail "podman: not installed"
    case "$OS_TYPE" in
        darwin) remediate "Install Podman: brew install podman (then podman machine init && podman machine start)" ;;
        linux)  remediate "Install Podman: sudo apt-get install -y podman   (or sudo yum install -y podman)" ;;
        *)      remediate "Install Podman: see https://podman.io/getting-started/installation" ;;
    esac
else
    PODMAN_VERSION="$(podman --version 2>/dev/null | awk '{print $3}')"
    PODMAN_MAJOR="$(echo "$PODMAN_VERSION" | cut -d. -f1)"
    if [[ -z "$PODMAN_MAJOR" ]]; then
        fail "podman: installed but version unparseable ($PODMAN_VERSION)"
        remediate "Reinstall Podman; 'podman --version' should print a x.y.z version string."
    elif (( PODMAN_MAJOR < 4 )); then
        fail "podman: version $PODMAN_VERSION is below 4.0 floor"
        remediate "Upgrade Podman to >= 4.0 (brew upgrade podman / apt-get upgrade podman)."
    else
        ok "podman: version $PODMAN_VERSION (>= 4.0 required)"
        PODMAN_OK=1
    fi
fi

# Machine layer (macOS only)
if (( PODMAN_OK )); then
    if [[ "$OS_TYPE" == "darwin" ]]; then
        if podman machine list 2>/dev/null | grep -q "Currently running"; then
            RUNNING_MACHINE="$(podman machine list 2>/dev/null | awk '/Currently running/ {print $1; exit}')"
            # Strip asterisk from machine name (podman marks the default machine with *)
            RUNNING_MACHINE="${RUNNING_MACHINE%\*}"
            # The watsonx.data Presto container's auth init script chmods files
            # on a bind-mounted volume. On a rootless podman machine that fails
            # ("Operation not permitted"), Presto then crashes with
            # "authenticator was not loaded". Require rootful on macOS.
            if podman machine inspect "$RUNNING_MACHINE" --format '{{.Rootful}}' 2>/dev/null | grep -q true; then
                ok "podman: machine '$RUNNING_MACHINE' running (rootful)"
            else
                fail "podman: machine '$RUNNING_MACHINE' is rootless — watsonx.data requires rootful on macOS"
                remediate "Switch to rootful: podman machine stop $RUNNING_MACHINE && podman machine set --rootful $RUNNING_MACHINE && podman machine start $RUNNING_MACHINE"
                PODMAN_OK=0
            fi
        else
            fail "podman: no machine is running (macOS requires a running podman machine)"
            remediate "Run ./setup/install-workshop.sh — it auto-creates a rootful 'watsonx-workshop' machine before this check. To do it manually: podman machine init --rootful --cpus 8 --memory 16384 --disk-size 200 watsonx-workshop && podman machine start watsonx-workshop"
            PODMAN_OK=0
        fi
    else
        info "podman: native Linux — no machine layer to check"
    fi
fi

# Daemon reachable
if (( PODMAN_OK )); then
    if podman info --format '{{.Host.OS}}' &>/dev/null; then
        ok "podman: daemon reachable"
    else
        fail "podman: daemon not reachable ('podman info' failed)"
        case "$OS_TYPE" in
            darwin) remediate "Restart the podman machine: podman machine stop && podman machine start" ;;
            *)
                # On WSL2 specifically, the systemctl remediation only works if
                # systemd is the init system. Default WSL2 distros pre-Ubuntu-24.04
                # don't run systemd unless /etc/wsl.conf has [boot] systemd=true,
                # in which case 'systemctl --user' fails with "Failed to connect
                # to bus" and the attendee gets stuck. Detect and route.
                if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && [[ ! -d /run/systemd/system ]]; then
                    remediate "WSL2 distro is not running systemd, so 'systemctl --user' won't work. Enable systemd: add the lines '[boot]' and 'systemd=true' to /etc/wsl.conf (inside WSL2), then run 'wsl --shutdown' from PowerShell and reopen the distro. Ubuntu 24.04 has systemd on by default — if you're on 22.04, consider upgrading."
                else
                    remediate "Restart the podman service: systemctl --user restart podman.socket (or reboot the WSL2 distro: wsl --shutdown from PowerShell)"
                fi
                ;;
        esac
        PODMAN_OK=0
    fi
fi

# Test pull (validates daemon + network egress to docker.io in one shot)
if (( PODMAN_OK )); then
    if podman pull --quiet hello-world:latest &>/dev/null; then
        ok "podman: test pull (hello-world) succeeded"
    else
        fail "podman: test pull from docker.io failed"
        remediate "Check network egress to docker.io. On corp networks, your VPN may MITM TLS or block container registries — try off-VPN or ask IT to whitelist registry-1.docker.io and cp.icr.io."
    fi
fi

###############################################################################
# Check 2: Port conflicts (9443, 9042, 8443)
###############################################################################

# Cross-platform: returns "PID COMMAND" if port is held, empty otherwise.
port_holder() {
    local port="$1" out=""
    if command -v lsof &>/dev/null; then
        # lsof works on both macOS and Linux. -nP avoids name resolution.
        out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2" "$1; exit}')"
    elif command -v ss &>/dev/null; then
        # ss output: ... users:(("name",pid=12345,fd=3))
        out="$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+,[^"]*"[^"]+"' | head -1 \
            | sed -E 's/pid=([0-9]+),[^"]*"([^"]+)"/\1 \2/')"
    elif command -v netstat &>/dev/null; then
        # netstat -an has no PID/command columns on macOS, so we can only
        # confirm "something is listening" — emit "unknown unknown" rather
        # than a literal "?" so the failure message reads cleanly.
        out="$(netstat -an 2>/dev/null | awk -v p=":$port" '$1 ~ /^tcp/ && $4 ~ (p "$") && $NF ~ /LISTEN/ {print "unknown unknown"; exit}')"
    else
        echo "NOPROBE"
        return
    fi
    echo "$out"
}

# Returns 0 if a workshop-owned container holds the given port.
#
# On macOS the listener visible to lsof is gvproxy (podman-machine's
# host-side port forwarder), not the container itself. So we match by:
#   - holder command is gvproxy (or qemu) AND
#   - any workshop container is currently running
# That covers wxd console (9443/8443), wxd internals, and Cassandra (9042),
# all of which surface through the same gvproxy process. Whitelisting the
# whole workshop set avoids per-port name maps drifting out of sync as
# IBM rearranges containers across releases.
workshop_owns_port() {
    local port="$1" holder_cmd="$2"
    if ! command -v podman &>/dev/null; then return 1; fi
    case "$holder_cmd" in
        gvproxy|qemu|qemu-system-*) ;;                # macOS podman-machine forwarders
        slirp4netns|rootlessport|pasta|conmon|podman) ;;  # Linux / WSL2 rootless + rootful
        *) return 1 ;;
    esac
    # Capture before grep -q. With `set -o pipefail`, piping straight into
    # `grep -q` is racy: grep exits on first match, podman ps still writing
    # gets SIGPIPE (exit 141), and the pipeline reports failure even though
    # the match succeeded. Buffering the names breaks the pipe.
    local names
    names=$(podman ps --format '{{.Names}}' 2>/dev/null)
    grep -qE '^(ibm-lh-|lhconsole-|lhingestion-|cassandra-workshop$|ibm-cassandra-)' <<<"$names"
}

PROBE_AVAILABLE=1
for port in 9443 9042 8443; do
    holder="$(port_holder "$port")"
    if [[ "$holder" == "NOPROBE" ]]; then
        PROBE_AVAILABLE=0
        warn "port $port: cannot probe (no lsof, ss, or netstat available)"
        continue
    fi
    if [[ -z "$holder" ]]; then
        ok "port $port: free"
    elif workshop_owns_port "$port" "${holder##* }"; then
        ok "port $port: held by a workshop container (workshop already running here)"
    else
        fail "port $port: in use by $holder"
        remediate "port $port held by an unrelated process: stop that process, or if you have an old workshop install, run ./setup/cleanup-all.sh --yes --remove-dirs and re-run pre-flight."
    fi
done

if (( ! PROBE_AVAILABLE )); then
    remediate "Install one of: lsof (recommended, all platforms), iproute2 (Linux ss), net-tools (netstat). Without one of these, pre-flight can't detect port conflicts before the install runs."
fi

###############################################################################
# Check 3: Entitlement key (format + live login probe)
###############################################################################

# Pull from env, then fall back to .env
KEY=""
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
    KEY="$IBM_ENTITLEMENT_KEY"
elif [[ -n "${WATSONX_ENTITLEMENT_KEY:-}" ]]; then
    KEY="$WATSONX_ENTITLEMENT_KEY"
elif [[ -f .env ]]; then
    set -a; source .env 2>/dev/null || true; set +a
    KEY="${IBM_ENTITLEMENT_KEY:-${WATSONX_ENTITLEMENT_KEY:-}}"
fi

if [[ -f .env ]]; then
    ok ".env: present"
else
    warn ".env: missing (interactive runs can paste a key; --yes runs require .env or env var)"
    remediate "Create .env at the repo root: echo 'IBM_ENTITLEMENT_KEY=<paste-your-key>' > .env   (key from https://myibm.ibm.com/products-services/containerlibrary)"
fi

if [[ -z "$KEY" ]]; then
    fail "key: IBM_ENTITLEMENT_KEY not found in env or .env"
    remediate "Get a key at https://myibm.ibm.com/products-services/containerlibrary and put it in .env: echo 'IBM_ENTITLEMENT_KEY=<paste-your-key>' > .env"
elif (( ${#KEY} < 50 )); then
    fail "key: present but too short (${#KEY} chars; expected ~400+ for a JWT)"
    remediate "Re-copy the entitlement key from https://myibm.ibm.com/products-services/containerlibrary (it's ~400+ characters, looks like aaa.bbb.ccc)."
elif [[ ! "$KEY" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    fail "key: present (${#KEY} chars) but not JWT-shaped (expected three base64url segments separated by dots)"
    remediate "The entitlement key must be a JWT (three dot-separated segments). Re-copy from https://myibm.ibm.com/products-services/containerlibrary — make sure you didn't copy a label or trailing whitespace."
else
    ok "key:  IBM_ENTITLEMENT_KEY present (${#KEY} chars, JWT-shaped)"

    # Live login probe — only worth doing if podman + network are healthy.
    if (( PODMAN_OK )); then
        # Logout first to avoid passing a probe via cached auth from a prior run.
        podman logout cp.icr.io &>/dev/null || true
        if echo "$KEY" | podman login -u cp --password-stdin cp.icr.io &>/dev/null; then
            ok "key:  live login to cp.icr.io succeeded"
            podman logout cp.icr.io &>/dev/null || true
        else
            fail "key:  live login to cp.icr.io failed (key is well-formed but rejected)"
            remediate "The entitlement key is JWT-shaped but cp.icr.io rejected it. Common causes: (1) key has expired — generate a new one at https://myibm.ibm.com/products-services/containerlibrary; (2) key copied from the wrong account — confirm you're logged in to the IBM ID that owns the entitlement; (3) network MITM by corp VPN — try off-VPN."
        fi
    else
        warn "key:  skipping live login probe (podman not healthy)"
    fi
fi

###############################################################################
# Sanity: tools used downstream
###############################################################################
MISSING_TOOLS=()
for tool in curl python3; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done
if (( ${#MISSING_TOOLS[@]} == 0 )); then
    ok "tools: curl, python3 present"
else
    fail "tools: missing: ${MISSING_TOOLS[*]}"
    case "$OS_TYPE" in
        darwin) remediate "Install missing tools: brew install ${MISSING_TOOLS[*]}" ;;
        *)      remediate "Install missing tools: sudo apt-get install -y ${MISSING_TOOLS[*]}" ;;
    esac
fi

# Default-Ubuntu has python3 in the base image but does not include the
# `venv` module — that's a separate package (python3-venv). The data-load
# step (setup/sample-data/load-data-with-venv.sh) creates a venv, so a
# missing venv module dies mid-install with a confusing
# "ensurepip is not available" error rather than a clean prerequisite
# failure. Probe ahead of time (cf. issue #72 field report — attendee had
# to apt-install python3-venv after a failed run).
if command -v python3 &>/dev/null; then
    if python3 -m venv --help &>/dev/null; then
        ok "tools: python3 venv module available"
    else
        fail "tools: python3 -m venv not working (the 'venv' module is not installed)"
        case "$OS_TYPE" in
            darwin) remediate "On macOS, venv ships with the Homebrew python3 — re-install: brew reinstall python3" ;;
            *)      remediate "Install the venv module: sudo apt-get install -y python3-venv   (the data-load step creates a Python venv at setup/sample-data/.venv and will fail without it)" ;;
        esac
    fi
fi

###############################################################################
# Summary
###############################################################################
echo
echo "[PREFLIGHT-RESULT] pass=$PASS warn=$WARN fail=$FAIL"

if (( FAIL > 0 )); then
    if (( ! QUIET )); then
        echo
        echo "${YELLOW}[REMEDIATION]${NC}"
        for item in "${REMEDIATION[@]}"; do
            echo "  - $item"
        done
        echo
    fi
    exit 1
fi

exit 0
