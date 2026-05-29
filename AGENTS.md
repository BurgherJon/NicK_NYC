# AGENTS.md

Hard rules and guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this repository. This file follows the [agents.md](https://agents.md/) convention.

This agent is built on **[The Forum](https://github.com/Comites-ai/the-forum)** — Comites.ai's open-source platform that bridges messaging platforms (Slack, Google Chat, Telegram, Discord) to AI agents on Vertex AI. Detailed background on how The Forum works lives in The Forum repo at [`docs/FOR_AGENT_DEVELOPERS.md`](https://github.com/Comites-ai/the-forum/blob/main/docs/FOR_AGENT_DEVELOPERS.md) — read it before doing anything non-trivial.

## Hard rules

These are invariants. Breaking them silently breaks the agent. Don't.

### 1. Infrastructure changes go through terraform

Never create or modify GCP resources for this agent via the Cloud Console, `gcloud` one-liners, or the GCP web UI. Always:

1. Edit `terraform/main.tf`.
2. `terraform apply`.
3. Commit the change.

The platform sections (Slack/Google Chat/Telegram/Discord/Scheduler MCP) in `main.tf` are intentionally commented out. **Uncomment** them when enabling a platform — never delete them. The two exceptions to "everything in terraform" are: (a) the GCP project itself, and (b) the terraform state bucket — both bootstrapped by `get_started_linux.sh` via gcloud. Don't try to bring those into terraform; the chicken-and-egg with the GCS backend isn't worth it.

### 2. Secrets live in GCP Secret Manager — never in code, .env, or terraform state

- Plaintext secrets must not appear in `.env`, `terraform.tfvars`, code, comments, commit messages, or PR descriptions.
- Use `secret_utilities.get_secret_from_secret_manager(project_id, secret_id)` to fetch them at runtime.
- Each secret must have an IAM binding granting `roles/secretmanager.secretAccessor` to whatever principal needs to read it (The Forum's Cloud Run SA for platform tokens; the agent's Reasoning Engine SA for things the agent itself reads). The IAM binding lives in `terraform/main.tf` next to the secret container.
- If you see a `403 Permission Denied` on a secret read, the fix is almost always to add or correct that IAM binding in terraform. Don't grant the permission via `gcloud secrets add-iam-policy-binding` and walk away — terraform will drift.

### 3. The Reasoning Engine deploys to THE FORUM's project, but RUNS AS this agent's per-agent SA

There are two projects in play:

- **The Forum's project** (`FORUM_PROJECT_ID` = `GOOGLE_CLOUD_PROJECT` in `.env`): Where The Forum runs, and where every agent's Reasoning Engine physically lives. Administratively centralized so The Forum can list/route to all agents.
- **This agent's own project** (`AGENT_PROJECT_ID` in `.env` = `project_id` in `terraform/terraform.tfvars`): Where the per-agent SA, secrets, and ADK staging bucket live.

The Reasoning Engine's runtime identity is the per-agent SA (`BOT_ACCOUNT_ID@AGENT_PROJECT_ID.iam.gserviceaccount.com`), set via `.agent_engine_config.json`'s `service_account` field. **That's the SA you share Google Docs / Sheets / Drive files with** — not the Forum's compute SA, and not your own user account. Sharing with anyone else won't grant the deployed agent access.

The cross-project IAM that makes this work is provisioned by terraform: the Forum's Vertex AI Reasoning Engine Service Agent gets `roles/iam.serviceAccountTokenCreator` on the per-agent SA (to mint runtime tokens) and `roles/storage.objectViewer` on the staging bucket (to fetch the packaged agent code at cold start). Don't deploy the Reasoning Engine to the agent's own project — that wastes the cross-project IAM and means The Forum can't see your agent in its routing lookups.

**Cross-project IAM dependency:** The Forum project must have the Vertex AI service identity provisioned before this agent's terraform can apply, because the IAM bindings reference the Forum's Vertex AI Reasoning Engine Service Agent (`service-${FORUM_PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com`), which only auto-exists once Vertex AI has been used in that project. **`get_started_linux.sh` handles this automatically** (phase 5 runs `gcloud beta services identity create --service=aiplatform.googleapis.com --project=$FORUM_PROJECT_ID` — idempotent, no-op if the identity already exists). If you skipped the bootstrap or are applying terraform by hand and hit a "principal does not exist" error on `engine_token_creator` or `engine_staging_reader`, run that same gcloud command and re-apply. The Forum's admin needs `roles/serviceusage.serviceUsageAdmin` on the Forum project to run it.

### 4. Always use `deploy_and_update.sh` to deploy

Don't run `adk deploy agent_engine` directly. The script does blue/green deploy + smoke test + Firestore registration + stale-session cleanup + old-engine deletion. Skipping the script means:

- Firestore still points at the old Reasoning Engine → users get the old agent.
- No smoke test → a broken deploy goes live and there's no quick rollback.
- Old engine isn't cleaned up → wasted spend.

### 5. Platforms are registered by auto-detection — don't hand-edit Firestore

`register_agent.py` (which `deploy_and_update.sh` calls) detects enabled platforms by probing Secret Manager for the expected secret IDs (`{bot_account_id}-slack-token`, `{bot_account_id}-telegram-token`, etc.). To enable a new platform:

1. Uncomment its section in `terraform/main.tf`.
2. `terraform apply`.
3. Populate the secret value via `gcloud secrets versions add`.
4. Re-run `./deploy_and_update.sh`.

Don't add platform entries directly in the Firestore Console. They'll be overwritten on the next deploy.

### 6. User IDs are names — not platform IDs

The Forum sends the user's actual name (e.g. `"Jonathan Cavell"`) as `user_id` to the agent, and prefixes incoming messages with `[From: Name]` (or `[From: Name | platform_id: ...]` for scheduled jobs). Your agent should treat `user_id` as a human name, not a Slack `U...` ID, Telegram numeric ID, etc. This is how cross-platform identity works: the same person on Slack and Telegram gets the same `user_id`.

### 7. The scheduler MCP URL must have a trailing slash

When wiring `MCPToolset(StreamableHTTPConnectionParams(url=...))`, the URL must end in `/api/v1/mcp/scheduler/` — with the trailing slash. The Forum's FastAPI route is registered as `/scheduler/`; the bare form 307-redirects POST → GET, which silently breaks the MCP JSON-RPC handshake.

### 8. Multimodal input requires explicit handling

If your agent should accept images from users, you must override the input handling to extract the `images` parameter The Forum sends alongside `message`. The default ADK `Agent` ignores it and produces empty responses on image messages. See [The Forum's `FOR_AGENT_DEVELOPERS.md` §"Receiving Images from Slack"](https://github.com/Comites-ai/the-forum/blob/main/docs/FOR_AGENT_DEVELOPERS.md#receiving-images-from-slack) for the pattern.

### 9. Don't reach into The Forum repo to change The Forum's code

This repo and The Forum repo coordinate over Firestore documents and Secret Manager — never via shared code. If you find yourself wanting to modify The Forum's behavior from here, you're solving the wrong problem. Either:

- Use The Forum's existing extension points (the scheduler MCP, the Firestore platform array, the per-agent webhook routes).
- Open a PR against The Forum.

### 10. Sessions are stateful — clear them when prompts change

The Forum's Firestore `sessions` collection holds running conversations. If you change `agent.py`'s prompt in a way that's incompatible with mid-conversation state, sessions from before the change can produce weird responses. `deploy_and_update.sh` step 5 clears stale sessions automatically — let it do its job.

### 11. `get_started_linux.sh` is single-use and self-deletes

The bootstrap script runs once at repo setup and deletes itself. Don't try to re-run it to "regenerate" `.env` or `terraform.tfvars` — edit those files directly, or modify them via `terraform.tfvars.example` + a fresh clone.

## Building your agent

When you're filling in actual agent behavior:

### Defining the agent's purpose

`agent.py`'s `root_agent` has three fields that shape the LLM's behavior:

- `description`: a short summary of what the agent does — shown to other agents that use this one as a sub-agent.
- `instruction`: the system prompt. This is where the bulk of agent behavior lives.
- `tools`: the list of `FunctionTool` / `AgentTool` / `MCPToolset` the LLM can call.

Replace the stub `STUB_INSTRUCTION` with your real prompt. Keep prompts specific about *what tools to call and when*, especially if the agent has multiple tools that overlap.

### Adding a function tool

1. Define the function in `custom_functions.py` with a clear docstring (the LLM sees the docstring as the tool description).
2. Import it in `agent.py`: `from .custom_functions import my_tool`.
3. Wrap and add: `tools=[FunctionTool(my_tool), ...]`.

### Adding a sub-agent

1. Define the sub-agent in `custom_agents.py` (its own `Agent(...)` with its own model + prompt).
2. Import it in `agent.py`: `from .custom_agents import my_subagent`.
3. Wrap and add: `tools=[AgentTool(agent=my_subagent), ...]`.

### Adding an MCP toolset

Two transports:

- **stdio** (most public MCP servers): `MCPToolset(connection_params=StdioServerParameters(command="npx", args=["-y", "@org/server"], env={...}))`. Requires `npx`/`uvx` in the Reasoning Engine container.
- **Streamable HTTP / SSE** (hosted servers, including The Forum's scheduler): `MCPToolset(connection_params=StreamableHTTPConnectionParams(url="...", headers={"X-API-Key": ...}))`.

The scheduler MCP wiring is already stubbed in `agent.py` — uncomment after you've completed the three-step setup (see `terraform/main.tf` Section 6 and `README.md` "Adding the scheduler MCP").

### Using external APIs that need a key

1. Add the secret container + IAM binding in `terraform/main.tf` (follow the pattern of the existing platform secrets).
2. `terraform apply`.
3. Populate the secret value: `echo -n "API_KEY_VALUE" | gcloud secrets versions add my-secret --data-file=- --project=$GOOGLE_CLOUD_PROJECT`.
4. Fetch in the agent code: `secret_utilities.get_secret_from_secret_manager(project_id, "my-secret")`. Do this at module load time so cold-start latency is paid once per container instance, not per request.

### Local development

`adk web` from the repo root spins up a local web UI for the agent (talks to Vertex AI for the model, runs `agent.py` locally). Useful for iterating on prompts and tools without a full Reasoning Engine deploy. The Forum routing/platform stuff is bypassed in this mode — to test platform integration end-to-end, you have to deploy.

### Redeploying

`./deploy_and_update.sh`. See rule 4.

## Testing

The template ships a minimal sanity test in `test.md` (for template maintainers — gets deleted by `get_started_linux.sh` during initial setup). Once you're building your own agent, add your own tests under a `tests/` directory using `pytest` (already implied by `requirements.txt`). When you wire up CI, model it on The Forum's [`.github/workflows/ci.yml`](https://github.com/Comites-ai/the-forum/blob/main/.github/workflows/ci.yml).
