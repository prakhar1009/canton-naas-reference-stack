#
# This Terraform module provisions a serverless, scheduled backup solution for
# Cloud SQL instances used by Canton Network participants. It complements the
# standard built-in automated backups by providing a flexible, on-demand trigger
# via Cloud Scheduler. This is useful for creating backups before maintenance,
# upgrades, or for more granular backup strategies.
#
# The module creates:
# 1. A dedicated IAM Service Account with the principle of least privilege.
# 2. IAM bindings to allow the Service Account to create Cloud SQL backups.
# 3. A Cloud Scheduler job for each specified SQL instance, which triggers
#    the backup via a direct HTTP call to the Cloud SQL Admin API.
#

# -----------------------------------------------------------------------------
# Module Variables
# -----------------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project ID where the Cloud SQL instances and scheduler reside."
  type        = string
}

variable "location" {
  description = "The GCP region for deploying the scheduler jobs (e.g., 'us-central1'). Must match the App Engine location in the project."
  type        = string
}

variable "sql_instance_names" {
  description = "A list of Cloud SQL instance names to be backed up. This can include both participant and PQS database instances."
  type        = list(string)
}

variable "schedule" {
  description = "The backup schedule in cron format (e.g., '0 2 * * *' for 2 AM daily)."
  type        = string
  default     = "0 2 * * *"
}

variable "time_zone" {
  description = "Specifies the time zone for the schedule, from the tz database. Defaults to UTC."
  type        = string
  default     = "Etc/UTC"
}

variable "service_account_name" {
  description = "The name (account_id) of the service account to create for managing backups."
  type        = string
  default     = "canton-sql-backup-sa"
}

variable "backup_description" {
  description = "A description to attach to the backups created by this scheduler for traceability."
  type        = string
  default     = "Scheduled on-demand backup triggered by Cloud Scheduler"
}

# -----------------------------------------------------------------------------
# Resources
# -----------------------------------------------------------------------------

# Create a dedicated service account for the backup jobs. This follows the
# principle of least privilege, ensuring the job only has permissions it needs.
resource "google_service_account" "backup_sa" {
  project      = var.project_id
  account_id   = var.service_account_name
  display_name = "Canton NaaS SQL Backup Service Account"
  description  = "Used by Cloud Scheduler to trigger on-demand backups for Canton participant and PQS databases."
}

# Grant the service account the 'Cloud SQL Editor' role at the project level.
# This role is required to call the backups.create API method.
resource "google_project_iam_member" "sql_editor_binding" {
  project = var.project_id
  role    = "roles/cloudsql.editor"
  member  = "serviceAccount:${google_service_account.backup_sa.email}"
}

# The scheduler service needs permission to generate an OAuth token for the service
# account it runs as, in order to authenticate its request to the Cloud SQL API.
# This grants the service account the ability to act as itself.
resource "google_service_account_iam_member" "token_creator_binding" {
  service_account_id = google_service_account.backup_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.backup_sa.email}"
}

# Create a scheduler job for each SQL instance provided in the input list.
# This allows the module to flexibly manage backups for multiple databases
# (e.g., a primary participant and its PQS instance) with the same schedule.
resource "google_cloud_scheduler_job" "sql_backup_job" {
  for_each = toset(var.sql_instance_names)

  project     = var.project_id
  region      = var.location
  name        = "canton-sql-backup-${each.key}"
  description = "Triggers an on-demand backup for the Cloud SQL instance: ${each.key}"
  schedule    = var.schedule
  time_zone   = var.time_zone

  # The job targets the Cloud SQL Admin REST API directly. This serverless approach
  # avoids the need for a separate Cloud Function or Cloud Run service, simplifying
  # the architecture and reducing cost.
  http_target {
    uri         = "https://sqladmin.googleapis.com/v1/projects/${var.project_id}/instances/${each.key}/backups"
    http_method = "POST"

    # Use the dedicated service account to authenticate the API request via an OAuth token.
    oauth_token {
      service_account_email = google_service_account.backup_sa.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }

    headers = {
      "Content-Type" = "application/json"
    }

    # The request body is a JSON object defining the backup run configuration.
    # We include a description for easy identification in the GCP console.
    # The body string must be base64 encoded for the scheduler resource.
    body = base64encode(jsonencode({
      description = var.backup_description
    }))
  }

  # Ensure IAM permissions are fully provisioned before attempting to create
  # the scheduler job that depends on them.
  depends_on = [
    google_project_iam_member.sql_editor_binding,
    google_service_account_iam_member.token_creator_binding
  ]
}

# -----------------------------------------------------------------------------
# Module Outputs
# -----------------------------------------------------------------------------

output "scheduler_job_ids" {
  description = "The full resource IDs of the created Cloud Scheduler jobs."
  value       = [for job in google_cloud_scheduler_job.sql_backup_job : job.id]
}

output "service_account_email" {
  description = "The email address of the service account created for managing backups."
  value       = google_service_account.backup_sa.email
}