# Comites.ai Agent Template

A starter template for building AI agents that run on Vertex AI Agent Engine and serve users through **[The Forum](https://github.com/Comites-ai/the-forum)** — Comites.ai's open-source middleware that bridges Slack, Google Chat, Telegram, and Discord to your agent.

> **You are reading the template's README.** Once you run `./get_started_linux.sh`, this file is rewritten to be about *your* agent. The "what is this template" content you're reading is only here for first-time setup and for people who want to contribute changes to the template itself.

This README has two audiences:

- **You want to build a new agent.** → See [Building an agent with this template](#building-an-agent-with-this-template).
- **You want to change something about the template itself.** → See [Modifying the template](#modifying-the-template).

## Architecture

```
┌──────────────────────────────────────────────────────┐
│         Messaging platforms                          │
│   (Slack · Google Chat · Telegram · Discord)         │
└──────────────────────────┬───────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│  The Forum (Cloud Run)                               │
│  github.com/Comites-ai/the-forum                     │
│  · Routes messages to the right agent (via Firestore)│
│  · Manages sessions, identity, scheduled jobs        │
│  · Hosts the scheduler MCP server                    │
└──────────────────────────┬───────────────────────────┘
                           │  (cross-project call)
                           ▼
┌──────────────────────────────────────────────────────┐
│  YOUR AGENT (Vertex AI Reasoning Engine)             │
│  Lives in this repo · Deployed by deploy_and_update  │
│  · Conducts conversations using your prompt + tools  │
│  · Reads secrets / accesses Google Workspace via its │
│    own service account                               │
└──────────────────────────────────────────────────────┘
```

The template gives you:

- An ADK agent stub (`agent.py`) that replies with a recognizable greeting until you replace its instruction with real logic — so the first deploy proves the full pipeline works before you write any agent code.
- `terraform/` for the agent's dedicated GCP project (service account, secrets per platform, IAM bindings to The Forum, ADK staging bucket, Workspace API enablements). Platform sections commented out until you select them.
- `deploy_and_update.sh` — blue/green deploy + smoke test + Firestore registration + stale-session cleanup.
- `register_agent.py` — auto-detects enabled platforms by probing Secret Manager and writes the agent record to The Forum's Firestore.
- `get_started_linux.sh` — interactive bootstrap that asks you a handful of questions, generates `.env` + `terraform.tfvars`, uncomments the right terraform sections, provisions the state bucket, optionally runs `terraform apply` + populates secrets, optionally wires up a Google Doc for persistent memory, rewrites this README to be about your agent, and self-deletes.
- `AGENTS.md` — hard rules for AI coding agents working in the repo (and equally useful for humans).

---

# Building an agent with this template

## Prerequisites

Before running `./get_started_linux.sh`:

1. **A local clone of [The Forum](https://github.com/Comites-ai/the-forum)** with its own `.env` and `terraform/terraform.tfvars` already populated, AND The Forum already deployed at least once. `get_started_linux.sh` reads from these to figure out what project The Forum runs in and what its public URL is.

   The "deployed at least once" part matters because this template's terraform creates IAM bindings that reference the Forum project's Vertex AI Reasoning Engine Service Agent (`service-${FORUM_PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com`), which only auto-exists once Vertex AI has been used in that project. **`get_started_linux.sh` handles this automatically** by running `gcloud beta services identity create --service=aiplatform.googleapis.com --project=$FORUM_PROJECT_ID` during its API-bootstrap phase (it's idempotent — no-op if the identity already exists). You only need to know about this if you're applying terraform by hand, or if you don't have `roles/serviceusage.serviceUsageAdmin` on the Forum project — in which case the bootstrap will print a warning and ask the Forum's admin to run that one command before you re-try.
2. **A GCP project for this agent** (separate from The Forum's project) with billing linked. Create with:
   ```bash
   gcloud projects create YOUR_AGENT_PROJECT \
     --name="Your Agent Name" \
     --organization=YOUR_ORG_ID
   gcloud beta billing projects link YOUR_AGENT_PROJECT \
     --billing-account=YOUR_BILLING_ACCT
   ```
   `get_started_linux.sh` verifies the project exists and offers helpful errors if billing or APIs are missing — but it does not create the project for you (deliberate: project creation is one-time and not really a fit for an idempotent bootstrap script).
3. **CLI tools installed and on `$PATH`**: `gcloud`, `terraform` (≥ 1.2), `python3`, `pip`, `adk` (`pip install google-adk`).
4. **`gcloud` authenticated**: both `gcloud auth login` and `gcloud auth application-default login`.
5. **For at least one messaging platform you intend to test with**: the bot is already created on the platform's side (Slack app, Telegram BotFather, etc.), so you can paste the token into `get_started_linux.sh` when it prompts you. See [The Forum's `FOR_AGENT_DEVELOPERS.md`](https://github.com/Comites-ai/the-forum/blob/main/docs/FOR_AGENT_DEVELOPERS.md) for per-platform bot creation steps.

## Quick start

```bash
# 1. Clone this template (rename the directory to something that's a
#    valid Python identifier — no hyphens — since ADK uses the directory
#    name as the agent package name).
git clone <this-repo> my_agent
cd my_agent

# 2. Run the bootstrap. It walks you through everything and self-deletes
#    on success.
./get_started_linux.sh

# 3. Once it finishes, deploy.
./deploy_and_update.sh

# 4. DM your bot on any platform you enabled. You should get the stub
#    greeting back, confirming the pipeline works end-to-end.
```

After that, the repo is about *your* agent. Edit `agent.py` with your real prompt and tools, then redeploy with `./deploy_and_update.sh`. The post-setup `README.md` (which `get_started` writes) has a "Next steps" section that walks through adding tools, sub-agents, MCP servers, and external API integrations.

## What `get_started_linux.sh` does

1. Verifies prerequisites and `gcloud` auth.
2. Locates your local clone of The Forum and reads its config.
3. Asks you for: agent display name, `bot_account_id`, GCP project, region, models, which platforms to enable.
4. Generates `.env` and `terraform/terraform.tfvars`.
5. Uncomments the platform sections you selected in `terraform/main.tf`.
6. Creates the GCS bucket for terraform state and wires up the `backend "gcs"` block in `terraform/providers.tf`.
7. Optionally: runs `terraform apply` (two-phase: secret containers first, then prompts silently for each platform token and `gcloud secrets versions add`, then full apply).
8. Optionally: wires up a Google Doc for persistent agent memory (prompts for the doc ID, sets `AGENT_MEMORY_DOC_ID` in `.env`, prints the SA email to share the doc with).
9. Rewrites this README and updates `AGENTS.md`'s preface for your agent.
10. Deletes the template-only files (`test.md`, `MAINTAINER_SETUP.md`, `tests/`) and itself.
11. Prints what to do next: configure platform webhooks (per-platform instructions for whichever you selected), then `./deploy_and_update.sh`.

## Repository layout

```
.
├── agent.py                  # ADK root agent (Junius Rusticus stub persona until you replace)
├── __init__.py
├── custom_functions.py       # Your FunctionTool implementations
├── custom_agents.py          # Your sub-agents (used via AgentTool)
├── secret_utilities.py       # Secret Manager + retry helpers
├── requirements.txt
├── .env / .env.example       # Runtime config (.env is gitignored)
├── deploy_and_update.sh      # Blue/green deploy + smoke test + register
├── register_agent.py         # Auto-detects platforms, writes Firestore record
├── get_started_linux.sh      # One-shot bootstrap (self-deletes)
├── AGENTS.md                 # Hard rules for AI agents working in this repo
├── terraform/
│   ├── main.tf               # All resources (platform sections commented)
│   ├── variables.tf
│   ├── terraform.tfvars      # Your config (gitignored)
│   ├── terraform.tfvars.example
│   ├── providers.tf          # GCS backend wired by get_started
│   └── README.md
├── NOTICE                    # Attribution to the Comites.ai Agent Template
├── TRADEMARK.md
├── THIRD_PARTY_LICENSES
├── CONTRIBUTING.md           # CLA flow (same as The Forum)
└── .github/                  # CODEOWNERS, PR template, issue templates, CI

# Template-only files (deleted by get_started_linux.sh on first run):
# test.md, MAINTAINER_SETUP.md, tests/, .readme_template_post_setup.md
```

---

# Modifying the template

If you want to change something about the scaffolding itself (the bootstrap script, the terraform, the deploy script, etc.) and contribute it back, this section is for you.

## What you're contributing to

This repo is the scaffolding for new Comites.ai agents. Changes here affect every new agent created with the template, so testing is more rigorous than a typical app: a change can pass shell lint and terraform lint and still break a real bootstrap end-to-end. There are two tiers of testing:

1. **Fast local unit tests** — run in seconds, no GCP needed, catch the most common heuristic regressions.
2. **End-to-end GCP smoke test** — required for any PR that touches `get_started_linux.sh`, `terraform/`, `deploy_and_update.sh`, or `register_agent.py`. Creates real cloud resources, deploys a real Reasoning Engine, sends a real message through a real Slack workspace.

Both tiers are documented in [`test.md`](test.md).

## Development setup

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full development setup, but in short:

```bash
git clone https://github.com/YOUR_USERNAME/agent-template.git
cd agent-template
# Optional: python venv if you want to run register_agent.py locally
python -m venv venv && source venv/bin/activate && pip install -r requirements.txt
```

## Required testing before opening a PR

Run these in order:

```bash
# 1. Fast unit test — catches uncomment_section regressions
./tests/test_uncomment_section.sh

# 2. Local lint checks (same checks CI runs)
bash -n *.sh
shellcheck -S error *.sh                                    # apt install shellcheck
terraform fmt -check -recursive terraform/
python -m py_compile agent.py custom_functions.py custom_agents.py secret_utilities.py register_agent.py

# 3. If your PR touches get_started_linux.sh, terraform/,
#    deploy_and_update.sh, or register_agent.py:
#    Walk through test.md end-to-end against a real GCP project.
#    Read test.md for the full sequence.
```

CI runs the lint checks automatically on every PR. The unit test and the GCP test are NOT automated — the unit test should be (TODO), and the GCP test can't be (requires credentials).

## How the pieces fit together

Most changes touch one or two of these:

- **`get_started_linux.sh`** — the interactive bootstrap. 16 phases, mirroring The Forum's `install.sh` patterns. The trickiest piece is `uncomment_section` (around line 470), which uses a brace-balanced block detector to selectively uncomment platform sections in `terraform/main.tf`. The unit test in `tests/test_uncomment_section.sh` exists specifically because this heuristic is the most likely thing to silently break.
- **`terraform/main.tf`** — all GCP infrastructure for the agent's dedicated project. Section 1 (common) is always active; sections 2-6 (Slack, Google Chat, Telegram, Discord, Scheduler MCP) are commented blocks that `uncomment_section` selectively enables. If you add a new platform or rename resources, update the expected-resource lists in `tests/test_uncomment_section.sh`.
- **`deploy_and_update.sh`** — blue/green deploy. Generalizes the pattern from `agents/growth_coach`. Reads config from `.env`.
- **`register_agent.py`** — auto-detects platforms from Secret Manager and writes the agent's Firestore record. Validates each token via the platform's native API before writing.
- **`agent.py`** — the stub agent that the template ships. Replaces operator-facing logic in `STUB_INSTRUCTION` and `description`. The default persona is Junius Rusticus (Stoic teacher of Marcus Aurelius — namesake inspiration for the project). If you change the stub persona, update the expected keywords in `test.md` step 7.
- **`AGENTS.md`** — hard rules for AI agents (and humans) working in repos created from the template. Add a new rule when there's a way to break an agent that's not obvious from the code.

## How CI works

Every PR runs three jobs (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

| Job | What it does |
|---|---|
| Shell lint | `bash -n` syntax check + `shellcheck -S error` on `*.sh` |
| Terraform lint | `terraform fmt -check -recursive terraform/` |
| Python syntax | `python -m py_compile` on `*.py` |

CI does NOT run the unit test in `tests/` or the GCP test in `test.md` yet — those are manual gates. The unit test is a near-term TODO to wire into CI (it doesn't need GCP credentials, just `terraform` and `python3`).

## PR flow

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the CLA process. Briefly:

1. Fork, branch from `main`, make your changes.
2. Run the testing sequence above.
3. Open a PR. CLA Assistant will prompt you to sign the CLA on your first PR; do so and email `cla@comites.ai` with the supplemental info described in `CONTRIBUTING.md`.
4. A maintainer will review. For PRs touching infrastructure files, the maintainer will spot-check the GCP test result you describe in your PR body.

## Maintainer-only docs

Two files exist for Comites.ai maintainers (not template contributors and not template users):

- [`MAINTAINER_SETUP.md`](MAINTAINER_SETUP.md) — One-time setup steps for publishing this repo as OSS on GitHub (CLA Assistant, branch protection, etc.) and for updating The Forum repo to point at this template. Read it once when first setting up the repo, then ignore.

Both `MAINTAINER_SETUP.md` and `test.md` are deleted by `get_started_linux.sh` so they never appear in an end user's agent repo.

---

## License

All rights reserved. This project does not ship an open-source license.

Built on the **Comites.ai Agent Template**, which is distributed under the MIT License. The template's original copyright and permission notice are retained in [NOTICE](NOTICE) as attribution. The Comites.ai trademark policy still applies separately: this project is not affiliated with, endorsed by, or a product of Comites.ai.

## Acknowledgements

This template is the convergence of patterns developed across The Forum and the existing Comites.ai agents (Growth Coach, Sommelier). It packages those patterns up so creating a new agent doesn't require excavating five years of decisions from five different repos.
