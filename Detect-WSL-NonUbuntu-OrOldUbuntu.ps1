# Detection – מדלג אם אין WSL/אין דיסטרואים, או אם כולם Installing/Uninstalling.
# מחזיר Exit 1 רק כשנמצאו דיסטראות לא-תואמים בפועל.

$ErrorActionPreference = 'SilentlyContinue'
$min = [version]'22.04'
$bad = @()

function Get-StableWslNames {
  # נסה קודם -q (שמות בלבד)
  $q = & wsl.exe -l -q 2>$null
  if ($q) {
    return $q |
      ForEach-Object { [regex]::Replace($_, '\p{C}', '') } |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ } |
      ForEach-Object { $_ -replace '^\*','' } |
      Sort-Object -Unique
  }

  # נפילה ל- -v: פרסר שם/סטטוס; דלג על Installing/Uninstalling
  $v = & wsl.exe -l -v 2>$null
  if (-not $v) { return @() }

  $names = @()
  $v | Select-Object -Skip 1 | ForEach-Object {
    $line = [regex]::Replace($_.ToString(), '\p{C}', '')
    $line = $line.Trim()
    if (-not $line) { return }
    if ($line.StartsWith('*')) { $line = $line.Substring(1).Trim() }
    $parts = $line -split ' {2,}'  # NAME  STATE  VERSION
    if ($parts.Count -lt 2) { return }
    $name  = $parts[0]
    $state = $parts[1]
    if ($state -match '^(Installing|Uninstalling)$') { return }  # דלג על טרנזיינט
    $names += $name
  }
  return ($names | Sort-Object -Unique)
}

$names = Get-StableWslNames
if (-not $names -or $names.Count -eq 0) {
  # אין WSL/אין דיסטרואים/הכול בתהליך התקנה/הסרה → אין מה לתקן
  exit 0
}

# בדיקת אי-תאימות
$names | ForEach-Object {
  $name = $_
  if ($name -match '^Ubuntu[^\d]*(\d+(?:\.\d+)+)$') {
    try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
    if ($ver -lt $min) { $bad += "$name (גרסה $ver) לא עומד בתנאים" }
  }
  elseif ($name -like 'Ubuntu*') {
    $bad += "$name (גרסה לא ידועה) לא עומד בתנאים"
  }
  else {
    $bad += "$name אינו Ubuntu 22.04 ומעלה"
  }
}

$bad | ForEach-Object { $_ }
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
