#!/usr/bin/env bash
# E4: invalid secret contents. First invalid base64, then key and certificate that do not match.
# The proxy fails with a specific message and never logs the values.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-err-e4

step "E4a: invalid base64 in the secret"
err_cleanup "$NS"
err_setup "$NS"
marker="E4MARKER$RANDOM"
secret_write "$NS" 0 "not*base64*$marker" "also*not*base64*$marker"
app_create "$NS" "$NS" 2.0.0
app_sync_async "$NS" "$NS"
wait_for "proxy pods in CrashLoopBackOff" 240 crashlooping "$NS"
info "evidence proxy log: $(proxy_logs "$NS" | grep -m1 '^ERROR')"
assert_cmd "proxy log: invalid base64" proxy_logs_contain "$NS" "ROOT_CA_PRIVATE_KEY is not valid base64"
assert_not_contains "the value is not in the proxy logs" "$(proxy_logs "$NS")" "$marker"

step "E4b: key and certificate that do not match"
work="$(tmp_dir)/e4"
mkdir -p "$work"
for n in a b; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=E4 $n" \
    -addext "basicConstraints=critical,CA:TRUE" -keyout "$work/$n.key" -out "$work/$n.crt" 2>/dev/null
done
key_b64="$(base64 <"$work/a.key" | tr -d '\n')"
cert_b64="$(base64 <"$work/b.crt" | tr -d '\n')"
rm -f "${work:?}/a.key" "${work:?}/b.key"
secret_write "$NS" "$(secret_version "$NS")" "$key_b64" "$cert_b64"
key_probe="${key_b64:40:40}"
unset key_b64 cert_b64
k -n "$NS" rollout restart deploy/proxy >/dev/null
wait_for "proxy log: key does not match" 240 proxy_logs_contain "$NS" "does not match the certificate"
info "evidence proxy log: $(proxy_logs "$NS" | grep -m1 'does not match')"
assert_cmd "proxy log: key does not match the certificate" proxy_logs_contain "$NS" "root CA private key does not match the certificate"
logs="$(proxy_logs "$NS")"
assert_not_contains "no key material in the proxy logs" "$logs" "$key_probe"
assert_not_contains "no PEM in the proxy logs" "$logs" "PRIVATE KEY"

err_cleanup "$NS"
assert_summary
