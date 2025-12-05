# ============================
#   Plex Restart Script
# ============================

Write-Host "Restarting Plex..." -ForegroundColor Yellow

# Plex install directory
$plexDir = "C:\Program Files\Plex\Plex Media Server"
$plexExe = Join-Path $plexDir "Plex Media Server.exe"

# 1. Kill Plex if running
Get-Process "Plex Media Server" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# 2. Start Plex properly using working directory
if (Test-Path $plexExe) {
    Write-Host "Starting Plex from: $plexDir" -ForegroundColor Cyan

    Start-Process -FilePath $plexExe -WorkingDirectory $plexDir

    Write-Host "Plex Media Server launched." -ForegroundColor Green
} else {
    Write-Host "ERROR: Plex executable not found at: $plexExe" -ForegroundColor Red
    exit 1
}

# 3. Restart PlexUpdateService if present
$svc = Get-Service "PlexUpdateService" -ErrorAction SilentlyContinue
if ($svc) {
    Restart-Service "PlexUpdateService" -ErrorAction SilentlyContinue
    Write-Host "Plex Update Service restarted." -ForegroundColor Green
}

Write-Host "Plex restart complete."