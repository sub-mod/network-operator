#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Remove only the dedicated ERNIC test environment; preserve caches and Podman VM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS="${ERNIC_TEST_RESULTS:-$ROOT/tests/.ernic}"
MOCK="${AMD_GPU_MOCK_ROOT:-$RESULTS/amd-gpu-mock}"
source "$MOCK/scripts/ernic/runtime.sh"
export KUBE_CONTEXT=kind-amd-netop-test
export ERNIC_NODE=amd-netop-ernic-worker ERNIC_CONTAINER=amd-netop-ernic-lab
export ERNIC_SSH_PORT=2238 ERNIC_STATE_DIR="$RESULTS/worker" DEMO_NAMESPACE=amd-netop-test
if kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null 2>&1; then
 bash "$MOCK/scripts/ernic/cleanup.sh"
elif ernic_container_exists "$ERNIC_CONTAINER"; then
 "$CONTAINER_RUNTIME" stop --time 30 "$ERNIC_CONTAINER"
 "$CONTAINER_RUNTIME" rm "$ERNIC_CONTAINER"
fi
kind delete cluster --name amd-netop-test
