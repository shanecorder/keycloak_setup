#!/usr/bin/env bash
# =============================================================================
# HPC Keycloak — Installation Script (Rocky Linux, bare-metal)
# =============================================================================
# Installs Keycloak 26.x as a systemd service on a Rocky Linux VM.
# Designed to run behind a Caddy (or nginx) reverse proxy that handles TLS.
#
# Prerequisites:
#   - Rocky Linux 8 or 9 (must run as root)
#   - config.env with DB_PASSWORD set (KC_ADMIN_PASSWORD generated if absent)
#   - PostgreSQL reachable at POSTGRES_HOST:POSTGRES_PORT with DB_NAME created
#   - Caddy configured to proxy https://KC_FQDN → http://localhost:KC_PORT
#
# Usage:
#   sudo ./new_keycloak_setup.sh
#   sudo ./new_keycloak_setup.sh --config=/path/to/config.env
#   sudo ./new_keycloak_setup.sh --version=26.2.5
#   sudo ./new_keycloak_setup.sh --dry-run --yes
#   sudo ./new_keycloak_setup.sh --help
#
# Options:
#   --config=FILE    Path to config.env (default: ./config.env)
#   --version=VER    Keycloak version to install (overrides config.env KC_VERSION)
#   --dry-run        Print commands without executing them
#   --yes            Non-interactive (skip confirmation prompts)
#   -h | --help      Show this message
#
# Exit codes:
#   0  Installation complete
#   1  Error
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

log_ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
log_info() { echo -e "  ${CYAN}→${RESET}  $*"; }
log_warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
log_err()  { echo -e "  ${RED}✖${RESET}  $*" >&2; }
log_step() { echo; echo -e "${BOLD}▶  $*${RESET}"; }
die()      { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.env"
KC_VERSION_OVERRIDE=""
DRY_RUN=0
YES=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)  CONFIG_FILE="${_arg#--config=}" ;;
        --version=*) KC_VERSION_OVERRIDE="${_arg#--version=}" ;;
        --dry-run)   DRY_RUN=1 ;;
        --yes)       YES=1 ;;
        -h|--help)
            sed -n '/^# ===.*$/,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -50
            exit 0
            ;;
        *) die "Unknown argument: ${_arg}. Use --help." ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_cmd() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo -e "  ${DIM}[DRY-RUN]${RESET} $*"
    else
        "$@"
    fi
}

gen_secret() { python3 -c "import secrets; print(secrets.token_urlsafe(24))"; }

write_env_var() {
    # Idempotently write KEY="VALUE" to config file
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        echo "${key}=\"${value}\"" >> "${file}"
    fi
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root: sudo $0 $*"
fi

# ---------------------------------------------------------------------------
# Load config.env
# ---------------------------------------------------------------------------
[[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

[[ -n "${KC_VERSION_OVERRIDE}" ]] && KC_VERSION="${KC_VERSION_OVERRIDE}"

# ---------------------------------------------------------------------------
# Validate required config
# ---------------------------------------------------------------------------
KC_VERSION="${KC_VERSION:-26.2.5}"
KC_FQDN="${KC_FQDN:?KC_FQDN not set in config.env}"
KC_PORT="${KC_PORT:-8080}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_INSTALL_DIR="${KC_INSTALL_DIR:-/opt/keycloak}"

DB_NAME="${DB_NAME:?DB_NAME not set in config.env}"
DB_USER="${DB_USER:?DB_USER not set in config.env}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD not set — set it in config.env before running}"
POSTGRES_HOST="${POSTGRES_HOST:?POSTGRES_HOST not set in config.env}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REALM_NAME="${REALM_NAME:-hpc-infrastructure}"

# Generate admin password if absent
if [[ -z "${KC_ADMIN_PASSWORD:-}" ]]; then
    KC_ADMIN_PASSWORD="$(gen_secret)"
    log_warn "KC_ADMIN_PASSWORD not set — generated a random password; will write to config.env"
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Keycloak HPC — Installation (Rocky Linux)           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "Version    : ${KC_VERSION}"
log_info "Install    : ${KC_INSTALL_DIR}"
log_info "Public URL : https://${KC_FQDN}"
log_info "Local bind : http://localhost:${KC_PORT}"
log_info "Database   : ${DB_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB_NAME}"
log_info "Realm      : ${REALM_NAME}"
[[ "${DRY_RUN}" -eq 1 ]] && log_warn "DRY-RUN mode — no changes will be made"
echo

if [[ "${YES}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
    read -rp "  Proceed with installation? [y/N]: " _ans
    [[ "${_ans}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Step 1: System dependencies
# ---------------------------------------------------------------------------
log_step "Step 1: System dependencies (Java 21, curl, tar)"
run_cmd dnf install -y java-21-openjdk-headless curl tar
log_ok "Dependencies installed"

# ---------------------------------------------------------------------------
# Step 2: Keycloak system user
# ---------------------------------------------------------------------------
log_step "Step 2: Keycloak system user"
if id keycloak &>/dev/null; then
    log_info "User 'keycloak' already exists — skipping"
else
    run_cmd useradd --system --no-create-home \
        --home-dir "${KC_INSTALL_DIR}" \
        --shell /sbin/nologin keycloak
    log_ok "System user 'keycloak' created"
fi

# ---------------------------------------------------------------------------
# Step 3: Download and install Keycloak
# ---------------------------------------------------------------------------
log_step "Step 3: Download Keycloak ${KC_VERSION}"
KC_ARCHIVE="keycloak-${KC_VERSION}.tar.gz"
KC_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/${KC_ARCHIVE}"

if [[ -d "${KC_INSTALL_DIR}/bin" ]]; then
    log_warn "Existing installation found at ${KC_INSTALL_DIR}"
    if [[ "${YES}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
        read -rp "  Replace existing installation? [y/N]: " _ans
        if [[ "${_ans}" =~ ^[Yy]$ ]]; then
            systemctl stop keycloak 2>/dev/null || true
            rm -rf "${KC_INSTALL_DIR}"
        else
            log_info "Keeping existing installation — skipping download"
        fi
    else
        log_info "Keeping existing installation (use --yes to auto-replace)"
    fi
fi

if [[ ! -d "${KC_INSTALL_DIR}/bin" ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        log_info "Downloading ${KC_URL} ..."
        curl -Lo "/tmp/${KC_ARCHIVE}" "${KC_URL}"
        mkdir -p "${KC_INSTALL_DIR}"
        tar -xf "/tmp/${KC_ARCHIVE}" --strip-components=1 -C "${KC_INSTALL_DIR}"
        rm -f "/tmp/${KC_ARCHIVE}"
        log_ok "Keycloak ${KC_VERSION} extracted to ${KC_INSTALL_DIR}"
    else
        echo -e "  ${DIM}[DRY-RUN]${RESET} Would download and extract to ${KC_INSTALL_DIR}"
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Write keycloak.conf
# ---------------------------------------------------------------------------
log_step "Step 4: keycloak.conf"
CONF_FILE="${KC_INSTALL_DIR}/conf/keycloak.conf"

if [[ "${DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${KC_INSTALL_DIR}/conf"
    cat > "${CONF_FILE}" <<KCCONF
# =============================================================================
# Keycloak HPC Configuration — managed by new_keycloak_setup.sh
# Do not edit manually; re-run the setup script to regenerate.
# =============================================================================

# PostgreSQL database
db=postgres
db-username=${DB_USER}
db-password=${DB_PASSWORD}
db-url=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${DB_NAME}

# HTTP — Keycloak binds locally; Caddy handles TLS termination
http-enabled=true
http-port=${KC_PORT}

# Proxy — trust X-Forwarded-* headers from Caddy
proxy-headers=xforwarded

# Public hostname (the FQDN Caddy advertises to clients)
hostname=https://${KC_FQDN}
hostname-strict=true
hostname-backchannel-dynamic=false

# Logging
log=console
log-level=INFO
KCCONF
    log_ok "keycloak.conf written to ${CONF_FILE}"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would write ${CONF_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 5: Build optimized distribution
# ---------------------------------------------------------------------------
log_step "Step 5: Build optimized distribution (kc.sh build)"
run_cmd chown -R keycloak:keycloak "${KC_INSTALL_DIR}"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    sudo -u keycloak "${KC_INSTALL_DIR}/bin/kc.sh" build
    log_ok "Optimized build complete"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would run: sudo -u keycloak ${KC_INSTALL_DIR}/bin/kc.sh build"
fi

# ---------------------------------------------------------------------------
# Step 6: Systemd service unit
# ---------------------------------------------------------------------------
log_step "Step 6: Systemd service unit"
SERVICE_FILE="/etc/systemd/system/keycloak.service"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    cat > "${SERVICE_FILE}" <<SVCEOF
[Unit]
Description=Keycloak Identity Provider (HPC)
Documentation=https://www.keycloak.org/documentation
After=network.target postgresql.service
Wants=network.target

[Service]
User=keycloak
Group=keycloak
Environment="KC_HOME=${KC_INSTALL_DIR}"
Environment="KEYCLOAK_ADMIN=${KC_ADMIN_USER}"
Environment="KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}"
ExecStart=${KC_INSTALL_DIR}/bin/kc.sh start
ExecStop=/bin/kill -TERM \$MAINPID
TimeoutStartSec=600
TimeoutStopSec=60
Restart=on-failure
RestartSec=30s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=keycloak

[Install]
WantedBy=multi-user.target
SVCEOF
    log_ok "Systemd unit written to ${SERVICE_FILE}"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would write ${SERVICE_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 7: Firewall
# ---------------------------------------------------------------------------
log_step "Step 7: Firewall (port ${KC_PORT}/tcp)"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    if firewall-cmd --query-port="${KC_PORT}/tcp" --quiet 2>/dev/null; then
        log_info "Port ${KC_PORT}/tcp already open in firewalld"
    else
        run_cmd firewall-cmd --permanent --add-port="${KC_PORT}/tcp"
        run_cmd firewall-cmd --reload
        log_ok "Port ${KC_PORT}/tcp opened"
    fi
else
    log_warn "firewalld not active — skipping (ensure port ${KC_PORT} is accessible to Caddy)"
fi

# ---------------------------------------------------------------------------
# Step 8: Enable and start Keycloak
# ---------------------------------------------------------------------------
log_step "Step 8: Enable and start Keycloak service"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    systemctl daemon-reload
    systemctl enable --now keycloak
    log_ok "keycloak service enabled and started"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would: systemctl daemon-reload && systemctl enable --now keycloak"
fi

# ---------------------------------------------------------------------------
# Step 9: Wait for Keycloak to be healthy
# ---------------------------------------------------------------------------
log_step "Step 9: Waiting for Keycloak to become ready"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    KC_HEALTH_URL="http://localhost:${KC_PORT}/realms/master"
    _waited=0 _max=180
    echo -ne "  Polling ${KC_HEALTH_URL} "
    while ! curl -sf --max-time 3 "${KC_HEALTH_URL}" &>/dev/null; do
        if [[ "${_waited}" -ge "${_max}" ]]; then
            echo
            log_err "Keycloak did not start within ${_max}s"
            log_info "Check logs: journalctl -u keycloak -n 50"
            exit 1
        fi
        printf '.'
        sleep 5
        _waited=$((_waited + 5))
    done
    echo " ready (${_waited}s)"
    log_ok "Keycloak is healthy"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would poll http://localhost:${KC_PORT}/realms/master"
fi

# ---------------------------------------------------------------------------
# Step 10: Write OIDC config to config.env
# ---------------------------------------------------------------------------
log_step "Step 10: Writing OIDC variables to ${CONFIG_FILE}"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    OIDC_ISSUER_VAL="https://${KC_FQDN}/realms/${REALM_NAME}"
    OIDC_DISCOVERY_VAL="${OIDC_ISSUER_VAL}/.well-known/openid-configuration"

    write_env_var "KC_ADMIN_PASSWORD"  "${KC_ADMIN_PASSWORD}"  "${CONFIG_FILE}"
    write_env_var "OIDC_ISSUER"        "${OIDC_ISSUER_VAL}"   "${CONFIG_FILE}"
    write_env_var "OIDC_DISCOVERY_URL" "${OIDC_DISCOVERY_VAL}" "${CONFIG_FILE}"
    log_ok "OIDC_ISSUER, OIDC_DISCOVERY_URL, KC_ADMIN_PASSWORD written to config.env"
else
    echo -e "  ${DIM}[DRY-RUN]${RESET} Would update OIDC_* and KC_ADMIN_PASSWORD in ${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Keycloak Installation Complete                      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "Admin console :  https://${KC_FQDN}/admin"
log_info "Admin user    :  ${KC_ADMIN_USER}"
[[ "${DRY_RUN}" -eq 0 ]] && log_info "Admin password:  ${KC_ADMIN_PASSWORD}  (saved to config.env)"
echo
echo -e "  ${GREEN}Next steps:${RESET}"
echo "  1. Confirm Caddy routes https://${KC_FQDN} → http://localhost:${KC_PORT}"
echo "  2. Run:  ./new_configure_hpc.sh    (configure realm, clients, scopes)"
echo "  3. Run:  ./setup_hpc_ad.sh         (federate Active Directory)"
echo "  4. Run:  ./test_hpc_auth.sh --user=<username>   (validate auth)"
echo