<#
.SYNOPSIS
    Uninstaller for NightWatch
#>

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Please run this script in an Administrator PowerShell window to remove the Scheduled Task."
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        pause
    }
    exit 1
}

Write-Host "Removing NightWatch Scheduled Tasks..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName "NightWatchSentinel" -Confirm:$false -ErrorAction SilentlyContinue

# Every name this product has used, plus any task still driving a
# SilentRunner.vbs or IdleMistakeDetector.ps1 directly. Leaving one behind means it keeps
# firing after the project is moved, popping "Can not find script file" forever.
foreach ($n in @("IdleMistakeDetector", "SleepSafeSentinel")) {
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
try {
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $hits = @($t.Actions | Where-Object {
            $_.Arguments -like "*SilentRunner.vbs*" -or
            $_.Arguments -like "*IdleMistakeDetector.ps1*" -or
            $_.Arguments -like "*StudyBreak.vbs*" -or
            $_.Execute -like "*SilentRunner.vbs*" -or
            $_.Execute -like "*StudyBreak.exe*"
        })
        if ($hits.Count -eq 0) { continue }
        Write-Host " -> Removing '$($t.TaskName)'" -ForegroundColor DarkGray
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning " -> Legacy task sweep skipped: $_"
}

# Revert BCD boot-status policy modifications
Write-Host "Reverting BCD boot-status policy modifications..." -ForegroundColor Yellow
$bcdTargets = @("{current}", "{default}")
try {
    $enumOut = cmd /c "bcdedit /enum all" 2>&1 | Out-String
    if ($enumOut -notmatch "Access is denied") {
        $ids = [regex]::Matches($enumOut, "identifier\s+(?i:\{[0-9a-fA-F\-]+\})") |
               ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        if ($ids) { $bcdTargets += $ids }
    }
} catch {}
$bcdTargets = @($bcdTargets | Select-Object -Unique)

$bcdReverted = 0
foreach ($bcdTarget in $bcdTargets) {
    foreach ($bcdSetting in @("bootstatuspolicy", "recoveryenabled")) {
        $bcdOut = cmd /c "bcdedit /deletevalue $bcdTarget $bcdSetting" 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $bcdReverted++
        }
    }
}
if ($bcdReverted -gt 0) {
    Write-Host " -> Reverted $bcdReverted boot-status setting(s) to Windows defaults." -ForegroundColor Green
}

# Clean up Desktop shortcuts and legacy marker files across all candidate desktops
$desktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$candidateDesktops = @(
    $desktopPath,
    (Join-Path $env:USERPROFILE "Desktop"),
    $(if ($env:OneDrive) { Join-Path $env:OneDrive "Desktop" }),
    $(if ($env:OneDriveConsumer) { Join-Path $env:OneDriveConsumer "Desktop" }),
    $(if ($env:OneDriveCommercial) { Join-Path $env:OneDriveCommercial "Desktop" }),
    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonDesktopDirectory)
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

foreach ($dir in $candidateDesktops) {
    $shortcut = Join-Path $dir "Study Break.lnk"
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
        Write-Host "Removed Desktop shortcut: '$shortcut'" -ForegroundColor Green
    }
    $marker = Join-Path $dir "break_marker.txt"
    if (Test-Path $marker) {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        Write-Host "Removed legacy marker: '$marker'" -ForegroundColor Green
    }
}

# Clean up ProgramData directory
$dataDir = "C:\ProgramData\NightWatch"
if (Test-Path $dataDir) {
    Remove-Item -Path $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed ProgramData directory." -ForegroundColor Green
}

# Clean up LocalAppData cache (%LOCALAPPDATA%\NightWatch - compiled DLLs and brand art)
$localDirs = @()
if ($env:LOCALAPPDATA) {
    $localDirs += (Join-Path $env:LOCALAPPDATA "NightWatch")
}
try {
    $userDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users)$' }
    foreach ($u in $userDirs) {
        $localDirs += (Join-Path $u.FullName "AppData\Local\NightWatch")
    }
} catch {}

foreach ($ld in ($localDirs | Select-Object -Unique)) {
    if (Test-Path $ld) {
        Remove-Item -Path $ld -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed cache directory: '$ld'" -ForegroundColor Green
    }
}

# Clean up temporary logs, screenshots, and test scratch files
$tempPatterns = @("NightWatch.log", "nw_idle_test_*.json", "nw-*.png", "cap-*.png")
foreach ($pat in $tempPatterns) {
    Get-ChildItem -Path $env:TEMP -Filter $pat -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Host "NightWatch uninstalled successfully." -ForegroundColor Green
