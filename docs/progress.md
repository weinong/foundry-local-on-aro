# Progress log

Each phase appends a timestamped entry here. Most-recent at the bottom. When a step fails, also capture the diagnostics the agent gathered before applying a workaround.

## 2026-05-19T20:14:23Z — aro

FIRST RUN FAILED with `InvalidPlatformWorkloadIdentity` on disk-csi-driver. Root cause: `scripts/01-aro-infra.sh` constructed `MI_SCOPE_PREFIX` with lowercase `/resourcegroups/` instead of `/resourceGroups/`. Azure CLI 2.85+ rejects this with `Invalid scope`. Errors were silently swallowed by `2>/dev/null || true`, so all 8 cluster-identity->Managed Identity Operator role assignments were never created, but the script still proceeded to `az aro create`. The ARO RP saw the operator identities had no federation grants and reported the first one (disk-csi-driver) as invalid. Fix: corrected casing and replaced error-swallowing with an `assign_role()` helper that tolerates RoleAssignmentExists but propagates everything else. Will re-run.
