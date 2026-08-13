[CmdletBinding()]
param([string]$SubjectPath = '', [string]$GoalStoreSubjectPath = '')

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$subject = if ([string]::IsNullOrWhiteSpace($SubjectPath)) { Join-Path $skillRoot 'templates\controller\tools\control-state.ps1' } else { [IO.Path]::GetFullPath($SubjectPath) }
$goalStoreSubject = if ([string]::IsNullOrWhiteSpace($GoalStoreSubjectPath)) { Join-Path $skillRoot 'templates\controller\tools\chain-store.ps1' } else { [IO.Path]::GetFullPath($GoalStoreSubjectPath) }
foreach ($path in @($subject,$goalStoreSubject)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Subject does not exist: $path" } }
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

function Get-EncodedStringExpression {
  param([string]$Value)
  $encoded = [Convert]::ToBase64String($utf8.GetBytes($Value))
  return "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')))"
}

function Start-TestPowerShell {
  param([string]$Command, [bool]$Redirect = $false)
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  $wrappedCommand = '$ProgressPreference = ''SilentlyContinue''; ' + $Command
  $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedCommand))
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $Redirect
  $startInfo.RedirectStandardError = $Redirect
  return [Diagnostics.Process]::Start($startInfo)
}

function Stop-TestProcess {
  param([AllowNull()][Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try {
    try { if (-not $Process.HasExited) { $Process.Kill(); $Process.WaitForExit(5000) | Out-Null } } catch {}
  }
  finally { $Process.Dispose() }
}

function Wait-TestProcess {
  param([Diagnostics.Process]$Process, [int]$TimeoutMilliseconds, [string]$Message)
  try {
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) { throw $Message }
  }
  finally { Stop-TestProcess $Process }
}

function Start-MutexHolder {
  param([string]$Root, [string]$SignalPath, [int]$HoldMilliseconds, [bool]$Abandon, [AllowNull()][string]$ReleasePath = $null)
  $name = 'Local\onboard-code-projects-' + (Get-Hash $utf8.GetBytes($Root.ToUpperInvariant()))
  $escapedName = $name.Replace("'", "''")
  $escapedSignal = $SignalPath.Replace("'", "''")
  $tail = if ($Abandon) { '[Environment]::Exit(0)' } else { '$mutex.ReleaseMutex(); $mutex.Dispose()' }
  $wait = if ([string]::IsNullOrWhiteSpace($ReleasePath)) { "Start-Sleep -Milliseconds $HoldMilliseconds" } else {
    $escapedRelease = $ReleasePath.Replace("'", "''")
    "`$watch = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath '$escapedRelease' -PathType Leaf) -and `$watch.ElapsedMilliseconds -lt $HoldMilliseconds) { Start-Sleep -Milliseconds 25 }"
  }
  $command = "`$mutex = New-Object Threading.Mutex(`$false, '$escapedName'); `$mutex.WaitOne() | Out-Null; [IO.File]::WriteAllText('$escapedSignal', 'ready'); $wait; $tail"
  $process = Start-TestPowerShell $command
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $SignalPath -PathType Leaf) -and $watch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 50 }
  if (-not (Test-Path -LiteralPath $SignalPath -PathType Leaf)) {
    Stop-TestProcess $process
    throw 'Mutex holder must signal acquisition within 5 seconds'
  }
  return $process
}

function Invoke-State {
  param(
    [string]$Action,
    [string]$ControllerRoot,
    [string]$ExpectedHash,
    [string]$Operation,
    [string]$PayloadJson,
    [string]$CandidatePath,
    [string]$CandidateHash,
    [bool]$ConfirmCleanup = $false
  )
  $command = '& ' + (Get-EncodedStringExpression $subject) + ' -Action ' + (Get-EncodedStringExpression $Action) + ' -ControllerRoot ' + (Get-EncodedStringExpression $ControllerRoot)
  foreach ($pair in @(
    [pscustomobject]@{ Name='ExpectedHash'; Value=$ExpectedHash },
    [pscustomobject]@{ Name='Operation'; Value=$Operation },
    [pscustomobject]@{ Name='PayloadJson'; Value=$PayloadJson },
    [pscustomobject]@{ Name='CandidatePath'; Value=$CandidatePath },
    [pscustomobject]@{ Name='CandidateHash'; Value=$CandidateHash }
  )) {
    if (-not [string]::IsNullOrEmpty([string]$pair.Value)) {
      $command += ' -' + $pair.Name + ' ' + (Get-EncodedStringExpression ([string]$pair.Value))
    }
  }
  if ($ConfirmCleanup) { $command += ' -ConfirmCleanup' }
  $command += '; exit $LASTEXITCODE'
  $process = Start-TestPowerShell $command $true
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(20000)) { throw "State adapter timed out for $Action" }
    $document = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
  }
  finally { Stop-TestProcess $process }
  Assert-True ([string]::IsNullOrWhiteSpace($stderr)) "State adapter must not emit stderr for $Action; stderr: $stderr"
  try { $result = $document.Trim() | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "State adapter must emit exactly one JSON document for $Action; output: $document" }
  foreach ($field in @('schemaVersion','action','status','reasonCode','controllerRoot','currentHash','candidatePath','candidateHash','resultHash','data','nextAction','warnings')) {
    Assert-True ($result.PSObject.Properties.Name -ccontains $field) "Result must contain $field"
  }
  Assert-True (@($result.PSObject.Properties.Name).Count -eq 12) 'Result must be a closed twelve-field object'
  Assert-True ($result.schemaVersion -eq 1 -and $result.action -ceq $Action) 'Result schema/action mismatch'
  Assert-True ($exitCode -in 0,1,2) "Unexpected exit code $exitCode"
  return [pscustomobject]@{ Result=$result; ExitCode=$exitCode }
}

function Assert-State {
  param($Call, [string]$Status, [int]$ExitCode, [string]$Reason)
  Assert-True ($Call.ExitCode -eq $ExitCode) "Expected $Status/$Reason exit $ExitCode, got $($Call.Result.status)/$($Call.Result.reasonCode) exit $($Call.ExitCode)"
  Assert-True ($Call.Result.status -ceq $Status) "Expected $Status/$Reason, got $($Call.Result.status)/$($Call.Result.reasonCode) at $((Get-PSCallStack)[1].Location)"
  Assert-True ($Call.Result.reasonCode -ceq $Reason) "Expected $Status/$Reason, got $($Call.Result.status)/$($Call.Result.reasonCode) at $((Get-PSCallStack)[1].Location)"
  $script:scenarioCount++
}

function Write-Manifest {
  param(
    [string]$Root,
    [AllowNull()][object]$ControllerBinding = $null,
    [AllowNull()][object]$ControllerTaskIntent = $null,
    [object[]]$ProjectBindings = @(),
    [int]$Version = 1
  )
  [IO.Directory]::CreateDirectory($Root) | Out-Null
  $manifest = [ordered]@{
    schemaVersion=$Version; generator='onboard-code-projects'; templateVersion=$Version; controllerName='State Test'
    controllerBinding=$ControllerBinding; controllerTaskIntent=$ControllerTaskIntent; projectBindings=@($ProjectBindings)
  }
  if ($Version -eq 2) { $manifest.dispatchQueues = @() }
  $manifest = [pscustomobject]$manifest
  $bytes = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
  [IO.File]::WriteAllBytes((Join-Path $Root '.codex-controller.json'), $bytes)
  return Get-Hash $bytes
}

function Prepare {
  param([string]$Root, [string]$Hash, [string]$Operation, [object]$Payload)
  return Invoke-State PrepareCandidate $Root $Hash $Operation ($Payload | ConvertTo-Json -Depth 12 -Compress) '' ''
}

function Apply {
  param([string]$Root, [string]$Hash, $Prepared)
  return Invoke-State ApplyCandidate $Root $Hash '' '' ([string]$Prepared.Result.candidatePath) ([string]$Prepared.Result.candidateHash)
}

function Mutate {
  param([string]$Root, [string]$Hash, [string]$Operation, [object]$Payload)
  $prepared = Prepare $Root $Hash $Operation $Payload
  try { Assert-State $prepared prepared 0 'controller-candidate-prepared' }
  catch { throw "$Operation prepare failed: $($_.Exception.Message)" }
  $applied = Apply $Root $Hash $prepared
  try { Assert-State $applied applied 0 'controller-state-applied' }
  catch { throw "$Operation apply failed: $($_.Exception.Message)" }
  return $applied
}

function Export-Dispatch {
  param([string]$Root, [string]$Hash, [object]$Payload)
  $command = '& ' + (Get-EncodedStringExpression $subject) +
    ' -Action ExportDispatch -ControllerRoot ' + (Get-EncodedStringExpression $Root) +
    ' -ExpectedHash ' + (Get-EncodedStringExpression $Hash) +
    ' -PayloadJson ' + (Get-EncodedStringExpression ($Payload | ConvertTo-Json -Depth 12 -Compress)) +
    '; exit $LASTEXITCODE'
  $process = Start-TestPowerShell $command $true
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(20000)) { throw 'ExportDispatch timed out' }
    $document = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) {
      throw "ExportDispatch failed: $document $stderr"
    }
    return ($document.Trim() | ConvertFrom-Json -ErrorAction Stop)
  }
  finally { Stop-TestProcess $process }
}

function Invoke-GoalStore {
  param([string]$Action, [string]$Root, [string]$GoalLineageId = '', [string]$CandidatePath = '', [string]$ExpectedEntryHash = '', [string]$ChainId = '', [bool]$ConfirmTerminal = $false)
  $command = '& ' + (Get-EncodedStringExpression $goalStoreSubject) + ' -Action ' + (Get-EncodedStringExpression $Action) +
    ' -ControllerRoot ' + (Get-EncodedStringExpression $Root)
  foreach ($pair in @(
    [pscustomobject]@{ Name='GoalLineageId'; Value=$GoalLineageId },
    [pscustomobject]@{ Name='CandidatePath'; Value=$CandidatePath },
    [pscustomobject]@{ Name='ExpectedEntryHash'; Value=$ExpectedEntryHash },
    [pscustomobject]@{ Name='ChainId'; Value=$ChainId }
  )) {
    if (-not [string]::IsNullOrEmpty($pair.Value)) { $command += ' -' + $pair.Name + ' ' + (Get-EncodedStringExpression $pair.Value) }
  }
  if ($ConfirmTerminal) { $command += ' -ConfirmTerminal' }
  $command += '; exit $LASTEXITCODE'
  $process = Start-TestPowerShell $command $true
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(30000)) { throw "Goal store timed out for $Action" }
    $document = $stdout.GetAwaiter().GetResult().Trim(); $errorText = $stderr.GetAwaiter().GetResult().Trim(); $exitCode = $process.ExitCode
  }
  finally { Stop-TestProcess $process }
  Assert-True ([string]::IsNullOrWhiteSpace($errorText)) "Goal store must not emit stderr for $Action; stderr: $errorText"
  try { $result = $document | ConvertFrom-Json -ErrorAction Stop } catch { throw "Goal store must emit JSON for $Action; output: $document" }
  return [pscustomobject]@{ Result=$result; ExitCode=$exitCode }
}

function New-TestChainRecord {
  param([string]$ChainId, [string]$State = 'active', [string]$Status = 'running', [string]$UpdatedAt = '2026-08-02T23:59:00Z')
  $phase = if ($State -ceq 'terminal') { 'closed' } else { 'execution' }
  $nextAction = if ($State -ceq 'terminal') { 'N/A' } else { 'wait for terminal evidence' }
  return [pscustomobject][ordered]@{
    schemaVersion=1; chainId=$ChainId; state=$State; phase=$phase; status=$Status
    createdAt='2026-08-02T23:58:00Z'; updatedAt=$UpdatedAt; objective="Complete $ChainId"; nextAction=$nextAction
    payload=[pscustomobject][ordered]@{ id=$ChainId; phase=$phase; status=$Status; createdAt='2026-08-02T23:58:00Z'; updatedAt=$UpdatedAt; goal="Complete $ChainId"; nextAction=$nextAction; history=@() }
  }
}

function Copy-JsonObject {
  param($Value)
  return (($Value | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
}

function Write-GoalCandidate {
  param([string]$Root, [string]$GoalLineageId, $Value)
  $path = Join-Path $Root ($GoalLineageId + '.candidate.json')
  [IO.File]::WriteAllText($path, (($Value | ConvertTo-Json -Depth 30 -Compress) + "`n"), $utf8)
  return $path
}

function Get-TestCanonicalValueHash {
  param($Value)
  return Get-Hash ($utf8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 8 -Compress)))
}

function Get-TestRuntimeHash {
  $descriptors = @(
    [pscustomobject][ordered]@{ path=[IO.Path]::GetFileName($subject); sha256=(Get-Hash ([IO.File]::ReadAllBytes($subject))) },
    [pscustomobject][ordered]@{ path='chain-store.ps1'; sha256=(Get-Hash ([IO.File]::ReadAllBytes($goalStoreSubject))) }
  )
  return Get-TestCanonicalValueHash @($descriptors)
}

function New-TestReservation {
  param(
    [string]$ReservationId, [string]$ChainId, [string]$DispatchId,
    [string]$ProblemInvariantId, [string]$StrategyFamilyId,
    [string]$Strategy = 'initial', [int]$AttemptNumber = 1, [string]$ReservedAt = '2026-08-02T23:59:00Z', $TaskSpec
  )
  $acceptanceIds = @($TaskSpec.acceptance | ForEach-Object { Get-Hash ($utf8.GetBytes([string]$_)) })
  $preconditions = [pscustomobject][ordered]@{
    contractVersionHash=(Get-TestCanonicalValueHash $TaskSpec.contract)
    targetSetHash=(Get-TestCanonicalValueHash @($TaskSpec.readiness.targets))
    capabilitySetHash=(Get-TestCanonicalValueHash @($TaskSpec.readiness.capabilityRefs))
    runtimeVersionHash=(Get-TestRuntimeHash); toolchainVersionHash=('e' * 64); authorizationBoundaryHash=('f' * 64)
    failureOracleHash=(Get-TestCanonicalValueHash @($TaskSpec.readiness.verification)); relevantContentHash=('9' * 64)
  }
  $preconditions.authorizationBoundaryHash = Get-TestCanonicalValueHash ([string]$TaskSpec.authorizationRef)
  $coverage = @()
  for ($index = 0; $index -lt $acceptanceIds.Count; $index++) {
    $coverage += [pscustomobject][ordered]@{
      acceptanceId=$acceptanceIds[$index]; operationId="op-$index"; operationClass=$TaskSpec.readiness.operationClass
      targets=@($TaskSpec.readiness.targets); capabilityRefs=@($TaskSpec.readiness.capabilityRefs); authorizationRef=$TaskSpec.authorizationRef
      verification=@($TaskSpec.readiness.verification); rollback=@($TaskSpec.readiness.rollback)
    }
  }
  return [pscustomobject][ordered]@{
    reservationId=$ReservationId; chainId=$ChainId; dispatchId=$DispatchId; problemInvariantId=$ProblemInvariantId
    strategyFamilyId=$StrategyFamilyId; strategy=$Strategy; attemptNumber=$AttemptNumber; retryOrdinal=0; executionFingerprint=(Get-TestCanonicalValueHash $TaskSpec.baseline)
    acceptanceIds=@($acceptanceIds); acceptanceHash=(Get-TestCanonicalValueHash @($acceptanceIds))
    materialPreconditions=$preconditions; materialPreconditionHash=(Get-TestCanonicalValueHash $preconditions)
    operationCoverage=$coverage; operationCoverageHash=(Get-TestCanonicalValueHash @($coverage))
    controllerRuntimeHash=$preconditions.runtimeVersionHash; capabilityBundleHash=$preconditions.capabilitySetHash; reservedAt=$ReservedAt
  }
}

function Get-TestGoalBinding {
  param($Reservation, [string]$GoalLineageId)
  return [pscustomobject][ordered]@{
    goalLineageId=$GoalLineageId; reservationId=$Reservation.reservationId; problemInvariantId=$Reservation.problemInvariantId
    strategyFamilyId=$Reservation.strategyFamilyId; materialPreconditionHash=$Reservation.materialPreconditionHash
    acceptanceHash=$Reservation.acceptanceHash; operationCoverageHash=$Reservation.operationCoverageHash
    controllerRuntimeHash=$Reservation.controllerRuntimeHash; capabilityBundleHash=$Reservation.capabilityBundleHash
  }
}

function Get-TestObjectiveFingerprint {
  param($TaskSpec)
  $identity = [pscustomobject][ordered]@{ objective=$TaskSpec.objective; nonGoals=@($TaskSpec.nonGoals); contract=$TaskSpec.contract }
  return Get-Hash ($utf8.GetBytes(($identity | ConvertTo-Json -Depth 6 -Compress)))
}

function New-TestGoal {
  param([string]$Root, [string]$GoalLineageId, [string]$ProjectRoot, [string]$ChainId, [string]$DispatchId, [string]$ProblemInvariantId, [string]$StrategyFamilyId, $TaskSpec)
  $goal = [pscustomobject][ordered]@{
    schemaVersion=1; goalLineageId=$GoalLineageId; objectiveFingerprint=(Get-TestObjectiveFingerprint $TaskSpec); state='active'
    createdAt='2026-08-02T23:58:00Z'; updatedAt='2026-08-02T23:58:00Z'
    budget=[pscustomobject][ordered]@{ readinessReplansUsed=0; crossProjectRebaselinesUsed=0 }; readinessFailures=@()
    lanes=@([pscustomobject][ordered]@{ projectRoot=$ProjectRoot; attemptsUsed=0; transientRetriesUsed=0; activeReservation=$null; outcomes=@() })
  }
  $path = Write-GoalCandidate $Root $GoalLineageId $goal
  $created = Invoke-GoalStore GoalPut $Root $GoalLineageId $path MISSING
  Assert-True ($created.ExitCode -eq 0 -and $created.Result.reasonCode -ceq 'goal-created') "Failed to create $GoalLineageId"
  $reservation = New-TestReservation -ReservationId "reservation-$DispatchId" -ChainId $ChainId -DispatchId $DispatchId -ProblemInvariantId $ProblemInvariantId -StrategyFamilyId $StrategyFamilyId -TaskSpec $TaskSpec
  $goal.lanes[0].attemptsUsed = 1; $goal.lanes[0].activeReservation = $reservation; $goal.updatedAt = $reservation.reservedAt
  $path = Write-GoalCandidate $Root $GoalLineageId $goal
  $reserved = Invoke-GoalStore GoalPut $Root $GoalLineageId $path ([string]$created.Result.resultEntryHash)
  Assert-True ($reserved.ExitCode -eq 0 -and $reserved.Result.reasonCode -ceq 'goal-updated') "Failed to reserve $DispatchId"
  return Get-TestGoalBinding $reservation $GoalLineageId
}

function Advance-TestGoal {
  param(
    [string]$Root, [string]$GoalLineageId, [string]$DispatchId, [string]$StrategyFamilyId,
    [string]$Strategy, [int]$AttemptNumber, [string]$FinishedAt, [string]$ReservedAt, [string]$EvidenceHash, $TaskSpec
  )
  $read = Invoke-GoalStore GoalGet $Root $GoalLineageId
  Assert-True ($read.ExitCode -eq 0) "Failed to read $GoalLineageId"
  $goal = Copy-JsonObject $read.Result.data.record; $lane = $goal.lanes[0]; $previous = $lane.activeReservation
  $lane.outcomes = @($lane.outcomes) + @([pscustomobject][ordered]@{ reservation=$previous; outcome='deterministic-failure'; failureClass='review'; evidenceHash=$EvidenceHash; finishedAt=$FinishedAt })
  $lane.activeReservation = $null; $goal.updatedAt = $FinishedAt
  $path = Write-GoalCandidate $Root $GoalLineageId $goal
  $finished = Invoke-GoalStore GoalPut $Root $GoalLineageId $path ([string]$read.Result.resultEntryHash)
  Assert-True ($finished.ExitCode -eq 0) "Failed to finish $($previous.dispatchId)"
  $reservation = New-TestReservation -ReservationId "reservation-$DispatchId" -ChainId $previous.chainId -DispatchId $DispatchId -ProblemInvariantId $previous.problemInvariantId -StrategyFamilyId $StrategyFamilyId -Strategy $Strategy -AttemptNumber $AttemptNumber -ReservedAt $ReservedAt -TaskSpec $TaskSpec
  $materialFields = @('contractVersionHash','targetSetHash','capabilitySetHash','runtimeVersionHash','toolchainVersionHash','authorizationBoundaryHash','failureOracleHash','relevantContentHash')
  $changedFields = @($materialFields | Where-Object { $previous.materialPreconditions.$_ -cne $reservation.materialPreconditions.$_ })
  if ($changedFields.Count -gt 0) {
    $evidenceChainId = "CHAIN-evidence-$DispatchId"
    $evidenceCandidate = Join-Path $Root ($evidenceChainId + '.json')
    $evidenceRecord = New-TestChainRecord $evidenceChainId active running $FinishedAt
    $evidenceRecord.payload.history = @($changedFields | ForEach-Object { [pscustomobject][ordered]@{ field=$_; previousHash=[string]$previous.materialPreconditions.$_; currentHash=[string]$reservation.materialPreconditions.$_; evidenceHash=$EvidenceHash; at=$FinishedAt; reason='direct material change evidence' } })
    [IO.File]::WriteAllText($evidenceCandidate, (($evidenceRecord | ConvertTo-Json -Depth 12 -Compress) + "`n"), $utf8)
    $evidenceCreated = Invoke-GoalStore -Action Put -Root $Root -CandidatePath $evidenceCandidate -ExpectedEntryHash MISSING -ChainId $evidenceChainId
    Assert-True ($evidenceCreated.ExitCode -eq 0) "Failed to create material evidence for $DispatchId"
    $evidenceEvent = ([IO.File]::ReadAllText([string]$evidenceCreated.Result.data.path, $utf8).TrimEnd("`n").Split("`n")[0] | ConvertFrom-Json)
    Add-Member -InputObject $reservation -NotePropertyName materialChangeEvidence -NotePropertyValue @($changedFields | ForEach-Object {
      [pscustomobject][ordered]@{
        field=$_; previousHash=[string]$previous.materialPreconditions.$_; currentHash=[string]$reservation.materialPreconditions.$_
        sourceChainId=$evidenceChainId; sourceEntryHash=[string]$evidenceEvent.entryHash; evidenceHash=$EvidenceHash; observedAt=$FinishedAt
      }
    })
  }
  $goal = Copy-JsonObject $finished.Result.data.record; $goal.lanes[0].attemptsUsed = $AttemptNumber
  $goal.lanes[0].activeReservation = $reservation; $goal.updatedAt = $ReservedAt
  $path = Write-GoalCandidate $Root $GoalLineageId $goal
  $reserved = Invoke-GoalStore GoalPut $Root $GoalLineageId $path ([string]$finished.Result.resultEntryHash)
  Assert-True ($reserved.ExitCode -eq 0) "Failed to reserve ${DispatchId}: $($reserved.Result.reasonCode) $($reserved.Result.nextAction)"
  return Get-TestGoalBinding $reservation $GoalLineageId
}

function Finish-TestGoal {
  param([string]$Root, [string]$GoalLineageId, [string]$Outcome, [string]$FailureClass, [string]$EvidenceHash, [string]$FinishedAt)
  $read = Invoke-GoalStore GoalGet $Root $GoalLineageId
  Assert-True ($read.ExitCode -eq 0) "Failed to read $GoalLineageId"
  $goal = Copy-JsonObject $read.Result.data.record; $reservation = $goal.lanes[0].activeReservation
  $goal.lanes[0].outcomes = @($goal.lanes[0].outcomes) + @([pscustomobject][ordered]@{ reservation=$reservation; outcome=$Outcome; failureClass=$FailureClass; evidenceHash=$EvidenceHash; finishedAt=$FinishedAt })
  $goal.lanes[0].activeReservation = $null; $goal.updatedAt = $FinishedAt
  $path = Write-GoalCandidate $Root $GoalLineageId $goal
  $finished = Invoke-GoalStore GoalPut $Root $GoalLineageId $path ([string]$read.Result.resultEntryHash)
  Assert-True ($finished.ExitCode -eq 0) "Failed to finish $GoalLineageId"
}

function New-TaskSpec {
  param([string]$Name, [string]$Head, [string]$AuthorizationRef, [string]$OperationClass = 'repository-write', [string]$ReturnMode = 'receipts-and-wake')
  $projectId = @($AuthorizationRef.Split(':'))[1]
  $rollback = if ($OperationClass -ceq 'read') { @() } else { @('preserve the working tree and do not commit') }
  return [ordered]@{
    objective="Complete $Name"
    nonGoals=@('commit', 'push', 'deploy')
    acceptance=@('tests pass', 'return terminal evidence')
    authorizedActions=@('read', 'edit', 'test')
    forbiddenActions=@('commit', 'push', 'deploy')
    baseline=[ordered]@{ branch='develop/1.0.0'; head=$Head; dirtyHash=('0' * 64) }
    contract=[ordered]@{ id="contract-$Name"; version='1'; hash=('1' * 64) }
    dependencies=@()
    authorizationRef=$AuthorizationRef
    readiness=[ordered]@{
      status='ready'; checkedAt='2026-08-02T23:59:00Z'; operationClass=$OperationClass
      targets=@("repository:$Name"); capabilityRefs=@()
      rollback=@($rollback)
      verification=@('run the frozen acceptance checks')
    }
    returnRoute=[ordered]@{ mode=$ReturnMode; controllerThreadId='queue-controller-thread'; hostId='queue-host' }
  }
}

if (-not (Test-Path -LiteralPath $subject -PathType Leaf)) { throw "Missing state adapter $subject" }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-state-tests-' + [guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$driveRoot = [IO.Path]::GetPathRoot($resolvedTestRoot)
$driveInfo = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $driveRoot } | Select-Object -First 1)
$fileSystem = if ($driveInfo.Count -eq 1) { [string]$driveInfo[0].DriveFormat } else { '' }

try {
  [IO.Directory]::CreateDirectory($testRoot) | Out-Null
  $root = Join-Path $testRoot 'controller'
  $hash = Write-Manifest $root
  $sentinel = Join-Path $testRoot 'external-sentinel.txt'
  [IO.File]::WriteAllText($sentinel, 'survive')

  $read = Invoke-State Read $root '' '' '' '' ''
  Assert-State $read verified 0 'controller-state-verified'
  Assert-True ($read.Result.currentHash -ceq $hash -and $read.Result.resultHash -ceq $hash) 'Read must report the exact manifest hash'

  $manifestPath = Join-Path $root '.codex-controller.json'
  $validManifestBytes = [IO.File]::ReadAllBytes($manifestPath)
  $validManifest = $utf8.GetString($validManifestBytes) | ConvertFrom-Json
  $tooManyBindings = @()
  for ($index = 0; $index -lt 1001; $index++) {
    $tooManyBindings += [pscustomobject][ordered]@{ entryThreadId="entry-$index"; codexProjectId="project-$index"; hostId='host-boundary'; projectRoot=(Join-Path $testRoot ("boundary-project-$index")) }
  }
  $tooManyManifest = [pscustomobject][ordered]@{ schemaVersion=1; generator='onboard-code-projects'; templateVersion=1; controllerName='State Test'; controllerBinding=$null; controllerTaskIntent=$null; projectBindings=$tooManyBindings }
  $duplicateRoot = Join-Path $testRoot 'Duplicate-Business-Root'
  $duplicateManifest = [pscustomobject][ordered]@{
    schemaVersion=1; generator='onboard-code-projects'; templateVersion=1; controllerName='State Test'; controllerBinding=$null; controllerTaskIntent=$null
    projectBindings=@(
      [pscustomobject][ordered]@{ entryThreadId='entry-duplicate-a'; codexProjectId='project-duplicate-a'; hostId='host-boundary'; projectRoot=$duplicateRoot },
      [pscustomobject][ordered]@{ entryThreadId='entry-duplicate-b'; codexProjectId='project-duplicate-b'; hostId='host-boundary'; projectRoot=$duplicateRoot.ToUpperInvariant() }
    )
  }
  $manifestBoundaryCases = @(
    [pscustomobject]@{ Name='over-1MiB'; Bytes=(New-Object byte[] (1MB + 1)) },
    [pscustomobject]@{ Name='1001-project-bindings'; Bytes=$utf8.GetBytes(($tooManyManifest | ConvertTo-Json -Depth 12 -Compress) + "`n") },
    [pscustomobject]@{ Name='case-insensitive-duplicate-root'; Bytes=$utf8.GetBytes(($duplicateManifest | ConvertTo-Json -Depth 12 -Compress) + "`n") },
    [pscustomobject]@{ Name='utf8-bom'; Bytes=[byte[]](@(0xEF,0xBB,0xBF) + @($validManifestBytes)) },
    [pscustomobject]@{ Name='pretty-crlf'; Bytes=$utf8.GetBytes(($validManifest | ConvertTo-Json -Depth 12).Replace("`n", "`r`n") + "`r`n") }
  )
  foreach ($boundaryCase in $manifestBoundaryCases) {
    [IO.File]::WriteAllBytes($manifestPath, [byte[]]$boundaryCase.Bytes)
    $boundaryRead = Invoke-State Read $root '' '' '' '' ''
    Assert-State $boundaryRead conflict 1 'controller-manifest-invalid'
    Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($manifestPath), [byte[]]$boundaryCase.Bytes)) "Read must preserve invalid manifest bytes for $($boundaryCase.Name)"
    [IO.File]::WriteAllBytes($manifestPath, $validManifestBytes)
    Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($manifestPath), $validManifestBytes)) "Boundary test must restore the legal manifest after $($boundaryCase.Name)"
  }

  $invalidBindingRoot = Join-Path $testRoot 'invalid-binding-root'
  $otherControllerRoot = Join-Path $testRoot 'other-controller-root'
  Write-Manifest $invalidBindingRoot ([pscustomobject][ordered]@{ threadId='thread-x'; codexProjectId='project-x'; hostId='host-x'; projectRoot=$otherControllerRoot }) | Out-Null
  $invalidBindingRead = Invoke-State Read $invalidBindingRoot '' '' '' '' ''
  Assert-State $invalidBindingRead conflict 1 'controller-manifest-invalid'

  $invalidIntentRoot = Join-Path $testRoot 'invalid-intent-root'
  Write-Manifest $invalidIntentRoot $null ([pscustomobject][ordered]@{ operationId='op-x'; codexProjectId='project-x'; hostId='host-x'; projectRoot=$otherControllerRoot; startedAt='2026-08-02T00:00:00Z'; clientThreadId=$null }) | Out-Null
  $invalidIntentRead = Invoke-State Read $invalidIntentRoot '' '' '' '' ''
  Assert-State $invalidIntentRead conflict 1 'controller-manifest-invalid'

  $invalidProjectRoot = Join-Path $testRoot 'invalid-project-overlap'
  $overlappingProject = Join-Path $invalidProjectRoot 'business-child'
  Write-Manifest $invalidProjectRoot $null $null @([pscustomobject][ordered]@{ entryThreadId='entry-x'; codexProjectId='project-x'; hostId='host-x'; projectRoot=$overlappingProject }) | Out-Null
  $invalidProjectRead = Invoke-State Read $invalidProjectRoot '' '' '' '' ''
  Assert-State $invalidProjectRead conflict 1 'controller-manifest-invalid'

  $invalidProjectParentRoot = Join-Path $testRoot 'invalid-project-parent-overlap'
  Write-Manifest $invalidProjectParentRoot $null $null @([pscustomobject][ordered]@{ entryThreadId='entry-parent'; codexProjectId='project-parent'; hostId='host-x'; projectRoot=$testRoot }) | Out-Null
  $invalidProjectParentRead = Invoke-State Read $invalidProjectParentRoot '' '' '' '' ''
  Assert-State $invalidProjectParentRead conflict 1 'controller-manifest-invalid'

  $aliasBusinessTarget = Join-Path $testRoot 'alias-business-target'
  $aliasBusinessRoot = Join-Path $testRoot 'alias-business-root'
  $aliasControllerRoot = Join-Path $aliasBusinessTarget 'controller'
  [IO.Directory]::CreateDirectory($aliasBusinessTarget) | Out-Null
  $aliasCreated = $false
  try {
    New-Item -ItemType Junction -Path $aliasBusinessRoot -Target $aliasBusinessTarget | Out-Null
    $aliasCreated = $true
  }
  catch {
    if ($fileSystem -ceq 'NTFS') { throw "Project-root junction creation must succeed on NTFS: $($_.Exception.Message)" }
    Write-Warning "SKIP project-root alias overlap test on $fileSystem filesystem: $($_.Exception.Message)"
  }
  if ($aliasCreated) {
    Write-Manifest $aliasControllerRoot $null $null @([pscustomobject][ordered]@{ entryThreadId='entry-alias'; codexProjectId='project-alias'; hostId='host-alias'; projectRoot=$aliasBusinessRoot }) | Out-Null
    $aliasOverlapRead = Invoke-State Read $aliasControllerRoot '' '' '' '' ''
    Assert-State $aliasOverlapRead conflict 1 'controller-manifest-invalid'
  }

  $projectRoot = $root
  $wrongControllerRoot = Join-Path $testRoot 'wrong-saved-controller-project'
  [IO.Directory]::CreateDirectory($wrongControllerRoot) | Out-Null
  $wrongRootIntent = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-wrong-root'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$wrongControllerRoot; startedAt='2026-08-02T00:00:00Z' })
  Assert-State $wrongRootIntent invalid 2 'controller-payload-invalid'
  $intentPayload = [ordered]@{ operationId='op-1'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:00.000Z' }
  $intentPrepare = Prepare $root $hash 'set-task-intent' $intentPayload
  Assert-State $intentPrepare prepared 0 'controller-candidate-prepared'
  Assert-True ((Get-Hash ([IO.File]::ReadAllBytes((Join-Path $root '.codex-controller.json')))) -ceq $hash) 'Prepare must not change the manifest'

  $orphanBlocked = Prepare $root $hash 'set-task-intent' $intentPayload
  Assert-State $orphanBlocked conflict 1 'controller-candidate-orphaned'
  Assert-True ($orphanBlocked.Result.candidatePath -ceq $intentPrepare.Result.candidatePath -and $orphanBlocked.Result.candidateHash -ceq $intentPrepare.Result.candidateHash) 'Orphan conflict must return the exact removable candidate path and hash'
  Assert-True ($orphanBlocked.Result.nextAction -cmatch [regex]::Escape((Split-Path -Leaf $intentPrepare.Result.candidatePath)) -and $orphanBlocked.Result.nextAction -cmatch $intentPrepare.Result.candidateHash) 'Orphan recovery must name the exact candidate and SHA-256'
  $wrongRemove = Invoke-State RemoveCandidate $root '' '' '' $intentPrepare.Result.candidatePath ('0' * 64) $true
  Assert-State $wrongRemove conflict 1 'controller-candidate-hash-mismatch'
  Assert-True (Test-Path -LiteralPath $intentPrepare.Result.candidatePath -PathType Leaf) 'Wrong cleanup hash must not delete the candidate'
  $removed = Invoke-State RemoveCandidate $root '' '' '' $intentPrepare.Result.candidatePath $intentPrepare.Result.candidateHash $true
  Assert-State $removed removed 0 'controller-candidate-removed'
  Assert-True (-not (Test-Path -LiteralPath $intentPrepare.Result.candidatePath)) 'RemoveCandidate success must prove the exact candidate is absent'
  $unsafeOrphan = Join-Path $root ('.codex-controller.' + [guid]::NewGuid().ToString('N') + '.tmp')
  [IO.Directory]::CreateDirectory($unsafeOrphan) | Out-Null
  $unsafeOrphanResult = Prepare $root $hash 'set-task-intent' $intentPayload
  Assert-State $unsafeOrphanResult conflict 1 'controller-filesystem-conflict'
  Assert-True ($null -eq $unsafeOrphanResult.Result.candidateHash) 'Unsafe orphan directory must not be read or hashed'
  [IO.Directory]::Delete($unsafeOrphan)
  $intentPrepare = Prepare $root $hash 'set-task-intent' $intentPayload
  Assert-State $intentPrepare prepared 0 'controller-candidate-prepared'
  $intentApply = Apply $root $hash $intentPrepare
  Assert-State $intentApply applied 0 'controller-state-applied'
  $hash = [string]$intentApply.Result.resultHash
  Assert-True ($intentApply.Result.data.controllerTaskIntent.operationId -ceq 'op-1' -and $null -eq $intentApply.Result.data.controllerTaskIntent.clientThreadId) 'set-task-intent must create a durable intent'

  $duplicateIntent = Prepare $root $hash 'set-task-intent' $intentPayload
  Assert-State $duplicateIntent conflict 1 'controller-task-state-conflict'
  $unknown = Prepare $root $hash 'record-client-thread' ([ordered]@{ operationId='op-1'; clientThreadId='client-1'; unknown=$true })
  Assert-State $unknown invalid 2 'controller-payload-invalid'
  $wrongType = Prepare $root $hash 'record-client-thread' ([ordered]@{ operationId='op-1'; clientThreadId=7 })
  Assert-State $wrongType invalid 2 'controller-payload-invalid'

  $record = Mutate $root $hash 'record-client-thread' ([ordered]@{ operationId='op-1'; clientThreadId='client-1' })
  $hash = [string]$record.Result.resultHash
  Assert-True ($record.Result.data.controllerTaskIntent.clientThreadId -ceq 'client-1') 'record-client-thread must preserve intent and store only diagnostics'
  $recordSame = Mutate $root $hash 'record-client-thread' ([ordered]@{ operationId='op-1'; clientThreadId='client-1' })
  $hash = [string]$recordSame.Result.resultHash
  $recordDifferent = Prepare $root $hash 'record-client-thread' ([ordered]@{ operationId='op-1'; clientThreadId='client-other' })
  Assert-State $recordDifferent conflict 1 'controller-task-state-conflict'

  $wrongRootBind = Prepare $root $hash 'bind-controller' ([ordered]@{ operationId='op-1'; threadId='thread-1'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$wrongControllerRoot })
  Assert-State $wrongRootBind conflict 1 'controller-task-state-conflict'

  $bind = Mutate $root $hash 'bind-controller' ([ordered]@{ operationId='op-1'; threadId='thread-1'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot })
  $hash = [string]$bind.Result.resultHash
  Assert-True ($null -eq $bind.Result.data.controllerTaskIntent -and $bind.Result.data.controllerBinding.threadId -ceq 'thread-1') 'bind-controller must clear intent and bind exact task identity'

  $businessRoot = Join-Path $testRoot 'business-A'
  [IO.Directory]::CreateDirectory($businessRoot) | Out-Null
  $registerPayload = [ordered]@{ entryThreadId='entry-1'; codexProjectId='project-A'; hostId='host-1'; projectRoot=$businessRoot }
  $register = Mutate $root $hash 'register-project' $registerPayload
  $hash = [string]$register.Result.resultHash
  Assert-True (@($register.Result.data.projectBindings).Count -eq 1) 'register-project must append one binding'
  $idempotent = Mutate $root $hash 'register-project' $registerPayload
  $hash = [string]$idempotent.Result.resultHash
  Assert-True (@($idempotent.Result.data.projectBindings).Count -eq 1) 'Exact project registration must be idempotent'
  $registerConflict = Prepare $root $hash 'register-project' ([ordered]@{ entryThreadId='entry-2'; codexProjectId='project-B'; hostId='host-1'; projectRoot=$businessRoot })
  Assert-State $registerConflict conflict 1 'project-binding-conflict'
  $registerOverlap = Prepare $root $hash 'register-project' ([ordered]@{ entryThreadId='entry-overlap'; codexProjectId='project-overlap'; hostId='host-1'; projectRoot=(Join-Path $root 'business-child') })
  Assert-State $registerOverlap invalid 2 'controller-payload-invalid'

  $queueRoot = Join-Path $testRoot 'queue-controller'
  $queueBusinessA = Join-Path $testRoot 'queue-business-A'
  $queueBusinessB = Join-Path $testRoot 'queue-business-B'
  $queueBusinessC = Join-Path $testRoot 'queue-business-C'
  [IO.Directory]::CreateDirectory($queueBusinessA) | Out-Null
  [IO.Directory]::CreateDirectory($queueBusinessB) | Out-Null
  [IO.Directory]::CreateDirectory($queueBusinessC) | Out-Null
  $queueBinding = [pscustomobject][ordered]@{ threadId='queue-controller-thread'; codexProjectId='queue-controller-project'; hostId='queue-host'; projectRoot=$queueRoot }
  $queueProjects = @(
    [pscustomobject][ordered]@{ entryThreadId='entry-A'; codexProjectId='project-A'; hostId='queue-host'; projectRoot=$queueBusinessA },
    [pscustomobject][ordered]@{ entryThreadId='entry-B'; codexProjectId='project-B'; hostId='queue-host'; projectRoot=$queueBusinessB },
    [pscustomobject][ordered]@{ entryThreadId='entry-C'; codexProjectId='project-C'; hostId='queue-host'; projectRoot=$queueBusinessC }
  )
  $queueHash = Write-Manifest $queueRoot $queueBinding $null $queueProjects 2
  $queueRead = Invoke-State Read $queueRoot '' '' '' '' ''
  Assert-State $queueRead verified 0 'controller-state-verified'
  $runtimeInfo = Invoke-State RuntimeInfo $queueRoot '' '' '' '' ''
  Assert-State $runtimeInfo verified 0 'controller-runtime-verified'
  Assert-True ($runtimeInfo.Result.data.controllerRuntimeHash -ceq (Get-TestRuntimeHash) -and @($runtimeInfo.Result.data.files).Count -eq 2) 'RuntimeInfo must expose the exact immutable dispatch runtime hash'
  $goalStoreInit = Invoke-GoalStore Initialize $queueRoot
  Assert-True ($goalStoreInit.ExitCode -eq 0 -and $goalStoreInit.Result.reasonCode -ceq 'store-initialized') 'Queue controller must initialize its canonical goal store'

  $taskSpecA1 = New-TaskSpec 'A1' ('a' * 40) 'authref:project-A:A1'
  $taskSpecA2 = New-TaskSpec 'A2' ('b' * 40) 'authref:project-A:A2' 'read'
  $taskSpecA2.baseline = [ordered]@{ branch='N/A'; head='N/A'; dirtyHash='N/A' }
  $taskSpecA2.contract = [ordered]@{ id='N/A'; version='N/A'; hash='N/A' }
  $taskSpecB1 = New-TaskSpec 'B1' ('c' * 40) 'authref:project-B:B1' 'read' 'receipts-and-wake'
  $taskSpecC1 = New-TaskSpec 'C1' ('d' * 40) 'authref:project-C:C1' 'read'
  $taskSpecA2.authorizedActions = @('read', 'test')
  $taskSpecB1.authorizedActions = @('read', 'test')
  $taskSpecC1.authorizedActions = @('read', 'test')
  $taskSpecA1.goalBinding = New-TestGoal $queueRoot 'GOAL-A1' $queueBusinessA 'CHAIN-A1' 'dispatch-A1' 'problem.A1' 'strategy.A1-initial' $taskSpecA1
  $taskSpecA2.goalBinding = New-TestGoal $queueRoot 'GOAL-A2' $queueBusinessA 'CHAIN-A2' 'dispatch-A2' 'problem.A2' 'strategy.A2-initial' $taskSpecA2
  $taskSpecB1.goalBinding = New-TestGoal $queueRoot 'GOAL-B1' $queueBusinessB 'CHAIN-B1' 'dispatch-B1' 'problem.B1' 'strategy.B1-initial' $taskSpecB1
  $taskSpecC1.goalBinding = New-TestGoal $queueRoot 'GOAL-C1' $queueBusinessC 'CHAIN-C1' 'dispatch-C1' 'problem.C1' 'strategy.C1-initial' $taskSpecC1
  $retryTaskSpecA1 = ($taskSpecA1 | ConvertTo-Json -Depth 12 -Compress) | ConvertFrom-Json
  $retryTaskSpecA1.baseline.head = ('9' * 40)
  $retryTaskSpecA1.baseline.dirtyHash = ('8' * 64)
  $retryTaskSpecA1.acceptance = @($retryTaskSpecA1.acceptance) + @('continue from the proven prior attempt state')
  $retryTaskSpecA1.dependencies = @()
  $retryTaskSpecA1.readiness.checkedAt = '2026-08-03T00:02:30Z'
  $retryTaskSpecA1.readiness.verification = @('refreshed retry baseline verified')
  $dispatchA1 = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-A1'; projectTaskId='entry-A'; dispatchId='dispatch-A1'; generation=1; rework=0; accessMode='write'; modelClass='balanced'; taskSpec=$taskSpecA1; enqueuedAt='2026-08-03T00:00:00Z' }
  $dispatchA2 = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-A2'; projectTaskId='entry-A'; dispatchId='dispatch-A2'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$taskSpecA2; enqueuedAt='2026-08-03T00:00:01Z' }
  $dispatchB1 = [ordered]@{ projectRoot=$queueBusinessB; chainId='CHAIN-B1'; projectTaskId='entry-B'; dispatchId='dispatch-B1'; generation=1; rework=0; accessMode='read'; modelClass='frontier'; taskSpec=$taskSpecB1; enqueuedAt='2026-08-03T00:00:02Z' }
  $dispatchC1 = [ordered]@{ projectRoot=$queueBusinessC; chainId='CHAIN-C1'; projectTaskId='entry-C'; dispatchId='dispatch-C1'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$taskSpecC1; enqueuedAt='2026-08-03T00:00:03Z' }
  $unboundDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-unbound'; projectTaskId='entry-A'; dispatchId='dispatch-unbound'; generation=1; rework=0; accessMode='write'; modelClass='balanced'; taskSpec=(New-TaskSpec 'unbound' ('e' * 40) 'authref:project-A:unbound'); enqueuedAt='2026-08-03T00:00:00Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $unboundDispatch) invalid 2 'controller-payload-invalid'
  $wrongObjectiveDispatch = Copy-JsonObject $dispatchA1
  $wrongObjectiveDispatch.taskSpec.objective = 'A different objective must not borrow this reservation'
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $wrongObjectiveDispatch) conflict 1 'controller-task-state-conflict'
  foreach ($dispatch in @($dispatchA1, $dispatchA2, $dispatchB1, $dispatchC1)) {
    try { $queued = Mutate $queueRoot $queueHash 'enqueue-dispatch' $dispatch }
    catch { throw "enqueue $($dispatch.dispatchId) failed: $($_.Exception.Message)" }
    $queueHash = [string]$queued.Result.resultHash
  }
  $duplicateQueue = Mutate $queueRoot $queueHash 'enqueue-dispatch' $dispatchA2
  $queueHash = [string]$duplicateQueue.Result.resultHash
  $queueA = @($duplicateQueue.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0]
  Assert-True (@($queueA.pending).Count -eq 2) 'Exact enqueue replay must not duplicate a pending dispatch'
  Assert-True ($queueA.pending[0].taskSpecHash -cmatch '^[0-9a-f]{64}$' -and $queueA.pending[0].taskSpec.objective -ceq 'Complete A1') 'Enqueue must persist the canonical taskSpec and its SHA-256 before delivery'
  $sealedIdentity = $queueA.pending[0].taskSpec.dispatchIdentity
  Assert-True ($sealedIdentity.chainId -ceq 'CHAIN-A1' -and $sealedIdentity.projectTaskId -ceq 'entry-A' -and
    $sealedIdentity.dispatchId -ceq 'dispatch-A1' -and $sealedIdentity.generation -eq 1 -and $sealedIdentity.rework -eq 0) `
    'The taskSpec hash must bind the complete dispatch identity before delivery'

  $queueManifestPath = Join-Path $queueRoot '.codex-controller.json'
  $queueManifestBytes = [IO.File]::ReadAllBytes($queueManifestPath)
  $tamperedIdentity = $utf8.GetString($queueManifestBytes) | ConvertFrom-Json -ErrorAction Stop
  $tamperedIdentity.dispatchQueues[0].pending[0].taskSpec.dispatchIdentity.generation = 2
  [IO.File]::WriteAllBytes($queueManifestPath, $utf8.GetBytes(($tamperedIdentity | ConvertTo-Json -Depth 12 -Compress) + "`n"))
  Assert-State (Invoke-State Read $queueRoot '' '' '' '' '') conflict 1 'controller-manifest-invalid'
  [IO.File]::WriteAllBytes($queueManifestPath, $queueManifestBytes)
  Assert-State (Invoke-State Read $queueRoot '' '' '' '' '') verified 0 'controller-state-verified'
  $unsafeControllerTexts = @(
    ('g' + 'hp_' + ('0' * 36)),
    ('sk-' + 'proj-' + ('0' * 36)),
    ('AK' + 'IA' + 'ABCDEFGHIJKLMNOP'),
    'https://example.invalid/path?access_token=should-never-enter-controller-history',
    ('-----BEGIN ' + 'PRIVATE KEY-----'),
    ('Use Authorization: ' + 'Bear' + 'er should-never-enter-controller-history'),
    "line one`nline two"
  )
  for ($unsafeIndex = 0; $unsafeIndex -lt $unsafeControllerTexts.Count; $unsafeIndex++) {
    $secretSpec = New-TaskSpec "secret-$unsafeIndex" ('d' * 40) "authref:project-A:secret-$unsafeIndex"
    $secretSpec.objective = $unsafeControllerTexts[$unsafeIndex]
    $secretSpec.authorizedActions = @('read', 'test')
    $secretDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId="CHAIN-secret-$unsafeIndex"; projectTaskId='entry-A'; dispatchId="dispatch-secret-$unsafeIndex"; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$secretSpec; enqueuedAt='2026-08-03T00:00:03Z' }
    $secretRejected = Prepare $queueRoot $queueHash 'enqueue-dispatch' $secretDispatch
    Assert-State $secretRejected invalid 2 'controller-payload-invalid'
  }
  $conflictingSpec = New-TaskSpec 'conflict' ('e' * 40) 'authref:project-A:conflict'
  $conflictingSpec.authorizedActions = @('read', 'commit')
  $conflictingDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-conflict'; projectTaskId='entry-A'; dispatchId='dispatch-conflict'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$conflictingSpec; enqueuedAt='2026-08-03T00:00:04Z' }
  $conflictRejected = Prepare $queueRoot $queueHash 'enqueue-dispatch' $conflictingDispatch
  Assert-State $conflictRejected invalid 2 'controller-payload-invalid'

  $missingReadinessSpec = New-TaskSpec 'missing-readiness' ('f' * 40) 'authref:project-A:missing-readiness' 'read'
  $missingReadinessSpec.Remove('readiness')
  $missingReadinessDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-missing-readiness'; projectTaskId='entry-A'; dispatchId='dispatch-missing-readiness'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$missingReadinessSpec; enqueuedAt='2026-08-03T00:00:05Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $missingReadinessDispatch) invalid 2 'controller-payload-invalid'

  $wrongRouteSpec = New-TaskSpec 'wrong-route' ('f' * 40) 'authref:project-A:wrong-route' 'read'
  $wrongRouteSpec.returnRoute.controllerThreadId = 'another-controller'
  $wrongRouteDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-wrong-route'; projectTaskId='entry-A'; dispatchId='dispatch-wrong-route'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$wrongRouteSpec; enqueuedAt='2026-08-03T00:00:06Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $wrongRouteDispatch) invalid 2 'controller-payload-invalid'

  $externalSpec = New-TaskSpec 'external-without-capability' ('f' * 40) 'authref:project-A:external-without-capability' 'external-write'
  $externalDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-external-without-capability'; projectTaskId='entry-A'; dispatchId='dispatch-external-without-capability'; generation=1; rework=0; accessMode='write'; modelClass='frontier'; taskSpec=$externalSpec; enqueuedAt='2026-08-03T00:00:07Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $externalDispatch) invalid 2 'controller-payload-invalid'

  foreach ($locator in @('C:\fixtures\credentials.xlsx', '\\server\share\client.pem', 'relative\secrets.kdbx')) {
    $locatorSpec = New-TaskSpec 'credential-locator' ('f' * 40) 'authref:project-A:credential-locator' 'read'
    $locatorSpec.authorizedActions = @('read', 'test')
    $locatorSpec.readiness.targets = @($locator)
    $locatorDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-credential-locator'; projectTaskId='entry-A'; dispatchId='dispatch-credential-locator'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$locatorSpec; enqueuedAt='2026-08-03T00:00:08Z' }
    Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $locatorDispatch) invalid 2 'controller-payload-invalid'
  }

  $externalReadySpec = New-TaskSpec 'external-ready' ('f' * 40) 'authref:project-A:external-ready' 'external-write'
  $externalReadySpec.readiness.capabilityRefs = @('capref:project-A:external-ready')
  $externalReadySpec.goalBinding = New-TestGoal $queueRoot 'GOAL-external-ready' $queueBusinessA 'CHAIN-external-ready' 'dispatch-external-ready' 'problem.external-ready' 'strategy.external-ready-initial' $externalReadySpec
  $externalReadyDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-external-ready'; projectTaskId='entry-A'; dispatchId='dispatch-external-ready'; generation=1; rework=0; accessMode='write'; modelClass='frontier'; taskSpec=$externalReadySpec; enqueuedAt='2026-08-03T00:00:09Z' }
  $externalReadyPrepared = Prepare $queueRoot $queueHash 'enqueue-dispatch' $externalReadyDispatch
  Assert-State $externalReadyPrepared prepared 0 'controller-candidate-prepared'
  Assert-State (Invoke-State RemoveCandidate $queueRoot '' '' '' $externalReadyPrepared.Result.candidatePath $externalReadyPrepared.Result.candidateHash $true) removed 0 'controller-candidate-removed'

  $dependencyChainId = 'CHAIN-dependency'
  $dependencyCandidate = Join-Path $queueRoot 'dependency-chain.candidate.json'
  $dependencyRecord = New-TestChainRecord $dependencyChainId
  [IO.File]::WriteAllText($dependencyCandidate, (($dependencyRecord | ConvertTo-Json -Depth 12 -Compress) + "`n"), $utf8)
  $dependencyCreated = Invoke-GoalStore -Action Put -Root $queueRoot -CandidatePath $dependencyCandidate -ExpectedEntryHash MISSING -ChainId $dependencyChainId
  Assert-True ($dependencyCreated.ExitCode -eq 0) 'Dependency fixture must create one canonical active CHAIN'
  $dependencySpec = New-TaskSpec 'dependency-ready' ('f' * 40) 'authref:project-A:dependency-ready' 'read'
  $dependencySpec.authorizedActions = @('read', 'test')
  $dependencySpec.dependencies = @([pscustomobject][ordered]@{ chainId=$dependencyChainId; allowedTerminalStatuses=@('completed','cancelled') })
  $dependencySpec.goalBinding = New-TestGoal $queueRoot 'GOAL-dependency-ready' $queueBusinessA 'CHAIN-dependency-ready' 'dispatch-dependency-ready' 'problem.dependency-ready' 'strategy.dependency-ready-initial' $dependencySpec
  $dependencyDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-dependency-ready'; projectTaskId='entry-A'; dispatchId='dispatch-dependency-ready'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$dependencySpec; enqueuedAt='2026-08-03T00:00:10Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $dependencyDispatch) conflict 1 'dispatch-dependency-pending'
  $dependencyRecord = New-TestChainRecord $dependencyChainId terminal cancelled '2026-08-03T00:00:11Z'
  [IO.File]::WriteAllText($dependencyCandidate, (($dependencyRecord | ConvertTo-Json -Depth 12 -Compress) + "`n"), $utf8)
  $dependencyTerminal = Invoke-GoalStore -Action Put -Root $queueRoot -CandidatePath $dependencyCandidate -ExpectedEntryHash ([string]$dependencyCreated.Result.resultEntryHash) -ChainId $dependencyChainId -ConfirmTerminal $true
  Assert-True ($dependencyTerminal.ExitCode -eq 0) 'Dependency fixture must become terminal cancelled'
  $cancelAllowed = Prepare $queueRoot $queueHash 'enqueue-dispatch' $dependencyDispatch
  Assert-State $cancelAllowed prepared 0 'controller-candidate-prepared'
  Assert-State (Invoke-State RemoveCandidate $queueRoot '' '' '' $cancelAllowed.Result.candidatePath $cancelAllowed.Result.candidateHash $true) removed 0 'controller-candidate-removed'
  $dependencyRejectedSpec = New-TaskSpec 'dependency-rejected' ('f' * 40) 'authref:project-A:dependency-rejected' 'read'
  $dependencyRejectedSpec.authorizedActions = @('read', 'test')
  $dependencyRejectedSpec.dependencies = @([pscustomobject][ordered]@{ chainId=$dependencyChainId; allowedTerminalStatuses=@('completed') })
  $dependencyRejectedSpec.goalBinding = New-TestGoal $queueRoot 'GOAL-dependency-rejected' $queueBusinessA 'CHAIN-dependency-rejected' 'dispatch-dependency-rejected' 'problem.dependency-rejected' 'strategy.dependency-rejected-initial' $dependencyRejectedSpec
  $dependencyRejectedDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-dependency-rejected'; projectTaskId='entry-A'; dispatchId='dispatch-dependency-rejected'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$dependencyRejectedSpec; enqueuedAt='2026-08-03T00:00:12Z' }
  Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $dependencyRejectedDispatch) conflict 1 'dispatch-dependency-unsatisfied'

  $dependencyStoreSpec = New-TaskSpec 'dependency-store-invalid' ('f' * 40) 'authref:project-A:dependency-store-invalid' 'read'
  $dependencyStoreSpec.authorizedActions = @('read', 'test')
  $dependencyStoreSpec.dependencies = @([pscustomobject][ordered]@{ chainId=$dependencyChainId; allowedTerminalStatuses=@('cancelled') })
  $dependencyStoreSpec.goalBinding = New-TestGoal $queueRoot 'GOAL-dependency-store-invalid' $queueBusinessA 'CHAIN-dependency-store-invalid' 'dispatch-dependency-store-invalid' 'problem.dependency-store-invalid' 'strategy.dependency-store-invalid-initial' $dependencyStoreSpec
  $dependencyStoreDispatch = [ordered]@{ projectRoot=$queueBusinessA; chainId='CHAIN-dependency-store-invalid'; projectTaskId='entry-A'; dispatchId='dispatch-dependency-store-invalid'; generation=1; rework=0; accessMode='read'; modelClass='economy'; taskSpec=$dependencyStoreSpec; enqueuedAt='2026-08-03T00:00:13Z' }
  $chainIndexPath = Join-Path $queueRoot 'state\index.json'
  $chainIndexBytes = [IO.File]::ReadAllBytes($chainIndexPath)
  try {
    [IO.File]::WriteAllText($chainIndexPath, "not-json`n", $utf8)
    Assert-State (Prepare $queueRoot $queueHash 'enqueue-dispatch' $dependencyStoreDispatch) conflict 1 'dispatch-dependency-state-invalid'
  }
  finally { [IO.File]::WriteAllBytes($chainIndexPath, $chainIndexBytes) }

  $startA1TooEarly = Prepare $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; startedAt='2026-08-02T23:59:59Z'; leaseId='lease-A' })
  Assert-State $startA1TooEarly conflict 1 'controller-task-state-conflict'
  $startA1 = Mutate $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; startedAt='2026-08-03T00:01:00Z'; leaseId='lease-A' })
  $queueHash = [string]$startA1.Result.resultHash
  $taskSpecHashA1 = [string](@($startA1.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active.taskSpecHash)
  $exportedA1 = Export-Dispatch $queueRoot $queueHash ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1' })
  Assert-True ((@($exportedA1.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,kind,chainId,projectTaskId,dispatchId,generation,rework,taskSpecHash,taskSpec,dispatchHash') `
    'ExportDispatch must emit one closed JSON envelope without prose or Base64 parser rules'
  $exportCore = [ordered]@{
    schemaVersion=$exportedA1.schemaVersion; kind=$exportedA1.kind; chainId=$exportedA1.chainId
    projectTaskId=$exportedA1.projectTaskId; dispatchId=$exportedA1.dispatchId; generation=$exportedA1.generation
    rework=$exportedA1.rework; taskSpecHash=$exportedA1.taskSpecHash; taskSpec=$exportedA1.taskSpec
  }
  Assert-True ($exportedA1.dispatchHash -ceq (Get-Hash ($utf8.GetBytes(($exportCore | ConvertTo-Json -Depth 12 -Compress))))) `
    'ExportDispatch must seal the exact outer identity and canonical taskSpec in one hash'
  $startA2Early = Prepare $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A2'; startedAt='2026-08-03T00:01:01Z'; leaseId=$null })
  Assert-State $startA2Early conflict 1 'controller-task-state-conflict'
  $startB1 = Mutate $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; startedAt='2026-08-03T00:01:02Z'; leaseId=$null })
  $queueHash = [string]$startB1.Result.resultHash
  $taskSpecHashB1 = [string](@($startB1.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0].active.taskSpecHash)
  Assert-True (@($startB1.Result.data.dispatchQueues | Where-Object { $null -ne $_.active }).Count -eq 2) 'Independent projects must run concurrently'
  $startC1 = Mutate $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; startedAt='2026-08-03T00:01:03Z'; leaseId=$null })
  $queueHash = [string]$startC1.Result.resultHash
  $taskSpecHashC1 = [string](@($startC1.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessC })[0].active.taskSpecHash)

  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $firstTransient = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; taskSpecHash=$taskSpecHashC1; resultState='blocked'; failureClass='payload-parse'; evidenceHash=('3' * 64); finishedAt='2026-08-03T00:01:10Z' })
  $queueHash = [string]$firstTransient.Result.resultHash
  $firstTransientPayload = [ordered]@{
    projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; failureClass='payload-parse'; evidenceHash=('3' * 64)
    confirmedAt='2026-08-03T00:01:11Z'
    observedBaseline=[ordered]@{ dirtyHash=$taskSpecC1.baseline.dirtyHash; head=$taskSpecC1.baseline.head; branch=$taskSpecC1.baseline.branch }
  }
  $firstTransientReopened = Mutate $queueRoot $queueHash 'reconcile-preflight-failure' $firstTransientPayload
  $queueHash = [string]$firstTransientReopened.Result.resultHash
  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $secondTransient = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessC; dispatchId='dispatch-C1'; taskSpecHash=$taskSpecHashC1; resultState='blocked'; failureClass='payload-parse'; evidenceHash=('3' * 64); finishedAt='2026-08-03T00:01:12Z' })
  $queueHash = [string]$secondTransient.Result.resultHash
  $secondTransientPayload = [ordered]@{}
  foreach ($key in $firstTransientPayload.Keys) { $secondTransientPayload[$key] = $firstTransientPayload[$key] }
  $secondTransientPayload.confirmedAt = '2026-08-03T00:01:13Z'
  Assert-State (Prepare $queueRoot $queueHash 'reconcile-preflight-failure' $secondTransientPayload) conflict 1 'controller-task-state-conflict'

  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $preflightBlocked = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; taskSpecHash=$taskSpecHashB1; resultState='blocked'; failureClass='payload-parse'; evidenceHash=('2' * 64); finishedAt='2026-08-03T00:01:10Z' })
  $queueHash = [string]$preflightBlocked.Result.resultHash
  $preflightPayload = [ordered]@{
    projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; failureClass='payload-parse'; evidenceHash=('2' * 64)
    confirmedAt='2026-08-03T00:01:11Z'
    observedBaseline=[ordered]@{ dirtyHash=$taskSpecB1.baseline.dirtyHash; head=$taskSpecB1.baseline.head; branch=$taskSpecB1.baseline.branch }
  }
  $reviewCannotBeFree = [ordered]@{}
  foreach ($key in $preflightPayload.Keys) { $reviewCannotBeFree[$key] = $preflightPayload[$key] }
  $reviewCannotBeFree.failureClass = 'review'
  Assert-State (Prepare $queueRoot $queueHash 'reconcile-preflight-failure' $reviewCannotBeFree) invalid 2 'controller-payload-invalid'
  $mismatchedPreflight = [ordered]@{}
  foreach ($key in $preflightPayload.Keys) { $mismatchedPreflight[$key] = $preflightPayload[$key] }
  $mismatchedPreflight.failureClass = 'transport'
  Assert-State (Prepare $queueRoot $queueHash 'reconcile-preflight-failure' $mismatchedPreflight) conflict 1 'controller-task-state-conflict'
  $preflightReopened = Mutate $queueRoot $queueHash 'reconcile-preflight-failure' $preflightPayload
  $queueHash = [string]$preflightReopened.Result.resultHash
  $preflightActive = @($preflightReopened.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0].active
  Assert-True ($preflightActive.phase -ceq 'dispatching' -and $preflightActive.generation -eq 1 -and $preflightActive.rework -eq 0 -and
    @($preflightActive.attemptFailures).Count -eq 0 -and $preflightActive.taskSpecHash -ceq $taskSpecHashB1 -and
    @($preflightActive.deliveryReconciliation.PSObject.Properties.Name).Count -eq 2 -and
    $preflightActive.deliveryReconciliation.evidenceHash -ceq ('2' * 64)) `
    'A proven zero-repository preflight failure must reopen the same attempt without consuming business convergence budget'
  $duplicatePreflight = [ordered]@{}
  foreach ($key in $preflightPayload.Keys) { $duplicatePreflight[$key] = $preflightPayload[$key] }
  $duplicatePreflight.evidenceHash = ('4' * 64); $duplicatePreflight.confirmedAt = '2026-08-03T00:01:12Z'
  Assert-State (Prepare $queueRoot $queueHash 'reconcile-preflight-failure' $duplicatePreflight) conflict 1 'controller-task-state-conflict'

  $sentA1 = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; phase='sent' })
  $queueHash = [string]$sentA1.Result.resultHash
  $lateExportPayload = ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1' } | ConvertTo-Json -Compress)
  Assert-State (Invoke-State ExportDispatch $queueRoot $queueHash '' $lateExportPayload '' '') conflict 1 'controller-task-state-conflict'
  $unknownA1 = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; phase='delivery-unknown' })
  $queueHash = [string]$unknownA1.Result.resultHash
  $retryUnknown = Prepare $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1'; dispatchId='dispatch-A1-duplicate'; generation=2; rework=1; modelClass='frontier'; failureClass='delivery'; failureFingerprint=('2' * 64); strategy='repair'; taskSpec=$retryTaskSpecA1; enqueuedAt='2026-08-03T00:01:30Z' })
  Assert-State $retryUnknown conflict 1 'controller-task-state-conflict'
  $earlyUndeliveredProof = Prepare $queueRoot $queueHash 'confirm-dispatch-not-delivered' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; evidenceHash=('9' * 64); confirmedAt='2026-08-02T23:59:59Z' })
  Assert-State $earlyUndeliveredProof conflict 1 'controller-task-state-conflict'
  $provenUndelivered = Mutate $queueRoot $queueHash 'confirm-dispatch-not-delivered' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; evidenceHash=('9' * 64); confirmedAt='2026-08-03T00:01:31Z' })
  $queueHash = [string]$provenUndelivered.Result.resultHash
  $provenActive = @($provenUndelivered.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  Assert-True ($provenActive.phase -ceq 'dispatching' -and $provenActive.deliveryReconciliation.evidenceHash -ceq ('9' * 64) -and @($provenActive.attemptFailures).Count -eq 0) 'Authoritative non-delivery may reopen the same attempt once without consuming convergence budget'
  $resentA1 = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; phase='sent' })
  $queueHash = [string]$resentA1.Result.resultHash
  $unknownAgainA1 = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; phase='delivery-unknown' })
  $queueHash = [string]$unknownAgainA1.Result.resultHash
  $secondResend = Prepare $queueRoot $queueHash 'confirm-dispatch-not-delivered' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; evidenceHash=('a' * 64); confirmedAt='2026-08-03T00:01:32Z' })
  Assert-State $secondResend conflict 1 'controller-task-state-conflict'
  $runningA1 = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; phase='running' })
  $queueHash = [string]$runningA1.Result.resultHash
  $earlyOutcome = Prepare $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; taskSpecHash=$taskSpecHashA1; resultState='blocked'; failureClass='implementation'; evidenceHash=('a' * 64); finishedAt='2026-08-02T23:59:59Z' })
  Assert-State $earlyOutcome conflict 1 'controller-task-state-conflict'
  $wrongTaskHash = Prepare $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; taskSpecHash=('f' * 64); resultState='blocked'; failureClass='implementation'; evidenceHash=('a' * 64); finishedAt='2026-08-03T00:01:59Z' })
  Assert-State $wrongTaskHash conflict 1 'controller-task-state-conflict'
  $completedOutcome = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1'; taskSpecHash=$taskSpecHashA1; resultState='completed'; failureClass='N/A'; evidenceHash=('a' * 64); finishedAt='2026-08-03T00:02:00Z' })
  $queueHash = [string]$completedOutcome.Result.resultHash
  $completedActive = @($completedOutcome.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  Assert-True ($completedActive.phase -ceq 'terminal' -and $completedActive.resultState -ceq 'completed' -and @($completedActive.attemptFailures).Count -eq 0 -and $null -eq $completedActive.writeLease.releasedAt) 'A completed initial attempt must retain its write lease until acceptance and review close'

  $retryTaskSpecA1.goalBinding = Advance-TestGoal $queueRoot 'GOAL-A1' 'dispatch-A1-r1' 'strategy.A1-repair' 'repair' 2 '2026-08-03T00:02:01Z' '2026-08-03T00:02:30Z' ('3' * 64) $retryTaskSpecA1
  $retryTooEarly = Prepare $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1'; dispatchId='dispatch-A1-early'; generation=2; rework=1; modelClass='frontier'; failureClass='review'; failureFingerprint=('3' * 64); strategy='repair'; taskSpec=$retryTaskSpecA1; enqueuedAt='2026-08-02T23:59:59Z' })
  Assert-State $retryTooEarly conflict 1 'controller-task-state-conflict'
  $retryDowngrade = Prepare $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1'; dispatchId='dispatch-A1-r0'; generation=2; rework=1; modelClass='economy'; failureClass='review'; failureFingerprint=('3' * 64); strategy='repair'; taskSpec=$retryTaskSpecA1; enqueuedAt='2026-08-03T00:03:00Z' })
  Assert-State $retryDowngrade conflict 1 'controller-task-state-conflict'
  $expandedRetryTaskSpecA1 = ($retryTaskSpecA1 | ConvertTo-Json -Depth 12 -Compress) | ConvertFrom-Json
  $expandedRetryTaskSpecA1.authorizedActions = @($expandedRetryTaskSpecA1.authorizedActions) + @('write production configuration')
  $expandedRetry = Prepare $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1'; dispatchId='dispatch-A1-expanded'; generation=2; rework=1; modelClass='frontier'; failureClass='review'; failureFingerprint=('3' * 64); strategy='repair'; taskSpec=$expandedRetryTaskSpecA1; enqueuedAt='2026-08-03T00:03:00Z' })
  Assert-State $expandedRetry conflict 1 'controller-task-state-conflict'
  $retryA = Mutate $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1'; dispatchId='dispatch-A1-r1'; generation=2; rework=1; modelClass='frontier'; failureClass='review'; failureFingerprint=('3' * 64); strategy='repair'; taskSpec=$retryTaskSpecA1; enqueuedAt='2026-08-03T00:03:00Z' })
  $queueHash = [string]$retryA.Result.resultHash
  $retriedActive = @($retryA.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  $taskSpecHashA1R1 = [string]$retriedActive.taskSpecHash
  Assert-True ($retriedActive.dispatchId -ceq 'dispatch-A1-r1' -and $taskSpecHashA1R1 -cne $taskSpecHashA1 -and
    $retriedActive.taskSpec.dispatchIdentity.dispatchId -ceq 'dispatch-A1-r1' -and $retriedActive.taskSpec.dispatchIdentity.generation -eq 2 -and
    $retriedActive.taskSpec.dispatchIdentity.rework -eq 1 -and @($retriedActive.attemptFailures).Count -eq 1 -and
    $retriedActive.attemptFailures[0].failureClass -ceq 'review' -and $retriedActive.modelClass -ceq 'frontier' -and
    $retriedActive.taskSpec.baseline.head -ceq ('9' * 40) -and $retriedActive.writeLease.leaseId -ceq 'lease-A') 'A repair must refresh evidence without widening scope and reseal identity while consuming one shared business attempt'
  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r1'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $blockedRepair = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r1'; taskSpecHash=$taskSpecHashA1R1; resultState='blocked'; failureClass='implementation'; evidenceHash=('b' * 64); finishedAt='2026-08-03T00:04:00Z' })
  $queueHash = [string]$blockedRepair.Result.resultHash
  $rebaselineTaskSpecA1 = ($retryTaskSpecA1 | ConvertTo-Json -Depth 12 -Compress) | ConvertFrom-Json
  $rebaselineTaskSpecA1.baseline.head = ('7' * 40)
  $rebaselineTaskSpecA1.baseline.dirtyHash = ('6' * 64)
  $rebaselineTaskSpecA1.readiness.checkedAt = '2026-08-03T00:04:30Z'
  $rebaselineTaskSpecA1.readiness.verification = @('architecture baseline verified')
  $rebaselineTaskSpecA1.goalBinding = Advance-TestGoal $queueRoot 'GOAL-A1' 'dispatch-A1-r2' 'strategy.A1-rebaseline' 'rebaseline' 3 '2026-08-03T00:04:01Z' '2026-08-03T00:04:30Z' ('4' * 64) $rebaselineTaskSpecA1
  $rebaselineA = Mutate $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1-r1'; dispatchId='dispatch-A1-r2'; generation=3; rework=2; modelClass='frontier'; failureClass='architecture'; failureFingerprint=('4' * 64); strategy='rebaseline'; taskSpec=$rebaselineTaskSpecA1; enqueuedAt='2026-08-03T00:05:00Z' })
  $queueHash = [string]$rebaselineA.Result.resultHash
  $rebaselineActive = @($rebaselineA.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  $taskSpecHashA1R2 = [string]$rebaselineActive.taskSpecHash
  Assert-True (@($rebaselineActive.attemptFailures).Count -eq 2 -and $rebaselineActive.generation -eq 3 -and $rebaselineActive.rework -eq 2 -and
    $taskSpecHashA1R2 -cne $taskSpecHashA1R1 -and $rebaselineActive.taskSpec.dispatchIdentity.dispatchId -ceq 'dispatch-A1-r2') `
    'The architecture rebaseline must reseal identity and consume the final business retry'
  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $controllerPreflightRejected = Prepare $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{
    projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; taskSpecHash=$taskSpecHashA1R2
    resultState='blocked'; failureClass='controller-preflight'; evidenceHash=('f' * 64); finishedAt='2026-08-03T00:05:29Z'
  })
  Assert-State $controllerPreflightRejected conflict 1 'controller-task-state-conflict'
  $finalPreflightEvidence = ('c' * 64)
  $finalPreflight = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{
    projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; taskSpecHash=$taskSpecHashA1R2
    resultState='blocked'; failureClass='tool-bootstrap'; evidenceHash=$finalPreflightEvidence; finishedAt='2026-08-03T00:05:30Z'
  })
  $queueHash = [string]$finalPreflight.Result.resultHash
  $finalPreflightPayload = [ordered]@{
    projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; failureClass='tool-bootstrap'; evidenceHash=$finalPreflightEvidence
    confirmedAt='2026-08-03T00:05:31Z'
    observedBaseline=[ordered]@{ dirtyHash=$rebaselineTaskSpecA1.baseline.dirtyHash; head=$rebaselineTaskSpecA1.baseline.head; branch=$rebaselineTaskSpecA1.baseline.branch }
  }
  $finalPreflightReopened = Mutate $queueRoot $queueHash 'reconcile-preflight-failure' $finalPreflightPayload
  $queueHash = [string]$finalPreflightReopened.Result.resultHash
  $finalPreflightActive = @($finalPreflightReopened.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  Assert-True ($finalPreflightActive.phase -ceq 'dispatching' -and $null -eq $finalPreflightActive.resultState -and @($finalPreflightActive.attemptFailures).Count -eq 2) `
    'A proven zero-repository final-generation preflight failure must reconcile once without becoming convergence-failed'
  Assert-State (Prepare $queueRoot $queueHash 'reconcile-preflight-failure' $finalPreflightPayload) conflict 1 'controller-task-state-conflict'
  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $completedRebaseline = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; taskSpecHash=$taskSpecHashA1R2; resultState='completed'; failureClass='N/A'; evidenceHash=('d' * 64); finishedAt='2026-08-03T00:06:00Z' })
  $queueHash = [string]$completedRebaseline.Result.resultHash
  $earlyConvergence = Prepare $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; taskSpecHash=$taskSpecHashA1R2; resultState='convergence-failed'; failureClass='review'; evidenceHash=('e' * 64); finishedAt='2026-08-03T00:05:59Z' })
  Assert-State $earlyConvergence conflict 1 'controller-task-state-conflict'
  $convergence = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A1-r2'; taskSpecHash=$taskSpecHashA1R2; resultState='convergence-failed'; failureClass='review'; evidenceHash=('e' * 64); finishedAt='2026-08-03T00:06:01Z' })
  $queueHash = [string]$convergence.Result.resultHash
  $convergenceActive = @($convergence.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessA })[0].active
  Assert-True ($convergenceActive.resultState -ceq 'convergence-failed' -and $null -eq $convergenceActive.writeLease.releasedAt) 'A final completed implementation with review findings must converge without releasing its write lease'
  $fourthAttempt = Prepare $queueRoot $queueHash 'retry-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; expectedDispatchId='dispatch-A1-r2'; dispatchId='dispatch-A1-r3'; generation=4; rework=3; modelClass='frontier'; failureClass='review'; failureFingerprint=('5' * 64); strategy='repair'; taskSpec=$rebaselineTaskSpecA1; enqueuedAt='2026-08-03T00:07:00Z' })
  Assert-State $fourthAttempt conflict 1 'dispatch-convergence-limit'
  $startA2AfterLimit = Prepare $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessA; dispatchId='dispatch-A2'; startedAt='2026-08-03T00:07:01Z'; leaseId=$null })
  Assert-State $startA2AfterLimit conflict 1 'controller-task-state-conflict'

  foreach ($phase in @('sent', 'running', 'approval-wait')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $cancelTooEarly = Prepare $queueRoot $queueHash 'request-dispatch-cancel' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; requestedAt='2026-08-02T23:59:59Z' })
  Assert-State $cancelTooEarly conflict 1 'controller-task-state-conflict'
  $cancelRequested = Mutate $queueRoot $queueHash 'request-dispatch-cancel' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; requestedAt='2026-08-03T00:08:00Z' })
  $queueHash = [string]$cancelRequested.Result.resultHash
  $cancelPending = @($cancelRequested.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0].active
  Assert-True ($cancelPending.phase -ceq 'approval-wait' -and $cancelPending.cancelRequestedAt -ceq '2026-08-03T00:08:00Z' -and $null -eq $cancelPending.resultState) 'A cancellation request must remain truthful while the exact runtime approval is unresolved'
  $closeCancelPending = Prepare $queueRoot $queueHash 'close-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; closedAt='2026-08-03T00:08:01Z' })
  Assert-State $closeCancelPending conflict 1 'controller-task-state-conflict'
  $cancelledB1 = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; taskSpecHash=$taskSpecHashB1; resultState='cancelled'; failureClass='N/A'; evidenceHash=('6' * 64); finishedAt='2026-08-03T00:08:02Z' })
  $queueHash = [string]$cancelledB1.Result.resultHash
  Finish-TestGoal $queueRoot 'GOAL-B1' 'cancelled' 'N/A' ('6' * 64) '2026-08-03T00:08:02Z'
  $goalB1Read = Invoke-GoalStore GoalGet $queueRoot 'GOAL-B1'
  Assert-True ($goalB1Read.ExitCode -eq 0 -and $goalB1Read.Result.data.record.lanes[0].outcomes[-1].outcome -ceq 'cancelled') 'B1 goal outcome must be readable before close'
  try { $closedB1 = Mutate $queueRoot $queueHash 'close-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B1'; closedAt='2026-08-03T00:08:03Z' }) }
  catch { throw "close B1 failed: $($_.Exception.Message)" }
  $queueHash = [string]$closedB1.Result.resultHash

  $taskSpecB2 = New-TaskSpec 'B2' ('d' * 40) 'authref:project-B:B2'
  $taskSpecB2.goalBinding = New-TestGoal $queueRoot 'GOAL-B2' $queueBusinessB 'CHAIN-B2' 'dispatch-B2' 'problem.B2' 'strategy.B2-initial' $taskSpecB2
  $dispatchB2 = [ordered]@{ projectRoot=$queueBusinessB; chainId='CHAIN-B2'; projectTaskId='entry-B'; dispatchId='dispatch-B2'; generation=1; rework=0; accessMode='write'; modelClass='balanced'; taskSpec=$taskSpecB2; enqueuedAt='2026-08-03T00:09:00Z' }
  $queuedB2 = Mutate $queueRoot $queueHash 'enqueue-dispatch' $dispatchB2
  $queueHash = [string]$queuedB2.Result.resultHash
  $startedB2 = Mutate $queueRoot $queueHash 'start-next-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; startedAt='2026-08-03T00:09:01Z'; leaseId='lease-B2' })
  $queueHash = [string]$startedB2.Result.resultHash
  $taskSpecHashB2 = [string](@($startedB2.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0].active.taskSpecHash)
  foreach ($phase in @('sent', 'running')) {
    $advanced = Mutate $queueRoot $queueHash 'advance-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; phase=$phase })
    $queueHash = [string]$advanced.Result.resultHash
  }
  $authRequired = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; taskSpecHash=$taskSpecHashB2; resultState='auth-required'; failureClass='authorization'; evidenceHash=('7' * 64); finishedAt='2026-08-03T00:10:00Z' })
  $queueHash = [string]$authRequired.Result.resultHash
  $earlyAuthorization = Prepare $queueRoot $queueHash 'resume-dispatch-authorization' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; authorizationRef='authref:project-B:B2'; resumedAt='2026-08-03T00:09:59Z' })
  Assert-State $earlyAuthorization conflict 1 'controller-task-state-conflict'
  $wrongAuthorization = Prepare $queueRoot $queueHash 'resume-dispatch-authorization' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; authorizationRef='authref:project-B:wrong'; resumedAt='2026-08-03T00:10:01Z' })
  Assert-State $wrongAuthorization conflict 1 'controller-task-state-conflict'
  $resumedB2 = Mutate $queueRoot $queueHash 'resume-dispatch-authorization' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; authorizationRef='authref:project-B:B2'; resumedAt='2026-08-03T00:10:02Z' })
  $queueHash = [string]$resumedB2.Result.resultHash
  $resumedActive = @($resumedB2.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0].active
  Assert-True ($resumedActive.phase -ceq 'running' -and $resumedActive.dispatchId -ceq 'dispatch-B2' -and @($resumedActive.attemptFailures).Count -eq 0 -and $resumedActive.taskSpecHash -ceq $taskSpecHashB2 -and $resumedActive.authorizationResumedAt -ceq '2026-08-03T00:10:02Z') 'Exact business authorization must leave durable evidence and resume the same attempt without consuming convergence budget'
  $completedB2 = Mutate $queueRoot $queueHash 'record-dispatch-outcome' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; taskSpecHash=$taskSpecHashB2; resultState='completed'; failureClass='N/A'; evidenceHash=('8' * 64); finishedAt='2026-08-03T00:11:00Z' })
  $queueHash = [string]$completedB2.Result.resultHash
  $closeB2TooEarly = Prepare $queueRoot $queueHash 'close-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; closedAt='2026-08-03T00:10:59Z' })
  Assert-State $closeB2TooEarly conflict 1 'controller-task-state-conflict'
  Finish-TestGoal $queueRoot 'GOAL-B2' 'accepted-success' 'N/A' ('8' * 64) '2026-08-03T00:11:00Z'
  try { $closedB2 = Mutate $queueRoot $queueHash 'close-dispatch' ([ordered]@{ projectRoot=$queueBusinessB; dispatchId='dispatch-B2'; closedAt='2026-08-03T00:11:01Z' }) }
  catch { throw "close B2 failed: $($_.Exception.Message)" }
  $queueHash = [string]$closedB2.Result.resultHash
  $closedQueueB = @($closedB2.Result.data.dispatchQueues | Where-Object { $_.projectRoot -ceq $queueBusinessB })[0]
  Assert-True ($null -eq $closedQueueB.active -and $closedQueueB.lastTerminal.writeLease.releasedAt -ceq '2026-08-03T00:11:01Z') 'Completed review close must atomically release the write lease'

  $replacementPayload = [ordered]@{
    confirmReconciliation=$true; projectRoot=$businessRoot
    expectedEntryThreadId='entry-1'; expectedCodexProjectId='project-A'; expectedHostId='host-1'
    replacementEntryThreadId='entry-2'; replacementCodexProjectId='project-B'; replacementHostId='host-2'
  }
  $replaceNoConfirmPayload = [ordered]@{}
  foreach ($property in $replacementPayload.Keys) { $replaceNoConfirmPayload[$property] = $replacementPayload[$property] }
  $replaceNoConfirmPayload.confirmReconciliation = $false
  $replaceNoConfirm = Prepare $root $hash 'replace-project-binding' $replaceNoConfirmPayload
  Assert-State $replaceNoConfirm invalid 2 'controller-payload-invalid'
  $replaceWrongPayload = [ordered]@{}
  foreach ($property in $replacementPayload.Keys) { $replaceWrongPayload[$property] = $replacementPayload[$property] }
  $replaceWrongPayload.expectedEntryThreadId = 'entry-wrong'
  $replaceWrong = Prepare $root $hash 'replace-project-binding' $replaceWrongPayload
  Assert-State $replaceWrong conflict 1 'project-binding-conflict'
  $replacement = Mutate $root $hash 'replace-project-binding' $replacementPayload
  $hash = [string]$replacement.Result.resultHash
  Assert-True ($replacement.Result.data.projectBindings[0].entryThreadId -ceq 'entry-2' -and $replacement.Result.data.projectBindings[0].codexProjectId -ceq 'project-B' -and $replacement.Result.data.projectBindings[0].hostId -ceq 'host-2') 'replace-project-binding must atomically replace the exact stale identity'
  $replacementReplay = Mutate $root $hash 'replace-project-binding' $replacementPayload
  $hash = [string]$replacementReplay.Result.resultHash
  Assert-True (@($replacementReplay.Result.data.projectBindings).Count -eq 1) 'Exact replacement replay must be idempotent'

  $clearNoConfirm = Prepare $root $hash 'clear-controller-task-state' ([ordered]@{ confirmReconciliation=$false; threadId='thread-1' })
  Assert-State $clearNoConfirm invalid 2 'controller-payload-invalid'
  $clearWrong = Prepare $root $hash 'clear-controller-task-state' ([ordered]@{ confirmReconciliation=$true; threadId='thread-other' })
  Assert-State $clearWrong conflict 1 'controller-task-state-conflict'
  $clear = Mutate $root $hash 'clear-controller-task-state' ([ordered]@{ confirmReconciliation=$true; threadId='thread-1' })
  $hash = [string]$clear.Result.resultHash
  Assert-True ($null -eq $clear.Result.data.controllerBinding) 'clear-controller-task-state must clear exact binding'

  $racePrepared = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-race'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:01Z' })
  Assert-State $racePrepared prepared 0 'controller-candidate-prepared'
  $staleHash = $hash
  $manifestPath = Join-Path $root '.codex-controller.json'
  $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
  $manifest.controllerName = 'Concurrent Writer'
  $changedBytes = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
  [IO.File]::WriteAllBytes($manifestPath, $changedBytes)
  $hash = Get-Hash $changedBytes
  $race = Apply $root $staleHash $racePrepared
  Assert-State $race conflict 1 'controller-hash-conflict'
  Assert-True ((Get-Hash ([IO.File]::ReadAllBytes($manifestPath))) -ceq $hash) 'Stale writer must not overwrite current manifest'
  $cleanupRace = Invoke-State RemoveCandidate $root '' '' '' $racePrepared.Result.candidatePath $racePrepared.Result.candidateHash $true
  Assert-State $cleanupRace removed 0 'controller-candidate-removed'

  $tamper = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-tamper'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $tamper prepared 0 'controller-candidate-prepared'
  [IO.File]::AppendAllText($tamper.Result.candidatePath, 'x')
  $tamperedApply = Apply $root $hash $tamper
  Assert-State $tamperedApply conflict 1 'controller-candidate-hash-mismatch'
  $tamperedBytesHash = Get-Hash ([IO.File]::ReadAllBytes($tamper.Result.candidatePath))
  $removeTampered = Invoke-State RemoveCandidate $root '' '' '' $tamper.Result.candidatePath $tamperedBytesHash $true
  Assert-State $removeTampered removed 0 'controller-candidate-removed'

  $casePrepared = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-path-case'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $casePrepared prepared 0 'controller-candidate-prepared'
  $caseRoot = if ($root -cne $root.ToUpperInvariant()) { $root.ToUpperInvariant() } else { $root.ToLowerInvariant() }
  $caseCandidatePath = Join-Path $caseRoot (Split-Path -Leaf $casePrepared.Result.candidatePath)
  $caseApplied = Invoke-State ApplyCandidate $root $hash '' '' $caseCandidatePath $casePrepared.Result.candidateHash
  Assert-State $caseApplied applied 0 'controller-state-applied'
  $hash = [string]$caseApplied.Result.resultHash
  $caseCleared = Mutate $root $hash 'clear-controller-task-state' ([ordered]@{ confirmReconciliation=$true; operationId='op-path-case' })
  $hash = [string]$caseCleared.Result.resultHash

  $invalidCandidatePath = Join-Path $root ('.codex-controller.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $invalidCandidateBytes = $utf8.GetBytes('{"not":"a manifest"}' + "`n")
  [IO.File]::WriteAllBytes($invalidCandidatePath, $invalidCandidateBytes)
  $invalidCandidateHash = Get-Hash $invalidCandidateBytes
  $invalidCandidate = Invoke-State ApplyCandidate $root $hash '' '' $invalidCandidatePath $invalidCandidateHash
  Assert-State $invalidCandidate conflict 1 'controller-candidate-invalid'
  $invalidCandidateCleanup = Invoke-State RemoveCandidate $root '' '' '' $invalidCandidatePath $invalidCandidateHash $true
  Assert-State $invalidCandidateCleanup removed 0 'controller-candidate-removed'

  $lockedCandidate = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-locked-candidate'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $lockedCandidate prepared 0 'controller-candidate-prepared'
  $candidateLock = New-Object IO.FileStream($lockedCandidate.Result.candidatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  try {
    $lockedCandidateApply = Apply $root $hash $lockedCandidate
    Assert-State $lockedCandidateApply blocked 1 'controller-io-failure'
  }
  finally { $candidateLock.Dispose() }
  $lockedCandidateCleanup = Invoke-State RemoveCandidate $root '' '' '' $lockedCandidate.Result.candidatePath $lockedCandidate.Result.candidateHash $true
  Assert-State $lockedCandidateCleanup removed 0 'controller-candidate-removed'

  $lockedManifestCandidate = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-locked-manifest'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $lockedManifestCandidate prepared 0 'controller-candidate-prepared'
  $manifestLock = New-Object IO.FileStream($manifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  try {
    $lockedManifestApply = Apply $root $hash $lockedManifestCandidate
    Assert-State $lockedManifestApply blocked 1 'controller-io-failure'
  }
  finally { $manifestLock.Dispose() }
  $lockedManifestCleanup = Invoke-State RemoveCandidate $root '' '' '' $lockedManifestCandidate.Result.candidatePath $lockedManifestCandidate.Result.candidateHash $true
  Assert-State $lockedManifestCleanup removed 0 'controller-candidate-removed'

  $atomicBlockedCandidate = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-atomic-blocked'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $atomicBlockedCandidate prepared 0 'controller-candidate-prepared'
  $atomicLock = New-Object IO.FileStream($manifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $atomicBlockedApply = Apply $root $hash $atomicBlockedCandidate
    Assert-State $atomicBlockedApply blocked 1 'controller-atomic-replace-failed'
  }
  finally { $atomicLock.Dispose() }
  $atomicBlockedCleanup = Invoke-State RemoveCandidate $root '' '' '' $atomicBlockedCandidate.Result.candidatePath $atomicBlockedCandidate.Result.candidateHash $true
  Assert-State $atomicBlockedCleanup removed 0 'controller-candidate-removed'

  $deleteBlockedCandidate = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-delete-blocked'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:02Z' })
  Assert-State $deleteBlockedCandidate prepared 0 'controller-candidate-prepared'
  $deleteLock = New-Object IO.FileStream($deleteBlockedCandidate.Result.candidatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $deleteBlocked = Invoke-State RemoveCandidate $root '' '' '' $deleteBlockedCandidate.Result.candidatePath $deleteBlockedCandidate.Result.candidateHash $true
    Assert-State $deleteBlocked blocked 1 'controller-io-failure'
    Assert-True (Test-Path -LiteralPath $deleteBlockedCandidate.Result.candidatePath -PathType Leaf) 'Failed delete must preserve the candidate'
  }
  finally { $deleteLock.Dispose() }
  $deleteBlockedCleanup = Invoke-State RemoveCandidate $root '' '' '' $deleteBlockedCandidate.Result.candidatePath $deleteBlockedCandidate.Result.candidateHash $true
  Assert-State $deleteBlockedCleanup removed 0 'controller-candidate-removed'

  if ($fileSystem -ceq 'NTFS') {
    $writeBlockedRoot = Join-Path $testRoot 'write-blocked-controller'
    $writeBlockedHash = Write-Manifest $writeBlockedRoot
    $originalAcl = Get-Acl -LiteralPath $writeBlockedRoot
    $deniedAcl = Get-Acl -LiteralPath $writeBlockedRoot
    $denyRule = New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.AccessControl.FileSystemRights]::CreateFiles, [Security.AccessControl.AccessControlType]::Deny)
    $deniedAcl.AddAccessRule($denyRule)
    Set-Acl -LiteralPath $writeBlockedRoot -AclObject $deniedAcl
    try {
      $writeBlocked = Prepare $writeBlockedRoot $writeBlockedHash 'set-task-intent' ([ordered]@{ operationId='op-write-blocked'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$writeBlockedRoot; startedAt='2026-08-02T00:00:02Z' })
      Assert-State $writeBlocked blocked 1 'controller-io-failure'
    }
    finally { Set-Acl -LiteralPath $writeBlockedRoot -AclObject $originalAcl }
  }

  $prepareMutexFailures = @()
  try {
    $prepareRaceRoot = Join-Path $testRoot 'prepare-race-controller'
    $prepareRaceBindings = @(1..300 | ForEach-Object {
      [pscustomobject][ordered]@{
        entryThreadId=('prepare-race-entry-{0:D3}-' -f $_) + ('e' * 96)
        codexProjectId=('prepare-race-project-{0:D3}-' -f $_) + ('p' * 96)
        hostId=('prepare-race-host-{0:D3}-' -f $_) + ('h' * 96)
        projectRoot=('D:\prepare-race-project-{0:D3}' -f $_)
      }
    })
    $prepareRaceHash = Write-Manifest $prepareRaceRoot $null $null $prepareRaceBindings 2
    $prepareRaceManifestHash = Get-Hash ([IO.File]::ReadAllBytes((Join-Path $prepareRaceRoot '.codex-controller.json')))
    $prepareRacePayload = ([ordered]@{ operationId='op-prepare-race'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$prepareRaceRoot; startedAt='2026-08-02T00:00:02Z' } | ConvertTo-Json -Compress)
    $prepareRaceStart = Join-Path $testRoot 'prepare-race-start.signal'
    $prepareRaceReady = @(); $prepareRaceProcesses = @(); $prepareRaceOutputs = @()
    try {
      foreach ($index in 1..2) {
        $ready = Join-Path $testRoot ("prepare-race-$index.ready")
        $prepareRaceReady += $ready
        $command = '[IO.File]::WriteAllText(' + (Get-EncodedStringExpression $ready) + ", 'ready'); while (-not (Test-Path -LiteralPath " + (Get-EncodedStringExpression $prepareRaceStart) + ' -PathType Leaf)) { Start-Sleep -Milliseconds 10 }; & ' +
          (Get-EncodedStringExpression $subject) + ' -Action PrepareCandidate -ControllerRoot ' + (Get-EncodedStringExpression $prepareRaceRoot) +
          ' -ExpectedHash ' + (Get-EncodedStringExpression $prepareRaceHash) + ' -Operation set-task-intent -PayloadJson ' + (Get-EncodedStringExpression $prepareRacePayload) + '; exit $LASTEXITCODE'
        $started = Start-TestPowerShell $command $true
        $prepareRaceProcesses += [pscustomobject]@{ Process=$started; Stdout=$started.StandardOutput.ReadToEndAsync(); Stderr=$started.StandardError.ReadToEndAsync() }
      }
      $readyWatch = [Diagnostics.Stopwatch]::StartNew()
      while (@($prepareRaceReady | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -gt 0 -and $readyWatch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 10 }
      Assert-True (@($prepareRaceReady | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 2) 'Concurrent Prepare workers must reach the shared start barrier'
      [IO.File]::WriteAllText($prepareRaceStart, 'go')
      foreach ($started in $prepareRaceProcesses) {
        if (-not $started.Process.WaitForExit(20000)) { throw 'Concurrent Prepare did not exit within 20 seconds' }
        $stdout = $started.Stdout.GetAwaiter().GetResult(); $stderr = $started.Stderr.GetAwaiter().GetResult()
        Assert-True ([string]::IsNullOrWhiteSpace($stderr)) 'Concurrent Prepare must not emit raw stderr'
        $result = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop
        Assert-True (($result.status -ceq 'prepared' -and $started.Process.ExitCode -eq 0) -or ($result.status -ceq 'conflict' -and $started.Process.ExitCode -eq 1)) 'Concurrent Prepare exit must match its JSON status'
        $prepareRaceOutputs += $result
      }
    }
    finally { foreach ($started in $prepareRaceProcesses) { Stop-TestProcess $started.Process } }
    $prepareRaceCandidates = @(Get-ChildItem -LiteralPath $prepareRaceRoot -Force | Where-Object { $_.Name -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$' })
    $prepareRaceCandidateCount = $prepareRaceCandidates.Count
    $prepareRaceManifestUnchanged = (Get-Hash ([IO.File]::ReadAllBytes((Join-Path $prepareRaceRoot '.codex-controller.json')))) -ceq $prepareRaceManifestHash
    foreach ($candidate in $prepareRaceCandidates) {
      $removed = Invoke-State RemoveCandidate $prepareRaceRoot '' '' '' $candidate.FullName (Get-Hash ([IO.File]::ReadAllBytes($candidate.FullName))) $true
      Assert-State $removed removed 0 'controller-candidate-removed'
    }
    $prepareRaceRecovered = Prepare $prepareRaceRoot $prepareRaceHash 'set-task-intent' ([ordered]@{ operationId='op-prepare-race-recovered'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$prepareRaceRoot; startedAt='2026-08-02T00:00:03Z' })
    Assert-State $prepareRaceRecovered prepared 0 'controller-candidate-prepared'
    Assert-State (Invoke-State RemoveCandidate $prepareRaceRoot '' '' '' $prepareRaceRecovered.Result.candidatePath $prepareRaceRecovered.Result.candidateHash $true) removed 0 'controller-candidate-removed'
    Assert-True (@($prepareRaceOutputs | Where-Object { $_.status -ceq 'prepared' }).Count -eq 1) 'Exactly one concurrent Prepare may succeed for one ExpectedHash'
    Assert-True (@($prepareRaceOutputs | Where-Object { $_.status -ceq 'conflict' }).Count -eq 1) 'The losing concurrent Prepare must fail closed'
    Assert-True ($prepareRaceCandidateCount -eq 1) 'Concurrent Prepare must leave exactly one recoverable candidate'
    Assert-True $prepareRaceManifestUnchanged 'Concurrent Prepare must not change the canonical manifest'
    $script:scenarioCount += 2
  }
  catch { $prepareMutexFailures += "concurrent Prepare: $($_.Exception.Message)" }

  try {
    $prepareHeldRoot = Join-Path $testRoot 'prepare-held-controller'
    $prepareHeldHash = Write-Manifest $prepareHeldRoot
    $prepareHeldManifestHash = Get-Hash ([IO.File]::ReadAllBytes((Join-Path $prepareHeldRoot '.codex-controller.json')))
    $prepareHeldSignal = Join-Path $testRoot 'prepare-held-mutex.signal'
    $prepareHeldRelease = Join-Path $testRoot 'prepare-held-mutex.release'
    $prepareHeldHolder = Start-MutexHolder $prepareHeldRoot $prepareHeldSignal 20000 $false $prepareHeldRelease
    try {
      $prepareWhileHeld = Prepare $prepareHeldRoot $prepareHeldHash 'set-task-intent' ([ordered]@{ operationId='op-prepare-held'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$prepareHeldRoot; startedAt='2026-08-02T00:00:03Z' })
    }
    finally {
      [IO.File]::WriteAllText($prepareHeldRelease, 'release')
      Wait-TestProcess $prepareHeldHolder 20000 'Prepare mutex holder did not exit within 20 seconds'
    }
    $prepareHeldCandidates = @(Get-ChildItem -LiteralPath $prepareHeldRoot -Force | Where-Object { $_.Name -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$' })
    $prepareHeldCandidateCount = $prepareHeldCandidates.Count
    foreach ($candidate in $prepareHeldCandidates) {
      Assert-State (Invoke-State RemoveCandidate $prepareHeldRoot '' '' '' $candidate.FullName (Get-Hash ([IO.File]::ReadAllBytes($candidate.FullName))) $true) removed 0 'controller-candidate-removed'
    }
    Assert-State $prepareWhileHeld conflict 1 'controller-mutex-timeout'
    Assert-True ($prepareHeldCandidateCount -eq 0) 'Prepare must not create a candidate while another root writer holds the mutex'
    Assert-True ((Get-Hash ([IO.File]::ReadAllBytes((Join-Path $prepareHeldRoot '.codex-controller.json')))) -ceq $prepareHeldManifestHash) 'Timed-out Prepare must not change the canonical manifest'
  }
  catch { $prepareMutexFailures += "mutex-held Prepare: $($_.Exception.Message)" }
  if ($prepareMutexFailures.Count -gt 0) { throw ($prepareMutexFailures -join '; ') }

  $timeoutCandidate = Prepare $root $hash 'set-task-intent' ([ordered]@{ operationId='op-timeout'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:03Z' })
  Assert-State $timeoutCandidate prepared 0 'controller-candidate-prepared'
  $timeoutSignal = Join-Path $testRoot 'mutex-timeout.signal'
  $timeoutHolder = Start-MutexHolder $root $timeoutSignal 7000 $false
  try {
    $timeoutApply = Apply $root $hash $timeoutCandidate
    Assert-State $timeoutApply conflict 1 'controller-mutex-timeout'
    Assert-True (Test-Path -LiteralPath $timeoutCandidate.Result.candidatePath -PathType Leaf) 'Mutex timeout must preserve candidate'
  }
  finally { Wait-TestProcess $timeoutHolder 15000 'Mutex timeout holder did not exit within 15 seconds' }
  $timeoutCleanup = Invoke-State RemoveCandidate $root '' '' '' $timeoutCandidate.Result.candidatePath $timeoutCandidate.Result.candidateHash $true
  Assert-State $timeoutCleanup removed 0 'controller-candidate-removed'

  $abandonedExpected = $hash
  $abandonedCandidate = Prepare $root $abandonedExpected 'set-task-intent' ([ordered]@{ operationId='op-abandoned'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:04Z' })
  Assert-State $abandonedCandidate prepared 0 'controller-candidate-prepared'
  $abandonedSignal = Join-Path $testRoot 'mutex-abandoned.signal'
  $abandonedHolder = Start-MutexHolder $root $abandonedSignal 300 $true
  try {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $manifest.controllerName = 'Abandoned Mutex Writer'
    $abandonedChangedBytes = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
    [IO.File]::WriteAllBytes($manifestPath, $abandonedChangedBytes)
    $hash = Get-Hash $abandonedChangedBytes
    $abandonedApply = Apply $root $abandonedExpected $abandonedCandidate
    Assert-State $abandonedApply conflict 1 'controller-hash-conflict'
  }
  finally { Wait-TestProcess $abandonedHolder 15000 'Abandoned mutex holder did not exit within 15 seconds' }
  $abandonedCleanup = Invoke-State RemoveCandidate $root '' '' '' $abandonedCandidate.Result.candidatePath $abandonedCandidate.Result.candidateHash $true
  Assert-State $abandonedCleanup removed 0 'controller-candidate-removed'
  Assert-True ((Get-Hash ([IO.File]::ReadAllBytes($manifestPath))) -ceq $hash) 'Abandoned mutex acquisition must still fully revalidate current state'

  $writerHash = $hash
  $writerOne = Mutate $root $writerHash 'set-task-intent' ([ordered]@{ operationId='op-writer-1'; codexProjectId='controller-project'; hostId='host-1'; projectRoot=$projectRoot; startedAt='2026-08-02T00:00:05Z' })
  $hash = [string]$writerOne.Result.resultHash
  $concurrentExpected = $hash
  $concurrentPrepared = Prepare $root $concurrentExpected 'record-client-thread' ([ordered]@{ operationId='op-writer-1'; clientThreadId='client-concurrent' })
  Assert-State $concurrentPrepared prepared 0 'controller-candidate-prepared'
  $secondCandidatePath = Join-Path $root ('.codex-controller.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $secondStream = New-Object IO.FileStream($secondCandidatePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $concurrentBytes = [IO.File]::ReadAllBytes($concurrentPrepared.Result.candidatePath)
    $secondStream.Write($concurrentBytes, 0, $concurrentBytes.Length)
  }
  finally { $secondStream.Dispose() }
  $concurrentOutputs = @()
  $processes = @()
  try {
    foreach ($candidate in @($concurrentPrepared.Result.candidatePath, $secondCandidatePath)) {
      $command = '& ' + (Get-EncodedStringExpression $subject) + ' -Action ApplyCandidate -ControllerRoot ' + (Get-EncodedStringExpression $root) + ' -ExpectedHash ' + (Get-EncodedStringExpression $concurrentExpected) + ' -CandidatePath ' + (Get-EncodedStringExpression $candidate) + ' -CandidateHash ' + (Get-EncodedStringExpression ([string]$concurrentPrepared.Result.candidateHash)) + '; exit $LASTEXITCODE'
      $started = Start-TestPowerShell $command $true
      $processes += [pscustomobject]@{ Process=$started; Stdout=$started.StandardOutput.ReadToEndAsync(); Stderr=$started.StandardError.ReadToEndAsync() }
    }
    foreach ($started in $processes) {
      if (-not $started.Process.WaitForExit(20000)) { throw 'Concurrent Apply did not exit within 20 seconds' }
      $stdout = $started.Stdout.GetAwaiter().GetResult()
      $stderr = $started.Stderr.GetAwaiter().GetResult()
      Assert-True ([string]::IsNullOrWhiteSpace($stderr)) 'Concurrent Apply must not emit raw stderr'
      $concurrentResult = $stdout | ConvertFrom-Json
      Assert-True (($concurrentResult.status -ceq 'applied' -and $started.Process.ExitCode -eq 0) -or ($concurrentResult.status -ceq 'conflict' -and $started.Process.ExitCode -eq 1)) 'Concurrent Apply process exit must match its JSON status'
      $concurrentOutputs += $concurrentResult
    }
  }
  finally {
    foreach ($started in $processes) { Stop-TestProcess $started.Process }
  }
  Assert-True (@($concurrentOutputs | Where-Object { $_.status -ceq 'applied' -and $_.reasonCode -ceq 'controller-state-applied' }).Count -eq 1) 'Exactly one concurrent writer must apply'
  Assert-True (@($concurrentOutputs | Where-Object { $_.status -ceq 'conflict' -and $_.reasonCode -ceq 'controller-hash-conflict' }).Count -eq 1) 'Exactly one concurrent writer must lose with expected-hash conflict'
  $script:scenarioCount += 2
  $hash = [string]$concurrentPrepared.Result.candidateHash
  Assert-True ((Get-Hash ([IO.File]::ReadAllBytes($manifestPath))) -ceq $hash) 'Concurrent writers must leave the canonical candidate bytes without overwrite'
  $remaining = @(Get-ChildItem -LiteralPath $root | Where-Object { $_.Name -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$' })
  Assert-True ($remaining.Count -eq 1) 'The losing concurrent candidate must remain for explicit recovery'
  $remainingCleanup = Invoke-State RemoveCandidate $root '' '' '' $remaining[0].FullName (Get-Hash ([IO.File]::ReadAllBytes($remaining[0].FullName))) $true
  Assert-State $remainingCleanup removed 0 'controller-candidate-removed'
  $recordConcurrentSame = Mutate $root $hash 'record-client-thread' ([ordered]@{ operationId='op-writer-1'; clientThreadId='client-concurrent' })
  $hash = [string]$recordConcurrentSame.Result.resultHash
  $recordConcurrentDifferent = Prepare $root $hash 'record-client-thread' ([ordered]@{ operationId='op-writer-1'; clientThreadId='client-different' })
  Assert-State $recordConcurrentDifferent conflict 1 'controller-task-state-conflict'

  $outside = Join-Path $testRoot ('.codex-controller.' + [guid]::NewGuid().ToString('N') + '.tmp')
  [IO.File]::WriteAllText($outside, 'outside')
  $outsideApply = Invoke-State ApplyCandidate $root $hash '' '' $outside (Get-Hash ([IO.File]::ReadAllBytes($outside)))
  Assert-State $outsideApply invalid 2 'controller-candidate-invalid'
  Assert-True (Test-Path -LiteralPath $outside -PathType Leaf) 'Outside candidate must survive'

  $missingConfirm = Invoke-State RemoveCandidate $root '' '' '' $outside (Get-Hash ([IO.File]::ReadAllBytes($outside))) $false
  Assert-State $missingConfirm invalid 2 'controller-cleanup-confirmation-required'
  Assert-True ((Get-Content -Raw -LiteralPath $sentinel) -ceq 'survive') 'External sentinel must survive every operation'

  $reparseTarget = Join-Path $testRoot 'candidate-reparse-target'
  [IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
  $reparseSentinel = Join-Path $reparseTarget 'target-sentinel.txt'
  [IO.File]::WriteAllText($reparseSentinel, 'survive')
  $reparseCandidate = Join-Path $root ('.codex-controller.' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    New-Item -ItemType Junction -Path $reparseCandidate -Target $reparseTarget | Out-Null
    $reparseApply = Invoke-State ApplyCandidate $root $hash '' '' $reparseCandidate ('0' * 64)
    Assert-State $reparseApply conflict 1 'controller-candidate-invalid'
    Assert-True ((Get-Content -Raw -LiteralPath $reparseSentinel) -ceq 'survive') 'Candidate reparse target must survive'
    [IO.Directory]::Delete($reparseCandidate)
  }
  catch {
    if (Test-Path -LiteralPath $reparseCandidate) { throw }
    Write-Warning "SKIP candidate reparse test: $($_.Exception.Message)"
  }

  $readAfter = Invoke-State Read $root '' '' '' '' ''
  Assert-State $readAfter verified 0 'controller-state-verified'
  Assert-True ($readAfter.Result.resultHash -ceq $hash) 'Read-after-apply must report exact result hash'

  Write-Output "PASS control-state ($scenarioCount scenarios)"
}
finally {
  if (Test-Path -LiteralPath $testRoot) {
    Assert-True ($resolvedTestRoot.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Refusing to remove outside system temp'
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}

exit 0
