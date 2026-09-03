# GoDaddy → Route53 migration

How this project's ACME DNS-01 challenges moved off a third-party GoDaddy
webhook onto cert-manager's native Route53 support - what it replaced, why,
and what changed across both `recipes-aws-infra` and this repo. Written
after the fact, from the actual commits, not from memory.

## Why this happened

Two reasons, not one:

1. **The domain's actual DNS needed to move to Route53 anyway.** Certificate
   issuance for `weaversls.com` requires DNS-01 challenges to succeed against
   whatever nameservers are authoritative for the domain - and this project's
   own scope (an AWS EKS platform) called for that authority to live in
   Route53, not stay on GoDaddy's own DNS panel.
2. **Once DNS lived in Route53, the GoDaddy webhook had nothing left to
   justify its cost.** It wasn't broken or malfunctioning - it worked. It was
   replaced because, the moment Route53 was the authoritative DNS provider,
   continuing to solve ACME challenges through a third-party GoDaddy webhook
   would have meant keeping an entire extra dependency (a webhook chart, a
   long-lived API key, custom RBAC) alive to solve a problem cert-manager
   already solves natively for the DNS provider actually in use.

## What the GoDaddy webhook approach actually was

- **`cert-manager-webhook-godaddy`** (`fred78290.github.io/cert-manager-webhook-godaddy`,
  chart `godaddy-webhook`) - a third-party Argo CD Application
  (`cert-manager-godaddy-webhook`), installed alongside cert-manager itself,
  registering a custom API group (`acme.weaversls.com`) that cert-manager's
  `ClusterIssuer` had to reference by name (`solvers[].dns01.webhook.groupName`)
  to route challenges through it.
- **A long-lived GoDaddy API key**, stored in AWS Secrets Manager
  (`godaddy-api-credentials`, with `api-key`/`api-secret` properties), pulled
  into the cluster via an `ExternalSecret`
  (`godaddy-api-external-secret.yaml`) into a plain Kubernetes Secret
  (`godaddy-api-key-secret`) that the webhook's solver config referenced
  directly by name.
- **A dedicated `ClusterRole`/`ClusterRoleBinding`**
  (`platform/rbac/cluster-role.yaml`) granting the webhook's own
  ServiceAccount access to its self-registered `acme.weaversls.com` API
  group - RBAC that only existed because the webhook's own custom resource
  type needed it.

Three moving parts (a third-party chart, a long-lived credential, a custom
RBAC grant) to solve one problem: proving control of a DNS zone to Let's
Encrypt.

## What replaced it

cert-manager has **built-in** Route53 DNS-01 support - no third-party
webhook chart at all. Authentication is IRSA (the same
ServiceAccount-annotation pattern already used everywhere else in this
project for AWS access - Loki's S3 role, External Secrets' Secrets Manager
role, and now this one), not a stored API key. One moving part instead of
three: an IAM role, scoped to exactly one hosted zone.

## What changed, concretely

**`recipes-aws-infra`** (commit `f3573a5`):

- New `route53_zone_id` Terraform variable, threaded through the same
  `envsubst`/`terraform.tfvars.template` mechanism every other CI-supplied
  value already uses.
- New IAM policy + IRSA role (`cert_manager_route53_irsa_role`), scoped to
  only `route53:ChangeResourceRecordSets`/`ListResourceRecordSets` on that
  one zone (plus the two Route53 actions - `GetChange`,
  `ListHostedZonesByName` - that don't support resource-level scoping at
  all, so they stay account-wide). Trust policy targets
  `system:serviceaccount:cert-manager:cert-manager`, confirmed against the
  live cluster's actual ServiceAccount name, not assumed.
- The now-dead `godaddy-api-credentials` ARN removed from the External
  Secrets IAM policy - nothing reads that secret once the webhook's gone.
- The hosted zone itself deliberately stayed **outside** Terraform's scope -
  created manually, once, matching this stack's own minimal-overlap
  principle (bootstrap + IRSA roles only, never the cluster resources
  themselves).

**`recipes-cluster-resources`** (commit `e09d22a`, plus follow-up work):

- `cluster-issuer.yaml`'s solver swapped from the webhook's
  `dns01.webhook` block to a plain `dns01.route53` block - no role ARN
  needed in the solver itself, since auth comes from the ServiceAccount's
  own IRSA annotation.
- `cert-manager.yaml` gained a `serviceAccount.annotations` block carrying
  that IRSA role ARN.
- `go-daddy-webhook.yaml` (the Application) and
  `go-daddy-external-api-secret.yaml` (the `ExternalSecret`) deleted
  outright - both entirely superseded.
- `platform/rbac/cluster-role.yaml` and its `rbac.yaml` Application -
  the webhook's now-pointless RBAC grant - initially left in place
  (flagged as dead code, blocked from removal at the time), removed
  cleanly in a later pass once nothing stood in the way.
- Later still: `cert-issuer` was restructured from a raw manifest into a
  real local Helm chart (`apps/cert-issuer`, matching the pattern
  `apps/grafana` already established), so the zone ID, ACME email, and
  AWS region became real chart values instead of literals baked into a
  template.
- Most recently: the zone ID, email, region, and the IRSA role ARN are no
  longer manually-filled placeholders at all - `recipes-aws-infra`'s
  `tf-apply-eks.yaml` (`sync-cert-issuer-config` job) writes all four
  straight into this repo, from that repo's own variables and its
  Terraform output, on every `apply`. Neither the zone ID nor the role ARN
  is sensitive data - both are resource identifiers, not credentials - so
  committing the real values directly, and letting Argo CD sync normally,
  beat every alternative that tried to keep them out of git.

**The registrar itself**: not a domain transfer. `weaversls.com` stayed
registered at GoDaddy throughout - only *which nameservers answer DNS
queries for it* changed, from GoDaddy's own to Route53's four assigned ones.
The manual, step-by-step cutover checklist (creating the zone, recreating
every other GoDaddy DNS record before flipping over, verifying propagation
via `dig NS`) lives in `recipes-aws-infra`'s readme.md, under "DNS: GoDaddy
→ Route53" - this document is the narrative of what changed and why, that
one is the operational checklist for actually doing it.

## Net effect

| | Before (GoDaddy webhook) | After (native Route53) |
|---|---|---|
| Moving parts | Third-party chart + API key Secret + custom RBAC | One IRSA role |
| Credential | Long-lived GoDaddy API key, manually rotated | None - IRSA, short-lived STS tokens |
| Blast radius if compromised | Whatever the GoDaddy API key itself allows | Exactly one Route53 hosted zone's record sets |
| Config source of truth | Partly a Kubernetes Secret, partly manifests | Fully in git (see the sync automation above) |
