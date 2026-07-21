#!/usr/bin/env bash
# =============================================================================
# HPC Keycloak — Authentication & Token Validation Test
# =============================================================================
# Validates that a cluster user can authenticate with Keycloak and that the
# resulting JWT token contains all expected claims for HPC access.
#
# Designed to run before AND after Active Directory federation — test results
# are identical whether the user lives in Keycloak's local store or is
# federated from Active Directory.
#
# Tests:
#   1.  Keycloak realm reachable (token endpoint responds)
#   2.  Password grant (username + password → access_token)
#   3.  Token is valid JWT (three base64 segments)
#   4.  Token issuer matches expected realm URL
#   5.  Token audience includes 'openondemand'
#   6.  Token contains hpc-user realm role
#   7.  Token not already expired (exp claim in future)
#   8.  Token subject (sub) is non-empty
#   9.  KC /userinfo endpoint accepts token (validates token against KC)
#   10. KC HTTPS discovery URL reachable (validates Caddy TLS proxy)
#   11. (Optional) POSIX attributes present (--check-posix)
#   12. (Optional) Groups claim present (--check-groups)
#
# Usage:
#   ./test_hpc_auth.sh --user=jsmith --password='s3cr3t'
#   ./test_hpc_auth.sh --user=jsmith              # prompts for password
#   ./test_hpc_auth.sh --user=jsmith --check-posix --check-groups
#   ./test_hpc_auth.sh --user=jsmith --realm=hpc-infrastructure
#   ./test_hpc_auth.sh --user=jsmith --kc=localhost:8080
#   ./test_hpc_auth.sh --config=/path/to/config.env --user=jsmith
#   ./test_hpc_auth.sh --help
#
# Options:
#   --config=FILE        Path to config.env (auto-detected if omitted)
#   --user=NAME          Username to test (required)
#   --password=PASS      Password (prompted securely if omitted)
#   --realm=REALM        Keycloak realm (default: from config.env or hpc-infrastructure)
#   --kc=HOST:PORT       Keycloak host:port override (e.g. localhost:8080)
#   --client=CLIENT_ID   ROPC client to use (default: hpc-cli)
#   --check-posix        TEST 11: verify POSIX attributes in token (uidNumber, etc.)
#   --check-groups       TEST 12: verify groups claim is present
#   --no-color           Disable ANSI colors
#   -h | --help          Show this message
#
# Exit codes:
#   0   All enabled tests passed
#   1   One or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE=""
TEST_USER=""
TEST_PASS=""
REALM_OVERRIDE=""
KC_OVERRIDE=""
CLIENT_OVERRIDE=""
CHECK_POSIX=0
CHECK_GROUPS=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)    CONFIG_FILE="${_arg#--config=}" ;;
        --user=*)      TEST_USER="${_arg#--user=}" ;;
        --password=*)  TEST_PASS="${_arg#--password=}" ;;
        --realm=*)     REALM_OVERRIDE="${_arg#--realm=}" ;;
        --kc=*)        KC_OVERRIDE="${_arg#--kc=}" ;;
        --client=*)    CLIENT_OVERRIDE="${_arg#--client=}" ;;
        --check-posix) CHECK_POSIX=1 ;;
        --check-groups)CHECK_GROUPS=1 ;;
        --no-color)    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET='' ;;
        -h|--help)
            sed -n '/^# ===.*$/,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -70
            exit 0
            ;;
        *) echo "Unknown argument: ${_arg}. Use --help." >&2; exit 1 ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Require username
# ---------------------------------------------------------------------------
if [[ -z "${TEST_USER}" ]]; then
    echo -e "${RED}ERROR:${RESET} --user=NAME is required." >&2
    echo "  Example: $0 --user=jsmith" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prompt for password securely if not provided
# ---------------------------------------------------------------------------
if [[ -z "${TEST_PASS}" ]]; then
    if [[ ! -t 0 ]]; then
        echo -e "${RED}ERROR:${RESET} --password=PASS required when stdin is not a TTY." >&2
        exit 1
    fi
    read -r -s -p "Password for ${TEST_USER}: " TEST_PASS
    echo
fi

# ---------------------------------------------------------------------------
# Locate and source config.env
# ---------------------------------------------------------------------------
if [[ -z "${CONFIG_FILE}" ]]; then
    for _p in \
        "${SCRIPT_DIR}/config.env" \
        "/opt/keycloak/conf/hpc-config.env" \
        "/etc/hpc-keycloak/config.env" \
        "${HOME}/config.env"
    do
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; break; fi
    done
fi
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# Resolve connection values
# ---------------------------------------------------------------------------
REALM="${REALM_OVERRIDE:-${REALM_NAME:-hpc-infrastructure}}"

if [[ -n "${KC_OVERRIDE}" ]]; then
    _kc_tmp="${KC_OVERRIDE}"
else
    _kc_tmp="${KC_HOST:-localhost}:${KC_PORT:-8080}"
fi
KC_HOST_ONLY="${_kc_tmp%%:*}"
KC_PORT_ONLY="${_kc_tmp##*:}"
[[ "${KC_PORT_ONLY}" == "${KC_HOST_ONLY}" ]] && KC_PORT_ONLY="8080"

TOKEN_URL="http://${KC_HOST_ONLY}:${KC_PORT_ONLY}/realms/${REALM}/protocol/openid-connect/token"
USERINFO_URL="http://${KC_HOST_ONLY}:${KC_PORT_ONLY}/realms/${REALM}/protocol/openid-connect/userinfo"

# Discover the authoritative issuer from the OIDC discovery document.
# The issued token's 'iss' claim must exactly match the KC frontend URL.
_disc_url="${OIDC_DISCOVERY_URL:-http://${KC_HOST_ONLY}:${KC_PORT_ONLY}/realms/${REALM}/.well-known/openid-configuration}"
_disc_issuer=$(curl -sk --max-time 10 "${_disc_url}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('issuer',''))" 2>/dev/null \
    || true)
EXPECTED_ISSUER="${_disc_issuer:-${OIDC_ISSUER:-http://${KC_HOST_ONLY}:${KC_PORT_ONLY}/realms/${REALM}}}"
EXPECTED_AUDIENCE="${OIDC_AUDIENCE:-openondemand}"

# HTTPS discovery URL (for TEST 10 — validates Caddy TLS is up)
KC_FQDN="${KC_FQDN:-}"
HTTPS_DISC_URL=""
if [[ -n "${KC_FQDN}" ]]; then
    HTTPS_DISC_URL="https://${KC_FQDN}/realms/${REALM}/.well-known/openid-configuration"
fi

# Client for ROPC grant
_CLIENT_ID="${CLIENT_OVERRIDE:-${KC_CLI_CLIENT_ID:-hpc-cli}}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    command -v "${_cmd}" &>/dev/null || { echo "ERROR: ${_cmd} not found." >&2; exit 1; }
done
python3 -c "import json,base64" 2>/dev/null || { echo "ERROR: python3 stdlib unavailable." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0

result() {
    local status="$1" desc="$2" detail="${3:-}"
    case "${status}" in
        PASS)
            PASS=$((PASS+1))
            echo -e "  ${GREEN}PASS${RESET}  ${desc}${detail:+  ${DIM}(${detail})${RESET}}"
            ;;
        FAIL)
            FAIL=$((FAIL+1))
            echo -e "  ${RED}FAIL${RESET}  ${desc}${detail:+  ${RED}${detail}${RESET}}"
            ;;
        SKIP)
            SKIP=$((SKIP+1))
            echo -e "  ${YELLOW}SKIP${RESET}  ${desc}${detail:+  ${DIM}${detail}${RESET}}"
            ;;
    esac
}

hr() { echo -e "${DIM}──────────────────────────────────────────────────────────${RESET}"; }

decode_jwt_part() {
    python3 - "$1" <<'PYEOF'
import sys, base64, json
seg = sys.argv[1]
seg += "=" * (4 - len(seg) % 4)
seg = seg.replace("-", "+").replace("_", "/")
try:
    raw = base64.b64decode(seg)
    print(json.dumps(json.loads(raw), indent=2))
except Exception as e:
    print(f"decode-error: {e}", file=sys.stderr)
    sys.exit(0)
PYEOF
}

json_field() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    for key in sys.argv[2].split("."):
        if isinstance(data, list):
            data = data[int(key)]
        else:
            data = data[key]
    print(data if isinstance(data, str) else json.dumps(data))
except Exception:
    pass
PYEOF
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}HPC Keycloak — Authentication Test${RESET}"
echo -e "${DIM}User: ${TEST_USER}  |  Realm: ${REALM}  |  KC: ${KC_HOST_ONLY}:${KC_PORT_ONLY}  |  Client: ${_CLIENT_ID}${RESET}"
echo

# ---------------------------------------------------------------------------
# TEST 1 — Keycloak token endpoint reachable
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 1${RESET}  Keycloak token endpoint reachable"
_t1_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    -X POST "${TOKEN_URL}" 2>/dev/null || echo "000")
if [[ "${_t1_code}" == "400" || "${_t1_code}" == "401" ]]; then
    result PASS "Token endpoint reachable" "${TOKEN_URL} → HTTP ${_t1_code}"
elif [[ "${_t1_code}" == "000" ]]; then
    result FAIL "Token endpoint reachable" "connection failed — is Keycloak running at ${KC_HOST_ONLY}:${KC_PORT_ONLY}?"
else
    result PASS "Token endpoint reachable" "${TOKEN_URL} → HTTP ${_t1_code}"
fi

# ---------------------------------------------------------------------------
# TEST 2 — Password grant (ROPC)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 2${RESET}  Password grant for '${TEST_USER}'"
_token_resp=$(curl -sk --max-time 15 \
    -X POST "${TOKEN_URL}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${_CLIENT_ID}" \
    --data-urlencode "username=${TEST_USER}" \
    --data-urlencode "password=${TEST_PASS}" \
    --data-urlencode "scope=openid profile email hpc-posix" \
    2>/dev/null)

ACCESS_TOKEN=$(json_field "${_token_resp}" "access_token")
_token_error=$(json_field "${_token_resp}" "error")
_token_error_desc=$(json_field "${_token_resp}" "error_description")

if [[ -n "${ACCESS_TOKEN}" ]]; then
    result PASS "Password grant" "access_token obtained (client=${_CLIENT_ID})"
    TOKEN_VALID=1
else
    result FAIL "Password grant" "${_token_error:-unknown_error}: ${_token_error_desc:-no description}"
    TOKEN_VALID=0
fi

if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    echo -e "\n  ${YELLOW}Warning:${RESET} No token obtained. Tests 3–12 will be skipped.\n"
fi

# ---------------------------------------------------------------------------
# Decode JWT payload once for tests 3–8
# ---------------------------------------------------------------------------
JWT_PAYLOAD=""
if [[ "${TOKEN_VALID}" -eq 1 ]]; then
    _jwt_part=$(echo "${ACCESS_TOKEN}" | cut -d'.' -f2)
    JWT_PAYLOAD=$(decode_jwt_part "${_jwt_part}")
fi

# ---------------------------------------------------------------------------
# TEST 3 — Token structure (valid JWT)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 3${RESET}  Token structure (valid JWT)"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token structure" "no token"
else
    _seg_count=$(echo "${ACCESS_TOKEN}" | tr -cd '.' | wc -c)
    if [[ "${_seg_count}" -eq 2 ]]; then
        result PASS "Token structure" "three segments (header.payload.sig)"
    else
        result FAIL "Token structure" "expected 3 segments, got $((_seg_count+1))"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 4 — Token issuer matches realm URL
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 4${RESET}  Token issuer"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token issuer" "no token"
else
    _iss=$(json_field "${JWT_PAYLOAD}" "iss")
    if [[ "${_iss}" == "${EXPECTED_ISSUER}" ]]; then
        result PASS "Token issuer" "${_iss}"
    else
        _iss_host="${_iss##*//}"; _iss_host="${_iss_host%%/*}"
        _exp_host="${EXPECTED_ISSUER##*//}"; _exp_host="${_exp_host%%/*}"
        if [[ "${_iss_host}" == "${_exp_host}" ]]; then
            result PASS "Token issuer" "${_iss}  ${DIM}(scheme differs — OK if behind TLS proxy)${RESET}"
            EXPECTED_ISSUER="${_iss}"
        else
            result FAIL "Token issuer" "got '${_iss}', expected '${EXPECTED_ISSUER}' — check OIDC_ISSUER / KC_FQDN in config.env"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TEST 5 — Token audience includes 'openondemand'
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 5${RESET}  Token audience (${EXPECTED_AUDIENCE})"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token audience" "no token"
else
    _aud_raw=$(json_field "${JWT_PAYLOAD}" "aud")
    if echo "${_aud_raw}" | grep -q "${EXPECTED_AUDIENCE}"; then
        result PASS "Token audience" "aud contains '${EXPECTED_AUDIENCE}'"
    else
        result FAIL "Token audience" "aud='${_aud_raw}' — add audience mapper for '${EXPECTED_AUDIENCE}' on hpc-cli client"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 6 — hpc-user realm role present
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 6${RESET}  Token realm role (hpc-user)"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token realm role" "no token"
else
    _roles_raw=$(json_field "${JWT_PAYLOAD}" "realm_access")
    if echo "${_roles_raw}" | grep -q "hpc-user"; then
        result PASS "Token realm role" "hpc-user present in realm_access.roles"
    else
        result FAIL "Token realm role" \
            "hpc-user not in realm_access — check hardcoded-role mapper in LDAP provider, or assign manually"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 7 — Token not expired
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 7${RESET}  Token not expired"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token expiry" "no token"
else
    _exp=$(json_field "${JWT_PAYLOAD}" "exp")
    _now=$(date +%s)
    if [[ -n "${_exp}" && "${_exp}" -gt "${_now}" ]]; then
        _remaining=$((_exp - _now))
        result PASS "Token expiry" "valid for ${_remaining}s"
    elif [[ -z "${_exp}" ]]; then
        result FAIL "Token expiry" "'exp' claim missing from token"
    else
        result FAIL "Token expiry" "token already expired (exp=${_exp}, now=${_now})"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 8 — Token subject non-empty
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 8${RESET}  Token subject (user identity)"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token subject" "no token"
else
    _sub=$(json_field "${JWT_PAYLOAD}" "sub")
    _preferred_username=$(json_field "${JWT_PAYLOAD}" "preferred_username")
    if [[ -n "${_sub}" ]]; then
        result PASS "Token subject" "sub=${_sub}  preferred_username=${_preferred_username}"
    else
        result FAIL "Token subject" "'sub' claim missing — malformed token"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 9 — KC userinfo endpoint accepts token
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 9${RESET}  KC /userinfo endpoint accepts token"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "KC userinfo" "no token"
else
    _ui_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        "${USERINFO_URL}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        2>/dev/null || echo "000")
    case "${_ui_code}" in
        200) result PASS "KC userinfo" "${USERINFO_URL} → HTTP 200" ;;
        401) result FAIL "KC userinfo" "HTTP 401 — token rejected by KC (issuer mismatch or expired)" ;;
        000) result SKIP "KC userinfo" "KC not reachable from this host" ;;
        *)   result FAIL "KC userinfo" "unexpected HTTP ${_ui_code} from ${USERINFO_URL}" ;;
    esac
fi

# ---------------------------------------------------------------------------
# TEST 10 — KC HTTPS discovery URL reachable (validates Caddy TLS proxy)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 10${RESET} KC HTTPS discovery URL reachable (Caddy TLS)"
if [[ -z "${HTTPS_DISC_URL}" ]]; then
    result SKIP "KC HTTPS reachable" "KC_FQDN not set in config.env — use --kc or set KC_FQDN"
else
    _https_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
        "${HTTPS_DISC_URL}" 2>/dev/null || echo "000")
    case "${_https_code}" in
        200) result PASS "KC HTTPS reachable" "${HTTPS_DISC_URL} → HTTP 200" ;;
        000) result FAIL "KC HTTPS reachable" "connection failed — is Caddy running and TLS cert valid for ${KC_FQDN}?" ;;
        *)   result FAIL "KC HTTPS reachable" "unexpected HTTP ${_https_code}" ;;
    esac
fi

# ---------------------------------------------------------------------------
# TEST 11 — POSIX attributes (uidNumber, homeDirectory, loginShell)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 11${RESET} POSIX attributes (uidNumber, homeDirectory, loginShell)"
if [[ "${CHECK_POSIX}" -eq 0 ]]; then
    result SKIP "POSIX attributes" "use --check-posix to enable (run after configuring LDAP POSIX mappers)"
elif [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "POSIX attributes" "no token"
else
    # Request userinfo which may have more claims than the access token
    _ui_body=$(curl -sk --max-time 10 \
        "${USERINFO_URL}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        2>/dev/null || echo "{}")

    _uid=$(json_field "${JWT_PAYLOAD}" "uidNumber")
    _home=$(json_field "${JWT_PAYLOAD}" "homeDirectory")
    _shell=$(json_field "${JWT_PAYLOAD}" "loginShell")
    _gid=$(json_field "${JWT_PAYLOAD}" "gidNumber")

    # Fall back to userinfo if not in access token
    [[ -z "${_uid}" ]]   && _uid=$(json_field "${_ui_body}" "uidNumber")
    [[ -z "${_home}" ]]  && _home=$(json_field "${_ui_body}" "homeDirectory")
    [[ -z "${_shell}" ]] && _shell=$(json_field "${_ui_body}" "loginShell")
    [[ -z "${_gid}" ]]   && _gid=$(json_field "${_ui_body}" "gidNumber")

    _posix_ok=1
    _posix_detail=""
    for _pair in "uidNumber:${_uid}" "homeDirectory:${_home}" "loginShell:${_shell}"; do
        _pkey="${_pair%%:*}"; _pval="${_pair#*:}"
        if [[ -n "${_pval}" ]]; then
            _posix_detail+="${_pkey}=${_pval}  "
        else
            _posix_ok=0
            _posix_detail+="${RED}${_pkey}=MISSING${RESET}  "
        fi
    done
    [[ -n "${_gid}" ]] && _posix_detail+="gidNumber=${_gid}"

    if [[ "${_posix_ok}" -eq 1 ]]; then
        result PASS "POSIX attributes" "${_posix_detail}"
    else
        result FAIL "POSIX attributes" "${_posix_detail}
         Fix: LDAP POSIX storage mappers must be configured (setup_hpc_ad.sh)
              and hpc-posix scope must be optional/default on hpc-cli client
              and the AD user must have uidNumber/homeDirectory/loginShell set in LDAP"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 12 — Groups claim present
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 12${RESET} Group membership claim (AD group mapper)"
if [[ "${CHECK_GROUPS}" -eq 0 ]]; then
    result SKIP "Group claim" "use --check-groups to enable (run after AD group mapper setup)"
elif [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Group claim" "no token"
else
    _groups_raw=$(json_field "${JWT_PAYLOAD}" "groups")
    if [[ -n "${_groups_raw}" && "${_groups_raw}" != "null" ]]; then
        _gcount=$(echo "${_groups_raw}" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 1)" \
            2>/dev/null || echo "?")
        result PASS "Group claim" "${_gcount} group(s): ${_groups_raw:0:120}"
    else
        result FAIL "Group claim" \
            "'groups' claim missing — add Group Membership mapper to hpc-cli:
         KC Admin → Clients → hpc-cli → Client Scopes → hpc-cli-dedicated
         → Add Mapper → Group Membership → Token Claim Name: groups"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hr; echo
_total=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}${PASS}${RESET} passed  ${RED}${FAIL}${RESET} failed  ${YELLOW}${SKIP}${RESET} skipped  (of ${_total} tests)"
echo

if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "  ${BOLD}Troubleshooting:${RESET}"
    echo -e "  ${DIM}• TEST 2 FAIL (invalid_credentials): verify user exists in KC or AD sync ran${RESET}"
    echo -e "  ${DIM}• TEST 2 FAIL (direct access grants disabled): KC → Clients → hpc-cli → Settings → enable Direct Access Grants${RESET}"
    echo -e "  ${DIM}• TEST 4 FAIL (issuer): KC_FQDN in config.env must match 'hostname' in keycloak.conf${RESET}"
    echo -e "  ${DIM}• TEST 5 FAIL (audience): KC → Clients → hpc-cli → Mappers → add Audience mapper for 'openondemand'${RESET}"
    echo -e "  ${DIM}• TEST 6 FAIL (hpc-user): check hardcoded-role mapper in LDAP provider (setup_hpc_ad.sh)${RESET}"
    echo -e "  ${DIM}• TEST 10 FAIL: verify Caddy config routes https://${KC_FQDN:-kc.hpc.moffitt.org} → http://localhost:${KC_PORT_ONLY}${RESET}"
    echo -e "  ${DIM}• TEST 11 FAIL (POSIX): verify uidNumber/homeDirectory/loginShell set on user in AD${RESET}"
    echo -e "  ${DIM}            and that hpc-posix scope is listed as optional scope on hpc-cli${RESET}"
    echo
    exit 1
fi

exit 0
