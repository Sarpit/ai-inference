#!/usr/bin/env bash
# Provisions a LiteLLM virtual API key for each user in USER_IDS (idempotent).
#
# Idempotency: LiteLLM's own DB is the source of truth. For each user we first
# ask LiteLLM (GET /user/info) whether a key already exists; only if not do we
# call POST /key/generate. The local STATE_FILE is a cache/audit log so re-runs
# skip the API round-trip for users we already know about, but it is never the
# only thing preventing a duplicate key.
#
# No packages are downloaded at runtime: curl is required, python3 is used for
# JSON handling when present, and everything falls back to grep/sed otherwise.

set -uo pipefail
umask 077

# ============================================================
# Configuration (edit these, or override via environment)
# ============================================================
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://localhost:9001}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-change-me-to-a-secure-master-key}"

STATE_FILE="${STATE_FILE:-./litellm_keys.csv}"   # user_id<TAB>key<TAB>created_at

KEY_DURATION="${KEY_DURATION:-30d}"
MAX_BUDGET="${MAX_BUDGET:-10}"
TPM_LIMIT="${TPM_LIMIT:-100000}"
RPM_LIMIT="${RPM_LIMIT:-60}"
TEAM_ID="${TEAM_ID:-}"        # optional; leave empty to omit from the request

# Users to provision — always the authoritative list of who gets a key. If
# USE_LDAP_LOOKUP=true, this list is looked up against LDAP (see
# fetch_users_from_ldap below) to confirm each id exists rather than being
# replaced by a full directory dump.
USER_IDS=(
  "sample_user_a"
  "sample_user_b"
)

# ============================================================
# LDAP placeholders (only used by fetch_users_from_ldap)
# ============================================================
USE_LDAP_LOOKUP="${USE_LDAP_LOOKUP:-false}"

LDAP_SERVER_HOST="${LDAP_SERVER_HOST:-ldapserver.example.com}"
LDAP_SERVER_PORT="${LDAP_SERVER_PORT:-389}"
LDAP_SEARCH_BASE="${LDAP_SEARCH_BASE:-dc=auth,dc=example,dc=com}"
LDAP_SEARCH_FILTER="${LDAP_SEARCH_FILTER:-(objectClass=person)}"
LDAP_ATTRIBUTE_FOR_USERNAME="${LDAP_ATTRIBUTE_FOR_USERNAME:-uid}"

# Leave both empty for an anonymous bind (no credentials sent). Set
# LDAP_BIND_DN to require a simple bind instead.
LDAP_BIND_DN="${LDAP_BIND_DN:-}"
LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD:-}"

# Confirms each id in USER_IDS actually exists in LDAP, and narrows USER_IDS
# down to only the ones that do (so a typo'd/removed id is silently dropped
# rather than silently skipped as "already provisioned"). Never expands
# USER_IDS beyond what was already listed — it does NOT dump the directory.
# No-op (with a warning) if ldapsearch isn't installed. When LDAP_BIND_DN is
# set, the bind password is passed via process substitution (-y), never as a
# literal argv entry, so it doesn't show up in `ps`. When LDAP_BIND_DN is
# empty, an anonymous bind is used instead.
fetch_users_from_ldap() {
  if ! command -v ldapsearch >/dev/null 2>&1; then
    echo "[warn] ldapsearch not found; USE_LDAP_LOOKUP requested but skipped, using hardcoded USER_IDS" >&2
    return 0
  fi

  if [[ "${#USER_IDS[@]}" -eq 0 ]]; then
    echo "[warn] USER_IDS is empty; nothing to look up" >&2
    return 0
  fi

  local bind_args=()
  if [[ -n "$LDAP_BIND_DN" ]]; then
    bind_args=(-D "$LDAP_BIND_DN" -y <(printf '%s' "$LDAP_BIND_PASSWORD"))
  fi

  # (&<LDAP_SEARCH_FILTER>(|(uid=a)(uid=b)...)) — scopes the search to exactly
  # the requested ids instead of every entry matching LDAP_SEARCH_FILTER.
  local id_clauses="" uid
  for uid in "${USER_IDS[@]}"; do
    id_clauses+="(${LDAP_ATTRIBUTE_FOR_USERNAME}=${uid})"
  done
  local scoped_filter="(&${LDAP_SEARCH_FILTER}(|${id_clauses}))"

  local raw
  raw=$(ldapsearch -x -H "ldap://${LDAP_SERVER_HOST}:${LDAP_SERVER_PORT}" \
    "${bind_args[@]}" \
    -b "${LDAP_SEARCH_BASE}" "${scoped_filter}" "${LDAP_ATTRIBUTE_FOR_USERNAME}" 2>/dev/null) \
    || { echo "[error] ldapsearch failed; keeping hardcoded USER_IDS" >&2; return 1; }

  local fetched=()
  while IFS= read -r line; do
    fetched+=("$line")
  done < <(printf '%s\n' "$raw" | awk -v attr="${LDAP_ATTRIBUTE_FOR_USERNAME}:" \
    'tolower($1) == tolower(attr) {print $2}')

  if [[ "${#fetched[@]}" -eq 0 ]]; then
    echo "[warn] LDAP lookup returned no users; keeping hardcoded USER_IDS" >&2
    return 0
  fi

  if [[ "${#fetched[@]}" -lt "${#USER_IDS[@]}" ]]; then
    echo "[warn] LDAP confirmed ${#fetched[@]}/${#USER_IDS[@]} requested user(s); the rest were not found and will be skipped" >&2
  fi

  USER_IDS=("${fetched[@]}")
  echo "[info] loaded ${#USER_IDS[@]} user(s) from LDAP" >&2
}

# ============================================================
# Helpers
# ============================================================

# GET a LiteLLM endpoint with master-key auth. Prints "STATUS\nBODY".
litellm_get() {
  local path="$1"
  curl -sS -w $'\n%{http_code}' \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    "${LITELLM_BASE_URL}${path}"
}

# POST JSON to a LiteLLM endpoint with master-key auth. Prints "STATUS\nBODY".
litellm_post() {
  local path="$1" data="$2"
  curl -sS -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${LITELLM_BASE_URL}${path}"
}

# Splits the "$'\n%{http_code}'"-terminated response into STATUS/BODY globals.
split_response() {
  local response="$1"
  RESP_STATUS="${response##*$'\n'}"
  RESP_BODY="${response%$'\n'*}"
}

# Extracts the "key" field from a LiteLLM /key/generate JSON response.
extract_key() {
  local body="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, json
try:
    print(json.loads(sys.stdin.read()).get("key", ""))
except Exception:
    pass' <<<"$body"
  else
    printf '%s' "$body" | grep -o '"key":"[^"]*"' | head -n1 | cut -d'"' -f4
  fi
}

# True (0) if LiteLLM already has at least one key for this user_id.
user_has_existing_key() {
  local uid="$1" response
  response=$(litellm_get "/user/info?user_id=${uid}")
  split_response "$response"

  if [[ "$RESP_STATUS" != "200" ]]; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, json
try:
    data = json.loads(sys.stdin.read())
    keys = data.get("keys") or []
    sys.exit(0 if len(keys) > 0 else 1)
except Exception:
    sys.exit(1)' <<<"$RESP_BODY"
    return $?
  else
    printf '%s' "$RESP_BODY" | grep -q '"token"'
  fi
}

state_file_has_user() {
  local uid="$1"
  [[ -f "$STATE_FILE" ]] || return 1
  awk -F'\t' -v u="$uid" '$1 == u { found=1 } END { exit !found }' "$STATE_FILE"
}

# Builds the JSON body for /key/generate.
build_key_request() {
  local uid="$1" team_field=""
  if [[ -n "$TEAM_ID" ]]; then
    team_field="\"team_id\": \"${TEAM_ID}\","
  fi
  cat <<EOF
{
  "user_id": "${uid}",
  "key_alias": "auto-${uid}",
  "duration": "${KEY_DURATION}",
  ${team_field}
  "max_budget": ${MAX_BUDGET},
  "tpm_limit": ${TPM_LIMIT},
  "rpm_limit": ${RPM_LIMIT}
}
EOF
}

# Provisions (or skips) a single user. Never lets a failure abort the batch.
process_user() {
  local uid="$1"

  if state_file_has_user "$uid"; then
    echo "[skip] ${uid}: already recorded in ${STATE_FILE}"
    return 0
  fi

  if user_has_existing_key "$uid"; then
    echo "[skip] ${uid}: LiteLLM already has a key for this user (not in local state file — add it manually if you need the value on record)"
    return 0
  fi

  echo "[create] ${uid}: requesting new key..."
  local response
  response=$(litellm_post "/key/generate" "$(build_key_request "$uid")")
  split_response "$response"

  if [[ "$RESP_STATUS" != "200" ]]; then
    echo "[error] ${uid}: /key/generate returned HTTP ${RESP_STATUS}: ${RESP_BODY}" >&2
    return 1
  fi

  local key
  key=$(extract_key "$RESP_BODY")
  if [[ -z "$key" ]]; then
    echo "[error] ${uid}: could not extract key from response: ${RESP_BODY}" >&2
    return 1
  fi

  printf '%s\t%s\t%s\n' "$uid" "$key" "$(date -u +%FT%TZ)" >> "$STATE_FILE"
  echo "[ok] ${uid}: key created and saved"
  return 0
}

# ============================================================
# Main
# ============================================================
main() {
  if [[ "$USE_LDAP_LOOKUP" == "true" ]]; then
    fetch_users_from_ldap
  fi

  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"

  local created=0 skipped=0 failed=0
  for uid in "${USER_IDS[@]}"; do
    local before_lines
    before_lines=$(wc -l < "$STATE_FILE")
    if process_user "$uid"; then
      local after_lines
      after_lines=$(wc -l < "$STATE_FILE")
      if [[ "$after_lines" -gt "$before_lines" ]]; then
        created=$((created + 1))
      else
        skipped=$((skipped + 1))
      fi
    else
      failed=$((failed + 1))
    fi
  done

  echo
  echo "Done: ${created} created, ${skipped} skipped, ${failed} failed. State: ${STATE_FILE}"
  [[ "$failed" -eq 0 ]]
}

main "$@"
