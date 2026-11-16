#!/usr/bin/env bash
# G4: scale to 0 and back to 2. Same CA, leaf certificates gone (ephemeral).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-green
FP="$(state_get FP_GREEN)"

step "G4: scale $NS to 0, then to 2"
pod="$(proxy_pods "$NS" | head -n1)"
http_get "$NS" "$pod" "/issue?host=g4.example" >/dev/null
k -n "$NS" scale deploy/proxy --replicas=0 >/dev/null
wait_for "no proxy pods in $NS" 180 no_proxy_pods "$NS"
info "scaled to 0"
k -n "$NS" scale deploy/proxy --replicas=2 >/dev/null
wait_deploy_ready "$NS"
assert_pods_ca "$NS" env "$FP"
for pod in $(proxy_pods "$NS"); do
  assert_eq "$pod: no leaf certificates" '[]' "$(http_get "$NS" "$pod" /certs | jq -c .)"
done
assert_summary
