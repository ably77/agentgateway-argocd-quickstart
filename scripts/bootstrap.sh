#!/usr/bin/env bash
#
# Bootstrap the Enterprise Agentgateway quickstart against kubeconfig
# context "cluster1". Mirrors the manual steps in ../README.md.
#
# Inputs:
#   SOLO_TRIAL_LICENSE_KEY   (required) — Solo trial license key
#   BOOTSTRAP_DATAPLANE      (optional) — "a", "b", or "skip" to bypass
#                                          the interactive prompt
#
# Requires: kubectl, helm (>= 3.8), kubeconfig context "cluster1".

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────
readonly CTX="cluster1"
readonly ARGOCD_NS="argocd"
readonly AGW_NS="agentgateway-system"
readonly ARGOCD_CHART_VERSION="9.5.17"
readonly GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml"
readonly ARGOCD_VALUES="/tmp/argocd-values.yaml"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly WAIT_TIMEOUT=300

# ── Helpers ───────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "failed at line ${LINENO} (last command: ${BASH_COMMAND})"' ERR

# Poll an Argo CD Application until Sync=Synced and Health=Healthy.
# Args: $1 = app name (in namespace argocd)
# Times out after WAIT_TIMEOUT seconds and dumps .status.conditions on failure.
wait_for_app() {
  local app="$1"
  local deadline
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  log "Waiting for Application/${app} to be Synced + Healthy..."
  while (( $(date +%s) < deadline )); do
    local err state rc
    err="$(mktemp)"
    state="$(kubectl --context "${CTX}" -n "${ARGOCD_NS}" get application/"${app}" \
      -o jsonpath='{.status.sync.status},{.status.health.status}' 2>"${err}")" \
      && rc=0 || rc=$?
    if (( rc != 0 )); then
      if ! grep -qi 'notfound\|not found' "${err}"; then
        warn "kubectl get application/${app}: $(tr -d '\n' < "${err}")"
      fi
      state=""
    fi
    rm -f "${err}"
    if [[ "${state}" == "Synced,Healthy" ]]; then
      log "Application/${app} is Synced + Healthy."
      return 0
    fi
    sleep 5
  done
  warn "Application/${app} did not become Synced+Healthy within ${WAIT_TIMEOUT}s."
  warn "Last conditions:"
  kubectl --context "${CTX}" -n "${ARGOCD_NS}" get application/"${app}" \
    -o jsonpath='{.status.conditions}' >&2 || true
  echo >&2
  die "timeout waiting for Application/${app}"
}

# ── Phase: preflight ──────────────────────────────────────────────────────
preflight() {
  log "Preflight checks..."

  command -v kubectl >/dev/null || die "kubectl not found in PATH"
  command -v helm    >/dev/null || die "helm not found in PATH"

  [[ -n "${SOLO_TRIAL_LICENSE_KEY:-}" ]] \
    || die "SOLO_TRIAL_LICENSE_KEY is unset; export it before running"

  case "${BOOTSTRAP_DATAPLANE:-}" in
    ""|a|b|skip) ;;
    *) die "BOOTSTRAP_DATAPLANE must be one of: a, b, skip (got: ${BOOTSTRAP_DATAPLANE})" ;;
  esac

  kubectl config get-contexts -o name | grep -qx "${CTX}" \
    || die "kubeconfig context '${CTX}' not found; rename your context with: kubectl config rename-context <name> ${CTX}"

  kubectl --context "${CTX}" version --request-timeout=5s >/dev/null \
    || die "cannot reach the cluster on context '${CTX}'"

  log "OK"
}

# ── Phase: Gateway API CRDs ───────────────────────────────────────────────
install_gateway_api() {
  log "Installing Gateway API standard-channel CRDs..."
  kubectl --context "${CTX}" apply --server-side -f "${GATEWAY_API_URL}"
  log "Gateway API CRDs applied."
}

# ── Phase: Argo CD ────────────────────────────────────────────────────────
write_argocd_values() {
  local with_bedag="${1:-}"

  cat > "${ARGOCD_VALUES}" <<'EOF'
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
EOF

  if [[ "${with_bedag}" == "with-bedag" ]]; then
    cat >> "${ARGOCD_VALUES}" <<'EOF'
    bedag-raw:
      type: helm
      name: bedag-raw
      url: https://bedag.github.io/helm-charts/
EOF
  fi

  cat >> "${ARGOCD_VALUES}" <<'EOF'
applicationSet:
  enabled: true
EOF
}

install_argocd() {
  log "Installing Argo CD ${ARGOCD_CHART_VERSION}..."

  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update argo >/dev/null

  write_argocd_values

  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" --create-namespace \
    --version "${ARGOCD_CHART_VERSION}" \
    --kube-context "${CTX}" \
    --values "${ARGOCD_VALUES}" \
    --wait --timeout 300s

  log "Argo CD ready."
}

# ── Phase: License Secret ─────────────────────────────────────────────────
create_license() {
  log "Creating namespace ${AGW_NS} and license Secret..."

  kubectl --context "${CTX}" create namespace "${AGW_NS}" \
    --dry-run=client -o yaml | kubectl --context "${CTX}" apply -f -

  kubectl --context "${CTX}" -n "${AGW_NS}" create secret generic \
    enterprise-agentgateway-license \
    --from-literal=enterprise-agentgateway-license-key="${SOLO_TRIAL_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context "${CTX}" apply -f -

  log "License Secret ready."
}

# ── Phase: Controller Application ─────────────────────────────────────────
deploy_controller() {
  log "Applying Application/enterprise-agentgateway..."
  kubectl --context "${CTX}" apply \
    -f "${REPO_ROOT}/argocd/applications/controller.yaml"
  wait_for_app "enterprise-agentgateway"
}

# ── Phase: Data-plane choice ──────────────────────────────────────────────
# Echoes one of: a, b, skip
# All user-facing output goes to >&2 so the captured stdout is exactly the choice.
prompt_dataplane() {
  if [[ -n "${BOOTSTRAP_DATAPLANE:-}" ]]; then
    echo "${BOOTSTRAP_DATAPLANE}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "stdin is not a TTY; set BOOTSTRAP_DATAPLANE=a|b|skip to choose non-interactively"
  fi

  cat <<'EOF' >&2

────────────────────────────────────────────────────────────────────────
Controller is up. Choose how to deploy the data plane:

  [a]  Option A — separate Application, plain-YAML files in this repo
                  (best if labs 002+ will edit gateway config repeatedly)
  [b]  Option B — single multi-source Application via bedag/raw
                  (best if you want one Argo CD object to point at)
  [s]  Skip    — leave the data plane unconfigured for now
────────────────────────────────────────────────────────────────────────
EOF
  local choice=""
  while [[ -z "${choice}" ]]; do
    read -n1 -r -p "Pick [a/b/s]: " key
    echo >&2
    case "${key}" in
      a|A) choice="a" ;;
      b|B) choice="b" ;;
      s|S) choice="skip" ;;
      *)   warn "Unrecognized: '${key}'. Pick a, b, or s." ;;
    esac
  done
  echo "${choice}"
}

deploy_option_a() {
  log "Applying Option A: separate data-plane Application..."
  kubectl --context "${CTX}" apply \
    -f "${REPO_ROOT}/argocd/applications/option-a-dataplane.yaml"
  wait_for_app "enterprise-agentgateway-config"
}

deploy_option_b() {
  log "Applying Option B: bedag/raw + multi-source Application..."

  # Re-render the values file with the bedag-raw repo entry nested under
  # configs.repositories. Doing this with a parameter (rather than appending
  # after the fact) keeps the YAML structurally valid on every run.
  write_argocd_values with-bedag

  # If an Option A Application is already installed, warn — it will be orphaned.
  if kubectl --context "${CTX}" -n "${ARGOCD_NS}" \
       get application/enterprise-agentgateway-config >/dev/null 2>&1; then
    warn "Application/enterprise-agentgateway-config exists from a previous Option A run."
    warn "It will be orphaned. Delete it manually if you want a clean Option B state:"
    warn "  kubectl --context ${CTX} -n ${ARGOCD_NS} delete application enterprise-agentgateway-config"
  fi

  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" --create-namespace \
    --version "${ARGOCD_CHART_VERSION}" \
    --kube-context "${CTX}" \
    --values "${ARGOCD_VALUES}" \
    --wait --timeout 300s

  kubectl --context "${CTX}" apply \
    -f "${REPO_ROOT}/argocd/applications/option-b-controller-and-dataplane.yaml"

  # Same Application name as the controller App — this replaces it in place.
  wait_for_app "enterprise-agentgateway"
}

# ── Phase: Banner ─────────────────────────────────────────────────────────
done_banner() {
  cat <<'EOF'

────────────────────────────────────────────────────────────────────────
Bootstrap complete.

Open the Argo CD UI:
  kubectl port-forward svc/argocd-server -n argocd 9999:443 --context cluster1
  → browse http://localhost:9999
  → login: admin / solo.io

Next steps and troubleshooting: see README.md.
────────────────────────────────────────────────────────────────────────
EOF
}

# ── Entrypoint ────────────────────────────────────────────────────────────
main() {
  preflight
  install_gateway_api
  install_argocd
  create_license
  deploy_controller

  local dp
  dp="$(prompt_dataplane)"
  case "${dp}" in
    a)    deploy_option_a ;;
    b)    deploy_option_b ;;
    skip) log "Skipping data plane." ;;
  esac

  done_banner
}

main "$@"
