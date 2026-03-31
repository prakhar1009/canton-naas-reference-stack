# Canton NaaS Reference Stack

This repository provides a fully automated, open-source reference stack for deploying a Canton Network as a Service (NaaS) provider. It leverages Terraform and Helm charts for rapid deployment on AWS, GCP, and Azure, offering KMS-based key segregation, auto-scaling, upgrade automation, monitoring hooks, and a multi-tenant dashboard.

## Overview

The Canton NaaS Reference Stack is designed to significantly reduce the time and effort required to launch a Canton NaaS business.  It addresses key operational concerns such as security, scalability, and multi-tenancy out-of-the-box, allowing teams to focus on building their core business logic and attracting network participants.

Key features:

*   **Automated Deployment:** Terraform and Helm charts enable one-click deployments across AWS, GCP, and Azure.
*   **KMS-Based Key Segregation:** Utilizes Key Management Services (KMS) for robust key management and segregation between tenants.
*   **Auto-Scaling:** Automatically scales resources based on demand, ensuring optimal performance and cost efficiency.
*   **Upgrade Automation:** Simplifies the process of upgrading Canton nodes and other components, minimizing downtime.
*   **Monitoring Hooks:** Provides comprehensive monitoring capabilities for proactive issue detection and resolution.
*   **Multi-Tenant Dashboard:** Offers a centralized dashboard for managing multiple tenants and their resources.

## Architecture

The reference stack typically comprises the following components:

*   **Canton Nodes:** The core components of the Canton network, responsible for processing transactions and maintaining the ledger.
*   **Sequencer:** Orders transactions and ensures consensus across the network.
*   **Relays:** Facilitate communication between Canton nodes in different domains.
*   **Postgres Database:** Stores ledger data and metadata.
*   **Monitoring System (Prometheus/Grafana):** Collects and visualizes metrics for monitoring the health and performance of the network.
*   **Identity Provider (optional):** Provides authentication and authorization services for users and applications.
*   **Multi-Tenant Dashboard:**  A user interface for managing tenants, resources, and network configurations.

## Deployment Guide

The following steps outline the general process for deploying the Canton NaaS Reference Stack. Specific instructions may vary depending on the cloud provider and chosen configuration.

### Prerequisites

*   **Cloud Provider Account:** An active account with AWS, GCP, or Azure.
*   **Terraform:** Installed and configured on your local machine.
*   **Helm:** Installed and configured on your local machine.
*   **kubectl:** Installed and configured to interact with your Kubernetes cluster.
*   **Daml SDK:** Installed and configured on your local machine (required for testing and development).
*   **Basic understanding of Canton, Terraform, and Helm.**

### Deployment Steps

1.  **Clone the Repository:**

    ```bash
    git clone <repository_url>
    cd canton-naas-reference-stack
    ```

2.  **Configure Terraform:**

    *   Navigate to the `terraform` directory.
    *   Create a `terraform.tfvars` file with the necessary variables for your chosen cloud provider (e.g., region, credentials, instance sizes).  Example:

    ```terraform
    region = "us-west-2"
    aws_access_key = "YOUR_AWS_ACCESS_KEY"
    aws_secret_key = "YOUR_AWS_SECRET_KEY"
    ```

3.  **Initialize Terraform:**

    ```bash
    terraform init
    ```

4.  **Plan Terraform:**

    ```bash
    terraform plan
    ```

5.  **Apply Terraform:**

    ```bash
    terraform apply
    ```

    This will provision the necessary infrastructure resources in your cloud provider account.

6.  **Configure Helm:**

    *   Navigate to the `helm` directory.
    *   Customize the `values.yaml` file for each Helm chart to match your desired configuration. This includes settings for the Canton nodes, sequencer, database, and other components.

7.  **Deploy Helm Charts:**

    ```bash
    helm install <release_name> <chart_name>
    ```

    Repeat this command for each Helm chart in the `helm` directory.

8.  **Access the Multi-Tenant Dashboard:**

    *   Once the deployment is complete, you can access the multi-tenant dashboard through a web browser. The exact URL will depend on your configuration.

### Post-Deployment Steps

*   **Configure Security Groups/Firewall Rules:** Ensure that the necessary ports are open for communication between Canton nodes and other components.
*   **Set up Monitoring:** Configure your monitoring system to collect metrics from the Canton network.
*   **Register Tenants:** Use the multi-tenant dashboard to register new tenants and allocate resources.
*   **Deploy Daml Applications:** Deploy your Daml applications to the Canton network.

## Customization

The Canton NaaS Reference Stack is highly customizable. You can modify the Terraform and Helm charts to tailor the deployment to your specific requirements.  Consider the following customizations:

*   **Instance Sizes:** Adjust the instance sizes of the Canton nodes and other components to optimize performance and cost.
*   **Database Configuration:** Configure the database settings, such as storage size and backup policies.
*   **Monitoring Configuration:** Customize the monitoring system to collect specific metrics and set up alerts.
*   **Identity Provider Integration:** Integrate with your existing identity provider for authentication and authorization.
*   **Daml Application Deployment:** Integrate Daml application deployment as part of the automated process.

## Contributing

We welcome contributions to the Canton NaaS Reference Stack. Please refer to the `CONTRIBUTING.md` file for guidelines.

## License

This project is licensed under the Apache 2.0 License. See the `LICENSE` file for details.