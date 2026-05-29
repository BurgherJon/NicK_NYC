# Agent Infrastructure — Terraform
#
# This file manages all GCP resources for the agent EXCEPT the GCP project
# itself and the terraform state bucket. Both are bootstrapped via gcloud
# in get_started_linux.sh (the project because terraform managing its own
# project is fragile; the state bucket because the backend has to exist
# before `terraform init`).
#
# STRUCTURE:
#   Section 1: Common infrastructure (all agents)
#   Section 2: Slack-specific infrastructure (uncomment if using Slack)
#   Section 3: Google Chat-specific infrastructure
#   Section 4: Telegram-specific infrastructure
#   Section 5: Discord-specific infrastructure
#   Section 6: Scheduler MCP key (uncomment to use The Forum's scheduler MCP)
#
# Sections 2-6 are commented out by default. get_started_linux.sh uncomments
# whichever ones the operator selects. You can also uncomment them manually.
#
# Hard rule: never add cloud resources to this agent outside terraform.
# Modify this file, `terraform apply`, and commit. See AGENTS.md.

# ==============================================================================
# SECTION 1: COMMON INFRASTRUCTURE (Required for all agents)
# ==============================================================================

# The project is pre-existing — created via `gcloud projects create` in
# get_started_linux.sh. We reference it as a data source so we never own
# its lifecycle.
data "google_project" "agent_project" {
  project_id = var.project_id
}

# The Forum's project, looked up so we can resolve its default compute SA
# (the principal The Forum runs Cloud Run as) for cross-project IAM
# bindings on this agent's platform secrets.
data "google_project" "forum" {
  project_id = var.forum_project_id
}

locals {
  # The Forum's Cloud Run runs as the project's default compute SA.
  forum_runtime_sa = "${data.google_project.forum.number}-compute@developer.gserviceaccount.com"

  # Vertex AI Reasoning Engine Service Agent in the Forum project. When
  # this agent is deployed (via deploy_and_update.sh, which lands the
  # Reasoning Engine in the Forum's project), this service agent is the
  # principal Vertex AI uses to mint short-lived credentials for the
  # runtime SA. It needs `roles/iam.serviceAccountTokenCreator` on the
  # per-agent SA, granted below as `engine_token_creator`.
  forum_vertex_ai_service_agent = "service-${data.google_project.forum.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
}

# --- APIs ---
# Bootstrap APIs (serviceusage, cloudresourcemanager, secretmanager) are
# already enabled by get_started_linux.sh — terraform would chicken-and-egg
# if it tried to enable them itself. The APIs below are the rest.

resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "aiplatform" {
  project            = var.project_id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

# Google Workspace APIs — enabled by default so the agent can read/write
# Sheets, Docs, and Drive once the operator shares a file with the agent SA.
# If your agent doesn't need any of these, you can comment them out.
resource "google_project_service" "drive" {
  project            = var.project_id
  service            = "drive.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sheets" {
  project            = var.project_id
  service            = "sheets.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "docs" {
  project            = var.project_id
  service            = "docs.googleapis.com"
  disable_on_destroy = false
}

# --- Service account ---
# A single SA is used for everything: Google APIs (Drive/Sheets/Docs) and,
# when Google Chat is enabled (Section 3), sending Chat messages. Share
# your spreadsheets, docs, and memory docs with this SA's email; its key
# (when Section 3 is enabled) gets stored in Secret Manager.
resource "google_service_account" "agent" {
  project      = var.project_id
  account_id   = var.bot_account_id
  display_name = var.bot_name
  description  = "Service account for ${var.bot_name} (Google APIs + platform integrations)"

  depends_on = [
    google_project_service.drive,
    google_project_service.sheets,
    google_project_service.docs,
  ]
}

# Allow service account key creation for this project. Most orgs enforce
# `constraints/iam.disableServiceAccountKeyCreation` org-wide. Google Chat
# (Section 3) needs an SA key in Secret Manager, so we override the policy
# at the project level. If you're not using Google Chat you can remove this.
resource "google_project_organization_policy" "allow_sa_key_creation" {
  project    = var.project_id
  constraint = "constraints/iam.disableServiceAccountKeyCreation"

  boolean_policy {
    enforced = false
  }
}

# --- Staging bucket for ADK deployments ---
# `adk deploy agent_engine` uploads the agent code here before deploying
# to Vertex AI. Lifecycle policy cleans up old uploads after 7 days.
#
# Note on project placement: the Reasoning Engine itself runs in the
# Forum's project (so all agents are administratively centralized), but
# the staging bucket lives in THIS project. That keeps the agent's code
# artifacts isolated under the agent's billing and IAM. The Forum's
# Vertex AI Service Agent gets read-only access via the cross-project
# IAM binding below (`engine_staging_reader`), so it can fetch the
# packaged agent code at cold-start time.
resource "google_storage_bucket" "staging" {
  project                     = var.project_id
  name                        = "${var.project_id}-staging"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [
    google_project_service.storage,
  ]
}

# --- Cross-project IAM for deploying as the per-agent SA ---
#
# The Reasoning Engine lands in the Forum's project but RUNS AS this
# agent's per-agent SA (configured via .agent_engine_config.json's
# `service_account` field). For Vertex AI to assume the per-agent SA's
# identity at runtime, the Vertex AI Reasoning Engine Service Agent in
# the Forum project needs:
#
#   1. Permission to mint tokens for the per-agent SA
#      (`roles/iam.serviceAccountTokenCreator` on the SA itself).
#   2. Permission to read the packaged agent code from this staging
#      bucket (`roles/storage.objectViewer` on the bucket).
#
# Without these, the deploy succeeds but the engine fails to start with
# a permission-denied error at first invocation.

resource "google_service_account_iam_member" "engine_token_creator" {
  service_account_id = google_service_account.agent.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.forum_vertex_ai_service_agent}"
}

resource "google_storage_bucket_iam_member" "engine_staging_reader" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.forum_vertex_ai_service_agent}"
}

# ==============================================================================
# SECTION 2: SLACK
# Uncomment to enable Slack. After `terraform apply`, populate the secret:
#   echo -n "xoxb-YOUR-TOKEN" | gcloud secrets versions add \
#     ${var.bot_account_id}-slack-token --data-file=- --project=${var.project_id}
# (get_started_linux.sh does this for you when you select Slack.)
# ==============================================================================

# resource "google_secret_manager_secret" "slack_bot_token" {
#   project   = var.project_id
#   secret_id = "${var.bot_account_id}-slack-token"
#
#   replication {
#     auto {}
#   }
#
#   depends_on = [google_project_service.secretmanager]
# }
#
# resource "google_secret_manager_secret_iam_member" "slack_token_forum_accessor" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.slack_bot_token.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:${local.forum_runtime_sa}"
# }

# ==============================================================================
# SECTION 3: GOOGLE CHAT
# Uncomment to enable Google Chat. Each Google Chat bot needs its own GCP
# project (Google Chat API restriction) — that's already handled because
# this whole template is per-agent-project.
# ==============================================================================

# resource "google_project_service" "chat" {
#   project            = var.project_id
#   service            = "chat.googleapis.com"
#   disable_on_destroy = false
# }
#
# # Grant the agent SA permission to send Google Chat messages.
# resource "google_project_iam_member" "chat_owner" {
#   project = var.project_id
#   role    = "roles/chat.owner"
#   member  = "serviceAccount:${google_service_account.agent.email}"
# }
#
# # Container for the agent SA's key (the key value itself is populated
# # post-apply: get_started_linux.sh creates the SA key, uploads it, and
# # deletes the local file).
# resource "google_secret_manager_secret" "chat_credentials" {
#   project   = var.project_id
#   secret_id = var.chat_credentials_secret_name
#
#   replication {
#     auto {}
#   }
#
#   depends_on = [google_project_service.secretmanager]
# }
#
# resource "google_secret_manager_secret_iam_member" "chat_credentials_forum_accessor" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.chat_credentials.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:${local.forum_runtime_sa}"
# }

# ==============================================================================
# SECTION 4: TELEGRAM
# Uncomment to enable Telegram. After `terraform apply`, populate the secret:
#   echo -n "YOUR_TELEGRAM_BOT_TOKEN" | gcloud secrets versions add \
#     ${var.bot_account_id}-telegram-token --data-file=- --project=${var.project_id}
# ==============================================================================

# resource "google_secret_manager_secret" "telegram_bot_token" {
#   project   = var.project_id
#   secret_id = "${var.bot_account_id}-telegram-token"
#
#   replication {
#     auto {}
#   }
#
#   depends_on = [google_project_service.secretmanager]
# }
#
# resource "google_secret_manager_secret_iam_member" "telegram_token_forum_accessor" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.telegram_bot_token.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:${local.forum_runtime_sa}"
# }

# ==============================================================================
# SECTION 5: DISCORD
#
# Unlike Slack/Telegram, Discord uses a long-lived Gateway WebSocket rather
# than an HTTP webhook. The Forum runs a SINGLE multi-tenant discord-worker
# VM in its own project; that worker auto-discovers Discord-enabled agents
# from Firestore at runtime. To onboard a Discord agent:
#   1. Uncomment this section, `terraform apply`.
#   2. Populate ${bot_account_id}-discord-token with the bot token.
#   3. register_agent.py writes the Firestore platform block on next deploy.
#   4. Wait up to 300s (or reset the worker VM in The Forum's project) for
#      the worker to pick up the new bot.
# No terraform changes in The Forum's repo are required.
#
# Discord needs TWO cross-project secretAccessor bindings: the discord-worker
# VM SA (reads the token to open the inbound Gateway WebSocket) AND The Forum's
# Cloud Run SA (reads the token to send outbound REST replies). Granting only
# one results in DMs reaching The Forum but every reply 403ing.
# ==============================================================================

# resource "google_secret_manager_secret" "discord_bot_token" {
#   project   = var.project_id
#   secret_id = "${var.bot_account_id}-discord-token"
#
#   replication {
#     auto {}
#   }
#
#   depends_on = [google_project_service.secretmanager]
# }
#
# # (a) The Forum's discord-worker VM SA — for inbound Gateway connection.
# resource "google_secret_manager_secret_iam_member" "discord_token_worker_accessor" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.discord_bot_token.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:discord-worker@${var.forum_project_id}.iam.gserviceaccount.com"
# }
#
# # (b) The Forum's Cloud Run SA — for outbound REST replies.
# resource "google_secret_manager_secret_iam_member" "discord_token_forum_accessor" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.discord_bot_token.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:${local.forum_runtime_sa}"
# }

# ==============================================================================
# SECTION 6: SCHEDULER MCP KEY
#
# Uncomment to use The Forum's scheduler MCP server (the only MCP server
# The Forum hosts). The agent uses this to create/list/update/delete
# scheduled reminders for its users via tool calls.
#
# Three-step flow:
#   1. Uncomment + `terraform apply` (creates the empty secret container +
#      IAM binding for the Reasoning Engine SA).
#   2. From The Forum repo, run `python scripts/provision_scheduler_api_key.py
#      --agent-id YOUR_AGENT_FIRESTORE_ID`. Copy the printed plaintext.
#   3. Populate: echo -n "PLAINTEXT" | gcloud secrets versions add \
#        ${bot_account_id}-scheduler-mcp-key --data-file=- --project=PROJECT
#
# get_started_linux.sh walks you through steps 2 and 3 if you select this option.
# ==============================================================================

# resource "google_secret_manager_secret" "scheduler_mcp_key" {
#   project   = var.project_id
#   secret_id = "${var.bot_account_id}-scheduler-mcp-key"
#
#   replication {
#     auto {}
#   }
#
#   depends_on = [google_project_service.secretmanager]
# }
#
# # Grant the AGENT's default compute SA (which Vertex AI Reasoning Engine
# # runs as by default) read access. If you deploy with --service-account=...
# # in deploy_and_update.sh, replace the member below with that SA email.
# resource "google_secret_manager_secret_iam_member" "scheduler_mcp_key_reasoning_engine" {
#   project   = var.project_id
#   secret_id = google_secret_manager_secret.scheduler_mcp_key.secret_id
#   role      = "roles/secretmanager.secretAccessor"
#   member    = "serviceAccount:${data.google_project.agent_project.number}-compute@developer.gserviceaccount.com"
# }

# ==============================================================================
# OUTPUTS
# ==============================================================================

output "project_id" {
  description = "GCP project ID hosting this agent"
  value       = var.project_id
}

output "service_account_email" {
  description = "Agent service account email. Share Google Sheets/Drive/Docs with this email; it also signs Google Chat messages when Section 3 is enabled."
  value       = google_service_account.agent.email
}

output "staging_bucket" {
  description = "GCS bucket for ADK deployment staging"
  value       = google_storage_bucket.staging.name
}

output "forum_runtime_sa" {
  description = "The Forum's Cloud Run service account (the principal granted secretAccessor on this agent's platform secrets)"
  value       = local.forum_runtime_sa
}
