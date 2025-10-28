# Mount-FamFlixNAS.ps1
$nasServer = "10.175.1.101"
$nasShare = "remote"
$username = "USERNAME"
$password = "PASSWORD"
$mountPath = "/mnt/nas"

Write-Host "Mounting $nasServer/$nasShare inside Docker WSL..."

# Make sure Docker is running
if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
    Write-Host "Starting Docker Desktop..."
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    Start-Sleep -Seconds 20
}

# Ensure Docker WSL is up
wsl -d docker-desktop -- echo "Docker WSL ready"

# Create mount folder if missing
wsl -d docker-desktop -- mkdir -p $mountPath

# Mount NAS share inside Docker WSL
wsl -d docker-desktop -- mount -t cifs "//$nasServer/$nasShare" $mountPath -o "username=$username,password=$password,vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777,nounix,noserverino"

# Verify
wsl -d docker-desktop -- ls $mountPath

Write-Host "✅ NAS mounted inside Docker WSL at $mountPath"

# Bring up the stack
docker compose up -d
