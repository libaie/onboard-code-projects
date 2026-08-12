[CmdletBinding()]
param(
  [switch]$RequireGit,
  [switch]$RequireSsh,
  [switch]$RequireLfs,
  [switch]$RequireNode,
  [switch]$SelfTest,
  [switch]$ReleaseGate,
  [string]$RepositoryRoot,
  [Parameter(ValueFromRemainingArguments=$true)]
  [object[]]$RemainingArgs
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Invoke-OnboardingPreflight {
  param(
    [bool]$RequireGit,
    [bool]$RequireSsh,
    [bool]$RequireLfs,
    [bool]$RequireNode,
    [scriptblock]$CommandResolver = {
      param($Name)
      Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    },
    [scriptblock]$CommandInvoker = {
      param($Path, $Arguments)
      $output = & $Path @Arguments 2>&1
      [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=(($output | ForEach-Object { [string]$_ }) -join "`n").Trim() }
    }
  )

  $tools = [ordered]@{}
  $missingRequired = @()
  $warnings = @()
  $powerShellReady = $PSVersionTable.PSVersion -ge [Version]'5.1'
  $tools.powershell = [ordered]@{
    available = $powerShellReady
    required = $true
    version = $PSVersionTable.PSVersion.ToString()
  }
  if (-not $powerShellReady) { $missingRequired += 'powershell>=5.1' }

  $checks = @(
    [pscustomobject]@{ Key='git'; Command='git'; Required=$RequireGit },
    [pscustomobject]@{ Key='ssh'; Command='ssh'; Required=$RequireSsh },
    [pscustomobject]@{ Key='gitLfs'; Command='git-lfs'; Required=$RequireLfs },
    [pscustomobject]@{ Key='node'; Command='node'; Required=$RequireNode }
  )
  foreach ($check in $checks) {
    $command = $null
    try { $command = @(& $CommandResolver $check.Command | Select-Object -First 1)[0] }
    catch { $warnings += "Unable to resolve $($check.Command)" }
    $path = $null
    if ($null -ne $command) {
      foreach ($property in @('Path','Source','Definition')) {
        if ($command.PSObject.Properties.Name -contains $property -and
          -not [string]::IsNullOrWhiteSpace([string]$command.$property)) {
          $path = [string]$command.$property
          break
        }
      }
    }
    $available = -not [string]::IsNullOrWhiteSpace($path)
    $tools[$check.Key] = [ordered]@{
      available = $available
      required = [bool]$check.Required
      path = $path
    }
    if ($check.Required -and -not $available) { $missingRequired += $check.Command }
  }

  $tools.node.minimumVersion = '18.0.0'
  $tools.node.version = $null
  $tools.node.compatible = $null
  if ($RequireNode -and $tools.node.available) {
    $tools.node.compatible = $false
    try {
      $nodeResult = & $CommandInvoker $tools.node.path ([string[]]@('--version'))
      $nodeText = [string]$nodeResult.Output
      if ($nodeResult.ExitCode -eq 0 -and $nodeText -match '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:[-+].*)?$') {
        $tools.node.version = $Matches.version
        $tools.node.compatible = [Version]$Matches.version -ge [Version]'18.0.0'
      }
    }
    catch { $warnings += 'Unable to execute Node.js version probe' }
    if (-not $tools.node.compatible) { $missingRequired += 'node>=18.0.0' }
  }

  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = if ($missingRequired.Count -eq 0) { 'ready' } else { 'blocked' }
    tools = [pscustomobject]$tools
    missingRequired = @($missingRequired)
    warnings = @($warnings)
  }
}

function Invoke-ReleasePackageGate {
  param([string]$Root)

  $requiredFiles = @(
    '.codex-plugin/plugin.json', '.gitattributes', '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/workflows/windows-tests.yml', '.gitignore', 'agents/openai.yaml', 'CHANGELOG.md',
    'CONTRIBUTING.md', 'docs/forward-tests/controller-bootstrap.md', 'docs/release-checklist.md',
    'hooks/hooks.json', 'LICENSE', 'SKILL.md', 'README.md', 'README.zh-CN.md', 'SECURITY.md',
    'references/controller-runtime.md', 'skills/onboard-code-projects/SKILL.md',
    'scripts/preflight.ps1', 'scripts/preflight.tests.ps1', 'scripts/init-controller.ps1', 'scripts/init-controller.tests.ps1',
    'scripts/source-input.ps1', 'scripts/source-input.tests.ps1', 'scripts/index-mode.ps1', 'scripts/index-mode.tests.ps1',
    'scripts/chain-store.tests.ps1', 'scripts/control-state.tests.ps1', 'scripts/skill-contract.tests.ps1', 'scripts/skill-size.tests.ps1',
    'scripts/dispatch-return-runtime.mjs', 'scripts/dispatch-return-runtime.tests.mjs',
    'templates/controller/.codex-controller.json', 'templates/controller/.chain-store.json',
    'templates/controller/.gitignore', 'templates/controller/AGENTS.md', 'templates/controller/docs/cross-project-contracts.md',
    'templates/controller/tools/control-state.ps1',
    'templates/controller/tools/chain-store.ps1'
  )
  $privacyRules = @(
    [pscustomobject]@{ Code='private-path'; Pattern='(?i)(?:[A-Z]:[\\/](?:Users[\\/][A-Za-z0-9._ -]+|[A-Za-z0-9._ -]+(?:projects?|repos?|workspaces?)[\\/])|/(?:home|Users)/[A-Za-z0-9._-]+/)' },
    [pscustomobject]@{ Code='credential-shape'; Pattern='(?i)(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-proj-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._=-]{20,})' }
  )
  $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($git.Count -ne 1) {
    return [pscustomobject][ordered]@{ schemaVersion=1; status='blocked'; reasonCode='release-git-unavailable'; repositoryRoot=$Root; head=$null; archiveHash=$null; archivedFiles=@(); missingTracked=@($requiredFiles); missingArchive=@($requiredFiles); unexpectedArchive=@(); privacyFindings=@(); dirtyEntries=@('git-unavailable') }
  }
  try { $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') }
  catch { $resolvedRoot = $Root }
  if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    return [pscustomobject][ordered]@{ schemaVersion=1; status='blocked'; reasonCode='release-repository-invalid'; repositoryRoot=$resolvedRoot; head=$null; archiveHash=$null; archivedFiles=@(); missingTracked=@($requiredFiles); missingArchive=@($requiredFiles); unexpectedArchive=@(); privacyFindings=@(); dirtyEntries=@('repository-missing') }
  }
  $topOutput = @(& $git[0].Source -C $resolvedRoot rev-parse --show-toplevel 2>$null)
  $topExit = $LASTEXITCODE
  $top = @($topOutput | Select-Object -First 1)[0]
  $normalizedTop = if ([string]::IsNullOrWhiteSpace([string]$top)) { '' } else { [IO.Path]::GetFullPath(([string]$top).Replace('/','\')).TrimEnd('\') }
  if ($topExit -ne 0 -or [string]::IsNullOrWhiteSpace($normalizedTop) -or $normalizedTop -ine $resolvedRoot) {
    return [pscustomobject][ordered]@{ schemaVersion=1; status='blocked'; reasonCode='release-repository-invalid'; repositoryRoot=$resolvedRoot; head=$null; archiveHash=$null; archivedFiles=@(); missingTracked=@($requiredFiles); missingArchive=@($requiredFiles); unexpectedArchive=@(); privacyFindings=@(); dirtyEntries=@('not-exact-git-root') }
  }
  $head = (& $git[0].Source -C $resolvedRoot rev-parse HEAD 2>$null | Select-Object -First 1)
  $tracked = @(& $git[0].Source -C $resolvedRoot ls-tree -r --name-only HEAD 2>$null | ForEach-Object { ([string]$_).Replace('\','/') })
  $missingTracked = @($requiredFiles | Where-Object { $tracked -cnotcontains $_ })
  $dirtyEntries = @(& $git[0].Source -C $resolvedRoot status --porcelain=v1 --untracked-files=all 2>$null | ForEach-Object { [string]$_ })
  $archivePath = Join-Path ([IO.Path]::GetTempPath()) ('onboard-release-' + [guid]::NewGuid().ToString('N') + '.zip')
  $archivedNames = @()
  $archiveHash = $null
  $privacyFindings = @()
  try {
    & $git[0].Source -C $resolvedRoot archive --format=zip --output=$archivePath HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
      try {
        foreach ($entry in $zip.Entries) {
          if ($entry.FullName.EndsWith('/')) { continue }
          $entryName = $entry.FullName.Replace('\','/')
          $archivedNames += $entryName
          $stream = $entry.Open()
          $reader = New-Object IO.StreamReader -ArgumentList $stream
          try { $entryText = $reader.ReadToEnd() }
          finally { $reader.Dispose(); $stream.Dispose() }
          foreach ($rule in $privacyRules) {
            if ($entryText -match $rule.Pattern) { $privacyFindings += "archive:$($rule.Code)" }
          }
        }
      }
      finally { $zip.Dispose() }
      $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    }
  }
  finally { if (Test-Path -LiteralPath $archivePath -PathType Leaf) { [IO.File]::Delete($archivePath) } }
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $historyOutput = @(& $git[0].Source -C $resolvedRoot -c core.quotepath=false log --all --format=fuller -p --no-ext-diff -- . 2>$null)
    $historyExitCode = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $previousErrorActionPreference }
  if ($historyExitCode -eq 0) {
    $historyText = $historyOutput -join "`n"
    foreach ($rule in $privacyRules) {
      if ($historyText -match $rule.Pattern) { $privacyFindings += "history:$($rule.Code)" }
    }
  }
  else { $privacyFindings += 'history:scan-failed' }
  $privacyFindings = @($privacyFindings | Sort-Object -Unique)
  $missingArchive = @($requiredFiles | Where-Object { $archivedNames -cnotcontains $_ })
  $unexpectedArchive = @($archivedNames | Where-Object { $requiredFiles -cnotcontains $_ })
  $archivedFiles = @($requiredFiles | Where-Object { $archivedNames -ccontains $_ })
  $reasonCode = if ($missingTracked.Count -gt 0 -or $missingArchive.Count -gt 0 -or [string]::IsNullOrWhiteSpace([string]$archiveHash)) { 'release-package-incomplete' } elseif ($dirtyEntries.Count -gt 0) { 'release-worktree-dirty' } elseif ($unexpectedArchive.Count -gt 0) { 'release-package-unexpected' } elseif ($historyExitCode -ne 0) { 'release-history-unreadable' } elseif ($privacyFindings.Count -gt 0) { 'release-package-private-content' } else { 'release-package-ready' }
  return [pscustomobject][ordered]@{
    schemaVersion=1; status=if ($reasonCode -ceq 'release-package-ready') { 'ready' } else { 'blocked' }; reasonCode=$reasonCode
    repositoryRoot=$resolvedRoot; head=$head; archiveHash=$archiveHash; archivedFiles=$archivedFiles
    missingTracked=$missingTracked; missingArchive=$missingArchive; unexpectedArchive=$unexpectedArchive
    privacyFindings=$privacyFindings; dirtyEntries=$dirtyEntries
  }
}

$hasRemainingArgs = $null -ne $RemainingArgs -and $RemainingArgs.Length -gt 0
if ($hasRemainingArgs -or ($SelfTest -and ($RequireGit -or $RequireSsh -or $RequireLfs -or $RequireNode -or $ReleaseGate -or $RepositoryRoot)) -or
    ($ReleaseGate -and ($RequireGit -or $RequireSsh -or $RequireLfs -or $RequireNode)) -or (-not $ReleaseGate -and $RepositoryRoot)) {
  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = 'invalid'
    tools = $null
    missingRequired = @()
    warnings = @('Invalid invocation')
  } | ConvertTo-Json -Depth 6 -Compress
  exit 2
}

if ($ReleaseGate) {
  $releaseRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { Split-Path -Parent $PSScriptRoot } else { $RepositoryRoot }
  $release = Invoke-ReleasePackageGate -Root $releaseRoot
  $release | ConvertTo-Json -Depth 6 -Compress
  if ($release.status -ceq 'ready') { exit 0 }
  exit 1
}

if ($SelfTest) {
  $missing = { param($Name) $null }
  $blocked = Invoke-OnboardingPreflight -RequireGit $true -RequireSsh $false -RequireLfs $false -CommandResolver $missing
  if ($blocked.status -cne 'blocked' -or $blocked.missingRequired -cnotcontains 'git') {
    throw 'Missing required Git must block'
  }
  $blockedNode = Invoke-OnboardingPreflight -RequireGit $false -RequireSsh $false -RequireLfs $false -RequireNode $true -CommandResolver $missing
  if ($blockedNode.status -cne 'blocked' -or $blockedNode.missingRequired -cnotcontains 'node') {
    throw 'Missing required Node.js must block event return'
  }

  $optional = Invoke-OnboardingPreflight -RequireGit $false -RequireSsh $false -RequireLfs $false -CommandResolver $missing
  if ($optional.status -cne 'ready') { throw 'Missing optional tools must not block' }

  $present = {
    param($Name)
    [pscustomobject]@{ Source = 'C:\tools\' + $Name + '.exe' }
  }
  $oldNode = { param($Path, $Arguments) [pscustomobject]@{ ExitCode=0; Output='v16.20.2' } }
  $unsupported = Invoke-OnboardingPreflight -RequireGit $false -RequireSsh $false -RequireLfs $false -RequireNode $true -CommandResolver $present -CommandInvoker $oldNode
  if ($unsupported.status -cne 'blocked' -or $unsupported.missingRequired -cnotcontains 'node>=18.0.0' -or $unsupported.tools.node.version -cne '16.20.2') {
    throw 'Node.js below the supported minimum must block event return'
  }
  $invalidNode = { param($Path, $Arguments) [pscustomobject]@{ ExitCode=0; Output='not-a-node-version' } }
  $unverified = Invoke-OnboardingPreflight -RequireGit $false -RequireSsh $false -RequireLfs $false -RequireNode $true -CommandResolver $present -CommandInvoker $invalidNode
  if ($unverified.status -cne 'blocked' -or $unverified.missingRequired -cnotcontains 'node>=18.0.0') {
    throw 'An unverified Node.js executable must block event return'
  }
  $currentNode = { param($Path, $Arguments) [pscustomobject]@{ ExitCode=0; Output='v18.0.0' } }
  $ready = Invoke-OnboardingPreflight -RequireGit $true -RequireSsh $true -RequireLfs $true -RequireNode $true -CommandResolver $present -CommandInvoker $currentNode
  if ($ready.status -cne 'ready' -or $ready.tools.git.path -cne 'C:\tools\git.exe' -or $ready.tools.node.version -cne '18.0.0') {
    throw 'Present compatible commands must be verified and reported'
  }
  Write-Output 'PASS preflight'
  exit 0
}

$result = Invoke-OnboardingPreflight `
  -RequireGit ([bool]$RequireGit) `
  -RequireSsh ([bool]$RequireSsh) `
  -RequireLfs ([bool]$RequireLfs) `
  -RequireNode ([bool]$RequireNode)

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $RequireGit -and $result.tools.git.available) {
  $longPaths = & $result.tools.git.path config --global --get core.longpaths 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]$longPaths -ine 'true') {
    $result.warnings = @($result.warnings) + 'git core.longpaths is not enabled globally'
  }
}

$result | ConvertTo-Json -Depth 6 -Compress
if ($result.status -ceq 'ready') { exit 0 }
exit 1
