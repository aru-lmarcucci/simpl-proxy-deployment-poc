#!/usr/bin/env bash
# E7: like B1, but the new chart renders a different accessModes. The sync must fail on the
# immutable field: this documents the risk of a PVC spec drift between the two charts.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e7

step "E7: migration with a different accessModes"
err_cleanup "$NS"
err_setup "$NS"
app_create "$NS" "$NS" 1.0.0
assert_sync "$NS"
k -n "$NS" rollout status statefulset/proxy --timeout=300s >/dev/null

a app set "$NS" --revision 2.0.0 --helm-set 'legacyCerts.accessModes[0]=ReadWriteMany' >/dev/null
assert_sync_fails "$NS"
phase="$(app_phase "$NS")"
pvc_msg="$(k -n argocd get application "$NS" -o json \
  | jq -r '[.status.operationState.syncResult.resources[]? | select(.kind == "PersistentVolumeClaim") | .message] | join(" ")')"
info "evidence sync: phase=$phase"
info "evidence PVC result: $pvc_msg"
assert_cmd "sync phase Failed or Error ($phase)" grep -qxE 'Failed|Error' <<<"$phase"
assert_contains "PVC rejected as immutable" "$pvc_msg $(app_message "$NS")" "immutable"
assert_eq "legacy StatefulSet still serving (PruneLast): ready replicas" "2" \
  "$(k -n "$NS" get statefulset proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
assert_eq "PVC accessModes unchanged" '["ReadWriteOnce"]' "$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.spec.accessModes}')"

err_cleanup "$NS"
assert_summary
