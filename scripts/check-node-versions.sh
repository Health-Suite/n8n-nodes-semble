#!/bin/bash

# Node Version Checker for n8n workflows
# Detects nodes running below their current maximum typeVersion (the "node is out of date" UI warning).
#
# Approach:
#   1. Build a registry of {nodeName: defaultVersion} by inspecting *.node.js files inside the
#      running n8n container (docker exec locally, SSH docker exec on production).
#   2. Fetch all workflows via the n8n public API.
#   3. Cross-reference each workflow's nodes against the registry and report outdated ones.
#
# Usage:
#   ./check-node-versions.sh [local|production]

set -e

WORKSPACE_ROOT="/Users/mikehatcher/Websites/the-health-suite"
ENV_FILE="$WORKSPACE_ROOT/.env"

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ .env file not found at $ENV_FILE"
    exit 1
fi

ENVIRONMENT="${1:-local}"

# Colour codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_status() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# ─── Environment config ────────────────────────────────────────────────────────

if [ "$ENVIRONMENT" = "production" ]; then
    API_ENDPOINT="$N8N_PROD_API_ENDPOINT"
    API_KEY="$N8N_PROD_API_KEY"
    CONTAINER_NAME="${N8N_PROD_CONTAINER_NAME:-n8n}"
else
    API_ENDPOINT="${N8N_LOCAL_API_ENDPOINT:-http://localhost:5678/api/v1}"
    API_KEY="$N8N_LOCAL_API_KEY"
    CONTAINER_NAME="n8n-semble-test"
fi

if [ -z "$API_KEY" ]; then
    print_status "$RED" "❌ API key not set for $ENVIRONMENT environment"
    exit 1
fi

# ─── Step 1: Build node version registry from the container ───────────────────

print_status "$BLUE" "🔍 Building node version registry from $ENVIRONMENT container..."

# Node.js script that scans all *.node.js files and outputs JSON: {"nodeName": defaultVersion, ...}
NODE_SCAN_SCRIPT='
const fs = require("fs");
const path = require("path");

const BASE_DIRS = [
  "/usr/local/lib/node_modules/n8n/node_modules/n8n-nodes-base/dist/nodes",
  "/home/node/.n8n/nodes/node_modules"
];

const registry = {};

function scanDir(dir) {
  if (!fs.existsSync(dir)) return;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      scanDir(fullPath);
    } else if (entry.isFile() && entry.name.endsWith(".node.js")) {
      try {
        const mod = require(fullPath);
        for (const key of Object.keys(mod)) {
          try {
            const inst = new mod[key]();
            const desc = inst.description;
            if (desc && desc.name && desc.defaultVersion !== undefined) {
              registry[desc.name] = desc.defaultVersion;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }
}

BASE_DIRS.forEach(scanDir);
process.stdout.write(JSON.stringify(registry));
'

# Write scan script to a temp file and copy into container
SCAN_SCRIPT_HOST="/tmp/n8n_node_scan_$$.js"
printf '%s' "$NODE_SCAN_SCRIPT" > "$SCAN_SCRIPT_HOST"

if [ "$ENVIRONMENT" = "production" ]; then
    if [ -z "$N8N_PROD_HOST" ] || [ -z "$N8N_PROD_USER" ] || [ -z "$N8N_PROD_PWD" ]; then
        print_status "$YELLOW" "⚠️  Production SSH not configured — falling back to workflow-based version inference"
        REGISTRY_JSON=""
    else
        # Copy script via SSH and execute
        sshpass -p "$N8N_PROD_PWD" scp -o StrictHostKeyChecking=no \
            "$SCAN_SCRIPT_HOST" "$N8N_PROD_USER@$N8N_PROD_HOST:/tmp/n8n_node_scan.js"
        REGISTRY_JSON=$(sshpass -p "$N8N_PROD_PWD" ssh -o StrictHostKeyChecking=no \
            "$N8N_PROD_USER@$N8N_PROD_HOST" \
            "docker cp /tmp/n8n_node_scan.js $CONTAINER_NAME:/tmp/n8n_node_scan.js && \
             docker exec $CONTAINER_NAME node /tmp/n8n_node_scan.js" 2>/dev/null || echo "")
    fi
else
    docker cp "$SCAN_SCRIPT_HOST" "$CONTAINER_NAME:/tmp/n8n_node_scan.js" >/dev/null 2>&1
    REGISTRY_JSON=$(docker exec "$CONTAINER_NAME" node /tmp/n8n_node_scan.js 2>/dev/null || echo "")
fi

rm -f "$SCAN_SCRIPT_HOST"

if [ -z "$REGISTRY_JSON" ] || [ "$REGISTRY_JSON" = "{}" ]; then
    print_status "$YELLOW" "⚠️  Could not build registry from container — using workflow-based inference"
    USE_INFERENCE=true
else
    NODE_COUNT=$(echo "$REGISTRY_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
    print_status "$GREEN" "✅ Registry built: $NODE_COUNT node types indexed"
    USE_INFERENCE=false
fi

# ─── Step 2: Fetch all workflows via API ──────────────────────────────────────

print_status "$BLUE" "📋 Fetching workflows from $ENVIRONMENT API..."

WORKFLOWS_JSON=$(curl -s \
    -H "X-N8N-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    "${API_ENDPOINT}/workflows?limit=250" 2>/dev/null)

# Handle pagination: keep fetching if there's a cursor
CURSOR=$(echo "$WORKFLOWS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('nextCursor') or '')" 2>/dev/null || echo "")
while [ -n "$CURSOR" ] && [ "$CURSOR" != "None" ]; do
    PAGE_JSON=$(curl -s \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        "${API_ENDPOINT}/workflows?limit=250&cursor=${CURSOR}" 2>/dev/null)
    # Merge data arrays
    WORKFLOWS_JSON=$(python3 -c "
import sys, json
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
a['data'] = a.get('data', []) + b.get('data', [])
a['nextCursor'] = b.get('nextCursor')
print(json.dumps(a))
" "$WORKFLOWS_JSON" "$PAGE_JSON")
    CURSOR=$(echo "$WORKFLOWS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('nextCursor') or '')" 2>/dev/null || echo "")
done

INACTIVE_JSON='{"data":[]}'

WORKFLOW_COUNT=$(echo "$WORKFLOWS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); wfs=d.get('data',d) if isinstance(d,dict) else d; print(len(wfs))" 2>/dev/null || echo "0")

print_status "$GREEN" "✅ Found $WORKFLOW_COUNT workflow(s)"

# ─── Step 3: Cross-reference and report ───────────────────────────────────────

print_status "$BLUE" "🔎 Analysing node versions..."
echo ""

ANALYSIS_SCRIPT="
import sys, json

registry      = json.loads(sys.argv[1]) if sys.argv[1] else {}
use_inference = sys.argv[2] == 'true'
active_file   = sys.argv[3]
inactive_file = sys.argv[4]

def parse_workflows(path):
    try:
        with open(path) as f:
            d = json.load(f)
        if isinstance(d, list):
            return d
        return d.get('data', [])
    except Exception:
        return []

active_wfs   = parse_workflows(active_file)
inactive_wfs = parse_workflows(inactive_file)
all_wfs      = active_wfs + inactive_wfs

# If using inference, build registry from the max typeVersion seen across all workflows
if use_inference:
    for wf in all_wfs:
        for node in wf.get('nodes', []):
            t = node.get('type', '').replace('n8n-nodes-base.', '')
            v = node.get('typeVersion')
            if t and v is not None:
                registry[t] = max(registry.get(t, 0), v)

# Analyse
outdated_workflows = {}
all_seen_types     = set()

for wf in all_wfs:
    wf_name   = wf.get('name', 'Unknown')
    wf_id     = wf.get('id', '?')
    wf_active = wf.get('active', False)
    outdated  = []

    for node in wf.get('nodes', []):
        raw_type    = node.get('type', '')
        node_type   = raw_type.replace('n8n-nodes-base.', '')
        node_name   = node.get('name', raw_type)
        type_ver    = node.get('typeVersion')
        all_seen_types.add(raw_type)

        if type_ver is None:
            continue

        # Skip internal/utility node types
        if raw_type.startswith('@n8n/n8n-nodes-langchain') or \
           raw_type in ('n8n-nodes-base.stickyNote', 'n8n-nodes-base.noOp'):
            continue

        max_ver = registry.get(node_type)
        if max_ver is None:
            # Try with full type string
            max_ver = registry.get(raw_type)

        if max_ver is not None and type_ver < max_ver:
            outdated.append({
                'node_name': node_name,
                'type':      raw_type,
                'current':   type_ver,
                'latest':    max_ver
            })

    if outdated:
        outdated_workflows[wf_id] = {
            'name':    wf_name,
            'active':  wf_active,
            'nodes':   outdated
        }

# Output report
if not outdated_workflows:
    print('ALL_CURRENT')
else:
    print(json.dumps(outdated_workflows, indent=2))
    print('TOTAL:' + str(len(outdated_workflows)))
"

ACTIVE_TMP="/tmp/n8n_active_wfs_$$.json"
INACTIVE_TMP="/tmp/n8n_inactive_wfs_$$.json"
echo "$WORKFLOWS_JSON" > "$ACTIVE_TMP"
echo "$INACTIVE_JSON"  > "$INACTIVE_TMP"

REPORT=$(python3 -c "$ANALYSIS_SCRIPT" "$REGISTRY_JSON" "$USE_INFERENCE" "$ACTIVE_TMP" "$INACTIVE_TMP")

rm -f "$ACTIVE_TMP" "$INACTIVE_TMP"

# ─── Step 4: Format output ────────────────────────────────────────────────────

echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  n8n Node Version Report — ${ENVIRONMENT}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""

if echo "$REPORT" | grep -q "^ALL_CURRENT"; then
    print_status "$GREEN" "✅ All workflow nodes are running their current version."
    echo ""
else
    OUTDATED_COUNT=$(echo "$REPORT" | grep "^TOTAL:" | cut -d: -f2)
    JSON_DATA=$(echo "$REPORT" | grep -v "^TOTAL:")

    print_status "$YELLOW" "⚠️  Found outdated nodes in $OUTDATED_COUNT workflow(s):"
    echo ""

    echo "$JSON_DATA" | python3 -c "
import sys, json

data = json.load(sys.stdin)
for wf_id, wf in data.items():
    status = '🟢 active' if wf['active'] else '⚫ inactive'
    print(f\"  Workflow: {wf['name']} ({wf_id}) [{status}]\")
    for node in wf['nodes']:
        print(f\"    ⚠️   {node['node_name']} ({node['type']})\")
        print(f\"         typeVersion: {node['current']}  →  latest: {node['latest']}\")
    print()
"
fi

if [ "$USE_INFERENCE" = "true" ]; then
    echo ""
    print_status "$CYAN" "ℹ️  Version registry was inferred from workflow data (max version seen per type)."
    print_status "$CYAN" "   Run with a live container for authoritative defaultVersion values."
fi

echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
