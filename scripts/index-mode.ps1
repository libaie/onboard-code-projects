[CmdletBinding()]
param(
  [ValidateSet('Get', 'Set')]
  [string]$Action = 'Get',
  [ValidateSet('fast', 'moderate', 'full')]
  [string]$IndexMode,
  [Parameter(DontShow = $true)]
  [string]$ConfigRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$choices = @('fast', 'moderate', 'full')
if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
  $stateRoot = $env:CODEX_HOME
  if ([string]::IsNullOrWhiteSpace($stateRoot)) {
    $stateRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
  }
}
else {
  if (-not [IO.Path]::IsPathRooted($ConfigRoot) -or
      -not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
    throw 'ConfigRoot must be an existing absolute directory'
  }
  $stateRoot = $ConfigRoot
}
$stateRoot = [IO.Path]::GetFullPath($stateRoot)
$configDirectory = Join-Path $stateRoot 'skill-state'
$configPath = Join-Path $configDirectory 'onboard-code-projects.json'

function Write-Result {
  param(
    [string]$Status,
    [AllowNull()]
    [object]$Mode,
    [AllowNull()]
    [object]$Reason
  )

  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = $Status
    indexMode = $Mode
    choices = $choices
    recommended = 'full'
    configPath = $configPath
    reason = $Reason
  } | ConvertTo-Json -Depth 3 -Compress
}

function Read-Preference {
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return $null
  }

  try {
    $preference = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
    if ($null -eq $preference -or
        -not ($preference.PSObject.Properties.Name -contains 'schemaVersion') -or
        [int]$preference.schemaVersion -ne 1 -or
        -not ($preference.PSObject.Properties.Name -contains 'indexMode') -or
        $choices -cnotcontains [string]$preference.indexMode) {
      throw 'Invalid preference'
    }
    return $preference
  }
  catch {
    return $false
  }
}

if ($Action -ceq 'Get') {
  $preference = Read-Preference
  if ($null -eq $preference) {
    Write-Result -Status 'needs-selection' -Mode $null -Reason $null
    exit 0
  }
  if ($preference -is [bool] -and -not $preference) {
    Write-Result -Status 'invalid' -Mode $null -Reason 'preference-file-invalid'
    exit 2
  }
  Write-Result -Status 'ready' -Mode ([string]$preference.indexMode) -Reason $null
  exit 0
}

if ([string]::IsNullOrWhiteSpace($IndexMode)) {
  throw 'IndexMode is required for Action Set'
}

New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$temporaryPath = Join-Path $configDirectory ('onboard-code-projects.' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
  $json = [pscustomobject][ordered]@{
    schemaVersion = 1
    indexMode = $IndexMode
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
}
finally {
  if (Test-Path -LiteralPath $temporaryPath) {
    Remove-Item -LiteralPath $temporaryPath -Force
  }
}

Write-Result -Status 'ready' -Mode $IndexMode -Reason $null
