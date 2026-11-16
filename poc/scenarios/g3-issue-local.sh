#!/usr/bin/env bash
# G3: leaf certificates are local to each instance (emptyDir).
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
NS=proxy-green

step "G3: issue a.example on pod 1, list certificates on both pods"
mapfile -t pods < <(proxy_pods "$NS")
assert_eq "2 running pods" "2" "${#pods[@]}"
issued="$(http_get "$NS" "${pods[0]}" "/issue?host=a.example")" || issued="{}"
info "evidence issue on ${pods[0]}: $issued"
assert_eq "certificate issued on pod 1" "a.example" "$(jq -r .host <<<"$issued")"
assert_eq "leaf written under /app/certs (emptyDir)" "/app/certs/a.example/cert.pem" "$(jq -r .path <<<"$issued")"
assert_eq "pod 1 (${pods[0]}) has a.example" '["a.example"]' "$(http_get "$NS" "${pods[0]}" /certs | jq -c .)"
assert_eq "pod 2 (${pods[1]}) has no certificates" '[]' "$(http_get "$NS" "${pods[1]}" /certs | jq -c .)"
assert_summary
