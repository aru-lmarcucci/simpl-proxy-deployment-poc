#!/usr/bin/env bash
# B2: brownfield, second sync. The job leaves the placeholder alone.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"

step "B2: sync $NS again"
assert_sync "$NS"
wait_deploy_ready "$NS" || true
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_not_contains "job: no warning" "$(job_logs "$NS")" "WARN"
secret="$(secret_summary "$NS")"
assert_cmd "secret still empty" jq -e '.key_len == 0 and .cert_len == 0' <<<"$secret"
assert_eq "secret version unchanged" "$(state_get SECRET_VERSION_B1)" "$(jq -r .version <<<"$secret")"
assert_pods_ca "$NS" legacy-volume "$FP"
assert_summary
