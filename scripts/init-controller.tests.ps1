[CmdletBinding()]
param([switch]$FocusedTaskSet, [switch]$FocusedTaskSetSeal, [switch]$FocusedStoreBackedV2)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$subject = Join-Path $PSScriptRoot 'init-controller.ps1'
$templateRoot = Join-Path $skillRoot 'templates\controller'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-TestHash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-ExpectedTaskSetId {
  param([string]$NormalizedRoot)
  $identityRoot = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $NormalizedRoot.ToLowerInvariant() } else { $NormalizedRoot }
  return 'task-set-' + (Get-TestHash ([Text.Encoding]::UTF8.GetBytes($identityRoot)))
}

function Get-ExpectedV3Manifest {
  param(
    [string]$Root,
    [string]$Name,
    [AllowNull()][object]$ControllerBinding = $null,
    [AllowNull()][object]$ControllerTaskIntent = $null,
    [object[]]$ProjectBindings = @(),
    [object[]]$DispatchQueues = @(),
    [AllowNull()][object]$TaskSetReset = $null
  )
  $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $manifest = [pscustomobject][ordered]@{
    schemaVersion=3; generator='onboard-code-projects'; templateVersion=3; controllerName=$Name
    controllerBinding=$ControllerBinding; controllerTaskIntent=$ControllerTaskIntent; projectBindings=@($ProjectBindings); dispatchQueues=@($DispatchQueues)
    taskSetId=(Get-ExpectedTaskSetId $normalizedRoot); taskSetReset=$TaskSetReset
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
  return [pscustomobject]@{ Manifest=$manifest; Bytes=$bytes; Hash=(Get-TestHash $bytes) }
}

function Assert-Result {
  param($Result, [string]$Action, [string[]]$AllowedStatuses, [int]$ExitCode)
  foreach ($property in @('schemaVersion', 'action', 'status', 'reasonCode', 'controllerRoot', 'changed', 'plannedCreates', 'currentManifestHash', 'resultManifestHash', 'nextAction', 'warnings')) {
    Assert-True ($Result.PSObject.Properties.Name -contains $property) "Result must contain $property"
  }
  Assert-True ($Result.schemaVersion -eq 1) 'Initializer result schemaVersion must be 1'
  Assert-True ($Result.action -ceq $Action) "Initializer action must be $Action"
  Assert-True ($AllowedStatuses -ccontains $Result.status) "Unexpected $Action status $($Result.status): $($Result.reasonCode) at $($Result.controllerRoot); nextAction: $($Result.nextAction); warnings: $(@($Result.warnings) -join '; ')"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Result.reasonCode) -and [string]$Result.reasonCode -match '^[a-z0-9-]+$') 'reasonCode must be a stable non-empty kebab-case value'
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Result.nextAction)) 'nextAction must be non-empty'
  Assert-True ($ExitCode -in 0, 1, 2) "Unexpected initializer exit code $ExitCode"
}

function Assert-ReasonCode {
  param($Result, [string]$Expected, [string]$Message)
  Assert-True ($Result.reasonCode -ceq $Expected) "$Message; expected $Expected, got $($Result.reasonCode)"
}

function Invoke-Subject {
  param(
    [string]$Action,
    [string]$ControllerRoot,
    [AllowNull()]
    [object]$ControllerName = 'Controller Test',
    [string[]]$BusinessProjectRoots = @(),
    [string]$SubjectPath = $subject,
    [bool]$AllowUpgrade = $false
  )

  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SubjectPath, '-Action', $Action, '-ControllerRoot', $ControllerRoot)
  if ($null -ne $ControllerName) { $arguments += @('-ControllerName', [string]$ControllerName) }
  if ($BusinessProjectRoots.Count -gt 0) { $arguments += @('-BusinessProjectRoots') + $BusinessProjectRoots }
  if ($AllowUpgrade) { $arguments += '-AllowUpgrade' }
  $output = & powershell.exe @arguments 2>&1
  $exitCode = $LASTEXITCODE
  $document = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  try { $result = $document.Trim() | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Initializer must emit exactly one JSON document for $Action; output: $document" }
  [pscustomobject]@{ Result = $result; ExitCode = $exitCode }
}

function Write-TestManifest {
  param(
    [string]$Root,
    [string]$Name = 'Controller Test',
    [AllowNull()][object]$ControllerBinding = $null,
    [AllowNull()][object]$ControllerTaskIntent = $null,
    [object[]]$ProjectBindings = @(),
    [object[]]$DispatchQueues = @(),
    [int]$Version = 3,
    [AllowNull()][object]$TaskSetReset = $null
  )
  $manifest = [ordered]@{
    schemaVersion = $Version
    generator = 'onboard-code-projects'
    templateVersion = $Version
    controllerName = $Name
    controllerBinding = $ControllerBinding
    controllerTaskIntent = $ControllerTaskIntent
    projectBindings = @($ProjectBindings)
  }
  if ($Version -ge 2) { $manifest.dispatchQueues = @($DispatchQueues) }
  if ($Version -eq 3) {
    $manifest.taskSetId = Get-ExpectedTaskSetId ([IO.Path]::GetFullPath($Root).TrimEnd('\'))
    $manifest.taskSetReset = $TaskSetReset
  }
  $manifest = [pscustomobject]$manifest
  $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
  [IO.File]::WriteAllBytes((Join-Path $Root '.codex-controller.json'), $bytes)
  return $bytes
}

function Get-TestCanonicalHash {
  param([object]$Value)
  return Get-TestHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 20 -Compress)))
}

function New-TestPreparedTaskSetReset {
  param(
    [string]$Root,
    [object]$ControllerBinding,
    [string]$OperationId,
    [string]$CreationOperationId
  )
  $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $fromTaskSetId = Get-ExpectedTaskSetId $normalizedRoot
  $toTaskSetId = 'task-set-' + (Get-TestCanonicalHash @('task-set-reset-v1', $normalizedRoot.ToLowerInvariant(), $fromTaskSetId, $OperationId))
  $summary = 'bounded reset fixture handoff'
  $handoff = [pscustomobject][ordered]@{
    summary=$summary; summaryHash=(Get-TestHash ([Text.Encoding]::UTF8.GetBytes($summary)))
    oldestTurnId='fixture-turn-1'; newestTurnId='fixture-turn-1'; turnCount=1; historyDigest=('a' * 64); eofComplete=$true; observedAt='2026-08-03T00:00:10Z'
  }
  $coordinator = [pscustomobject][ordered]@{ threadId='fixture-reset-coordinator'; hostId='fixture-reset-coordinator-host' }
  $planTarget = [pscustomobject][ordered]@{
    kind='controller'; projectRoot=$normalizedRoot; creationOperationId=$CreationOperationId
    expectedCodexProjectId=$ControllerBinding.codexProjectId; expectedHostId=$ControllerBinding.hostId
  }
  $plan = [pscustomobject][ordered]@{
    operationId=$OperationId; fromTaskSetId=$fromTaskSetId; toTaskSetId=$toTaskSetId; coordinator=$coordinator
    expectedController=$ControllerBinding; expectedProjectBindings=@(); targets=@($planTarget)
  }
  $planHash = Get-TestCanonicalHash $plan
  $runtimeReadback = [pscustomobject][ordered]@{
    state='controller-replacement-read'; controllerRoot=$normalizedRoot; controllerThreadId=$ControllerBinding.threadId; hostId=$ControllerBinding.hostId
    replacementState='none'; operationId=$null; replacementSetHash=$null; oldControllerThreadId=$null; oldHostId=$null; newControllerThreadId=$null; newHostId=$null
    manifestPreparedHash=$null; prepareToken=$null; manifestSwitchedHash=$null; preparedAt=$null; committedAt=$null; activeDispatchCount=0; unacknowledgedReceiptCount=0
    fenceState='prepared'; fenceOperationId=$OperationId; fencePlanHash=$planHash; fenceManifestExpectedHash=('f' * 64); fencePreparedAt='2026-08-03T00:00:15Z'; fenceCompletedManifestHash=$null; fenceCompletedAt=$null
    wakeWorkerState='none'; wakeWorkerOperationId=$null; wakeWorkerThreadId=$null; wakeWorkerClientThreadId=$null
    wakeAutomationState='none'; wakeAutomationOperationId=$null; wakeAutomationId=$null
  }
  $quietCore = [pscustomobject][ordered]@{
    runtimeDispatches=0; unackedReceipts=0; claims=0; goalReservations=0; approvals=0; activeScopedTasks=0
    automationIntents=0; writers=0; candidates=0; heartbeatPaused=$true
    runtimeReadback=$runtimeReadback; runtimeReadbackHash=(Get-TestCanonicalHash $runtimeReadback); observedAt='2026-08-03T00:00:20Z'
  }
  $quiet = [pscustomobject][ordered]@{
    runtimeDispatches=0; unackedReceipts=0; claims=0; goalReservations=0; approvals=0; activeScopedTasks=0
    automationIntents=0; writers=0; candidates=0; heartbeatPaused=$true
    runtimeReadback=$runtimeReadback; runtimeReadbackHash=$quietCore.runtimeReadbackHash; observedAt=$quietCore.observedAt; proofHash=(Get-TestCanonicalHash $quietCore)
  }
  $storedTarget = [pscustomobject][ordered]@{
    kind='controller'; projectRoot=$normalizedRoot; creationOperationId=$CreationOperationId
    expectedCodexProjectId=$ControllerBinding.codexProjectId; expectedHostId=$ControllerBinding.hostId
    initialHandoff=$handoff; finalHandoff=$null; creationIssuedAt=$null; clientThreadId=$null; replacement=$null; bootstrapProof=$null; standbyProof=$null
  }
  $evidence = [pscustomobject][ordered]@{
    targets=@([pscustomobject][ordered]@{kind='controller';projectRoot=$normalizedRoot;handoff=$handoff})
    activeChains=@(); externalQuiescence=$quiet; archives=@()
  }
  return [pscustomobject][ordered]@{
    operationId=$OperationId; planHash=$planHash; initialEvidenceHash=(Get-TestCanonicalHash $evidence); finalEvidenceHash=$null
    fromTaskSetId=$fromTaskSetId; toTaskSetId=$toTaskSetId; phase='prepared'; coordinator=$coordinator
    expectedController=$ControllerBinding; expectedProjectBindings=@(); targets=@($storedTarget)
    initialActiveChains=@(); initialExternalQuiescence=$quiet; finalActiveChains=$null; finalExternalQuiescence=$null
    replacementSetHash=$null; runtimePrepared=$null; runtimeCommitted=$null; archives=@()
    preparedAt='2026-08-03T00:00:30Z'; finalizedAt=$null; switchedAt=$null; completedAt=$null
  }
}

function Invoke-FreshTaskSetLifecycle {
  param([string]$Root, [string]$Name = 'Controller Test')
  $expected = Get-ExpectedV3Manifest -Root $Root -Name $Name
  $firstPlan = Invoke-Subject -Action Plan -ControllerRoot $Root -ControllerName $Name
  Assert-Result $firstPlan.Result 'Plan' @('planned') $firstPlan.ExitCode
  Assert-True ($firstPlan.ExitCode -eq 0 -and $firstPlan.Result.changed) 'Fresh Plan must report the deterministic v3 scaffold'
  Assert-True ($firstPlan.Result.resultManifestHash -ceq $expected.Hash) 'Fresh Plan must publish the exact deterministic v3 manifest hash'
  Assert-True (-not (Test-Path -LiteralPath $Root)) 'Fresh Plan must remain write-free'
  $secondPlan = Invoke-Subject -Action Plan -ControllerRoot ($Root + '\') -ControllerName $Name
  Assert-Result $secondPlan.Result 'Plan' @('planned') $secondPlan.ExitCode
  Assert-True ($secondPlan.Result.resultManifestHash -ceq $firstPlan.Result.resultManifestHash) 'Equivalent normalized roots must produce the same Plan manifest hash'
  Assert-True (-not (Test-Path -LiteralPath $Root)) 'Repeated Plan must remain write-free'
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $casePlan = Invoke-Subject -Action Plan -ControllerRoot $Root.ToUpperInvariant() -ControllerName $Name
    Assert-Result $casePlan.Result 'Plan' @('planned') $casePlan.ExitCode
    Assert-True ($casePlan.Result.resultManifestHash -ceq $firstPlan.Result.resultManifestHash) 'Equivalent Windows path casing must produce the same Plan manifest hash'
    Assert-True (-not (Test-Path -LiteralPath $Root)) 'Case-variant Plan must remain write-free'
  }
  $apply = Invoke-Subject -Action Apply -ControllerRoot $Root -ControllerName $Name
  Assert-Result $apply.Result 'Apply' @('applied') $apply.ExitCode
  Assert-True ($apply.ExitCode -eq 0 -and $apply.Result.resultManifestHash -ceq $firstPlan.Result.resultManifestHash) 'Apply must materialize the exact manifest hash reported by Plan'
  $actualBytes = [IO.File]::ReadAllBytes((Join-Path $Root '.codex-controller.json'))
  Assert-True ([Linq.Enumerable]::SequenceEqual($actualBytes, [byte[]]$expected.Bytes)) 'Apply must materialize the exact closed v3 manifest bytes'
  Assert-True (-not ([Text.Encoding]::UTF8.GetString($actualBytes).Contains('__'))) 'Apply must not leave a template placeholder in the manifest'
  $verify = Invoke-Subject -Action Verify -ControllerRoot $Root -ControllerName $null
  Assert-Result $verify.Result 'Verify' @('verified') $verify.ExitCode
  Assert-True ($verify.ExitCode -eq 0 -and $verify.Result.resultManifestHash -ceq $firstPlan.Result.resultManifestHash) 'Verify must accept the deterministic v3 manifest'
  return [pscustomobject]@{ Plan=$firstPlan; Apply=$apply; Verify=$verify; Expected=$expected }
}

function Convert-ToLegacyLayout {
  param([string]$Root)
  foreach ($relativePath in @('.chain-store.json', 'TASKS.md', 'tools\chain-store.ps1', 'tools\dispatch-return-runtime.mjs')) {
    $path = Join-Path $Root $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
  }
  foreach ($relativePath in @('memory', 'state')) {
    $path = Join-Path $Root $relativePath
    if (Test-Path -LiteralPath $path -PathType Container) { [IO.Directory]::Delete($path, $true) }
  }
}

if (-not (Test-Path -LiteralPath $subject -PathType Leaf)) {
  throw "RED: missing initializer subject $subject"
}
$runtimeSource = Join-Path $PSScriptRoot 'dispatch-return-runtime.mjs'
if (-not (Test-Path -LiteralPath $runtimeSource -PathType Leaf)) { throw "RED: missing runtime source $runtimeSource" }
$managedPaths = @('.codex-controller.json', '.gitignore', 'AGENTS.md', 'docs\cross-project-contracts.md', 'tools\control-state.ps1', '.chain-store.json', 'tools\chain-store.ps1', 'tools\dispatch-return-runtime.mjs', 'TASKS.md', 'memory\MEMORY.md', 'state\index.json', 'state\experience-index.json')
$managedDirectories = @('docs','tools','memory','state','state\active','state\archive','state\goals')
$plannedPaths = $managedDirectories + $managedPaths
$templatePaths = @($managedPaths | Where-Object { $_ -notin @('tools\dispatch-return-runtime.mjs','TASKS.md','memory\MEMORY.md','state\index.json','state\experience-index.json') })
foreach ($template in $templatePaths) {
  if (-not (Test-Path -LiteralPath (Join-Path $templateRoot $template) -PathType Leaf)) {
    throw "RED: missing controller template $template"
  }
}

if ($FocusedTaskSet) {
  $focusedRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-controller-task-set-focus-' + [guid]::NewGuid().ToString('N'))
  try {
    Invoke-FreshTaskSetLifecycle -Root $focusedRoot | Out-Null
    $focusedBinding = [pscustomobject][ordered]@{ threadId='focused-controller'; codexProjectId='focused-project'; hostId='focused-host'; projectRoot=$focusedRoot }
    $focusedReset = New-TestPreparedTaskSetReset -Root $focusedRoot -ControllerBinding $focusedBinding -OperationId 'focused-reset' -CreationOperationId 'focused-create'
    Write-TestManifest -Root $focusedRoot -ControllerBinding $focusedBinding -TaskSetReset $focusedReset | Out-Null
    $focusedStateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $focusedRoot 'tools\control-state.ps1') -Action Read -ControllerRoot $focusedRoot
    $focusedStateExit = $LASTEXITCODE
    $focusedState = (($focusedStateOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($focusedStateExit -eq 0 -and $focusedState.status -ceq 'verified') "Focused reset fixture must pass v3 validation; got $($focusedState.reasonCode)"
    $focusedResetPlan = Invoke-Subject -Action Plan -ControllerRoot $focusedRoot -ControllerName 'Controller Test' -AllowUpgrade $true
    Assert-Result $focusedResetPlan.Result 'Plan' @('conflict') $focusedResetPlan.ExitCode
    Assert-ReasonCode $focusedResetPlan.Result 'controller-upgrade-active-work' "Initializer writes must block while a task-set reset exists; nextAction: $($focusedResetPlan.Result.nextAction)"
    Write-Output 'PASS init-controller focused task-set v3'
  }
  finally {
    if (Test-Path -LiteralPath $focusedRoot) { Remove-Item -LiteralPath $focusedRoot -Recurse -Force }
  }
  exit 0
}

if ($FocusedTaskSetSeal) {
  $focusedRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-controller-task-set-seal-focus-' + [guid]::NewGuid().ToString('N'))
  try {
    Invoke-FreshTaskSetLifecycle -Root $focusedRoot | Out-Null
    $manifestPath = Join-Path $focusedRoot '.codex-controller.json'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $markerPath = Join-Path $focusedRoot 'state\.task-set-reset-seal.json'
    $markerBytes = [Text.Encoding]::UTF8.GetBytes("{}`n")
    [IO.File]::WriteAllBytes($markerPath, $markerBytes)
    foreach ($action in @('Plan','Apply','Verify')) {
      $blocked = Invoke-Subject -Action $action -ControllerRoot $focusedRoot
      Assert-Result $blocked.Result $action @('conflict') $blocked.ExitCode
      Assert-ReasonCode $blocked.Result 'controller-task-set-reset-seal-recovery-required' "$action must fail closed while reset seal recovery is pending"
      Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($manifestPath), $manifestBytes)) "$action must preserve exact manifest bytes while seal recovery is pending"
      Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($markerPath), $markerBytes)) "$action must preserve exact seal marker bytes"
    }
    Write-Output 'PASS init-controller focused task-set seal recovery gate'
  }
  finally {
    if (Test-Path -LiteralPath $focusedRoot) { Remove-Item -LiteralPath $focusedRoot -Recurse -Force }
  }
  exit 0
}

if ($FocusedStoreBackedV2) {
  $focusedRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-controller-store-v2-focus-' + [guid]::NewGuid().ToString('N'))
  try {
    $initial = Invoke-Subject -Action Apply -ControllerRoot $focusedRoot
    Assert-Result $initial.Result 'Apply' @('applied') $initial.ExitCode
    Assert-True ($initial.ExitCode -eq 0) 'Focused store-backed fixture must start as an intact generated controller'
    $v2ManifestBytes = [byte[]](Write-TestManifest -Root $focusedRoot -Version 2)
    $customPath = Join-Path $focusedRoot 'docs\cross-project-contracts.md'
    $customBytes = [Text.Encoding]::UTF8.GetBytes("# preserved custom store-backed controller`n")
    [IO.File]::WriteAllBytes($customPath, $customBytes)
    $statePath = Join-Path $focusedRoot 'state\index.json'
    $stateBytes = [IO.File]::ReadAllBytes($statePath)
    foreach ($action in @('Plan','Apply')) {
      $blocked = Invoke-Subject -Action $action -ControllerRoot $focusedRoot -AllowUpgrade $true
      Assert-Result $blocked.Result $action @('conflict') $blocked.ExitCode
      Assert-ReasonCode $blocked.Result 'controller-upgrade-unsupported-layout' "$action must fail closed for a store-backed v2 controller"
      Assert-True (-not $blocked.Result.changed) "$action must not claim a store-backed v2 change"
      Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $focusedRoot '.codex-controller.json')), $v2ManifestBytes)) "$action must preserve exact store-backed v2 manifest bytes"
      Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($statePath), $stateBytes)) "$action must preserve exact store-backed state bytes"
      Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($customPath), $customBytes)) "$action must preserve exact custom document bytes"
    }
    Write-Output 'PASS init-controller focused store-backed v2 fail-closed'
  }
  finally {
    if (Test-Path -LiteralPath $focusedRoot) { Remove-Item -LiteralPath $focusedRoot -Recurse -Force }
  }
  exit 0
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-controller-tests-' + [guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$driveRoot = [IO.Path]::GetPathRoot($resolvedTestRoot)
$isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$driveInfo = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $driveRoot } | Select-Object -First 1)
$fileSystem = if ($isWindows -and $driveInfo.Count -eq 1) { [string]$driveInfo[0].DriveFormat } else { '' }
try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $attributesPath = Join-Path $skillRoot '.gitattributes'
  Assert-True (Test-Path -LiteralPath $attributesPath -PathType Leaf) 'The package must pin text files to LF for core.autocrlf=true clones'
  $cloneSource = Join-Path $testRoot 'autocrlf-source'
  $cloneCheckout = Join-Path $testRoot 'autocrlf-checkout'
  [IO.Directory]::CreateDirectory((Join-Path $cloneSource 'scripts')) | Out-Null
  [IO.Directory]::CreateDirectory((Join-Path $cloneSource 'templates')) | Out-Null
  $cloneTemplateRoot = Join-Path $cloneSource 'templates\controller'
  [IO.Directory]::CreateDirectory($cloneTemplateRoot) | Out-Null
  Copy-Item -LiteralPath $attributesPath -Destination (Join-Path $cloneSource '.gitattributes')
  Copy-Item -LiteralPath $subject -Destination (Join-Path $cloneSource 'scripts\init-controller.ps1')
  Copy-Item -LiteralPath $runtimeSource -Destination (Join-Path $cloneSource 'scripts\dispatch-return-runtime.mjs')
  foreach ($templateItem in @(Get-ChildItem -Force -LiteralPath $templateRoot)) {
    Copy-Item -LiteralPath $templateItem.FullName -Destination $cloneTemplateRoot -Recurse
  }
  & git -C $cloneSource init --quiet
  & git -C $cloneSource config user.name 'Onboard Test'
  & git -C $cloneSource config user.email 'onboard-test@example.invalid'
  & git -C $cloneSource add -f -- .
  & git -C $cloneSource commit --quiet -m 'autocrlf fixture'
  Assert-True ($LASTEXITCODE -eq 0) 'Autocrlf fixture commit must succeed'
  & git -c core.autocrlf=true clone --quiet --no-local $cloneSource $cloneCheckout
  Assert-True ($LASTEXITCODE -eq 0) 'core.autocrlf=true fixture clone must succeed'
  foreach ($relativePath in @('scripts\init-controller.ps1','scripts\dispatch-return-runtime.mjs') + @($templatePaths | ForEach-Object { 'templates\controller\' + $_ })) {
    $cloneBytes = [IO.File]::ReadAllBytes((Join-Path $cloneCheckout $relativePath))
    Assert-True (-not ([Text.Encoding]::UTF8.GetString($cloneBytes).Contains("`r"))) "core.autocrlf=true must preserve LF bytes for $relativePath"
  }
  $clonePlan = Invoke-Subject -Action Plan -ControllerRoot (Join-Path $testRoot 'autocrlf-controller') -SubjectPath (Join-Path $cloneCheckout 'scripts\init-controller.ps1')
  Assert-Result $clonePlan.Result 'Plan' @('planned') $clonePlan.ExitCode
  Assert-True ($clonePlan.ExitCode -eq 0) 'A core.autocrlf=true checkout must pass controller Plan'

  $controllerRoot = Join-Path $testRoot 'controller'
  $lifecycle = Invoke-FreshTaskSetLifecycle -Root $controllerRoot
  $plan = $lifecycle.Plan
  $apply = $lifecycle.Apply
  Assert-True (@($plan.Result.plannedCreates).Count -eq $plannedPaths.Count) 'Fresh plan must declare the complete bounded scaffold'
  foreach ($relativePath in $plannedPaths) {
    Assert-True (@($plan.Result.plannedCreates) -contains $relativePath) "Fresh plan must declare $relativePath"
  }

  foreach ($relativePath in $managedPaths) {
    Assert-True (Test-Path -LiteralPath (Join-Path $controllerRoot $relativePath) -PathType Leaf) "Apply must create $relativePath"
  }
  foreach ($relativePath in $managedDirectories) {
    Assert-True (Test-Path -LiteralPath (Join-Path $controllerRoot $relativePath) -PathType Container) "Apply must create directory $relativePath"
  }
  $manifestPath = Join-Path $controllerRoot '.codex-controller.json'
  $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
  Assert-True (-not ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF)) 'Manifest must be UTF-8 without BOM'
  $manifestText = [Text.Encoding]::UTF8.GetString($manifestBytes)
  Assert-True ($manifestText.EndsWith("`n") -and -not $manifestText.Contains("`r") -and ($manifestText.TrimEnd("`n") -notmatch "`n")) 'Manifest must be compact JSON with one trailing LF'
  $manifest = $manifestText | ConvertFrom-Json
  $manifestFields = @($manifest.PSObject.Properties.Name)
  Assert-True (@($manifestFields).Count -eq 10) 'Manifest must be a closed ten-field object'
  foreach ($field in @('schemaVersion', 'generator', 'templateVersion', 'controllerName', 'controllerBinding', 'controllerTaskIntent', 'projectBindings', 'dispatchQueues', 'taskSetId', 'taskSetReset')) {
    Assert-True ($manifestFields -ccontains $field) "Manifest must contain $field"
  }
  Assert-True ($manifest.schemaVersion -eq 3 -and $manifest.generator -ceq 'onboard-code-projects' -and $manifest.templateVersion -eq 3) 'Manifest version and generator must match the v3 contract'
  Assert-True ($manifest.taskSetId -ceq (Get-ExpectedTaskSetId $controllerRoot) -and $manifest.taskSetId -cmatch '^task-set-[0-9a-f]{64}$' -and $null -eq $manifest.taskSetReset) 'Fresh manifest must contain the safe root-derived task-set identity and no reset'
  Assert-True ($manifest.controllerName -ceq 'Controller Test' -and $null -eq $manifest.controllerBinding -and $null -eq $manifest.controllerTaskIntent -and @($manifest.projectBindings).Count -eq 0 -and @($manifest.dispatchQueues).Count -eq 0) 'Fresh manifest must contain the requested name and empty bindings/queues'
  $stateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $controllerRoot 'tools\control-state.ps1') -Action Read -ControllerRoot $controllerRoot
  $stateExit = $LASTEXITCODE
  $stateResult = (($stateOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
  Assert-True ($stateExit -eq 0 -and $stateResult.status -ceq 'verified' -and $stateResult.currentHash -ceq $stateResult.resultHash) 'Generated state adapter Read must verify the v3 manifest'
  $chainOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $controllerRoot 'tools\chain-store.ps1') -Action Verify -ControllerRoot $controllerRoot
  $chainExit = $LASTEXITCODE
  $chainResult = (($chainOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
  Assert-True ($chainExit -eq 0 -and $chainResult.status -ceq 'verified' -and $chainResult.data.activeCount -eq 0) 'Generated chain store must verify its compact empty state'
  $runtimePath = Join-Path $controllerRoot 'tools\dispatch-return-runtime.mjs'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($runtimePath), [IO.File]::ReadAllBytes($runtimeSource))) 'Generated dispatch return runtime must remain byte-identical to its tested source'
  $runtimeOutput = & node $runtimePath verify --state-path (Join-Path $testRoot 'runtime-state.json')
  $runtimeExit = $LASTEXITCODE
  $runtimeResult = (($runtimeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
  Assert-True ($runtimeExit -eq 0 -and $runtimeResult.state -ceq 'runtime-verified') 'Generated dispatch return runtime must verify'

  $idempotent = Invoke-Subject -Action Apply -ControllerRoot $controllerRoot
  Assert-Result $idempotent.Result 'Apply' @('applied') $idempotent.ExitCode
  Assert-True ($idempotent.ExitCode -eq 0 -and -not $idempotent.Result.changed) 'Byte-identical Apply must be idempotent'

  $verify = $lifecycle.Verify

  $namedRoot = Join-Path $testRoot 'named-controller'
  $namedApply = Invoke-Subject -Action Apply -ControllerRoot $namedRoot -ControllerName '__TEAM__'
  Assert-Result $namedApply.Result 'Apply' @('applied') $namedApply.ExitCode
  $namedVerify = Invoke-Subject -Action Verify -ControllerRoot $namedRoot -ControllerName $null
  Assert-Result $namedVerify.Result 'Verify' @('verified') $namedVerify.ExitCode
  Assert-True ($namedVerify.ExitCode -eq 0) 'Verify must accept a valid persisted custom name when ControllerName is omitted'

  $invalidManifestRoot = Join-Path $testRoot 'invalid-manifest-controller'
  $invalidManifestApply = Invoke-Subject -Action Apply -ControllerRoot $invalidManifestRoot
  Assert-Result $invalidManifestApply.Result 'Apply' @('applied') $invalidManifestApply.ExitCode
  $invalidManifestPath = Join-Path $invalidManifestRoot '.codex-controller.json'
  $invalidManifestBytes = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":3,"generator":"onboard-code-projects","templateVersion":3,"controllerName":"Controller Test","controllerBinding":null,"controllerTaskIntent":null,"projectBindings":[],"dispatchQueues":[],"taskSetId":"task-set-invalid-fixture","taskSetReset":null,"unknown":true}' + "`n")
  [IO.File]::WriteAllBytes($invalidManifestPath, $invalidManifestBytes)
  $invalidManifestVerify = Invoke-Subject -Action Verify -ControllerRoot $invalidManifestRoot
  Assert-Result $invalidManifestVerify.Result 'Verify' @('conflict') $invalidManifestVerify.ExitCode
  Assert-ReasonCode $invalidManifestVerify.Result 'controller-filesystem-conflict' 'Closed-manifest violations must fail verification without rewriting'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($invalidManifestPath), $invalidManifestBytes)) 'Invalid manifest bytes must be preserved for manual recovery'

  $boundRoot = Join-Path $testRoot 'bound-controller'
  $boundApply = Invoke-Subject -Action Apply -ControllerRoot $boundRoot
  Assert-Result $boundApply.Result 'Apply' @('applied') $boundApply.ExitCode
  $controllerBinding = [pscustomobject][ordered]@{
    threadId = 'controller-thread-A'
    codexProjectId = 'controller-project-A'
    hostId = 'host-A'
    projectRoot = $boundRoot
  }
  $controllerIntent = [pscustomobject][ordered]@{
    operationId = 'operation-A'
    codexProjectId = 'controller-project-A'
    hostId = 'host-A'
    projectRoot = (Join-Path $testRoot 'saved-controller-project')
    startedAt = '2026-08-02T00:00:00.000Z'
    clientThreadId = $null
  }
  $projectBinding = [pscustomobject][ordered]@{
    entryThreadId = 'entry-thread-A'
    codexProjectId = 'business-project-A'
    hostId = 'host-A'
    projectRoot = (Join-Path $testRoot 'business-bound-A')
  }
  Write-TestManifest -Root $boundRoot -ControllerBinding $controllerBinding -ProjectBindings @($projectBinding) | Out-Null
  $boundVerify = Invoke-Subject -Action Verify -ControllerRoot $boundRoot -ControllerName $null
  Assert-Result $boundVerify.Result 'Verify' @('verified') $boundVerify.ExitCode
  Assert-True ($boundVerify.ExitCode -eq 0) 'Read and Verify must accept a valid binding-only closed v3 manifest'

  $legacyRoot = Join-Path $testRoot 'legacy-v1-controller'
  $legacyApply = Invoke-Subject -Action Apply -ControllerRoot $legacyRoot
  Assert-Result $legacyApply.Result 'Apply' @('applied') $legacyApply.ExitCode
  Convert-ToLegacyLayout -Root $legacyRoot
  $legacyBinding = [pscustomobject][ordered]@{ threadId='legacy-thread'; codexProjectId='legacy-project'; hostId='legacy-host'; projectRoot=$legacyRoot }
  $legacyProjectRoot = Join-Path $testRoot 'legacy-business'
  [IO.Directory]::CreateDirectory($legacyProjectRoot) | Out-Null
  $legacyProject = [pscustomobject][ordered]@{ entryThreadId='legacy-entry'; codexProjectId='legacy-business-project'; hostId='legacy-host'; projectRoot=$legacyProjectRoot }
  $legacyBytes = [byte[]](Write-TestManifest -Root $legacyRoot -ControllerBinding $legacyBinding -ProjectBindings @($legacyProject) -Version 1)
  $legacyContractsPath = Join-Path $legacyRoot 'docs\cross-project-contracts.md'
  $legacyContractsBytes = [Text.Encoding]::UTF8.GetBytes("# preserved legacy contracts`n")
  [IO.File]::WriteAllBytes($legacyContractsPath, $legacyContractsBytes)
  $legacyPlanWithoutApproval = Invoke-Subject -Action Plan -ControllerRoot $legacyRoot
  Assert-Result $legacyPlanWithoutApproval.Result 'Plan' @('authorization-required') $legacyPlanWithoutApproval.ExitCode
  Assert-ReasonCode $legacyPlanWithoutApproval.Result 'controller-upgrade-authorization-required' 'A legacy controller must require explicit upgrade authorization'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $legacyRoot '.codex-controller.json')), $legacyBytes)) 'Upgrade planning without authorization must not change the legacy manifest'
  $legacyPlan = Invoke-Subject -Action Plan -ControllerRoot $legacyRoot -AllowUpgrade $true
  Assert-Result $legacyPlan.Result 'Plan' @('planned') $legacyPlan.ExitCode
  Assert-ReasonCode $legacyPlan.Result 'controller-upgrade-plan-ready' 'An authorized legacy Plan must expose the exact migration'
  $expectedLegacyUpgrade = Get-ExpectedV3Manifest -Root $legacyRoot -Name 'Controller Test' -ControllerBinding $legacyBinding -ProjectBindings @($legacyProject)
  Assert-True ($legacyPlan.Result.resultManifestHash -ceq $expectedLegacyUpgrade.Hash) 'Legacy Plan must publish the exact deterministic v3 manifest hash'
  Assert-True ([string]$legacyPlan.Result.nextAction -cmatch 'Skill preflight') 'Legacy Plan must assign external quiescence proof to the Skill preflight'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $legacyRoot '.codex-controller.json')), $legacyBytes)) 'Authorized Plan must remain write-free'
  $legacyUpgrade = Invoke-Subject -Action Apply -ControllerRoot $legacyRoot -AllowUpgrade $true
  Assert-Result $legacyUpgrade.Result 'Apply' @('applied') $legacyUpgrade.ExitCode
  Assert-ReasonCode $legacyUpgrade.Result 'controller-upgraded' 'Authorized Apply must migrate a known v1 controller'
  $upgradedManifestBytes = [IO.File]::ReadAllBytes((Join-Path $legacyRoot '.codex-controller.json'))
  $upgradedManifest = [Text.Encoding]::UTF8.GetString($upgradedManifestBytes) | ConvertFrom-Json
  Assert-True ([Linq.Enumerable]::SequenceEqual($upgradedManifestBytes, [byte[]]$expectedLegacyUpgrade.Bytes) -and $legacyUpgrade.Result.resultManifestHash -ceq $expectedLegacyUpgrade.Hash) 'Legacy Apply must materialize the exact manifest bytes and hash from Plan'
  Assert-True ($upgradedManifest.schemaVersion -eq 3 -and $upgradedManifest.templateVersion -eq 3 -and @($upgradedManifest.dispatchQueues).Count -eq 0 -and $upgradedManifest.taskSetId -ceq (Get-ExpectedTaskSetId $legacyRoot) -and $null -eq $upgradedManifest.taskSetReset) 'Upgrade must create the closed deterministic v3 task-set state'
  Assert-True ($upgradedManifest.controllerBinding.threadId -ceq 'legacy-thread' -and @($upgradedManifest.projectBindings).Count -eq 1 -and $upgradedManifest.projectBindings[0].entryThreadId -ceq 'legacy-entry') 'Upgrade must preserve controller and project bindings'
  Assert-True ([string]$legacyUpgrade.Result.nextAction -cmatch 'Skill preflight' -and [string]$legacyUpgrade.Result.nextAction -cnotmatch '(?i)initializer verified') 'Upgrade result must not claim initializer verification of external runtime state'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($legacyContractsPath), $legacyContractsBytes)) 'Upgrade must preserve the human-edited cross-project contract'
  $legacyVerify = Invoke-Subject -Action Verify -ControllerRoot $legacyRoot -ControllerName $null
  Assert-Result $legacyVerify.Result 'Verify' @('verified') $legacyVerify.ExitCode

  $legacyV2Root = Join-Path $testRoot 'legacy-v2-terminal-controller'
  Invoke-Subject -Action Apply -ControllerRoot $legacyV2Root | Out-Null
  Convert-ToLegacyLayout -Root $legacyV2Root
  $legacyV2ProjectRoot = Join-Path $testRoot 'legacy-v2-business'
  [IO.Directory]::CreateDirectory($legacyV2ProjectRoot) | Out-Null
  $legacyV2Binding = [pscustomobject][ordered]@{ threadId='legacy-v2-controller'; codexProjectId='legacy-v2-controller-project'; hostId='legacy-v2-host'; projectRoot=$legacyV2Root }
  $legacyV2Project = [pscustomobject][ordered]@{ entryThreadId='legacy-v2-current-entry'; codexProjectId='legacy-v2-business-project'; hostId='legacy-v2-host'; projectRoot=$legacyV2ProjectRoot }
  $terminalTaskSpec = [pscustomobject][ordered]@{
    objective='Preserve terminal history during upgrade'; nonGoals=@('write'); acceptance=@('old task id remains')
    authorizedActions=@('read','test'); forbiddenActions=@('write'); baseline=[pscustomobject][ordered]@{ branch='N/A'; head='N/A'; dirtyHash='N/A' }
    contract=[pscustomobject][ordered]@{ id='N/A'; version='N/A'; hash='N/A' }; dependencies=@(); authorizationRef='authref:legacy-v2-business-project:terminal'
  }
  $terminalTaskSpecHash = Get-TestHash ([Text.Encoding]::UTF8.GetBytes(($terminalTaskSpec | ConvertTo-Json -Depth 12 -Compress)))
  $lastTerminal = [pscustomobject][ordered]@{
    chainId='CHAIN-legacy-v2-terminal'; projectTaskId='legacy-v2-old-entry'; dispatchId='dispatch-legacy-v2-terminal'; generation=1; rework=0; accessMode='read'; modelClass='economy'
    taskSpec=$terminalTaskSpec; taskSpecHash=$terminalTaskSpecHash; attemptFailures=@(); deliveryReconciliation=$null; authorizationResumedAt=$null
    enqueuedAt='2026-08-01T00:00:00Z'; startedAt='2026-08-01T00:01:00Z'; phase='terminal'; resultState='completed'; evidenceHash=('a' * 64); finishedAt='2026-08-01T00:02:00Z'; cancelRequestedAt=$null; writeLease=$null
  }
  $legacyV2Queue = [pscustomobject][ordered]@{ projectRoot=$legacyV2ProjectRoot; active=$null; pending=@(); lastTerminal=$lastTerminal }
  $legacyV2Bytes = [byte[]](Write-TestManifest -Root $legacyV2Root -Name 'Preserved V2 Controller' -ControllerBinding $legacyV2Binding -ProjectBindings @($legacyV2Project) -DispatchQueues @($legacyV2Queue) -Version 2)
  $expectedV2Upgrade = Get-ExpectedV3Manifest -Root $legacyV2Root -Name 'Preserved V2 Controller' -ControllerBinding $legacyV2Binding -ProjectBindings @($legacyV2Project) -DispatchQueues @($legacyV2Queue)
  $legacyV2Plan = Invoke-Subject -Action Plan -ControllerRoot $legacyV2Root -ControllerName 'Preserved V2 Controller' -AllowUpgrade $true
  Assert-Result $legacyV2Plan.Result 'Plan' @('planned') $legacyV2Plan.ExitCode
  Assert-True ($legacyV2Plan.Result.resultManifestHash -ceq $expectedV2Upgrade.Hash) 'V2 Plan must publish the exact deterministic v3 preservation hash'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $legacyV2Root '.codex-controller.json')), $legacyV2Bytes)) 'V2 Plan must preserve the exact legacy manifest bytes'
  $legacyV2Upgrade = Invoke-Subject -Action Apply -ControllerRoot $legacyV2Root -ControllerName 'Preserved V2 Controller' -AllowUpgrade $true
  Assert-Result $legacyV2Upgrade.Result 'Apply' @('applied') $legacyV2Upgrade.ExitCode
  $legacyV2UpgradedBytes = [IO.File]::ReadAllBytes((Join-Path $legacyV2Root '.codex-controller.json'))
  Assert-True ([Linq.Enumerable]::SequenceEqual($legacyV2UpgradedBytes, [byte[]]$expectedV2Upgrade.Bytes)) 'V2 Apply must preserve the full dispatch queues as exact v3 bytes'
  $legacyV2Upgraded = [Text.Encoding]::UTF8.GetString($legacyV2UpgradedBytes) | ConvertFrom-Json
  Assert-True ($legacyV2Upgraded.controllerName -ceq 'Preserved V2 Controller' -and $legacyV2Upgraded.controllerBinding.threadId -ceq 'legacy-v2-controller' -and $legacyV2Upgraded.dispatchQueues[0].lastTerminal.projectTaskId -ceq 'legacy-v2-old-entry') 'V2 Apply must preserve names, bindings, and old task IDs in terminal history'

  $activeUpgradeRoot = Join-Path $testRoot 'legacy-v2-active-controller'
  $activeUpgradeApply = Invoke-Subject -Action Apply -ControllerRoot $activeUpgradeRoot
  Assert-Result $activeUpgradeApply.Result 'Apply' @('applied') $activeUpgradeApply.ExitCode
  Convert-ToLegacyLayout -Root $activeUpgradeRoot
  $activeProjectRoot = Join-Path $testRoot 'active-upgrade-business'
  [IO.Directory]::CreateDirectory($activeProjectRoot) | Out-Null
  $activeBinding = [pscustomobject][ordered]@{ threadId='active-controller'; codexProjectId='active-controller-project'; hostId='active-host'; projectRoot=$activeUpgradeRoot }
  $activeProject = [pscustomobject][ordered]@{ entryThreadId='active-entry'; codexProjectId='active-business-project'; hostId='active-host'; projectRoot=$activeProjectRoot }
  $activeTaskSpec = [pscustomobject][ordered]@{
    objective='Preserve one queued task during upgrade'; nonGoals=@('write'); acceptance=@('remain queued')
    authorizedActions=@('read','test'); forbiddenActions=@('write'); baseline=[pscustomobject][ordered]@{ branch='N/A'; head='N/A'; dirtyHash='N/A' }
    contract=[pscustomobject][ordered]@{ id='N/A'; version='N/A'; hash='N/A' }; dependencies=@(); authorizationRef='authref:active-business-project:queued'
  }
  $activeTaskSpecHash = Get-TestHash ([Text.Encoding]::UTF8.GetBytes(($activeTaskSpec | ConvertTo-Json -Depth 12 -Compress)))
  $pendingDispatch = [pscustomobject][ordered]@{
    chainId='CHAIN-active-upgrade'; projectTaskId='active-entry'; dispatchId='dispatch-active-upgrade'; generation=1; rework=0; accessMode='read'; modelClass='economy'
    taskSpec=$activeTaskSpec; taskSpecHash=$activeTaskSpecHash; attemptFailures=@(); deliveryReconciliation=$null; authorizationResumedAt=$null
    enqueuedAt='2026-08-02T00:00:00Z'; startedAt=$null; phase='queued'; resultState=$null; evidenceHash=$null; finishedAt=$null; cancelRequestedAt=$null; writeLease=$null
  }
  $activeQueue = [pscustomobject][ordered]@{ projectRoot=$activeProjectRoot; active=$null; pending=@($pendingDispatch); lastTerminal=$null }
  $activeManifestBytes = [byte[]](Write-TestManifest -Root $activeUpgradeRoot -ControllerBinding $activeBinding -ProjectBindings @($activeProject) -DispatchQueues @($activeQueue) -Version 2)
  $activeUpgrade = Invoke-Subject -Action Plan -ControllerRoot $activeUpgradeRoot -AllowUpgrade $true
  Assert-Result $activeUpgrade.Result 'Plan' @('conflict') $activeUpgrade.ExitCode
  Assert-ReasonCode $activeUpgrade.Result 'controller-upgrade-active-work' 'Pinned runtime upgrade must wait for an empty dispatch queue'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $activeUpgradeRoot '.codex-controller.json')), $activeManifestBytes)) 'Blocked runtime upgrade must preserve the exact active manifest'

  $intentUpgradeRoot = Join-Path $testRoot 'legacy-v2-intent-controller'
  Invoke-Subject -Action Apply -ControllerRoot $intentUpgradeRoot | Out-Null
  Convert-ToLegacyLayout -Root $intentUpgradeRoot
  $upgradeIntent = [pscustomobject][ordered]@{
    operationId='legacy-v2-intent'; codexProjectId='legacy-v2-intent-project'; hostId='legacy-v2-host'; projectRoot=$intentUpgradeRoot
    startedAt='2026-08-02T00:00:00Z'; clientThreadId=$null
  }
  $intentUpgradeBytes = [byte[]](Write-TestManifest -Root $intentUpgradeRoot -ControllerTaskIntent $upgradeIntent -Version 2)
  $intentUpgrade = Invoke-Subject -Action Plan -ControllerRoot $intentUpgradeRoot -AllowUpgrade $true
  Assert-Result $intentUpgrade.Result 'Plan' @('conflict') $intentUpgrade.ExitCode
  Assert-ReasonCode $intentUpgrade.Result 'controller-upgrade-active-work' 'Upgrade must block while controller task creation intent exists'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $intentUpgradeRoot '.codex-controller.json')), $intentUpgradeBytes)) 'Blocked intent upgrade must preserve exact manifest bytes'

  $unreleasedRoot = Join-Path $testRoot 'legacy-v2-unreleased-terminal-lease-controller'
  Invoke-Subject -Action Apply -ControllerRoot $unreleasedRoot | Out-Null
  Convert-ToLegacyLayout -Root $unreleasedRoot
  $unreleasedBinding = [pscustomobject][ordered]@{ threadId='unreleased-controller'; codexProjectId='unreleased-controller-project'; hostId='unreleased-host'; projectRoot=$unreleasedRoot }
  $unreleasedTerminal = [pscustomobject][ordered]@{
    chainId='CHAIN-unreleased'; projectTaskId='active-entry'; dispatchId='dispatch-unreleased'; generation=1; rework=0; accessMode='write'; modelClass='economy'
    taskSpec=$activeTaskSpec; taskSpecHash=$activeTaskSpecHash; attemptFailures=@(); deliveryReconciliation=$null; authorizationResumedAt=$null
    enqueuedAt='2026-08-02T00:00:00Z'; startedAt='2026-08-02T00:01:00Z'; phase='terminal'; resultState='completed'; evidenceHash=('b' * 64); finishedAt='2026-08-02T00:02:00Z'; cancelRequestedAt=$null
    writeLease=[pscustomobject][ordered]@{ leaseId='lease-unreleased'; acquiredAt='2026-08-02T00:01:00Z'; releasedAt=$null }
  }
  $unreleasedQueue = [pscustomobject][ordered]@{ projectRoot=$activeProjectRoot; active=$unreleasedTerminal; pending=@(); lastTerminal=$null }
  $unreleasedBytes = [byte[]](Write-TestManifest -Root $unreleasedRoot -ControllerBinding $unreleasedBinding -ProjectBindings @($activeProject) -DispatchQueues @($unreleasedQueue) -Version 2)
  $unreleasedUpgrade = Invoke-Subject -Action Plan -ControllerRoot $unreleasedRoot -AllowUpgrade $true
  Assert-Result $unreleasedUpgrade.Result 'Plan' @('conflict') $unreleasedUpgrade.ExitCode
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $unreleasedRoot '.codex-controller.json')), $unreleasedBytes)) 'Upgrade must preserve a manifest with an unreleased terminal write lease for manual recovery'

  $upgradeOrphanRoot = Join-Path $testRoot 'legacy-v1-orphan-controller'
  Invoke-Subject -Action Apply -ControllerRoot $upgradeOrphanRoot | Out-Null
  Convert-ToLegacyLayout -Root $upgradeOrphanRoot
  $upgradeOrphanBytes = [byte[]](Write-TestManifest -Root $upgradeOrphanRoot -Version 1)
  $upgradeOrphan = Join-Path $upgradeOrphanRoot ('.codex-controller.' + [guid]::NewGuid().ToString('N').ToLowerInvariant() + '.tmp')
  [IO.File]::WriteAllBytes($upgradeOrphan, [byte[]](1,2,3))
  $upgradeOrphanPlan = Invoke-Subject -Action Plan -ControllerRoot $upgradeOrphanRoot -AllowUpgrade $true
  Assert-Result $upgradeOrphanPlan.Result 'Plan' @('conflict') $upgradeOrphanPlan.ExitCode
  Assert-ReasonCode $upgradeOrphanPlan.Result 'controller-candidate-orphaned' 'Upgrade must block on an orphan manifest candidate'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $upgradeOrphanRoot '.codex-controller.json')), $upgradeOrphanBytes) -and (Test-Path -LiteralPath $upgradeOrphan -PathType Leaf)) 'Blocked orphan upgrade must preserve both manifest and candidate bytes'

  $resetUpgradeRoot = Join-Path $testRoot 'v3-reset-in-progress-controller'
  Invoke-Subject -Action Apply -ControllerRoot $resetUpgradeRoot | Out-Null
  $resetBinding = [pscustomobject][ordered]@{ threadId='reset-controller'; codexProjectId='reset-controller-project'; hostId='reset-host'; projectRoot=$resetUpgradeRoot }
  $taskSetReset = New-TestPreparedTaskSetReset -Root $resetUpgradeRoot -ControllerBinding $resetBinding -OperationId 'reset-operation' -CreationOperationId 'create-reset-controller'
  $resetManifestBytes = [byte[]](Write-TestManifest -Root $resetUpgradeRoot -ControllerBinding $resetBinding -TaskSetReset $taskSetReset)
  $resetUpgrade = Invoke-Subject -Action Plan -ControllerRoot $resetUpgradeRoot -AllowUpgrade $true
  Assert-Result $resetUpgrade.Result 'Plan' @('conflict') $resetUpgrade.ExitCode
  Assert-ReasonCode $resetUpgrade.Result 'controller-upgrade-active-work' 'Initializer writes must block while a task-set reset exists'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $resetUpgradeRoot '.codex-controller.json')), $resetManifestBytes)) 'Blocked reset upgrade must preserve exact manifest bytes'

  $legacyTamperedRoot = Join-Path $testRoot 'legacy-v1-tampered-controller'
  $legacyTamperedApply = Invoke-Subject -Action Apply -ControllerRoot $legacyTamperedRoot
  Assert-Result $legacyTamperedApply.Result 'Apply' @('applied') $legacyTamperedApply.ExitCode
  Convert-ToLegacyLayout -Root $legacyTamperedRoot
  Write-TestManifest -Root $legacyTamperedRoot -Version 1 | Out-Null
  $legacyTamperedPath = Join-Path $legacyTamperedRoot 'AGENTS.md'
  $legacyTamperedBytes = [Text.Encoding]::UTF8.GetBytes("unrecognized legacy policy`n")
  [IO.File]::WriteAllBytes($legacyTamperedPath, $legacyTamperedBytes)
  $legacyTamperedUpgrade = Invoke-Subject -Action Apply -ControllerRoot $legacyTamperedRoot -AllowUpgrade $true
  Assert-Result $legacyTamperedUpgrade.Result 'Apply' @('conflict') $legacyTamperedUpgrade.ExitCode
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($legacyTamperedPath), $legacyTamperedBytes)) 'Upgrade must preserve an unrecognized legacy managed file'

  $legacyRollbackRoot = Join-Path $testRoot 'legacy-v1-rollback-controller'
  $legacyRollbackApply = Invoke-Subject -Action Apply -ControllerRoot $legacyRollbackRoot
  Assert-Result $legacyRollbackApply.Result 'Apply' @('applied') $legacyRollbackApply.ExitCode
  Convert-ToLegacyLayout -Root $legacyRollbackRoot
  Write-TestManifest -Root $legacyRollbackRoot -Version 1 | Out-Null
  $rollbackPaths = @('.codex-controller.json','.gitignore','AGENTS.md','tools\control-state.ps1')
  $rollbackBefore = @{}
  foreach ($relativePath in $rollbackPaths) { $rollbackBefore[$relativePath] = [IO.File]::ReadAllBytes((Join-Path $legacyRollbackRoot $relativePath)) }
  $rollbackLock = New-Object IO.FileStream((Join-Path $legacyRollbackRoot 'AGENTS.md'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  try {
    $legacyRollbackUpgrade = Invoke-Subject -Action Apply -ControllerRoot $legacyRollbackRoot -AllowUpgrade $true
    Assert-Result $legacyRollbackUpgrade.Result 'Apply' @('blocked') $legacyRollbackUpgrade.ExitCode
  }
  finally { $rollbackLock.Dispose() }
  foreach ($relativePath in $rollbackPaths) {
    Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $legacyRollbackRoot $relativePath)), [byte[]]$rollbackBefore[$relativePath])) "A failed upgrade must roll back $relativePath"
  }
  foreach ($relativePath in @('.chain-store.json', 'TASKS.md', 'tools\chain-store.ps1', 'tools\dispatch-return-runtime.mjs', 'memory', 'state')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyRollbackRoot $relativePath))) "A failed upgrade must remove newly created $relativePath"
  }

  $intentRoot = Join-Path $testRoot 'intent-controller'
  $intentApply = Invoke-Subject -Action Apply -ControllerRoot $intentRoot
  Assert-Result $intentApply.Result 'Apply' @('applied') $intentApply.ExitCode
  foreach ($validStartedAt in @('2026-08-02T00:00:00.000Z', '2026-08-02T00:00:00+00:00')) {
    $controllerIntent.projectRoot = $intentRoot
    $controllerIntent.startedAt = $validStartedAt
    Write-TestManifest -Root $intentRoot -ControllerTaskIntent $controllerIntent | Out-Null
    $intentVerify = Invoke-Subject -Action Verify -ControllerRoot $intentRoot -ControllerName $null
    Assert-Result $intentVerify.Result 'Verify' @('verified') $intentVerify.ExitCode
    Assert-True ($intentVerify.ExitCode -eq 0) "Read and Verify must accept intent-only UTC startedAt $validStartedAt"
  }

  $bothRoot = Join-Path $testRoot 'both-controller-state'
  $bothApply = Invoke-Subject -Action Apply -ControllerRoot $bothRoot
  Assert-Result $bothApply.Result 'Apply' @('applied') $bothApply.ExitCode
  $controllerBinding.projectRoot = $bothRoot
  $controllerIntent.projectRoot = $bothRoot
  Write-TestManifest -Root $bothRoot -ControllerBinding $controllerBinding -ControllerTaskIntent $controllerIntent | Out-Null
  $bothVerify = Invoke-Subject -Action Verify -ControllerRoot $bothRoot -ControllerName $null
  Assert-Result $bothVerify.Result 'Verify' @('conflict') $bothVerify.ExitCode
  Assert-ReasonCode $bothVerify.Result 'controller-filesystem-conflict' 'controllerBinding and controllerTaskIntent must be mutually exclusive'

  $invalidStartedAtRoot = Join-Path $testRoot 'invalid-started-at-controller'
  $invalidStartedAtApply = Invoke-Subject -Action Apply -ControllerRoot $invalidStartedAtRoot
  Assert-Result $invalidStartedAtApply.Result 'Apply' @('applied') $invalidStartedAtApply.ExitCode
  foreach ($invalidStartedAt in @('not-an-iso-date', '2026-08-02T08:00:00+08:00')) {
    $controllerIntent.projectRoot = $invalidStartedAtRoot
    $controllerIntent.startedAt = $invalidStartedAt
    Write-TestManifest -Root $invalidStartedAtRoot -ControllerTaskIntent $controllerIntent | Out-Null
    $invalidStartedAtVerify = Invoke-Subject -Action Verify -ControllerRoot $invalidStartedAtRoot -ControllerName $null
    Assert-Result $invalidStartedAtVerify.Result 'Verify' @('conflict') $invalidStartedAtVerify.ExitCode
    Assert-ReasonCode $invalidStartedAtVerify.Result 'controller-filesystem-conflict' "startedAt $invalidStartedAt must be rejected"
  }

  $invalidBindingRoot = Join-Path $testRoot 'invalid-binding-controller'
  $invalidBindingApply = Invoke-Subject -Action Apply -ControllerRoot $invalidBindingRoot
  Assert-Result $invalidBindingApply.Result 'Apply' @('applied') $invalidBindingApply.ExitCode
  Write-TestManifest -Root $invalidBindingRoot -ControllerBinding ([pscustomobject]@{}) | Out-Null
  $invalidBindingVerify = Invoke-Subject -Action Verify -ControllerRoot $invalidBindingRoot -ControllerName $null
  Assert-Result $invalidBindingVerify.Result 'Verify' @('conflict') $invalidBindingVerify.ExitCode
  Assert-ReasonCode $invalidBindingVerify.Result 'controller-filesystem-conflict' 'An empty controllerBinding object must fail closed-manifest validation'

  $implicitOverlapRoot = Join-Path $testRoot 'implicit-overlap-controller'
  $implicitOverlapApply = Invoke-Subject -Action Apply -ControllerRoot $implicitOverlapRoot
  Assert-Result $implicitOverlapApply.Result 'Apply' @('applied') $implicitOverlapApply.ExitCode
  $overlappingBinding = [pscustomobject][ordered]@{
    entryThreadId = 'entry-thread-overlap'
    codexProjectId = 'business-project-overlap'
    hostId = 'host-A'
    projectRoot = (Join-Path $implicitOverlapRoot 'business')
  }
  $implicitManifestBytes = [byte[]](Write-TestManifest -Root $implicitOverlapRoot -ProjectBindings @($overlappingBinding))
  foreach ($implicitAction in @('Plan', 'Apply')) {
    $implicitOverlap = Invoke-Subject -Action $implicitAction -ControllerRoot $implicitOverlapRoot
    Assert-Result $implicitOverlap.Result $implicitAction @('conflict') $implicitOverlap.ExitCode
    Assert-ReasonCode $implicitOverlap.Result 'controller-filesystem-conflict' "$implicitAction must reject a manifest whose project root overlaps the controller"
    Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $implicitOverlapRoot '.codex-controller.json')), $implicitManifestBytes)) "$implicitAction must not change an overlapping controller"
  }

  $defaultRoot = Join-Path $testRoot 'default-controller'
  $defaultApply = Invoke-Subject -Action Apply -ControllerRoot $defaultRoot -ControllerName $null
  Assert-Result $defaultApply.Result 'Apply' @('applied') $defaultApply.ExitCode
  $defaultManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $defaultRoot '.codex-controller.json') | ConvertFrom-Json
  Assert-True ($defaultManifest.controllerName -ceq 'Multi-Project Control Center') 'Omitted ControllerName must use the public default'

  $trailingRoot = Join-Path $testRoot 'trailing-separator-controller'
  $trailingInput = $trailingRoot + '\'
  foreach ($trailingAction in @('Plan', 'Apply', 'Verify')) {
    $trailing = Invoke-Subject -Action $trailingAction -ControllerRoot $trailingInput
    $expectedStatus = if ($trailingAction -ceq 'Plan') { 'planned' } elseif ($trailingAction -ceq 'Apply') { 'applied' } else { 'verified' }
    Assert-Result $trailing.Result $trailingAction @($expectedStatus) $trailing.ExitCode
    Assert-True ($trailing.ExitCode -eq 0 -and $trailing.Result.controllerRoot -ceq $trailingRoot) "$trailingAction must accept one trailing separator and report the normalized root"
  }

  $gitRoot = Join-Path $testRoot 'git-controller'
  New-Item -ItemType Directory -Path (Join-Path $gitRoot '.git') -Force | Out-Null
  $gitApply = Invoke-Subject -Action Apply -ControllerRoot $gitRoot
  Assert-Result $gitApply.Result 'Apply' @('applied') $gitApply.ExitCode
  Assert-True ($gitApply.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $gitRoot '.git') -PathType Container)) 'An otherwise empty root may retain an untouched .git directory'

  $businessRoot = Join-Path $testRoot 'business-project'
  New-Item -ItemType Directory -Path $businessRoot | Out-Null
  $overlapRoot = Join-Path $businessRoot 'controller'
  foreach ($overlapAction in @('Plan', 'Apply')) {
    $overlap = Invoke-Subject -Action $overlapAction -ControllerRoot $overlapRoot -BusinessProjectRoots @($businessRoot)
    Assert-Result $overlap.Result $overlapAction @('conflict') $overlap.ExitCode
    Assert-True ($overlap.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $overlapRoot)) "$overlapAction must reject controller/business root overlap without writing"
    Assert-ReasonCode $overlap.Result 'controller-root-overlap' "$overlapAction must report controller-root-overlap"
  }

  $aliasTarget = Join-Path $testRoot 'business-alias-target'
  $aliasRoot = Join-Path $testRoot 'business-alias'
  New-Item -ItemType Directory -Path $aliasTarget | Out-Null
  $aliasCreated = $false
  try {
    New-Item -ItemType Junction -Path $aliasRoot -Target $aliasTarget | Out-Null
    $aliasCreated = $true
  }
  catch {
    if ($isWindows -and $fileSystem -ceq 'NTFS') { throw "Business-root junction creation must succeed on Windows/NTFS: $($_.Exception.Message)" }
    Write-Warning "SKIP business-root alias overlap test on $fileSystem filesystem: $($_.Exception.Message)"
  }
  if ($aliasCreated) {
    $aliasOverlapRoot = Join-Path $aliasTarget 'controller'
    foreach ($aliasAction in @('Plan', 'Apply')) {
      $aliasOverlap = Invoke-Subject -Action $aliasAction -ControllerRoot $aliasOverlapRoot -BusinessProjectRoots @($aliasRoot)
      Assert-Result $aliasOverlap.Result $aliasAction @('conflict') $aliasOverlap.ExitCode
      Assert-ReasonCode $aliasOverlap.Result 'controller-root-overlap' "$aliasAction must compare the business root's final physical path"
      Assert-True (-not (Test-Path -LiteralPath $aliasOverlapRoot)) "$aliasAction must not write through a junction-alias overlap"
    }
  }

  $partialRoot = Join-Path $testRoot 'partial-controller'
  New-Item -ItemType Directory -Path $partialRoot | Out-Null
  $partialFile = Join-Path $partialRoot '.gitignore'
  $partialBytes = [IO.File]::ReadAllBytes((Join-Path $templateRoot '.gitignore'))
  [IO.File]::WriteAllBytes($partialFile, $partialBytes)
  $partialApply = Invoke-Subject -Action Apply -ControllerRoot $partialRoot
  Assert-Result $partialApply.Result 'Apply' @('applied') $partialApply.ExitCode
  Assert-True ($partialApply.ExitCode -eq 0) 'A recognized partial scaffold must be completed'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($partialFile), $partialBytes)) 'A matching pre-existing managed file must remain byte-identical'
  foreach ($relativePath in $managedPaths) {
    Assert-True (Test-Path -LiteralPath (Join-Path $partialRoot $relativePath) -PathType Leaf) "Partial Apply must complete $relativePath"
  }

  $orphanRoot = Join-Path $testRoot 'orphan-controller'
  New-Item -ItemType Directory -Path $orphanRoot | Out-Null
  $orphan = Join-Path $orphanRoot ('.codex-controller.' + [guid]::NewGuid().ToString('N').ToLowerInvariant() + '.tmp')
  $orphanBytes = [byte[]](111, 114, 112, 104, 97, 110)
  [IO.File]::WriteAllBytes($orphan, $orphanBytes)
  $orphanName = Split-Path -Leaf $orphan
  foreach ($orphanAction in @('Plan', 'Apply')) {
    $orphanResult = Invoke-Subject -Action $orphanAction -ControllerRoot $orphanRoot
    Assert-Result $orphanResult.Result $orphanAction @('conflict') $orphanResult.ExitCode
    Assert-True ($orphanResult.ExitCode -eq 1) "$orphanAction must reject an orphan controller candidate"
    Assert-ReasonCode $orphanResult.Result 'controller-candidate-orphaned' "$orphanAction must report an orphan controller candidate"
    Assert-True ([string]$orphanResult.Result.nextAction -cmatch [regex]::Escape($orphanName)) "$orphanAction recovery must name the exact orphan candidate"
    Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($orphan), $orphanBytes)) "$orphanAction must preserve orphan candidate bytes"
  }

  $orphanDirectoryRoot = Join-Path $testRoot 'orphan-directory-controller'
  New-Item -ItemType Directory -Path $orphanDirectoryRoot | Out-Null
  $orphanDirectory = Join-Path $orphanDirectoryRoot ('.codex-controller.' + [guid]::NewGuid().ToString('N').ToLowerInvariant() + '.tmp')
  New-Item -ItemType Directory -Path $orphanDirectory | Out-Null
  $orphanDirectoryResult = Invoke-Subject -Action Plan -ControllerRoot $orphanDirectoryRoot
  Assert-Result $orphanDirectoryResult.Result 'Plan' @('conflict') $orphanDirectoryResult.ExitCode
  Assert-ReasonCode $orphanDirectoryResult.Result 'controller-filesystem-conflict' 'A matching orphan directory must be rejected before hashing'
  Assert-True (Test-Path -LiteralPath $orphanDirectory -PathType Container) 'An orphan directory must be preserved'

  $editableRoot = Join-Path $testRoot 'editable-controller'
  $editableApply = Invoke-Subject -Action Apply -ControllerRoot $editableRoot
  Assert-Result $editableApply.Result 'Apply' @('applied') $editableApply.ExitCode
  $editableDoc = Join-Path $editableRoot 'docs\cross-project-contracts.md'
  $editableBytes = [Text.Encoding]::UTF8.GetBytes("# __API_VERSION__`n")
  [IO.File]::WriteAllBytes($editableDoc, $editableBytes)
  $editableRerun = Invoke-Subject -Action Apply -ControllerRoot $editableRoot
  Assert-Result $editableRerun.Result 'Apply' @('applied') $editableRerun.ExitCode
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($editableDoc), $editableBytes)) 'Human-edited cross-project contracts must be preserved by Apply'
  $editableVerify = Invoke-Subject -Action Verify -ControllerRoot $editableRoot
  Assert-Result $editableVerify.Result 'Verify' @('verified') $editableVerify.ExitCode
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($editableDoc), $editableBytes)) 'Human-edited cross-project contracts must be preserved by Verify'

  $brokenTemplateRoot = Join-Path $testRoot 'broken-template-controller'
  $brokenSkillRoot = Join-Path $testRoot 'broken-skill'
  $brokenSubject = Join-Path $brokenSkillRoot 'scripts\init-controller.ps1'
  [IO.Directory]::CreateDirectory((Split-Path -Parent $brokenSubject)) | Out-Null
  [IO.File]::WriteAllBytes($brokenSubject, [IO.File]::ReadAllBytes($subject))
  [IO.File]::WriteAllBytes((Join-Path $brokenSkillRoot 'scripts\dispatch-return-runtime.mjs'), [IO.File]::ReadAllBytes($runtimeSource))
  foreach ($relativePath in $templatePaths) {
    $sourceTemplate = Join-Path $templateRoot $relativePath
    $copiedTemplate = Join-Path (Join-Path $brokenSkillRoot 'templates\controller') $relativePath
    [IO.Directory]::CreateDirectory((Split-Path -Parent $copiedTemplate)) | Out-Null
    [IO.File]::WriteAllBytes($copiedTemplate, [IO.File]::ReadAllBytes($sourceTemplate))
  }
  [IO.File]::WriteAllBytes((Join-Path $brokenSkillRoot 'templates\controller\AGENTS.md'), [Text.Encoding]::UTF8.GetBytes("__BROKEN_TEMPLATE__`n"))
  $brokenTemplatePlan = Invoke-Subject -Action Plan -ControllerRoot $brokenTemplateRoot -SubjectPath $brokenSubject
  Assert-Result $brokenTemplatePlan.Result 'Plan' @('conflict', 'blocked') $brokenTemplatePlan.ExitCode
  Assert-True ($brokenTemplatePlan.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $brokenTemplateRoot)) 'Plan must validate every canonical template before writing'
  Assert-ReasonCode $brokenTemplatePlan.Result 'controller-filesystem-conflict' 'A damaged canonical template must report a stable conflict'
  [IO.File]::WriteAllBytes((Join-Path $brokenSkillRoot 'templates\controller\AGENTS.md'), [IO.File]::ReadAllBytes((Join-Path $templateRoot 'AGENTS.md')))
  [IO.File]::WriteAllBytes((Join-Path $brokenSkillRoot 'templates\controller\.codex-controller.json'), [Text.Encoding]::UTF8.GetBytes('{"controllerName":__CONTROLLER_NAME_JSON__}' + "`n"))
  $brokenManifestRoot = Join-Path $testRoot 'broken-manifest-template-controller'
  $brokenManifestPlan = Invoke-Subject -Action Plan -ControllerRoot $brokenManifestRoot -SubjectPath $brokenSubject
  Assert-Result $brokenManifestPlan.Result 'Plan' @('conflict') $brokenManifestPlan.ExitCode
  Assert-ReasonCode $brokenManifestPlan.Result 'controller-filesystem-conflict' 'A structurally invalid manifest template must fail adapter prevalidation'
  Assert-True (-not (Test-Path -LiteralPath $brokenManifestRoot)) 'Manifest template prevalidation failure must remain write-free'
  $canonicalManifestTemplate = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $templateRoot '.codex-controller.json')))
  $duplicateTaskSetTemplate = $canonicalManifestTemplate.Replace('__TASK_SET_ID_JSON__', '__TASK_SET_ID_JSON____TASK_SET_ID_JSON__')
  [IO.File]::WriteAllBytes((Join-Path $brokenSkillRoot 'templates\controller\.codex-controller.json'), [Text.Encoding]::UTF8.GetBytes($duplicateTaskSetTemplate))
  $duplicatePlaceholderRoot = Join-Path $testRoot 'duplicate-task-set-placeholder-controller'
  $duplicatePlaceholderPlan = Invoke-Subject -Action Plan -ControllerRoot $duplicatePlaceholderRoot -SubjectPath $brokenSubject
  Assert-Result $duplicatePlaceholderPlan.Result 'Plan' @('conflict') $duplicatePlaceholderPlan.ExitCode
  Assert-ReasonCode $duplicatePlaceholderPlan.Result 'controller-filesystem-conflict' 'Manifest rendering must require exactly one task-set placeholder'
  Assert-True (-not (Test-Path -LiteralPath $duplicatePlaceholderRoot)) 'Duplicate task-set placeholder rejection must remain write-free'
  $brokenInvalidRoot = Invoke-Subject -Action Plan -ControllerRoot '.\relative-controller' -SubjectPath $brokenSubject
  Assert-Result $brokenInvalidRoot.Result 'Plan' @('invalid') $brokenInvalidRoot.ExitCode
  Assert-ReasonCode $brokenInvalidRoot.Result 'controller-root-unsupported' 'Invalid root validation must precede damaged template validation'
  $brokenReparseTarget = Join-Path $testRoot 'broken-template-reparse-target'
  $brokenReparseRoot = Join-Path $testRoot 'broken-template-reparse-root'
  New-Item -ItemType Directory -Path $brokenReparseTarget | Out-Null
  $brokenReparseCreated = $false
  try {
    New-Item -ItemType Junction -Path $brokenReparseRoot -Target $brokenReparseTarget | Out-Null
    $brokenReparseCreated = $true
  }
  catch {
    if ($isWindows -and $fileSystem -ceq 'NTFS') { throw "Broken-template junction creation must succeed on Windows/NTFS: $($_.Exception.Message)" }
    Write-Warning "SKIP broken-template reparse priority test on $fileSystem filesystem: $($_.Exception.Message)"
  }
  if ($brokenReparseCreated) {
    $brokenReparse = Invoke-Subject -Action Plan -ControllerRoot $brokenReparseRoot -SubjectPath $brokenSubject
    Assert-Result $brokenReparse.Result 'Plan' @('conflict') $brokenReparse.ExitCode
    Assert-ReasonCode $brokenReparse.Result 'controller-filesystem-conflict' 'Reparse root validation must precede damaged template validation'
    Assert-True ($brokenReparse.Result.controllerRoot -ceq [IO.Path]::GetFullPath($brokenReparseRoot).TrimEnd('\')) 'Reparse conflict must report the normalized controller root'
    Assert-True (@(Get-ChildItem -Force -LiteralPath $brokenReparseTarget).Count -eq 0) 'Reparse priority validation must remain write-free'
  }

  $managedBytes = [byte[]](1, 2, 3, 4)
  $managedFile = Join-Path $controllerRoot 'AGENTS.md'
  [IO.File]::WriteAllBytes($managedFile, $managedBytes)
  $managedConflict = Invoke-Subject -Action Apply -ControllerRoot $controllerRoot
  Assert-Result $managedConflict.Result 'Apply' @('conflict') $managedConflict.ExitCode
  Assert-True ($managedConflict.ExitCode -eq 1) 'Differing managed files must produce conflict exit 1'
  Assert-ReasonCode $managedConflict.Result 'controller-filesystem-conflict' 'Differing managed files must report the filesystem conflict code'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($managedFile), $managedBytes)) 'Differing managed files must never be overwritten'

  $sentinelRoot = Join-Path $testRoot 'sentinel-controller'
  $freshSentinel = Invoke-Subject -Action Apply -ControllerRoot $sentinelRoot
  Assert-Result $freshSentinel.Result 'Apply' @('applied') $freshSentinel.ExitCode
  $sentinel = Join-Path $sentinelRoot 'external-sentinel-must-survive.txt'
  $sentinelBytes = [byte[]](99, 111, 100, 101, 120)
  [IO.File]::WriteAllBytes($sentinel, $sentinelBytes)
  $sentinelConflict = Invoke-Subject -Action Apply -ControllerRoot $sentinelRoot
  Assert-Result $sentinelConflict.Result 'Apply' @('conflict') $sentinelConflict.ExitCode
  Assert-True ($sentinelConflict.ExitCode -eq 1) 'Unknown inventory must produce conflict exit 1'
  Assert-ReasonCode $sentinelConflict.Result 'controller-filesystem-conflict' 'Unknown inventory must report the filesystem conflict code'
  Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($sentinel), $sentinelBytes)) 'External sentinel bytes must be preserved'

  foreach ($invalidRoot in @('.\relative', 'C:drive-relative', '\\server\share\controller', '\\.\PhysicalDrive0', 'C:\controller:stream', $driveRoot)) {
    $invalid = Invoke-Subject -Action Plan -ControllerRoot $invalidRoot
    Assert-Result $invalid.Result 'Plan' @('invalid') $invalid.ExitCode
    Assert-True ($invalid.ExitCode -eq 2) "Unsafe root $invalidRoot must exit 2"
    Assert-ReasonCode $invalid.Result 'controller-root-unsupported' "Unsafe root $invalidRoot must report the unsupported-root code"
  }
  $lossyAncestor = Join-Path $testRoot 'lossy-ancestor'
  New-Item -ItemType Directory -Path $lossyAncestor | Out-Null
  $lossyCases = @(
    [pscustomobject]@{ Input=(Join-Path $testRoot 'lossy-final-dot.'); Alias=(Join-Path $testRoot 'lossy-final-dot') },
    [pscustomobject]@{ Input=((Join-Path $testRoot 'lossy-final-space') + ' '); Alias=(Join-Path $testRoot 'lossy-final-space') },
    [pscustomobject]@{ Input=((Join-Path $testRoot 'lossy-ancestor') + '.\controller'); Alias=(Join-Path $lossyAncestor 'controller') },
    [pscustomobject]@{ Input=(Join-Path $testRoot 'lossy-segment\..\lossy-dotdot-controller'); Alias=(Join-Path $testRoot 'lossy-dotdot-controller') },
    [pscustomobject]@{ Input=(Join-Path $testRoot 'CON\controller'); Alias=(Join-Path $testRoot 'CON\controller') }
  )
  foreach ($lossyCase in $lossyCases) {
    foreach ($lossyAction in @('Plan', 'Apply')) {
      $lossy = Invoke-Subject -Action $lossyAction -ControllerRoot $lossyCase.Input
      Assert-Result $lossy.Result $lossyAction @('invalid') $lossy.ExitCode
      Assert-True ($lossy.ExitCode -eq 2 -and $null -eq $lossy.Result.controllerRoot) "$lossyAction must reject a lossy Windows path without claiming a normalized target: $($lossyCase.Input)"
      Assert-ReasonCode $lossy.Result 'controller-root-unsupported' "$lossyAction must report unsupported lossy Windows path"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $lossyCase.Alias '.codex-controller.json'))) "$lossyAction must not write through lossy alias $($lossyCase.Alias)"
    }
  }
  $missingParentRoot = Join-Path (Join-Path $testRoot 'missing-parent') 'controller'
  $blocked = Invoke-Subject -Action Plan -ControllerRoot $missingParentRoot
  Assert-Result $blocked.Result 'Plan' @('blocked') $blocked.ExitCode
  Assert-True ($blocked.ExitCode -eq 1) 'A missing controller parent must produce blocked exit 1'
  Assert-ReasonCode $blocked.Result 'controller-root-unsupported' 'A missing controller parent must report the unsupported-root code'
  $invalidAction = Invoke-Subject -Action 'Nope' -ControllerRoot (Join-Path $testRoot 'invalid-action')
  Assert-Result $invalidAction.Result 'Nope' @('invalid') $invalidAction.ExitCode
  Assert-True ($invalidAction.ExitCode -eq 2) 'Invalid Action must exit 2'
  Assert-ReasonCode $invalidAction.Result 'invalid-controller-input' 'Invalid Action must report invalid-controller-input'

  foreach ($invalidName in @(([string][char]0x00A0), 'bad/name', "bad`nname", ('a' * 81))) {
    $invalidNameResult = Invoke-Subject -Action Plan -ControllerRoot (Join-Path $testRoot ('invalid-name-' + [guid]::NewGuid().ToString('N'))) -ControllerName $invalidName
    Assert-Result $invalidNameResult.Result 'Plan' @('invalid') $invalidNameResult.ExitCode
    Assert-True ($invalidNameResult.ExitCode -eq 2) "Invalid ControllerName [$($invalidName.Replace("`n", '<NL>'))] must exit 2; got $($invalidNameResult.ExitCode)"
    Assert-ReasonCode $invalidNameResult.Result 'invalid-controller-input' 'Invalid ControllerName must report invalid-controller-input'
  }

  $junctionTarget = Join-Path $testRoot 'junction-target-controller'
  $junctionTargetApply = Invoke-Subject -Action Apply -ControllerRoot $junctionTarget
  Assert-Result $junctionTargetApply.Result 'Apply' @('applied') $junctionTargetApply.ExitCode
  Assert-True ($junctionTargetApply.ExitCode -eq 0) 'Junction target must begin as a complete intact scaffold'
  $junction = Join-Path $testRoot 'controller-junction'
  $junctionCreated = $false
  try {
    New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
    $junctionCreated = $true
  }
  catch {
    if ($isWindows -and $fileSystem -ceq 'NTFS') {
      throw "Junction creation must succeed on Windows/NTFS: $($_.Exception.Message)"
    }
    Write-Warning "SKIP reparse safety test on $fileSystem filesystem: $($_.Exception.Message)"
  }
  if ($junctionCreated) {
    $reparse = Invoke-Subject -Action Plan -ControllerRoot $junction
    Assert-Result $reparse.Result 'Plan' @('conflict') $reparse.ExitCode
    Assert-True ($reparse.ExitCode -eq 1) 'Existing-component reparse controller root must exit 1'
    Assert-ReasonCode $reparse.Result 'controller-filesystem-conflict' 'Existing-component reparse root must report the filesystem conflict code'
  }

  $ancestorTarget = Join-Path $testRoot 'ancestor-junction-target'
  New-Item -ItemType Directory -Path $ancestorTarget | Out-Null
  $ancestorLink = Join-Path $testRoot 'ancestor-junction'
  $ancestorCreated = $false
  try {
    New-Item -ItemType Junction -Path $ancestorLink -Target $ancestorTarget | Out-Null
    $ancestorCreated = $true
  }
  catch {
    if ($isWindows -and $fileSystem -ceq 'NTFS') {
      throw "Ancestor junction creation must succeed on Windows/NTFS: $($_.Exception.Message)"
    }
    Write-Warning "SKIP ancestor reparse safety test on $fileSystem filesystem: $($_.Exception.Message)"
  }
  if ($ancestorCreated) {
    $ancestorController = Join-Path $ancestorLink 'controller'
    $externalController = Join-Path $ancestorTarget 'controller'
    foreach ($ancestorAction in @('Plan', 'Apply')) {
      $ancestorResult = Invoke-Subject -Action $ancestorAction -ControllerRoot $ancestorController
      Assert-Result $ancestorResult.Result $ancestorAction @('conflict') $ancestorResult.ExitCode
      Assert-True ($ancestorResult.ExitCode -eq 1) "$ancestorAction must reject an ancestor reparse point"
      Assert-ReasonCode $ancestorResult.Result 'controller-filesystem-conflict' "$ancestorAction must report the ancestor reparse conflict code"
      Assert-True (-not (Test-Path -LiteralPath $externalController)) "$ancestorAction must not write through an ancestor reparse point"
    }
  }

  Write-Output 'PASS init-controller'
}
finally {
  if (Test-Path -LiteralPath $testRoot) {
    Assert-True ($resolvedTestRoot.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Refusing to remove a test directory outside the system temporary directory'
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}

exit 0
