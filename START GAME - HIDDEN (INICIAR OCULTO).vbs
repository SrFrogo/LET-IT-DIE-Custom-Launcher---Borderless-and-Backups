Option Explicit

Dim shell, fileSystem, rootFolder, powershellPath, launcherPath, command, waitForExit
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

rootFolder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
launcherPath = rootFolder & "\_Launcher Files\launcher.ps1"
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & launcherPath & Chr(34)

waitForExit = False
If WScript.Arguments.Named.Exists("selftest") Then
    command = command & " -SelfTest"
    waitForExit = True
End If

WScript.Quit shell.Run(command, 0, waitForExit)
