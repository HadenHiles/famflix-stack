param([Parameter(Mandatory = $true)][string]$Path)
Write-Host ("Analyzing: {0}" -f $Path) -ForegroundColor Cyan
try {
    $lineCount = (Get-Content -Path $Path -ErrorAction Stop).Count
    Write-Host ("Lines: {0}" -f $lineCount) -ForegroundColor DarkGray
}
catch {
    Write-Host ("Failed to read file: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}

$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ("{0} @line {1}" -f $_.Message, $_.Extent.StartLineNumber) -ForegroundColor Red }
    $tail = Get-Content -Path $Path -Tail 3
    Write-Host "--- File tail ---" -ForegroundColor DarkGray
    $tail | ForEach-Object { Write-Host $_ }
    exit 1
}
else {
    Write-Host "SYNTAX OK" -ForegroundColor Green
}
