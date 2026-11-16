#!/usr/bin/env bash
# E1: brownfield with the empty placeholder, then the CA disappears from the PVC (e.g. lost
# volume). The job must not regenerate a CA; the proxy must fail.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e1

step "E1: placeholder secret, CA removed from the PVC"
err_cleanup "$NS"
err_setup "$NS"
app_create "$NS" "$NS" 1.0.0
assert_sync "$NS"
k -n "$NS" rollout status statefulset/proxy --timeout=300s >/dev/null
a app set "$NS" --revision 2.0.0 >/dev/null
assert_sync "$NS"
wait_deploy_ready "$NS"
assert_eq "brownfield placeholder created" "placeholder-created" "$(job_result "$NS")"

info "scaling the Deployment to 0 and wiping _ca with a RW service pod"
k -n "$NS" scale deploy/proxy --replicas=0 >/dev/null
wait_for "no proxy pods in $NS" 180 no_proxy_pods "$NS"
k -n "$NS" run wipe-ca --image=proxy-stub:poc --image-pull-policy=IfNotPresent --restart=Never \
  --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":10001,"runAsGroup":10001},
    "containers":[{"name":"wipe-ca","image":"proxy-stub:poc","command":["sh","-c","rm -r /certs/_ca && ls -A /certs"],
    "volumeMounts":[{"name":"certs","mountPath":"/certs"}]}],
    "volumes":[{"name":"certs","persistentVolumeClaim":{"claimName":"proxy-certs"}}]}}' >/dev/null
k -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/wipe-ca --timeout=120s >/dev/null
info "evidence PVC content after wipe: $(k -n "$NS" logs wipe-ca | tr '\n' ' ')"
k -n "$NS" delete pod wipe-ca --wait=false >/dev/null

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
