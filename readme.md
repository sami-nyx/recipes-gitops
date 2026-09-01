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
├── .github/workflows/        # pr-validation.yaml - lint/schema checks only, never deploys (see Core technologies)
├── apps/                     # Local Helm charts owned by this repo
│   ├── recipes-api/          # The Flask backend — Deployment, Service, Ingress, ConfigMap, DB-init Job, HPA
│   └── grafana/               # Wraps the upstream grafana chart + our own dashboards/*.json
├── argocd/applications/      # One file = one Argo CD Application (see table below)
│   ├── observability/        # Prometheus, Grafana, Loki, Fluent Bit, Alerting
│   ├── platform/             # Cert-manager, cert-issuer, NGINX Ingress, CloudNativePG, storage
│   ├── security/             # RBAC, NetworkPolicies, External Secrets
│   └── workloads/            # Postgres cluster, recipes-api
├── bootstrap/                # One-time cluster bootstrap (script + root Application)
├── platform/                 # Raw manifests referenced by argocd/applications/{observability,platform,security,workloads}
│   └── alerts/                # PrometheusRule - see "Alerting" below
└── readme.md
```

## Applications reference

| Application | Source | Deploys into |
|---|---|---|
| `recipes-api` | this repo · `apps/recipes-api` | `recipes` |
| `recipes-postgres` | this repo · `platform/postgres` | `recipes` |
| `network-policies` | this repo · `platform/network-policies` | `recipes` (default-deny `NetworkPolicy`s - see below) |
| `grafana` | this repo · `apps/grafana` | `monitoring` |
| `prometheus`, `loki`, `fluent-bit` | remote charts | `monitoring` / `logging` |
| `cert-manager`, `nginx-ingress`, `cloud-native-pg` | remote charts | `platform` add-ons |
| `cert-issuer` | this repo · `platform/cert-manager` | cluster-wide `ClusterIssuer` |
| `storage` | this repo · `platform/storage` | cluster-wide `StorageClass` |
| `rbac` | this repo · `platform/rbac` | cluster-wide `ClusterRole` (leftover from the GoDaddy webhook cert-manager replaced - grants access to an API group that no longer exists; harmless, but pending removal) |
| `secrets` | this repo · `platform/external-secrets` | `recipes` + `monitoring` (`ExternalSecret`s - the recipes-api DB/JWT secrets and Alertmanager's Slack webhook) |
| `alerts` | this repo · `platform/alerts` | cluster-wide `PrometheusRule` (see "Alerting" below) |

**`network-policies`**: three manifests, all scoped to the `recipes` namespace and targeting real, live-tested traffic paths rather than a blanket deny-all:

- `postgres-ingress.yaml` — only `recipes-api` and the one-shot `recipes-api-db-init` Job can open a Postgres connection (port 5432); the CNPG operator (`cnpg-system` namespace) gets 5432 *and* 8000 (its instance-manager status API - miss this one and the operator can still read/write the database but every status poll fails, showing the Application as `Unknown` instead of `Healthy` in Argo CD even though nothing is actually wrong).
- `recipes-api-ingress.yaml` — only `nginx-ingress` and Prometheus (by pod label, scraping the pod IP directly - `ServiceMonitor` bypasses the Service) can reach `recipes-api`.
- `recipes-api-egress.yaml` — `recipes-api` can reach Postgres and DNS, nothing else.

Requires the VPC CNI's `enableNetworkPolicy` addon config to be `true` (set in `recipes-aws-infra`'s Terraform) - without it these manifests apply cleanly but are never actually enforced.

## Grafana dashboards

Three dashboards, one per failure domain - not one dashboard covering everything (unfocused, hard to triage from) and not five thinly-spread ones (more than one person can realistically maintain). Each is meant to answer a different "what do I open first" question.

**`recipes-api`** (`apps/grafana/dashboards/recipes-api-dashboard.json`) - is the app okay. RED metrics (`prometheus_flask_exporter`) plus what's specific to this deployment:

- Request rate by method/path, and request count by HTTP status.
- **Error rate** - the 5xx ratio as its own panel, not just inferred from the status breakdown (a raw count doesn't distinguish "2 errors out of 2 requests" from "2 errors out of 2,000" at a glance). *Not yet added - next up.*
- Average + p95 latency.
- **Active pod count** - HPA current replicas against its configured min/max, placed next to the CPU/memory panels that explain *why* a scaling event happened, instead of needing `kubectl get hpa` to see the same thing. Implemented.
- Pod CPU / memory.
- Logs, filterable by Method/Status. These are parsed out of gunicorn's access-log line at *query time* via a LogQL `regexp` stage, not extracted as real Loki labels - that keeps the two new filter dimensions (5 methods × ~10 status codes) out of the index entirely. The trade-off: the two dashboard variables are a fixed hand-written list instead of a dynamic `label_values()` dropdown - worth it here, since Loki's index cardinality is a real storage cost and this app's method/status set is small and stable enough not to need discovering dynamically.

**`postgres`** (planned - the biggest current gap): zero visibility today. The CNPG pod exposes a metrics port (`9187`) but nothing scrapes it yet - a `PodMonitor` has to exist before any of this is possible.

- Active/idle connections vs `max_connections`.
- Transaction/query rate.
- Cache hit ratio.
- Disk usage.
- Replication lag (moot at the current single instance, becomes real the moment HA is turned on).

**`platform`** (planned): everything that isn't the app or the database, but fails silently rather than loudly.

- cert-manager certificate expiry (`certmanager_certificate_expiration_timestamp_seconds`) - directly relevant: this is exactly the class of failure the Route53 migration's placeholder-ARN gap was, and an expiry alert would have caught it long before a real renewal attempt did.
- Node CPU/mem/disk headroom - the node group is a fixed 2 nodes with no cluster autoscaler, so headroom is finite and worth watching directly, not assumed.
- Cluster-wide pod restart count, via kube-state-metrics.

Deliberately not a fourth "business metrics" dashboard (recipe-creation rate, active users, ...) - `POST /recipes/create` rate on the app dashboard already gives a crude proxy, and three focused ops dashboards make a stronger case than four where one is decorative.

## Autoscaling

`recipes-api`'s Deployment deliberately has no `replicas` field - a `HorizontalPodAutoscaler` owns it (`minReplicas: 2`, `maxReplicas: 4`, targeting 70% CPU/memory utilization, backed by `metrics-server`). `minReplicas` is 2, not 1: the whole point is removing the single-point-of-failure a fixed `replicas: 1` was, so idling back down to 1 at low load would quietly undo that. Leaving `replicas` in the template at all would make Argo CD's `selfHeal` fight the HPA - every scale-up would get reset back down on the next sync, since Argo CD would see it as drift from the git-defined value.

## Alerting

`platform/alerts/recipes-alerts.yaml` (one `PrometheusRule`, synced by the `alerts` Application) - routed through Alertmanager to Slack via `platform/external-secrets/alertmanager-slack-webhook.yaml` (a separate AWS secret from CI's `SLACK_WEBHOOK_URL`, even though the value may be the same one - see `recipes-aws-infra`'s cluster-roles module for why). Four rules, deliberately not pod-level CPU/memory:

- `NodeCPUHigh` / `NodeMemoryHigh` - node-level, not pod-level. `recipes-api`'s own HPA already targets 70% CPU/memory and scales out before a pod-level 80% would ever sustain - alerting on that too would just re-announce something already being handled automatically. Node headroom has no automatic mitigation at all (fixed 2-node group, no cluster autoscaler), which is what makes it actually actionable.
- `RecipesApiHPAAtMax` - fires when the HPA has been pinned at `maxReplicas` for 10m+: autoscaling has run out of room to help, a human needs to raise the ceiling or investigate.
- `RecipesApiErrorRateWarning` / `RecipesApiErrorRateCritical` - two-tier (2% / 10%) 5xx ratio, `for: 5m`. The load generator's deliberate error-path traffic is all 4xx (401/403/404/409/429), not 5xx, so baseline should sit near 0% - a two-tier threshold catches a real regression early without paging on noise.

## Adding a new component

- **It's a third-party thing with its own Helm chart** (an operator, an ingress controller, …) → add an Application under `argocd/applications/platform/` (or wherever fits) with `source.repoURL`/`chart`/`targetRevision` pointing at the upstream chart, values inlined under `source.helm.values`.
- **It's ours** (a service we wrote, or an upstream chart we need to customize/extend) → give it a real local Helm chart under `apps/<name>/` (`Chart.yaml` + `values.yaml` + `templates/`) and point an Application's `source.path` at it. `apps/grafana` is the reference example: it depends on the upstream `grafana` chart and adds a small template that turns any file under `dashboards/*.json` into a provisioned dashboard — no chart forking needed.

## Core technologies

- **Infra:** AWS EKS via Terraform, using EKS Access Entries (`API` auth mode) for RBAC.
- **CI:** GitHub Actions, but only `pr-validation.yaml` - yamllint, `helm lint`/`template`, `kubeconform` against real CRD schemas, and `promtool check rules`. No AWS/cluster credentials anywhere in it: this repo never deploys itself, so it has nothing to authenticate to. (OIDC federation for actual AWS deploys belongs to `recipes-aws-infra` and `recipes`, not here.)
- **Delivery:** Argo CD, App of Apps pattern - the only thing that ever deploys this repo, triggered by a merge to `main` itself.
- **Secrets:** External Secrets Operator, bridging AWS Secrets Manager into native Kubernetes Secrets.
- **Observability:** Prometheus + Grafana + Loki + Fluent Bit.
- **Data:** CloudNativePG-managed PostgreSQL.
- **Ingress:** NGINX Ingress + cert-manager (Let's Encrypt via Route53 DNS-01, IRSA-authenticated - see recipes-aws-infra's readme.md for the migration off GoDaddy).
- **Network policy:** default-deny `NetworkPolicy`s scoping `recipes` namespace traffic to real, named paths (app ↔ Postgres, ingress/Prometheus ↔ app) - see the `network-policies` entry below.
- **Autoscaling:** HPA on `recipes-api` (CPU/memory, `metrics-server`) - see "Autoscaling" below.
- **Alerting:** Prometheus `PrometheusRule` → Alertmanager → Slack - see "Alerting" below.
