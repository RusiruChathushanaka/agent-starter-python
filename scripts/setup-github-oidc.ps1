#!/usr/bin/env pwsh
# =============================================================================
# setup-github-oidc.ps1
#
# Creates the Azure AD app registration and federated credentials that allow
# GitHub Actions to authenticate to Azure without any stored client secrets
# (OpenID Connect / Workload Identity Federation).
#
# Run this ONCE before your first deployment. After running it, add the three
# output values as GitHub Actions secrets in your repository settings.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Sufficient Azure AD permissions (Application Administrator or higher)
# =============================================================================

# ── Configuration — update these before running ───────────────────────────────
$GITHUB_ORG         = "your-github-org"        # <-- your GitHub username or org
$GITHUB_REPO        = "your-repo-name"          # <-- your GitHub repository name
$GITHUB_BRANCH      = "main"                    # branch that triggers deployments

$APP_NAME           = "sp-livekit-agent-cicd"
$ACR_NAME           = "agenttestsea"
$AKS_CLUSTER        = "aks-livekit-agent"
$RESOURCE_GROUP     = "rg-voice-agent-test-sea-dev"
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Done($msg) { Write-Host "    $msg" -ForegroundColor Green }

# ── 1. Get subscription and tenant info ───────────────────────────────────────
Write-Step "Getting subscription info..."
$account        = az account show | ConvertFrom-Json
$SUBSCRIPTION_ID = $account.id
$TENANT_ID       = $account.tenantId
Write-Done "Subscription : $SUBSCRIPTION_ID"
Write-Done "Tenant       : $TENANT_ID"

# ── 2. Create the Azure AD app registration ───────────────────────────────────
Write-Step "Creating Azure AD app registration '$APP_NAME'..."
$existingApp = az ad app list --display-name $APP_NAME | ConvertFrom-Json
if ($existingApp.Count -gt 0) {
    Write-Host "    App already exists — reusing it." -ForegroundColor Yellow
    $CLIENT_ID = $existingApp[0].appId
} else {
    $app = az ad app create --display-name $APP_NAME | ConvertFrom-Json
    $CLIENT_ID = $app.appId
    Write-Done "Created app: $CLIENT_ID"
}

# Create the associated service principal (needed for role assignments)
$spExists = az ad sp list --filter "appId eq '$CLIENT_ID'" | ConvertFrom-Json
if ($spExists.Count -eq 0) {
    Write-Step "Creating service principal..."
    az ad sp create --id $CLIENT_ID | Out-Null
    Write-Done "Service principal created."
}

# ── 3. Add federated credentials for GitHub Actions ───────────────────────────
# This allows pushes to the main branch to authenticate as this app.
Write-Step "Adding federated credential for branch '$GITHUB_BRANCH'..."
$federatedCredential = @{
    name        = "github-$GITHUB_REPO-$GITHUB_BRANCH"
    issuer      = "https://token.actions.githubusercontent.com"
    subject     = "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${GITHUB_BRANCH}"
    description = "GitHub Actions — $GITHUB_REPO branch $GITHUB_BRANCH"
    audiences   = @("api://AzureADTokenExchange")
} | ConvertTo-Json -Compress

$credJson = $federatedCredential | Out-File -FilePath "$env:TEMP\fed-cred.json" -Encoding utf8 -PassThru
az ad app federated-credential create --id $CLIENT_ID --parameters "$env:TEMP\fed-cred.json" | Out-Null
Remove-Item "$env:TEMP\fed-cred.json" -Force
Write-Done "Federated credential created."

# ── 4. Assign roles ───────────────────────────────────────────────────────────
Write-Step "Assigning AcrPush role on ACR..."
$acrId = (az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP | ConvertFrom-Json).id
az role assignment create `
    --assignee $CLIENT_ID `
    --role "AcrPush" `
    --scope $acrId `
    --output none
Write-Done "AcrPush assigned."

Write-Step "Assigning Azure Kubernetes Service Cluster Admin Role on AKS..."
$aksId = (az aks show --name $AKS_CLUSTER --resource-group $RESOURCE_GROUP | ConvertFrom-Json).id
az role assignment create `
    --assignee $CLIENT_ID `
    --role "Azure Kubernetes Service Cluster Admin Role" `
    --scope $aksId `
    --output none
Write-Done "AKS Admin role assigned."

# ── 5. Print GitHub secrets to add ────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Add these 3 values as GitHub Actions secrets:" -ForegroundColor Green
Write-Host " (Repository Settings → Secrets and variables → Actions)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  AZURE_CLIENT_ID       = $CLIENT_ID" -ForegroundColor White
Write-Host "  AZURE_TENANT_ID       = $TENANT_ID" -ForegroundColor White
Write-Host "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID" -ForegroundColor White
Write-Host ""
Write-Host " Also ensure these existing secrets are present:" -ForegroundColor DarkGray
Write-Host "  LIVEKIT_URL           (already used by tests.yml)" -ForegroundColor DarkGray
Write-Host "  LIVEKIT_API_KEY       (already used by tests.yml)" -ForegroundColor DarkGray
Write-Host "  LIVEKIT_API_SECRET    (already used by tests.yml)" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Green
