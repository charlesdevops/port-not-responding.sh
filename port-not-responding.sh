#!/usr/bin/env bash
# ============================================================
#  port-not-responding.sh  v1.0.0
#  Full diagnostics for a VM not responding on a port
#  mapped to a container (Docker or Podman).
#
#  Supported distros (auto-detection):
#    - Ubuntu / Debian
#    - RedHat / CentOS / Rocky / AlmaLinux / Fedora
#    - VMware Photon OS
#    - Generic fallback for any other Linux distro
#
#  Supported engines (auto-detection):
#    - Docker   (daemon dockerd, docker-proxy, docker0)
#    - Podman   (daemonless, rootful/rootless, netavark/CNI,
#                pasta/slirp4netns, podman0/cni0)
#
#  Usage: sudo bash port-not-responding.sh [OPTIONS] [PORT] [CONTAINER]
#       PORT       – host port to test (default: 8000)
#       CONTAINER  – container name or ID (default: auto-detect)
#
#  Options:
#    --no-color   Disable ANSI colors on stdout as well
#
#  Output:
#    - Prints a human-readable SUMMARY with ANSI colors to stdout
#    - Writes an extended log to ./port-not-responding_<timestamp>.log
#      (log is ANSI-free for grep/LLM-friendliness)
# ============================================================

set -euo pipefail

VERSION="1.0.0"

# ── Parse options and positional arguments ────────────────────
# --no-color may appear anywhere in the argument list
NO_COLOR=false
POSITIONAL=()
for arg in "$@"; do
  if [[ "$arg" == "--no-color" ]]; then
    NO_COLOR=true
  else
    POSITIONAL+=("$arg")
  fi
done

TARGET_PORT="${POSITIONAL[0]:-8000}"
TARGET_CONTAINER="${POSITIONAL[1]:-}"

# ── Input validation ──────────────────────────────────────────
if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  echo "Error: PORT must be a number between 1 and 65535 (got: '$TARGET_PORT')" >&2
  exit 1
fi
# Allow letters, digits, underscore, dot, hyphen — dot is literal inside []
if [[ -n "$TARGET_CONTAINER" ]] && ! [[ "$TARGET_CONTAINER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "Error: CONTAINER name contains invalid characters: '$TARGET_CONTAINER'" >&2
  exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="./port-not-responding_${TIMESTAMP}.log"
SUMMARY_ISSUES=()
SUMMARY_HINTS=()

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Color helpers ─────────────────────────────────────────────
# _color: wraps text in ANSI codes; respects NO_COLOR
_color() {
  local code="$1"; shift
  if [[ "$NO_COLOR" == false ]]; then
    echo -e "${code}${*}${RESET}"
  else
    echo "$*"
  fi
}

# strip_ansi: removes ANSI escape sequences from stdin
strip_ansi() {
  sed 's/\x1b\[[0-9;]*[mK]//g'
}

# log_raw: writes a plain-text line to the log file (ANSI-free)
log_raw() {
  printf '%s\n' "$*" | strip_ansi >> "$LOG_FILE"
}

# log: writes to stdout (with colors) AND to file (without colors)
log() {
  local msg="$*"
  if [[ "$NO_COLOR" == false ]]; then
    echo -e "$msg"
  else
    echo -e "$msg" | strip_ansi
  fi
  # Always write ANSI-free to the log file
  printf '%s\n' "$msg" | strip_ansi >> "$LOG_FILE"
}

hdr() {
  log ""
  log "$(_color "${CYAN}${BOLD}" "════════════════════════════════════════")"
  log "$(_color "${CYAN}${BOLD}" "  $*")"
  log "$(_color "${CYAN}${BOLD}" "════════════════════════════════════════")"
}
sec()  { log ""; log "$(_color "${BOLD}" "── $* ──")"; }
ok()   { log "$(_color "${GREEN}"  "[OK]  $*")"; }
warn() { log "$(_color "${YELLOW}" "[WARN] $*")"; SUMMARY_ISSUES+=("⚠  $*"); }
err()  { log "$(_color "${RED}"    "[ERR]  $*")"; SUMMARY_ISSUES+=("✗  $*"); }
hint() { SUMMARY_HINTS+=("→  $*"); }

# run: executes a command string, writes stdout+stderr to screen and log (ANSI-free).
# NOTE: uses bash -c to support pipes/globs in command strings; user-supplied
# values (TARGET_PORT, TARGET_CONTAINER) are validated at startup to prevent injection.
run() {
  log "$(_color "${BOLD}" "$ $*")"
  # Strip ANSI from command output before appending to log file
  bash -c "$1" 2>&1 | tee >(strip_ansi >> "$LOG_FILE") || true
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: this script requires root privileges. Re-run with sudo." >&2
    exit 1
  fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

# ──────────────────────────────────────────────────────────────
# DISTRO DETECTION
# ──────────────────────────────────────────────────────────────
detect_distro() {
  DISTRO_ID=""; DISTRO_FAMILY=""; PKG_INSTALL=""; SYSLOG_PATH=""
  PRETTY_NAME="unknown"; DISTRO_ID_LIKE=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"
    PRETTY_NAME="${PRETTY_NAME:-$DISTRO_ID}"
  fi

  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop)
      DISTRO_FAMILY="debian"; PKG_INSTALL="apt-get install -y"; SYSLOG_PATH="/var/log/syslog" ;;
    rhel|centos|rocky|almalinux|fedora|ol)
      DISTRO_FAMILY="redhat"; PKG_INSTALL="dnf install -y"; SYSLOG_PATH="/var/log/messages" ;;
    photon)
      DISTRO_FAMILY="photon"; PKG_INSTALL="tdnf install -y"; SYSLOG_PATH="/var/log/messages" ;;
    *)
      if echo "$DISTRO_ID_LIKE" | grep -qi "debian\|ubuntu"; then
        DISTRO_FAMILY="debian"; PKG_INSTALL="apt-get install -y"; SYSLOG_PATH="/var/log/syslog"
      elif echo "$DISTRO_ID_LIKE" | grep -qi "rhel\|fedora\|centos"; then
        DISTRO_FAMILY="redhat"; PKG_INSTALL="dnf install -y"; SYSLOG_PATH="/var/log/messages"
      else
        DISTRO_FAMILY="generic"; PKG_INSTALL="<package-manager> install"; SYSLOG_PATH="/var/log/syslog"
      fi ;;
  esac

  log "# Detected distro : ${PRETTY_NAME}"
  log "# Family          : $DISTRO_FAMILY"
  log "# Package manager : $PKG_INSTALL"
}

# ──────────────────────────────────────────────────────────────
# ENGINE DETECTION (Docker vs Podman)
# Priority: Docker is checked first; if both are installed,
# Docker takes precedence (it has a persistent daemon to check).
# Override by passing CONTAINER_ENGINE=podman in the environment.
# ──────────────────────────────────────────────────────────────
detect_engine() {
  ENGINE=""          # "docker" | "podman" | "none"
  ENGINE_BIN=""      # path to the binary
  ENGINE_ROOTLESS="" # "true" | "false" | ""
  ENGINE_NET_BACKEND=""  # "netavark" | "cni" | "docker-proxy" | "unknown" | ""
  ENGINE_BRIDGE=""   # bridge interface name (docker0 / podman0 / cni0)

  local preferred="${CONTAINER_ENGINE:-}"

  if [[ -n "$preferred" ]] && cmd_exists "$preferred"; then
    ENGINE="$preferred"
    ENGINE_BIN="$preferred"
  elif cmd_exists docker; then
    ENGINE="docker"
    ENGINE_BIN="docker"
  elif cmd_exists podman; then
    ENGINE="podman"
    ENGINE_BIN="podman"
  else
    ENGINE="none"
    ENGINE_BIN=""
  fi

  if [[ "$ENGINE" == "podman" ]]; then
    # Rootless: when running as non-root
    if [[ $EUID -eq 0 ]]; then
      ENGINE_ROOTLESS="false"
    else
      ENGINE_ROOTLESS="true"
    fi

    # Network backend
    ENGINE_NET_BACKEND=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "unknown")

    # Bridge interface
    if ip link show podman0 &>/dev/null; then
      ENGINE_BRIDGE="podman0"
    elif ip link show cni0 &>/dev/null; then
      ENGINE_BRIDGE="cni0"
    else
      ENGINE_BRIDGE="(not detected)"
    fi

  elif [[ "$ENGINE" == "docker" ]]; then
    ENGINE_ROOTLESS="false"
    ENGINE_NET_BACKEND="docker-proxy"
    ENGINE_BRIDGE="docker0"
  else
    # ENGINE == "none" — initialise all variables to safe defaults
    ENGINE_ROOTLESS=""
    ENGINE_NET_BACKEND=""
    ENGINE_BRIDGE=""
  fi

  log "# Detected engine : ${ENGINE}"
  log "# Binary          : ${ENGINE_BIN:-N/A}"
  log "# Rootless        : ${ENGINE_ROOTLESS:-N/A}"
  log "# Network backend : ${ENGINE_NET_BACKEND:-N/A}"
  log "# Bridge iface    : ${ENGINE_BRIDGE:-N/A}"
}

# ──────────────────────────────────────────────────────────────
# ENTRY POINT
# ──────────────────────────────────────────────────────────────
require_root

log "# port-not-responding.sh  v${VERSION}"
log "# Started          : $(date)"
log "# Target port      : $TARGET_PORT"
log "# Target container : ${TARGET_CONTAINER:-'(auto-detect)'}"
log "# Log file         : $LOG_FILE"

detect_distro
detect_engine

# ══════════════════════════════════════════════════════════════
hdr "1. SYSTEM INFORMATION"
# ══════════════════════════════════════════════════════════════

sec "OS / Kernel"
run "uname -a"
[[ -f /etc/os-release ]] && run "cat /etc/os-release"

sec "Uptime and load"
run "uptime"

sec "Resources: memory and disk"
run "free -h"
run "df -h /"

# ══════════════════════════════════════════════════════════════
hdr "2. ENGINE STATUS (${ENGINE})"
# ══════════════════════════════════════════════════════════════

sec "Engine installed?"
if [[ "$ENGINE" == "none" ]]; then
  err "Neither Docker nor Podman found in PATH"
  case "$DISTRO_FAMILY" in
    debian) hint "Install Docker: apt-get install -y docker.io"
            hint "Install Podman: apt-get install -y podman" ;;
    redhat) hint "Install Docker: dnf install -y docker-ce"
            hint "Install Podman: dnf install -y podman" ;;
    photon) hint "Install Docker: tdnf install -y docker"
            hint "Install Podman: tdnf install -y podman" ;;
    *)      hint "See https://docs.docker.com/engine/install/ or https://podman.io/docs/installation" ;;
  esac
else
  ok "Engine found: $ENGINE — $($ENGINE_BIN --version 2>/dev/null || echo 'version N/A')"
fi

# ── Daemon status (only Docker has a persistent daemon) ─────
if [[ "$ENGINE" == "docker" ]]; then
  sec "Is dockerd daemon running?"
  if systemctl is-active --quiet docker 2>/dev/null; then
    ok "dockerd is running"
  else
    err "dockerd is NOT active"
    hint "Start the daemon : systemctl start docker"
    hint "Enable at boot  : systemctl enable docker"
  fi
  run "systemctl status docker --no-pager -l" || true

elif [[ "$ENGINE" == "podman" ]]; then
  sec "Podman is daemonless — no persistent daemon"
  ok "Podman does not require an active daemon to run containers"

  # Podman socket (used by some orchestrators and by podman-compose)
  sec "Podman socket (podman.socket)"
  if systemctl is-active --quiet podman.socket 2>/dev/null; then
    ok "podman.socket is active (Docker-compatible API available)"
  else
    log "podman.socket not active (normal if not used by orchestrators)"
  fi

  # Podman system service (REST API)
  sec "Podman system service"
  if systemctl is-active --quiet podman 2>/dev/null; then
    ok "podman service active"
  else
    log "podman service not active (normal for standalone use)"
  fi
fi

sec "Engine version and info"
if [[ "$ENGINE" != "none" ]]; then
  run "$ENGINE_BIN version" || true
  run "$ENGINE_BIN info"    || true
fi

# ── Podman: rootless specifics ───────────────────────────────
if [[ "$ENGINE" == "podman" && "$ENGINE_ROOTLESS" == "true" ]]; then
  sec "Podman ROOTLESS — specific checks"
  warn "Podman is running in rootless mode — port forwarding uses pasta or slirp4netns"

  UNPRIV_PORT=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo "N/A")
  log "net.ipv4.ip_unprivileged_port_start = $UNPRIV_PORT"
  if [[ "$UNPRIV_PORT" != "N/A" && "$TARGET_PORT" -lt "$UNPRIV_PORT" ]]; then
    err "Port $TARGET_PORT < ip_unprivileged_port_start ($UNPRIV_PORT) — non-root user cannot bind"
    hint "Lower the limit: sysctl -w net.ipv4.ip_unprivileged_port_start=${TARGET_PORT}"
    hint "Or use port >= $UNPRIV_PORT and map with -p ${UNPRIV_PORT}:${TARGET_PORT}"
  else
    ok "Port $TARGET_PORT accessible in rootless mode"
  fi

  # User namespace
  sec "User namespaces (subordinate UIDs/GIDs)"
  run "cat /proc/sys/user/max_user_namespaces" || true
  MAX_NS=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "0")
  if [[ "$MAX_NS" == "0" ]]; then
    err "User namespaces disabled — Podman rootless cannot work"
    hint "Enable: sysctl -w user.max_user_namespaces=15000"
  fi
  run "cat /etc/subuid" || true
  run "cat /etc/subgid" || true
fi

# ══════════════════════════════════════════════════════════════
hdr "3. CONTAINER STATUS"
# ══════════════════════════════════════════════════════════════

sec "All containers (including stopped)"
if [[ "$ENGINE" != "none" ]]; then
  run "$ENGINE_BIN ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'" || true
fi

sec "Auto-detect container on port $TARGET_PORT"
if [[ "$ENGINE" != "none" && -z "$TARGET_CONTAINER" ]]; then
  TARGET_CONTAINER=$($ENGINE_BIN ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
    | grep ":${TARGET_PORT}->" | awk '{print $1}' | head -1 || true)
  if [[ -n "$TARGET_CONTAINER" ]]; then
    ok "Container auto-detected: $TARGET_CONTAINER"
  else
    warn "No running container found with port $TARGET_PORT mapped"
    hint "Make sure the container is started with -p ${TARGET_PORT}:<internal_port>"
  fi
fi

if [[ -n "$TARGET_CONTAINER" && "$ENGINE" != "none" ]]; then
  sec "Container details: $TARGET_CONTAINER"
  CONTAINER_STATUS=$($ENGINE_BIN inspect "$TARGET_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo "N/A")
  CONTAINER_RUNNING=$($ENGINE_BIN inspect "$TARGET_CONTAINER" --format '{{.State.Running}}' 2>/dev/null || echo "false")
  # RestartCount may be absent in some Podman versions; default to 0
  RESTART_COUNT=$($ENGINE_BIN inspect "$TARGET_CONTAINER" --format '{{.RestartCount}}' 2>/dev/null || echo "0")
  RESTART_COUNT="${RESTART_COUNT:-0}"

  log "Status: $CONTAINER_STATUS | Running: $CONTAINER_RUNNING | Restarts: $RESTART_COUNT"

  if [[ "$CONTAINER_RUNNING" != "true" ]]; then
    err "Container '$TARGET_CONTAINER' is NOT running (status: $CONTAINER_STATUS)"
    hint "Start the container: $ENGINE_BIN start $TARGET_CONTAINER"
  else
    ok "Container '$TARGET_CONTAINER' is running"
  fi

  if [[ "$RESTART_COUNT" =~ ^[0-9]+$ && "$RESTART_COUNT" -gt 3 ]]; then
    warn "Container restarted $RESTART_COUNT times — possible crash loop"
    hint "Inspect logs: $ENGINE_BIN logs --tail 100 $TARGET_CONTAINER"
  fi

  sec "Full inspect: $TARGET_CONTAINER"
  run "$ENGINE_BIN inspect $TARGET_CONTAINER" || true

  sec "Container logs (last 80 lines)"
  run "$ENGINE_BIN logs --tail 80 --timestamps $TARGET_CONTAINER" || true

  sec "Processes inside the container"
  run "$ENGINE_BIN top $TARGET_CONTAINER" || true

  sec "Container resource stats"
  run "$ENGINE_BIN stats $TARGET_CONTAINER --no-stream" || true

  sec "Declared port mappings"
  PORTS=$($ENGINE_BIN inspect "$TARGET_CONTAINER" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null || echo "{}")
  log "Ports JSON: $PORTS"
  # Docker uses "HostPort"; Podman uses "host_port" — check both
  if echo "$PORTS" | grep -qiE '"HostPort"|"host_port"'; then
    ok "Port mapping present"
  else
    err "No port mapping in container — host port is not exposed"
    hint "Recreate the container with: $ENGINE_BIN run -p ${TARGET_PORT}:<internal_port> ..."
  fi

  sec "Networks the container belongs to"
  run "$ENGINE_BIN inspect $TARGET_CONTAINER --format '{{json .NetworkSettings.Networks}}'" || true

  # Podman: network inspect for extra details
  if [[ "$ENGINE" == "podman" ]]; then
    sec "Podman network list"
    run "podman network ls" || true
    CONTAINER_NET=$(podman inspect "$TARGET_CONTAINER" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)
    if [[ -n "$CONTAINER_NET" ]]; then
      for NET in $CONTAINER_NET; do
        log "Network inspect: $NET"
        run "podman network inspect $NET" || true
      done
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════
hdr "4. HOST NETWORKING – PORTS AND SOCKETS"
# ══════════════════════════════════════════════════════════════

sec "Process listening on port $TARGET_PORT (ss)"
LISTEN_OUT=$(ss -tlnp "sport = :${TARGET_PORT}" 2>/dev/null || true)
log "$LISTEN_OUT"
if echo "$LISTEN_OUT" | grep -q ":${TARGET_PORT}"; then
  ok "Something is listening on :${TARGET_PORT}"
else
  err "No process listening on port $TARGET_PORT on the host"
  if [[ "$ENGINE" == "docker" ]]; then
    hint "docker-proxy did not start — restart the container with correct port binding"
  else
    hint "Podman: verify that pasta/slirp4netns is active for the container"
    hint "Podman rootful uses iptables/nftables directly — check NAT rules"
  fi
fi

sec "All TCP sockets in LISTEN state"
run "ss -tlnp"

sec "Listening process (netstat fallback)"
if cmd_exists netstat; then
  run "netstat -tlnp | grep :${TARGET_PORT}" || warn "netstat: no result for port $TARGET_PORT"
fi

sec "Network interfaces"
run "ip addr show"
run "ip route show"

# ── Port forwarding agent (engine-specific) ──────────────────
if [[ "$ENGINE" == "docker" ]]; then
  sec "docker-proxy bind address"
  PROXY_BIND=$(ss -tlnp | grep ":${TARGET_PORT}" | awk '{print $4}' || true)
  if [[ -n "$PROXY_BIND" ]]; then
    log "docker-proxy listening on: $PROXY_BIND"
    if echo "$PROXY_BIND" | grep -qE "^127\.|^::1"; then
      warn "docker-proxy is bound to localhost only — not reachable from outside"
      hint "Use -p 0.0.0.0:${TARGET_PORT}:<port> to expose on all interfaces"
    fi
  fi

elif [[ "$ENGINE" == "podman" ]]; then
  sec "Podman port forwarding agent (pasta / slirp4netns)"

  # pasta (default from Podman 4.4+ rootless)
  PASTA_PID=$(pgrep -a pasta 2>/dev/null | grep "${TARGET_PORT}" || true)
  if [[ -n "$PASTA_PID" ]]; then
    ok "pasta active for port $TARGET_PORT"
    log "$PASTA_PID"
  else
    log "pasta not detected for port $TARGET_PORT"
  fi

  # slirp4netns (predecessor to pasta, still used in some setups)
  SLIRP_PID=$(pgrep -a slirp4netns 2>/dev/null || true)
  if [[ -n "$SLIRP_PID" ]]; then
    ok "slirp4netns is running"
    log "$SLIRP_PID"
  else
    log "slirp4netns is not running"
  fi

  # rootful Podman uses iptables/nftables directly (no userspace proxy)
  if [[ "$ENGINE_ROOTLESS" == "false" ]]; then
    log "Podman rootful: forwarding is handled directly by iptables/nftables (no userspace proxy)"
    PODMAN_NAT=$(iptables -t nat -L -n 2>/dev/null | grep ":${TARGET_PORT}" || true)
    if [[ -n "$PODMAN_NAT" ]]; then
      ok "iptables NAT rule found for port $TARGET_PORT"
      log "$PODMAN_NAT"
    else
      # try nftables
      if cmd_exists nft; then
        PODMAN_NFT=$(nft list ruleset 2>/dev/null | grep "${TARGET_PORT}" || true)
        if [[ -n "$PODMAN_NFT" ]]; then
          ok "nftables rule found for port $TARGET_PORT"
          log "$PODMAN_NFT"
        else
          err "No NAT rule (iptables/nftables) for port $TARGET_PORT — port mapping not active"
          hint "Recreate the container with: podman run -p ${TARGET_PORT}:<internal_port> ..."
        fi
      else
        warn "nft not available — cannot verify nftables rules for port $TARGET_PORT"
        hint "Install nftables: ${PKG_INSTALL} nftables"
        err "No iptables NAT rule found and nftables unavailable — port mapping may not be active"
        hint "Recreate the container with: podman run -p ${TARGET_PORT}:<internal_port> ..."
      fi
    fi
  fi

  # Bind address check (rootless: default 0.0.0.0)
  PROXY_BIND=$(ss -tlnp | grep ":${TARGET_PORT}" | awk '{print $4}' || true)
  if [[ -n "$PROXY_BIND" ]]; then
    log "Port $TARGET_PORT bound to: $PROXY_BIND"
    if echo "$PROXY_BIND" | grep -qE "^127\.|^::1"; then
      warn "Port bound to localhost only — not reachable from outside"
      hint "Use -p 0.0.0.0:${TARGET_PORT}:<port> to expose on all interfaces"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════
hdr "5. FIREWALL (distro-adaptive: $DISTRO_FAMILY)"
# ══════════════════════════════════════════════════════════════

# ── 5a. ufw (Debian/Ubuntu) ──────────────────────────────────
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  sec "ufw status"
  if cmd_exists ufw; then
    UFW_STATUS=$(ufw status 2>/dev/null || true)
    log "$UFW_STATUS"
    if echo "$UFW_STATUS" | grep -qi "^Status: active"; then
      warn "ufw is ACTIVE — may be blocking port $TARGET_PORT"
      if ! echo "$UFW_STATUS" | grep -q "$TARGET_PORT"; then
        err "ufw rule for port $TARGET_PORT NOT found"
        hint "Add rule: ufw allow ${TARGET_PORT}/tcp"
      else
        ok "ufw has a rule for port $TARGET_PORT"
      fi
    else
      ok "ufw is inactive"
    fi
  else
    log "ufw not present on this system"
  fi
fi

# ── 5b. firewalld (RedHat / Photon) ─────────────────────────
if [[ "$DISTRO_FAMILY" == "redhat" || "$DISTRO_FAMILY" == "photon" ]]; then
  sec "firewalld status"
  if cmd_exists firewall-cmd; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      warn "firewalld is ACTIVE — may be blocking port $TARGET_PORT"
      run "firewall-cmd --list-all"
      FWD_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
      log "Open ports: $FWD_PORTS"
      if echo "$FWD_PORTS" | grep -q "${TARGET_PORT}/tcp"; then
        ok "Port ${TARGET_PORT}/tcp is open in firewalld"
      else
        err "Port ${TARGET_PORT}/tcp is NOT open in firewalld"
        hint "Open the port: firewall-cmd --permanent --add-port=${TARGET_PORT}/tcp && firewall-cmd --reload"
      fi
    else
      ok "firewalld is inactive"
    fi
  else
    log "firewall-cmd not found (firewalld not installed)"
  fi

  if [[ "$DISTRO_FAMILY" == "redhat" ]]; then
    sec "SELinux status"
    if cmd_exists getenforce; then
      SELINUX_STATUS=$(getenforce 2>/dev/null || echo "N/A")
      log "SELinux: $SELINUX_STATUS"
      if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
        warn "SELinux is in Enforcing mode — may block ${ENGINE} or network connections"
        hint "Check audit log: ausearch -m avc -ts recent | grep -E 'docker|podman|container'"
        hint "Allow container connections: setsebool -P container_manage_cgroup 1"
        run "sestatus" || true
      fi
    fi
    if cmd_exists semanage; then
      sec "Registered SELinux ports"
      run "semanage port -l | grep -E 'http_port|container'" || true
    fi
  fi
fi

# ── 5c. iptables / nftables (all distros) ───────────────────
sec "iptables – container and FORWARD chains"

# Docker uses DOCKER / DOCKER-USER chains; rootful Podman creates similar chains
if [[ "$ENGINE" == "docker" ]]; then
  run "iptables -L DOCKER -n -v"       || true
  run "iptables -L DOCKER-USER -n -v"  || true
elif [[ "$ENGINE" == "podman" ]]; then
  # Podman creates chains with different names depending on the backend
  run "iptables -L PODMAN -n -v"       || true
  run "iptables -L PODMAN-FORWARD -n -v" || true
fi
run "iptables -L FORWARD -n -v"        || true
run "iptables -t nat -L -n -v"         || true

sec "iptables rules for port $TARGET_PORT"
IPRULE=$(iptables -L -n -v 2>/dev/null | grep ":${TARGET_PORT}" || true)
if [[ -n "$IPRULE" ]]; then
  log "$IPRULE"
  if echo "$IPRULE" | grep -qi "DROP\|REJECT"; then
    err "DROP/REJECT rule found for port $TARGET_PORT in iptables"
    hint "Remove the blocking rule or add an ACCEPT rule with higher priority"
  fi
else
  log "(no specific rule for :${TARGET_PORT} in iptables)"
fi

sec "ip6tables (IPv6)"
run "ip6tables -L -n -v" || true

sec "nftables"
if cmd_exists nft; then
  run "nft list ruleset" || true
fi

# ══════════════════════════════════════════════════════════════
hdr "6. ENGINE DAEMON / RUNTIME CONFIGURATION"
# ══════════════════════════════════════════════════════════════

if [[ "$ENGINE" == "docker" ]]; then
  sec "/etc/docker/daemon.json"
  if [[ -f /etc/docker/daemon.json ]]; then
    run "cat /etc/docker/daemon.json"
    if grep -q '"iptables": false' /etc/docker/daemon.json 2>/dev/null; then
      err "iptables=false in Docker daemon — Docker does not manage NAT rules"
      hint "Remove '\"iptables\": false' from daemon.json and restart Docker"
    fi
    if grep -q '"ip-forward"' /etc/docker/daemon.json 2>/dev/null; then
      log "Note: ip-forward explicitly configured in daemon"
    fi
  else
    log "daemon.json not present (using defaults)"
  fi

elif [[ "$ENGINE" == "podman" ]]; then
  sec "Podman: runtime configuration files"

  for CONF in /etc/containers/containers.conf \
              /etc/containers/storage.conf \
              /etc/containers/registries.conf \
              "${HOME}/.config/containers/containers.conf" \
              "${HOME}/.config/containers/storage.conf"; do
    if [[ -f "$CONF" ]]; then
      log "── $CONF ──"
      run "cat $CONF" || true
    else
      log "$CONF — not present"
    fi
  done

  sec "Podman: network backend (netavark vs CNI)"
  log "Detected network backend: $ENGINE_NET_BACKEND"
  if [[ "$ENGINE_NET_BACKEND" == "netavark" ]]; then
    ok "Netavark (modern backend, Podman >= 4.0)"
    run "podman network ls" || true
    # netavark config dir
    for NETDIR in /etc/containers/networks /run/containers/networks; do
      if [[ -d "$NETDIR" ]]; then run "ls -la $NETDIR"; fi
    done
  elif [[ "$ENGINE_NET_BACKEND" == "cni" ]]; then
    ok "CNI (legacy backend)"
    run "podman network ls" || true
    for CNIDIR in /etc/cni/net.d /opt/cni/bin; do
      if [[ -d "$CNIDIR" ]]; then run "ls -la $CNIDIR"; fi
    done
    if [[ -d /etc/cni/net.d ]]; then
      run "cat /etc/cni/net.d/*.conflist 2>/dev/null" || true
    fi
  else
    warn "Unknown network backend: $ENGINE_NET_BACKEND"
  fi

  sec "Podman: aardvark-dns (internal container DNS)"
  if cmd_exists aardvark-dns; then
    ok "aardvark-dns found: $(aardvark-dns --version 2>/dev/null || true)"
  else
    log "aardvark-dns not found (used only with Netavark)"
  fi
fi

sec "Kernel IP forwarding"
IPF=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "N/A")
log "net.ipv4.ip_forward = $IPF"
if [[ "$IPF" != "1" ]]; then
  err "IP forwarding disabled — container traffic will not be forwarded"
  hint "Enable now: sysctl -w net.ipv4.ip_forward=1"
  case "$DISTRO_FAMILY" in
    photon) hint "Make permanent in /etc/sysctl.d/99-container.conf" ;;
    *)      hint "Make permanent in /etc/sysctl.conf: net.ipv4.ip_forward=1" ;;
  esac
else
  ok "IP forwarding enabled"
fi

sec "bridge-nf-call-iptables"
BNF=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo "N/A")
log "net.bridge.bridge-nf-call-iptables = $BNF"
if [[ "$BNF" == "0" ]]; then
  warn "bridge-nf-call-iptables=0 — iptables is not called for bridge traffic"
  hint "Set: sysctl -w net.bridge.bridge-nf-call-iptables=1"
fi

sec "Container bridge interface (${ENGINE_BRIDGE:-N/A})"
if [[ -n "$ENGINE_BRIDGE" && "$ENGINE_BRIDGE" != "(not detected)" ]]; then
  run "ip link show ${ENGINE_BRIDGE}" || warn "Interface ${ENGINE_BRIDGE} not found"
else
  warn "Container bridge interface not detected"
  hint "Check with: ip link show type bridge"
fi
if cmd_exists brctl; then
  run "brctl show"
else
  run "ip link show type bridge" || true
fi

# ══════════════════════════════════════════════════════════════
hdr "7. LOCAL CONNECTIVITY TEST"
# ══════════════════════════════════════════════════════════════

sec "curl localhost:$TARGET_PORT"
if cmd_exists curl; then
  CURL_OUT=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "http://localhost:${TARGET_PORT}" 2>&1 || echo "FAILED")
  log "HTTP status code: $CURL_OUT"
  if [[ "$CURL_OUT" == "FAILED" || "$CURL_OUT" == "000" ]]; then
    err "curl cannot connect to localhost:${TARGET_PORT}"
  else
    ok "curl responded with HTTP $CURL_OUT"
  fi
fi

sec "nc / ncat port test $TARGET_PORT"
if cmd_exists nc; then
  NC_OUT=$(nc -zv -w 3 127.0.0.1 "$TARGET_PORT" 2>&1 || true)
  log "$NC_OUT"
  if echo "$NC_OUT" | grep -qi "succeeded\|open\|Connected"; then
    ok "Port $TARGET_PORT reachable via nc on localhost"
  else
    err "Port $TARGET_PORT not reachable via nc on localhost"
  fi
fi

# ══════════════════════════════════════════════════════════════
hdr "8. TCP HANDSHAKE ANALYSIS – SYN / SYN-ACK"
# ══════════════════════════════════════════════════════════════

sec "conntrack table: size and usage"
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
log "nf_conntrack_max   = $CT_MAX"
log "nf_conntrack_count = $CT_COUNT"

if [[ "$CT_MAX" != "N/A" && "$CT_COUNT" != "N/A" && "$CT_MAX" -gt 0 ]]; then
  CT_PCT=$(( CT_COUNT * 100 / CT_MAX ))
  log "conntrack usage    : ${CT_PCT}%"
  if [[ $CT_PCT -ge 90 ]]; then
    err "conntrack table nearly full (${CT_PCT}%) — new SYN packets are silently dropped"
    hint "Increase: sysctl -w net.netfilter.nf_conntrack_max=$((CT_MAX * 2))"
    hint "Reduce timeout: sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600"
  elif [[ $CT_PCT -ge 70 ]]; then
    warn "conntrack table at ${CT_PCT}% — monitor closely"
  else
    ok "conntrack table OK (${CT_PCT}%)"
  fi
fi

sec "conntrack: SYN_RECV / SYN_SENT states"
if cmd_exists conntrack; then
  run "conntrack -L -p tcp --dport ${TARGET_PORT} 2>/dev/null | head -30" || true
  SYN_RECV=$(conntrack -L 2>/dev/null | grep -c "SYN_RECV" || true)
  SYN_SENT=$(conntrack -L 2>/dev/null | grep -c "SYN_SENT" || true)
  SYN_RECV="${SYN_RECV:-0}"
  SYN_SENT="${SYN_SENT:-0}"
  log "Connections in SYN_RECV : $SYN_RECV"
  log "Connections in SYN_SENT : $SYN_SENT"
  if [[ "$SYN_RECV" =~ ^[0-9]+$ && "$SYN_RECV" -gt 100 ]]; then
    warn "High SYN_RECV count ($SYN_RECV) — possible SYN flood or saturated backlog"
  fi
else
  log "conntrack CLI not available — install with: ${PKG_INSTALL} conntrack"
  if [[ -f /proc/net/nf_conntrack ]]; then head -40 /proc/net/nf_conntrack | tee -a "$LOG_FILE" || true; fi
fi

sec "TCP parameters: backlog, syncookies, synack_retries"
TCP_SYN_BACKLOG=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || echo "N/A")
SOMAXCONN=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "N/A")
TCP_SYNCOOKIES=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || echo "N/A")
TCP_SYNACK_RETRIES=$(cat /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null || echo "N/A")
TCP_ABORT_ON_OVERFLOW=$(cat /proc/sys/net/ipv4/tcp_abort_on_overflow 2>/dev/null || echo "N/A")

log "tcp_max_syn_backlog   = $TCP_SYN_BACKLOG"
log "net.core.somaxconn    = $SOMAXCONN"
log "tcp_syncookies        = $TCP_SYNCOOKIES"
log "tcp_synack_retries    = $TCP_SYNACK_RETRIES"
log "tcp_abort_on_overflow = $TCP_ABORT_ON_OVERFLOW"

if [[ "$TCP_SYNCOOKIES" == "0" ]]; then
  warn "tcp_syncookies=0 — excess SYN packets are silently dropped under SYN flood"
  hint "Enable: sysctl -w net.ipv4.tcp_syncookies=1"
else
  ok "tcp_syncookies enabled ($TCP_SYNCOOKIES)"
fi
if [[ "$TCP_SYN_BACKLOG" != "N/A" && "$TCP_SYN_BACKLOG" -lt 256 ]]; then
  warn "tcp_max_syn_backlog=$TCP_SYN_BACKLOG is low"
  hint "Increase: sysctl -w net.ipv4.tcp_max_syn_backlog=1024"
fi
if [[ "$SOMAXCONN" != "N/A" && "$SOMAXCONN" -lt 128 ]]; then
  warn "somaxconn=$SOMAXCONN — accept() queue is very small"
  hint "Increase: sysctl -w net.core.somaxconn=1024"
fi

sec "Listen queue on port $TARGET_PORT (ss -lnt)"
SS_LISTEN=$(ss -lnt "sport = :${TARGET_PORT}" 2>/dev/null || true)
log "$SS_LISTEN"
RECV_Q=$(echo "$SS_LISTEN" | awk 'NR>1 {print $2}' | head -1 || true)
SEND_Q=$(echo "$SS_LISTEN" | awk 'NR>1 {print $3}' | head -1 || true)
log "  Recv-Q (pending accept): ${RECV_Q:-N/A}  |  Send-Q (max backlog): ${SEND_Q:-N/A}"
if [[ -n "$RECV_Q" && "$RECV_Q" =~ ^[0-9]+$ && "$RECV_Q" -gt 0 ]]; then
  warn "Recv-Q=$RECV_Q — completed connections not yet accepted by the app"
  hint "The application inside the container is slow to accept connections"
fi

sec "Reverse Path Filtering (rp_filter)"
while IFS= read -r IFACE; do
  RPF=$(cat "/proc/sys/net/ipv4/conf/${IFACE}/rp_filter" 2>/dev/null || echo "N/A")
  log "  rp_filter[$IFACE] = $RPF"
  if [[ "$RPF" == "1" ]]; then
    warn "rp_filter=1 (strict) on ${IFACE} — asymmetric routing causes silent SYN drops"
    hint "If asymmetric routing: sysctl -w net.ipv4.conf.${IFACE}.rp_filter=2"
  fi
done < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)

sec "Full routing table"
run "ip route show table all" || true

sec "Kernel TCP statistics (overflow, drop, retransmit)"
if cmd_exists netstat; then
  netstat -s 2>/dev/null \
    | grep -iE "syn|overflow|drop|reset|failed|retransmit|listen|backlog" \
    | tee -a "$LOG_FILE" || true
fi
run "ss -s" || true
if cmd_exists nstat; then
  run "nstat -az | grep -iE 'Syn|Listen|Drop|Overflow|Retrans'" || true
else
  if [[ -f /proc/net/snmp    ]]; then grep -E "^Tcp:"    /proc/net/snmp    | tee -a "$LOG_FILE" || true; fi
  if [[ -f /proc/net/netstat ]]; then grep -E "^TcpExt:" /proc/net/netstat | tee -a "$LOG_FILE" || true; fi
fi

sec "Live SYN/SYN-ACK capture on port $TARGET_PORT (5 seconds)"
if cmd_exists tcpdump; then
  log "Starting tcpdump for 5s — port $TARGET_PORT ..."
  TCPDUMP_OUT=$(timeout 5 tcpdump -nn -i any \
    "tcp port ${TARGET_PORT} and (tcp[tcpflags] & (tcp-syn|tcp-ack) != 0)" \
    2>&1 || true)
  echo "$TCPDUMP_OUT" | tee -a "$LOG_FILE"

  SYN_COUNT=$(echo "$TCPDUMP_OUT"    | grep -c "Flags \[S\]"   || true)
  SYNACK_COUNT=$(echo "$TCPDUMP_OUT" | grep -c "Flags \[S\.\]" || true)
  RST_COUNT=$(echo "$TCPDUMP_OUT"    | grep -c "Flags \[R"     || true)
  SYN_COUNT="${SYN_COUNT:-0}"
  SYNACK_COUNT="${SYNACK_COUNT:-0}"
  RST_COUNT="${RST_COUNT:-0}"
  log "  SYN: $SYN_COUNT  |  SYN-ACK: $SYNACK_COUNT  |  RST: $RST_COUNT"

  if [[ "$SYN_COUNT" -gt 0 && "$SYNACK_COUNT" -eq 0 ]]; then
    err "SYN received ($SYN_COUNT) but NO SYN-ACK sent — kernel is dropping packets"
    hint "Likely causes: full conntrack, strict rp_filter, saturated backlog, iptables DROP"
  elif [[ "$SYN_COUNT" -gt 0 && "$SYNACK_COUNT" -gt 0 ]]; then
    ok "SYN-ACK sent correctly ($SYNACK_COUNT out of $SYN_COUNT SYN)"
    [[ "$RST_COUNT" -gt 0 ]] && warn "RST packets present ($RST_COUNT) — server is rejecting some connections"
  elif [[ "$SYN_COUNT" -eq 0 ]]; then
    warn "No SYN captured in 5s — traffic is not reaching the VM"
    hint "Check cloud firewall / Security Group / upstream routing"
  fi
else
  warn "tcpdump not available — live capture skipped"
  hint "Install: ${PKG_INSTALL} tcpdump"
fi

# ══════════════════════════════════════════════════════════════
hdr "9. JOURNAL AND SYSTEM LOGS"
# ══════════════════════════════════════════════════════════════

sec "Recent engine logs (journalctl)"
if [[ "$ENGINE" == "docker" ]]; then
  run "journalctl -u docker --since '1 hour ago' --no-pager -l" || true
elif [[ "$ENGINE" == "podman" ]]; then
  run "journalctl -u podman --since '1 hour ago' --no-pager -l" || true
  run "journalctl -u podman.socket --since '1 hour ago' --no-pager -l" || true
fi

sec "Recent kernel log (dmesg)"
if dmesg --time-format reltime &>/dev/null; then
  run "dmesg --level=err,warn --time-format reltime | tail -40" || true
else
  run "dmesg | tail -40" || true
fi

sec "System log (${SYSLOG_PATH})"
if [[ -f "$SYSLOG_PATH" ]]; then
  grep -i "docker\|podman\|container\|iptables\|forward" "$SYSLOG_PATH" 2>/dev/null \
    | tail -50 | tee -a "$LOG_FILE" || true
else
  log "$SYSLOG_PATH not found on this machine"
fi

if [[ "$DISTRO_FAMILY" == "redhat" ]] && [[ -f /var/log/audit/audit.log ]]; then
  sec "SELinux audit log (container denials)"
  grep -i "avc.*\(docker\|podman\|container\)\|denied.*\(docker\|podman\|container\)" \
    /var/log/audit/audit.log 2>/dev/null | tail -30 | tee -a "$LOG_FILE" || true
fi

# ══════════════════════════════════════════════════════════════
hdr "10. CLOUD / VM SPECIFICS"
# ══════════════════════════════════════════════════════════════

sec "Security Group / Cloud provider hints"
log "WARNING: if this VM is on a cloud provider (AWS, GCP, Azure, Hetzner, OVH…)"
log "the following checks must be performed OUTSIDE the VM:"
log "  • Security Group / Firewall rules: allow TCP ingress on port $TARGET_PORT"
log "  • Network ACL (AWS VPC) must not block traffic"
log "  • Load Balancer health check properly configured"
log "  • Public IP / Floating IP assigned to the instance"

sec "Cloud metadata (best-effort)"
if cmd_exists curl; then
  AWS_ID=$(curl -s --connect-timeout 2 \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
  [[ -n "$AWS_ID" ]] && log "AWS Instance ID: $AWS_ID"
  GCP_ID=$(curl -s --connect-timeout 2 -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/id 2>/dev/null || true)
  [[ -n "$GCP_ID" ]] && log "GCP Instance ID: $GCP_ID"
  AZURE_ID=$(curl -s --connect-timeout 2 -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text" \
    2>/dev/null || true)
  [[ -n "$AZURE_ID" ]] && log "Azure VM ID: $AZURE_ID"
fi

# ══════════════════════════════════════════════════════════════
hdr "11. SUMMARY – POSSIBLE CAUSES AND SOLUTIONS"
# ══════════════════════════════════════════════════════════════

log ""
log "$(_color "${BOLD}${CYAN}" "╔══════════════════════════════════════════════════════════╗")"
log "$(_color "${BOLD}${CYAN}" "║           DETECTED ISSUES SUMMARY                       ║")"
log "$(_color "${BOLD}${CYAN}" "╚══════════════════════════════════════════════════════════╝")"
log "  Engine : ${ENGINE}  |  Rootless: ${ENGINE_ROOTLESS:-N/A}  |  Net backend: ${ENGINE_NET_BACKEND:-N/A}"
log "  Distro : ${PRETTY_NAME} (${DISTRO_FAMILY})"

if [[ ${#SUMMARY_ISSUES[@]} -eq 0 ]]; then
  log ""
  log "$(_color "${GREEN}" "No critical issues detected automatically.")"
  log "Check the extended log for deeper analysis: $LOG_FILE"
else
  log ""
  log "$(_color "${RED}${BOLD}" "ISSUES FOUND:")"
  for issue in "${SUMMARY_ISSUES[@]}"; do
    log "$(_color "${RED}" "  $issue")"
  done
fi

# Write checklist to both stdout and log file via log()
log ""
log "$(_color "${YELLOW}${BOLD}" "COMMON CAUSES CHECKLIST:")"
log "  ── GENERIC ───────────────────────────────────────────────────"
log "  1.  Container not started or in crash loop"
log "  2.  Missing or incorrect port binding (-p host:container)"
log "  3.  Process inside container listening on 127.0.0.1 only"
log "  4.  IP forwarding disabled (net.ipv4.ip_forward=0)"
log "  5.  ufw active without a rule for the port    [Debian/Ubuntu]"
log "  6.  firewalld active without a rule for port  [RedHat/Photon]"
log "  7.  SELinux in Enforcing mode blocking traffic [RedHat]"
log "  8.  iptables DROP/REJECT rule overrides container rules"
log "  9.  Cloud Security Group not opening the port externally"
log "  10. Port conflict: another process is using the same port"
log "  11. Resources exhausted (OOM killer terminated the container)"
log "  ── DOCKER SPECIFIC ───────────────────────────────────────────"
log "  12. docker-proxy listening on 127.0.0.1 instead of 0.0.0.0"
log "  13. iptables=false in daemon.json → Docker does not create NAT rules"
log "  14. docker0 bridge missing or in DOWN state"
log "  ── PODMAN SPECIFIC ───────────────────────────────────────────"
log "  15. Port < ip_unprivileged_port_start in rootless mode"
log "  16. User namespaces disabled (max_user_namespaces=0)"
log "  17. pasta / slirp4netns not running (rootless)"
log "  18. No iptables/nftables NAT rule (rootful)"
log "  19. Corrupted or misconfigured CNI/Netavark network"
log "  20. podman0 / cni0 bridge missing or in DOWN state"
log "  ── TCP HANDSHAKE (SYN arrives but no SYN-ACK sent) ──────────"
log "  21. conntrack table full (nf_conntrack_max reached)"
log "  22. tcp_syncookies=0 under SYN flood"
log "  23. tcp_max_syn_backlog or somaxconn too low"
log "  24. rp_filter=1 strict on interface with asymmetric routing"
log "  25. Recv-Q > 0 — application slow to accept connections"

if [[ ${#SUMMARY_HINTS[@]} -gt 0 ]]; then
  log ""
  log "$(_color "${GREEN}${BOLD}" "SUGGESTED ACTIONS:")"
  for h in "${SUMMARY_HINTS[@]}"; do
    log "$(_color "${GREEN}" "  $h")"
  done
fi

log ""
log "$(_color "${BOLD}" "Full log saved to:") $LOG_FILE"
log "$(_color "${BOLD}" "Analysed port:    ") ${TARGET_PORT}"
log "$(_color "${BOLD}" "Container:        ") ${TARGET_CONTAINER:-'(none detected)'}"
log "$(_color "${BOLD}" "Engine:           ") ${ENGINE} (rootless: ${ENGINE_ROOTLESS:-N/A}, backend: ${ENGINE_NET_BACKEND:-N/A})"
log "$(_color "${BOLD}" "Distro:           ") ${PRETTY_NAME} (${DISTRO_FAMILY})"
log "$(_color "${BOLD}" "Timestamp:        ") $(date)"
log ""

hdr "END OF DIAGNOSTICS"
log "End timestamp: $(date)"
log "Total issues detected: ${#SUMMARY_ISSUES[@]}"

exit 0
