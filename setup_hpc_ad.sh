#!/usr/bin/env bash
# =============================================================================
# HPC Keycloak — Active Directory / LDAP Federation Setup
# =============================================================================
# Configures Keycloak to federate users from Moffitt's Active Directory into
# the hpc-infrastructure realm. Run AFTER new_configure_hpc.sh.
#
# What this script does:
#   1. Reads AD connection parameters from config.env (or prompts for missing)
#   2. Sets up LDAPS truststore (imports AD certificate chain via keytool)
#   3. Creates/updates the LDAP user-storage provider in KC
#   4. Adds standard attribute mappers (username, email, first/last name)
#   5. Adds POSIX attribute mappers (uidNumber, gidNumber/UPG, homeDirectory, loginShell)
#   6. Adds a group LDAP mapper (syncs AD groups)
#   7. Adds a hardcoded-role mapper  (all synced users → hpc-user realm role)
#   8. Adds a groups claim mapper to hpc-cli (for test --check-groups)
#   9. Triggers initial full user sync
#   10. Optionally runs test_hpc_auth.sh to validate
#
# Usage:
#   ./setup_hpc_ad.sh                          # interactive wizard
#   ./setup_hpc_ad.sh --yes                    # non-interactive (config.env must be complete)
#   ./setup_hpc_ad.sh --test-user=jsmith       # run auth test after sync
#   ./setup_hpc_ad.sh --dry-run --yes
#   ./setup_hpc_ad.sh --config=/path/to/config.env
#   ./setup_hpc_ad.sh --provider-name=moffitt-ad2   # second domain
#   ./setup_hpc_ad.sh --help
#
# Options:
#   --config=FILE          Path to config.env (default: ./config.env)
#   --kc=HOST:PORT         Keycloak host:port (default: from config.env)
#   --realm=REALM          Keycloak realm (default: from config.env)
#   --provider-name=NAME   LDAP provider name (default: moffitt-ad)
#   --test-user=USER       Run test_hpc_auth.sh --check-groups after sync
#   --dry-run              Print API payloads without calling Keycloak
#   --yes                  Non-interactive (fail if required values missing)
#   -h | --help            Show this message
#
# Exit codes:
#   0  Success
#   1  Fatal error or missing required input
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
KC_OVERRIDE=""
REALM_OVERRIDE=""
PROVIDER_NAME="moffitt-ad"
TEST_USER=""
DRY_RUN=0
YES=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)         CONFIG_FILE="${_arg#--config=}" ;;
        --kc=*)             KC_OVERRIDE="${_arg#--kc=}" ;;
        --realm=*)          REALM_OVERRIDE="${_arg#--realm=}" ;;
        --provider-name=*)  PROVIDER_NAME="${_arg#--provider-name=}" ;;
        --test-user=*)      TEST_USER="${_arg#--test-user=}" ;;
        --dry-run)          DRY_RUN=1 ;;
        --yes)              YES=1 ;;
        -h|--help)
            sed -n '/^# ===.*$/,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -70
            exit 0
            ;;
        *) die "Unknown argument: ${_arg}. Use --help." ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
write_env_var() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
    else
        echo "${key}=${value}" >> "${file}"
    fi
}

prompt_if_empty() {
    local var_name="$1" prompt_text="$2" default="${3:-}"
    local current="${!var_name:-}"
    if [[ -n "${current}" ]]; then
        log_info "${var_name}: ${current}"
        return
    fi
    if [[ "${YES}" -eq 1 ]]; then
        [[ -n "${default}" ]] && { declare -g "${var_name}=${default}"; return; }
        die "${var_name} is required but not set (use --yes only when config.env is complete)"
    fi
    local input
    if [[ -n "${default}" ]]; then
        read -rp "  ${prompt_text} [${default}]: " input
        declare -g "${var_name}=${input:-${default}}"
    else
        read -rp "  ${prompt_text}: " input
        [[ -n "${input}" ]] || die "${var_name} is required"
        declare -g "${var_name}=${input}"
    fi
}

prompt_secret() {
    local var_name="$1" prompt_text="$2"
    local current="${!var_name:-}"
    if [[ -n "${current}" && "${current}" != "XXXXXX" ]]; then
        log_info "${var_name}: [set]"
        return
    fi
    [[ "${YES}" -eq 1 ]] && die "${var_name} must be set in config.env before using --yes"
    local input
    read -rsp "  ${prompt_text}: " input
    echo
    [[ -n "${input}" ]] || die "${var_name} is required"
    declare -g "${var_name}=${input}"
}

# ---------------------------------------------------------------------------
# Load config.env
# ---------------------------------------------------------------------------
[[ -f "${CONFIG_FILE}" ]] || die "Config not found: ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Apply overrides
[[ -n "${REALM_OVERRIDE}" ]] && REALM_NAME="${REALM_OVERRIDE}"
REALM_NAME="${REALM_NAME:-hpc-infrastructure}"

# ---------------------------------------------------------------------------
# Resolve KC host:port
# ---------------------------------------------------------------------------
if [[ -n "${KC_OVERRIDE}" ]]; then
    _kc="${KC_OVERRIDE}"
else
    _kc="${KC_HOST:-localhost}:${KC_PORT:-8080}"
fi
KC_BASE="http://${_kc}"

KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD not set in config.env}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v python3 &>/dev/null || die "python3 is required"
command -v curl    &>/dev/null || die "curl is required"
command -v openssl &>/dev/null || die "openssl is required (for LDAPS cert fetch)"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Keycloak HPC — Active Directory Federation          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "Provider:    ${PROVIDER_NAME}"
log_info "KC:          ${KC_BASE}"
log_info "Realm:       ${REALM_NAME}"
[[ "${DRY_RUN}" -eq 1 ]] && log_warn "DRY-RUN mode — no changes to Keycloak"
echo

# ---------------------------------------------------------------------------
# Step 1: Gather AD parameters
# ---------------------------------------------------------------------------
log_step "Step 1: AD Connection Parameters"
echo -e "  ${DIM}(Values from config.env are shown; press Enter to keep, or type new value)${RESET}"
echo

prompt_if_empty AD_SERVER_URL    "AD server URL(s) space-separated (ldaps://ad.example.org)"
prompt_secret   AD_BIND_PASSWORD "Service account password"
prompt_if_empty AD_BIND_DN       "Service account DN (user@domain.com or CN=svc,...)"
prompt_if_empty AD_USER_DN       "User search base DN (OU=Users,DC=...)"
prompt_if_empty AD_CUSTOM_FILTER "Custom LDAP filter (leave empty for none)" ""
prompt_if_empty AD_RESEARCHER_GROUP \
    "AD group DN for HPC users (CN=HPC Users,OU=DLs,...)" ""

echo
log_step "Step 2: Optional attribute tuning (Enter = keep current/default)"
echo

prompt_if_empty AD_USER_OBJECT_CLASS  "User object class"         "user"
prompt_if_empty AD_UUID_ATTR          "UUID attribute"            "objectGUID"
prompt_if_empty AD_USERNAME_ATTR      "Username attribute"        "sAMAccountName"
prompt_if_empty AD_FIRSTNAME_ATTR     "First name attribute"      "givenName"
prompt_if_empty AD_LASTNAME_ATTR      "Last name attribute"       "sn"
prompt_if_empty AD_EMAIL_ATTR         "Email attribute"           "mail"
prompt_if_empty AD_GROUP_OBJECT_CLASS "Group object class"        "group"
prompt_if_empty AD_SYNC_INTERVAL      "Full sync interval (s, 0=manual)" "86400"
echo

# ---------------------------------------------------------------------------
# Step 3: Persist AD parameters to config.env
# ---------------------------------------------------------------------------
log_step "Step 3: Saving AD config to ${CONFIG_FILE}"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    for _pair in \
        "AD_SERVER_URL:${AD_SERVER_URL}" \
        "AD_BIND_DN:${AD_BIND_DN}" \
        "AD_USER_DN:${AD_USER_DN}" \
        "AD_RESEARCHER_GROUP:${AD_RESEARCHER_GROUP:-}" \
        "AD_USER_OBJECT_CLASS:${AD_USER_OBJECT_CLASS}" \
        "AD_UUID_ATTR:${AD_UUID_ATTR}" \
        "AD_USERNAME_ATTR:${AD_USERNAME_ATTR}" \
        "AD_FIRSTNAME_ATTR:${AD_FIRSTNAME_ATTR}" \
        "AD_LASTNAME_ATTR:${AD_LASTNAME_ATTR}" \
        "AD_EMAIL_ATTR:${AD_EMAIL_ATTR}" \
        "AD_GROUP_OBJECT_CLASS:${AD_GROUP_OBJECT_CLASS}" \
        "AD_SYNC_INTERVAL:${AD_SYNC_INTERVAL}"
    do
        _key="${_pair%%:*}"
        _val="${_pair#*:}"
        write_env_var "${_key}" "'${_val}'" "${CONFIG_FILE}"
    done
    # Write password separately (already in config.env format)
    write_env_var "AD_BIND_PASSWORD" "'${AD_BIND_PASSWORD}'" "${CONFIG_FILE}"
    log_ok "AD configuration persisted"
else
    log_info "[DRY-RUN] Would update AD_* variables in ${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 4: LDAPS truststore setup (PEM bundle — no password required)
# Keycloak 26.x/Quarkus reads PEM files directly via truststore-paths.
# ---------------------------------------------------------------------------
log_step "Step 4: LDAPS truststore"

KC_INSTALL_DIR="${KC_INSTALL_DIR:-/opt/keycloak}"
KC_LDAP_TRUSTSTORE_PEM="${KC_LDAP_TRUSTSTORE_PEM:-${KC_INSTALL_DIR}/conf/ldap-ad-ca.pem}"

if echo "${AD_SERVER_URL}" | grep -qi "ldaps://"; then
    log_info "Truststore: ${KC_LDAP_TRUSTSTORE_PEM}"

    # Take the first LDAPS URL from a space-separated list
    _first_url=$(echo "${AD_SERVER_URL}" | awk '{print $1}')
    _ad_host=$(echo "${_first_url}" | sed 's|ldaps://||;s|/.*||;s|:.*||')
    _ad_port=$(echo "${_first_url}" | grep -oP ':\K[0-9]+$' || echo "636")
    _ad_port="${_ad_port:-636}"

    log_info "Fetching cert chain from ${_ad_host}:${_ad_port} ..."

    if [[ "${DRY_RUN}" -eq 0 ]]; then
        mkdir -p "$(dirname "${KC_LDAP_TRUSTSTORE_PEM}")"

        # Fetch full cert chain and save as PEM bundle (no password, no JKS)
        openssl s_client -connect "${_ad_host}:${_ad_port}" \
            -showcerts -verify_quiet -verify_return_error \
            </dev/null 2>/dev/null \
            | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
            > "${KC_LDAP_TRUSTSTORE_PEM}" || true

        if [[ ! -s "${KC_LDAP_TRUSTSTORE_PEM}" ]]; then
            die "Could not fetch cert chain from ${_ad_host}:${_ad_port}. Check connectivity: openssl s_client -connect ${_ad_host}:${_ad_port}"
        fi

        _cert_count=$(grep -c 'BEGIN CERTIFICATE' "${KC_LDAP_TRUSTSTORE_PEM}" || true)
        log_ok "Fetched ${_cert_count} certificate(s) → ${KC_LDAP_TRUSTSTORE_PEM}"
        chown keycloak:keycloak "${KC_LDAP_TRUSTSTORE_PEM}" 2>/dev/null || true
        chmod 640 "${KC_LDAP_TRUSTSTORE_PEM}" 2>/dev/null || true

        # Update keycloak.conf: add or replace truststore-paths with PEM path
        KC_CONF="${KC_INSTALL_DIR}/conf/keycloak.conf"
        if [[ -f "${KC_CONF}" ]]; then
            if grep -q "^truststore-paths=" "${KC_CONF}"; then
                # Replace existing entry (may point to old JKS — update to PEM)
                sed -i "s|^truststore-paths=.*|truststore-paths=${KC_LDAP_TRUSTSTORE_PEM}|" "${KC_CONF}"
                log_ok "truststore-paths updated in keycloak.conf"
            else
                printf '\n# LDAPS truststore (PEM bundle)\ntruststore-paths=%s\n' \
                    "${KC_LDAP_TRUSTSTORE_PEM}" >> "${KC_CONF}"
                log_ok "truststore-paths added to keycloak.conf"
            fi
            log_info "Restarting Keycloak to apply truststore config ..."
            systemctl restart keycloak 2>/dev/null || true
            # Poll until KC is healthy (up to 120 s)
            _kc_health_url="http://${KC_HOST:-localhost}:${KC_PORT:-8080}/realms/master"
            log_info "Waiting for Keycloak to become ready at ${_kc_health_url} ..."
            _waited=0
            until curl -sf "${_kc_health_url}" -o /dev/null 2>/dev/null; do
                if [[ ${_waited} -ge 120 ]]; then
                    die "Keycloak did not become ready within 120 s after restart (check: journalctl -u keycloak -n 50)"
                fi
                sleep 3
                (( _waited += 3 ))
            done
            log_ok "Keycloak ready (${_waited}s)"
        fi
        write_env_var "KC_LDAP_TRUSTSTORE_PEM" "${KC_LDAP_TRUSTSTORE_PEM}" "${CONFIG_FILE}"
    else
        log_info "[DRY-RUN] Would fetch certs from ${_ad_host}:${_ad_port} → ${KC_LDAP_TRUSTSTORE_PEM}"
        log_info "[DRY-RUN] Would update truststore-paths in keycloak.conf"
    fi
else
    log_warn "AD_SERVER_URL uses ldap:// (plaintext) — skipping truststore setup"
    log_warn "Use ldaps:// in production for encrypted LDAP connections"
fi

# ---------------------------------------------------------------------------
# Step 5: Obtain KC admin token & configure LDAP provider
# ---------------------------------------------------------------------------
log_step "Step 5: Configuring LDAP user-storage provider via REST API"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] Would configure LDAP provider '${PROVIDER_NAME}' in realm '${REALM_NAME}'"
    log_info "[DRY-RUN] Would add attribute mappers, role mapper, and trigger sync"
else
    python3 - \
        "${KC_BASE}" \
        "${KC_ADMIN_USER}" \
        "${KC_ADMIN_PASSWORD}" \
        "${REALM_NAME}" \
        "${PROVIDER_NAME}" \
        "${AD_SERVER_URL}" \
        "${AD_BIND_DN}" \
        "${AD_BIND_PASSWORD}" \
        "${AD_USER_DN}" \
        "${AD_CUSTOM_FILTER:-}" \
        "${AD_USER_OBJECT_CLASS:-user}" \
        "${AD_UUID_ATTR:-objectGUID}" \
        "${AD_USERNAME_ATTR:-sAMAccountName}" \
        "${AD_FIRSTNAME_ATTR:-givenName}" \
        "${AD_LASTNAME_ATTR:-sn}" \
        "${AD_EMAIL_ATTR:-mail}" \
        "${AD_GROUP_OBJECT_CLASS:-group}" \
        "${AD_SYNC_INTERVAL:-86400}" \
        <<'PYEOF'
import sys, json, time
import urllib.request as urlreq
import urllib.parse as urlparse
import urllib.error as urlerr

kc_url        = sys.argv[1]
admin_u       = sys.argv[2]
admin_p       = sys.argv[3]
realm         = sys.argv[4]
provider_name = sys.argv[5]
ad_urls       = sys.argv[6].split()   # space-separated list → list
bind_dn       = sys.argv[7]
bind_pw       = sys.argv[8]
user_dn       = sys.argv[9]
custom_filter = sys.argv[10]
user_obj_cls  = sys.argv[11]
uuid_attr     = sys.argv[12]
username_attr = sys.argv[13]
first_attr    = sys.argv[14]
last_attr     = sys.argv[15]
email_attr    = sys.argv[16]
group_obj_cls = sys.argv[17]
sync_interval = sys.argv[18]

# Build comma-separated connection URL list for KC (it accepts space-sep too,
# but we normalise to the first URL here; KC >= 21 supports multiple via
# connectionUrl with space separator directly)
connection_url = ad_urls[0]

# ---------- HTTP helper ----------
def _http(method, path, data=None, token=None, form=False, ignore404=False):
    url = kc_url + path
    body = ctype = None
    if form and data:
        body  = urlparse.urlencode(data).encode()
        ctype = 'application/x-www-form-urlencoded'
    elif data is not None:
        body  = json.dumps(data).encode()
        ctype = 'application/json'
    hdrs = {}
    if ctype:  hdrs['Content-Type']  = ctype
    if token:  hdrs['Authorization'] = 'Bearer ' + token
    req = urlreq.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urlreq.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urlerr.HTTPError as e:
        if ignore404 and e.code == 404:
            return 404, None
        raw = e.read()
        return e.code, (json.loads(raw) if raw.strip() else None)

def get_token(retries=24, interval=5):
    for _ in range(retries):
        st, body = _http('POST', '/realms/master/protocol/openid-connect/token',
                         {'grant_type': 'password', 'client_id': 'admin-cli',
                          'username': admin_u, 'password': admin_p}, form=True)
        if st == 200 and body and body.get('access_token'):
            return body['access_token']
        sys.stdout.write('.')
        sys.stdout.flush()
        time.sleep(interval)
    raise SystemExit('\nERROR: KC admin API unreachable')

sys.stdout.write('[AD] Connecting to KC admin API ')
sys.stdout.flush()
token = get_token()
print(' OK')

# ---------- Pre-flight: Test LDAP connection & bind ----------
print('[AD] Testing LDAP connection ...')
_test_base = {
    'connectionUrl':     connection_url,
    'bindDn':            bind_dn,
    'bindCredential':    bind_pw,
    'useTruststoreSpi':  'always',
    'connectionTimeout': '5000',
    'startTls':          'false',
}
st_c, resp_c = _http('POST', f'/admin/realms/{realm}/testLDAPConnection',
                     {**_test_base, 'action': 'testConnection'}, token=token)
if st_c == 204:
    print('[AD]   Connection OK')
    st_a, resp_a = _http('POST', f'/admin/realms/{realm}/testLDAPConnection',
                         {**_test_base, 'action': 'testAuthentication'}, token=token)
    if st_a == 204:
        print('[AD]   Bind (authentication) OK')
    else:
        _err = (resp_a or {}).get('errorMessage', str(resp_a))
        raise SystemExit(
            f'ERROR: LDAP bind test failed (HTTP {st_a}): {_err}\n'
            f'       Check AD_BIND_DN and AD_BIND_PASSWORD in config.env.\n'
            f'       Bind DN used: {bind_dn}'
        )
elif st_c == 400:
    _err = (resp_c or {}).get('errorMessage', str(resp_c))
    raise SystemExit(
        f'ERROR: LDAP connection test failed (HTTP {st_c}): {_err}\n'
        f'       Connection URL: {connection_url}\n'
        f'       Checklist:\n'
        f'         1. Network/firewall: nc -zv {connection_url.split("//")[-1]} 636\n'
        f'         2. Cert chain:       openssl s_client -connect {connection_url.split("//")[-1]}:636\n'
        f'         3. KC truststore:    grep truststore-paths /opt/keycloak/conf/keycloak.conf\n'
        f'         4. KC logs:          journalctl -u keycloak -n 80 --no-pager | grep -i ldap'
    )
else:
    print(f'[AD]   WARN: testLDAPConnection returned HTTP {st_c} — continuing anyway')

# ---------- Resolve realm UUID (required as parentId in KC 26.x) ----------
# KC 26.x sync endpoint resolves the provider by realm UUID internally.
# Using the realm name string as parentId causes silent HTTP 400 on sync.
st_r, realm_rep = _http('GET', f'/admin/realms/{realm}', token=token)
if st_r != 200 or not realm_rep:
    raise SystemExit(
        f'ERROR: realm {realm!r} not found (HTTP {st_r}).\n'
        f'       Run new_configure_hpc.sh first to create the realm.'
    )
realm_uuid = realm_rep.get('id', realm)
print(f'[AD] Realm UUID: {realm_uuid}')

# ---------- Create or update LDAP user-storage provider ----------
# Note: the ?type= query filter is unreliable in KC 26.x — fetch all
# components and filter by name + providerId in Python.
st, comps = _http('GET', f'/admin/realms/{realm}/components', token=token)
existing_id = next(
    (c['id'] for c in (comps or [])
     if c.get('name') == provider_name and c.get('providerId') == 'ldap'), None)

use_tls = connection_url.lower().startswith('ldaps')

ldap_payload = {
    'name': provider_name,
    'providerId': 'ldap',
    'providerType': 'org.keycloak.storage.UserStorageProvider',
    'parentId': realm_uuid,   # must be UUID, not realm name, for sync to work in KC 26.x
    'config': {
        'vendor':                    ['ad'],
        'connectionUrl':             [connection_url],
        'usersDn':                   [user_dn],
        'bindDn':                    [bind_dn],
        'bindCredential':            [bind_pw],
        'usernameLDAPAttribute':     [username_attr],
        'rdnLDAPAttribute':          ['cn'],
        'uuidLDAPAttribute':         [uuid_attr],
        'userObjectClasses':         [user_obj_cls],
        'searchScope':               ['2'],    # SUBTREE
        'editMode':                  ['READ_ONLY'],
        'importEnabled':             ['true'],
        'syncRegistrations':         ['false'],
        'referralMode':              ['IGNORE'],
        'useTruststoreSpi':          ['always'],
        'pagination':                ['true'],
        'batchSizeForSync':          ['1000'],
        'fullSyncPeriod':            [sync_interval],
        'changedSyncPeriod':         ['-1'],
        'validatePasswordPolicy':    ['false'],
        'trustEmail':                ['false'],
        'allowKerberosAuthentication': ['false'],
    }
}
# Add custom LDAP filter if provided
if custom_filter.strip():
    ldap_payload['config']['customUserSearchFilter'] = [custom_filter.strip()]

if existing_id:
    # Delete the existing provider so it is recreated clean.
    # A provider in an error state (e.g. wrong parentId from a previous run)
    # will keep failing sync even after a PUT update.
    # All mappers are recreated by the steps below, so nothing is lost.
    print(f'[AD] Removing existing provider (id={existing_id}) for clean recreation ...')
    _http('DELETE', f'/admin/realms/{realm}/components/{existing_id}', token=token)
    existing_id = None

if not existing_id:
    st, _ = _http('POST', f'/admin/realms/{realm}/components', ldap_payload, token=token)
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create LDAP provider: HTTP {st}')
    st, comps = _http('GET', f'/admin/realms/{realm}/components', token=token)
    provider_id = next(
        (c['id'] for c in (comps or [])
         if c.get('name') == provider_name and c.get('providerId') == 'ldap'), None)
    if not provider_id:
        seen = [(c.get('name'), c.get('providerId')) for c in (comps or [])]
        raise SystemExit(
            f'ERROR: LDAP provider {provider_name!r} not found after creation.\n'
            f'       GET /components returned HTTP {st}, {len(comps or [])} component(s).\n'
            f'       (name, providerId) seen: {seen}\n'
            f'       Check KC logs: journalctl -u keycloak -n 50'
        )
    print(f'[AD] LDAP provider created (id={provider_id})')

# ---------- Helper: add/update mapper ----------
def add_mapper(name, mapper_type, config_dict):
    st, existing = _http('GET',
        f'/admin/realms/{realm}/components?parent={provider_id}'
        f'&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper',
        token=token)
    existing_mapper = next((m for m in (existing or []) if m.get('name') == name), None)
    payload = {
        'name': name,
        'providerId': mapper_type,
        'providerType': 'org.keycloak.storage.ldap.mappers.LDAPStorageMapper',
        'parentId': provider_id,
        'config': config_dict,
    }
    if existing_mapper:
        payload['id'] = existing_mapper['id']
        _http('PUT', f'/admin/realms/{realm}/components/{existing_mapper["id"]}',
              payload, token=token)
        print(f'[AD]   Mapper updated: {name}')
    else:
        st2, _ = _http('POST', f'/admin/realms/{realm}/components', payload, token=token)
        if st2 in (201, 409):
            print(f'[AD]   Mapper created: {name}')
        else:
            print(f'[AD]   WARN: mapper {name}: HTTP {st2}')

# ---------- Step 5a: Standard identity attribute mappers ----------
print('[AD] Adding standard attribute mappers ...')

add_mapper('username', 'user-attribute-ldap-mapper', {
    'ldap.attribute':            [username_attr],
    'user.model.attribute':      ['username'],
    'is.mandatory.in.ldap':      ['true'],
    'always.read.value.from.ldap': ['true'],
    'read.only':                 ['true'],
})
add_mapper('email', 'user-attribute-ldap-mapper', {
    'ldap.attribute':            [email_attr],
    'user.model.attribute':      ['email'],
    'is.mandatory.in.ldap':      ['false'],
    'always.read.value.from.ldap': ['true'],
    'read.only':                 ['true'],
})
add_mapper('firstName', 'user-attribute-ldap-mapper', {
    'ldap.attribute':            [first_attr],
    'user.model.attribute':      ['firstName'],
    'is.mandatory.in.ldap':      ['false'],
    'always.read.value.from.ldap': ['true'],
    'read.only':                 ['true'],
})
add_mapper('lastName', 'user-attribute-ldap-mapper', {
    'ldap.attribute':            [last_attr],
    'user.model.attribute':      ['lastName'],
    'is.mandatory.in.ldap':      ['false'],
    'always.read.value.from.ldap': ['true'],
    'read.only':                 ['true'],
})

# ---------- Step 5b: POSIX attribute mappers (uidNumber, gidNumber, home, shell) ----------
print('[AD] Adding POSIX attribute mappers ...')

for ldap_attr, model_attr in [
    ('uidNumber',     'uidNumber'),
    ('gidNumber',     'gidNumber'),
    ('homeDirectory', 'homeDirectory'),
    ('loginShell',    'loginShell'),
]:
    add_mapper(f'{ldap_attr}-ldap-mapper', 'user-attribute-ldap-mapper', {
        'ldap.attribute':              [ldap_attr],
        'user.model.attribute':        [model_attr],
        'is.mandatory.in.ldap':        ['false'],
        'always.read.value.from.ldap': ['true'],
        'read.only':                   ['true'],
    })

# ---------- Step 5c: Group LDAP mapper ----------
print('[AD] Adding group LDAP mapper ...')
add_mapper('groups', 'group-ldap-mapper', {
    'mode':                          ['READ_ONLY'],
    'membership.attribute.type':     ['DN'],
    'group.name.ldap.attribute':     ['cn'],
    'group.object.classes':          [group_obj_cls],
    'preserve.group.inheritance':    ['false'],
    'ignore.missing.groups':         ['false'],
    'membership.ldap.attribute':     ['member'],
    'membership.user.ldap.attribute': ['dn'],
    'groups.dn':                     [user_dn.split(',', 1)[1] if ',' in user_dn else user_dn],
    'user.roles.retrieve.strategy':  ['LOAD_GROUPS_BY_MEMBER_ATTRIBUTE'],
    'mapped.group.attributes':       [''],
    'drop.non.existing.groups.during.sync': ['false'],
})

# ---------- Step 5d: Hardcoded role mapper → hpc-user ----------
# All users synced via this LDAP provider get the hpc-user realm role.
# Combined with AD_CUSTOM_FILTER (restricts who syncs), only authorized
# HPC group members end up with hpc-user.
print('[AD] Adding hardcoded role mapper (hpc-user) ...')
add_mapper('hpc-user-role-mapper', 'hardcoded-ldap-role-mapper', {
    'role': ['hpc-user'],
})

print('[AD] All LDAP mappers configured')

# ---------- Step 5e: Add groups claim to hpc-cli client ----------
print('[AD] Adding groups claim mapper to hpc-cli ...')
st, cli_resp = _http('GET', f'/admin/realms/{realm}/clients?clientId=hpc-cli', token=token)
if not cli_resp:
    print('[AD] WARN: hpc-cli client not found — run new_configure_hpc.sh first')
else:
    cli_id = cli_resp[0]['id']
    st, pm_existing = _http('GET',
        f'/admin/realms/{realm}/clients/{cli_id}/protocol-mappers/models', token=token)
    if not any(m.get('name') == 'groups-claim' for m in (pm_existing or [])):
        st, _ = _http('POST',
            f'/admin/realms/{realm}/clients/{cli_id}/protocol-mappers/models', {
                'name': 'groups-claim',
                'protocol': 'openid-connect',
                'protocolMapper': 'oidc-group-membership-mapper',
                'config': {
                    'full.path':           'false',
                    'id.token.claim':      'true',
                    'access.token.claim':  'true',
                    'userinfo.token.claim':'true',
                    'claim.name':          'groups',
                },
            }, token=token)
        print('[AD] groups-claim mapper added to hpc-cli')
    else:
        print('[AD] groups-claim mapper already present on hpc-cli')

# ---------- Step 5f: Trigger initial sync ----------
print('[AD] Triggering initial full user sync ...')
st, sync_resp = _http('POST',
    f'/admin/realms/{realm}/user-storage/{provider_id}/sync?action=triggerFullSync',
    token=token)
if st in (200, 201):
    added   = (sync_resp or {}).get('added', '?')
    updated = (sync_resp or {}).get('updated', '?')
    removed = (sync_resp or {}).get('removed', '?')
    failed  = (sync_resp or {}).get('failed', 0)
    print(f'[AD] Sync complete: added={added}  updated={updated}  removed={removed}  failed={failed}')
    if failed and int(str(failed)) > 0:
        print(f'[AD] WARN: {failed} users failed to sync — check KC logs for details')
else:
    print(f'[AD] WARN: Sync returned HTTP {st} — check KC logs')
    if sync_resp:
        print(f'[AD]       Response: {json.dumps(sync_resp)[:300]}')
    print(f'[AD]       Run: journalctl -u keycloak -n 80 --no-pager | grep -iE "ldap|sync|error"')

print('')
print('[AD] ═══════════════════════════════════════════════')
print(f'[AD] Active Directory federation complete')
print(f'[AD] Provider: {provider_name}  Realm: {realm}')
print('[AD] ═══════════════════════════════════════════════')
PYEOF

    log_ok "LDAP federation configured"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Active Directory Federation — Summary               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "Provider :  ${PROVIDER_NAME}"
log_info "AD Server:  ${AD_SERVER_URL}"
log_info "User Base:  ${AD_USER_DN}"
log_info "Role map :  All synced users → hpc-user"
echo
echo -e "  ${GREEN}Next steps:${RESET}"
echo "  1. KC Admin → User Federation → ${PROVIDER_NAME} → verify users synced"
echo "  2. KC Admin → Users → search for an AD username to confirm"
echo "  3. Run: ./test_hpc_auth.sh --user=<ad-username> [--check-groups]"
echo "  4. If POSIX attrs missing (uidNumber etc.): verify AD schema has these"
echo "     attributes — uidNumber must be set per-user in AD (RFC 2307 schema)"
echo

# ---------------------------------------------------------------------------
# Optional auth test
# ---------------------------------------------------------------------------
if [[ -n "${TEST_USER}" ]]; then
    TEST_SCRIPT="${SCRIPT_DIR}/test_hpc_auth.sh"
    if [[ -f "${TEST_SCRIPT}" ]]; then
        log_step "Running auth test for user: ${TEST_USER}"
        bash "${TEST_SCRIPT}" \
            --config="${CONFIG_FILE}" \
            --user="${TEST_USER}" \
            --check-groups \
            --check-posix
    else
        log_warn "test_hpc_auth.sh not found — skipping auth test"
    fi
fi
