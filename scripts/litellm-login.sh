#!/usr/bin/env bash
BROKER_URL="https://testai.example.com/broker/login"
LITELLM_BASE_URL="https://testai.example.com/litellm/v1"

CRUSH_REAL_BIN="crush"

OPENCODE_CONFIG="/group/tools/opencode/opencode.json"
CRUSH_GLOBAL_CONFIG="/group/tools/crush"

CACHE_FILE="${HOME}/.config/litellm/.litellm_key"
ENV_FILE="${HOME}/.config/litellm/.litellm_env"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: source this script: source ${0}" >&2
  exit 1
fi

_login_fail() { echo "[litellm-login] $*" >&2; return 1; }

_litellm_token_works() {
  local tok="$1" code
  [[ -n "$tok" ]] || return 1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Authorization: Bearer ${tok}" \
    "${LITELLM_BASE_URL}/models" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

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

  token=$(_litellm_authenticate_and_mint "$username") || return 1

  if ! _litellm_token_works "$token"; then
    _login_fail "newly issued key failed validation against LiteLLM"
    return 1
  fi

  _litellm_export_all "$token"
  _litellm_persist_token "$token"
  echo "[litellm-login] new key minted and cached at ${CACHE_FILE}." >&2
  echo "[litellm-login] for new shells: source ${ENV_FILE}" >&2
}

if _litellm_login; then
  if [[ "${LAUNCH_CRUSH:-true}" == "true" ]] && command -v "$CRUSH_REAL_BIN" >/dev/null 2>&1; then
    "$CRUSH_REAL_BIN" "$@"
  elif [[ "${LAUNCH_CRUSH:-true}" == "true" ]]; then
    echo "[litellm-login] '${CRUSH_REAL_BIN}' not found on PATH; skipping launch (login is already done)." >&2
  fi
else
  echo "[litellm-login] login failed; not launching crush." >&2
fi
