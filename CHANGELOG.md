# Changelog

All notable changes to this project are documented here.

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
