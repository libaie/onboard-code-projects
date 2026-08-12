[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$subject = Join-Path $PSScriptRoot 'preflight.ps1'
$requiredPackageFiles = @(
  '.codex-plugin/plugin.json',
  '.gitattributes',
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/workflows/windows-tests.yml',
  '.gitignore',
  'agents/openai.yaml',
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'docs/forward-tests/controller-bootstrap.md',
  'docs/release-checklist.md',
  'hooks/hooks.json',
  'LICENSE',
  'SKILL.md',
  'README.md',
  'README.zh-CN.md',
  'SECURITY.md',
  'references/controller-runtime.md',
  'skills/onboard-code-projects/SKILL.md',
  'scripts/preflight.ps1', 'scripts/preflight.tests.ps1',
  'scripts/init-controller.ps1', 'scripts/init-controller.tests.ps1',
  'scripts/source-input.ps1', 'scripts/source-input.tests.ps1',
  'scripts/index-mode.ps1', 'scripts/index-mode.tests.ps1',
  'scripts/chain-store.tests.ps1', 'scripts/control-state.tests.ps1',
  'scripts/skill-contract.tests.ps1', 'scripts/skill-size.tests.ps1',
  'scripts/dispatch-return-runtime.mjs',
  'scripts/dispatch-return-runtime.tests.mjs',
  'templates/controller/.codex-controller.json',
  'templates/controller/.chain-store.json',
  'templates/controller/.gitignore',
  'templates/controller/AGENTS.md',
  'templates/controller/docs/cross-project-contracts.md',
  'templates/controller/tools/control-state.ps1',
  'templates/controller/tools/chain-store.ps1'
)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-ReleaseGate {
  param([string]$RepositoryRoot)
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $subject -ReleaseGate -RepositoryRoot $RepositoryRoot 2>&1
  $exitCode = $LASTEXITCODE
  $document = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  try { $result = $document.Trim() | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Release gate must emit one JSON document; output: $document" }
  return [pscustomobject]@{ Result=$result; ExitCode=$exitCode }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-preflight-tests-' + [guid]::NewGuid().ToString('N'))
try {
  [IO.Directory]::CreateDirectory($testRoot) | Out-Null
  $repo = Join-Path $testRoot 'release-candidate'
  [IO.Directory]::CreateDirectory($repo) | Out-Null
  foreach ($relativePath in $requiredPackageFiles) {
    $path = Join-Path $repo ($relativePath.Replace('/', '\'))
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    $content = if ($relativePath -ceq '.gitattributes') { "* text=auto eol=lf`n" } elseif ($relativePath.EndsWith('.gitignore')) { "# fixture`n" } elseif ($relativePath -ceq 'README.md') { "$relativePath`nExample validator: /Users/[A-Za-z0-9._-]+/`nExample root: C:\projects\service-a`n" } else { "$relativePath`n" }
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($false)))
  }
  & git -C $repo init --quiet
  & git -C $repo config user.name 'Onboard Test'
  & git -C $repo config user.email 'onboard-test@example.invalid'
  & git -C $repo add -- .
  & git -C $repo commit --quiet -m 'release fixture'
  Assert-True ($LASTEXITCODE -eq 0) 'Release fixture commit must succeed'

  $ready = Invoke-ReleaseGate $repo
  Assert-True ($ready.ExitCode -eq 0 -and $ready.Result.status -ceq 'ready' -and $ready.Result.reasonCode -ceq 'release-package-ready') "A clean archive containing every required package file must pass; got $($ready.Result | ConvertTo-Json -Depth 6 -Compress)"
  Assert-True (@($ready.Result.archivedFiles).Count -eq $requiredPackageFiles.Count -and -not [string]::IsNullOrWhiteSpace([string]$ready.Result.archiveHash)) 'The release gate must prove exact archive membership and hash the archive'
  Assert-True (@($ready.Result.unexpectedArchive).Count -eq 0 -and @($ready.Result.privacyFindings).Count -eq 0) 'A ready release must prove an exact public allowlist and an empty privacy scan'

  [IO.File]::AppendAllText((Join-Path $repo 'README.md'), "dirty`n", (New-Object Text.UTF8Encoding($false)))
  $dirty = Invoke-ReleaseGate $repo
  Assert-True ($dirty.ExitCode -eq 1 -and $dirty.Result.status -ceq 'blocked' -and $dirty.Result.reasonCode -ceq 'release-worktree-dirty') 'A dirty worktree must never be reported release-ready'

  & git -C $repo reset --hard --quiet HEAD

  [IO.File]::WriteAllText((Join-Path $repo 'internal-notes.txt'), "not distributable`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $repo add -- 'internal-notes.txt'
  & git -C $repo commit --quiet -m 'add unexpected file'
  Assert-True ($LASTEXITCODE -eq 0) 'Unexpected-file fixture commit must succeed'
  $unexpected = Invoke-ReleaseGate $repo
  Assert-True ($unexpected.ExitCode -eq 1 -and $unexpected.Result.reasonCode -ceq 'release-package-unexpected') 'A clean archive containing an unapproved file must block release'
  Assert-True (@($unexpected.Result.unexpectedArchive) -ccontains 'internal-notes.txt') 'The unexpected archive entry must be reported exactly'
  & git -C $repo reset --hard --quiet HEAD^

  $privatePath = 'C:' + '\Users\private\Documents\controller'
  $privateProjectPath = 'Z:' + '\client-projects\sample\controller'
  $credential = 'gh' + 'p_' + ('a' * 36)
  [IO.File]::AppendAllText((Join-Path $repo 'README.md'), "$privatePath`n$privateProjectPath`n$credential`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $repo add -- 'README.md'
  & git -C $repo commit --quiet -m 'add private path fixture'
  & git -C $repo checkout --quiet HEAD^ -- 'README.md'
  & git -C $repo commit --quiet -m 'remove private path fixture'
  Assert-True ($LASTEXITCODE -eq 0) 'History privacy fixture commits must succeed'
  $privateHistory = Invoke-ReleaseGate $repo
  Assert-True ($privateHistory.ExitCode -eq 1 -and $privateHistory.Result.reasonCode -ceq 'release-package-private-content') 'Private content retained only in reachable Git history must block release'
  Assert-True (@($privateHistory.Result.privacyFindings) -contains 'history:private-path') 'The release gate must report the privacy rule and scope without echoing private content'
  Assert-True (@($privateHistory.Result.privacyFindings) -contains 'history:credential-shape') 'The release gate must aggregate every matched privacy rule without echoing private content'
  & git -C $repo reset --hard --quiet HEAD^^

  $brokenRef = Join-Path $repo '.git\refs\heads\unreadable-history'
  [IO.Directory]::CreateDirectory((Split-Path -Parent $brokenRef)) | Out-Null
  [IO.File]::WriteAllText($brokenRef, (('f' * 40) + "`n"), (New-Object Text.UTF8Encoding($false)))
  $historyUnreadable = Invoke-ReleaseGate $repo
  Assert-True ($historyUnreadable.ExitCode -eq 1 -and $historyUnreadable.Result.status -ceq 'blocked' -and $historyUnreadable.Result.reasonCode -ceq 'release-history-unreadable') 'An unreadable reachable Git history must fail closed with a stable reason'
  Assert-True (@($historyUnreadable.Result.privacyFindings) -contains 'history:scan-failed') 'A history scan failure must be reported as a stable finding without leaking command output'
  [IO.File]::Delete($brokenRef)

  & git -C $repo rm --quiet -- 'hooks/hooks.json'
  & git -C $repo commit --quiet -m 'remove required hook'
  Assert-True ($LASTEXITCODE -eq 0) 'Incomplete fixture commit must succeed'
  $incomplete = Invoke-ReleaseGate $repo
  Assert-True ($incomplete.ExitCode -eq 1 -and $incomplete.Result.status -ceq 'blocked' -and $incomplete.Result.reasonCode -ceq 'release-package-incomplete') 'A clean commit missing one required archive entry must block release'
  Assert-True (@($incomplete.Result.missingArchive) -ccontains 'hooks/hooks.json') 'The missing archive entry must be reported exactly'

  Write-Output 'PASS preflight release gate'
}
finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
