# ============================
#   FamFlix FULL RESTART
# ============================

# --- Logging Setup ---
$logDir = "C:\Users\haden\FamFlixLogs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$latest = "$logDir\famflix-latest.log"
$history = "$logDir\famflix-history.log"

# Create/overwrite latest run log
"----- START: $(Get-Date) -----" | Out-File $latest

# Function to write & append to logs
function Log ($msg) {
    $timestamp = "[{0}] " -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp$msg"
    
    $line | Out-File $latest -Append
    $line | Out-File $history -Append
}

# Add entry to main log
Log "FamFlix nightly restart triggered"

Write-Host "=== Restarting FamFlix ===" -ForegroundColor Cyan

$stop = "C:\Users\haden\stop-famflix.ps1"
$start = "C:\Users\haden\start-famflix.ps1"

Write-Host "Stopping FamFlix..." -ForegroundColor Yellow
& $stop

# Wait for all containers to truly exit
$retry = 0
while ($retry -lt 30) {

    # FIX: docker must run inside Ubuntu
    $running = wsl -d Ubuntu -- bash -lc "docker ps --format '{{.Names}}'" 2>$null

    if (-not $running) {
        Write-Host "All containers stopped. Namespace is clean." -ForegroundColor Green
        break
    }

    Write-Host "Waiting for containers to exit... Attempt $retry" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    $retry++
}

# ============================
# FIX: FORCE-KILL MUST RUN WHILE WSL IS STILL ALIVE
# ============================
if ($running) {
    Write-Host "WARNING: Containers still running after wait period. Forcing kill." -ForegroundColor Red

    # FIX: run the kill in Ubuntu BEFORE WSL shuts down
    wsl -d Ubuntu -- bash -lc "docker kill \$(docker ps -q)" 2>$null
}
# ============================

Write-Host "Starting FamFlix..." -ForegroundColor Green
& $start

Write-Host "FamFlix restart complete!" -ForegroundColor Green

Log "FamFlix restart complete."
"----- END: $(Get-Date) -----" | Out-File $latest -Append

# Roll history file to max 500 lines (FIFO behavior)
$maxLines = 500
$lines = Get-Content $history
if ($lines.Count -gt $maxLines) {
    $lines | Select-Object -Last $maxLines | Set-Content $history
}
