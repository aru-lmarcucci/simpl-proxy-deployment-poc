#!/usr/bin/env bash
# E5: with the job's own OpenBao role, overwriting an existing secret is denied (no "update").
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e5

step "E5: the init role cannot overwrite an existing secret"
err_cleanup "$NS"
err_setup "$NS"
k create namespace "$NS" >/dev/null
k -n "$NS" create serviceaccount proxy-ca-init >/dev/null
secret_write "$NS" 0 "b3JpZ2luYWw=" "b3JpZ2luYWw="
version_before="$(secret_version "$NS")"

# Runs in the cluster with the proxy-ca-init service account; prints HTTP codes only.
cat >"$(tmp_dir)/e5-probe.sh" <<'PROBE'
set -euo pipefail
api="http://openbao.openbao.svc:8200/v1"
path="$api/secret/data/proxy/$NS/root-ca"
jq -n --arg role "proxy-ca-init-$NS" --rawfile jwt /var/run/secrets/kubernetes.io/serviceaccount/token \
  '{role: $role, jwt: ($jwt | rtrimstr("\n"))}' >/tmp/login.json
curl -sS -X POST --data-binary @/tmp/login.json "$api/auth/kubernetes/login" \
  | jq -r '"X-Vault-Token: " + .auth.client_token' >/tmp/h
code() { curl -sS -o /dev/null -w '%{http_code}' -H @/tmp/h "$@"; }
echo "read=$(code "$path")"
echo "write-cas=$(code -X POST -d '{"options":{"cas":1},"data":{"private_key":"x","certificate":"y"}}' "$path")"
echo "write-nocas=$(code -X POST -d '{"data":{"private_key":"x","certificate":"y"}}' "$path")"
PROBE
k -n "$NS" run e5-probe --image=proxy-ca-init:poc --image-pull-policy=IfNotPresent --restart=Never \
  --env="NS=$NS" --overrides='{"apiVersion":"v1","spec":{"serviceAccountName":"proxy-ca-init"}}' \
  --command -- bash -c "$(cat "$(tmp_dir)/e5-probe.sh")" >/dev/null
k -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/e5-probe --timeout=120s >/dev/null || true
out="$(k -n "$NS" logs e5-probe)"
info "evidence: $(tr '\n' ' ' <<<"$out")"
assert_contains "read allowed (200)" "$out" "read=200"
assert_contains "overwrite with cas denied (403)" "$out" "write-cas=403"
assert_contains "overwrite without cas denied (403)" "$out" "write-nocas=403"
assert_eq "secret version unchanged" "$version_before" "$(secret_version "$NS")"

err_cleanup "$NS"
assert_summary
