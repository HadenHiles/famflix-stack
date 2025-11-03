param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart')]
    [string]$Action
)

$stackPath = 'C:\Users\haden\famflix-stack'
$mountRoot = '/mnt/nas'
$mountPoint = "$mountRoot/remote"

. "$PSScriptRoot\famflix-secrets.ps1"

function Wait-ForWSL {
    Write-Host "`n[Init] Waiting for docker-desktop WSL backend to start..." -ForegroundColor Cyan
    $maxWait = 120
    for ($i = 0; $i -lt $maxWait; $i++) {
        $wslStatus = wsl -l -v 2>$null | Select-String "docker-desktop" | Select-String "Running"
        $dockerdUp = docker info --format '{{.ServerVersion}}' 2>$null
        if ($wslStatus -or $dockerdUp) {
            Write-Host "[OK] Docker WSL backend is live." -ForegroundColor Green
            return
        }
        if ($i -eq 0) {
            Write-Host "Waiting for Docker Engine to start (this can take about 20-30s after launch)..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
    Write-Host "[Error] docker-desktop failed to start after $maxWait seconds." -ForegroundColor Red
    exit 1
}

function Mount-NAS {
    Write-Host "`n[Mounting] NAS share inside Docker..." -ForegroundColor Cyan
    Wait-ForWSL
    wsl -d docker-desktop -- mkdir -p "$mountPoint" | Out-Null

    # Mask password for display
    $maskedPassword = if ($password.Length -gt 4) {
        $password.Substring(0, 1) + ('*' * ($password.Length - 4)) + $password.Substring($password.Length - 2)
    }
    else { '*' * $password.Length }

    Write-Host "[Debug] Mount configuration:" -ForegroundColor Yellow
    Write-Host ("   NAS Server : {0}" -f $nasServer)
    Write-Host ("   NAS Share  : {0}" -f $nasShare)
    Write-Host ("   Username   : {0}" -f $username)
    Write-Host ("   Password   : {0}" -f $maskedPassword)
    Write-Host ("   Mount Root : {0}" -f $mountRoot)
    Write-Host ("   Mount Point: {0}" -f $mountPoint)

    $isMounted = wsl -d docker-desktop mount | Select-String "$mountPoint"
    if ($isMounted) {
        Write-Host "[Skip] NAS already mounted at $mountPoint" -ForegroundColor Yellow
        return
    }

    # Build mount command as argument array to avoid PowerShell quote issues
    $mountArgs = @(
        "-d", "docker-desktop",
        "--",
        "mount",
        "-t", "cifs",
        "//${nasServer}/${nasShare}",
        $mountRoot,
        "-o", "username=${username},password=${password},rw,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino"
    )

    Write-Host "`n[Debug] Running mount command inside docker-desktop:" -ForegroundColor Cyan
    Write-Host "   wsl $($mountArgs -join ' ')" -ForegroundColor White

    for ($try = 1; $try -le 3; $try++) {
        Write-Host "Attempt $try mounting //$nasServer/$nasShare..."
        $result = & wsl.exe @mountArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $mounted = wsl -d docker-desktop -- ls "$mountPoint/famflix/media/movies" 2>$null
            if ($mounted) {
                Write-Host "[OK] NAS mounted at $mountPoint" -ForegroundColor Green
                return
            }
        }
        Write-Host "[Warn] Mount failed (try $try). Output:" -ForegroundColor Yellow
        Write-Host $result
        Start-Sleep -Seconds 3
    }

    Write-Host "[Error] Mount failed after multiple attempts. Check NAS credentials or IP." -ForegroundColor Red
    exit 1
}


function Unmount-NAS {
    Write-Host "`n[Unmounting] NAS from Docker..." -ForegroundColor Cyan
    wsl -d docker-desktop -- umount "$mountRoot" 2>$null
    Write-Host "[OK] NAS unmounted." -ForegroundColor Green
}

function Start-Docker {
    if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-Host "[Starting] Docker Desktop..." -ForegroundColor Cyan
        Start-Process 'C:\Program Files\Docker\Docker Desktop.exe'
        Start-Sleep -Seconds 10
    }
    Wait-ForWSL
}

function Start-Stack {
    Write-Host "`n[Starting] FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    docker compose up -d
    Write-Host "[OK] Stack is live!" -ForegroundColor Green
}

function Stop-Stack {
    Write-Host "`n[Stopping] FamFlix stack..." -ForegroundColor Cyan
    Set-Location $stackPath
    docker compose down
    Write-Host "[OK] Stack stopped." -ForegroundColor Green
}

switch ($Action) {
    'start' {
        Start-Docker
        Mount-NAS
        Start-Stack
    }
    'stop' {
        Stop-Stack
        Unmount-NAS
    }
    'restart' {
        Stop-Stack
        Unmount-NAS
        Start-Docker
        Mount-NAS
        Start-Stack
    }
    default {
        Write-Host "Unknown action '$Action'. Use: start | stop | restart" -ForegroundColor Yellow
        exit 1
    }
}
