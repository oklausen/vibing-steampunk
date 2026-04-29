<#
.SYNOPSIS
    Starts the AKS cluster and waits for the SAP system to be fully ready.

.DESCRIPTION
    Starts the AKS cluster (if stopped), waits for the SAP node pool to be ready,
    waits for the SAP pod to be running, waits for SAP to fully start (via sapcontrol),
    and optionally starts the SAP Cloud Connector.

.PARAMETER ResourceGroup
    Azure resource group (default: ACSS-DEMO-01)

.PARAMETER ClusterName
    AKS cluster name (default: MySAPAKS)

.PARAMETER Namespace
    Kubernetes namespace (default: sap)

.PARAMETER Deployment
    Deployment name (default: sap-a4h)

.PARAMETER Fqdn
    External FQDN (default: mysapa4haks.swedencentral.cloudapp.azure.com)

.PARAMETER SkipSCC
    Skip starting the SAP Cloud Connector.

.PARAMETER TimeoutMinutes
    Max minutes to wait for SAP readiness (default: 15)

.EXAMPLE
    .\Start-SAP-AKS.ps1
    .\Start-SAP-AKS.ps1 -SkipSCC
#>
param(
    [string]$ResourceGroup = "ACSS-DEMO-01",
    [string]$ClusterName = "MySAPAKS",
    [string]$Namespace = "sap",
    [string]$Deployment = "sap-a4h",
    [string]$Fqdn = "mysapa4haks.swedencentral.cloudapp.azure.com",
    [switch]$SkipSCC,
    [int]$TimeoutMinutes = 25
)

$ErrorActionPreference = "Stop"

function Write-Status($msg) { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Red }

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ============================================================
# Step 1: Start AKS cluster
# ============================================================
Write-Status "Checking AKS cluster state..."
$clusterState = az aks show -g $ResourceGroup -n $ClusterName --query "powerState.code" -o tsv 2>&1
Write-Status "Cluster state: $clusterState"

if ($clusterState -eq "Stopped") {
    Write-Status "Starting AKS cluster '$ClusterName'... (this takes 3-5 minutes)"
    az aks start -g $ResourceGroup -n $ClusterName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to start AKS cluster."
        exit 1
    }
    Write-Ok "AKS cluster started."
} elseif ($clusterState -eq "Running") {
    Write-Ok "AKS cluster is already running."
} else {
    Write-Warn "Unexpected cluster state: $clusterState — attempting to proceed..."
}

# ============================================================
# Step 2: Get kubectl credentials
# ============================================================
Write-Status "Fetching kubectl credentials..."
az aks get-credentials -g $ResourceGroup -n $ClusterName --overwrite-existing 2>&1 | Out-Null
Write-Ok "kubectl context set to '$ClusterName'."

# ============================================================
# Step 3: Wait for SAP node pool to be ready
# ============================================================
Write-Status "Waiting for SAP node to be Ready..."
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

while ((Get-Date) -lt $deadline) {
    $nodeReady = kubectl get nodes -l workload=sap -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}" 2>&1
    if ($nodeReady -eq "True") { break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

if ($nodeReady -ne "True") {
    Write-Err "SAP node did not become Ready within $TimeoutMinutes minutes."
    exit 1
}
Write-Ok "SAP node is Ready."

# ============================================================
# Step 4: Wait for SAP pod to be running
# ============================================================
Write-Status "Waiting for SAP pod to be Running..."
$podDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-Date) -lt $podDeadline) {
    $podPhase = kubectl get pods -n $Namespace -l app=sap-a4h -o jsonpath="{.items[0].status.phase}" 2>&1
    if ($podPhase -eq "Running") { break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

if ($podPhase -ne "Running") {
    Write-Err "SAP pod did not reach Running state. Current: $podPhase"
    exit 1
}

$podName = kubectl get pods -n $Namespace -l app=sap-a4h -o jsonpath="{.items[0].metadata.name}" 2>&1
Write-Ok "SAP pod '$podName' is Running."

# ============================================================
# Step 5: Wait for SAP services to start
# ============================================================
Write-Status "Waiting for SAP to start... (typically 5-8 minutes)"
$sapDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
$sapStarted = $false
$startAttempted = $false

while ((Get-Date) -lt $sapDeadline) {
    # sapcontrol exit codes: 0=all GREEN, 3=some YELLOW/GRAY, 4=all stopped
    $null = kubectl exec -n $Namespace deployment/$Deployment -- su - a4hadm -c "sapcontrol -nr 00 -function GetProcessList" 2>&1
    $sapExitCode = $LASTEXITCODE

    # Exit code 0 = all GREEN; 3 = all listed processes GREEN (instance quirk)
    if ($sapExitCode -eq 0 -or $sapExitCode -eq 3) {
        $sapStarted = $true
        break
    }

    if ($sapExitCode -eq 4 -and -not $startAttempted) {
        # All processes stopped — SAP didn't auto-start; start explicitly
        Write-Status "SAP processes not running. Starting with sapcontrol..."
        kubectl exec -n $Namespace deployment/$Deployment -- su - a4hadm -c "sapcontrol -nr 00 -function StartSystem ALL" 2>&1 | ForEach-Object { Write-Host "  $_" }
        $startAttempted = $true
    }

    Write-Host "." -NoNewline
    Start-Sleep -Seconds 15
}
Write-Host ""

if ($sapStarted) {
    Write-Ok "SAP is running (all processes GREEN)."
} else {
    Write-Warn "SAP did not fully start within $TimeoutMinutes minutes."
    Write-Warn "Check: kubectl exec -n $Namespace deployment/$Deployment -- su - a4hadm -c 'sapcontrol -nr 00 -function GetProcessList'"
}

# ============================================================
# Step 6: Verify external connectivity
# ============================================================
Write-Status "Verifying external connectivity..."
try {
    $tcpTest = Test-NetConnection -ComputerName $Fqdn -Port 3200 -WarningAction SilentlyContinue
    if ($tcpTest.TcpTestSucceeded) {
        Write-Ok "SAP GUI reachable at $Fqdn`:3200"
    } else {
        Write-Warn "Port 3200 not yet reachable externally. May need a moment."
    }
} catch {
    Write-Warn "Could not test external connectivity: $_"
}

# ============================================================
# Step 7: Start SCC (optional)
# ============================================================
if (-not $SkipSCC) {
    Write-Status "Checking SCC status..."
    $sccRunning = kubectl exec -n $Namespace deployment/$Deployment -- ss -tlnp 2>&1 | Select-String "8443"

    if ($sccRunning) {
        Write-Ok "SCC is already running."
    } else {
        Write-Status "Starting SCC daemon..."
        # Both rcscc_daemon and daemon.sh block under kubectl exec (wait $pid / foreground Java).
        # Background the process so kubectl exec returns immediately, then verify via port check.
        # Redirect output to a log file for debugging (not /dev/null).
        $null = kubectl exec -n $Namespace deployment/$Deployment -- bash -c "cd /opt/sap/scc && nohup ./daemon.sh start > /tmp/scc_start.log 2>&1 &" 2>&1

        # SCC Java process needs time to initialise and bind to port 8443.
        # Check every 5 seconds for up to 60 seconds.
        $sccDeadline = (Get-Date).AddSeconds(60)
        $sccUp = $false
        while ((Get-Date) -lt $sccDeadline) {
            Start-Sleep -Seconds 5
            $sccVerify = kubectl exec -n $Namespace deployment/$Deployment -- ss -tlnp 2>&1 | Select-String "8443"
            if ($sccVerify) {
                $sccUp = $true
                break
            }
            Write-Status "  Waiting for SCC to bind port 8443..."
        }

        if ($sccUp) {
            Write-Ok "SCC started at https://${Fqdn}:8443/"
        } else {
            # Dump the start log for troubleshooting
            Write-Warn "SCC did not bind port 8443 within 60 seconds."
            $sccLog = kubectl exec -n $Namespace deployment/$Deployment -- cat /tmp/scc_start.log 2>&1
            if ($sccLog) { Write-Host $sccLog }
            Write-Warn "SCC may not have started. Check manually."
        }
    }
}

# ============================================================
# Summary
# ============================================================
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed.ToString("mm\:ss")

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  SAP on AKS — Ready! ($elapsed)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  SAP GUI:  $Fqdn`:3200 (SID: A4H, Client: 001)" -ForegroundColor White
Write-Host "  HTTP:     http://${Fqdn}:50000/sap/bc/adt/" -ForegroundColor White
Write-Host "  HTTPS:    https://${Fqdn}:50001/sap/bc/adt/" -ForegroundColor White
Write-Host "  HANA:     ${Fqdn}:30213" -ForegroundColor White
if (-not $SkipSCC) {
    Write-Host "  SCC:      https://${Fqdn}:8443/" -ForegroundColor White
}
Write-Host "  User:     DEVELOPER / ABAPtr2023#00" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Green
