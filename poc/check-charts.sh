#!/usr/bin/env bash
# Offline chart checks (no cluster): helm lint, helm template, and the PVC spec diff between the
# legacy chart and the new one. The PVC spec must be identical: accessModes, storageClassName,
# volumeName and selector are immutable, so any difference breaks the brownfield sync.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools helm diff

LEGACY="$REPO_ROOT/charts/proxy-legacy"
NEW="$REPO_ROOT/charts/proxy"
NS=proxy-check
OUT="$(tmp_dir)"

step "helm lint"
helm lint --strict "$LEGACY" "$NEW" >"$OUT/lint.log" 2>&1 || { cat "$OUT/lint.log"; die "helm lint failed"; }
assert_cmd "helm lint --strict (both charts)" true

step "helm template"
assert_cmd "legacy chart renders" helm template proxy "$LEGACY" -n "$NS"
assert_cmd "new chart renders" helm template proxy "$NEW" -n "$NS"
assert_cmd "new chart renders without PVC (E6)" helm template proxy "$NEW" -n "$NS" --set legacyCerts.renderPvc=false

new_manifest="$(helm template proxy "$NEW" -n "$NS")"
assert_contains "secret path defaults to the release namespace" "$new_manifest" \
  "vault:secret/data/proxy/$NS/root-ca#private_key"
assert_contains "init role defaults to proxy-ca-init-<ns>" "$new_manifest" "proxy-ca-init-$NS"
assert_contains "proxy role defaults to proxy-<ns>" "$new_manifest" "vault-role: \"proxy-$NS\""
assert_not_contains "no PVC when renderPvc=false" \
  "$(helm template proxy "$NEW" -n "$NS" --set legacyCerts.renderPvc=false)" "kind: PersistentVolumeClaim"

# pvc_spec <chart> [helm args...]: the rendered PVC from "spec:" on.
pvc_spec() {
  local chart="$1"; shift
  helm template proxy "$chart" -n "$NS" --show-only templates/pvc.yaml "$@" | sed -n '/^spec:/,$p'
}

# check_pvc <label> <legacy values...> -- <new values...>
check_pvc() {
  local label="$1"; shift
  local legacy_args=() new_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do legacy_args+=("$1"); shift; done
  shift || true
  new_args=("$@")
  pvc_spec "$LEGACY" "${legacy_args[@]}" >"$OUT/legacy.yaml"
  pvc_spec "$NEW" "${new_args[@]}" >"$OUT/new.yaml"
  if diff -u "$OUT/legacy.yaml" "$OUT/new.yaml" >"$OUT/pvc.diff"; then
    assert_eq "PVC spec identical ($label)" "" ""
  else
    assert_eq "PVC spec identical ($label)" "no diff" "$(cat "$OUT/pvc.diff")"
  fi
}

step "PVC spec: legacy vs new"
check_pvc "chart defaults"
check_pvc "kind values (standard, RWO)" \
  --set persistence.storageClassName=standard --set "persistence.accessModes={ReadWriteOnce}" -- \
  --set legacyCerts.storageClassName=standard --set "legacyCerts.accessModes={ReadWriteOnce}"
assert_eq "PVC name identical" \
  "$(helm template proxy "$LEGACY" -n "$NS" --show-only templates/pvc.yaml | sed -n 's/^  name: //p')" \
  "$(helm template proxy "$NEW" -n "$NS" --show-only templates/pvc.yaml | sed -n 's/^  name: //p')"

assert_summary
