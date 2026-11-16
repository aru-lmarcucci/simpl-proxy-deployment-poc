#!/usr/bin/env bash
# E2: only private-key.pem left on the PVC. The job fails, the sync fails, the Deployment is not
# created and, thanks to PruneLast, the legacy StatefulSet is not pruned and keeps serving.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e2

step "E2: incomplete CA on the legacy volume"
err_cleanup "$NS"
err_setup "$NS"
app_create "$NS" "$NS" 1.0.0
assert_sync "$NS"
k -n "$NS" rollout status statefulset/proxy --timeout=300s >/dev/null
k -n "$NS" exec proxy-0 -c proxy -- rm /app/certs/_ca/certificate.pem
info "evidence PVC _ca after removal: $(k -n "$NS" exec proxy-0 -c proxy -- ls /app/certs/_ca | tr '\n' ' ')"

a app set "$NS" --revision 2.0.0 >/dev/null
assert_sync_fails "$NS"
phase="$(app_phase "$NS")"
info "evidence sync: phase=$phase message=$(app_message "$NS")"
info "evidence job: $(job_logs "$NS" | grep -E '^(ERROR|RESULT)' | sort -u | tr '\n' '|')"
assert_cmd "sync phase Failed or Error ($phase)" grep -qxE 'Failed|Error' <<<"$phase"
assert_contains "job error: incomplete CA" "$(job_logs "$NS")" "incomplete CA on legacy volume"
assert_cmd_fails "Deployment not created" k -n "$NS" get deploy proxy
assert_eq "legacy StatefulSet still serving (PruneLast): ready replicas" "2" \
  "$(k -n "$NS" get statefulset proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
assert_eq "no secret written" "absent" "$(secret_summary "$NS")"

err_cleanup "$NS"
assert_summary
