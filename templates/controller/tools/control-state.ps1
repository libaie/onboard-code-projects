[CmdletBinding()]
param(
  [string]$Action = 'Read',
  [string]$ControllerRoot,
  [string]$ExpectedHash,
  [string]$Operation,
  [string]$PayloadJson,
  [string]$CandidatePath,
  [string]$CandidateHash,
  [switch]$ConfirmCleanup
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)

if (-not ('OnboardCodeProjects.NativePath' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace OnboardCodeProjects {
  public static class NativePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(string path, uint access, FileShare share, IntPtr security, FileMode mode, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
  }
}
'@
}

function Get-Hash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Test-BytesEqual {
  param([byte[]]$Left, [byte[]]$Right)
  if ($Left.Length -ne $Right.Length) { return $false }
  for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
  return $true
}

function Test-ClosedObject {
  param([object]$Value, [string[]]$Fields)
  if ($null -eq $Value -or $Value -is [Array] -or $Value -is [string] -or $Value -is [ValueType]) { return $false }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Fields.Count) { return $false }
  foreach ($field in $Fields) { if ($actual -cnotcontains $field) { return $false } }
  return $true
}

function Test-NonEmptyString {
  param([object]$Value)
  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-Hash {
  param([object]$Value)
  return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$'
}

function Test-UtcIso8601 {
  param([object]$Value)
  if (-not (Test-NonEmptyString $Value) -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$') { return $false }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }
  return $parsed.Offset -eq [TimeSpan]::Zero
}

function Test-TimeOnOrAfter {
  param([object]$Later, [object]$Earlier)
  if (-not (Test-UtcIso8601 $Later) -or -not (Test-UtcIso8601 $Earlier)) { return $false }
  return [DateTimeOffset]::Parse([string]$Later, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -ge
    [DateTimeOffset]::Parse([string]$Earlier, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Test-LosslessWindowsPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('/') -or $Path.Length -lt 4 -or $Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { return $false }
  $components = $Path.Substring(3).Split(@('\'), [StringSplitOptions]::None)
  for ($index = 0; $index -lt $components.Count; $index++) {
    $component = $components[$index]
    if ([string]::IsNullOrEmpty($component)) {
      if ($index -eq $components.Count - 1 -and $index -gt 0) { continue }
      return $false
    }
    if ($component -in @('.', '..') -or $component.EndsWith('.') -or $component.EndsWith(' ') -or
        $component -match '[<>:"/\\|?*\x00-\x1f]' -or
        $component -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') { return $false }
  }
  return $true
}

function Test-ReparseComponents {
  param([string]$Path)
  $root = [IO.Path]::GetPathRoot($Path)
  $current = $root.TrimEnd('\')
  foreach ($part in $Path.Substring($root.Length).Split(@('\'), [StringSplitOptions]::RemoveEmptyEntries)) {
    $current = if ($current.EndsWith(':')) { $current + '\' + $part } else { Join-Path $current $part }
    if (-not (Test-Path -LiteralPath $current)) { break }
    $item = Get-Item -Force -LiteralPath $current
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
  }
  return $true
}

function Resolve-ControllerRoot {
  param([string]$Path)
  if (-not (Test-LosslessWindowsPath $Path)) { return $null }
  try { $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $null }
  $driveRoot = [IO.Path]::GetPathRoot($normalized)
  if ($normalized -ieq $driveRoot.TrimEnd('\')) { return $null }
  $drive = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $driveRoot } | Select-Object -First 1)
  if ($drive.Count -ne 1 -or $drive[0].DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) { return $null }
  if (-not (Test-Path -LiteralPath $normalized -PathType Container)) { return $null }
  if (-not (Test-ReparseComponents $normalized)) { throw 'controller-filesystem-conflict' }
  return $normalized
}

function Test-NormalizedWindowsRoot {
  param([object]$Value)
  if (-not (Test-NonEmptyString $Value) -or -not (Test-LosslessWindowsPath $Value)) { return $false }
  try { $normalized = [IO.Path]::GetFullPath($Value).TrimEnd('\') } catch { return $false }
  return $Value -ceq $normalized -and $normalized -cne [IO.Path]::GetPathRoot($normalized).TrimEnd('\')
}

function Resolve-PhysicalWindowsPath {
  param([string]$Path)
  $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $existing = $normalized
  $suffix = New-Object 'Collections.Generic.List[string]'
  while (-not (Test-Path -LiteralPath $existing)) {
    $leaf = [IO.Path]::GetFileName($existing)
    $parent = [IO.Path]::GetDirectoryName($existing)
    if ([string]::IsNullOrEmpty($leaf) -or [string]::IsNullOrEmpty($parent) -or $parent -ceq $existing) { throw 'physical-path' }
    $suffix.Insert(0, $leaf)
    $existing = $parent
  }
  if (-not (Test-Path -LiteralPath $existing -PathType Container)) { throw 'physical-path' }
  $handle = [OnboardCodeProjects.NativePath]::CreateFile($existing, 0, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete, [IntPtr]::Zero, [IO.FileMode]::Open, 0x02000000, [IntPtr]::Zero)
  if ($handle.IsInvalid) { $handle.Dispose(); throw 'physical-path' }
  try {
    $buffer = New-Object Text.StringBuilder 32768
    $length = [OnboardCodeProjects.NativePath]::GetFinalPathNameByHandle($handle, $buffer, [uint32]$buffer.Capacity, 0)
    if ($length -eq 0 -or $length -ge $buffer.Capacity) { throw 'physical-path' }
    $resolved = $buffer.ToString()
  }
  finally { $handle.Dispose() }
  if ($resolved.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $resolved = '\\' + $resolved.Substring(8) }
  elseif ($resolved.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $resolved = $resolved.Substring(4) }
  foreach ($part in $suffix) { $resolved = Join-Path $resolved $part }
  return [IO.Path]::GetFullPath($resolved).TrimEnd('\')
}

function Test-PathsOverlap {
  param([string]$Left, [string]$Right)
  try {
    $physicalLeft = Resolve-PhysicalWindowsPath $Left
    $physicalRight = Resolve-PhysicalWindowsPath $Right
  }
  catch { return $true }
  $leftPrefix = $physicalLeft + '\'
  $rightPrefix = $physicalRight + '\'
  return $physicalLeft.Equals($physicalRight, [StringComparison]::OrdinalIgnoreCase) -or
    $physicalLeft.StartsWith($rightPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $physicalRight.StartsWith($leftPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Convert-ControllerBinding {
  param([AllowNull()][object]$Value, [string]$Root)
  if ($null -eq $Value) { return $null }
  $fields = @('threadId','codexProjectId','hostId','projectRoot')
  if (-not (Test-ClosedObject $Value $fields)) { throw 'manifest' }
  foreach ($field in @('threadId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $Value.$field)) { throw 'manifest' } }
  if (-not (Test-NormalizedWindowsRoot $Value.projectRoot) -or -not $Root.Equals([string]$Value.projectRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'manifest' }
  return [pscustomobject][ordered]@{ threadId=[string]$Value.threadId; codexProjectId=[string]$Value.codexProjectId; hostId=[string]$Value.hostId; projectRoot=[string]$Value.projectRoot }
}

function Convert-ControllerTaskIntent {
  param([AllowNull()][object]$Value, [string]$Root)
  if ($null -eq $Value) { return $null }
  $fields = @('operationId','codexProjectId','hostId','projectRoot','startedAt','clientThreadId')
  if (-not (Test-ClosedObject $Value $fields)) { throw 'manifest' }
  foreach ($field in @('operationId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $Value.$field)) { throw 'manifest' } }
  if (-not (Test-NormalizedWindowsRoot $Value.projectRoot) -or -not $Root.Equals([string]$Value.projectRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-UtcIso8601 $Value.startedAt)) { throw 'manifest' }
  if ($null -ne $Value.clientThreadId -and -not (Test-NonEmptyString $Value.clientThreadId)) { throw 'manifest' }
  return [pscustomobject][ordered]@{
    operationId=[string]$Value.operationId; codexProjectId=[string]$Value.codexProjectId; hostId=[string]$Value.hostId
    projectRoot=[string]$Value.projectRoot; startedAt=[string]$Value.startedAt
    clientThreadId=if ($null -eq $Value.clientThreadId) { $null } else { [string]$Value.clientThreadId }
  }
}

function Convert-ProjectBindings {
  param([object]$Value, [string]$Root)
  if ($Value -isnot [Array] -or @($Value).Count -gt 1000) { throw 'manifest' }
  $fields = @('entryThreadId','codexProjectId','hostId','projectRoot')
  $roots = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $converted = @()
  foreach ($binding in @($Value)) {
    if (-not (Test-ClosedObject $binding $fields)) { throw 'manifest' }
    foreach ($field in @('entryThreadId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $binding.$field)) { throw 'manifest' } }
    if (-not (Test-NormalizedWindowsRoot $binding.projectRoot) -or (Test-PathsOverlap $Root ([string]$binding.projectRoot)) -or -not $roots.Add([string]$binding.projectRoot)) { throw 'manifest' }
    $converted += [pscustomobject][ordered]@{ entryThreadId=[string]$binding.entryThreadId; codexProjectId=[string]$binding.codexProjectId; hostId=[string]$binding.hostId; projectRoot=[string]$binding.projectRoot }
  }
  return @($converted)
}

function Test-ControllerText {
  param([object]$Value, [int]$MaximumLength = 4000)
  if (-not (Test-NonEmptyString $Value) -or $Value.Length -gt $MaximumLength -or $Value -match '[\x00-\x1f\x7f]') { return $false }
  $secretPattern = '(?is)(?:authorization\s*:\s*(?:bearer|basic)\s+\S+|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+|https?://[^/\s:@]+:[^/\s@]+@|https?://\S+[?&](?:access_token|refresh_token|api[_-]?key|client[_-]?secret|password)=\S+|\bgh[pousr]_[A-Za-z0-9]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b)'
  return $Value -notmatch $secretPattern
}

function Test-CredentialLocator {
  param([object]$Value)
  return $Value -is [string] -and $Value -match '(?i)(?:^|[\s"(])(?:[A-Z]:[\\/]|\\\\|/|\.{0,2}[\\/])?[^\r\n"<>|]*\.(?:xlsx?|kdbx|pem|pfx|p12|key)(?:$|[\s",;)])'
}

function Convert-TaskSpecStrings {
  param([object]$Value, [int]$MaximumItems, [bool]$RequireItem)
  if ($Value -isnot [Array] -or @($Value).Count -gt $MaximumItems -or ($RequireItem -and @($Value).Count -eq 0)) { throw 'payload' }
  $items = @()
  $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($item in @($Value)) {
    if (-not (Test-ControllerText $item 1000) -or -not $seen.Add([string]$item)) { throw 'payload' }
    $items += [string]$item
  }
  return @($items)
}

function Convert-TaskReadiness {
  param([object]$Value, [string]$ProjectId)
  if (-not (Test-ClosedObject $Value @('status','checkedAt','operationClass','targets','capabilityRefs','rollback','verification')) -or
      $Value.status -cne 'ready' -or -not (Test-UtcIso8601 $Value.checkedAt) -or
      $Value.operationClass -cnotin @('read','repository-write','external-write')) { throw 'payload' }
  $targets = @(Convert-TaskSpecStrings $Value.targets 50 $true)
  $capabilityRefs = @(Convert-TaskSpecStrings $Value.capabilityRefs 20 $false)
  $rollback = @(Convert-TaskSpecStrings $Value.rollback 50 ($Value.operationClass -cne 'read'))
  $verification = @(Convert-TaskSpecStrings $Value.verification 50 $true)
  $capabilityPrefix = 'capref:' + $ProjectId + ':'
  foreach ($reference in $capabilityRefs) {
    if (-not $reference.StartsWith($capabilityPrefix, [StringComparison]::Ordinal) -or
        $reference.Substring($capabilityPrefix.Length) -cnotmatch '^[A-Za-z0-9._-]{1,120}$') { throw 'payload' }
  }
  if ($Value.operationClass -ceq 'external-write' -and $capabilityRefs.Count -eq 0) { throw 'payload' }
  return [pscustomobject][ordered]@{
    status='ready'; checkedAt=[string]$Value.checkedAt; operationClass=[string]$Value.operationClass
    targets=@($targets); capabilityRefs=@($capabilityRefs); rollback=@($rollback); verification=@($verification)
  }
}

function Convert-TaskReturnRoute {
  param([object]$Value)
  if (-not (Test-ClosedObject $Value @('mode','controllerThreadId','hostId')) -or
      $Value.mode -cnotin @('foreground','native-callback','receipts','receipts-and-wake')) { throw 'payload' }
  if ($Value.mode -ceq 'foreground') {
    if ($Value.controllerThreadId -cne 'N/A' -or $Value.hostId -cne 'N/A') { throw 'payload' }
  }
  elseif (-not (Test-ControllerText $Value.controllerThreadId 200) -or -not (Test-ControllerText $Value.hostId 200)) { throw 'payload' }
  return [pscustomobject][ordered]@{
    mode=[string]$Value.mode; controllerThreadId=[string]$Value.controllerThreadId; hostId=[string]$Value.hostId
  }
}

function Convert-GoalBinding {
  param([object]$Value)
  $fields = @('goalLineageId','reservationId','problemInvariantId','strategyFamilyId','materialPreconditionHash','acceptanceHash','operationCoverageHash','controllerRuntimeHash','capabilityBundleHash')
  if (-not (Test-ClosedObject $Value $fields)) { throw 'payload' }
  foreach ($field in @('goalLineageId','reservationId','problemInvariantId','strategyFamilyId')) {
    if (-not (Test-ControllerText $Value.$field 128) -or $Value.$field -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') { throw 'payload' }
  }
  foreach ($field in @('materialPreconditionHash','acceptanceHash','operationCoverageHash','controllerRuntimeHash','capabilityBundleHash')) {
    if (-not (Test-Hash $Value.$field)) { throw 'payload' }
  }
  return [pscustomobject][ordered]@{
    goalLineageId=[string]$Value.goalLineageId; reservationId=[string]$Value.reservationId
    problemInvariantId=[string]$Value.problemInvariantId; strategyFamilyId=[string]$Value.strategyFamilyId
    materialPreconditionHash=[string]$Value.materialPreconditionHash; acceptanceHash=[string]$Value.acceptanceHash
    operationCoverageHash=[string]$Value.operationCoverageHash; controllerRuntimeHash=[string]$Value.controllerRuntimeHash
    capabilityBundleHash=[string]$Value.capabilityBundleHash
  }
}

function Convert-TaskDependencies {
  param([object]$Value)
  if ($Value -isnot [Array] -or @($Value).Count -gt 50) { throw 'payload' }
  $result = @(); $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($dependency in @($Value)) {
    if (-not (Test-ClosedObject $dependency @('chainId','allowedTerminalStatuses')) -or
        -not (Test-ControllerText $dependency.chainId 128) -or $dependency.chainId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
        -not $seen.Add([string]$dependency.chainId)) { throw 'payload' }
    $statuses = @(Convert-TaskSpecStrings $dependency.allowedTerminalStatuses 20 $true)
    foreach ($status in $statuses) { if ($status -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$') { throw 'payload' } }
    $result += [pscustomobject][ordered]@{ chainId=[string]$dependency.chainId; allowedTerminalStatuses=@($statuses) }
  }
  return @($result)
}

function Convert-TaskSpec {
  param([object]$Value, [string]$ProjectId, [string]$Failure = 'payload')
  try {
    $legacyFields = @('objective','nonGoals','acceptance','authorizedActions','forbiddenActions','baseline','contract','dependencies','authorizationRef')
    $currentFields = @($legacyFields) + @('readiness','returnRoute')
    $goalFields = @($currentFields) + @('goalBinding')
    $sealedFields = @($currentFields) + @('dispatchIdentity')
    $sealedGoalFields = @($goalFields) + @('dispatchIdentity')
    $isLegacy = Test-ClosedObject $Value $legacyFields
    $isCurrent = Test-ClosedObject $Value $currentFields
    $isGoalCurrent = Test-ClosedObject $Value $goalFields
    $isSealed = (Test-ClosedObject $Value $sealedFields) -or (Test-ClosedObject $Value $sealedGoalFields)
    $hasGoalBinding = $isGoalCurrent -or (Test-ClosedObject $Value $sealedGoalFields)
    $hasCurrent = $isCurrent -or $isGoalCurrent -or $isSealed
    if ((-not $isLegacy -and -not $hasCurrent) -or
        -not (Test-ControllerText $Value.objective 4000)) { throw 'invalid' }
    $nonGoals = @(Convert-TaskSpecStrings $Value.nonGoals 50 $false)
    $acceptance = @(Convert-TaskSpecStrings $Value.acceptance 50 $true)
    $authorized = @(Convert-TaskSpecStrings $Value.authorizedActions 50 $true)
    $forbidden = @(Convert-TaskSpecStrings $Value.forbiddenActions 50 $false)
    $dependencies = if ($hasGoalBinding) { @(Convert-TaskDependencies $Value.dependencies) } else { @(Convert-TaskSpecStrings $Value.dependencies 50 $false) }
    foreach ($action in $authorized) {
      if (@($forbidden | Where-Object { $_.Equals($action, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'invalid' }
    }
    if (-not (Test-ClosedObject $Value.baseline @('branch','head','dirtyHash'))) { throw 'invalid' }
    $nonGitBaseline = $Value.baseline.branch -ceq 'N/A' -and $Value.baseline.head -ceq 'N/A' -and $Value.baseline.dirtyHash -ceq 'N/A'
    if (-not $nonGitBaseline -and (-not (Test-ControllerText $Value.baseline.branch 256) -or $Value.baseline.head -isnot [string] -or
        $Value.baseline.head -cnotmatch '^[0-9a-f]{40}(?:[0-9a-f]{24})?$' -or -not (Test-Hash $Value.baseline.dirtyHash))) { throw 'invalid' }
    if (-not (Test-ClosedObject $Value.contract @('id','version','hash'))) { throw 'invalid' }
    $noContract = $Value.contract.id -ceq 'N/A' -and $Value.contract.version -ceq 'N/A' -and $Value.contract.hash -ceq 'N/A'
    if (-not $noContract -and (-not (Test-ControllerText $Value.contract.id 256) -or -not (Test-ControllerText $Value.contract.version 80) -or -not (Test-Hash $Value.contract.hash))) { throw 'invalid' }
    if (-not (Test-ControllerText $Value.authorizationRef 300)) { throw 'invalid' }
    $authorizationPrefix = 'authref:' + $ProjectId + ':'
    if (-not $Value.authorizationRef.StartsWith($authorizationPrefix, [StringComparison]::Ordinal) -or
        $Value.authorizationRef.Substring($authorizationPrefix.Length) -cnotmatch '^[A-Za-z0-9._-]{1,120}$') { throw 'invalid' }
    $canonical = [ordered]@{
      objective=[string]$Value.objective; nonGoals=@($nonGoals); acceptance=@($acceptance)
      authorizedActions=@($authorized); forbiddenActions=@($forbidden)
      baseline=[pscustomobject][ordered]@{ branch=[string]$Value.baseline.branch; head=[string]$Value.baseline.head; dirtyHash=[string]$Value.baseline.dirtyHash }
      contract=[pscustomobject][ordered]@{ id=[string]$Value.contract.id; version=[string]$Value.contract.version; hash=[string]$Value.contract.hash }
      dependencies=@($dependencies); authorizationRef=[string]$Value.authorizationRef
    }
    if ($hasCurrent) {
      $canonical.readiness = Convert-TaskReadiness $Value.readiness $ProjectId
      $canonical.returnRoute = Convert-TaskReturnRoute $Value.returnRoute
    }
    if ($hasGoalBinding) { $canonical.goalBinding = Convert-GoalBinding $Value.goalBinding }
    if ($isSealed) {
      if (-not (Test-ClosedObject $Value.dispatchIdentity @('chainId','projectTaskId','dispatchId','generation','rework')) -or
          -not (Test-ControllerText $Value.dispatchIdentity.chainId 200) -or
          -not (Test-ControllerText $Value.dispatchIdentity.projectTaskId 200) -or
          -not (Test-ControllerText $Value.dispatchIdentity.dispatchId 200) -or
          $Value.dispatchIdentity.generation -isnot [int] -or $Value.dispatchIdentity.generation -lt 1 -or
          $Value.dispatchIdentity.rework -isnot [int] -or $Value.dispatchIdentity.rework -lt 0) { throw 'invalid' }
      $canonical.dispatchIdentity = [pscustomobject][ordered]@{
        chainId=[string]$Value.dispatchIdentity.chainId; projectTaskId=[string]$Value.dispatchIdentity.projectTaskId
        dispatchId=[string]$Value.dispatchIdentity.dispatchId; generation=[int]$Value.dispatchIdentity.generation
        rework=[int]$Value.dispatchIdentity.rework
      }
    }
    $canonical = [pscustomobject]$canonical
    $locatorTexts = @($canonical.objective) + @($canonical.nonGoals) + @($canonical.acceptance) + @($canonical.authorizedActions) +
      @($canonical.forbiddenActions)
    if ($hasCurrent) {
      $locatorTexts += @($canonical.readiness.targets) + @($canonical.readiness.rollback) + @($canonical.readiness.verification)
    }
    if (@($locatorTexts | Where-Object { Test-CredentialLocator $_ }).Count -gt 0) { throw 'invalid' }
    $canonicalJson = $canonical | ConvertTo-Json -Depth 12 -Compress
    $bytes = $utf8.GetBytes($canonicalJson)
    if ($bytes.Length -gt 8192) { throw 'invalid' }
    return [pscustomobject]@{ Value=$canonical; Hash=(Get-Hash $bytes) }
  }
  catch { throw $Failure }
}

function Convert-AttemptFailures {
  param([object]$Value, [string]$Failure = 'manifest')
  try {
    if ($Value -isnot [Array] -or @($Value).Count -gt 2) { throw 'invalid' }
    $converted = @()
    $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $expectedStrategies = @('repair','rebaseline')
    $previousFinishedAt = $null
    for ($index = 0; $index -lt @($Value).Count; $index++) {
      $item = @($Value)[$index]
      if (-not (Test-ClosedObject $item @('dispatchId','failureClass','failureFingerprint','strategy','finishedAt')) -or
          -not (Test-ControllerText $item.dispatchId 200) -or -not $ids.Add([string]$item.dispatchId) -or
          -not (Test-ControllerText $item.failureClass 80) -or -not (Test-Hash $item.failureFingerprint) -or
          $item.strategy -cne $expectedStrategies[$index] -or -not (Test-UtcIso8601 $item.finishedAt)) { throw 'invalid' }
      if ($null -ne $previousFinishedAt -and -not (Test-TimeOnOrAfter $item.finishedAt $previousFinishedAt)) { throw 'invalid' }
      $converted += [pscustomobject][ordered]@{
        dispatchId=[string]$item.dispatchId; failureClass=[string]$item.failureClass; failureFingerprint=[string]$item.failureFingerprint
        strategy=[string]$item.strategy; finishedAt=[string]$item.finishedAt
      }
      $previousFinishedAt = [string]$item.finishedAt
    }
    return @($converted)
  }
  catch { throw $Failure }
}

function Convert-DispatchRecord {
  param([object]$Value, [string]$ProjectRoot, [string]$EntryThreadId, [string]$ProjectId, [string]$Kind)
  $fields = @('chainId','projectTaskId','dispatchId','generation','rework','accessMode','modelClass','taskSpec','taskSpecHash','attemptFailures','deliveryReconciliation','authorizationResumedAt','enqueuedAt','startedAt','phase','resultState','evidenceHash','finishedAt','cancelRequestedAt','writeLease')
  if (-not (Test-ClosedObject $Value $fields)) { throw 'manifest' }
  foreach ($field in @('chainId','projectTaskId','dispatchId','accessMode','modelClass','enqueuedAt','phase')) {
    if (-not (Test-ControllerText $Value.$field 200)) { throw 'manifest' }
  }
  if ($Value.projectTaskId -cne $EntryThreadId -or $Value.generation -isnot [int] -or $Value.generation -lt 1 -or $Value.rework -isnot [int] -or $Value.rework -lt 0 -or
      $Value.accessMode -cnotin @('read','write') -or $Value.modelClass -cnotin @('economy','balanced','frontier') -or -not (Test-UtcIso8601 $Value.enqueuedAt)) { throw 'manifest' }
  $taskSpec = Convert-TaskSpec $Value.taskSpec $ProjectId 'manifest'
  if (-not (Test-Hash $Value.taskSpecHash) -or $Value.taskSpecHash -cne $taskSpec.Hash) { throw 'manifest' }
  if ($taskSpec.Value.PSObject.Properties.Name -ccontains 'dispatchIdentity') {
    $identity = $taskSpec.Value.dispatchIdentity
    if ($identity.chainId -cne $Value.chainId -or $identity.projectTaskId -cne $Value.projectTaskId -or
        $identity.dispatchId -cne $Value.dispatchId -or $identity.generation -ne $Value.generation -or
        $identity.rework -ne $Value.rework) { throw 'manifest' }
  }
  $failures = @(Convert-AttemptFailures $Value.attemptFailures 'manifest')
  if ($Value.generation -ne ($failures.Count + 1) -or $Value.rework -ne $failures.Count -or @($failures | Where-Object { $_.dispatchId -ceq $Value.dispatchId }).Count -gt 0) { throw 'manifest' }
  if ($failures.Count -gt 0 -and -not (Test-TimeOnOrAfter $Value.enqueuedAt $failures[$failures.Count - 1].finishedAt)) { throw 'manifest' }
  $deliveryReconciliation = $null
  if ($null -ne $Value.deliveryReconciliation) {
    $legacyReconciliation = Test-ClosedObject $Value.deliveryReconciliation @('evidenceHash','confirmedAt')
    $preflightReconciliation = Test-ClosedObject $Value.deliveryReconciliation @('failureClass','evidenceHash','confirmedAt')
    if ((-not $legacyReconciliation -and -not $preflightReconciliation) -or -not (Test-Hash $Value.deliveryReconciliation.evidenceHash) -or
        -not (Test-UtcIso8601 $Value.deliveryReconciliation.confirmedAt) -or
        ($preflightReconciliation -and $Value.deliveryReconciliation.failureClass -cnotin @('transport','tool-bootstrap','payload-parse'))) { throw 'manifest' }
    if ($preflightReconciliation) {
      $deliveryReconciliation = [pscustomobject][ordered]@{
        failureClass=[string]$Value.deliveryReconciliation.failureClass
        evidenceHash=[string]$Value.deliveryReconciliation.evidenceHash; confirmedAt=[string]$Value.deliveryReconciliation.confirmedAt
      }
    }
    else {
      $deliveryReconciliation = [pscustomobject][ordered]@{ evidenceHash=[string]$Value.deliveryReconciliation.evidenceHash; confirmedAt=[string]$Value.deliveryReconciliation.confirmedAt }
    }
  }
  foreach ($nullableTime in @('authorizationResumedAt','startedAt','finishedAt','cancelRequestedAt')) {
    if ($null -ne $Value.$nullableTime -and -not (Test-UtcIso8601 $Value.$nullableTime)) { throw 'manifest' }
  }
  if (($null -ne $Value.startedAt -and -not (Test-TimeOnOrAfter $Value.startedAt $Value.enqueuedAt)) -or
      ($null -ne $Value.finishedAt -and ($null -eq $Value.startedAt -or -not (Test-TimeOnOrAfter $Value.finishedAt $Value.startedAt))) -or
      ($null -ne $Value.cancelRequestedAt -and ($null -eq $Value.startedAt -or -not (Test-TimeOnOrAfter $Value.cancelRequestedAt $Value.startedAt))) -or
      ($null -ne $deliveryReconciliation -and ($null -eq $Value.startedAt -or -not (Test-TimeOnOrAfter $deliveryReconciliation.confirmedAt $Value.startedAt)))) { throw 'manifest' }
  if ($null -ne $Value.resultState -and ($Value.resultState -isnot [string] -or $Value.resultState -cnotin @('completed','blocked','auth-required','cancelled','convergence-failed'))) { throw 'manifest' }
  if ($null -ne $Value.evidenceHash -and -not (Test-Hash $Value.evidenceHash)) { throw 'manifest' }

  $lease = $null
  if ($null -ne $Value.writeLease) {
    if (-not (Test-ClosedObject $Value.writeLease @('leaseId','acquiredAt','releasedAt')) -or -not (Test-NonEmptyString $Value.writeLease.leaseId) -or -not (Test-UtcIso8601 $Value.writeLease.acquiredAt) -or
        ($null -ne $Value.writeLease.releasedAt -and -not (Test-UtcIso8601 $Value.writeLease.releasedAt))) { throw 'manifest' }
    $lease = [pscustomobject][ordered]@{ leaseId=[string]$Value.writeLease.leaseId; acquiredAt=[string]$Value.writeLease.acquiredAt; releasedAt=if ($null -eq $Value.writeLease.releasedAt) { $null } else { [string]$Value.writeLease.releasedAt } }
    if (($null -ne $Value.finishedAt -and $null -ne $lease.releasedAt -and -not (Test-TimeOnOrAfter $lease.releasedAt $Value.finishedAt)) -or
        ($null -ne $Value.startedAt -and -not (Test-TimeOnOrAfter $Value.startedAt $lease.acquiredAt))) { throw 'manifest' }
  }

  switch -CaseSensitive ($Kind) {
    'pending' {
      if ($Value.phase -cne 'queued' -or $failures.Count -ne 0 -or $null -ne $deliveryReconciliation -or $null -ne $Value.authorizationResumedAt -or $null -ne $Value.startedAt -or $null -ne $Value.resultState -or $null -ne $Value.evidenceHash -or $null -ne $Value.finishedAt -or $null -ne $Value.cancelRequestedAt -or $null -ne $lease) { throw 'manifest' }
    }
    'active' {
      if ($Value.phase -cnotin @('dispatching','sent','delivery-unknown','running','approval-wait','terminal')) { throw 'manifest' }
      if ($null -eq $Value.startedAt) { throw 'manifest' }
      if ($Value.phase -cne 'terminal') {
        if ($null -ne $Value.resultState -or $null -ne $Value.evidenceHash -or $null -ne $Value.finishedAt) { throw 'manifest' }
      }
      else {
        if ($Value.resultState -cnotin @('completed','blocked','auth-required','cancelled','convergence-failed') -or -not (Test-Hash $Value.evidenceHash) -or $null -eq $Value.finishedAt) { throw 'manifest' }
        if ($Value.resultState -ceq 'convergence-failed' -and $failures.Count -ne 2) { throw 'manifest' }
      }
      if (($Value.accessMode -ceq 'write') -ne ($null -ne $lease) -or ($null -ne $lease -and $null -ne $lease.releasedAt)) { throw 'manifest' }
    }
    'terminal' {
      if ($Value.phase -cne 'terminal' -or $Value.resultState -cnotin @('completed','cancelled') -or
          -not (Test-Hash $Value.evidenceHash) -or $null -eq $Value.startedAt -or $null -eq $Value.finishedAt) { throw 'manifest' }
      if (($Value.accessMode -ceq 'write') -ne ($null -ne $lease) -or ($null -ne $lease -and $null -eq $lease.releasedAt)) { throw 'manifest' }
    }
    default { throw 'manifest' }
  }
  return [pscustomobject][ordered]@{
    chainId=[string]$Value.chainId; projectTaskId=[string]$Value.projectTaskId; dispatchId=[string]$Value.dispatchId
    generation=[int]$Value.generation; rework=[int]$Value.rework; accessMode=[string]$Value.accessMode; modelClass=[string]$Value.modelClass
    taskSpec=$taskSpec.Value; taskSpecHash=[string]$taskSpec.Hash; attemptFailures=@($failures); deliveryReconciliation=$deliveryReconciliation
    authorizationResumedAt=if ($null -eq $Value.authorizationResumedAt) { $null } else { [string]$Value.authorizationResumedAt }
    enqueuedAt=[string]$Value.enqueuedAt; startedAt=if ($null -eq $Value.startedAt) { $null } else { [string]$Value.startedAt }
    phase=[string]$Value.phase
    resultState=if ($null -eq $Value.resultState) { $null } else { [string]$Value.resultState }
    evidenceHash=if ($null -eq $Value.evidenceHash) { $null } else { [string]$Value.evidenceHash }
    finishedAt=if ($null -eq $Value.finishedAt) { $null } else { [string]$Value.finishedAt }
    cancelRequestedAt=if ($null -eq $Value.cancelRequestedAt) { $null } else { [string]$Value.cancelRequestedAt }; writeLease=$lease
  }
}

function Convert-DispatchQueues {
  param([object]$Value, [object[]]$Projects)
  if ($Value -isnot [Array] -or @($Value).Count -gt 1000) { throw 'manifest' }
  $roots = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $converted = @()
  foreach ($queue in @($Value)) {
    if (-not (Test-ClosedObject $queue @('projectRoot','active','pending','lastTerminal')) -or -not (Test-NormalizedWindowsRoot $queue.projectRoot) -or -not $roots.Add([string]$queue.projectRoot) -or $queue.pending -isnot [Array] -or @($queue.pending).Count -gt 100) { throw 'manifest' }
    $binding = @($Projects | Where-Object { $_.projectRoot.Equals([string]$queue.projectRoot, [StringComparison]::OrdinalIgnoreCase) })
    if ($binding.Count -ne 1) { throw 'manifest' }
    $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $pending = @()
    foreach ($dispatch in @($queue.pending)) {
      $item = Convert-DispatchRecord $dispatch ([string]$queue.projectRoot) ([string]$binding[0].entryThreadId) ([string]$binding[0].codexProjectId) 'pending'
      if (-not $ids.Add($item.dispatchId)) { throw 'manifest' }
      $pending += $item
    }
    $active = if ($null -eq $queue.active) { $null } else { Convert-DispatchRecord $queue.active ([string]$queue.projectRoot) ([string]$binding[0].entryThreadId) ([string]$binding[0].codexProjectId) 'active' }
    if ($null -ne $active -and -not $ids.Add($active.dispatchId)) { throw 'manifest' }
    # A terminal record may reference the entry task that owned the completed dispatch before an explicit binding reconciliation.
    $terminalEntry = if ($null -eq $queue.lastTerminal) { $null } else { [string]$queue.lastTerminal.projectTaskId }
    $lastTerminal = if ($null -eq $queue.lastTerminal) { $null } else { Convert-DispatchRecord $queue.lastTerminal ([string]$queue.projectRoot) $terminalEntry ([string]$binding[0].codexProjectId) 'terminal' }
    if ($null -ne $lastTerminal -and -not $ids.Add($lastTerminal.dispatchId)) { throw 'manifest' }
    $converted += [pscustomobject][ordered]@{ projectRoot=[string]$queue.projectRoot; active=$active; pending=@($pending); lastTerminal=$lastTerminal }
  }
  return @($converted)
}

function Convert-ManifestBytes {
  param([byte[]]$Bytes, [string]$Root)
  try {
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 1MB -or ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) { throw 'manifest' }
    $text = $utf8.GetString($Bytes)
    $manifest = $text | ConvertFrom-Json -ErrorAction Stop
    $version = $manifest.schemaVersion
    $fields = if ($version -eq 1) { @('schemaVersion','generator','templateVersion','controllerName','controllerBinding','controllerTaskIntent','projectBindings') } else { @('schemaVersion','generator','templateVersion','controllerName','controllerBinding','controllerTaskIntent','projectBindings','dispatchQueues') }
    if (-not (Test-ClosedObject $manifest $fields)) { throw 'manifest' }
    if ($manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -notin @(1,2) -or $manifest.generator -cne 'onboard-code-projects' -or $manifest.templateVersion -isnot [int] -or $manifest.templateVersion -ne $manifest.schemaVersion) { throw 'manifest' }
    if (-not (Test-NonEmptyString $manifest.controllerName) -or $manifest.controllerName.Length -gt 80 -or $manifest.controllerName -match '[\x00-\x1f\x7f/\\]') { throw 'manifest' }
    $binding = Convert-ControllerBinding $manifest.controllerBinding $Root
    $intent = Convert-ControllerTaskIntent $manifest.controllerTaskIntent $Root
    if ($null -ne $binding -and $null -ne $intent) { throw 'manifest' }
    $projects = @(Convert-ProjectBindings $manifest.projectBindings $Root)
    $canonical = [ordered]@{
      schemaVersion=[int]$version; generator='onboard-code-projects'; templateVersion=[int]$version; controllerName=[string]$manifest.controllerName
      controllerBinding=$binding; controllerTaskIntent=$intent; projectBindings=@($projects)
    }
    if ($version -eq 2) { $canonical.dispatchQueues = @(Convert-DispatchQueues $manifest.dispatchQueues $projects) }
    $canonical = [pscustomobject]$canonical
    $canonicalBytes = $utf8.GetBytes(($canonical | ConvertTo-Json -Depth 12 -Compress) + "`n")
    if (-not (Test-BytesEqual $Bytes $canonicalBytes)) { throw 'manifest' }
    return [pscustomobject]@{ Data=$canonical; Bytes=$canonicalBytes; Hash=(Get-Hash $canonicalBytes) }
  }
  catch { throw 'manifest' }
}

function Read-Manifest {
  param([string]$Root)
  $path = Join-Path $Root '.codex-controller.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-ReparseComponents $path)) { throw 'manifest' }
  $item = Get-Item -Force -LiteralPath $path
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'manifest' }
  $bytes = [IO.File]::ReadAllBytes($path)
  return Convert-ManifestBytes $bytes $Root
}

function Write-StateResult {
  param(
    [string]$Status, [string]$ReasonCode, [AllowNull()][object]$Root,
    [AllowNull()][object]$Current, [AllowNull()][object]$Candidate,
    [AllowNull()][object]$CandidateDigest, [AllowNull()][object]$Result,
    [AllowNull()][object]$Data, [string]$NextAction, [string[]]$Warnings, [int]$ExitCode
  )
  [pscustomobject][ordered]@{
    schemaVersion=1; action=$Action; status=$Status; reasonCode=$ReasonCode; controllerRoot=$Root
    currentHash=$Current; candidatePath=$Candidate; candidateHash=$CandidateDigest; resultHash=$Result
    data=$Data; nextAction=$NextAction; warnings=@($Warnings)
  } | ConvertTo-Json -Depth 12 -Compress
  exit $ExitCode
}

function Finish-Invalid {
  param([string]$Reason='invalid-controller-state-input', [AllowNull()][object]$Root=$ControllerRoot, [AllowNull()][object]$Current=$null, [AllowNull()][object]$Candidate=$null, [AllowNull()][object]$Digest=$null)
  Write-StateResult invalid $Reason $Root $Current $Candidate $Digest $null $null 'Correct the input and rerun without changing controller state.' @() 2
}

function Finish-Conflict {
  param([string]$Reason, [string]$Root, [AllowNull()][object]$Current=$null, [AllowNull()][object]$Candidate=$null, [AllowNull()][object]$Digest=$null, [string]$Next='Read the current controller state, reconcile it, then retry.')
  Write-StateResult conflict $Reason $Root $Current $Candidate $Digest $null $null $Next @() 1
}

function Finish-Blocked {
  param([string]$Reason='controller-io-failure', [AllowNull()][object]$Root=$ControllerRoot, [AllowNull()][object]$Current=$null, [AllowNull()][object]$Candidate=$null, [AllowNull()][object]$Digest=$null, [string]$Next='Preserve current files, resolve the runtime or filesystem failure, then retry.')
  Write-StateResult blocked $Reason $Root $Current $Candidate $Digest $null $null $Next @('Controller state was not reported as successfully changed.') 1
}

function Get-CandidateItems {
  param([string]$Root)
  return @(Get-ChildItem -Force -LiteralPath $Root | Where-Object { $_.Name -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$' })
}

function Resolve-Candidate {
  param([string]$Root, [string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-LosslessWindowsPath $Path)) { return $null }
  try { $normalized = [IO.Path]::GetFullPath($Path) } catch { return $null }
  if (-not [string]::Equals((Split-Path -Parent $normalized), $Root, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $normalized) -cnotmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$') { return $null }
  if (-not (Test-Path -LiteralPath $normalized -PathType Leaf) -or -not (Test-ReparseComponents $normalized)) { return $null }
  $item = Get-Item -Force -LiteralPath $normalized
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  return $normalized
}

function Test-CandidateArgument {
  param([string]$Root, [string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-LosslessWindowsPath $Path)) { return $false }
  try { $normalized = [IO.Path]::GetFullPath($Path) } catch { return $false }
  return (Split-Path -Parent $normalized).Equals($Root, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $normalized) -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$'
}

function Get-MutexName {
  param([string]$Root)
  return 'Local\onboard-code-projects-' + (Get-Hash $utf8.GetBytes($Root.ToUpperInvariant()))
}

function Enter-ControllerMutex {
  param([string]$Root)
  $mutex = New-Object Threading.Mutex($false, (Get-MutexName $Root))
  $acquired = $false
  try { $acquired = $mutex.WaitOne(5000) }
  catch [Threading.AbandonedMutexException] { $acquired = $true }
  return [pscustomobject]@{ Mutex=$mutex; Acquired=$acquired }
}

function Convert-Payload {
  param([string]$Json, [string[]]$Fields)
  if ([string]::IsNullOrWhiteSpace($Json)) { throw 'payload' }
  try { $payload = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw 'payload' }
  if (-not (Test-ClosedObject $payload $Fields)) { throw 'payload' }
  return $payload
}

function New-QueuedDispatch {
  param([object]$Payload, [string]$ProjectId)
  $taskSpec = Convert-TaskSpec $Payload.taskSpec $ProjectId
  if ($taskSpec.Value.PSObject.Properties.Name -ccontains 'dispatchIdentity') { throw 'payload' }
  Add-Member -InputObject $taskSpec.Value -NotePropertyName dispatchIdentity -NotePropertyValue ([pscustomobject][ordered]@{
    chainId=[string]$Payload.chainId; projectTaskId=[string]$Payload.projectTaskId; dispatchId=[string]$Payload.dispatchId
    generation=[int]$Payload.generation; rework=[int]$Payload.rework
  })
  $taskSpec = Convert-TaskSpec $taskSpec.Value $ProjectId
  return [pscustomobject][ordered]@{
    chainId=[string]$Payload.chainId; projectTaskId=[string]$Payload.projectTaskId; dispatchId=[string]$Payload.dispatchId
    generation=[int]$Payload.generation; rework=[int]$Payload.rework; accessMode=[string]$Payload.accessMode; modelClass=[string]$Payload.modelClass
    taskSpec=$taskSpec.Value; taskSpecHash=[string]$taskSpec.Hash; attemptFailures=@(); deliveryReconciliation=$null; authorizationResumedAt=$null
    enqueuedAt=[string]$Payload.enqueuedAt; startedAt=$null; phase='queued'; resultState=$null; evidenceHash=$null; finishedAt=$null; cancelRequestedAt=$null; writeLease=$null
  }
}

function Invoke-ChainStoreRead {
  param([string]$Root, [string]$StoreAction, [string]$IdentitySwitch, [string]$Identity)
  $tool = Join-Path $PSScriptRoot 'chain-store.ps1'
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'goal' }
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $tool + '" -Action ' + $StoreAction + ' -ControllerRoot "' + $Root + '" -' + $IdentitySwitch + ' "' + $Identity + '"'
  $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::Start($startInfo)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(30000)) { try { $process.Kill() } catch {}; throw 'goal' }
    $document = $stdout.GetAwaiter().GetResult().Trim(); $errorText = $stderr.GetAwaiter().GetResult().Trim()
    $exitCode = $process.ExitCode
  }
  finally { $process.Dispose() }
  try { $result = $document | ConvertFrom-Json -ErrorAction Stop } catch { throw 'goal' }
  if ($exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($errorText)) { throw ('goal-store-' + [string]$result.reasonCode) }
  return $result
}

function Read-GoalReservation {
  param([string]$Root, [string]$GoalLineageId)
  $result = Invoke-ChainStoreRead $Root 'GoalGet' 'GoalLineageId' $GoalLineageId
  if ($result.status -cne 'verified' -or $result.reasonCode -cne 'goal-read') { throw 'goal' }
  return $result.data.record
}

function Get-TaskObjectiveFingerprint {
  param([object]$TaskSpec)
  $identity = [pscustomobject][ordered]@{ objective=$TaskSpec.objective; nonGoals=@($TaskSpec.nonGoals); contract=$TaskSpec.contract }
  return Get-Hash ($utf8.GetBytes(($identity | ConvertTo-Json -Depth 6 -Compress)))
}

function Get-CanonicalValueHash {
  param($Value)
  return Get-Hash ($utf8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 8 -Compress)))
}

function Get-ControllerRuntimeHash {
  $descriptors = @()
  foreach ($name in @('control-state.ps1','chain-store.ps1')) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-ReparseComponents $path)) { throw 'runtime' }
    $descriptors += [pscustomobject][ordered]@{ path=$name; sha256=(Get-Hash ([IO.File]::ReadAllBytes($path))) }
  }
  return Get-CanonicalValueHash @($descriptors)
}

function Assert-DispatchRuntime {
  param([object]$Dispatch)
  if ($Dispatch.taskSpec.PSObject.Properties.Name -ccontains 'goalBinding' -and
      $Dispatch.taskSpec.goalBinding.controllerRuntimeHash -cne (Get-ControllerRuntimeHash)) { throw 'runtime' }
}

function Test-CanonicalValueEqual {
  param($Left, $Right)
  return (ConvertTo-Json -InputObject $Left -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $Right -Depth 8 -Compress)
}

function Assert-TaskDependencies {
  param([string]$Root, [object[]]$Dependencies)
  foreach ($dependency in @($Dependencies)) {
    try { $result = Invoke-ChainStoreRead $Root 'Get' 'ChainId' ([string]$dependency.chainId) }
    catch {
      if ($_.Exception.Message -ceq 'goal-store-task-not-found') { throw 'dependency-wait' }
      throw 'dependency-state'
    }
    if ($result.status -cne 'verified' -or $result.reasonCode -cne 'task-read' -or $result.data.record.state -cne 'terminal') { throw 'dependency-wait' }
    if (@($dependency.allowedTerminalStatuses | Where-Object { $_ -ceq [string]$result.data.record.status }).Count -eq 0) { throw 'dependency-unsatisfied' }
  }
}

function Assert-GoalReservationBinding {
  param([string]$Root, [string]$ProjectRoot, [string]$ChainId, [string]$DispatchId, [object]$TaskSpec, [string]$Strategy, [int]$AttemptNumber)
  $Binding = $TaskSpec.goalBinding
  $goal = Read-GoalReservation $Root ([string]$Binding.goalLineageId)
  $lanes = @($goal.lanes | Where-Object { $_.projectRoot.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase) })
  if ($goal.state -cne 'active' -or $goal.objectiveFingerprint -cne (Get-TaskObjectiveFingerprint $TaskSpec) -or
      $lanes.Count -ne 1 -or $null -eq $lanes[0].activeReservation) { throw 'goal' }
  $reservation = $lanes[0].activeReservation
  if ($reservation.controllerRuntimeHash -cne (Get-ControllerRuntimeHash)) { throw 'runtime' }
  $pairs = @(
    @('reservationId','reservationId'), @('problemInvariantId','problemInvariantId'), @('strategyFamilyId','strategyFamilyId'),
    @('materialPreconditionHash','materialPreconditionHash'), @('acceptanceHash','acceptanceHash'), @('operationCoverageHash','operationCoverageHash'),
    @('controllerRuntimeHash','controllerRuntimeHash'), @('capabilityBundleHash','capabilityBundleHash')
  )
  foreach ($pair in $pairs) { if ([string]$Binding.($pair[0]) -cne [string]$reservation.($pair[1])) { throw 'goal' } }
  if ($reservation.chainId -cne $ChainId -or $reservation.dispatchId -cne $DispatchId -or
      $reservation.strategy -cne $Strategy -or $reservation.attemptNumber -ne $AttemptNumber -or $reservation.retryOrdinal -ne 0) { throw 'goal' }
  $acceptanceIds = @($TaskSpec.acceptance | ForEach-Object { Get-Hash ($utf8.GetBytes([string]$_)) })
  if (-not (Test-CanonicalValueEqual $reservation.acceptanceIds $acceptanceIds) -or
      $reservation.acceptanceHash -cne (Get-CanonicalValueHash $acceptanceIds) -or
      $reservation.executionFingerprint -cne (Get-CanonicalValueHash $TaskSpec.baseline)) { throw 'goal' }
  $expectedMaterial = [ordered]@{
    contractVersionHash=Get-CanonicalValueHash $TaskSpec.contract
    targetSetHash=Get-CanonicalValueHash @($TaskSpec.readiness.targets)
    capabilitySetHash=Get-CanonicalValueHash @($TaskSpec.readiness.capabilityRefs)
    authorizationBoundaryHash=Get-CanonicalValueHash ([string]$TaskSpec.authorizationRef)
    failureOracleHash=Get-CanonicalValueHash @($TaskSpec.readiness.verification)
  }
  foreach ($field in $expectedMaterial.Keys) { if ($reservation.materialPreconditions.$field -cne $expectedMaterial[$field]) { throw 'goal' } }
  if (@($reservation.operationCoverage).Count -ne $acceptanceIds.Count) { throw 'goal' }
  foreach ($index in 0..($acceptanceIds.Count - 1)) {
    $row = @($reservation.operationCoverage | Where-Object { $_.acceptanceId -ceq $acceptanceIds[$index] })
    if ($row.Count -ne 1 -or $row[0].operationClass -cne $TaskSpec.readiness.operationClass -or
        -not (Test-CanonicalValueEqual $row[0].targets @($TaskSpec.readiness.targets)) -or
        -not (Test-CanonicalValueEqual $row[0].capabilityRefs @($TaskSpec.readiness.capabilityRefs)) -or
        $row[0].authorizationRef -cne $TaskSpec.authorizationRef -or
        -not (Test-CanonicalValueEqual $row[0].verification @($TaskSpec.readiness.verification)) -or
        -not (Test-CanonicalValueEqual $row[0].rollback @($TaskSpec.readiness.rollback))) { throw 'goal' }
  }
}

function Assert-GoalRetryEvidence {
  param([string]$Root, [string]$ProjectRoot, [object]$PreviousTaskSpec, [object]$NextTaskSpec, [string]$FailureFingerprint)
  $goal = Read-GoalReservation $Root ([string]$NextTaskSpec.goalBinding.goalLineageId)
  $lane = @($goal.lanes | Where-Object { $_.projectRoot.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase) })
  if ($lane.Count -ne 1) { throw 'goal' }
  $prior = @($lane[0].outcomes | Where-Object { $_.reservation.reservationId -ceq $PreviousTaskSpec.goalBinding.reservationId })
  if ($prior.Count -ne 1 -or $prior[0].outcome -notin @('deterministic-failure','environment-block','superseded') -or
      $prior[0].evidenceHash -cne $FailureFingerprint) { throw 'goal' }
}

function Assert-GoalCloseEvidence {
  param([string]$Root, [string]$ProjectRoot, [object]$Dispatch)
  if ($Dispatch.taskSpec.PSObject.Properties.Name -cnotcontains 'goalBinding') { return }
  $goal = Read-GoalReservation $Root ([string]$Dispatch.taskSpec.goalBinding.goalLineageId)
  $lane = $null
  foreach ($candidate in @($goal.lanes)) {
    if ($candidate.projectRoot.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
      if ($null -ne $lane) { throw 'goal-close-lane' }
      $lane = $candidate
    }
  }
  if ($null -eq $lane) { throw 'goal-close-lane' }
  $expected = if ($Dispatch.resultState -ceq 'completed') { 'accepted-success' } else { 'cancelled' }
  $outcome = $null
  foreach ($candidate in @($lane.outcomes)) {
    if ($candidate.reservation.reservationId -ceq $Dispatch.taskSpec.goalBinding.reservationId) {
      if ($null -ne $outcome) { throw 'goal-close-reservation' }
      $outcome = $candidate
    }
  }
  if ($null -eq $outcome) { throw 'goal-close-reservation' }
  if ($outcome.outcome -cne $expected) { throw 'goal-close-result' }
  if ($outcome.evidenceHash -cne $Dispatch.evidenceHash) { throw 'goal-close-evidence' }
  if ($null -ne $lane.activeReservation) { throw 'goal-close-active' }
}

function Get-QueueIndex {
  param([AllowEmptyCollection()][object[]]$Queues, [string]$ProjectRoot)
  for ($index = 0; $index -lt $Queues.Count; $index++) {
    if ($Queues[$index].projectRoot.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) { return $index }
  }
  return -1
}

function Find-DispatchById {
  param([AllowEmptyCollection()][object[]]$Queues, [string]$DispatchId)
  foreach ($queue in $Queues) {
    foreach ($item in @($queue.active, $queue.lastTerminal) + @($queue.pending)) {
      if ($null -ne $item -and $item.dispatchId -ceq $DispatchId) { return $item }
    }
  }
  return $null
}

function Test-DispatchEqual {
  param([object]$Left, [object]$Right)
  return ($Left | ConvertTo-Json -Depth 6 -Compress) -ceq ($Right | ConvertTo-Json -Depth 6 -Compress)
}

function Test-RetryTaskSpecScope {
  param([object]$Previous, [object]$Candidate)
  $previousScope = [pscustomobject][ordered]@{
    objective=$Previous.objective; nonGoals=$Previous.nonGoals
    authorizedActions=$Previous.authorizedActions; forbiddenActions=$Previous.forbiddenActions
    contract=$Previous.contract; authorizationRef=$Previous.authorizationRef; returnRoute=$Previous.returnRoute
    branch=$Previous.baseline.branch; operationClass=$Previous.readiness.operationClass
    targets=$Previous.readiness.targets; capabilityRefs=$Previous.readiness.capabilityRefs; rollback=$Previous.readiness.rollback
  }
  $candidateScope = [pscustomobject][ordered]@{
    objective=$Candidate.objective; nonGoals=$Candidate.nonGoals
    authorizedActions=$Candidate.authorizedActions; forbiddenActions=$Candidate.forbiddenActions
    contract=$Candidate.contract; authorizationRef=$Candidate.authorizationRef; returnRoute=$Candidate.returnRoute
    branch=$Candidate.baseline.branch; operationClass=$Candidate.readiness.operationClass
    targets=$Candidate.readiness.targets; capabilityRefs=$Candidate.readiness.capabilityRefs; rollback=$Candidate.readiness.rollback
  }
  if (-not (Test-DispatchEqual $previousScope $candidateScope)) { return $false }
  if ($null -eq $Previous.goalBinding -or $null -eq $Candidate.goalBinding -or
      $Previous.goalBinding.goalLineageId -cne $Candidate.goalBinding.goalLineageId -or
      $Previous.goalBinding.problemInvariantId -cne $Candidate.goalBinding.problemInvariantId) { return $false }
  foreach ($dependency in @($Previous.dependencies)) {
    $dependencyJson = $dependency | ConvertTo-Json -Depth 4 -Compress
    if (@($Candidate.dependencies | Where-Object { ($_ | ConvertTo-Json -Depth 4 -Compress) -ceq $dependencyJson }).Count -eq 0) { return $false }
  }
  return Test-TimeOnOrAfter $Candidate.readiness.checkedAt $Previous.readiness.checkedAt
}

function New-MutatedManifest {
  param([object]$Manifest, [string]$Mutation, [string]$Json, [string]$Root)
  $version = [int]$Manifest.schemaVersion
  $binding = $Manifest.controllerBinding
  $intent = $Manifest.controllerTaskIntent
  $projects = @($Manifest.projectBindings)
  $queues = @()
  if ($version -eq 2) { $queues = @($Manifest.dispatchQueues) }
  switch -CaseSensitive ($Mutation) {
    'set-task-intent' {
      $payload = Convert-Payload $Json @('operationId','codexProjectId','hostId','projectRoot','startedAt')
      foreach ($field in @('operationId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $payload.$field)) { throw 'payload' } }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not $Root.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-UtcIso8601 $payload.startedAt)) { throw 'payload' }
      if ($null -ne $binding -or $null -ne $intent) { throw 'state' }
      $intent = [pscustomobject][ordered]@{ operationId=[string]$payload.operationId; codexProjectId=[string]$payload.codexProjectId; hostId=[string]$payload.hostId; projectRoot=[string]$payload.projectRoot; startedAt=[string]$payload.startedAt; clientThreadId=$null }
    }
    'record-client-thread' {
      $payload = Convert-Payload $Json @('operationId','clientThreadId')
      if (-not (Test-NonEmptyString $payload.operationId) -or -not (Test-NonEmptyString $payload.clientThreadId)) { throw 'payload' }
      if ($null -ne $binding -or $null -eq $intent -or $intent.operationId -cne $payload.operationId) { throw 'state' }
      if ($null -ne $intent.clientThreadId -and $intent.clientThreadId -cne $payload.clientThreadId) { throw 'state' }
      $intent = [pscustomobject][ordered]@{ operationId=$intent.operationId; codexProjectId=$intent.codexProjectId; hostId=$intent.hostId; projectRoot=$intent.projectRoot; startedAt=$intent.startedAt; clientThreadId=[string]$payload.clientThreadId }
    }
    'bind-controller' {
      $payload = Convert-Payload $Json @('operationId','threadId','codexProjectId','hostId','projectRoot')
      foreach ($field in @('operationId','threadId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $payload.$field)) { throw 'payload' } }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot)) { throw 'payload' }
      if (-not $Root.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'state' }
      if ($null -ne $binding -or $null -eq $intent -or $intent.operationId -cne $payload.operationId -or $intent.codexProjectId -cne $payload.codexProjectId -or $intent.hostId -cne $payload.hostId -or -not $intent.projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'state' }
      $binding = [pscustomobject][ordered]@{ threadId=[string]$payload.threadId; codexProjectId=[string]$payload.codexProjectId; hostId=[string]$payload.hostId; projectRoot=[string]$payload.projectRoot }
      $intent = $null
    }
    'register-project' {
      $payload = Convert-Payload $Json @('entryThreadId','codexProjectId','hostId','projectRoot')
      foreach ($field in @('entryThreadId','codexProjectId','hostId')) { if (-not (Test-NonEmptyString $payload.$field)) { throw 'payload' } }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or (Test-PathsOverlap $Root ([string]$payload.projectRoot))) { throw 'payload' }
      if ($null -eq $binding) { throw 'state' }
      # ponytail: linear scan is intentional for up to 100 bindings; use a keyed schema if larger controllers become common.
      $existing = @($projects | Where-Object { $_.projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase) })
      if ($existing.Count -gt 0) {
        $same = $existing[0].entryThreadId -ceq $payload.entryThreadId -and $existing[0].codexProjectId -ceq $payload.codexProjectId -and $existing[0].hostId -ceq $payload.hostId
        if (-not $same) { throw 'project' }
      }
      else {
        if ($projects.Count -ge 1000) { throw 'project-limit' }
        $projects += [pscustomobject][ordered]@{ entryThreadId=[string]$payload.entryThreadId; codexProjectId=[string]$payload.codexProjectId; hostId=[string]$payload.hostId; projectRoot=[string]$payload.projectRoot }
      }
    }
    'enqueue-dispatch' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','chainId','projectTaskId','dispatchId','generation','rework','accessMode','modelClass','taskSpec','enqueuedAt')
      foreach ($field in @('chainId','projectTaskId','dispatchId','accessMode','modelClass')) { if (-not (Test-ControllerText $payload.$field 200)) { throw 'payload' } }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or $payload.generation -isnot [int] -or $payload.generation -ne 1 -or $payload.rework -isnot [int] -or $payload.rework -ne 0 -or
          $payload.accessMode -cnotin @('read','write') -or $payload.modelClass -cnotin @('economy','balanced','frontier') -or -not (Test-UtcIso8601 $payload.enqueuedAt)) { throw 'payload' }
      if ($null -eq $binding) { throw 'state' }
      $project = @($projects | Where-Object { $_.projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase) })
      if ($project.Count -ne 1 -or $project[0].entryThreadId -cne $payload.projectTaskId) { throw 'project' }
      $desired = New-QueuedDispatch $payload ([string]$project[0].codexProjectId)
      if (-not (Test-ClosedObject $desired.taskSpec @('objective','nonGoals','acceptance','authorizedActions','forbiddenActions','baseline','contract','dependencies','authorizationRef','readiness','returnRoute','goalBinding','dispatchIdentity')) -or
          -not (Test-TimeOnOrAfter $payload.enqueuedAt $desired.taskSpec.readiness.checkedAt) -or
          (($payload.accessMode -ceq 'read') -ne ($desired.taskSpec.readiness.operationClass -ceq 'read'))) { throw 'payload' }
      if ($desired.taskSpec.returnRoute.mode -cne 'foreground' -and
          ($desired.taskSpec.returnRoute.controllerThreadId -cne $binding.threadId -or $desired.taskSpec.returnRoute.hostId -cne $binding.hostId)) { throw 'payload' }
      if ($desired.accessMode -ceq 'read' -and @($desired.taskSpec.authorizedActions | Where-Object { $_ -match '(?i)\b(?:edit|write|modify|delete|commit|push|deploy|database-write|config-write|task-create|branch-switch)\b' }).Count -gt 0) { throw 'payload' }
      $existingDispatch = Find-DispatchById $queues ([string]$payload.dispatchId)
      if ($null -ne $existingDispatch) {
        if (-not (Test-DispatchEqual $existingDispatch $desired)) { throw 'state' }
        break
      }
      Assert-GoalReservationBinding $Root ([string]$payload.projectRoot) ([string]$payload.chainId) ([string]$payload.dispatchId) $desired.taskSpec 'initial' 1
      Assert-TaskDependencies $Root $desired.taskSpec.dependencies
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0) {
        $queues += [pscustomobject][ordered]@{ projectRoot=[string]$payload.projectRoot; active=$null; pending=@(); lastTerminal=$null }
        $queueIndex = @($queues).Count - 1
      }
      if (@($queues[$queueIndex].pending).Count -ge 100) { throw 'queue-limit' }
      $queues[$queueIndex].pending = @($queues[$queueIndex].pending) + @($desired)
    }
    'start-next-dispatch' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','startedAt','leaseId')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or -not (Test-UtcIso8601 $payload.startedAt) -or
          ($null -ne $payload.leaseId -and -not (Test-NonEmptyString $payload.leaseId))) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -ne $queues[$queueIndex].active -or @($queues[$queueIndex].pending).Count -eq 0 -or $queues[$queueIndex].pending[0].dispatchId -cne $payload.dispatchId) { throw 'state' }
      $next = $queues[$queueIndex].pending[0]
      Assert-DispatchRuntime $next
      if (($next.accessMode -ceq 'write') -ne ($null -ne $payload.leaseId)) { throw 'payload' }
      if (-not (Test-TimeOnOrAfter $payload.startedAt $next.enqueuedAt)) { throw 'state' }
      $next.startedAt = [string]$payload.startedAt
      $next.phase = 'dispatching'
      if ($next.accessMode -ceq 'write') { $next.writeLease = [pscustomobject][ordered]@{ leaseId=[string]$payload.leaseId; acquiredAt=[string]$payload.startedAt; releasedAt=$null } }
      $queues[$queueIndex].active = $next
      $queues[$queueIndex].pending = @($queues[$queueIndex].pending | Select-Object -Skip 1)
    }
    'advance-dispatch' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','phase')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or $payload.phase -cnotin @('sent','delivery-unknown','running','approval-wait')) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.phase -ceq $payload.phase) { break }
      $allowed = ($active.phase -ceq 'dispatching' -and $payload.phase -ceq 'sent') -or
        ($active.phase -ceq 'sent' -and $payload.phase -in @('delivery-unknown','running')) -or
        ($active.phase -ceq 'delivery-unknown' -and $payload.phase -ceq 'running') -or
        ($active.phase -ceq 'approval-wait' -and $payload.phase -ceq 'running') -or
        ($active.phase -ceq 'running' -and $payload.phase -ceq 'approval-wait')
      if (-not $allowed) { throw 'state' }
      $active.phase = [string]$payload.phase
    }
    'record-dispatch-outcome' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','taskSpecHash','resultState','failureClass','evidenceHash','finishedAt')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or -not (Test-Hash $payload.taskSpecHash) -or
          $payload.resultState -cnotin @('completed','blocked','auth-required','cancelled','convergence-failed') -or -not (Test-Hash $payload.evidenceHash) -or -not (Test-UtcIso8601 $payload.finishedAt)) { throw 'payload' }
      $requiresFailure = $payload.resultState -notin @('completed','cancelled')
      if (($requiresFailure -and ($payload.failureClass -ceq 'N/A' -or -not (Test-ControllerText $payload.failureClass 80))) -or
          (-not $requiresFailure -and $payload.failureClass -cne 'N/A') -or
          ($payload.resultState -ceq 'auth-required' -and $payload.failureClass -cne 'authorization') -or
          ($payload.failureClass -in @('transport','tool-bootstrap','payload-parse') -and $payload.resultState -cne 'blocked')) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.taskSpecHash -cne $payload.taskSpecHash) { throw 'state' }
      if (-not (Test-TimeOnOrAfter $payload.finishedAt $active.startedAt)) { throw 'state' }
      if ($active.phase -ceq 'terminal' -and $active.resultState -ceq $payload.resultState -and $active.evidenceHash -ceq $payload.evidenceHash -and $active.finishedAt -ceq $payload.finishedAt) { break }
      $canCancel = $payload.resultState -ceq 'cancelled' -and $null -ne $active.cancelRequestedAt -and
        ($active.phase -cne 'terminal' -or $active.resultState -in @('blocked','auth-required','convergence-failed'))
      $canConvergeReview = $active.phase -ceq 'terminal' -and $active.resultState -ceq 'completed' -and
        $payload.resultState -ceq 'convergence-failed' -and @($active.attemptFailures).Count -eq 2 -and
        (Test-TimeOnOrAfter $payload.finishedAt $active.finishedAt)
      $canRecord = ($active.phase -ceq 'running' -and $payload.resultState -in @('completed','blocked','auth-required')) -or
        ($active.phase -ceq 'running' -and $payload.resultState -ceq 'convergence-failed' -and @($active.attemptFailures).Count -eq 2) -or
        $canConvergeReview -or $canCancel
      if ($payload.resultState -ceq 'blocked' -and @($active.attemptFailures).Count -eq 2 -and $payload.failureClass -cnotin @('transport','tool-bootstrap','payload-parse')) { $canRecord = $false }
      if ($payload.resultState -ceq 'auth-required' -and $null -ne $active.authorizationResumedAt) { $canRecord = $false }
      if (-not $canRecord) { throw 'state' }
      $active.phase = 'terminal'; $active.resultState = [string]$payload.resultState
      $active.evidenceHash = [string]$payload.evidenceHash; $active.finishedAt = [string]$payload.finishedAt
      if ($null -eq $active.deliveryReconciliation -and $payload.resultState -ceq 'blocked' -and $payload.failureClass -in @('transport','tool-bootstrap','payload-parse')) {
        $active.deliveryReconciliation = [pscustomobject][ordered]@{
          failureClass=[string]$payload.failureClass; evidenceHash=[string]$payload.evidenceHash; confirmedAt=[string]$payload.finishedAt
        }
      }
    }
    'confirm-dispatch-not-delivered' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','evidenceHash','confirmedAt')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or -not (Test-Hash $payload.evidenceHash) -or -not (Test-UtcIso8601 $payload.confirmedAt)) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.phase -cne 'delivery-unknown' -or $null -ne $active.deliveryReconciliation -or -not (Test-TimeOnOrAfter $payload.confirmedAt $active.startedAt)) { throw 'state' }
      $active.deliveryReconciliation = [pscustomobject][ordered]@{ evidenceHash=[string]$payload.evidenceHash; confirmedAt=[string]$payload.confirmedAt }
      $active.phase = 'dispatching'
    }
    'reconcile-preflight-failure' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','failureClass','evidenceHash','confirmedAt','observedBaseline')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or
          $payload.failureClass -cnotin @('transport','tool-bootstrap','payload-parse') -or -not (Test-Hash $payload.evidenceHash) -or
          -not (Test-UtcIso8601 $payload.confirmedAt) -or -not (Test-ClosedObject $payload.observedBaseline @('branch','head','dirtyHash'))) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      $baselineMatches = $payload.observedBaseline.branch -ceq $active.taskSpec.baseline.branch -and
        $payload.observedBaseline.head -ceq $active.taskSpec.baseline.head -and
        $payload.observedBaseline.dirtyHash -ceq $active.taskSpec.baseline.dirtyHash
      $recordedFailure = $active.deliveryReconciliation
      if ($active.phase -cne 'terminal' -or $active.resultState -cne 'blocked' -or $null -eq $recordedFailure -or
          -not (Test-ClosedObject $recordedFailure @('failureClass','evidenceHash','confirmedAt')) -or
          $recordedFailure.failureClass -cne $payload.failureClass -or $recordedFailure.evidenceHash -cne $payload.evidenceHash -or
          $active.evidenceHash -cne $payload.evidenceHash -or $null -ne $active.cancelRequestedAt -or -not $baselineMatches -or
          -not (Test-TimeOnOrAfter $payload.confirmedAt $active.finishedAt)) { throw 'state' }
      # ponytail: the existing two-field reconciliation shape is the durable one-shot marker; without it, identical evidence can reopen forever.
      $active.deliveryReconciliation = [pscustomobject][ordered]@{
        evidenceHash=[string]$payload.evidenceHash; confirmedAt=[string]$payload.confirmedAt
      }
      $active.phase = 'dispatching'; $active.resultState = $null; $active.evidenceHash = $null; $active.finishedAt = $null
    }
    'request-dispatch-cancel' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','requestedAt')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or -not (Test-UtcIso8601 $payload.requestedAt)) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.resultState -in @('completed','cancelled')) { throw 'state' }
      if (-not (Test-TimeOnOrAfter $payload.requestedAt $active.startedAt)) { throw 'state' }
      if ($null -ne $active.cancelRequestedAt -and $active.cancelRequestedAt -cne $payload.requestedAt) { throw 'state' }
      $active.cancelRequestedAt = [string]$payload.requestedAt
    }
    'resume-dispatch-authorization' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','authorizationRef','resumedAt')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or
          -not (Test-ControllerText $payload.authorizationRef 300) -or -not (Test-UtcIso8601 $payload.resumedAt)) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.phase -cne 'terminal' -or $active.resultState -cne 'auth-required' -or $null -ne $active.cancelRequestedAt -or $null -ne $active.authorizationResumedAt -or
          $active.taskSpec.authorizationRef -cne $payload.authorizationRef -or -not (Test-TimeOnOrAfter $payload.resumedAt $active.finishedAt)) { throw 'state' }
      $active.phase = 'running'; $active.resultState = $null; $active.evidenceHash = $null; $active.finishedAt = $null; $active.authorizationResumedAt = [string]$payload.resumedAt
    }
    'retry-dispatch' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','expectedDispatchId','dispatchId','generation','rework','modelClass','failureClass','failureFingerprint','strategy','taskSpec','enqueuedAt')
      foreach ($field in @('expectedDispatchId','dispatchId','failureClass','strategy')) { if (-not (Test-NonEmptyString $payload.$field)) { throw 'payload' } }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or $payload.dispatchId -ceq $payload.expectedDispatchId -or $payload.generation -isnot [int] -or $payload.rework -isnot [int] -or
          $payload.modelClass -cnotin @('economy','balanced','frontier') -or -not (Test-ControllerText $payload.failureClass 80) -or -not (Test-Hash $payload.failureFingerprint) -or
          $payload.strategy -cnotin @('repair','rebaseline') -or -not (Test-UtcIso8601 $payload.enqueuedAt)) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if (@($active.attemptFailures).Count -ge 2) { throw 'convergence-limit' }
      $modelRank = @{ economy=0; balanced=1; frontier=2 }
      $expectedStrategy = if (@($active.attemptFailures).Count -eq 0) { 'repair' } else { 'rebaseline' }
      if ($active.dispatchId -cne $payload.expectedDispatchId -or $active.phase -cne 'terminal' -or $active.resultState -cnotin @('blocked','completed') -or $payload.strategy -cne $expectedStrategy -or
          $payload.generation -ne ($active.generation + 1) -or $payload.rework -ne ($active.rework + 1) -or $payload.generation -gt 3 -or $payload.rework -gt 2 -or
          $modelRank[[string]$payload.modelClass] -lt $modelRank[[string]$active.modelClass] -or -not (Test-TimeOnOrAfter $payload.enqueuedAt $active.finishedAt) -or
          $null -ne (Find-DispatchById $queues ([string]$payload.dispatchId))) { throw 'state' }
      $project = @($projects | Where-Object { $_.projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase) })
      if ($project.Count -ne 1 -or $payload.taskSpec.PSObject.Properties.Name -ccontains 'dispatchIdentity') { throw 'state' }
      $refreshedTaskSpec = Convert-TaskSpec $payload.taskSpec ([string]$project[0].codexProjectId)
      if (-not (Test-RetryTaskSpecScope $active.taskSpec $refreshedTaskSpec.Value) -or
          -not (Test-TimeOnOrAfter $payload.enqueuedAt $refreshedTaskSpec.Value.readiness.checkedAt)) { throw 'state' }
      Assert-GoalReservationBinding $Root ([string]$payload.projectRoot) ([string]$active.chainId) ([string]$payload.dispatchId) $refreshedTaskSpec.Value ([string]$payload.strategy) ([int]$payload.generation)
      Assert-GoalRetryEvidence $Root ([string]$payload.projectRoot) $active.taskSpec $refreshedTaskSpec.Value ([string]$payload.failureFingerprint)
      Assert-TaskDependencies $Root $refreshedTaskSpec.Value.dependencies
      $active.attemptFailures = @($active.attemptFailures) + @([pscustomobject][ordered]@{
        dispatchId=[string]$active.dispatchId; failureClass=[string]$payload.failureClass; failureFingerprint=[string]$payload.failureFingerprint
        strategy=[string]$payload.strategy; finishedAt=[string]$active.finishedAt
      })
      Add-Member -InputObject $refreshedTaskSpec.Value -NotePropertyName dispatchIdentity -NotePropertyValue ([pscustomobject][ordered]@{
        chainId=[string]$active.chainId; projectTaskId=[string]$active.projectTaskId; dispatchId=[string]$payload.dispatchId
        generation=[int]$payload.generation; rework=[int]$payload.rework
      })
      $resealedTaskSpec = Convert-TaskSpec $refreshedTaskSpec.Value ([string]$project[0].codexProjectId)
      $active.taskSpec = $resealedTaskSpec.Value; $active.taskSpecHash = [string]$resealedTaskSpec.Hash
      $active.dispatchId = [string]$payload.dispatchId; $active.generation = [int]$payload.generation; $active.rework = [int]$payload.rework
      $active.modelClass = [string]$payload.modelClass
      $active.enqueuedAt = [string]$payload.enqueuedAt; $active.startedAt = [string]$payload.enqueuedAt; $active.phase = 'dispatching'
      $active.resultState = $null; $active.evidenceHash = $null; $active.finishedAt = $null; $active.cancelRequestedAt = $null; $active.deliveryReconciliation = $null
    }
    'close-dispatch' {
      if ($version -ne 2) { throw 'migration' }
      $payload = Convert-Payload $Json @('projectRoot','dispatchId','closedAt')
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId) -or -not (Test-UtcIso8601 $payload.closedAt)) { throw 'payload' }
      $queueIndex = Get-QueueIndex $queues ([string]$payload.projectRoot)
      if ($queueIndex -lt 0 -or $null -eq $queues[$queueIndex].active -or $queues[$queueIndex].active.dispatchId -cne $payload.dispatchId) { throw 'state' }
      $active = $queues[$queueIndex].active
      Assert-DispatchRuntime $active
      if ($active.phase -cne 'terminal' -or $active.resultState -cnotin @('completed','cancelled')) { throw 'state' }
      if (-not (Test-TimeOnOrAfter $payload.closedAt $active.finishedAt)) { throw 'state' }
      Assert-GoalCloseEvidence $Root ([string]$payload.projectRoot) $active
      if ($null -ne $active.writeLease) { $active.writeLease.releasedAt = [string]$payload.closedAt }
      $queues[$queueIndex].lastTerminal = $active; $queues[$queueIndex].active = $null
    }
    'replace-project-binding' {
      $payload = Convert-Payload $Json @(
        'confirmReconciliation','projectRoot',
        'expectedEntryThreadId','expectedCodexProjectId','expectedHostId',
        'replacementEntryThreadId','replacementCodexProjectId','replacementHostId'
      )
      if ($payload.confirmReconciliation -isnot [bool] -or -not $payload.confirmReconciliation) { throw 'payload' }
      foreach ($field in @('expectedEntryThreadId','expectedCodexProjectId','expectedHostId','replacementEntryThreadId','replacementCodexProjectId','replacementHostId')) {
        if (-not (Test-NonEmptyString $payload.$field)) { throw 'payload' }
      }
      if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or (Test-PathsOverlap $Root ([string]$payload.projectRoot))) { throw 'payload' }
      if ($null -eq $binding) { throw 'state' }
      $projectIndex = -1
      for ($index = 0; $index -lt $projects.Count; $index++) {
        if ($projects[$index].projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase)) { $projectIndex = $index; break }
      }
      if ($projectIndex -lt 0) { throw 'project' }
      $current = $projects[$projectIndex]
      $matchesExpected = $current.entryThreadId -ceq $payload.expectedEntryThreadId -and $current.codexProjectId -ceq $payload.expectedCodexProjectId -and $current.hostId -ceq $payload.expectedHostId
      $matchesReplacement = $current.entryThreadId -ceq $payload.replacementEntryThreadId -and $current.codexProjectId -ceq $payload.replacementCodexProjectId -and $current.hostId -ceq $payload.replacementHostId
      if (-not $matchesExpected -and -not $matchesReplacement) { throw 'project' }
      if ($matchesExpected) {
        $projects[$projectIndex] = [pscustomobject][ordered]@{
          entryThreadId=[string]$payload.replacementEntryThreadId; codexProjectId=[string]$payload.replacementCodexProjectId
          hostId=[string]$payload.replacementHostId; projectRoot=[string]$payload.projectRoot
        }
      }
    }
    'clear-controller-task-state' {
      try { $payload = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw 'payload' }
      if ($null -eq $payload -or $payload -is [Array] -or $payload.confirmReconciliation -isnot [bool] -or -not $payload.confirmReconciliation) { throw 'payload' }
      $names = @($payload.PSObject.Properties.Name)
      $hasOperation = $names -ccontains 'operationId'
      $hasThread = $names -ccontains 'threadId'
      $expectedFields = if ($hasOperation -and -not $hasThread) { @('confirmReconciliation','operationId') } elseif ($hasThread -and -not $hasOperation) { @('confirmReconciliation','threadId') } else { @() }
      if ($expectedFields.Count -eq 0 -or -not (Test-ClosedObject $payload $expectedFields)) { throw 'payload' }
      if ($hasOperation) {
        if (-not (Test-NonEmptyString $payload.operationId)) { throw 'payload' }
        if ($null -eq $intent -or $intent.operationId -cne $payload.operationId) { throw 'state' }
        $intent = $null
      }
      else {
        if (-not (Test-NonEmptyString $payload.threadId)) { throw 'payload' }
        if ($null -eq $binding -or $binding.threadId -cne $payload.threadId -or @($queues | Where-Object { $null -ne $_.active -or @($_.pending).Count -gt 0 }).Count -gt 0) { throw 'state' }
        $binding = $null
      }
    }
    default { throw 'operation' }
  }
  $result = [ordered]@{
    schemaVersion=$version; generator='onboard-code-projects'; templateVersion=$version; controllerName=$Manifest.controllerName
    controllerBinding=$binding; controllerTaskIntent=$intent; projectBindings=@($projects)
  }
  if ($version -eq 2) { $result.dispatchQueues = @($queues) }
  return [pscustomobject]$result
}

$normalizedRoot = $null
try {
  try { $normalizedRoot = Resolve-ControllerRoot $ControllerRoot }
  catch {
    if ($_.Exception.Message -ceq 'controller-filesystem-conflict') { Finish-Conflict 'controller-filesystem-conflict' $ControllerRoot }
    Finish-Blocked 'controller-io-failure' $ControllerRoot
  }
  if ($null -eq $normalizedRoot) { Finish-Invalid 'controller-root-unsupported' $null }
  if ($Action -cnotin @('Read','RuntimeInfo','ExportDispatch','PrepareCandidate','ApplyCandidate','RemoveCandidate')) { Finish-Invalid }

  if ($Action -ceq 'RuntimeInfo') {
    try { $runtimeHash = Get-ControllerRuntimeHash }
    catch { Finish-Blocked 'controller-runtime-unavailable' $normalizedRoot }
    $data = [pscustomobject][ordered]@{ controllerRuntimeHash=$runtimeHash; algorithm='sha256-canonical-file-set-v1'; files=@('control-state.ps1','chain-store.ps1') }
    Write-StateResult verified 'controller-runtime-verified' $normalizedRoot $null $null $null $runtimeHash $data 'Bind this exact hash into the goal reservation; do not change either runtime file until all queues and leases are empty.' @() 0
  }

  if ($Action -ceq 'Read') {
    try { $current = Read-Manifest $normalizedRoot }
    catch {
      if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot }
      Finish-Blocked 'controller-io-failure' $normalizedRoot
    }
    Write-StateResult verified 'controller-state-verified' $normalizedRoot $current.Hash $null $null $current.Hash $current.Data 'Use the verified hash as ExpectedHash for a prepared mutation.' @() 0
  }

  if ($Action -ceq 'ExportDispatch') {
    if (-not (Test-Hash $ExpectedHash)) { Finish-Invalid }
    try { $current = Read-Manifest $normalizedRoot }
    catch {
      if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot }
      Finish-Blocked 'controller-io-failure' $normalizedRoot
    }
    if ($current.Hash -cne $ExpectedHash) { Finish-Conflict 'controller-hash-conflict' $normalizedRoot $current.Hash }
    try { $payload = Convert-Payload $PayloadJson @('projectRoot','dispatchId') }
    catch { Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash }
    if (-not (Test-NormalizedWindowsRoot $payload.projectRoot) -or -not (Test-NonEmptyString $payload.dispatchId)) {
      Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash
    }
    $queue = @($current.Data.dispatchQueues | Where-Object { $_.projectRoot.Equals([string]$payload.projectRoot, [StringComparison]::OrdinalIgnoreCase) })
    if ($queue.Count -ne 1 -or $null -eq $queue[0].active -or $queue[0].active.dispatchId -cne $payload.dispatchId -or $queue[0].active.phase -cne 'dispatching') {
      Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash
    }
    $active = $queue[0].active
    try { Assert-DispatchRuntime $active } catch { Finish-Conflict 'controller-runtime-drift' $normalizedRoot $current.Hash }
    $core = [ordered]@{
      schemaVersion=1; kind='onboard-code-projects.dispatch'; chainId=[string]$active.chainId
      projectTaskId=[string]$active.projectTaskId; dispatchId=[string]$active.dispatchId
      generation=[int]$active.generation; rework=[int]$active.rework; taskSpecHash=[string]$active.taskSpecHash
      taskSpec=$active.taskSpec
    }
    $dispatchHash = Get-Hash ($utf8.GetBytes(($core | ConvertTo-Json -Depth 12 -Compress)))
    $envelope = [ordered]@{}
    foreach ($key in $core.Keys) { $envelope[$key] = $core[$key] }
    $envelope.dispatchHash = $dispatchHash
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 12 -Compress))
    exit 0
  }

  if ($Action -ceq 'PrepareCandidate') {
    if (-not (Test-Hash $ExpectedHash) -or [string]::IsNullOrWhiteSpace($Operation)) { Finish-Invalid }
    try { $current = Read-Manifest $normalizedRoot }
    catch {
      if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot }
      Finish-Blocked 'controller-io-failure' $normalizedRoot
    }
    if ($current.Hash -cne $ExpectedHash) { Finish-Conflict 'controller-hash-conflict' $normalizedRoot $current.Hash }
    try { $orphans = @(Get-CandidateItems $normalizedRoot) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $current.Hash }
    if ($orphans.Count -gt 0) {
      $orphan = $orphans[0]
      if ($orphan.PSIsContainer -or ($orphan.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-Path -LiteralPath $orphan.FullName -PathType Leaf) -or -not (Test-ReparseComponents $orphan.FullName)) {
        Finish-Conflict 'controller-filesystem-conflict' $normalizedRoot $current.Hash $orphan.FullName $null 'Replace the unsafe orphan candidate only after manual inspection; it was not read.'
      }
      try { $orphanHash = Get-Hash ([IO.File]::ReadAllBytes($orphan.FullName)) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $current.Hash $orphan.FullName }
      Finish-Conflict 'controller-candidate-orphaned' $normalizedRoot $current.Hash $orphan.FullName $orphanHash "Run RemoveCandidate for the exact file $($orphan.Name) with SHA-256 $orphanHash, then retry."
    }
    try { $mutated = New-MutatedManifest $current.Data $Operation $PayloadJson $normalizedRoot }
    catch {
      $mutationFailure = $_.Exception.Message
      switch -CaseSensitive ($mutationFailure) {
        'payload' { Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash }
        'operation' { Finish-Invalid 'controller-operation-invalid' $normalizedRoot $current.Hash }
        'project' { Finish-Conflict 'project-binding-conflict' $normalizedRoot $current.Hash }
        'project-limit' { Finish-Conflict 'project-binding-limit' $normalizedRoot $current.Hash }
        'queue-limit' { Finish-Conflict 'dispatch-queue-limit' $normalizedRoot $current.Hash }
        'convergence-limit' { Finish-Conflict 'dispatch-convergence-limit' $normalizedRoot $current.Hash }
        'dependency-wait' { Finish-Conflict 'dispatch-dependency-pending' $normalizedRoot $current.Hash }
        'dependency-unsatisfied' { Finish-Conflict 'dispatch-dependency-unsatisfied' $normalizedRoot $current.Hash }
        'dependency-state' { Finish-Conflict 'dispatch-dependency-state-invalid' $normalizedRoot $current.Hash }
        'runtime' { Finish-Conflict 'controller-runtime-drift' $normalizedRoot $current.Hash }
        'goal-close-lane' { Finish-Conflict 'dispatch-goal-lane-mismatch' $normalizedRoot $current.Hash }
        'goal-close-reservation' { Finish-Conflict 'dispatch-goal-reservation-mismatch' $normalizedRoot $current.Hash }
        'goal-close-result' { Finish-Conflict 'dispatch-goal-result-mismatch' $normalizedRoot $current.Hash }
        'goal-close-evidence' { Finish-Conflict 'dispatch-goal-evidence-mismatch' $normalizedRoot $current.Hash }
        'goal-close-active' { Finish-Conflict 'dispatch-goal-still-active' $normalizedRoot $current.Hash }
        'goal-store-experience-index-stale' { Finish-Conflict 'controller-experience-index-stale' $normalizedRoot $current.Hash }
        'goal-store-goal-not-found' { Finish-Conflict 'dispatch-goal-not-found' $normalizedRoot $current.Hash }
        'migration' { Finish-Conflict 'controller-upgrade-required' $normalizedRoot $current.Hash }
        default { Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash }
      }
    }
    $candidateBytes = $utf8.GetBytes(($mutated | ConvertTo-Json -Depth 12 -Compress) + "`n")
    try { $validated = Convert-ManifestBytes $candidateBytes $normalizedRoot } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $current.Hash }
    $candidate = Join-Path $normalizedRoot ('.codex-controller.' + [guid]::NewGuid().ToString('N').ToLowerInvariant() + '.tmp')
    try {
      if (-not (Test-ReparseComponents $candidate)) { throw 'candidate-path' }
      $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $stream.Write($candidateBytes, 0, $candidateBytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    }
    catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $current.Hash $candidate $validated.Hash }
    Write-StateResult prepared 'controller-candidate-prepared' $normalizedRoot $current.Hash $candidate $validated.Hash $validated.Hash $validated.Data 'Apply this exact candidate with the same ExpectedHash, candidate path, and candidate hash.' @() 0
  }

  if ($Action -ceq 'ApplyCandidate') {
    if (-not (Test-Hash $ExpectedHash) -or -not (Test-Hash $CandidateHash) -or -not (Test-CandidateArgument $normalizedRoot $CandidatePath)) { Finish-Invalid 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
    try { $candidate = Resolve-Candidate $normalizedRoot $CandidatePath } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
    if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
    try { $candidateBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if ((Get-Hash $candidateBytes) -cne $CandidateHash) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
    try { $null = Convert-ManifestBytes $candidateBytes $normalizedRoot } catch { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $candidate $CandidateHash }
    try { $gate = Enter-ControllerMutex $normalizedRoot } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if (-not $gate.Acquired) { $gate.Mutex.Dispose(); Finish-Conflict 'controller-mutex-timeout' $normalizedRoot $null $candidate $CandidateHash 'Wait for the current controller writer to finish, then retry.' }
    try {
      try { $candidate = Resolve-Candidate $normalizedRoot $candidate } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
      if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-changed' $normalizedRoot $null $CandidatePath $CandidateHash }
      try { $lockedCandidateBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
      if ((Get-Hash $lockedCandidateBytes) -cne $CandidateHash -or -not (Test-BytesEqual $candidateBytes $lockedCandidateBytes)) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
      try { $null = Convert-ManifestBytes $lockedCandidateBytes $normalizedRoot } catch { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $candidate $CandidateHash }
      try { $current = Read-Manifest $normalizedRoot }
      catch {
        if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot $null $candidate $CandidateHash }
        Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash
      }
      if ($current.Hash -cne $ExpectedHash) { Finish-Conflict 'controller-hash-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash }
      $manifestPath = Join-Path $normalizedRoot '.codex-controller.json'
      try { [IO.File]::Replace($candidate, $manifestPath, [System.Management.Automation.Language.NullString]::Value) }
      catch { Finish-Blocked 'controller-atomic-replace-failed' $normalizedRoot $current.Hash $candidate $CandidateHash 'Preserve both files, resolve the filesystem conflict, then retry.' }
      try { $readback = Read-Manifest $normalizedRoot } catch { Finish-Blocked 'controller-readback-failed' $normalizedRoot $current.Hash $candidate $CandidateHash }
      if ($readback.Hash -cne $CandidateHash -or -not (Test-BytesEqual $readback.Bytes $lockedCandidateBytes)) { Finish-Blocked 'controller-readback-failed' $normalizedRoot $current.Hash $candidate $CandidateHash }
      Write-StateResult applied 'controller-state-applied' $normalizedRoot $current.Hash $candidate $CandidateHash $readback.Hash $readback.Data 'Continue using the applied manifest hash as the next ExpectedHash.' @() 0
    }
    finally {
      try { $gate.Mutex.ReleaseMutex() } catch {}
      $gate.Mutex.Dispose()
    }
  }

  if (-not $ConfirmCleanup) { Finish-Invalid 'controller-cleanup-confirmation-required' $normalizedRoot $null $CandidatePath $CandidateHash }
  if (-not (Test-Hash $CandidateHash) -or -not (Test-CandidateArgument $normalizedRoot $CandidatePath)) { Finish-Invalid 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
  try { $candidate = Resolve-Candidate $normalizedRoot $CandidatePath } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
  if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
  try { $removeBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
  if ((Get-Hash $removeBytes) -cne $CandidateHash) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
  try { $gate = Enter-ControllerMutex $normalizedRoot } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
  if (-not $gate.Acquired) { $gate.Mutex.Dispose(); Finish-Conflict 'controller-mutex-timeout' $normalizedRoot $null $candidate $CandidateHash 'Wait for the current controller writer to finish, then retry.' }
  try {
    try { $candidate = Resolve-Candidate $normalizedRoot $candidate } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
    if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-changed' $normalizedRoot $null $CandidatePath $CandidateHash }
    try { $lockedRemoveBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if ((Get-Hash $lockedRemoveBytes) -cne $CandidateHash) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
    try { [IO.File]::Delete($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    try { $stillExists = Test-Path -LiteralPath $candidate } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if ($stillExists) { Finish-Blocked 'controller-candidate-remove-unverified' $normalizedRoot $null $candidate $CandidateHash }
    Write-StateResult removed 'controller-candidate-removed' $normalizedRoot $null $candidate $CandidateHash $null $null 'Rerun PrepareCandidate from the current manifest hash when ready.' @() 0
  }
  finally {
    try { $gate.Mutex.ReleaseMutex() } catch {}
    $gate.Mutex.Dispose()
  }
}
catch {
  Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash
}
