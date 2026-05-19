#!/usr/bin/env bash
# =============================================================================
# 01-aro-infra.sh - Create ARO cluster with managed identities
#
# Creates:
#   1. Resource group
#   2. Virtual network with master/worker subnets
#   3. 9 user-assigned managed identities
#   4. All required role assignments
#   5. ARO cluster with --enable-managed-identity
#
# Reference: https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase 1: ARO Infrastructure Provisioning"
echo "============================================="

# -----------------------------------------------
# 1. Create Resource Group
# -----------------------------------------------
log_info "Creating resource group: $RESOURCEGROUP in $LOCATION..."
az group create \
    --location "$LOCATION" \
    --name "$RESOURCEGROUP" \
    --output none
log_ok "Resource group created."

# -----------------------------------------------
# 2. Create Virtual Network and Subnets
# -----------------------------------------------
log_info "Creating virtual network: $VNET_NAME ($VNET_CIDR)..."
az network vnet create \
    --resource-group "$RESOURCEGROUP" \
    --name "$VNET_NAME" \
    --address-prefixes "$VNET_CIDR" \
    --output none

log_info "Creating master subnet: $MASTER_SUBNET ($MASTER_SUBNET_CIDR)..."
az network vnet subnet create \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$MASTER_SUBNET" \
    --address-prefixes "$MASTER_SUBNET_CIDR" \
    --output none

log_info "Creating worker subnet: $WORKER_SUBNET ($WORKER_SUBNET_CIDR)..."
az network vnet subnet create \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$WORKER_SUBNET" \
    --address-prefixes "$WORKER_SUBNET_CIDR" \
    --output none
log_ok "Virtual network and subnets created."

# -----------------------------------------------
# 3. Create 9 User-Assigned Managed Identities
# -----------------------------------------------
IDENTITIES=(
    "$MI_CLUSTER"
    "$MI_CCM"
    "$MI_INGRESS"
    "$MI_MACHINE_API"
    "$MI_DISK_CSI"
    "$MI_CLOUD_NET"
    "$MI_IMAGE_REG"
    "$MI_FILE_CSI"
    "$MI_ARO_OP"
)

log_info "Creating ${#IDENTITIES[@]} user-assigned managed identities..."
for id_name in "${IDENTITIES[@]}"; do
    log_info "  Creating identity: $id_name"
    az identity create \
        --resource-group "$RESOURCEGROUP" \
        --name "$id_name" \
        --output none
done
log_ok "All managed identities created."

# Wait a moment for AAD propagation
log_info "Waiting 30s for identity propagation..."
sleep 30

# -----------------------------------------------
# 4. Create Role Assignments
# -----------------------------------------------
log_info "Creating role assignments..."

# Helper: get principal ID for a managed identity
get_principal_id() {
    az identity show \
        --resource-group "$RESOURCEGROUP" \
        --name "$1" \
        --query principalId -o tsv
}

CLUSTER_PRINCIPAL=$(get_principal_id "$MI_CLUSTER")
CCM_PRINCIPAL=$(get_principal_id "$MI_CCM")
INGRESS_PRINCIPAL=$(get_principal_id "$MI_INGRESS")
MACHINE_API_PRINCIPAL=$(get_principal_id "$MI_MACHINE_API")
CLOUD_NET_PRINCIPAL=$(get_principal_id "$MI_CLOUD_NET")
FILE_CSI_PRINCIPAL=$(get_principal_id "$MI_FILE_CSI")
IMAGE_REG_PRINCIPAL=$(get_principal_id "$MI_IMAGE_REG")
ARO_OP_PRINCIPAL=$(get_principal_id "$MI_ARO_OP")

# Note: disk-csi-driver does not need an explicit role assignment here.
# Its role is assigned automatically by the ARO RP during cluster creation.
# The identity only needs to exist so it can be passed to --assign-platform-workload-identity.

# Role definition IDs (built-in)
ROLE_MI_OPERATOR="ef318e2a-8334-4a05-9e4a-295a196c6a6e"  # Managed Identity Operator

# Operator-specific roles on subnets/VNet
ROLE_CCM_SUBNET="a1f96423-95ce-4224-ab27-4e3dc72facd4"
ROLE_INGRESS_SUBNET="0336e1d3-7a87-462b-b6db-342b63f7802c"
ROLE_MACHINE_API_SUBNET="0358943c-7e01-48ba-8889-02cc51d78637"
ROLE_CLOUD_NET_VNET="be7a6435-15ae-4171-8f30-4a343eff9e8f"
ROLE_FILE_CSI_VNET="0d7aedc0-15fd-4a67-a412-efad370c947e"
ROLE_IMAGE_REG_VNET="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
ROLE_ARO_OP_SUBNET="4436bae4-7702-4c84-919b-c4069ff25ee2"
ROLE_RP_VNET="42f3c60f-e7b1-46d7-ba56-6de681664342"

# Scope paths.
# Note: Azure CLI 2.85.0+ validates scope path casing strictly. The literal
# segments must be /subscriptions/, /resourceGroups/ (capital G), and
# /providers/. Lowercase variants like 'resourcegroups' are rejected with
# 'Invalid scope' — silently if errors are swallowed.
MI_SCOPE_PREFIX="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities"
VNET_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"
MASTER_SCOPE="${VNET_SCOPE}/subnets/${MASTER_SUBNET}"
WORKER_SCOPE="${VNET_SCOPE}/subnets/${WORKER_SUBNET}"
ROLE_DEF_PREFIX="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions"

# Idempotent role-assignment helper.
# Args: <principalId> <roleDefId> <scope>
# Treats "RoleAssignmentExists" (HTTP 409) as success; everything else fails loudly.
assign_role() {
    local pid="$1"
    local role_id="$2"
    local scope="$3"
    local out
    if out=$(az role assignment create \
            --assignee-object-id "$pid" \
            --assignee-principal-type ServicePrincipal \
            --role "${ROLE_DEF_PREFIX}/${role_id}" \
            --scope "$scope" \
            --output none 2>&1); then
        return 0
    fi
    if echo "$out" | grep -qE 'RoleAssignmentExists|already exists'; then
        return 0
    fi
    log_error "Role assignment failed:"
    log_error "  principal: $pid"
    log_error "  role:      $role_id"
    log_error "  scope:     $scope"
    log_error "  error:     $out"
    return 1
}

# --- 4a. Cluster identity -> Managed Identity Operator over each operator identity ---
OPERATOR_IDENTITIES=("$MI_ARO_OP" "$MI_CCM" "$MI_INGRESS" "$MI_MACHINE_API" "$MI_DISK_CSI" "$MI_CLOUD_NET" "$MI_IMAGE_REG" "$MI_FILE_CSI")

log_info "  Assigning Managed Identity Operator role to cluster identity..."
for op_id in "${OPERATOR_IDENTITIES[@]}"; do
    assign_role "$CLUSTER_PRINCIPAL" "$ROLE_MI_OPERATOR" "${MI_SCOPE_PREFIX}/${op_id}"
done

# --- 4b. cloud-controller-manager -> subnets ---
log_info "  Assigning cloud-controller-manager roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    assign_role "$CCM_PRINCIPAL" "$ROLE_CCM_SUBNET" "$SUBNET_SCOPE"
done

# --- 4c. ingress -> subnets ---
log_info "  Assigning ingress roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    assign_role "$INGRESS_PRINCIPAL" "$ROLE_INGRESS_SUBNET" "$SUBNET_SCOPE"
done

# --- 4d. machine-api -> subnets ---
log_info "  Assigning machine-api roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    assign_role "$MACHINE_API_PRINCIPAL" "$ROLE_MACHINE_API_SUBNET" "$SUBNET_SCOPE"
done

# --- 4e. cloud-network-config -> VNet ---
log_info "  Assigning cloud-network-config role..."
assign_role "$CLOUD_NET_PRINCIPAL" "$ROLE_CLOUD_NET_VNET" "$VNET_SCOPE"

# --- 4f. file-csi-driver -> VNet ---
log_info "  Assigning file-csi-driver role..."
assign_role "$FILE_CSI_PRINCIPAL" "$ROLE_FILE_CSI_VNET" "$VNET_SCOPE"

# --- 4g. image-registry -> VNet ---
log_info "  Assigning image-registry role..."
assign_role "$IMAGE_REG_PRINCIPAL" "$ROLE_IMAGE_REG_VNET" "$VNET_SCOPE"

# --- 4h. aro-operator -> subnets ---
log_info "  Assigning aro-operator roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    assign_role "$ARO_OP_PRINCIPAL" "$ROLE_ARO_OP_SUBNET" "$SUBNET_SCOPE"
done

# --- 4i. Azure Red Hat OpenShift RP first-party SP -> VNet ---
log_info "  Assigning ARO RP first-party service principal role..."
ARO_RP_SP_OID=$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query '[0].id' -o tsv 2>/dev/null || echo "")
if [[ -n "$ARO_RP_SP_OID" ]]; then
    assign_role "$ARO_RP_SP_OID" "$ROLE_RP_VNET" "$VNET_SCOPE"
    log_ok "  ARO RP SP role assigned."
else
    log_warn "  Could not find 'Azure Red Hat OpenShift RP' service principal."
    log_warn "  This may mean the Microsoft.RedHatOpenShift provider isn't registered."
fi

log_ok "All role assignments created."

# -----------------------------------------------
# 5. Get available ARO versions and create cluster
# -----------------------------------------------
log_info "Fetching available ARO versions in $LOCATION..."
ARO_VERSIONS=$(az aro get-versions --location "$LOCATION" -o json 2>/dev/null || echo "[]")

# Helper: parse a semver-ish '4.18.35' into a comparable tuple of ints.
# Sort by tuple (so 4.18.x > 4.9.x) rather than lexicographically.
echo "$ARO_VERSIONS" | python3 -c "
import sys, json
def key(v):
    parts = v.split('.')
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        # Pre-release suffix like '4.18.0-rc.1' — sort by major.minor only.
        return tuple(int(p) for p in parts[:2])

versions = json.load(sys.stdin)
if versions:
    print('Available versions:')
    for v in sorted(versions, key=key, reverse=True):
        print(f'  {v}')
else:
    print('No versions available (or command not supported in this CLI version)')
"

# Pick the latest version with minor >= 18. K8s 1.29+ (Foundry Local floor)
# is satisfied by ARO >= 4.18.
ARO_VERSION=$(echo "$ARO_VERSIONS" | python3 -c "
import sys, json
def key(v):
    parts = v.split('.')
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return tuple(int(p) for p in parts[:2])

versions = sorted(json.load(sys.stdin), key=key, reverse=True)
for v in versions:
    parts = v.split('.')
    if len(parts) < 2:
        continue
    try:
        major, minor = int(parts[0]), int(parts[1])
    except ValueError:
        continue
    if major >= 4 and minor >= 18:
        print(v)
        break
" 2>/dev/null || echo "")

if [[ -z "$ARO_VERSION" ]]; then
    log_error "No ARO version >= 4.18 found. Foundry Local requires Kubernetes >= 1.29 (ARO 4.18 ships K8s 1.31)."
    log_error "Available versions: $ARO_VERSIONS"
    exit 1
fi

log_ok "Selected ARO version: $ARO_VERSION"

# -----------------------------------------------
# 6. Create the ARO cluster
# -----------------------------------------------
log_info "Creating ARO cluster '$CLUSTER' (this takes 30-45 minutes)..."
log_info "  Version: $ARO_VERSION"
log_info "  Worker VM size: $WORKER_VM_SIZE"
log_info "  Worker count: $WORKER_COUNT"

CREATE_CMD=(
    az aro create
    --resource-group "$RESOURCEGROUP"
    --name "$CLUSTER"
    --vnet "$VNET_NAME"
    --master-subnet "$MASTER_SUBNET"
    --worker-subnet "$WORKER_SUBNET"
    --worker-vm-size "$WORKER_VM_SIZE"
    --worker-count "$WORKER_COUNT"
    --worker-vm-disk-size-gb "$WORKER_DISK_SIZE_GB"
    --version "$ARO_VERSION"
    --enable-managed-identity
    --assign-cluster-identity "$MI_CLUSTER"
    --assign-platform-workload-identity "$MI_FILE_CSI" "$MI_FILE_CSI"
    --assign-platform-workload-identity "$MI_CCM" "$MI_CCM"
    --assign-platform-workload-identity "$MI_INGRESS" "$MI_INGRESS"
    --assign-platform-workload-identity "$MI_IMAGE_REG" "$MI_IMAGE_REG"
    --assign-platform-workload-identity "$MI_MACHINE_API" "$MI_MACHINE_API"
    --assign-platform-workload-identity "$MI_CLOUD_NET" "$MI_CLOUD_NET"
    --assign-platform-workload-identity "$MI_ARO_OP" "$MI_ARO_OP"
    --assign-platform-workload-identity "$MI_DISK_CSI" "$MI_DISK_CSI"
)

# Validate pull secret (required for the cluster to pull Red Hat images / OperatorHub)
if ! validate_pull_secret "$PULL_SECRET_FILE"; then
    exit 1
fi

log_ok "  .pull-secret.txt validated"
CREATE_CMD+=(--pull-secret "@${PULL_SECRET_FILE}")

"${CREATE_CMD[@]}"

log_ok "ARO cluster '$CLUSTER' created successfully!"

# -----------------------------------------------
# 7. Retrieve cluster credentials and API server URL
# -----------------------------------------------
log_info "Retrieving cluster credentials..."
CREDENTIALS=$(az aro list-credentials --resource-group "$RESOURCEGROUP" --name "$CLUSTER" -o json)
API_SERVER=$(az aro show --resource-group "$RESOURCEGROUP" --name "$CLUSTER" --query apiserverProfile.url -o tsv)
CONSOLE_URL=$(az aro show --resource-group "$RESOURCEGROUP" --name "$CLUSTER" --query consoleProfile.url -o tsv)

echo ""
log_ok "============================================="
log_ok " ARO Cluster Ready!"
log_ok "============================================="
log_ok "  API Server:  $API_SERVER"
log_ok "  Console:     $CONSOLE_URL"
log_ok "  Username:    $(echo "$CREDENTIALS" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kubeadminUsername"])')"
log_ok "  Password:    (retrieve with: az aro list-credentials -g $RESOURCEGROUP -n $CLUSTER)"
log_ok ""
log_ok "  Login with:  oc login $API_SERVER -u kubeadmin -p <password>"
log_ok "============================================="

mark_state "aro"
progress_log "aro" "Created ARO cluster \`${CLUSTER}\` version \`${ARO_VERSION}\` in \`${LOCATION}\` (RG \`${RESOURCEGROUP}\`). API: ${API_SERVER}"
