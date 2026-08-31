# Recipes Platform — GitOps Infrastructure

Declarative GitOps for the Recipes platform on AWS EKS: Terraform provisions the cluster once, then Argo CD (App of Apps) owns everything that runs on it, sourced entirely from this repo.

## How it flows

1. **Terraform** provisions the VPC, EKS cluster, IAM OIDC provider, and access entries.
2. **`bootstrap/bootstrap.sh`** runs once against the new cluster: installs the External Secrets Operator, injects the GitHub credentials Argo CD needs to read this repo, then applies `bootstrap/root-app.yaml`. Normally run by `recipes-aws-infra`'s `tf-apply-eks.yaml` workflow, using its `terraform apply` outputs - `bootstrap/bootstrap_local.sh <path-to-local-recipes-aws-infra-clone>` does the same thing locally, reading those outputs straight from `terraform output` instead, for when you'd rather not spend GitHub Actions minutes on it.
3. **`recipes-root`** (the root Argo CD Application from step 2) recursively watches `argocd/applications/`. Every `.yaml` file in there is one Argo CD `Application` — add a file, get a new Application, no manual `argocd app create`.
4. Each Application's `source` points either at a **remote Helm chart** (`repoURL` + `chart` + `targetRevision`) or at a **path in this repo** (`repoURL` = this repo + `path`). The table below shows which.

## Repo layout

```text
.
├── apps/                     # Local Helm charts owned by this repo
│   ├── recipes-api/          # The Flask backend — Deployment, Service, Ingress, ConfigMap, DB-init Job
│   └── grafana/               # Wraps the upstream grafana chart + our own dashboards/*.json
├── argocd/applications/      # One file = one Argo CD Application (see table below)
│   ├── observability/        # Prometheus, Grafana, Loki, Fluent Bit
│   ├── platform/             # Cert-manager, NGINX Ingress, CloudNativePG, storage
│   ├── security/             # RBAC, External Secrets
│   └── workloads/            # Postgres cluster, recipes-api
├── bootstrap/                # One-time cluster bootstrap (script + root Application)
├── platform/                 # Raw manifests referenced by argocd/applications/{platform,security,workloads}
└── readme.md
```

## Applications reference

| Application | Source | Deploys into |
|---|---|---|
| `recipes-api` | this repo · `apps/recipes-api` | `recipes` |
| `recipes-postgres` | this repo · `platform/postgres` | `recipes` |
| `grafana` | this repo · `apps/grafana` | `monitoring` |
| `prometheus`, `loki`, `fluent-bit` | remote charts | `monitoring` / `logging` |
| `cert-manager`, `nginx-ingress`, `cloud-native-pg`, `go-daddy-webhook` | remote charts | `platform` add-ons |
| `cert-issuer` | this repo · `platform/cert-manager` | cluster-wide `ClusterIssuer` |
| `storage` | this repo · `platform/storage` | cluster-wide `StorageClass` |
| `rbac` | this repo · `platform/rbac` | cluster-wide `ClusterRole` |
| `secrets` | this repo · `platform/external-secrets` | `recipes` (`ExternalSecret`s) |

## Adding a new component

- **It's a third-party thing with its own Helm chart** (an operator, an ingress controller, …) → add an Application under `argocd/applications/platform/` (or wherever fits) with `source.repoURL`/`chart`/`targetRevision` pointing at the upstream chart, values inlined under `source.helm.values`.
- **It's ours** (a service we wrote, or an upstream chart we need to customize/extend) → give it a real local Helm chart under `apps/<name>/` (`Chart.yaml` + `values.yaml` + `templates/`) and point an Application's `source.path` at it. `apps/grafana` is the reference example: it depends on the upstream `grafana` chart and adds a small template that turns any file under `dashboards/*.json` into a provisioned dashboard — no chart forking needed.

## Core technologies

- **Infra:** AWS EKS via Terraform, using EKS Access Entries (`API` auth mode) for RBAC.
- **CI/CD:** GitHub Actions with OIDC federation — no long-lived AWS credentials.
- **Delivery:** Argo CD, App of Apps pattern.
- **Secrets:** External Secrets Operator, bridging AWS Secrets Manager into native Kubernetes Secrets.
- **Observability:** Prometheus + Grafana + Loki + Fluent Bit.
- **Data:** CloudNativePG-managed PostgreSQL.
- **Ingress:** NGINX Ingress + cert-manager (Let's Encrypt via Route53 DNS-01, IRSA-authenticated - see recipes-aws-infra's readme.md for the migration off GoDaddy).
