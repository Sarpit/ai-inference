#!/usr/bin/env bash
# Deletes every LiteLLM key created by provision_litellm_keys.sh.
#
# Source of truth: LiteLLM's own /key/list, filtered to key_alias values
# starting with ALIAS_PREFIX ("auto-<user_id>" — the alias every key from
# provision_litellm_keys.sh gets). This works whether or not STATE_FILE
# (litellm_keys.csv) still exists. If STATE_FILE is present it's removed
# too (backed up with a timestamp) once the matching keys are deleted.
#
# This will NOT touch keys you created by hand or via the UI, unless they
# happen to share the "auto-" alias prefix — check the dry-run list below.
#
# Requires python3, to walk LiteLLM's paginated /key/list JSON reliably
# (no jq dependency, but this genuinely needs real JSON parsing).
#
# Usage:
#   ./scripts/flush_litellm_keys.sh            # dry run: lists matches
#   ./scripts/flush_litellm_keys.sh --yes       # actually deletes
#   CONFIRM=yes ./scripts/flush_litellm_keys.sh # same, non-interactive

set -uo pipefail

LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://localhost:9001}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-change-me-to-a-secure-master-key}"
STATE_FILE="${STATE_FILE:-./litellm_keys.csv}"
ALIAS_PREFIX="${ALIAS_PREFIX:-auto-}"

CONFIRM="${CONFIRM:-no}"
[[ "${1:-}" == "--yes" ]] && CONFIRM=yes

if ! command -v python3 >/dev/null 2>&1; then
  echo "[error] python3 is required for this script (reliable JSON pagination handling)." >&2
  echo "        Without it: open the LiteLLM UI's Virtual Keys page, sort/search for" >&2
  echo "        aliases starting with '${ALIAS_PREFIX}', and delete them by hand." >&2
  exit 1
fi

echo "Fetching keys with alias prefix '${ALIAS_PREFIX}' from ${LITELLM_BASE_URL}..."

# Paginate through /key/list, collect (key_alias, token) pairs whose alias
# starts with ALIAS_PREFIX. `token` here is the identifier LiteLLM's list
# endpoint returns for each key (not the raw sk-... secret) and is what
# /key/delete accepts back for deletion.
matches_json=$(python3 - "$LITELLM_BASE_URL" "$LITELLM_MASTER_KEY" "$ALIAS_PREFIX" <<'PY'
import json
import sys
import urllib.request

base_url, master_key, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
headers = {"Authorization": f"Bearer {master_key}"}

matches = []
page = 1
while True:
    # return_full_object=true: without it, some LiteLLM versions return
    # "keys" as a bare list of key strings with no alias info to filter on.
    req = urllib.request.Request(
        f"{base_url}/key/list?page={page}&size=100&return_full_object=true",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"[error] /key/list request failed: {e}", file=sys.stderr)
        sys.exit(1)

    keys = data.get("keys", []) if isinstance(data, dict) else data
    for k in keys:
        if not isinstance(k, dict):
            # Still a bare string even with return_full_object=true — no
            # alias to filter on, so we can't safely tell it apart from a
            # hand-created key. Skip it rather than risk deleting the wrong
            # thing.
            continue
        alias = k.get("key_alias") or ""
        token = k.get("token") or k.get("key_name") or ""
        if alias.startswith(prefix) and token:
            matches.append({"key_alias": alias, "token": token})

    total_pages = data.get("total_pages", page) if isinstance(data, dict) else page
    if page >= total_pages or not keys:
        break
    page += 1

print(json.dumps(matches))
PY
) || exit 1

count=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$matches_json")

if [[ "$count" -eq 0 ]]; then
  echo "[info] no keys found with alias prefix '${ALIAS_PREFIX}'"
  exit 0
fi

echo "Found ${count} key(s):"
python3 -c 'import json,sys
for m in json.loads(sys.argv[1]):
    print(f"  - {m[\"key_alias\"]}")' "$matches_json"

if [[ "$CONFIRM" != "yes" ]]; then
  echo
  echo "Dry run only — no keys deleted. Re-run with --yes (or CONFIRM=yes) to actually delete."
  exit 0
fi

tokens_json=$(python3 -c 'import json,sys
print(json.dumps([m["token"] for m in json.loads(sys.argv[1])]))' "$matches_json")

body="{\"keys\": ${tokens_json}}"
response=$(curl -sS -w $'\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "$body" \
  "${LITELLM_BASE_URL}/key/delete")
status="${response##*$'\n'}"
resp_body="${response%$'\n'*}"

if [[ "$status" != "200" ]]; then
  echo "[error] delete request failed (HTTP ${status}): ${resp_body}" >&2
  exit 1
fi

echo "Deleted ${count} key(s)."

if [[ -f "$STATE_FILE" ]]; then
  backup="${STATE_FILE}.flushed-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$STATE_FILE" "$backup"
  chmod 600 "$backup"
  echo "State file cleared; prior contents backed up to ${backup}"
fi
