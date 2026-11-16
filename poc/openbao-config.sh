#!/usr/bin/env bash
# Configures OpenBao for the PoC (docs/plan.md §4.3). Uses the dev-mode root token: setup only.
#
#   poc/openbao-config.sh                    # auth + KV + policies/roles for proxy-green, proxy-brown
#   poc/openbao-config.sh <ns>...            # policies/roles for the given namespaces
#   poc/openbao-config.sh --delete <ns>...   # removes policies, roles and the secret of <ns>
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

require_context

# bao CLI inside the dev server pod, as root (dev mode only).
bao() { bao_root "$@"; }

configure_base() {
  step "OpenBao: auth/kubernetes and KV v2 on secret/"
  if ! bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
    bao auth enable kubernetes >/dev/null
  fi
  # No reviewer JWT: OpenBao uses its own service account (chart authDelegator binding).
  bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

  local kv_version
  kv_version="$(bao secrets list -format=json | jq -r '."secret/".options.version // empty')"
  if [[ -z "$kv_version" ]]; then
    bao secrets enable -path=secret -version=2 kv >/dev/null
  elif [[ "$kv_version" != 2 ]]; then
    die "secret/ is mounted as KV v$kv_version, expected v2"
  fi
  info "auth/kubernetes and secret/ (KV v2) ready"
}

configure_namespace() {
  local ns="$1" path="secret/data/proxy/$1/root-ca"
  step "OpenBao: policies and roles for namespace $ns"
  # No "update": in KV v2 writing an existing secret needs it, so the job can never overwrite.
  bao policy write "proxy-ca-init-$ns" - >/dev/null <<EOF
path "$path" {
  capabilities = ["create", "read"]
}
EOF
  bao policy write "proxy-read-$ns" - >/dev/null <<EOF
path "$path" {
  capabilities = ["read"]
}
EOF
  bao write "auth/kubernetes/role/proxy-ca-init-$ns" \
    bound_service_account_names=proxy-ca-init bound_service_account_namespaces="$ns" \
    token_policies="proxy-ca-init-$ns" token_ttl=10m >/dev/null
  bao write "auth/kubernetes/role/proxy-$ns" \
    bound_service_account_names=proxy bound_service_account_namespaces="$ns" \
    token_policies="proxy-read-$ns" token_ttl=10m >/dev/null
  info "roles proxy-ca-init-$ns, proxy-$ns -> $path"
}

delete_namespace() {
  local ns="$1"
  step "OpenBao: removing configuration of namespace $ns"
  bao delete "auth/kubernetes/role/proxy-ca-init-$ns" >/dev/null
  bao delete "auth/kubernetes/role/proxy-$ns" >/dev/null
  bao policy delete "proxy-ca-init-$ns" >/dev/null
  bao policy delete "proxy-read-$ns" >/dev/null
  bao kv metadata delete "secret/proxy/$ns/root-ca" >/dev/null
  info "removed"
}

wait_for "OpenBao unsealed" 120 bao status

if [[ "${1:-}" == "--delete" ]]; then
  shift
  (($# > 0)) || die "usage: $0 --delete <namespace>..."
  for ns in "$@"; do delete_namespace "$ns"; done
  exit 0
fi

configure_base
if (($# == 0)); then set -- proxy-green proxy-brown; fi
for ns in "$@"; do configure_namespace "$ns"; done
