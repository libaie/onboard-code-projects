[CmdletBinding()]
param([string]$SubjectPath = '')

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$subject = if ([string]::IsNullOrWhiteSpace($SubjectPath)) { Join-Path $skillRoot 'templates\controller\tools\chain-store.ps1' } else { [IO.Path]::GetFullPath($SubjectPath) }
if (-not (Test-Path -LiteralPath $subject -PathType Leaf)) { throw "Subject does not exist: $subject" }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$passed = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Pass {
  param([string]$Message)
  $script:passed++
  [Console]::Out.WriteLine("PASS $Message")
}

function Invoke-Store {
  param(
    [string]$Action,
    [string]$Root,
    [string]$ChainId = '',
    [string]$CandidatePath = '',
    [string]$ExpectedEntryHash = '',
    [bool]$ConfirmTerminal = $false,
    [string]$LedgerPath = '',
    [string]$ArchiveRoot = '',
    [string]$MigrationPath = '',
    [string]$ExpectedSourceHash = '',
    [bool]$ConfirmMigration = $false,
    [string]$GoalLineageId = ''
  )
  $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$subject,'-Action',$Action,'-ControllerRoot',$Root)
  foreach ($pair in @(
    [pscustomobject]@{Name='ChainId';Value=$ChainId},
    [pscustomobject]@{Name='CandidatePath';Value=$CandidatePath},
    [pscustomobject]@{Name='ExpectedEntryHash';Value=$ExpectedEntryHash},
    [pscustomobject]@{Name='LedgerPath';Value=$LedgerPath},
    [pscustomobject]@{Name='ArchiveRoot';Value=$ArchiveRoot},
    [pscustomobject]@{Name='MigrationPath';Value=$MigrationPath},
    [pscustomobject]@{Name='ExpectedSourceHash';Value=$ExpectedSourceHash},
    [pscustomobject]@{Name='GoalLineageId';Value=$GoalLineageId}
  )) {
    if (-not [string]::IsNullOrEmpty($pair.Value)) {
      $arguments += ('-' + $pair.Name)
      $arguments += [string]$pair.Value
    }
  }
  if ($ConfirmTerminal) { $arguments += '-ConfirmTerminal' }
  if ($ConfirmMigration) { $arguments += '-ConfirmMigration' }
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = ($arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::Start($startInfo)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw "$Action timed out" }
    $out = $stdout.GetAwaiter().GetResult().Trim()
    $err = $stderr.GetAwaiter().GetResult().Trim()
    $exit = $process.ExitCode
  }
  finally { $process.Dispose() }
  try { $results = @($out | ConvertFrom-Json -ErrorAction Stop) }
  catch { throw "$Action must return one JSON result; exit=$exit stdout=$out stderr=$err" }
  if ($results.Count -ne 1) { throw "$Action must return exactly one JSON result; count=$($results.Count) stdout=$out stderr=$err" }
  $result = $results[0]
  if ($null -eq $result) { throw "$Action returned a null JSON result; stdout=$out stderr=$err" }
  $propertyNames = @($result | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
  foreach ($field in @('schemaVersion','action','status','reasonCode','controllerRoot','chainId','currentEntryHash','resultEntryHash','sourceHash','data','nextAction','warnings')) {
    Assert-True ($propertyNames -ccontains $field) "$Action result missing $field"
  }
  Assert-True ($propertyNames.Count -eq 12) "$Action result must be closed"
  return [pscustomobject]@{Result=$result;ExitCode=$exit;Error=$err}
}

function Invoke-DefaultStoreRead {
  param([string]$ScriptPath, [string]$WorkingDirectory)
  $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath -Action Read 2>&1
  $exit = $LASTEXITCODE
  try { $result = ($out -join "`n") | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Default Read must return JSON; exit=$exit output=$($out -join ' ')" }
  return [pscustomobject]@{ Result=$result; ExitCode=$exit }
}

function Assert-Result {
  param($Call, [int]$ExitCode, [string]$Status, [string]$Reason)
  Assert-True ($Call.ExitCode -eq $ExitCode) "Expected exit $ExitCode, got $($Call.ExitCode): $($Call.Result.status)/$($Call.Result.reasonCode) $($Call.Result.nextAction) stderr=$($Call.Error)"
  Assert-True ($Call.Result.status -ceq $Status) "Expected status $Status, got $($Call.Result.status)"
  Assert-True ($Call.Result.reasonCode -ceq $Reason) "Expected reason $Reason, got $($Call.Result.reasonCode): $($Call.Result.nextAction)"
}

function Write-Json {
  param([string]$Path, $Object)
  [IO.File]::WriteAllText($Path, (($Object | ConvertTo-Json -Depth 30 -Compress) + "`n"), $utf8)
}

function Get-TestHash {
  param([string]$Text)
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}
  finally{$sha.Dispose()}
}

function New-Record {
  param([string]$Id, [string]$State = 'active', [string]$Status = 'running', [string]$Objective = 'Verify the controller memory store')
  $updated = if ($State -ceq 'terminal') { '2099-01-01T11:00:00+08:00' } else { '2099-01-01T10:00:00+08:00' }
  $phase = if ($State -ceq 'terminal') { 'closed' } else { 'execution' }
  $nextAction = if ($State -ceq 'terminal') { 'N/A' } else { 'Collect evidence' }
  return [pscustomobject][ordered]@{
    schemaVersion=1; chainId=$Id; state=$State; phase=$phase; status=$Status
    createdAt='2099-01-01T09:00:00+08:00'; updatedAt=$updated; objective=$Objective
    nextAction=$nextAction
    payload=[pscustomobject][ordered]@{ id=$Id; phase=$phase; status=$Status; createdAt='2099-01-01T09:00:00+08:00'; updatedAt=$updated; goal=$Objective; nextAction=$nextAction; history=@() }
  }
}

function New-GoalRecord {
  param([string]$Id, [string[]]$ProjectRoots)
  $lanes = @($ProjectRoots | ForEach-Object {
    [pscustomobject][ordered]@{ projectRoot=$_; attemptsUsed=0; transientRetriesUsed=0; activeReservation=$null; outcomes=@() }
  })
  return [pscustomobject][ordered]@{
    schemaVersion=1; goalLineageId=$Id; objectiveFingerprint=(Get-TestHash $Id); state='active'
    createdAt='2099-01-01T09:00:00Z'; updatedAt='2099-01-01T09:00:00Z'
    budget=[pscustomobject][ordered]@{ readinessReplansUsed=0; crossProjectRebaselinesUsed=0 }
    readinessFailures=@(); lanes=@($lanes)
  }
}

function Copy-JsonObject {
  param($Value)
  return (($Value | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
}

function New-GoalReservation {
  param(
    [string]$ReservationId,
    [string]$ChainId,
    [string]$DispatchId,
    [string]$Strategy = 'initial',
    [int]$AttemptNumber = 1,
    [int]$RetryOrdinal = 0,
    [string]$ProblemInvariantId = 'problem.invite-binding',
    [string]$StrategyFamilyId = 'strategy.complete-contract-fix',
    [string]$ExecutionFingerprint = ('8' * 64),
    [string]$RelevantContentHash = ('9' * 64),
    [string]$ReservedAt = '2099-01-01T09:01:00Z'
  )
  $preconditions = [pscustomobject][ordered]@{
    contractVersionHash=('a' * 64); targetSetHash=('b' * 64); capabilitySetHash=('c' * 64)
    runtimeVersionHash=('d' * 64); toolchainVersionHash=('e' * 64); authorizationBoundaryHash=('f' * 64)
    failureOracleHash=('0' * 64); relevantContentHash=$RelevantContentHash
  }
  $preconditionHash = if ($RelevantContentHash -ceq ('9' * 64)) {
    '0599d8823377d0f42e5e4c2693d5db0e577f223cdca0898a3147080a791d000e'
  }
  elseif ($RelevantContentHash -ceq ('7' * 64)) {
    '7521023c8ce73b9846f1494db4178c21b268974b77fdbcc19268854e61a70392'
  }
  else { throw 'Test fixture requires a hand-derived material-precondition hash' }
  $coverage = @(
    [pscustomobject][ordered]@{ acceptanceId=('1' * 64); operationId='op-read'; operationClass='read'; targets=@('repo:A'); capabilityRefs=@(); authorizationRef='N/A'; verification=@('verify-read'); rollback=@() },
    [pscustomobject][ordered]@{ acceptanceId=('2' * 64); operationId='op-write'; operationClass='repository-write'; targets=@('repo:A'); capabilityRefs=@(); authorizationRef='authref:test'; verification=@('verify-write'); rollback=@('revert') }
  )
  return [pscustomobject][ordered]@{
    reservationId=$ReservationId; chainId=$ChainId; dispatchId=$DispatchId
    problemInvariantId=$ProblemInvariantId; strategyFamilyId=$StrategyFamilyId; strategy=$Strategy
    attemptNumber=$AttemptNumber; retryOrdinal=$RetryOrdinal; executionFingerprint=$ExecutionFingerprint
    acceptanceIds=@(('1' * 64),('2' * 64)); acceptanceHash='055373d2d5916d7245990454c54ab62817bf787538ca4475c73a310b556aabef'
    materialPreconditions=$preconditions; materialPreconditionHash=$preconditionHash
    operationCoverage=$coverage; operationCoverageHash='0387e5700154e5ffd75738b90903a8cefd835922132d097a6146b69dcdac78e2'
    controllerRuntimeHash=('d' * 64); capabilityBundleHash=('c' * 64); reservedAt=$ReservedAt
  }
}

function Complete-GoalReservation {
  param($Goal, [int]$LaneIndex, [string]$Outcome, [string]$FailureClass, [string]$EvidenceHash, [string]$FinishedAt)
  $reservation = $Goal.lanes[$LaneIndex].activeReservation
  $Goal.lanes[$LaneIndex].outcomes = @($Goal.lanes[$LaneIndex].outcomes) + @([pscustomobject][ordered]@{
    reservation=$reservation; outcome=$Outcome; failureClass=$FailureClass; evidenceHash=$EvidenceHash; finishedAt=$FinishedAt
  })
  $Goal.lanes[$LaneIndex].activeReservation = $null
  $Goal.updatedAt = $FinishedAt
}

if (-not (Test-Path -LiteralPath $subject -PathType Leaf)) { throw "RED: missing chain store tool $subject" }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('chain-store-tests-' + [guid]::NewGuid().ToString('N'))

try {
  [IO.Directory]::CreateDirectory($testRoot) | Out-Null
  $root = Join-Path $testRoot 'controller'
  [IO.Directory]::CreateDirectory($root) | Out-Null

  $init = Invoke-Store Initialize $root
  Assert-Result $init 0 initialized 'store-initialized'
  foreach ($relative in @('.chain-store.json','state\index.json','state\experience-index.json','memory\MEMORY.md','TASKS.md')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "Initialize missing $relative"
  }
  Assert-True (Test-Path -LiteralPath (Join-Path $root 'state\goals') -PathType Container) 'Initialize missing state\goals'
  Pass 'initialize creates only the bounded store scaffold'

  $read = Invoke-Store Read $root
  Assert-Result $read 0 verified 'store-read'
  Assert-True ($read.Result.data.activeCount -eq 0 -and $read.Result.data.terminalCount -eq 0) 'New store must be empty'
  Pass 'read returns an empty derived index'

  $goalId = 'GOAL-20990101-invite-flow'
  $goalCandidate = Join-Path $root 'goal-candidate.json'
  $goal = New-GoalRecord $goalId @('C:\projects\alpha','C:\projects\beta','C:\projects\gamma')
  Write-Json $goalCandidate $goal
  $goalCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash MISSING -GoalLineageId $goalId
  Assert-Result $goalCreated 0 applied 'goal-created'
  $duplicateGoalId = 'GOAL-20990101-invite-flow-renamed'
  $duplicateGoal = New-GoalRecord $duplicateGoalId @('C:\projects\alpha','C:\projects\beta','C:\projects\gamma')
  $duplicateGoal.objectiveFingerprint = $goal.objectiveFingerprint
  $duplicateGoalCandidate = Join-Path $root 'duplicate-goal-candidate.json'
  Write-Json $duplicateGoalCandidate $duplicateGoal
  $duplicateGoalRejected = Invoke-Store -Action GoalPut -Root $root -CandidatePath $duplicateGoalCandidate -ExpectedEntryHash MISSING -GoalLineageId $duplicateGoalId
  Assert-Result $duplicateGoalRejected 1 conflict 'goal-objective-exists'
  Pass 'renaming a goal lineage cannot reset an existing objective budget'
  $goalRead = Invoke-Store -Action GoalGet -Root $root -GoalLineageId $goalId
  Assert-Result $goalRead 0 verified 'goal-read'
  Assert-True ($goalRead.Result.data.record.goalLineageId -ceq $goalId -and @($goalRead.Result.data.record.lanes).Count -eq 3) 'GoalGet must return the exact bounded lineage'
  Pass 'goal lineage is canonical and independently readable'

  $goal = Copy-JsonObject $goalRead.Result.data.record
  $goal.lanes[0].attemptsUsed = 1
  $goal.lanes[0].activeReservation = New-GoalReservation 'reservation-alpha-1' 'CHAIN-20990101-A' 'dispatch-alpha-1'
  $goal.updatedAt = '2099-01-01T09:01:00Z'
  Write-Json $goalCandidate $goal
  $reserved = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $goalCreated.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $reserved 0 applied 'goal-updated'
  Assert-True ($reserved.Result.data.record.lanes[0].attemptsUsed -eq 1 -and $reserved.Result.data.record.lanes[1].attemptsUsed -eq 0) 'A reservation must charge only its project lane'
  Pass 'project-lane budgets are isolated'

  $goal = Copy-JsonObject $reserved.Result.data.record
  Complete-GoalReservation $goal 0 'deterministic-failure' 'contract' ('4' * 64) '2099-01-01T09:02:00Z'
  Write-Json $goalCandidate $goal
  $failed = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $reserved.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $failed 0 applied 'goal-updated'
  $experience = Invoke-Store -Action ExperienceRead -Root $root
  Assert-Result $experience 0 verified 'experience-read'
  $hardFailures = @($experience.Result.data.entries | Where-Object { $_.outcome -ceq 'deterministic-failure' })
  Assert-True ($hardFailures.Count -eq 1 -and $hardFailures[0].sourceReservationId -ceq 'reservation-alpha-1') 'Only verified deterministic failure should enter the hard experience index'
  Pass 'deterministic failure is indexed with canonical evidence'

  $renamedProblem = Copy-JsonObject $failed.Result.data.record
  $renamedProblem.lanes[0].attemptsUsed = 2
  $renamedProblem.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-alpha-2-renamed' -ChainId 'CHAIN-20990101-A2' -DispatchId 'dispatch-alpha-2-renamed' -ProblemInvariantId 'problem.invite-binding-renamed' -Strategy repair -AttemptNumber 2 -ReservedAt '2099-01-01T09:03:00Z'
  $renamedProblem.updatedAt = '2099-01-01T09:03:00Z'
  Write-Json $goalCandidate $renamedProblem
  $renamedProblemRejected = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $failed.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $renamedProblemRejected 2 invalid 'goal-transition-invalid'
  Pass 'a successor attempt cannot rename its problem invariant'

  $sameFailure = Copy-JsonObject $failed.Result.data.record
  $sameFailure.lanes[0].attemptsUsed = 2
  $sameFailure.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-alpha-2-head-only' -ChainId 'CHAIN-20990101-A2' -DispatchId 'dispatch-alpha-2-head-only' -Strategy repair -AttemptNumber 2 -ExecutionFingerprint ('7' * 64) -ReservedAt '2099-01-01T09:03:00Z'
  $sameFailure.updatedAt = '2099-01-01T09:03:00Z'
  Write-Json $goalCandidate $sameFailure
  $headBypass = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $failed.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $headBypass 1 conflict 'goal-known-deterministic-failure'
  Pass 'HEAD-only execution changes cannot bypass a known failed strategy family'

  $materialEvidenceChainId = 'CHAIN-20990101-material-evidence'
  $materialEvidenceCandidate = Join-Path $root 'material-evidence.json'
  $materialEvidenceHash = ('6' * 64)
  $materialEvidenceRecord = New-Record $materialEvidenceChainId
  $materialEvidenceRecord.payload.history = @([pscustomobject][ordered]@{ field='relevantContentHash'; previousHash=('9' * 64); currentHash=('7' * 64); evidenceHash=$materialEvidenceHash; at='2099-01-01T09:00:30Z'; reason='relevant content changed' })
  Write-Json $materialEvidenceCandidate $materialEvidenceRecord
  $materialEvidenceCreated = Invoke-Store -Action Put -Root $root -ChainId $materialEvidenceChainId -CandidatePath $materialEvidenceCandidate -ExpectedEntryHash MISSING
  $materialEvidenceRecord = New-Record $materialEvidenceChainId terminal completed
  Write-Json $materialEvidenceCandidate $materialEvidenceRecord
  $materialEvidenceClosed = Invoke-Store -Action Put -Root $root -ChainId $materialEvidenceChainId -CandidatePath $materialEvidenceCandidate -ExpectedEntryHash $materialEvidenceCreated.Result.resultEntryHash -ConfirmTerminal $true
  $materialEvidenceEvent = ([IO.File]::ReadAllText([string]$materialEvidenceClosed.Result.data.path, $utf8).TrimEnd("`n").Split("`n")[0] | ConvertFrom-Json)

  $changedMaterial = Copy-JsonObject $failed.Result.data.record
  $changedMaterial.lanes[0].attemptsUsed = 2
  $changedMaterial.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-alpha-2-material' -ChainId 'CHAIN-20990101-A2' -DispatchId 'dispatch-alpha-2-material' -Strategy repair -AttemptNumber 2 -ExecutionFingerprint ('7' * 64) -RelevantContentHash ('7' * 64) -ReservedAt '2099-01-01T09:03:00Z'
  $changedMaterial.updatedAt = '2099-01-01T09:03:00Z'
  Write-Json $goalCandidate $changedMaterial
  $unprovedMaterialRetry = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $failed.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $unprovedMaterialRetry 2 invalid 'goal-transition-invalid'
  Add-Member -InputObject $changedMaterial.lanes[0].activeReservation -NotePropertyName materialChangeEvidence -NotePropertyValue @(
    [pscustomobject][ordered]@{
      field='relevantContentHash'; previousHash=('9' * 64); currentHash=('7' * 64)
      sourceChainId=$materialEvidenceChainId; sourceEntryHash=[string]$materialEvidenceEvent.entryHash; evidenceHash=$materialEvidenceHash; observedAt='2099-01-01T09:00:30Z'
    }
  )
  Write-Json $goalCandidate $changedMaterial
  $materialRetry = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $failed.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $materialRetry 0 applied 'goal-updated'
  Pass 'each material change requires direct field-bound evidence'

  $cancelGoal = Copy-JsonObject $materialRetry.Result.data.record
  $cancelGoal.lanes[1].attemptsUsed = 1
  $cancelGoal.lanes[1].activeReservation = New-GoalReservation -ReservationId 'reservation-beta-1' -ChainId 'CHAIN-20990101-B' -DispatchId 'dispatch-beta-1' -ProblemInvariantId 'problem.cancel-case' -StrategyFamilyId 'strategy.cancel-case' -ReservedAt '2099-01-01T09:04:00Z'
  $cancelGoal.updatedAt = '2099-01-01T09:04:00Z'
  Write-Json $goalCandidate $cancelGoal
  $cancelReserved = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $materialRetry.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $cancelReserved 0 applied 'goal-updated'
  $cancelGoal = Copy-JsonObject $cancelReserved.Result.data.record
  Complete-GoalReservation $cancelGoal 1 'cancelled' 'N/A' ('5' * 64) '2099-01-01T09:05:00Z'
  Write-Json $goalCandidate $cancelGoal
  $cancelled = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $cancelReserved.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $cancelled 0 applied 'goal-updated'
  $afterCancelExperience = Invoke-Store -Action ExperienceRead -Root $root
  Assert-True (@($afterCancelExperience.Result.data.entries | Where-Object { $_.problemInvariantId -ceq 'problem.cancel-case' }).Count -eq 0) 'Cancellation must not poison hard experience'
  Pass 'cancelled and superseded work is not blacklisted'

  $duplicateTransientReservation = Copy-JsonObject $cancelled.Result.data.record
  $duplicateTransientReservation.lanes[2].transientRetriesUsed = 1
  $duplicateTransientReservation.lanes[2].activeReservation = New-GoalReservation -ReservationId 'reservation-gamma-retry' -ChainId 'CHAIN-20990101-C' -DispatchId 'dispatch-gamma-retry' -ProblemInvariantId 'problem.transient-case' -StrategyFamilyId 'strategy.transient-case' -RetryOrdinal 1 -ReservedAt '2099-01-01T09:06:00Z'
  $duplicateTransientReservation.updatedAt = '2099-01-01T09:06:00Z'
  Write-Json $goalCandidate $duplicateTransientReservation
  $duplicateTransientRejected = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $cancelled.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $duplicateTransientRejected 2 invalid 'goal-record-invalid'
  Pass 'transient preflight replay cannot create a second goal reservation'

  $badCoverageGoal = Copy-JsonObject $cancelled.Result.data.record
  $badCoverageGoal.lanes[1].attemptsUsed = 2
  $badCoverageGoal.lanes[1].activeReservation = New-GoalReservation -ReservationId 'reservation-beta-bad-coverage' -ChainId 'CHAIN-20990101-B2' -DispatchId 'dispatch-beta-bad-coverage' -Strategy repair -AttemptNumber 2 -ProblemInvariantId 'problem.coverage-case' -StrategyFamilyId 'strategy.coverage-case' -ReservedAt '2099-01-01T09:09:00Z'
  $badCoverageGoal.lanes[1].activeReservation.operationCoverage = @($badCoverageGoal.lanes[1].activeReservation.operationCoverage | Select-Object -First 1)
  $badCoverageGoal.updatedAt = '2099-01-01T09:09:00Z'
  Write-Json $goalCandidate $badCoverageGoal
  $coverageRejected = Invoke-Store -Action GoalPut -Root $root -CandidatePath $goalCandidate -ExpectedEntryHash $cancelled.Result.resultEntryHash -GoalLineageId $goalId
  Assert-Result $coverageRejected 2 invalid 'goal-record-invalid'
  Pass 'readiness cannot be ready when an acceptance has no declared operation'

  $readinessId = 'GOAL-20990101-readiness-budget'
  $readinessCandidate = Join-Path $root 'readiness-goal-candidate.json'
  $readinessGoal = New-GoalRecord $readinessId @('C:\projects\readiness')
  Write-Json $readinessCandidate $readinessGoal
  $readinessCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $readinessCandidate -ExpectedEntryHash MISSING -GoalLineageId $readinessId
  Assert-Result $readinessCreated 0 applied 'goal-created'
  $readinessGoal.budget.readinessReplansUsed = 1
  $readinessGoal.readinessFailures = @([pscustomobject][ordered]@{ projectRoot='C:\projects\readiness'; chainId='CHAIN-readiness-1'; dispatchId='dispatch-readiness-1'; failureClass='controller-readiness-failed'; evidenceHash=('a' * 64); occurredAt='2099-01-01T09:01:00Z' })
  $readinessGoal.updatedAt = '2099-01-01T09:01:00Z'
  Write-Json $readinessCandidate $readinessGoal
  $readinessReplanned = Invoke-Store -Action GoalPut -Root $root -CandidatePath $readinessCandidate -ExpectedEntryHash $readinessCreated.Result.resultEntryHash -GoalLineageId $readinessId
  Assert-Result $readinessReplanned 0 applied 'goal-updated'
  $readinessGoal = Copy-JsonObject $readinessReplanned.Result.data.record
  $readinessGoal.readinessFailures = @($readinessGoal.readinessFailures) + @([pscustomobject][ordered]@{ projectRoot='C:\projects\readiness'; chainId='CHAIN-readiness-2'; dispatchId='dispatch-readiness-2'; failureClass='controller-readiness-failed'; evidenceHash=('b' * 64); occurredAt='2099-01-01T09:02:00Z' })
  $readinessGoal.updatedAt = '2099-01-01T09:02:00Z'
  Write-Json $readinessCandidate $readinessGoal
  $readinessExhausted = Invoke-Store -Action GoalPut -Root $root -CandidatePath $readinessCandidate -ExpectedEntryHash $readinessReplanned.Result.resultEntryHash -GoalLineageId $readinessId
  Assert-Result $readinessExhausted 0 applied 'goal-updated'
  $readinessGoal = Copy-JsonObject $readinessExhausted.Result.data.record
  $readinessGoal.readinessFailures = @($readinessGoal.readinessFailures) + @([pscustomobject][ordered]@{ projectRoot='C:\projects\readiness'; chainId='CHAIN-readiness-3'; dispatchId='dispatch-readiness-3'; failureClass='controller-readiness-failed'; evidenceHash=('c' * 64); occurredAt='2099-01-01T09:03:00Z' })
  $readinessGoal.updatedAt = '2099-01-01T09:03:00Z'
  Write-Json $readinessCandidate $readinessGoal
  $thirdReadiness = Invoke-Store -Action GoalPut -Root $root -CandidatePath $readinessCandidate -ExpectedEntryHash $readinessExhausted.Result.resultEntryHash -GoalLineageId $readinessId
  Assert-Result $thirdReadiness 2 invalid 'goal-record-invalid'
  Pass 'readiness permits one replan and one final failed proof, never an unbounded loop'

  $rebaselineId = 'GOAL-20990101-cross-project'
  $rebaselineCandidate = Join-Path $root 'cross-project-goal-candidate.json'
  $rebaselineGoal = New-GoalRecord $rebaselineId @('C:\projects\cross-a','C:\projects\cross-b')
  Write-Json $rebaselineCandidate $rebaselineGoal
  $rebaselineCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $rebaselineCandidate -ExpectedEntryHash MISSING -GoalLineageId $rebaselineId
  Assert-Result $rebaselineCreated 0 applied 'goal-created'
  $rebaselineHead = $rebaselineCreated.Result.resultEntryHash
  foreach ($attempt in 1,2) {
    $strategy = @('initial','repair')[$attempt - 1]
    $rebaselineGoal = Copy-JsonObject (Invoke-Store -Action GoalGet -Root $root -GoalLineageId $rebaselineId).Result.data.record
    for ($lane = 0; $lane -lt 2; $lane++) {
      $rebaselineGoal.lanes[$lane].attemptsUsed = $attempt
      $rebaselineGoal.lanes[$lane].activeReservation = New-GoalReservation -ReservationId "reservation-cross-$lane-$attempt" -ChainId "CHAIN-cross-$lane" -DispatchId "dispatch-cross-$lane-$attempt" -ProblemInvariantId "problem.cross-$lane" -StrategyFamilyId "strategy.cross-$lane-$attempt" -Strategy $strategy -AttemptNumber $attempt -ReservedAt "2099-01-01T09:1$($attempt):00Z"
    }
    $rebaselineGoal.updatedAt = "2099-01-01T09:1$($attempt):00Z"
    Write-Json $rebaselineCandidate $rebaselineGoal
    $reservedBatch = Invoke-Store -Action GoalPut -Root $root -CandidatePath $rebaselineCandidate -ExpectedEntryHash $rebaselineHead -GoalLineageId $rebaselineId
    Assert-Result $reservedBatch 0 applied 'goal-updated'
    $rebaselineGoal = Copy-JsonObject $reservedBatch.Result.data.record
    for ($lane = 0; $lane -lt 2; $lane++) { Complete-GoalReservation $rebaselineGoal $lane 'superseded' 'N/A' (('d','e')[$lane] * 64) "2099-01-01T09:1$($attempt):30Z" }
    $rebaselineGoal.updatedAt = "2099-01-01T09:1$($attempt):30Z"
    Write-Json $rebaselineCandidate $rebaselineGoal
    $finishedBatch = Invoke-Store -Action GoalPut -Root $root -CandidatePath $rebaselineCandidate -ExpectedEntryHash $reservedBatch.Result.resultEntryHash -GoalLineageId $rebaselineId
    Assert-Result $finishedBatch 0 applied 'goal-updated'
    $rebaselineHead = $finishedBatch.Result.resultEntryHash
  }
  $rebaselineGoal = Copy-JsonObject $finishedBatch.Result.data.record
  for ($lane = 0; $lane -lt 2; $lane++) {
    $rebaselineGoal.lanes[$lane].attemptsUsed = 3
    $rebaselineGoal.lanes[$lane].activeReservation = New-GoalReservation -ReservationId "reservation-cross-$lane-3" -ChainId "CHAIN-cross-$lane" -DispatchId "dispatch-cross-$lane-3" -ProblemInvariantId "problem.cross-$lane" -StrategyFamilyId "strategy.cross-$lane-3" -Strategy rebaseline -AttemptNumber 3 -ReservedAt '2099-01-01T09:13:00Z'
  }
  $rebaselineGoal.updatedAt = '2099-01-01T09:13:00Z'
  Write-Json $rebaselineCandidate $rebaselineGoal
  $unaccountedRebaseline = Invoke-Store -Action GoalPut -Root $root -CandidatePath $rebaselineCandidate -ExpectedEntryHash $rebaselineHead -GoalLineageId $rebaselineId
  Assert-Result $unaccountedRebaseline 2 invalid 'goal-transition-invalid'
  $rebaselineGoal.budget.crossProjectRebaselinesUsed = 1
  Write-Json $rebaselineCandidate $rebaselineGoal
  $atomicRebaseline = Invoke-Store -Action GoalPut -Root $root -CandidatePath $rebaselineCandidate -ExpectedEntryHash $rebaselineHead -GoalLineageId $rebaselineId
  Assert-Result $atomicRebaseline 0 applied 'goal-updated'
  Pass 'a multi-project architecture rebaseline is one atomic, globally bounded decision'

  $terminalId = 'GOAL-20990101-terminal'
  $terminalCandidate = Join-Path $root 'terminal-goal-candidate.json'
  $terminalGoal = New-GoalRecord $terminalId @('C:\projects\terminal')
  Write-Json $terminalCandidate $terminalGoal
  $terminalCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $terminalCandidate -ExpectedEntryHash MISSING -GoalLineageId $terminalId
  $terminalGoal.state = 'terminal'; $terminalGoal.updatedAt = '2099-01-01T09:01:00Z'
  Write-Json $terminalCandidate $terminalGoal
  $terminal = Invoke-Store -Action GoalPut -Root $root -CandidatePath $terminalCandidate -ExpectedEntryHash $terminalCreated.Result.resultEntryHash -GoalLineageId $terminalId -ConfirmTerminal $true
  Assert-Result $terminal 0 applied 'goal-updated'
  $terminalGoal.state = 'active'; $terminalGoal.updatedAt = '2099-01-01T09:02:00Z'
  Write-Json $terminalCandidate $terminalGoal
  $reopenedTerminal = Invoke-Store -Action GoalPut -Root $root -CandidatePath $terminalCandidate -ExpectedEntryHash $terminal.Result.resultEntryHash -GoalLineageId $terminalId
  Assert-Result $reopenedTerminal 1 conflict 'goal-terminal'
  Pass 'terminal goal lineages are immutable'

  $successId = 'GOAL-20990101-success'
  $successCandidate = Join-Path $root 'success-goal-candidate.json'
  $successGoal = New-GoalRecord $successId @('C:\projects\success')
  Write-Json $successCandidate $successGoal
  $successCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $successCandidate -ExpectedEntryHash MISSING -GoalLineageId $successId
  $successGoal.lanes[0].attemptsUsed = 1
  $successGoal.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-success-1' -ChainId 'CHAIN-success' -DispatchId 'dispatch-success-1' -ProblemInvariantId 'problem.success-case' -StrategyFamilyId 'strategy.success-case' -ReservedAt '2099-01-01T09:01:00Z'
  $successGoal.updatedAt = '2099-01-01T09:01:00Z'
  Write-Json $successCandidate $successGoal
  $successReserved = Invoke-Store -Action GoalPut -Root $root -CandidatePath $successCandidate -ExpectedEntryHash $successCreated.Result.resultEntryHash -GoalLineageId $successId
  $successGoal = Copy-JsonObject $successReserved.Result.data.record
  Complete-GoalReservation $successGoal 0 'accepted-success' 'N/A' ('f' * 64) '2099-01-01T09:02:00Z'
  Write-Json $successCandidate $successGoal
  $successFinished = Invoke-Store -Action GoalPut -Root $root -CandidatePath $successCandidate -ExpectedEntryHash $successReserved.Result.resultEntryHash -GoalLineageId $successId
  Assert-Result $successFinished 0 applied 'goal-updated'
  $successExperience = Invoke-Store -Action ExperienceRead -Root $root
  Assert-True (@($successExperience.Result.data.entries | Where-Object { $_.outcome -ceq 'accepted-success' -and $_.sourceReservationId -ceq 'reservation-success-1' }).Count -eq 1) 'Accepted success must enter the bounded experience index'
  Pass 'accepted success and deterministic failure both become reusable experience'
  $afterSuccess = Copy-JsonObject $successFinished.Result.data.record
  $afterSuccess.lanes[0].attemptsUsed = 2
  $afterSuccess.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-success-2' -ChainId 'CHAIN-success' -DispatchId 'dispatch-success-2' -ProblemInvariantId 'problem.success-case' -StrategyFamilyId 'strategy.success-case-2' -Strategy repair -AttemptNumber 2 -ReservedAt '2099-01-01T09:03:00Z'
  $afterSuccess.updatedAt = '2099-01-01T09:03:00Z'
  Write-Json $successCandidate $afterSuccess
  $successSuccessor = Invoke-Store -Action GoalPut -Root $root -CandidatePath $successCandidate -ExpectedEntryHash $successFinished.Result.resultEntryHash -GoalLineageId $successId
  Assert-Result $successSuccessor 2 invalid 'goal-transition-invalid'
  Pass 'accepted or user-terminated lanes cannot silently re-enter the retry loop'

  $sourceChainId = 'CHAIN-20990101-curated-source'
  $sourceCandidate = Join-Path $root 'historical-source.json'
  $sourceEvidenceHash = ('3' * 64)
  $sourceRecord = New-Record $sourceChainId
  $sourceRecord.payload.history = @([pscustomobject][ordered]@{ at='2099-01-01T09:00:30Z'; reason="historical controller outcome evidenceHash=$sourceEvidenceHash" })
  Write-Json $sourceCandidate $sourceRecord
  $sourceCreated = Invoke-Store -Action Put -Root $root -ChainId $sourceChainId -CandidatePath $sourceCandidate -ExpectedEntryHash MISSING
  Assert-Result $sourceCreated 0 applied 'task-created'
  $sourceRecord = New-Record $sourceChainId terminal completed
  Write-Json $sourceCandidate $sourceRecord
  $sourceClosed = Invoke-Store -Action Put -Root $root -ChainId $sourceChainId -CandidatePath $sourceCandidate -ExpectedEntryHash $sourceCreated.Result.resultEntryHash -ConfirmTerminal $true
  Assert-Result $sourceClosed 0 applied 'task-archived'
  $sourceLogPath = [string]$sourceClosed.Result.data.path
  $sourceEvent = ([IO.File]::ReadAllText($sourceLogPath, $utf8).TrimEnd("`n").Split("`n")[0] | ConvertFrom-Json)

  $importPath = Join-Path $root 'historical-experience.json'
  $importReservation = New-GoalReservation 'reservation-import-fixture' 'CHAIN-import-fixture' 'dispatch-import-fixture'
  $historicalImport = [pscustomobject][ordered]@{
    schemaVersion=1; importId='IMPORT-20260812-controller-history'; curatedAt='2099-01-02T00:00:00Z'
    entries=@([pscustomobject][ordered]@{
      experienceId='experience.service-a.preflight-hash'; problemInvariantId='problem.controller-preflight-contract'
      strategyFamilyId='strategy.reuse-invalid-preflight-payload'; materialPreconditions=$importReservation.materialPreconditions; materialPreconditionHash=$importReservation.materialPreconditionHash
      outcome='deterministic-failure'; failureClass='controller-preflight'
      sourceChainId=$sourceChainId; sourceEntryHash=[string]$sourceEvent.entryHash
      evidenceHash=$sourceEvidenceHash; observedAt='2099-01-01T09:00:30Z'
    })
  }
  Write-Json $importPath $historicalImport
  $imported = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash MISSING
  Assert-Result $imported 0 applied 'experience-imported'
  $importedHead = [string]$imported.Result.resultEntryHash
  $afterImport = Invoke-Store -Action ExperienceRead -Root $root
  $importedEntries = @($afterImport.Result.data.entries | Where-Object { $_.sourceImportId -ceq $historicalImport.importId })
  Assert-True ($importedEntries.Count -eq 1 -and $importedEntries[0].sourceExperienceId -ceq 'experience.service-a.preflight-hash' -and $importedEntries[0].materialPreconditions.relevantContentHash -ceq ('9' * 64)) 'Curated history must retain reconstructable preconditions without a synthetic goal outcome'
  $importGuardId = 'GOAL-20990101-import-guard'
  $importGuardCandidate = Join-Path $root 'import-guard.json'
  $importGuardGoal = New-GoalRecord $importGuardId @('C:\projects\import-guard')
  Write-Json $importGuardCandidate $importGuardGoal
  $importGuardCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $importGuardCandidate -ExpectedEntryHash MISSING -GoalLineageId $importGuardId
  $importGuardGoal.lanes[0].attemptsUsed = 1
  $importGuardGoal.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-import-guard' -ChainId 'CHAIN-import-guard' -DispatchId 'dispatch-import-guard' -ProblemInvariantId 'problem.controller-preflight-contract' -StrategyFamilyId 'strategy.reuse-invalid-preflight-payload'
  $importGuardGoal.updatedAt = '2099-01-01T09:31:00Z'
  Write-Json $importGuardCandidate $importGuardGoal
  $importGuardRejected = Invoke-Store -Action GoalPut -Root $root -CandidatePath $importGuardCandidate -ExpectedEntryHash $importGuardCreated.Result.resultEntryHash -GoalLineageId $importGuardId
  Assert-Result $importGuardRejected 1 conflict 'goal-known-deterministic-failure'
  $replayedImport = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash MISSING
  Assert-Result $replayedImport 0 applied 'experience-import-replay'
  Assert-True ($replayedImport.Result.resultEntryHash -ceq $importedHead) 'Exact import replay must be idempotent even with an obsolete CAS token'

  $nextImport = Copy-JsonObject $historicalImport
  $nextImport.importId = 'IMPORT-20260812-controller-successes'; $nextImport.curatedAt = '2099-01-02T00:01:00Z'
  $nextImport.entries[0].experienceId = 'experience.project-a.preflight-recovery'
  $nextImport.entries[0].problemInvariantId = 'problem.controller-preflight-recovery'
  $nextImport.entries[0].strategyFamilyId = 'strategy.reconcile-same-dispatch'
  $nextImport.entries[0].outcome = 'accepted-success'; $nextImport.entries[0].failureClass = 'N/A'
  $nextImport.entries[0].evidenceHash = $sourceEvidenceHash
  Write-Json $importPath $nextImport
  $staleImport = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash MISSING
  Assert-Result $staleImport 1 conflict 'experience-import-head-conflict'
  $secondImported = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash $importedHead
  Assert-Result $secondImported 0 applied 'experience-imported'
  Pass 'curated history import is append-only, CAS-protected, merged, and replay-safe'

  $duplicateImport = Copy-JsonObject $historicalImport
  $duplicateImport.importId = 'IMPORT-20260812-duplicate-semantic'; $duplicateImport.curatedAt = '2099-01-02T00:02:00Z'
  $duplicateImport.entries[0].experienceId = 'experience.duplicate-semantic'
  Write-Json $importPath $duplicateImport
  $duplicateImportRejected = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash $secondImported.Result.resultEntryHash
  Assert-Result $duplicateImportRejected 1 conflict 'experience-import-duplicate'

  $secretImport = Copy-JsonObject $historicalImport
  $secretImport.importId = 'IMPORT-20260812-secret'; $secretImport.curatedAt = '2099-01-02T00:03:00Z'
  $secretImport.entries[0].experienceId = 'experience.secret'; $secretImport.entries[0].problemInvariantId = 'problem.secret'
  Add-Member -InputObject $secretImport.entries[0] -NotePropertyName note -NotePropertyValue ('Bear' + 'er definitely-not-storable')
  Write-Json $importPath $secretImport
  $secretImportRejected = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash $secondImported.Result.resultEntryHash
  Assert-Result $secretImportRejected 2 invalid 'task-secret-rejected'

  $fakeEvidenceImport = Copy-JsonObject $historicalImport
  $fakeEvidenceImport.importId = 'IMPORT-20260812-fake-evidence'; $fakeEvidenceImport.curatedAt = '2099-01-02T00:04:00Z'
  $fakeEvidenceImport.entries[0].experienceId = 'experience.fake-evidence'; $fakeEvidenceImport.entries[0].problemInvariantId = 'problem.fake-evidence'
  $fakeEvidenceImport.entries[0].sourceEntryHash = ('0' * 64); $fakeEvidenceImport.entries[0].evidenceHash = ('1' * 64)
  Write-Json $importPath $fakeEvidenceImport
  $fakeEvidenceRejected = Invoke-Store -Action ExperienceImport -Root $root -CandidatePath $importPath -ExpectedEntryHash $secondImported.Result.resultEntryHash
  Assert-Result $fakeEvidenceRejected 1 conflict 'experience-import-evidence-invalid'

  $importLogPath = Join-Path $root 'state\experience-imports.jsonl'
  $importLogBytes = [IO.File]::ReadAllBytes($importLogPath)
  $importEvents = @([IO.File]::ReadAllText($importLogPath, $utf8).TrimEnd("`n").Split("`n"))
  $tamperedImportEvent = $importEvents[0] | ConvertFrom-Json
  $tamperedImportEvent.record.entries[0].evidenceHash = ('5' * 64)
  $importEvents[0] = $tamperedImportEvent | ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($importLogPath, (($importEvents -join "`n") + "`n"), $utf8)
  $tamperedImportRead = Invoke-Store -Action ExperienceRead -Root $root
  Assert-Result $tamperedImportRead 1 conflict 'experience-import-log-invalid'
  [IO.File]::WriteAllBytes($importLogPath, $importLogBytes)
  Assert-Result (Invoke-Store -Action ExperienceRead -Root $root) 0 verified 'experience-read'
  Pass 'historical imports reject duplicate identities, secrets, and tampered evidence'

  $indexPath = Join-Path $root 'state\experience-index.json'
  $tamperedIndex = [IO.File]::ReadAllText($indexPath, $utf8) | ConvertFrom-Json
  $tamperedIndex.entries[0].evidenceHash = ('1' * 64)
  Write-Json $indexPath $tamperedIndex
  $tamperedExperience = Invoke-Store -Action ExperienceRead -Root $root
  Assert-Result $tamperedExperience 1 conflict 'experience-index-stale'
  Assert-Result (Invoke-Store -Action Rebuild -Root $root) 0 applied 'store-rebuilt'
  Pass 'experience content must exactly derive from canonical goal logs, not only share their watermark'

  $index = [IO.File]::ReadAllText($indexPath, $utf8) | ConvertFrom-Json
  $index.sourceWatermark = ('0' * 64)
  Write-Json $indexPath $index
  $staleExperience = Invoke-Store -Action ExperienceRead -Root $root
  Assert-Result $staleExperience 1 conflict 'experience-index-stale'
  $rebuiltExperience = Invoke-Store -Action Rebuild -Root $root
  Assert-Result $rebuiltExperience 0 applied 'store-rebuilt'
  Pass 'a stale derived experience index fails closed and rebuilds from canonical logs'

  $casId = 'GOAL-20990101-cas'
  $casCandidateA = Join-Path $root 'cas-a.json'; $casCandidateB = Join-Path $root 'cas-b.json'
  $casGoal = New-GoalRecord $casId @('C:\projects\cas')
  Write-Json $casCandidateA $casGoal
  $casCreated = Invoke-Store -Action GoalPut -Root $root -CandidatePath $casCandidateA -ExpectedEntryHash MISSING -GoalLineageId $casId
  $casA = Copy-JsonObject $casGoal; $casB = Copy-JsonObject $casGoal
  $casA.lanes[0].attemptsUsed = 1; $casA.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-cas-a' -ChainId 'CHAIN-cas-a' -DispatchId 'dispatch-cas-a' -ProblemInvariantId 'problem.cas-a' -StrategyFamilyId 'strategy.cas-a'; $casA.updatedAt = '2099-01-01T09:01:00Z'
  $casB.lanes[0].attemptsUsed = 1; $casB.lanes[0].activeReservation = New-GoalReservation -ReservationId 'reservation-cas-b' -ChainId 'CHAIN-cas-b' -DispatchId 'dispatch-cas-b' -ProblemInvariantId 'problem.cas-b' -StrategyFamilyId 'strategy.cas-b'; $casB.updatedAt = '2099-01-01T09:01:01Z'
  Write-Json $casCandidateA $casA; Write-Json $casCandidateB $casB
  $casWinner = Invoke-Store -Action GoalPut -Root $root -CandidatePath $casCandidateA -ExpectedEntryHash $casCreated.Result.resultEntryHash -GoalLineageId $casId
  Assert-Result $casWinner 0 applied 'goal-updated'
  $casLoser = Invoke-Store -Action GoalPut -Root $root -CandidatePath $casCandidateB -ExpectedEntryHash $casCreated.Result.resultEntryHash -GoalLineageId $casId
  Assert-Result $casLoser 1 conflict 'goal-head-conflict'
  Pass 'whole-goal CAS prevents a stale controller decision from overwriting a winner'

  $defaultRoot = Join-Path $testRoot 'default-root'
  $defaultTools = Join-Path $defaultRoot 'tools'
  [IO.Directory]::CreateDirectory($defaultTools) | Out-Null
  $defaultSubject = Join-Path $defaultTools 'chain-store.ps1'
  Copy-Item -LiteralPath $subject -Destination $defaultSubject
  [void](Invoke-Store Initialize $defaultRoot)
  $defaultRead = Invoke-DefaultStoreRead $defaultSubject $defaultRoot
  Assert-True ($defaultRead.ExitCode -eq 0 -and $defaultRead.Result.reasonCode -ceq 'store-read' -and $defaultRead.Result.controllerRoot -ceq $defaultRoot) 'Installed chain-store must resolve its controller root when -ControllerRoot is omitted'
  Pass 'direct installed invocation resolves the controller root'

  $semanticRoot = Join-Path $testRoot 'semantic-state'
  [IO.Directory]::CreateDirectory($semanticRoot) | Out-Null
  [void](Invoke-Store Initialize $semanticRoot)
  $semanticCandidate = Join-Path $semanticRoot 'candidate.json'
  $semanticRecord = New-Record 'CHAIN-20990101-semantic'
  $semanticRecord.phase='closed';$semanticRecord.status='completed';$semanticRecord.nextAction='N/A'
  $semanticRecord.payload.phase=$semanticRecord.phase;$semanticRecord.payload.status=$semanticRecord.status;$semanticRecord.payload.nextAction=$semanticRecord.nextAction
  Write-Json $semanticCandidate $semanticRecord
  $semanticRejected = Invoke-Store Put $semanticRoot '' $semanticCandidate 'MISSING'
  Assert-Result $semanticRejected 2 invalid 'task-state-summary-mismatch'
  Pass 'new active CHAIN cannot carry a terminal phase or status'

  $id = 'CHAIN-20990101-001'
  $candidate = Join-Path $root 'candidate.json'
  $record = New-Record $id
  Write-Json $candidate $record
  $created = Invoke-Store Put $root '' $candidate 'MISSING'
  Assert-Result $created 0 applied 'task-created'
  Assert-True ($created.Result.resultEntryHash -cmatch '^[0-9a-f]{64}$') 'Create must return a head entry hash'
  Pass 'create appends the first canonical event'

  $get = Invoke-Store Get $root $id
  Assert-Result $get 0 verified 'task-read'
  Assert-True ($get.Result.data.record.chainId -ceq $id -and $get.Result.data.record.payload.id -ceq $id) 'Get must return the exact task'
  Pass 'get loads one exact CHAIN'

  $record.status = 'blocked'; $record.payload.status = 'blocked'; $record.updatedAt = '2099-01-01T10:01:00+08:00'; $record.payload.updatedAt = $record.updatedAt
  Write-Json $candidate $record
  $updated = Invoke-Store Put $root '' $candidate $created.Result.resultEntryHash
  Assert-Result $updated 0 applied 'task-updated'
  Pass 'update uses head-entry CAS'

  $staleRecord = New-Record $id
  $staleRecord.status = 'waiting'; $staleRecord.payload.status = 'waiting'; $staleRecord.updatedAt = '2099-01-01T10:02:00+08:00'; $staleRecord.payload.updatedAt = $staleRecord.updatedAt
  Write-Json $candidate $staleRecord
  $stale = Invoke-Store Put $root '' $candidate $created.Result.resultEntryHash
  Assert-Result $stale 1 conflict 'task-head-conflict'
  $afterStale = Invoke-Store Get $root $id
  Assert-True ($afterStale.Result.data.record.status -ceq 'blocked') 'Stale write must preserve current state'
  Pass 'stale CAS cannot overwrite a newer task'

  Write-Json $candidate $record
  $replay = Invoke-Store Put $root '' $candidate $updated.Result.resultEntryHash
  Assert-Result $replay 0 applied 'task-replay'
  Assert-True ($replay.Result.resultEntryHash -ceq $updated.Result.resultEntryHash) 'Exact replay must not append another event'
  Pass 'exact current replay is idempotent'

  $record.state='terminal';$record.phase='closed';$record.status='completed';$record.updatedAt='2099-01-01T11:00:00+08:00';$record.nextAction='N/A'
  $record.payload.phase=$record.phase;$record.payload.status=$record.status;$record.payload.updatedAt=$record.updatedAt;$record.payload.nextAction=$record.nextAction
  Write-Json $candidate $record
  $unconfirmed = Invoke-Store Put $root '' $candidate $updated.Result.resultEntryHash
  Assert-Result $unconfirmed 2 invalid 'terminal-confirmation-required'
  $archived = Invoke-Store Put $root '' $candidate $updated.Result.resultEntryHash $true
  Assert-Result $archived 0 applied 'task-archived'
  Assert-True ($archived.Result.data.path -cmatch 'state[\\/]archive[\\/]2099-01') 'Terminal task must move to its month archive'
  Pass 'terminal transition is explicit and archived'

  $terminalRewrite = Invoke-Store Put $root '' $candidate $archived.Result.resultEntryHash $true
  Assert-Result $terminalRewrite 0 applied 'task-replay'
  $record.objective='rewrite terminal';$record.payload.goal=$record.objective;Write-Json $candidate $record
  $immutable = Invoke-Store Put $root '' $candidate $archived.Result.resultEntryHash $true
  Assert-Result $immutable 1 conflict 'task-terminal'
  Pass 'terminal log is immutable except exact replay'

  $verify = Invoke-Store Verify $root
  Assert-Result $verify 0 verified 'store-verified'
  Pass 'verify checks canonical and derived state'

  [IO.File]::Delete((Join-Path $root 'state\index.json'))
  [IO.File]::Delete((Join-Path $root 'memory\MEMORY.md'))
  [IO.File]::Delete((Join-Path $root 'TASKS.md'))
  $rebuilt = Invoke-Store Rebuild $root
  Assert-Result $rebuilt 0 applied 'store-rebuilt'
  $memoryBytes = [IO.File]::ReadAllBytes((Join-Path $root 'memory\MEMORY.md'))
  $memoryLines = ([regex]::Matches($utf8.GetString($memoryBytes), "`n")).Count
  Assert-True ($memoryBytes.Length -le 25600 -and $memoryLines -le 200) 'Startup memory must remain within 200 lines and 25 KiB'
  Pass 'derived views are rebuildable and startup memory is bounded'

  $secretId='CHAIN-20990101-002';$secretRecord=New-Record $secretId;$secretRecord.payload | Add-Member -NotePropertyName password -NotePropertyValue 'do-not-store'
  Write-Json $candidate $secretRecord
  $secret = Invoke-Store Put $root '' $candidate 'MISSING'
  Assert-Result $secret 2 invalid 'task-secret-rejected'
  Pass 'secret-shaped payload fields are rejected'

  $embeddedCredential='g'+'hp_'+('A'*36)
  $secretTextId='CHAIN-20990101-secret-text';$secretTextRecord=New-Record $secretTextId
  $secretTextRecord.objective='Investigate '+$embeddedCredential+' without storing it';$secretTextRecord.payload.goal=$secretTextRecord.objective
  Write-Json $candidate $secretTextRecord
  $secretText=Invoke-Store Put $root '' $candidate 'MISSING'
  Assert-Result $secretText 2 invalid 'task-secret-rejected'
  Assert-True ((ConvertTo-Json $secretText.Result -Compress).Contains($embeddedCredential) -eq $false) 'Rejected output must not echo an embedded credential'
  Pass 'secret-shaped tokens embedded in arbitrary task text are rejected'

  $bomCandidate=Join-Path $root 'bom.json';$bomBody=$utf8.GetBytes(((New-Record 'CHAIN-20990101-003' | ConvertTo-Json -Depth 30 -Compress)+"`n"))
  [IO.File]::WriteAllBytes($bomCandidate,[byte[]](@(0xEF,0xBB,0xBF)+@($bomBody)))
  $bom = Invoke-Store Put $root '' $bomCandidate 'MISSING'
  Assert-Result $bom 2 invalid 'candidate-encoding-invalid'
  Pass 'candidate UTF-8 BOM is rejected'

  $tamperRoot=Join-Path $testRoot 'tamper';[IO.Directory]::CreateDirectory($tamperRoot)|Out-Null
  [void](Invoke-Store Initialize $tamperRoot)
  $tamperCandidate=Join-Path $tamperRoot 'candidate.json';Write-Json $tamperCandidate (New-Record 'CHAIN-20990101-004')
  $tamperCreate=Invoke-Store Put $tamperRoot '' $tamperCandidate 'MISSING'
  $logPath=[string]$tamperCreate.Result.data.path
  [IO.File]::AppendAllText($logPath,"{}`n",$utf8)
  $tampered=Invoke-Store Verify $tamperRoot
  Assert-Result $tampered 1 conflict 'store-log-invalid'
  Pass 'hash-chain tampering is detected'

  $migrationRoot=Join-Path $testRoot 'migration';[IO.Directory]::CreateDirectory((Join-Path $migrationRoot 'legacy-archive'))|Out-Null
  $activePayload=[pscustomobject][ordered]@{id='CHAIN-20990201-001';phase='execution';status='running';createdAt='2099-02-01T09:00:00+08:00';updatedAt='2099-02-01T10:00:00+08:00';goal=('A'*1800);nextAction='continue';archiveState='active'}
  $terminalPayload=[pscustomobject][ordered]@{id='CHAIN-20990201-002';phase='closed';status='completed';createdAt='2099-02-01T09:00:00+08:00';updatedAt='2099-02-01T11:00:00+08:00';goal='done';nextAction='N/A';archiveState='pending'}
  $legacyClosedOnlyPayload=[pscustomobject][ordered]@{id='CHAIN-20990201-003';phase='closed';status='completed';createdAt='2099-02-01T09:00:00+08:00';updatedAt='2099-02-01T12:00:00+08:00';goal='legacy closed';nextAction='N/A';archiveState='active'}
  $activeJson=$activePayload|ConvertTo-Json -Depth 10
  $terminalJson=$terminalPayload|ConvertTo-Json -Depth 10
  $legacyClosedOnlyJson=$legacyClosedOnlyPayload|ConvertTo-Json -Depth 10
  $ledger=Join-Path $migrationRoot 'legacy-ledger.md'
  $archive=Join-Path $migrationRoot 'legacy-archive\2099-02.md'
  $ledgerText="# ledger`n`n## active`n`n### $($activePayload.id)`n`n``````json`n$activeJson`n```````n`n### $($terminalPayload.id)`n`n``````json`n$terminalJson`n```````n`n### $($legacyClosedOnlyPayload.id)`n`n``````json`n$legacyClosedOnlyJson`n```````n"
  $archiveText="# archive`n`n### $($terminalPayload.id)`n`n``````json`n$terminalJson`n```````n"
  [IO.File]::WriteAllText($ledger,$ledgerText,$utf8);[IO.File]::WriteAllText($archive,$archiveText,$utf8)
  $prepared=Invoke-Store PrepareMigration $migrationRoot '' '' '' $false $ledger (Split-Path -Parent $archive)
  Assert-Result $prepared 0 prepared 'migration-prepared'
  Assert-True ($prepared.Result.data.activeCount -eq 1 -and $prepared.Result.data.terminalCount -eq 2) 'Migration must deduplicate pending active/archive records and classify semantic terminal summaries'
  $legacyClosedOnly=Invoke-Store Get $prepared.Result.data.migrationPath $legacyClosedOnlyPayload.id
  Assert-True ($legacyClosedOnly.Result.data.record.state -ceq 'terminal') 'Migration must not keep a closed legacy summary active'
  Pass 'legacy migration builds a verified shadow store'

  [IO.File]::AppendAllText($ledger,"`n",$utf8)
  $sourceConflict=Invoke-Store ApplyMigration $migrationRoot '' '' '' $false $ledger (Split-Path -Parent $archive) $prepared.Result.data.migrationPath $prepared.Result.sourceHash $true
  Assert-Result $sourceConflict 1 conflict 'migration-source-conflict'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $migrationRoot 'state'))) 'Source conflict must not cut over state'
  Pass 'migration source CAS prevents stale cutover'

  [IO.File]::WriteAllText($ledger,$ledgerText,$utf8)
  $prepared=Invoke-Store PrepareMigration $migrationRoot '' '' '' $false $ledger (Split-Path -Parent $archive)
  $applied=Invoke-Store ApplyMigration $migrationRoot '' '' '' $false $ledger (Split-Path -Parent $archive) $prepared.Result.data.migrationPath $prepared.Result.sourceHash $true
  Assert-Result $applied 0 applied 'migration-applied'
  Assert-True ((Get-Content -Encoding UTF8 -LiteralPath $ledger -TotalCount 1) -ceq '# Controller Tasks') 'Cutover must replace the ledger with a generated dashboard'
  Assert-True (Test-Path -LiteralPath $applied.Result.data.legacyBackup -PathType Container) 'Cutover must preserve exact legacy bytes'
  $postMigration=Invoke-Store Verify $migrationRoot
  Assert-Result $postMigration 0 verified 'store-verified'
  Pass 'migration cutover preserves legacy bytes and verifies the new store'

  $bulkRoot=Join-Path $testRoot 'bulk-migration';$bulkArchive=Join-Path $bulkRoot 'legacy-archive';[IO.Directory]::CreateDirectory($bulkArchive)|Out-Null
  $bulkLedger=Join-Path $bulkRoot 'legacy-ledger.md';[IO.File]::WriteAllText($bulkLedger,"# ledger`n",$utf8)
  $bulkText="# archive`n"
  for($index=1;$index -le 501;$index++){
    $bulkId=('CHAIN-20990301-{0:d3}' -f $index)
    $bulkPayload=[pscustomobject][ordered]@{id=$bulkId;phase='closed';status='completed';createdAt='2099-03-01T09:00:00+08:00';updatedAt='2099-03-01T11:00:00+08:00';goal=('done '+$index);nextAction='N/A';archiveState='pending'}
    $bulkText += "`n### $bulkId`n`n``````json`n$($bulkPayload|ConvertTo-Json -Depth 10)`n```````n"
  }
  $bulkArchiveFile=Join-Path $bulkArchive '2099-03.md';[IO.File]::WriteAllText($bulkArchiveFile,$bulkText,$utf8)
  $bulkPrepared=Invoke-Store PrepareMigration $bulkRoot '' '' '' $false $bulkLedger $bulkArchive
  Assert-Result $bulkPrepared 0 prepared 'migration-prepared'
  $bulkIndex=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $bulkPrepared.Result.data.migrationPath 'state\index.json')|ConvertFrom-Json
  Assert-True ($bulkIndex.terminalCount -eq 501 -and @($bulkIndex.items).Count -eq 500) 'Derived index must bound terminal summaries without losing the total count'
  $bulkGet=Invoke-Store Get $bulkPrepared.Result.data.migrationPath 'CHAIN-20990301-501'
  Assert-Result $bulkGet 0 verified 'task-read'
  Assert-True ($bulkGet.Result.data.record.chainId -ceq 'CHAIN-20990301-501') 'Get must resolve an exact archived CHAIN omitted from the compact index'
  Pass 'compact index stays bounded while exact archived lookup remains available'

  [Console]::Out.WriteLine("PASS COUNT $passed")
}
finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
