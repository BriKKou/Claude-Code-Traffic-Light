# ---------------------------------------------------------------
#  Claude Code status light — single script, two modes
#
#  No argument -> BRIDGE mode (resident).
#      Keeps the COM port open permanently (so the board only resets
#      once), tracks one state per Claude Code instance, and sends the
#      board the frame that summarizes all of them.
#
#      powershell -NoProfile -ExecutionPolicy Bypass -File traffic-light.ps1
#
#  With an argument -> CLIENT mode (throwaway, called by the hooks).
#      Identifies the calling instance, writes to the named pipe, exits.
#
#      powershell -NoProfile -ExecutionPolicy Bypass -File traffic-light.ps1 working
#
#  States: idle, working, permission, waiting, end
#
#  Windows PowerShell 5.1 (powershell.exe): System.IO.Ports is native there.
#  The named pipe is strictly local, no network port is opened.
# ---------------------------------------------------------------

param([Parameter(Position = 0)][string]$State)

$PipeName = 'claude-traffic-light'
$Baud     = 115200

# ------- green timing -------
$SolidGreenSec = 60      # solid green right after the last job finishes
$IdleAnimMin   = 4       # then idle animation (white sweep, firmware side), before turning off
# -----------------------------

$StaleMinutes  = 20      # slot with no update and no live PID -> forgotten
$RefreshSec    = 30      # periodic re-send of the frame

# =========================== CLIENT MODE ===========================

if ($State) {

    # Identifies the instance: PID of the parent claude process if found
    # (its liveness can be checked), otherwise the session_id passed by
    # the hook on stdin.
    function Get-ClaudeKey {
        $current = $PID
        for ($i = 0; $i -lt 6; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.ParentProcessId) { break }
            $current = $proc.ParentProcessId
            $parent  = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
            if (-not $parent) { break }
            if ($parent.Name -match '^(claude|node)\.exe$') { return "pid:$current" }
        }

        if ([Console]::IsInputRedirected) {
            try {
                $raw = [Console]::In.ReadToEnd()
                $m = [regex]::Match($raw, '"session_id"\s*:\s*"([^"]+)"')
                if ($m.Success) { return "sid:$($m.Groups[1].Value)" }
            } catch { }
        }
        return 'sid:default'
    }

    try {
        $key  = Get-ClaudeKey
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
            '.', $PipeName, [System.IO.Pipes.PipeDirection]::Out)
        $pipe.Connect(250)

        $writer = New-Object System.IO.StreamWriter($pipe)
        $writer.AutoFlush = $true
        $writer.WriteLine("$key|$State")

        $writer.Dispose()
        $pipe.Dispose()
    } catch {
        # bridge absent or busy: ignore it. A hook must never block or
        # make Claude Code fail.
    }
    exit 0
}

# ============================ BRIDGE MODE ===========================

# CH340, CH9102, FTDI, official Arduino chip
$VendorIds = @('VID_1A86&PID_7523', 'VID_1A86&PID_55D4',
               'VID_0403&PID_6001', 'VID_2341')

$script:port         = $null
$script:slots        = @{}      # key -> @{ State; Seen; Pid }
$script:lastFrame    = ''       # last frame sent
$script:lastSentAt   = [datetime]::MinValue
$script:calmSince    = $null
$script:hadActivity  = $false   # while false, no instance has ever
                                 # worked: the light stays off, no green
                                 # just because the bridge started up

function Write-Log([string]$m) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m)
}

function Find-BoardPort {
    $candidates = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\(COM\d+\)' }

    foreach ($d in $candidates) {
        $devId = $d.PNPDeviceID
        foreach ($vid in $VendorIds) {
            if ($devId -like "*$vid*") {
                if ($d.Name -match '\((COM\d+)\)') { return $Matches[1] }
            }
        }
    }
    return $null
}

function Connect-Board {
    if ($script:port -and $script:port.IsOpen) { return $true }

    $name = Find-BoardPort
    if (-not $name) { return $false }

    try {
        $p = New-Object System.IO.Ports.SerialPort $name, $Baud, 'None', 8, 'One'
        # DTR/RTS held low: avoids triggering the auto-reset
        $p.DtrEnable    = $false
        $p.RtsEnable    = $false
        $p.WriteTimeout = 500
        $p.Open()
        Start-Sleep -Milliseconds 1800     # let the bootloader window pass
        $script:port      = $p
        $script:lastFrame = ''             # force the frame to be re-sent
        Write-Log "connected on $name"
        return $true
    } catch {
        Write-Log "failed to open ${name}: $($_.Exception.Message)"
        $script:port = $null
        return $false
    }
}

function Send-Frame([string]$frame) {
    if (-not (Connect-Board)) { return }
    try {
        $script:port.Write($frame)
    } catch {
        try { $script:port.Close() } catch { }
        $script:port = $null
        if (Connect-Board) { try { $script:port.Write($frame) } catch { } }
    }
}

function Set-Slot([string]$key, [string]$state) {
    $script:hadActivity = $true
    if ($state -eq 'end') { $script:slots.Remove($key); return }

    $pidNum = 0
    if ($key -match '^pid:(\d+)$') { $pidNum = [int]$Matches[1] }

    $script:slots[$key] = @{ State = $state; Seen = (Get-Date); Pid = $pidNum }
}

# Drops dead instances: process gone, or slot silent for too long when
# there's no PID to settle it either way.
function Remove-DeadSlots {
    $limit = (Get-Date).AddMinutes(-$StaleMinutes)
    foreach ($key in @($script:slots.Keys)) {
        $s = $script:slots[$key]
        $dead = $false
        if ($s.Pid -gt 0) {
            if (-not (Get-Process -Id $s.Pid -ErrorAction SilentlyContinue)) { $dead = $true }
        } elseif ($s.Seen -lt $limit) {
            $dead = $true
        }
        if ($dead) { $script:slots.Remove($key); Write-Log "instance $key gone" }
    }
}

# Aggregates every slot into one frame. Red and orange can be on at the
# same time; green only lights up once everything is calm.
function Get-Frame {
    $permission = $false; $waiting = $false; $working = $false

    foreach ($s in $script:slots.Values) {
        switch ($s.State) {
            'permission' { $permission = $true }
            'waiting'    { $waiting    = $true }
            'working'    { $working    = $true }
        }
    }

    $red    = if ($permission) { 2 } elseif ($waiting) { 1 } else { 0 }
    $orange = if ($working)    { 1 } else { 0 }

    if ($red -eq 0 -and $orange -eq 0 -and $script:hadActivity) {
        if (-not $script:calmSince) { $script:calmSince = Get-Date }
        $age = (Get-Date) - $script:calmSince
        $green = if ($age.TotalSeconds -lt $SolidGreenSec)    { 1 }
                 elseif ($age.TotalSeconds -lt $SolidGreenSec + $IdleAnimMin * 60) { 3 }
                 else { 0 }
    } else {
        if ($red -ne 0 -or $orange -ne 0) { $script:calmSince = $null }
        $green = 0
    }

    return "S$red$orange$green"
}

function Update-Light {
    Remove-DeadSlots
    $frame = Get-Frame

    # Already idle and the port already released: nothing to report, don't
    # reopen it just to re-send an S000 that nobody's listening for.
    if ($frame -eq 'S000' -and $frame -eq $script:lastFrame -and -not $script:port) {
        return
    }

    $elapsed = (Get-Date) - $script:lastSentAt
    if ($frame -ne $script:lastFrame -or $elapsed.TotalSeconds -ge $RefreshSec) {
        Send-Frame $frame
        if ($frame -ne $script:lastFrame) {
            Write-Log "$frame  ($($script:slots.Count) instance(s))"
        }
        $script:lastFrame  = $frame
        $script:lastSentAt = Get-Date

        # Nothing left to show: release the port so the board can be
        # reflashed without having to kill the bridge. It reopens itself
        # (with a board reset) on the next real activity.
        if ($frame -eq 'S000' -and $script:port) {
            try { $script:port.Close() } catch { }
            $script:port = $null
            Write-Log "port released (nothing to report)"
        }
    }
}

function New-Pipe {
    New-Object System.IO.Pipes.NamedPipeServerStream(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::In,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
}

Write-Log "bridge started, pipe \\.\pipe\$PipeName"
Connect-Board | Out-Null

$pipe  = New-Pipe
$async = $pipe.BeginWaitForConnection($null, $null)

while ($true) {
    try {
        # short wait: leaves room for the green timer and the dead-slot sweep
        if ($async.AsyncWaitHandle.WaitOne(200)) {
            $pipe.EndWaitForConnection($async)

            $reader = New-Object System.IO.StreamReader($pipe)
            $line   = $reader.ReadLine()

            if ($line -and $line -match '^(.+)\|(.+)$') {
                Set-Slot $Matches[1].Trim() $Matches[2].Trim().ToLower()
            }

            $pipe.Dispose()
            $pipe  = New-Pipe
            $async = $pipe.BeginWaitForConnection($null, $null)
        }

        Update-Light

    } catch {
        Write-Log "error: $($_.Exception.Message)"
        try { $pipe.Dispose() } catch { }
        Start-Sleep -Milliseconds 300
        $pipe  = New-Pipe
        $async = $pipe.BeginWaitForConnection($null, $null)
    }
}
