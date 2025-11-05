<#
.SYNOPSIS
  Manages FamFlix Docker stack inside WSL, including proper mount setup for NAS and external drives.

.USAGE
  ./famflix.ps1 -Action start|stop|restart|status [-DryRun]
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action,
    [switch]$DryRun
)

# -----------------------------
# CONFIGURATION
# -----------------------------
$wslDistro  = "Ubuntu"
$stackPath  = "/mnt/c/Users/haden/famflix-stack"

# Mount targets inside WSL
$mountNAS   = "/mnt/nas/famflix"
$mountEXT   = "/mnt/ext/famflix"
$nasServer  = "10.175.1.103"
$nasUser    = "haden"
$nasPass    = "Hockey0709rules"

# Docker project name
$composeProject = "famflix-stack"

# -----------------------------
# UTILS
# -----------------------------
function Log($msg, $color="Gray") {
    Write-Host $msg -ForegroundColor $color
}
function Run-WSL($cmd) {
    if ($DryRun) { Log "[DRYRUN] wsl -d $wslDistro -- bash -lc '$cmd'" DarkGray; return }
    wsl -d $wslDistro -- bash -lc "$cmd"
}
function Run-Sudo($cmd) {
    if ($DryRun) { Log "[DRYRUN] sudo $cmd" DarkGray; return }
    Run-WSL "echo '$global:sudoPassPlain' | sudo -S bash -lc '$cmd'"
}
function Wait-Docker {
    Log "`n[Check] Docker Engine availability..." Cyan
    if ($DryRun) { Log "[DRYRUN] Skipping Docker check" DarkGray; return }
    $engine = Run-WSL "docker info --format '{{.ServerVersion}}' 2>/dev/null"
    if (-not $engine) { Log "[ERROR] Docker Engine not available inside WSL!" Red; exit 1 }
    Log "[OK] Docker Engine is running ($engine)" Green
}

# -----------------------------
# MOUNT HANDLERS
# -----------------------------
function Mount-Volumes {
    Log "`n[Mounting] NAS + External drives..." Cyan
    Wait-Docker

    # --- Mount NAS ---
    Log "[NAS] Mounting //$nasServer/famflix to $mountNAS" Yellow
    Run-Sudo "umount -f $mountNAS 2>/dev/null || true"
    Run-Sudo "mkdir -p $mountNAS"
    Run-Sudo "mount -t cifs //$nasServer/famflix $mountNAS -o username=$nasUser,password=$nasPass,uid=0,gid=0,file_mode=0777,dir_mode=0777,vers=3.0"
    $nasCheck = Run-WSL "mountpoint -q $mountNAS && echo ok || echo fail"
    if ($nasCheck.Trim() -ne "ok") { Log "[ERROR] NAS mount failed at $mountNAS" Red; exit 1 }
    Log "[OK] NAS mounted successfully." Green

    # --- Mount External Drive ---
    Log "[EXT] Mounting external drive F: to $mountEXT" Yellow
    Run-Sudo "umount -f $mountEXT 2>/dev/null || true"
    Run-Sudo "mkdir -p $mountEXT"
    # Bind via WSL shared path
    Run-Sudo "mount --bind /mnt/wsl/shared-nas/f/famflix $mountEXT"
    $extCheck = Run-WSL "mountpoint -q $mountEXT && echo ok || echo fail"
    if ($extCheck.Trim() -ne "ok") { Log "[ERROR] External drive bind failed at $mountEXT" Red; exit 1 }
    Log "[OK] External drive mounted successfully." Green

    # --- Verify ---
    Run-WSL "ls $mountNAS | head -5"
    Run-WSL "ls $mountEXT | head -5"
}

function Unmount-Volumes {
    Log "`n[Unmounting] NAS + External drives..." Cyan
    Run-Sudo "umount -f $mountNAS 2>/dev/null || true"
    Run-Sudo "umount -f $mountEXT 2>/dev/null || true"
    Log "[OK] Unmounted all volumes." Green
}

# -----------------------------
# DOCKER STACK CONTROL
# -----------------------------
function Start-Stack {
    Log "`n[Starting] FamFlix stack..." Cyan
    Run-WSL "ls '$stackPath' >/dev/null 2>&1"
    $cmd = "docker compose -f '$stackPath/docker-compose.yml' -p $composeProject up -d"
    if ($DryRun) { Log "[DRYRUN] $cmd" DarkGray } else { Run-WSL $cmd }
    Log "[OK] Stack launch triggered." Green
}

function Stop-Stack {
    Log "`n[Stopping] FamFlix stack..." Cyan
    $cmd = "docker compose -f '$stackPath/docker-compose.yml' -p $composeProject down"
    if ($DryRun) { Log "[DRYRUN] $cmd" DarkGray } else { Run-WSL $cmd }
    Log "[OK] Stack stopped." Green
}

function Show-Status {
    Log "`n[Status] Active Docker containers:" Cyan
    Run-WSL "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
}

# -----------------------------
# MAIN EXECUTION
# -----------------------------
if (-not $DryRun) {
    $secure = Read-Host "Enter your Ubuntu sudo password" -AsSecureString
    $global:sudoPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
} else {
    Log "[DRYRUN] Skipping sudo prompt" DarkGray
    $global:sudoPassPlain = ""
}

switch ($Action) {
    'start' {
        Mount-Volumes
        Start-Stack
        Show-Status
    }
    'stop' {
        Stop-Stack
        Unmount-Volumes
    }
    'restart' {
        Stop-Stack
        Unmount-Volumes
        Mount-Volumes
        Start-Stack
        Show-Status
    }
    'status' {
        Show-Status
    }
}