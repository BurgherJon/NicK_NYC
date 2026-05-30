# AGENTS.md

Hard rules and guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this repository. This file follows the [agents.md](https://agents.md/) convention.

Nick runs on **[The Forum](https://github.com/Comites-ai/the-forum)** — the platform that bridges messaging platforms (Slack, Google Chat, Telegram, Discord) to AI agents on Vertex AI. Background on how The Forum works lives in [`docs/FOR_AGENT_DEVELOPERS.md`](https://github.com/Comites-ai/the-forum/blob/main/docs/FOR_AGENT_DEVELOPERS.md) — read it before doing anything non-trivial.

## How Nick is wired

- **Instructions**: Nick's system prompt is the live contents of a read-only Google Doc (`INSTRUCTION_DOC_ID` in [agent.py](agent.py)), fetched on each turn via an ADK instruction provider. Editing the doc changes behavior with no redeploy. Nick has no tool to write it.
- **Memory**: `get_agent_memory()` / `update_agent_memory()` ([custom_functions.py](custom_functions.py)) read/write a separate Google Doc (`AGENT_MEMORY_DOC_ID`). This is the only doc Nick writes to.
- Both docs must be **native Google Docs** (the Docs API can't read uploaded `.docx` blobs) shared with the runtime SA `agent-demo@agent-demo-497222.iam.gserviceaccount.com` — Viewer for instructions, Editor for memory.

## Hard rules

These are invariants. Breaking them silently breaks the agent. Don't.

### 1. Infrastructure changes go through terraform

Never create or modify GCP resources for this agent via the Cloud Console, `gcloud` one-liners, or the GCP web UI. Always: edit `terraform/main.tf` → `terraform apply` → commit. The state lives in the GCS backend wired in `terraform/providers.tf`. The two exceptions are the GCP project itself and the terraform state bucket (bootstrapped out of band) — don't try to bring those into terraform.

### 2. Secrets live in GCP Secret Manager — never in code, .env, or terraform state

- Plaintext secrets must not appear in `.env`, `terraform.tfvars`, code, comments, commit messages, or PR descriptions.
- Use `secret_utilities.get_secret_from_secret_manager(project_id, secret_id)` to fetch them at runtime.
- Each secret needs an IAM binding granting `roles/secretmanager.secretAccessor` to whatever principal reads it (The Forum's Cloud Run SA for platform tokens; the agent's Reasoning Engine SA for things the agent reads). The binding lives in `terraform/main.tf` next to the secret container.
- A `403 Permission Denied` on a secret read is almost always a missing IAM binding — fix it in terraform, not via `gcloud secrets add-iam-policy-binding` (that drifts from state).

### 3. The Reasoning Engine deploys to THE FORUM's project, but RUNS AS this agent's per-agent SA

Two projects are in play:

- **The Forum's project** (`FORUM_PROJECT_ID` = `vertex-ai-middleware-prod`): where The Forum runs and where every agent's Reasoning Engine physically lives, so The Forum can list/route to all agents.
- **This agent's own project** (`AGENT_PROJECT_ID` = `agent-demo-497222` = `project_id` in `terraform/terraform.tfvars`): where the per-agent SA, secrets, and ADK staging bucket live.

The Reasoning Engine's runtime identity is the per-agent SA (`agent-demo@agent-demo-497222.iam.gserviceaccount.com`), set via `.agent_engine_config.json`'s `service_account` field. **That's the SA you share Google Docs / Sheets / Drive files with** — not the Forum's compute SA, not your own user account. The cross-project IAM that makes this work (the Forum's Vertex AI Reasoning Engine Service Agent gets `roles/iam.serviceAccountTokenCreator` on the per-agent SA and `roles/storage.objectViewer` on the staging bucket) is provisioned by terraform. Don't deploy the Reasoning Engine to the agent's own project — that breaks The Forum's routing lookups.

If terraform apply fails with a "principal does not exist" error on `engine_token_creator` or `engine_staging_reader`, the Forum project's Vertex AI service identity isn't provisioned yet — run `gcloud beta services identity create --service=aiplatform.googleapis.com --project=vertex-ai-middleware-prod` (idempotent) and re-apply.

### 4. Always use `deploy_and_update.sh` to deploy

Don't run `adk deploy agent_engine` directly. The script does blue/green deploy + smoke test + Firestore registration + stale-session cleanup + old-engine deletion. Skipping it means Firestore points at the old engine (users get the old agent), no smoke test (a broken deploy goes live), and the old engine lingers (wasted spend).

### 5. Platforms are registered by auto-detection — don't hand-edit Firestore

`register_agent.py` (which `deploy_and_update.sh` calls) detects enabled platforms by probing Secret Manager for the expected secret IDs (`agent-demo-slack-token`, etc.). To change platforms: uncomment the section in `terraform/main.tf` → `terraform apply` → populate the secret → re-run `./deploy_and_update.sh`. Don't add platform entries directly in the Firestore Console — they're overwritten on the next deploy. (Nick currently runs on Slack; the other platform sections in `main.tf` stay commented until enabled.)

### 6. User IDs are names — not platform IDs

The Forum sends the user's actual name (e.g. `"Jonathan Cavell"`) as `user_id`, and prefixes incoming messages with `[From: Name]` (or `[From: Name | platform_id: ...]` for scheduled jobs). Treat `user_id` as a human name, not a Slack `U...` ID. This is how cross-platform identity works: the same person on different platforms gets the same `user_id`.

### 7. Multimodal input requires explicit handling

If Nick should accept images, you must override input handling to extract the `images` parameter The Forum sends alongside `message`. The default ADK `Agent` ignores it and produces empty responses on image messages. See [The Forum's `FOR_AGENT_DEVELOPERS.md` §"Receiving Images from Slack"](https://github.com/Comites-ai/the-forum/blob/main/docs/FOR_AGENT_DEVELOPERS.md#receiving-images-from-slack).

### 8. Don't reach into The Forum repo to change The Forum's code

This repo and The Forum coordinate over Firestore documents and Secret Manager — never via shared code. Use The Forum's extension points (the Firestore platform array, the per-agent webhook routes), or open a PR against The Forum.

### 9. Sessions are stateful — clear them when prompts change

The Forum's Firestore `sessions` collection holds running conversations. If you change Nick's behavior in a way that's incompatible with mid-conversation state, old sessions can produce weird responses. `deploy_and_update.sh` clears stale sessions automatically — let it. (Changing the instruction *doc* doesn't redeploy, so if a doc edit is structurally incompatible with in-flight sessions, clear them manually.)

## Common changes

- **Add a function tool**: define it in `custom_functions.py` with a clear docstring (the LLM sees the docstring as the tool description), then `from .custom_functions import my_tool` and add `FunctionTool(my_tool)` to `root_agent.tools` in `agent.py`.
- **Add a sub-agent**: define an `Agent(...)` in `custom_agents.py`, then add `AgentTool(agent=my_subagent)` to `root_agent.tools`.
- **Use an external API that needs a key**: add the secret container + IAM binding in `terraform/main.tf` → `terraform apply` → `echo -n "KEY" | gcloud secrets versions add my-secret --data-file=- --project=agent-demo-497222` → fetch at module load with `secret_utilities.get_secret_from_secret_manager(...)`.
- **Local iteration**: `adk web` from the repo root (model runs against Vertex AI; Forum/platform routing is bypassed).
