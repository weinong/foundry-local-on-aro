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
