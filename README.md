# Nick — NYC Expert

Nick is a friendly, knowledgeable New York City expert. He talks to users over **Slack**, runs on **Vertex AI Agent Engine**, and is routed through **[The Forum](https://github.com/Comites-ai/the-forum)** — the middleware that bridges messaging platforms to agents.

## How Nick works

- **Instructions come from a Google Doc.** Nick's system prompt is the live contents of a read-only Google Doc, fetched fresh on each turn (see `INSTRUCTION_DOC_ID` in [agent.py](agent.py)). Edit the doc to change Nick's behavior — no redeploy needed. Nick has no tool to modify it, so he can never edit his own instructions.
- **Memory is a second Google Doc.** `get_agent_memory()` / `update_agent_memory()` ([custom_functions.py](custom_functions.py)) read and write a separate Google Doc (`AGENT_MEMORY_DOC_ID`) where Nick keeps notes about users and ongoing context.

Both docs are native Google Docs shared with Nick's runtime service account (`agent-demo@agent-demo-497222.iam.gserviceaccount.com`) — Viewer for instructions, Editor for memory.

## Architecture

```
┌───────────────────────────────────────────────┐
│  Slack (bot: nick_the_nyc_planner)            │
└───────────────────────┬───────────────────────┘
                        ▼
┌───────────────────────────────────────────────┐
│  The Forum (Cloud Run)                        │
│  project: vertex-ai-middleware-prod           │
└───────────────────────┬───────────────────────┘
                        ▼
┌───────────────────────────────────────────────┐
│  Nick NYC (Vertex AI Reasoning Engine)        │
│  runs as: agent-demo@agent-demo-497222        │
│  config/secrets project: agent-demo-497222    │
└───────────────────────────────────────────────┘
```

The Reasoning Engine physically lives in The Forum's project (so The Forum can route to it) but runs as Nick's own per-agent service account in `agent-demo-497222`, where his secrets and staging bucket live. See [AGENTS.md](AGENTS.md) for why.

## Local development

```bash
# In a venv with this repo's dependencies installed (pip install -r requirements.txt)
adk web
```

Launches a local UI for chatting with Nick. Slack/Forum routing is bypassed in this mode — to test the platform integration end-to-end, deploy.

## Deploy

```bash
./deploy_and_update.sh
```

Blue/green: deploys a new Reasoning Engine, smoke-tests it, repoints The Forum's Firestore at the new engine, clears stale sessions, then deletes the old engine. Safe to re-run — if anything fails partway, the old engine is untouched. See [AGENTS.md](AGENTS.md) for the operating rules (infra goes through terraform, secrets in Secret Manager, platforms auto-detected, etc.).

## Attribution & license

All rights reserved; this project ships no open-source license. It was bootstrapped from the [Comites.ai Agent Template](https://github.com/Comites-ai/agent-template) (MIT) and runs on [The Forum](https://github.com/Comites-ai/the-forum) — the template's MIT notice is retained in [NOTICE](NOTICE) as attribution. Third-party dependency licenses are listed in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
