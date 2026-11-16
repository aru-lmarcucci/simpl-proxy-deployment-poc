#!/usr/bin/env bash
# E3: secret with private_key set and certificate empty. The proxy fails (partial configuration).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e3

step "E3: partial secret"
err_cleanup "$NS"
err_setup "$NS"
# Dummy value (base64 of "PLACEHOLDER"): the error is raised before decoding.
secret_write "$NS" 0 "UExBQ0VIT0xERVI=" ""
info "evidence secret: $(secret_summary "$NS")"
app_create "$NS" "$NS" 2.0.0
app_sync_async "$NS" "$NS"
info "evidence job: $(job_logs "$NS" | grep -E '^(WARN|RESULT)' | tr '\n' '|')"
assert_eq "job RESULT" "noop" "$(job_result "$NS")"
assert_contains "job warns about the partial secret" "$(job_logs "$NS")" "partial configuration"

wait_for "proxy pods in CrashLoopBackOff" 240 crashlooping "$NS"
assert_cmd "proxy pods in CrashLoopBackOff" crashlooping "$NS"
info "evidence proxy log: $(proxy_logs "$NS" | grep -m1 '^ERROR')"
assert_cmd "proxy log: partial configuration" proxy_logs_contain "$NS" "partial configuration: ROOT_CA_PRIVATE_KEY is set but ROOT_CA_CERTIFICATE is empty"

err_cleanup "$NS"
assert_summary
