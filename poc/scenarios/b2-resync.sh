#!/usr/bin/env bash
# B2: brownfield, second sync. The secret exists: the job does nothing.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"

step "B2: sync $NS again"
assert_sync "$NS"
wait_deploy_ready "$NS" || true
info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|WARN|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_not_contains "job: no warning" "$(job_logs "$NS")" "WARN"
assert_eq "secret version unchanged" "$(state_get SECRET_VERSION_B1)" "$(secret_version "$NS")"
assert_pods_ca "$NS" env "$FP"
assert_summary
