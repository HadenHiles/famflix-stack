# ============================
#   FamFlix FULL STARTUP
# ============================

Write-Host "=== Starting FamFlix (Windows layer) ===" -ForegroundColor Cyan

# 1. Run fix-famflix first
& "C:\Users\haden\fix-famflix.ps1"

# ------------------------
# 2. WSL Warm-Up
# ------------------------

Write-Host "`nWarming up WSL..." -ForegroundColor Yellow
wsl -d Ubuntu -- bash -lc 'echo warmup' | Out-Null
Start-Sleep -Seconds 1

$wslReady = $false
for ($i = 1; $i -le 12; $i++) {
    $probe = wsl -d Ubuntu -- bash -lc 'echo ok' 2>$null
    if ($probe -match "ok") {
        $wslReady = $true
        break
    }
    Write-Host "WSL not fully ready... ($i/12)" -ForegroundColor DarkYellow
    Start-Sleep -Milliseconds 500
}

if (-not $wslReady) {
    Write-Host "ERROR: WSL failed to initialize in time." -ForegroundColor Red
    Read-Host 'Press ENTER to exit'
    exit 1
}

Write-Host "WSL is ready." -ForegroundColor Green

# ------------------------
# 3. Docker Engine Warm-Up
# ------------------------

Write-Host "`nChecking Docker Engine..." -ForegroundColor Yellow

$dockerReady = $false
for ($i = 1; $i -le 20; $i++) {

    wsl -d Ubuntu -- bash -lc 'docker info > /dev/null 2>&1'

    if ($LASTEXITCODE -eq 0) {
        $dockerReady = $true
        break
    }

    Write-Host "Docker not ready yet... ($i/20)" -ForegroundColor DarkYellow
    Start-Sleep -Milliseconds 600
}

if (-not $dockerReady) {
    Write-Host "ERROR: Docker Engine inside WSL failed to start." -ForegroundColor Red
    Read-Host 'Press ENTER to exit'
    exit 1
}

Write-Host "Docker Engine is ready." -ForegroundColor Green

# ------------------------
# 4. Start FamFlix stack
# ------------------------

Write-Host "`n=== Starting FamFlix (WSL/Ubuntu layer) ===" -ForegroundColor Cyan
wsl -d Ubuntu -- bash -lc '~/famflix-stack/famflix.sh start'

# ------------------------
# 5. Port checks
# ------------------------

Write-Host "`nVerifying core ports inside WSL..." -ForegroundColor Yellow

$portsToCheck = @(8081, 8082, 7878, 8989, 9696, 8888, 8181, 6767, 6246, 7863)

foreach ($p in $portsToCheck) {
    $ssOutput = wsl -d Ubuntu -- bash -lc 'ss -tln' 2>$null
    if ($ssOutput -match (":$p\s")) {
        Write-Host "Port $p OK" -ForegroundColor Green
    } else {
        Write-Host "WARNING: Port $p is NOT listening yet." -ForegroundColor Red
    }
}

# ------------------------
# 6. Docker container status
# ------------------------

Write-Host "`nChecking Docker container health..." -ForegroundColor Yellow
wsl -d Ubuntu -- bash -lc 'docker ps --format "{{.Names}}: {{.Status}}"'

# ------------------------
# 7. Final WSL wake
# ------------------------

Write-Host "`nFinalizing WSL startup..." -ForegroundColor Yellow

Start-Process "C:\WINDOWS\system32\wsl.exe" `
    -ArgumentList "--distribution-id","{01f06e87-f7d0-4b69-8c38-698a2d3e1659}", "--cd","~" `
    -WindowStyle Hidden

Start-Sleep -Seconds 4

Write-Host "WSL real-session wake complete." -ForegroundColor Green
Write-Host "`nFamFlix fully started!" -ForegroundColor Green
# Read-Host 'Press ENTER to exit'
Start-Sleep -Seconds 1
