<#
.SYNOPSIS
    Stops the SCC, SAP system, and AKS cluster to save costs.

.DESCRIPTION
    Gracefully stops the SAP Cloud Connector, performs a clean SAP shutdown
    (sapcontrol StopSystem inside the pod), then stops the AKS cluster to deallocate
    all compute resources.

.PARAMETER ResourceGroup
    Azure resource group (default: ACSS-DEMO-01)

.PARAMETER ClusterName
    AKS cluster name (default: MySAPAKS)

.PARAMETER Namespace
    Kubernetes namespace (default: sap)

.PARAMETER Deployment
    Deployment name (default: sap-a4h)

.PARAMETER SkipSCC
    Skip stopping the SAP Cloud Connector.

.PARAMETER SkipSAP
    Skip graceful SAP shutdown (just stop the cluster).

.PARAMETER TimeoutMinutes
    Max minutes to wait for SAP shutdown (default: 10)

.EXAMPLE
    .\Stop-SAP-AKS.ps1
    .\Stop-SAP-AKS.ps1 -SkipSCC
    .\Stop-SAP-AKS.ps1 -SkipSAP
#>
param(
    [string]$ResourceGroup = "ACSS-DEMO-01",
    [string]$ClusterName = "MySAPAKS",
    [string]$Namespace = "sap",
    [string]$Deployment = "sap-a4h",
    [switch]$SkipSCC,
    [switch]$SkipSAP,
    [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = "Stop"

function Write-Status($msg) { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Red }

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ============================================================
# Step 1: Check AKS cluster state
# ============================================================
Write-Status "Checking AKS cluster state..."
$clusterState = az aks show -g $ResourceGroup -n $ClusterName --query "powerState.code" -o tsv 2>&1
Write-Status "Cluster state: $clusterState"

if ($clusterState -eq "Stopped") {
    Write-Ok "AKS cluster is already stopped. Nothing to do."
    exit 0
}

if ($clusterState -ne "Running") {
    Write-Warn "Unexpected cluster state: $clusterState — attempting to proceed..."
}

# ============================================================
# Step 2: Get kubectl credentials
# ============================================================
Write-Status "Fetching kubectl credentials..."
az aks get-credentials -g $ResourceGroup -n $ClusterName --overwrite-existing 2>&1 | Out-Null
Write-Ok "kubectl context set to '$ClusterName'."

# ============================================================
# Step 3: Check pod is running
# ============================================================
$podStatus = kubectl get pods -n $Namespace -l app=sap-a4h -o jsonpath="{.items[0].status.phase}" 2>&1

if ($podStatus -ne "Running") {
    Write-Warn "Pod is not running (status: $podStatus). Skipping in-pod shutdown."
    $SkipSCC = $true
    $SkipSAP = $true
}

# ============================================================
# Step 4: Stop SCC
# ============================================================
if (-not $SkipSCC) {
    Write-Status "Checking SCC status..."
    $sccCheck = kubectl exec -n $Namespace deployment/$Deployment -- ss -tlnp 2>&1 | Select-String "8443"

    if ($sccCheck) {
        Write-Status "Stopping SCC daemon..."
        $sccResult = kubectl exec -n $Namespace deployment/$Deployment -- /usr/local/sbin/rcscc_daemon stop 2>&1
        $sccResult | ForEach-Object { Write-Host "  $_" }
        Start-Sleep -Seconds 3

        $sccVerify = kubectl exec -n $Namespace deployment/$Deployment -- ss -tlnp 2>&1 | Select-String "8443"
        if ($sccVerify) {
            Write-Warn "SCC may still be running on port 8443."
        } else {
            Write-Ok "SCC stopped."
        }
    } else {
        Write-Ok "SCC is not running."
    }
}

# ============================================================
# Step 5: Graceful SAP shutdown
# ============================================================
if (-not $SkipSAP) {
    Write-Status "Initiating SAP shutdown (sapcontrol StopSystem)... this takes 1-3 minutes"

    try {
        kubectl exec -n $Namespace deployment/$Deployment -- su - a4hadm -c "sapcontrol -nr 00 -function StopSystem ALL" 2>&1 | ForEach-Object {
            Write-Host "  $_"
        }
        Write-Ok "SAP stop command accepted."
    } catch {
        Write-Warn "SAP stop command failed: $_ — proceeding with cluster stop."
    }

    # Wait for all SAP processes to stop (sapcontrol exit code 4 = all stopped)
    Write-Status "Waiting for SAP to finish shutting down..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sapStopped = $false

    while ((Get-Date) -lt $deadline) {
        $null = kubectl exec -n $Namespace deployment/$Deployment -- su - a4hadm -c "sapcontrol -nr 00 -function GetProcessList" 2>&1
        if ($LASTEXITCODE -eq 4) {
            $sapStopped = $true
            break
        }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ""

    if ($sapStopped) {
        Write-Ok "SAP has shut down cleanly (all processes stopped)."
    } else {
        Write-Warn "SAP did not fully stop within timeout. Proceeding with cluster stop."
    }
}

# ============================================================
# Step 6: Stop AKS cluster
# ============================================================
Write-Status "Stopping AKS cluster '$ClusterName'... (this takes 2-4 minutes)"
az aks stop -g $ResourceGroup -n $ClusterName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to stop AKS cluster."
    exit 1
}
Write-Ok "AKS cluster stopped."

# ============================================================
# Summary
# ============================================================
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed.ToString("mm\:ss")

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  SAP on AKS — Stopped ($elapsed)" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Cluster:  $ClusterName (deallocated)" -ForegroundColor White
Write-Host "  To start: .\Start-SAP-AKS.ps1" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Yellow
