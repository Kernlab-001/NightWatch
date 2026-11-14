Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

exePath = scriptDir & "\StudyBreak.exe"
If WScript.Arguments.Count = 0 And fso.FileExists(exePath) Then
    ' Fast path: execute compiled binary directly (<30ms, zero console)
    WshShell.Run """" & exePath & """", 1, False
    WScript.Quit
End If

' Script path: launch PowerShell script with window hidden (zero console flash)
psScript = scriptDir & "\StudyBreak.ps1"
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & psScript & """", 0, False
