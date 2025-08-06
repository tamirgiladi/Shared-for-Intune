פקודות להרצה לוקאלית של הCompliance:


& "C:\Users\User\Documents\WSL-Ubuntu-Compliance-Detect_Min22.04_v2.ps1" -MinVersion '22.04.0'

$o = & "C:\Users\User\Documents\WSL-Ubuntu-Compliance-Detect_Min22.04_v2.ps1" -MinVersion '22.04.0' -IncludeDebug | ConvertFrom-Json
$o._debug.Distros | Format-Table Name, ID, Ver -Auto


פקודות להרצה לוקאלית של הDetect+Remediation:


& "C:\Users\User\Documents\Detect-WSL-NonUbuntu-OrOldUbuntu.ps1"
$LASTEXITCODE  # 0=אין לא-תואמים, 1=נמצאו לא-תואמים


& "C:\Users\User\Documents\Remediate-WSL-NonUbuntu-OrOldUbuntu.ps1" -MinVersion '22.04'
