<#
.SYNOPSIS
    NightWatch Automated Mistake Detector & Idle Sentinel (v4.0)
.DESCRIPTION
    1. Measures TRUE physical keyboard/mouse idle time via Win32 GetLastInputInfo.
    2. Only acts if computer has been idle for AT LEAST 30 MINUTES (1800 seconds).
    3. Break state has a user-set DURATION and auto-expires when it elapses.
    4. Break state is bound to the OS boot session: if the PC was restarted or
       shut down, any break from the previous session is discarded.
       Sleep and hibernate do NOT reset boot uptime, so breaks survive those.
    5. Never modifies or deletes Desktop files, preventing desktop refresh/flicker.
    6. If 30-min idle is reached without a valid break:
       - Plays 30 seconds of warning beeps.
       - Moving mouse or pressing any key cancels shutdown immediately.
    7. The idle clock is reset when the user comes back (v4.0).
       GetLastInputInfo only sees input delivered to the session's normal
       desktop. Input on the Winlogon secure desktop - unlocking the screen,
       logging in, dismissing a UAC prompt - is NOT visible to it, so the idle
       timer kept running while the user was actually back at the machine.
       The alarm then fired within seconds of an unlock and the PC shut down
       while the user was standing in front of it. The same blind spot made
       the timer start at BOOT after a restart, because the login input is
       secure-desktop input too, which is why the alarm could start beeping
       again right after the PC came back up.
    8. The warning is actually audible (v4.0).
       The alarm now holds the system awake and the display on for its whole
       run. While the machine was in Modern Standby - which is what it does
       when the lid closes or the screen times out - the audio endpoint is
       suspended, the tone was dropped, and the PC shut down in silence.
.PARAMETER Test
    Print a diagnostic report and play the warning alarm once so the user
    can confirm it can actually be heard. Never shuts anything down.
.PARAMETER DryRun
    Run the full detection and alarm logic, but never power the machine off.
    The alarm is shortened so the check is quick. Use it to verify what
    NightWatch WOULD do right now.
#>
[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$DryRun
)

# 1. Compile Win32 LastInputInfo if not already loaded
if (-not ([System.Management.Automation.PSTypeName]'Win32Idle').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public class Win32Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static uint GetIdleTimeMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return (uint)Environment.TickCount - lii.dwTime;
    }
}
'@
}

# 1b. Compile a high-volume alarm using the Win32 waveOut API.
# Console::Beep plays a quiet system tone that is easily missed when the user
# is asleep. waveOut lets us drive the audio device at full volume, so the
# warning is genuinely loud enough to wake someone.
if (-not ([System.Management.Automation.PSTypeName]'NightWatchLoudAlarm').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public class NightWatchLoudAlarm {
    const int WAVE_MAPPER = -1;
    const uint WAVE_FORMAT_PCM = 1;
    const uint WAVE_MAPPER_NO_SOUNDHANDLER_HACK = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEFORMATEX {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    static extern int waveOutOpen(out IntPtr hWaveOut, int uDeviceID, ref WAVEFORMATEX lpFormat, IntPtr dwCallback, IntPtr dwInstance, uint dwFlags);

    [DllImport("winmm.dll")]
    static extern int waveOutPrepareHeader(IntPtr hWaveOut, ref WAVEHDR lpWaveOutHdr, uint uSize);

    [DllImport("winmm.dll")]
    static extern int waveOutWrite(IntPtr hWaveOut, ref WAVEHDR lpWaveOutHdr, uint uSize);

    [DllImport("winmm.dll")]
    static extern int waveOutUnprepareHeader(IntPtr hWaveOut, ref WAVEHDR lpWaveOutHdr, uint uSize);

    [DllImport("winmm.dll")]
    static extern int waveOutReset(IntPtr hWaveOut);

    [DllImport("winmm.dll")]
    static extern int waveOutClose(IntPtr hWaveOut);

    const uint WHDR_DONE = 0x00000001;
    const uint WAVEVOLUME_MAX = (uint)0xFFFFFFFF;

    [DllImport("winmm.dll")]
    static extern int waveOutSetVolume(IntPtr hWaveOut, uint dwVolume);

    /// <summary>Plays a full-volume square-wave tone. Returns false on failure.</summary>
    public static bool PlayTone(int frequency, int milliseconds) {
        IntPtr hWave = IntPtr.Zero;
        GCHandle pin = GCHandle.Alloc(IntPtr.Zero);
        try {
            WAVEFORMATEX fmt = new WAVEFORMATEX();
            fmt.wFormatTag = (ushort)WAVE_FORMAT_PCM;
            fmt.nChannels = 1;          // mono
            fmt.nSamplesPerSec = 44100; // CD-rate, so tones stay clean
            fmt.wBitsPerSample = 16;
            fmt.nBlockAlign = (ushort)(fmt.nChannels * fmt.wBitsPerSample / 8);
            fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
            fmt.cbSize = 0;

            if (waveOutOpen(out hWave, WAVE_MAPPER, ref fmt, IntPtr.Zero, IntPtr.Zero, 0) != 0)
                return false;

            // Drive the device to its maximum output level.
            waveOutSetVolume(hWave, WAVEVOLUME_MAX);

            int numSamples = (int)(fmt.nSamplesPerSec * (milliseconds / 1000.0));
            short[] buffer = new short[numSamples];

            // Square wave at full scale: far louder and far more attention
            // grabbing than the sine the system beep uses.
            int halfPeriod = (int)Math.Max(1L, (long)fmt.nSamplesPerSec / (frequency * 2));
            for (int i = 0; i < numSamples; i++) {
                buffer[i] = ((i / halfPeriod) % 2 == 0) ? (short)32767 : (short)-32768;
            }

            GCHandle b = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            WAVEHDR hdr = new WAVEHDR();
            hdr.lpData = b.AddrOfPinnedObject();
            hdr.dwBufferLength = (uint)(numSamples * sizeof(short));
            hdr.dwBytesRecorded = 0;
            hdr.dwUser = IntPtr.Zero;
            hdr.dwFlags = 0;
            hdr.dwLoops = 0;
            hdr.lpNext = IntPtr.Zero;
            hdr.reserved = IntPtr.Zero;

            if (waveOutPrepareHeader(hWave, ref hdr, (uint)Marshal.SizeOf(typeof(WAVEHDR))) != 0) {
                b.Free();
                return false;
            }

            if (waveOutWrite(hWave, ref hdr, (uint)Marshal.SizeOf(typeof(WAVEHDR))) != 0) {
                waveOutUnprepareHeader(hWave, ref hdr, (uint)Marshal.SizeOf(typeof(WAVEHDR)));
                b.Free();
                return false;
            }

            // Block until the tone finishes so the buffer is not freed early.
            int waited = 0;
            while ((hdr.dwFlags & WHDR_DONE) == 0 && waited < milliseconds + 2000) {
                System.Threading.Thread.Sleep(20);
                waited += 20;
            }

            waveOutReset(hWave);
            waveOutUnprepareHeader(hWave, ref hdr, (uint)Marshal.SizeOf(typeof(WAVEHDR)));
            b.Free();
            return true;
        } catch {
            return false;
        } finally {
            if (hWave != IntPtr.Zero) {
                try { waveOutReset(hWave); } catch { }
                try { waveOutClose(hWave); } catch { }
            }
            try { if (pin.IsAllocated) pin.Free(); } catch { }
        }
    }
}
'@
}

# 1c. Session state + power control.
#
# IsLocked() tells us whether the interactive session is showing the Winlogon
# secure desktop (locked) or the normal desktop (the user is at the machine).
# That single fact is what lets us tell "the user is away" apart from "the
# user just came back and unlocked the screen".
#
# HoldAwake() pins the system and display awake for the duration of the alarm.
# In Modern Standby the audio endpoint is suspended, so a tone played in that
# state is silently dropped - which is why the PC used to shut down with no
# warning at all.
if (-not ([System.Management.Automation.PSTypeName]'NightWatchSession').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NightWatchSession {
    const uint DESKTOP_READOBJECTS  = 0x0001;
    const uint DESKTOP_SWITCHDESKTOP = 0x0100;
    const int  UOI_NAME = 2;

    const uint ES_CONTINUOUS       = 0x80000000;
    const uint ES_SYSTEM_REQUIRED  = 0x00000001;
    const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError=true)]
    static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint SetThreadExecutionState(uint esFlags);

    /// <summary>
    /// True when the session is locked (secure desktop in front).
    /// False when the user is at the machine. If the desktop cannot be
    /// opened we return false, which is the safe direction: we never shut
    /// down a machine we cannot prove is unattended.
    /// </summary>
    public static bool IsLocked() {
        IntPtr h = OpenInputDesktop(0, false, DESKTOP_READOBJECTS | DESKTOP_SWITCHDESKTOP);
        if (h == IntPtr.Zero) return false;
        try {
            int need;
            GetUserObjectInformation(h, UOI_NAME, null, 0, out need);
            StringBuilder sb = new StringBuilder(need + 2);
            if (!GetUserObjectInformation(h, UOI_NAME, sb, sb.Capacity, out need)) return false;
            return !string.Equals(sb.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
        } catch {
            return false;
        } finally {
            try { CloseDesktop(h); } catch { }
        }
    }

    /// <summary>Keeps the system awake and the display on. False if the call failed.</summary>
    public static bool HoldAwake() {
        return SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED) != 0;
    }

    /// <summary>Releases the power hold taken by HoldAwake.</summary>
    public static void ReleaseAwake() {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}
'@
}

# 2. Get true physical idle time in seconds
$idleMs = [Win32Idle]::GetIdleTimeMs()
$winIdleSeconds = [Math]::Floor($idleMs / 1000)
$targetIdleSeconds = 1800 # 30 minutes exact

# Current OS boot uptime in ms. Resets to ~0 on restart/shutdown, keeps
# increasing across sleep and hibernate. This is the boot-session fingerprint.
$currentUptimeMs = [long][Environment]::TickCount

$dataDir = "C:\ProgramData\NightWatch"
if (-not (Test-Path $dataDir)) {
    try { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null } catch {}
}
$stateFile = Join-Path $dataDir "break_state.json"
$idleStateFile = Join-Path $dataDir "idle_state.json"
$logFile = Join-Path $dataDir "mistake_detector.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Write a log line. If the primary log is denied (e.g. running as a non-admin
# user with the default ProgramData ACL), fall back to %TEMP% so a warning is
# never silently lost. Never throws.
#
# The timestamp is taken when the line is WRITTEN, not when the script
# started. Every line used to carry the script's start time, so a run that
# took a minute looked like it had all happened in the same second and the
# log could not be used to tell how long anything actually took.
function Write-Log {
    param([string]$Message)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
    $candidates = @($logFile, (Join-Path $env:TEMP "NightWatch.log"))
    foreach ($f in $candidates) {
        try {
            Add-Content -Path $f -Value $line -ErrorAction Stop
            return
        } catch {}
    }
    # Both paths denied: surface to the user via the console.
    [Console]::Error.WriteLine($line)
}

# -----------------------------------------------------------------
# BREAK STATE RESOLUTION (single source of truth: break_state.json)
# A break is only honoured when BOTH hold:
#   a) it was created in the CURRENT boot session, and
#   b) its duration has not elapsed yet.
# -----------------------------------------------------------------
$isBreakActive = $false
$clearReason = $null
$json = $null

if (Test-Path $stateFile) {
    try {
        $json = Get-Content $stateFile -Raw | ConvertFrom-Json
    } catch { $json = $null }
}

if ($json -and [bool]$json.Active) {
    $isBreakActive = $true

    # (a) Boot-session check. Stored uptime greater than current uptime means
    # the machine rebooted after the break was created, so it is stale.
    # Sleep/hibernate keep uptime monotonic, so those breaks stay valid.
    if ($null -eq $json.BootUptimeMs) {
        # Legacy state with no boot fingerprint: cannot prove it is current.
        $isBreakActive = $false
        $clearReason = "Break state predates boot-session tracking. Break discarded."
    } else {
        $storedUptime = [long]$json.BootUptimeMs
        if ($storedUptime -gt $currentUptimeMs) {
            $isBreakActive = $false
            $clearReason = "PC was restarted or shut down since this break was set. Break discarded."
        }
    }

    # (b) Duration expiry check. Evaluated independently of (a) so a break is
    # still cleared for expiry even if the boot check already flagged it.
    if ($json.ExpiresAt) {
        try {
            $expiry = [DateTime]$json.ExpiresAt
            if ((Get-Date) -gt $expiry) {
                $isBreakActive = $false
                if (-not $clearReason) {
                    $clearReason = "Break duration of $($json.DurationMinutes) min has elapsed. Auto-disabled."
                }
            }
        } catch {
            # Unparseable expiry: treat the break as expired rather than trust it.
            $isBreakActive = $false
            if (-not $clearReason) {
                $clearReason = "Break expiry time unreadable. Break discarded for safety."
            }
        }
    }
}

# Persist the cleared state once, so later runs agree and the toggle button
# reflects reality. Guarded so this only happens on the transition.
# NOTE: the state write and the log append are deliberately SEPARATE try blocks.
# The log lives in ProgramData and can be locked/unwritable (e.g. while another
# instance holds it). If both shared one try, a failing log append would abort
# the block BEFORE the state was flushed, leaving a stale break "active" forever
# and silently swallowed by the catch.
if ($clearReason -and (Test-Path $stateFile)) {
    try {
        $cleared = @{ Active = $false; Timestamp = (Get-Date).ToString("o"); Mode = "AutoCleared" }
        $cleared | ConvertTo-Json | Set-Content -Path $stateFile -Force
    } catch {
        # Could not persist; treat the break as inactive for this run anyway.
    }
    try {
        Write-Log "BREAK CLEARED: $clearReason"
    } catch {}
}

# -----------------------------------------------------------------
# IDLE STATE RESOLUTION
#
# GetLastInputInfo cannot see input that arrives on the Winlogon secure
# desktop: unlocking the screen, logging in, dismissing a UAC prompt. The
# idle counter therefore kept running while the user was actually back at
# the machine, and the alarm fired seconds after an unlock - the PC then
# shut down while the user was standing in front of it. The same blind spot
# made the counter start at BOOT after a restart, because the login input
# is secure-desktop input too.
#
# So the idle time is tracked here, across runs, and reset whenever we can
# prove the user is present:
#   * the PC rebooted      -> the login input was secure-desktop input
#   * the session unlocked -> the user just came back
#   * real input happened  -> the Win32 counter moved backwards
# -----------------------------------------------------------------
$lockedNow = [NightWatchSession]::IsLocked()

$idleState = $null
if (Test-Path $idleStateFile) {
    try { $idleState = Get-Content $idleStateFile -Raw | ConvertFrom-Json } catch { $idleState = $null }
}

$effectiveIdleSeconds = $winIdleSeconds
$idleResetReason = $null
$firstRun = ($null -eq $idleState)

if ($idleState) {
    $prevBootUptimeMs  = 0
    $prevIdleSeconds   = 0
    $prevWinIdleSeconds = 0
    $prevLocked         = $false
    $elapsedSeconds     = 0
    try { $prevBootUptimeMs   = [long]$idleState.BootUptimeMs } catch {}
    try { $prevIdleSeconds    = [double]$idleState.IdleSeconds } catch {}
    try { $prevWinIdleSeconds = [double]$idleState.WinIdleSeconds } catch {}
    try { $prevLocked         = [bool]$idleState.Locked } catch {}
    try { $elapsedSeconds     = ((Get-Date) - [DateTime]$idleState.UpdatedAt).TotalSeconds } catch {}
    if ($elapsedSeconds -lt 0) { $elapsedSeconds = 0 }

    if ($prevBootUptimeMs -gt $currentUptimeMs) {
        # The PC rebooted: the login input happened on the secure desktop and
        # was never counted, so the idle clock starts again from now.
        $effectiveIdleSeconds = 0
        $idleResetReason = "the PC restarted since the last check"
    }
    elseif ($prevLocked -and -not $lockedNow) {
        # The session was locked and is unlocked now: the user came back.
        $effectiveIdleSeconds = 0
        $idleResetReason = "the session was unlocked - you are back"
    }
    elseif ($winIdleSeconds -lt $prevWinIdleSeconds) {
        # The Win32 counter moved backwards: real keyboard/mouse input.
        $effectiveIdleSeconds = $winIdleSeconds
        $idleResetReason = "keyboard or mouse activity"
    }
    else {
        $ours = $prevIdleSeconds + $elapsedSeconds
        if ($lockedNow) {
            # Away: keep counting our own clock.
            $effectiveIdleSeconds = $ours
        }
        else {
            # Present but idle. Never let the Win32 counter win here: while
            # the session was locked it still includes the time from BEFORE
            # the lock, which would fire the alarm while the user is awake.
            $effectiveIdleSeconds = [Math]::Min($ours, $winIdleSeconds)
        }
    }
}

# Persist the tracked idle time so the next run can continue the count.
function Save-IdleState {
    param([double]$IdleSeconds, [bool]$Locked)
    try {
        @{
            IdleSeconds    = [Math]::Round($IdleSeconds, 1)
            WinIdleSeconds = [Math]::Round($winIdleSeconds, 1)
            Locked         = $Locked
            BootUptimeMs   = $currentUptimeMs
            UpdatedAt      = (Get-Date).ToString("o")
        } | ConvertTo-Json | Set-Content -Path $idleStateFile -Force
    } catch {}
}

# -----------------------------------------------------------------
# WARNING ALARM
#
# Holds the system awake for the whole alarm so the tone is not dropped by
# a suspended audio endpoint, and aborts if the user comes back mid-alarm.
# -----------------------------------------------------------------
function Start-WarningAlarm {
    param(
        [int]$Cycles = 36,
        [int]$ToneMs = 750,
        [switch]$IgnoreActivity
    )

    $aborted = $false
    $abortReason = ""
    $tonesPlayed = 0
    $lockedAtStart = [NightWatchSession]::IsLocked()
    $heldAwake = [NightWatchSession]::HoldAwake()

    try {
        # Give the audio and display pipeline a moment to come back up after
        # the system was in standby.
        Start-Sleep -Milliseconds 1500

        for ($i = 0; $i -lt $Cycles; $i++) {
            # Check if user moved mouse or pressed any key
            $latestIdle = [Win32Idle]::GetIdleTimeMs() / 1000
            if ((-not $IgnoreActivity) -and $latestIdle -lt 5) {
                $aborted = $true
                $abortReason = "keyboard or mouse activity"
                break
            }

            # The user unlocked the screen while the alarm was running, so
            # they are back at the machine. Never shut down on someone who
            # is standing in front of the PC.
            if ((-not $IgnoreActivity) -and $lockedAtStart -and -not [NightWatchSession]::IsLocked()) {
                $aborted = $true
                $abortReason = "the session was unlocked - you came back"
                break
            }

            # Loud, full-volume alarm. Alternate between two piercing tones so it
            # cuts through sleep and is impossible to mistake for a normal beep.
            $freq = if ($i % 2 -eq 0) { 1800 } else { 2400 }
            $played = $false
            try {
                $played = [NightWatchLoudAlarm]::PlayTone($freq, $ToneMs)
            } catch {}

            if ($played) {
                $tonesPlayed++
            } else {
                # Fall back to the system beep if waveOut is unavailable.
                try {
                    [Console]::Beep($freq, $ToneMs)
                    $tonesPlayed++
                } catch {
                    try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
                }
            }
        }
    } finally {
        [void][NightWatchSession]::ReleaseAwake()
    }

    return [pscustomobject]@{
        Aborted = $aborted
        Reason  = $abortReason
        HeldAwake = $heldAwake
        TonesPlayed = $tonesPlayed
    }
}

# -----------------------------------------------------------------
# -Test: report the state and play the alarm once so the user can
# confirm it is actually audible. Nothing is ever shut down.
# -----------------------------------------------------------------
if ($Test) {
    Write-Host ""
    Write-Host "  NightWatch diagnostic" -ForegroundColor Cyan
    Write-Host "  ----------------------" -ForegroundColor Cyan
    $upMin = [Math]::Round($currentUptimeMs / 60000, 1)
    Write-Host ("  boot uptime        : {0} min" -f $upMin)
    Write-Host ("  session             : {0}" -f $(if ($lockedNow) { "LOCKED (screen locked - you are away)" } else { "UNLOCKED (you are at the machine)" }))
    Write-Host ("  Win32 idle counter  : {0} s" -f $winIdleSeconds)
    Write-Host ("  tracked idle time   : {0} s" -f ([Math]::Round($effectiveIdleSeconds, 1)))
    if ($idleResetReason) { Write-Host ("  idle clock reset by : {0}" -f $idleResetReason) }
    Write-Host ("  break active        : {0}" -f $isBreakActive)
    Write-Host ""
    Write-Host "  Playing the warning alarm - listen for it." -ForegroundColor Yellow
    $alarm = Start-WarningAlarm -Cycles 4 -ToneMs 750 -IgnoreActivity
    Write-Host ("  alarm held the system awake : {0}" -f $alarm.HeldAwake)
    Write-Host ("  waveOut tones played        : {0} of 4" -f $alarm.TonesPlayed)
    Write-Host ("  alarm ended because        : {0}" -f $(if ($alarm.Aborted) { $alarm.Reason } else { "the full run finished" }))
    Write-Host ""
    exit 0
}

# The very first run after an install only seeds the tracked idle time. It
# must not alarm, otherwise installing the fix while the machine has been
# idle for a while would immediately sound the alarm.
if ($firstRun) {
    Save-IdleState -IdleSeconds $effectiveIdleSeconds -Locked $lockedNow
    Write-Log "IDLE: first run - tracked idle time seeded at $([Math]::Round($effectiveIdleSeconds,1))s. No alarm on this run."
    exit 0
}

# IF COMPUTER IS NOT IDLE FOR 30 MINUTES -> EXIT IMMEDIATELY
# Does not touch any files, does not steal focus, 0% CPU impact.
if ($effectiveIdleSeconds -lt $targetIdleSeconds) {
    Save-IdleState -IdleSeconds $effectiveIdleSeconds -Locked $lockedNow
    exit 0
}

# -----------------------------------------------------------------
# 30 MINUTES OF TRUE INACTIVITY REACHED
# -----------------------------------------------------------------

if ($isBreakActive) {
    # Intentional break is active: DO NOT SHUT DOWN.
    # Leave laptop alone and do not touch any desktop files.
    Save-IdleState -IdleSeconds $effectiveIdleSeconds -Locked $lockedNow
    $logMsg = "INTENTIONAL BREAK: Computer idle for $([Math]::Round($effectiveIdleSeconds/60,1)) mins, but break is active. Shutdown skipped."
    Write-Log $logMsg
    exit 0
}

# -----------------------------------------------------------------
# ACCIDENTAL SLEEP DETECTED: 30-SECOND WARNING BEEP COUNTDOWN
# -----------------------------------------------------------------
$sessionState = if ($lockedNow) { "locked" } else { "unlocked" }
$logMsg = "ACCIDENTAL SLEEP: 30 mins idle reached without break signal (session $sessionState, tracked idle $([Math]::Round($effectiveIdleSeconds,1))s). Starting warning beeps..."
Write-Log $logMsg

# Persist before the alarm so a crash or a shutdown cannot lose the count.
Save-IdleState -IdleSeconds $effectiveIdleSeconds -Locked $lockedNow

$alarmStartedAt = Get-Date
$alarm = Start-WarningAlarm -Cycles $(if ($DryRun) { 4 } else { 36 })

if ($alarm.Aborted) {
    # The user is here: either they moved the mouse, or they unlocked the
    # screen. Both mean the clock starts again from now. It is deliberately
    # NOT the Win32 idle value, which still carries the pre-unlock time and
    # would put the machine straight back into the alarm.
    Save-IdleState -IdleSeconds 0 -Locked ([NightWatchSession]::IsLocked())
    $logMsg = "SHUTDOWN CANCELLED: $($alarm.Reason) during warning beeps. PC stays awake."
    Write-Log $logMsg
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
    exit 0
}

# The alarm ran to the end, so the machine really was idle for that long.
$alarmElapsed = ((Get-Date) - $alarmStartedAt).TotalSeconds
Save-IdleState -IdleSeconds ($effectiveIdleSeconds + $alarmElapsed) -Locked ([NightWatchSession]::IsLocked())

# Warning beeps expired with zero input -> Clean forced shutdown
if ($DryRun) {
    Write-Log "DRY RUN: the warning alarm expired with no response. A real run would shut the PC down here."
    exit 0
}

$logMsg = "SHUTTING DOWN: Warning beeps expired without response. PC protecting battery & SSD."
Write-Log $logMsg

shutdown.exe /s /f /t 0
