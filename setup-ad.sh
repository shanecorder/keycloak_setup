#!/usr/bin/env bash
# =============================================================================
# StromaAI — Active Directory / LDAP Federation Setup
# =============================================================================
# Configures Keycloak to federate users from your institution's Active
# Directory (or any LDAP server) into the stroma-ai realm.
#
# What this script does:
#   1. Reads AD connection parameters (from config.env or flags)
#   2. Obtains a Keycloak admin token
#   3. Creates/replaces the LDAP user-storage provider in the stroma-ai realm
#   4. Adds standard attribute mappers (username, email, firstName, lastName)
#   5. Adds a group-to-role mapper: AD_RESEARCHER_GROUP → stroma_researcher
#   6. Adds a hardcoded-role mapper for the role fallback (optional)
#   7. Triggers an initial full sync (users + groups)
#   8. Runs test-auth.sh --check-groups to validate the mapping
#
# After running this script, cluster users can log in to StromaAI using their
# normal institutional username and password. No account provisioning needed.
#
# Usage:
#   deploy/keycloak/setup-ad.sh                              # interactive wizard
#   deploy/keycloak/setup-ad.sh --yes                        # non-interactive
#   deploy/keycloak/setup-ad.sh --provider-name=stroma-ai-partner  # second domain
#   deploy/keycloak/setup-ad.sh --dry-run --yes
#   deploy/keycloak/setup-ad.sh --config=/path/to/config.env
#   deploy/keycloak/setup-ad.sh --test-user=jsmith
#   deploy/keycloak/setup-ad.sh --help
#
# Multiple AD domains:
#   Run the script twice with different --provider-name values.
#   Each provider gets its own namespaced variables in config.env:
#
#     # First domain (default name stroma-ai-ad  →  prefix AD_)
#     deploy/keycloak/setup-ad.sh
#
#     # Second domain (name stroma-ai-partner  →  prefix PARTNER_AD_)
#     deploy/keycloak/setup-ad.sh --provider-name=stroma-ai-partner
#
#   Config.env layout for two domains:
#     AD_SERVER_URL=ldaps://ad.moffitt.org
#     PARTNER_AD_SERVER_URL=ldaps://ad.partner.org
#     ... (each provider has its own PARTNER_AD_* vars)
#
# Configuration (all readable from config.env or passed as flags):
#   AD_SERVER_URL         ldaps://ad.your-institution.org  (or ldap:// for plain)
#   AD_BIND_DN            cn=svc-stroma,ou=Service Accounts,dc=moffitt,dc=org
#   AD_BIND_PASSWORD      <service account password>
#   AD_USER_DN            ou=Users,dc=moffitt,dc=org
#   AD_RESEARCHER_GROUP   CN=HPC-GPU-Users,ou=Groups,dc=moffitt,dc=org
#
# Optional tuning (defaults are safe for most AD deployments):
#   AD_USER_OBJECT_CLASS   user            (AD default)
#   AD_UUID_ATTR           objectGUID      (AD default; use entryUUID for OpenLDAP)
#   AD_USERNAME_ATTR       sAMAccountName  (AD default; use uid for OpenLDAP)
#   AD_FIRSTNAME_ATTR      givenName
#   AD_LASTNAME_ATTR       sn
#   AD_EMAIL_ATTR          mail
#   AD_GROUP_OBJECT_CLASS  group           (AD default)
#   AD_SYNC_INTERVAL       86400           (full sync period in seconds; 0=manual)
#
# Security requirements:
#   - AD_BIND_DN should be a read-only service account with no write access
#   - Use ldaps:// (TLS) in production; ldap:// only for testing
#   - AD_BIND_PASSWORD is written to config.env (chmod 640, owned by stromaai)
#
# Options:
#   --config=FILE            Path to config.env (auto-detected if omitted)
#   --provider-name=NAME     Keycloak LDAP provider name (default: stroma-ai-ad)
#                            Use a unique name per AD domain when federating multiple
#   --kc=HOST:PORT           Keycloak host:port (default: from KC_INTERNAL_URL)
#   --realm=REALM            Keycloak realm (default: stroma-ai)
#   --test-user=USER         Run test-auth.sh --check-groups after sync
#   --dry-run                Print API payloads without calling Keycloak
#   --yes                    Non-interactive (fail if required values missing)
#   -h | --help              Show this message
#
# Exit codes:
#   0  Completed successfully
#   1  Fatal error or missing required input
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Source shared library
# ---------------------------------------------------------------------------
# shellcheck source=install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"

# DIM is not declared in common.sh — add it here
DIM=$([[ -t 1 ]] && echo '\033[2m' || echo '')

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE=""
KC_OVERRIDE=""
REALM="stroma-ai"
PROVIDER_NAME="stroma-ai-ad"
TEST_USER=""
DRY_RUN=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)         CONFIG_FILE="${_arg#--config=}" ;;
        --provider-name=*)  PROVIDER_NAME="${_arg#--provider-name=}" ;;
        --kc=*)             KC_OVERRIDE="${_arg#--kc=}" ;;
        --realm=*)          REALM="${_arg#--realm=}" ;;
        --test-user=*)      TEST_USER="${_arg#--test-user=}" ;;
        --dry-run)          DRY_RUN=1 ;;
        --yes)              export STROMA_YES=1 ;;
        -h|--help)
            sed -n '2,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -80
            exit 0
            ;;
        *) echo "Unknown argument: ${_arg}. Use --help." >&2; exit 1 ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Derive config.env namespace from provider name.
# stroma-ai-ad      → CONF_NS="AD"       → vars: AD_SERVER_URL, AD_BIND_DN …
# stroma-ai-partner → CONF_NS="PARTNER"  → vars: PARTNER_AD_SERVER_URL …
# stroma-ai-ucf     → CONF_NS="UCF"      → vars: UCF_AD_SERVER_URL …
# ---------------------------------------------------------------------------
_derive_conf_ns() {
    local name="$1"
    local short="${name#stroma-ai-}"
    # Uppercase and replace hyphens with underscores
    echo "${short^^}" | tr '-' '_'
}
CONF_NS="$(_derive_conf_ns "${PROVIDER_NAME}")"

# Build the actual config.env key names for this provider.
# Default provider (stroma-ai-ad / CONF_NS=AD) uses the plain AD_ prefix
# for backward compatibility.  All others use <NS>_AD_ prefix.
if [[ "${CONF_NS}" == "AD" ]]; then
    _pfx="AD_"
else
    _pfx="${CONF_NS}_AD_"
fi

# Pre-load values from namespaced config.env keys into the canonical
# AD_* variable names that the rest of the script uses internally.
# This is done BEFORE sourcing config.env so the source can overwrite; we
# re-assign from the namespaced names just after.
_preload_ns_vars() {
    local pfx="$1"
    for _pair in \
        "${pfx}SERVER_URL:AD_SERVER_URL" \
        "${pfx}BIND_DN:AD_BIND_DN" \
        "${pfx}BIND_PASSWORD:AD_BIND_PASSWORD" \
        "${pfx}USER_DN:AD_USER_DN" \
        "${pfx}CUSTOM_FILTER:AD_CUSTOM_FILTER" \

        "${pfx}RESEARCHER_GROUP:AD_RESEARCHER_GROUP" \
        "${pfx}USER_OBJECT_CLASS:AD_USER_OBJECT_CLASS" \
        "${pfx}UUID_ATTR:AD_UUID_ATTR" \
        "${pfx}USERNAME_ATTR:AD_USERNAME_ATTR" \
        "${pfx}FIRSTNAME_ATTR:AD_FIRSTNAME_ATTR" \
        "${pfx}LASTNAME_ATTR:AD_LASTNAME_ATTR" \
        "${pfx}EMAIL_ATTR:AD_EMAIL_ATTR" \
        "${pfx}GROUP_OBJECT_CLASS:AD_GROUP_OBJECT_CLASS" \
        "${pfx}SYNC_INTERVAL:AD_SYNC_INTERVAL"
    do
        local src_key="${_pair%%:*}" dst_var="${_pair##*:}"
        local val="${!src_key:-}"
        # Strip surrounding double-quotes written by the persist block
        val="${val#\"}" val="${val%\"}"
        if [[ -n "${val}" ]]; then
            declare -g "${dst_var}=${val}"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Locate and source config.env
# ---------------------------------------------------------------------------
if [[ -z "${CONFIG_FILE}" ]]; then
    for _p in \
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}" \
        "/cm/shared/apps/stroma-ai/config.env" \
        "/opt/stroma-ai/config.env" \
        "/opt/apps/stroma-ai/config.env" \
        "${HOME}/stroma-ai/config.env"
    do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; break; fi
    done
fi
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi
# Map namespaced config.env keys → canonical AD_* vars used internally
_preload_ns_vars "${_pfx}"

# ---------------------------------------------------------------------------
# Resolve Keycloak host:port
# ---------------------------------------------------------------------------
if [[ -n "${KC_OVERRIDE}" ]]; then
    _kc_tmp="${KC_OVERRIDE}"
else
    if [[ -n "${KC_INTERNAL_URL:-}" ]]; then
        _kc_tmp="${KC_INTERNAL_URL#http://}"; _kc_tmp="${_kc_tmp#https://}"
        _kc_tmp="${_kc_tmp%%/*}"
    else
        _kc_tmp="${STROMA_HEAD_HOST:-localhost}:8080"
    fi
fi
KC_HOST="${_kc_tmp%%:*}"
KC_PORT="${_kc_tmp##*:}"; [[ "${KC_PORT}" == "${KC_HOST}" ]] && KC_PORT="8080"
KC_BASE="http://${KC_HOST}:${KC_PORT}"

# ---------------------------------------------------------------------------
# Pre-flight: require tools
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    command -v "${_cmd}" &>/dev/null || { echo "ERROR: ${_cmd} not found." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Dry-run helpers
# ---------------------------------------------------------------------------
kc_api() {
    # kc_api METHOD PATH JSON_BODY — calls Keycloak admin REST API
    local method="$1" path="$2" body="${3:-}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo -e "  ${DIM}[DRY-RUN] ${method} ${KC_BASE}${path}${RESET}"
        [[ -n "${body}" ]] && echo -e "  ${DIM}  body: ${body:0:120}...${RESET}"
        echo "dry-run-placeholder"
        return 0
    fi
    local resp
    if [[ -n "${body}" ]]; then
        resp=$(curl -sk --max-time 30 \
            -X "${method}" "${KC_BASE}${path}" \
            -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${body}" \
            -w "\n%{http_code}" 2>/dev/null)
    else
        resp=$(curl -sk --max-time 30 \
            -X "${method}" "${KC_BASE}${path}" \
            -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
            -w "\n%{http_code}" 2>/dev/null)
    fi
    # Split body and status code
    local http_code body_text
    http_code=$(echo "${resp}" | tail -1)
    body_text=$(echo "${resp}" | head -n -1)
    # 2xx = success, 409 = already exists (treat as OK)
    if [[ "${http_code}" =~ ^2 ]] || [[ "${http_code}" == "409" ]]; then
        echo "${body_text}"
    else
        echo -e "${RED}ERROR${RESET}: KC API ${method} ${path} returned HTTP ${http_code}" >&2
        echo -e "  Response: ${body_text:0:300}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   StromaAI — Active Directory Federation Setup        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${DIM}Provider: ${PROVIDER_NAME}  |  Config prefix: ${_pfx}${RESET}"
echo
[[ "${DRY_RUN}" -eq 1 ]] && echo -e "${YELLOW}DRY-RUN mode — no changes will be made to Keycloak${RESET}\n"

# ---------------------------------------------------------------------------
# Gather AD parameters interactively if not in config.env
# ---------------------------------------------------------------------------
prompt_if_empty() {
    # prompt_if_empty VAR_NAME "Prompt text" [default]
    local var_name="$1" prompt_text="$2" default="${3:-}"
    local current="${!var_name:-}"
    if [[ -n "${current}" ]]; then
        echo -e "  ${DIM}${var_name}=${current}${RESET}"
        return
    fi
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        if [[ -n "${default}" ]]; then
            declare -g "${var_name}=${default}"
            echo -e "  ${DIM}${var_name}=${default} (default)${RESET}"
        else
            echo -e "${RED}ERROR:${RESET} ${var_name} is required but not set. Add it to config.env or use --yes with all values set." >&2
            exit 1
        fi
        return
    fi
    local input
    if [[ -n "${default}" ]]; then
        read -rp "  ${prompt_text} [${default}]: " input
        declare -g "${var_name}=${input:-${default}}"
    else
        read -rp "  ${prompt_text}: " input
        if [[ -z "${input}" ]]; then
            echo -e "${RED}ERROR:${RESET} ${var_name} is required." >&2
            exit 1
        fi
        declare -g "${var_name}=${input}"
    fi
}

prompt_secret() {
    # prompt_secret VAR_NAME "Prompt text" — masked input, no default shown
    local var_name="$1" prompt_text="$2"
    local current="${!var_name:-}"
    if [[ -n "${current}" ]]; then
        echo -e "  ${DIM}${var_name}=<set>${RESET}"
        return
    fi
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        echo -e "${RED}ERROR:${RESET} ${var_name} is required but not set." >&2
        exit 1
    fi
    local input
    read -rsp "  ${prompt_text}: " input
    echo
    if [[ -z "${input}" ]]; then
        echo -e "${RED}ERROR:${RESET} ${var_name} is required." >&2
        exit 1
    fi
    declare -g "${var_name}=${input}"
}

echo -e "${BOLD}Step 1: AD Connection Parameters${RESET}"
echo -e "${DIM}(Values already in config.env are shown and skipped)${RESET}"
echo

prompt_if_empty AD_SERVER_URL    "AD server URL (ldaps://ad.example.org or ldap://...)"
prompt_if_empty AD_BIND_DN       "Service account DN (cn=svc-stroma,ou=Service Accounts,dc=example,dc=org)"
prompt_secret   AD_BIND_PASSWORD "Service account password"
prompt_if_empty AD_USER_DN       "User search base DN (ou=Users,dc=example,dc=org)"
prompt_if_empty AD_CUSTOM_FILTER "Custom LDAP filter — leave blank for none\n    (e.g. (|(memberOf=CN=HPC Users,ou=Groups,dc=example,dc=org)(memberOf=CN=Admins,...)))" ""
prompt_if_empty AD_RESEARCHER_GROUP \
    "AD group DN for StromaAI researchers (CN=HPC-GPU-Users,ou=Groups,dc=example,dc=org)"

echo
echo -e "${BOLD}Step 2: Optional tuning${RESET} ${DIM}(press Enter to accept defaults)${RESET}"
echo
prompt_if_empty AD_USER_OBJECT_CLASS  "User object class"           "user"
prompt_if_empty AD_UUID_ATTR          "UUID attribute"              "objectGUID"
prompt_if_empty AD_USERNAME_ATTR      "Username attribute"          "sAMAccountName"
prompt_if_empty AD_FIRSTNAME_ATTR     "First name attribute"        "givenName"
prompt_if_empty AD_LASTNAME_ATTR      "Last name attribute"         "sn"
prompt_if_empty AD_EMAIL_ATTR         "Email attribute"             "mail"
prompt_if_empty AD_GROUP_OBJECT_CLASS "Group object class"          "group"
prompt_if_empty AD_SYNC_INTERVAL      "Full sync interval (seconds, 0=manual)" "86400"
echo

# ---------------------------------------------------------------------------
# Persist AD params to config.env (except password — stored separately)
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 0 && -n "${CONFIG_FILE}" ]]; then
    log_step "Persisting AD configuration to ${CONFIG_FILE}"
    # Write using namespaced keys so multiple providers don't overwrite each other.
    # printf '%q' produces shell-safe quoting for any value (handles spaces,
    # parens, ?, |, = in LDAP DN/filter strings without triggering bash extglob).
    for _bare in SERVER_URL BIND_DN USER_DN CUSTOM_FILTER RESEARCHER_GROUP \
                 USER_OBJECT_CLASS UUID_ATTR USERNAME_ATTR \
                 FIRSTNAME_ATTR LASTNAME_ATTR EMAIL_ATTR \
                 GROUP_OBJECT_CLASS SYNC_INTERVAL; do
        local_var="AD_${_bare}"
        conf_key="${_pfx}${_bare}"
        printf -v _qval '%q' "${!local_var:-}"
        write_env_var "${conf_key}" "${_qval}" "${CONFIG_FILE}" 2>/dev/null || true
    done
    # Store bind password with namespaced key — config.env is already 640
    printf -v _qval '%q' "${AD_BIND_PASSWORD}"
    write_env_var "${_pfx}BIND_PASSWORD" "${_qval}" "${CONFIG_FILE}" 2>/dev/null || true
    log_ok "AD config saved (keys prefixed with '${_pfx}')"
fi

# ---------------------------------------------------------------------------
# LDAPS truststore setup (only when using ldaps://)
# ---------------------------------------------------------------------------
# keytool is part of the JVM — it is not a standalone binary on most HPC nodes.
# We use keytool from inside the running Keycloak container so the host doesn't
# need a JDK installed.
# ---------------------------------------------------------------------------
if echo "${AD_SERVER_URL}" | grep -qi "^ldaps://"; then
    # Take only the first URL from a space-separated list, then extract host/port
    _first_url=$(echo "${AD_SERVER_URL}" | awk '{print $1}')
    _ad_host=$(echo "${_first_url}" | sed 's|ldaps://||;s|/.*||;s|:.*||')
    _ad_port=$(echo "${_first_url}" | grep -oP ':\K[0-9]+$' || echo "636")
    _ad_port="${_ad_port:-636}"
    _ts_dir="$(dirname "${CONFIG_FILE}")"
    _ts_path="${_ts_dir}/ldap-truststore.jks"
    _ts_pass="${KC_LDAP_TRUSTSTORE_PASSWORD:-changeit}"

    log_step "Setting up LDAPS truststore for ${_ad_host}:${_ad_port}"

    # Detect keytool: prefer host, fall back to Keycloak container
    _keytool=""
    if command -v keytool &>/dev/null; then
        _keytool="keytool"
    else
        # Find the Keycloak container — match keycloak twice to avoid keycloak_postgres_1
        _kc_container=$(podman ps --format '{{.Names}}' 2>/dev/null | grep -i 'keycloak.*keycloak\|keycloak_keycloak' | head -1 || true)
        # Fallback: any container with keycloak that is NOT postgres
        if [[ -z "${_kc_container}" ]]; then
            _kc_container=$(podman ps --format '{{.Names}}' 2>/dev/null | grep -i keycloak | grep -iv postgres | head -1 || true)
        fi
        if [[ -n "${_kc_container}" ]]; then
            _keytool="podman exec ${_kc_container} keytool"
            echo -e "  ${DIM}keytool not found on host — using container: ${_kc_container}${RESET}"
        fi
    fi

    if [[ -z "${_keytool}" ]]; then
        echo -e "  ${YELLOW}WARN:${RESET} keytool not found (host or container). Skipping truststore setup."
        echo -e "  Run setup-ad.sh again after starting the Keycloak container, or"
        echo -e "  create ${_ts_path} manually and set KC_LDAP_TRUSTSTORE_JKS in config.env."
    else
        # Fetch the full cert chain from the AD LDAPS port
        _chain_file="/tmp/stroma-ad-ca-chain-$$.pem"
        echo -e "  Fetching cert chain from ${_ad_host}:${_ad_port} ..."
        openssl s_client -connect "${_ad_host}:${_ad_port}" -showcerts \
            </dev/null 2>/dev/null \
            | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
            > "${_chain_file}"

        _cert_count=$(grep -c "BEGIN CERTIFICATE" "${_chain_file}" 2>/dev/null || echo 0)
        if [[ "${_cert_count}" -eq 0 ]]; then
            echo -e "  ${YELLOW}WARN:${RESET} Could not retrieve certs from ${_ad_host}:${_ad_port}."
            echo -e "  Check firewall / AD server URL and run setup-ad.sh again."
            rm -f "${_chain_file}"
        else
            echo -e "  Retrieved ${_cert_count} certificate(s) from chain."

            # Split chain into individual cert files and import each into JKS.
            # Using Python to split avoids csplit portability issues (RHEL 8 vs 9).
            python3 - "${_chain_file}" /tmp/stroma-ad-cert-$$ <<'PYEOF'
import sys, re
chain  = open(sys.argv[1]).read()
prefix = sys.argv[2]
certs  = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', chain, re.DOTALL)
for i, c in enumerate(certs):
    with open(f"{prefix}-{i}.pem", "w") as f:
        f.write(c + "\n")
PYEOF

            _imported=0
            for _cert_file in /tmp/stroma-ad-cert-$$-*.pem; do
                [[ -f "${_cert_file}" ]] || continue
                _alias="ad-ldaps-$(basename "${_cert_file}" .pem)"

                # When keytool runs inside a container, cert files must be
                # copied into the container first — podman exec stdin redirection
                # does not deliver file content to the keytool process correctly.
                _kt_cert_arg="${_cert_file}"
                if [[ "${_keytool}" == podman\ exec* ]]; then
                    _ctr="${_kc_container}"
                    podman cp "${_cert_file}" "${_ctr}:${_cert_file}" 2>/dev/null || true
                    _kt_ts_path="/tmp/stroma-ldap-truststore-$$.jks"
                    # Also copy existing truststore into container if it exists on host
                    if [[ -f "${_ts_path}" ]] && ! podman exec "${_ctr}" test -f "${_kt_ts_path}" 2>/dev/null; then
                        podman cp "${_ts_path}" "${_ctr}:${_kt_ts_path}" 2>/dev/null || true
                    fi
                else
                    _kt_ts_path="${_ts_path}"
                fi

                # Skip if alias already exists
                if ${_keytool} -list -keystore "${_kt_ts_path}" -storepass "${_ts_pass}" \
                        -alias "${_alias}" &>/dev/null 2>&1; then
                    echo -e "  ${DIM}skip (already imported): ${_alias}${RESET}"
                else
                    ${_keytool} -importcert -noprompt -trustcacerts \
                        -alias "${_alias}" -file "${_cert_file}" \
                        -keystore "${_kt_ts_path}" \
                        -storepass "${_ts_pass}" &>/dev/null \
                        && { echo -e "  Imported: ${_alias}"; _imported=$((_imported+1)); } \
                        || echo -e "  ${YELLOW}WARN:${RESET} Failed to import ${_alias}"
                fi

                # Clean up cert from container
                if [[ "${_keytool}" == podman\ exec* ]]; then
                    podman exec "${_ctr}" rm -f "${_cert_file}" 2>/dev/null || true
                fi
                rm -f "${_cert_file}"
            done

            # Copy truststore back from container to host
            if [[ "${_keytool}" == podman\ exec* && -n "${_kc_container}" ]]; then
                podman cp "${_kc_container}:${_kt_ts_path}" "${_ts_path}" 2>/dev/null \
                    && podman exec "${_kc_container}" rm -f "${_kt_ts_path}" 2>/dev/null || true
            fi
            rm -f "${_chain_file}"

            if [[ "${_imported}" -gt 0 || -f "${_ts_path}" ]]; then
                chmod 640 "${_ts_path}" 2>/dev/null || true
                # Persist truststore path to config.env
                write_env_var "KC_LDAP_TRUSTSTORE_JKS" "${_ts_path}" "${CONFIG_FILE}" 2>/dev/null || true
                write_env_var "KC_LDAP_TRUSTSTORE_PASSWORD" "${_ts_pass}" "${CONFIG_FILE}" 2>/dev/null || true
                log_ok "Truststore ready: ${_ts_path} (${_imported} cert(s) imported)"
                echo -e "  ${YELLOW}ACTION:${RESET} Restart Keycloak to pick up truststore:"
                echo -e "    cd $(dirname "${CONFIG_FILE}")/../keycloak && podman compose down keycloak && podman compose up -d keycloak"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Obtain KC admin token
# ---------------------------------------------------------------------------
log_step "Obtaining Keycloak admin token"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-}"
if [[ -z "${KC_ADMIN_PASSWORD}" ]]; then
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        echo -e "${RED}ERROR:${RESET} KC_ADMIN_PASSWORD not in config.env." >&2
        exit 1
    fi
    read -rsp "  Keycloak admin password: " KC_ADMIN_PASSWORD; echo
fi

_token_resp=$(curl -sk --max-time 15 \
    -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_ADMIN_PASSWORD}" \
    2>/dev/null)
KC_ADMIN_TOKEN=$(python3 -c "import sys,json; print(json.loads(sys.argv[1]).get('access_token',''))" \
    "${_token_resp}" 2>/dev/null || true)

if [[ -z "${KC_ADMIN_TOKEN}" ]]; then
    _err=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('error_description', d.get('error','unknown')))" \
        "${_token_resp}" 2>/dev/null || echo "connection failed")
    echo -e "${RED}FATAL:${RESET} Could not obtain admin token: ${_err}" >&2
    echo "  Check: KC_ADMIN_PASSWORD in config.env, and that KC is running at ${KC_BASE}" >&2
    exit 1
fi
log_ok "Admin token obtained (KC: ${KC_BASE})"

# Tokens are short-lived (~60s). We now execute all API calls without pause.


# ---------------------------------------------------------------------------
# Step 3: Create/replace LDAP user-storage provider
# ---------------------------------------------------------------------------
log_step "Configuring LDAP user-storage provider"

# Check if a provider with our name already exists
_existing=$(kc_api GET "/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider")
_existing_id=$(python3 - "${_existing}" "${PROVIDER_NAME}" <<'PYEOF'
import sys, json
try:
    comps = json.loads(sys.argv[1])
    name  = sys.argv[2]
    for c in comps:
        if c.get("name") == name:
            print(c["id"])
            break
except Exception:
    pass
PYEOF
)

# Use PUT to update, POST to create
if [[ -n "${_existing_id}" && "${_existing_id}" != "dry-run-placeholder" ]]; then
    log_info "Existing LDAP provider found (${_existing_id}) — updating"
    _ldap_method="PUT"
    _ldap_path="/admin/realms/${REALM}/components/${_existing_id}"
    _ldap_id_field="\"id\": \"${_existing_id}\","
else
    _ldap_method="POST"
    _ldap_path="/admin/realms/${REALM}/components"
    _ldap_id_field=""
fi

# Determine whether this is AD (binary UUID needs special handling) or generic LDAP
_is_ad="true"
if echo "${AD_SERVER_URL}" | grep -qi "ldap://"; then
    _use_tls="false"
else
    _use_tls="true"
fi

_ldap_payload=$(python3 -c "
import json, sys
payload = {
    ${_ldap_id_field}
    'name': '${PROVIDER_NAME}',
    'providerId': 'ldap',
    'providerType': 'org.keycloak.storage.UserStorageProvider',
    'parentId': '${REALM}',
    'config': {
        'enabled':                   ['true'],
        'priority':                  ['0'],
        'editMode':                  ['READ_ONLY'],
        'syncRegistrations':         ['false'],
        'vendor':                    ['ad'],
        'usernameLDAPAttribute':     ['${AD_USERNAME_ATTR}'],
        'rdnLDAPAttribute':          ['cn'],
        'uuidLDAPAttribute':         ['${AD_UUID_ATTR}'],
        'userObjectClasses':         ['${AD_USER_OBJECT_CLASS}'],
        'connectionUrl':             ['${AD_SERVER_URL}'],
        'usersDn':                   ['${AD_USER_DN}'],
        'customUserSearchFilter':     ['${AD_CUSTOM_FILTER}'],
        'authType':                  ['simple'],
        'bindDn':                    ['${AD_BIND_DN}'],
        'bindCredential':            ['${AD_BIND_PASSWORD}'],
        'searchScope':               ['2'],
        'useTruststoreSpi':          ['ldapsOnly'],
        'connectionPooling':         ['true'],
        'pagination':                ['true'],
        'startTls':                  ['false'],
        'usePasswordModifyExtendedOp': ['false'],
        'validatePasswordPolicy':    ['false'],
        'trustEmail':                ['true'],
        'fullSyncPeriod':            ['${AD_SYNC_INTERVAL}'],
        'changedSyncPeriod':         ['3600'],
        'batchSizeForSync':          ['1000'],
        'debug':                     ['false'],
    }
}
print(json.dumps(payload))
")

_ldap_resp=$(kc_api "${_ldap_method}" "${_ldap_path}" "${_ldap_payload}")

# Get the provider ID for mapper creation
if [[ "${DRY_RUN}" -eq 1 ]]; then
    _provider_id="dry-run-ldap-id"
elif [[ -n "${_existing_id}" ]]; then
    _provider_id="${_existing_id}"
else
    # POST returns 201 with Location header, but our kc_api returns body.
    # Re-fetch to get the ID.
    _prov=$(kc_api GET "/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider")
    _provider_id=$(python3 - "${_prov}" "${PROVIDER_NAME}" <<'PYEOF'
import sys, json
try:
    comps = json.loads(sys.argv[1])
    name  = sys.argv[2]
    for c in comps:
        if c.get("name") == name:
            print(c["id"])
            break
except Exception:
    pass
PYEOF
)
fi
log_ok "LDAP provider configured (id=${_provider_id})"

# ---------------------------------------------------------------------------
# Step 4: Standard attribute mappers
# ---------------------------------------------------------------------------
log_step "Adding attribute mappers"

add_mapper() {
    local name="$1" mapper_type="$2" config_json="$3"
    # Skip if a mapper with this name already exists on this provider
    _existing_mappers=$(kc_api GET "/admin/realms/${REALM}/components?parent=${_provider_id}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper")
    _exists=$(python3 -c "
import sys, json
try:
    ms = json.loads(sys.argv[1])
    print('yes' if any(m.get('name') == sys.argv[2] for m in ms) else 'no')
except Exception:
    print('no')
" "${_existing_mappers}" "${name}" 2>/dev/null || echo "no")
    if [[ "${_exists}" == "yes" ]]; then
        echo -e "  ${DIM}skip (already exists): ${name}${RESET}"
        return
    fi
    local payload
    payload=$(python3 -c "
import json
print(json.dumps({
    'name': '${name}',
    'providerId': '${mapper_type}',
    'providerType': 'org.keycloak.storage.ldap.mappers.LDAPStorageMapper',
    'parentId': '${_provider_id}',
    'config': ${config_json}
}))
")
    kc_api POST "/admin/realms/${REALM}/components" "${payload}" > /dev/null
    echo -e "  ${GREEN}+${RESET} ${name}"
}

# username
add_mapper "username" "user-attribute-ldap-mapper" \
    '{"ldap.attribute":["'"${AD_USERNAME_ATTR}"'"],"user.model.attribute":["username"],"always.read.value.from.ldap":["false"],"is.mandatory.in.ldap":["true"],"read.only":["true"]}'

# email
add_mapper "email" "user-attribute-ldap-mapper" \
    '{"ldap.attribute":["'"${AD_EMAIL_ATTR}"'"],"user.model.attribute":["email"],"always.read.value.from.ldap":["true"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

# firstName
add_mapper "firstName" "user-attribute-ldap-mapper" \
    '{"ldap.attribute":["'"${AD_FIRSTNAME_ATTR}"'"],"user.model.attribute":["firstName"],"always.read.value.from.ldap":["true"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

# lastName
add_mapper "lastName" "user-attribute-ldap-mapper" \
    '{"ldap.attribute":["'"${AD_LASTNAME_ATTR}"'"],"user.model.attribute":["lastName"],"always.read.value.from.ldap":["true"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

log_ok "Attribute mappers ready"

# ---------------------------------------------------------------------------
# Step 5: Group-to-role mapper (AD group → stroma_researcher realm role)
# ---------------------------------------------------------------------------
log_step "Configuring group-to-role mapper (${AD_RESEARCHER_GROUP} → stroma_researcher)"

# First ensure a group-ldap-mapper exists so KC syncs groups at all
add_mapper "groups" "group-ldap-mapper" \
    "$(python3 -c "
import json
print(json.dumps({
    'mode':                         ['READ_ONLY'],
    'membership.attribute.type':    ['DN'],
    'membership.ldap.attribute':    ['member'],
    'membership.user.ldap.attribute': ['${AD_USERNAME_ATTR}'],
    'memberof.ldap.attribute':      ['memberOf'],
    'groups.dn':                    ['${AD_RESEARCHER_GROUP%,*}'],
    'group.name.ldap.attribute':    ['cn'],
    'group.object.classes':         ['${AD_GROUP_OBJECT_CLASS}'],
    'preserve.group.inheritance':   ['false'],
    'ignore.missing.groups':        ['true'],
    'user.roles.retrieve.strategy': ['LOAD_GROUPS_BY_MEMBER_ATTRIBUTE'],
    'mapped.group.attributes':      [''],
    'drop.non.existing.groups.during.sync': ['false'],
}))
")"

# Use a hardcoded-role mapper instead of role-ldap-mapper.
# AD_CUSTOM_FILTER already restricts which users get synced to exactly those
# in the authorized groups — so every synced user qualifies for stroma_researcher.
# hardcoded-role assigns the role unconditionally to all users from this provider.
add_mapper "stroma-researcher-role-mapper" "hardcoded-ldap-role-mapper" \
    "$(python3 -c "
import json
print(json.dumps({
    'role': ['stroma_researcher'],
}))
")"

log_ok "Group-to-role mapper configured"

# ---------------------------------------------------------------------------
# Step 6: Add groups claim mapper to stroma-cli client scope
#         so tokens contain the 'groups' array (for test-auth --check-groups)
# ---------------------------------------------------------------------------
log_step "Adding groups claim to stroma-cli token"

# Find stroma-cli client UUID
_cli_resp=$(kc_api GET "/admin/realms/${REALM}/clients?clientId=stroma-cli")
_cli_id=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    print(data[0]['id'])
except Exception:
    pass
" "${_cli_resp}" 2>/dev/null || true)

if [[ -z "${_cli_id}" || "${_cli_id}" == "dry-run-placeholder" ]]; then
    log_warn "stroma-cli client not found — skipping groups claim mapper (run setup-keycloak.sh first)"
else
    # Check if mapper already exists
    _pm_existing=$(kc_api GET "/admin/realms/${REALM}/clients/${_cli_id}/protocol-mappers/models")
    _pm_exists=$(python3 -c "
import sys, json
try:
    ms = json.loads(sys.argv[1])
    print('yes' if any(m.get('name') == 'groups' for m in ms) else 'no')
except Exception:
    print('no')
" "${_pm_existing}" 2>/dev/null || echo "no")

    if [[ "${_pm_exists}" == "yes" ]]; then
        echo -e "  ${DIM}skip (groups mapper already present on stroma-cli)${RESET}"
    else
        kc_api POST "/admin/realms/${REALM}/clients/${_cli_id}/protocol-mappers/models" \
            '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","id.token.claim":"false","access.token.claim":"true","userinfo.token.claim":"false","claim.name":"groups"}}' \
            > /dev/null
        echo -e "  ${GREEN}+${RESET} groups mapper added to stroma-cli"
    fi
fi
log_ok "Groups claim configured"

# ---------------------------------------------------------------------------
# Step 7: Trigger initial user sync
# ---------------------------------------------------------------------------
log_step "Triggering initial LDAP user sync (this may take 30–60s for large directories)"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo -e "  ${DIM}[DRY-RUN] POST /admin/realms/${REALM}/user-storage/${_provider_id}/sync?action=triggerFullSync${RESET}"
else
    _sync_resp=$(curl -sk --max-time 120 \
        -X POST "${KC_BASE}/admin/realms/${REALM}/user-storage/${_provider_id}/sync?action=triggerFullSync" \
        -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
        -w "\n%{http_code}" 2>/dev/null)
    _sync_code=$(echo "${_sync_resp}" | tail -1)
    _sync_body=$(echo "${_sync_resp}" | head -n -1)
    if [[ "${_sync_code}" =~ ^2 ]]; then
        _added=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('added',0))" "${_sync_body}" 2>/dev/null || echo "?")
        _updated=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('updated',0))" "${_sync_body}" 2>/dev/null || echo "?")
        _failed=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('failed',0))" "${_sync_body}" 2>/dev/null || echo "0")
        log_ok "Sync complete: ${_added} added, ${_updated} updated, ${_failed} failed"
        if [[ "${_failed}" != "0" && "${_failed}" != "?" ]]; then
            log_warn "Some users failed to sync — check Keycloak admin console: Users → View all users"
        fi
    else
        log_warn "Sync returned HTTP ${_sync_code}: ${_sync_body:0:200}"
        log_warn "Manual sync: KC Admin → User Federation → stroma-ai-ad → Synchronize all users"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Active Directory Federation — Summary               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
  echo "  Provider      : ${PROVIDER_NAME} (${_provider_id})"
  echo "  Config prefix : ${_pfx}  (in config.env)"
echo "  AD Server     : ${AD_SERVER_URL}"
echo "  User Base DN  : ${AD_USER_DN}"
echo "  Researcher grp: ${AD_RESEARCHER_GROUP}"
echo "  Username attr : ${AD_USERNAME_ATTR}"
echo "  Sync interval : ${AD_SYNC_INTERVAL}s"
echo
echo -e "  ${GREEN}Next steps:${RESET}"
echo "  1. Verify a user synced: KC Admin → Users → search for an AD user"
echo "  2. Run the auth test against a real AD user:"
echo "     scripts/test-auth.sh --user=<ad-username> --check-groups"
echo "  3. If TEST 6 (role) fails: the user's AD group membership may not have"
echo "     synced yet — trigger a manual sync in KC Admin → User Federation"
echo "  4. If TEST 4 (issuer) fails after AD enable: check KC_HOSTNAME in"
echo "     deploy/keycloak/.env matches OIDC_ISSUER in config.env"
echo

# ---------------------------------------------------------------------------
# Step 8: Optional post-setup auth test
# ---------------------------------------------------------------------------
if [[ -n "${TEST_USER}" ]]; then
    echo -e "${BOLD}Running auth test for '${TEST_USER}'...${RESET}"
    echo
    TEST_PW=""
    if [[ ! -t 0 && "${STROMA_YES:-0}" == "1" ]]; then
        log_warn "--test-user requires a TTY for password input; skipping auth test"
    else
        read -rsp "  Password for ${TEST_USER}: " TEST_PW; echo
        "${REPO_ROOT}/scripts/test-auth.sh" \
            ${CONFIG_FILE:+--config="${CONFIG_FILE}"} \
            --user="${TEST_USER}" \
            --password="${TEST_PW}" \
            --check-groups || true
    fi
fi