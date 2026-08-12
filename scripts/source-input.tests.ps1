[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$subject = Join-Path $PSScriptRoot 'source-input.ps1'
$count = 0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:count++
}

function Invoke-Subject([object]$InputValue) {
  $json = ConvertTo-Json -InputObject @($InputValue) -Depth 8 -Compress
  $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $subject -SourcesJsonBase64 $base64 2>$null
  $exitCode = $LASTEXITCODE
  $result = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
  return [pscustomobject]@{ ExitCode=$exitCode; Result=$result }
}

$localRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'onboard-source-input-local')).TrimEnd('\')
[IO.Directory]::CreateDirectory($localRoot) | Out-Null
try {
  $valid = Invoke-Subject @(
    [ordered]@{ source=$localRoot },
    [ordered]@{ source=$localRoot.ToUpperInvariant() },
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; branch='main'; fullLfsCheckout=$false },
    [ordered]@{ source='git@github.com:example/other.git'; cloneRoot=$localRoot; ref='refs/tags/v1.0.0'; fullLfsCheckout=$true }
  )
  Assert-True ($valid.ExitCode -eq 0 -and $valid.Result.status -ceq 'ready') 'Valid local, HTTPS, and SCP-style sources must normalize'
  Assert-True (@($valid.Result.sources).Count -eq 3) 'Case-insensitive duplicate local roots must collapse before onboarding lanes start'
  Assert-True ($valid.Result.sources[1].source -ceq 'https://github.com/example/repo.git' -and $valid.Result.sources[1].branch -ceq 'main') 'HTTPS source options must be preserved in a closed per-source record'

  $embeddedCredential = 'g' + 'hp_' + ('A' * 36)
  $credentialInPath = Invoke-Subject @([ordered]@{ source=('https://github.com/example/' + $embeddedCredential + '/repo.git'); cloneRoot=$localRoot })
  Assert-True ($credentialInPath.ExitCode -eq 2 -and $credentialInPath.Result.status -ceq 'invalid') 'Credential-shaped tokens embedded in Git URL paths must be rejected before Git'
  Assert-True (-not ((ConvertTo-Json $credentialInPath.Result -Compress).Contains($embeddedCredential))) 'Rejected output must not echo an embedded credential'
  $encodedCredential = $embeddedCredential.Replace('_', '%5F')
  $encodedCredentialInPath = Invoke-Subject @([ordered]@{ source=('https://github.com/example/' + $encodedCredential + '/repo.git'); cloneRoot=$localRoot })
  Assert-True ($encodedCredentialInPath.ExitCode -eq 2 -and $encodedCredentialInPath.Result.status -ceq 'invalid') 'Percent-encoded credential shapes must be rejected at the shared text boundary'
  Assert-True (-not ((ConvertTo-Json $encodedCredentialInPath.Result -Compress).Contains($encodedCredential))) 'Rejected output must not echo an encoded credential'

  foreach ($bad in @(
    [ordered]@{ source='https://user:secret@github.com/example/repo.git'; cloneRoot=$localRoot },
    [ordered]@{ source='https://github.com/example/repo.git?token=secret'; cloneRoot=$localRoot },
    [ordered]@{ source='http://github.com/example/repo.git'; cloneRoot=$localRoot },
    [ordered]@{ source='git://github.com/example/repo.git'; cloneRoot=$localRoot },
    [ordered]@{ source='git@github.com:/absolute/path.git'; cloneRoot=$localRoot },
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; branch='main'; ref='HEAD' },
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; ref='--upload-pack=evil' },
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; unknown=$true }
  )) {
    $rejected = Invoke-Subject @($bad)
    Assert-True ($rejected.ExitCode -eq 2 -and $rejected.Result.status -ceq 'invalid') 'Unsafe or open-schema source input must be rejected before Git'
    Assert-True ((ConvertTo-Json $rejected.Result -Compress) -notmatch 'secret') 'Rejected output must not echo credentials'
  }

  $conflictingDuplicate = Invoke-Subject @(
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; branch='main' },
    [ordered]@{ source='https://github.com/example/repo.git'; cloneRoot=$localRoot; branch='develop' }
  )
  Assert-True ($conflictingDuplicate.ExitCode -eq 2 -and $conflictingDuplicate.Result.reasonCode -ceq 'source-duplicate-conflict') 'A duplicate source with different options must fail as one batch'
}
finally {
  if ((Test-Path -LiteralPath $localRoot -PathType Container) -and @(Get-ChildItem -Force -LiteralPath $localRoot).Count -eq 0) { [IO.Directory]::Delete($localRoot) }
}

Write-Output "PASS source input ($count assertions)"
