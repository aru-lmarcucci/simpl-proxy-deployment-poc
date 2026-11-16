#!/usr/bin/env bash
# Runs every scenario in order (docs/plan.md §5) and prints a summary. Starts from a clean
# scenario state (reset.sh); requires setup.sh and build.sh. Logs: .tmp/scenario-logs/<id>.log
# shellcheck source-path=SCRIPTDIR source=../lib.sh
source "$(dirname "$0")/../lib.sh"

require_context

SCENARIOS=(
  g1-create-sync g2-resync g3-issue-local g4-scale g5-restart
  b0-legacy b1-migrate b2-resync b3-move-ca b4-resync
  e1-lost-volume-ca e2-incomplete-volume e3-partial-secret e4-invalid-secret
  e5-no-overwrite e6-pvc-not-pruned e7-immutable-pvc
)
LOG_DIR="$REPO_ROOT/.tmp/scenario-logs"
rm -rf "${LOG_DIR:?}"
mkdir -p "$LOG_DIR"

"$POC_DIR/scenarios/reset.sh"

results=()
failed=0
for s in "${SCENARIOS[@]}"; do
  id="$(tr '[:lower:]' '[:upper:]' <<<"${s%%-*}")"
  start=$SECONDS
  if "$POC_DIR/scenarios/$s.sh" 2>&1 | tee "$LOG_DIR/$id.log"; then
    status=PASS
  else
    status=FAIL
    failed=$((failed + 1))
  fi
  counts="$(sed -n 's/^--- \(.*\)$/\1/p' "$LOG_DIR/$id.log" | tail -n1)"
  results+=("$(printf '%-4s %-22s %-4s %4ss  %s' "$id" "$s" "$status" "$((SECONDS - start))" "${counts:-no summary}")")
  echo
done

step "Summary"
printf '%s\n' "${results[@]}" | tee "$LOG_DIR/summary.txt"
if ((failed > 0)); then
  printf 'FAIL %d of %d scenarios failed\n' "$failed" "${#SCENARIOS[@]}"
  exit 1
fi
printf 'OK   all %d scenarios passed\n' "${#SCENARIOS[@]}"
