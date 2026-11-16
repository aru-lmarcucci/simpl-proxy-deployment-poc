#!/usr/bin/env bash
# E1: the secret exists with empty values (e.g. created by hand) and there is no CA on the PVC.
# The job must not regenerate a CA (it cannot overwrite anyway); the proxy must fail.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e1

step "E1: secret with empty values, no CA on the PVC"
err_cleanup "$NS"
err_setup "$NS"
secret_write "$NS" 0 "" ""
info "evidence secret: $(secret_summary "$NS")"
app_create "$NS" "$NS" 2.0.0
app_sync_async "$NS" "$NS"
info "evidence job: $(job_logs "$NS" | grep -E '^(legacy volume|WARN|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_contains "job warns that the proxy will fail" "$(job_logs "$NS")" "the proxy will fail"
assert_eq "secret still empty (no regeneration)" '{"version":1,"key_len":0,"cert_len":0}' "$(secret_summary "$NS")"

wait_for "proxy pods in CrashLoopBackOff" 240 crashlooping "$NS"
assert_cmd "proxy pods in CrashLoopBackOff" crashlooping "$NS"
info "evidence proxy log: $(proxy_logs "$NS" | grep -m1 '^ERROR')"
assert_cmd "proxy log: no root CA available" proxy_logs_contain "$NS" "no root CA available"

err_cleanup "$NS"
assert_summary
