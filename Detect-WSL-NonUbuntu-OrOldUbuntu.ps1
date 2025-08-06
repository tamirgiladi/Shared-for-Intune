# Detection – מדלג אם אין WSL/אין דיסטרואים, ומחזיר 1 רק כשנמצאו לא-תואמים
$ErrorActionPreference = 'SilentlyContinue'
$min = [version]'22.04'
$bad = @()

# נסה להביא רשימת דיסטרואים; אם אין WSL/אין רשומים -> דלג (Exit 0, בלי פלט)
try {
  $list = & wsl.exe -l -q 2>$null
} catch {
  $list = $null
}
if (-not $list -or $list.Count -eq 0) {
  exit 0
}

# נרמל שמות ובדוק אי-תאימות
$list |
  ForEach-Object {
    $name = $_.ToString()
    $name = $name -replace '^\*',''                 # הסר כוכבית ברירת מחדל
    $name = [regex]::Replace($name, '\p{C}', '')    # נקה תווי בקרה/כיוון נסתרים
    $name = $name.Trim()
    if (-not $name) { return }

    if ($name -match '^Ubuntu[^\d]*(\d+(?:\.\d+)+)$') {
      try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
      if ($ver -lt $min) { $bad += "$name (גרסה $ver) לא עומד בתנאים" }
    }
    elseif ($name -like 'Ubuntu*') {
      # Ubuntu בלי מספר גרסה → לא עומד בתנאי
      $bad += "$name (גרסה לא ידועה) לא עומד בתנאים"
    }
    else {
      # כל מה שאינו Ubuntu
      $bad += "$name אינו Ubuntu 22.04 ומעלה"
    }
  }

# פלט + קוד יציאה
$bad | ForEach-Object { $_ }
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
