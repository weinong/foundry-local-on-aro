# Foundry Local on ARO — Validation Report

Status: **validated end-to-end. Inference round-trip succeeded against `qwen3-0.6b` (HTTP 200).**

This report summarizes the outcome of following the [Deploy Foundry Local as an Azure Arc extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension) documentation (plus the Helm Chart Installation Guide supplied by the Foundry team in `helm.txt`) against Azure Red Hat OpenShift (ARO).

## Environment

| Item | Value |
|------|-------|
| ARO version | 4.20.15 |
| OpenShift Kubernetes | v1.33.6 |
| Region | `centralus` (Foundry Local supported region) |
| Worker pool | 3 × `Standard_D8s_v5` (CPU only) |
| Arc agent version | 1.33.0 |
| cert-manager | v1.20.1 (Jetstack upstream chart) |
| trust-manager | v0.20.1 (Jetstack upstream chart) |
| ingress-nginx | latest from upstream chart, ClusterIP, `ingressClass=nginx` |
| Foundry inference operator | helm chart `0.260430.8` from `oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator` |
| Validation model | `qwen3-0.6b` (ONNX, CPU, ~600MB) |

## Phase results

| Phase | Make target | Result |
|-------|-------------|--------|
| Provision ARO | `make aro` | OK (two local bugs fixed in `scripts/01-aro-infra.sh`) |
| `oc-login` | `make oc-login` | OK |
| OpenShift Arc prep | `make prep-arc` | OK with SCC + Helm-ownership workaround |
| Arc connect | `make arc-connect` | OK (`distribution=openshift`, `connectivityStatus=Connected`) |
| Entra app registration | `make entra-app` | OK (split into two Graph PATCHes; not consumed in current path) |
| cert-manager + trust-manager | `make cert-manager` | OK via upstream charts (the Microsoft.CertManagement extension is broken on OpenShift) |
| ingress-nginx | `make ingress` | OK with chart-value overrides + `nonroot-v2` SCC |
| Foundry inference operator | `make foundry-operator` | OK via public helm chart from MCR (the Arc extension type is access-gated) |
| Inference call | `make validate` | OK — `qwen3-0.6b` returned `"Paris is the capital of France."` |

Inference details from the last run:

```
- Model alias: qwen3-0.6b
- compute: cpu, runtime: onnx-genai
- ModelDeployment ready in ~0s (already up from previous attempt)
- Inference HTTP status: 200
- Sample answer (truncated):
  > "Okay, the user is asking for the capital city of France in one sentence...
     Paris is the capital of France."
```

## Local script defects (not OpenShift-specific)

These were bugs in the existing scripts. Fixed before continuing.

| # | File | Bug | Fix commit |
|---|------|-----|------------|
| L1 | `scripts/01-aro-infra.sh` | `MI_SCOPE_PREFIX` used lowercase `/resourcegroups/`. Azure CLI 2.85+ rejects with `Invalid scope`. The `2>/dev/null \|\| true` error suppression masked it, so all eight `aro-cluster` → Managed Identity Operator role assignments were silently skipped. ARO RP then reported `InvalidPlatformWorkloadIdentity`. | `47d2300` |
| L2 | `scripts/01-aro-infra.sh` | Did not call `require_azure_login` before constructing `${SUBSCRIPTION_ID}`-bearing scope strings. | `781f607` |

## OpenShift divergences from the AKS-validated path

### D1. Arc proxy SCC + Helm namespace ownership

| Trigger | `az connectedk8s connect` fails on OpenShift unless `azure-arc-kube-aad-proxy-sa` has the `privileged` SCC. We pre-grant the SCC by creating the namespace and applying the RoleBinding before connect. |
|---|---|
| Knock-on | Helm 3 (used by `az connectedk8s connect` internally) refuses to import a pre-existing namespace and aborts with `invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"`. |
| Workaround | Label the pre-created namespace `app.kubernetes.io/managed-by=Helm` and annotate it `meta.helm.sh/release-name=azure-arc`, `meta.helm.sh/release-namespace=azure-arc-release` before `connect`. Baked into `scripts/03-aro-prep-for-arc.sh`. |
| Doc reference | [Arc troubleshooting — OpenShift](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) — the Helm ownership conflict it triggers is NOT documented. |
| Recommendation to MS docs | Either (a) move the `privileged` SCC grant to AFTER `connect`, accepting one aad-proxy CrashLoop cycle while the SCC propagates, or (b) document the Helm ownership pre-annotation as a required companion step to the SCC fix. |

### D2. Microsoft Entra application registration via Graph PATCH

Not OpenShift-related, but worth flagging because it makes scripted onboarding error-prone:

The Graph v1.0 application API rejects a single PATCH that both creates `oauth2PermissionScopes` AND references the new scope ID from `preAuthorizedApplications.delegatedPermissionIds`. The validator runs against the *currently persisted* scope set:

```
InvalidValue: Property api.preAuthorizedApplications.delegatedPermissionIds
has a Permission Id that cannot be found in the AppPermissions sets.
```

`scripts/05-entra-app.sh` issues two sequential PATCHes: first the scope definition, then the Azure CLI preauthorization. Note: in the current validation path we install Foundry Local with `entraAuth.enabled=false` and use API-key auth, so the Entra app is **not consumed**; it is provisioned for the future Entra-auth path but exercising it is out of scope.

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

**Workaround used here**: install upstream `jetstack/cert-manager` and `jetstack/trust-manager` charts directly. The Foundry Local inference operator only depends on the `cert-manager.io` and `trust.cert-manager.io` API surfaces; nothing in those Foundry CRDs references Microsoft's private otel-collector sidecar or other extension-private resources. **Confirmed working end-to-end** including TLS cert issuance for ModelDeployment services (the operator successfully creates `Certificate` resources for each ModelDeployment).

**Recommendation to MS docs**: For OpenShift / any CRI-O cluster, document upstream cert-manager + trust-manager as an acceptable substitute for the `Microsoft.CertManagement` extension. Or fix the chart: drop the deprecated alpha seccomp annotations, drop the hostPath volumes, and republish the otel-collector image as a flat single-platform index.

### D4. ingress-nginx chart needs non-default values on OpenShift

The upstream `ingress-nginx/ingress-nginx` chart's defaults fail on ARO for several reasons:

| Default | Why it fails on OpenShift | Workaround in `scripts/07-ingress-nginx.sh` |
|---------|---------------------------|----------------------------------------------|
| `controller.image.runAsUser: 101` | `restricted-v2` requires UID in the namespace's auto-assigned range; UID 101 is not in range. | Keep UID 101 (the controller image is chown'd to www-data), bind `nonroot-v2` SCC. |
| `controller.containerSecurityContext.capabilities.add: [NET_BIND_SERVICE]` | `anyuid` forbids adding any capabilities. `nonroot-v2` allows NET_BIND_SERVICE explicitly. | Use `nonroot-v2`. |
| `controller.containerSecurityContext.readOnlyRootFilesystem: true` | The controller writes `/etc/ingress-controller/ssl/default-fake-certificate.pem`. That directory is image-baked (not a volume). | Set `readOnlyRootFilesystem: false`. |
| `controller.admissionWebhooks.{createSecretJob,patchWebhookJob}.securityContext.runAsUser: 65532` | Same UID-range problem as the controller. | Set `runAsUser: null`. |

The `anyuid` SCC is also bound as a fallback for the `kube-webhook-certgen` admission jobs.

### D5. Foundry inference operator Arc-extension type is preview-access-gated

`az k8s-extension create --extension-type microsoft.foundry` against this Arc cluster fails with:

```
ExtensionOperationFailed: Failed to resolve the extension version from the given values.
InnerError: 'Internal error: Extension type microsoft.foundry doesn't have any
supporting artifacts. Please contact Microsoft support for further assistance.'
```

`az k8s-extension extension-types list-versions-by-cluster --extension-type microsoft.foundry` returns `[]` — no versions are released to this subscription. This is the preview gate documented in the Foundry Local prerequisites.

**Workaround used here**: install via the public OCI helm chart provided in `helm.txt`:

```
helm upgrade --install inference-operator \
  oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator \
  --version 0.260430.8 \
  --namespace foundry-local-operator --create-namespace \
  --set entraAuth.enabled=false
```

The helm chart is publicly available on MCR and is NOT gated on the preview subscription allow-list. Authentication is set to API-key mode (`entraAuth.enabled=false`) so the Entra Auth SDK + msi-adapter sidecars are not injected; inference is protected by per-deployment API keys.

**Recommendation to MS docs**: prominently feature the helm-chart install path. The Arc-extension path is not generally available even within the preview cohort, and the helm chart is the actually working option today.

### D6. Foundry helm chart's `telemetry-collector` requires `privileged` SCC

After installing the chart, only the `inference-operator` and `inference-operator-model-store` pods come up cleanly; the `telemetry-collector` Deployment stalls because its init container needs:

- `runAsUser: 0`
- `NET_ADMIN` + `NET_RAW` capabilities
- `fsGroup: 10001` (specific group, not in OpenShift's namespace range)

Only the `privileged` SCC permits all of these on OpenShift. The main pods (operator + model-store) are happy with `nonroot-v2`.

**Workaround in `scripts/08-foundry-operator.sh`**: pre-grant `nonroot-v2`, `anyuid`, **and** `privileged` SCCs to all ServiceAccounts in the `foundry-local-operator` namespace before the helm install. After the install, restart the `telemetry-collector` Deployment so the existing ReplicaSet picks up the new SCC binding.

**Recommendation to MS docs**: either (a) document the SCC requirements explicitly for OpenShift, or (b) ship the telemetry-collector with a less-privileged init (e.g., move the network setup into a CNI plugin or a securityContext-less wrapper). The init container's privileges look like networking init — likely sets up sidecar proxy iptables — and could plausibly be replaced with a CNI-managed setup on OpenShift.

## Recommendations to the Foundry Local docs team

1. **Document the helm-chart install path as the primary route**, not the Arc-extension. The Arc extension type is gated; the helm chart is public.
2. **Document an OpenShift-compatible cert-manager path.** Either explicitly support installing upstream cert-manager + trust-manager as a replacement for `Microsoft.CertManagement` on CRI-O clusters, or fix the three chart defects in D3.
3. **Document the OpenShift Arc-connect Helm ownership prerequisite** alongside the existing SCC note. The two need to be applied together for connect to succeed when the SCC is applied pre-connect.
4. **Document the SCC requirements** for the inference operator chart on OpenShift (D6).
5. **Document the Graph PATCH ordering for Entra setup.** Step 2 (scope) and Step 4 (CLI preauthorization) must be separate PATCH calls when scripted.
6. **Test the deploy path on OpenShift before declaring "Arc-enabled Kubernetes" support generically.** The doc currently reads as if any Arc-connected cluster will work; in practice only AKS does without significant tuning.


## Validation run — 2026-05-21T00:47:52Z

- Model alias: `qwen3-0.6b`
- compute: `cpu`, runtime: `onnx-genai`
- ModelDeployment readiness time: ~0s
- Inference HTTP status: 200
- Sample answer (first 200 chars, whitespace collapsed):

  >  Okay, the user is asking for the capital city of France in one sentence. Let me start by recalling the correct information.  France's capital is Paris. The user wants this in one sentence. I need to 

## Validation run — 2026-05-21T00:52:42Z

- Model alias: `qwen3-0.6b`
- compute: `cpu`, runtime: `onnx-genai`
- ModelDeployment readiness time: ~1s
- Inference HTTP status: 200
- Sample answer (first 200 chars, whitespace collapsed):

  >  Okay, the user is asking for the capital city of France in a single sentence. Let me start by recalling the correct information.  France's capital is Paris. The user wants it in one sentence. Let me 
