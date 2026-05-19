# AGENTS.md — Foundry Local on Azure Red Hat OpenShift

## Goal

Validate that **Foundry Local** (Azure Arc extension) deploys and runs correctly on **Azure Red Hat OpenShift (ARO)** by following the official Microsoft documentation step-by-step. The doc only validates against AKS; this project's purpose is to **identify every divergence between AKS and OpenShift**, apply minimum-viable workarounds, and produce a compatibility report.

## Authoritative references

Pin all work to these documents. Do not invent steps that are not derivable from them.

- ARO create with managed identities — https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster
- Connect a cluster to Arc — https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
- Arc + OpenShift SCC note — https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc
- Deploy Foundry Local Arc extension — https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension
- Configure Foundry Local authentication — https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication
- Foundry Local supported regions — https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local#supported-regions

## Strategy / phases

Each phase is a numbered script under `scripts/` and a `make` target. Sentinel files in `.state/` make phases resumable.

| # | Phase | Script | Make target |
|---|-------|--------|-------------|
| A | Preflight | (Makefile) | `make preflight` |
| B | Provision ARO | `scripts/01-aro-infra.sh` | `make aro` |
| C | `oc login` | (Makefile) | `make oc-login` |
| D | OpenShift Arc prep (SCC, RPs, CLI ext) | `scripts/03-aro-prep-for-arc.sh` | `make prep-arc` |
| E | Connect to Arc | `scripts/04-arc-connect.sh` | `make arc-connect` |
| F | Entra app registration | `scripts/05-entra-app.sh` | `make entra-app` |
| G | cert-manager Arc extension | `scripts/06-cert-manager.sh` | `make cert-manager` |
| H | ingress-nginx (ClusterIP) | `scripts/07-ingress-nginx.sh` | `make ingress` |
| I | Foundry inference operator | `scripts/08-foundry-operator.sh` | `make foundry-operator` |
| J | Validation (deploy model + inference call) | `scripts/09-validate.sh` | `make validate` |
| K | Teardown | `scripts/99-teardown.sh` | `make teardown` |

## Agent behavior on failures

When any step fails, the agent must:

1. **Do not prompt the user immediately.**
2. **Capture diagnostics** before doing anything else:
   - `oc get events --sort-by=.lastTimestamp -A | tail -100`
   - Affected pod's `describe`, `logs`, owning controller logs.
   - `az k8s-extension show` JSON for any extension that failed to install.
   - Append all of the above to `docs/progress.md` under a timestamped entry.
3. **Search for cause**:
   - Search MS Learn and the web for the exact error message.
   - Check known OpenShift gotchas: SCC denials, PSA labels, `IngressClass` collision, CRD conflicts, image pull secrets, image registry mirroring.
4. **Apply the most likely workaround** if low-risk and reversible. Examples we expect:
   - SCC grants on specific ServiceAccounts (`nonroot-v2` first, `anyuid` if required, `privileged` only as last resort and only for the documented `azure-arc-kube-aad-proxy-sa`).
   - Labelling a namespace `pod-security.kubernetes.io/enforce=privileged` when required by sidecar injection.
   - Using a distinct `ingressClassName` to avoid colliding with OpenShift Router.
5. **Document** the workaround in `docs/progress.md` and add a permanent entry in `docs/validation-report.md` under "Known divergences".
6. **Escalate to the user** only when:
   - The workaround requires destructive scope (uninstalling an existing operator, deleting cluster-scoped CRDs).
   - Credentials or interactive input are required.
   - After two documented attempts the issue is unresolved.

## Commit policy

- Commit after every meaningful, working step (see milestones in README.md).
- Conventional Commits prefix (`feat:`, `fix:`, `docs:`, `chore:`).
- Per global AGENTS.md: run the `code-reviewer` subagent on `git diff HEAD` before each commit. Fix Critical / High findings before committing.

## Out of scope

- GPU workloads and the NVIDIA GPU Operator. (CPU-only validation first.)
- Public ingress / `LoadBalancer` services. (Internal validation via `kubectl port-forward`.)
- Multi-namespace `ModelDeployment` configuration.
- OpenShift Virtualization integration (`02-upgrade-cluster.sh` is unused for this project).
- Production hardening, observability, autoscaling.

## Conventions

- All Azure resources live in resource group `$RESOURCEGROUP` (default `aro-virt-test-rg`), region `$LOCATION` (default `centralus`, which is in Foundry Local's supported region list).
- The Arc connectedCluster is named `${CLUSTER}-arc`.
- The Entra app registration is named `foundry-local-${CLUSTER}`.
- Kubeconfig for ARO is written to `./kubeconfig` (gitignored). Scripts that talk to the cluster export `KUBECONFIG=$(pwd)/kubeconfig`.
- Secrets / generated credentials go to dotfiles at repo root (`.pull-secret.txt`, `.foundry-app.json`) — all gitignored.
