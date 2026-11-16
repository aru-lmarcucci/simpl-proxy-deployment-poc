#!/usr/bin/env bash
# Brings the cluster back to the state expected by the first scenario, without recreating it:
# removes the PoC Applications, their namespaces and OpenBao secrets/roles, then recreates the
# roles for proxy-green and proxy-brown. Infra (OpenBao, webhook, Argo CD, ChartMuseum) is kept.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

require_context

step "Resetting scenario state"
mapfile -t apps < <(k -n argocd get applications -o name 2>/dev/null | sed -n 's|^application.argoproj.io/\(proxy-.*\)$|\1|p')
mapfile -t namespaces < <(k get namespaces -o name | sed -n 's|^namespace/\(proxy-.*\)$|\1|p')
for app in "${apps[@]}"; do
  k -n argocd delete application "$app" --wait=true >/dev/null
done
for ns in "${namespaces[@]}"; do
  k delete namespace "$ns" --wait=true --timeout=180s >/dev/null
done
for ns in proxy-green proxy-brown "${namespaces[@]}"; do
  "$POC_DIR/openbao-config.sh" --delete "$ns" >/dev/null 2>&1 || true
done
"$POC_DIR/openbao-config.sh" >/dev/null
rm -rf "${REPO_ROOT:?}/.tmp/scenarios"
info "removed applications: ${apps[*]:-none}; namespaces: ${namespaces[*]:-none}"
info "OpenBao roles recreated for proxy-green, proxy-brown"
