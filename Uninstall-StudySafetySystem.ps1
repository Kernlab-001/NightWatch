<#
.SYNOPSIS
    Uninstaller for NightWatch
#>

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Please run this script in an Administrator PowerShell window to remove the Scheduled Task."
    pause
    exit 1
}

Write-Host "Removing NightWatch Scheduled Tasks..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName "NightWatchSentinel" -Confirm:$false -ErrorAction SilentlyContinue

# Every name this product has used, plus any task still driving a
# SilentRunner.vbs. Leaving one behind means it keeps firing after the
# project is moved, popping "Can not find script file" forever.
foreach ($n in @("IdleMistakeDetector", "SleepSafeSentinel")) {
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
try {
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $hits = @($t.Actions | Where-Object { $_.Arguments -like "*SilentRunner.vbs*" })
        if ($hits.Count -eq 0) { continue }
        Write-Host " -> Removing '$($t.TaskName)'" -ForegroundColor DarkGray
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning " -> Legacy task sweep skipped: $_"
}

# Clean up the legacy break_marker.txt if an older version left one behind.
# Current versions never create it, so this is a no-op for fresh installs.
$desktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$shortcut = Join-Path $desktopPath "Study Break.lnk"
if (Test-Path $shortcut) {
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Write-Host "Removed Desktop shortcut." -ForegroundColor Green
}

foreach ($markerDir in @($desktopPath, (Join-Path $env:USERPROFILE "Desktop"), $(if ($env:OneDrive) { Join-Path $env:OneDrive "Desktop" }))) {
    if (-not $markerDir) { continue }
    $marker = Join-Path $markerDir "break_marker.txt"
    if (Test-Path $marker) {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        Write-Host "Removed legacy marker: $marker" -ForegroundColor Green
    }
}

$dataDir = "C:\ProgramData\NightWatch"
if (Test-Path $dataDir) {
    Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "NightWatch uninstalled successfully." -ForegroundColor Green
