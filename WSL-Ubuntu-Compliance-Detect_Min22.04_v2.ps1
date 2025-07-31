param(
    [string] $MinVersion = '22.04.0',
    [switch] $NonUbuntuIsNonCompliant,
    [switch] $IncludeDebug
)

if (-not $PSBoundParameters.ContainsKey('NonUbuntuIsNonCompliant')) {
    $NonUbuntuIsNonCompliant = $true
}

function Clean-WslName {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $s = $s -replace '\x00','' -replace '^\*','' -replace '\p{Cf}',''
    $s = $s.Trim()
    # קו הגנה נוסף: שם תקני בלבד (אותיות/מספרים/מקף/קו תחתון/נקודה, עד 30 תווים, בלי רווחים)
    if ($s -eq '' -or $s.Length -gt 30 -or $s -notmatch '^[A-Za-z0-9._-]+$' -or $s -match '(.)\1{8,}') { return $null }
    # לא שמות מוזרים כמו "Ubuntu-22.04Ubuntu-22.04"
    if ($s -match '(.+)\1') { return $null }
    # שמות בעייתיים נוספים (טקסט שגוי)
    if ($s -match 'usage:|options?:|copyright|error|no installed distributions|is not recognized|failed|cannot|do not|windows|subsystem|list|download|help') { return $null }
    return $s
}


function Get-RegisteredWslNamesFromRegistry {
    param([string]$RegPath)
    try {
        if (-not (Test-Path $RegPath)) { return @() }
        $items = Get-ChildItem $RegPath -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^{[0-9a-f-]+}$' } |
            ForEach-Object { (Get-ItemProperty $_.PsPath -ErrorAction Stop).DistributionName }
        return ($items | ForEach-Object { Clean-WslName $_ } | Where-Object { $_ } | Sort-Object -Unique)
    } catch { return @() }
}

function Get-AllRegisteredWslNames {
    # HKCU
    $list = Get-RegisteredWslNamesFromRegistry -RegPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    # HKLM: לכל היוזרים שהוגדרו
    try {
        $profileKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue
        foreach ($key in $profileKeys) {
            $sid = $key.PSChildName
            $userReg = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Lxss"
            $l = Get-RegisteredWslNamesFromRegistry -RegPath $userReg
            if ($l.Count -gt 0) { $list += $l }
        }
    } catch {}
    return ($list | Sort-Object -Unique)
}

function Get-ValidWslListNames {
    try {
        # בדוק האם wsl.exe קיים בכלל במערכת
        $wslPath = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
        if (-not $wslPath) { return @() }
        $list = & wsl.exe -l -q 2>&1
        if (-not $list) { return @() }
        # סינון: כל שורה שאינה שם דיסטרו חוקי (אין רווחים, אין נקודותיים, קצרה)
        $res = $list | Where-Object {
            ($_ -notmatch 'usage:|examples?:|options?:|microsoft|copyright|list|download|enable|status|feature|install|display|windows|subsystem|for linux|do not|cannot|argument|help|error|not recognized|no installed distributions|is not recognized|failed') `
            -and ($_ -match '^[A-Za-z0-9._-]+$') `
            -and ($_.Length -le 30)
        }
        return ($res | ForEach-Object { Clean-WslName $_ } | Where-Object { $_ } | Sort-Object -Unique)
    } catch { return @() }
}


function Get-WslOsReleasePair {
    param([Parameter(Mandatory)][string]$DistroName)
    try {
        $n = Clean-WslName $DistroName
        if (-not $n) { return $null }

        $cmd = "if [ -r /etc/os-release ]; then . /etc/os-release; printf '%s|%s' ""${ID:-}"" ""${VERSION_ID:-}""; else printf '|'; fi"
        $out  = & wsl.exe -d "$n" -- sh -lc $cmd 2>$null
        $line = ($out | Select-Object -First 1)
        if ($line) { $line = $line -replace '\x00','' }

        $ok = $false
        if (-not [string]::IsNullOrWhiteSpace($line) -and ($line -match '\|')) {
            $p = $line -split '\|', 2
            if ($p.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($p[0]) -and -not [string]::IsNullOrWhiteSpace($p[1])) {
                $ok = $true
            }
        }
        if ($ok) { return $line }

        $raw = & wsl.exe -d "$n" -- cat /etc/os-release 2>$null
        if ($raw) {
            $rawStr = (($raw -join "`n") -replace '\x00','')
            $idMatch  = [regex]::Match($rawStr, '^[ \t]*ID[ \t]*=[ \t]*"?(?<id>[^"\r\n#]+)"?', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            $verMatch = [regex]::Match($rawStr, '^[ \t]*VERSION_ID[ \t]*=[ \t]*"?(?<ver>[^"\r\n#]+)"?', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            $id  = if ($idMatch.Success)  { $idMatch.Groups['id'].Value.Trim() }  else { '' }
            $ver = if ($verMatch.Success) { $verMatch.Groups['ver'].Value.Trim() } else { '' }
            if ($id -or $ver) {
                return ("{0}|{1}" -f $id, $ver)
            }
        }
        return $null
    } catch { return $null }
}

function ConvertTo-VersionSafe {
    param([Parameter(Mandatory)][string]$VersionText)
    $txt = $VersionText.Trim()
    if ($txt -match '^\d+\.\d+$') { $txt = "$txt.0" }
    try { return [Version]$txt } catch {
        try { return [Version]("$txt.0") } catch { return $null }
    }
}

function Test-WslUbuntuMinVersion {
    param(
        [Parameter(Mandatory)][string]$MinVer,
        [switch]$FlagNonUbuntuNC
    )

    $minVersion = ConvertTo-VersionSafe -VersionText $MinVer
    if ($null -eq $minVersion) { return $false }

    $distros = Get-AllRegisteredWslNames
    if (-not $distros -or $distros.Count -eq 0) {
        $distros = Get-ValidWslListNames
    }

    # --- הגנה נוספת: אם עדיין אין דיסטרואים בכלל, המחשב תקין ---
    if (-not $distros -or $distros.Count -eq 0) {
        return $true
    }

    $nonCompliant = $false

    foreach ($raw in $distros) {
        $name = Clean-WslName $raw
        if (-not $name) { continue }
        $pair = Get-WslOsReleasePair -DistroName $name
        if ([string]::IsNullOrWhiteSpace($pair)) {
            $nonCompliant = $true
            continue
        }
        $parts = $pair -split '\|', 2
        $id    = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0].Trim().ToLowerInvariant() } else { $null }
        $verS  = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1].Trim() } else { $null }
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($verS)) {
            $nonCompliant = $true
            continue
        }
        if ($id -eq 'ubuntu') {
            $verObj = ConvertTo-VersionSafe -VersionText $verS
            if ($null -eq $verObj -or $verObj -lt $minVersion) {
                $nonCompliant = $true
            }
        }
        elseif ($FlagNonUbuntuNC) {
            $nonCompliant = $true
        }
    }
    return (-not $nonCompliant)
}

# --- הרצה בפועל ---
$result = Test-WslUbuntuMinVersion -MinVer $MinVersion -FlagNonUbuntuNC:$NonUbuntuIsNonCompliant

$payload = @{
    DetectOldUbuntuWsl = if ($result) { 'Compliant' } else { 'Noncompliant' }
}

if ($IncludeDebug) {
    $names = Get-AllRegisteredWslNames
    if (-not $names -or $names.Count -eq 0) {
        $names = Get-ValidWslListNames
    }

    $details = @()
    foreach ($d in $names) {
        $pair = Get-WslOsReleasePair -DistroName $d
        $p = if ($pair) { $pair -split '\|', 2 } else { @('','') }
        $details += [pscustomobject]@{
            Name = $d
            ID   = if ($p.Count -ge 1) { $p[0] } else { '' }
            Ver  = if ($p.Count -ge 2) { $p[1] } else { '' }
        }
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $payload['_debug'] = @{
        User                    = $identity.Name
        IsSystem                = ($identity.User -and $identity.User.Value -eq 'S-1-5-18')
        MinVersion              = $MinVersion
        NonUbuntuIsNonCompliant = [bool]$NonUbuntuIsNonCompliant
        DistroCount             = @($names).Count
        Distros                 = $details
        ScriptTimeUtc           = (Get-Date).ToUniversalTime().ToString('s')
    }
}

return ($payload | ConvertTo-Json -Compress -Depth 8)
