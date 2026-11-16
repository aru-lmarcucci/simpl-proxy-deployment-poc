#!/usr/bin/env bash
# B0: brownfield starting point. proxy-brown on the legacy chart 1.0.0 (StatefulSet): the CA is
# generated on the shared PVC. Saves FP_LEGACY and PVC_UID for the next scenarios.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown

step "B0: sync $NS with the legacy chart 1.0.0"
k apply -f "$POC_DIR/argocd/app-brown.yaml" >/dev/null
assert_sync "$NS"
k -n "$NS" rollout status statefulset/proxy --timeout=300s >/dev/null || true
assert_eq "StatefulSet: 2 ready replicas" "2" "$(k -n "$NS" get statefulset proxy -o jsonpath='{.status.readyReplicas}')"

ca0="$(http_get "$NS" proxy-0 /ca)" || ca0="{}"
fp="$(jq -r .fingerprint_sha256 <<<"$ca0")"
info "evidence proxy-0: $(root_ca_log "$NS" proxy-0)"
info "evidence proxy-1: $(root_ca_log "$NS" proxy-1)"
assert_eq "proxy-0 generated the CA" "generated" "$(jq -r .source <<<"$ca0")"
assert_eq "proxy-1 loaded the same CA from the volume" "legacy-volume $fp" \
  "$(http_get "$NS" proxy-1 /ca | jq -r '.source + " " + .fingerprint_sha256')"
assert_eq "CA files on the PVC" "certificate.pem private-key.pem" \
  "$(k -n "$NS" exec proxy-0 -c proxy -- ls /app/certs/_ca | sort | tr '\n' ' ' | sed 's/ $//')"

issued="$(http_get "$NS" proxy-0 "/issue?host=b.example")" || issued="{}"
assert_eq "leaf b.example issued on the shared volume" "/app/certs/b.example/cert.pem" "$(jq -r .path <<<"$issued")"

pvc_uid="$(k -n "$NS" get pvc proxy-certs -o jsonpath='{.metadata.uid}')"
info "evidence FP_LEGACY=$fp PVC_UID=$pvc_uid"
assert_eq "no secret in OpenBao" "absent" "$(secret_summary "$NS")"

state_set FP_LEGACY "$fp"
state_set PVC_UID "$pvc_uid"
assert_summary
