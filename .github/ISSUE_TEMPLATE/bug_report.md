---
name: Bug Report
about: Report a bug in the Comites.ai Agent Template
title: '[BUG] '
labels: bug
assignees: ''
---

## Description

<!-- A clear description of the bug. Is this about the template scaffolding (terraform, scripts, etc.) or about agent behavior after using the template? -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What you expected to happen -->

## Actual Behavior

<!-- What actually happened -->

## Environment

- Step where the bug appeared: <!-- get_started_linux.sh / terraform apply / deploy_and_update.sh / register_agent.py / agent runtime / other -->
- Platforms enabled: <!-- Slack / Google Chat / Telegram / Discord -->
- OS:
- gcloud version: <!-- gcloud --version | head -1 -->
- terraform version: <!-- terraform -version | head -1 -->
- Python version:
- ADK version: <!-- adk --version -->

## Logs

<!-- Include relevant log output. For runtime issues, the most useful sources are:
     - get_started_linux.sh / deploy_and_update.sh stdout
     - gcloud run services logs read the-forum --project <FORUM_PROJECT> --region us-central1 --limit 50
     - gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine"' --project <AGENT_PROJECT> --limit 50
-->

```
Paste logs here
```

## Additional Context

<!-- Any other information that might help -->
