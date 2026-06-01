# Airgap Image Overrides Design

**Date:** 2026-06-01
**Status:** Approved (pending spec review)

## Context

The `agentgateway-argocd-quickstart` repo installs Enterprise Agentgateway via Argo CD using two Helm charts hosted at `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts`. By default, the controller chart and the `EnterpriseAgentgatewayParameters` CR render pod specs whose container images come from those same Google-hosted public registries (`us-docker.pkg.dev/solo-public/*`, `gcr.io/*`, `docker.io/*` public images).

For airgap-style environments — and for users who want a single setup that doesn't depend on multiple public registries at pod-launch time — the workshop reference at `/Users/alexly-solo/Desktop/solo/archive/5-29-26/airgap-agw/` documents a working alternative: all images mirrored to `docker.io/ably7`. The Helm chart values and the `EnterpriseAgentgatewayParameters` spec accept per-component `image:` blocks (`registry`, `repository`, `tag`, optional `pullPolicy`) that override the chart's defaults.

This work folds those image overrides into the canonical setup in this repo.

## Goals

1. The current install path (controller App + Option A or Option B data-plane App) deploys pods whose images come from `docker.io/ably7/*` instead of `us-docker.pkg.dev/solo-public/*` and other public defaults.
2. The image registries and tags exactly match `/Users/alexly-solo/Desktop/solo/archive/5-29-26/airgap-agw/ably7-image-list.md` so the result is bit-for-bit equivalent to the validated workshop airgap setup.
3. `imagePullSecrets` placeholders are present (commented) for real airgap users who pull from a private registry, mirroring the reference doc's style.
4. The existing Option A vs Option B choice, the `bedag/raw` drift-check, the Switching guidance, and the Argo CD Application structure all stay intact.
5. From-scratch install on a fresh cluster (vcluster-docker `cluster1`) reaches all components Running and Argo CD Applications Synced/Healthy. (Upgrade-from-public-images is explicitly not tested or supported by this work; the user provisions a fresh cluster.)

## Non-Goals

- Not a fully self-contained airgap. The Helm chart pulls themselves still come from `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts`. Documented as a known limitation; the reference doc has the same gap.
- Not Solo UI / management chart (`002+`) airgap. Out of scope here.
- Not adding sample workloads or HTTPRoutes.
- Not parameterizing the registry via a values file or templated chart — image registries and tags are hardcoded to `docker.io/ably7/*`. Substituting a different mirror requires editing the YAMLs.
- Not introducing a non-airgap variant alongside. This becomes the canonical setup; there is no "public-registry" alternative shipped.
- Not adding `pullPolicy: IfNotPresent` to anything except the controller (matching the reference).
- Not testing the upgrade path from the previous public-registry install. The user has a fresh cluster.

## Image values

Sourced verbatim from `airgap-agw/ably7-image-list.md`:

| Component | Registry/repo | Tag |
|---|---|---|
| controller | `docker.io/ably7/enterprise-agentgateway-controller` | `2026.5.0` |
| proxy | `docker.io/ably7/agentgateway-enterprise` | `2026.5.0` |
| ext-auth | `docker.io/ably7/ext-auth-service` | `0.81.1` |
| rate-limiter | `docker.io/ably7/rate-limiter` | `0.18.6` |
| ext-cache (redis) | `docker.io/ably7/redis` | `8.6.2-alpine` |

For each block, `image:` is structured as `{registry, repository, tag}`. Per the reference doc's convention:

- **controller** uses `registry: docker.io/ably7` and `repository: enterprise-agentgateway-controller` (registry includes the user namespace).
- **proxy / extensions** use `registry: docker.io` and `repository: ably7/<name>` (user namespace folded into repository).

This split is intentional — it preserves the reference doc's structure byte-for-byte. Both forms resolve to the same pull URL.

## Design

### File changes

| File | Change |
|---|---|
| `argocd/applications/controller.yaml` | Add `controller.image.{registry, repository, tag, pullPolicy: IfNotPresent}` under the controller chart's `valuesObject`. Add commented `controller.imagePullSecrets:` placeholder block. |
| `argocd/manifests/agw-config/parameters.yaml` | Add top-level `spec.image` (proxy override). Add `spec.sharedExtensions.{extauth,ratelimiter,extCache}.image` blocks (3 extension services). Add commented `imagePullSecrets:` placeholders inside each `deployment.spec.template.spec` and the top-level deployment. |
| `argocd/applications/option-b-controller-and-dataplane.yaml` | Mirror the controller-chart change (same as `controller.yaml`). Mirror the parameters change inside the inline `resources:` list. Inline parameters CR must be byte-identical to `argocd/manifests/agw-config/parameters.yaml` (the existing drift-check script enforces this). |
| `README.md` | Insert a blockquote "Air-gap note" immediately after the `## Introduction` paragraph (before `## Purpose of this Tutorial`), styled like the reference doc's blockquote: it states that container images come from `docker.io/ably7` and that the Helm chart sources themselves are still pulled from `us-docker.pkg.dev/solo-public`. No other structural changes; no new sections. |

### Why each block goes where

- **`controller.image` in the chart's `valuesObject`** — the `enterprise-agentgateway` Helm chart's controller `Deployment` template reads from `controller.image.{registry,repository,tag,pullPolicy}` and `controller.imagePullSecrets`. Setting them in the chart values is the supported path.

- **`spec.image` on the `EnterpriseAgentgatewayParameters` CR** — controls the image used for the data-plane proxy `Deployment` (`agentgateway-proxy`). The controller reads this CR when reconciling the `Gateway/agentgateway-proxy` resource.

- **`spec.sharedExtensions.<name>.image` on the same CR** — three nested blocks (`extauth`, `ratelimiter`, `extCache`) each controlling the image for their respective auxiliary deployment.

- **Commented `imagePullSecrets:` placeholders** — `docker.io/ably7` is a public Docker Hub user, so no auth is needed for the demo. The reference doc keeps these as comments alongside each deployment spec so a real airgap user pulling from a private registry has obvious anchor points to uncomment and edit.

### Drift between files

The existing drift-check (key-by-Kind+name comparison between inline `resources:` in `option-b-controller-and-dataplane.yaml` and the files under `argocd/manifests/agw-config/`) continues to enforce that the parameters CR is identical in both representations. After this change, both representations carry the same image overrides; the check should remain green.

### Charts vs images

The chart sources stay at `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` in both `controller.yaml` and `option-b-controller-and-dataplane.yaml`. This is the same as the workshop reference doc, which acknowledges "All images have been mirrored" but still pulls the Helm chart from Google. A user with truly no outbound internet would need to mirror the chart separately (out of scope here).

### From-scratch test target

User's cluster context: `cluster1` (vcluster-docker), freshly provisioned, contains only kube-system / flannel / local-path-storage. The implementation plan's verification re-runs the full install path against this fresh cluster:

1. Install Gateway API CRDs (standard channel).
2. Install Argo CD (no airgap on Argo CD itself — out of scope).
3. Create license Secret.
4. Apply `controller.yaml` — controller pod must come up using `docker.io/ably7/enterprise-agentgateway-controller:2026.5.0`.
5. Apply `option-a-dataplane.yaml` — 3 CRs created from the Git path; proxy + extension pods come up using `docker.io/ably7/*` images.
6. (Optionally) verify `option-b-controller-and-dataplane.yaml` reaches the same pod images from inline `resources:`.

Image references on every pod must match `airgap-agw/output.md` exactly:

```
docker.io/ably7/agentgateway-enterprise:2026.5.0
docker.io/ably7/enterprise-agentgateway-controller:2026.5.0
docker.io/ably7/ext-auth-service:0.81.1
docker.io/ably7/rate-limiter:0.18.6
docker.io/ably7/redis:8.6.2-alpine
```

## Verification

After implementation:

1. `controller.yaml` and `option-b-controller-and-dataplane.yaml` both `kubectl apply --dry-run=server` cleanly.
2. The inline-vs-file drift python script (existing) prints `OK` for all three CRs.
3. Fresh-cluster install reaches Argo CD Applications `Synced/Healthy` for both the controller App (and the data-plane App in Option A).
4. `kubectl get pods -n agentgateway-system -oyaml | grep image:` matches the airgap reference output set: all `docker.io/ably7/*`, no `us-docker.pkg.dev/*` images.
5. Pods Ready: controller, proxy×2, ext-auth, ext-cache, rate-limiter — total 6 pods Running.

## Risks

- **Drift between inline (option-b) and file (parameters.yaml)** image specs. Already mitigated by the existing comparison script.
- **Hardcoded `docker.io/ably7` registry.** A user who wants a different mirror has to grep-and-replace across three files. Acceptable trade-off vs introducing values templating.
- **Reference doc says `registry: docker.io/ably7` for controller but `registry: docker.io` for proxy/extensions.** This asymmetry is preserved verbatim in our YAMLs. Either form would work; preserving the reference's exact shape avoids any chart-template surprises and lets a reader cross-reference the source doc.
- **Future tag updates.** Bumping to a new Enterprise Agentgateway version requires updating tags in three files (`controller.yaml`, `parameters.yaml`, `option-b-controller-and-dataplane.yaml`) plus rebuilding the mirror. No automation. Documented as known toil; out of scope to fix here.

## Files changed

| File | Action |
|---|---|
| `argocd/applications/controller.yaml` | Modified |
| `argocd/applications/option-b-controller-and-dataplane.yaml` | Modified |
| `argocd/manifests/agw-config/parameters.yaml` | Modified |
| `README.md` | Modified (single new note) |
| `argocd/applications/option-a-dataplane.yaml` | Unchanged |
| `argocd/manifests/agw-config/gateway.yaml` | Unchanged |
| `argocd/manifests/agw-config/policy-access-logs.yaml` | Unchanged |
