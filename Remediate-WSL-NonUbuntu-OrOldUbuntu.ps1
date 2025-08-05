param([string]$MinVersion = '22.04')

$min = [version]$MinVersion
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')

function Get-NonCompliantDistroNames {
  $list = & wsl.exe -l -q 2>$null
  if (-not $list) { return @() }

  $list |
    ForEach-Object { $_.ToString() } |
    ForEach-Object { [regex]::Replace($_, '\p{C}', '') } | # נקה תווי בקרה/כיוון
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object {
      $n = $_ -replace '^\*',''
      if ($n -like 'Ubuntu-*') {
        $num = $n -replace '^Ubuntu-',''
        try { $v = [version]$num } catch { $v = [version]'0.0' }
        if ($v -lt $min) { $n }
      } else {
        $n
      }
    } | Sort-Object -Unique
}

function Try-Unregister([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  Write-Host "WSL: Unregister '$Name'..."
  Start-Process wsl.exe -ArgumentList @('--terminate', $Name) -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
  $p = Start-Process wsl.exe -ArgumentList @('--unregister', $Name) -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
  return ($p.ExitCode -eq 0)
}

function Force-UnregisterByRegistry([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return }
  Write-Host "WSL: Force-unregister (Registry) '$Name'..."
  wsl.exe --shutdown | Out-Null
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (Test-Path $lxss) {
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
      if ($p.DistributionName -eq $Name) {
        $base = $p.BasePath
        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        if ($base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "Removed registry + base path for '$Name'."
      }
    }
  }
}

# --- שלב 1: הסרת אינסטנסים לא תואמים ---
$toRemove = Get-NonCompliantDistroNames
foreach ($n in $toRemove) {
  if (-not (Try-Unregister -Name $n)) {
    Force-UnregisterByRegistry -Name $n
  }
}

# --- שלב 2–3: הסרת חבילות Store ישנות וניקוי (Admin בלבד) ---
if ($IsAdmin) {
  # הסרת חבילות Ubuntu ישנות לכל המשתמשים
  $appxAll = Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -like 'CanonicalGroupLimited.Ubuntu*' -and
    ($_.Name -match 'Ubuntu(\d+(?:\.\d+)+)') -and
    ([version]$Matches[1] -lt $min)
  }
  foreach ($p in $appxAll) {
    Write-Host "Store: Remove-AppxPackage (AllUsers) '$($p.Name)'..."
    try { Remove-AppxPackage -AllUsers -Package $p.PackageFullName -ErrorAction Stop } catch { Write-Warning $_ }
  }

  # הסרה מ-Provisioned (שלא יופיע למשתמשים חדשים)
  $prov = Get-AppxProvisionedPackage -Online | Where-Object {
    $_.DisplayName -like 'CanonicalGroupLimited.Ubuntu*' -and
    ($_.DisplayName -match 'Ubuntu(\d+(?:\.\d+)+)') -and
    ([version]$Matches[1] -lt $min)
  }
  foreach ($pp in $prov) {
    Write-Host "Store: Remove-AppxProvisionedPackage '$($pp.DisplayName)'..."
    try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop } catch { Write-Warning $_ }
  }

  # ניקוי תיקיות LocalState של Ubuntu ישנות
  $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $pkgRoot) {
    Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'CanonicalGroupLimited.Ubuntu*' } |
      ForEach-Object {
        if ($_.Name -match 'Ubuntu(\d+(?:\.\d+)+)' -and ([version]$Matches[1] -lt $min)) {
          Write-Host "Cleanup: $($_.FullName)"
          Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
  }
} else {
  Write-Host "הרץ כ-Administrator כדי להסיר גם את חבילות ה-Store הישנות (18.04/20.04)."
}

Write-Host 'Done. סגור ופתח מחדש את Windows Terminal.'
