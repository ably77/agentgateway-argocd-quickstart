# Deploy Enterprise Agentgateway with Argo CD

## Introduction
GitOps is becoming an increasingly popular approach to manage Kubernetes components. It works by using Git as a single source of truth for declarative infrastructure and applications, allowing your application definitions, configurations, and environments to be declarative and version controlled. This helps to make these workflows automated, auditable, and easy to understand.

> **Air-gap note:** Container images for the controller, proxy, and shared extensions are pulled from the `docker.io/ably7` mirror — see the workshop's `ably7-image-list` for the full inventory. Pods do not pull from `us-docker.pkg.dev`, `gcr.io`, or unmirrored `docker.io` at runtime. The Helm chart sources referenced by the Argo CD Applications themselves still come from `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` — Argo CD's repo-server needs egress to that registry. For full chart-source airgap, mirror those charts to your private OCI registry and update the `repoURL:` fields under `argocd/applications/`.

## Purpose of this Tutorial
The main goal of this tutorial is to showcase how Enterprise Agentgateway components can seamlessly integrate into a GitOps workflow, with Argo CD being our tool of choice. We'll guide you through the installation of Argo CD and Enterprise Agentgateway, then walk through verification.

The Enterprise Agentgateway install is composed of two Helm charts:

| Chart | Purpose |
| --- | --- |
| `enterprise-agentgateway-crds` | Installs the CRDs (`enterpriseagentgateway.solo.io`, `agentgateway.dev`, `extauth.solo.io`, `ratelimit.solo.io`) |
| `enterprise-agentgateway` | Installs the controller Deployment, RBAC, license Secret, and (optional) shared extensions |

We deliver both with a **single multi-source `Application`**. Argo CD's built-in kind-sort installs `CustomResourceDefinition` before `Deployment` regardless of which source produced it, so the two charts coexist safely under one Application object.

## Prerequisites
This tutorial assumes a single Kubernetes cluster (≥ 1.30) for demonstration. Instructions have been validated on `kind`, k3d, EKS, and GKE. Setting up the cluster itself is out of scope. Ensure your kubeconfig context is named `cluster1`:

```bash
kubectl config get-contexts
```

```
CURRENT   NAME       CLUSTER         AUTHINFO         NAMESPACE
*         cluster1   kind-cluster1   kind-cluster1
```

If your local cluster uses a different context name, rename it:
```bash
kubectl config rename-context <your-context-name> cluster1
```

You will also need:
- `helm` ≥ 3.8 (only used to inspect chart values; not required for the install)
- A Solo trial license key exported as `SOLO_TRIAL_LICENSE_KEY`
- `kubectl` configured for the cluster

```bash
# Replace the placeholder with your actual key (or ensure SOLO_TRIAL_LICENSE_KEY
# is already exported in your shell — the license Secret step below reads it).
export SOLO_TRIAL_LICENSE_KEY=<your-trial-license-key>
```

## Install the Kubernetes Gateway API CRDs
Enterprise Agentgateway implements the upstream Gateway API. This quickstart installs the **standard channel** — it covers everything the tutorial uses (Gateway, HTTPRoute, GatewayClass, etc.). If you need experimental features later (e.g. frontend mTLS), swap the URL below to `experimental-install.yaml`.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml --context cluster1
```

Verify:
```bash
kubectl api-resources --api-group=gateway.networking.k8s.io --context cluster1
```

## Install Argo CD
Argo CD is installed via the official `argo/argo-cd` Helm chart. A small values file pre-bakes three things so we don't have to patch them afterwards:

1. `--insecure` on the API server (workshop / local-cluster convenience)
2. The bcrypt-hashed admin password (`solo.io`) under `configs.secret.argocdServerAdminPassword`
3. The Enterprise Agentgateway OCI Helm registry under `configs.cm.repositories` — this replaces the standalone "register a repository Secret" step

Add the Argo Helm repo:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
```

Create the `argocd` namespace:
```bash
kubectl create namespace argocd --context cluster1
```

Write the values file:
```bash
cat > /tmp/argocd-values.yaml <<'EOF'
server:
  service:
    type: ClusterIP
  extraArgs:
    - --insecure
configs:
  secret:
    # bcrypt of "solo.io"
    argocdServerAdminPassword: "$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy"
  params:
    applicationsetcontroller.policy: sync
    applicationsetcontroller.enable.new.git.file.globbing: "true"
  cm:
    helm.enabled: "true"
    timeout.reconciliation: 30s
  repositories:
    enterprise-agentgateway:
      type: helm
      name: enterprise-agentgateway
      url: us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
      enableOCI: "true"
applicationSet:
  enabled: true
EOF
```

Install Argo CD:
```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 9.5.17 \
  --kube-context cluster1 \
  --values /tmp/argocd-values.yaml \
  --wait --timeout 300s
```

Verify pods:
```bash
kubectl get pods -n argocd --context cluster1
```

```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          90s
argocd-applicationset-controller-...                1/1     Running   0          90s
argocd-dex-server-...                               1/1     Running   0          90s
argocd-notifications-controller-...                 1/1     Running   0          90s
argocd-redis-...                                    1/1     Running   0          90s
argocd-repo-server-...                              1/1     Running   0          90s
argocd-server-...                                   1/1     Running   0          90s
```

### Open the Argo CD UI
```bash
kubectl port-forward svc/argocd-server -n argocd 9999:443 --context cluster1
```

Then browse to <http://localhost:9999>. Login with `admin` / `solo.io`.

## Bootstrap the License Secret
The controller chart can either create the license Secret for you (`licensing.createSecret: true`, the default) or consume an existing one (`licensing.createSecret: false`). We use the existing-Secret pattern so the license key never has to live inside the `Application` manifest.

The chart's Deployment template hard-codes the Secret key to **`enterprise-agentgateway-license-key`**, so the Secret must use exactly that key:

```bash
kubectl create namespace agentgateway-system --context cluster1
```

```bash
kubectl --context cluster1 -n agentgateway-system create secret generic enterprise-agentgateway-license \
  --from-literal=enterprise-agentgateway-license-key="$SOLO_TRIAL_LICENSE_KEY"
```

> Note: the license env var is declared with `optional: true`, so the controller pod will start even if the Secret is missing. The pod will simply fail license validation. This means Argo CD won't block on Secret ordering — but you should still create it before the first sync to get a clean rollout.

## Deploy Enterprise Agentgateway via Argo CD
A single multi-source `Application` deploys both the CRD chart and the controller chart. Argo CD will render each Helm source independently, merge the resulting manifests, and apply them with its built-in kind ordering (CRDs first).

```bash
kubectl apply -f argocd/applications/controller.yaml --context cluster1
```

### Why these settings?
- **`sources:` (plural)** — multi-source Application. Both charts deploy as one Argo CD object.
- **`releaseName:`** — pin the Helm release name per source. Without this, both sources would default to the Application name and collide.
- **`licensing.createSecret: false`** — tells the chart not to manage the license Secret. We pre-created it in the previous step. The chart's Deployment still references the Secret by `secretName` and reads the `enterprise-agentgateway-license-key` key.
- **`gatewayClassParametersRefs`** — points the `enterprise-agentgateway` `GatewayClass` at an `EnterpriseAgentgatewayParameters` named `agentgateway-config` in `agentgateway-system`. This CR is not created by the chart; you'll create it in the next step (or a later Application) when you deploy a `Gateway`.
- **`automated.prune + selfHeal`** — typical GitOps reconcile loop.
- **`CreateNamespace=true`** — Argo CD creates `agentgateway-system` if it doesn't exist (a no-op if you already created it for the license Secret).
- **`ServerSideApply=true`** — CRDs are large; SSA avoids the 256KB `last-applied-configuration` annotation limit and provides field-manager–aware merges.

## Verify the Install
Watch the Application converge:
```bash
kubectl get application enterprise-agentgateway -n argocd --context cluster1 -w
```

Expect `STATUS=Synced` and `HEALTH=Healthy` within ~1 minute.

Verify CRDs:
```bash
kubectl api-resources --context cluster1 \
  | awk 'NR==1 || /enterpriseagentgateway\.solo\.io|agentgateway\.dev|ratelimit\.solo\.io|extauth\.solo\.io/'
```

Verify the controller pod:
```bash
kubectl get pods -n agentgateway-system -l app.kubernetes.io/name=enterprise-agentgateway --context cluster1
```

```
NAME                                       READY   STATUS    RESTARTS   AGE
enterprise-agentgateway-5fc9d95758-n8vvb   1/1     Running   0          45s
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Application` stuck in `OutOfSync` with a `helm template` error mentioning OCI | `enterprise-agentgateway` repo entry missing from the Argo CD ConfigMap, or `enableOCI: "true"` not set | Re-run `helm upgrade` with the values file from the install step, or edit `configmap argocd-cm -n argocd` to add the entry under `repositories:` |
| Controller pod `CrashLoopBackOff` with license errors | License Secret missing, wrong key name, or wrong namespace | Recreate the Secret in `agentgateway-system` with key `enterprise-agentgateway-license-key`, then `kubectl rollout restart deployment/enterprise-agentgateway -n agentgateway-system` |
| `Application` shows `SyncFail` mentioning CRD size | `last-applied-configuration` annotation too large | Confirm `ServerSideApply=true` is in `syncPolicy.syncOptions` |
| Sources collide on Helm release name | Missing `releaseName:` on one of the sources | Add an explicit `helm.releaseName` to both sources |

## Deploy the Data Plane

The controller is running, but the data plane isn't until we apply three more resources:

| Resource | Purpose |
| --- | --- |
| `EnterpriseAgentgatewayParameters/agentgateway-config` | Referenced by `gatewayClassParametersRefs` in the controller chart values. Controls replicas, shared extensions (extauth, ratelimiter, extCache), service type, and metrics enrichment. |
| `Gateway/agentgateway-proxy` | The actual data-plane Gateway. Owned by the `enterprise-agentgateway` GatewayClass. |
| `EnterpriseAgentgatewayPolicy/access-logs` | Enriches access logs with JWT claims and LLM-specific fields (`llm.streaming`, `llm.cached_tokens`, `llm.prompt`, etc.). |

> The `tracing` policy from `001` is deliberately skipped here — it points at `solo-enterprise-telemetry-collector` which is installed by `002`. Apply it after the telemetry collector exists.

Two GitOps patterns are shown side by side. **Option A** uses a second `Application` pulling from a Git path; **Option B** keeps everything in the single existing multi-source `Application` by adding a third "raw manifests" Helm source. Pick one — they manage the same three CRs and cannot run simultaneously.

### Option A — Separate Application from a Git path

The three CRs live in this repo under `argocd/manifests/agw-config/`:

```
argocd/
└── manifests/
    └── agw-config/
        ├── parameters.yaml          # EnterpriseAgentgatewayParameters/agentgateway-config
        ├── gateway.yaml             # Gateway/agentgateway-proxy
        └── policy-access-logs.yaml  # EnterpriseAgentgatewayPolicy/access-logs
```

If you fork this repo, edit the values in those files to suit your environment and `git push` before creating the Application below. You'll also need to update the `repoURL:` field in `argocd/applications/option-a-dataplane.yaml` to point at your fork.

Create the second `Application`:

```bash
kubectl apply -f argocd/applications/option-a-dataplane.yaml --context cluster1
```

**Why a separate Application:** the controller App owns chart-rendered resources (Deployment, RBAC, etc.) and is reconciled on chart upgrades. The config App owns hand-written CRs and is reconciled on every `git push`. Keeping them split means changing the gateway config doesn't risk re-templating the controller chart, and vice versa.

**Sync ordering note:** the `Gateway` and `EnterpriseAgentgatewayParameters` CRs depend on CRDs already installed by the controller App. Argo CD won't enforce ordering *between* Applications by default — apply the controller App first, wait for `Synced + Healthy`, then create this one. If you want explicit ordering, add `argocd.argoproj.io/sync-wave: "1"` to this Application's metadata.

### Option B — Inline manifests via `bedag/raw`

Keep one Argo CD object. The file `argocd/applications/option-b-controller-and-dataplane.yaml` is a superset of `controller.yaml` with a third source using the [`bedag/raw`](https://github.com/bedag/helm-charts/tree/main/charts/raw) chart, whose only job is to template arbitrary YAML from `valuesObject.resources`.

First, register the `bedag` Helm repo in Argo CD by appending one entry to the values file you used at install time, then `helm upgrade`:

```yaml
# add under configs.cm.repositories in /tmp/argocd-values.yaml
    bedag-raw:
      type: helm
      name: bedag-raw
      url: https://bedag.github.io/helm-charts/
```

> If you're returning to the tutorial in a fresh shell (or after a reboot) and `/tmp/argocd-values.yaml` no longer exists, recreate it from the values block in the [Install Argo CD](#install-argo-cd) section above, then append the `bedag-raw` entry.

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 9.5.17 \
  --kube-context cluster1 \
  --values /tmp/argocd-values.yaml \
  --wait --timeout 300s
```

Then apply the multi-source Application (same name as the controller App — this replaces it in place):

```bash
kubectl apply -f argocd/applications/option-b-controller-and-dataplane.yaml --context cluster1
```

**Why this works:** `bedag/raw` is a thin chart whose `templates/` block just `{{ toYaml . }}`s the `resources:` list. It exists specifically to let Helm-flavored GitOps tools (Argo CD, Flux) ship raw manifests inline without a separate Git repo. Pinned to `2.0.2`.

**Caveats vs Option A:**
- Editing the gateway config means editing this Application manifest — there's no `git diff` on YAML files, just on the embedded `valuesObject`.
- The files under `argocd/manifests/agw-config/` in this repo are still the canonical source — the `resources:` block in this file must be kept in sync with them. There is no automated check today; remember to mirror any edits.
- The third-party chart introduces a (tiny) supply-chain dependency.

### Switching between Option A and Option B

The two options manage the same three CRs and conflict if both are applied. Switch like this:

**A → B:**

First register the `bedag-raw` repo (see the Option B install step above) if you didn't already, then:

```bash
kubectl delete application enterprise-agentgateway-config -n argocd --context cluster1

# Wait until Argo CD has actually pruned the three CRs (the deleted Application's
# resources-finalizer drives the prune, but the finalizer is not guaranteed on
# every install — poll until the Gateway is gone to avoid an SSA field-manager
# race when the new owner takes over.
until ! kubectl get gateway/agentgateway-proxy -n agentgateway-system --context cluster1 >/dev/null 2>&1; do
  sleep 2
done

kubectl apply -f argocd/applications/option-b-controller-and-dataplane.yaml --context cluster1
# the bedag/raw source re-creates the three CRs under the enterprise-agentgateway App
```

**B → A:**

```bash
kubectl apply -f argocd/applications/controller.yaml --context cluster1

# Re-applying controller.yaml only updates the Application spec; the prune of the
# three CRs (owned by the now-removed bedag/raw source) happens on Argo's next
# reconcile. Poll until the Gateway is gone before creating the new owner, or
# the new Application will hit an SSA field-manager conflict.
until ! kubectl get gateway/agentgateway-proxy -n agentgateway-system --context cluster1 >/dev/null 2>&1; do
  sleep 2
done

kubectl apply -f argocd/applications/option-a-dataplane.yaml --context cluster1
```

Both transitions briefly delete and recreate the `Gateway` CR, which tears down the data-plane proxy Deployment. Acceptable for a tutorial; you would not do this on a live prod gateway.

### When to pick which

| Pick Option A if… | Pick Option B if… |
| --- | --- |
| Labs 002+ will edit the gateway config repeatedly | You want a single Argo CD object to point at |
| You want plain-YAML PRs for changes | You're allergic to extra Git repos / paths |
| Your team prefers one Application per "concern" | You're OK with `bedag/raw` as a dependency |
| You want to demo `git push` → reconcile loop | You're scripting a demo that should be 100% recoverable from one manifest |

## Next Steps
With the controller and gateway configuration installed via Argo CD, continue with `002` to set up the Solo UI and monitoring (Prometheus, Grafana, OpenTelemetry collector). Once the telemetry collector exists, come back and apply the `tracing` policy from `001` — either as a fourth file under `argocd/manifests/agw-config/` (Option A) or as a fourth entry in the `bedag/raw` source's `resources:` list (Option B).
