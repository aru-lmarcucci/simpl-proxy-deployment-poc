#!/usr/bin/env bash
# G5: rollout restart. Same CA, leaf certificates gone (ephemeral).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-green
FP="$(state_get FP_GREEN)"

step "G5: rollout restart of $NS"
for pod in $(proxy_pods "$NS"); do http_get "$NS" "$pod" "/issue?host=g5.example" >/dev/null; done
k -n "$NS" rollout restart deploy/proxy >/dev/null
wait_deploy_ready "$NS"
assert_pods_ca "$NS" env "$FP"
for pod in $(proxy_pods "$NS"); do
  assert_eq "$pod: no leaf certificates" '[]' "$(http_get "$NS" "$pod" /certs | jq -c .)"
done
assert_summary
