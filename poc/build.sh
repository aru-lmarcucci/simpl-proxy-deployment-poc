#!/usr/bin/env bash
# Builds the stub and job images, loads them into kind and publishes both charts on ChartMuseum
# (docs/plan.md §4.7). An already published version is deleted and uploaded again.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

require_context
require_tools docker kind helm curl jq

step "Offline chart checks"
"$POC_DIR/check-charts.sh" >"$(tmp_dir)/check-charts.log" 2>&1 \
  || { cat "$(tmp_dir)/check-charts.log"; die "chart checks failed"; }
info "OK"

step "Building images"
docker build -q --build-arg PYTHON_IMAGE="$PYTHON_IMAGE" -t proxy-stub:poc "$REPO_ROOT/app" >/dev/null
docker build -q --build-arg ALPINE_IMAGE="$ALPINE_IMAGE" -t proxy-ca-init:poc "$REPO_ROOT/job" >/dev/null
info "proxy-stub:poc, proxy-ca-init:poc"

step "Loading images into kind"
kind load docker-image proxy-stub:poc proxy-ca-init:poc --name "$CLUSTER_NAME" >/dev/null
info "OK"

step "Publishing charts on ChartMuseum"
pkg_dir="$(tmp_dir)/charts"
mkdir -p "$pkg_dir"
port_forward chartmuseum svc/chartmuseum 8080
cm="http://127.0.0.1:$PF_PORT"
for chart in proxy-legacy proxy; do
  tgz="$(helm package "$REPO_ROOT/charts/$chart" -d "$pkg_dir" | sed -n 's/^Successfully packaged chart and saved it to: //p')"
  name="$(helm show chart "$tgz" | sed -n 's/^name: //p')"
  version="$(helm show chart "$tgz" | sed -n 's/^version: //p')"
  curl -fsS -o /dev/null -X DELETE "$cm/api/charts/$name/$version" 2>/dev/null || true
  status="$(curl -sS -o "$pkg_dir/resp" -w '%{http_code}' --data-binary "@$tgz" "$cm/api/charts")"
  [[ "$status" == 201 ]] || die "upload of $name-$version failed: HTTP $status $(cat "$pkg_dir/resp")"
  info "$name $version ($chart)"
done
published="$(curl -fsS "$cm/api/charts/proxy" | jq -r '[.[].version] | sort | join(", ")')"
info "ChartMuseum now serves proxy: $published"

step "Build complete. Argo CD caches charts by version: hard-refresh the apps before syncing."
