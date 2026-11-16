#!/usr/bin/env bash
# B1: brownfield migration. proxy-brown moves to chart 2.0.0 with prune. The job imports the CA
# from the legacy volume into OpenBao, the PVC is kept (same UID) and the proxy loads the same CA
# from env, without mounting the volume.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"
PVC_UID="$(state_get PVC_UID)"

step "B1: $NS targetRevision 2.0.0, sync with prune"
a app set "$NS" --revision 2.0.0 >/dev/null
ready_sampler_start "$NS"
assert_sync "$NS"
wait_deploy_ready "$NS" || true
sleep 3
read -r min_ready samples zero_ready < <(ready_sampler_stop)
info "evidence availability during the migration: min ready pods=$min_ready, samples=$samples, samples with 0 ready=$zero_ready"
assert_cmd "always at least one Ready proxy pod during the migration (PruneLast)" test "${min_ready:-0}" -ge 1

info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|importing|RESULT|FINGERPRINT)' | tr '\n' '|')"
assert_eq "job RESULT" "ca-imported" "$(job_result "$NS")"
assert_eq "job imported the legacy CA (fingerprint)" "$FP" "$(job_fingerprint "$NS")"
secret="$(secret_summary "$NS")"
info "evidence secret: $secret"
assert_cmd "secret in OpenBao has data" jq -e '.key_len > 0 and .cert_len > 0' <<<"$secret"
state_set SECRET_VERSION_B1 "$(jq -r .version <<<"$secret")"

assert_cmd_fails "StatefulSet pruned" k -n "$NS" get statefulset proxy
assert_cmd_fails "headless Service pruned" k -n "$NS" get service proxy-headless
assert_cmd "Service proxy still there" k -n "$NS" get service proxy
assert_eq "PVC kept, same UID" "$PVC_UID" "$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.metadata.uid}')"
assert_eq "Deployment mounts no PVC" "" "$(deploy_pvcs "$NS")"

for pod in $(proxy_pods "$NS"); do
  env_state="$(injected_env "$NS" "$pod")" || env_state="{}"
  info "evidence injected env ($pod): $env_state"
  assert_cmd "$pod: injected env has values" jq -e 'to_entries | all(.value | type == "number" and . > 0)' <<<"$env_state"
done

assert_pods_ca "$NS" env "$FP"
assert_summary
