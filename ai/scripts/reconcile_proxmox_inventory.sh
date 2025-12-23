#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${CLUSTER_CONFIG_FILE:=${REPO_ROOT}/config/clusters/prox-n100.yaml}"
: "${PROXMOX_INVENTORY_FILE:=${REPO_ROOT}/ai/state/proxmox_inventory.json}"

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[inventory] starting Proxmox inventory snapshot at ${timestamp}"

extract_controller_ip() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  python3 - "$config_file" <<'PY'
import re
import sys

path = sys.argv[1]
block_pattern = re.compile(r'^(?P<indent>[ \t]*)controller\s*:\s*$')
key_pattern = re.compile(r'^[ \t]*ip\s*:\s*(\S+)')
inside = False
block_indent = 0

try:
    with open(path) as fh:
        for line in fh:
            stripped = line.rstrip('\n')
            if not inside:
                match = block_pattern.match(stripped)
                if match:
                    inside = True
                    block_indent = len(match.group('indent'))
                continue
            if not stripped.strip():
                continue
            indent = len(stripped) - len(stripped.lstrip())
            if indent <= block_indent:
                break
            match = key_pattern.match(stripped)
            if match:
                print(match.group(1).strip())
                sys.exit(0)
except FileNotFoundError:
    pass
PY
}

if ! command -v qm >/dev/null 2>&1; then
  echo "[inventory] qm binary missing; cannot collect inventory" >&2
  exit 1
fi

controller_ip="$(extract_controller_ip "${CLUSTER_CONFIG_FILE}")"
controller_ip="${controller_ip//$'\r'/}"
controller_ip="${controller_ip//$'\n'/}"

echo "[inventory] gathered controller ip from ${CLUSTER_CONFIG_FILE}: ${controller_ip:-<none>}"

echo "[inventory] qm list"
qm list || true

inventory_format="json"
inventory_output=""
echo "[inventory] capturing qm list --full (attempting json output)"
if inventory_output="$(qm list --full --output-format json 2>/dev/null)"; then
  inventory_format="json"
else
  inventory_format="text"
  echo "[inventory] fallback to qm list --full text output"
  inventory_output="$(qm list --full 2>/dev/null || true)"
fi

normalized_vms="$(printf '%s' "$inventory_output" | python3 - <<'PY'
import json
import re
import sys

text = sys.stdin.read()
if not text.strip():
    print("[]")
    sys.exit(0)

def normalize_entries(entries):
    result = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        normalized = {}
        for key, value in entry.items():
            if value is None:
                continue
            normalized[key.lower()] = value
        if "vmid" in normalized:
            normalized["vmid"] = str(normalized["vmid"])
        result.append(normalized)
    return result

def parse_table(text):
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if not lines or len(lines) < 2:
        return []
    header = [part.lower().strip() for part in re.split(r'\s{2,}', lines[0].strip()) if part.strip()]
    rows = []
    for line in lines[1:]:
        parts = [part.strip() for part in re.split(r'\s{2,}', line.strip()) if part.strip()]
        if not parts:
            continue
        entry = {}
        for idx, key in enumerate(header):
            if idx >= len(parts):
                break
            entry[key] = parts[idx]
        rows.append(entry)
    return rows

entries = None
try:
    parsed = json.loads(text)
except json.JSONDecodeError:
    parsed = None

if parsed is None:
    entries = parse_table(text)
else:
    if isinstance(parsed, dict):
        candidate = parsed.get("data") or parsed.get("result")
        if isinstance(candidate, list):
            entries = candidate
        elif candidate is not None:
            entries = [candidate]
        else:
            entries = []
    elif isinstance(parsed, list):
        entries = parsed
    else:
        entries = [parsed]

print(json.dumps(normalize_entries(entries)))
PY
)"

echo "[inventory] parsed $(printf '%s' "$normalized_vms" | python3 - <<'PY'
import json, sys

data = json.load(sys.stdin)
print(len(data))
PY
  ) VMs (format=${inventory_format})"

vmids="$(printf '%s' "$normalized_vms" | python3 - <<'PY'
import json, sys

for vm in json.load(sys.stdin):
    vmid = vm.get("vmid")
    if vmid is not None:
        print(vmid)
PY
)"

if [ -n "$vmids" ]; then
  echo "[inventory] enumerating VM statuses"
  while IFS= read -r vmid; do
    [ -z "$vmid" ] && continue
    echo "[inventory] vmid=${vmid}:"
    qm status "$vmid" || true
  done <<< "$vmids"
else
  echo "[inventory] no VMs discovered"
fi

payload="$(printf '%s' "$normalized_vms" | python3 - "$timestamp" "${controller_ip:-}" <<'PY'
import json
import sys

ts = sys.argv[1]
controller = sys.argv[2]
vms = json.load(sys.stdin)
payload = {"timestamp": ts, "controller_ip": controller, "vms": vms}
print(json.dumps(payload, indent=2))
PY
)"

mkdir -p "$(dirname "${PROXMOX_INVENTORY_FILE}")"
printf '%s\n' "$payload" > "${PROXMOX_INVENTORY_FILE}"
echo "[inventory] wrote ${PROXMOX_INVENTORY_FILE} (controller_ip=${controller_ip:-<none>})"
echo "[inventory] snapshot complete at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
