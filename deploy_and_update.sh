#!/usr/bin/env bash
#
# deploy_and_update.sh — Deploy this agent to Vertex AI, smoke-test it,
# register it (with all enabled platforms) in The Forum's Firestore via
# register_agent.py, and delete the previous Reasoning Engine.
#
# Usage:
#   ./deploy_and_update.sh
#
# Prerequisites:
#   - gcloud CLI authenticated
#   - ADK installed (path in ADK_BIN, or on PATH)
#   - terraform/terraform.tfvars present (used by register_agent.py)
#   - At least one platform secret populated in the agent project's Secret
#     Manager (slack token, telegram token, discord token, or chat SA key)
#
# Configuration is read from .env in this directory. Required keys:
#   GOOGLE_CLOUD_PROJECT (= the Forum's project; the Reasoning Engine
#     lives in this project administratively, alongside every other agent),
#   AGENT_PROJECT_ID (= this agent's own project; the per-agent SA, secrets,
#     and staging bucket live here),
#   AGENT_DISPLAY_NAME, FORUM_PROJECT_ID (same as GOOGLE_CLOUD_PROJECT),
#   ADK_BIN, ADK_PYTHON.
#
# The Reasoning Engine RUNS AS the per-agent SA via the `service_account`
# field in .agent_engine_config.json (next to this script). Without that
# config file the engine would inherit the Forum project's default
# compute SA — shared with every other agent — which defeats per-agent
# isolation. Confirm the file is present and points at the right SA.

set -euo pipefail

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    echo "Loading environment from ${SCRIPT_DIR}/.env..."
    set -a
    # shellcheck disable=SC1091
    eval "$(grep -v '^\s*#' "${SCRIPT_DIR}/.env" | grep -v '^\s*$')"
    set +a
else
    echo "ERROR: .env not found at ${SCRIPT_DIR}/.env"
    echo "Run ./get_started_linux.sh to generate it, or copy .env.example to .env and edit."
    exit 1
fi

# Deploy target = the Forum's project. The Reasoning Engine runs there
# (alongside every other agent), but uses this agent's per-agent SA as
# its runtime identity (see .agent_engine_config.json).
FORUM_PROJECT_ID="${FORUM_PROJECT_ID:?FORUM_PROJECT_ID must be set in .env}"

# Agent's own project = where the SA, secrets, and staging bucket live.
AGENT_PROJECT_ID="${AGENT_PROJECT_ID:?AGENT_PROJECT_ID must be set in .env}"

# GOOGLE_CLOUD_PROJECT and FORUM_PROJECT_ID should normally match in .env
# (both = the Forum's project), but tolerate one being unset.
PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-$FORUM_PROJECT_ID}"

REGION="${GOOGLE_CLOUD_REGION:-us-central1}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:?AGENT_DISPLAY_NAME must be set in .env}"
ADK_BIN="${ADK_BIN:-$(command -v adk 2>/dev/null || echo adk)}"
ADK_PYTHON="${ADK_PYTHON:-$(dirname "$ADK_BIN")/python3}"
AGENT_DIR="${SCRIPT_DIR}"

# Hard-fail if the SA-assignment config is missing — without it the engine
# silently inherits the Forum's compute SA (shared with every other agent)
# and per-agent secret/doc isolation breaks. get_started_linux.sh generates
# this file; if it's gone, something went wrong.
if [[ ! -f "${SCRIPT_DIR}/.agent_engine_config.json" ]]; then
    echo "ERROR: .agent_engine_config.json missing in ${SCRIPT_DIR}."
    echo "  Without this file the deployed engine would run as the Forum's"
    echo "  default compute SA instead of this agent's per-agent SA, and"
    echo "  every other agent's per-doc / per-secret IAM would apply to it."
    echo "  Re-run ./get_started_linux.sh to regenerate it, or recreate from"
    echo "  the template at the same path."
    exit 1
fi

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m> $*\033[0m"; }
ok()   { echo -e "\033[1;32m  [OK] $*\033[0m"; }
err()  { echo -e "\033[1;31m  [xx] $*\033[0m" >&2; }
warn() { echo -e "\033[1;33m  [!!] $*\033[0m"; }

get_existing_agent_id() {
    "$ADK_PYTHON" -c "
import vertexai
from vertexai.preview import reasoning_engines
vertexai.init(project='${FORUM_PROJECT_ID}', location='${REGION}')
for e in reasoning_engines.ReasoningEngine.list():
    if '${AGENT_DISPLAY_NAME}' in (e.display_name or ''):
        print(e.resource_name.split('/')[-1])
        break
" 2>/dev/null || true
}

get_agent_resource_name() {
    echo "projects/${FORUM_PROJECT_ID}/locations/${REGION}/reasoningEngines/$1"
}

# ------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------
log "Pre-flight"

# We deploy to the Forum's project. The agent's own project is only
# touched indirectly (via the SA assignment, staging bucket reads, and
# cross-project secret IAM bindings already wired by terraform).
gcloud config set project "$FORUM_PROJECT_ID" --quiet
ok "gcloud project set to $FORUM_PROJECT_ID (deploy target)"
ok "Per-agent SA + secrets live in: $AGENT_PROJECT_ID"

if ! command -v "$ADK_BIN" >/dev/null 2>&1 && [[ ! -x "$ADK_BIN" ]]; then
    err "ADK binary not found at $ADK_BIN"
    echo "  Install with: pip install google-adk"
    echo "  Then set ADK_BIN in .env to the full path (e.g. /path/to/venv/bin/adk)."
    exit 1
fi
ok "ADK binary: $ADK_BIN"

# ------------------------------------------------------------------
# Step 1: Look for the existing Reasoning Engine (for blue/green)
# ------------------------------------------------------------------
log "Step 1: Looking for existing '${AGENT_DISPLAY_NAME}' Reasoning Engine..."
OLD_AGENT_ID=$(get_existing_agent_id)
if [[ -n "$OLD_AGENT_ID" ]]; then
    ok "Found: $(get_agent_resource_name "$OLD_AGENT_ID")"
else
    warn "No existing Reasoning Engine found. Will create a new one."
fi

# ------------------------------------------------------------------
# Step 2: Deploy the new Reasoning Engine
# ------------------------------------------------------------------
log "Step 2: Deploying agent to Vertex AI Agent Engine..."
echo "  Engine project:   $FORUM_PROJECT_ID  (Forum project — where every agent lives)"
echo "  Staging bucket:   gs://${AGENT_PROJECT_ID}-staging  (in this agent's project)"
echo "  Region:           $REGION"
echo "  Source:           $AGENT_DIR"
echo "  Runtime SA:       (from .agent_engine_config.json — should be this agent's per-agent SA)"

AGENT_PARENT_DIR="$(dirname "$AGENT_DIR")"
AGENT_PACKAGE_NAME="$(basename "$AGENT_DIR")"

DEPLOY_OUTPUT=$(cd "$AGENT_PARENT_DIR" && "$ADK_BIN" deploy agent_engine \
    --project "$FORUM_PROJECT_ID" \
    --region "$REGION" \
    --staging_bucket "gs://${AGENT_PROJECT_ID}-staging" \
    --display_name "$AGENT_DISPLAY_NAME" \
    --trace_to_cloud \
    --agent_engine_config_file "${AGENT_DIR}/.agent_engine_config.json" \
    "$AGENT_PACKAGE_NAME" 2>&1) || {
    err "Deployment failed!"
    echo "$DEPLOY_OUTPUT"
    exit 1
}
echo "$DEPLOY_OUTPUT"

# ADK can exit 0 even when the engine fails to start (e.g. import errors).
# Detect that explicitly so we don't go on to delete the old working engine.
if echo "$DEPLOY_OUTPUT" | grep -qE "Deploy failed:|failed to start"; then
    err "ADK exited 0 but the engine failed to start. NOT touching the old agent."
    err "Check logs:"
    err "  gcloud logging read 'resource.type=\"aiplatform.googleapis.com/ReasoningEngine\"' --project=$FORUM_PROJECT_ID --limit=50"
    exit 1
fi

NEW_AGENT_ID=$(echo "$DEPLOY_OUTPUT" | grep -oP 'reasoningEngines/\K[0-9]+' | tail -1)
if [[ -z "$NEW_AGENT_ID" ]]; then
    warn "Could not auto-extract new agent ID from deploy output."
    read -rp "  Enter the new Reasoning Engine ID manually: " NEW_AGENT_ID
fi

NEW_RESOURCE_NAME=$(get_agent_resource_name "$NEW_AGENT_ID")
ok "New Reasoning Engine deployed: $NEW_RESOURCE_NAME"

# ------------------------------------------------------------------
# Step 3: Smoke test
# ------------------------------------------------------------------
log "Step 3: Smoke testing new agent..."
SMOKE_RESULT=$("$ADK_PYTHON" -c "
import vertexai
from vertexai.preview import reasoning_engines
vertexai.init(project='${FORUM_PROJECT_ID}', location='${REGION}')
agent = reasoning_engines.ReasoningEngine('${NEW_RESOURCE_NAME}')
session = agent.create_session(user_id='smoke-test')
print(f'Session created: {session[\"id\"]}')
print('OK')
" 2>&1) || true

if echo "$SMOKE_RESULT" | grep -q "OK"; then
    ok "Smoke test passed."
else
    err "Smoke test failed. NOT touching the old agent."
    echo "$SMOKE_RESULT" | tail -10
    err "Check logs:"
    err "  gcloud logging read 'resource.type=\"aiplatform.googleapis.com/ReasoningEngine\" AND resource.labels.reasoning_engine_id=\"$NEW_AGENT_ID\"' --project=$FORUM_PROJECT_ID --limit=50"
    exit 1
fi

# ------------------------------------------------------------------
# Step 4: Register with The Forum
# ------------------------------------------------------------------
log "Step 4: Registering agent in The Forum's Firestore..."

"$ADK_PYTHON" -m pip install --quiet google-cloud-firestore google-cloud-secret-manager 2>/dev/null || true

"$ADK_PYTHON" "${SCRIPT_DIR}/register_agent.py" \
    --agent-name "$AGENT_DISPLAY_NAME" \
    --vertex-ai-agent-id "$NEW_RESOURCE_NAME" \
    --firestore-project "$FORUM_PROJECT_ID" || {
    err "Agent registration failed!"
    echo "  New Reasoning Engine is live at: $NEW_RESOURCE_NAME"
    echo "  You can re-run register_agent.py manually after fixing the issue."
    exit 1
}
ok "The Forum's Firestore updated."

# ------------------------------------------------------------------
# Step 5: Clear stale sessions for this agent
# ------------------------------------------------------------------
log "Step 5: Clearing stale sessions..."
SESSIONS_DELETED=$("$ADK_PYTHON" -c "
from google.cloud import firestore
db = firestore.Client(project='${FORUM_PROJECT_ID}')

agents = db.collection('agents').where('display_name', '==', '${AGENT_DISPLAY_NAME}').stream()
agent_doc_id = None
for agent in agents:
    agent_doc_id = agent.id
    break

if not agent_doc_id:
    print('0')
else:
    deleted = 0
    for session in db.collection('sessions').stream():
        if agent_doc_id in session.id:
            db.collection('sessions').document(session.id).delete()
            deleted += 1
    print(deleted)
" 2>/dev/null) || SESSIONS_DELETED="0"

if [[ "$SESSIONS_DELETED" -gt 0 ]]; then
    ok "Cleared $SESSIONS_DELETED stale session(s)."
else
    ok "No stale sessions to clear."
fi

# ------------------------------------------------------------------
# Step 6: Delete the old Reasoning Engine
# ------------------------------------------------------------------
if [[ -n "$OLD_AGENT_ID" && "$OLD_AGENT_ID" != "$NEW_AGENT_ID" ]]; then
    log "Step 6: Cleaning up old Reasoning Engine ($OLD_AGENT_ID)..."
    OLD_RESOURCE_NAME=$(get_agent_resource_name "$OLD_AGENT_ID")

    ACCESS_TOKEN=$(gcloud auth print-access-token)
    if curl -s -X DELETE \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/${OLD_RESOURCE_NAME}?force=true" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        | grep -q '"done": true'; then
        ok "Old Reasoning Engine deleted: $OLD_RESOURCE_NAME"
    else
        warn "Could not auto-delete old Reasoning Engine $OLD_RESOURCE_NAME — delete it manually if not needed."
    fi
else
    log "Step 6: No old Reasoning Engine to clean up."
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo
echo "==========================================================="
echo "  Deployment complete!"
echo "==========================================================="
echo "  Agent:        $AGENT_DISPLAY_NAME"
echo "  New engine:   $NEW_RESOURCE_NAME"
echo "  The Forum:    Updated in Firestore (project=$FORUM_PROJECT_ID)"
if [[ -n "${OLD_AGENT_ID:-}" && "$OLD_AGENT_ID" != "$NEW_AGENT_ID" ]]; then
    echo "  Old engine:   Deleted ($(get_agent_resource_name "$OLD_AGENT_ID"))"
fi
echo
echo "  Test it by sending a DM to your bot on one of its enabled platforms."
echo "==========================================================="
