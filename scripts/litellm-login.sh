#!/usr/bin/env bash
# ============================================================
# CONFIG -- EDIT THESE BEFORE DISTRIBUTING THIS SCRIPT.
# This ships to end-user machines standalone (no ../.env, no rest of this
# repo) so the real values have to live directly here.
#
# The tracked copy of this file in the repo must keep the example.com
# placeholders below (see CLAUDE.md's "no real environment details" rule)
# -- fill in the real host only in the copy you actually hand out, and
# don't commit that edit back.
# ============================================================
BROKER_URL="https://testai.example.com/broker/login"
LITELLM_BASE_URL="https://testai.example.com/litellm/v1"

# Real crush binary to launch at the end. If you installed the disguise
# wrapper from ../scripts/crush, point this at crush.real instead.
CRUSH_REAL_BIN="crush"

# Central, shared opencode/crush configs (provider, models, baseURL) --
# maintained by admins, not written by this script. Neither tool looks in a
# shared location by default, so these are exported to point them at it:
#   OPENCODE_CONFIG      -- path to the opencode.json *file*
#   CRUSH_GLOBAL_CONFIG  -- *directory* crush reads crush.json from
# Leave either empty to fall back to that tool's per-user default.
OPENCODE_CONFIG="/group/tools/opencode/opencode.json"
CRUSH_GLOBAL_CONFIG="/group/tools/crush"

# Where the key is cached (0600) and where a sourceable env-var file for new
# shells gets written (also 0600). Defaults are fine for most setups.
CACHE_FILE="${HOME}/.config/litellm/.litellm_key"
ENV_FILE="${HOME}/.config/litellm/.litellm_env"
# ============================================================
# END CONFIG.
# ============================================================

# LDAP -> LiteLLM login for opencode/crush: authenticates against the
# litellm-ldap-broker (see ../broker), caches the resulting key on disk with
# tight permissions, reuses it while it's still valid, re-mints once it's
# expired or revoked, and exports it under every env var name opencode or
# crush might be configured to read.
#
# USAGE: source ./litellm-login.sh   (MUST be sourced, not run directly --
# `source` is what makes the exported vars land in *your* shell, so a later
# `opencode` run in the same terminal also picks them up, not just the
# `crush` launched at the end of this script.)
#
# Username is always `whoami` -- only the password is prompted for.
#
# Why this calls the broker's /login (username+password) instead of a bare
# "mint" endpoint that only takes a username: a mint-by-username-only
# endpoint has no way to tell a legitimate client from someone who just
# guessed a colleague's username and called it directly -- the LDAP bind has
# to happen somewhere the server can verify it. The broker does that bind
# server-side before it ever calls LiteLLM's /key/generate.
#
# Requires: curl, python3 (used only to build/parse the login JSON without
# ever putting the password on argv or in `ps`).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: source this script: source ${0}" >&2
  exit 1
fi

_login_fail() { echo "[litellm-login] $*" >&2; return 1; }

# Validates a key by making an authed call it must pass.
# 200 = key valid & authorized. 401/403 = dead/revoked -- don't trust it.
# Anything else (5xx, network blip) is "can't confirm" -- also don't trust
# it, but this is what naturally forces a re-mint once the broker's own
# KEY_DURATION (default 30d) has passed and LiteLLM has expired the key.
_litellm_token_works() {
  local tok="$1" code
  [[ -n "$tok" ]] || return 1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Authorization: Bearer ${tok}" \
    "${LITELLM_BASE_URL}/models" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

# Writes CACHE_FILE + ENV_FILE at 0600. ENV_FILE exports the key under every
# name opencode/crush might be configured to read:
#   - LITELLM_API_KEY          opencode's `{env:LITELLM_API_KEY}` pattern
#   - OPENAI_API_KEY / _BASE_URL  crush's "openai"/"openai-compat" provider
#   - OPENCODE_CONFIG / CRUSH_GLOBAL_CONFIG  the central configs, if set
# Once you've confirmed which var name the central opencode.json / crush.json
# actually reference, feel free to trim this down to just those -- exporting
# all of them is a "works everywhere while we sort out the exact names"
# default, not a final state.
_litellm_persist_token() {
  local tok="$1"
  umask 077
  mkdir -p "$(dirname "$CACHE_FILE")"
  printf '%s' "$tok" > "$CACHE_FILE"
  chmod 600 "$CACHE_FILE"

  {
    printf 'export LITELLM_API_KEY=%q\n' "$tok"
    printf 'export OPENAI_API_KEY=%q\n' "$tok"
    printf 'export OPENAI_BASE_URL=%q\n' "$LITELLM_BASE_URL"
    printf 'export LITELLM_BASE_URL=%q\n' "$LITELLM_BASE_URL"
    [[ -n "$OPENCODE_CONFIG" ]] && printf 'export OPENCODE_CONFIG=%q\n' "$OPENCODE_CONFIG"
    [[ -n "$CRUSH_GLOBAL_CONFIG" ]] && printf 'export CRUSH_GLOBAL_CONFIG=%q\n' "$CRUSH_GLOBAL_CONFIG"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

_litellm_export_all() {
  local tok="$1"
  export LITELLM_API_KEY="$tok"
  export OPENAI_API_KEY="$tok"
  export OPENAI_BASE_URL="$LITELLM_BASE_URL"
  export LITELLM_BASE_URL="$LITELLM_BASE_URL"
  if [[ -n "$OPENCODE_CONFIG" ]]; then
    [[ -r "$OPENCODE_CONFIG" ]] || echo "[litellm-login] warning: shared opencode config not found at ${OPENCODE_CONFIG}" >&2
    export OPENCODE_CONFIG
  fi
  if [[ -n "$CRUSH_GLOBAL_CONFIG" ]]; then
    [[ -r "${CRUSH_GLOBAL_CONFIG}/crush.json" ]] || echo "[litellm-login] warning: shared crush config not found at ${CRUSH_GLOBAL_CONFIG}/crush.json" >&2
    export CRUSH_GLOBAL_CONFIG
  fi
}

# Authenticates against the broker and mints/looks up a key. Prints the key
# on stdout, returns non-zero (nothing printed) on failure.
_litellm_authenticate_and_mint() {
  local username="$1" password request_body response status body token

  read -rs -p "LDAP password for ${username}: " password
  echo >&2
  [[ -n "$password" ]] || { _login_fail "no password"; return 1; }

  request_body=$(LOGIN_USER="$username" LOGIN_PASS="$password" python3 -c '
import json, os
print(json.dumps({
    "username": os.environ["LOGIN_USER"],
    "password": os.environ["LOGIN_PASS"],
}))
' 2>/dev/null)
  unset password
  [[ -n "$request_body" ]] || { _login_fail "python3 is required"; return 1; }

  response=$(printf '%s' "$request_body" | curl -sS -w $'\n%{http_code}' -X POST "$BROKER_URL" \
    -H "Content-Type: application/json" --data-binary @-)
  unset request_body

  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$status" != "200" ]]; then
    _login_fail "login failed (HTTP ${status}): ${body}"
    return 1
  fi

  token=$(python3 -c 'import sys, json
try:
    print(json.loads(sys.stdin.read()).get("api_key", ""))
except Exception:
    pass' <<<"$body")

  if [[ -z "$token" ]]; then
    _login_fail "no api_key in broker response: ${body}"
    return 1
  fi

  printf '%s' "$token"
}

_litellm_login() {
  local username token
  username="$(whoami)"

  # --- 0) try the cached key first, skip LDAP entirely if it still works.
  if [[ -r "$CACHE_FILE" ]]; then
    local cached
    cached="$(<"$CACHE_FILE")"
    if _litellm_token_works "$cached"; then
      _litellm_export_all "$cached"
      echo "[litellm-login] cached key still valid; reusing it." >&2
      return 0
    fi
    echo "[litellm-login] cached key missing/expired; re-authenticating." >&2
  fi

  # --- 1) LDAP auth + mint-or-lookup, via the broker.
  token=$(_litellm_authenticate_and_mint "$username") || return 1

  # --- 2) sanity-check the freshly obtained key before trusting it.
  if ! _litellm_token_works "$token"; then
    _login_fail "newly issued key failed validation against LiteLLM"
    return 1
  fi

  # --- 3) export + persist.
  _litellm_export_all "$token"
  _litellm_persist_token "$token"
  echo "[litellm-login] new key minted and cached at ${CACHE_FILE}." >&2
  echo "[litellm-login] for new shells: source ${ENV_FILE}" >&2
}

if _litellm_login; then
  # Launching crush is optional -- this script's real job (LDAP auth, key
  # mint/cache, exporting the env vars) is already done by this point
  # regardless of whether crush is even installed. Set LAUNCH_CRUSH=false
  # (or just don't have `crush` on PATH) to use this purely for login, e.g.
  # before running `opencode` instead.
  if [[ "${LAUNCH_CRUSH:-true}" == "true" ]] && command -v "$CRUSH_REAL_BIN" >/dev/null 2>&1; then
    # NOT exec: this script is sourced into your interactive shell, so exec
    # here would replace that shell's process with crush -- when crush
    # exited you'd have no shell left at all, instead of returning to your
    # prompt with LITELLM_API_KEY etc. still exported for a later
    # `opencode` run.
    "$CRUSH_REAL_BIN" "$@"
  elif [[ "${LAUNCH_CRUSH:-true}" == "true" ]]; then
    echo "[litellm-login] '${CRUSH_REAL_BIN}' not found on PATH; skipping launch (login is already done)." >&2
  fi
else
  echo "[litellm-login] login failed; not launching crush." >&2
fi
