#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

load_env_file() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "${line}"
    fi
  done < "${ENV_FILE}"
}

if [[ -f "${ENV_FILE}" ]]; then
  load_env_file
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "python3 or python is required to parse Cloudflare API responses." >&2
  exit 1
fi

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
}

cf_request() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"
  local response

  if [[ -n "${payload}" ]]; then
    response="$(curl --silent --show-error --fail \
      -X "${method}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "${url}")"
  else
    response="$(curl --silent --show-error --fail \
      -X "${method}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      "${url}")"
  fi

  printf '%s' "${response}" | "${PYTHON_BIN}" -c 'import json, sys
body = json.load(sys.stdin)
if not body.get("success"):
    errors = body.get("errors") or []
    if errors:
        for item in errors:
            print(item.get("message", "Cloudflare API returned an unknown error."), file=sys.stderr)
    else:
        print("Cloudflare API returned success=false.", file=sys.stderr)
    sys.exit(1)
'

  printf '%s' "${response}"
}

build_payload() {
  local fqdn="$1"
  local ip="$2"
  local proxied="$3"
  "${PYTHON_BIN}" - "$fqdn" "$ip" "$proxied" <<'PY'
import json
import sys

fqdn, ip, proxied = sys.argv[1:4]
payload = {
    "type": "A",
    "name": fqdn,
    "content": ip,
    "ttl": 1,
    "proxied": proxied.lower() == "true",
    "comment": "Managed by cloudflare-dns.sh",
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

upsert_a_record() {
  local fqdn="$1"
  local ip="$2"
  local proxied="$3"
  local lookup_url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${fqdn}"
  local payload
  local lookup_response
  local status

  payload="$(build_payload "${fqdn}" "${ip}" "${proxied}")"
  lookup_response="$(cf_request GET "${lookup_url}")"
  status="$(printf '%s' "${lookup_response}" | "${PYTHON_BIN}" -c 'import json, sys
fqdn = sys.argv[1].rstrip(".")
records = json.load(sys.stdin).get("result", [])
a_record = None
conflicts = []

for record in records:
    name = (record.get("name") or "").rstrip(".")
    if name != fqdn:
        continue
    record_type = record.get("type")
    if record_type == "A" and a_record is None:
        a_record = record
    elif record_type != "A":
        conflicts.append(record_type)

if conflicts:
    print("conflict|" + ",".join(conflicts))
elif a_record:
    print("update|" + a_record["id"])
else:
    print("create|")
' "$fqdn")"

  case "${status%%|*}" in
    create)
      cf_request POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" "${payload}" >/dev/null
      printf 'Created A record: %s -> %s\n' "${fqdn}" "${ip}"
      ;;
    update)
      local record_id="${status#*|}"
      cf_request PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" "${payload}" >/dev/null
      printf 'Updated A record: %s -> %s\n' "${fqdn}" "${ip}"
      ;;
    conflict)
      printf 'Cannot create A record for %s because Cloudflare already has conflicting record types: %s\n' "${fqdn}" "${status#*|}" >&2
      exit 1
      ;;
    *)
      printf 'Unexpected Cloudflare lookup state for %s: %s\n' "${fqdn}" "${status}" >&2
      exit 1
      ;;
  esac
}

require_env CF_API_TOKEN
require_env CF_ZONE_ID
require_env VPS_IP
require_env DOMAIN

COOLIFY_SUBDOMAIN="${COOLIFY_SUBDOMAIN:-coolify}"
N8N_SUBDOMAIN="${N8N_SUBDOMAIN:-n8n}"
CF_PROXIED="${CF_PROXIED:-false}"

upsert_a_record "${COOLIFY_SUBDOMAIN}.${DOMAIN}" "${VPS_IP}" "${CF_PROXIED}"
upsert_a_record "${N8N_SUBDOMAIN}.${DOMAIN}" "${VPS_IP}" "${CF_PROXIED}"

printf '\nDone. Records were created in DNS-only mode by default (proxied=%s).\n' "${CF_PROXIED}"
printf 'If you later want Cloudflare proxying, set CF_PROXIED=true and run the script again.\n'
