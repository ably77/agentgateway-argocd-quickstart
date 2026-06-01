# Data Plane Deployment Design

**Date:** 2026-06-01
**Status:** Approved (pending spec review)

## Context

The `agentgateway-argocd-quickstart` repo installs Argo CD and the Enterprise Agentgateway controller via a single multi-source Argo CD `Application`. After the controller is running, three custom resources must be applied to bring up the data plane:

| Resource | Purpose |
|---|---|
| `EnterpriseAgentgatewayParameters/agentgateway-config` | Referenced by `gatewayClassParametersRefs` in the controller chart values. Controls replicas, shared extensions (extauth, ratelimiter, extCache), service type, metrics enrichment. |
| `Gateway/agentgateway-proxy` | The actual data-plane Gateway, owned by the `enterprise-agentgateway` GatewayClass. |
| `EnterpriseAgentgatewayPolicy/access-logs` | Enriches access logs with JWT claims and LLM-specific fields. |

These three CRs already live in the repo at `argocd/manifests/agw-config/` as plain YAML.

The current `README.md` documents two GitOps patterns for delivering these CRs:

- **Option A**: a second Argo CD `Application` pointing at the git path `argocd/manifests/agw-config/`.
- **Option C**: a third source on the existing multi-source `Application` via the [`bedag/raw`](https://github.com/bedag/helm-charts/tree/main/charts/raw) chart, embedding the CRs inline as `valuesObject.resources`.

Both patterns are shown as `kubectl apply --context cluster1 -f- <<EOF … EOF` heredocs in the README. There are no checked-in `Application` YAML files in the repo today — the source of truth for these Application manifests is the README prose itself.

## Goals

1. Let a user walking through the tutorial deploy the data plane via **either** pattern by applying a single file with `kubectl apply -f …`.
2. Keep both patterns first-class: neither is hidden behind a flag or chosen for the user.
3. No behavioral change to what's already running on a cluster that was set up by following the existing README.
4. Keep the choice between Option A and Option B visible and reversible.

## Non-Goals

- Templating the three CRs (no values, no Helm chart authored in this repo). YAGNI for three static CRs.
- Adding the deferred `tracing` policy. It still requires the `solo-enterprise-telemetry-collector` from `002` and is out of scope.
- Adding sample workloads (httpbin, HTTPRoute) to prove traffic flow end-to-end. Out of scope; tutorial stops at the gateway data plane being deployed.
- Building a wrapper script that selects A vs B. The user chose plain README + `kubectl apply` lines.
- Supporting forks via a placeholder repoURL or `sed` snippet. The user chose to hardcode the upstream URL.

## Naming

Throughout this spec, "Option A" and "Option B" are used for clarity. **Option B** here corresponds to **Option C** in the current README (the `bedag/raw` third-source pattern). The current README's "Option B" — plain `kubectl apply` of the raw manifests — is not a GitOps pattern and is dropped in this work.

## Design

### File layout

```
argocd/
├── manifests/
│   └── agw-config/                                  (unchanged)
│       ├── parameters.yaml
│       ├── gateway.yaml
│       └── policy-access-logs.yaml
└── applications/                                    (new directory)
    ├── controller.yaml
    ├── option-a-dataplane.yaml
    └── option-b-controller-and-dataplane.yaml
```

### File contents

**`argocd/applications/controller.yaml`** — verbatim from the existing README "Deploy Enterprise Agentgateway via Argo CD" heredoc. Multi-source `Application` named `enterprise-agentgateway` with two sources: `enterprise-agentgateway-crds` and `enterprise-agentgateway` charts. `targetRevision: v2026.5.0` on both. This is what is already running on the cluster — content must match exactly so applying it from the file is a no-op against a cluster set up by the existing README.

**`argocd/applications/option-a-dataplane.yaml`** — verbatim from the existing README "Option A — Second Application from a Git path" heredoc. `Application` named `enterprise-agentgateway-config`, single source, `repoURL: https://github.com/ably77/agentgateway-argocd-quickstart.git`, `targetRevision: main`, `path: argocd/manifests/agw-config`. `syncPolicy.automated.prune: true` so deleting the App prunes the three CRs.

**`argocd/applications/option-b-controller-and-dataplane.yaml`** — verbatim from the existing README "Option C — Third source on the existing Application via `bedag/raw`" heredoc. Same `Application` name as `controller.yaml` (`enterprise-agentgateway`), so applying it replaces the controller-only App in-place with the same-named App that has a third `bedag/raw` source. The third source's `resources:` list contains the same three CRs as `argocd/manifests/agw-config/` with values pinned to match those files.

### Why same Application name for B

Applying `option-b-controller-and-dataplane.yaml` does a server-side replace of the existing `enterprise-agentgateway` Application. Argo CD reconciles the new spec (now with three sources instead of two) and the bedag/raw source produces the three CRs. No new Argo CD object is created. This keeps "Option B" coherent with the README's framing of "one Argo CD object end-to-end."

### Why same CR values in both options

For someone switching A ↔ B, the apparent diff against the cluster should be limited to *who owns the CRs* (which Application), not *what's in the CRs*. If the embedded `resources:` in B drifted from the files in `argocd/manifests/agw-config/`, switching options would silently change gateway config. They must stay in sync.

A future improvement could enforce this with a CI check that diff's the inline `resources:` against the files. Out of scope here; called out as a known maintenance risk.

### Apply paths

**Option A:**
```bash
kubectl apply -f argocd/applications/controller.yaml --context cluster1
# wait for Synced/Healthy
kubectl apply -f argocd/applications/option-a-dataplane.yaml --context cluster1
```

**Option B:**
```bash
kubectl apply -f argocd/applications/option-b-controller-and-dataplane.yaml --context cluster1
```
(Replaces the controller App in place if it already exists. Safe on a fresh cluster too — the file is a superset of `controller.yaml`.)

### Switching between options

**A → B:**

Prerequisite: the `bedag-raw` Helm repo entry must exist in Argo CD's `argocd-cm`. If you started from Option A and never ran Option B, this entry is *not* present yet. Add it by re-running the `helm upgrade` from the README's "Option B" subsection (the values file gains a `bedag-raw` entry under `configs.cm.repositories`). Then:

```bash
kubectl delete application enterprise-agentgateway-config -n argocd --context cluster1
# wait for prune (the three CRs are owned by this App; Argo deletes them)
kubectl apply -f argocd/applications/option-b-controller-and-dataplane.yaml --context cluster1
# the bedag/raw source re-creates the three CRs under the enterprise-agentgateway App
```

**B → A:**
```bash
kubectl apply -f argocd/applications/controller.yaml --context cluster1
# Argo prunes the three CRs (the bedag/raw source is gone)
kubectl apply -f argocd/applications/option-a-dataplane.yaml --context cluster1
```

Both transitions briefly delete and recreate the three CRs. The `Gateway` deletion will tear down its data-plane proxy Deployment; this is acceptable for a tutorial demo. Flagged in the README "Switching" subsection.

## README changes

1. **Section "Deploy Enterprise Agentgateway via Argo CD"** — replace the existing heredoc-style `kubectl apply --context cluster1 -f- <<EOF … EOF` with:
   ```bash
   kubectl apply -f argocd/applications/controller.yaml --context cluster1
   ```
   Keep the "Why these settings?" prose unchanged.

2. **New top-level section "Deploy the Data Plane"** — replaces the current "Deploy the Gateway Configuration" section. Contains:
   - One-paragraph intro listing the three CRs.
   - Subsection **"Option A — Separate Application from a Git path"**: one-line `kubectl apply -f argocd/applications/option-a-dataplane.yaml --context cluster1`, plus the "Why a separate Application" prose from the current README.
   - Subsection **"Option B — Inline manifests via `bedag/raw`"** (renamed from current "Option C"): one-line `kubectl apply -f argocd/applications/option-b-controller-and-dataplane.yaml --context cluster1`, plus the "Why this works" / "Caveats" prose from the current README. The `helm upgrade` step for the bedag repo entry stays (Option B still needs the bedag/raw entry in Argo CD's repositories).
   - Subsection **"Switching between Option A and Option B"** with the two transition recipes above.
   - Subsection **"When to pick which"** — keep the existing comparison table, updated to A/B labels.

3. **Remove** the current README's "Option B — plain `kubectl apply`" parenthetical aside. It was already not recommended; with two named GitOps options, removing it cleans up the prose.

4. **Section "Next Steps"** — update wording to reference Option A / Option B by name.

## Files changed

| File | Action |
|---|---|
| `argocd/applications/controller.yaml` | New |
| `argocd/applications/option-a-dataplane.yaml` | New |
| `argocd/applications/option-b-controller-and-dataplane.yaml` | New |
| `README.md` | Modified (sections noted above) |
| `argocd/manifests/agw-config/parameters.yaml` | Unchanged |
| `argocd/manifests/agw-config/gateway.yaml` | Unchanged |
| `argocd/manifests/agw-config/policy-access-logs.yaml` | Unchanged |

## Verification

After implementation, the following must hold:

1. `diff` between `kubectl get application enterprise-agentgateway -n argocd -o yaml` from the existing cluster (set up via the current README) and the spec of `argocd/applications/controller.yaml` shows no semantic difference (ignoring server-side fields like `status`, `metadata.resourceVersion`, etc.).
2. Applying `option-a-dataplane.yaml` to the existing cluster reaches `Synced/Healthy` and creates the three CRs.
3. After A → B switch, the existing cluster reaches `Synced/Healthy` on the `enterprise-agentgateway` App with three sources, and the three CRs exist and are owned by the bedag/raw source.
4. After B → A switch, the cluster ends in the same state as step 2.
5. The three CR specs after Option A apply are byte-identical (mod metadata) to the three CR specs after Option B apply.

## Risks

- **Drift between inline and file CRs.** Anyone editing `argocd/manifests/agw-config/*.yaml` must remember to mirror the change in `option-b-controller-and-dataplane.yaml`'s `resources:` block. No automation enforces this. Mitigation: a sentence in the README's Option B subsection warning future editors.
- **Switching tears down the Gateway.** Between delete-old-App and apply-new-App, the three CRs cease to exist and the data-plane proxy Deployment is removed. Acceptable for tutorial; would not be in production.
- **Hardcoded upstream repoURL.** Forkers must edit `option-a-dataplane.yaml` before apply. The current README already lives with this; calling it out is sufficient.
