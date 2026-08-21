```markdown
# Recipes Platform GitOps Infrastructure

A production-grade, declarative GitOps platform deployed on AWS EKS using Terraform, GitHub Actions OIDC, Argo CD (App of Apps pattern), and External Secrets.

---

## 🏗️ Project Architecture & Directory Structure

```text
.
├── apps/                        # Custom application helm charts (e.g., recipes-api)
│   └── recipes-api/             # Core backend service chart
├── argocd/                      # Argo CD application definitions (App of Apps architecture)
│   └── applications/
│       ├── observability/       # Monitoring & logging (Prometheus, Grafana, Loki, Fluent Bit)
│       ├── platform/            # Core cluster add-ons (Cert-Manager, NGINX Ingress, CloudNativePG, Storage)
│       ├── security/            # RBAC and Secrets management
│       └── workloads/           # Application layers (Postgres database, Recipes API)
├── bootstrap/                   # Cluster bootstrapping automation and initial manifests
│   ├── bootstrap.sh             # End-to-end bootstrap orchestration script
│   ├── manifests/               # Core cluster secrets and SecretStore templates
│   ├── root-app.yaml            # Argo CD root "App of Apps" manifest
│   └── values/                  # Operator override values (External Secrets, etc.)
└── platform/                    # Platform configurations managed by Argo CD
    ├── cert-manager/            # Cluster Issuers and certificate definitions
    ├── external-secrets/        # ExternalSecret definitions synced from AWS/GoDaddy
    ├── postgres/                # CloudNativePG database cluster declarations
    ├── rbac/                    # Cluster Roles and access control
    └── storage/                 # Storage classes (e.g., GP3 EBS provisioner)

```

---

## 🚀 Core Components & Technologies

* **Infrastructure Provisioning:** AWS EKS managed via custom Terraform modules with modern **AWS EKS Access Entries** (`API` authentication mode) for secure RBAC.
* **CI/CD Pipeline:** GitHub Actions with secure **OIDC (OpenID Connect)** federation—eliminating hardcoded AWS credentials.
* **GitOps Continuous Delivery:** **Argo CD** deployed using the scalable **App of Apps** pattern to maintain declarative desired states.
* **Secrets Management:** **External Secrets Operator** securely bridging AWS Secrets Manager/Parameter Store and GoDaddy APIs directly into native Kubernetes secrets.
* **Observability & Storage:** Fully integrated Prometheus, Grafana, Loki, Fluent Bit logging pipeline, CloudNativePG operator for resilient PostgreSQL workloads, and NGINX Ingress controller routing.

---

## 🛠️ Bootstrapping & Deployment Flow

1. **Infrastructure Provisioning:** Terraform sets up the AWS VPC, EKS cluster, IAM OIDC provider, and access entries.
2. **Platform Bootstrap:** The GitHub Actions bootstrap job configures `kubectl` and `helm`, installs the External Secrets Operator, injects root GitHub credentials, and deploys the Argo CD root application (`recipes-root`).
3. **GitOps Reconciliation:** Argo CD cascades through ordered sync waves to provision storage classes, operators, monitoring suites, and application microservices safely and sequentially.

```

```