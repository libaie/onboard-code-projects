[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$subject = Join-Path $PSScriptRoot 'index-mode.ps1'
$powerShell = if ($PSVersionTable.PSEdition -ceq 'Core') {
  (Get-Process -Id $PID).Path
}
else {
  (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-code-projects-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
  [IO.Path]::DirectorySeparatorChar,
  [IO.Path]::AltDirectorySeparatorChar
)
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)

function Invoke-Subject {
  param([string[]]$Arguments)

  $output = & $powerShell -NoProfile -ExecutionPolicy Bypass -File $subject -ConfigRoot $testRoot @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Subject failed with exit code $LASTEXITCODE"
  }
  $output | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $configPath = Join-Path $testRoot 'skill-state\onboard-code-projects.json'

  $missing = Invoke-Subject -Arguments @('-Action', 'Get')
  if ($missing.status -cne 'needs-selection' -or $null -ne $missing.indexMode) {
    throw 'Missing preference must require a user selection'
  }
  if (Test-Path -LiteralPath $configPath) {
    throw 'Reading a missing preference must not create it'
  }

  $saved = Invoke-Subject -Arguments @('-Action', 'Set', '-IndexMode', 'full')
  if ($saved.status -cne 'ready' -or $saved.indexMode -cne 'full') {
    throw 'Selected index mode must be returned'
  }

  $loaded = Invoke-Subject -Arguments @('-Action', 'Get')
  if ($loaded.status -cne 'ready' -or $loaded.indexMode -cne 'full') {
    throw 'Saved index mode must be reused'
  }

  $changed = Invoke-Subject -Arguments @('-Action', 'Set', '-IndexMode', 'fast')
  if ($changed.status -cne 'ready' -or $changed.indexMode -cne 'fast') {
    throw 'An explicitly changed default must replace the prior preference'
  }
  $reloaded = Invoke-Subject -Arguments @('-Action', 'Get')
  if ($reloaded.status -cne 'ready' -or $reloaded.indexMode -cne 'fast') {
    throw 'The changed default must persist'
  }

  $ErrorActionPreference = 'Continue'
  & $powerShell -NoProfile -ExecutionPolicy Bypass -File $subject -ConfigRoot $testRoot -Action Set -IndexMode invalid *> $null
  $invalidExitCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($invalidExitCode -eq 0) {
    throw 'Invalid index mode must be rejected'
  }

  Write-Output 'PASS index-mode'
}
finally {
  if (Test-Path -LiteralPath $testRoot) {
    if (-not $resolvedTestRoot.StartsWith(
        $resolvedTempRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
      )) {
      throw 'Refusing to remove a test directory outside the system temporary directory'
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}

exit 0
