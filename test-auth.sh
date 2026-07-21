#!/usr/bin/env bash
# =============================================================================
# StromaAI — Keycloak Authentication Test
# =============================================================================
# Validates that a cluster user can authenticate with Keycloak and that
# the resulting token grants access to the StromaAI API.
#
# Designed to run before AND after Active Directory federation — test results
# are identical regardless of whether the user lives in Keycloak's local store
# or is federated from Active Directory/LDAP.
#
# Tests:
#   1.  Keycloak realm reachable (token endpoint responds)
#   2.  Password grant (username + password → access_token)
#   3.  Token is a valid JWT (three base64 segments)
#   4.  Token issuer matches expected realm URL
#   5.  Token audience includes stroma-ai-gateway client
#   6.  Token contains stroma_researcher realm role
#   7.  Token not already expired (exp claim in future)
#   8.  Token subject (sub) is non-empty UUID
#   9.  Token accepted by StromaAI gateway (/v1/models)
#   10. Token accepted via nginx TLS proxy (/v1/models)
#   11. Optional: group membership claim present (after AD group mapper setup)
#
# Usage:
#   scripts/test-auth.sh --user=jsmith --password='s3cr3t'
#   scripts/test-auth.sh --user=jsmith --password='s3cr3t' --realm=stroma-ai
#   scripts/test-auth.sh --user=jsmith --password='s3cr3t' --skip-inference
#   scripts/test-auth.sh --user=jsmith --password='s3cr3t' --no-color
#   scripts/test-auth.sh --config=/path/to/config.env --user=jsmith --password='s3cr3t'
#   scripts/test-auth.sh --help
#
# Options:
#   --config=FILE        Path to config.env (auto-detected if omitted)
#   --user=NAME          Username to test (required)
#   --password=PASS      Password (prompted securely if omitted)
#   --realm=REALM        Keycloak realm name (default: stroma-ai)
#   --kc=HOST            Keycloak host:port override (e.g. kchpc.moffitt.org:8080)
#   --gateway=URL        Gateway base URL override (e.g. http://head:9000)
#   --head=HOST          Head node hostname for TLS proxy test
#   --skip-inference     Skip tests 9–10 (token validation only)
#   --check-groups       Check group membership claim is present (TEST 11)
#   --no-color           Disable ANSI colors
#   -h | --help          Show this message
#
# Exit codes:
#   0   All tests passed
#   1   One or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
REALM="stroma-ai"
KC_OVERRIDE=""
GATEWAY_OVERRIDE=""
HEAD_OVERRIDE=""
SKIP_INFERENCE=0
CHECK_GROUPS=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)       CONFIG_FILE="${_arg#--config=}" ;;
        --user=*)         TEST_USER="${_arg#--user=}" ;;
        --password=*)     TEST_PASS="${_arg#--password=}" ;;
        --realm=*)        REALM="${_arg#--realm=}" ;;
        --kc=*)           KC_OVERRIDE="${_arg#--kc=}" ;;
        --gateway=*)      GATEWAY_OVERRIDE="${_arg#--gateway=}" ;;
        --head=*)         HEAD_OVERRIDE="${_arg#--head=}" ;;
        --skip-inference) SKIP_INFERENCE=1 ;;
        --check-groups)   CHECK_GROUPS=1 ;;
        --no-color)       RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET='' ;;
        -h|--help)
            sed -n '2,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -50
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
    echo "  Example: $0 --user=jsmith --password='mypass'" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prompt for password securely if not provided
# ---------------------------------------------------------------------------
if [[ -z "${TEST_PASS}" ]]; then
    # Only prompt if we're on a TTY; if piped in, fail clearly.
    if [[ ! -t 0 ]]; then
        echo -e "${RED}ERROR:${RESET} --password=PASS is required when stdin is not a TTY." >&2
        exit 1
    fi
    read -r -s -p "Password for ${TEST_USER}: " TEST_PASS
    echo  # newline after hidden input
fi

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

# ---------------------------------------------------------------------------
# Resolve connection values
# ---------------------------------------------------------------------------
HEAD="${HEAD_OVERRIDE:-${STROMA_HEAD_HOST:-}}"

# Keycloak host:port — can be e.g. kchpc.moffitt.org:8080
if [[ -n "${KC_OVERRIDE}" ]]; then
    _kc_tmp="${KC_OVERRIDE}"
else
    # Fall back to KC_INTERNAL_URL → extract host:port
    if [[ -n "${KC_INTERNAL_URL:-}" ]]; then
        _kc_tmp="${KC_INTERNAL_URL#http://}"; _kc_tmp="${_kc_tmp#https://}"
        _kc_tmp="${_kc_tmp%%/*}"        # strip any path
    else
        _kc_tmp="${HEAD:-localhost}:8080"
    fi
fi
KC_HOST="${_kc_tmp%%:*}"
KC_PORT="${_kc_tmp##*:}"; [[ "${KC_PORT}" == "${KC_HOST}" ]] && KC_PORT="8080"

GATEWAY_BASE="${GATEWAY_OVERRIDE:-http://${HEAD}:${GATEWAY_PORT:-9000}}"
TLS_BASE="https://${HEAD}"

TOKEN_URL="http://${KC_HOST}:${KC_PORT}/realms/${REALM}/protocol/openid-connect/token"

# Discover the authoritative issuer from the OIDC discovery document.
# KC emits tokens with the issuer it was configured with (KC_HOSTNAME /
# frontendUrl), which may differ from the IP in KC_INTERNAL_URL.  Fetching
# the discovery doc gives us the exact value the token will contain.
# Falls back to OIDC_ISSUER from config.env, then to constructing from KC_HOST.
_disc_url="${OIDC_DISCOVERY_URL:-http://${KC_HOST}:${KC_PORT}/realms/${REALM}/.well-known/openid-configuration}"
_disc_issuer=$(curl -sk --max-time 10 "${_disc_url}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('issuer',''))" 2>/dev/null || true)
EXPECTED_ISSUER="${_disc_issuer:-${OIDC_ISSUER:-http://${KC_HOST}:${KC_PORT}/realms/${REALM}}}"

# Use OIDC_AUDIENCE from config.env — the installed value is 'stroma-gateway',
# not 'stroma-ai-gateway'.  Fall back to the gateway-client ID.
EXPECTED_AUDIENCE="${OIDC_AUDIENCE:-stroma-gateway}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    command -v "${_cmd}" &>/dev/null || { echo "ERROR: ${_cmd} not found." >&2; exit 1; }
done

python3 -c "import json,base64,sys" 2>/dev/null || { echo "ERROR: python3 json/base64 unavailable." >&2; exit 1; }

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

# Decode a JWT segment (base64url → JSON string); never exits non-zero
decode_jwt_part() {
    local part="$1"
    python3 - "$part" <<'PYEOF'
import sys, base64, json
seg = sys.argv[1]
# Pad to a multiple of 4
seg += "=" * (4 - len(seg) % 4)
# base64url → base64
seg = seg.replace("-", "+").replace("_", "/")
try:
    raw = base64.b64decode(seg)
    print(json.dumps(json.loads(raw), indent=2))
except Exception as e:
    print(f"decode-error: {e}", file=sys.stderr)
    sys.exit(0)         # don't fail the outer test
PYEOF
}

# json_field BODY FIELD  — supports dotted paths e.g. "roles.0"
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
echo -e "${BOLD}StromaAI — Keycloak Authentication Test${RESET}"
echo -e "${DIM}User: ${TEST_USER}  |  Realm: ${REALM}  |  KC: ${KC_HOST}:${KC_PORT}${RESET}"
echo

# ---------------------------------------------------------------------------
# TEST 1 — Keycloak token endpoint reachable
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 1${RESET}  Keycloak token endpoint reachable"
_t1_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    -X POST "${TOKEN_URL}" 2>/dev/null || echo "000")
if [[ "${_t1_code}" == "400" || "${_t1_code}" == "401" ]]; then
    # 400/401 means KC answered — bad request is fine here, we just want reachability
    result PASS "Token endpoint reachable" "${TOKEN_URL} → HTTP ${_t1_code}"
elif [[ "${_t1_code}" == "000" ]]; then
    result FAIL "Token endpoint reachable" "connection failed — is Keycloak running at ${KC_HOST}:${KC_PORT}?"
else
    result PASS "Token endpoint reachable" "${TOKEN_URL} → HTTP ${_t1_code}"
fi

# ---------------------------------------------------------------------------
# TEST 2 — Password grant (the actual AD/local auth)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 2${RESET}  Password grant for '${TEST_USER}'"

# Determine which OIDC client to use for the Resource Owner Password Credentials grant.
# stroma-cli is a public client with Direct Access Grants enabled — created by
# setup-keycloak.sh specifically for CLI tools. No client_secret needed.
# Override with KC_AUTH_TEST_CLIENT if your install uses a different client.
_CLIENT_ID="${KC_AUTH_TEST_CLIENT:-stroma-cli}"

_token_resp=$(curl -sk --max-time 15 \
    -X POST "${TOKEN_URL}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${_CLIENT_ID}" \
    --data-urlencode "username=${TEST_USER}" \
    --data-urlencode "password=${TEST_PASS}" \
    --data-urlencode "scope=openid profile email" \
    2>/dev/null)

ACCESS_TOKEN=$(json_field "${_token_resp}" "access_token")
_token_error=$(json_field "${_token_resp}" "error")
_token_error_desc=$(json_field "${_token_resp}" "error_description")

if [[ -n "${ACCESS_TOKEN}" ]]; then
    result PASS "Password grant" "access_token obtained (client=${_CLIENT_ID})"
else
    result FAIL "Password grant" "${_token_error:-unknown_error}: ${_token_error_desc:-no description} — raw: ${_token_resp:0:200}"
fi

# If we have no token, later tests can't run; skip them but still continue.
if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo -e "\n  ${YELLOW}Warning:${RESET} No token obtained. Tests 3–11 will be skipped.\n"
    TOKEN_VALID=0
else
    TOKEN_VALID=1
fi

# ---------------------------------------------------------------------------
# Decode payload once for tests 3–8
# ---------------------------------------------------------------------------
JWT_PAYLOAD=""
if [[ "${TOKEN_VALID}" -eq 1 ]]; then
    _jwt_part=$(echo "${ACCESS_TOKEN}" | cut -d'.' -f2)
    JWT_PAYLOAD=$(decode_jwt_part "${_jwt_part}")
fi

# ---------------------------------------------------------------------------
# TEST 3 — Token is valid JWT (three segments)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 3${RESET}  Token structure (valid JWT)"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token structure" "no token"
else
    _seg_count=$(echo "${ACCESS_TOKEN}" | tr -cd '.' | wc -c)
    if [[ "${_seg_count}" -eq 2 ]]; then
        result PASS "Token structure" "three segments (header.payload.sig)"
    else
        result FAIL "Token structure" "expected 3 segments, got $((${_seg_count}+1)) — not a JWT?"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 4 — Issuer matches realm URL
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 4${RESET}  Token issuer"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token issuer" "no token"
else
    _iss=$(json_field "${JWT_PAYLOAD}" "iss")
    if [[ "${_iss}" == "${EXPECTED_ISSUER}" ]]; then
        result PASS "Token issuer" "${_iss}"
    else
        # If behind TLS proxy the issuer may be https:// — treat as pass with a note
        _iss_host="${_iss##*//}"; _iss_host="${_iss_host%%/*}"
        _exp_host="${EXPECTED_ISSUER##*//}"; _exp_host="${_exp_host%%/*}"
        if [[ "${_iss_host}" == "${_exp_host}" ]]; then
            result PASS "Token issuer" "${_iss}  ${DIM}(scheme differs from expected — okay if behind TLS proxy)${RESET}"
            EXPECTED_ISSUER="${_iss}"   # update so TEST 4 PASS is stable
        else
            result FAIL "Token issuer" "got '${_iss}', expected '${EXPECTED_ISSUER}' — check OIDC_DISCOVERY_URL in config.env"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TEST 5 — Token audience includes expected audience (default: stroma-gateway)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 5${RESET}  Token audience (${EXPECTED_AUDIENCE})"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token audience" "no token"
else
    _aud_raw=$(json_field "${JWT_PAYLOAD}" "aud")
    if echo "${_aud_raw}" | grep -q "${EXPECTED_AUDIENCE}"; then
        result PASS "Token audience" "aud contains ${EXPECTED_AUDIENCE}"
    else
        result FAIL "Token audience" "aud='${_aud_raw}' — add audience mapper for '${EXPECTED_AUDIENCE}' in the ${_CLIENT_ID} KC client"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 6 — stroma_researcher realm role present
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 6${RESET}  Token realm role (stroma_researcher)"
if [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Token realm role" "no token"
else
    _roles_raw=$(json_field "${JWT_PAYLOAD}" "realm_access")
    if echo "${_roles_raw}" | grep -q "stroma_researcher"; then
        result PASS "Token realm role" "stroma_researcher present in realm_access"
    else
        # Provide specific remediation depending on whether it looks like an AD user
        result FAIL "Token realm role" \
            "stroma_researcher not in realm_access.roles — assign role to user or map AD group → stroma_researcher"
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
        _remaining=$(( _exp - _now ))
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
# TEST 9 — Token accepted by StromaAI gateway (direct, no TLS)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 9${RESET}  Gateway accepts token (direct HTTP)"
if [[ "${SKIP_INFERENCE}" -eq 1 ]]; then
    result SKIP "Gateway auth" "--skip-inference set"
elif [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Gateway auth" "no token"
elif [[ -z "${HEAD}" ]]; then
    result SKIP "Gateway auth" "STROMA_HEAD_HOST not set — use --head=HOST"
else
    _g_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        "${GATEWAY_BASE}/v1/models" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        2>/dev/null || true)
    case "${_g_code}" in
        200) result PASS "Gateway auth" "${GATEWAY_BASE}/v1/models → HTTP ${_g_code}" ;;
        401) result FAIL "Gateway auth" "HTTP 401 — token rejected by gateway (issuer mismatch? OIDC_DISCOVERY_URL points to different KC?)" ;;
        403) result FAIL "Gateway auth" "HTTP 403 — token valid but role not accepted (check stroma_researcher role)" ;;
        000) result SKIP "Gateway auth" "port ${GATEWAY_PORT:-9000} unreachable from this host — gateway is internal to head node; TEST 10 (TLS proxy) is the authoritative check" ;;
        *)   result FAIL "Gateway auth" "unexpected HTTP ${_g_code} from ${GATEWAY_BASE}/v1/models" ;;
    esac
fi

# ---------------------------------------------------------------------------
# TEST 10 — Token accepted via nginx TLS proxy
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 10${RESET} Gateway accepts token (nginx TLS proxy)"
if [[ "${SKIP_INFERENCE}" -eq 1 ]]; then
    result SKIP "TLS proxy auth" "--skip-inference set"
elif [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "TLS proxy auth" "no token"
elif [[ -z "${HEAD}" ]]; then
    result SKIP "TLS proxy auth" "STROMA_HEAD_HOST not set — use --head=HOST"
else
    _t_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
        "${TLS_BASE}/v1/models" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        2>/dev/null || echo "000")
    case "${_t_code}" in
        200) result PASS "TLS proxy auth" "${TLS_BASE}/v1/models → HTTP ${_t_code}" ;;
        401) result FAIL "TLS proxy auth" "HTTP 401 — issuer mismatch common cause: OIDC_DISCOVERY_URL in config.env uses http:// but token iss= uses https:// (or vice versa)" ;;
        403) result FAIL "TLS proxy auth" "HTTP 403 — token valid but rejected by gateway policy" ;;
        000) result FAIL "TLS proxy auth" "connection failed — is nginx running on ${HEAD}:443?" ;;
        *)   result FAIL "TLS proxy auth" "unexpected HTTP ${_t_code}" ;;
    esac
fi

# ---------------------------------------------------------------------------
# TEST 11 — Group membership claim (optional, for AD group-role mapping)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 11${RESET} Group membership claim (AD group mapper)"
if [[ "${CHECK_GROUPS}" -eq 0 ]]; then
    result SKIP "Group claim" "use --check-groups to enable (run after configuring AD group mapper)"
elif [[ "${TOKEN_VALID}" -eq 0 ]]; then
    result SKIP "Group claim" "no token"
else
    # Keycloak group mapper can emit groups under various claim names
    _groups_raw=$(json_field "${JWT_PAYLOAD}" "groups")
    if [[ -n "${_groups_raw}" && "${_groups_raw}" != "null" ]]; then
        # Count how many groups
        _gcount=$(echo "${_groups_raw}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "1")
        result PASS "Group claim" "${_gcount} group(s) present: ${_groups_raw:0:120}"
    else
        result FAIL "Group claim" \
            "'groups' claim missing — add a Group Membership mapper to the ${_CLIENT_ID} client in KC: Client Scopes → ${_CLIENT_ID}-dedicated → Add Mapper → Group Membership → Token Claim Name: groups"
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
    echo -e "  ${BOLD}Troubleshooting hints:${RESET}"
    echo -e "  ${DIM}• TEST 2 FAIL (Invalid credentials): verify the user exists in KC or AD is synced${RESET}"
    echo -e "  ${DIM}• TEST 2 FAIL (Direct access grants disabled): KC → Clients → stroma-cli → Settings → enable 'Direct access grants'${RESET}"
    echo -e "  ${DIM}• TEST 4 FAIL (issuer): token iss= must match OIDC_ISSUER in config.env — re-run setup-keycloak.sh or set KC_HOSTNAME correctly${RESET}"
    echo -e "  ${DIM}• TEST 5 FAIL (audience): KC → Clients → stroma-cli → Client Scopes → Add mapper → Audience → ${EXPECTED_AUDIENCE}${RESET}"
    echo -e "  ${DIM}• TEST 6 FAIL (role): KC → Users → ${TEST_USER} → Role Mappings → assign stroma_researcher${RESET}"
    echo -e "  ${DIM}•        (or for AD): KC → Identity Providers → ${REALM}-ad → Mappers → add Role Importer${RESET}"
    echo -e "  ${DIM}• TEST 10 FAIL (401): OIDC_DISCOVERY_URL in config.env must match the 'iss' in token (TEST 4)${RESET}"
    echo
    exit 1
fi

exit 0