#!/usr/bin/env pwsh
# =============================================================================
# create-aks-cluster.ps1
# Provisions an AKS cluster with cluster autoscaler, attaches the existing ACR,
# and enables the metrics-server addon required for HPA to work.
#
# Prerequisites:
#   - Azure CLI installed and logged in  (az login)
#   - An existing Azure Resource Group
#   - The ACR "agenttestsea" already exists in the same subscription
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
$RESOURCE_GROUP     = "rg-voice-agent-test-sea-dev"   # <-- update this
$CLUSTER_NAME       = "aks-livekit-agent"
$ACR_NAME           = "agenttestsea"
$LOCATION           = "southeastasia"

# Node pool — Standard_D4s_v3: 4 vCPU / 16 GB, good for Silero VAD + ai-coustics
$NODE_VM_SIZE       = "Standard_D4s_v3"
$NODE_MIN_COUNT     = 2   # matches HPA minReplicas
$NODE_MAX_COUNT     = 10  # matches HPA maxReplicas
$NODE_INITIAL_COUNT = 2

$NODEPOOL_NAME      = "agentpool"
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Done($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARNING: $msg" -ForegroundColor Yellow }

# ── 1. Verify prerequisites ───────────────────────────────────────────────────
Write-Step "Checking Azure CLI login..."
$account = az account show 2>&1 | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in. Run 'az login' first."
}
Write-Done "Logged in as: $($account.user.name) | Subscription: $($account.name)"

Write-Step "Verifying resource group '$RESOURCE_GROUP' exists..."
$rg = az group show --name $RESOURCE_GROUP 2>&1 | ConvertFrom-Json
if (-not $rg) {
    Write-Error "Resource group '$RESOURCE_GROUP' not found. Update the script variable."
}
Write-Done "Resource group found in $($rg.location)"

Write-Step "Verifying ACR '$ACR_NAME' exists..."
$acr = az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP 2>&1 | ConvertFrom-Json
if (-not $acr) {
    Write-Error "ACR '$ACR_NAME' not found in resource group '$RESOURCE_GROUP'."
}
Write-Done "ACR found: $($acr.loginServer)"

# ── 2. Create AKS cluster ─────────────────────────────────────────────────────
Write-Step "Creating AKS cluster '$CLUSTER_NAME'..."
Write-Host "    This takes ~5-10 minutes." -ForegroundColor DarkGray

az aks create `
    --resource-group $RESOURCE_GROUP `
    --name $CLUSTER_NAME `
    --location $LOCATION `
    --node-count $NODE_INITIAL_COUNT `
    --nodepool-name $NODEPOOL_NAME `
    --node-vm-size $NODE_VM_SIZE `
    --enable-cluster-autoscaler `
    --min-count $NODE_MIN_COUNT `
    --max-count $NODE_MAX_COUNT `
    --enable-managed-identity `
    --attach-acr $ACR_NAME `
    --network-plugin azure `
    --network-plugin-mode overlay `
    --generate-ssh-keys `
    --output table

if ($LASTEXITCODE -ne 0) { Write-Error "AKS cluster creation failed." }
Write-Done "Cluster created."

# ── 3. Enable metrics-server (required for HPA) ───────────────────────────────
Write-Step "Enabling metrics-server addon (required for HPA)..."
az aks enable-addons `
    --resource-group $RESOURCE_GROUP `
    --name $CLUSTER_NAME `
    --addons monitoring `
    --output table

if ($LASTEXITCODE -ne 0) {
    Write-Warn "Could not enable monitoring addon — you may need a Log Analytics workspace."
    Write-Warn "You can still install metrics-server manually:"
    Write-Warn "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
} else {
    Write-Done "Monitoring addon enabled."
}

# ── 4. Get kubeconfig credentials ─────────────────────────────────────────────
Write-Step "Fetching kubeconfig credentials..."
az aks get-credentials `
    --resource-group $RESOURCE_GROUP `
    --name $CLUSTER_NAME `
    --overwrite-existing

if ($LASTEXITCODE -ne 0) { Write-Error "Failed to get credentials." }
Write-Done "kubectl context set to '$CLUSTER_NAME'."

# ── 5. Verify cluster ─────────────────────────────────────────────────────────
Write-Step "Verifying cluster nodes..."
kubectl get nodes

# ── 6. Summary ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Cluster ready. Deploy your agent manifests:" -ForegroundColor Green
Write-Host ""
Write-Host "   kubectl apply -f k8s/namespace.yaml" -ForegroundColor White
Write-Host "   kubectl apply -f k8s/secret.yaml    # fill in credentials first!" -ForegroundColor Yellow
Write-Host "   kubectl apply -f k8s/deployment.yaml" -ForegroundColor White
Write-Host "   kubectl apply -f k8s/hpa.yaml" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Green
