# Progress log

Each phase appends a timestamped entry here. Most-recent at the bottom. When a step fails, also capture the diagnostics the agent gathered before applying a workaround.

## 2026-05-19T20:14:23Z — aro

FIRST RUN FAILED with `InvalidPlatformWorkloadIdentity` on disk-csi-driver. Root cause: `scripts/01-aro-infra.sh` constructed `MI_SCOPE_PREFIX` with lowercase `/resourcegroups/` instead of `/resourceGroups/`. Azure CLI 2.85+ rejects this with `Invalid scope`. Errors were silently swallowed by `2>/dev/null || true`, so all 8 cluster-identity->Managed Identity Operator role assignments were never created, but the script still proceeded to `az aro create`. The ARO RP saw the operator identities had no federation grants and reported the first one (disk-csi-driver) as invalid. Fix: corrected casing and replaced error-swallowing with an `assign_role()` helper that tolerates RoleAssignmentExists but propagates everything else. Will re-run.

## 2026-05-19T20:55:59Z — aro

Created ARO cluster `aro-virt-test` version `4.20.15` in `centralus` (RG `aro-virt-test-rg`). API: https://api.dd1lmoi8.centralus.aroapp.io:6443/

## 2026-05-19T20:56:33Z — oc-login

Wrote kubeconfig to local file for API `https://api.dd1lmoi8.centralus.aroapp.io:6443/`.

## 2026-05-19T21:05:01Z — prep-arc

OpenShift-specific divergence applied: granted `privileged` SCC to `system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa`. Per [MS troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) this is required for the Arc aad-proxy pod to start on OpenShift.

## 2026-05-19T21:08:42Z — oc-login

Wrote kubeconfig to local file for API `https://api.dd1lmoi8.centralus.aroapp.io:6443/`.

## 2026-05-19T21:09:33Z — prep-arc

OpenShift-specific divergence applied: granted `privileged` SCC to `system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa`. Per [MS troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) this is required for the Arc aad-proxy pod to start on OpenShift.

## 2026-05-19T21:16:44Z — arc-connect

Cluster `aro-virt-test-arc` is **Connected** to Arc. distribution=`openshift`, k8s=`1.33.6`, agentVersion=`1.33.0`.

## 2026-05-19T21:17:01Z — arc-connect

Connected via Arc, status=`Connected`, distribution=`openshift`, k8s=`1.33.6`, agentVersion=`1.33.0`. **OpenShift divergence #2**: pre-creating the `azure-arc` namespace (so the `privileged` SCC binding can be applied to `azure-arc-kube-aad-proxy-sa` before pods land) collides with Helm 3 ownership semantics. `az connectedk8s connect` runs `helm install` and refuses to import a namespace it did not create. **Workaround**: label the namespace `app.kubernetes.io/managed-by=Helm` and annotate it with `meta.helm.sh/release-name=azure-arc` + `meta.helm.sh/release-namespace=azure-arc-release` before connect. Now baked into `scripts/03-aro-prep-for-arc.sh`. The doc never mentions this because AKS does not need the pre-SCC binding.

## 2026-05-19T21:18:45Z — entra-app

Created/updated app registration `foundry-local-aro-virt-test` (appId `f3b14cf4-1eb0-4e89-bd0c-e9b62dc5dc55`, scope `foundry_access`, token v2). Granted Arc identity `bf61031b-c321-4667-abda-c13c614e634e` the `Cognitive Services OpenAI User` role on the connectedCluster.

## 2026-05-19T21:37:11Z — cert-manager

ABORTED: pre-existing cert-manager CRDs detected. Manual intervention required.

## 2026-05-19T22:08:34Z — oc-login

Wrote kubeconfig to local file for API `https://api.dd1lmoi8.centralus.aroapp.io:6443/`.

## 2026-05-19T22:09:54Z — prep-arc

OpenShift-specific divergence applied: granted `privileged` SCC to `system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa`. Per [MS troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) this is required for the Arc aad-proxy pod to start on OpenShift.

## 2026-05-19T22:11:19Z — arc-connect

Cluster `aro-virt-test-arc` is **Connected** to Arc. distribution=`openshift`, k8s=`1.33.6`, agentVersion=`1.33.0`.

## 2026-05-19T22:13:38Z — cert-manager

Installed **upstream** cert-manager `v1.20.1` and trust-manager `v0.20.1` via Jetstack helm chart, bypassing the Microsoft.CertManagement Arc extension. **OpenShift divergence #3** (three sub-issues): the extension's chart uses (a) hostPath volumes, (b) deprecated `seccomp.security.alpha.kubernetes.io/*` annotations, and (c) an otel-collector sidecar image packaged as a nested OCI index that CRI-O cannot pull. None of these can be worked around with SCC bindings or namespace labels alone. Granted `nonroot-v2` SCC to ServiceAccounts in `cert-manager` to satisfy the upstream chart's pod security context. The Foundry Local inference operator only depends on the `cert-manager.io` and `trust.cert-manager.io` API surfaces, which upstream charts provide identically.

## 2026-05-19T23:11:13Z — ingress

Installed upstream ingress-nginx in namespace `ingress-nginx` with ingressClassName=`nginx` (ClusterIP). **OpenShift divergence**: granted `anyuid` SCC to ingress-nginx ServiceAccounts; kept a distinct ingressClass so it does not collide with OpenShift Router's `openshift-default`.

## 2026-05-19T23:11:58Z — entra-app

Created/updated app registration `foundry-local-aro-virt-test` (appId `f3b14cf4-1eb0-4e89-bd0c-e9b62dc5dc55`, scope `foundry_access`, token v2). Granted Arc identity `bf61031b-c321-4667-abda-c13c614e634e` the `Cognitive Services OpenAI User` role on the connectedCluster.

## 2026-05-19T23:13:35Z — foundry-operator

**BLOCKED**: az k8s-extension create --extension-type microsoft.foundry returned `ExtensionOperationFailed: Extension type microsoft.foundry does not have any supporting artifacts`. This means the `microsoft.foundry` extension type is not available to this subscription/tenant. Per the Foundry Local doc: *"Foundry Local on Azure Local is available by request during preview. Submit an access request at https://aka.ms/FoundryLocalAzure_PreviewRequest."* The subscription `L1VH Virt Testing` (`2ad02bfb-c56e-4a34-b46a-b3eaa246d0f3`) has not been allow-listed for the private preview. This is a Microsoft-side approval gate — not an OpenShift-specific issue and not something the agent can resolve. Need to file the preview-access request and re-run `make foundry-operator` after approval.
