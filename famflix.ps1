param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart')]
    [string]$Action
)

# --- Config ---
$stackPath = '/mnt/c/Users/haden/famflix-stack'
$mountRoot = '/mnt/nas'
$sharedMount = '/mnt/wsl/shared-nas'
$wslDistro = 'Ubuntu'

# --- Load secrets ---
. "$PSScriptRoot\famflix-secrets.ps1"

# --- Ask for sudo password once ---
Write-Host "`nEnter your Ubuntu sudo password (used once for all mount operations):"
$securePwd = Read-Host -AsSecureString
$plainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
)

# Helper: run a bash command inside Ubuntu with sudo password piped
function Invoke-WSL {
    param([string]$cmd)
    # Escape single quotes so the command can be safely embedded in a single-quoted bash -c
    $replaceWith = ([char]39) + ([char]34) + ([char]39) + ([char]34) + ([char]39)
    $escaped = $cmd -replace "'", $replaceWith
    $wrapped = "echo '$plainPwd' | sudo -S bash -lc '$escaped'"
    wsl -d $wslDistro -- bash -lc "$wrapped"
}

# --- Wait for Docker ---
function Wait-ForDocker {
    Write-Host "`n[Init] Checking Docker Engine in WSL ($wslDistro)..." -ForegroundColor Cyan
    for ($i = 0; $i -lt 60; $i++) {
        wsl -d $wslDistro -- bash -lc 'docker info >/dev/null 2>&1'
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Docker Engine is live in $wslDistro." -ForegroundColor Green
            return
        }
        if ($i -eq 0) { Write-Host "Waiting for Docker to start inside Ubuntu..." -ForegroundColor Yellow }
        Start-Sleep -Seconds 2
    }
    Write-Host "[Error] Docker not responding inside WSL ($wslDistro)." -ForegroundColor Red
    exit 1
}

# --- Mount NAS ---
function Mount-NAS {
    Write-Host "`n[Mounting] NAS share inside WSL ($wslDistro)..." -ForegroundColor Cyan
    Wait-ForDocker

    $maskedPassword = if ($password.Length -gt 4) {
        $password.Substring(0, 1) + ('*' * ($password.Length - 3)) + $password.Substring($password.Length - 2)
    }
    else { '*' * $password.Length }

    Write-Host "[Debug] NAS config:" -ForegroundColor Yellow
    Write-Host "   NAS Server : $nasServer"
    Write-Host "   NAS Share  : $nasShare"
    Write-Host "   Username   : $username"
    Write-Host "   Password   : $maskedPassword"
    Write-Host "   Mount Root : $mountRoot"

    $mountCmd = @"
mkdir -p '$mountRoot'
mount -t cifs '//$nasServer/$nasShare' '$mountRoot' -o username=$username,password=$password,rw,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino
"@
    Write-Host "[Debug] Mounting NAS..." -ForegroundColor Yellow
    Invoke-WSL $mountCmd

    $bindCmd = @"
mkdir -p '$sharedMount'
mount --bind '$mountRoot' '$sharedMount'
"@
    Write-Host "[Debug] Creating Docker-visible bind mount..." -ForegroundColor Yellow
    Invoke-WSL $bindCmd

    $check = wsl -d $wslDistro -- bash -c "ls '$sharedMount/famflix/media/movies' 2>/dev/null | head -n 1"
    if ($check) {
        Write-Host "[OK] NAS mounted and bound to $sharedMount (Docker-visible)." -ForegroundColor Green
    }
    else {
        Write-Host "[Error] Bind mount exists but media folder is empty/unreadable." -ForegroundColor Red
        exit 1
    }
}

# --- Unmount NAS ---
function Unmount-NAS {
    Write-Host "`n[Unmounting] NAS and bind mounts from WSL ($wslDistro)..." -ForegroundColor Cyan
    Invoke-WSL "umount -f '$sharedMount' >/dev/null 2>&1 || true"
    Invoke-WSL "umount -f '$mountRoot' >/dev/null 2>&1 || true"
    Write-Host "[OK] NAS unmounted." -ForegroundColor Green
}

# --- Stack Controls ---
function Start-Stack {
    Write-Host "`n[Starting] FamFlix stack via Ubuntu Docker..." -ForegroundColor Cyan
    $cmd = @"
cd '$stackPath'
docker compose up -d
"@
    wsl -d $wslDistro -- bash -lc "$cmd"
    Write-Host "[OK] Stack is live!" -ForegroundColor Green

    Write-Host "[Check] Listing Plex media folder..." -ForegroundColor Yellow
    wsl -d $wslDistro -- bash -lc "docker exec plex ls -al /data/media/movies | head -n 10"
}

function Stop-Stack {
    Write-Host "`n[Stopping] FamFlix stack..." -ForegroundColor Cyan
    $cmd = @"
cd '$stackPath'
docker compose down
"@
    wsl -d $wslDistro -- bash -lc "$cmd"
    Write-Host "[OK] Stack stopped." -ForegroundColor Green
}

# --- Main Flow ---
switch ($Action) {
    'start' { Mount-NAS; Start-Stack }
    'stop' { Stop-Stack; Unmount-NAS }
    'restart' { Stop-Stack; Unmount-NAS; Mount-NAS; Start-Stack }
    default { Write-Host ("Unknown action '{0}'. Use: start | stop | restart." -f $Action) -ForegroundColor Yellow; exit 1 }
}