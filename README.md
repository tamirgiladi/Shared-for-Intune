& "C:\Users\User\Documents\WSL-Ubuntu-Compliance-Detect_Min22.04_v2.ps1" -MinVersion '22.04.0'



$o = & "C:\Users\User\Documents\WSL-Ubuntu-Compliance-Detect_Min22.04_v2.ps1" -MinVersion '22.04.0' -IncludeDebug | ConvertFrom-Json
$o._debug.Distros | Format-Table Name, ID, Ver -Auto
