#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run this checkout against amd-gpu-mock's real ERNIC VM worker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS="${ERNIC_TEST_RESULTS:-$ROOT/tests/.ernic}"
mkdir -p "$RESULTS/build"
RESULTS="$(cd "$RESULTS" && pwd)"
MOCK_COMMIT=4bfb27db112ffb721de5b3b1bc05ffdebd566435
MOCK="${AMD_GPU_MOCK_ROOT:-$RESULTS/amd-gpu-mock}"
for tool in git go kind kubectl helm python3 curl ssh scp ssh-keygen; do command -v "$tool" >/dev/null; done
if [ ! -d "$MOCK/.git" ]; then
 git clone https://github.com/sub-mod/amd-gpu-mock.git "$MOCK"
 git -C "$MOCK" checkout --detach "$MOCK_COMMIT"
fi
[ "$(git -C "$MOCK" rev-parse HEAD)" = "$MOCK_COMMIT" ] || { echo "Expected mock revision $MOCK_COMMIT" >&2; exit 1; }
[ -z "$(git -C "$MOCK" status --porcelain --untracked-files=no)" ] || { echo 'Mock checkout has tracked changes' >&2; exit 1; }
source "$MOCK/scripts/ernic/runtime.sh"
[ "$ERNIC_RUNTIME_ARCH" = arm64 ] || { echo 'Requires an ARM64 container engine.' >&2; exit 1; }
CLUSTER=amd-netop-test
export KUBE_CONTEXT="kind-$CLUSTER" ERNIC_NODE=amd-netop-ernic-worker
export ERNIC_CONTAINER=amd-netop-ernic-lab ERNIC_CONTROL_PLANE="$CLUSTER-control-plane"
export ERNIC_NETWORK_TIMEOUT="${ERNIC_NETWORK_TIMEOUT:-15m}"
export ERNIC_SSH_PORT=2238 ERNIC_STATE_DIR="$RESULTS/worker" DEMO_NAMESPACE=amd-netop-test
k=(kubectl --context "$KUBE_CONTEXT")
# Refuse to take ownership of an unrelated or previously left running setup.
if kind get clusters | grep -qx "$CLUSTER" || ernic_container_exists "$ERNIC_CONTAINER"; then
 echo 'Dedicated test environment already exists; inspect or clean it before rerunning.' >&2
 exit 1
fi
source "$MOCK/scripts/ernic/versions.env"
REVISION="$(git -C "$ROOT" rev-parse HEAD)"
IMAGE="localhost/amd-network-operator:ernic-checkout-${REVISION:0:12}"
created=false
collect() {
 "${k[@]}" get nodes -o json > "$RESULTS/nodes.json" 2>/dev/null || true
 "${k[@]}" get pods -A -o wide > "$RESULTS/pods.txt" 2>/dev/null || true
 "${k[@]}" -n kube-amd-network get ds/ernic-device-plugin -o json > "$RESULTS/device-plugin.json" 2>/dev/null || true
 "${k[@]}" -n kube-amd-network logs deployment/amd-network-network-operator-charts-controller-manager -c manager > "$RESULTS/operator.log" 2>/dev/null || true
 "${k[@]}" -n "$DEMO_NAMESPACE" get events -o json > "$RESULTS/events.json" 2>/dev/null || true
}
finish() {
 status=$?
 trap - EXIT
 if $created; then
  collect
  if [ "${ERNIC_TEST_KEEP:-false}" != true ]; then
   bash "$MOCK/scripts/ernic/cleanup.sh" > "$RESULTS/cleanup.log" 2>&1 || true
   kind delete cluster --name "$CLUSTER" >> "$RESULTS/cleanup.log" 2>&1 || true
  fi
 fi
 echo "Test exit=$status. Evidence: $RESULTS"
 exit "$status"
}
trap finish EXIT
# Compile the operator under test, not the project's prepackaged operator binary.
cd "$ROOT"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-X main.GitCommit=$REVISION" -o "$RESULTS/build/manager" ./cmd
cat > "$RESULTS/build/Containerfile" <<EOF
FROM $NETWORK_OPERATOR_IMAGE
COPY manager /usr/local/bin/manager
LABEL org.opencontainers.image.revision=$REVISION
EOF
"$CONTAINER_RUNTIME" build -f "$RESULTS/build/Containerfile" -t "$IMAGE" "$RESULTS/build"
"$CONTAINER_RUNTIME" save -o "$RESULTS/operator.tar" "$IMAGE"
# Use the project's upstream quick start, with dedicated names/dashboard ports.
sed -e 's/hostPort: 8080/hostPort: 9080/' -e 's/hostPort: 3000/hostPort: 3300/' \
 "$MOCK/deployments/kind-node/kind-config.yaml" > "$RESULTS/kind.yaml"
created=true
kind create cluster --name "$CLUSTER" --image docker.io/submod/amd-mock-kind-node:0.2.2 --config "$RESULTS/kind.yaml"
helm install amd-gpu-mock oci://docker.io/submod/amd-gpu-mock --version 0.2.13 \
 --kube-context "$KUBE_CONTEXT" --namespace amd-mock --create-namespace --wait --timeout 10m \
 --set monitoring.enabled=false --set metricsExporter.enabled=false
# A fresh guest has new SSH host keys; this file belongs only to this test VM.
rm -f "$ERNIC_STATE_DIR/known_hosts"
bash "$MOCK/scripts/ernic/setup.sh" | tee "$RESULTS/setup.log"
kind load image-archive "$RESULTS/operator.tar" --name "$CLUSTER"
# Project configuration only: adapt NIC selectors to ERNIC's PCI identity.
# Keep this checkout's controller/CRD/chart templates unchanged otherwise.
rm -rf "$RESULTS/chart"
cp -R "$ROOT/helm-charts-k8s" "$RESULTS/chart"
cp "$MOCK/scripts/ernic/plugin-config.yaml" "$RESULTS/chart/templates/device-plugin-config.yaml"
helm upgrade amd-network "$RESULTS/chart" --kube-context "$KUBE_CONTEXT" -n kube-amd-network \
 --set kmm.enabled=false --set installdefaultNFDRule=false --set upgradeCRD=false \
 --set controllerManager.env.simEnable=false \
 --set "controllerManager.nodeSelector.kubernetes\\.io/hostname=$ERNIC_CONTROL_PLANE" \
 --set "controllerManager.manager.image.repository=${IMAGE%:*}" \
 --set "controllerManager.manager.image.tag=${IMAGE##*:}" \
 --set controllerManager.manager.imagePullPolicy=Never --wait --timeout 5m
# Assert the checkout image and non-simulation controller settings.
"${k[@]}" -n kube-amd-network get deployment -l control-plane=controller-manager -o json > "$RESULTS/controller-deployments.json"
IMAGE="$IMAGE" python3 - "$RESULTS/controller-deployments.json" <<'PY'
import json,os,sys
items=json.load(open(sys.argv[1]))["items"]
assert len(items)==1
manager=next(c for c in items[0]["spec"]["template"]["spec"]["containers"] if c["name"]=="manager")
assert manager["image"]==os.environ["IMAGE"]
assert next(e["value"] for e in manager["env"] if e["name"]=="SIM_ENABLE")=="false"
print("PASS: controller runs checkout-built image with SIM_ENABLE=false")
PY
# Force fresh reconciliation by the checkout-built controller.
"${k[@]}" -n kube-amd-network delete ds/ernic-device-plugin
ready=false
for attempt in $(seq 1 60); do
 if "${k[@]}" -n kube-amd-network get ds/ernic-device-plugin >/dev/null 2>&1; then ready=true; break; fi
 sleep 2
done
$ready || { echo 'Operator did not recreate NIC device plugin' >&2; exit 1; }
"${k[@]}" -n kube-amd-network rollout status ds/ernic-device-plugin --timeout=300s
bash "$MOCK/demo/gpu-network/single-node/run.sh" | tee "$RESULTS/allocation-first.log"
# Check that this is the real guest PCI device, bound to ionic, not fake sysfs.
"${k[@]}" -n "$DEMO_NAMESPACE" exec tiny-llm-gpu-network -- python3 -c '
import os,pathlib
pci=os.environ["PCIDEVICE_AMD_COM_NIC"]
p=pathlib.Path("/sys/bus/pci/devices")/pci
assert (p/"vendor").read_text().strip()=="0x1dd8"
assert (p/"device").read_text().strip()=="0x1002"
assert (p/"driver").resolve().name=="ionic"
print("PASS: allocated ERNIC PCI device",pci,"is bound to real ionic driver")
' | tee "$RESULTS/pci-proof.log"
# Omit the host-port reservation so NIC capacity is the scheduling constraint.
"${k[@]}" -n "$DEMO_NAMESPACE" get pod tiny-llm-gpu-network -o json | python3 -c '
import json,sys
p=json.load(sys.stdin)
p["metadata"]={"name":"tiny-llm-network-second","namespace":p["metadata"]["namespace"]}
p.pop("status",None)
p["spec"].pop("nodeName",None)
for c in p["spec"]["containers"]:
 c.pop("ports",None)
 c["readinessProbe"]["httpGet"]["port"]=8000
print(json.dumps(p))
' | "${k[@]}" create -f -
blocked=false
for attempt in $(seq 1 60); do
 if "${k[@]}" -n "$DEMO_NAMESPACE" get events --field-selector involvedObject.name=tiny-llm-network-second -o json | python3 -c '
import json,sys
sys.exit(0 if any("Insufficient amd.com/nic" in e.get("message","") for e in json.load(sys.stdin)["items"]) else 1)
'; then blocked=true; break; fi
 sleep 2
done
$blocked || { echo 'Missing NIC exhaustion scheduling evidence' >&2; exit 1; }
"${k[@]}" -n "$DEMO_NAMESPACE" get pod tiny-llm-network-second -o json | python3 -c '
import json,sys
p=json.load(sys.stdin);assert p["status"]["phase"]=="Pending";print("PASS: second Pod waits for the occupied NIC")
' | tee "$RESULTS/exhaustion.log"
"${k[@]}" -n "$DEMO_NAMESPACE" delete pod tiny-llm-gpu-network --wait=true
"${k[@]}" -n "$DEMO_NAMESPACE" wait --for=condition=Ready pod/tiny-llm-network-second --timeout=300s
DEMO_POD=tiny-llm-network-second python3 "$MOCK/demo/gpu-network/single-node/verify.py" | tee "$RESULTS/allocation-second.log"
printf 'PASS: checkout operator reconciliation, ERNIC discovery, GPU+NIC allocation, NIC exhaustion and reuse\n' | tee "$RESULTS/result.txt"
