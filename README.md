# Keycloak HPC Infrastructure — Setup Guide

Keycloak 26.x on a Rocky Linux VM, federated to Moffitt Active Directory, serving the `hpc-infrastructure` realm for OpenOnDemand and CLI HPC access.

## Overview

| Script | Purpose | Run as |
|---|---|---|
| `config.env` | Master config — sourced by all scripts | — |
| `new_keycloak_setup.sh` | Install Keycloak + systemd service | root |
| `new_configure_hpc.sh` | Create realm, clients, scopes via REST API | any user with KC admin credentials |
| `setup_hpc_ad.sh` | Federate Active Directory (LDAPS) | any user with KC admin credentials |
| `test_hpc_auth.sh` | Validate authentication end-to-end | any user |

---

## Prerequisites

Before running any script, ensure the following are in place on or accessible from the VM:

- **Rocky Linux 8 or 9**
- **Java 21** — installed automatically by `new_keycloak_setup.sh` via `dnf`
- **PostgreSQL** — external DB at `10.14.193.208:5432`; database `keycloak` and user `keycloak` must already exist
- **Caddy** (or nginx) — configured to proxy `https://kc.hpc.moffitt.org` → `http://localhost:8080`
- **Firewalld** — port 8080 will be opened automatically
- **`python3`** — required by `new_configure_hpc.sh` and `setup_hpc_ad.sh` for REST API calls
- **`keytool`** (from JDK 21) — required by `setup_hpc_ad.sh` for LDAPS truststore setup
- **`openssl`** — required by `setup_hpc_ad.sh` to fetch the AD certificate chain

---

## Step 0 — Edit config.env

All scripts source `config.env`. Fill in the secrets before running anything:

```bash
chmod 640 config.env
vi config.env
```

**Required values to set:**

```bash
DB_PASSWORD=""          # PostgreSQL password for the keycloak DB user
AD_BIND_PASSWORD=""     # AD service account password (hpc-ldap-bind@moffitt.org)
```

**Optional — set these or let the scripts fill them in:**

```bash
KC_ADMIN_PASSWORD=""    # Keycloak admin password — generated and written back if blank
```

Everything else (hostnames, realm name, client IDs, OIDC URLs) is pre-configured for the Moffitt HPC environment and should not need to change.

---

## Step 1 — Install Keycloak

```bash
sudo ./new_keycloak_setup.sh
```

This script must run as **root**. It will:

1. Install Java 21 via `dnf`
2. Create a `keycloak` system user (no home directory)
3. Download Keycloak 26.2.5 from GitHub and extract to `/opt/keycloak`
4. Write `/opt/keycloak/conf/keycloak.conf` (PostgreSQL backend, HTTP on localhost:8080, proxy headers for Caddy)
5. Run `kc.sh build` as the `keycloak` user
6. Install and enable a `keycloak.service` systemd unit
7. Open port 8080 in firewalld
8. Start the service and poll `http://localhost:8080/realms/master` until healthy (180 s timeout)
9. Write `OIDC_ISSUER`, `OIDC_DISCOVERY_URL`, and `KC_ADMIN_PASSWORD` back to `config.env`

**Options:**

```
--config=FILE      Use an alternate config file
--version=VER      Override the Keycloak version
--dry-run          Print commands without executing
--yes              Non-interactive (skip confirmations)
-h | --help        Usage help
```

**After this step:**  
Keycloak is running. Verify with:

```bash
systemctl status keycloak
curl -s http://localhost:8080/realms/master | python3 -m json.tool | grep realm
```

---

## Step 2 — Configure the HPC Realm

```bash
./new_configure_hpc.sh
```

This script does **not** require root. It uses the Keycloak admin REST API (Python 3 `urllib`) and is fully **idempotent** — safe to re-run.

It creates:

| Object | Details |
|---|---|
| Realm | `hpc-infrastructure` |
| Client scope | `hpc-posix` — injects `uidNumber`, `gidNumber`, `homeDirectory`, `loginShell` into JWT |
| Realm role | `hpc-user` — baseline HPC access |
| Realm role | `hpc-admin` — admin tier |
| Client | `openondemand` — confidential, Authorization Code + PKCE, `https://hpc.moffitt.org` redirect |
| Client | `hpc-cli` — public, ROPC (for CLI tools and test script) |
| Mappers | Audience mapper (`openondemand`), groups-claim mapper on `hpc-cli` |

At completion, `KC_OOD_CLIENT_SECRET` is written back to `config.env`.

**Options:**

```
--config=FILE    Alternate config file
--kc=HOST:PORT   Override Keycloak host (default: localhost:8080)
--reset          Delete and recreate the realm (DESTRUCTIVE — deletes all users and data)
--dry-run        Print API payloads without calling Keycloak
--yes            Non-interactive
-h | --help      Usage help
```

---

## Step 3 — Federate Active Directory

```bash
./setup_hpc_ad.sh
```

Also does not require root. Run after Step 2. This script:

1. Reads AD parameters from `config.env` (or prompts interactively for any that are missing)
2. Fetches the AD certificate chain via `openssl s_client` and imports it into a JKS truststore at `/opt/keycloak/conf/ldap-truststore.jks`
3. Appends `truststore-paths=` to `keycloak.conf` and restarts the Keycloak service
4. Creates the `moffitt-ad` LDAP user-storage provider (READ\_ONLY, SUBTREE scope, LDAPS)
5. Adds standard mappers: `username`, `email`, `firstName`, `lastName`
6. Adds POSIX mappers: `uidNumber`, `gidNumber` (UPG pattern — maps `gidNumber` from `uidNumber`), `homeDirectory`, `loginShell`
7. Adds a group LDAP mapper (syncs AD group membership)
8. Adds a hardcoded-role mapper (all synced AD users automatically get the `hpc-user` realm role)
9. Adds a groups-claim mapper to `hpc-cli`
10. Triggers an initial full user sync

**Options:**

```
--config=FILE          Alternate config file
--kc=HOST:PORT         Override Keycloak host
--realm=REALM          Override realm name
--provider-name=NAME   LDAP provider name (default: moffitt-ad); use a different name to add a second domain
--test-user=USER       Run test_hpc_auth.sh --check-posix --check-groups after sync
--dry-run              Print API payloads without calling Keycloak
--yes                  Non-interactive (all required values must be set in config.env)
-h | --help            Usage help
```

**After this step:**  
AD users can authenticate. Keycloak will sync and cache their attributes on first login.

---

## Step 4 — Validate Authentication

```bash
./test_hpc_auth.sh --user=jsmith
```

The script prompts for the password securely if `--password` is not provided.

**What it tests:**

| # | Test |
|---|---|
| 1 | Keycloak realm endpoint reachable |
| 2 | Password grant (ROPC via `hpc-cli`) succeeds |
| 3 | Response is a valid JWT (three base64 segments) |
| 4 | Token issuer matches `OIDC_ISSUER` in config.env |
| 5 | Token audience includes `openondemand` |
| 6 | Token contains `hpc-user` realm role |
| 7 | Token is not expired |
| 8 | Token subject (`sub`) is non-empty |
| 9 | `/userinfo` endpoint accepts the token (HTTP 200) |
| 10 | HTTPS discovery URL reachable via Caddy TLS proxy |
| 11 | *(optional)* POSIX attributes present: `uidNumber`, `homeDirectory`, `loginShell` |
| 12 | *(optional)* `groups` claim present in token |

**Run with all checks (after AD federation):**

```bash
./test_hpc_auth.sh --user=jsmith --check-posix --check-groups
```

**Options:**

```
--config=FILE        Alternate config file
--user=NAME          Username to test (required)
--password=PASS      Password (prompted securely if omitted)
--realm=REALM        Override realm name
--kc=HOST:PORT       Override Keycloak host (e.g. localhost:8080)
--client=CLIENT_ID   ROPC client to use (default: hpc-cli)
--check-posix        Enable test 11: POSIX attributes in token
--check-groups       Enable test 12: groups claim in token
--no-color           Disable ANSI color output
-h | --help          Usage help
```

---

## Complete Installation Sequence

```bash
# 0. Configure secrets
chmod 640 config.env
vi config.env          # set DB_PASSWORD and AD_BIND_PASSWORD at minimum

# 1. Install Keycloak (as root)
sudo ./new_keycloak_setup.sh

# 2. Create realm, clients, and scopes
./new_configure_hpc.sh

# 3. Federate Active Directory (interactive wizard)
./setup_hpc_ad.sh

# 4. Validate
./test_hpc_auth.sh --user=jsmith --check-posix --check-groups
```

---

## Configure OpenOnDemand

After Step 2 completes, `config.env` contains the generated `KC_OOD_CLIENT_SECRET`. Use these values in your OOD OIDC config:

| Setting | Value |
|---|---|
| Client ID | `openondemand` |
| Client Secret | `KC_OOD_CLIENT_SECRET` from `config.env` |
| Discovery URL | `https://kc.hpc.moffitt.org/realms/hpc-infrastructure/.well-known/openid-configuration` |
| Redirect URI | `https://hpc.moffitt.org/oidc` |

---

## Maintenance

### Re-run realm configuration (idempotent)

```bash
./new_configure_hpc.sh
```

Safe to re-run at any time. Existing objects are checked before creation; nothing is overwritten.

### Reset realm (destructive)

```bash
./new_configure_hpc.sh --reset
```

Deletes the entire `hpc-infrastructure` realm and recreates it from scratch. **All user data and sessions will be lost.**

### Re-run AD federation setup

```bash
./setup_hpc_ad.sh
```

Idempotent — existing LDAP providers and mappers are updated in place, not duplicated.

### Check Keycloak service

```bash
systemctl status keycloak
journalctl -u keycloak -n 100 --no-pager
```

### Upgrade Keycloak

Edit `KC_VERSION` in `config.env`, then re-run:

```bash
sudo ./new_keycloak_setup.sh --version=<new-version>
```

---

## File Reference

```
keycloak/
├── config.env              # Master config — edit secrets here (chmod 640)
├── new_keycloak_setup.sh   # Step 1 — install KC + systemd
├── new_configure_hpc.sh    # Step 2 — realm / clients / scopes (idempotent)
├── setup_hpc_ad.sh         # Step 3 — LDAP / AD federation (idempotent)
└── test_hpc_auth.sh        # Step 4 — 12-test auth validation
```
