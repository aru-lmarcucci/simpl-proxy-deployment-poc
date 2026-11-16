#!/usr/bin/env bash
# G1: greenfield, first sync of proxy-green (chart 2.0.0). The job generates the CA in OpenBao,
# the proxy pods load it from env. The PVC stays empty and only the job mounts it.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-green

step "G1: create and sync $NS (chart 2.0.0)"
k apply -f "$POC_DIR/argocd/app-green.yaml" >/dev/null
assert_sync "$NS"
wait_deploy_ready "$NS" || true

info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|RESULT|FINGERPRINT)' | tr '\n' '|')"
assert_eq "job RESULT" "ca-generated" "$(job_result "$NS")"
fp="$(job_fingerprint "$NS")"
assert_ne "job printed a fingerprint" "" "$fp"

secret="$(secret_summary "$NS")"
info "evidence secret: $secret"
assert_cmd "secret in OpenBao has data" jq -e '.key_len > 0 and .cert_len > 0' <<<"$secret"

assert_eq "Deployment: 2 ready replicas" "2" "$(k -n "$NS" get deploy proxy -o jsonpath='{.status.readyReplicas}')"
assert_pods_ca "$NS" env "$fp"
pod="$(proxy_pods "$NS" | head -n1)"
info "evidence injected env ($pod): $(injected_env "$NS" "$pod")"

assert_eq "PVC proxy-certs Bound" "Bound" "$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.status.phase}')"
assert_contains "job: PVC proxy-certs has no CA" "$(job_logs "$NS")" "legacy volume: absent"
assert_eq "Deployment mounts no PVC" "" "$(deploy_pvcs "$NS")"

state_set FP_GREEN "$fp"
assert_summary
