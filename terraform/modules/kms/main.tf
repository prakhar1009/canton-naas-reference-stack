# Manages KMS resources for Canton validator key segregation on Google Cloud Platform.
# This module creates a KMS KeyRing and a unique, HSM-protected CryptoKey for
# each validator, ensuring cryptographic isolation between tenants.

variable "project_id" {
  description = "The GCP project ID where KMS resources will be created."
  type        = string
}

variable "location" {
  description = "The GCP location (region) for the KMS KeyRing."
  type        = string
}

variable "keyring_name" {
  description = "The name of the KMS KeyRing that will hold validator keys."
  type        = string
  default     = "canton-validator-keyring"
}

variable "validators" {
  description = "A map of validators to create KMS keys for. The map key is a unique validator identifier, and the value is an object containing the service account email that will operate the validator."
  type = map(object({
    service_account_email = string
  }))
  default = {}
}

variable "key_rotation_period" {
  description = "The period for mandatory key rotation (e.g., '7776000s' for 90 days)."
  type        = string
  default     = "7776000s"
}

variable "deletion_protection" {
  description = "If set to true, prevents the accidental destruction of KMS keys via Terraform. Recommended for production."
  type        = bool
  default     = true
}

# Create a KeyRing to hold all the validator keys for the environment.
# This acts as a logical grouping for all Canton-related keys.
resource "google_kms_key_ring" "canton_keyring" {
  project  = var.project_id
  name     = var.keyring_name
  location = var.location
}

# Create a unique cryptographic key for each validator.
# This ensures that each validator's private key material is encrypted with a
# distinct key, providing strong tenant isolation.
resource "google_kms_crypto_key" "validator_key" {
  for_each = var.validators

  name     = "validator-key-${each.key}" # 'each.key' is the validator ID from the input map
  key_ring = google_kms_key_ring.canton_keyring.id

  # Automatically rotate the key according to the specified period.
  rotation_period = var.key_rotation_period

  # When a key is destroyed, it enters a "scheduled for destruction" state for this duration.
  # This provides a window to recover from accidental deletion.
  destroy_scheduled_duration = "86400s" # 24 hours

  # Keys are used for symmetric encryption/decryption, as required by Canton for
  # wrapping its own keys.
  purpose = "ENCRYPT_DECRYPT"

  version_template {
    # GOOGLE_SYMMETRIC_ENCRYPTION is the standard algorithm for this purpose.
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"

    # Use a Hardware Security Module for the highest level of security.
    # This ensures key material never leaves the HSM boundary.
    protection_level = "HSM"
  }

  lifecycle {
    prevent_destroy = var.deletion_protection
  }
}

# Grant the specific validator's service account permission to *use* its dedicated key.
# This is the critical IAM binding that enforces segregation. The service account
# associated with a validator can only access its own key and no others.
resource "google_kms_crypto_key_iam_member" "validator_key_user_binding" {
  for_each = var.validators

  crypto_key_id = google_kms_crypto_key.validator_key[each.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${each.value.service_account_email}"
}

output "key_ring_id" {
  description = "The full resource ID of the KMS KeyRing."
  value       = google_kms_key_ring.canton_keyring.id
}

output "validator_key_ids" {
  description = "A map of validator IDs to their full KMS CryptoKey resource IDs. This is used to configure the Canton validator nodes."
  value = {
    for k, v in google_kms_crypto_key.validator_key : k => v.id
  }
  sensitive = true
}