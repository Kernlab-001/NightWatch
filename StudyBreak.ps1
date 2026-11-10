<#
.SYNOPSIS
    NightWatch Study Break - launcher.
.DESCRIPTION
    The dialogs themselves live in NWCore.cs, which is compiled once into
    %LOCALAPPDATA%\NightWatch\NW.Core.<hash>.dll and loaded from there on
    every later run. The C# compiler is therefore only ever invoked when the
    source actually changes.

    The user interface used to be built by this script instead. That works,
    but PowerShell has to create every control and every table cell through
    its own adapter at run time, which measured at about 420ms per dialog.
    The same layout written in C# costs about 40ms, and this file stays small
    enough to parse instantly.

    What is left here is the part that genuinely belongs to the script:
      - loading the compiled library,
      - the brand icon,
      - the break state in C:\ProgramData\NightWatch\break_state.json,
      - the -SelfTest and -Capture harnesses.

    The break_state.json contract is unchanged, so IdleMistakeDetector.ps1
    keeps working exactly as before:
        Active, Timestamp, Mode, DurationMinutes, ExpiresAt, BootUptimeMs

.PARAMETER SelfTest
    Render each dialog to a PNG and run the behavioural self-check, then
    exit, without interaction.
.PARAMETER Capture
    Show each dialog and photograph the real screen instead of using
    DrawToBitmap, then exit. Transparent controls composite differently in
    a live window than they do under WM_PRINT, so -SelfTest can pass while
    the dialog shows a black block on screen. Run this before trusting a
    change that touches backgrounds or the timing card.
.PARAMETER OutDir
    Destination folder for -SelfTest and -Capture output. Defaults to %TEMP%.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Capture,
    [string]$OutDir = $env:TEMP
)

$dataDir = "C:\ProgramData\NightWatch"
if (-not (Test-Path $dataDir)) {
    try { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null } catch {}
}
$stateFile = Join-Path $dataDir "break_state.json"

# Boot-session fingerprint: uptime in ms. Resets on restart/shutdown,
# keeps growing across sleep/hibernate.
$bootUptimeMs = [long][Environment]::TickCount

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==================================================================
# Load the compiled UI library.
#
# Add-Type shells out to the C# compiler, so the library was being rebuilt
# on EVERY launch: ~2s on an idle machine and 10s or more when the CPU is
# busy (which is exactly when the user is least patient). The compiled
# assembly is cached under %LOCALAPPDATA%\NightWatch and keyed by a hash
# of the source, so the first run compiles and every later run just loads
# a DLL. Editing NWCore.cs changes the hash and rebuilds it.
# ==================================================================
if (-not ('NW.Theme' -as [type])) {
    $coreFile = Join-Path $PSScriptRoot "NWCore.cs"
    if (-not (Test-Path $coreFile)) {
        throw "NWCore.cs not found next to this script. NightWatch cannot start without it."
    }
    $coreSource = [System.IO.File]::ReadAllText($coreFile)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($coreSource + "|" + [System.Environment]::Version))
    } finally {
        $sha.Dispose()
    }
    $coreKey = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 16)
    $coreDir = Join-Path $env:LOCALAPPDATA "NightWatch"
    $coreDll = Join-Path $coreDir ("NW.Core.$coreKey.dll")

    $loaded = $false
    if (Test-Path $coreDll) {
        try {
            Add-Type -Path $coreDll
            $loaded = $true
        } catch {
            # A stale or half-written cache entry: fall through and rebuild.
            $loaded = $false
        }
    }
    if (-not $loaded) {
        try {
            if (-not (Test-Path $coreDir)) { New-Item -ItemType Directory -Path $coreDir -Force | Out-Null }
            Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms `
                -OutputAssembly $coreDll -OutputType Library -TypeDefinition $coreSource
            Add-Type -Path $coreDll
        } catch {
            # Could not write or load the cache (read-only profile, locked
            # file): compile in memory so the UI still works.
            Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition $coreSource
        }
    }

    # Every revision of NWCore.cs gets its own DLL, so the cache grows a file
    # at a time. Drop the ones this run did not need. The DLL that is loaded
    # right now is locked by Windows, so its own delete fails and is ignored.
    try {
        Get-ChildItem $coreDir -Filter "NW.Core.*.dll" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne (Split-Path $coreDll -Leaf) } |
            ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {} }
    } catch {}
}

[NW.Theme]::DetectReducedMotion()

# ==================================================================
# Brand assets
#
# The real NightWatch icon lives in assets/. The header shows the
# crescent-and-pause mark cropped out of it - the same crop
# generate_icon.py puts into the small frames of icon.ico, so the
# dialog and the Desktop shortcut show the same artwork.
#
# The finished tile is cached next to the compiled library: decoding
# an 818x818 PNG and rounding its corners on every launch costs far
# more than the icon is worth, and after the first run the cache is a
# 128x128 PNG that loads in a couple of milliseconds.
# ==================================================================
$script:AssetsDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot "assets" } else { Join-Path (Get-Location).Path "assets" }

function Get-BrandImage {
    $iconPath = Join-Path $script:AssetsDir "icon.png"
    if (-not (Test-Path $iconPath)) { return $null }
    try {
        $cacheDir = Join-Path $env:LOCALAPPDATA "NightWatch"
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($iconPath)
            $key = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 12)
        } finally { $sha.Dispose() }

        # v3 is part of the name on purpose: the key covers the SOURCE image
        # only, so without a version tag a changed crop would keep serving
        # the stale tile from the cache.
        $cached = Join-Path $cacheDir ("brand.v3.$key.png")
        if (Test-Path $cached) {
            try { return New-Object System.Drawing.Bitmap($cached) } catch {}
        }

        $src = New-Object System.Drawing.Bitmap($iconPath)
        try {
            $w = $src.Width; $h = $src.Height
            # The WHOLE artwork, not the crescent-and-pause crop: this is the
            # same picture the Desktop shortcut shows, so the header and the
            # shortcut are the same icon.
            $crop = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
            $tile = New-Object System.Drawing.Bitmap(128, 128, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($tile)
            try {
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.Clear([System.Drawing.Color]::Transparent)
                # Round the corners so the tile melts into the header
                # instead of showing up as a pasted-on rectangle.
                $d = 26
                $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
                $clip.AddArc(0, 0, $d, $d, 180, 90)
                $clip.AddArc(128 - $d, 0, $d, $d, 270, 90)
                $clip.AddArc(128 - $d, 128 - $d, $d, $d, 0, 90)
                $clip.AddArc(0, 128 - $d, $d, $d, 90, 90)
                $clip.CloseFigure()
                $g.SetClip($clip)
                $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, 128, 128)), $crop, [System.Drawing.GraphicsUnit]::Pixel)
                $g.ResetClip()
                $clip.Dispose()
            } finally { $g.Dispose() }
            try { $tile.Save($cached, [System.Drawing.Imaging.ImageFormat]::Png) } catch {}
            return $tile
        } finally { $src.Dispose() }
    } catch {
        return $null
    }
}

# The window icon: the real NightWatch icon in the title bar and on the
# taskbar, instead of the generic PowerShell one.
$script:AppIcon = $null
try {
    $icoPath = Join-Path $script:AssetsDir "icon.ico"
    if (Test-Path $icoPath) { $script:AppIcon = New-Object System.Drawing.Icon($icoPath) }
} catch {}

try {
    $brand = Get-BrandImage
    if ($brand) { [NW.Theme]::SetBrandImage($brand) }
} catch {}

try {
    if ($script:AppIcon) { [NW.UI]::SetIcon($script:AppIcon) }
} catch {}

# ==================================================================
# Helpers shared by -SelfTest and -Capture
# ==================================================================
function Stop-FormTimers {
    param($Form)
    # Stop any timer before disposal. A live timer would keep firing into
    # state that the NEXT form has already taken over.
    if ($Form -is [NW.PickerForm]) {
        try { $Form.Clock.Stop(); $Form.Clock.Dispose() } catch {}
    }
    if ($Form -is [NW.ActiveForm]) {
        try { $Form.Clock.Stop(); $Form.Clock.Dispose() } catch {}
    }
}

# ==================================================================
# -SelfTest: render the real dialogs to PNG and check their behaviour
# ==================================================================
function Invoke-SelfTest {
    $dir = if ($OutDir) { $OutDir } else { $env:TEMP }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    function Dump($form, $name) {
        $form.StartPosition = "Manual"
        $form.Location = New-Object System.Drawing.Point(0, 0)
        $form.TopMost = $false
        $form.ShowInTaskbar = $false
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $p = Join-Path $dir $name
        $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Stop-FormTimers $form
        $form.Hide()
        $form.Dispose()
        Write-Host "wrote $p"
    }

    $f1 = [NW.UI]::NewPickerForm()
    Dump $f1 "nw-picker.png"

    # --- behavioural self-check on the real controls -------------------
    $f1c = [NW.UI]::NewPickerForm()
    $f1c.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $script:SelfCheckFails = 0
    function Check($name, [bool]$cond, $detail = "") {
        if ($cond) { Write-Host "[PASS] $name" -ForegroundColor Green }
        else { Write-Host "[FAIL] $name - $detail" -ForegroundColor Red; $script:SelfCheckFails++ }
    }

    $b60 = $f1c.Presets | Where-Object { [int]$_.Tag -eq 60 }
    $b30 = $f1c.Presets | Where-Object { [int]$_.Tag -eq 30 }
    $b60.PerformClick()
    Check "click 60 -> caption updates" ($f1c.StartButton.Caption -eq "Start 60-minute break") "got '$($f1c.StartButton.Caption)'"
    Check "click 60 -> chip becomes selected" ($b60.Selected -and -not $b30.Selected) "60=$($b60.Selected) 30=$($b30.Selected)"
    Check "click 60 -> field follows" ($f1c.NumBox.Text -eq "60") "got '$($f1c.NumBox.Text)'"

    $f1c.NumBox.Text = "6000"
    [System.Windows.Forms.Application]::DoEvents()
    Check "invalid 6000 -> button disabled" (-not $f1c.StartButton.Enabled) "button still enabled"
    Check "invalid 6000 -> error shown" ($f1c.ErrLabel.Text.Length -gt 0) "no error text"

    # The regression that made this feel broken: the 1s clock used to rewrite
    # Enabled/Caption and silently re-enable the button over bad input.
    Start-Sleep -Milliseconds 1400
    [System.Windows.Forms.Application]::DoEvents()
    Check "still disabled after a clock tick" (-not $f1c.StartButton.Enabled) "clock tick re-enabled it"

    $f1c.NumBox.Text = "45"
    [System.Windows.Forms.Application]::DoEvents()
    Check "valid 45 -> re-enabled" ($f1c.StartButton.Enabled) "still disabled"
    Check "valid 45 -> caption updates" ($f1c.StartButton.Caption -eq "Start 45-minute break") "got '$($f1c.StartButton.Caption)'"
    Check "valid 45 -> chips cleared" (-not ($f1c.Presets | Where-Object { $_.Selected } | Measure-Object).Count) "a chip is still selected"

    $f1c.NumBox.Text = "1440"
    [System.Windows.Forms.Application]::DoEvents()
    Check "1440 accepted" ($f1c.StartButton.Enabled -and $f1c.StartButton.Caption -eq "Start 1440-minute break") "got '$($f1c.StartButton.Caption)'"
    $f1c.NumBox.Text = "0"
    [System.Windows.Forms.Application]::DoEvents()
    Check "0 rejected" (-not $f1c.StartButton.Enabled) "0 was accepted"

    Write-Host ""
    Write-Host "Self-check: $($script:SelfCheckFails) failure(s)" -ForegroundColor $(if ($script:SelfCheckFails -eq 0) { "Green" } else { "Red" })
    Stop-FormTimers $f1c
    $f1c.Close()
    $f1c.Dispose()

    # --- active-break form: the 250ms timer must survive the function ---
    $f2c = [NW.UI]::NewActiveForm((Get-Date).AddMinutes(18), 30)
    $f2c.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $firstBig = $f2c.Card.Ring.CenterBig
    $f2c.Clock.Start()
    Start-Sleep -Milliseconds 1600
    [System.Windows.Forms.Application]::DoEvents()
    Check "active ring shows minutes left" ([int]$f2c.Card.Ring.CenterBig -ge 15 -and [int]$f2c.Card.Ring.CenterBig -le 18) "got '$($f2c.Card.Ring.CenterBig)' (was '$firstBig')"
    Check "active ring fraction is partial" ($f2c.Card.Ring.Value -gt 0.4 -and $f2c.Card.Ring.Value -lt 0.8) "got $($f2c.Card.Ring.Value)"
    # The countdown is written by a 250ms timer, so read it a few times
    # rather than trusting a single sample that can land between ticks.
    $clockText = ""
    for ($try = 0; $try -lt 5; $try++) {
        $clockText = $f2c.Card.TimeLabel.Text
        if ($clockText -match '^\d\d:\d\d:\d\d$') { break }
        Start-Sleep -Milliseconds 120
        [System.Windows.Forms.Application]::DoEvents()
    }
    Check "active clock still ticking" ($clockText -match '^\d\d:\d\d:\d\d$') "got '$clockText'"

    $f2c.EndNow = $false
    $f2c.KeepButton.PerformClick()
    Check "Keep break -> does not end it" (-not $f2c.EndNow) "EndNow=$($f2c.EndNow)"
    Stop-FormTimers $f2c
    $f2c.Close()
    $f2c.Dispose()

    Write-Host ""
    Write-Host "Self-check total: $($script:SelfCheckFails) failure(s)" -ForegroundColor $(if ($script:SelfCheckFails -eq 0) { "Green" } else { "Red" })

    $f2 = [NW.UI]::NewActiveForm((Get-Date).AddMinutes(18), 30)
    Dump $f2 "nw-active.png"

    $f3 = [NW.UI]::NewStatusForm("PAUSED", "Break started",
        "Auto-shutdown is paused.", (Get-Date).AddMinutes(45).ToString("HH:mm:ss"),
        "It turns itself off. You don't need to click again.", [NW.Theme]::Cyan, "45", "Got it")
    Dump $f3 "nw-activated.png"
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

# -Capture shows each dialog for real and photographs the screen. DrawToBitmap
# goes through WM_PRINT, which renders transparent controls by asking the parent
# to repaint; a live composited window does not always get that repaint, so a
# control can pass -SelfTest and still show as a black block on screen. This
# is the only check that sees the real thing.
if ($Capture) {
    $dir = if ($OutDir) { $OutDir } else { $env:TEMP }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    function Grab($form, $name) {
        $form.StartPosition = "CenterScreen"
        $form.ShowInTaskbar = $false
        $form.Show()
        $form.Activate()
        # Let layout settle and every animation timer finish before shooting,
        # otherwise the capture races the first paint.
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 1200
        [System.Windows.Forms.Application]::DoEvents()

        $r = $form.Bounds
        $bmp = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.X, $r.Y, 0, 0, $bmp.Size)
        $g.Dispose()
        $p = Join-Path $dir $name
        $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()

        Stop-FormTimers $form
        $form.Close()
        $form.Dispose()
        Write-Host "captured $p"
    }

    $capPicker = [NW.UI]::NewPickerForm()
    Grab $capPicker "cap-picker.png"

    $capActive = [NW.UI]::NewActiveForm((Get-Date).AddMinutes(18), 30)
    Grab $capActive "cap-active.png"

    $capStatus = [NW.UI]::NewStatusForm("PAUSED", "Break started",
        "Auto-shutdown is paused.", (Get-Date).AddMinutes(30).ToString("HH:mm:ss"),
        "It turns itself off. You don't need to click again.", [NW.Theme]::Cyan, "45", "Got it")
    Grab $capStatus "cap-activated.png"
    exit 0
}

# ==================================================================
# State read (SAME validity rules as the detector)
# ==================================================================
$isActive = $false
$expiresAt = $null
$durationMinutes = 0

if (Test-Path $stateFile) {
    try {
        $json = Get-Content $stateFile -Raw | ConvertFrom-Json
        $isActive = [bool]$json.Active
        if ($isActive) {
            $valid = $true
            if ($null -eq $json.BootUptimeMs -or [long]$json.BootUptimeMs -gt $bootUptimeMs) {
                $valid = $false
            }
            if ($valid -and $json.ExpiresAt) {
                try {
                    if ((Get-Date) -gt ([DateTime]$json.ExpiresAt)) { $valid = $false }
                } catch { $valid = $false }
            }
            $isActive = $valid
            if ($isActive) {
                if ($json.DurationMinutes) { $durationMinutes = [int]$json.DurationMinutes }
                if ($json.ExpiresAt) { try { $expiresAt = [DateTime]$json.ExpiresAt } catch {} }
            }
        }
    } catch {}
}

function Save-Inactive {
    $state = @{
        Active = $false
        Timestamp = (Get-Date).ToString("o")
        Mode = "Working"
    } | ConvertTo-Json
    try {
        Set-Content -Path $stateFile -Value $state -Force
    } catch {}
}

# ==================================================================
# BREAK ALREADY RUNNING -> offer to end it early
# ==================================================================
if ($isActive) {
    if (-not $expiresAt) { $expiresAt = (Get-Date).AddMinutes($durationMinutes) }

    $dlg = [NW.UI]::NewActiveForm($expiresAt, $durationMinutes)
    $dlg.Clock.Start()
    $dlg.ShowDialog() | Out-Null
    $dlg.Clock.Stop()
    $dlg.Clock.Dispose()
    $dlg.Dispose()

    if ($dlg.EndNow) {
        Save-Inactive
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        $s = [NW.UI]::NewStatusForm("PROTECTION ARMED", "Break ended early",
            "Auto-shutdown is armed again.", (Get-Date).AddMinutes(30).ToString("HH:mm:ss"),
            "30 minutes of no activity will shut the PC down again.", [NW.Theme]::Success, "30", "Back to studying")
        $s.ShowDialog() | Out-Null
        $s.Dispose()
    }
    exit 0
}

# ==================================================================
# DURATION PICKER
# ==================================================================
$form = [NW.UI]::NewPickerForm()
$form.Clock.Start()
$form.ShowDialog() | Out-Null
$form.Clock.Stop()
$form.Clock.Dispose()
$form.Dispose()

$minutes = [int]$form.ChosenMinutes
if ($minutes -lt 1 -or $minutes -gt 1440) {
    exit 0
}

# ==================================================================
# Enable the break with an explicit expiry and boot fingerprint
# (state contract unchanged - IdleMistakeDetector.ps1 reads this)
# ==================================================================
$now = Get-Date
$expiresAt = $now.AddMinutes($minutes)

$state = @{
    Active = $true
    Timestamp = $now.ToString("o")
    Mode = "OnBreak"
    DurationMinutes = $minutes
    ExpiresAt = $expiresAt.ToString("o")
    BootUptimeMs = $bootUptimeMs
} | ConvertTo-Json
Set-Content -Path $stateFile -Value $state -Force

try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}

$done = [NW.UI]::NewStatusForm("PAUSED", "Break started",
    "Auto-shutdown is paused.", $expiresAt.ToString("HH:mm:ss"),
    "It turns itself off. You don't need to click again.", [NW.Theme]::Cyan, [string]$minutes, "Got it")
$done.ShowDialog() | Out-Null
$done.Dispose()
