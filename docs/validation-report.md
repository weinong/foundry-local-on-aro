# Foundry Local on ARO — Validation Report

Status: in progress.

This report summarizes the outcome of following the [Deploy Foundry Local as an Azure Arc extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension) documentation against Azure Red Hat OpenShift (ARO), which Microsoft does not currently validate against.

## Environment

- ARO version: _populated by `make aro`_
- Kubernetes version: _populated by `make aro`_
- Region: `centralus`
- Worker pool: 3× `Standard_D8s_v5` (CPU only)
- Arc agent version: _populated by `make arc-connect`_
- Foundry extension version: _populated by `make foundry-operator`_

## Phase results

| Phase | Result | Notes |
|-------|--------|-------|
| ARO provisioning | _pending_ | |
| OpenShift Arc prep (SCC) | _pending_ | |
| Arc connect | _pending_ | |
| Entra app registration | _pending_ | |
| cert-manager extension | _pending_ | |
| ingress-nginx | _pending_ | |
| Foundry inference operator | _pending_ | |
| Model deployment + inference call | _pending_ | |

## Known divergences from the AKS-validated path

_Workarounds applied during validation will be documented here as they occur. Each entry should include: the symptom, the OpenShift-specific cause, the workaround, and a doc reference._

## Recommendations to the Foundry Local docs team

_Filled in once validation completes._
