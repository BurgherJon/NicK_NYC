#!/usr/bin/env bash
#
# get_started_linux.sh — Interactive bootstrap for the Comites.ai Agent Template.
#
# Run once after cloning the template. Walks through prereq checks, prompts
# for agent config, generates .env + terraform.tfvars, uncomments the right
# terraform sections, creates the GCS state bucket, optionally runs
# terraform apply + populates platform secrets silently, optionally wires
# up a Google Doc for persistent memory, rewrites this repo to be about
# your agent, and self-deletes.
#
# Idempotency: re-running is generally NOT supported. If the script fails
# partway through, fix the underlying issue and either complete the
# remaining steps manually (the script's output tells you what's left) or
# revert and re-clone.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Colors / output helpers ---
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'

say()  { printf "%s==>%s %s\n" "$BLUE" "$NC" "$*"; }
ok()   { printf "%sOK%s  %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%s!! %s%s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "%sxx%s  %s\n" "$RED" "$NC" "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

prompt_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local yn
    while true; do
        read -rp "$prompt $hint " yn
        yn="${yn:-$default}"
        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Read a value from a tfvars-style file (key = "value" pattern). Empty if not found.
tfvars_get() {
    local file="$1"; local key="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
      | head -1 \
      | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/' \
      | sed -E 's/^[^=]*=[[:space:]]*([^"[:space:]]+).*/\1/'
}

# Read a value from a .env-style file (KEY=value pattern). Empty if not found.
env_get() {
    local file="$1"; local key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/^"//; s/"$//'
}

# ==============================================================================
# Phase 1: Announce + sanity-check we're in the right place
# ==============================================================================
phase_1_announce() {
    cat <<EOF
${BOLD}=== Comites.ai Agent Template — Get Started ===${NC}

This script walks through everything needed to turn this template into a
working agent on Comites.ai's The Forum:

  1.  Verify prerequisites (gcloud, terraform, adk, python, etc.).
  2.  Locate your local clone of The Forum.
  3.  Verify your GCP project exists and has billing linked.
  4.  Bootstrap APIs that terraform needs.
  5.  Ask you which messaging platforms to enable.
  6.  Generate .env and terraform/terraform.tfvars.
  7.  Uncomment the platform sections you selected in terraform/main.tf.
  8.  Create a GCS bucket for terraform state.
  9.  (Optional) Run terraform apply + populate platform secret values
      silently via gcloud.
  10. (Optional) Wire up a Google Doc for persistent agent memory.
  11. Rewrite README.md and AGENTS.md to be about your agent.
  12. Delete template-only files (test.md, MAINTAINER_SETUP.md) and this
      script itself.
  13. Print what to do next (platform-side webhook config, then deploy).

${BOLD}Pre-requisites you must handle yourself:${NC}
  - A GCP project exists for your agent, with billing linked. Create with:
      gcloud projects create YOUR_PROJECT --organization=YOUR_ORG_ID
      gcloud beta billing projects link YOUR_PROJECT --billing-account=YOUR_BILLING
  - A local clone of https://github.com/Comites-ai/the-forum with its own
    .env and terraform/terraform.tfvars already populated.
  - gcloud auth login AND gcloud auth application-default login.
  - For each messaging platform you intend to enable, the bot has already
    been created on the platform side (Slack app, Telegram BotFather, etc.)
    and you have the token ready to paste in.

You can cancel any time with Ctrl-C.

EOF
    if ! prompt_yn "Proceed?" y; then
        echo "Aborted."
        exit 0
    fi
    hr
}

# ==============================================================================
# Phase 2: Tool prerequisites
# ==============================================================================
phase_2_prereqs() {
    say "Phase 2: Tool prerequisites"

    local missing=()
    for tool in gcloud terraform python3 pip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if ! command -v adk >/dev/null 2>&1; then
        warn "adk CLI not found on PATH. You can install it with: pip install google-adk"
        warn "  (This is required for deploy_and_update.sh later — not for this script.)"
    else
        ok "adk:       $(adk --version 2>/dev/null || echo 'unknown version')"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        echo "  - gcloud:    https://cloud.google.com/sdk/docs/install"
        echo "  - terraform: https://developer.hashicorp.com/terraform/install"
        echo "  - python3:   your package manager"
        exit 1
    fi

    ok "gcloud:    $(gcloud --version 2>/dev/null | head -1)"
    ok "terraform: $(terraform -version 2>/dev/null | head -1)"
    ok "python3:   $(python3 --version 2>/dev/null)"

    # gcloud auth
    local active_account
    active_account=$(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null || true)
    if [[ -z "$active_account" ]]; then
        say "No active gcloud account. Logging in..."
        gcloud auth login
        active_account=$(gcloud auth list --filter='status:ACTIVE' --format='value(account)')
    fi
    ok "gcloud account: $active_account"

    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        say "Application Default Credentials not configured. Logging in..."
        gcloud auth application-default login
    fi
    ok "Application Default Credentials configured."
    hr
}

# ==============================================================================
# Phase 3: Locate The Forum repo
# ==============================================================================
phase_3_forum() {
    say "Phase 3: Locate your local clone of The Forum"
    echo "We need to read The Forum's .env and terraform.tfvars to learn its"
    echo "project ID and Cloud Run URL — your agent's terraform binds The"
    echo "Forum's Cloud Run service account to your agent's platform secrets,"
    echo "and your .env needs FORUM_URL for the scheduler MCP."
    echo

    # Try a few common locations as defaults
    local default=""
    for candidate in \
        "$REPO_ROOT/../slack-vertex-ai-middleware" \
        "$REPO_ROOT/../the-forum" \
        "$HOME/projects/slack-vertex-ai-middleware" \
        "$HOME/projects/the-forum"; do
        if [[ -f "$candidate/terraform/terraform.tfvars" ]]; then
            default="$(cd "$candidate" && pwd)"
            break
        fi
    done

    if [[ -n "$default" ]]; then
        read -rp "Path to The Forum repo [$default]: " FORUM_REPO
        FORUM_REPO="${FORUM_REPO:-$default}"
    else
        read -rp "Path to The Forum repo: " FORUM_REPO
    fi

    FORUM_REPO="${FORUM_REPO/#\~/$HOME}"
    if [[ ! -d "$FORUM_REPO" ]]; then
        err "Not a directory: $FORUM_REPO"
        exit 1
    fi

    local forum_tfvars="$FORUM_REPO/terraform/terraform.tfvars"
    if [[ ! -f "$forum_tfvars" ]]; then
        err "The Forum's terraform.tfvars not found at $forum_tfvars"
        echo "  The Forum must be set up first (with its install.sh)."
        exit 1
    fi

    FORUM_PROJECT_ID=$(tfvars_get "$forum_tfvars" "project_id")
    FORUM_REGION=$(tfvars_get "$forum_tfvars" "region")
    FORUM_REGION="${FORUM_REGION:-us-central1}"

    if [[ -z "$FORUM_PROJECT_ID" ]]; then
        err "Could not read project_id from $forum_tfvars"
        exit 1
    fi
    ok "The Forum project: $FORUM_PROJECT_ID  (region: $FORUM_REGION)"

    # Try to discover The Forum's Cloud Run URL
    FORUM_URL=""
    if FORUM_URL=$(gcloud run services describe the-forum \
        --project="$FORUM_PROJECT_ID" --region="$FORUM_REGION" \
        --format='value(status.url)' 2>/dev/null) && [[ -n "$FORUM_URL" ]]; then
        ok "The Forum URL:      $FORUM_URL"
    else
        warn "Could not auto-discover The Forum's Cloud Run URL via gcloud."
        read -rp "Enter The Forum's public URL (e.g. https://the-forum-XXXX.a.run.app): " FORUM_URL
    fi
    hr
}

# ==============================================================================
# Phase 4: Agent GCP project
# ==============================================================================
phase_4_project() {
    say "Phase 4: Your agent's GCP project"
    echo "This project will host the agent's service account, secrets,"
    echo "staging bucket, terraform state, and Reasoning Engine. It must"
    echo "be SEPARATE from The Forum's project ($FORUM_PROJECT_ID)."
    echo

    while true; do
        read -rp "GCP project ID for this agent: " PROJECT_ID
        if [[ -z "$PROJECT_ID" ]]; then
            echo "Required."
            continue
        fi
        if [[ "$PROJECT_ID" == "$FORUM_PROJECT_ID" ]]; then
            err "That's The Forum's project. The agent needs its own project."
            continue
        fi
        if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
            ok "Project $PROJECT_ID exists."
            break
        fi
        err "Project $PROJECT_ID not found or you don't have permission to describe it."
        echo "  Create it with:"
        echo "    gcloud projects create $PROJECT_ID --organization=YOUR_ORG_ID"
        echo "    gcloud beta billing projects link $PROJECT_ID --billing-account=YOUR_BILLING"
        echo "  Then re-run this script."
        if ! prompt_yn "Try a different project ID?" y; then
            exit 1
        fi
    done

    gcloud config set project "$PROJECT_ID" --quiet
    ok "gcloud default project set to $PROJECT_ID"

    # Check billing
    local billing
    billing=$(gcloud beta billing projects describe "$PROJECT_ID" \
        --format='value(billingEnabled)' 2>/dev/null || echo "")
    if [[ "$billing" != "True" ]]; then
        err "Billing is not enabled on project $PROJECT_ID."
        echo "  Link a billing account with:"
        echo "    gcloud beta billing projects link $PROJECT_ID --billing-account=YOUR_BILLING_ACCT"
        exit 1
    fi
    ok "Billing is enabled."

    read -rp "Region [$FORUM_REGION]: " REGION
    REGION="${REGION:-$FORUM_REGION}"
    ok "Region: $REGION"
    hr
}

# ==============================================================================
# Phase 5: Bootstrap APIs
# ==============================================================================
phase_5_bootstrap_apis() {
    say "Phase 5: Bootstrap APIs in $PROJECT_ID"
    echo "Enabling serviceusage, cloudresourcemanager, and secretmanager —"
    echo "terraform itself needs these to manage everything else."
    gcloud services enable \
        serviceusage.googleapis.com \
        cloudresourcemanager.googleapis.com \
        secretmanager.googleapis.com \
        --project="$PROJECT_ID"
    ok "Bootstrap APIs enabled in $PROJECT_ID."

    # Force-provision the Vertex AI service identity in The Forum's project
    # if it doesn't already exist. Our terraform creates an IAM binding that
    # references `service-${FORUM_PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam
    # .gserviceaccount.com`, which only auto-exists once Vertex AI has been
    # used in that project. For the very first agent against a fresh Forum
    # project, the binding would fail with "principal does not exist." This
    # gcloud call is idempotent — no-op if the identity already exists.
    echo
    echo "Ensuring Vertex AI service identity exists in $FORUM_PROJECT_ID"
    echo "(needed for cross-project IAM in terraform; idempotent)."
    if gcloud beta services identity create \
        --service=aiplatform.googleapis.com \
        --project="$FORUM_PROJECT_ID" 2>&1 | tee /tmp/svc_identity_out.log; then
        ok "Vertex AI service identity ready in $FORUM_PROJECT_ID."
    else
        warn "Could not provision Vertex AI service identity in $FORUM_PROJECT_ID."
        warn "  This usually means you lack roles/serviceusage.serviceUsageAdmin on"
        warn "  the Forum's project. If terraform apply later fails with a"
        warn "  'principal does not exist' error on engine_token_creator or"
        warn "  engine_staging_reader, ask the Forum's admin to run:"
        warn "    gcloud beta services identity create \\"
        warn "      --service=aiplatform.googleapis.com \\"
        warn "      --project=$FORUM_PROJECT_ID"
    fi
    rm -f /tmp/svc_identity_out.log
    hr
}

# ==============================================================================
# Phase 6: Agent identity prompts
# ==============================================================================
phase_6_agent_identity() {
    say "Phase 6: Your agent's identity"

    read -rp "Display name (e.g. 'Growth Coach'): " AGENT_DISPLAY_NAME
    while [[ -z "$AGENT_DISPLAY_NAME" ]]; do
        read -rp "Display name (required): " AGENT_DISPLAY_NAME
    done

    # Suggest a bot_account_id derived from the display name
    local default_bot_id
    default_bot_id=$(echo "$AGENT_DISPLAY_NAME" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
        | cut -c1-30)
    while true; do
        read -rp "bot_account_id (lowercase, hyphens, max 30 chars) [$default_bot_id]: " BOT_ACCOUNT_ID
        BOT_ACCOUNT_ID="${BOT_ACCOUNT_ID:-$default_bot_id}"
        if [[ "$BOT_ACCOUNT_ID" =~ ^[a-z][a-z0-9-]{0,29}$ ]] && [[ ! "$BOT_ACCOUNT_ID" =~ -$ ]]; then
            break
        fi
        err "Invalid. Must start with a lowercase letter, only lowercase/digits/hyphens, max 30 chars, no trailing hyphen."
    done

    local default_desc="AI assistant powered by Vertex AI on The Forum (Comites.ai)"
    read -rp "Short description (used for Google Chat & Firestore) [$default_desc]: " AGENT_DESCRIPTION
    AGENT_DESCRIPTION="${AGENT_DESCRIPTION:-$default_desc}"

    read -rp "High-quality model [gemini-2.5-pro]: " HIGH_QUALITY_AGENT_MODEL
    HIGH_QUALITY_AGENT_MODEL="${HIGH_QUALITY_AGENT_MODEL:-gemini-2.5-pro}"

    read -rp "Quick/cheap model [gemini-2.5-flash]: " QUICK_AGENT_MODEL
    QUICK_AGENT_MODEL="${QUICK_AGENT_MODEL:-gemini-2.5-flash}"

    ok "Agent identity captured."
    hr
}

# ==============================================================================
# Phase 7: Platforms
# ==============================================================================
phase_7_platforms() {
    say "Phase 7: Platforms"
    echo "Which messaging platforms will this agent serve? Space-separated."
    echo "Options: ${BOLD}slack${NC}  ${BOLD}gchat${NC} (Google Chat)  ${BOLD}telegram${NC}  ${BOLD}discord${NC}  ${BOLD}scheduler${NC} (The Forum's MCP)"
    echo
    echo "You can enable more platforms later by uncommenting the relevant"
    echo "section in terraform/main.tf and re-running terraform apply +"
    echo "deploy_and_update.sh. For this initial setup, pick at least one"
    echo "messaging platform so the agent has somewhere to receive messages."
    echo

    USE_SLACK=false
    USE_GCHAT=false
    USE_TELEGRAM=false
    USE_DISCORD=false
    USE_SCHEDULER=false

    while true; do
        read -rp "Platforms: " platforms_input
        for p in $platforms_input; do
            case "$p" in
                slack)     USE_SLACK=true ;;
                gchat)     USE_GCHAT=true ;;
                telegram)  USE_TELEGRAM=true ;;
                discord)   USE_DISCORD=true ;;
                scheduler) USE_SCHEDULER=true ;;
                *) warn "Unknown: $p (ignored)" ;;
            esac
        done
        if [[ "$USE_SLACK" == "true" || "$USE_GCHAT" == "true" || \
              "$USE_TELEGRAM" == "true" || "$USE_DISCORD" == "true" ]]; then
            break
        fi
        warn "No messaging platforms selected. Pick at least one of slack/gchat/telegram/discord."
    done

    # Discord-specific: collect the application ID up front
    DISCORD_APPLICATION_ID=""
    if [[ "$USE_DISCORD" == "true" ]]; then
        echo
        echo "Discord needs the Application ID from the Developer Portal"
        echo "(General Information → Application ID)."
        read -rp "Discord Application ID: " DISCORD_APPLICATION_ID
    fi

    local selected=""
    $USE_SLACK     && selected="$selected slack"
    $USE_GCHAT     && selected="$selected gchat"
    $USE_TELEGRAM  && selected="$selected telegram"
    $USE_DISCORD   && selected="$selected discord"
    $USE_SCHEDULER && selected="$selected scheduler"
    ok "Selected:${selected}"
    hr
}

# ==============================================================================
# Phase 8: Generate .env + terraform.tfvars
# ==============================================================================
phase_8_config_files() {
    say "Phase 8: Generate .env and terraform/terraform.tfvars"

    local chat_secret_name="${BOT_ACCOUNT_ID}-chat-credentials"

    cat > "$REPO_ROOT/terraform/terraform.tfvars" <<EOF
# Generated by get_started_linux.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
project_id       = "$PROJECT_ID"
region           = "$REGION"
bot_name         = "$AGENT_DISPLAY_NAME"
bot_account_id   = "$BOT_ACCOUNT_ID"
bot_description  = "$AGENT_DESCRIPTION"
bot_avatar_url   = ""

chat_credentials_secret_name = "$chat_secret_name"

forum_project_id = "$FORUM_PROJECT_ID"

discord_application_id = "$DISCORD_APPLICATION_ID"
EOF
    ok "Wrote terraform/terraform.tfvars"

    # Find ADK paths to put in .env (best effort — operator can fix later)
    local adk_bin adk_python
    adk_bin=$(command -v adk 2>/dev/null || echo "/path/to/your/venv/bin/adk")
    adk_python=$(dirname "$adk_bin")/python3
    if [[ ! -x "$adk_python" ]]; then
        adk_python=$(command -v python3 || echo "/path/to/your/venv/bin/python3")
    fi

    cat > "$REPO_ROOT/.env" <<EOF
# Generated by get_started_linux.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- GCP projects: the Reasoning Engine lives in the FORUM's project but
# RUNS AS the per-agent SA from AGENT_PROJECT_ID (via .agent_engine_config.json). ---
GOOGLE_CLOUD_PROJECT=$FORUM_PROJECT_ID
FORUM_PROJECT_ID=$FORUM_PROJECT_ID
AGENT_PROJECT_ID=$PROJECT_ID

GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_VERTEXAI=TRUE

HIGH_QUALITY_AGENT_MODEL=$HIGH_QUALITY_AGENT_MODEL
QUICK_AGENT_MODEL=$QUICK_AGENT_MODEL

AGENT_DISPLAY_NAME=$AGENT_DISPLAY_NAME
BOT_ACCOUNT_ID=$BOT_ACCOUNT_ID

FORUM_URL=$FORUM_URL

ADK_BIN=$adk_bin
ADK_PYTHON=$adk_python

# Populated by Phase 12 if you wire up persistent memory.
AGENT_MEMORY_DOC_ID=

GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=TRUE
OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=TRUE
EOF
    ok "Wrote .env"

    # --- Render .agent_engine_config.json with the real SA email ---
    # ADK reads this file at deploy time and uses `service_account` to tell
    # Vertex AI which identity the Reasoning Engine should run as. Without
    # this substitution, the deployed engine would inherit the Forum's
    # shared compute SA and per-agent isolation would break.
    local engine_config="$REPO_ROOT/.agent_engine_config.json"
    if [[ -f "$engine_config" ]]; then
        local agent_sa="${BOT_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
        # Use python rather than sed — it handles the JSON quoting cleanly
        # and won't choke on the @ or dots in the SA email.
        python3 - "$engine_config" "$agent_sa" <<'PYEOF'
import json, sys
path, sa = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["service_account"] = sa
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
        ok "Wrote service_account=$agent_sa into $(basename "$engine_config")"
    else
        warn ".agent_engine_config.json not found — deploy will run as the"
        warn "  Forum's default compute SA (shared with every other agent)."
        warn "  Restore it from the template before running deploy_and_update.sh."
    fi
    hr
}

# ==============================================================================
# Phase 9: Uncomment selected sections in terraform/main.tf
# ==============================================================================

# Uncomment a single platform section in terraform/main.tf.
#
# Strategy: find each `# resource ...` / `# data ...` block START within
# the target section, then uncomment the entire block by counting `{`
# and `}` until the braces balance. This is robust against `# Note:`
# commentary that happens to contain shell-style `${var.foo}` strings
# (a per-line heuristic would mistakenly uncomment those because they
# end with `}`).
#
# Section boundaries are the `# SECTION N:` headers and the OUTPUTS
# block at the bottom of the file. Resources outside the target section
# are left untouched.
uncomment_section() {
    local section_num="$1"
    local file="$2"
    local label="SECTION ${section_num}:"

    python3 - "$file" "$label" <<'PYEOF'
import re, sys

path, label = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().splitlines()

# Terraform top-level block keywords. When we see `# (keyword) ...` we
# enter "uncomment a block" mode and stay there until the brace count
# returns to zero.
KEYWORDS = ("resource", "data", "variable", "output", "module", "provider", "locals")
block_start_re = re.compile(r"^# (?:" + "|".join(KEYWORDS) + r")\b")

section_start_re = re.compile(r"^#\s*" + re.escape(label))
any_section_or_outputs_re = re.compile(r"^#\s*(?:SECTION\s+\d+:|OUTPUTS)")


def uncomment_line(line: str) -> str:
    """Strip the leading `# ` (or `#` for blank-comment lines)."""
    if line.startswith("# "):
        return line[2:]
    if line.startswith("#"):
        return line[1:]
    return line


def count_braces(text: str) -> int:
    """Net brace delta (+1 per `{`, -1 per `}`)."""
    return text.count("{") - text.count("}")


in_target_section = False
in_block = False
brace_depth = 0

out = []
for line in lines:
    # Enter target section
    if not in_target_section and section_start_re.match(line):
        in_target_section = True
        out.append(line)
        continue

    # Leave target section when we hit the next SECTION or OUTPUTS header
    if in_target_section and any_section_or_outputs_re.match(line) and not section_start_re.match(line):
        in_target_section = False
        # Defensive: if we were mid-block somehow, abandon it (shouldn't happen with sane input).
        in_block = False
        brace_depth = 0
        out.append(line)
        continue

    if not in_target_section:
        out.append(line)
        continue

    # ---- Inside the target section ----

    if in_block:
        # We're inside a `# resource ... { ... # }` block; uncomment
        # every line until braces balance.
        uncommented = uncomment_line(line)
        out.append(uncommented)
        brace_depth += count_braces(uncommented)
        if brace_depth <= 0:
            in_block = False
            brace_depth = 0
        continue

    # Look for the start of a new resource/data/etc block
    if block_start_re.match(line):
        uncommented = uncomment_line(line)
        out.append(uncommented)
        brace_depth = count_braces(uncommented)
        # A `# resource ... {` opens depth=1; if the line is somehow
        # complete (e.g. single-line definition) we stay out of block mode.
        if brace_depth > 0:
            in_block = True
        else:
            brace_depth = 0
        continue

    # Plain commentary inside the section — leave alone.
    out.append(line)

with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
PYEOF
}

phase_9_uncomment_terraform() {
    say "Phase 9: Uncomment selected platform sections in terraform/main.tf"

    local file="$REPO_ROOT/terraform/main.tf"
    cp "$file" "$file.bak"

    $USE_SLACK     && { uncomment_section 2 "$file"; ok "Uncommented Section 2 (Slack)"; }
    $USE_GCHAT     && { uncomment_section 3 "$file"; ok "Uncommented Section 3 (Google Chat)"; }
    $USE_TELEGRAM  && { uncomment_section 4 "$file"; ok "Uncommented Section 4 (Telegram)"; }
    $USE_DISCORD   && { uncomment_section 5 "$file"; ok "Uncommented Section 5 (Discord)"; }
    $USE_SCHEDULER && { uncomment_section 6 "$file"; ok "Uncommented Section 6 (Scheduler MCP)"; }

    # Verify terraform fmt is happy
    if ! terraform fmt -check "$file" >/dev/null 2>&1; then
        warn "terraform fmt found formatting drift after uncommenting. Auto-formatting..."
        terraform fmt "$file" >/dev/null || true
    fi
    rm -f "$file.bak"
    hr
}

# ==============================================================================
# Phase 10: Create the state bucket and wire backend
# ==============================================================================
phase_10_state_backend() {
    say "Phase 10: Set up GCS state backend"
    local state_bucket="${PROJECT_ID}-tfstate"

    if gcloud storage buckets describe "gs://$state_bucket" --project="$PROJECT_ID" >/dev/null 2>&1; then
        ok "State bucket already exists: gs://$state_bucket"
    else
        say "Creating state bucket gs://$state_bucket..."
        gcloud storage buckets create "gs://$state_bucket" \
            --project="$PROJECT_ID" \
            --location="$REGION" \
            --uniform-bucket-level-access \
            --public-access-prevention
        gcloud storage buckets update "gs://$state_bucket" --versioning >/dev/null
        ok "State bucket created with versioning enabled."
    fi

    local providers="$REPO_ROOT/terraform/providers.tf"
    # Replace the commented backend block with an uncommented one.
    python3 - "$providers" "$state_bucket" <<'PYEOF'
import sys, re
path, bucket = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
# The commented block is:
#   # backend "gcs" {
#   #   bucket = "YOUR_PROJECT_ID-tfstate"
#   #   prefix = "agent/state"
#   # }
new_block = f'  backend "gcs" {{\n    bucket = "{bucket}"\n    prefix = "agent/state"\n  }}'
pattern = re.compile(
    r'  # backend "gcs" \{\s*\n'
    r'  #   bucket = "[^"]*"\s*\n'
    r'  #   prefix = "[^"]*"\s*\n'
    r'  # \}',
    re.MULTILINE,
)
new_text, n = pattern.subn(new_block, text, count=1)
if n == 0:
    # Already uncommented or schema drift — leave alone but warn via stderr.
    sys.stderr.write("warning: backend block not in expected commented form, leaving providers.tf unchanged\n")
else:
    with open(path, "w") as f:
        f.write(new_text)
PYEOF
    ok "Wired backend \"gcs\" block in providers.tf"

    say "Running terraform init..."
    (cd "$REPO_ROOT/terraform" && terraform init -upgrade)
    ok "Terraform initialized."
    hr
}

# ==============================================================================
# Helpers for phase 11
# ==============================================================================

secret_has_version() {
    local name="$1"
    local count
    count=$(gcloud secrets versions list "$name" \
        --filter="state:ENABLED" --limit=1 --format="value(name)" \
        --project="$PROJECT_ID" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -ge 1 ]]
}

add_secret_version_silent() {
    local name="$1"
    local value="$2"
    printf '%s' "$value" | gcloud secrets versions add "$name" \
        --data-file=- --project="$PROJECT_ID" >/dev/null
}

# ==============================================================================
# Phase 11: Optional terraform apply + secret population
# ==============================================================================
phase_11_apply() {
    say "Phase 11: terraform apply + secret population"
    echo
    echo "This is the step where real GCP resources get created. It's"
    echo "broken into two passes:"
    echo "  11a. apply -target= for just the secret CONTAINERS, so we can"
    echo "       populate their values before any resource that binds to"
    echo "       them (like the IAM policies) needs them."
    echo "  11b. apply for everything else."
    echo
    if ! prompt_yn "Run terraform apply now?"; then
        SKIPPED_APPLY=true
        warn "Skipping terraform apply. You'll need to run it yourself."
        hr
        return 0
    fi
    SKIPPED_APPLY=false

    # ---- 11a: targeted apply of secret containers ----
    local targets=()
    $USE_SLACK     && targets+=("-target=google_secret_manager_secret.slack_bot_token")
    $USE_TELEGRAM  && targets+=("-target=google_secret_manager_secret.telegram_bot_token")
    $USE_DISCORD   && targets+=("-target=google_secret_manager_secret.discord_bot_token")
    $USE_GCHAT     && targets+=("-target=google_secret_manager_secret.chat_credentials")
    $USE_SCHEDULER && targets+=("-target=google_secret_manager_secret.scheduler_mcp_key")

    # Always also apply the SA in the first pass so it exists for the GCh key step
    $USE_GCHAT && targets+=("-target=google_service_account.agent")

    if [[ ${#targets[@]} -gt 0 ]]; then
        say "11a: Creating secret containers..."
        (cd "$REPO_ROOT/terraform" && terraform apply -auto-approve "${targets[@]}")
        ok "Secret containers created."
        echo

        # ---- 11b: populate values silently ----
        say "11b: Populating secret values (input is hidden)..."

        if $USE_SLACK; then
            local secret="${BOT_ACCOUNT_ID}-slack-token"
            if secret_has_version "$secret"; then
                ok "  Slack token already populated."
            else
                read -rsp "  Slack bot token (xoxb-...): " val; echo
                if [[ -n "$val" ]]; then
                    add_secret_version_silent "$secret" "$val"
                    ok "  Slack token stored in $secret."
                else
                    warn "  Empty input — skipped. Populate later with: echo -n 'TOKEN' | gcloud secrets versions add $secret --data-file=- --project=$PROJECT_ID"
                fi
            fi
        fi

        if $USE_TELEGRAM; then
            local secret="${BOT_ACCOUNT_ID}-telegram-token"
            if secret_has_version "$secret"; then
                ok "  Telegram token already populated."
            else
                echo "  Get the token from @BotFather (https://t.me/BotFather → /newbot)."
                read -rsp "  Telegram bot token (1234567890:ABC...): " val; echo
                if [[ -n "$val" ]]; then
                    add_secret_version_silent "$secret" "$val"
                    ok "  Telegram token stored in $secret."
                else
                    warn "  Empty input — skipped."
                fi
            fi
        fi

        if $USE_DISCORD; then
            local secret="${BOT_ACCOUNT_ID}-discord-token"
            if secret_has_version "$secret"; then
                ok "  Discord token already populated."
            else
                echo "  Get the token from https://discord.com/developers/applications → your app → Bot → Reset Token."
                read -rsp "  Discord bot token: " val; echo
                if [[ -n "$val" ]]; then
                    add_secret_version_silent "$secret" "$val"
                    ok "  Discord token stored in $secret."
                else
                    warn "  Empty input — skipped."
                fi
            fi
        fi

        if $USE_GCHAT; then
            local secret="${BOT_ACCOUNT_ID}-chat-credentials"
            local sa_email="${BOT_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
            if secret_has_version "$secret"; then
                ok "  Google Chat credentials already populated."
            else
                say "  Creating SA key for $sa_email..."
                local keyfile
                keyfile=$(mktemp)
                if gcloud iam service-accounts keys create "$keyfile" \
                    --iam-account="$sa_email" \
                    --project="$PROJECT_ID" >/dev/null 2>&1; then
                    gcloud secrets versions add "$secret" \
                        --data-file="$keyfile" --project="$PROJECT_ID" >/dev/null
                    ok "  Google Chat SA key stored in $secret."
                else
                    err "  Failed to create SA key. The org policy override may not have taken effect yet — try again in a minute."
                fi
                rm -f "$keyfile"
            fi
        fi

        if $USE_SCHEDULER; then
            local secret="${BOT_ACCOUNT_ID}-scheduler-mcp-key"
            if secret_has_version "$secret"; then
                ok "  Scheduler MCP key already populated."
            else
                echo
                echo "  ${BOLD}The scheduler MCP key is generated by The Forum, not by you.${NC}"
                echo "  After this script finishes:"
                echo "    cd $FORUM_REPO"
                echo "    python scripts/provision_scheduler_api_key.py --agent-id <YOUR_AGENT_FIRESTORE_ID>"
                echo "  Then populate the secret here:"
                echo "    echo -n 'PLAINTEXT_FROM_FORUM' | gcloud secrets versions add \\"
                echo "      $secret --data-file=- --project=$PROJECT_ID"
                echo "  (You won't have a Firestore agent ID until after first deploy — that's fine, the scheduler MCP wiring in agent.py is commented out by default.)"
            fi
        fi
        echo
    fi

    # ---- 11c: full apply ----
    say "11c: Applying the rest of the configuration..."
    (cd "$REPO_ROOT/terraform" && terraform apply -auto-approve)
    ok "terraform apply complete."
    hr
}

# ==============================================================================
# Phase 12: Optional Google Doc memory wiring
# ==============================================================================
phase_12_memory_doc() {
    say "Phase 12: Persistent memory via Google Doc (recommended)"
    echo "Your agent comes with memory tools (get_agent_memory and"
    echo "update_agent_memory) already wired into root_agent.tools. They"
    echo "need a Google Doc to read from and write to — without one, the"
    echo "tools will raise a clear error if the model ever calls them."
    echo
    echo "If you skip this, the stub greeting still works (the stub doesn't"
    echo "call the memory tools) — but you'll need to either configure"
    echo "AGENT_MEMORY_DOC_ID later, or remove the memory tools from"
    echo "agent.py before your real prompt starts using them."
    echo

    if ! prompt_yn "Wire up a Google Doc for persistent memory?" y; then
        warn "Skipping memory doc setup — AGENT_MEMORY_DOC_ID will be empty."
        hr
        return 0
    fi

    echo
    echo "  1. Create a new Google Doc at https://docs.google.com (or use an existing one)."
    echo "  2. The doc URL looks like:"
    echo "       https://docs.google.com/document/d/AAAA111122223333.../edit"
    echo "     The ID is the part between /d/ and /edit."
    echo
    local doc_id
    read -rp "  Google Doc ID: " doc_id
    if [[ -z "$doc_id" ]]; then
        warn "  Empty input — skipping."
        hr
        return 0
    fi

    # Append to .env (or replace if already there)
    if grep -qE '^AGENT_MEMORY_DOC_ID=' "$REPO_ROOT/.env"; then
        sed -i.bak -E "s|^AGENT_MEMORY_DOC_ID=.*|AGENT_MEMORY_DOC_ID=$doc_id|" "$REPO_ROOT/.env"
        rm -f "$REPO_ROOT/.env.bak"
    else
        echo "" >> "$REPO_ROOT/.env"
        echo "AGENT_MEMORY_DOC_ID=$doc_id" >> "$REPO_ROOT/.env"
    fi
    ok "  AGENT_MEMORY_DOC_ID set in .env."

    # This SA is the runtime identity the Reasoning Engine actually
    # impersonates (via .agent_engine_config.json's service_account field).
    # Sharing the doc with any other SA will not grant the agent access.
    local sa_email="${BOT_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
    cat <<EOF

  ${BOLD}Now share the Doc with your agent's runtime SA:${NC}
    1. Open the Doc in your browser.
    2. Click "Share" (top right).
    3. Add this email: ${BOLD}$sa_email${NC}
    4. Set its access to "Editor".
    5. Click Send (uncheck "Notify people" — the SA can't read email).

  ${BOLD}This is the SA the Reasoning Engine runs as${NC} once you deploy
  (assigned via .agent_engine_config.json). Sharing the doc with any
  other identity — the Forum's compute SA, your personal account, etc.
  — won't grant the deployed agent access. The agent will get a 403
  from the Docs API until this step is done.

EOF
    hr
}

# ==============================================================================
# Phase 13: Re-target the repo for the new agent
# ==============================================================================
phase_13_retarget_repo() {
    say "Phase 13: Re-target the repo for $AGENT_DISPLAY_NAME"

    # Replace README.md with the post-setup version, substituting in the
    # agent details.
    local template="$REPO_ROOT/.readme_template_post_setup.md"
    if [[ -f "$template" ]]; then
        local enabled_line=()
        $USE_SLACK    && enabled_line+=("Slack")
        $USE_GCHAT    && enabled_line+=("Google Chat")
        $USE_TELEGRAM && enabled_line+=("Telegram")
        $USE_DISCORD  && enabled_line+=("Discord")
        local enabled_str="${enabled_line[*]}"
        enabled_str="${enabled_str// / · }"

        python3 - "$template" "$REPO_ROOT/README.md" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()
text = (text
    .replace("{{AGENT_DISPLAY_NAME}}", "$AGENT_DISPLAY_NAME")
    .replace("{{AGENT_DESCRIPTION}}", "$AGENT_DESCRIPTION")
    .replace("{{FORUM_PROJECT_ID}}", "$FORUM_PROJECT_ID")
    .replace("{{GOOGLE_CLOUD_PROJECT}}", "$PROJECT_ID")
    .replace("{{BOT_ACCOUNT_ID}}", "$BOT_ACCOUNT_ID")
    .replace("{{ENABLED_PLATFORMS_LINE}}", "$enabled_str")
)
with open(dst, "w") as f:
    f.write(text)
PYEOF
        rm -f "$template"
        ok "README.md rewritten for $AGENT_DISPLAY_NAME."
    else
        warn "Post-setup README template not found at $template — leaving README.md as-is."
    fi
    hr
}

# ==============================================================================
# Phase 14: Cleanup — delete template-only files and self-delete
# ==============================================================================
phase_14_cleanup() {
    say "Phase 14: Removing template-only files"
    local to_remove=(
        "$REPO_ROOT/test.md"
        "$REPO_ROOT/MAINTAINER_SETUP.md"
        "$REPO_ROOT/.readme_template_post_setup.md"
    )
    for f in "${to_remove[@]}"; do
        if [[ -e "$f" ]]; then
            rm -f "$f"
            ok "Removed $(basename "$f")"
        fi
    done
    # The tests/ dir holds template-maintainer unit tests; end users don't
    # need them in their agent repo.
    if [[ -d "$REPO_ROOT/tests" ]]; then
        rm -rf "$REPO_ROOT/tests"
        ok "Removed tests/"
    fi
    hr
}

# ==============================================================================
# Phase 15: Next steps
# ==============================================================================
phase_15_next_steps() {
    say "Phase 15: Next steps"
    echo
    echo "${BOLD}==================== WHAT TO DO NOW ====================${NC}"
    echo

    if [[ "$SKIPPED_APPLY" == "true" ]]; then
        cat <<EOF
${BOLD}[ ] Run terraform apply${NC}
    You skipped the terraform apply step. To do it manually:
      cd terraform
      terraform plan
      terraform apply
    Then populate each platform's secret value with:
      echo -n 'TOKEN' | gcloud secrets versions add \\
        ${BOT_ACCOUNT_ID}-<platform>-token \\
        --data-file=- --project=$PROJECT_ID

EOF
    fi

    if $USE_SLACK; then
        cat <<EOF
${BOLD}[ ] Configure Slack Event Subscriptions${NC}
    1. https://api.slack.com/apps → your bot
    2. Event Subscriptions → Enable Events
    3. Request URL: $FORUM_URL/api/v1/slack/events
       (wait for the green checkmark)
    4. Subscribe to bot events → add: message.im
    5. Save (and reinstall to workspace if prompted)
    6. Confirm that this bot's Signing Secret is in The Forum's
       SLACK_SIGNING_SECRET (comma-separated list). If not, add it via
       The Forum's Secret Manager and redeploy The Forum.

EOF
    fi

    if $USE_GCHAT; then
        cat <<EOF
${BOLD}[ ] Configure Google Chat bot${NC}
    1. https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=$PROJECT_ID
    2. Click Configuration.
    3. Bot name:    $AGENT_DISPLAY_NAME
    4. Description: $AGENT_DESCRIPTION
    5. Functionality: enable "Receive 1:1 messages" and "Join spaces and group conversations"
    6. Connection settings: App URL = $FORUM_URL/api/v1/google-chat/events
    7. Permissions: pick who can use the bot.
    8. Save.

EOF
    fi

    if $USE_TELEGRAM; then
        cat <<EOF
${BOLD}[ ] Set the Telegram webhook${NC}
    (You'll need your agent's Firestore document ID after first deploy.)
    1. ./deploy_and_update.sh
    2. Note the AGENT_ID printed at the end.
    3. Generate a webhook secret:
         export WEBHOOK_SECRET=\$(openssl rand -base64 32)
    4. Set the webhook:
         curl -X POST "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook" \\
           -H "Content-Type: application/json" \\
           -d '{"url":"$FORUM_URL/api/v1/telegram/events/<AGENT_ID>",
                "secret_token":"'"\$WEBHOOK_SECRET"'"}'
    5. Add the webhook secret to your agent's Firestore platform block
       as telegram_webhook_secret (use Firestore Console).

EOF
    fi

    if $USE_DISCORD; then
        cat <<EOF
${BOLD}[ ] Discord bot setup${NC}
    1. The Forum's discord-worker VM must be running (check with the
       Forum operator if you're unsure). It auto-discovers new
       Discord-enabled agents every 5 minutes.
    2. ./deploy_and_update.sh (writes the Discord platform block to
       Firestore — the worker picks it up automatically).
    3. In the Discord Developer Portal:
       OAuth2 → URL Generator → scopes: bot, permissions: Send Messages
       + Read Message History. Open the URL, pick a server, authorize.
    4. DM the bot.

EOF
    fi

    if $USE_SCHEDULER; then
        cat <<EOF
${BOLD}[ ] Provision the scheduler MCP key${NC}
    1. ./deploy_and_update.sh (so the agent has a Firestore ID).
    2. cd $FORUM_REPO
    3. python scripts/provision_scheduler_api_key.py --agent-id <AGENT_ID>
    4. Copy the printed plaintext (shown ONCE) and populate the secret:
         echo -n 'PLAINTEXT' | gcloud secrets versions add \\
           ${BOT_ACCOUNT_ID}-scheduler-mcp-key \\
           --data-file=- --project=$PROJECT_ID
    5. Uncomment the scheduler_toolset block in agent.py and add it to
       root_agent.tools. Re-deploy.

EOF
    fi

    cat <<EOF
${BOLD}[ ] First deploy${NC}
    ./deploy_and_update.sh
    Then DM your bot on any enabled platform. The agent will introduce
    itself as Junius Rusticus — the Roman Stoic philosopher and teacher
    of Marcus Aurelius — whose title (comes / comites) inspired the
    project's name. Wording varies per response; it should include the
    name Rusticus, a reference to Marcus Aurelius, and a reference to
    Comites.ai.

${BOLD}[ ] Replace the stub with real agent logic${NC}
    Edit agent.py — replace STUB_INSTRUCTION (the Junius Rusticus
    persona) with your real prompt and description, then add tools as
    you build them. See README.md's "Next steps" section and AGENTS.md
    for guidance.

${BOLD}=========================================================${NC}
EOF
    hr
}

# ==============================================================================
# Phase 16: Self-delete
# ==============================================================================
phase_16_self_delete() {
    say "Phase 16: Self-delete"
    if prompt_yn "Delete get_started_linux.sh now? (Recommended — it's single-use.)" y; then
        rm -f "$REPO_ROOT/get_started_linux.sh"
        ok "Deleted get_started_linux.sh."
    else
        warn "Leaving get_started_linux.sh in place. Remember it should not be re-run."
    fi
    hr
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    phase_1_announce
    phase_2_prereqs
    phase_3_forum
    phase_4_project
    phase_5_bootstrap_apis
    phase_6_agent_identity
    phase_7_platforms
    phase_8_config_files
    phase_9_uncomment_terraform
    phase_10_state_backend
    phase_11_apply
    phase_12_memory_doc
    phase_13_retarget_repo
    phase_14_cleanup
    phase_15_next_steps
    phase_16_self_delete

    echo
    ok "${BOLD}Setup complete!${NC} Welcome to Comites.ai."
}

# Only run main when this file is invoked directly. Sourcing the script
# (e.g. from tests/test_uncomment_section.sh) gets you the function
# definitions without triggering the interactive flow.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
