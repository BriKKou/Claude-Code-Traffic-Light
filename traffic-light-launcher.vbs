' Launches the traffic light bridge with no visible window at all.
' powershell.exe -WindowStyle Hidden still flashes a console briefly when
' run from Task Scheduler; WScript.Shell.Run with windowStyle 0 doesn't.
Set objShell = CreateObject("WScript.Shell")
scriptPath = objShell.ExpandEnvironmentStrings("%USERPROFILE%\.claude\hooks\traffic-light.ps1")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
