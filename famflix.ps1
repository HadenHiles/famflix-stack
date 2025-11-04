param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart')]
    [string]$Action,
    [switch]$DryRun
)

# --- CONFIG ---
$stackPath = "/mnt/c/Users/haden/famflix-stack"
$wslDistro = "Ubuntu"
$mountRootNas = "/mnt/nas/famflix"
$sharedNas    = "/mnt/wsl/shared-nas/famflix"
$mountRootF   = "/mnt/f"
$sharedF      = "/mnt/wsl/shared-nas/f/famflix"
$nasServer    = "10.175.1.103"

# --- Load Secrets ---
. "$PSScriptRoot\famflix-secrets.ps1"

# --- Quoting helpers & WSL runners ---
function Escape-BashSingleQuotes([string]$text) {
    $SQ = [char]39; $DQ = [char]34
    $replacement = $SQ.ToString() + $DQ + $SQ + $DQ + $SQ
    return ($text -replace "'", $replacement)
}

function Invoke-WSL($cmd) {
    if ($DryRun) {
        Write-Host "[DRYRUN] wsl -d $wslDistro -- bash -lc $cmd" -ForegroundColor DarkGray
        return ""
    }
    wsl -d $wslDistro -- bash -lc "$cmd"
}

# --- Request sudo password once ---
if (-not $DryRun) {
    $global:sudoPassword = Read-Host "Enter your Ubuntu sudo password (used once for all mount operations)" -AsSecureString
    $global:sudoPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sudoPassword)
    )
} else {
    Write-Host "[DRYRUN] Skipping sudo password prompt" -ForegroundColor DarkGray
    $global:sudoPassPlain = ''
}

# --- Utility: run with sudo using stored password ---
function Invoke-Sudo($command) {
    if ($DryRun) {
        Write-Host "[DRYRUN] sudo -S bash -lc $command" -ForegroundColor DarkGray
        return ""
    }
    $escaped = Escape-BashSingleQuotes $command
    return (wsl -d $wslDistro -- bash -lc "echo '$global:sudoPassPlain' | sudo -S bash -lc '$escaped'")
}

Write-Host "[Prep] Cleaning any stale Docker Desktop bind mounts..." -ForegroundColor DarkYellow
Invoke-Sudo "rm -rf /mnt/wsl/docker-desktop-bind-mounts/Ubuntu/* /mnt/wsl/docker-desktop-bind-mounts/default/* 2>/dev/null || true"

# --- Check Docker Engine in Ubuntu ---
function Wait-Docker {
    Write-Host "`n[Init] Checking Docker Engine in WSL ($wslDistro)..." -ForegroundColor Cyan
    if ($DryRun) { Write-Host "[DRYRUN] Skipping Docker check" -ForegroundColor DarkGray; return }
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

    # --- Clean up any stale mounts first ---
    Write-Host "[Prep] Unmounting any stale mounts..." -ForegroundColor DarkYellow
    Invoke-Sudo "umount -f /mnt/wsl/shared-nas/famflix 2>/dev/null || true"
    Invoke-Sudo "umount -f /mnt/nas/famflix 2>/dev/null || true"
    Invoke-Sudo "umount -f /mnt/f 2>/dev/null || true"
    Start-Sleep -Seconds 2

    # --- NAS ---
    Write-Host "[Debug] Mounting NAS share..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p '$mountRootNas'"
    Invoke-Sudo "mount -t cifs '//$nasServer/remote/famflix/media' '$mountRootNas' -o username=$username,password=$password,rw,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino"

    Write-Host "[Debug] Binding NAS into Docker-visible path..." -ForegroundColor Yellow
    Invoke-Sudo "mkdir -p /mnt/wsl/shared-nas"
    Invoke-Sudo "mkdir -p '$sharedNas'"
    Invoke-Sudo "mount --bind '$mountRootNas' '$sharedNas'"

    # --- Verify bind mount worked ---
    $bindCheck = Invoke-WSL ("if mountpoint -q " + $sharedNas + "; then echo ok; else echo fail; fi")
    if ($bindCheck -and $bindCheck.Trim() -eq 'ok') {
        Write-Host "[OK] Bind mount verified at $sharedNas." -ForegroundColor Green
    } else {
        Write-Host "[Error] Bind mount failed for $sharedNas." -ForegroundColor Red
        Invoke-WSL "mount | grep famflix"
        exit 1
    }

    # --- F: Drive ---
    Write-Host "[Debug] Mounting F: drive..." -ForegroundColor Yellow

    $alreadyMounted = Invoke-WSL "mountpoint -q /mnt/f && echo 1 || echo 0"
    if ($alreadyMounted -eq "1") {
        Write-Host "[OK] /mnt/f already mounted - skipping remount." -ForegroundColor Green
    } else {
        Write-Host "[Info] /mnt/f not mounted, attempting mount..." -ForegroundColor Yellow
        Invoke-Sudo "mkdir -p /mnt/f"
        $mountResult = Invoke-Sudo "mount -t drvfs F: /mnt/f 2>/dev/null || echo fail"

        if ($mountResult -match "fail") {
            Write-Host "[Warn] Mount attempt failed - unmounting and retrying..." -ForegroundColor DarkYellow
            Invoke-Sudo "umount -f /mnt/f 2>/dev/null || true"
            Start-Sleep -Seconds 2
            Invoke-Sudo "mount -t drvfs F: /mnt/f"
        }

        $mountedNow = Invoke-WSL "mountpoint -q /mnt/f && echo 1 || echo 0"
        if ($mountedNow -eq "1") {
            Write-Host "[OK] /mnt/f successfully mounted." -ForegroundColor Green
        } else {
            Write-Host "[Error] Failed to mount F: drive even after retry." -ForegroundColor Red
        }

        # --- Bind external F: drive into Docker-visible path ---
        Write-Host "[Debug] Binding F:/famflix into Docker-visible path..." -ForegroundColor Yellow
        Invoke-Sudo "mkdir -p /mnt/wsl/shared-nas/f"
        Invoke-Sudo "mkdir -p '$sharedF'"
        Invoke-Sudo "mount --bind /mnt/f/famflix '$sharedF'"

        # --- Verify bind mount worked ---
        $bindFCheck = Invoke-WSL ("if mountpoint -q " + $sharedF + "; then echo ok; else echo fail; fi")
        if ($bindFCheck -and $bindFCheck.Trim() -eq 'ok') {
            Write-Host "[OK] Bind mount verified at $sharedF." -ForegroundColor Green
        } else {
            Write-Host "[Error] Bind mount failed for $sharedF." -ForegroundColor Red
            Invoke-WSL "mount | grep famflix"
            exit 1
        }

    }

    # --- Verification ---
    Write-Host "[Verify] Checking NAS paths..." -ForegroundColor Yellow
    $nasMovies = Invoke-WSL "ls '$sharedNas/movies' 2>/dev/null | head -5"
    $nasTv     = Invoke-WSL "ls '$sharedNas/tv' 2>/dev/null | head -5"
    $fMounted  = Invoke-WSL ("mountpoint -q '{0}' && echo 1 || echo 0" -f $mountRootF)

    $nasOk = [bool]$nasMovies -or [bool]$nasTv
    $fOk   = ($fMounted -eq '1')

    if ($nasOk) { Write-Host "[OK] NAS content visible at $sharedNas (movies/tv)." -ForegroundColor Green } else { Write-Host "[Warn] NAS content not visible at $sharedNas." -ForegroundColor DarkYellow }
    if ($fOk)   { Write-Host "[OK] F: mounted at $mountRootF." -ForegroundColor Green } else { Write-Host "[Warn] F: not mounted at $mountRootF." -ForegroundColor DarkYellow }

    if (-not $nasOk) {
        Write-Host "[Error] Mount verification failed for NAS." -ForegroundColor Red
        exit 1
    }
}

# --- Unmount everything cleanly ---
function Unmount-Volumes {
    Write-Host "`n[Unmounting] NAS and F: mounts..." -ForegroundColor Cyan
    Invoke-Sudo "umount -f /mnt/wsl/shared-nas/famflix 2>/dev/null || true"
    Invoke-Sudo "umount -f /mnt/nas/famflix 2>/dev/null || true"
    Invoke-Sudo "umount -f /mnt/wsl/shared-nas/f/famflix 2>/dev/null || true"
    Invoke-Sudo "umount -f /mnt/f 2>/dev/null || true"
    Write-Host "[OK] Unmounted all mounts cleanly." -ForegroundColor Green
}

# --- Start Stack ---
function Start-Stack {
    Write-Host "`n[Starting] FamFlix stack via Ubuntu Docker..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "[DRYRUN] cd '$stackPath' && docker compose up -d" -ForegroundColor DarkGray
    } else {
        Invoke-WSL "cd '$stackPath' && docker compose up -d"
    }
    Write-Host "[OK] Stack launched." -ForegroundColor Green
    Write-Host "[Check] Listing Plex media folder..." -ForegroundColor Yellow
    if ($DryRun) {
        Write-Host "[DRYRUN] docker exec plex ls -al /media/movies | head" -ForegroundColor DarkGray
    } else {
        Invoke-WSL "docker exec plex ls -al /media/movies | head"
    }
}

# --- Stop Stack ---
function Stop-Stack {
    Write-Host "`n[Stopping] FamFlix stack..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "[DRYRUN] cd '$stackPath' && docker compose down" -ForegroundColor DarkGray
    } else {
        Invoke-WSL "cd '$stackPath' && docker compose down"
    }
    Write-Host "[OK] Stack stopped." -ForegroundColor Green
}

# --- Main ---
switch ($Action) {
    'start'   { Mount-Volumes; Start-Stack }
    'stop'    { Stop-Stack; Unmount-Volumes }
    # 'restart' { Stop-Stack; Unmount-Volumes; Mount-Volumes; Start-Stack }
}