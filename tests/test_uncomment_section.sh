#!/usr/bin/env bash
#
# test_uncomment_section.sh — Unit test for the uncomment_section function
# in get_started_linux.sh. For each platform section (2-6), this:
#
#   1. Restores terraform/main.tf to a saved baseline (the current
#      working-tree version).
#   2. Calls uncomment_section <N> terraform/main.tf.
#   3. Verifies that the EXPECTED resources for section N are now
#      uncommented (no leading `# ` on their `resource ...` line).
#   4. Verifies that every OTHER section's resources are still commented.
#   5. Verifies `terraform fmt -check` still passes (catches structural
#      breakage in the heuristic — missing `}`, extra spaces, etc.).
#
# Restores the baseline at the end (or on Ctrl-C / failure) so the
# working tree is left exactly as found.
#
# Usage:
#   ./tests/test_uncomment_section.sh
#
# Exit status: 0 if all sections pass, non-zero if any fail.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Output helpers ---
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BOLD=$'\033[1m'
NC=$'\033[0m'

pass() { printf "  %sPASS%s %s\n" "$GREEN" "$NC" "$*"; }
fail() { printf "  %sFAIL%s %s\n" "$RED"   "$NC" "$*"; }
info() { printf "  %s..%s   %s\n" "$YELLOW" "$NC" "$*"; }

# --- Bring uncomment_section into scope ---
# get_started_linux.sh has a BASH_SOURCE guard so sourcing it doesn't
# trigger the interactive main().
# shellcheck disable=SC1091
source "$REPO_ROOT/get_started_linux.sh"

if ! declare -F uncomment_section >/dev/null; then
    echo "ERROR: uncomment_section was not defined after sourcing get_started_linux.sh"
    exit 2
fi

# --- Save baseline and arrange restore ---
TFILE="$REPO_ROOT/terraform/main.tf"
BASELINE=$(mktemp)
cp "$TFILE" "$BASELINE"

restore() {
    cp "$BASELINE" "$TFILE"
    rm -f "$BASELINE"
}
trap restore EXIT

# --- Expected resources per section ---
# Each entry: section_num, human_label, space-separated list of
# `resource_type.name` declarations that MUST be uncommented when this
# section is enabled (and only this section).
declare -A SECTION_LABEL=(
    [2]="Slack"
    [3]="Google Chat"
    [4]="Telegram"
    [5]="Discord"
    [6]="Scheduler MCP"
)
declare -A SECTION_RESOURCES=(
    [2]="google_secret_manager_secret.slack_bot_token google_secret_manager_secret_iam_member.slack_token_forum_accessor"
    [3]="google_project_service.chat google_project_iam_member.chat_owner google_secret_manager_secret.chat_credentials google_secret_manager_secret_iam_member.chat_credentials_forum_accessor"
    [4]="google_secret_manager_secret.telegram_bot_token google_secret_manager_secret_iam_member.telegram_token_forum_accessor"
    [5]="google_secret_manager_secret.discord_bot_token google_secret_manager_secret_iam_member.discord_token_worker_accessor google_secret_manager_secret_iam_member.discord_token_forum_accessor"
    [6]="google_secret_manager_secret.scheduler_mcp_key google_secret_manager_secret_iam_member.scheduler_mcp_key_reasoning_engine"
)

# --- Predicates ---

# True if the named resource appears UNCOMMENTED somewhere in $TFILE.
# Matches `resource "TYPE" "NAME" {` (with or without leading whitespace),
# explicitly NOT preceded by `#`.
resource_uncommented() {
    local fqname="$1"  # e.g. google_secret_manager_secret.slack_bot_token
    local type="${fqname%.*}"
    local name="${fqname#*.}"
    # Anchor on start of line + optional whitespace + the literal keyword.
    grep -qE "^[[:space:]]*(resource|data)[[:space:]]+\"${type}\"[[:space:]]+\"${name}\"" "$TFILE"
}

# True if the named resource appears COMMENTED OUT (line starts with #).
resource_commented() {
    local fqname="$1"
    local type="${fqname%.*}"
    local name="${fqname#*.}"
    grep -qE "^[[:space:]]*#[[:space:]]*(resource|data)[[:space:]]+\"${type}\"[[:space:]]+\"${name}\"" "$TFILE"
}

# --- The test ---
test_section() {
    local section="$1"
    local label="${SECTION_LABEL[$section]}"
    local resources="${SECTION_RESOURCES[$section]}"

    printf "\n%sSection %s (%s)%s\n" "$BOLD" "$section" "$label" "$NC"
    cp "$BASELINE" "$TFILE"
    info "restored terraform/main.tf to baseline"

    if ! uncomment_section "$section" "$TFILE" 2>&1 | sed 's/^/      /'; then
        fail "uncomment_section exited non-zero"
        return 1
    fi
    info "ran uncomment_section $section"

    local errors=0

    # (a) Expected resources in THIS section must be uncommented
    for fq in $resources; do
        if resource_uncommented "$fq"; then
            pass "$fq is uncommented"
        else
            fail "$fq should be uncommented, but isn't"
            errors=$((errors + 1))
        fi
    done

    # (b) Resources in OTHER sections must still be commented
    for other in "${!SECTION_RESOURCES[@]}"; do
        [[ "$other" == "$section" ]] && continue
        for fq in ${SECTION_RESOURCES[$other]}; do
            if resource_uncommented "$fq"; then
                fail "$fq (Section $other) leaked uncommented while testing Section $section"
                errors=$((errors + 1))
            fi
        done
    done
    if [[ $errors -eq 0 ]]; then
        pass "no other-section resources leaked"
    fi

    # (c) terraform fmt -check should pass — catches structural breakage
    if terraform fmt -check "$TFILE" >/dev/null 2>&1; then
        pass "terraform fmt -check passes"
    else
        fail "terraform fmt -check failed — the heuristic broke formatting"
        terraform fmt -check "$TFILE" 2>&1 | sed 's/^/      /'
        errors=$((errors + 1))
    fi

    return $errors
}

# --- Run all sections ---
total_failures=0
for n in 2 3 4 5 6; do
    if ! test_section "$n"; then
        total_failures=$((total_failures + 1))
    fi
done

printf "\n%s==========================================================%s\n" "$BOLD" "$NC"
if [[ $total_failures -eq 0 ]]; then
    printf "%sAll 5 sections passed.%s\n" "$GREEN" "$NC"
    exit 0
else
    printf "%s%d section(s) failed.%s\n" "$RED" "$total_failures" "$NC"
    exit 1
fi
