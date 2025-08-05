# מצא דיסטרואים שאינם Ubuntu 22.04 ומעלה (מדפיס רק את ה"לא תקינים")
# אם נמצאו לא-תקינים -> Exit 1; אחרת Exit 0

$ErrorActionPreference = 'SilentlyContinue'
$min = [version]'22.04'
$bad = @()

# אם אין WSL מותקן - לא נחשב כתקין (ידווח "אין WSL")
$wslList = & wsl.exe -l -q 2>$null
if (-not $wslList) {
  $bad += 'WSL אינו זמין במערכת (wsl.exe -l -q החזיר פלט ריק/שגיאה)'
} else {
  $wslList |
    ForEach-Object {
      $name = $_.ToString()
      $name = $name -replace '^\*',''                 # הסר כוכבית של ברירת מחדל
      $name = [regex]::Replace($name, '\p{C}', '')    # נקה תווי בקרה/כיוון נסתרים
      $name = $name.Trim()
      if (-not $name) { return }

      if ($name -match '^Ubuntu(?:[^\d]*)(\d+)\.(\d+)$') {
        $ver = [version]::new([int]$Matches[1], [int]$Matches[2])
        if ($ver -lt $min) { $bad += "$name (גרסה $ver) לא עומד בתנאים" }
      }
      elseif ($name -like 'Ubuntu*') {
        # Ubuntu בלי מספר גרסה → התייחס כלא עומד בתנאים
        $bad += "$name (גרסה לא ידועה) לא עומד בתנאים"
      }
      else {
        $bad += "$name אינו Ubuntu 22.04 ומעלה"
      }
    }
}

$bad | ForEach-Object { $_ }   # הדפסה בלבד
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
