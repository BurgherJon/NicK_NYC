# Maintainer Setup

**Audience: Comites.ai maintainers only.** This file documents the one-time steps needed to (a) publish this repository as an OSS project on GitHub and (b) update [The Forum](https://github.com/Comites-ai/the-forum) to point at this template.

**Important: This file is deleted by `get_started_linux.sh`.** End users of the template never see it. If you're using the template to build your own agent, ignore this file — `get_started_linux.sh` will remove it on first run.

---

## Part 1: Publish this repo as OSS

Follow these steps in order. Each step depends on the previous ones.

### 1. Create the GitHub repo

Create a new repo under the `Comites-ai` GitHub org. Suggested names (pick one):

- `agent-template` (cleanest)
- `comites-agent-template` (explicit)
- `forum-agent-template` (ties to The Forum)

Set the repo's description to something like *"Starter template for building Comites.ai agents on The Forum."* and link to https://github.com/Comites-ai/the-forum.

**Keep the repo private until you've completed step 7 (running the smoke test in `test.md`).** Once tested, switch to public.

### 2. Push this code

```bash
cd /path/to/this/repo
git remote add origin git@github.com:Comites-ai/<repo-name>.git
git push -u origin main
# (and any feature branches you want to keep)
```

### 3. ⚠️ Enable CLA Assistant BEFORE accepting any PRs ⚠️

Without CLA Assistant, contributors can open PRs that copyright law makes very awkward to merge or remove later. **Do this immediately after creating the repo, before sharing it with anyone.**

1. Go to https://cla-assistant.io/ and sign in with the GitHub account that has admin access to the new repo.
2. Click "Configure CLA".
3. Select the new repository.
4. Paste this gist URL when prompted for the CLA:
   ```
   https://gist.github.com/Jonathan-Comites/5825b5747f2446c9c4f973989858001f
   ```
   (Same gist The Forum uses — one CLA covers all Comites.ai repos.)
5. Save.

Verify by opening a test PR — CLA Assistant should comment within ~30 seconds with the signing link. Close the test PR after confirming.

### 4. Set branch protection on `main`

GitHub repo settings → Branches → Add classic branch protection rule for `main`:

- Require a pull request before merging
- Require approvals: at least 1
- Require status checks to pass before merging:
  - Shell lint
  - Terraform lint
  - Python syntax
  - CLA signed
- Require linear history
- Do not allow bypassing the above settings (no admin overrides)

### 5. Verify the `@Comites-ai/maintainers` team

`.github/CODEOWNERS` references `@Comites-ai/maintainers`. Confirm that team exists in the GitHub org and that you've added this repo to the team with admin access. If the team doesn't exist, create it under GitHub Organizations → Teams.

### 6. Configure repository metadata

In the repo's Settings page:

- **About section** (right sidebar of the main repo page): write a one-line description, link to https://github.com/Comites-ai/the-forum.
- **Topics**: add `agent-template`, `comites-ai`, `vertex-ai`, `adk`, `slack`, `google-chat`, `telegram`, `discord`. Helps discoverability.
- **Features**: enable Issues; enable Discussions if you want a Q&A surface beyond Issues.

### 7. Run `test.md` end-to-end against a fresh GCP project

Before going public, confirm the template actually works:

```bash
# Clone a fresh copy (don't use your dev copy — you want the published version)
git clone git@github.com:Comites-ai/<repo-name>.git test_smoke
cd test_smoke
# Follow test.md
```

If anything fails, fix it on a branch, PR back to `main`, and re-run.

### 8. Make the repo public

GitHub repo settings → General → Danger Zone → "Change repository visibility" → Public.

### 9. Announce

- Update https://github.com/Comites-ai (the org's public profile / README) to link to the new template.
- Cross-post on whatever channels you use to announce Comites.ai releases.

---

## Part 2: Update The Forum to point at this template

Once the template is published and public, The Forum repo needs updates so:

- Its docs reference this template as the canonical way to start a new agent.
- It doesn't ship its own copy of the same files (terraform template, register script).

The Forum changes are themselves a PR — open it against `Comites-ai/the-forum`. Below is what to change.

### 1. Delete the now-redundant terraform template

The Forum currently ships its own copy of the agent-project terraform template at:

- `docs/terraform-templates/agent-project/main.tf`
- `docs/terraform-templates/agent-project/variables.tf`
- `docs/terraform-templates/agent-project/terraform.tfvars.example`
- `docs/terraform-templates/agent-project/README.md`

The whole directory can be deleted — `terraform/` in *this* template is the authoritative copy. (Note: the two are nearly identical today, but this template's version has been adapted to use a `data "google_project"` reference instead of creating the project, and assumes the GCS state backend pattern. If you want to keep a single source of truth, the cleanest path is: delete the Forum's copy, link to this template from `FOR_AGENT_DEVELOPERS.md`.)

```bash
# In The Forum repo
git rm -r docs/terraform-templates/
```

### 2. Delete the now-redundant register_agent template

Similarly, `docs/scripts/register_agent_template.py` in The Forum is the seed of this template's `register_agent.py`. Delete it.

```bash
git rm docs/scripts/register_agent_template.py
# If docs/scripts/ is now empty, remove the directory too.
```

### 3. Update `docs/FOR_AGENT_DEVELOPERS.md`

Several sections currently say "copy `docs/terraform-templates/agent-project/` to your agent repo" or "copy `docs/scripts/register_agent_template.py` to your agent repo". Replace those with a pointer to the template:

> To create a new agent that integrates with The Forum, use the [Comites.ai Agent Template](https://github.com/Comites-ai/agent-template). It packages the terraform, registration script, deploy script, and bootstrap wizard — and walks you through configuration interactively.

Specifically, search-and-update these phrases in `FOR_AGENT_DEVELOPERS.md`:

- "Copy this file to your agent repository" (early on)
- "Copy the terraform templates from the middleware repo"
- "Copy the template to your agent repository"
- "Use the Template Registration Script (Recommended)"
- The full "Creating a Brand New Agent — Slack/Google Chat/Telegram/Discord" sections can be condensed substantially — most of their content is now in the template's `get_started_linux.sh` flow. Keep the *platform-specific* details (how to create a Slack app, how to get a Telegram BotFather token, how to configure Google Chat in the Console, the Discord worker setup) but defer the *infrastructure* steps to "see the agent template".

After this PR, `FOR_AGENT_DEVELOPERS.md` should be roughly half its current length — the parts about Vertex AI deployment, terraform, and Firestore registration all live in the template now.

### 4. Update The Forum's main `README.md`

In the "Adding agents" or equivalent section, replace any "copy this terraform template / copy this registration script" instructions with a link to https://github.com/Comites-ai/agent-template.

### 5. Update The Forum's `terraform/README.md` if needed

If The Forum's terraform README references the agent-project template directory, update those links to point at this repo.

### 6. Cross-link from both directions

In the new template's `README.md` (this repo): linked to The Forum already.

In The Forum's `README.md`: add the agent template to whatever "related projects" section exists, or add one if it doesn't.

### 7. Open the PR

Title: `Migrate agent scaffolding to the dedicated agent-template repo`

Body should:

- Link this template repo
- List what's being deleted from The Forum
- List what's being updated in `FOR_AGENT_DEVELOPERS.md`
- Note that the template repo is the new authoritative source for the terraform + register script

Wait for review, get CI green (The Forum's CI runs `pytest` + shell lint + terraform lint), merge.

### 8. After the Forum PR is merged

Verify that someone following The Forum's docs ends up at this template repo. If they don't, iterate on the doc updates.

---

## Once both parts are done

You can delete this file from your local working copy of the agent template if you want (it's not used after initial setup). It's also automatically deleted by `get_started_linux.sh` for any end user who clones the template — so it never gets in their way. The only people who see this file are:

- You and other maintainers, immediately after cloning the template repo for maintenance.
- Anyone reading the repo on GitHub without going through `get_started_linux.sh`.

If you ever fork The Forum and want to publish a sibling agent template against your fork, this file is the recipe for redoing the setup against your fork.
