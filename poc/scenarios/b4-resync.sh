#!/usr/bin/env bash
# B4: sync after the migration. The job must not touch the secret (no emptying).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"

step "B4: sync $NS after the migration"
assert_sync "$NS"
wait_deploy_ready "$NS" || true
info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|WARN|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_contains "job warns that OpenBao wins over the volume" "$(job_logs "$NS")" "the proxy will use the CA from OpenBao"
secret="$(secret_summary "$NS")"
info "evidence secret: $secret"
assert_eq "secret version unchanged" "$(state_get SECRET_VERSION_B3)" "$(jq -r .version <<<"$secret")"
assert_cmd "secret not emptied" jq -e '.key_len > 0 and .cert_len > 0' <<<"$secret"
assert_pods_ca "$NS" env "$FP"
assert_summary
