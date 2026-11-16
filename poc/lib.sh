# shellcheck shell=bash
# Common helpers for the PoC scripts. Source it, do not execute it:
#
#   source "$(dirname "$0")/lib.sh"          # from poc/
#   source "$(dirname "$0")/../lib.sh"       # from poc/scenarios/
#
# Every script must call require_context before touching the cluster
# (setup.sh calls it right after creating the cluster).

set -euo pipefail

POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$POC_DIR/.." && pwd)"
export POC_DIR REPO_ROOT

# shellcheck source-path=SCRIPTDIR source=versions.env
source "$POC_DIR/versions.env"

CLUSTER_NAME="proxy-poc"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

step() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cluster guard and tool wrappers
# ---------------------------------------------------------------------------

# Fails unless the kind context exists and points to a local kind cluster.
# Never rely on the implicit current-context: real clusters may be configured.
require_context() {
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" \
    || die "kube context '$KUBE_CONTEXT' not found. Run poc/setup.sh first."

  local cluster server
  cluster="$(kubectl config view -o "jsonpath={.contexts[?(@.name==\"$KUBE_CONTEXT\")].context.cluster}")"
  [[ "$cluster" == "$KUBE_CONTEXT" ]] \
    || die "context '$KUBE_CONTEXT' points to cluster '$cluster', expected '$KUBE_CONTEXT'."

  server="$(kubectl config view -o "jsonpath={.clusters[?(@.name==\"$cluster\")].cluster.server}")"
  [[ "$server" =~ ^https://(127\.0\.0\.1|localhost|\[::1\]): ]] \
    || die "context '$KUBE_CONTEXT' points to '$server', which is not a local kind cluster."

  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    || die "kind cluster '$CLUSTER_NAME' not found. Run poc/setup.sh first."
}

# Always pass the context explicitly.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
h() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

# Fails listing every missing command.
require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Assertions: print OK/FAIL and keep going; call assert_summary at the end.
# Never pass secrets as arguments: values are printed on failure.
# ---------------------------------------------------------------------------

ASSERT_PASSED=0
ASSERT_FAILED=0

_ok()   { ASSERT_PASSED=$((ASSERT_PASSED + 1)); printf 'OK   %s\n' "$1"; }
_fail() { ASSERT_FAILED=$((ASSERT_FAILED + 1)); printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '     %s\n' "$2"; }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then _ok "$1"; else _fail "$1" "expected '$2', got '$3'"; fi
}

# assert_ne <description> <unexpected> <actual>
assert_ne() {
  if [[ "$2" != "$3" ]]; then _ok "$1"; else _fail "$1" "got unexpected '$3'"; fi
}

# assert_contains <description> <haystack> <needle>
# The haystack (often a log) is not printed on failure.
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then _ok "$1"; else _fail "$1" "'$3' not found"; fi
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then _ok "$1"; else _fail "$1" "'$3' found"; fi
}

# assert_cmd <description> <command...>: OK if the command succeeds.
assert_cmd() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then _ok "$desc"; else _fail "$desc" "command failed: $*"; fi
}

# assert_cmd_fails <description> <command...>: OK if the command fails.
assert_cmd_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then _fail "$desc" "command succeeded: $*"; else _ok "$desc"; fi
}

# Prints the totals and returns non-zero if any assertion failed.
assert_summary() {
  printf -- '--- %d passed, %d failed\n' "$ASSERT_PASSED" "$ASSERT_FAILED"
  ((ASSERT_FAILED == 0))
}

# ---------------------------------------------------------------------------
# Cleanup and port-forwards
# ---------------------------------------------------------------------------

_CLEANUPS=()
_PF_PIDS=()
# Created eagerly: tmp_dir is often called in $(...), where a lazy init would be lost.
_TMP_DIR="$(mktemp -d)"

# add_cleanup <command string>: run on exit, in reverse order.
add_cleanup() { _CLEANUPS+=("$1"); }

_run_cleanups() {
  local i pid
  for ((i = ${#_CLEANUPS[@]} - 1; i >= 0; i--)); do
    eval "${_CLEANUPS[$i]}" || true
  done
  for pid in "${_PF_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -z "$_TMP_DIR" ]] || rm -rf "$_TMP_DIR"
}
trap _run_cleanups EXIT

# Private temp dir for this script run, removed on exit.
tmp_dir() {
  printf '%s\n' "$_TMP_DIR"
}

# port_forward <namespace> <target> <remote port>
# Starts a background port-forward on a free local port and sets PF_PORT.
# Do not call it in a subshell ($(...)): the forward would die with it.
# Example: port_forward argocd svc/argocd-server 443; curl -k "https://127.0.0.1:$PF_PORT"
port_forward() {
  local ns="$1" target="$2" rport="$3" log pid port="" i
  log="$(mktemp "$(tmp_dir)/pf.XXXXXX")"
  # kubectl directly, not the k() wrapper: $! must be the kubectl PID, not a subshell's.
  kubectl --context "$KUBE_CONTEXT" -n "$ns" port-forward "$target" ":$rport" >"$log" 2>&1 &
  pid=$!
  _PF_PIDS+=("$pid")
  for ((i = 0; i < 60; i++)); do
    port="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$log" | head -n1)"
    [[ -z "$port" ]] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [[ -z "$port" ]]; then
    cat "$log" >&2
    die "port-forward to $ns/$target:$rport failed"
  fi
  # shellcheck disable=SC2034 # read by the caller
  PF_PORT="$port"
}

# ---------------------------------------------------------------------------
# Argo CD CLI: isolated config (never ~/.config/argocd), context named after the kube context.
# ---------------------------------------------------------------------------

ARGOCD_CONFIG="$_TMP_DIR/argocd-config"

# Logs in through a port-forward to argocd-server with the initial admin password.
argocd_login() {
  local password
  port_forward argocd svc/argocd-server 443
  password="$(k -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  argocd --config "$ARGOCD_CONFIG" login "127.0.0.1:$PF_PORT" --name "$KUBE_CONTEXT" \
    --username admin --password "$password" --insecure --grpc-web >/dev/null
}

# Always targets the PoC Argo CD (call argocd_login first).
a() { argocd --config "$ARGOCD_CONFIG" --argocd-context "$KUBE_CONTEXT" "$@"; }

# wait_for <description> <timeout seconds> <command...>: retries until the command succeeds.
wait_for() {
  local desc="$1" timeout="$2" start=$SECONDS; shift 2
  until "$@" >/dev/null 2>&1; do
    ((SECONDS - start < timeout)) || die "timeout after ${timeout}s waiting for: $desc"
    sleep 2
  done
}

# bao CLI inside the OpenBao dev pod with the dev root token. PoC setup and test support only:
# the job and the proxy never use it. Pass secret values via stdin, never as arguments.
bao_root() { k -n openbao exec -i openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao "$@"; }
