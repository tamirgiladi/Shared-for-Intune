<#
.SYNOPSIS
  Export Intune Mobile Apps & Assignments to Excel, with group names resolution.

.PARAMETER OutXlsx
  Target Excel file path.

.PARAMETER AuthMode
  'Delegated' | 'AppSecret' | 'AppCert'

.PARAMETER TenantId
  Tenant GUID or domain.

.PARAMETER ClientId
  Application (client) ID.

.PARAMETER ClientSecret
  SecureString client secret (or pass via $env:GRAPH_CLIENT_SECRET).

.PARAMETER CertificateThumbprint
  Thumbprint for AppCert mode (CurrentUser\My by default).

.PARAMETER DelegatedScopes
  Scopes for interactive delegated sign-in.

.PARAMETER UseBeta
  Use Graph beta endpoint (recommended for some Intune surfaces).
#>

param(
  [string]$OutXlsx = ".\Intune_Apps_Assignments.xlsx",

  # מצב התחברות: Delegated | AppSecret | AppCert
  [ValidateSet('Delegated','AppSecret','AppCert')]
  [string]$AuthMode = 'AppSecret',

  # מזהים
  [string]$TenantId,
  [string]$ClientId,

  # ל-AppSecret
  [securestring]$ClientSecret,

  # ל-AppCert
  [string]$CertificateThumbprint,
  [string]$CertificateStoreScope = 'CurrentUser',  # או 'LocalMachine'

  # Scopes ל-Delegated
  [string[]]$DelegatedScopes = @(
    'DeviceManagementApps.Read.All',
    'Directory.Read.All'
  ),

  # שימוש ב-beta
  [switch]$UseBeta = $true
)

# ---------------- Helpers: Modules ----------------
function Ensure-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Install-Module $Name -Scope CurrentUser -Force | Out-Null
  }
  Import-Module $Name -Force -ErrorAction SilentlyContinue
}
function Ensure-ImportExcel { Ensure-Module -Name 'ImportExcel' }
function Ensure-GraphSdk  { Ensure-Module -Name 'Microsoft.Graph' }

# --------------- Helpers: Auth --------------------
function Get-CertByThumbprint {
  param([string]$Thumb,[string]$Scope)
  $path = if ($Scope -eq 'LocalMachine') { "Cert:\LocalMachine\My\$Thumb" } else { "Cert:\CurrentUser\My\$Thumb" }
  if (Test-Path $path) { Get-Item $path } else { $null }
}

function Ensure-Connected {
  try {
    $ctx = Get-MgContext -ErrorAction Stop
    if ($ctx) { return }
  } catch {}

  Ensure-GraphSdk

  switch ($AuthMode) {
    'Delegated' {
      if (-not $TenantId) { throw "TenantId נדרש ל-Delegated." }
      Write-Host "[AUTH] Delegated | $TenantId | Scopes: $($DelegatedScopes -join ', ')"
      Connect-MgGraph -TenantId $TenantId -UseDeviceCode -Scopes $DelegatedScopes -NoWelcome
    }
    'AppSecret' {
      if (-not $TenantId -or -not $ClientId) { throw "TenantId ו-ClientId נדרשים ל-AppSecret." }

      # הבא את ה-secret: פרמטר SecureString או ENV או קלט ידני
      $secSS = $ClientSecret
      if (-not $secSS -and $env:GRAPH_CLIENT_SECRET) {
        $secretPlain = $env:GRAPH_CLIENT_SECRET
      } else {
        if (-not $secSS) { $secSS = Read-Host -AsSecureString "Enter Graph Client Secret" }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secSS)
        try { $secretPlain = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
      }
      if ([string]::IsNullOrWhiteSpace($secretPlain)) { throw "Client secret ריק." }

      Write-Host "[AUTH] App-only(Secret) | Tenant: $TenantId | App: $ClientId"

      # תמיכה בשתי גרסאות המודול:
      $hasClientSecretString =
        ((Get-Command Connect-MgGraph -ErrorAction Ignore).Parameters.Keys -contains 'ClientSecret')

      if ($hasClientSecretString) {
        # גרסה חדשה: -ClientSecret (string)
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $secretPlain -NoWelcome
      } else {
        # גרסה ישנה: צריך PSCredential ושם הפרמטר הוא -ClientSecretCredential
        $sec = ConvertTo-SecureString $secretPlain -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($ClientId, $sec)
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -NoWelcome
      }
    }
    'AppCert' {
      if (-not $TenantId -or -not $ClientId -or -not $CertificateThumbprint) {
        throw "TenantId, ClientId ו-CertificateThumbprint נדרשים ל-AppCert."
      }
      $cert = Get-CertByThumbprint -Thumb $CertificateThumbprint -Scope $CertificateStoreScope
      if (-not $cert) { throw "Certificate $CertificateThumbprint לא נמצא ב-$CertificateStoreScope\My." }
      Write-Host "[AUTH] App-only(Cert) | Tenant: $TenantId | App: $ClientId"
      Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
    }
  }

  $ctx = Get-MgContext
  if (-not $ctx) { throw "Connection to Microsoft Graph failed." }
  Write-Host ("[AUTH] Connected as {0} | Tenant {1}" -f ($ctx.Account ?? $ctx.AppName), $ctx.TenantId)
}

# --------------- Start: Modules + Auth ------------
Ensure-Connected
Ensure-ImportExcel

# בסיס ל-beta/v1.0
$base = if ($UseBeta) { "https://graph.microsoft.com/beta" } else { "https://graph.microsoft.com/v1.0" }

# ---------------- Helpers: HTTP / Graph -----------
function Invoke-GraphPaged {
  param(
    [Parameter(Mandatory)] [string]$Uri
  )
  $all = @()
  $next = $Uri
  while ($next) {
    $resp = Invoke-MgGraphRequest -Method GET -Uri $next
    if ($resp.value) { $all += $resp.value }
    $next = $resp.'@odata.nextLink'
  }
  return $all
}

# --------------- Helpers: Intune lookups ----------
function Resolve-GroupNames {
  param([string[]]$Ids)
  if (-not $Ids -or $Ids.Count -eq 0) { return @{} }

  # סינון כפילויות + הסרה של null/ריקים
  $uniq = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach($i in $Ids){
    if ($i -and $i.Trim()){
      [void]$uniq.Add($i.Trim())
    }
  }

  # המרה ל-array באופן עקבי (בלי .ToArray())
  [string[]]$arr = @()
  if ($uniq.Count -gt 0) {
    $enum = $uniq.GetEnumerator()
    $temp = @()
    while ($enum.MoveNext()) { $temp += $enum.Current }
    $arr = $temp
  }

  if ($arr.Count -eq 0) { return @{} }

  # getByIds – במנות עד 900~ כדי להישאר בטוח
  $map = @{}
  $chunkSize = 900
  for ($o = 0; $o -lt $arr.Count; $o += $chunkSize) {
    $chunk = $arr[$o..([Math]::Min($o + $chunkSize - 1, $arr.Count - 1))]
    $body = @{ ids = $chunk; types = @("group") }
    $resp = Invoke-MgGraphRequest -Method POST -Uri "$base/directoryObjects/getByIds" -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json"
    foreach($obj in $resp.value){
      if ($obj.'@odata.type' -match 'group' -and $obj.id) {
        $map[$obj.id] = $obj.displayName
      }
    }
  }
  return $map
}

function Resolve-FilterNames {
  param([string[]]$Ids)
  if (-not $Ids -or $Ids.Count -eq 0) { return @{} }

  $uniq = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach($i in $Ids){ if ($i -and $i.Trim()) { [void]$uniq.Add($i.Trim()) } }

  [string[]]$arr = @()
  if ($uniq.Count -gt 0) {
    $enum = $uniq.GetEnumerator(); $temp = @()
    while ($enum.MoveNext()) { $temp += $enum.Current }; $arr = $temp
  }
  if ($arr.Count -eq 0) { return @{} }

  # מושכים את כל המסננים ואז ממפים (אין getByIds API למסננים)
  $all = Invoke-GraphPaged -Uri "$base/deviceManagement/assignmentFilters"
  $map = @{}
  foreach($f in $all){
    if ($f.id -and $f.displayName) { $map[$f.id] = $f.displayName }
  }
  return $map
}

# --------------- Main: Fetch apps & assignments ----
Write-Host "[INFO] Fetching Intune mobile apps..."
# תִקּוּן: ללא $select כדי למנוע 400 על שדות לא קיימים בטיפוס הבסיסי
$apps = Invoke-GraphPaged -Uri "$base/deviceAppManagement/mobileApps"

# אם אין אפליקציות
if (-not $apps -or $apps.Count -eq 0) {
  Write-Warning "לא נמצאו אפליקציות."
}

# מושכים הקצאות לכל אפליקציה
Write-Host "[INFO] Fetching assignments per app..."
$rows = @()
$allGroupIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$allFilterIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($a in $apps) {
  $appId   = $a.id
  $appName = $a.displayName

  # Assignments
  $assigns = @()
  try {
    $assigns = Invoke-GraphPaged -Uri "$base/deviceAppManagement/mobileApps/$appId/assignments"
  } catch {
    Write-Warning "Failed to fetch assignments for app $appName ($appId): $($_.Exception.Message)"
  }

  if (-not $assigns -or $assigns.Count -eq 0) {
    # עדיין נרשום שורה אפליקציה ללא הקצאה
    $rows += [pscustomobject]@{
      AppId                = $appId
      AppName              = $appName
      AssignmentId         = $null
      Intent               = $null
      TargetType           = "none"
      TargetGroupId        = $null
      TargetGroupName      = $null
      AllUsers             = $false
      AllDevices           = $false
      FilterMode           = $null
      FilterId             = $null
      FilterName           = $null
      InstallTimeSettings  = $null
      UseDeviceContext     = $null
      DeliveryOptimization = $null
    }
    continue
  }

  foreach ($as in $assigns) {
    $intent = $as.intent  # available/install/uninstall/required
    $target = $as.target

    $targetType    = $null
    $groupId       = $null
    $allUsers      = $false
    $allDevices    = $false
    $filterMode    = $as.settings.filterMode
    $filterId      = $as.settings.filterId
    $filterName    = $null
    $installTime   = $as.settings.installTimeSettings
    $useDevCtx     = $as.settings.useDeviceContext
    $doSettings    = $as.settings.deliveryOptimizationPriority

    if ($null -ne $target) {
      $otype = $target.'@odata.type'
      switch -Wildcard ($otype) {
        "*allLicensedUsersAssignmentTarget" { $targetType = 'allLicensedUsers'; $allUsers = $true }
        "*allDevicesAssignmentTarget"       { $targetType = 'allDevices';       $allDevices = $true }
        "*groupAssignmentTarget"            {
          $targetType = 'group'
          $groupId = $target.groupId
          if ($groupId) { [void]$allGroupIds.Add($groupId) }
        }
        default { $targetType = $otype }
      }
    }

    if ($filterId) { [void]$allFilterIds.Add($filterId) }

    $rows += [pscustomobject]@{
      AppId                = $appId
      AppName              = $appName
      AssignmentId         = $as.id
      Intent               = $intent
      TargetType           = $targetType
      TargetGroupId        = $groupId
      TargetGroupName      = $null   # נמלא לאחר רזולוציה
      AllUsers             = $allUsers
      AllDevices           = $allDevices
      FilterMode           = $filterMode
      FilterId             = $filterId
      FilterName           = $null   # נמלא לאחר רזולוציה
      InstallTimeSettings  = if ($installTime) { ($installTime | ConvertTo-Json -Depth 10) } else { $null }
      UseDeviceContext     = $useDevCtx
      DeliveryOptimization = $doSettings
    }
  }
}

Write-Host "[INFO] Total apps: $($apps.Count)"
Write-Host "[INFO] Total assignments: $($rows.Count)"

# --------- Resolve group names ----------
$grpIds = @()
if ($allGroupIds.Count -gt 0) {
  $enum = $allGroupIds.GetEnumerator(); $tmp=@()
  while ($enum.MoveNext()) { $tmp += $enum.Current }
  $grpIds = $tmp
}
$grpMap = if ($grpIds.Count -gt 0) { Resolve-GroupNames -Ids $grpIds } else { @{} }

# --------- Resolve filter names ----------
$fltIds = @()
if ($allFilterIds.Count -gt 0) {
  $enum = $allFilterIds.GetEnumerator(); $tmp=@()
  while ($enum.MoveNext()) { $tmp += $enum.Current }
  $fltIds = $tmp
}
$fltMap = if ($fltIds.Count -gt 0) { Resolve-FilterNames -Ids $fltIds } else { @{} }

# --------- Fill names ----------
foreach($r in $rows){
  if ($r.TargetGroupId -and $grpMap.ContainsKey($r.TargetGroupId)) {
    $r.TargetGroupName = $grpMap[$r.TargetGroupId]
  }
  if ($r.FilterId -and $fltMap.ContainsKey($r.FilterId)) {
    $r.FilterName = $fltMap[$r.FilterId]
  }
}

# --------- Write Excel ----------
if (Test-Path $OutXlsx) { Remove-Item $OutXlsx -Force }

$appsSheet = $apps | Select-Object `
  id, displayName, publisher, displayVersion, createdDateTime, lastModifiedDateTime, `
  uploadState, publishingState, isAssigned, isFeatured, developer, appStoreUrl

$assignSheet = $rows | Select-Object `
  AppId, AppName, AssignmentId, Intent, TargetType, TargetGroupId, TargetGroupName, `
  AllUsers, AllDevices, FilterMode, FilterId, FilterName, UseDeviceContext, DeliveryOptimization, InstallTimeSettings

$xlParams = @{
  Path                 = $OutXlsx
  AutoSize             = $true
  FreezeTopRow         = $true
  BoldTopRow           = $true
  ClearSheet           = $true
}

$appsSheet    | Export-Excel @xlParams -WorksheetName "Apps"
$assignSheet  | Export-Excel @xlParams -WorksheetName "Assignments"

# טבלת תקציר קטנה
$summary = [pscustomobject]@{
  ExportedAt      = (Get-Date)
  AppsCount       = ($apps  | Measure-Object).Count
  AssignmentsCount= ($rows  | Measure-Object).Count
  GroupsResolved  = ($grpMap.Keys | Measure-Object).Count
  FiltersResolved = ($fltMap.Keys | Measure-Object).Count
  Endpoint        = $base
  AuthMode        = $AuthMode
}
$summary | Export-Excel @xlParams -WorksheetName "Summary"

Write-Host "[DONE] Exported to: $OutXlsx"
