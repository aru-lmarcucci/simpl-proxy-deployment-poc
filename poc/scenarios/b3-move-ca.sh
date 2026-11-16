#!/usr/bin/env bash
# B3: migration to OpenBao. Support step with the root token: copy the CA from the volume into
# the secret (cas on the current version), then restart. Same CA, now from env.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-brown
FP="$(state_get FP_LEGACY)"

step "B3: copy the volume CA into OpenBao, then rollout restart"
pod="$(proxy_pods "$NS" | head -n1)"
version="$(secret_version "$NS")"
# Values only in variables and stdin, never printed.
key_b64="$(k -n "$NS" exec "$pod" -c proxy -- cat /app/certs/_ca/private-key.pem | base64 | tr -d '\n')"
cert_b64="$(k -n "$NS" exec "$pod" -c proxy -- cat /app/certs/_ca/certificate.pem | base64 | tr -d '\n')"
assert_cmd "secret written with cas=$version" secret_write "$NS" "$version" "$key_b64" "$cert_b64"
unset key_b64 cert_b64
secret="$(secret_summary "$NS")"
info "evidence secret: $secret"
state_set SECRET_VERSION_B3 "$(jq -r .version <<<"$secret")"

k -n "$NS" rollout restart deploy/proxy >/dev/null
wait_deploy_ready "$NS"
assert_pods_ca "$NS" env "$FP"
assert_summary
