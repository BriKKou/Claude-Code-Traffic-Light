# Changelog

All notable changes to this project are documented here.

## [1.1.0] — 2026-10-30

Reliability fixes after several weeks of daily use on a managed Windows 11
machine.

### Added
- `traffic-light-task.xml`: scheduled task with logon + resume-from-sleep
  triggers, 5-min retry for 2 h, restart on failure, no execution time limit.
- `traffic-light-launcher.vbs`: launches the bridge with no console flash.

### Fixed
- Light dead after sleep: no trigger restarted the bridge on resume.
- Bridge killed after 72 h by the task's default execution time limit.
- Bridge killed at boot (EDR initializing): now retried every 5 min.
- Second bridge instance crashed on the busy named pipe: a global mutex now
  makes it exit quietly.
- Endless error loop after a long sleep: the serial port is reset on any
  error in the main loop.
- Red stuck after denying a permission prompt (Claude Code has no hook for
  it): `permission` state now expires after 90 s.

## [1.0.0] — 2026-09-06

Initial release.

### Added
- Arduino Nano + WS2812B firmware (`traffic_light/traffic_light.ino`) driving
  a 3-LED strip (red / orange / green).
- PowerShell bridge + client script (`traffic-light.ps1`) that talks to the
  board over serial and exposes a one-shot client for hooks to call.
- Claude Code hook wiring (`settings-hooks.json`): orange while working, red
  when input/approval is needed, green when done.
- 3D-printed enclosure (4-part STL set in `3D/`) with assembly instructions
  (EN/FR).
- Wiring diagram and build photos (`photos/`).
- Full documentation: project overview, software reference, and install plan
  for a fresh machine (EN/FR).
