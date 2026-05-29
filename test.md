# Smoke Test for Template Changes

**Audience: template maintainers.** Anyone modifying `get_started_linux.sh`, `terraform/`, `deploy_and_update.sh`, or `register_agent.py` must walk through this test against a real GCP project before requesting PR review. CI cannot verify infrastructure or platform integration end-to-end.

**This file is deleted by `get_started_linux.sh`** — it does not ship with the agent that an end user builds from the template.

## What this test proves

Following this template from `git clone` to "the bot replies on Telegram" works in a single pass, with no manual GCP wiring beyond what `get_started_linux.sh` walks the operator through.

Telegram is the test platform of choice here because:
- It is **free** (the BotFather hands out tokens at no cost; Slack requires a paid workspace for most useful testing).
- Bot creation takes about 30 seconds via @BotFather.
- The webhook setup is a single `curl` call — no app manifest, no scopes UI.
- Cleanup is one BotFather command (`/deletebot`).

## Pre-flight: fast unit tests (no GCP)

Run these first. They take seconds and catch the most common regression — the `uncomment_section` heuristic in `get_started_linux.sh` mishandling `terraform/main.tf`. If these fail, fix them before doing the GCP test; otherwise you'll burn time discovering a broken heuristic against real cloud resources.

```bash
./tests/test_uncomment_section.sh
```

What it does:

- For each platform section (Slack, Google Chat, Telegram, Discord, Scheduler MCP):
  1. Saves a baseline copy of `terraform/main.tf`.
  2. Runs `uncomment_section <N> terraform/main.tf`.
  3. Verifies the expected resources for THAT section are now uncommented (no leading `#`).
  4. Verifies the OTHER sections' resources are still commented.
  5. Verifies `terraform fmt -check terraform/main.tf` still passes (catches structural breakage in the heuristic — missing `}`, extra spaces, etc.).
- Restores `terraform/main.tf` to the baseline at the end (or on Ctrl-C / failure) so the working tree is left clean.

Expected output ends with `All 5 sections passed.` and exit code 0.

If a section fails, look at the test output for the specific resource that didn't uncomment (or that leaked between sections), then either fix `uncomment_section` in `get_started_linux.sh` (the Python heredoc inside the function) or update the expected-resources list in `tests/test_uncomment_section.sh` if `terraform/main.tf` legitimately added or removed a resource.

After this passes, continue with the GCP test below.

## Prerequisites

Before starting:

1. **A test GCP project** with billing linked. Reuse if possible (faster), or create fresh. The test will create resources in this project and the easiest cleanup is a full `terraform destroy`.
2. **A personal Telegram account** (the free phone-number-based account, no business or paid account needed). You'll DM @BotFather to create the test bot.
3. **A local clone of [The Forum](https://github.com/Comites-ai/the-forum)** that's already deployed to its own GCP project and operational. The Forum must be reachable on its Cloud Run URL.
4. **CLI tools installed**: `gcloud` (authenticated, both `auth login` and `auth application-default login`), `terraform` (≥ 1.2), `python3`, `pip`, `adk`, `curl`, `openssl`.

## Test steps

### Step 1: Fresh clone of your branch

```bash
# Clone the branch you want to test into a directory with a valid
# Python identifier name (no hyphens — ADK uses the dir as a package name).
git clone -b YOUR_BRANCH git@github.com:Comites-ai/agent-template.git smoke_test_agent
cd smoke_test_agent

# Confirm the working tree is the version under test (in particular, that
# you don't have any uncommitted changes that wouldn't ship to an end user).
git status
```

### Step 2: Create a Telegram bot via @BotFather

Open Telegram on your phone or desktop:

1. Search for **@BotFather** (official, blue checkmark).
2. Send `/newbot`.
3. When asked for a display name: `Smoke Test Agent` (or any name).
4. When asked for a username: something ending in `bot`, e.g. `comites_smoke_test_bot`. It must be globally unique on Telegram, so add randomness if needed.
5. BotFather replies with the bot token, formatted like `1234567890:ABCdefGHIjklMNOpqrsTUVwxyz`. **Copy it now** — you'll paste it into `get_started_linux.sh` in Step 3, and into the webhook `curl` in Step 6.

Keep the BotFather chat open — you'll use `/deletebot` for cleanup in Step 9.

### Step 3: Run `get_started_linux.sh`

```bash
./get_started_linux.sh
```

Answer the prompts:

- Path to The Forum repo: the absolute path to your local Forum clone.
- Agent display name: `Smoke Test Agent`.
- `bot_account_id`: `smoke-test-agent`.
- GCP project: your test project ID.
- Region: `us-central1` (or whatever matches The Forum).
- Models: defaults are fine.
- Platforms: type `telegram` (Telegram only for this smoke test).
- Memory doc: skip (`n`) for this test.
- Run `terraform apply` now: **yes**.
- When prompted for the Telegram bot token: paste the token from @BotFather.

The script should:

- Verify gcloud auth and the project exists.
- Bootstrap APIs (`serviceusage`, `cloudresourcemanager`, `secretmanager`, `aiplatform`).
- Generate `.env` and `terraform/terraform.tfvars`.
- Uncomment Section 4 (Telegram) in `terraform/main.tf`.
- Create the GCS state bucket and wire up the backend in `providers.tf`.
- Run `terraform init`.
- Run `terraform apply -target=google_secret_manager_secret.telegram_bot_token` (secret container).
- Populate the Telegram token via `gcloud secrets versions add`.
- Run the full `terraform apply` (IAM bindings, service account, staging bucket).
- Rewrite `README.md` and `AGENTS.md` preface.
- Delete itself, `MAINTAINER_SETUP.md`, `tests/`, and this `test.md`.

**Expected end state**: `README.md` now starts with `# Smoke Test Agent`; `test.md`, `MAINTAINER_SETUP.md`, `tests/`, and `get_started_linux.sh` no longer exist; `terraform/terraform.tfvars` and `.env` are present and populated.

If any step fails, the script should exit with a clear error and leave you in a recoverable state.

### Step 4: Deploy

```bash
./deploy_and_update.sh
```

Expected:

- Step 1: "No existing Reasoning Engine found" (first deploy).
- Step 2: ADK deploys the agent. Takes 3-5 minutes. Output ends with a `reasoningEngines/<long-id>` resource name.
- Step 3: Smoke test creates a session against the new engine. Should print `OK`.
- Step 4: `register_agent.py` runs. Should detect Telegram (`[OK] Telegram: bot @your_bot_username ...`), write the Firestore doc, print `AGENT_ID=...`. **Copy the AGENT_ID** — you need it for the webhook URL in Step 6.
- Step 5: "No stale sessions to clear" (first deploy).
- Step 6: "No old Reasoning Engine to clean up" (first deploy).
- Final banner: "Deployment complete!"

### Step 5: Verify the agent is registered in The Forum's Firestore

```bash
gcloud firestore documents list agents --project=<FORUM_PROJECT_ID>
```

There should be a document with `display_name=Smoke Test Agent`, `vertex_ai_agent_id=projects/<test-project>/locations/us-central1/reasoningEngines/<id>`, and a `platforms` array containing a Telegram entry with `telegram_bot_token_secret`.

### Step 6: Set the Telegram webhook

Telegram delivers messages to The Forum via webhook. Each Telegram bot points to a per-agent URL containing the agent's Firestore ID (from Step 4).

```bash
# Variables — substitute your values
export TELEGRAM_BOT_TOKEN="1234567890:ABCdef..."  # from BotFather (Step 2)
export FORUM_URL="https://the-forum-XXXXX.a.run.app"  # The Forum's Cloud Run URL
export AGENT_ID="abc123def456"                    # printed by register_agent.py in Step 4
export WEBHOOK_SECRET=$(openssl rand -base64 32)

# Register the webhook
curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"url\": \"${FORUM_URL}/api/v1/telegram/events/${AGENT_ID}\",
    \"secret_token\": \"${WEBHOOK_SECRET}\"
  }"
# Response should be: {"ok":true,"result":true,"description":"Webhook was set"}

# Verify
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
# Expected: url matches what you set, pending_update_count is 0 or small,
# last_error_message should be empty.

# Save the WEBHOOK_SECRET for the next step.
echo "Webhook secret: $WEBHOOK_SECRET"
```

Now add the webhook secret to the agent's Firestore document so The Forum can verify incoming webhooks. Use the Firestore Console: navigate to `agents` → your agent's document → edit the Telegram entry in the `platforms` array → add field `telegram_webhook_secret` with the value above.

(There's no CLI for editing a single field in a nested array right now. If you do this often, write a script for it.)

### Step 7: Send a DM and verify the stub response

1. In Telegram, search for your bot's username (e.g. `@comites_smoke_test_bot`).
2. Tap **Start** (or send `/start` manually).
3. Send a message: `hello`.

**Expected response** (the agent introduces itself as Junius Rusticus — the historical Stoic teacher of Marcus Aurelius and the namesake inspiration for the Comites.ai project — and prompts you to replace the stub instructions). Exact wording varies per response since the model is reasoning from a persona prompt, not echoing a fixed string. A typical response will look something like:

> Greetings. I am Quintus Junius Rusticus — Roman Stoic, twice-consul of Rome, and the teacher who Marcus Aurelius credited in his Meditations with shaping his character. I serve as the placeholder voice of the Comites.ai Agent Template, whose name draws on the Roman tradition of trusted imperial counselors. When you are ready, replace my instructions in `agent.py` with the prompt for the agent you intend to build.

Verify the response contains all three of these elements:

- The name **Junius Rusticus** (or just "Rusticus")
- A reference to **Marcus Aurelius**
- A reference to **Comites.ai** (or just "Comites" / "comes")

If all three appear, the template works end-to-end. ✅ If the response is missing one of them, the model is probably ignoring parts of the prompt — try a higher-quality model in `HIGH_QUALITY_AGENT_MODEL` (`gemini-2.5-pro` is a safe choice) and redeploy.

### Step 8: Test a redeploy

Make a trivial change (e.g., add a print statement to `agent.py`), then:

```bash
./deploy_and_update.sh
```

Expected:

- Step 1: Finds the existing Reasoning Engine.
- Step 6: Cleans up the OLD Reasoning Engine (not the new one).
- Sending another DM to the bot still works (and now hits the new engine).

This proves the blue/green logic. **Note**: the Telegram webhook URL doesn't change between deploys (it's keyed on the Firestore agent ID, which is stable across redeploys), so no webhook re-registration is needed.

### Step 9: Cleanup

```bash
# In smoke_test_agent/
cd terraform && terraform destroy && cd ..

# Delete the Reasoning Engine
gcloud ai reasoning-engines list --region=us-central1 --project=<test-project>
gcloud ai reasoning-engines delete <ENGINE_ID> --region=us-central1 --project=<test-project>

# (Optional) delete the state bucket
gcloud storage rm -r gs://<test-project>-tfstate

# Delete the Firestore record
# Use the Firestore console: agents collection -> delete the Smoke Test Agent doc
# (Or write a Python one-liner — there's no gcloud delete-by-query for nested docs.)

# Delete the Telegram bot
# In Telegram, message @BotFather: /deletebot -> pick your bot.

# (Optional) Drop the webhook before deleting the bot — keeps Telegram's
# logs clean and stops any retries:
# curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook"

# Delete the local clone
cd .. && rm -rf smoke_test_agent
```

## Failure modes worth debugging before merging

If any of these happen during the test, fix on a branch before merging:

- **`get_started_linux.sh` fails partway through** and leaves the repo in a state where a re-run doesn't work cleanly. Idempotency matters — the operator should be able to fix the underlying issue and re-run.
- **`terraform apply` produces a 403 Permission Denied** that the script didn't catch in pre-flight. Add the missing pre-flight check.
- **`register_agent.py` says "No platform secrets found"** even though `terraform apply` succeeded. The secret-population step in `get_started_linux.sh` is broken (most likely the targeted `-target=` apply didn't include the Telegram secret).
- **The bot doesn't respond** but the Reasoning Engine is healthy. Walk through these in order:
  - `curl https://api.telegram.org/bot<TOKEN>/getWebhookInfo` — does `last_error_message` say something? Most common: webhook URL points at the wrong host or wrong agent ID.
  - Check The Forum's Cloud Run logs (`gcloud run services logs read the-forum --project=<forum-project>`) for "Discord" or "Telegram" lines on each message you send.
  - Verify `telegram_webhook_secret` in Firestore matches what you used in `setWebhook` (Step 6). If they don't match, The Forum rejects the request.
  - Verify the IAM binding from terraform: `gcloud secrets get-iam-policy smoke-test-agent-telegram-token --project=<test-project>` should show The Forum's compute SA with `roles/secretmanager.secretAccessor`.
- **The bot replies but with the wrong text** (or with multiple messages). The stub instruction in `agent.py` is wrong, or the model is being chatty despite "always respond with this exact text".
- **Redeploy doesn't update the bot's behavior**. Either Firestore wasn't updated (check `vertex_ai_agent_id` in the agent doc points at the NEW Reasoning Engine ID) or stale sessions weren't cleared (check `sessions` collection in The Forum's Firestore for sessions still pointing at the old engine).

## Where to look when things break

```bash
# get_started_linux.sh output
# (re-run with `bash -x ./get_started_linux.sh` to see every command)

# terraform state
cd terraform && terraform show

# Reasoning Engine logs
gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine"' \
  --project=<test-project> --limit=50

# The Forum's Cloud Run logs (most useful — Telegram-specific lines say "Telegram")
gcloud run services logs read the-forum \
  --project=<forum-project> --region=us-central1 --limit=50 \
  | grep -i telegram

# Firestore — agent registration
gcloud firestore documents list agents --project=<forum-project>

# Firestore — sessions for this agent
# (filter manually in the console; gcloud doesn't have a query filter for this)

# Telegram-side: what does Telegram think the webhook is?
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo" | python3 -m json.tool
```
