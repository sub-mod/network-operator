# ERNIC-backed operator integration

Run the operator checkout against the real ERNIC environment provided by
[amd-gpu-mock](https://github.com/sub-mod/amd-gpu-mock). The guest kernel creates
the NIC discovery surface from ERNIC's emulated PCI device.

## Run

Requires an ARM64 Docker Engine 28+ or Podman engine, Go matching `go.mod`, kind v0.33+, kubectl,
Helm, Git, Python 3, curl and OpenSSH. The initial published worker/lab images
are large; later runs reuse the image cache. The integration CI job uses Docker on `ubuntu-24.04-arm`; no Podman installation
or Podman machine is required. AMD64 lab/guest images are not currently supported.

```bash
CONTAINER_RUNTIME=docker make test-ernic
# On a Mac with Podman:
CONTAINER_RUNTIME=podman make test-ernic
# Use an existing clean checkout at the pinned mock revision:
AMD_GPU_MOCK_ROOT=/path/to/amd-gpu-mock make test-ernic
```

The script pins mock project commit `4bfb27db112ffb721de5b3b1bc05ffdebd566435`
and uses its published node, chart, ERNIC lab and prepared worker artifacts.
It builds this operator checkout's manager for Linux ARM64, replaces the manager
in the published runtime image, and loads that local test image into Kind.
The test image is disposable and does not replace a published release.

It creates a dedicated `amd-netop-test` cluster, `amd-netop-ernic-lab` container
and Ubuntu VM worker. Existing clusters are preserved. Dashboard ports are
9080 and 3300; the guest management SSH port is 2238. It refuses to reuse an
existing test environment. Results and guest cache default to `tests/.ernic/`
(which is gitignored and may include private SSH/bootstrap material).

## What it proves

```text
[1] Published amd-gpu-mock Kind node + GPU/DRA chart
                   |
[2] ERNIC process -- VFIO-user --> QEMU Ubuntu worker
                                  |
                          real ionic + ionic_rdma
                                  |
[3] NFD discovers PCI identity --> worker label
                                  |
[4] Operator built from this checkout reconciles NetworkConfig
    Delete NIC plugin DaemonSet --> operator recreates it
                                  |
[5] NIC plugin registers amd.com/nic: 1 with kubelet
                                  |
[6] Tiny LLM Pod requests one AMD DRA GPU + one NIC
    Verify claim, GPU device nodes, NIC PCI identity and RDMA device nodes
                                  |
[7] Second GPU+NIC Pod --> Pending: Insufficient amd.com/nic
                                  |
[8] Delete first Pod --> second Pod starts with GPU+NIC allocation
```

The project's existing demo verifier checks the GPU claim against the matching
ResourceSlice, injected GPU character devices, NIC allocation environment and
RDMA character devices. An additional check verifies PCI vendor/device
`1dd8:1002` and the guest's real `ionic` driver binding. The exhaustion assertion
requires a scheduler event naming `Insufficient amd.com/nic`, then checks that
the waiting Pod becomes Ready after release. The second Pod has no host-port
reservation and uses a numeric readiness-probe port, so port exhaustion does
not mask NIC exhaustion. Both workloads use the project's host-network demo;
this does not test secondary-network attachment or tenant isolation.

The project's setup initially installs its pinned operator. The test then
replaces it with the checkout-built manager and recreates the NIC plugin through
that controller before allocating workloads. NIC selectors and the NFD rule
are configured for ERNIC's emulated PCI identity. NIC reconfiguration and
exporter health checks are disabled through supported plugin configuration;
driver installation, NIC
metrics and secondary-network CNI management are disabled. Operator
`SIM_ENABLE` stays false. The Tiny LLM response is scripted; no inference,
GPU-direct DMA or RDMA transfer is claimed.

## Evidence and cleanup

The result directory contains `allocation-first.log`, `pci-proof.log`,
`exhaustion.log`, `allocation-second.log`, `result.txt`, Node/DaemonSet JSON,
Pod status, scheduler events and controller logs. The first allocation log
includes the GPU+NIC demo's assertions, not just workload stdout.

The cluster and ERNIC lab are removed on exit; downloaded images and worker
artifacts remain cached. Set `ERNIC_TEST_KEEP=true` to keep the environment for
inspection. To clean a kept environment:

```bash
bash tests/ernic/cleanup.sh
# If the run used an existing mock checkout, supply the same path:
AMD_GPU_MOCK_ROOT=/path/to/amd-gpu-mock bash tests/ernic/cleanup.sh
```

Do not commit the cache or private bootstrap files.

## Validated run

A fresh ARM64 Podman run on 2026-10-14 passed the complete target without manual
intervention after correcting the second-Pod port/probe configuration. See
[captured output](captured-output.txt) for the checkout-built controller source
identity, one advertised NIC, both GPU+NIC allocation assertions, the genuine
NIC-exhaustion scheduling event and the final result. Production operator code
was unchanged from main `df08b06e068ac8724660ae69320d6eaa52032131`.


The hosted allocation check disables optional telemetry to avoid competing cold
image pulls in the guest and sets `ERNIC_NETWORK_TIMEOUT=15m`. The published
quick-start defaults remain unchanged.

The pinned environment defers RDMA auto-probing until Ethernet is up, preserving
shared interrupt capacity. A guest service restores that order on reboot.
Driver and emulator production source remain unmodified.

Hosted ARM64 Docker validation also passed: [run 38611876019](https://github.com/sub-mod/network-operator/actions/runs/38611876019), [captured output](captured-docker-ci.txt). This built the controller from the checkout and verified reconciliation, real ERNIC discovery, GPU+NIC allocation, NIC exhaustion and reuse.
