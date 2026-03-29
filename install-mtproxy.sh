#!/usr/bin/env bash
set -euo pipefail

# Telegram MTProto Proxy installer for Ubuntu 22.04/24.04.
# - Asks exactly two interactive questions: proxy port and max connections.
# - Builds official MTProxy from source.
# - Configures and starts a systemd service.

SERVICE_NAME="mtproto-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/mtproxy"
ETC_DIR="/etc/mtproxy"
BIN_PATH="${INSTALL_DIR}/mtproto-proxy"
UPDATE_SCRIPT="/usr/local/bin/mtproxy-fetch-config.sh"
RUN_USER="mtproxy"

REPO_URL="https://github.com/TelegramMessenger/MTProxy.git"
PROXY_SECRET_URL="https://core.telegram.org/getProxySecret"
PROXY_CONFIG_URL="https://core.telegram.org/getProxyConfig"

BUILD_DIR=""
PORT=""
MAX_CONNECTIONS=""
STATS_PORT=""
SECRET=""
PUBLIC_IP=""
SNI_DOMAIN=""
CLIENT_SECRET=""
TRANSPORT_MODE="classic"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
    rm -rf "${BUILD_DIR}"
  fi
}

error_handler() {
  local exit_code="$1"
  local line_no="$2"
  local failed_cmd="$3"
  set +e
  printf '\n[ERROR] Script failed with code %s at line %s.\n' "$exit_code" "$line_no" >&2
  printf '[ERROR] Failed command: %s\n' "$failed_cmd" >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash install-mtproxy.sh"
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "Only Ubuntu is supported."
  case "${VERSION_ID:-}" in
    "22.04"|"24.04") ;;
    *) die "Supported Ubuntu versions: 22.04 and 24.04. Found: ${VERSION_ID:-unknown}" ;;
  esac
}

ensure_interactive_tty() {
  [[ -r /dev/tty ]] || die "Interactive terminal (/dev/tty) is required."
}

ensure_base_commands() {
  for cmd in apt-get systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
  done
}

ensure_ss_available() {
  if command -v ss >/dev/null 2>&1; then
    return 0
  fi

  log "Installing iproute2 (ss is required for port checks)..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get install -y --no-install-recommends iproute2
  command -v ss >/dev/null 2>&1 || die "Failed to install ss (iproute2)."
}

is_port_free() {
  local port="$1"

  # Check both TCP and UDP listening sockets.
  if ss -H -ltn "( sport = :${port} )" | grep -q .; then
    return 1
  fi
  if ss -H -lun "( sport = :${port} )" | grep -q .; then
    return 1
  fi

  return 0
}

is_valid_domain() {
  local domain="$1"

  # Basic domain validation for SNI hostname.
  (( ${#domain} >= 1 && ${#domain} <= 253 )) || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  local labels=()
  local label=""
  IFS='.' read -r -a labels <<< "$domain"
  (( ${#labels[@]} >= 2 )) || return 1

  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done

  return 0
}

ask_port() {
  local raw=""
  local candidate=""

  while true; do
    read -r -p "Enter MTProto proxy port (1-65535): " raw < /dev/tty

    if [[ "$raw" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      candidate="${BASH_REMATCH[1]}"

      if (( candidate < 1 || candidate > 65535 )); then
        warn "Port must be in range 1-65535."
        continue
      fi

      if ! is_port_free "$candidate"; then
        warn "Port ${candidate} is busy. Choose another one."
        continue
      fi

      PORT="$candidate"
      break
    else
      warn "Invalid input. Enter an integer from 1 to 65535."
    fi
  done
}

ask_sni_domain() {
  local raw=""
  local candidate=""

  while true; do
    read -r -p "Enter SNI domain for TLS camouflage (empty = disable): " raw < /dev/tty

    # Empty value keeps classic MTProto transport.
    if [[ -z "${raw//[[:space:]]/}" ]]; then
      SNI_DOMAIN=""
      break
    fi

    candidate="${raw//[[:space:]]/}"
    candidate="${candidate,,}"

    if ! is_valid_domain "$candidate"; then
      warn "Invalid domain format. Example: www.cloudflare.com"
      continue
    fi

    SNI_DOMAIN="$candidate"
    break
  done
}

ask_max_connections() {
  local raw=""
  local candidate=""

  while true; do
    read -r -p "Enter max connections (0 = unlimited): " raw < /dev/tty

    if [[ "$raw" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      candidate="${BASH_REMATCH[1]}"
      MAX_CONNECTIONS="$candidate"
      break
    else
      warn "Invalid input. Enter an integer >= 0."
    fi
  done
}

install_dependencies() {
  log "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    openssl \
    iproute2
}

verify_dependencies() {
  local missing=0
  for cmd in curl git make gcc openssl ss install useradd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command after installation: $cmd"
      missing=1
    fi
  done

  (( missing == 0 )) || die "Dependencies verification failed."
}

prepare_system_user_and_dirs() {
  log "Preparing user and directories..."

  install -d -m 0755 "$INSTALL_DIR"
  install -d -m 0755 "$ETC_DIR"

  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$RUN_USER"
  fi
}

build_and_install_mtproxy() {
  log "Downloading and building official MTProxy..."
  BUILD_DIR="$(mktemp -d /tmp/mtproxy-build.XXXXXX)"

  git clone --depth 1 "$REPO_URL" "${BUILD_DIR}/MTProxy"

  local jobs=1
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  fi

  make -C "${BUILD_DIR}/MTProxy" -j"${jobs}"
  install -m 0755 "${BUILD_DIR}/MTProxy/objs/bin/mtproto-proxy" "$BIN_PATH"

  [[ -x "$BIN_PATH" ]] || die "MTProxy binary was not installed correctly."
}

write_fetch_script() {
  # Helper script for atomic runtime config refresh.
  cat > "$UPDATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/mtproxy"
SECRET_URL="https://core.telegram.org/getProxySecret"
CONFIG_URL="https://core.telegram.org/getProxyConfig"

tmp_secret="$(mktemp)"
tmp_config="$(mktemp)"

cleanup() {
  rm -f "$tmp_secret" "$tmp_config"
}
trap cleanup EXIT

curl -fsSL --retry 5 --retry-delay 1 --connect-timeout 10 "$SECRET_URL" -o "$tmp_secret"
curl -fsSL --retry 5 --retry-delay 1 --connect-timeout 10 "$CONFIG_URL" -o "$tmp_config"

install -m 0644 "$tmp_secret" "${CONF_DIR}/proxy-secret"
install -m 0644 "$tmp_config" "${CONF_DIR}/proxy-multi.conf"
EOF

  chmod 0755 "$UPDATE_SCRIPT"
}

fetch_runtime_files() {
  log "Fetching Telegram runtime config files..."
  "$UPDATE_SCRIPT"

  [[ -s "${ETC_DIR}/proxy-secret" ]] || die "${ETC_DIR}/proxy-secret is missing or empty."
  [[ -s "${ETC_DIR}/proxy-multi.conf" ]] || die "${ETC_DIR}/proxy-multi.conf is missing or empty."
}

generate_user_secret() {
  log "Generating proxy secret for clients..."
  SECRET="$(openssl rand -hex 16)"
  [[ "$SECRET" =~ ^[0-9a-f]{32}$ ]] || die "Generated secret has invalid format."

  printf '%s\n' "$SECRET" > "${ETC_DIR}/user-secret"
  chmod 0600 "${ETC_DIR}/user-secret"
}

build_client_secret() {
  if [[ -n "$SNI_DOMAIN" ]]; then
    local domain_hex=""
    domain_hex="$(printf '%s' "$SNI_DOMAIN" | od -An -tx1 -v | tr -d ' \n')"
    [[ -n "$domain_hex" ]] || die "Failed to encode SNI domain to hex."

    CLIENT_SECRET="ee${SECRET}${domain_hex}"
    TRANSPORT_MODE="fake-tls+sni"
  else
    CLIENT_SECRET="$SECRET"
    TRANSPORT_MODE="classic"
  fi
}

find_free_stats_port() {
  local candidate

  # Preferred local stats ports.
  for candidate in 2398 2399 2400 2401 2402; do
    if is_port_free "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  # Fallback random search.
  local i
  for i in $(seq 1 300); do
    candidate=$((20000 + RANDOM % 40000))
    if is_port_free "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

write_systemd_service() {
  log "Creating systemd service..."

  local exec_start=""
  if [[ -n "$SNI_DOMAIN" ]]; then
    exec_start="${BIN_PATH} -u ${RUN_USER} -p ${STATS_PORT} -H ${PORT} -S ${SECRET} -D ${SNI_DOMAIN} -C ${MAX_CONNECTIONS} --aes-pwd ${ETC_DIR}/proxy-secret ${ETC_DIR}/proxy-multi.conf"
  else
    exec_start="${BIN_PATH} -u ${RUN_USER} -p ${STATS_PORT} -H ${PORT} -S ${SECRET} -C ${MAX_CONNECTIONS} --aes-pwd ${ETC_DIR}/proxy-secret ${ETC_DIR}/proxy-multi.conf"
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telegram MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=-${UPDATE_SCRIPT}
ExecStart=${exec_start}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$SERVICE_FILE"
}

configure_ufw_if_active() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "^Status: active"; then
      log "UFW is active. Opening TCP port ${PORT}..."
      ufw allow "${PORT}/tcp" >/dev/null || warn "Failed to add UFW rule automatically."
    fi
  fi
}

start_and_enable_service() {
  log "Enabling and starting service..."
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
  systemctl restart "${SERVICE_NAME}.service"
}

is_valid_ipv4() {
  local ip="$1"

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

  for octet in "$o1" "$o2" "$o3" "$o4"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done

  return 0
}

get_public_ip() {
  local candidate=""
  local url=""

  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    if candidate="$(curl -4fsSL --retry 3 --retry-delay 1 --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" \
      && is_valid_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

print_summary() {
  local service_status=""
  local service_enabled=""
  local limit_display=""
  local tg_link=""

  service_status="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  service_enabled="$(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true)"

  if [[ "$MAX_CONNECTIONS" == "0" ]]; then
    limit_display="0 (unlimited)"
  else
    limit_display="$MAX_CONNECTIONS"
  fi

  tg_link="tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"

  printf '\n'
  printf '=============================================\n'
  printf ' MTProto Proxy installed and started\n'
  printf '=============================================\n'
  printf 'Transport mode:            %s\n' "$TRANSPORT_MODE"
  if [[ -n "$SNI_DOMAIN" ]]; then
    printf 'SNI domain:                %s\n' "$SNI_DOMAIN"
  fi
  printf 'Port:                      %s\n' "$PORT"
  printf 'Connection limit:          %s\n' "$limit_display"
  printf 'Systemd status:            %s (enabled: %s)\n' "$service_status" "$service_enabled"
  printf 'Server secret:             %s\n' "$SECRET"
  printf 'Client secret:             %s\n' "$CLIENT_SECRET"
  printf 'tg:// link:                %s\n' "$tg_link"
  printf '\n'
  printf 'Logs: journalctl -u %s.service -f\n' "$SERVICE_NAME"
  printf '=============================================\n'
}

main() {
  require_root
  check_os
  ensure_interactive_tty
  ensure_base_commands
  ensure_ss_available

  log "Telegram MTProto Proxy installer (Ubuntu 22.04/24.04)"

  # Interactive Question #1
  ask_port

  # Interactive Question #2
  ask_sni_domain

  # Interactive Question #3
  ask_max_connections

  install_dependencies
  verify_dependencies
  prepare_system_user_and_dirs
  build_and_install_mtproxy
  write_fetch_script
  fetch_runtime_files
  generate_user_secret
  build_client_secret

  STATS_PORT="$(find_free_stats_port)" || die "Could not find a free local stats port."

  write_systemd_service
  configure_ufw_if_active
  start_and_enable_service

  PUBLIC_IP="$(get_public_ip)" || die "Could not detect external IPv4 for tg:// link."
  print_summary
}

main "$@"
