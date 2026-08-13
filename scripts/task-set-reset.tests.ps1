[CmdletBinding()]
param([string]$SubjectPath = '',[switch]$KeepTestRoot)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$subject = if ([string]::IsNullOrWhiteSpace($SubjectPath)) { Join-Path $skillRoot 'templates\controller\tools\control-state.ps1' } else { [IO.Path]::GetFullPath($SubjectPath) }
$chainSubject=Join-Path (Split-Path -Parent $subject) 'chain-store.ps1'
$runtimeSubject=Join-Path $skillRoot 'scripts\dispatch-return-runtime.mjs'
if (-not (Test-Path -LiteralPath $subject -PathType Leaf)) { throw "Missing state adapter: $subject" }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$scenarioCount = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-Hash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-TreeFingerprint {
  param([string]$Root)
  $rows=@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force|Sort-Object FullName|ForEach-Object{
    $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')+[char]0+(Get-Hash ([IO.File]::ReadAllBytes($_.FullName)))
  })
  return Get-Hash $utf8.GetBytes(($rows-join([char]0)))
}

function Get-TaskSetId {
  param([string]$Root,[string]$FromTaskSetId,[string]$OperationId)
  $identity=@('task-set-reset-v1',([IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()),$FromTaskSetId,$OperationId)
  return 'task-set-' + (Get-Hash $utf8.GetBytes(($identity|ConvertTo-Json -Compress)))
}

function Get-InitialTaskSetId {
  param([string]$Root)
  return 'task-set-' + (Get-Hash $utf8.GetBytes(([IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant())))
}

function Get-EncodedStringExpression {
  param([string]$Value)
  $encoded = [Convert]::ToBase64String($utf8.GetBytes($Value))
  return "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')))"
}

function Invoke-State {
  param(
    [string]$Action, [string]$ControllerRoot, [string]$ExpectedHash = '', [string]$Operation = '',
    [AllowNull()][object]$Payload = $null, [string]$CandidatePath = '', [string]$CandidateHash = '', [bool]$ConfirmCleanup = $false
  )
  $command = '$ProgressPreference = ''SilentlyContinue''; & ' + (Get-EncodedStringExpression $subject) + ' -Action ' + (Get-EncodedStringExpression $Action) + ' -ControllerRoot ' + (Get-EncodedStringExpression $ControllerRoot)
  foreach ($pair in @(
    [pscustomobject]@{ Name='ExpectedHash'; Value=$ExpectedHash }, [pscustomobject]@{ Name='Operation'; Value=$Operation },
    [pscustomobject]@{ Name='CandidatePath'; Value=$CandidatePath }, [pscustomobject]@{ Name='CandidateHash'; Value=$CandidateHash }
  )) { if (-not [string]::IsNullOrEmpty([string]$pair.Value)) { $command += ' -' + $pair.Name + ' ' + (Get-EncodedStringExpression ([string]$pair.Value)) } }
  $payloadPath=$null
  if ($null -ne $Payload) {
    $payloadPath=Join-Path ([IO.Path]::GetTempPath()) ('tsr-payload-'+[guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($payloadPath,($Payload|ConvertTo-Json -Depth 20 -Compress),$utf8)
    $command += ' -PayloadJson ([IO.File]::ReadAllText(' + (Get-EncodedStringExpression $payloadPath) + ',(New-Object Text.UTF8Encoding($false,$true))))'
  }
  if ($ConfirmCleanup) { $command += ' -ConfirmCleanup' }
  $command += '; exit $LASTEXITCODE'
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = 'powershell.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $process = [Diagnostics.Process]::Start($start)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(20000)) { try { $process.Kill() } catch {}; throw "State adapter timed out for $Action/$Operation" }
    $document = $stdout.GetAwaiter().GetResult().Trim(); $errorText = $stderr.GetAwaiter().GetResult().Trim(); $exitCode = $process.ExitCode
  }
  finally { $process.Dispose();if($null-ne$payloadPath-and(Test-Path -LiteralPath $payloadPath)){Remove-Item -LiteralPath $payloadPath -Force} }
  Assert-True ([string]::IsNullOrWhiteSpace($errorText)) "State adapter must not emit stderr; stderr: $errorText"
  try { $result = $document | ConvertFrom-Json -ErrorAction Stop } catch { throw "State adapter must emit one JSON document; output: $document" }
  return [pscustomobject]@{ ExitCode=$exitCode; Result=$result }
}

function Assert-State {
  param($Call, [string]$Status, [int]$ExitCode, [string]$Reason)
  Assert-True ($Call.ExitCode -eq $ExitCode -and $Call.Result.status -ceq $Status -and $Call.Result.reasonCode -ceq $Reason) `
    "Expected $Status/$Reason exit $ExitCode, got $($Call.Result.status)/$($Call.Result.reasonCode) exit $($Call.ExitCode); assertion line $((Get-PSCallStack)[1].ScriptLineNumber)"
  $script:scenarioCount++
}

function Invoke-RuntimeCli {
  param([string]$Action,[string]$StatePath,[object]$Payload)
  $encoded=[Convert]::ToBase64String($utf8.GetBytes(($Payload|ConvertTo-Json -Depth 20 -Compress)))
  $raw=& node.exe $runtimeSubject $Action --state-path $StatePath --payload-base64 $encoded 2>&1
  Assert-True ($LASTEXITCODE-eq0) "Runtime CLI failed for ${Action}: $($raw-join' ')"
  return ($raw-join"`n")|ConvertFrom-Json -ErrorAction Stop
}

function Write-Manifest {
  param([string]$Root, [object]$Manifest)
  [IO.Directory]::CreateDirectory($Root) | Out-Null
  $bytes = $utf8.GetBytes(($Manifest | ConvertTo-Json -Depth 20 -Compress) + "`n")
  [IO.File]::WriteAllBytes((Join-Path $Root '.codex-controller.json'), $bytes)
  if($Manifest.schemaVersion-eq3-and-not(Test-Path -LiteralPath (Join-Path $Root '.chain-store.json'))){$null=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $chainSubject -Action Initialize -ControllerRoot $Root}
  return Get-Hash $bytes
}

function Put-ActiveChain {
  param([string]$Root,[string]$ChainId,[string]$Objective,[string]$NextAction,[string]$HistoryNote='N/A')
  $candidate=Join-Path $Root ('.chain-candidate-'+[guid]::NewGuid().ToString('N')+'.json')
  $record=[pscustomobject][ordered]@{
    schemaVersion=1;chainId=$ChainId;state='active';phase='execution';status='running'
    createdAt='2026-08-13T00:00:00Z';updatedAt='2026-08-13T00:00:01Z';objective=$Objective;nextAction=$NextAction
    payload=[pscustomobject][ordered]@{id=$ChainId;phase='execution';status='running';createdAt='2026-08-13T00:00:00Z';updatedAt='2026-08-13T00:00:01Z';goal=$Objective;nextAction=$NextAction;historyNote=$HistoryNote}
  }
  [IO.File]::WriteAllText($candidate,(($record|ConvertTo-Json -Depth 10 -Compress)+"`n"),$utf8)
  try{
    $raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $chainSubject -Action Put -ControllerRoot $Root -ChainId $ChainId -CandidatePath $candidate -ExpectedEntryHash MISSING 2>&1
    $exit=$LASTEXITCODE;$result=($raw-join"`n")|ConvertFrom-Json -ErrorAction Stop
    Assert-True ($exit-eq0-and$result.status-ceq'applied'-and$result.reasonCode-ceq'task-created') "Active CHAIN setup failed: $($raw-join' ')"
    return [string]$result.resultEntryHash
  }finally{if(Test-Path -LiteralPath $candidate){Remove-Item -LiteralPath $candidate -Force}}
}

function Prepare {
  param([string]$Root, [string]$Hash, [string]$Operation, [object]$Payload)
  return Invoke-State PrepareCandidate $Root $Hash $Operation $Payload
}

function Mutate {
  param([string]$Root, [string]$Hash, [string]$Operation, [object]$Payload)
  $prepared = Prepare $Root $Hash $Operation $Payload
  Assert-True ($prepared.ExitCode-eq0-and$prepared.Result.status-ceq'prepared'-and$prepared.Result.reasonCode-ceq'controller-candidate-prepared') "Prepare failed for ${Operation}: $($prepared.Result.status)/$($prepared.Result.reasonCode) exit $($prepared.ExitCode); caller line $((Get-PSCallStack)[1].ScriptLineNumber)"
  $script:scenarioCount++
  $applied = Invoke-State ApplyCandidate $Root $Hash '' $null $prepared.Result.candidatePath $prepared.Result.candidateHash
  Assert-True ($applied.ExitCode -eq 0 -and $applied.Result.status -ceq 'applied' -and $applied.Result.reasonCode -ceq 'controller-state-applied') "Apply failed for ${Operation}: $($applied.Result.status)/$($applied.Result.reasonCode) exit $($applied.ExitCode)"
  $script:scenarioCount++
  return $applied
}

function New-TaskSpec {
  param([string]$ProjectId, [string]$ProjectTaskId, [string]$DispatchId)
  return [pscustomobject][ordered]@{
    objective='Preserve terminal evidence'; nonGoals=@(); acceptance=@('Evidence remains readable')
    authorizedActions=@('read'); forbiddenActions=@('write')
    baseline=[pscustomobject][ordered]@{ branch='N/A'; head='N/A'; dirtyHash='N/A' }
    contract=[pscustomobject][ordered]@{ id='N/A'; version='N/A'; hash='N/A' }
    dependencies=@(); authorizationRef=('authref:' + $ProjectId + ':reset-test')
    readiness=[pscustomobject][ordered]@{ status='ready'; checkedAt='2026-08-13T00:00:00Z'; operationClass='read'; targets=@('manifest'); capabilityRefs=@(); rollback=@(); verification=@('hash') }
    returnRoute=[pscustomobject][ordered]@{ mode='foreground'; controllerThreadId='N/A'; hostId='N/A' }
    dispatchIdentity=[pscustomobject][ordered]@{ chainId='CHAIN-TERMINAL'; projectTaskId=$ProjectTaskId; dispatchId=$DispatchId; generation=1; rework=0 }
  }
}

function New-DispatchRecord {
  param([string]$ProjectId, [string]$ProjectTaskId, [string]$DispatchId, [string]$Kind)
  $taskSpec = New-TaskSpec $ProjectId $ProjectTaskId $DispatchId
  $taskSpecHash = Get-Hash $utf8.GetBytes(($taskSpec | ConvertTo-Json -Depth 12 -Compress))
  $record = [pscustomobject][ordered]@{
    chainId='CHAIN-TERMINAL'; projectTaskId=$ProjectTaskId; dispatchId=$DispatchId; generation=1; rework=0
    accessMode=if ($Kind -ceq 'active') { 'write' } else { 'read' }; modelClass='balanced'; taskSpec=$taskSpec; taskSpecHash=$taskSpecHash
    attemptFailures=@(); deliveryReconciliation=$null; authorizationResumedAt=$null; enqueuedAt='2026-08-13T00:00:01Z'
    startedAt=$null; phase='queued'; resultState=$null; evidenceHash=$null; finishedAt=$null; cancelRequestedAt=$null; writeLease=$null
  }
  if ($Kind -ceq 'terminal') {
    $record.startedAt='2026-08-13T00:00:02Z'; $record.phase='terminal'; $record.resultState='completed'
    $record.evidenceHash='a' * 64; $record.finishedAt='2026-08-13T00:00:03Z'
  }
  elseif ($Kind -ceq 'active') {
    $record.startedAt='2026-08-13T00:00:02Z'; $record.phase='running'
    $record.writeLease=[pscustomobject][ordered]@{ leaseId='lease-active'; acquiredAt='2026-08-13T00:00:02Z'; releasedAt=$null }
  }
  return $record
}

function New-Manifest {
  param([string]$ControllerRoot, [string]$ProjectARoot, [string]$ProjectBRoot, [string]$Mode = 'quiet', [int]$Version = 3)
  $controller = [pscustomobject][ordered]@{ threadId='controller-old'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$ControllerRoot }
  $projects = @(
    [pscustomobject][ordered]@{ entryThreadId='project-A-old'; codexProjectId='project-A'; hostId='host-1'; projectRoot=$ProjectARoot },
    [pscustomobject][ordered]@{ entryThreadId='project-B-old'; codexProjectId='project-B'; hostId='host-1'; projectRoot=$ProjectBRoot }
  )
  $queues = @(
    [pscustomobject][ordered]@{ projectRoot=$ProjectARoot; active=$null; pending=@(); lastTerminal=(New-DispatchRecord 'project-A' 'project-A-old' 'dispatch-terminal-A' 'terminal') },
    [pscustomobject][ordered]@{ projectRoot=$ProjectBRoot; active=$null; pending=@(); lastTerminal=$null }
  )
  $intent = $null
  if ($Mode -ceq 'busy-pending') { $queues[1].pending=@(New-DispatchRecord 'project-B' 'project-B-old' 'dispatch-pending-B' 'pending') }
  if ($Mode -ceq 'busy-lease') { $queues[1].active=New-DispatchRecord 'project-B' 'project-B-old' 'dispatch-active-B' 'active' }
  if ($Mode -ceq 'intent') { $intent=[pscustomobject][ordered]@{ operationId='controller-create'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$ControllerRoot; startedAt='2026-08-13T00:00:00Z'; clientThreadId=$null }; $controller=$null }
  $manifest = [ordered]@{
    schemaVersion=$Version; generator='onboard-code-projects'; templateVersion=$Version; controllerName='Reset Test'
    controllerBinding=$controller; controllerTaskIntent=$intent; projectBindings=@($projects)
  }
  if ($Version -ge 2) { $manifest.dispatchQueues=@($queues) }
  if ($Version -eq 3) { $manifest.taskSetId=Get-InitialTaskSetId $ControllerRoot; $manifest.taskSetReset=$null }
  return [pscustomobject]$manifest
}

function New-Handoff {
  param([string]$Summary, [string]$OldestTurnId, [string]$NewestTurnId, [int]$TurnCount,[string]$ObservedAt='2026-08-13T00:00:20Z')
  $turnRows=@();for($index=0;$index-lt$TurnCount;$index++){$turnRows+=[pscustomobject][ordered]@{
    turnId=if($index-eq0){$OldestTurnId}elseif($index-eq($TurnCount-1)){$NewestTurnId}else{"handoff-turn-$index"}
    status='completed';completedAt=('2026-08-13T00:00:{0:D2}Z'-f(10+$index))
  }}
  return [pscustomobject][ordered]@{
    summary=$Summary; summaryHash=(Get-Hash $utf8.GetBytes($Summary)); oldestTurnId=$OldestTurnId
    newestTurnId=$NewestTurnId; turnCount=$TurnCount; historyDigest=(Get-Hash $utf8.GetBytes(($turnRows|ConvertTo-Json -Depth 4 -Compress)))
    eofComplete=$true; observedAt=$ObservedAt
  }
}

function New-ExternalQuiescence {
  param([string]$ObservedAt='2026-08-13T00:00:30Z',[object]$RuntimeReadback)
  $runtimeReadbackHash=Get-Hash $utf8.GetBytes(($RuntimeReadback|ConvertTo-Json -Depth 20 -Compress))
  $proof = [pscustomobject][ordered]@{
    runtimeDispatches=0; unackedReceipts=0; claims=0; goalReservations=0; approvals=0; activeScopedTasks=0
    automationIntents=0;writers=0;candidates=0;heartbeatPaused=$true
    runtimeReadback=$RuntimeReadback;runtimeReadbackHash=$runtimeReadbackHash;observedAt=$ObservedAt
  }
  return [pscustomobject][ordered]@{
    runtimeDispatches=$proof.runtimeDispatches; unackedReceipts=$proof.unackedReceipts; claims=$proof.claims
    goalReservations=$proof.goalReservations; approvals=$proof.approvals; activeScopedTasks=$proof.activeScopedTasks; automationIntents=$proof.automationIntents
    writers=$proof.writers;candidates=$proof.candidates;heartbeatPaused=$proof.heartbeatPaused
    runtimeReadback=$proof.runtimeReadback;runtimeReadbackHash=$proof.runtimeReadbackHash;observedAt=$proof.observedAt
    proofHash=(Get-Hash $utf8.GetBytes(($proof | ConvertTo-Json -Depth 5 -Compress)))
  }
}

function Get-ExternalQuiescenceHash {
  param($Proof)
  $snapshot=[pscustomobject][ordered]@{
    runtimeDispatches=$Proof.runtimeDispatches; unackedReceipts=$Proof.unackedReceipts; claims=$Proof.claims
    goalReservations=$Proof.goalReservations; approvals=$Proof.approvals; activeScopedTasks=$Proof.activeScopedTasks; automationIntents=$Proof.automationIntents
    writers=$Proof.writers;candidates=$Proof.candidates;heartbeatPaused=$Proof.heartbeatPaused
    runtimeReadback=$Proof.runtimeReadback;runtimeReadbackHash=$Proof.runtimeReadbackHash;observedAt=$Proof.observedAt
  }
  return Get-Hash $utf8.GetBytes(($snapshot | ConvertTo-Json -Depth 5 -Compress))
}

function New-PlanPayload {
  param([string]$ControllerRoot, [string]$ProjectARoot, [string]$ProjectBRoot, [string]$ExpectedChainHash = '')
  return [pscustomobject][ordered]@{
    operationId='reset-op-1';fromTaskSetId=(Get-InitialTaskSetId $ControllerRoot);toTaskSetId=(Get-TaskSetId $ControllerRoot (Get-InitialTaskSetId $ControllerRoot) 'reset-op-1')
    coordinator=[pscustomobject][ordered]@{ threadId='coordinator-task'; hostId='host-external' }
    expectedController=[pscustomobject][ordered]@{ threadId='controller-old'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$ControllerRoot }
    expectedProjectBindings=@(
      [pscustomobject][ordered]@{ entryThreadId='project-A-old'; codexProjectId='project-A'; hostId='host-1'; projectRoot=$ProjectARoot },
      [pscustomobject][ordered]@{ entryThreadId='project-B-old'; codexProjectId='project-B'; hostId='host-1'; projectRoot=$ProjectBRoot }
    )
    targets=@(
      [pscustomobject][ordered]@{ kind='controller'; projectRoot=$ControllerRoot; creationOperationId='create-controller-new'; expectedCodexProjectId='controller-project'; expectedHostId='host-1' },
      [pscustomobject][ordered]@{ kind='project'; projectRoot=$ProjectARoot; creationOperationId='create-project-A-new'; expectedCodexProjectId='project-A'; expectedHostId='host-1' },
      [pscustomobject][ordered]@{ kind='project'; projectRoot=$ProjectBRoot; creationOperationId='create-project-B-new'; expectedCodexProjectId='project-B'; expectedHostId='host-1' }
    )
  }
}

function New-PreparePayload {
  param([string]$ControllerRoot, [string]$ProjectARoot, [string]$ProjectBRoot, [object[]]$ActiveChains = @())
  $payload=New-PlanPayload $ControllerRoot $ProjectARoot $ProjectBRoot
  Add-Member -InputObject $payload -NotePropertyName planHash -NotePropertyValue (Get-TaskSetPlanHash $payload)
  for($i=0;$i-lt$payload.targets.Count;$i++){
    $summary=@('Controller full initial handoff','Project A full initial handoff','Project B full initial handoff')[$i]
    $oldest=@('c-1','a-1','b-1')[$i];$newest=@('c-2','a-2','b-2')[$i]
    Add-Member -InputObject $payload.targets[$i] -NotePropertyName handoff -NotePropertyValue (New-Handoff $summary $oldest $newest 2)
  }
  Add-Member -InputObject $payload -NotePropertyName initialActiveChains -NotePropertyValue @($ActiveChains)
  $manifestHash=Get-Hash ([IO.File]::ReadAllBytes((Join-Path $ControllerRoot '.codex-controller.json')))
  $fenceReadback=New-RuntimeReadback $ControllerRoot 'none' $null $null $null $null $null $null $payload.planHash $manifestHash
  Add-Member -InputObject $payload -NotePropertyName initialExternalQuiescence -NotePropertyValue (New-ExternalQuiescence '2026-08-13T00:00:30Z' $fenceReadback)
  Add-Member -InputObject $payload -NotePropertyName initialEvidenceHash -NotePropertyValue (Get-TaskSetEvidenceHash $payload.targets $payload.initialActiveChains $payload.initialExternalQuiescence @())
  Add-Member -InputObject $payload -NotePropertyName preparedAt -NotePropertyValue '2026-08-13T00:01:00Z'
  return $payload
}

function Get-TaskSetPlanHash {
  param($Payload)
  $stableTargets=@($Payload.targets|ForEach-Object{
    [pscustomobject][ordered]@{
      kind=$_.kind;projectRoot=$_.projectRoot;creationOperationId=$_.creationOperationId
      expectedCodexProjectId=$_.expectedCodexProjectId;expectedHostId=$_.expectedHostId
    }
  })
  $plan = [pscustomobject][ordered]@{
    operationId=$Payload.operationId; fromTaskSetId=$Payload.fromTaskSetId; toTaskSetId=$Payload.toTaskSetId; coordinator=$Payload.coordinator
    expectedController=$Payload.expectedController; expectedProjectBindings=@($Payload.expectedProjectBindings)
    targets=@($stableTargets)
  }
  return Get-Hash $utf8.GetBytes(($plan | ConvertTo-Json -Depth 20 -Compress))
}

function Get-TaskSetEvidenceHash {
  param([object[]]$Targets,[object[]]$ActiveChains,$ExternalQuiescence,[object[]]$Archives)
  $evidenceTargets=@($Targets|ForEach-Object{
    [pscustomobject][ordered]@{
      kind=$_.kind;projectRoot=$_.projectRoot
      handoff=if($_.PSObject.Properties['handoff']){$_.handoff}else{$null}
    }
  })
  $evidence=[pscustomobject][ordered]@{
    targets=@($evidenceTargets);activeChains=@($ActiveChains);externalQuiescence=$ExternalQuiescence;archives=@($Archives)
  }
  return Get-Hash $utf8.GetBytes(($evidence|ConvertTo-Json -Depth 20 -Compress))
}

function New-FinalEvidencePayload {
  param([object[]]$Targets,[object[]]$ActiveChains,$ExternalQuiescence,[object[]]$Archives,[string]$FinalizedAt)
  $payload=[pscustomobject][ordered]@{
    operationId='reset-op-1';targets=@($Targets);activeChains=@($ActiveChains);externalQuiescence=$ExternalQuiescence
    archives=@($Archives);finalEvidenceHash=(Get-TaskSetEvidenceHash $Targets $ActiveChains $ExternalQuiescence $Archives);finalizedAt=$FinalizedAt
  }
  return $payload
}

function New-RuntimeReadback {
  param(
    [string]$ControllerRoot,[string]$ReplacementState,[AllowNull()][object]$ReplacementSetHash,
    [AllowNull()][object]$ManifestPreparedHash,[AllowNull()][object]$RuntimePrepareToken,[AllowNull()][object]$ManifestSwitchedHash,
    [AllowNull()][object]$PreparedAt,[AllowNull()][object]$CommittedAt,[string]$FencePlanHash='',[string]$FenceManifestExpectedHash=''
  )
  $committed=$ReplacementState -ceq 'committed'
  $replacement=$ReplacementState -in @('prepared','committed')
  return [pscustomobject][ordered]@{
    state='controller-replacement-read'; controllerRoot=$ControllerRoot
    controllerThreadId=if($committed){'controller-new'}else{'controller-old'}; hostId='host-1'; replacementState=$ReplacementState
    operationId=if($replacement){'reset-op-1'}else{$null};replacementSetHash=$ReplacementSetHash
    oldControllerThreadId=if($replacement){'controller-old'}else{$null};oldHostId=if($replacement){'host-1'}else{$null}
    newControllerThreadId=if($replacement){'controller-new'}else{$null};newHostId=if($replacement){'host-1'}else{$null};manifestPreparedHash=$ManifestPreparedHash
    prepareToken=$RuntimePrepareToken; manifestSwitchedHash=$ManifestSwitchedHash; preparedAt=$PreparedAt; committedAt=$CommittedAt
    activeDispatchCount=0; unacknowledgedReceiptCount=0
    fenceState='prepared';fenceOperationId='reset-op-1';fencePlanHash=$FencePlanHash;fenceManifestExpectedHash=$FenceManifestExpectedHash
    fencePreparedAt='2026-08-13T00:00:25Z';fenceCompletedManifestHash=$null;fenceCompletedAt=$null
    wakeWorkerState='none';wakeWorkerOperationId=$null;wakeWorkerThreadId=$null;wakeWorkerClientThreadId=$null
    wakeAutomationState='none';wakeAutomationOperationId=$null;wakeAutomationId=$null
  }
}

function New-RuntimeEvidencePayload {
  param($Readback)
  return [pscustomobject][ordered]@{
    operationId='reset-op-1'; runtimeReadback=$Readback
    runtimeReadbackHash=(Get-Hash $utf8.GetBytes(($Readback | ConvertTo-Json -Depth 20 -Compress)))
  }
}

function New-CompletedFenceReadback {
  param([string]$ControllerRoot,[string]$PlanHash,[string]$FenceManifestExpectedHash,[string]$CompletedManifestHash)
  return [pscustomobject][ordered]@{
    state='controller-replacement-read';controllerRoot=$ControllerRoot;controllerThreadId='controller-new';hostId='host-1';replacementState='legacy'
    operationId='reset-op-1';replacementSetHash=$null;oldControllerThreadId='controller-old';oldHostId='host-1';newControllerThreadId='controller-new';newHostId='host-1'
    manifestPreparedHash=$null;prepareToken=$null;manifestSwitchedHash=$null;preparedAt=$null;committedAt='2026-08-13T00:09:00Z'
    activeDispatchCount=0;unacknowledgedReceiptCount=0
    fenceState='completed';fenceOperationId='reset-op-1';fencePlanHash=$PlanHash;fenceManifestExpectedHash=$FenceManifestExpectedHash;fencePreparedAt='2026-08-13T00:00:25Z'
    fenceCompletedManifestHash=$CompletedManifestHash;fenceCompletedAt='2026-08-13T00:10:01Z'
    wakeWorkerState='none';wakeWorkerOperationId=$null;wakeWorkerThreadId=$null;wakeWorkerClientThreadId=$null
    wakeAutomationState='none';wakeAutomationOperationId=$null;wakeAutomationId=$null
  }
}

function New-StandbyProof {
  param([string]$ThreadId, [string]$CodexProjectId, [string]$HostId, [string]$ProjectRoot, $Handoff, [string]$ObservedAt)
  $snapshot=[pscustomobject][ordered]@{
    threadId=$ThreadId; codexProjectId=$CodexProjectId; hostId=$HostId; projectRoot=$ProjectRoot; state='standby'
    summaryHash=$Handoff.summaryHash; historyDigest=$Handoff.historyDigest; newestTurnId=$Handoff.newestTurnId; acknowledgedTurnId=$Handoff.newestTurnId; observedAt=$ObservedAt
  }
  return [pscustomobject][ordered]@{
    threadId=$snapshot.threadId; codexProjectId=$snapshot.codexProjectId; hostId=$snapshot.hostId; projectRoot=$snapshot.projectRoot
    state=$snapshot.state; summaryHash=$snapshot.summaryHash; historyDigest=$snapshot.historyDigest; newestTurnId=$snapshot.newestTurnId
    acknowledgedTurnId=$snapshot.acknowledgedTurnId; observedAt=$snapshot.observedAt
    snapshotHash=(Get-Hash $utf8.GetBytes(($snapshot | ConvertTo-Json -Depth 10 -Compress)))
  }
}

function New-BootstrapProof {
  param([string]$ThreadId,[string]$CodexProjectId,[string]$HostId,[string]$ProjectRoot,[string]$CreationOperationId,[string]$ObservedAt)
  $snapshot=[pscustomobject][ordered]@{
    threadId=$ThreadId;codexProjectId=$CodexProjectId;hostId=$HostId;projectRoot=$ProjectRoot
    creationOperationId=$CreationOperationId;state='standby';observedAt=$ObservedAt
  }
  $snapshot|Add-Member -NotePropertyName snapshotHash -NotePropertyValue (Get-Hash $utf8.GetBytes(($snapshot|ConvertTo-Json -Depth 8 -Compress)))
  return $snapshot
}

function New-BootstrapEvidencePayload {
  param([string]$Kind,[string]$ProjectRoot,$BootstrapProof)
  return [pscustomobject][ordered]@{operationId='reset-op-1';kind=$Kind;projectRoot=$ProjectRoot;bootstrapProof=$BootstrapProof}
}

function Get-StandbyProofHash {
  param($Proof)
  $snapshot=[pscustomobject][ordered]@{
    threadId=$Proof.threadId; codexProjectId=$Proof.codexProjectId; hostId=$Proof.hostId; projectRoot=$Proof.projectRoot
    state=$Proof.state; summaryHash=$Proof.summaryHash; historyDigest=$Proof.historyDigest; newestTurnId=$Proof.newestTurnId
    acknowledgedTurnId=$Proof.acknowledgedTurnId; observedAt=$Proof.observedAt
  }
  return Get-Hash $utf8.GetBytes(($snapshot | ConvertTo-Json -Depth 10 -Compress))
}

function New-StandbyEvidencePayload {
  param([string]$Kind, [string]$ProjectRoot, $StandbyProof)
  return [pscustomobject][ordered]@{
    operationId='reset-op-1'; kind=$Kind; projectRoot=$ProjectRoot; standbyProof=$StandbyProof
  }
}

function New-HandoffEvidencePayload {
  param([string]$Kind, [string]$ProjectRoot, $Handoff)
  return [pscustomobject][ordered]@{ operationId='reset-op-1'; kind=$Kind; projectRoot=$ProjectRoot; handoff=$Handoff }
}

function New-ArchiveSnapshot {
  param([string]$ThreadId, [string]$CodexProjectId, [string]$HostId, [string]$ProjectRoot, $Handoff, [bool]$Archived = $true)
  return [pscustomobject][ordered]@{
    threadId=$ThreadId; hostId=$HostId; codexProjectId=$CodexProjectId; archived=$Archived; projectRoot=$ProjectRoot
    history=[pscustomobject][ordered]@{
      oldestTurnId=$Handoff.oldestTurnId; newestTurnId=$Handoff.newestTurnId; turnCount=$Handoff.turnCount
      historyDigest=$Handoff.historyDigest; eofComplete=$Handoff.eofComplete
    }
  }
}

function New-ArchiveEvidencePayload {
  param([string]$Kind, $Snapshot, [string]$ArchivedAt)
  return [pscustomobject][ordered]@{
    operationId='reset-op-1'; kind=$Kind; snapshot=$Snapshot
    snapshotHash=(Get-Hash $utf8.GetBytes(($Snapshot | ConvertTo-Json -Depth 10 -Compress))); archivedAt=$ArchivedAt
  }
}

function Complete-SecondReset {
  param([string]$Root,[string]$ProjectARoot,[string]$ProjectBRoot,[string]$ExpectedHash,[string]$FromTaskSetId)
  $operationId='reset-op-2';$toTaskSetId=Get-TaskSetId $Root $FromTaskSetId $operationId
  $plan=[pscustomobject][ordered]@{
    operationId=$operationId;fromTaskSetId=$FromTaskSetId;toTaskSetId=$toTaskSetId
    coordinator=[pscustomobject][ordered]@{threadId='coordinator-task';hostId='host-external'}
    expectedController=[pscustomobject][ordered]@{threadId='controller-new';codexProjectId='controller-project';hostId='host-1';projectRoot=$Root}
    expectedProjectBindings=@(
      [pscustomobject][ordered]@{entryThreadId='project-A-new';codexProjectId='project-A';hostId='host-1';projectRoot=$ProjectARoot},
      [pscustomobject][ordered]@{entryThreadId='project-B-new';codexProjectId='project-B';hostId='host-1';projectRoot=$ProjectBRoot}
    )
    targets=@(
      [pscustomobject][ordered]@{kind='controller';projectRoot=$Root;creationOperationId='create-controller-next';expectedCodexProjectId='controller-project';expectedHostId='host-1'},
      [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectARoot;creationOperationId='create-project-A-next';expectedCodexProjectId='project-A';expectedHostId='host-1'},
      [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectBRoot;creationOperationId='create-project-B-next';expectedCodexProjectId='project-B';expectedHostId='host-1'}
    )
  }
  Assert-State (Invoke-State PlanTaskSetReset $Root '' '' $plan) verified 0 'controller-task-set-reset-planned'
  $planHash=Get-TaskSetPlanHash $plan
  $initialRuntime=[pscustomobject][ordered]@{
    state='controller-replacement-read';controllerRoot=$Root;controllerThreadId='controller-new';hostId='host-1';replacementState='legacy'
    operationId='reset-op-1';replacementSetHash=$null;oldControllerThreadId='controller-old';oldHostId='host-1';newControllerThreadId='controller-new';newHostId='host-1'
    manifestPreparedHash=$null;prepareToken=$null;manifestSwitchedHash=$null;preparedAt=$null;committedAt='2026-08-13T00:09:00Z'
    activeDispatchCount=0;unacknowledgedReceiptCount=0
    fenceState='prepared';fenceOperationId=$operationId;fencePlanHash=$planHash;fenceManifestExpectedHash=$ExpectedHash;fencePreparedAt='2026-08-14T00:00:25Z';fenceCompletedManifestHash=$null;fenceCompletedAt=$null
    wakeWorkerState='none';wakeWorkerOperationId=$null;wakeWorkerThreadId=$null;wakeWorkerClientThreadId=$null
    wakeAutomationState='none';wakeAutomationOperationId=$null;wakeAutomationId=$null
  }
  $prepare=$plan|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  Add-Member -InputObject $prepare -NotePropertyName planHash -NotePropertyValue $planHash
  $handoffSummaries=@('Controller second initial handoff','Project A second initial handoff','Project B second initial handoff')
  $handoffOldest=@('c-3','a-3','b-3');$handoffNewest=@('c-4','a-4','b-4')
  for($index=0;$index-lt$prepare.targets.Count;$index++){
    Add-Member -InputObject $prepare.targets[$index] -NotePropertyName handoff -NotePropertyValue (New-Handoff $handoffSummaries[$index] $handoffOldest[$index] $handoffNewest[$index] 2 '2026-08-14T00:00:20Z')
  }
  Add-Member -InputObject $prepare -NotePropertyName initialActiveChains -NotePropertyValue @()
  Add-Member -InputObject $prepare -NotePropertyName initialExternalQuiescence -NotePropertyValue (New-ExternalQuiescence '2026-08-14T00:00:30Z' $initialRuntime)
  Add-Member -InputObject $prepare -NotePropertyName initialEvidenceHash -NotePropertyValue (Get-TaskSetEvidenceHash $prepare.targets @() $prepare.initialExternalQuiescence @())
  Add-Member -InputObject $prepare -NotePropertyName preparedAt -NotePropertyValue '2026-08-14T00:01:00Z'
  $applied=Mutate $Root $ExpectedHash 'prepare-task-set-reset' $prepare;$hash=[string]$applied.Result.resultHash

  foreach($issued in @(
    [ordered]@{operationId=$operationId;kind='project';projectRoot=$ProjectARoot;creationOperationId='create-project-A-next';issuedAt='2026-08-14T00:02:00Z'},
    [ordered]@{operationId=$operationId;kind='project';projectRoot=$ProjectBRoot;creationOperationId='create-project-B-next';issuedAt='2026-08-14T00:02:10Z'},
    [ordered]@{operationId=$operationId;kind='controller';projectRoot=$Root;creationOperationId='create-controller-next';issuedAt='2026-08-14T00:02:20Z'}
  )){$applied=Mutate $Root $hash 'record-task-set-creation-issued' $issued;$hash=[string]$applied.Result.resultHash}
  foreach($replacement in @(
    [ordered]@{operationId=$operationId;kind='project';projectRoot=$ProjectARoot;threadId='project-A-next';codexProjectId='project-A';hostId='host-1'},
    [ordered]@{operationId=$operationId;kind='project';projectRoot=$ProjectBRoot;threadId='project-B-next';codexProjectId='project-B';hostId='host-1'},
    [ordered]@{operationId=$operationId;kind='controller';projectRoot=$Root;threadId='controller-next';codexProjectId='controller-project';hostId='host-1'}
  )){$applied=Mutate $Root $hash 'record-task-set-replacement' $replacement;$hash=[string]$applied.Result.resultHash}
  foreach($bootstrap in @(
    (New-BootstrapEvidencePayload 'project' $ProjectARoot (New-BootstrapProof 'project-A-next' 'project-A' 'host-1' $ProjectARoot 'create-project-A-next' '2026-08-14T00:03:10Z')),
    (New-BootstrapEvidencePayload 'project' $ProjectBRoot (New-BootstrapProof 'project-B-next' 'project-B' 'host-1' $ProjectBRoot 'create-project-B-next' '2026-08-14T00:03:20Z')),
    (New-BootstrapEvidencePayload 'controller' $Root (New-BootstrapProof 'controller-next' 'controller-project' 'host-1' $Root 'create-controller-next' '2026-08-14T00:03:30Z'))
  )){$bootstrap.operationId=$operationId;$applied=Mutate $Root $hash 'record-task-set-bootstrap-proof' $bootstrap;$hash=[string]$applied.Result.resultHash}

  $finalController=New-Handoff 'Controller second final handoff' 'c-3' 'c-5' 3 '2026-08-14T00:05:20Z'
  $finalA=New-Handoff 'Project A second final handoff' 'a-3' 'a-5' 3 '2026-08-14T00:05:00Z'
  $finalB=New-Handoff 'Project B second final handoff' 'b-3' 'b-5' 3 '2026-08-14T00:05:10Z'
  $archives=@(
    (New-ArchiveEvidencePayload 'project' (New-ArchiveSnapshot 'project-A-new' 'project-A' 'host-1' $ProjectARoot $finalA) '2026-08-14T00:04:00Z'),
    (New-ArchiveEvidencePayload 'project' (New-ArchiveSnapshot 'project-B-new' 'project-B' 'host-1' $ProjectBRoot $finalB) '2026-08-14T00:04:10Z'),
    (New-ArchiveEvidencePayload 'controller' (New-ArchiveSnapshot 'controller-new' 'controller-project' 'host-1' $Root $finalController) '2026-08-14T00:04:20Z')
  )
  foreach($archive in $archives){$archive.operationId=$operationId;$applied=Mutate $Root $hash 'record-task-set-archive' $archive;$hash=[string]$applied.Result.resultHash}
  $archives=@($applied.Result.data.taskSetReset.archives)
  $finalTargets=@(
    [pscustomobject][ordered]@{kind='controller';projectRoot=$Root;handoff=$finalController},
    [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectARoot;handoff=$finalA},
    [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectBRoot;handoff=$finalB}
  )
  $finalQuiet=New-ExternalQuiescence '2026-08-14T00:05:30Z' $initialRuntime
  $finalEvidence=New-FinalEvidencePayload $finalTargets @() $finalQuiet $archives '2026-08-14T00:06:00Z';$finalEvidence.operationId=$operationId
  $applied=Mutate $Root $hash 'record-task-set-final-evidence' $finalEvidence;$hash=[string]$applied.Result.resultHash
  foreach($standby in @(
    (New-StandbyEvidencePayload 'project' $ProjectARoot (New-StandbyProof 'project-A-next' 'project-A' 'host-1' $ProjectARoot $finalA '2026-08-14T00:06:10Z')),
    (New-StandbyEvidencePayload 'project' $ProjectBRoot (New-StandbyProof 'project-B-next' 'project-B' 'host-1' $ProjectBRoot $finalB '2026-08-14T00:06:20Z')),
    (New-StandbyEvidencePayload 'controller' $Root (New-StandbyProof 'controller-next' 'controller-project' 'host-1' $Root $finalController '2026-08-14T00:06:30Z'))
  )){$standby.operationId=$operationId;$applied=Mutate $Root $hash 'record-task-set-standby-proof' $standby;$hash=[string]$applied.Result.resultHash}

  $replacementSet=@(
    [pscustomobject][ordered]@{kind='controller';projectRoot=$Root;threadId='controller-next';codexProjectId='controller-project';hostId='host-1'},
    [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectARoot;threadId='project-A-next';codexProjectId='project-A';hostId='host-1'},
    [pscustomobject][ordered]@{kind='project';projectRoot=$ProjectBRoot;threadId='project-B-next';codexProjectId='project-B';hostId='host-1'}
  )
  $replacementSetHash=Get-Hash $utf8.GetBytes(($replacementSet|ConvertTo-Json -Depth 6 -Compress));$manifestPreparedHash=$hash;$runtimePrepareToken='4'*64
  $runtimePrepared=New-RuntimeReadback $Root 'prepared' $replacementSetHash $manifestPreparedHash $runtimePrepareToken $null '2026-08-14T00:07:00Z' $null $planHash $ExpectedHash
  $runtimePrepared.controllerThreadId='controller-new';$runtimePrepared.operationId=$operationId;$runtimePrepared.oldControllerThreadId='controller-new';$runtimePrepared.newControllerThreadId='controller-next';$runtimePrepared.fenceOperationId=$operationId;$runtimePrepared.fencePreparedAt='2026-08-14T00:00:25Z'
  $runtimeEvidence=New-RuntimeEvidencePayload $runtimePrepared;$runtimeEvidence.operationId=$operationId
  $applied=Mutate $Root $hash 'record-task-set-runtime-prepared' $runtimeEvidence;$hash=[string]$applied.Result.resultHash
  $switch=[ordered]@{operationId=$operationId;replacementSetHash=$replacementSetHash;runtimePrepareToken=$runtimePrepareToken;switchedAt='2026-08-14T00:08:00Z'}
  $applied=Mutate $Root $hash 'switch-task-set' $switch;$hash=[string]$applied.Result.resultHash
  $runtimeCommitted=New-RuntimeReadback $Root 'committed' $replacementSetHash $manifestPreparedHash $runtimePrepareToken $hash '2026-08-14T00:07:00Z' '2026-08-14T00:09:00Z' $planHash $ExpectedHash
  $runtimeCommitted.controllerThreadId='controller-next';$runtimeCommitted.operationId=$operationId;$runtimeCommitted.oldControllerThreadId='controller-new';$runtimeCommitted.newControllerThreadId='controller-next';$runtimeCommitted.fenceOperationId=$operationId;$runtimeCommitted.fencePreparedAt='2026-08-14T00:00:25Z'
  $runtimeEvidence=New-RuntimeEvidencePayload $runtimeCommitted;$runtimeEvidence.operationId=$operationId
  $applied=Mutate $Root $hash 'record-task-set-runtime-committed' $runtimeEvidence;$hash=[string]$applied.Result.resultHash
  $applied=Mutate $Root $hash 'complete-task-set-reset' ([ordered]@{operationId=$operationId;completedAt='2026-08-14T00:10:00Z'});$hash=[string]$applied.Result.resultHash
  $completedFence=New-CompletedFenceReadback $Root $planHash $ExpectedHash $hash
  $completedFence.controllerThreadId='controller-next';$completedFence.operationId=$operationId;$completedFence.oldControllerThreadId='controller-new';$completedFence.newControllerThreadId='controller-next';$completedFence.committedAt='2026-08-14T00:09:00Z';$completedFence.fenceOperationId=$operationId;$completedFence.fencePreparedAt='2026-08-14T00:00:25Z';$completedFence.fenceCompletedAt='2026-08-14T00:10:01Z'
  $recovery=[pscustomobject][ordered]@{runtimeReadback=$completedFence;runtimeReadbackHash=(Get-Hash $utf8.GetBytes(($completedFence|ConvertTo-Json -Depth 20 -Compress)))}
  Assert-State (Invoke-State RecoverTaskSetResetSeal $Root '' '' $recovery) applied 0 'controller-task-set-reset-seal-recovered'
  return [pscustomobject]@{Hash=$hash;Plan=$plan;CompletedFence=$completedFence}
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tsr-' + [guid]::NewGuid().ToString('N'))

try {
  $controllerRoot = Join-Path $testRoot 'controller'; $projectARoot = Join-Path $testRoot 'project-A'; $projectBRoot = Join-Path $testRoot 'project-B'
  [IO.Directory]::CreateDirectory($projectARoot) | Out-Null; [IO.Directory]::CreateDirectory($projectBRoot) | Out-Null
  $manifest = New-Manifest $controllerRoot $projectARoot $projectBRoot
  $hash = Write-Manifest $controllerRoot $manifest

  $read = Invoke-State Read $controllerRoot
  Assert-State $read verified 0 'controller-state-verified'
  Assert-True ($read.Result.data.schemaVersion -eq 3 -and $read.Result.data.taskSetId -ceq (Get-InitialTaskSetId $controllerRoot) -and $null -eq $read.Result.data.taskSetReset) 'Schema v3 read must preserve taskSetId and nullable taskSetReset'

  $readOnlyPlanRoot=Join-Path $testRoot 'read-only-plan';$readOnlyPlanA=Join-Path $testRoot 'read-only-plan-A';$readOnlyPlanB=Join-Path $testRoot 'read-only-plan-B'
  [IO.Directory]::CreateDirectory($readOnlyPlanA)|Out-Null;[IO.Directory]::CreateDirectory($readOnlyPlanB)|Out-Null
  $readOnlyManifestHash=Write-Manifest $readOnlyPlanRoot (New-Manifest $readOnlyPlanRoot $readOnlyPlanA $readOnlyPlanB)
  $readOnlyBytes=[IO.File]::ReadAllBytes((Join-Path $readOnlyPlanRoot '.codex-controller.json'))
  $readOnlyPlan=New-PlanPayload $readOnlyPlanRoot $readOnlyPlanA $readOnlyPlanB
  $readOnlyApply=New-PreparePayload $readOnlyPlanRoot $readOnlyPlanA $readOnlyPlanB
  $candidateCountBefore=@(Get-ChildItem -LiteralPath $readOnlyPlanRoot -Filter '.codex-controller.*.tmp' -Force).Count
  $planned=Invoke-State PlanTaskSetReset $readOnlyPlanRoot '' '' $readOnlyPlan
  Assert-State $planned verified 0 'controller-task-set-reset-planned'
  Assert-True ((Get-Hash ([IO.File]::ReadAllBytes((Join-Path $readOnlyPlanRoot '.codex-controller.json'))))-ceq(Get-Hash $readOnlyBytes)-and@(Get-ChildItem -LiteralPath $readOnlyPlanRoot -Filter '.codex-controller.*.tmp' -Force).Count-eq$candidateCountBefore) 'PlanTaskSetReset must be write-free for manifest and candidate files'
  $changedReadOnlyPlan=$readOnlyPlan|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;$changedReadOnlyPlan.targets[1].creationOperationId='create-project-A-other'
  $changedPlanned=Invoke-State PlanTaskSetReset $readOnlyPlanRoot '' '' $changedReadOnlyPlan
  Assert-State $changedPlanned verified 0 'controller-task-set-reset-planned'
  Assert-True ($changedPlanned.Result.data.planHash-cne$planned.Result.data.planHash) 'A changed stable plan fact must produce a different plan hash'
  $readOnlyApply.planHash=$planned.Result.data.planHash;$readOnlyApply.initialExternalQuiescence.observedAt='2026-08-13T00:00:40Z';$readOnlyApply.initialExternalQuiescence.proofHash=Get-ExternalQuiescenceHash $readOnlyApply.initialExternalQuiescence;$readOnlyApply.initialEvidenceHash=Get-TaskSetEvidenceHash $readOnlyApply.targets $readOnlyApply.initialActiveChains $readOnlyApply.initialExternalQuiescence @()
  Assert-State (Prepare $readOnlyPlanRoot $readOnlyManifestHash 'prepare-task-set-reset' $readOnlyApply) prepared 0 'controller-candidate-prepared'

  $realRuntimeRoot=Join-Path $testRoot 'real-runtime-contract';$realRuntimeA=Join-Path $testRoot 'real-runtime-contract-A';$realRuntimeB=Join-Path $testRoot 'real-runtime-contract-B'
  [IO.Directory]::CreateDirectory($realRuntimeA)|Out-Null;[IO.Directory]::CreateDirectory($realRuntimeB)|Out-Null
  $realRuntimeManifestHash=Write-Manifest $realRuntimeRoot (New-Manifest $realRuntimeRoot $realRuntimeA $realRuntimeB)
  $realRuntimePlan=New-PlanPayload $realRuntimeRoot $realRuntimeA $realRuntimeB
  $realRuntimePlanned=Invoke-State PlanTaskSetReset $realRuntimeRoot '' '' $realRuntimePlan
  Assert-State $realRuntimePlanned verified 0 'controller-task-set-reset-planned'
  $realRuntimeState=Join-Path $testRoot 'real-runtime.json'
  $null=Invoke-RuntimeCli 'register-controller' $realRuntimeState ([ordered]@{controllerRoot=$realRuntimeRoot;controllerThreadId='controller-old';hostId='host-1'})
  $null=Invoke-RuntimeCli 'prepare-task-set-reset-fence' $realRuntimeState ([ordered]@{
    controllerRoot=$realRuntimeRoot;operationId='reset-op-1';planHash=$realRuntimePlanned.Result.data.planHash
    manifestExpectedHash=$realRuntimeManifestHash;preparedAt='2026-08-13T00:00:25Z'
  })
  $realRuntimeReadback=Invoke-RuntimeCli 'read-controller-replacement' $realRuntimeState ([ordered]@{controllerRoot=$realRuntimeRoot})
  $realRuntimeApply=New-PreparePayload $realRuntimeRoot $realRuntimeA $realRuntimeB
  $realRuntimeApply.planHash=$realRuntimePlanned.Result.data.planHash
  $realRuntimeApply.initialExternalQuiescence=New-ExternalQuiescence '2026-08-13T00:00:30Z' $realRuntimeReadback
  $realRuntimeApply.initialEvidenceHash=Get-TaskSetEvidenceHash $realRuntimeApply.targets $realRuntimeApply.initialActiveChains $realRuntimeApply.initialExternalQuiescence @()

  $legacyNestedReadback=[pscustomobject][ordered]@{
    state='controller-replacement-read';controllerRoot=$realRuntimeRoot;controllerThreadId='controller-old';hostId='host-1';replacementState='none'
    taskSetReplacement=$null;lastReplacement=$null;activeDispatchCount=0;unacknowledgedReceiptCount=0;wakeWorker=$null
  }
  $legacyNested=$realRuntimeApply|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  $legacyNested.initialExternalQuiescence=New-ExternalQuiescence '2026-08-13T00:00:30Z' $legacyNestedReadback
  $legacyNested.initialEvidenceHash=Get-TaskSetEvidenceHash $legacyNested.targets $legacyNested.initialActiveChains $legacyNested.initialExternalQuiescence @()
  Assert-State (Prepare $realRuntimeRoot $realRuntimeManifestHash 'prepare-task-set-reset' $legacyNested) invalid 2 'controller-payload-invalid'

  $extraReadback=$realRuntimeReadback|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  Add-Member -InputObject $extraReadback -NotePropertyName unexpectedRuntimeField -NotePropertyValue 'forbidden'
  $extraRuntime=$realRuntimeApply|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  $extraRuntime.initialExternalQuiescence=New-ExternalQuiescence '2026-08-13T00:00:30Z' $extraReadback
  $extraRuntime.initialEvidenceHash=Get-TaskSetEvidenceHash $extraRuntime.targets $extraRuntime.initialActiveChains $extraRuntime.initialExternalQuiescence @()
  Assert-State (Prepare $realRuntimeRoot $realRuntimeManifestHash 'prepare-task-set-reset' $extraRuntime) invalid 2 'controller-payload-invalid'

  $realRuntimePrepared=Prepare $realRuntimeRoot $realRuntimeManifestHash 'prepare-task-set-reset' $realRuntimeApply
  Assert-State $realRuntimePrepared prepared 0 'controller-candidate-prepared'
  $realRuntimeApplied=Invoke-State ApplyCandidate $realRuntimeRoot $realRuntimeManifestHash '' $null $realRuntimePrepared.Result.candidatePath $realRuntimePrepared.Result.candidateHash
  Assert-State $realRuntimeApplied applied 0 'controller-state-applied'
  Assert-True ($realRuntimeApplied.Result.data.taskSetReset.initialExternalQuiescence.runtimeReadbackHash-ceq$realRuntimeApply.initialExternalQuiescence.runtimeReadbackHash) 'Apply must preserve the exact canonical runtime CLI readback hash'

  $planRoot=Join-Path $testRoot 'plan-hash'; $planA=Join-Path $testRoot 'plan-hash-A'; $planB=Join-Path $testRoot 'plan-hash-B'
  [IO.Directory]::CreateDirectory($planA) | Out-Null; [IO.Directory]::CreateDirectory($planB) | Out-Null
  $planManifestHash=Write-Manifest $planRoot (New-Manifest $planRoot $planA $planB)
  $exactPlan=New-PreparePayload $planRoot $planA $planB; $exactPlan.planHash=Get-TaskSetPlanHash $exactPlan
  $changedPlan=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
  $changedPlan.targets[1].creationOperationId='create-project-A-third'
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $changedPlan) invalid 2 'controller-payload-invalid'

  $fakePlan=New-PreparePayload $planRoot $planA $planB; $fakePlan.planHash='f' * 64
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $fakePlan) invalid 2 'controller-payload-invalid'
  $clockPlan=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $clockPlan.preparedAt='2026-08-13T00:01:30Z'
  Assert-True ((Get-TaskSetPlanHash $clockPlan) -ceq $exactPlan.planHash) 'Execution preparedAt must not change the stable authorized plan hash'
  $fakeEvidence=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $fakeEvidence.initialEvidenceHash='e' * 64
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $fakeEvidence) invalid 2 'controller-payload-invalid'
  $fakeQuietProof=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $fakeQuietProof.initialExternalQuiescence.proofHash='7' * 64; $fakeQuietProof.planHash=Get-TaskSetPlanHash $fakeQuietProof
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $fakeQuietProof) invalid 2 'controller-payload-invalid'
  $futureEvidence=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $futureEvidence.initialExternalQuiescence.observedAt='2026-08-13T00:02:00Z'; $futureEvidence.initialExternalQuiescence.proofHash=Get-ExternalQuiescenceHash $futureEvidence.initialExternalQuiescence; $futureEvidence.initialEvidenceHash=Get-TaskSetEvidenceHash $futureEvidence.targets $futureEvidence.initialActiveChains $futureEvidence.initialExternalQuiescence @()
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $futureEvidence) invalid 2 'controller-payload-invalid'
  $busyExternal=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $busyExternal.initialExternalQuiescence.runtimeDispatches=1; $busyExternal.initialExternalQuiescence.proofHash=Get-ExternalQuiescenceHash $busyExternal.initialExternalQuiescence; $busyExternal.planHash=Get-TaskSetPlanHash $busyExternal;$busyExternal.initialEvidenceHash=Get-TaskSetEvidenceHash $busyExternal.targets $busyExternal.initialActiveChains $busyExternal.initialExternalQuiescence @()
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $busyExternal) conflict 1 'controller-task-state-conflict'
  $scopedCoordinator=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $scopedCoordinator.coordinator.threadId='controller-old'; $scopedCoordinator.planHash=Get-TaskSetPlanHash $scopedCoordinator
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $scopedCoordinator) conflict 1 'controller-task-state-conflict'
  $changedCoordinator=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $changedCoordinator.coordinator.threadId='coordinator-third'
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $changedCoordinator) invalid 2 'controller-payload-invalid'
  $changedQuietPlan=$exactPlan | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json; $changedQuietPlan.initialExternalQuiescence.observedAt='2026-08-13T00:00:31Z'; $changedQuietPlan.initialExternalQuiescence.proofHash=Get-ExternalQuiescenceHash $changedQuietPlan.initialExternalQuiescence
  Assert-True ((Get-TaskSetPlanHash $changedQuietPlan) -ceq $exactPlan.planHash) 'Fresh quiescence observation must preserve the stable authorized plan hash'
  Assert-True ((Get-TaskSetEvidenceHash $changedQuietPlan.targets $changedQuietPlan.initialActiveChains $changedQuietPlan.initialExternalQuiescence @()) -cne $exactPlan.initialEvidenceHash) 'Fresh quiescence observation must produce a distinct execution evidence hash'
  $changedQuietPlan.initialEvidenceHash=Get-TaskSetEvidenceHash $changedQuietPlan.targets $changedQuietPlan.initialActiveChains $changedQuietPlan.initialExternalQuiescence @()
  Assert-State (Prepare $planRoot $planManifestHash 'prepare-task-set-reset' $changedQuietPlan) prepared 0 'controller-candidate-prepared'

  foreach ($case in @(
    [pscustomobject]@{ Name='pending'; Mode='busy-pending' },
    [pscustomobject]@{ Name='active lease'; Mode='busy-lease' },
    [pscustomobject]@{ Name='controller intent'; Mode='intent' }
  )) {
    $caseRoot=Join-Path $testRoot ('blocked-' + $case.Mode); $caseA=Join-Path $testRoot ($case.Mode + '-A'); $caseB=Join-Path $testRoot ($case.Mode + '-B')
    [IO.Directory]::CreateDirectory($caseA) | Out-Null; [IO.Directory]::CreateDirectory($caseB) | Out-Null
    $caseHash=Write-Manifest $caseRoot (New-Manifest $caseRoot $caseA $caseB $case.Mode)
    Assert-State (Prepare $caseRoot $caseHash 'prepare-task-set-reset' (New-PreparePayload $caseRoot $caseA $caseB)) conflict 1 'controller-task-state-conflict'
  }

  foreach($chainCase in @(
    [pscustomobject]@{Name='stale-wrapper';NextAction='Continue in project-A-old';History='N/A';Allowed=$false},
    [pscustomobject]@{Name='payload-history';NextAction='Continue through the current project binding';History='Previously ran in project-A-old';Allowed=$true},
    [pscustomobject]@{Name='identifier-boundary';NextAction='Continue in project-A-old-suffix';History='N/A';Allowed=$true}
  )){
    $caseRoot=Join-Path $testRoot ('chain-'+$chainCase.Name);$caseA=Join-Path $testRoot ('chain-'+$chainCase.Name+'-A');$caseB=Join-Path $testRoot ('chain-'+$chainCase.Name+'-B')
    [IO.Directory]::CreateDirectory($caseA)|Out-Null;[IO.Directory]::CreateDirectory($caseB)|Out-Null
    $caseHash=Write-Manifest $caseRoot (New-Manifest $caseRoot $caseA $caseB)
    $chainId='CHAIN-'+$chainCase.Name.ToUpperInvariant();$head=Put-ActiveChain $caseRoot $chainId 'Preserve active work' $chainCase.NextAction $chainCase.History
    $reset=New-PreparePayload $caseRoot $caseA $caseB @([pscustomobject][ordered]@{chainId=$chainId;expectedEntryHash=$head})
    if($chainCase.Allowed){$applied=Mutate $caseRoot $caseHash 'prepare-task-set-reset' $reset;Assert-True ($applied.Result.data.taskSetReset.initialActiveChains[0].expectedEntryHash-ceq$head) 'Allowed active CHAIN must retain its exact canonical head'}
    else{Assert-State (Prepare $caseRoot $caseHash 'prepare-task-set-reset' $reset) conflict 1 'controller-task-state-conflict'}
  }

  $mismatch = New-PreparePayload $controllerRoot $projectARoot $projectBRoot
  $mismatch.expectedProjectBindings[0].entryThreadId='wrong-old-task';$mismatch.planHash=Get-TaskSetPlanHash $mismatch
  Assert-State (Prepare $controllerRoot $hash 'prepare-task-set-reset' $mismatch) conflict 1 'project-binding-conflict'

  foreach ($version in 1,2) {
    $legacyRoot=Join-Path $testRoot "legacy-$version"; $legacyA=Join-Path $testRoot "legacy-$version-A"; $legacyB=Join-Path $testRoot "legacy-$version-B"
    [IO.Directory]::CreateDirectory($legacyA) | Out-Null; [IO.Directory]::CreateDirectory($legacyB) | Out-Null
    $legacyHash=Write-Manifest $legacyRoot (New-Manifest $legacyRoot $legacyA $legacyB 'quiet' $version)
    Assert-State (Prepare $legacyRoot $legacyHash 'prepare-task-set-reset' (New-PreparePayload $legacyRoot $legacyA $legacyB)) conflict 1 'controller-capability-unavailable'
    Assert-State (Invoke-State PlanTaskSetReset $legacyRoot '' '' (New-PlanPayload $legacyRoot $legacyA $legacyB)) conflict 1 'controller-capability-unavailable'
  }

  $preparePayload = New-PreparePayload $controllerRoot $projectARoot $projectBRoot
  $prepared = Mutate $controllerRoot $hash 'prepare-task-set-reset' $preparePayload
  $hash = [string]$prepared.Result.resultHash
  Assert-True ($prepared.Result.data.taskSetReset.phase -ceq 'prepared' -and @($prepared.Result.data.taskSetReset.targets).Count -eq 3) 'Quiet prepare must persist the exact reset scope'
  Assert-True ($prepared.Result.data.dispatchQueues[0].lastTerminal.projectTaskId -ceq 'project-A-old') 'Prepare must preserve terminal queue history with old task IDs'

  $replay = Mutate $controllerRoot $hash 'prepare-task-set-reset' $preparePayload
  $hash = [string]$replay.Result.resultHash
  $third = New-PreparePayload $controllerRoot $projectARoot $projectBRoot; $third.operationId='reset-op-other';$third.toTaskSetId=Get-TaskSetId $controllerRoot $third.fromTaskSetId $third.operationId;$third.planHash=Get-TaskSetPlanHash $third
  Assert-State (Prepare $controllerRoot $hash 'prepare-task-set-reset' $third) conflict 1 'controller-task-state-conflict'
  $thirdPlan = New-PreparePayload $controllerRoot $projectARoot $projectBRoot; $thirdPlan.planHash='0' * 64
  Assert-State (Prepare $controllerRoot $hash 'prepare-task-set-reset' $thirdPlan) invalid 2 'controller-payload-invalid'

  $manifestPath=Join-Path $controllerRoot '.codex-controller.json'; $preparedBytes=[IO.File]::ReadAllBytes($manifestPath)
  $preparedDrift=$utf8.GetString($preparedBytes) | ConvertFrom-Json; $preparedDrift.controllerBinding.threadId='controller-third'
  [IO.File]::WriteAllBytes($manifestPath,$utf8.GetBytes(($preparedDrift | ConvertTo-Json -Depth 20 -Compress)+"`n"))
  Assert-State (Invoke-State Read $controllerRoot) conflict 1 'controller-manifest-invalid'
  [IO.File]::WriteAllBytes($manifestPath,$preparedBytes)

  Assert-State (Prepare $controllerRoot $hash 'register-project' ([ordered]@{ entryThreadId='x'; codexProjectId='x'; hostId='x'; projectRoot=(Join-Path $testRoot 'extra') })) conflict 1 'controller-task-set-reset-in-progress'
  Assert-State (Invoke-State ExportDispatch $controllerRoot $hash '' ([ordered]@{ projectRoot=$projectARoot; dispatchId='dispatch-terminal-A' })) conflict 1 'controller-task-set-reset-in-progress'

  $projectAIssued=[ordered]@{
    operationId='reset-op-1'; kind='project'; projectRoot=$projectARoot
    creationOperationId='create-project-A-new'; issuedAt='2026-08-13T00:02:00Z'
  }

  $handoff=[ordered]@{
    operationId='reset-op-1'; kind='controller'; projectRoot=$controllerRoot; summary=$preparePayload.targets[0].handoff.summary
    summaryHash=$preparePayload.targets[0].handoff.summaryHash; oldestTurnId=$preparePayload.targets[0].handoff.oldestTurnId
    newestTurnId=$preparePayload.targets[0].handoff.newestTurnId; turnCount=$preparePayload.targets[0].handoff.turnCount; eofComplete=$true
  }
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-handoff' $handoff) conflict 1 'controller-task-set-reset-in-progress'
  foreach ($invalid in @(
    [pscustomobject]@{ Name='hash'; Mutate={ param($p) $p.targets[0].handoff.summaryHash='2' * 64 } },
    [pscustomobject]@{ Name='secret'; Mutate={ param($p) $p.targets[0].handoff.summary='password=hunter2'; $p.targets[0].handoff.summaryHash=Get-Hash $utf8.GetBytes($p.targets[0].handoff.summary) } },
    [pscustomobject]@{ Name='oversize'; Mutate={ param($p) $p.targets[0].handoff.summary='x' * 6001; $p.targets[0].handoff.summaryHash=Get-Hash $utf8.GetBytes($p.targets[0].handoff.summary) } },
    [pscustomobject]@{ Name='incomplete'; Mutate={ param($p) $p.targets[0].handoff.eofComplete=$false } }
  )) {
    $invalidRoot=Join-Path $testRoot ('handoff-' + $invalid.Name); $invalidA=Join-Path $testRoot ('handoff-' + $invalid.Name + '-A'); $invalidB=Join-Path $testRoot ('handoff-' + $invalid.Name + '-B')
    [IO.Directory]::CreateDirectory($invalidA) | Out-Null; [IO.Directory]::CreateDirectory($invalidB) | Out-Null
    $invalidHash=Write-Manifest $invalidRoot (New-Manifest $invalidRoot $invalidA $invalidB)
    $copy=New-PreparePayload $invalidRoot $invalidA $invalidB; & $invalid.Mutate $copy; $copy.planHash=Get-TaskSetPlanHash $copy
    Assert-State (Prepare $invalidRoot $invalidHash 'prepare-task-set-reset' $copy) invalid 2 'controller-payload-invalid'
  }

  $clientController=[ordered]@{ operationId='reset-op-1'; kind='controller'; projectRoot=$controllerRoot; clientThreadId='client-controller-new' }
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-client-thread' $clientController) conflict 1 'controller-task-state-conflict'

  $controllerIssued=[ordered]@{operationId='reset-op-1';kind='controller';projectRoot=$controllerRoot;creationOperationId='create-controller-new';issuedAt='2026-08-13T00:02:20Z'}
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-creation-issued' $controllerIssued) conflict 1 'controller-task-state-conflict'
  $issued=Mutate $controllerRoot $hash 'record-task-set-creation-issued' $projectAIssued;$hash=[string]$issued.Result.resultHash
  $issuedReplay=Mutate $controllerRoot $hash 'record-task-set-creation-issued' $projectAIssued;$hash=[string]$issuedReplay.Result.resultHash
  $issuedThird=$projectAIssued|ConvertTo-Json -Compress|ConvertFrom-Json;$issuedThird.issuedAt='2026-08-13T00:02:01Z'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-creation-issued' $issuedThird) conflict 1 'controller-task-state-conflict'
  $projectBIssued=[ordered]@{operationId='reset-op-1';kind='project';projectRoot=$projectBRoot;creationOperationId='create-project-B-new';issuedAt='2026-08-13T00:02:10Z'}
  $issued=Mutate $controllerRoot $hash 'record-task-set-creation-issued' $projectBIssued;$hash=[string]$issued.Result.resultHash
  $issued=Mutate $controllerRoot $hash 'record-task-set-creation-issued' $controllerIssued;$hash=[string]$issued.Result.resultHash

  $runtimeBeforeAll=New-RuntimeEvidencePayload (New-RuntimeReadback $controllerRoot 'prepared' ('2' * 64) $hash ('3' * 64) $null '2026-08-13T00:04:00Z' $null $preparePayload.planHash $preparePayload.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash)
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-runtime-prepared' $runtimeBeforeAll) conflict 1 'controller-task-state-conflict'

  $replacementRows=@(
    [pscustomobject]@{ kind='project'; root=$projectARoot; client='client-project-A'; thread='project-A-new'; project='project-A' },
    [pscustomobject]@{ kind='project'; root=$projectBRoot; client='client-project-B'; thread='project-B-new'; project='project-B' }
  )
  foreach ($row in $replacementRows) {
    if ($row.root -cne $projectBRoot) {
      $client=[ordered]@{ operationId='reset-op-1'; kind=$row.kind; projectRoot=$row.root; clientThreadId=$row.client }
      $clientApplied=Mutate $controllerRoot $hash 'record-task-set-client-thread' $client; $hash=[string]$clientApplied.Result.resultHash
    }
    $replacement=[ordered]@{ operationId='reset-op-1'; kind=$row.kind; projectRoot=$row.root; threadId=$row.thread; codexProjectId=$row.project; hostId='host-1' }
    if($row.root-ceq$projectARoot){$coordinatorReplacement=$replacement|ConvertTo-Json -Compress|ConvertFrom-Json;$coordinatorReplacement.threadId='coordinator-task';Assert-State (Prepare $controllerRoot $hash 'record-task-set-replacement' $coordinatorReplacement) conflict 1 'controller-task-state-conflict'}
    if ($row.root -ceq $projectBRoot) {
      $duplicateClient=[ordered]@{ operationId='reset-op-1'; kind='project'; projectRoot=$projectBRoot; clientThreadId='client-project-A' }
      Assert-State (Prepare $controllerRoot $hash 'record-task-set-client-thread' $duplicateClient) conflict 1 'controller-task-state-conflict'
      $duplicate=($replacement | ConvertTo-Json -Compress | ConvertFrom-Json); $duplicate.threadId='project-A-new'
      Assert-State (Prepare $controllerRoot $hash 'record-task-set-replacement' $duplicate) conflict 1 'controller-task-state-conflict'
    }
    $replacementApplied=Mutate $controllerRoot $hash 'record-task-set-replacement' $replacement; $hash=[string]$replacementApplied.Result.resultHash
  }
  $beforeControllerIdentity=Invoke-State Read $controllerRoot
  Assert-True ($null -eq $beforeControllerIdentity.Result.data.taskSetReset.replacementSetHash) 'Replacement-set hash must stay null until the controller-last identity barrier'

  $clientResult=Mutate $controllerRoot $hash 'record-task-set-client-thread' $clientController; $hash=[string]$clientResult.Result.resultHash
  $clientReplay=Mutate $controllerRoot $hash 'record-task-set-client-thread' $clientController; $hash=[string]$clientReplay.Result.resultHash
  $clientThird=($clientController | ConvertTo-Json -Compress | ConvertFrom-Json); $clientThird.clientThreadId='client-controller-other'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-client-thread' $clientThird) conflict 1 'controller-task-state-conflict'
  $controllerReplacement=[ordered]@{
    operationId='reset-op-1'; kind='controller'; projectRoot=$controllerRoot; threadId='controller-new'
    codexProjectId='controller-project'; hostId='host-1'
  }
  $oldThread=($controllerReplacement | ConvertTo-Json -Compress | ConvertFrom-Json); $oldThread.threadId='controller-old'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-replacement' $oldThread) conflict 1 'controller-task-state-conflict'
  $wrongSavedProject=($controllerReplacement | ConvertTo-Json -Compress | ConvertFrom-Json); $wrongSavedProject.codexProjectId='wrong-project'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-replacement' $wrongSavedProject) conflict 1 'controller-task-state-conflict'
  $controllerReplaced=Mutate $controllerRoot $hash 'record-task-set-replacement' $controllerReplacement; $hash=[string]$controllerReplaced.Result.resultHash
  Assert-True ($controllerReplaced.Result.data.taskSetReset.replacementSetHash -cmatch '^[0-9a-f]{64}$') 'Final controller replacement must persist the deterministic replacement-set hash for runtime prepare'
  $controllerReplacementReplay=Mutate $controllerRoot $hash 'record-task-set-replacement' $controllerReplacement; $hash=[string]$controllerReplacementReplay.Result.resultHash
  $controllerReplacementThird=($controllerReplacement | ConvertTo-Json -Compress | ConvertFrom-Json); $controllerReplacementThird.threadId='controller-third'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-replacement' $controllerReplacementThird) conflict 1 'controller-task-state-conflict'

  $earlyArchive=New-ArchiveEvidencePayload 'project' (New-ArchiveSnapshot 'project-A-old' 'project-A' 'host-1' $projectARoot $preparePayload.targets[1].handoff) '2026-08-13T00:03:40Z'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-archive' $earlyArchive) conflict 1 'controller-task-state-conflict'
  $controllerBootstrap=New-BootstrapEvidencePayload 'controller' $controllerRoot (New-BootstrapProof 'controller-new' 'controller-project' 'host-1' $controllerRoot 'create-controller-new' '2026-08-13T00:03:30Z')
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-bootstrap-proof' $controllerBootstrap) conflict 1 'controller-task-state-conflict'
  foreach($bootstrap in @(
    (New-BootstrapEvidencePayload 'project' $projectARoot (New-BootstrapProof 'project-A-new' 'project-A' 'host-1' $projectARoot 'create-project-A-new' '2026-08-13T00:03:10Z')),
    (New-BootstrapEvidencePayload 'project' $projectBRoot (New-BootstrapProof 'project-B-new' 'project-B' 'host-1' $projectBRoot 'create-project-B-new' '2026-08-13T00:03:20Z'))
  )){$bootstrapApplied=Mutate $controllerRoot $hash 'record-task-set-bootstrap-proof' $bootstrap;$hash=[string]$bootstrapApplied.Result.resultHash}
  $controllerBootstrapApplied=Mutate $controllerRoot $hash 'record-task-set-bootstrap-proof' $controllerBootstrap;$hash=[string]$controllerBootstrapApplied.Result.resultHash

  $replacementSet=@(
    [pscustomobject][ordered]@{ kind='controller'; projectRoot=$controllerRoot; threadId='controller-new'; codexProjectId='controller-project'; hostId='host-1' },
    [pscustomobject][ordered]@{ kind='project'; projectRoot=$projectARoot; threadId='project-A-new'; codexProjectId='project-A'; hostId='host-1' },
    [pscustomobject][ordered]@{ kind='project'; projectRoot=$projectBRoot; threadId='project-B-new'; codexProjectId='project-B'; hostId='host-1' }
  )
  $replacementSetHash=Get-Hash $utf8.GetBytes(($replacementSet | ConvertTo-Json -Depth 6 -Compress))
  $finalController=New-Handoff 'Controller final full handoff' 'c-1' 'c-3' 3 '2026-08-13T00:05:20Z'
  $finalA=New-Handoff 'Project A final full handoff after drift' 'a-1' 'a-3' 3 '2026-08-13T00:05:00Z'
  $finalB=New-Handoff 'Project B final full handoff' 'b-1' 'b-2' 2 '2026-08-13T00:05:10Z'
  $archiveA=New-ArchiveEvidencePayload 'project' (New-ArchiveSnapshot 'project-A-old' 'project-A' 'host-1' $projectARoot $finalA) '2026-08-13T00:04:00Z'
  $fakeArchiveHash=($archiveA | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json); $fakeArchiveHash.snapshotHash='b' * 64
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-archive' $fakeArchiveHash) invalid 2 'controller-payload-invalid'
  $archiveAApplied=Mutate $controllerRoot $hash 'record-task-set-archive' $archiveA; $hash=[string]$archiveAApplied.Result.resultHash
  $archiveAReplay=Mutate $controllerRoot $hash 'record-task-set-archive' $archiveA; $hash=[string]$archiveAReplay.Result.resultHash
  $archiveAThird=($archiveA | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json);$archiveAThird.snapshot.threadId='project-A-third';$archiveAThird.snapshotHash=Get-Hash $utf8.GetBytes(($archiveAThird.snapshot|ConvertTo-Json -Depth 10 -Compress))
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-archive' $archiveAThird) conflict 1 'controller-task-state-conflict'
  $archiveB=New-ArchiveEvidencePayload 'project' (New-ArchiveSnapshot 'project-B-old' 'project-B' 'host-1' $projectBRoot $finalB) '2026-08-13T00:04:10Z'
  $controllerArchive=New-ArchiveEvidencePayload 'controller' (New-ArchiveSnapshot 'controller-old' 'controller-project' 'host-1' $controllerRoot $finalController) '2026-08-13T00:04:20Z'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-archive' $controllerArchive) conflict 1 'controller-task-state-conflict'
  $archiveBApplied=Mutate $controllerRoot $hash 'record-task-set-archive' $archiveB; $hash=[string]$archiveBApplied.Result.resultHash
  $controllerArchived=Mutate $controllerRoot $hash 'record-task-set-archive' $controllerArchive; $hash=[string]$controllerArchived.Result.resultHash
  Assert-True (@($controllerArchived.Result.data.taskSetReset.archives).Count -eq 3 -and $controllerArchived.Result.data.taskSetReset.archives[2].kind -ceq 'controller') 'Controller archive must be recorded only after every project archive'
  $finalTargets=@(
    [pscustomobject][ordered]@{kind='controller';projectRoot=$controllerRoot;handoff=$finalController},
    [pscustomobject][ordered]@{kind='project';projectRoot=$projectARoot;handoff=$finalA},
    [pscustomobject][ordered]@{kind='project';projectRoot=$projectBRoot;handoff=$finalB}
  )
  $finalQuiet=New-ExternalQuiescence '2026-08-13T00:05:30Z' $preparePayload.initialExternalQuiescence.runtimeReadback
  $archives=@($controllerArchived.Result.data.taskSetReset.archives)
  $staleFinal=New-FinalEvidencePayload @(
    [pscustomobject][ordered]@{kind='controller';projectRoot=$controllerRoot;handoff=$preparePayload.targets[0].handoff},
    [pscustomobject][ordered]@{kind='project';projectRoot=$projectARoot;handoff=$preparePayload.targets[1].handoff},
    [pscustomobject][ordered]@{kind='project';projectRoot=$projectBRoot;handoff=$preparePayload.targets[2].handoff}
  ) @() $finalQuiet $archives '2026-08-13T00:06:00Z'
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-final-evidence' $staleFinal) conflict 1 'controller-task-state-conflict'
  $finalEvidence=New-FinalEvidencePayload $finalTargets @() $finalQuiet $archives '2026-08-13T00:06:00Z'
  $finalized=Mutate $controllerRoot $hash 'record-task-set-final-evidence' $finalEvidence;$hash=[string]$finalized.Result.resultHash
  $finalReplay=Mutate $controllerRoot $hash 'record-task-set-final-evidence' $finalEvidence;$hash=[string]$finalReplay.Result.resultHash
  $finalThird=$finalEvidence|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  $finalThird.targets[1].handoff.summary='Project A conflicting full handoff';$finalThird.targets[1].handoff.summaryHash=Get-Hash $utf8.GetBytes($finalThird.targets[1].handoff.summary)
  $finalThird.finalEvidenceHash=Get-TaskSetEvidenceHash $finalThird.targets $finalThird.activeChains $finalThird.externalQuiescence $finalThird.archives
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-final-evidence' $finalThird) conflict 1 'controller-task-state-conflict'

  $controllerStandby=New-StandbyEvidencePayload 'controller' $controllerRoot (New-StandbyProof 'controller-new' 'controller-project' 'host-1' $controllerRoot $finalController '2026-08-13T00:06:30Z')
  Assert-State (Prepare $controllerRoot $hash 'record-task-set-standby-proof' $controllerStandby) conflict 1 'controller-task-state-conflict'
  foreach($projectStandby in @(
    (New-StandbyEvidencePayload 'project' $projectARoot (New-StandbyProof 'project-A-new' 'project-A' 'host-1' $projectARoot $finalA '2026-08-13T00:06:10Z')),
    (New-StandbyEvidencePayload 'project' $projectBRoot (New-StandbyProof 'project-B-new' 'project-B' 'host-1' $projectBRoot $finalB '2026-08-13T00:06:20Z'))
  )){$standbyApplied=Mutate $controllerRoot $hash 'record-task-set-standby-proof' $projectStandby;$hash=[string]$standbyApplied.Result.resultHash}
  $controllerStandbyApplied=Mutate $controllerRoot $hash 'record-task-set-standby-proof' $controllerStandby;$hash=[string]$controllerStandbyApplied.Result.resultHash

  $manifestPreparedHash=$hash;$runtimePrepareToken='3'*64
  $runtimePrepared=New-RuntimeEvidencePayload (New-RuntimeReadback $controllerRoot 'prepared' $replacementSetHash $manifestPreparedHash $runtimePrepareToken $null '2026-08-13T00:07:00Z' $null $preparePayload.planHash $preparePayload.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash)
  $runtimePreparedResult=Mutate $controllerRoot $hash 'record-task-set-runtime-prepared' $runtimePrepared;$hash=[string]$runtimePreparedResult.Result.resultHash
  $runtimePreparedReplay=Mutate $controllerRoot $hash 'record-task-set-runtime-prepared' $runtimePrepared;$hash=[string]$runtimePreparedReplay.Result.resultHash
  $switch=[ordered]@{operationId='reset-op-1';replacementSetHash=$replacementSetHash;runtimePrepareToken=$runtimePrepareToken;switchedAt='2026-08-13T00:08:00Z'}
  $switchPrepared=Prepare $controllerRoot $hash 'switch-task-set' $switch;Assert-State $switchPrepared prepared 0 'controller-candidate-prepared'
  $unchanged=Invoke-State Read $controllerRoot;Assert-True ($unchanged.Result.data.controllerBinding.threadId-ceq'controller-old') 'Switch prepare must be atomic'
  $switchApplied=Invoke-State ApplyCandidate $controllerRoot $hash '' $null $switchPrepared.Result.candidatePath $switchPrepared.Result.candidateHash;Assert-State $switchApplied applied 0 'controller-state-applied';$hash=[string]$switchApplied.Result.resultHash
  Assert-True ($switchApplied.Result.data.taskSetId-ceq$preparePayload.toTaskSetId-and$switchApplied.Result.data.controllerBinding.threadId-ceq'controller-new') 'Switch must atomically install exact derived task set'
  $switchReplay=Mutate $controllerRoot $hash 'switch-task-set' $switch;$hash=[string]$switchReplay.Result.resultHash
  $runtimeCommit=New-RuntimeEvidencePayload (New-RuntimeReadback $controllerRoot 'committed' $replacementSetHash $manifestPreparedHash $runtimePrepareToken $hash '2026-08-13T00:07:00Z' '2026-08-13T00:09:00Z' $preparePayload.planHash $preparePayload.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash)
  $runtimeCommitted=Mutate $controllerRoot $hash 'record-task-set-runtime-committed' $runtimeCommit;$hash=[string]$runtimeCommitted.Result.resultHash
  $runtimeCommitReplay=Mutate $controllerRoot $hash 'record-task-set-runtime-committed' $runtimeCommit;$hash=[string]$runtimeCommitReplay.Result.resultHash
  $complete=[ordered]@{operationId='reset-op-1';completedAt='2026-08-13T00:10:00Z'}
  $completed=Mutate $controllerRoot $hash 'complete-task-set-reset' $complete;$hash=[string]$completed.Result.resultHash
  Assert-True ($null-eq$completed.Result.data.taskSetReset) 'Completion must seal the full reset outside the live manifest and clear the active slot'
  $sealPath=Join-Path $controllerRoot 'state\.task-set-reset-seal.json'
  Assert-True (Test-Path -LiteralPath $sealPath -PathType Leaf) 'Completion must retain the reset seal until the runtime fence confirms the exact final manifest hash'
  Assert-State (Invoke-State Read $controllerRoot) conflict 1 'controller-task-set-reset-seal-recovery-required'
  Assert-State (Invoke-State RecoverTaskSetResetSeal $controllerRoot) applied 0 'controller-task-set-reset-seal-runtime-pending'
  Assert-True (Test-Path -LiteralPath $sealPath -PathType Leaf) 'Storage recovery without runtime evidence must retain the reset seal'
  $completedFence=New-CompletedFenceReadback $controllerRoot $preparePayload.planHash $preparePayload.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash $hash
  $sealRecovery=[pscustomobject][ordered]@{runtimeReadback=$completedFence;runtimeReadbackHash=(Get-Hash $utf8.GetBytes(($completedFence|ConvertTo-Json -Depth 20 -Compress)))}
  $recovered=Invoke-State RecoverTaskSetResetSeal $controllerRoot '' '' $sealRecovery
  Assert-State $recovered applied 0 'controller-task-set-reset-seal-recovered'
  Assert-True (-not(Test-Path -LiteralPath $sealPath)) 'Verified runtime completion must remove the final reset seal'
  $history=Invoke-State ReadTaskSetResetHistory $controllerRoot
  Assert-State $history verified 0 'controller-task-set-reset-history-read'
  Assert-True ($history.Result.data.count-eq1-and$history.Result.data.items[0].operationId-ceq'reset-op-1') 'Sealed history must retain the completed operation'
  $completeReplay=Mutate $controllerRoot $hash 'complete-task-set-reset' $complete;$hash=[string]$completeReplay.Result.resultHash
  $completeThird=$complete|ConvertTo-Json -Compress|ConvertFrom-Json;$completeThird.completedAt='2026-08-13T00:10:01Z'
  Assert-State (Prepare $controllerRoot $hash 'complete-task-set-reset' $completeThird) conflict 1 'controller-task-state-conflict'

  $secondReset=Complete-SecondReset $controllerRoot $projectARoot $projectBRoot $hash $preparePayload.toTaskSetId;$hash=[string]$secondReset.Hash
  $history=Invoke-State ReadTaskSetResetHistory $controllerRoot
  Assert-State $history verified 0 'controller-task-set-reset-history-read'
  Assert-True ($history.Result.data.count-eq2-and$history.Result.data.items[0].operationId-ceq'reset-op-1'-and$history.Result.data.items[1].operationId-ceq'reset-op-2') 'Two completed resets must be sealed in immutable order before reuse is attempted'

  $reusePlan=$secondReset.Plan|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
  $reusePlan.operationId='reset-op-1';$reusePlan.fromTaskSetId=$secondReset.Plan.toTaskSetId;$reusePlan.toTaskSetId=Get-TaskSetId $controllerRoot $reusePlan.fromTaskSetId $reusePlan.operationId
  $reusePlan.expectedController.threadId='controller-next'
  $reusePlan.expectedProjectBindings[0].entryThreadId='project-A-next';$reusePlan.expectedProjectBindings[1].entryThreadId='project-B-next'
  $reusePlan.targets[0].creationOperationId='create-controller-reused';$reusePlan.targets[1].creationOperationId='create-project-A-reused';$reusePlan.targets[2].creationOperationId='create-project-B-reused'
  $reusePrepare=$reusePlan|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;$reusePlanHash=Get-TaskSetPlanHash $reusePlan
  Add-Member -InputObject $reusePrepare -NotePropertyName planHash -NotePropertyValue $reusePlanHash
  $reuseSummaries=@('Controller reused operation handoff','Project A reused operation handoff','Project B reused operation handoff')
  for($index=0;$index-lt$reusePrepare.targets.Count;$index++){
    Add-Member -InputObject $reusePrepare.targets[$index] -NotePropertyName handoff -NotePropertyValue (New-Handoff $reuseSummaries[$index] @('c-5','a-5','b-5')[$index] @('c-6','a-6','b-6')[$index] 2 '2026-08-15T00:00:20Z')
  }
  $reuseRuntime=[pscustomobject][ordered]@{
    state='controller-replacement-read';controllerRoot=$controllerRoot;controllerThreadId='controller-next';hostId='host-1';replacementState='legacy'
    operationId='reset-op-2';replacementSetHash=$null;oldControllerThreadId='controller-new';oldHostId='host-1';newControllerThreadId='controller-next';newHostId='host-1'
    manifestPreparedHash=$null;prepareToken=$null;manifestSwitchedHash=$null;preparedAt=$null;committedAt='2026-08-14T00:09:00Z'
    activeDispatchCount=0;unacknowledgedReceiptCount=0
    fenceState='prepared';fenceOperationId='reset-op-1';fencePlanHash=$reusePlanHash;fenceManifestExpectedHash=$hash;fencePreparedAt='2026-08-15T00:00:25Z';fenceCompletedManifestHash=$null;fenceCompletedAt=$null
    wakeWorkerState='none';wakeWorkerOperationId=$null;wakeWorkerThreadId=$null;wakeWorkerClientThreadId=$null
    wakeAutomationState='none';wakeAutomationOperationId=$null;wakeAutomationId=$null
  }
  Add-Member -InputObject $reusePrepare -NotePropertyName initialActiveChains -NotePropertyValue @()
  Add-Member -InputObject $reusePrepare -NotePropertyName initialExternalQuiescence -NotePropertyValue (New-ExternalQuiescence '2026-08-15T00:00:30Z' $reuseRuntime)
  Add-Member -InputObject $reusePrepare -NotePropertyName initialEvidenceHash -NotePropertyValue (Get-TaskSetEvidenceHash $reusePrepare.targets @() $reusePrepare.initialExternalQuiescence @())
  Add-Member -InputObject $reusePrepare -NotePropertyName preparedAt -NotePropertyValue '2026-08-15T00:01:00Z'

  $manifestPath=Join-Path $controllerRoot '.codex-controller.json';$historyPath=Join-Path $controllerRoot 'state\task-set-reset-history.jsonl'
  $manifestBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath));$historyBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($historyPath))
  $candidatesBefore=@(Get-ChildItem -LiteralPath $controllerRoot -Force|Where-Object{$_.Name-cmatch'^\.codex-controller\.[0-9a-f]{32}\.tmp$'}|Sort-Object Name|ForEach-Object{[pscustomobject][ordered]@{name=$_.Name;bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))}})|ConvertTo-Json -Depth 3 -Compress
  $treeBefore=Get-TreeFingerprint $controllerRoot
  $reusePlanCall=Invoke-State PlanTaskSetReset $controllerRoot '' '' $reusePlan
  $reusePrepareCall=Prepare $controllerRoot $hash 'prepare-task-set-reset' $reusePrepare
  Assert-True ($reusePlanCall.ExitCode-eq1-and$reusePlanCall.Result.status-ceq'conflict'-and$reusePlanCall.Result.reasonCode-ceq'controller-task-state-conflict'-and$reusePrepareCall.ExitCode-eq1-and$reusePrepareCall.Result.status-ceq'conflict'-and$reusePrepareCall.Result.reasonCode-ceq'controller-task-state-conflict') "Historical operationId reuse must reject Plan and Prepare before writes; got Plan $($reusePlanCall.Result.status)/$($reusePlanCall.Result.reasonCode) exit $($reusePlanCall.ExitCode), Prepare $($reusePrepareCall.Result.status)/$($reusePrepareCall.Result.reasonCode) exit $($reusePrepareCall.ExitCode)"
  $scenarioCount+=2
  $candidatesAfter=@(Get-ChildItem -LiteralPath $controllerRoot -Force|Where-Object{$_.Name-cmatch'^\.codex-controller\.[0-9a-f]{32}\.tmp$'}|Sort-Object Name|ForEach-Object{[pscustomobject][ordered]@{name=$_.Name;bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))}})|ConvertTo-Json -Depth 3 -Compress
  Assert-True ((Get-TreeFingerprint $controllerRoot)-ceq$treeBefore) 'Historical operationId rejection must leave the complete controller state tree byte-identical'
  Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))-ceq$manifestBefore) 'Historical operationId rejection must not change manifest bytes'
  Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($historyPath))-ceq$historyBefore) 'Historical operationId rejection must not change immutable history bytes'
  Assert-True ($candidatesAfter-ceq$candidatesBefore) 'Historical operationId rejection must not create or change candidate bytes'

  $extraRoot=Join-Path $testRoot 'post-reset-extra';[IO.Directory]::CreateDirectory($extraRoot)|Out-Null
  Assert-State (Prepare $controllerRoot $hash 'register-project' ([ordered]@{entryThreadId='extra-task';codexProjectId='extra-project';hostId='host-1';projectRoot=$extraRoot})) prepared 0 'controller-candidate-prepared'

  Write-Output "PASS task-set-reset closed-state-machine ($scenarioCount checks)"
}
finally {
  if($KeepTestRoot){Write-Output "KEPT $testRoot"}elseif (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
