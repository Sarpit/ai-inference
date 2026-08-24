#!/usr/bin/env bash
# Deletes every key recorded in STATE_FILE (i.e. everything
# provision_litellm_keys.sh has created) from LiteLLM, and clears the file.
#
# This is destructive: it revokes live API keys. It will NOT touch any key
# you created by hand or via the UI — only rows present in STATE_FILE.
#
# Usage:
#   ./scripts/flush_litellm_keys.sh            # prints what would be deleted
#   ./scripts/flush_litellm_keys.sh --yes       # actually deletes
#   CONFIRM=yes ./scripts/flush_litellm_keys.sh # same, for non-interactive use

set -uo pipefail

LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://localhost:9001}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-change-me-to-a-secure-master-key}"
STATE_FILE="${STATE_FILE:-./litellm_keys.csv}"
BATCH_SIZE=50

CONFIRM="${CONFIRM:-no}"
[[ "${1:-}" == "--yes" ]] && CONFIRM=yes

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[info] ${STATE_FILE} not found; nothing to flush"
  exit 0
fi

mapfile -t KEYS < <(awk -F'\t' 'NF >= 2 { print $2 }' "$STATE_FILE")

if [[ "${#KEYS[@]}" -eq 0 ]]; then
  echo "[info] ${STATE_FILE} has no key rows; nothing to flush"
  exit 0
fi

echo "About to delete ${#KEYS[@]} key(s) recorded in ${STATE_FILE} from ${LITELLM_BASE_URL}:"
awk -F'\t' 'NF >= 2 { printf "  - %s (%s...)\n", $1, substr($2,1,12) }' "$STATE_FILE"

if [[ "$CONFIRM" != "yes" ]]; then
  echo
  echo "Dry run only — no keys deleted. Re-run with --yes (or CONFIRM=yes) to actually delete."
  exit 0
fi

# Build a JSON array of key strings without jq.
build_batch_json() {
  local -n batch_ref=$1
  local json="["
  local first=true
  local k
  for k in "${batch_ref[@]}"; do
    $first || json+=","
    first=false
    json+="\"${k}\""
  done
  json+="]"
  printf '%s' "$json"
}

deleted=0
failed=0
batch=()
for key in "${KEYS[@]}"; do
  batch+=("$key")
  if [[ "${#batch[@]}" -eq "$BATCH_SIZE" ]]; then
    body="{\"keys\": $(build_batch_json batch)}"
    response=$(curl -sS -w $'\n%{http_code}' -X POST \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "${LITELLM_BASE_URL}/key/delete")
    status="${response##*$'\n'}"
    if [[ "$status" == "200" ]]; then
      deleted=$((deleted + ${#batch[@]}))
    else
      echo "[error] batch delete failed (HTTP ${status}): ${response%$'\n'*}" >&2
      failed=$((failed + ${#batch[@]}))
    fi
    batch=()
  fi
done
if [[ "${#batch[@]}" -gt 0 ]]; then
  body="{\"keys\": $(build_batch_json batch)}"
  response=$(curl -sS -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${LITELLM_BASE_URL}/key/delete")
  status="${response##*$'\n'}"
  if [[ "$status" == "200" ]]; then
    deleted=$((deleted + ${#batch[@]}))
  else
    echo "[error] batch delete failed (HTTP ${status}): ${response%$'\n'*}" >&2
    failed=$((failed + ${#batch[@]}))
  fi
fi

echo
echo "Deleted: ${deleted}, failed: ${failed}"

if [[ "$failed" -eq 0 ]]; then
  backup="${STATE_FILE}.flushed-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$STATE_FILE" "$backup"
  chmod 600 "$backup"
  echo "State file cleared; prior contents backed up to ${backup}"
else
  echo "[warn] leaving ${STATE_FILE} in place since some deletes failed — inspect and re-run" >&2
fi
