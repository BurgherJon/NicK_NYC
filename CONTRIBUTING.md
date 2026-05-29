# Contributing to the Comites.ai Agent Template

Welcome! This repository is the starter template for building Comites.ai agents — the AI advisors that run on [The Forum](https://github.com/Comites-ai/the-forum). Contributions here improve the bootstrap experience for everyone who uses the template to create a new agent.

## About the Project

The name "Comites" comes from the advisors who counseled Roman emperors. In our vision, users create AI agents (comites) that advise and assist them. "The Forum" is the place where users interact with their comites — and this template is the scaffolding that makes it fast and safe to spin up a new comes.

## Why MIT?

This template is licensed MIT — the most permissive widely-used open source license — because templates are scaffolding, and people building agents on top of it should be able to keep their own agent code under whatever license fits their situation (proprietary work for hire, internal tools, side projects, open source — anything). Forcing a copyleft license on every downstream agent would shrink the audience without giving Comites.ai anything in return.

[The Forum](https://github.com/Comites-ai/the-forum) itself stays AGPL-3.0 — that's a deployed service, where network copyleft makes sense. This template is starter code that gets cloned and modified, where MIT makes sense.

If you contribute changes back to the template, the CLA (below) is what gives Comites.ai the right to keep redistributing your contributions under MIT alongside the rest of the template.

## Contributor License Agreement (CLA)

All contributors must sign our Contributor License Agreement before their first pull request can be merged. We use [CLA Assistant](https://cla-assistant.io/) to handle the signing.

You can read the full CLA here: <https://gist.github.com/Jonathan-Comites/5825b5747f2446c9c4f973989858001f>

### Why a CLA?

The CLA ensures that Comites.ai has the rights to keep your contributions as part of this open-source project permanently. Without a CLA, contributors would retain sole copyright over their code and could potentially ask us to remove it later.

By signing the CLA, you're granting Comites.ai a license to use your contributions as part of the Comites.ai project — while you still retain your own copyright and can use your code however you like.

### How to Sign

When you open your first pull request, CLA Assistant will post a comment with a link. Follow the link, sign in with GitHub, and click the button to agree. **The CLA is effective the moment you do that** — your PR is unblocked immediately.

### Supplemental Information by Email

CLA Assistant records your GitHub username, email, and agreement timestamp. There is some additional information we'd like to have on file even though the CLA is already in force. Please email it to **cla@comites.ai** at your convenience. Use a subject line like `CLA supplemental info — <your GitHub username>` so we can match it to your signature.

Always include:

- **Full legal name** — the name CLA Assistant captured is your GitHub display name, which may not match your legal name.

Include the following only **if Section 4 of the CLA applies to you** (i.e., you are contributing on behalf of an employer or other entity):

- **Employer full legal name**
- **Your title or role at Employer**
- **Basis for your authority to bind** the employer to the CLA (e.g., signed delegation, role-based authority, employment policy, written approval from a specific authorized person, etc.)

### Contributing as Part of Your Job

If you are contributing to this codebase as part of your employment, we assume that when you sign the CLA, you are also signing it on behalf of your company. **You are responsible for ensuring you have the proper approvals from your employer to do so**, and we ask you to document this in your supplemental email (above).

If your company would prefer to have a formal Corporate CLA in place, please contact us at cla@comites.ai to arrange that.

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or request features.
- Search existing issues before creating a new one.
- Provide as much detail as possible: steps to reproduce, expected behavior, actual behavior, environment.

### Submitting Changes

1. **Fork the repository** and create a new branch from `main`.
2. **Make your changes** following our standards (below).
3. **Run through [`test.md`](test.md)** end-to-end: deploy a stub agent from your fork to a real GCP project, enable at least one messaging platform, and confirm the Junius Rusticus persona response reaches you on that platform. CI cannot verify this for you — it requires real GCP credentials.
4. **Submit a pull request** with a clear description of what you've done — CI runs automatically (shell lint + terraform lint + Python syntax).
5. **Sign the CLA** when prompted by CLA Assistant, and email cla@comites.ai with the supplemental information described above.

### Pull Request Guidelines

- Keep PRs focused on a single change.
- Write clear commit messages.
- Update [`README.md`](README.md), [`AGENTS.md`](AGENTS.md), or [`terraform/README.md`](terraform/README.md) if behavior changes.
- If you change `get_started_linux.sh`, `terraform/main.tf`, or `deploy_and_update.sh`, walk through `test.md` against a real GCP project before requesting review.
- Make sure CI is green before requesting review (shell lint, terraform lint, Python syntax all run automatically).

## Development Setup

### Prerequisites

- Python 3.11+
- Google Cloud SDK (`gcloud`) and `gcloud auth application-default login` completed.
- Terraform 1.2+.
- ADK (`pip install google-adk`).
- A GCP project with billing linked, dedicated to template testing — you'll create and destroy infrastructure in it repeatedly.
- A local clone of [The Forum](https://github.com/Comites-ai/the-forum) with its own `.env` and `terraform/terraform.tfvars` populated.

### Local Setup

```bash
# Clone your fork (rename the directory to something Python can import —
# get_started_linux.sh uses the directory name as the ADK package name).
git clone https://github.com/YOUR_USERNAME/agent-template.git my_test_agent
cd my_test_agent

# (Optional) Install dependencies in a venv if you want to lint or run
# register_agent.py locally without invoking get_started.
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Running the Template

The template doesn't have a "run" — `get_started_linux.sh` is the entrypoint. To test changes:

```bash
./get_started_linux.sh
# Walk through the prompts, selecting at least one platform.
# Once it completes, deploy:
./deploy_and_update.sh
# DM your bot on the platform you enabled. The agent should introduce itself
# as Junius Rusticus (the template's default placeholder persona) — see
# test.md step 7 for the exact keywords to verify.
```

Full smoke-test instructions are in [`test.md`](test.md).

### Cleaning Up After a Test

```bash
# In the terraform directory
terraform destroy

# Delete the Reasoning Engine
gcloud ai reasoning-engines list --region=us-central1 --project=$PROJECT_ID
gcloud ai reasoning-engines delete <ENGINE_ID> --region=us-central1 --project=$PROJECT_ID

# Delete the state bucket if you don't need it anymore
gcloud storage rm -r gs://$PROJECT_ID-tfstate

# Delete the Firestore record from The Forum's project
# (use the Firestore Console; the agent doc is in collection `agents`)
```

### Continuous Integration

Every pull request automatically runs:

| Check | What it does |
|---|---|
| **Shell lint** | `bash -n` syntax check + `shellcheck -S error` on `*.sh` |
| **Terraform lint** | `terraform fmt -check -recursive terraform/` |
| **Python syntax** | `python -m py_compile` on `*.py` (catches import-time errors only — no unit tests in the template) |

Workflow lives at [.github/workflows/ci.yml](.github/workflows/ci.yml). You can run the same checks locally:

```bash
bash -n *.sh
shellcheck -S error *.sh        # apt install shellcheck
terraform fmt -check -recursive terraform/
python -m py_compile agent.py custom_functions.py custom_agents.py secret_utilities.py register_agent.py
```

Live infrastructure tests are **not automated** — maintainers run `test.md` manually for PRs that touch `get_started_linux.sh`, `terraform/`, `deploy_and_update.sh`, or `register_agent.py`.

## Code Standards

### Style

- Follow PEP 8 for Python code.
- Use type hints where possible.
- Keep functions focused and reasonably sized.
- Write docstrings for public functions and classes (the LLM sees `FunctionTool` docstrings as tool descriptions — make them count).

### Layout

The template intentionally keeps the agent at the repo root (matching ADK convention). Don't add a `src/` or package wrapper.

- `agent.py` is the entrypoint — defines `root_agent`.
- `custom_functions.py` holds `FunctionTool`-wrappable functions.
- `custom_agents.py` holds sub-`Agent`s wrapped in `AgentTool`.
- `secret_utilities.py` holds Secret Manager helpers.
- Everything in `terraform/` is per-agent GCP infrastructure.
- Everything in `*.sh` is operator-facing automation.

### Commits

- Write clear, descriptive commit messages.
- Use present tense ("Add feature" not "Added feature").
- Reference issue numbers when applicable.

## Questions?

If you have questions about contributing, feel free to open an issue or reach out to the maintainers.

Thank you for contributing to the Comites.ai Agent Template!
