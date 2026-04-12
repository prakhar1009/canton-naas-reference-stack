# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Terraform modules for Azure deployment (AKS and Azure Key Vault).
- Helm chart for a multi-tenant operator dashboard for managing participants and resource allocation.
- Detailed monitoring and alerting configurations using Prometheus and Grafana.
- Support for Canton Enterprise features, including high-availability participant setups.
- Automated backup and restore procedures for participant node state.

### Changed
- Refactor KMS Terraform module to be more generic across cloud providers.

## [0.1.0] - 2024-07-15

### Added
- **Initial Release** of the Canton NaaS (Network-as-a-Service) Reference Stack.
- Terraform modules for provisioning core infrastructure on AWS (EKS, VPC, KMS) and GCP (GKE, VPC, Cloud KMS).
- Helm chart (`canton-validator`) for deploying and configuring Canton validator/participant nodes on Kubernetes.
- Secure, per-tenant key segregation using cloud-native KMS (`terraform/modules/kms/main.tf`).
- Automated, zero-downtime upgrade process for Canton nodes using a Kubernetes Job (`helm/canton-validator/templates/upgrade-job.yaml`).
- CI pipeline using GitHub Actions to validate Terraform and Helm chart configurations (`.github/workflows/ci.yml`).
- Initial bootstrap script (`scripts/bootstrap-naas.sh`) for simplifying the initial setup for a NaaS operator.
- Comprehensive deployment guide (`docs/DEPLOYMENT_GUIDE.md`) covering prerequisites, cloud setup, and Canton deployment.