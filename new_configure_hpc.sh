#!/usr/bin/env bash
# =============================================================================
# HPC Keycloak — Realm Configuration
# =============================================================================
# Configures the hpc-infrastructure realm via the Keycloak admin REST API.
# Run AFTER new_keycloak_setup.sh has Keycloak running and healthy.
#
# Creates / updates (idempotent):
#   • Realm:         hpc-infrastructure
#   • Client scope:  hpc-posix        (uidNumber, gidNumber, homeDirectory, loginShell)
#   • Realm roles:   hpc-user, hpc-admin
#   • Client:        openondemand     (confidential, Authorization Code + PKCE)
#   • Client:        hpc-cli          (public ROPC — for CLI tools & test_hpc_auth.sh)
#   • Mappers:       audience (openondemand), groups claim — both on hpc-cli
#
# Usage:
#   ./new_configure_hpc.sh
#   ./new_configure_hpc.sh --config=/path/to/config.env
#   ./new_configure_hpc.sh --kc=localhost:8080
#   ./new_configure_hpc.sh --reset    # delete and recreate realm (destructive!)
#   ./new_configure_hpc.sh --dry-run
#   ./new_configure_hpc.sh --yes
#   ./new_configure_hpc.sh --help
#
# Options:
#   --config=FILE    Path to config.env (default: ./config.env)
#   --kc=HOST:PORT   Keycloak override (default: from config.env KC_HOST:KC_PORT)
#   --reset          Delete existing realm before configuring (ALL DATA LOST)
#   --dry-run        Print actions without making any API calls
#   --yes            Non-interactive
#   -h | --help      Show this message
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
RESET_REALM=0
DRY_RUN=0
YES=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)  CONFIG_FILE="${_arg#--config=}" ;;
        --kc=*)      KC_OVERRIDE="${_arg#--kc=}" ;;
        --reset)     RESET_REALM=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --yes)       YES=1 ;;
        -h|--help)
            sed -n '/^# ===.*$/,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -55
            exit 0
            ;;
        *) die "Unknown argument: ${_arg}. Use --help." ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Load config.env
# ---------------------------------------------------------------------------
[[ -f "${CONFIG_FILE}" ]] || die "Config not found: ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Resolve KC host:port
# ---------------------------------------------------------------------------
if [[ -n "${KC_OVERRIDE}" ]]; then
    _kc="${KC_OVERRIDE}"
else
    _kc="${KC_HOST:-localhost}:${KC_PORT:-8080}"
fi
KC_BASE_URL="http://${_kc}"

REALM_NAME="${REALM_NAME:-hpc-infrastructure}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD not set in config.env}"
OOD_DOMAIN="${OOD_DOMAIN:-hpc.moffitt.org}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v python3 &>/dev/null || die "python3 is required"
command -v curl    &>/dev/null || die "curl is required"

write_env_var() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        echo "${key}=\"${value}\"" >> "${file}"
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Keycloak HPC — Realm Configuration                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "KC Base URL:  ${KC_BASE_URL}"
log_info "Realm:        ${REALM_NAME}"
log_info "Admin:        ${KC_ADMIN_USER}"
log_info "OOD Domain:   ${OOD_DOMAIN}"
[[ "${DRY_RUN}"    -eq 1 ]] && log_warn "DRY-RUN mode — no changes to Keycloak"
[[ "${RESET_REALM}" -eq 1 ]] && log_warn "--reset: existing realm WILL BE DELETED"
echo

if [[ "${RESET_REALM}" -eq 1 && "${YES}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
    read -rp "  DELETE realm '${REALM_NAME}' and ALL its data? [y/N]: " _ans
    [[ "${_ans}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Generate OOD client secret (reuse if already set)
# ---------------------------------------------------------------------------
OOD_CLIENT_SECRET="${KC_OOD_CLIENT_SECRET:-}"
if [[ -z "${OOD_CLIENT_SECRET}" ]]; then
    OOD_CLIENT_SECRET="$(python3 -c "import secrets; print(secrets.token_hex(32))")"
    log_info "Generated new OOD client secret"
fi

# ---------------------------------------------------------------------------
# DRY-RUN short-circuit
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "Would configure realm '${REALM_NAME}' at ${KC_BASE_URL}"
    log_info "  Roles:   hpc-user, hpc-admin"
    log_info "  Scope:   hpc-posix (uidNumber, gidNumber, homeDirectory, loginShell)"
    log_info "  Clients: openondemand (confidential), hpc-cli (public ROPC)"
    log_info "  Mappers: audience=openondemand, groups claim"
    exit 0
fi

# ---------------------------------------------------------------------------
# Configure realm via admin REST API  (Python3 urllib — no extra dependencies)
# ---------------------------------------------------------------------------
log_step "Configuring Keycloak realm via admin REST API"

python3 - \
    "${KC_BASE_URL}" \
    "${KC_ADMIN_USER}" \
    "${KC_ADMIN_PASSWORD}" \
    "${REALM_NAME}" \
    "${OOD_CLIENT_SECRET}" \
    "${OOD_DOMAIN}" \
    "${RESET_REALM}" \
    <<'PYEOF'
import sys, json, time
import urllib.request as urlreq
import urllib.parse as urlparse
import urllib.error as urlerr

kc_url      = sys.argv[1]
admin_u     = sys.argv[2]
admin_p     = sys.argv[3]
realm       = sys.argv[4]
ood_sec     = sys.argv[5]
ood_domain  = sys.argv[6]
reset_realm = sys.argv[7] == "1"

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

def get_token(retries=30, interval=5):
    for _ in range(retries):
        st, body = _http('POST', '/realms/master/protocol/openid-connect/token',
                         {'grant_type': 'password', 'client_id': 'admin-cli',
                          'username': admin_u, 'password': admin_p}, form=True)
        if st == 200 and body and body.get('access_token'):
            return body['access_token']
        sys.stdout.write('.')
        sys.stdout.flush()
        time.sleep(interval)
    raise SystemExit('\nERROR: KC admin API not reachable — is Keycloak running?')

sys.stdout.write('[KC] Connecting to admin API ')
sys.stdout.flush()
token = get_token()
print(' OK')

if reset_realm:
    st, _ = _http('DELETE', f'/admin/realms/{realm}', token=token, ignore404=True)
    print(f'[KC] Realm {realm!r} deleted (HTTP {st})')
    token = get_token()

st, realms = _http('GET', '/admin/realms', token=token)
realm_exists = st == 200 and any(r.get('realm') == realm for r in (realms or []))

if realm_exists:
    print(f'[KC] Realm {realm!r} already exists — skipping creation')
else:
    print(f'[KC] Creating realm: {realm}')
    st, resp = _http('POST', '/admin/realms', {
        'id': realm, 'realm': realm, 'enabled': True,
        'displayName': 'HPC Infrastructure',
        'sslRequired': 'external',
        'registrationAllowed': False,
        'loginWithEmailAllowed': True,
        'resetPasswordAllowed': True,
        'bruteForceProtected': True,
        'failureFactor': 5,
        'accessTokenLifespan': 3600,
        'ssoSessionIdleTimeout': 7200,
        'ssoSessionMaxLifespan': 36000,
    }, token=token)
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create realm HTTP {st}: {resp}')
    print(f'[KC] Realm {realm!r} created')

for rname, rdesc in [
    ('hpc-user',  'Baseline compute access — all authorized HPC cluster users.'),
    ('hpc-admin', 'Administrative access to HPC infrastructure management.'),
]:
    st, _ = _http('POST', f'/admin/realms/{realm}/roles',
                  {'name': rname, 'description': rdesc}, token=token)
    status = 'created' if st == 201 else 'already exists' if st == 409 else f'HTTP {st}'
    print(f'[KC] Role {rname}: {status}')
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create role {rname}: HTTP {st}')

_, rr_user = _http('GET', f'/admin/realms/{realm}/roles/hpc-user', token=token)
hpc_user_role = {'id': rr_user['id'], 'name': rr_user['name']}

st, all_scopes = _http('GET', f'/admin/realms/{realm}/client-scopes', token=token)
scope_id = next((s['id'] for s in (all_scopes or []) if s.get('name') == 'hpc-posix'), None)

if not scope_id:
    st, _ = _http('POST', f'/admin/realms/{realm}/client-scopes', {
        'name': 'hpc-posix',
        'description': 'POSIX user attributes for HPC workload identity',
        'protocol': 'openid-connect',
        'attributes': {
            'include.in.token.scope': 'true',
            'display.on.consent.screen': 'false',
        },
    }, token=token)
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create hpc-posix scope: HTTP {st}')
    _, all_scopes = _http('GET', f'/admin/realms/{realm}/client-scopes', token=token)
    scope_id = next(s['id'] for s in all_scopes if s['name'] == 'hpc-posix')
    print('[KC] hpc-posix client scope created')
else:
    print('[KC] hpc-posix scope already exists')

_, existing_pm = _http('GET',
    f'/admin/realms/{realm}/client-scopes/{scope_id}/protocol-mappers/models',
    token=token)
existing_pm_names = {m.get('name') for m in (existing_pm or [])}

for attr, claim, jtype in [
    ('uidNumber',     'uidNumber',     'int'),
    ('gidNumber',     'gidNumber',     'int'),
    ('homeDirectory', 'homeDirectory', 'String'),
    ('loginShell',    'loginShell',    'String'),
]:
    mname = f'{attr}-mapper'
    if mname not in existing_pm_names:
        st, _ = _http('POST',
            f'/admin/realms/{realm}/client-scopes/{scope_id}/protocol-mappers/models', {
                'name': mname,
                'protocol': 'openid-connect',
                'protocolMapper': 'oidc-usermodel-attribute-mapper',
                'config': {
                    'user.attribute':       attr,
                    'claim.name':           claim,
                    'jsonType.label':       jtype,
                    'id.token.claim':       'true',
                    'access.token.claim':   'true',
                    'userinfo.token.claim': 'true',
                },
            }, token=token)
        print(f'[KC]   POSIX mapper: {mname}')
print('[KC] hpc-posix protocol mappers ready')

st, ood_check = _http('GET', f'/admin/realms/{realm}/clients?clientId=openondemand', token=token)
ood_id = ood_check[0]['id'] if ood_check else None

if not ood_id:
    st, _ = _http('POST', f'/admin/realms/{realm}/clients', {
        'clientId': 'openondemand',
        'name': 'Moffitt HPC OpenOnDemand',
        'description': 'Open OnDemand web portal — OIDC Authorization Code with PKCE',
        'enabled': True,
        'protocol': 'openid-connect',
        'publicClient': False,
        'standardFlowEnabled': True,
        'implicitFlowEnabled': False,
        'directAccessGrantsEnabled': False,
        'serviceAccountsEnabled': False,
        'clientAuthenticatorType': 'client-secret',
        'secret': ood_sec,
        'redirectUris': [
            f'https://{ood_domain}/oidc',
            f'https://{ood_domain}/auth/callback',
            f'https://{ood_domain}/*',
        ],
        'webOrigins': [f'https://{ood_domain}'],
        'attributes': {
            'pkce.code.challenge.method': 'S256',
            'access.token.lifespan': '3600',
        },
    }, token=token)
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create openondemand client: HTTP {st}')
    _, ood_check = _http('GET', f'/admin/realms/{realm}/clients?clientId=openondemand', token=token)
    ood_id = ood_check[0]['id']
    print('[KC] openondemand client created')
else:
    print('[KC] openondemand client already exists')

st, _ = _http('PUT',
    f'/admin/realms/{realm}/clients/{ood_id}/default-client-scopes/{scope_id}',
    token=token)
print(f'[KC] hpc-posix scope attached to openondemand (HTTP {st})')

st, cli_check = _http('GET', f'/admin/realms/{realm}/clients?clientId=hpc-cli', token=token)
cli_id = cli_check[0]['id'] if cli_check else None

if not cli_id:
    st, _ = _http('POST', f'/admin/realms/{realm}/clients', {
        'clientId': 'hpc-cli',
        'name': 'HPC CLI / Auth Test',
        'description': 'Public ROPC client for CLI tools and auth testing. No client secret needed.',
        'enabled': True,
        'protocol': 'openid-connect',
        'publicClient': True,
        'standardFlowEnabled': False,
        'implicitFlowEnabled': False,
        'directAccessGrantsEnabled': True,
        'serviceAccountsEnabled': False,
        'redirectUris': [],
        'defaultClientScopes': ['openid', 'profile', 'email'],
        'optionalClientScopes': ['hpc-posix'],
    }, token=token)
    if st not in (201, 409):
        raise SystemExit(f'ERROR: create hpc-cli client: HTTP {st}')
    _, cli_check = _http('GET', f'/admin/realms/{realm}/clients?clientId=hpc-cli', token=token)
    cli_id = cli_check[0]['id']
    print('[KC] hpc-cli client created')
else:
    print('[KC] hpc-cli client already exists')

_, cli_pm = _http('GET',
    f'/admin/realms/{realm}/clients/{cli_id}/protocol-mappers/models', token=token)
cli_pm_names = {m.get('name') for m in (cli_pm or [])}

if 'openondemand-audience' not in cli_pm_names:
    _http('POST',
        f'/admin/realms/{realm}/clients/{cli_id}/protocol-mappers/models', {
            'name': 'openondemand-audience',
            'protocol': 'openid-connect',
            'protocolMapper': 'oidc-audience-mapper',
            'config': {
                'included.client.audience': 'openondemand',
                'id.token.claim':           'false',
                'access.token.claim':       'true',
            },
        }, token=token)
    print('[KC] Audience mapper added to hpc-cli (aud: openondemand)')

if 'groups-claim' not in cli_pm_names:
    _http('POST',
        f'/admin/realms/{realm}/clients/{cli_id}/protocol-mappers/models', {
            'name': 'groups-claim',
            'protocol': 'openid-connect',
            'protocolMapper': 'oidc-group-membership-mapper',
            'config': {
                'full.path':            'false',
                'id.token.claim':       'true',
                'access.token.claim':   'true',
                'userinfo.token.claim': 'true',
                'claim.name':           'groups',
            },
        }, token=token)
    print('[KC] Groups claim mapper added to hpc-cli')

print('')
print('[KC] ══════════════════════════════════════════════════')
print(f'[KC] Realm configuration complete: {realm}')
print(f'[KC] openondemand client secret: {ood_sec}')
print('[KC] ══════════════════════════════════════════════════')
PYEOF

log_ok "Realm configured"

write_env_var "KC_OOD_CLIENT_SECRET" "${OOD_CLIENT_SECRET}" "${CONFIG_FILE}"
log_ok "KC_OOD_CLIENT_SECRET written to ${CONFIG_FILE}"

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Realm Configuration Complete                        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
log_info "Realm        :  ${REALM_NAME}"
log_info "Admin URL    :  ${KC_BASE_URL}/admin/master/console/#/${REALM_NAME}"
log_info "OOD Client   :  openondemand  (secret saved to config.env)"
log_info "CLI Client   :  hpc-cli       (public — no secret)"
echo
echo -e "  ${GREEN}Next steps:${RESET}"
echo "  1. Run: ./setup_hpc_ad.sh       (federate Active Directory)"
echo "  2. Configure OpenOnDemand with:"
echo "       Client ID:     openondemand"
echo "       Client Secret: (KC_OOD_CLIENT_SECRET in config.env)"
echo "       Discovery URL: ${OIDC_DISCOVERY_URL:-https://${KC_FQDN:-kc.hpc.moffitt.org}/realms/${REALM_NAME}/.well-known/openid-configuration}"
echo "  3. Run: ./test_hpc_auth.sh --user=<ad-user>   (validate end-to-end)"
echo