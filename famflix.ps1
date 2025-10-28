<#
FamFlix Control Script
Usage:
    famflix.ps1 start
    famflix.ps1 stop
    famflix.ps1 restart
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "stop", "restart")]
    [string]$Action
)

# ---------- CONFIG ----------
$stackPath = "C:\Users\haden\famflix-stack"
$nasServer = "10.175.1.101"
$nasShare = "remote"
$username = "haden"
$password = "Hockey0709rules"
$mountPath = "/mnt/nas"
# ----------------------------

function Mount-NAS {
    Write-Host "`n🔗 Mounting NAS share inside Docker..." -ForegroundColor Cyan
    wsl -d docker-desktop -- mkdir -p $mountPath | Out-Null
    wsl -d docker-desktop -- mount -t cifs "//$nasServer/$nasShare" $mountPath -o "username=$username,password=$password,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino" 2>$null
    $mounted = (wsl -d docker-desktop -- ls $mountPath 2>$null)
    if (-not $mounted) {
        Write-Host "❌ Mount failed — check NAS connection or credentials." -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "✅ NAS mounted at $mountPath" -ForegroundColor Green
    }
}

function Unmount-NAS {
    Write-Host "`n🔌 Unmounting NAS from Docker..." -ForegroundColor Cyan
    wsl -d docker-desktop -- umount $mountPath 2>$null
    Write-Host "✅ NAS unmounted" -ForegroundColor Green
}

function Start-Docker {
    if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
        Write-Host "🚀 Starting Docker Desktop..." -ForegroundColor Cyan
        Start-Process "C:\Program Files\Docker\Docker Desktop.exe"
        Start-Sleep -Seconds 20
    }
    wsl -d docker-desktop -- echo "Docker WSL ready" | Out-Null
}

function Start-Stack {
    Write-Host "`n🎬 Starting FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    docker compose up -d
    Write-Host "✅ Stack is live!" -ForegroundColor Green
}

function Stop-Stack {
    Write-Host "`n🛑 Stopping FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    docker compose down
    Write-Host "✅ Stack stopped." -ForegroundColor Green
}

# ---------- ACTIONS ----------
switch ($Action) {
    "start" {
        Start-Docker
        Mount-NAS
        Start-Stack
    }
    "stop" {
        Stop-Stack
        Unmount-NAS
    }
    "restart" {
        Stop-Stack
        Unmount-NAS
        Start-Docker
        Mount-NAS
        Start-Stack
    }
}
