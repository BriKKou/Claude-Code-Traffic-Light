# Claude Code status light — software side

A single script, `traffic-light.ps1`, with two modes depending on whether it's
called with an argument:

```
Claude Code hook -> traffic-light.ps1 working -> named pipe -> traffic-light.ps1 (no argument) -> USB serial -> Nano
                      client mode                 pure local    bridge mode, resident
```

Why two roles: Claude Code spawns a fresh process for every event, which dies
right away. It can't keep the serial port open. And opening the port resets
the board — hence a resident bridge that opens it once, and a throwaway
client that just talks to it.

## Multiple Claude Code instances

The bridge keeps one state per instance and displays the combined picture.
The three LEDs are independent, so red and orange can be lit at the same time:

| LED | Lit when |
|---|---|
| Red blinking | at least one instance is waiting for your approval |
| Red solid | at least one instance is waiting for input |
| Orange | at least one instance is working |
| Green | nothing is running, nothing is waiting |

So one instance's `Stop` can no longer turn off another instance's red — that
was the real risk: missing a confirmation prompt.

The instance is identified by the PID of the parent `claude` process, found by
walking up the process chain. That's more solid than a session identifier,
because a PID lets you verify the process is still alive: a window closed
abruptly, which never sends its `SessionEnd`, gets detected and forgotten. If
the PID can't be found, the client falls back to the `session_id` passed by
the hook, expiring after 20 minutes of silence.

## Green behaviour

After the last job finishes: solid green for 1 min, then a soft white
Knight Rider-style sweep across the three LEDs for 4 min, then it turns off.
Configurable at the top of `traffic-light.ps1`:

```powershell
$SolidGreenSec = 60
$IdleAnimMin   = 4
```

The switch to the sweep happens on the firmware side: the bridge always sends
the `S003` frame (red and orange off, green idle), and it's
`traffic_light.ino` that reads that specific frame as a signal to start the
animation instead of just lighting green at low brightness. Sweep speed is
configurable at the top of the `.ino` (`KNIGHT_MS`, in ms per step; higher =
slower). Brightness is configurable via `KNIGHT_SCALE`.

This sequence only fires if an instance actually did work — starting the
bridge without Claude Code ever having done anything doesn't make the light
flash on its own; it stays off.

Note: once off, the light is indistinguishable from a crashed bridge. Set
`$IdleAnimMin = 0` for a permanent idle sweep if you'd rather have that.

The serial port is also released automatically at that point (once `S000` has
been sent): no need to kill the bridge to reflash the board, just wait for the
fade to finish. New activity reopens the port on its own (with a board reset,
same as any time it's opened).

## 1. Firmware

Required library: FastLED (Arduino IDE library manager).

Board: *Arduino Nano*, *ATmega328P (Old Bootloader)* processor on most clones.
If the upload fails with a sync error, that's the setting to change.

On startup, the board sweeps the three LEDs top to bottom: that's the wiring
test. If the sweep starts from the bottom, the strip is mounted backwards —
swap `I_GREEN` and `I_RED` at the top of the file rather than taking it apart.

Serial protocol: a `S<red><orange><green>` frame describes the full state,
each digit being `0` off, `1` on, `2` blinking, `3` idle. `S201` = red
blinking, orange off, green on. `X` turns everything off, `?` returns the
current frame.

## 2. Wiring

| Strip | Nano |
|---|---|
| 5V | 5V |
| GND | GND |
| DIN | D6 |

## 3. Installing the script

Copy `traffic-light.ps1` into `%USERPROFILE%\.claude\hooks\`.

Manual test, in two windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1" permission
```

Run by hand, the client won't find a parent `claude` process and falls back
to the `sid:default` key — that's expected, it still exercises the full chain.

The bridge finds the COM port on its own, by the USB identifier of the
converter chip (CH340, CH9102, FTDI, or the official Arduino chip). No COM
number to configure, and it keeps working if you switch USB ports.

Auto-start at logon:

```
schtasks /Create /TN "Claude Code Traffic Light" /SC ONLOGON /RL LIMITED /F /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%USERPROFILE%\.claude\hooks\traffic-light.ps1`""
```

(One line, PowerShell syntax — the `` ` `` before the inner quotes is
PowerShell's escape character. Don't split it with `^`, that's cmd.exe
syntax and fails in PowerShell.)

## 4. Hooks

Merge `settings-hooks.json` into `%USERPROFILE%\.claude\settings.json` (if the
file already has a `hooks` section, add these entries into it rather than
replacing the file). No path to hand-edit: every hook uses the "exec" form
(`command` + an `args` array), which launches `powershell.exe` directly
without going through an intermediate shell. So it's PowerShell itself that
resolves `$env:USERPROFILE` at run time — the file works as-is once copied
into any `%USERPROFILE%\.claude\`.

(Abandoned earlier approach: the "shell" form — a plain `command` string with
no `args` — goes through Git Bash on Windows when it's installed, which
doesn't understand PowerShell's `$env:USERPROFILE` or cmd's `%USERPROFILE%`.
That's what used to force hardcoding the path.)

| Event | State sent |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PreToolUse` | working |
| `PostToolUse` | working |
| `PermissionRequest` | permission |
| `Notification` | waiting |
| `Stop` | idle |
| `SessionEnd` | end |

`PostToolUse` matters: it's what switches back to orange once you've granted
a permission, otherwise red would stay lit until `Stop`.

Check with `claude --debug` that the hooks fire, or `/hooks` to list the
loaded configuration.

## Troubleshooting

**The board resets on every colour change.** The bridge isn't running and the
client has nobody to talk to — or some other program is holding the port.
Check that `traffic-light.ps1` with no argument is actually running. The
scheduled task is set to `ONLOGON`: it doesn't start on its own right after
being created, run it by hand once first.

**"Access denied" on COM3 when launching `traffic-light.ps1` with no
argument.** Some other program already holds the port — the bridge can only
have one owner at a time. Two common causes:

- A previous bridge is still running in the background (hidden window,
  started by the scheduled task or an earlier test). Find it with
  `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object
  { $_.CommandLine -match 'traffic-light\.ps1' }` and stop it
  (`Stop-Process -Id … -Force`) before relaunching.
- The Arduino IDE has the port open — its Serial Monitor locks it as soon as
  it's opened, and the IDE itself can briefly hold it as soon as a board is
  selected. Close the Serial Monitor (or the IDE) before starting the bridge.

If the bridge fails to open the port, it still tries to create the local
named pipe, which can surface a second, unrelated error
(`BeginWaitForConnection`) — ignore it, it's a side effect of the first one.

**Red stays lit even though everything is done.** An instance was killed
mid-job. The bridge forgets it once its process disappears, but if the key in
use is a `session_id` (no PID found), you have to wait out the 20-minute
expiry. The bridge console logs every instance that disappears.

**Nothing lights up, but the startup self-test works.** The firmware is fine,
it's the software chain. Call `traffic-light.ps1 permission` by hand and watch
the bridge console: it logs every frame sent and the number of tracked
instances.

**The self-test doesn't work either.** Wiring or power. Check the strip's
direction: the printed arrow points away from DIN.

**The bridge can't find the board.** Open Device Manager. If the board shows
up as an unknown device, the CH340 driver is missing. If it shows up with a
USB identifier not in the list, add it to `$VendorIds` at the top of the
script.

**PowerShell refuses to run scripts.** The commands above already pass
`-ExecutionPolicy Bypass`. If needed, `Set-ExecutionPolicy -Scope
CurrentUser RemoteSigned` doesn't require admin rights.

**Reliability bonus (optional).** On this build (3 LEDs, 5 cm of wire, inside
an enclosure), none of the following is necessary — but if the wiring ever
gets longer or the strip grows, a 330 Ω resistor in series on DIN and a
1000 µF capacitor between 5V and GND on the strip side protect against
first-LED glitches and the inrush current at power-on.
