param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart')]
    [string]$Action
)

# --- Paths & Config ---
$stackPath = 'C:\Users\haden\famflix-stack'
$credFile = "$stackPath\.famflix-secrets.ps1"
$zDrivePath = 'Z:\famflix'
$composeCmd = 'docker compose'

# --- Import credentials safely ---
if (Test-Path $credFile) {
    . $credFile
}
else {
    Write-Host "[Error] Missing credentials file: $credFile" -ForegroundColor Red
    Write-Host "→ Create it with lines like:" -ForegroundColor Yellow
    Write-Host "   `$nasServer = '10.175.1.101'" -ForegroundColor Gray
    Write-Host "   `$nasShare  = 'remote'" -ForegroundColor Gray
    Write-Host "   `$username  = 'haden'" -ForegroundColor Gray
    Write-Host "   `$password  = 'YourNASPassword'" -ForegroundColor Gray
    exit 1
}

# --- Helper: wait for Docker backend ---
function Wait-ForWSL {
    Write-Host "`n[Init] Waiting for docker-desktop WSL backend to start..." -ForegroundColor Cyan
    $maxWait = 120
    for ($i = 0; $i -lt $maxWait; $i++) {
        $running = (wsl -l -v 2>$null | Select-String "docker-desktop" | Select-String "Running")
        $engine = (docker info --format '{{.ServerVersion}}' 2>$null)
        if ($running -or $engine) {
            Write-Host "[OK] Docker WSL backend is live." -ForegroundColor Green
            return
        }
        if ($i -eq 0) {
            Write-Host "Waiting for Docker Engine to start (~20–30s after launch)..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
    Write-Host "[Error] docker-desktop failed to start after $maxWait seconds." -ForegroundColor Red
    exit 1
}

# --- Verify Windows NAS mount ---
function Verify-WindowsMount {
    Write-Host "`n[Check] Verifying Windows NAS mount (Z:)..." -ForegroundColor Cyan
    if (-not (Test-Path $zDrivePath)) {
        Write-Host "[Error] Z: drive not found or disconnected!" -ForegroundColor Red
        Write-Host "→ Please ensure //$nasServer/$nasShare is mounted as Z: in Windows Explorer." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[OK] NAS drive is available at $zDrivePath" -ForegroundColor Green
}

# --- Start Docker Desktop if needed ---
function Start-Docker {
    if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-Host "[Starting] Docker Desktop..." -ForegroundColor Cyan
        Start-Process 'C:\Program Files\Docker\Docker Desktop.exe'
        Start-Sleep -Seconds 10
    }
    Wait-ForWSL
}

# --- No-op mount step (we use Windows Z: now) ---
function Mount-NAS {
    Write-Host "[Mounting] Skipped — using Windows-mounted Z: drive via Docker Desktop bind." -ForegroundColor Yellow
}

# --- Stack control ---
function Start-Stack {
    Write-Host "`n[Starting] FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    & $composeCmd up -d
    Write-Host "[OK] Stack is live!" -ForegroundColor Green
}

function Stop-Stack {
    Write-Host "`n[Stopping] FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    & $composeCmd down
    Write-Host "[OK] Stack stopped." -ForegroundColor Green
}

# --- Actions ---
switch ($Action) {
    'start' {
        Verify-WindowsMount
        Start-Docker
        Mount-NAS
        Start-Stack
    }
    'stop' {
        Stop-Stack
        Write-Host "[OK] No unmount required (Windows manages Z:)" -ForegroundColor Yellow
    }
    'restart' {
        Stop-Stack
        Write-Host "[OK] No unmount required (Windows manages Z:)" -ForegroundColor Yellow
        Verify-WindowsMount
        Start-Docker
        Mount-NAS
        Start-Stack
    }
    default {
        Write-Host "Unknown action '$Action'. Use: start | stop | restart" -ForegroundColor Yellow
        exit 1
    }
}
