#!/usr/bin/env bash
# B3: after the migration the legacy volume is no longer needed. The CA is removed from the PVC:
# the job does not regenerate anything and the proxy, restarted, keeps the same CA from OpenBao.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"

step "B3: CA removed from the PVC after the migration"
info "evidence PVC content after wipe: $(wipe_volume_ca "$NS")"
assert_sync "$NS"
info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|WARN|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_contains "job sees no CA on the volume" "$(job_logs "$NS")" "legacy volume: absent"
assert_not_contains "job: no warning" "$(job_logs "$NS")" "WARN"
assert_eq "secret version unchanged" "$(state_get SECRET_VERSION_B1)" "$(secret_version "$NS")"

k -n "$NS" rollout restart deploy/proxy >/dev/null
wait_deploy_ready "$NS"
assert_pods_ca "$NS" env "$FP"
assert_summary
