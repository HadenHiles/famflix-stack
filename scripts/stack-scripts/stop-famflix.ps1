# ============================
#   FamFlix FULL SHUTDOWN
# ============================

Write-Host "=== Stopping FamFlix (WSL / Ubuntu) ===" -ForegroundColor Cyan

Write-Host "Warming up WSL..." -ForegroundColor Yellow
wsl -- bash -lc 'echo warmup' 2>$null | Out-Null
Start-Sleep -Seconds 1

# Retry until WSL responds or timeout
$wslReady = $false
for ($i = 1; $i -le 10; $i++) {
    $probe = wsl -- bash -lc 'echo ok' 2>$null
    if ($probe -match 'ok') {
        $wslReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}

if ($wslReady) {
    Write-Host "Stopping FamFlix stack inside WSL..." -ForegroundColor Cyan
    wsl -d Ubuntu -- bash -lc '~/famflix-stack/famflix.sh stop' 2>$null
} else {
    Write-Host "WSL not ready - skipping WSL shutdown safely." -ForegroundColor Yellow
}

Write-Host "Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown 2>$null
# Wait until vmmemWSL is gone
while (Get-Process -Name "VmmemWSL" -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
}

# ----- Stop Windows components -----

Write-Host ""
Write-Host "Stopping Jellyseerr (Node)..." -ForegroundColor Yellow
taskkill /F /IM node.exe 2>$null

Write-Host "Stopping Caddy..." -ForegroundColor Yellow
taskkill /F /IM caddy.exe 2>$null

Write-Host "Stopping Cloudflare Tunnel..." -ForegroundColor Yellow
taskkill /F /IM cloudflared.exe 2>$null

Write-Host ""
Write-Host "FamFlix fully stopped!" -ForegroundColor Green
