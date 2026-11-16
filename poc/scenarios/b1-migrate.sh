#!/usr/bin/env bash
# B1: brownfield migration. proxy-brown moves to chart 2.0.0 with prune. The job writes an empty
# placeholder, the PVC is kept (same UID) and the proxy loads the legacy CA from the volume.
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

info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "placeholder-created" "$(job_result "$NS")"
secret="$(secret_summary "$NS")"
info "evidence secret: $secret"
assert_cmd "secret values are empty" jq -e '.key_len == 0 and .cert_len == 0' <<<"$secret"
state_set SECRET_VERSION_B1 "$(jq -r .version <<<"$secret")"

assert_cmd_fails "StatefulSet pruned" k -n "$NS" get statefulset proxy
assert_cmd_fails "headless Service pruned" k -n "$NS" get service proxy-headless
assert_cmd "Service proxy still there" k -n "$NS" get service proxy
assert_eq "PVC kept, same UID" "$PVC_UID" "$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.metadata.uid}')"

# Injection with empty KV values (docs/plan.md §5): must be empty or absent, never the literal ref.
for pod in $(proxy_pods "$NS"); do
  env_state="$(injected_env "$NS" "$pod")" || env_state="{}"
  info "evidence injected env ($pod): $env_state"
  assert_cmd "$pod: injected env empty or absent" \
    jq -e 'to_entries | all(.value == 0 or .value == "absent")' <<<"$env_state"
done

assert_pods_ca "$NS" legacy-volume "$FP"
pod="$(proxy_pods "$NS" | head -n1)"
if write_err="$(k -n "$NS" exec "$pod" -c proxy -- touch /app/certs/b1-write-test 2>&1)"; then
  write_err="WRITE SUCCEEDED"
fi
write_err="$(head -n1 <<<"$write_err")"
info "evidence write attempt on /app/certs: $write_err"
assert_contains "$pod: /app/certs is read-only" "$write_err" "Read-only file system"
assert_summary
