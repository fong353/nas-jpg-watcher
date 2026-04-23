' ============================================================
' Silent launcher for scan.cmd — no visible window flash.
' The scheduled task points here instead of scan.cmd directly.
' Run: 0 = SW_HIDE (no window)
' Wait: False = fire and forget
' ============================================================
Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
strPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\scan.cmd"
objShell.Run """" & strPath & """", 0, False
