# Infrastructure Plan

A working roadmap for this repo, grounded in what's actually deployed today (see `readme.md` for the current architecture). Each item states the current state, why it matters, and the concrete step to take. Grouped by lens — architecture, then security — with a suggested phasing at the end.

---

## Architecture

### 1. Postgres runs as a single instance with no backup configured
`platform/postgres/postgres-cluster.yaml` sets `instances: 1` and has no `.spec.backup` block. CloudNativePG gives HA and continuous WAL archiving for free, but only if configured — right now a node loss or a bad migration is unrecoverable beyond whatever's still on the EBS volume.
**Step:** bump to `instances: 2` (or 3) for automatic failover, and add a `backup:` section (Barman Cloud plugin to an S3 bucket) so there's a point-in-time-recovery target independent of the volume.

### 2. `apps/recipes-api/values.yaml` has a dead `postgres:` block
It defines `postgres.instances`, `postgres.storage`, `postgres.databaseName`, etc., but no template in `apps/recipes-api/templates/` reads `.Values.postgres` — the actual database is the unrelated `platform/postgres/postgres-cluster.yaml`, deployed by a separate Application (`workloads/postgres.yaml`). Anyone editing that block to "fix" the database is editing nothing.
**Step:** delete the block, or if the intent was to eventually fold Postgres into this chart, do that fold and remove `platform/postgres/` + `workloads/postgres.yaml` instead.

### 3. `bootstrap/` has three script variants
`bootstrap.sh`, `bootstrap.old.sh`, and `bootstrap copy.sh` all exist side by side. It's not obvious which one is canonical without reading all three, and only one can actually be current.
**Step:** confirm `bootstrap.sh` is the one in use (README now documents it as such), delete the other two or move them out of the repo.

### 4. No Argo CD `AppProject` scoping — every Application uses `default`
All 14 Applications under `argocd/applications/` set `project: default`, the built-in project with no restrictions on source repos, destination namespaces, or cluster-scoped resources. There's currently no blast-radius boundary between, say, `security/` and `workloads/`.
**Step:** introduce a small number of `AppProject`s (e.g. `platform`, `workloads`, `security`) each restricted via `sourceRepos`, `destinations`, and `clusterResourceWhitelist` to only what that group legitimately needs, and point each Application at its project.

### 5. No consistent resource requests/limits policy
`apps/recipes-api` sets `resources` explicitly; the remote-chart Applications (Prometheus, Loki, Grafana, cert-manager, nginx-ingress, cloudnative-pg) all inherit upstream chart defaults, unexamined. On a small cluster this is how one component starves another.
**Step:** review and set `resources` for each remote-chart Application's key workloads via `source.helm.values`, and add PodDisruptionBudgets where relevant (Postgres, Grafana).

---

## Security

### 1. `terraform.tfstate` is committed to git, and there's no `.gitignore`
The file is tracked (`git ls-files` confirms it) and currently near-empty (0 resources), so nothing sensitive is exposed *yet* — but a state file's normal contents include resource IDs and can include plaintext secrets depending on what it manages. There's also no `.gitignore` in this repo at all, so nothing stops a future `terraform apply` run from this directory populating it with real state and committing it.
**Step:** `git rm --cached terraform.tfstate`, add a `.gitignore` (at minimum `*.tfstate*`, `.terraform/`), and confirm the real Terraform state lives in a remote backend (S3 + locking), not as a file in any repo.

### 2. No Kubernetes `NetworkPolicy` anywhere in the repo
Every namespace (`recipes`, `monitoring`, `cert-manager`, `logging`, …) has fully open pod-to-pod networking by default — nothing here restricts which namespaces can reach the Postgres cluster, Grafana, or each other.
**Step:** add default-deny `NetworkPolicy` per namespace plus explicit allow rules for the traffic that's actually needed (e.g. `recipes-api` → Postgres, Prometheus → `recipes-api` metrics endpoint).

### 3. No pod or container `securityContext` set anywhere
Confirmed via search — zero hits for `securityContext` across `apps/` and `platform/`. Containers run with whatever the base image's default user is (root, for most public images), full Linux capabilities, and a writable root filesystem.
**Step:** add a baseline `securityContext` (`runAsNonRoot: true`, dropped capabilities, `readOnlyRootFilesystem` where the app allows it) to `apps/recipes-api`'s Deployment and Job at minimum, then extend to other owned workloads.

### 4. No AppProject scoping (see Architecture #4 — also a security control)
Worth calling out here too: unrestricted `project: default` isn't just an organizational gap, it's the actual RBAC boundary Argo CD offers between "what can this group of manifests touch." Right now that boundary doesn't exist.

### 5. EBS storage doesn't declare encryption
`platform/storage/gp3-sc.yaml`'s `StorageClass` has no `encrypted: "true"` parameter. Whether Postgres's volume ends up encrypted at rest depends entirely on the AWS account's default-EBS-encryption setting, which isn't visible or enforced from this repo.
**Step:** add `encrypted: "true"` (and optionally a `kmsKeyId`) to the StorageClass parameters so encryption is guaranteed regardless of account defaults.

### 6. Namespaces get created with no Pod Security admission labels
Every Application uses `syncOptions: [CreateNamespace=true]`, and none of the resulting namespaces carry `pod-security.kubernetes.io/enforce` labels — so the built-in Pod Security Admission controller isn't enforcing any baseline.
**Step:** label each namespace (`recipes`, `monitoring`, `logging`, `cert-manager`) with at least the `baseline` Pod Security Standard, `restricted` where workloads support it.

### 7. Let's Encrypt account uses a personal email
`platform/cert-manager/cluster-issuer.yaml` hardcodes a personal Gmail address as the ACME account contact. Low severity — the GitHub repo checked as private, so this isn't publicly exposed — but worth an alias/role address if that ever changes.

---

## Suggested phasing

- **Now (cheap, high value):** #1 security (tfstate + `.gitignore`), architecture #2 and #3 (delete dead config/scripts) — all pure cleanup, no risk.
- **Next:** AppProject scoping (architecture #4 / security #4), StorageClass encryption (security #5), namespace PSA labels (security #6) — config-only changes, no application code involved.
- **Then:** Postgres HA + backups (architecture #1), NetworkPolicies (security #2), container `securityContext` hardening (security #3) — each needs a bit more care/testing since they touch running workloads.
- **Ongoing:** resource requests/limits review (architecture #5) as new components get added, following the "Adding a new component" convention in `readme.md`.
