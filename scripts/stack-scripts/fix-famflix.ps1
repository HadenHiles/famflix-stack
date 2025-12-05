# ================================================
#  FamFlix WSL -> Windows Bridge (WSLRelay Version)
# ================================================

Write-Host "Stopping FamFlix services..." -ForegroundColor Yellow

taskkill /F /IM caddy.exe 2>$null
taskkill /F /IM node.exe 2>$null
taskkill /F /IM cloudflared.exe 2>$null

Write-Host "Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown 2>$null
# Wait until vmmemWSL is gone
while (Get-Process -Name "VmmemWSL" -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
}

Write-Host "Getting WSL IP..." -ForegroundColor Cyan

$wslIP = $null
for ($i = 1; $i -le 15; $i++) {
    $ip = (wsl hostname -I 2>$null)
    if ($ip) {
        $wslIP = $ip.Split(" ")[0]
        break
    }
    Start-Sleep -Milliseconds 400
}

if (-not $wslIP) {
    Write-Host "ERROR: Could not obtain WSL IP." -ForegroundColor Red
    exit
}

[System.Environment]::SetEnvironmentVariable("WSL_IP", $wslIP, "Process")
Write-Host "WSL IP is $wslIP" -ForegroundColor Green

# ----- Jellyseerr -----
Write-Host "`nStarting Jellyseerr..." -ForegroundColor Green

Start-Process powershell.exe -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy Bypass",
    "-Command",
    "cd 'C:\Users\haden\FamFlix\jellyseerr'; `$env:HOST='0.0.0.0'; `$env:NODE_ENV='production'; node dist/index.js"
)

# ----- Caddy -----
Write-Host "`nStarting Caddy..." -ForegroundColor Green

Start-Process cmd.exe -ArgumentList @(
    "/c",
    "set WSL_IP=$wslIP && caddy run --config C:\ProgramData\Caddy\Caddyfile --adapter caddyfile"
)

# Optional: restart Cloudflare Tunnel if you want it constantly running
# Start-Process cloudflared.exe -ArgumentList "tunnel", "run"

Write-Host "`nAll done! WSLRelay is forwarding ports automatically." -ForegroundColor Green
