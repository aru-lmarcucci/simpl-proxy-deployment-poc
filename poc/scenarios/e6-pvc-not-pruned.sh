#!/usr/bin/env bash
# E6: the PVC disappears from the rendered chart and the sync runs with prune. The PVC must stay
# (Prune=false on the resource).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e6

step "E6: PVC removed from the chart, sync with prune"
err_cleanup "$NS"
err_setup "$NS"
app_create "$NS" "$NS" 2.0.0
assert_sync "$NS"
wait_deploy_ready "$NS"
pvc_uid="$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.metadata.uid}')"

a app set "$NS" --helm-set legacyCerts.renderPvc=false >/dev/null
assert_sync "$NS"
info "evidence Argo CD status of the PVC: $(a app get "$NS" -o json | jq -c '.status.resources[] | select(.kind == "PersistentVolumeClaim") | {status, requiresPruning}')"
assert_eq "PVC not pruned (same UID)" "$pvc_uid" "$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"

err_cleanup "$NS"
assert_summary
