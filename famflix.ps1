param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart')]
    [string]$Action
)

# --- CONFIG ---
$stackPath = "/mnt/c/Users/haden/famflix-stack"
$wslDistro = "Ubuntu"
$mountRootNas = "/mnt/nas/famflix/media"
$mountRootF = "/mnt/f"
$sharedNas = "/mnt/wsl/shared-nas/famflix/media"
$sharedF = "/mnt/wsl/shared-nas/f/famflix"
$nasServer = "10.175.1.103"

# --- Load Secrets ---
. "$PSScriptRoot\famflix-secrets.ps1"

# --- Helper to run WSL commands ---
function Invoke-WSL($cmd) {
    wsl -d $wslDistro -- bash -c "$cmd"
}

# --- Request sudo password once ---
$global:sudoPassword = Read-Host "Enter your Ubuntu sudo password (used once for all mount operations)" -AsSecureString
$global:sudoPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sudoPassword)
)

# --- Utility: run with sudo using stored password ---
function Invoke-Sudo($command) {
    Invoke-WSL "echo '$global:sudoPassPlain' | sudo -S bash -c '$command'"
}

# --- Check Docker Engine in Ubuntu ---
function Wait-Docker {
    Write-Host "`n[Init] Checking Docker Engine in WSL ($wslDistro)..." -ForegroundColor Cyan
    $engine = Invoke-WSL "docker info --format '{{.ServerVersion}}' 2>/dev/null"
    if ($engine) {
        Write-Host "[OK] Docker Engine is live in Ubuntu." -ForegroundColor Green
    } else {
        Write-Host "[Error] Docker not available in Ubuntu." -ForegroundColor Red
        exit 1
    }
}

# --- Mount NAS + External Drive ---
function Mount-Volumes {
    Write-Host "`n[Mounting] NAS and F: drive into WSL ($wslDistro)..." -ForegroundColor Cyan
    Wait-Docker

    Write-Host "[Debug] Mounting NAS share..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p '$mountRootNas'"
    Invoke-Sudo "mount -t cifs '//$nasServer/remote/famflix/media' '$mountRootNas' -o username=$username,password=$password,rw,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino"

    Write-Host "[Debug] Binding NAS into Docker-visible path..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p '$sharedNas'"
    Invoke-Sudo "mount --bind '$mountRootNas' '$sharedNas'"

    Write-Host "[Debug] Mounting F: drive..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p '$mountRootF'"
    Invoke-Sudo "mount -t drvfs F: '$mountRootF'"

    Write-Host "[Debug] Binding F:/famflix into Docker-visible path..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p '$sharedF'"
    Invoke-Sudo "mount --bind '$mountRootF/famflix' '$sharedF'"

    # Verification
    $check = Invoke-WSL "ls '$sharedNas/movies' 2>/dev/null | head -5"
    if ($check) {
        Write-Host "[OK] NAS and F: mounts verified." -ForegroundColor Green
    } else {
        Write-Host "[Error] Mount verification failed." -ForegroundColor Red
        exit 1
    }
}

# --- Unmount everything cleanly ---
function Unmount-Volumes {
    Write-Host "`n[Unmounting] NAS and F: mounts..." -ForegroundColor Cyan
    Invoke-Sudo "umount -f '$sharedNas' 2>/dev/null || true"
    Invoke-Sudo "umount -f '$mountRootNas' 2>/dev/null || true"
    Invoke-Sudo "umount -f '$sharedF' 2>/dev/null || true"
    Invoke-Sudo "umount -f '$mountRootF' 2>/dev/null || true"
    Write-Host "[OK] Unmounted all." -ForegroundColor Green
}

# --- Start Stack ---
function Start-Stack {
    Write-Host "`n[Starting] FamFlix stack via Ubuntu Docker..." -ForegroundColor Cyan
    Invoke-WSL "cd '$stackPath' && docker compose up -d"
    Write-Host "[OK] Stack launched." -ForegroundColor Green
    Write-Host "[Check] Listing Plex media folder..." -ForegroundColor Yellow
    Invoke-WSL "docker exec plex ls -al /media/movies | head"
}

# --- Stop Stack ---
function Stop-Stack {
    Write-Host "`n[Stopping] FamFlix stack..." -ForegroundColor Cyan
    Invoke-WSL "cd '$stackPath' && docker compose down"
    Write-Host "[OK] Stack stopped." -ForegroundColor Green
}

# --- Main ---
switch ($Action) {
    'start'   { Mount-Volumes; Start-Stack }
    'stop'    { Stop-Stack; Unmount-Volumes }
    # 'restart' { Stop-Stack; Unmount-Volumes; Mount-Volumes; Start-Stack }
}
