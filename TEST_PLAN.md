# Full Test Plan

What's already tested and how, across all three repos (`recipes`,
`recipes-aws-infra`, `recipes-cluster-resources`), and concrete steps for
everything that's currently only verified manually. Organized by what's
automated today, then the manual/E2E gaps, in the order they're worth
closing.

## 1. Automated - already running in CI today

### 1.1 `recipes` (the application)

Four independent, path-gated tiers, all wired into `pr-to-develop-ci.yaml`
and `push-to-develop-ci.yaml` - see that repo's README for the full
architecture diagrams.

- **Static analysis** (Super-Linter, scoped to changed files only): Python
  (Flake8), Dockerfiles (Hadolint), YAML (yamllint), GitHub Actions
  (actionlint), Bash (ShellCheck).
- **Unit tests**, path-gated:
  - Backend (`recipes-backend/recipes-api/**`): registration, authentication,
    invalid credentials, recipe CRUD, protected routes, input validation.
  - Frontend (`recipes-ui/**`, Vitest): component rendering, reactive form
    validation, signed-in vs. guest UI state.
- **Component tests** (every PR, backend + Postgres only, no nginx/UI
  build): the same `test/component/` suite the integration tier reuses,
  talking to `recipes-api` directly.
- **Integration tests** (once per merge to `develop`, real topology via
  Docker Compose: nginx + built Angular app + Flask + Postgres): the same
  suite again, this time routed through nginx, so proxying/routing is
  actually exercised, not assumed.

### 1.2 `recipes-aws-infra`

- `eks-platform.yaml` / `oidc-roles.yaml`: `terraform fmt -check`,
  `init -backend=false`, `validate` on every PR touching that stack's own
  directory. No AWS credentials involved - this only catches syntax/type
  errors and formatting, not whether a real `apply` would succeed or what
  it would actually change.

### 1.3 `recipes-cluster-resources`

- `pr-validation.yaml`: yamllint (raw manifests), `helm lint` +
  `helm template` for both local charts (with `kubeconform` against the
  rendered output), `kubeconform` against every raw manifest using real
  CRD schemas (Argo CD `Application`, `PrometheusRule`, `ExternalSecret`,
  `NetworkPolicy`, CNPG `Cluster`, ...), and `promtool check rules` against
  the alert rules. Zero cluster/AWS credentials - pure static validation,
  since Argo CD (already running in-cluster) is the only thing that
  actually deploys this repo.

**What none of the above proves**: that `terraform apply` actually
succeeds against real AWS, that Argo CD actually reconciles cleanly, that
a certificate actually issues, that an alert actually reaches Slack, that
the HPA actually scales under load. All of CI here is static analysis -
real, valuable, but it stops at "this is syntactically and structurally
correct," not "this works end-to-end." Sections 2-3 are the plan for that
half.

## 2. Manual / not yet automated - concrete steps

Each of these was verified by hand at least once this session (noted
where). None are automated in CI - each needs a live cluster, which is
exactly why they aren't: this project's own cost model is destroy the
cluster when not in use, so CI can't assume one exists.

### 2.1 Full bootstrap-from-zero

The strongest single test available: prove the whole stack comes up clean
from nothing, not just that individual pieces work in isolation.

1. `terraform destroy` (or `destroy-cluster.yaml`) against a real running
   cluster, confirm it completes without orphaned ELBs/security groups
   blocking subnet deletion.
2. `tf-apply-eks.yaml` from scratch.
3. Confirm `sync-cert-issuer-config` actually committed real values to
   `recipes-gitops` (check the commit landed, not just that the job
   succeeded).
4. Confirm `bootstrap-cluster` finished and `kubectl get application -n
   argocd` shows all Applications eventually `Synced`/`Healthy` - some
   will race through `Unknown`/`Progressing` first, that's expected (see
   the CNPG port-8000 class of issue found this session); only a
   *sustained* non-Healthy state after several minutes is a real problem.

### 2.2 TLS / certificate issuance, end-to-end

Not yet actually exercised - the Route53 solver has never issued a real
certificate through it (the current cert was still valid from before the
migration, so nothing has forced a real renewal attempt yet).

1. After a bootstrap with the sync job's real values in place, confirm
   `kubectl describe clusterissuer letsencrypt-prod` shows
   `Ready: True` for the right reason (ACME account registered *and* no
   solver errors - the account-registered condition alone was previously
   confirmed misleading, since it doesn't validate the solver config).
2. Force a real renewal test rather than waiting ~2 months for the natural
   one: delete the `recipes-api-tls` Secret and watch cert-manager
   re-issue it from scratch (`kubectl get certificate recipes-api-tls -n
   recipes -w`), or drop `certificate.spec.duration` temporarily on a
   throwaway `Certificate` to force a near-term renewal without touching
   the real one.
3. Confirm the DNS-01 challenge record actually appears and clears in
   Route53 (`aws route53 list-resource-record-sets` during the challenge
   window) - proves the IRSA role's permissions are actually sufficient,
   not just present.

### 2.3 HPA scaling under real load

Partially verified this session (confirmed 1→2 replica scale-up against
real CPU metrics) - not yet verified at the `maxReplicas` ceiling, or that
`RecipesApiHPAAtMax` actually fires.

1. Port-forward `recipes-api`, run the load generator with high
   concurrency (`CONCURRENT_USERS=20+`) for 10+ minutes.
2. Watch `kubectl get hpa recipes-api -n recipes -w` - confirm it climbs
   to `maxReplicas` (4) and holds, not just scales once.
3. Confirm `RecipesApiHPAAtMax` actually fires and reaches Slack after
   the full 10m `for:` window - this alert has never actually fired for
   real, only the synthetic `SyntheticTestAlert` proved the Slack pipeline
   itself works.

### 2.4 Error-rate and node alerts firing for real

Only the Slack *pipeline* has been proven (via the synthetic test alert).
None of the 5 real rules have fired from an actual triggering condition.

1. `RecipesApiErrorRateWarning`/`Critical`: the load generator's own
   `act_create_recipe_bad_payload`/`act_create_recipe_unauthenticated`
   actions produce 400/401, not 5xx - deliberately, since those are the
   realistic error paths. To actually trigger the *error-rate* alerts,
   something has to produce real 5xx - e.g. temporarily scale Postgres to
   0 and watch `recipes-api` fail requests, confirming both the alert
   fires **and** that it correctly stays silent for the 4xx-only traffic
   the load generator produces the rest of the time.
2. `NodeCPUHigh`/`NodeMemoryHigh`: genuinely hard to trigger safely on a
   real 2-node cluster without disrupting everything else running on it.
   Reasonable to defer - lower priority than the app-level alerts, and the
   PromQL expressions were already verified against live Prometheus data
   this session (correct math, just never crossed the 80% threshold for
   real).

### 2.5 Grafana dashboards showing real data

All three dashboards' individual queries were verified against live
Prometheus/Loki data this session (see the dashboard-build work) - not
yet viewed together, end-to-end, by an actual human in the Grafana UI
across a full session of real traffic.

1. Run the load generator for an extended period (30min+) with the
   cluster up.
2. Open each of the three dashboards in Grafana and confirm every panel
   renders sensibly (not just "no error" - actually look at whether the
   numbers make sense): `recipes-api` (request rate, error rate, latency,
   pod replicas, filtered logs), `postgres` (connections, cache hit
   ratio, disk), `platform` (cert expiry, node headroom, restarts).

### 2.6 NetworkPolicy enforcement

Already thoroughly live-tested this session (disposable test pods,
confirmed both allow and deny paths for every rule) - re-verify after any
future change to `platform/network-policies/*.yaml`, since this is exactly
the kind of thing that fails silently (a policy that doesn't match live
pod labels applies cleanly and blocks nothing, or blocks everything,
without any error).

### 2.7 DNS cutover verification

Not yet done - GoDaddy's nameservers haven't been flipped to Route53's
yet as of this document. `dig NS weaversls.com` should eventually return
the four Route53 nameservers, not GoDaddy's - see `recipes-aws-infra`'s
readme.md, "DNS: GoDaddy → Route53," steps 4-5.

## 3. If you want to go further than this

Two genuine next steps, both bigger lifts than anything above - noted,
not started:

- **A real `terraform plan` in CI**, not just `validate` - would need real
  (read-only) AWS credentials in the PR workflow, a bigger trust boundary
  than this repo's CI currently has (zero AWS access today, deliberately).
  Worth it once the account has more than one contributor; for a
  single-maintainer project the manual `terraform plan` before every
  `apply` already covers this.
- **An ephemeral `kind`/`k3d` cluster in `recipes-cluster-resources`'s
  CI**, actually installing Argo CD and letting it sync every Application
  for real, instead of just schema-validating the manifests. Would catch
  real reconciliation failures (chart incompatibilities, real CRD
  ordering issues) before merge instead of after. Meaningfully more CI
  time and complexity than the current pure-static-validation approach -
  worth it if this repo's Application count keeps growing, not clearly
  worth it at 15.
