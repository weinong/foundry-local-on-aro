# Foundry Local on ARO — Validation Report

Status: **partial validation completed; final inference step blocked on Microsoft preview-access gate.**

This report summarizes the outcome of following the [Deploy Foundry Local as an Azure Arc extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension) documentation against Azure Red Hat OpenShift (ARO), which Microsoft does not currently validate against.

## Environment

| Item | Value |
|------|-------|
| ARO version | 4.20.15 |
| OpenShift Kubernetes | v1.33.6 |
| Region | `centralus` (Foundry Local supported region) |
| Worker pool | 3 × `Standard_D8s_v5` (CPU only) |
| Arc agent version | 1.33.0 |
| Foundry extension version | **not installable — see Phase J** |

## Phase results

| Phase | Make target | Result | Notes |
|-------|-------------|--------|-------|
| Provision ARO | `make aro` | OK | Two local bugs fixed in `scripts/01-aro-infra.sh` (see _Local script defects_). |
| `oc-login` | `make oc-login` | OK | kubeadmin via `az aro list-credentials`. |
| OpenShift Arc prep | `make prep-arc` | OK with workaround | SCC binding + namespace pre-annotation. |
| Arc connect | `make arc-connect` | OK | `distribution=openshift`, `agentVersion=1.33.0`, `connectivityStatus=Connected`. |
| Entra app registration | `make entra-app` | OK with split PATCH | Graph API rejects scope+preauthorization in a single PATCH. |
| cert-manager (Microsoft.CertManagement) | `make cert-manager` | **FAILED** | Three independent OpenShift incompatibilities. Bypassed with upstream charts. |
| ingress-nginx | `make ingress` | OK with non-trivial chart overrides | Multiple OpenShift SCC adjustments. |
| Foundry inference operator | `make foundry-operator` | **BLOCKED** | `microsoft.foundry` extension type has zero versions visible to this subscription. Requires preview-access approval. |
| Model deployment + inference call | `make validate` | not attempted | Dependent on the previous phase. |

## Local script defects (not OpenShift-specific)

These were bugs in the existing scripts. Fixed before continuing.

| # | File | Bug | Fix commit |
|---|------|-----|------------|
| L1 | `scripts/01-aro-infra.sh` | `MI_SCOPE_PREFIX` used lowercase `/resourcegroups/`. Azure CLI 2.85+ rejects with `Invalid scope`. The `2>/dev/null \|\| true` error suppression masked it, so all eight `aro-cluster` → Managed Identity Operator role assignments were silently skipped. ARO RP then reported `InvalidPlatformWorkloadIdentity` for the first lexically-sorted operator identity (`disk-csi-driver`). | `47d2300` |
| L2 | `scripts/01-aro-infra.sh` | Did not call `require_azure_login` before constructing `${SUBSCRIPTION_ID}`-bearing scope strings. Resulted in `/subscriptions//resourceGroups/...` once L1 stopped masking errors. | `781f607` |

## OpenShift divergences from the AKS-validated path

### D1. Arc proxy SCC + Helm namespace ownership

| Trigger | `az connectedk8s connect` fails on OpenShift unless `azure-arc-kube-aad-proxy-sa` has the `privileged` SCC. We pre-grant the SCC by creating the namespace and applying the RoleBinding before connect. |
|---|---|
| Knock-on | Helm 3 (used by `az connectedk8s connect` internally) refuses to import a pre-existing namespace and aborts with `invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"`. |
| Workaround | Label the pre-created namespace `app.kubernetes.io/managed-by=Helm` and annotate it `meta.helm.sh/release-name=azure-arc`, `meta.helm.sh/release-namespace=azure-arc-release` before `connect`. Baked into `scripts/03-aro-prep-for-arc.sh`. |
| Doc reference for the SCC | [Arc troubleshooting — OpenShift](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) — the Helm ownership conflict it triggers is NOT documented. |
| Recommendation to MS docs | Either (a) move the `privileged` SCC grant to AFTER `connect`, accepting one aad-proxy CrashLoop cycle while the SCC propagates, or (b) document the Helm ownership pre-annotation as a required companion step to the SCC fix. |

### D2. Microsoft Entra application registration via Graph PATCH

Not OpenShift-related, but worth flagging because it makes scripted onboarding error-prone:

The Graph v1.0 application API rejects a single PATCH that both creates `oauth2PermissionScopes` AND references the new scope ID from `preAuthorizedApplications.delegatedPermissionIds`. The validator runs against the *currently persisted* scope set, not the one in the in-flight PATCH:

```
InvalidValue: Property api.preAuthorizedApplications.delegatedPermissionIds
has a Permission Id that cannot be found in the AppPermissions sets.
```

`scripts/05-entra-app.sh` issues two sequential PATCHes: first the scope definition, then the Azure CLI preauthorization. Doc Step 2 + Step 4 read as if they were independent portal clicks, which is true; the doc doesn't anticipate someone scripting them.

### D3. Microsoft.CertManagement Arc extension is non-installable on OpenShift

The deploy doc's Step 1 (install `Microsoft.CertManagement`) is the single biggest divergence. Three independent reasons the helm chart cannot run on OpenShift, all baked into the Microsoft chart and its images:

**D3a — Deprecated alpha seccomp annotations.** The chart's pod specs carry `seccomp.security.alpha.kubernetes.io/pod` and `container.seccomp.security.alpha.kubernetes.io/<container>` annotations (the Kubernetes-1.18-deprecated form). OpenShift's SCC admission rejects every SCC for any pod that uses these annotations:
```
pod.metadata.annotations[seccomp.security.alpha.kubernetes.io/pod]: Forbidden: seccomp may not be set
```
Modern alternative is `securityContext.seccompProfile.type`, which the same templates also set — the alpha annotations are redundant and should be removed.

**D3b — hostPath volumes.** Multiple deployments (`cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook`, `trust-manager`) mount `hostPath` volumes. OpenShift's default SCCs (`restricted-v2`, `nonroot-v2`, `anyuid`) all forbid hostPath; only `hostmount-anyuid`, `hostaccess`, and `privileged` allow it. cert-manager upstream does not need hostPath, so this is a Microsoft chart customization.

**D3c — Nested OCI index image (CRI-O incompatible).** The chart injects an `otel-collector` sidecar pulling `mcr.microsoft.com/azuremonitor/opentelemetry-collector-internal:v0.143.3`. That image is published as a **nested OCI index** — the multi-arch manifest's per-platform entries are themselves manifest indexes (mediaType `application/vnd.oci.image.index.v1+json`) instead of normal image manifests. CRI-O (OpenShift's container runtime) refuses:

```
Unexpectedly received a manifest list instead of a manifest for a single image;
Treating manifest lists as individual manifests is not implemented
```

This is a fundamental image-publishing bug. It cannot be worked around with SCC bindings or chart values — the image simply will not pull on any CRI-O cluster.

**D3d — Atomic install removes the patching window.** The `az k8s-extension create` invocation uses `--atomic`, so the moment any pod fails to schedule the entire helm release rolls back. There is no opportunity to patch deployment specs after-the-fact.

**Workaround used here**: install upstream `jetstack/cert-manager` and `jetstack/trust-manager` charts directly. The Foundry Local inference operator only depends on the `cert-manager.io` and `trust.cert-manager.io` API surfaces; nothing in those Foundry CRDs references Microsoft's private otel-collector sidecar or other extension-private resources.

**Recommendation to MS docs**: For OpenShift / any CRI-O cluster, document upstream cert-manager + trust-manager as an acceptable substitute for the `Microsoft.CertManagement` extension. Or fix the chart: drop the deprecated alpha seccomp annotations, drop the hostPath volumes, and republish the otel-collector image as a flat single-platform index.

### D4. ingress-nginx chart needs non-default values on OpenShift

The upstream `ingress-nginx/ingress-nginx` chart's defaults fail on ARO for three reasons:

| Default | Why it fails on OpenShift | Workaround in `scripts/07-ingress-nginx.sh` |
|---------|---------------------------|----------------------------------------------|
| `controller.image.runAsUser: 101` | `restricted-v2` requires UID in the namespace's auto-assigned range (e.g. `[1000820000, 1000829999]`); UID 101 is not in range. | Keep UID 101 (the controller image is chown'd to www-data), but bind `nonroot-v2` SCC to the namespace's service accounts. `nonroot-v2` allows `RunAsAny` and permits `NET_BIND_SERVICE`. |
| `controller.containerSecurityContext.capabilities.add: [NET_BIND_SERVICE]` | `anyuid` forbids adding any capabilities. `nonroot-v2` allows NET_BIND_SERVICE explicitly. | See above — `nonroot-v2`. |
| `controller.containerSecurityContext.readOnlyRootFilesystem: true` | The controller writes `/etc/ingress-controller/ssl/default-fake-certificate.pem`. That directory is image-baked (not a volume), so even with `fsGroup` it stays read-only. | Set `readOnlyRootFilesystem: false`. |
| `controller.admissionWebhooks.{createSecretJob,patchWebhookJob}.securityContext.runAsUser: 65532` | Same UID-range problem as the controller. | Set `runAsUser: null`; `nonroot-v2` accepts any non-zero UID. |

The `anyuid` SCC is still bound as a fallback for the `kube-webhook-certgen` admission jobs (which use UID 65532 by default).

### D5. Foundry inference operator extension type is preview-gated (BLOCKING)

`az k8s-extension create --extension-type microsoft.foundry` against this Arc cluster fails with:

```
ExtensionOperationFailed: Failed to resolve the extension version from the given values.
InnerError: 'Internal error: Extension type microsoft.foundry doesn't have any
supporting artifacts. Please contact Microsoft support for further assistance.'
```

`az k8s-extension extension-types show-by-cluster --extension-type microsoft.foundry` confirms the extension type is registered:

```json
{
  "name": "microsoft.foundry",
  "description": "Arc Extension of Foundry",
  "publisher": "Microsoft Foundry",
  "supportedClusterTypes": ["Connectedclusters"]
}
```

But `list-versions-by-cluster --extension-type microsoft.foundry` returns `[]` — no versions are released to this subscription. This is the preview gate documented in the Foundry Local prerequisites: "Foundry Local on Azure Local is available by request during preview. Submit an access request at https://aka.ms/FoundryLocalAzure_PreviewRequest."

This is not an OpenShift incompatibility and not something the agent can work around. After preview-access is granted to subscription `2ad02bfb-c56e-4a34-b46a-b3eaa246d0f3`, re-running `make foundry-operator` should be the next step.

## Validation gaps (not yet exercised)

Because Phase I is blocked at the access gate, the following have not been tested on OpenShift:

- Whether the Foundry inference operator pods start cleanly under OpenShift's SCCs.
- Whether the Entra Auth SDK + msi-adapter sidecars (injected into each inference pod by the operator's mutating webhook) tolerate `restricted-v2`.
- Whether ingress objects created by the operator work with our `ingressClassName: nginx` setup.
- The end-to-end inference call (Phase J / `make validate`).

These should be the focus of the next pass once preview access is granted.

## Recommendations to the Foundry Local docs team

1. **Document an OpenShift-compatible cert-manager path.** Either explicitly support installing upstream cert-manager + trust-manager as a replacement for `Microsoft.CertManagement` on CRI-O clusters, or fix the three chart defects in D3.
2. **Document the OpenShift Arc-connect Helm ownership prerequisite** alongside the existing SCC note. The two need to be applied together for connect to succeed when the SCC is applied pre-connect.
3. **Document the Graph PATCH ordering for Entra setup.** Step 2 (scope) and Step 4 (CLI preauthorization) must be separate PATCH calls when scripted.
4. **Test the deploy path on OpenShift before declaring "Arc-enabled Kubernetes" support generically.** The doc currently reads as if any Arc-connected cluster will work; in practice only AKS does.
