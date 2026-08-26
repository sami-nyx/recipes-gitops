# Bugs and Fixes

## recipes-api: ConfigMap never created — stuck PreSync hook ordering

**Symptom:** The `recipes-api` Argo CD Application stayed `OutOfSync` for hours.
The `recipes-api-db-init` pod was crash-looping with:

```
Error: configmap "recipes-api-config" not found
```

confirmed on-cluster via:

```
kubectl get configmap recipes-api-config -n recipes
kubectl describe pod -n recipes -l app=recipes-api-db-init
```

**Root cause:** `templates/db-init-job.yaml` is annotated
`helm.sh/hook: pre-install,pre-upgrade`, so Argo CD creates and runs it in the
**PreSync** phase. `templates/configmap.yaml` had no hook annotation, so it
was only applied later, in the normal **Sync** phase. The Job's pod
`envFrom`s that ConfigMap, so it was scheduled before the ConfigMap existed —
a chicken-and-egg deadlock. `helm lint` / `helm template` never caught this
because the templates render correctly on their own; the bug only exists in
Argo CD's phase ordering across resources.

**Fix:** Made the ConfigMap a `pre-install,pre-upgrade` hook itself, with
`helm.sh/hook-weight: "-5"` (lower than the Job's default weight `0`, made
explicit on the Job for clarity) and `helm.sh/hook-delete-policy:
before-hook-creation`, so it's created before the Job within the same
PreSync phase.

Files: `apps/recipes-api/templates/configmap.yaml`,
`apps/recipes-api/templates/db-init-job.yaml`

---

## recipes-api: Secret hook fix caused a stuck sync (shared-resource collision)

**Symptom:** After applying the same hook treatment to `templates/secret.yaml`
(reasoning it needed the same PreSync ordering as the ConfigMap), the Argo CD
sync operation got stuck `Running` indefinitely:

```
operationState.phase: Running
operationState.message: waiting for deletion of hook /Secret/recipes-api-secret
```

with an Application condition:

```
SharedResourceWarning: Secret/recipes-api-secret is part of applications
  argocd/recipes-api and cluster-secrets
```

**Root cause:** `Secret/recipes-api-secret` was never actually populated by
the chart's own `secret.yaml` (it was an empty, dataless `Opaque` Secret).
The real object is owned by an `ExternalSecret`
(`platform/external-secrets/recipes-external-secret.yaml`, pulling
`JWT_SECRET_KEY`/`SECRET_KEY` from AWS Secrets Manager), which belongs to a
*separate* Argo CD Application, `cluster-secrets` — confirmed via:

```
kubectl get secret recipes-api-secret -n recipes -o json
# ownerReferences -> ExternalSecret/recipes-api-external-secret
```

Turning the chart's placeholder Secret into a `before-hook-creation` hook
made Argo CD try to delete the live Secret before recreating its own — but
that Secret is owned by the External Secrets Operator, which just recreates
it, so the "wait for hook deletion" step never completed. The `cluster-secrets`
Application already syncs at `sync-wave: 0`, well before `recipes-api` at
`sync-wave: 10`, so the real Secret is always present in time regardless —
the chart never needed to manage it at all.

**Fix:** Reverted the hook annotations, then removed
`apps/recipes-api/templates/secret.yaml` entirely — it was redundant.
`deployment.yaml` and `db-init-job.yaml` only reference the Secret by name
(`secretRef: name: recipes-api-secret`), so they're unaffected; the
`ExternalSecret`-owned object continues to satisfy that reference.

Files: `apps/recipes-api/templates/secret.yaml` (deleted)

---

## Unrelated: local/remote `main` diverged on push

**Symptom:** `git push` rejected as non-fast-forward.

**Root cause:** Local `main` had the ConfigMap-hook fix commit
(`ADD: webhook`) on top of `7305bde`, while `origin/main` had two CI-bot
commits (`chore: deploy recipes-api v1.0.29` / `v1.0.30`, bumping
`values.yaml`) on top of the same base — a normal divergence, not a real
conflict, since the two histories touched disjoint files.

**Fix:** `git fetch origin && git rebase origin/main && git push origin main`
(rebase was conflict-free since the CI commits only touched `values.yaml`).
