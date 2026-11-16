#!/usr/bin/env bash
# Deletes the kind cluster "proxy-poc" (and only that one, by name).
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools kind

step "Deleting kind cluster $CLUSTER_NAME"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  info "not found, nothing to do"
fi
