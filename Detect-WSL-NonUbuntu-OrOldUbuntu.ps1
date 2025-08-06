# Detection – Exit 1 רק כשנמצאו לא-תואמים; מדלג בשקט אם אין WSL/אין דיסטראות.
$ErrorActionPreference = 'SilentlyContinue'
$min = [version]'22.04'
$bad = @()

function Is-HelpLine([string]$s) {
  return ($s -match '^\s*(Usage:|Options:|Examples:|--help|wsl --install|--list|--status)')
}

function Get-WslNames {
  # נסה שיטה 1: quiet
  $q = & wsl.exe --list --quiet 2>$null
  if ($LASTEXITCODE -eq 0 -and $q) {
    $names = @()
    foreach ($l in $q) {
      if (Is-HelpLine $l) { continue }
      $n = ([regex]::Replace($l,'\p{C}','')).Trim() -replace '^\*',''
      if ($n) { $names += $n }
    }
    if ($names.Count) { return ($names | Sort-Object -Unique) }
  }

  # שיטה 2: verbose (NAME  STATE  VERSION)
  $v = & wsl.exe --list --verbose 2>$null
  if ($LASTEXITCODE -eq 0 -and $v) {
    $names = @()
    $lines = $v | Select-Object -Skip 1
    foreach ($l in $lines) {
      $s = ([regex]::Replace($l,'\p{C}','')).Trim()
      if (-not $s -or (Is-HelpLine $s)) { continue }
      if ($s.StartsWith('*')) { $s = $s.Substring(1).Trim() }
      $parts = $s -split ' {2,}'
      if ($parts.Count -ge 1) {
        $state = ($parts | Select-Object -Skip 1 | Select-Object -First 1)
        if ($state -match '^(Installing|Uninstalling)$') { continue } # דלג על טרנזיינט
        $names += $parts[0]
      }
    }
    if ($names.Count) { return ($names | Sort-Object -Unique) }
  }

  # שיטה 3: list רגיל
  $l1 = & wsl.exe --list 2>$null
  if ($LASTEXITCODE -eq 0 -and $l1) {
    $names = @()
    foreach ($l in $l1) {
      if (Is-HelpLine $l) { continue }
      $n = ([regex]::Replace($l,'\p{C}','')).Trim() -replace '^\*',''
      if ($n -and $n -notmatch '^(NAME|Windows Subsystem)') { $names += $n }
    }
    if ($names.Count) { return ($names | Sort-Object -Unique) }
  }

  return @()
}

function Get-UbuntuVersionFromDistro([string]$dName) {
  # מנסה לקרוא את /etc/os-release מתוך הדיסטורו (לשם 'Ubuntu' למשל)
  $os = & wsl.exe -d $dName -- cat /etc/os-release 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $os) { return $null }
  foreach ($line in $os) {
    if ($line -match '^VERSION_ID="?(\d+(?:\.\d+)+)"?') {
      try { return [version]$Matches[1] } catch { return $null }
    }
  }
  return $null
}

$names = Get-WslNames
if (-not $names -or $names.Count -eq 0) {
  exit 0  # אין WSL/אין דיסטראות/הכול בתהליך התקנה/הסרה → דלג
}

foreach ($name in $names) {
  if ($name -match '^Ubuntu[^\d]*(\d+(?:\.\d+)+)$') {
    try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
    if ($ver -lt $min) { $bad += "$name (גרסה $ver) לא עומד בתנאים" }
  }
  elseif ($name -ieq 'Ubuntu') {
    $ver = Get-UbuntuVersionFromDistro -dName 'Ubuntu'
    if ($ver -and $ver -ge $min) {
      # תקין – אל תוסיף לרשימת הבעיות
    } else {
      $msg = if ($ver) { "(גרסה $ver)" } else { "(גרסה לא ידועה)" }
      $bad += "$name $msg לא עומד בתנאים"
    }
  }
  else {
    $bad += "$name אינו Ubuntu 22.04 ומעלה"
  }
}

$bad | ForEach-Object { $_ }
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
