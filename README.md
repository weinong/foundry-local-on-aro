# Foundry Local on Azure Red Hat OpenShift

Validate that **Foundry Local** (an Azure Arc extension) can be deployed and run on **Azure Red Hat OpenShift (ARO)**. Microsoft documents and validates Foundry Local only on AKS; this repo follows the same doc against ARO step-by-step to identify and work around OpenShift-specific friction.

See [AGENTS.md](./AGENTS.md) for goals, strategy, and the rules an automation agent should follow when steps fail.

## Prerequisites

On your workstation:

- `az` (Azure CLI ≥ 2.84) and logged in (`az login`) to a subscription with sufficient quota.
- `oc` (OpenShift CLI), `kubectl`, `helm`, `jq`, `curl`, `python3`.
- The `connectedk8s` and `k8s-extension` Azure CLI extensions (installed automatically by `make prep-arc`).
- A Red Hat pull secret saved at the repo root as `.pull-secret.txt`. Download from <https://console.redhat.com/openshift/install/azure/aro-provisioned>.
- Sufficient Azure permissions:
  - Contributor + User Access Administrator on the target subscription/RG (or Owner) to create the ARO cluster, managed identities, and role assignments.
  - Permission to create a Microsoft Entra app registration (member or guest with Application Administrator).
- Quota for ≥ 44 vCPU of `Standard_D8s_v5` (3 workers + control plane + bootstrap) in your target region.

Region: `centralus` (a [Foundry Local supported region](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local#supported-regions)).

## Architecture

```
                    +--------------------------+
   az CLI ---->     |  Azure (centralus)       |
                    |                          |
                    |  ARO cluster ----------+ |
                    |  (kubeadmin)          | |
                    |                       v |
                    |  Microsoft.Kubernetes/  |
                    |    connectedClusters    |
                    |    (Arc-enabled K8s)    |
                    |          |              |
                    |          v              |
                    |  Arc extensions:        |
                    |   - Microsoft.CertManagement
                    |   - Microsoft.Foundry (inference-operator)
                    |  In-cluster:            |
                    |   - ingress-nginx       |
                    |   - foundry-local-operator ns
                    |     - Model / ModelDeployment CRDs
                    |     - inference pods (with Entra Auth sidecars)
                    +--------------------------+
                                  ^
                                  | port-forward (internal only)
                                  |
                          oc port-forward svc/...
                          + Entra ID bearer token
                          (az account get-access-token)
```

## Run order

Everything is wired into `make`. Each phase records a sentinel under `.state/` so re-running `make all` resumes from where you left off.

```bash
make preflight         # check local prerequisites and pull secret
make aro               # ~45 min — create the ARO cluster
make oc-login          # fetch kubeadmin creds, write ./kubeconfig
make prep-arc          # OpenShift SCC for Arc + register RPs + CLI extensions
make arc-connect       # az connectedk8s connect
make entra-app         # create Entra app registration, save .foundry-app.json
make cert-manager      # install Microsoft.CertManagement Arc extension
make ingress           # install ingress-nginx (ClusterIP only)
make foundry-operator  # install Microsoft.Foundry Arc extension
make validate          # deploy a CPU model, port-forward, run inference
```

Or run the whole pipeline:

```bash
make all
```

Tear it all down:

```bash
make teardown
```

## Progress and findings

- Running log: [`docs/progress.md`](./docs/progress.md)
- Compatibility report: [`docs/validation-report.md`](./docs/validation-report.md)

**Status: validated end-to-end on ARO.** All 9 pipeline phases (preflight → validate) complete with an inference round-trip (HTTP 200, model `qwen3-0.6b` returned a sensible chat completion).

Key OpenShift divergences from the AKS-validated path:

1. Helm-ownership annotations on the pre-created `azure-arc` namespace (required to combine with the documented `privileged` SCC fix for the aad-proxy SA).
2. The `Microsoft.CertManagement` Arc extension is non-installable on OpenShift due to three independent chart/image defects. Workaround: install upstream `jetstack/cert-manager` + `jetstack/trust-manager` directly.
3. ingress-nginx upstream chart needs `nonroot-v2` SCC, `readOnlyRootFilesystem: false`, and high-UID overrides on its admission jobs.
4. The `Microsoft.Foundry` Arc extension type is preview-access-gated. Workaround: use the public helm chart `oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator` (per the Foundry team's Helm Installation Guide).
5. The Foundry chart's `telemetry-collector` requires `privileged` SCC (init container needs `runAsUser: 0`, `NET_ADMIN`/`NET_RAW`, `fsGroup: 10001`); the main `inference-operator` and `model-store` pods only need `nonroot-v2`.

## Out of scope

GPU workloads, public ingress, multi-namespace model deployments, OpenShift Virtualization, production hardening. See [AGENTS.md](./AGENTS.md#out-of-scope).
