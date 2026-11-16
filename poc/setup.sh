#!/usr/bin/env bash
# Creates the kind cluster "proxy-poc" and installs OpenBao, vault-secrets-webhook, Argo CD and
# ChartMuseum (docs/plan.md §4.7). Idempotent: re-running reuses what already exists.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

# --- 1. prerequisites ----------------------------------------------------------
step "Checking prerequisites"
missing=()
for t in docker kind kubectl helm argocd curl jq python3; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if ((${#missing[@]} > 0)); then
  cat >&2 <<EOF
ERROR: missing tools: ${missing[*]}
  kind    https://kind.sigs.k8s.io/docs/user/quick-start/#installation ($KIND_VERSION)
  argocd  https://argo-cd.readthedocs.io/en/stable/cli_installation/ ($ARGOCD_VERSION)
  kubectl, helm, jq, curl, python3 >= 3.12, docker: from your package manager
EOF
  exit 1
fi
kind_v="$(kind version | awk '{print $2}')"
[[ "$kind_v" == "$KIND_VERSION" ]] || die "kind $kind_v found, $KIND_VERSION required (node image $KIND_NODE_IMAGE)"
argocd_v="$(argocd version --client --short 2>/dev/null | sed -E 's/^argocd: (v[0-9.]+).*/\1/')"
[[ "$argocd_v" == "$ARGOCD_VERSION" ]] || die "argocd CLI $argocd_v found, $ARGOCD_VERSION required"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' || die "python >= 3.12 required"
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
info "OK: kind $kind_v, argocd $argocd_v, $(python3 --version)"

# --- 2. kind cluster -----------------------------------------------------------
step "kind cluster $CLUSTER_NAME"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "already exists, reusing it"
else
  # kind switches the current-context: restore the user's one (our scripts never use it).
  prev_context="$(kubectl config current-context 2>/dev/null || true)"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
    --config "$POC_DIR/kind-config.yaml" --wait 120s
  if [[ -n "$prev_context" ]]; then
    kubectl config use-context "$prev_context" >/dev/null
    info "current-context restored to '$prev_context'"
  fi
fi
require_context
k wait --for=condition=Ready node --all --timeout=120s >/dev/null
info "node Ready"

# --- 3. OpenBao ----------------------------------------------------------------
step "OpenBao $OPENBAO_IMAGE_TAG (chart $OPENBAO_CHART_VERSION, dev mode)"
h upgrade --install openbao openbao --repo https://openbao.github.io/openbao-helm \
  --version "$OPENBAO_CHART_VERSION" -n openbao --create-namespace \
  --set server.dev.enabled=true --set server.dev.devRootToken=root \
  --set server.image.tag="$OPENBAO_IMAGE_TAG" \
  --set injector.enabled=false \
  --wait --timeout 5m >/dev/null
k -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=180s >/dev/null
"$POC_DIR/openbao-config.sh"

# --- 4. vault-secrets-webhook ----------------------------------------------------
step "vault-secrets-webhook (chart $VAULT_WEBHOOK_CHART_VERSION)"
# Pods: failurePolicy Fail, so a proxy pod is never created without injection (with Ignore it
# would start with the literal "vault:..." values). Infra namespaces are excluded, so a webhook
# outage cannot block them; the release namespace is excluded by the chart.
h upgrade --install vault-secrets-webhook oci://ghcr.io/bank-vaults/helm-charts/vault-secrets-webhook \
  --version "$VAULT_WEBHOOK_CHART_VERSION" -n vault-webhook --create-namespace \
  --set podsFailurePolicy=Fail \
  --set 'namespaceSelector.matchExpressions[0].key=kubernetes.io/metadata.name' \
  --set 'namespaceSelector.matchExpressions[0].operator=NotIn' \
  --set 'namespaceSelector.matchExpressions[0].values={kube-system,kube-public,kube-node-lease,local-path-storage,openbao,vault-webhook,argocd,chartmuseum}' \
  --wait --timeout 5m >/dev/null
excluded="$(k get mutatingwebhookconfiguration vault-secrets-webhook \
  -o jsonpath='{.webhooks[?(@.name=="pods.vault-secrets-webhook.admission.banzaicloud.com")].namespaceSelector.matchExpressions[*].values}')"
for ns in kube-system openbao vault-webhook argocd chartmuseum; do
  [[ "$excluded" == *"\"$ns\""* ]] || die "webhook does not exclude namespace $ns"
done
info "webhook excludes system and infra namespaces"

# --- 5. Argo CD -----------------------------------------------------------------
step "Argo CD $ARGOCD_VERSION"
k create namespace argocd --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null
k -n argocd rollout status deploy/argocd-server deploy/argocd-repo-server --timeout=300s >/dev/null
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
wait_for "argocd-initial-admin-secret" 120 k -n argocd get secret argocd-initial-admin-secret
argocd_login
info "CLI login OK ($(a version --short 2>/dev/null | grep -m1 argocd-server || echo server))"

# --- 6. ChartMuseum ---------------------------------------------------------------
step "ChartMuseum $CHARTMUSEUM_IMAGE_TAG (chart $CHARTMUSEUM_CHART_VERSION)"
h upgrade --install chartmuseum chartmuseum --repo https://chartmuseum.github.io/charts \
  --version "$CHARTMUSEUM_CHART_VERSION" -n chartmuseum --create-namespace \
  --set image.tag="$CHARTMUSEUM_IMAGE_TAG" \
  --set env.open.DISABLE_API=false --set env.open.STORAGE=local \
  --wait --timeout 5m >/dev/null

# Helm repository for Argo CD (declarative, no auth).
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-chartmuseum
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: chartmuseum
  url: http://chartmuseum.chartmuseum.svc:8080
EOF
wait_for "chartmuseum repo registered in Argo CD" 60 \
  bash -c "argocd --config '$ARGOCD_CONFIG' --argocd-context '$KUBE_CONTEXT' repo list -o url | grep -qx 'http://chartmuseum.chartmuseum.svc:8080'"
info "repo http://chartmuseum.chartmuseum.svc:8080 registered"

step "Setup complete. Next: poc/build.sh"
