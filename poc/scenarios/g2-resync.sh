#!/usr/bin/env bash
# G2: greenfield, second sync. The job finds the secret and does nothing.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-green
FP="$(state_get FP_GREEN)"

step "G2: sync $NS again"
version_before="$(secret_version "$NS")"
assert_sync "$NS"
wait_deploy_ready "$NS" || true
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_eq "secret version unchanged" "$version_before" "$(secret_version "$NS")"
assert_pods_ca "$NS" env "$FP"
assert_summary
