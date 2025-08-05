# ⚠️ מסיר בפועל (unregister) כל דיסטרו שאינו Ubuntu ≥ 22.04.
# הפעולה מוחקת לצמיתות את קבצי הדיסטרו (rootfs והמשתמשים שבתוכו).
# הרץ בהקשר המשתמש (Logged-on credentials = Yes) כדי להסיר את האינסטנסים של המשתמש.

$ErrorActionPreference = 'SilentlyContinue'
$min = [version]'22.04'
$toRemove = @()

# אסוף דיסטרואים להסרה
wsl.exe -l -q |
  ForEach-Object {
    $name = $_.ToString()
    $name = $name -replace '^\*',''                 # הסר כוכבית ברירת מחדל
    $name = [regex]::Replace($name, '\p{C}', '')    # נקה תווי בקרה/כיוון נסתרים
    $name = $name.Trim()
    if (-not $name) { return }

    if ($name -match '^Ubuntu(?:[^\d]*)(\d+)\.(\d+)$') {
      $ver = [version]::new([int]$Matches[1], [int]$Matches[2])
      if ($ver -lt $min) { $toRemove += $name }
    }
    elseif ($name -like 'Ubuntu*') {
      # Ubuntu בלי מספר גרסה → הסר
      $toRemove += $name
    }
    else {
      # כל מה שאינו Ubuntu
      $toRemove += $name
    }
  }

$toRemove = $toRemove | Sort-Object -Unique

# נסה להסיר
$removed = @()
$failed  = @()

foreach ($name in $toRemove) {
  Write-Host "Unregistering '$name'..."
  & wsl.exe --terminate "$name" 2>$null
  & wsl.exe --unregister "$name"
  if ($LASTEXITCODE -eq 0) {
    Write-Host "OK: '$name' הוסר."
    $removed += $name
  } else {
    Write-Warning "נכשל להסיר '$name' (ExitCode=$LASTEXITCODE)."
    $failed += $name
  }
}

# סיכום ללוג
if ($removed.Count) { Write-Host "Removed: $($removed -join ', ')" }
if ($failed.Count)  { Write-Warning "Failed:  $($failed  -join ', ')" }

# ל-Proactive Remediations לא נדרש קוד יציאה מיוחד; משאירים 0.
exit 0
