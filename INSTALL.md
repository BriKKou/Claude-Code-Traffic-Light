# Install plan — for Claude Code

This file is written for an instance of Claude Code to follow, with a human
present to handle the physical steps (wiring, flashing, watching the LEDs).
Hand this whole folder plus this file to Claude Code on a fresh Windows
machine and say "follow INSTALL.md". Everything here is idempotent — safe to
re-run if a step was already done.

Read `README-software.md` for *why* things are built this way (exec-form
hooks, why the bridge is resident, why the port auto-releases) before
troubleshooting something that looks wrong — several odd-looking choices here
are deliberate fixes for specific Windows quirks, documented there.

## 0. What you're installing

A 3-LED status strip (red / orange / green) wired to an Arduino Nano over
USB, driven by Claude Code hooks so it reflects what Claude Code is doing:
orange while working, red when it needs input or approval, green when it's
done and calming down. One PowerShell script does both the always-on "bridge"
that talks to the board and the one-shot "client" that hooks call.

Files in this folder:

| Path | What it is |
|---|---|
| `README.md` / `README_FR.md` | Project overview: features, components, where to start (EN / FR) |
| `traffic-light.ps1` | The one script — bridge mode (no args) and client mode (with an arg) |
| `traffic-light-launcher.vbs` | Starts the bridge with no console window (used by the scheduled task) |
| `traffic-light-task.xml` | Scheduled task definition: logon + resume-from-sleep triggers, retry, no time limit |
| `settings-hooks.json` | The hook entries to merge into the user's Claude Code settings |
| `traffic_light/traffic_light.ino` | Arduino Nano firmware (needs the FastLED library) |
| `README-software.md` / `README-software_FR.md` | Full software reference and troubleshooting (EN / FR) |
| `3D/assembly.md` / `3D/assembly_FR.md` | 3D-printed enclosure + wiring (EN / FR) |
| `3D/*.stl` | Print files for the enclosure |
| `photos/wiring-diagram.jpg` | Wiring reference photo/diagram |

## 1. Prerequisites — confirm with the human before proceeding

- Windows, with Claude Code already installed and working.
- An Arduino Nano (or clone) wired to a 3-LED WS2812B segment. See
  `3D/assembly.md` for the wiring table if it's not built yet.
- Arduino IDE installed, with the **FastLED** library (Library Manager).
- The human needs to do the actual USB flashing — you cannot access the
  serial port or the Arduino IDE directly. Everything else in this plan you
  can do yourself.

## 2. Deploy the script

```
$hooksDir = "$env:USERPROFILE\.claude\hooks"
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
Copy-Item "traffic-light.ps1" "$hooksDir\traffic-light.ps1" -Force
Copy-Item "traffic-light-launcher.vbs" "$hooksDir\traffic-light-launcher.vbs" -Force
```

## 3. Merge the hooks into settings.json

`%USERPROFILE%\.claude\settings.json` is the **global** settings file — it
applies to every project on this machine, not just one. If it doesn't exist
yet, create it with just `{}` first.

- If it has no `hooks` key yet: merge in the whole `hooks` object from
  `settings-hooks.json` as-is.
- If it already has a `hooks` key: merge event-by-event — for each event
  name (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PermissionRequest`, `Notification`, `Stop`, `SessionEnd`) that already has
  entries, **append** this project's hook entry to the existing array rather
  than replacing it, so you don't clobber hooks from something else the user
  has configured.
- Validate the result parses as JSON before considering this step done:
  `Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json | Out-Null`

Every hook command uses the "exec" form (`command` + an `args` array, no
shell). That's deliberate — see README-software.md's Hooks section for why a
plain shell-form command with a hardcoded path used to be needed and no
longer is. Don't "simplify" these back into a single command string; that
reintroduces the bug.

## 4. Firmware — hand off to the human

You cannot do this part. Tell the human to:

1. Open `traffic_light/traffic_light.ino` in the Arduino IDE (the folder name
   must match the `.ino` name — don't rename one without the other).
2. Board: *Arduino Nano*, processor *ATmega328P (Old Bootloader)* on most
   clones (if upload fails with a sync error, that's the setting to flip).
3. Select the right COM port and upload.
4. Confirm the startup self-test runs: the three LEDs sweep top to bottom
   once. If the sweep runs bottom to top, the strip is mounted backwards —
   that's fixed in software (`I_GREEN` / `I_RED` swap at the top of the
   `.ino`), not by re-wiring.

Wait for the human to confirm the upload succeeded before continuing.

## 5. Manual smoke test

Two terminal windows:

```
# window 1 — bridge (leave running)
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1"

# window 2 — client
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1" permission
```

Ask the human to confirm the red LED lit up (blinking) after the second
command, and that window 1's console logged a connect line and a frame. If
window 1 fails with "Access denied" on the COM port, something else already
holds it (a previous bridge, or the Arduino Serial Monitor) — see
README-software.md's Troubleshooting section.

## 6. Auto-start (logon and resume from sleep)

This is a system-level change (registers a scheduled task) that you may be
blocked from running directly ("Access denied" from `schtasks` or
`Register-ScheduledTask`). If so, give the human these exact commands to run
themselves, from this folder, rather than trying to work around the block:

```
schtasks /Delete /TN "Claude Code Traffic Light" /F
schtasks /Create /TN "Claude Code Traffic Light" /XML "traffic-light-task.xml" /F
```

(The `/Delete` fails harmlessly if the task doesn't exist yet.) Use the XML,
not a hand-built `schtasks /SC ONLOGON` one-liner: it carries the resume
trigger, the 5-min retry, the unlimited run time and the VBS launcher — see
README-software.md, section 3, for why each one is needed.

The task doesn't start itself right after being created — it only fires on
the next logon/resume. Start the bridge by hand once after importing it (as
in step 5, but as a hidden background process) so it's running for the
current session too.

## 7. Verify hooks actually fire

Start (or resume) a real Claude Code session and check:

- `claude --debug` shows the hook commands firing, or `/hooks` lists the
  loaded configuration and shows these entries present.
- Orange comes on while Claude is working, and clears via `PostToolUse`.
- Ending the session (closing the window, or a clean exit) eventually turns
  the light off — solid green for ~1 min, then a soft white sweep for a few
  minutes, then off. This only happens after real activity; a freshly
  started bridge with nothing having happened yet should stay dark.

## 8. Report back

Summarize what was actually done versus what's still pending (most likely:
the scheduled task, if you got blocked on step 6), and point the human at
`README-software.md` for tuning (green/animation timing, sweep speed and
brightness, LED colors) and its Troubleshooting section for anything that
doesn't match what's described in step 5 or 7.
