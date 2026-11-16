# shellcheck shell=bash
# Helpers shared by the scenarios (docs/plan.md §5). Source it from a scenario script:
#   source "$(dirname "$0")/common.sh"
# Never print secret values: helpers report versions, lengths and fingerprints only.

# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_context
argocd_login

STATE_DIR="$REPO_ROOT/.tmp/scenarios"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

PROXY_SELECTOR="app.kubernetes.io/name=proxy"

# --- state shared between scenarios (fingerprints, UIDs: no secrets) ----------

state_set() {
  local tmp="$STATE_FILE.tmp"
  grep -v "^$1=" "$STATE_FILE" >"$tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
}
state_get() { sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1; }

# --- Argo CD ----------------------------------------------------------------

# app_create <name> <namespace> <revision> [extra valuesObject YAML, indented by 8]
app_create() {
  local name="$1" ns="$2" rev="$3" extra="${4:-}"
  k apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://chartmuseum.chartmuseum.svc:8080
    chart: proxy
    targetRevision: $rev
    helm:
      releaseName: proxy
      valuesObject:
        persistence:
          storageClassName: standard
          accessModes: [ReadWriteOnce]
        legacyCerts:
          storageClassName: standard
          accessModes: [ReadWriteOnce]
$extra
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
EOF
}

# app_sync <app> [argocd sync args...]: hard refresh (charts are cached by version), then sync
# with prune. Returns the sync exit code; the CLI output goes to $STATE_DIR/<app>-sync.log.
app_sync() {
  local app="$1"; shift
  a app get "$app" --hard-refresh >/dev/null
  a app sync "$app" --prune --timeout 300 "$@" >"$STATE_DIR/$app-sync.log" 2>&1
}

# assert_sync <app>: the sync must succeed; on failure prints the tail of the CLI output.
assert_sync() {
  if app_sync "$@"; then
    _ok "sync $1"
  else
    _fail "sync $1" "$(tail -n 5 "$STATE_DIR/$1-sync.log" | tr '\n' ' ')"
  fi
}

# assert_sync_fails <app>: the sync is expected to fail.
assert_sync_fails() {
  if app_sync "$@"; then
    _fail "sync $1 fails" "sync succeeded"
  else
    _ok "sync $1 fails"
  fi
}

# app_sync_async <app> <ns>: for syncs whose pods are expected to crash. Deletes the previous
# hook Job first (as BeforeHookCreation would), starts the sync and waits for the new Job.
app_sync_async() {
  local app="$1" ns="$2"
  k -n "$ns" delete job proxy-ca-init --ignore-not-found --wait=true >/dev/null 2>&1 || true
  a app get "$app" --hard-refresh >/dev/null
  a app sync "$app" --prune --async >"$STATE_DIR/$app-sync.log" 2>&1
  wait_for "provisioning job of $app finished" 240 job_done "$ns"
}

# app_phase <app>: phase of the last sync operation (Succeeded, Failed, Error, Running).
app_phase() { k -n argocd get application "$1" -o jsonpath='{.status.operationState.phase}'; }
app_message() { k -n argocd get application "$1" -o jsonpath='{.status.operationState.message}'; }

# --- availability sampling ---------------------------------------------------

# ready_sampler_start <ns>: samples the number of Ready proxy pods about once per second.
ready_sampler_start() {
  READY_LOG="$STATE_DIR/$1-ready.log"
  : >"$READY_LOG"
  (
    while true; do
      k -n "$1" get pods -l "$PROXY_SELECTOR" -o json 2>/dev/null \
        | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length' \
        >>"$READY_LOG" || true
      sleep 1
    done
  ) &
  READY_SAMPLER_PID=$!
}

# ready_sampler_stop: stops the sampler and prints "<min ready> <samples> <samples with 0 ready>".
ready_sampler_stop() {
  kill "$READY_SAMPLER_PID" 2>/dev/null || true
  wait "$READY_SAMPLER_PID" 2>/dev/null || true
  printf '%s %s %s\n' "$(sort -n "$READY_LOG" | head -n1)" "$(wc -l <"$READY_LOG" | tr -d ' ')" "$(grep -cx 0 "$READY_LOG" || true)"
}

# --- provisioning job -------------------------------------------------------

job_logs() { k -n "$1" logs job/proxy-ca-init --tail=-1 2>/dev/null || true; }
job_result() { job_logs "$1" | sed -n 's/^RESULT: //p' | tail -n1; }
job_fingerprint() { job_logs "$1" | sed -n 's/^FINGERPRINT_SHA256: //p' | tail -n1; }
job_done() { [[ -n "$(k -n "$1" get job proxy-ca-init -o jsonpath='{.status.completionTime}{.status.failed}' 2>/dev/null)" ]]; }

# --- OpenBao (root token, test support only) ----------------------------------

secret_path() { printf 'secret/data/proxy/%s/root-ca' "$1"; }

# secret_summary <ns>: "absent" or {"version":N,"key_len":N,"cert_len":N}.
secret_summary() {
  local out
  if ! out="$(bao_root read -format=json "$(secret_path "$1")" 2>/dev/null)"; then
    echo absent
    return
  fi
  jq -c '{version: .data.metadata.version,
          key_len: (.data.data.private_key // "" | length),
          cert_len: (.data.data.certificate // "" | length)}' <<<"$out"
}
secret_version() { secret_summary "$1" | jq -r '.version // empty' 2>/dev/null || true; }

# secret_write <ns> <cas> <private_key b64> <certificate b64>: values travel via stdin only.
secret_write() {
  jq -n --argjson cas "$2" --arg k "$3" --arg c "$4" '{options: {cas: $cas}, data: {private_key: $k, certificate: $c}}' \
    | bao_root write -format=json "$(secret_path "$1")" - >/dev/null
}

# --- proxy pods ---------------------------------------------------------------

# proxy_pods <ns>: running, non-terminating proxy pods.
proxy_pods() {
  k -n "$1" get pods -l "$PROXY_SELECTOR" -o json \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running") | .metadata.name'
}
no_proxy_pods() { [[ -z "$(k -n "$1" get pods -l "$PROXY_SELECTOR" -o name)" ]]; }

# http_get <ns> <pod> <path>: GET on the stub from inside the pod (no curl in the image).
http_get() {
  k -n "$1" exec "$2" -c proxy -- python -c \
    'import sys, urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080" + sys.argv[1], timeout=10).read().decode())' \
    "$3"
}

# injected_env <pod ns> <pod>: what vault-env handed to the process (PID 1), as lengths only.
# "kubectl exec -- env" would show the pod spec values ("vault:..."), not the injected ones.
injected_env() {
  k -n "$1" exec "$2" -c proxy -- python -c '
import json
env = dict(l.split("=", 1) for l in open("/proc/1/environ").read().split("\0") if "=" in l)
out = {}
for name in ("ROOT_CA_PRIVATE_KEY", "ROOT_CA_CERTIFICATE"):
    v = env.get(name)
    out[name] = "absent" if v is None else ("literal-vault-ref" if v.startswith("vault:") else len(v))
print(json.dumps(out, sort_keys=True))'
}

# root_ca_log <ns> <pod>: the root_ca_loaded line of the pod log.
root_ca_log() { k -n "$1" logs "$2" -c proxy | grep -m1 '"root_ca_loaded"' || true; }

# assert_pods_ca <ns> <expected source> <expected fingerprint>: checks /ca on every pod.
assert_pods_ca() {
  local ns="$1" source="$2" fp="$3" pods pod ca
  pods="$(proxy_pods "$ns")"
  assert_ne "$ns: there are running proxy pods" "" "$pods"
  for pod in $pods; do
    ca="$(http_get "$ns" "$pod" /ca)" || ca="{}"
    assert_eq "$pod: source=$source" "$source" "$(jq -r .source <<<"$ca")"
    assert_eq "$pod: fingerprint" "$fp" "$(jq -r .fingerprint_sha256 <<<"$ca")"
    info "evidence $pod: $(root_ca_log "$ns" "$pod")"
  done
}

# deploy_pvcs <ns>: PVC claims mounted by the proxy Deployment (expected: none).
deploy_pvcs() {
  k -n "$1" get deploy proxy -o json \
    | jq -r '[.spec.template.spec.volumes[]? | .persistentVolumeClaim.claimName // empty] | join(" ")'
}

# wipe_volume_ca <ns>: removes _ca from the PVC with a RW service pod; prints what is left.
wipe_volume_ca() {
  k -n "$1" run wipe-ca --image=proxy-stub:poc --image-pull-policy=IfNotPresent --restart=Never \
    --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":10001,"runAsGroup":10001},
      "containers":[{"name":"wipe-ca","image":"proxy-stub:poc","command":["sh","-c","rm -r /certs/_ca && ls -A /certs"],
      "volumeMounts":[{"name":"certs","mountPath":"/certs"}]}],
      "volumes":[{"name":"certs","persistentVolumeClaim":{"claimName":"proxy-certs"}}]}}' >/dev/null
  k -n "$1" wait --for=jsonpath='{.status.phase}'=Succeeded pod/wipe-ca --timeout=120s >/dev/null
  k -n "$1" logs wipe-ca | tr '\n' ' '
  k -n "$1" delete pod wipe-ca --wait=false >/dev/null
}

# wait_deploy_ready <ns>: Deployment rolled out and all replicas ready.
wait_deploy_ready() { k -n "$1" rollout status deploy/proxy --timeout=300s >/dev/null; }

# proxy_logs <ns>: current and previous logs of every proxy pod (for crash assertions).
proxy_logs() {
  local pod
  for pod in $(k -n "$1" get pods -l "$PROXY_SELECTOR" -o name); do
    k -n "$1" logs "$pod" -c proxy --tail=50 2>/dev/null || true
    k -n "$1" logs "$pod" -c proxy --tail=50 --previous 2>/dev/null || true
  done
}
proxy_logs_contain() { proxy_logs "$1" | grep -qF -- "$2"; }

# crashlooping <ns>: at least one proxy pod waiting in CrashLoopBackOff.
crashlooping() {
  k -n "$1" get pods -l "$PROXY_SELECTOR" -o json \
    | jq -e '[.items[].status.containerStatuses[]? | select(.name == "proxy") | .state.waiting.reason] | index("CrashLoopBackOff")' >/dev/null
}

# --- temporary error namespaces -------------------------------------------------

# err_setup <ns>: OpenBao roles for <ns> (namespace and Application are created by the caller).
err_setup() { "$POC_DIR/openbao-config.sh" "$1" >/dev/null; }

# err_cleanup <ns>: Application, namespace and OpenBao configuration of <ns>.
err_cleanup() {
  local ns="$1"
  k -n argocd delete application "$ns" --ignore-not-found --wait=true >/dev/null
  k delete namespace "$ns" --ignore-not-found --wait=true --timeout=180s >/dev/null
  "$POC_DIR/openbao-config.sh" --delete "$ns" >/dev/null 2>&1 || true
  info "cleaned up $ns"
}
