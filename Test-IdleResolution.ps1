<#
.SYNOPSIS
    Regression test for the NightWatch idle-resolution logic (v4.0).
.DESCRIPTION
    Extracts the real resolution block out of IdleMistakeDetector.ps1 and
    runs it against controlled inputs, so the test exercises the shipped
    code instead of a copy of it.

    The bug it guards against: GetLastInputInfo cannot see input on the
    Winlogon secure desktop, so unlocking the screen and logging in never
    reset the idle counter. The alarm then fired seconds after the user
    came back and the PC powered off while they were standing in front of
    it (see the 2026-11-10 07:20 shutdown in the system event log).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-IdleResolution.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot "IdleMistakeDetector.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Cannot find IdleMistakeDetector.ps1 next to this script."
    exit 1
}
$full = Get-Content $scriptPath -Raw

# Pull the REAL resolution block out of the script.
$startMarker = '$idleState = $null'
$endMarker   = '# Persist the tracked idle time so the next run can continue the count.'
$s = $full.IndexOf($startMarker)
$e = $full.IndexOf($endMarker)
if ($s -lt 0 -or $e -lt 0) {
    Write-Error "Could not locate the idle-resolution block in $scriptPath. The script's structure changed."
    exit 1
}
$block = $full.Substring($s, $e - $s)

$uptime   = [long][Environment]::TickCount
$failures = 0
$script:createdTestFiles = [System.Collections.Generic.List[string]]::new()

# Clean up any leftover test scratch files from earlier interrupted runs
Get-ChildItem -Path $env:TEMP -Filter "nw_idle_test_*.json" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

# A unique scratch file per run. Each case that needs "no state file yet"
# simply switches to a fresh name.
$script:testFile = Join-Path $env:TEMP ("nw_idle_test_" + [guid]::NewGuid().ToString("N") + ".json")
$script:createdTestFiles.Add($script:testFile)

function Invoke-Case {
    param(
        [string]$Name,
        [bool]$LockedNow,
        [double]$WinIdle,
        [hashtable]$Stored,
        [double]$ExpectIdle,
        [string]$ExpectReasonContains
    )
    $script:winIdleSeconds = $WinIdle
    $script:currentUptimeMs = $script:uptime
    $script:lockedNow      = $LockedNow
    $script:idleState      = $null

    if ($null -ne $Stored) {
        $script:testFile = Join-Path $env:TEMP ("nw_idle_test_" + [guid]::NewGuid().ToString("N") + ".json")
        $script:createdTestFiles.Add($script:testFile)
        $Stored | ConvertTo-Json | Set-Content -Path $script:testFile -Force
    } else {
        # A unique file name per case means "no state file yet" needs no delete.
        $script:testFile = Join-Path $env:TEMP ("nw_idle_test_" + [guid]::NewGuid().ToString("N") + ".json")
        $script:createdTestFiles.Add($script:testFile)
    }
    $script:idleStateFile = $script:testFile

    $effectiveIdleSeconds = 0
    $idleResetReason = $null
    $firstRun = $true

    Invoke-Expression $block

    $idleOk = ([Math]::Abs($effectiveIdleSeconds - $ExpectIdle) -lt 1.0)
    $reasonOk = $true
    if ($ExpectReasonContains -and ($idleResetReason -notlike "*$ExpectReasonContains*")) { $reasonOk = $false }

    if ($idleOk -and $reasonOk) {
        Write-Output ("  PASS  {0}" -f $Name)
        Write-Output ("        idle={0}s  reason='{1}'" -f ([Math]::Round($effectiveIdleSeconds, 1)), $idleResetReason)
    } else {
        $script:failures++
        Write-Output ("  FAIL  {0}" -f $Name)
        Write-Output ("        expected idle~{0} reason~'{1}'  GOT idle={2} reason='{3}'" -f `
            $ExpectIdle, $ExpectReasonContains, ([Math]::Round($effectiveIdleSeconds, 1)), $idleResetReason)
    }
}

$twoMinAgo = (Get-Date).AddMinutes(-2).ToString("o")

Write-Output "=== NightWatch idle-resolution test suite ==="
Write-Output ""

try {
    # 1. The real case from 2026-11-10: the session was locked, the user came
    #    back and unlocked it, and the old code still thought 30 minutes had
    #    passed. The unlock must reset the clock.
    Invoke-Case -Name "session unlocked -> clock resets (the shutdown-on-return bug)" `
        -LockedNow $false -WinIdle 1800 `
        -Stored @{ IdleSeconds = 1800; WinIdleSeconds = 1800; Locked = $true; BootUptimeMs = $uptime; UpdatedAt = $twoMinAgo } `
        -ExpectIdle 0 -ExpectReasonContains "unlocked"

    # 2. The PC rebooted since the last check: the login input is secure-desktop
    #    input and was never counted, so the clock must restart from zero.
    Invoke-Case -Name "PC restarted -> clock resets (the beeping-after-restart bug)" `
        -LockedNow $false -WinIdle 1800 `
        -Stored @{ IdleSeconds = 1800; WinIdleSeconds = 1800; Locked = $false; BootUptimeMs = ($uptime + 500000); UpdatedAt = $twoMinAgo } `
        -ExpectIdle 0 -ExpectReasonContains "restarted"

    # 3. Genuine keyboard/mouse input: the Win32 counter moved backwards.
    Invoke-Case -Name "real mouse/keyboard activity -> clock resets" `
        -LockedNow $false -WinIdle 3 `
        -Stored @{ IdleSeconds = 1800; WinIdleSeconds = 900; Locked = $false; BootUptimeMs = $uptime; UpdatedAt = $twoMinAgo } `
        -ExpectIdle 3 -ExpectReasonContains "activity"

    # 4. Present but idle: our own clock keeps counting, capped by the Win32
    #    counter so the two never drift apart.
    Invoke-Case -Name "present and idle -> tracked clock keeps counting" `
        -LockedNow $false -WinIdle 2000 `
        -Stored @{ IdleSeconds = 1800; WinIdleSeconds = 1900; Locked = $false; BootUptimeMs = $uptime; UpdatedAt = $twoMinAgo } `
        -ExpectIdle 1920 -ExpectReasonContains ""

    # 5. Away (locked): our own clock counts, and the Win32 counter - which
    #    still includes the pre-lock time - is deliberately ignored.
    Invoke-Case -Name "away and locked -> tracked clock counts, Win32 counter ignored" `
        -LockedNow $true -WinIdle 100 `
        -Stored @{ IdleSeconds = 1800; WinIdleSeconds = 100; Locked = $true; BootUptimeMs = $uptime; UpdatedAt = $twoMinAgo } `
        -ExpectIdle 1920 -ExpectReasonContains ""

    # 6. First ever run: seed only, no alarm.
    Invoke-Case -Name "first run (no state yet) -> seeds from the Win32 counter" `
        -LockedNow $false -WinIdle 42 -Stored $null -ExpectIdle 42 -ExpectReasonContains ""
} finally {
    foreach ($f in $script:createdTestFiles) {
        if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output ""
if ($failures -eq 0) {
    Write-Host "ALL CASES PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures CASE(S) FAILED" -ForegroundColor Red
    exit 1
}
