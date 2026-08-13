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
  $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
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

function Convert-TaskSetHandoff {
  param([AllowNull()][object]$Value, [string]$Failure = 'manifest')
  if ($null -eq $Value) { return $null }
  try {
    if (-not (Test-ClosedObject $Value @('summary','summaryHash','oldestTurnId','newestTurnId','turnCount','historyDigest','eofComplete','observedAt')) -or
        -not (Test-ControllerText $Value.summary 6000) -or (Test-CredentialLocator $Value.summary) -or
        -not (Test-Hash $Value.summaryHash) -or $Value.summaryHash -cne (Get-Hash $utf8.GetBytes([string]$Value.summary)) -or
        -not (Test-ControllerText $Value.oldestTurnId 200) -or -not (Test-ControllerText $Value.newestTurnId 200) -or
        $Value.turnCount -isnot [int] -or $Value.turnCount -lt 1 -or -not (Test-Hash $Value.historyDigest) -or
        $Value.eofComplete -isnot [bool] -or -not $Value.eofComplete -or -not (Test-UtcIso8601 $Value.observedAt)) { throw 'invalid' }
    return [pscustomobject][ordered]@{
      summary=[string]$Value.summary; summaryHash=[string]$Value.summaryHash
      oldestTurnId=[string]$Value.oldestTurnId; newestTurnId=[string]$Value.newestTurnId
      turnCount=[int]$Value.turnCount; historyDigest=[string]$Value.historyDigest; eofComplete=$true; observedAt=[string]$Value.observedAt
    }
  }
  catch { throw $Failure }
}

function Convert-TaskSetCoordinator {
  param([object]$Value, [string]$Failure = 'manifest')
  try {
    if (-not (Test-ClosedObject $Value @('threadId','hostId')) -or -not (Test-ControllerText $Value.threadId 200) -or -not (Test-ControllerText $Value.hostId 200)) { throw 'invalid' }
    return [pscustomobject][ordered]@{ threadId=[string]$Value.threadId; hostId=[string]$Value.hostId }
  } catch { throw $Failure }
}

function Convert-ExternalQuiescence {
  param([object]$Value,[string]$Root,[string]$Failure = 'manifest')
  try {
    $fields=@('runtimeDispatches','unackedReceipts','claims','goalReservations','approvals','activeScopedTasks','automationIntents','writers','candidates','heartbeatPaused','runtimeReadback','runtimeReadbackHash','observedAt','proofHash')
    if (-not (Test-ClosedObject $Value $fields) -or -not (Test-UtcIso8601 $Value.observedAt) -or -not (Test-Hash $Value.proofHash) -or
        $Value.heartbeatPaused -isnot [bool] -or -not $Value.heartbeatPaused) { throw 'invalid' }
    foreach($field in @('runtimeDispatches','unackedReceipts','claims','goalReservations','approvals','activeScopedTasks','automationIntents','writers','candidates')) {
      if($Value.$field -isnot [int] -or $Value.$field -ne 0){ throw 'busy' }
    }
    $runtimeReadback=Convert-RuntimeReadback $Value.runtimeReadback $Root $Failure
    if(-not(Test-Hash $Value.runtimeReadbackHash)-or(Get-Hash $utf8.GetBytes(($runtimeReadback|ConvertTo-Json -Depth 20 -Compress)))-cne$Value.runtimeReadbackHash-or
       $runtimeReadback.activeDispatchCount-ne0-or$runtimeReadback.unacknowledgedReceiptCount-ne0-or
       $runtimeReadback.wakeWorkerState-ceq'pending'-or$runtimeReadback.wakeAutomationState-ceq'pending'){throw 'busy'}
    $proof=[pscustomobject][ordered]@{
      runtimeDispatches=[int]$Value.runtimeDispatches; unackedReceipts=[int]$Value.unackedReceipts; claims=[int]$Value.claims
      goalReservations=[int]$Value.goalReservations; approvals=[int]$Value.approvals; activeScopedTasks=[int]$Value.activeScopedTasks
      automationIntents=[int]$Value.automationIntents; writers=[int]$Value.writers; candidates=[int]$Value.candidates
      heartbeatPaused=$true;runtimeReadback=$runtimeReadback;runtimeReadbackHash=[string]$Value.runtimeReadbackHash;observedAt=[string]$Value.observedAt
    }
    if((Get-Hash $utf8.GetBytes(($proof|ConvertTo-Json -Depth 5 -Compress))) -cne $Value.proofHash){ throw 'invalid' }
    return [pscustomobject][ordered]@{
      runtimeDispatches=$proof.runtimeDispatches; unackedReceipts=$proof.unackedReceipts; claims=$proof.claims
      goalReservations=$proof.goalReservations; approvals=$proof.approvals; activeScopedTasks=$proof.activeScopedTasks
      automationIntents=$proof.automationIntents; writers=$proof.writers; candidates=$proof.candidates
      heartbeatPaused=$true;runtimeReadback=$runtimeReadback;runtimeReadbackHash=[string]$Value.runtimeReadbackHash;observedAt=$proof.observedAt;proofHash=[string]$Value.proofHash
    }
  } catch { if($_.Exception.Message -ceq 'busy'){throw 'state'}; throw $Failure }
}

function Get-TaskSetPlanHash {
  param([string]$OperationId,[string]$FromTaskSetId,[string]$ToTaskSetId,$Coordinator,$ExpectedController,[object[]]$ExpectedProjects,[object[]]$Targets)
  $planTargets=@($Targets|ForEach-Object{[pscustomobject][ordered]@{
    kind=[string]$_.kind;projectRoot=[string]$_.projectRoot;creationOperationId=[string]$_.creationOperationId
    expectedCodexProjectId=[string]$_.expectedCodexProjectId;expectedHostId=[string]$_.expectedHostId
  }})
  $plan=[pscustomobject][ordered]@{
    operationId=$OperationId;fromTaskSetId=$FromTaskSetId;toTaskSetId=$ToTaskSetId;coordinator=$Coordinator
    expectedController=$ExpectedController;expectedProjectBindings=@($ExpectedProjects);targets=@($planTargets)
  }
  return Get-Hash $utf8.GetBytes(($plan|ConvertTo-Json -Depth 20 -Compress))
}

function Get-TaskSetEvidenceHash {
  param([object[]]$Targets,[string]$HandoffProperty,[object[]]$ActiveChains,$ExternalQuiescence,[object[]]$Archives)
  $rows=@($Targets|ForEach-Object{[pscustomobject][ordered]@{kind=[string]$_.kind;projectRoot=[string]$_.projectRoot;handoff=$_.$HandoffProperty}})
  $evidence=[pscustomobject][ordered]@{targets=@($rows);activeChains=@($ActiveChains);externalQuiescence=$ExternalQuiescence;archives=@($Archives)}
  return Get-Hash $utf8.GetBytes(($evidence|ConvertTo-Json -Depth 20 -Compress))
}

function Get-NextTaskSetId {
  param([string]$Root,[string]$FromTaskSetId,[string]$OperationId)
  $identity=@('task-set-reset-v1',(Resolve-PhysicalWindowsPath $Root).ToLowerInvariant(),$FromTaskSetId,$OperationId)
  return 'task-set-' + (Get-Hash $utf8.GetBytes(($identity|ConvertTo-Json -Compress)))
}

function Get-InitialTaskSetId {
  param([string]$Root)
  return 'task-set-' + (Get-Hash $utf8.GetBytes((Resolve-PhysicalWindowsPath $Root).ToLowerInvariant()))
}

function Convert-StandbyProof {
  param([AllowNull()][object]$Value,[string]$Failure='manifest')
  if($null-eq$Value){return $null}
  try{
    $fields=@('threadId','codexProjectId','hostId','projectRoot','state','summaryHash','historyDigest','newestTurnId','acknowledgedTurnId','observedAt','snapshotHash')
    if(-not(Test-ClosedObject $Value $fields)-or-not(Test-ControllerText $Value.threadId 200)-or-not(Test-ControllerText $Value.codexProjectId 200)-or
       -not(Test-ControllerText $Value.hostId 200)-or-not(Test-NormalizedWindowsRoot $Value.projectRoot)-or$Value.state-cne'standby'-or
       -not(Test-Hash $Value.summaryHash)-or-not(Test-Hash $Value.historyDigest)-or-not(Test-ControllerText $Value.newestTurnId 200)-or
       $Value.acknowledgedTurnId-cne$Value.newestTurnId-or-not(Test-UtcIso8601 $Value.observedAt)-or-not(Test-Hash $Value.snapshotHash)){throw 'invalid'}
    $snapshot=[pscustomobject][ordered]@{
      threadId=[string]$Value.threadId;codexProjectId=[string]$Value.codexProjectId;hostId=[string]$Value.hostId;projectRoot=[string]$Value.projectRoot
      state='standby';summaryHash=[string]$Value.summaryHash;historyDigest=[string]$Value.historyDigest;newestTurnId=[string]$Value.newestTurnId
      acknowledgedTurnId=[string]$Value.acknowledgedTurnId;observedAt=[string]$Value.observedAt
    }
    if((Get-Hash $utf8.GetBytes(($snapshot|ConvertTo-Json -Depth 10 -Compress)))-cne$Value.snapshotHash){throw 'invalid'}
    return [pscustomobject][ordered]@{
      threadId=$snapshot.threadId;codexProjectId=$snapshot.codexProjectId;hostId=$snapshot.hostId;projectRoot=$snapshot.projectRoot;state='standby'
      summaryHash=$snapshot.summaryHash;historyDigest=$snapshot.historyDigest;newestTurnId=$snapshot.newestTurnId
      acknowledgedTurnId=$snapshot.acknowledgedTurnId;observedAt=$snapshot.observedAt;snapshotHash=[string]$Value.snapshotHash
    }
  }catch{throw $Failure}
}

function Convert-BootstrapProof {
  param([AllowNull()][object]$Value,[string]$Failure='manifest')
  if($null-eq$Value){return $null}
  try{
    $fields=@('threadId','codexProjectId','hostId','projectRoot','creationOperationId','state','observedAt','snapshotHash')
    if(-not(Test-ClosedObject $Value $fields)-or-not(Test-ControllerText $Value.threadId 200)-or-not(Test-ControllerText $Value.codexProjectId 200)-or
       -not(Test-ControllerText $Value.hostId 200)-or-not(Test-NormalizedWindowsRoot $Value.projectRoot)-or-not(Test-ControllerText $Value.creationOperationId 200)-or
       $Value.state-cne'standby'-or-not(Test-UtcIso8601 $Value.observedAt)-or-not(Test-Hash $Value.snapshotHash)){throw 'invalid'}
    $snapshot=[pscustomobject][ordered]@{
      threadId=[string]$Value.threadId;codexProjectId=[string]$Value.codexProjectId;hostId=[string]$Value.hostId;projectRoot=[string]$Value.projectRoot
      creationOperationId=[string]$Value.creationOperationId;state='standby';observedAt=[string]$Value.observedAt
    }
    if((Get-Hash $utf8.GetBytes(($snapshot|ConvertTo-Json -Depth 8 -Compress)))-cne$Value.snapshotHash){throw 'invalid'}
    $snapshot|Add-Member -NotePropertyName snapshotHash -NotePropertyValue ([string]$Value.snapshotHash)
    return $snapshot
  }catch{throw $Failure}
}

function Convert-RuntimeReadback {
  param([object]$Value,[string]$Root,[string]$Failure='manifest')
  try{
    $fields=@(
      'state','controllerRoot','controllerThreadId','hostId','replacementState','operationId','replacementSetHash','oldControllerThreadId','oldHostId','newControllerThreadId','newHostId',
      'manifestPreparedHash','prepareToken','manifestSwitchedHash','preparedAt','committedAt','activeDispatchCount','unacknowledgedReceiptCount',
      'fenceState','fenceOperationId','fencePlanHash','fenceManifestExpectedHash','fencePreparedAt','fenceCompletedManifestHash','fenceCompletedAt',
      'wakeWorkerState','wakeWorkerOperationId','wakeWorkerThreadId','wakeWorkerClientThreadId','wakeAutomationState','wakeAutomationOperationId','wakeAutomationId'
    )
    if(-not(Test-ClosedObject $Value $fields)-or$Value.state-cne'controller-replacement-read'-or-not$Root.Equals([string]$Value.controllerRoot,[StringComparison]::OrdinalIgnoreCase)-or
       $Value.replacementState-cnotin@('none','legacy','prepared','committed')-or-not(Test-ControllerText $Value.controllerThreadId 200)-or-not(Test-ControllerText $Value.hostId 200)-or
       $Value.activeDispatchCount-isnot[int]-or$Value.activeDispatchCount-lt0-or$Value.unacknowledgedReceiptCount-isnot[int]-or$Value.unacknowledgedReceiptCount-lt0){throw 'invalid'}
    if($Value.replacementState-ceq'none'){
      foreach($field in @('operationId','replacementSetHash','oldControllerThreadId','oldHostId','newControllerThreadId','newHostId','manifestPreparedHash','prepareToken','manifestSwitchedHash','preparedAt','committedAt')){if($null-ne$Value.$field){throw 'invalid'}}
    }elseif($Value.replacementState-ceq'legacy'){
      foreach($field in @('operationId','oldControllerThreadId','oldHostId','newControllerThreadId','newHostId')){if(-not(Test-ControllerText $Value.$field 200)){throw 'invalid'}}
      if($Value.controllerThreadId-cne$Value.newControllerThreadId-or$Value.hostId-cne$Value.newHostId-or-not(Test-UtcIso8601 $Value.committedAt)){throw 'invalid'}
      foreach($field in @('replacementSetHash','manifestPreparedHash','prepareToken','manifestSwitchedHash','preparedAt')){if($null-ne$Value.$field){throw 'invalid'}}
    }else{
      foreach($field in @('operationId','oldControllerThreadId','oldHostId','newControllerThreadId','newHostId')){if(-not(Test-ControllerText $Value.$field 200)){throw 'invalid'}}
      if(-not(Test-Hash $Value.replacementSetHash)-or-not(Test-Hash $Value.manifestPreparedHash)-or-not(Test-Hash $Value.prepareToken)-or-not(Test-UtcIso8601 $Value.preparedAt)){throw 'invalid'}
    }
    if($Value.replacementState-ceq'prepared'){
      if($Value.controllerThreadId-cne$Value.oldControllerThreadId-or$Value.hostId-cne$Value.oldHostId-or$null-ne$Value.manifestSwitchedHash-or$null-ne$Value.committedAt){throw 'invalid'}
    }elseif($Value.replacementState-ceq'committed'){
      if($Value.controllerThreadId-cne$Value.newControllerThreadId-or$Value.hostId-cne$Value.newHostId-or-not(Test-Hash $Value.manifestSwitchedHash)-or
         -not(Test-UtcIso8601 $Value.committedAt)-or-not(Test-TimeOnOrAfter $Value.committedAt $Value.preparedAt)){throw 'invalid'}
    }
    if($Value.fenceState-cnotin@('none','prepared','completed')){throw 'invalid'}
    if($Value.fenceState-ceq'none'){
      foreach($field in @('fenceOperationId','fencePlanHash','fenceManifestExpectedHash','fencePreparedAt','fenceCompletedManifestHash','fenceCompletedAt')){if($null-ne$Value.$field){throw 'invalid'}}
    }else{
      if(-not(Test-ControllerText $Value.fenceOperationId 200)-or-not(Test-Hash $Value.fencePlanHash)-or-not(Test-Hash $Value.fenceManifestExpectedHash)-or-not(Test-UtcIso8601 $Value.fencePreparedAt)){throw 'invalid'}
      if($Value.fenceState-ceq'prepared' -and ($null-ne$Value.fenceCompletedManifestHash-or$null-ne$Value.fenceCompletedAt)){throw 'invalid'}
      if($Value.fenceState-ceq'completed' -and (-not(Test-Hash $Value.fenceCompletedManifestHash)-or-not(Test-UtcIso8601 $Value.fenceCompletedAt)-or-not(Test-TimeOnOrAfter $Value.fenceCompletedAt $Value.fencePreparedAt))){throw 'invalid'}
    }
    if($Value.wakeWorkerState-cnotin@('none','pending','bound')-or$Value.wakeAutomationState-cnotin@('none','pending','bound')){throw 'invalid'}
    if($Value.wakeWorkerState-ceq'none'){
      foreach($field in @('wakeWorkerOperationId','wakeWorkerThreadId','wakeWorkerClientThreadId')){if($null-ne$Value.$field){throw 'invalid'}}
    }else{
      if(-not(Test-ControllerText $Value.wakeWorkerOperationId 200)){throw 'invalid'}
      if($Value.wakeWorkerState-ceq'bound' -and (-not(Test-ControllerText $Value.wakeWorkerThreadId 200)-or-not(Test-ControllerText $Value.wakeWorkerClientThreadId 200))){throw 'invalid'}
      if($Value.wakeWorkerState-ceq'pending' -and $null-ne$Value.wakeWorkerThreadId -and $null-ne$Value.wakeWorkerClientThreadId){throw 'invalid'}
    }
    if($Value.wakeAutomationState-ceq'none'){
      if($null-ne$Value.wakeAutomationOperationId-or$null-ne$Value.wakeAutomationId){throw 'invalid'}
    }else{
      if($Value.wakeWorkerState-cne'bound'-or-not(Test-ControllerText $Value.wakeAutomationOperationId 200)){throw 'invalid'}
      if($Value.wakeAutomationState-ceq'bound' -and -not(Test-ControllerText $Value.wakeAutomationId 200)){throw 'invalid'}
      if($Value.wakeAutomationState-ceq'pending' -and $null-ne$Value.wakeAutomationId){throw 'invalid'}
    }
    return [pscustomobject][ordered]@{
      state='controller-replacement-read';controllerRoot=[string]$Value.controllerRoot;controllerThreadId=[string]$Value.controllerThreadId;hostId=[string]$Value.hostId
      replacementState=[string]$Value.replacementState
      operationId=if($null-eq$Value.operationId){$null}else{[string]$Value.operationId};replacementSetHash=if($null-eq$Value.replacementSetHash){$null}else{[string]$Value.replacementSetHash}
      oldControllerThreadId=if($null-eq$Value.oldControllerThreadId){$null}else{[string]$Value.oldControllerThreadId};oldHostId=if($null-eq$Value.oldHostId){$null}else{[string]$Value.oldHostId}
      newControllerThreadId=if($null-eq$Value.newControllerThreadId){$null}else{[string]$Value.newControllerThreadId};newHostId=if($null-eq$Value.newHostId){$null}else{[string]$Value.newHostId}
      manifestPreparedHash=if($null-eq$Value.manifestPreparedHash){$null}else{[string]$Value.manifestPreparedHash};prepareToken=if($null-eq$Value.prepareToken){$null}else{[string]$Value.prepareToken}
      manifestSwitchedHash=if($null-eq$Value.manifestSwitchedHash){$null}else{[string]$Value.manifestSwitchedHash};preparedAt=if($null-eq$Value.preparedAt){$null}else{[string]$Value.preparedAt};committedAt=if($null-eq$Value.committedAt){$null}else{[string]$Value.committedAt}
      activeDispatchCount=[int]$Value.activeDispatchCount;unacknowledgedReceiptCount=[int]$Value.unacknowledgedReceiptCount
      fenceState=[string]$Value.fenceState;fenceOperationId=if($null-eq$Value.fenceOperationId){$null}else{[string]$Value.fenceOperationId};fencePlanHash=if($null-eq$Value.fencePlanHash){$null}else{[string]$Value.fencePlanHash}
      fenceManifestExpectedHash=if($null-eq$Value.fenceManifestExpectedHash){$null}else{[string]$Value.fenceManifestExpectedHash};fencePreparedAt=if($null-eq$Value.fencePreparedAt){$null}else{[string]$Value.fencePreparedAt}
      fenceCompletedManifestHash=if($null-eq$Value.fenceCompletedManifestHash){$null}else{[string]$Value.fenceCompletedManifestHash};fenceCompletedAt=if($null-eq$Value.fenceCompletedAt){$null}else{[string]$Value.fenceCompletedAt}
      wakeWorkerState=[string]$Value.wakeWorkerState;wakeWorkerOperationId=if($null-eq$Value.wakeWorkerOperationId){$null}else{[string]$Value.wakeWorkerOperationId};wakeWorkerThreadId=if($null-eq$Value.wakeWorkerThreadId){$null}else{[string]$Value.wakeWorkerThreadId};wakeWorkerClientThreadId=if($null-eq$Value.wakeWorkerClientThreadId){$null}else{[string]$Value.wakeWorkerClientThreadId}
      wakeAutomationState=[string]$Value.wakeAutomationState;wakeAutomationOperationId=if($null-eq$Value.wakeAutomationOperationId){$null}else{[string]$Value.wakeAutomationOperationId};wakeAutomationId=if($null-eq$Value.wakeAutomationId){$null}else{[string]$Value.wakeAutomationId}
    }
  }catch{throw $Failure}
}

function Convert-ArchiveSnapshot {
  param([object]$Value,[string]$Failure='manifest')
  try{
    if(-not(Test-ClosedObject $Value @('threadId','hostId','codexProjectId','archived','projectRoot','history'))-or
       -not(Test-ControllerText $Value.threadId 200)-or-not(Test-ControllerText $Value.hostId 200)-or-not(Test-ControllerText $Value.codexProjectId 200)-or
       $Value.archived-isnot[bool]-or-not$Value.archived-or-not(Test-NormalizedWindowsRoot $Value.projectRoot)-or
       -not(Test-ClosedObject $Value.history @('oldestTurnId','newestTurnId','turnCount','historyDigest','eofComplete'))-or
       -not(Test-ControllerText $Value.history.oldestTurnId 200)-or-not(Test-ControllerText $Value.history.newestTurnId 200)-or
       $Value.history.turnCount-isnot[int]-or$Value.history.turnCount-lt1-or-not(Test-Hash $Value.history.historyDigest)-or
       $Value.history.eofComplete-isnot[bool]-or-not$Value.history.eofComplete){throw 'invalid'}
    return [pscustomobject][ordered]@{
      threadId=[string]$Value.threadId;hostId=[string]$Value.hostId;codexProjectId=[string]$Value.codexProjectId;archived=$true;projectRoot=[string]$Value.projectRoot
      history=[pscustomobject][ordered]@{oldestTurnId=[string]$Value.history.oldestTurnId;newestTurnId=[string]$Value.history.newestTurnId;turnCount=[int]$Value.history.turnCount;historyDigest=[string]$Value.history.historyDigest;eofComplete=$true}
    }
  }catch{throw $Failure}
}

function Convert-TaskSetReset {
  param([AllowNull()][object]$Value,[string]$Root,[object]$Controller,[object[]]$Projects)
  if($null-eq$Value){return $null}
  $fields=@('operationId','planHash','initialEvidenceHash','finalEvidenceHash','fromTaskSetId','toTaskSetId','phase','coordinator','expectedController','expectedProjectBindings','targets','initialActiveChains','initialExternalQuiescence','finalActiveChains','finalExternalQuiescence','replacementSetHash','runtimePrepared','runtimeCommitted','archives','preparedAt','finalizedAt','switchedAt','completedAt')
  if(-not(Test-ClosedObject $Value $fields)-or$Value.phase-cnotin@('prepared','archiving','archived','finalized','runtime-prepared','switched','runtime-committed','completed')){throw 'manifest'}
  foreach($field in @('operationId','fromTaskSetId','toTaskSetId')){if(-not(Test-ControllerText $Value.$field 200)){throw 'manifest'}}
  if(-not(Test-Hash $Value.planHash)-or-not(Test-Hash $Value.initialEvidenceHash)-or$Value.toTaskSetId-cne(Get-NextTaskSetId $Root $Value.fromTaskSetId $Value.operationId)-or-not(Test-UtcIso8601 $Value.preparedAt)){throw 'manifest'}
  $coordinator=Convert-TaskSetCoordinator $Value.coordinator
  $expectedController=Convert-ControllerBinding $Value.expectedController $Root
  $expectedProjects=@(Convert-ProjectBindings $Value.expectedProjectBindings $Root)
  if($null-eq$expectedController-or$Value.targets-isnot[Array]-or@($Value.targets).Count-ne($expectedProjects.Count+1)-or
     $Value.initialActiveChains-isnot[Array]-or@($Value.initialActiveChains).Count-gt1000-or$Value.archives-isnot[Array]){throw 'manifest'}
  $oldThreads=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $null=$oldThreads.Add([string]$expectedController.threadId);foreach($project in $expectedProjects){$null=$oldThreads.Add([string]$project.entryThreadId)}
  if($oldThreads.Contains([string]$coordinator.threadId)){throw 'manifest'}
  $targets=@();$targetKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$creationIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($target in @($Value.targets)){
    if(-not(Test-ClosedObject $target @('kind','projectRoot','creationOperationId','expectedCodexProjectId','expectedHostId','initialHandoff','finalHandoff','creationIssuedAt','clientThreadId','replacement','bootstrapProof','standbyProof'))-or
       $target.kind-cnotin@('controller','project')-or-not(Test-NormalizedWindowsRoot $target.projectRoot)-or-not(Test-ControllerText $target.creationOperationId 200)-or
       -not(Test-ControllerText $target.expectedCodexProjectId 200)-or-not(Test-ControllerText $target.expectedHostId 200)-or
       -not$targetKeys.Add(([string]$target.kind+"`n"+[string]$target.projectRoot))-or-not$creationIds.Add([string]$target.creationOperationId)-or
        ($null-ne$target.creationIssuedAt-and-not(Test-UtcIso8601 $target.creationIssuedAt))-or
        ($null-ne$target.clientThreadId-and-not(Test-ControllerText $target.clientThreadId 200))){throw 'manifest'}
    $initialHandoff=Convert-TaskSetHandoff $target.initialHandoff;if($null-eq$initialHandoff){throw 'manifest'}
    $finalHandoff=Convert-TaskSetHandoff $target.finalHandoff
    $replacement=$null
    if($null-ne$target.replacement){
      if(-not(Test-ClosedObject $target.replacement @('threadId','codexProjectId','hostId','projectRoot'))-or-not(Test-ControllerText $target.replacement.threadId 200)-or
         -not(Test-ControllerText $target.replacement.codexProjectId 200)-or-not(Test-ControllerText $target.replacement.hostId 200)-or$target.replacement.projectRoot-cne$target.projectRoot){throw 'manifest'}
      $replacement=[pscustomobject][ordered]@{threadId=[string]$target.replacement.threadId;codexProjectId=[string]$target.replacement.codexProjectId;hostId=[string]$target.replacement.hostId;projectRoot=[string]$target.replacement.projectRoot}
      if($replacement.threadId-ceq$coordinator.threadId){throw 'manifest'}
    }
    $bootstrap=Convert-BootstrapProof $target.bootstrapProof
    if($null-ne$bootstrap){
      if($null-eq$replacement-or$bootstrap.threadId-cne$replacement.threadId-or$bootstrap.codexProjectId-cne$replacement.codexProjectId-or$bootstrap.hostId-cne$replacement.hostId-or
         $null-eq$target.creationIssuedAt-or$bootstrap.projectRoot-cne$replacement.projectRoot-or$bootstrap.creationOperationId-cne$target.creationOperationId-or
         -not(Test-TimeOnOrAfter $bootstrap.observedAt $target.creationIssuedAt)){throw 'manifest'}
    }
    $standby=Convert-StandbyProof $target.standbyProof
    if($null-ne$standby){
      if($null-eq$finalHandoff){throw 'manifest'}
      if($null-eq$replacement-or-not(Test-CanonicalValueEqual ([pscustomobject][ordered]@{threadId=$standby.threadId;codexProjectId=$standby.codexProjectId;hostId=$standby.hostId;projectRoot=$standby.projectRoot}) $replacement)-or
         $standby.summaryHash-cne$finalHandoff.summaryHash-or$standby.historyDigest-cne$finalHandoff.historyDigest-or$standby.newestTurnId-cne$finalHandoff.newestTurnId-or
         -not(Test-TimeOnOrAfter $standby.observedAt $finalHandoff.observedAt)){throw 'manifest'}
    }
    $targets+=[pscustomobject][ordered]@{
      kind=[string]$target.kind;projectRoot=[string]$target.projectRoot;creationOperationId=[string]$target.creationOperationId
      expectedCodexProjectId=[string]$target.expectedCodexProjectId;expectedHostId=[string]$target.expectedHostId
      initialHandoff=$initialHandoff;finalHandoff=$finalHandoff
      creationIssuedAt=if($null-eq$target.creationIssuedAt){$null}else{[string]$target.creationIssuedAt}
      clientThreadId=if($null-eq$target.clientThreadId){$null}else{[string]$target.clientThreadId};replacement=$replacement;bootstrapProof=$bootstrap;standbyProof=$standby
    }
  }
  if(@($targets|Where-Object{$_.kind-ceq'controller'-and$_.projectRoot.Equals($Root,[StringComparison]::OrdinalIgnoreCase)}).Count-ne1){throw 'manifest'}
  foreach($project in $expectedProjects){if(@($targets|Where-Object{$_.kind-ceq'project'-and$_.projectRoot-ceq$project.projectRoot}).Count-ne1){throw 'manifest'}}
  $controllerTarget=@($targets|Where-Object{$_.kind-ceq'controller'})[0]
  foreach($target in $targets){$expected=if($target.kind-ceq'controller'){$expectedController}else{@($expectedProjects|Where-Object{$_.projectRoot-ceq$target.projectRoot})[0]};if($target.expectedCodexProjectId-cne$expected.codexProjectId-or$target.expectedHostId-cne$expected.hostId){throw 'manifest'}}
  if($null-ne$controllerTarget.standbyProof-and@($targets|Where-Object{$_.kind-ceq'project'-and$null-eq$_.standbyProof}).Count-gt0){throw 'manifest'}
  if($null-ne$controllerTarget.bootstrapProof-and(@($targets|Where-Object{$_.kind-ceq'project'-and$null-eq$_.bootstrapProof}).Count-gt0-or@($targets|Where-Object{$_.kind-ceq'project'-and-not(Test-TimeOnOrAfter $controllerTarget.bootstrapProof.observedAt $_.bootstrapProof.observedAt)}).Count-gt0)){throw 'manifest'}
  $replacementThreads=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($target in $targets){
    if($null-eq$target.replacement){continue}
    $expected=if($target.kind-ceq'controller'){$expectedController}else{@($expectedProjects|Where-Object{$_.projectRoot-ceq$target.projectRoot})[0]}
    if($target.replacement.codexProjectId-cne$expected.codexProjectId-or$target.replacement.hostId-cne$expected.hostId-or$oldThreads.Contains([string]$target.replacement.threadId)-or-not$replacementThreads.Add([string]$target.replacement.threadId)){throw 'manifest'}
  }
  if($Value.phase-in@('prepared','archiving','archived','finalized','runtime-prepared')){
    if($null-eq$Controller-or$Controller.threadId-cne$expectedController.threadId-or$Controller.codexProjectId-cne$expectedController.codexProjectId-or$Controller.hostId-cne$expectedController.hostId-or$Controller.projectRoot-cne$expectedController.projectRoot-or$Projects.Count-ne$expectedProjects.Count){throw 'manifest'}
    foreach($project in $Projects){$expected=@($expectedProjects|Where-Object{$_.projectRoot-ceq$project.projectRoot});if($expected.Count-ne1-or$project.entryThreadId-cne$expected[0].entryThreadId-or$project.codexProjectId-cne$expected[0].codexProjectId-or$project.hostId-cne$expected[0].hostId){throw 'manifest'}}
  }else{
    if($null-eq$controllerTarget.replacement-or$null-eq$Controller-or$Controller.threadId-cne$controllerTarget.replacement.threadId-or$Controller.codexProjectId-cne$controllerTarget.replacement.codexProjectId-or$Controller.hostId-cne$controllerTarget.replacement.hostId-or$Controller.projectRoot-cne$controllerTarget.projectRoot-or$Projects.Count-ne$expectedProjects.Count){throw 'manifest'}
    foreach($project in $Projects){$target=@($targets|Where-Object{$_.kind-ceq'project'-and$_.projectRoot-ceq$project.projectRoot});if($target.Count-ne1-or$null-eq$target[0].replacement-or$project.entryThreadId-cne$target[0].replacement.threadId-or$project.codexProjectId-cne$target[0].replacement.codexProjectId-or$project.hostId-cne$target[0].replacement.hostId){throw 'manifest'}}
  }
  if((Get-TaskSetPlanHash $Value.operationId $Value.fromTaskSetId $Value.toTaskSetId $coordinator $expectedController $expectedProjects $targets)-cne$Value.planHash){throw 'manifest'}
  $initialChains=@();$chainIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($chain in @($Value.initialActiveChains)){if(-not(Test-ClosedObject $chain @('chainId','expectedEntryHash'))-or-not(Test-ControllerText $chain.chainId 200)-or-not(Test-Hash $chain.expectedEntryHash)-or-not$chainIds.Add([string]$chain.chainId)){throw 'manifest'};$initialChains+=[pscustomobject][ordered]@{chainId=[string]$chain.chainId;expectedEntryHash=[string]$chain.expectedEntryHash}}
  $initialExternal=Convert-ExternalQuiescence $Value.initialExternalQuiescence $Root
  $initialRuntime=$initialExternal.runtimeReadback
  if($initialRuntime.fenceState-cne'prepared'-or$initialRuntime.fenceOperationId-cne$Value.operationId-or$initialRuntime.fencePlanHash-cne$Value.planHash-or
     $initialRuntime.replacementState-cnotin@('none','legacy')-or$initialRuntime.controllerThreadId-cne$expectedController.threadId-or$initialRuntime.hostId-cne$expectedController.hostId-or
     -not(Test-TimeOnOrAfter $initialExternal.observedAt $initialRuntime.fencePreparedAt)){throw 'manifest'}
  foreach($target in $targets){if(-not(Test-TimeOnOrAfter $initialExternal.observedAt $target.initialHandoff.observedAt)){throw 'manifest'}}
  if(-not(Test-TimeOnOrAfter $Value.preparedAt $initialExternal.observedAt)){throw 'manifest'}
  if((Get-TaskSetEvidenceHash $targets 'initialHandoff' $initialChains $initialExternal @())-cne$Value.initialEvidenceHash){throw 'manifest'}
  $allReplacementsReady=@($targets|Where-Object{$null-eq$_.replacement}).Count-eq0
  $allBootstrapsReady=@($targets|Where-Object{$null-eq$_.bootstrapProof}).Count-eq0
  $allStandbysReady=@($targets|Where-Object{$null-eq$_.standbyProof}).Count-eq0
  $computedReplacementSetHash=if($allReplacementsReady){Get-TaskSetReplacementHash $targets}else{$null}
  if(($allReplacementsReady-and$Value.replacementSetHash-cne$computedReplacementSetHash)-or(-not$allReplacementsReady-and$null-ne$Value.replacementSetHash)){throw 'manifest'}
  $replacementSetHash=if($allReplacementsReady){[string]$Value.replacementSetHash}else{$null}
  $archives=@();$archiveKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach($archive in @($Value.archives)){
    if(-not(Test-ClosedObject $archive @('kind','snapshot','snapshotHash','archivedAt'))-or$archive.kind-cnotin@('controller','project')-or-not(Test-Hash $archive.snapshotHash)-or-not(Test-UtcIso8601 $archive.archivedAt)-or-not(Test-TimeOnOrAfter $archive.archivedAt $Value.preparedAt)){throw 'manifest'}
    $snapshot=Convert-ArchiveSnapshot $archive.snapshot
    if((Get-Hash $utf8.GetBytes(($snapshot|ConvertTo-Json -Depth 10 -Compress)))-cne$archive.snapshotHash-or-not$archiveKeys.Add(([string]$archive.kind+"`n"+[string]$snapshot.projectRoot))){throw 'manifest'}
    $expected=if($archive.kind-ceq'controller'){$expectedController}else{@($expectedProjects|Where-Object{$_.projectRoot-ceq$snapshot.projectRoot})[0]}
    $expectedThread=if($archive.kind-ceq'controller'){$expected.threadId}else{$expected.entryThreadId}
    $target=@($targets|Where-Object{$_.kind-ceq$archive.kind-and$_.projectRoot-ceq$snapshot.projectRoot})
    if($null-eq$expected-or$target.Count-ne1-or$null-eq$target[0].bootstrapProof-or-not(Test-TimeOnOrAfter $archive.archivedAt $target[0].bootstrapProof.observedAt)-or
       $snapshot.threadId-cne$expectedThread-or$snapshot.codexProjectId-cne$expected.codexProjectId-or$snapshot.hostId-cne$expected.hostId-or$snapshot.projectRoot-cne$expected.projectRoot){throw 'manifest'}
    if($archive.kind-ceq'controller'-and(@($expectedProjects|Where-Object{-not$archiveKeys.Contains("project`n"+[string]$_.projectRoot)}).Count-gt0-or@($archives|Where-Object{$_.kind-ceq'project'-and-not(Test-TimeOnOrAfter $archive.archivedAt $_.archivedAt)}).Count-gt0)){throw 'manifest'}
    $archives+=[pscustomobject][ordered]@{kind=[string]$archive.kind;snapshot=$snapshot;snapshotHash=[string]$archive.snapshotHash;archivedAt=[string]$archive.archivedAt}
  }
  if(( -not$allReplacementsReady -or -not$allBootstrapsReady)-and$archives.Count-gt0){throw 'manifest'}
  if(($Value.phase-ceq'prepared'-and$archives.Count-ne0)-or($Value.phase-ceq'archiving'-and($archives.Count-lt1-or$archives.Count-ge$targets.Count))-or($Value.phase-in@('archived','finalized','runtime-prepared','switched','runtime-committed','completed')-and$archives.Count-ne$targets.Count)){throw 'manifest'}
  $finalized=$Value.phase-in@('finalized','runtime-prepared','switched','runtime-committed','completed')
  $finalChains=@();$finalExternal=$null;$finalizedAt=$null
  if($finalized){
    if(-not(Test-Hash $Value.finalEvidenceHash)-or$Value.finalActiveChains-isnot[Array]-or@($Value.finalActiveChains).Count-gt1000-or-not(Test-UtcIso8601 $Value.finalizedAt)){throw 'manifest'}
    $finalIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($chain in @($Value.finalActiveChains)){if(-not(Test-ClosedObject $chain @('chainId','expectedEntryHash'))-or-not(Test-ControllerText $chain.chainId 200)-or-not(Test-Hash $chain.expectedEntryHash)-or-not$finalIds.Add([string]$chain.chainId)){throw 'manifest'};$finalChains+=[pscustomobject][ordered]@{chainId=[string]$chain.chainId;expectedEntryHash=[string]$chain.expectedEntryHash}}
    $finalExternal=Convert-ExternalQuiescence $Value.finalExternalQuiescence $Root
    $finalRuntime=$finalExternal.runtimeReadback
    if(-not(Test-CanonicalValueEqual @($finalChains) @($initialChains))-or$finalRuntime.fenceState-cne'prepared'-or
       $finalRuntime.fenceOperationId-cne$Value.operationId-or$finalRuntime.fencePlanHash-cne$Value.planHash-or
       $finalRuntime.fenceManifestExpectedHash-cne$initialRuntime.fenceManifestExpectedHash-or$finalRuntime.fencePreparedAt-cne$initialRuntime.fencePreparedAt-or
       $finalRuntime.replacementState-cnotin@('none','legacy')-or$finalRuntime.controllerThreadId-cne$expectedController.threadId-or$finalRuntime.hostId-cne$expectedController.hostId){throw 'manifest'}
    foreach($target in $targets){
      if($null-eq$target.finalHandoff){throw 'manifest'}
      $archive=@($archives|Where-Object{$_.kind-ceq$target.kind-and$_.snapshot.projectRoot-ceq$target.projectRoot})
      if($archive.Count-ne1-or$target.finalHandoff.oldestTurnId-cne$archive[0].snapshot.history.oldestTurnId-or$target.finalHandoff.newestTurnId-cne$archive[0].snapshot.history.newestTurnId-or$target.finalHandoff.turnCount-ne$archive[0].snapshot.history.turnCount-or$target.finalHandoff.historyDigest-cne$archive[0].snapshot.history.historyDigest-or-not(Test-TimeOnOrAfter $target.finalHandoff.observedAt $archive[0].archivedAt)-or-not(Test-TimeOnOrAfter $finalExternal.observedAt $target.finalHandoff.observedAt)){throw 'manifest'}
    }
    if(-not(Test-TimeOnOrAfter $Value.finalizedAt $finalExternal.observedAt)-or(Get-TaskSetEvidenceHash $targets 'finalHandoff' $finalChains $finalExternal $archives)-cne$Value.finalEvidenceHash){throw 'manifest'}
    $finalizedAt=[string]$Value.finalizedAt
  }else{
    if($null-ne$Value.finalEvidenceHash-or$null-ne$Value.finalActiveChains-or$null-ne$Value.finalExternalQuiescence-or$null-ne$Value.finalizedAt-or@($targets|Where-Object{$null-ne$_.finalHandoff-or$null-ne$_.standbyProof}).Count-gt0){throw 'manifest'}
  }
  if($Value.phase-in@('runtime-prepared','switched','runtime-committed','completed')-and-not$allStandbysReady){throw 'manifest'}
  $runtimePrepared=$null
  if($Value.phase-in@('runtime-prepared','switched','runtime-committed','completed')){
    if(-not(Test-ClosedObject $Value.runtimePrepared @('runtimeReadback','runtimeReadbackHash'))-or-not(Test-Hash $Value.runtimePrepared.runtimeReadbackHash)){throw 'manifest'}
    $readback=Convert-RuntimeReadback $Value.runtimePrepared.runtimeReadback $Root
    if((Get-Hash $utf8.GetBytes(($readback|ConvertTo-Json -Depth 20 -Compress)))-cne$Value.runtimePrepared.runtimeReadbackHash-or$readback.replacementState-cne'prepared'-or
       $readback.operationId-cne$Value.operationId-or$readback.fenceState-cne'prepared'-or$readback.fenceOperationId-cne$Value.operationId-or$readback.fencePlanHash-cne$Value.planHash-or
       $readback.fenceManifestExpectedHash-cne$initialRuntime.fenceManifestExpectedHash-or$readback.replacementSetHash-cne$Value.replacementSetHash-or$readback.oldControllerThreadId-cne$expectedController.threadId-or$readback.oldHostId-cne$expectedController.hostId-or
       $readback.newControllerThreadId-cne$controllerTarget.replacement.threadId-or$readback.newHostId-cne$controllerTarget.replacement.hostId-or-not(Test-TimeOnOrAfter $readback.preparedAt $Value.finalizedAt)){throw 'manifest'}
    $replacementSetHash=[string]$Value.replacementSetHash;$runtimePrepared=[pscustomobject][ordered]@{runtimeReadback=$readback;runtimeReadbackHash=[string]$Value.runtimePrepared.runtimeReadbackHash}
  }elseif($null-ne$Value.runtimePrepared){throw 'manifest'}
  if($Value.phase-in@('switched','runtime-committed','completed')-and(-not(Test-UtcIso8601 $Value.switchedAt)-or-not(Test-TimeOnOrAfter $Value.switchedAt $runtimePrepared.runtimeReadback.preparedAt))){throw 'manifest'}elseif($Value.phase-notin@('switched','runtime-committed','completed')-and$null-ne$Value.switchedAt){throw 'manifest'}
  $runtimeCommitted=$null
  if($Value.phase-in@('runtime-committed','completed')){
    if(-not(Test-ClosedObject $Value.runtimeCommitted @('runtimeReadback','runtimeReadbackHash'))-or-not(Test-Hash $Value.runtimeCommitted.runtimeReadbackHash)){throw 'manifest'}
    $commitReadback=Convert-RuntimeReadback $Value.runtimeCommitted.runtimeReadback $Root
    if((Get-Hash $utf8.GetBytes(($commitReadback|ConvertTo-Json -Depth 20 -Compress)))-cne$Value.runtimeCommitted.runtimeReadbackHash-or$commitReadback.replacementState-cne'committed'-or
        $commitReadback.operationId-cne$Value.operationId-or$commitReadback.fenceState-cne'prepared'-or$commitReadback.fenceOperationId-cne$Value.operationId-or$commitReadback.fencePlanHash-cne$Value.planHash-or
        $commitReadback.fenceManifestExpectedHash-cne$initialRuntime.fenceManifestExpectedHash-or$commitReadback.replacementSetHash-cne$replacementSetHash-or$commitReadback.oldControllerThreadId-cne$runtimePrepared.runtimeReadback.oldControllerThreadId-or
       $commitReadback.oldHostId-cne$runtimePrepared.runtimeReadback.oldHostId-or$commitReadback.newControllerThreadId-cne$runtimePrepared.runtimeReadback.newControllerThreadId-or
       $commitReadback.newHostId-cne$runtimePrepared.runtimeReadback.newHostId-or$commitReadback.manifestPreparedHash-cne$runtimePrepared.runtimeReadback.manifestPreparedHash-or
       $commitReadback.prepareToken-cne$runtimePrepared.runtimeReadback.prepareToken-or$commitReadback.preparedAt-cne$runtimePrepared.runtimeReadback.preparedAt-or
       -not(Test-TimeOnOrAfter $commitReadback.committedAt $Value.switchedAt)){throw 'manifest'}
    $runtimeCommitted=[pscustomobject][ordered]@{runtimeReadback=$commitReadback;runtimeReadbackHash=[string]$Value.runtimeCommitted.runtimeReadbackHash}
  }elseif($null-ne$Value.runtimeCommitted){throw 'manifest'}
  $completedAt=$null
  if($Value.phase-ceq'completed'){if(-not(Test-UtcIso8601 $Value.completedAt)-or-not(Test-TimeOnOrAfter $Value.completedAt $runtimeCommitted.runtimeReadback.committedAt)){throw 'manifest'};$completedAt=[string]$Value.completedAt}elseif($null-ne$Value.completedAt){throw 'manifest'}
  return [pscustomobject][ordered]@{
    operationId=[string]$Value.operationId;planHash=[string]$Value.planHash;initialEvidenceHash=[string]$Value.initialEvidenceHash;finalEvidenceHash=if($null-eq$Value.finalEvidenceHash){$null}else{[string]$Value.finalEvidenceHash};fromTaskSetId=[string]$Value.fromTaskSetId;toTaskSetId=[string]$Value.toTaskSetId;phase=[string]$Value.phase;coordinator=$coordinator
    expectedController=$expectedController;expectedProjectBindings=@($expectedProjects);targets=@($targets);initialActiveChains=@($initialChains);initialExternalQuiescence=$initialExternal;finalActiveChains=if($null-eq$Value.finalActiveChains){$null}else{,@($finalChains)};finalExternalQuiescence=$finalExternal
    replacementSetHash=$replacementSetHash;runtimePrepared=$runtimePrepared;runtimeCommitted=$runtimeCommitted;archives=@($archives)
    preparedAt=[string]$Value.preparedAt;finalizedAt=$finalizedAt;switchedAt=if($null-eq$Value.switchedAt){$null}else{[string]$Value.switchedAt};completedAt=$completedAt
  }
}

function Get-TaskSetResetHistoryPath {
  param([string]$Root)
  return Join-Path $Root 'state\task-set-reset-history.jsonl'
}

function Get-TaskSetResetSealPath {
  param([string]$Root)
  return Join-Path $Root 'state\.task-set-reset-seal.json'
}

function New-TaskSetResetHistoryEvent {
  param([object]$Record,[int]$Sequence,[AllowNull()][object]$PreviousEntryHash)
  $previous=if($null-eq$PreviousEntryHash){$null}else{[string]$PreviousEntryHash}
  $recordHash=Get-Hash $utf8.GetBytes(($Record|ConvertTo-Json -Depth 30 -Compress))
  $core=[pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;previousEntryHash=$previous;recordHash=$recordHash;record=$Record}
  $entryHash=Get-Hash $utf8.GetBytes(($core|ConvertTo-Json -Depth 32 -Compress))
  return [pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;previousEntryHash=$previous;recordHash=$recordHash;record=$Record;entryHash=$entryHash}
}

function Read-TaskSetResetHistory {
  param([string]$Root)
  $path=Get-TaskSetResetHistoryPath $Root
  if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Path=$path;Bytes=[byte[]]@();Hash=(Get-Hash ([byte[]]@()));Items=@()}}
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or-not(Test-ReparseComponents $path)){throw 'history'}
  $item=Get-Item -Force -LiteralPath $path
  if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'history'}
  $bytes=[IO.File]::ReadAllBytes($path)
  if($bytes.Length-gt64MB-or($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF)){throw 'history'}
  if($bytes.Length-eq0){return [pscustomobject]@{Path=$path;Bytes=$bytes;Hash=(Get-Hash $bytes);Items=@()}}
  $text=$utf8.GetString($bytes)
  if($text.Contains("`r")-or-not$text.EndsWith("`n")){throw 'history'}
  $lines=$text.Split("`n");$events=@();$previous=$null;$operations=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  for($index=0;$index-lt($lines.Count-1);$index++){
    $line=$lines[$index];if([string]::IsNullOrWhiteSpace($line)){throw 'history'}
    try{$event=$line|ConvertFrom-Json -ErrorAction Stop}catch{throw 'history'}
    if(-not(Test-ClosedObject $event @('schemaVersion','seq','previousEntryHash','recordHash','record','entryHash'))-or$event.schemaVersion-isnot[int]-or$event.schemaVersion-ne1-or
       $event.seq-isnot[int]-or$event.seq-ne($index+1)-or(($index-eq0-and$null-ne$event.previousEntryHash)-or($index-gt0-and$event.previousEntryHash-cne$previous))-or
       -not(Test-Hash $event.recordHash)-or-not(Test-Hash $event.entryHash)){throw 'history'}
    $rawRecord=$event.record
    if($null-eq$rawRecord-or$rawRecord.phase-cne'completed'){throw 'history'}
    $controllerTarget=@($rawRecord.targets|Where-Object{$_.kind-ceq'controller'});$projectTargets=@($rawRecord.targets|Where-Object{$_.kind-ceq'project'})
    if($controllerTarget.Count-ne1-or$null-eq$controllerTarget[0].replacement-or@($projectTargets|Where-Object{$null-eq$_.replacement}).Count-gt0){throw 'history'}
    $historyController=[pscustomobject][ordered]@{threadId=[string]$controllerTarget[0].replacement.threadId;codexProjectId=[string]$controllerTarget[0].replacement.codexProjectId;hostId=[string]$controllerTarget[0].replacement.hostId;projectRoot=[string]$controllerTarget[0].projectRoot}
    $historyProjects=@($projectTargets|ForEach-Object{[pscustomobject][ordered]@{entryThreadId=[string]$_.replacement.threadId;codexProjectId=[string]$_.replacement.codexProjectId;hostId=[string]$_.replacement.hostId;projectRoot=[string]$_.projectRoot}})
    try{$record=Convert-TaskSetReset $rawRecord $Root $historyController $historyProjects}catch{throw 'history'}
    if($record.phase-cne'completed'-or-not$operations.Add([string]$record.operationId)){throw 'history'}
    $canonical=New-TaskSetResetHistoryEvent $record ($index+1) $previous
    if($canonical.recordHash-cne$event.recordHash-or$canonical.entryHash-cne$event.entryHash-or($canonical|ConvertTo-Json -Depth 32 -Compress)-cne$line){throw 'history'}
    if($index-eq0){if($record.fromTaskSetId-cne(Get-InitialTaskSetId $Root)){throw 'history'}}elseif($record.fromTaskSetId-cne$events[$index-1].record.toTaskSetId){throw 'history'}
    $events+=$canonical;$previous=$canonical.entryHash
  }
  return [pscustomobject]@{Path=$path;Bytes=$bytes;Hash=(Get-Hash $bytes);Items=@($events)}
}

function Assert-TaskSetResetHistory {
  param([string]$Root,[object]$Manifest)
  if($Manifest.schemaVersion-ne3){return}
  $history=Read-TaskSetResetHistory $Root
  $expectedTaskSetId=if($null-eq$Manifest.taskSetReset){[string]$Manifest.taskSetId}else{[string]$Manifest.taskSetReset.fromTaskSetId}
  if($history.Items.Count-eq0){if($expectedTaskSetId-cne(Get-InitialTaskSetId $Root)){throw 'history'}}
  elseif($history.Items[-1].record.toTaskSetId-cne$expectedTaskSetId){throw 'history'}
  if($null-ne$Manifest.taskSetReset-and@($history.Items|Where-Object{$_.record.operationId-ceq$Manifest.taskSetReset.operationId}).Count-gt0){throw 'history'}
}

function Convert-TaskSetResetSealMarker {
  param([object]$Value)
  $fields=@('schemaVersion','kind','operationId','completedAt','sourceManifestHash','candidateHash','sourceHistoryHash','targetHistoryHash','historyEntryHash','finalManifestHash')
  if(-not(Test-ClosedObject $Value $fields)-or$Value.schemaVersion-isnot[int]-or$Value.schemaVersion-ne1-or$Value.kind-cne'task-set-reset-seal'-or
     -not(Test-ControllerText $Value.operationId 200)-or-not(Test-UtcIso8601 $Value.completedAt)){throw 'seal'}
  foreach($field in @('sourceManifestHash','candidateHash','sourceHistoryHash','targetHistoryHash','historyEntryHash','finalManifestHash')){if(-not(Test-Hash $Value.$field)){throw 'seal'}}
  return [pscustomobject][ordered]@{schemaVersion=1;kind='task-set-reset-seal';operationId=[string]$Value.operationId;completedAt=[string]$Value.completedAt;sourceManifestHash=[string]$Value.sourceManifestHash;candidateHash=[string]$Value.candidateHash;sourceHistoryHash=[string]$Value.sourceHistoryHash;targetHistoryHash=[string]$Value.targetHistoryHash;historyEntryHash=[string]$Value.historyEntryHash;finalManifestHash=[string]$Value.finalManifestHash}
}

function Read-TaskSetResetSealMarker {
  param([string]$Root)
  $path=Get-TaskSetResetSealPath $Root
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or-not(Test-ReparseComponents $path)){throw 'seal'}
  $bytes=[IO.File]::ReadAllBytes($path);if($bytes.Length-eq0-or$bytes.Length-gt16KB){throw 'seal'}
  try{$value=$utf8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop;$marker=Convert-TaskSetResetSealMarker $value}catch{throw 'seal'}
  $canonical=$utf8.GetBytes(($marker|ConvertTo-Json -Compress)+"`n");if(-not(Test-BytesEqual $bytes $canonical)){throw 'seal'}
  return [pscustomobject]@{Path=$path;Bytes=$bytes;Data=$marker}
}

function Write-AtomicControllerFile {
  param([string]$Path,[byte[]]$Bytes)
  $directory=Split-Path -Parent $Path;[IO.Directory]::CreateDirectory($directory)|Out-Null
  $temporary=Join-Path $directory ('.'+[IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
  try{
    $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    if(-not(Test-BytesEqual ([IO.File]::ReadAllBytes($Path)) $Bytes)){throw 'readback'}
  }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function Get-TaskSetResetSealArtifacts {
  param([string]$Root,[object]$SourceManifest,[string]$SourceManifestHash,[object]$CompletedManifest,[string]$CandidateHash,[object]$History)
  $reset=$CompletedManifest.taskSetReset
  if($null-eq$reset-or$reset.phase-cne'completed'){throw 'seal'}
  $previousEntryHash=if($History.Items.Count-eq0){$null}else{[string]$History.Items[-1].entryHash}
  $event=New-TaskSetResetHistoryEvent $reset ($History.Items.Count+1) $previousEntryHash
  if(@($History.Items|Where-Object{$_.record.operationId-ceq$reset.operationId}).Count-gt0){throw 'seal'}
  $eventBytes=$utf8.GetBytes(($event|ConvertTo-Json -Depth 32 -Compress)+"`n");$targetHistoryBytes=[byte[]]($History.Bytes+$eventBytes)
  $final=$CompletedManifest|ConvertTo-Json -Depth 32 -Compress|ConvertFrom-Json;$final.taskSetReset=$null
  $finalBytes=$utf8.GetBytes(($final|ConvertTo-Json -Depth 32 -Compress)+"`n");$finalValidated=Convert-ManifestBytes $finalBytes $Root
  $marker=[pscustomobject][ordered]@{schemaVersion=1;kind='task-set-reset-seal';operationId=[string]$reset.operationId;completedAt=[string]$reset.completedAt;sourceManifestHash=$SourceManifestHash;candidateHash=$CandidateHash;sourceHistoryHash=[string]$History.Hash;targetHistoryHash=(Get-Hash $targetHistoryBytes);historyEntryHash=[string]$event.entryHash;finalManifestHash=[string]$finalValidated.Hash}
  return [pscustomobject]@{Marker=$marker;Event=$event;TargetHistoryBytes=$targetHistoryBytes;Final=$finalValidated}
}

function Invoke-TaskSetResetSeal {
  param([string]$Root,[object]$Current,[object]$Completed,[string]$CandidateHash,[string]$CandidatePath)
  if(Test-Path -LiteralPath (Get-TaskSetResetSealPath $Root)){throw 'seal'}
  $history=Read-TaskSetResetHistory $Root
  $artifacts=Get-TaskSetResetSealArtifacts $Root $Current.Data $Current.Hash $Completed.Data $CandidateHash $history
  $markerBytes=$utf8.GetBytes(($artifacts.Marker|ConvertTo-Json -Compress)+"`n")
  Write-AtomicControllerFile (Get-TaskSetResetSealPath $Root) $markerBytes
  Write-AtomicControllerFile $history.Path $artifacts.TargetHistoryBytes
  Write-AtomicControllerFile (Join-Path $Root '.codex-controller.json') $artifacts.Final.Bytes
  Assert-TaskSetResetHistory $Root $artifacts.Final.Data
  if(Test-Path -LiteralPath $CandidatePath){Remove-Item -LiteralPath $CandidatePath -Force}
  return $artifacts.Final
}

function Recover-TaskSetResetSeal {
  param([string]$Root,[AllowNull()][object]$RuntimeEvidence)
  $marker=Read-TaskSetResetSealMarker $Root
  $current=Read-Manifest $Root -SkipResetHistory
  $history=Read-TaskSetResetHistory $Root
  if($current.Hash-cnotin@($marker.Data.sourceManifestHash,$marker.Data.finalManifestHash)-or$history.Hash-cnotin@($marker.Data.sourceHistoryHash,$marker.Data.targetHistoryHash)){throw 'seal'}
  if($current.Hash-ceq$marker.Data.finalManifestHash-and$history.Hash-cne$marker.Data.targetHistoryHash){throw 'seal'}
  $completed=$null
  if($history.Hash-ceq$marker.Data.targetHistoryHash){
    if($history.Items.Count-eq0-or$history.Items[-1].entryHash-cne$marker.Data.historyEntryHash-or$history.Items[-1].record.operationId-cne$marker.Data.operationId){throw 'seal'}
    $completed=[pscustomobject]@{Data=($current.Data|ConvertTo-Json -Depth 32 -Compress|ConvertFrom-Json);Hash=$marker.Data.candidateHash}
    $completed.Data.taskSetReset=$history.Items[-1].record
  }else{
    if($current.Hash-cne$marker.Data.sourceManifestHash-or$null-eq$current.Data.taskSetReset-or$current.Data.taskSetReset.operationId-cne$marker.Data.operationId-or$current.Data.taskSetReset.phase-cne'runtime-committed'){throw 'seal'}
    $completedData=$current.Data|ConvertTo-Json -Depth 32 -Compress|ConvertFrom-Json
    $completedData.taskSetReset.phase='completed';$completedData.taskSetReset.completedAt=$marker.Data.completedAt
    $completedBytes=$utf8.GetBytes(($completedData|ConvertTo-Json -Depth 32 -Compress)+"`n");$completedValidated=Convert-ManifestBytes $completedBytes $Root
    if($completedValidated.Hash-cne$marker.Data.candidateHash){throw 'seal'}
    $completed=$completedValidated
  }
  $sourceForArtifacts=if($current.Hash-ceq$marker.Data.sourceManifestHash){$current}else{[pscustomobject]@{Data=$completed.Data;Hash=$marker.Data.sourceManifestHash}}
  $sourceHistory=if($history.Hash-ceq$marker.Data.sourceHistoryHash){$history}else{
    if($history.Items.Count-eq1){$priorBytes=[byte[]]::new(0);$priorItems=@()}
    else{$priorBytes=$utf8.GetBytes((@($history.Items[0..($history.Items.Count-2)]|ForEach-Object{$_|ConvertTo-Json -Depth 32 -Compress})-join"`n")+"`n");$priorItems=@($history.Items[0..($history.Items.Count-2)])}
    [pscustomobject]@{Path=$history.Path;Bytes=$priorBytes;Hash=(Get-Hash $priorBytes);Items=@($priorItems)}
  }
  $artifacts=Get-TaskSetResetSealArtifacts $Root $sourceForArtifacts.Data $marker.Data.sourceManifestHash $completed.Data $marker.Data.candidateHash $sourceHistory
  $canonicalMarker=Convert-TaskSetResetSealMarker $artifacts.Marker
  if(-not(Test-CanonicalValueEqual $canonicalMarker $marker.Data)){throw 'seal'}
  if($history.Hash-ceq$marker.Data.sourceHistoryHash){Write-AtomicControllerFile $history.Path $artifacts.TargetHistoryBytes}
  if($current.Hash-ceq$marker.Data.sourceManifestHash){Write-AtomicControllerFile (Join-Path $Root '.codex-controller.json') $artifacts.Final.Bytes}
  $readback=Read-Manifest $Root -SkipResetHistory
  $historyReadback=Read-TaskSetResetHistory $Root
  if($readback.Hash-cne$marker.Data.finalManifestHash-or$historyReadback.Hash-cne$marker.Data.targetHistoryHash){throw 'seal'}
  Assert-TaskSetResetHistory $Root $readback.Data
  if($null-eq$RuntimeEvidence){return [pscustomobject]@{Readback=$readback;Released=$false}}
  if(-not(Test-ClosedObject $RuntimeEvidence @('runtimeReadback','runtimeReadbackHash'))-or-not(Test-Hash $RuntimeEvidence.runtimeReadbackHash)){throw 'seal'}
  $runtime=try{Convert-RuntimeReadback $RuntimeEvidence.runtimeReadback $Root 'seal'}catch{throw 'seal'}
  if((Get-Hash $utf8.GetBytes(($runtime|ConvertTo-Json -Depth 20 -Compress)))-cne$RuntimeEvidence.runtimeReadbackHash){throw 'seal'}
  $record=$historyReadback.Items[-1].record;$controllerTarget=@($record.targets|Where-Object{$_.kind-ceq'controller'})[0]
  if($runtime.fenceState-cne'completed'-or$runtime.fenceOperationId-cne$marker.Data.operationId-or$runtime.fencePlanHash-cne$record.planHash-or
     $runtime.fenceManifestExpectedHash-cne$record.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash-or$runtime.fenceCompletedManifestHash-cne$readback.Hash-or
     -not(Test-TimeOnOrAfter $runtime.fenceCompletedAt $record.completedAt)-or$runtime.replacementState-cne'legacy'-or$runtime.operationId-cne$marker.Data.operationId-or
     $runtime.controllerThreadId-cne$readback.Data.controllerBinding.threadId-or$runtime.hostId-cne$readback.Data.controllerBinding.hostId-or
     $runtime.oldControllerThreadId-cne$record.expectedController.threadId-or$runtime.oldHostId-cne$record.expectedController.hostId-or
     $runtime.newControllerThreadId-cne$controllerTarget.replacement.threadId-or$runtime.newHostId-cne$controllerTarget.replacement.hostId-or
     $runtime.activeDispatchCount-ne0-or$runtime.unacknowledgedReceiptCount-ne0-or$runtime.wakeWorkerState-ceq'pending'-or$runtime.wakeAutomationState-ceq'pending'){throw 'seal'}
  foreach($candidate in @(Get-CandidateItems $Root)){
    if($candidate.PSIsContainer-or($candidate.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or(Get-Hash ([IO.File]::ReadAllBytes($candidate.FullName)))-cne$marker.Data.candidateHash){throw 'seal'}
    Remove-Item -LiteralPath $candidate.FullName -Force
  }
  Remove-Item -LiteralPath $marker.Path -Force
  if(Test-Path -LiteralPath $marker.Path){throw 'seal'}
  return [pscustomobject]@{Readback=$readback;Released=$true}
}

function Get-TaskSetReplacementHash {
  param([object[]]$Targets)
  $rows = @($Targets | ForEach-Object {
    [pscustomobject][ordered]@{
      kind=[string]$_.kind; projectRoot=[string]$_.projectRoot; threadId=[string]$_.replacement.threadId
      codexProjectId=[string]$_.replacement.codexProjectId; hostId=[string]$_.replacement.hostId
    }
  })
  return Get-Hash $utf8.GetBytes(($rows | ConvertTo-Json -Depth 6 -Compress))
}

function Convert-ManifestBytes {
  param([byte[]]$Bytes, [string]$Root)
  try {
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 1MB -or ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) { throw 'manifest' }
    $text = $utf8.GetString($Bytes)
    $manifest = $text | ConvertFrom-Json -ErrorAction Stop
    $version = $manifest.schemaVersion
    $fields = if ($version -eq 1) {
      @('schemaVersion','generator','templateVersion','controllerName','controllerBinding','controllerTaskIntent','projectBindings')
    }
    elseif ($version -eq 2) {
      @('schemaVersion','generator','templateVersion','controllerName','controllerBinding','controllerTaskIntent','projectBindings','dispatchQueues')
    }
    else {
      @('schemaVersion','generator','templateVersion','controllerName','controllerBinding','controllerTaskIntent','projectBindings','dispatchQueues','taskSetId','taskSetReset')
    }
    if (-not (Test-ClosedObject $manifest $fields)) { throw 'manifest' }
    if ($manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -notin @(1,2,3) -or $manifest.generator -cne 'onboard-code-projects' -or $manifest.templateVersion -isnot [int] -or $manifest.templateVersion -ne $manifest.schemaVersion) { throw 'manifest' }
    if (-not (Test-NonEmptyString $manifest.controllerName) -or $manifest.controllerName.Length -gt 80 -or $manifest.controllerName -match '[\x00-\x1f\x7f/\\]') { throw 'manifest' }
    $binding = Convert-ControllerBinding $manifest.controllerBinding $Root
    $intent = Convert-ControllerTaskIntent $manifest.controllerTaskIntent $Root
    if ($null -ne $binding -and $null -ne $intent) { throw 'manifest' }
    $projects = @(Convert-ProjectBindings $manifest.projectBindings $Root)
    $canonical = [ordered]@{
      schemaVersion=[int]$version; generator='onboard-code-projects'; templateVersion=[int]$version; controllerName=[string]$manifest.controllerName
      controllerBinding=$binding; controllerTaskIntent=$intent; projectBindings=@($projects)
    }
    if ($version -ge 2) { $canonical.dispatchQueues = @(Convert-DispatchQueues $manifest.dispatchQueues $projects) }
    if ($version -eq 3) {
      if (-not (Test-ControllerText $manifest.taskSetId 200)) { throw 'manifest' }
      $canonical.taskSetId = [string]$manifest.taskSetId
      $canonical.taskSetReset = Convert-TaskSetReset $manifest.taskSetReset $Root $binding $projects
      if ($null -ne $canonical.taskSetReset) {
        $expectedTaskSetId = if ($canonical.taskSetReset.phase -in @('prepared','archiving','archived','finalized','runtime-prepared')) { $canonical.taskSetReset.fromTaskSetId } else { $canonical.taskSetReset.toTaskSetId }
        if ($canonical.taskSetId -cne $expectedTaskSetId) { throw 'manifest' }
      }
    }
    $canonical = [pscustomobject]$canonical
    $canonicalBytes = $utf8.GetBytes(($canonical | ConvertTo-Json -Depth 12 -Compress) + "`n")
    if (-not (Test-BytesEqual $Bytes $canonicalBytes)) { throw 'manifest' }
    return [pscustomobject]@{ Data=$canonical; Bytes=$canonicalBytes; Hash=(Get-Hash $canonicalBytes) }
  }
  catch { throw 'manifest' }
}

function Read-Manifest {
  param([string]$Root,[switch]$SkipResetHistory)
  $path = Join-Path $Root '.codex-controller.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-ReparseComponents $path)) { throw 'manifest' }
  $item = Get-Item -Force -LiteralPath $path
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'manifest' }
  $bytes = [IO.File]::ReadAllBytes($path)
  $result=Convert-ManifestBytes $bytes $Root
  if(-not$SkipResetHistory){Assert-TaskSetResetHistory $Root $result.Data}
  return $result
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

function Get-ActiveChainHeads {
  param([string]$Root,[string[]]$RetiredIdentifiers=@())
  try{$index=Invoke-ChainStoreRead $Root 'Read' 'ChainId' 'N/A'}catch{throw 'state'}
  if($index.status-cne'verified'-or$index.reasonCode-cne'store-read'){throw 'state'}
  $items=@($index.data.items|Where-Object{$_.state-ceq'active'})
  if([int]$index.data.activeCount-ne$items.Count){throw 'state'}
  $heads=@()
  foreach($item in @($items|Sort-Object -CaseSensitive -Property chainId)){
    try{$result=Invoke-ChainStoreRead $Root 'Get' 'ChainId' ([string]$item.chainId)}catch{throw 'state'}
    if($result.status-cne'verified'-or$result.reasonCode-cne'task-read'-or$result.currentEntryHash-cne$item.headEntryHash-or$result.resultEntryHash-cne$item.headEntryHash-or$result.data.record.state-cne'active'){throw 'state'}
    foreach($identifier in $RetiredIdentifiers){
      $pattern='(?<![A-Za-z0-9._:-])'+[Text.RegularExpressions.Regex]::Escape($identifier)+'(?![A-Za-z0-9._:-])'
      if([Text.RegularExpressions.Regex]::IsMatch([string]$result.data.record.objective,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)-or
         [Text.RegularExpressions.Regex]::IsMatch([string]$result.data.record.nextAction,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)){throw 'state'}
    }
    $heads+=[pscustomobject][ordered]@{chainId=[string]$item.chainId;expectedEntryHash=[string]$item.headEntryHash}
  }
  return @($heads)
}

function Assert-ActiveChainHeads {
  param([string]$Root,[object[]]$Chains,[string[]]$RetiredIdentifiers=@())
  $actual=@(Get-ActiveChainHeads $Root $RetiredIdentifiers)
  if(-not(Test-CanonicalValueEqual @($actual) @($Chains))){throw 'state'}
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
  param([object]$Manifest, [string]$Mutation, [string]$Json, [string]$Root, [string]$CurrentHash)
  $version = [int]$Manifest.schemaVersion
  $binding = $Manifest.controllerBinding
  $intent = $Manifest.controllerTaskIntent
  $projects = @($Manifest.projectBindings)
  $queues = @()
  if ($version -ge 2) { $queues = @($Manifest.dispatchQueues) }
  $taskSetId = if ($version -eq 3) { [string]$Manifest.taskSetId } else { $null }
  $taskSetReset = if ($version -eq 3) { $Manifest.taskSetReset } else { $null }
  $resetOperations = @(
    'prepare-task-set-reset','record-task-set-creation-issued','record-task-set-client-thread','record-task-set-replacement','record-task-set-bootstrap-proof','record-task-set-final-evidence','record-task-set-standby-proof',
    'record-task-set-runtime-prepared','switch-task-set','record-task-set-runtime-committed',
    'record-task-set-archive','complete-task-set-reset'
  )
  if ($Mutation -in $resetOperations -and $version -ne 3) { throw 'reset-capability' }
  if ($null -ne $taskSetReset -and $taskSetReset.phase -cne 'completed' -and $Mutation -notin $resetOperations) { throw 'reset' }
  switch -CaseSensitive ($Mutation) {
    'prepare-task-set-reset' {
      $payload = Convert-Payload $Json @('operationId','planHash','initialEvidenceHash','fromTaskSetId','toTaskSetId','coordinator','expectedController','expectedProjectBindings','targets','initialActiveChains','initialExternalQuiescence','preparedAt')
      foreach ($field in @('operationId','fromTaskSetId','toTaskSetId')) { if (-not (Test-ControllerText $payload.$field 200)) { throw 'payload' } }
      try{$history=Read-TaskSetResetHistory $Root}catch{throw 'state'}
      if(@($history.Items|Where-Object{$_.record.operationId-ceq$payload.operationId}).Count-ne0){throw 'state'}
      if (-not (Test-Hash $payload.planHash) -or-not(Test-Hash $payload.initialEvidenceHash)-or $payload.toTaskSetId -cne (Get-NextTaskSetId $Root $payload.fromTaskSetId $payload.operationId) -or -not (Test-UtcIso8601 $payload.preparedAt)) { throw 'payload' }
      $coordinator=try{Convert-TaskSetCoordinator $payload.coordinator 'payload'}catch{throw 'payload'}
      $expectedController = try { Convert-ControllerBinding $payload.expectedController $Root } catch { throw 'payload' }
      $expectedProjects = try { @(Convert-ProjectBindings $payload.expectedProjectBindings $Root) } catch { throw 'payload' }
      if ($null -eq $expectedController -or $expectedProjects.Count -ne $projects.Count) { throw 'project' }
      if ($payload.targets -isnot [Array] -or @($payload.targets).Count -ne ($projects.Count + 1) -or
          $payload.initialActiveChains -isnot [Array] -or @($payload.initialActiveChains).Count -gt 1000) { throw 'payload' }
      $targetKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      $creationIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      $inputTargets = @()
      foreach ($target in @($payload.targets)) {
        if (-not (Test-ClosedObject $target @('kind','projectRoot','creationOperationId','expectedCodexProjectId','expectedHostId','handoff')) -or $target.kind -cnotin @('controller','project') -or
            -not (Test-NormalizedWindowsRoot $target.projectRoot) -or -not (Test-ControllerText $target.creationOperationId 200) -or
            -not(Test-ControllerText $target.expectedCodexProjectId 200)-or-not(Test-ControllerText $target.expectedHostId 200)-or
            -not $targetKeys.Add(([string]$target.kind + "`n" + [string]$target.projectRoot)) -or -not $creationIds.Add([string]$target.creationOperationId)) { throw 'payload' }
        $handoff=try{Convert-TaskSetHandoff $target.handoff 'payload'}catch{throw 'payload'}
        if($null-eq$handoff){throw 'payload'}
        $inputTargets += [pscustomobject][ordered]@{kind=[string]$target.kind;projectRoot=[string]$target.projectRoot;creationOperationId=[string]$target.creationOperationId;expectedCodexProjectId=[string]$target.expectedCodexProjectId;expectedHostId=[string]$target.expectedHostId;handoff=$handoff}
      }
      $orderedTargets = @()
      foreach ($definition in @([pscustomobject]@{ kind='controller'; projectRoot=$Root }) + @($projects | ForEach-Object { [pscustomobject]@{ kind='project'; projectRoot=$_.projectRoot } })) {
        $target = @($inputTargets | Where-Object { $_.kind -ceq $definition.kind -and $_.projectRoot -ceq $definition.projectRoot })
        if ($target.Count -ne 1) { throw 'payload' }
        $orderedTargets += [pscustomobject][ordered]@{
          kind=[string]$definition.kind; projectRoot=[string]$definition.projectRoot; creationOperationId=[string]$target[0].creationOperationId
          expectedCodexProjectId=[string]$target[0].expectedCodexProjectId;expectedHostId=[string]$target[0].expectedHostId
           initialHandoff=$target[0].handoff;finalHandoff=$null;creationIssuedAt=$null;clientThreadId=$null;replacement=$null;bootstrapProof=$null;standbyProof=$null
        }
      }
      $chains = @(); $chainIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      foreach ($chain in @($payload.initialActiveChains)) {
        if (-not (Test-ClosedObject $chain @('chainId','expectedEntryHash')) -or -not (Test-ControllerText $chain.chainId 200) -or
            -not (Test-Hash $chain.expectedEntryHash) -or -not $chainIds.Add([string]$chain.chainId)) { throw 'payload' }
        $chains += [pscustomobject][ordered]@{ chainId=[string]$chain.chainId; expectedEntryHash=[string]$chain.expectedEntryHash }
      }
      $computedPlanHash=Get-TaskSetPlanHash $payload.operationId $payload.fromTaskSetId $payload.toTaskSetId $coordinator $expectedController $expectedProjects $orderedTargets
      if($computedPlanHash-cne$payload.planHash){throw 'payload-plan-hash'}
      $oldThreadIds=@([string]$expectedController.threadId)+@($expectedProjects|ForEach-Object{[string]$_.entryThreadId})
      if($coordinator.threadId-in$oldThreadIds){throw 'state'}
      foreach($target in $orderedTargets){$expected=if($target.kind-ceq'controller'){$expectedController}else{@($expectedProjects|Where-Object{$_.projectRoot-ceq$target.projectRoot})[0]};if($target.expectedCodexProjectId-cne$expected.codexProjectId-or$target.expectedHostId-cne$expected.hostId){throw 'project'}}
      foreach($project in $projects){$expected=@($expectedProjects|Where-Object{$_.projectRoot-ceq$project.projectRoot});if($expected.Count-ne1-or$expected[0].entryThreadId-cne$project.entryThreadId-or$expected[0].codexProjectId-cne$project.codexProjectId-or$expected[0].hostId-cne$project.hostId){throw 'project'}}
      try{$externalQuiescence=Convert-ExternalQuiescence $payload.initialExternalQuiescence $Root 'payload'}catch{if($_.Exception.Message-ceq'state'){throw 'state'};throw 'payload-quiescence'}
      $runtime=$externalQuiescence.runtimeReadback
      $expectedFenceManifestHash=if($null-ne$taskSetReset-and$taskSetReset.operationId-ceq$payload.operationId-and$taskSetReset.planHash-ceq$payload.planHash){$taskSetReset.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash}else{$CurrentHash}
      if($runtime.fenceState-cne'prepared'-or$runtime.fenceOperationId-cne$payload.operationId-or$runtime.fencePlanHash-cne$payload.planHash-or
         $runtime.fenceManifestExpectedHash-cne$expectedFenceManifestHash-or$runtime.replacementState-cnotin@('none','legacy')-or
         $runtime.controllerThreadId-cne$expectedController.threadId-or$runtime.hostId-cne$expectedController.hostId-or
         -not(Test-TimeOnOrAfter $externalQuiescence.observedAt $runtime.fencePreparedAt)){throw 'state'}
      foreach($target in $orderedTargets){if(-not(Test-TimeOnOrAfter $externalQuiescence.observedAt $target.initialHandoff.observedAt)){throw 'payload'}}
      if(-not(Test-TimeOnOrAfter $payload.preparedAt $externalQuiescence.observedAt)){throw 'payload'}
      if((Get-TaskSetEvidenceHash $orderedTargets 'initialHandoff' $chains $externalQuiescence @())-cne$payload.initialEvidenceHash){throw 'payload'}
      $desiredReset = [pscustomobject][ordered]@{
        operationId=[string]$payload.operationId; planHash=[string]$payload.planHash;initialEvidenceHash=[string]$payload.initialEvidenceHash;finalEvidenceHash=$null; fromTaskSetId=[string]$payload.fromTaskSetId; toTaskSetId=[string]$payload.toTaskSetId; phase='prepared'
        coordinator=$coordinator;expectedController=$expectedController; expectedProjectBindings=@($expectedProjects); targets=@($orderedTargets); initialActiveChains=@($chains);initialExternalQuiescence=$externalQuiescence;finalActiveChains=$null;finalExternalQuiescence=$null
        replacementSetHash=$null; runtimePrepared=$null; runtimeCommitted=$null; archives=@()
        preparedAt=[string]$payload.preparedAt;finalizedAt=$null; switchedAt=$null; completedAt=$null
      }
      if ($null -ne $taskSetReset) {
        $existingCore = [pscustomobject][ordered]@{
          operationId=$taskSetReset.operationId; planHash=$taskSetReset.planHash;initialEvidenceHash=$taskSetReset.initialEvidenceHash; fromTaskSetId=$taskSetReset.fromTaskSetId; toTaskSetId=$taskSetReset.toTaskSetId
          coordinator=$taskSetReset.coordinator;expectedController=$taskSetReset.expectedController; expectedProjectBindings=$taskSetReset.expectedProjectBindings
          targets=@($taskSetReset.targets | ForEach-Object { [pscustomobject][ordered]@{kind=$_.kind;projectRoot=$_.projectRoot;creationOperationId=$_.creationOperationId;expectedCodexProjectId=$_.expectedCodexProjectId;expectedHostId=$_.expectedHostId;initialHandoff=$_.initialHandoff;finalHandoff=$null;creationIssuedAt=$null;clientThreadId=$null;replacement=$null;bootstrapProof=$null;standbyProof=$null} })
          initialActiveChains=$taskSetReset.initialActiveChains;initialExternalQuiescence=$taskSetReset.initialExternalQuiescence; preparedAt=$taskSetReset.preparedAt
        }
        $desiredCore = [pscustomobject][ordered]@{
          operationId=$desiredReset.operationId; planHash=$desiredReset.planHash;initialEvidenceHash=$desiredReset.initialEvidenceHash; fromTaskSetId=$desiredReset.fromTaskSetId; toTaskSetId=$desiredReset.toTaskSetId
          coordinator=$desiredReset.coordinator;expectedController=$desiredReset.expectedController; expectedProjectBindings=$desiredReset.expectedProjectBindings; targets=$desiredReset.targets
          initialActiveChains=$desiredReset.initialActiveChains;initialExternalQuiescence=$desiredReset.initialExternalQuiescence; preparedAt=$desiredReset.preparedAt
        }
        if (Test-CanonicalValueEqual $existingCore $desiredCore) { break }
        if ($taskSetReset.phase -cne 'completed') { throw 'state' }
      }
      if ($payload.fromTaskSetId -cne $taskSetId -or $payload.toTaskSetId -ceq $taskSetId -or
          $null -eq $binding -or $null -ne $intent -or $binding.threadId -cne $expectedController.threadId -or
          $binding.codexProjectId -cne $expectedController.codexProjectId -or $binding.hostId -cne $expectedController.hostId -or
          $binding.projectRoot -cne $expectedController.projectRoot -or
          @($queues | Where-Object { $null -ne $_.active -or @($_.pending).Count -gt 0 }).Count -gt 0) { throw 'state' }
      foreach ($project in $projects) {
        $expected = @($expectedProjects | Where-Object { $_.projectRoot -ceq $project.projectRoot })
        if ($expected.Count -ne 1 -or $expected[0].entryThreadId -cne $project.entryThreadId -or
            $expected[0].codexProjectId -cne $project.codexProjectId -or $expected[0].hostId -cne $project.hostId) { throw 'project' }
      }
      Assert-ActiveChainHeads -Root $Root -Chains @($chains) -RetiredIdentifiers (@($oldThreadIds)+@([string]$payload.fromTaskSetId))
      $taskSetReset = $desiredReset
    }
    'record-task-set-creation-issued' {
      $payload=Convert-Payload $Json @('operationId','kind','projectRoot','creationOperationId','issuedAt')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or$payload.kind-cnotin@('controller','project')-or
         -not(Test-NormalizedWindowsRoot $payload.projectRoot)-or-not(Test-ControllerText $payload.creationOperationId 200)-or-not(Test-UtcIso8601 $payload.issuedAt)){throw 'state'}
      $target=@($taskSetReset.targets|Where-Object{$_.kind-ceq$payload.kind-and$_.projectRoot-ceq$payload.projectRoot})
      if($target.Count-ne1-or$target[0].creationOperationId-cne$payload.creationOperationId-or-not(Test-TimeOnOrAfter $payload.issuedAt $taskSetReset.preparedAt)){throw 'state'}
      if($null-ne$target[0].creationIssuedAt){if($target[0].creationIssuedAt-cne$payload.issuedAt){throw 'state'};break}
      if($taskSetReset.phase-cne'prepared'-or$null-ne$target[0].clientThreadId-or$null-ne$target[0].replacement){throw 'state'}
      if($payload.kind-ceq'controller'-and@($taskSetReset.targets|Where-Object{$_.kind-ceq'project'-and$null-eq$_.creationIssuedAt}).Count-gt0){throw 'state'}
      $target[0].creationIssuedAt=[string]$payload.issuedAt
    }
    'record-task-set-client-thread' {
      $payload = Convert-Payload $Json @('operationId','kind','projectRoot','clientThreadId')
      if ($null -eq $taskSetReset -or $taskSetReset.operationId -cne $payload.operationId -or
          $payload.kind -cnotin @('controller','project') -or -not (Test-NormalizedWindowsRoot $payload.projectRoot) -or
          -not (Test-ControllerText $payload.clientThreadId 200)) { throw 'state' }
      $target = @($taskSetReset.targets | Where-Object { $_.kind -ceq $payload.kind -and $_.projectRoot -ceq $payload.projectRoot })
      if ($target.Count -ne 1 -or $null -eq $target[0].initialHandoff -or $null -eq $target[0].creationIssuedAt) { throw 'state' }
      if (@($taskSetReset.targets | Where-Object { $null -ne $_.clientThreadId -and $_.clientThreadId -ceq $payload.clientThreadId -and $_.projectRoot -cne $payload.projectRoot }).Count -gt 0) { throw 'state' }
      if ($null -ne $target[0].clientThreadId) {
        if ($target[0].clientThreadId -cne $payload.clientThreadId) { throw 'state' }
        break
      }
      if ($taskSetReset.phase -cne 'prepared') { throw 'state' }
      if ($payload.kind -ceq 'controller' -and @($taskSetReset.targets | Where-Object { $_.kind -ceq 'project' -and $null -eq $_.replacement }).Count -gt 0) { throw 'state' }
      $target[0].clientThreadId = [string]$payload.clientThreadId
    }
    'record-task-set-replacement' {
      $payload = Convert-Payload $Json @('operationId','kind','projectRoot','threadId','codexProjectId','hostId')
      foreach ($field in @('threadId','codexProjectId','hostId')) { if (-not (Test-ControllerText $payload.$field 200)) { throw 'payload' } }
      if ($null -eq $taskSetReset -or $taskSetReset.operationId -cne $payload.operationId -or
          $payload.kind -cnotin @('controller','project') -or -not (Test-NormalizedWindowsRoot $payload.projectRoot)) { throw 'state' }
      $target = @($taskSetReset.targets | Where-Object { $_.kind -ceq $payload.kind -and $_.projectRoot -ceq $payload.projectRoot })
      if ($target.Count -ne 1 -or $null -eq $target[0].initialHandoff -or $null -eq $target[0].creationIssuedAt) { throw 'state' }
      $expected = if ($payload.kind -ceq 'controller') { $taskSetReset.expectedController } else { @($taskSetReset.expectedProjectBindings | Where-Object { $_.projectRoot -ceq $payload.projectRoot })[0] }
      $oldThreadIds = @([string]$taskSetReset.expectedController.threadId) + @($taskSetReset.expectedProjectBindings | ForEach-Object { [string]$_.entryThreadId })
      if ($payload.codexProjectId -cne $expected.codexProjectId -or $payload.hostId -cne $expected.hostId -or $payload.threadId -ceq $taskSetReset.coordinator.threadId -or $payload.threadId -in $oldThreadIds -or
          @($taskSetReset.targets | Where-Object { $null -ne $_.replacement -and $_.replacement.threadId -ceq $payload.threadId -and $_.projectRoot -cne $payload.projectRoot }).Count -gt 0) { throw 'state' }
      $replacement = [pscustomobject][ordered]@{
        threadId=[string]$payload.threadId; codexProjectId=[string]$payload.codexProjectId; hostId=[string]$payload.hostId; projectRoot=[string]$payload.projectRoot
      }
      if ($null -ne $target[0].replacement) {
        if (-not (Test-CanonicalValueEqual $target[0].replacement $replacement)) { throw 'state' }
        break
      }
      if ($taskSetReset.phase -cne 'prepared') { throw 'state' }
      if ($payload.kind -ceq 'controller' -and @($taskSetReset.targets | Where-Object { $_.kind -ceq 'project' -and $null -eq $_.replacement }).Count -gt 0) { throw 'state' }
      $target[0].replacement = $replacement
      if (@($taskSetReset.targets | Where-Object { $null -eq $_.replacement }).Count -eq 0) {
        $taskSetReset.replacementSetHash = Get-TaskSetReplacementHash $taskSetReset.targets
      }
    }
    'record-task-set-bootstrap-proof' {
      $payload=Convert-Payload $Json @('operationId','kind','projectRoot','bootstrapProof')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or$payload.kind-cnotin@('controller','project')-or-not(Test-NormalizedWindowsRoot $payload.projectRoot)){throw 'state'}
      $target=@($taskSetReset.targets|Where-Object{$_.kind-ceq$payload.kind-and$_.projectRoot-ceq$payload.projectRoot})
      if($target.Count-ne1-or$null-eq$target[0].replacement-or$null-eq$target[0].creationIssuedAt){throw 'state'}
      $proof=try{Convert-BootstrapProof $payload.bootstrapProof 'payload'}catch{throw 'payload'}
      if($null-ne$target[0].bootstrapProof){if(-not(Test-CanonicalValueEqual $target[0].bootstrapProof $proof)){throw 'state'};break}
      if($taskSetReset.phase-cne'prepared'-or$proof.threadId-cne$target[0].replacement.threadId-or$proof.codexProjectId-cne$target[0].replacement.codexProjectId-or$proof.hostId-cne$target[0].replacement.hostId-or$proof.projectRoot-cne$target[0].projectRoot-or$proof.creationOperationId-cne$target[0].creationOperationId-or-not(Test-TimeOnOrAfter $proof.observedAt $target[0].creationIssuedAt)){throw 'state'}
      if($payload.kind-ceq'controller'-and(@($taskSetReset.targets|Where-Object{$_.kind-ceq'project'-and$null-eq$_.bootstrapProof}).Count-gt0-or@($taskSetReset.targets|Where-Object{$_.kind-ceq'project'-and-not(Test-TimeOnOrAfter $proof.observedAt $_.bootstrapProof.observedAt)}).Count-gt0)){throw 'state'}
      $target[0].bootstrapProof=$proof
    }
    'record-task-set-standby-proof' {
      $payload=Convert-Payload $Json @('operationId','kind','projectRoot','standbyProof')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or$payload.kind-cnotin@('controller','project')-or-not(Test-NormalizedWindowsRoot $payload.projectRoot)){throw 'state'}
      $target=@($taskSetReset.targets|Where-Object{$_.kind-ceq$payload.kind-and$_.projectRoot-ceq$payload.projectRoot})
      if($target.Count-ne1-or$null-eq$target[0].replacement){throw 'state'}
      $standby=try{Convert-StandbyProof $payload.standbyProof 'payload'}catch{throw 'payload'}
      $replacement=$target[0].replacement;$handoff=$target[0].finalHandoff
      if($null-ne$target[0].standbyProof){if(-not(Test-CanonicalValueEqual $target[0].standbyProof $standby)){throw 'state'};break}
      if($taskSetReset.phase-cne'finalized'-or$null-eq$handoff-or$standby.threadId-cne$replacement.threadId-or$standby.codexProjectId-cne$replacement.codexProjectId-or$standby.hostId-cne$replacement.hostId-or$standby.projectRoot-cne$replacement.projectRoot-or
         $standby.summaryHash-cne$handoff.summaryHash-or$standby.historyDigest-cne$handoff.historyDigest-or$standby.newestTurnId-cne$handoff.newestTurnId-or-not(Test-TimeOnOrAfter $standby.observedAt $handoff.observedAt)){throw 'state'}
      if($payload.kind-ceq'controller'-and@($taskSetReset.targets|Where-Object{$_.kind-ceq'project'-and$null-eq$_.standbyProof}).Count-gt0){throw 'state'}
      $target[0].standbyProof=$standby
    }
    'record-task-set-final-evidence' {
      $payload=Convert-Payload $Json @('operationId','targets','activeChains','externalQuiescence','archives','finalEvidenceHash','finalizedAt')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or$taskSetReset.phase-cnotin@('archived','finalized','runtime-prepared','switched','runtime-committed','completed')-or-not(Test-Hash $payload.finalEvidenceHash)-or-not(Test-UtcIso8601 $payload.finalizedAt)-or$payload.targets-isnot[Array]-or@($payload.targets).Count-ne@($taskSetReset.targets).Count-or$payload.activeChains-isnot[Array]-or$payload.archives-isnot[Array]){throw 'state'}
      if(-not(Test-CanonicalValueEqual @($payload.archives) @($taskSetReset.archives))){throw 'state'}
      $chains=@();$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      foreach($chain in @($payload.activeChains)){if(-not(Test-ClosedObject $chain @('chainId','expectedEntryHash'))-or-not(Test-ControllerText $chain.chainId 200)-or-not(Test-Hash $chain.expectedEntryHash)-or-not$ids.Add([string]$chain.chainId)){throw 'payload'};$chains+=[pscustomobject][ordered]@{chainId=[string]$chain.chainId;expectedEntryHash=[string]$chain.expectedEntryHash}}
      try{$quiet=Convert-ExternalQuiescence $payload.externalQuiescence $Root 'payload'}catch{if($_.Exception.Message-ceq'state'){throw 'state'};throw 'payload'}
      $finalRuntime=$quiet.runtimeReadback;$initialRuntime=$taskSetReset.initialExternalQuiescence.runtimeReadback
      if(-not(Test-CanonicalValueEqual @($chains) @($taskSetReset.initialActiveChains))-or$finalRuntime.fenceState-cne'prepared'-or
         $finalRuntime.fenceOperationId-cne$taskSetReset.operationId-or$finalRuntime.fencePlanHash-cne$taskSetReset.planHash-or
         $finalRuntime.fenceManifestExpectedHash-cne$initialRuntime.fenceManifestExpectedHash-or$finalRuntime.fencePreparedAt-cne$initialRuntime.fencePreparedAt-or
         $finalRuntime.replacementState-cnotin@('none','legacy')-or$finalRuntime.controllerThreadId-cne$taskSetReset.expectedController.threadId-or$finalRuntime.hostId-cne$taskSetReset.expectedController.hostId){throw 'state'}
      $finalTargets=@()
      foreach($targetInput in @($payload.targets)){
        if(-not(Test-ClosedObject $targetInput @('kind','projectRoot','handoff'))-or$targetInput.kind-cnotin@('controller','project')-or-not(Test-NormalizedWindowsRoot $targetInput.projectRoot)){throw 'payload'}
        $stored=@($taskSetReset.targets|Where-Object{$_.kind-ceq$targetInput.kind-and$_.projectRoot-ceq$targetInput.projectRoot});if($stored.Count-ne1){throw 'state'}
        $handoff=try{Convert-TaskSetHandoff $targetInput.handoff 'payload'}catch{throw 'payload'}
        $archive=@($taskSetReset.archives|Where-Object{$_.kind-ceq$stored[0].kind-and$_.snapshot.projectRoot-ceq$stored[0].projectRoot})
        if($archive.Count-ne1-or$handoff.oldestTurnId-cne$archive[0].snapshot.history.oldestTurnId-or$handoff.newestTurnId-cne$archive[0].snapshot.history.newestTurnId-or$handoff.turnCount-ne$archive[0].snapshot.history.turnCount-or$handoff.historyDigest-cne$archive[0].snapshot.history.historyDigest-or-not(Test-TimeOnOrAfter $handoff.observedAt $archive[0].archivedAt)-or-not(Test-TimeOnOrAfter $quiet.observedAt $handoff.observedAt)){throw 'state'}
        $clone=[pscustomobject][ordered]@{
          kind=$stored[0].kind;projectRoot=$stored[0].projectRoot;creationOperationId=$stored[0].creationOperationId
          expectedCodexProjectId=$stored[0].expectedCodexProjectId;expectedHostId=$stored[0].expectedHostId
          initialHandoff=$stored[0].initialHandoff;finalHandoff=$handoff;creationIssuedAt=$stored[0].creationIssuedAt;clientThreadId=$stored[0].clientThreadId
          replacement=$stored[0].replacement;bootstrapProof=$stored[0].bootstrapProof;standbyProof=$stored[0].standbyProof
        }
        $finalTargets+=$clone
      }
      $ordered=@();foreach($stored in $taskSetReset.targets){$item=@($finalTargets|Where-Object{$_.kind-ceq$stored.kind-and$_.projectRoot-ceq$stored.projectRoot});if($item.Count-ne1){throw 'state'};$ordered+=$item[0]}
      if((Get-TaskSetEvidenceHash $ordered 'finalHandoff' $chains $quiet $taskSetReset.archives)-cne$payload.finalEvidenceHash){throw 'payload'}
      $retired=@([string]$taskSetReset.expectedController.threadId)+@($taskSetReset.expectedProjectBindings|ForEach-Object{[string]$_.entryThreadId})+@([string]$taskSetReset.fromTaskSetId)
      Assert-ActiveChainHeads -Root $Root -Chains @($chains) -RetiredIdentifiers @($retired)
      if($taskSetReset.phase-cne'archived'){
        if($taskSetReset.finalEvidenceHash-cne$payload.finalEvidenceHash-or$taskSetReset.finalizedAt-cne$payload.finalizedAt-or
           -not(Test-CanonicalValueEqual @($taskSetReset.finalActiveChains) @($chains))-or-not(Test-CanonicalValueEqual $taskSetReset.finalExternalQuiescence $quiet)){throw 'state'}
        foreach($target in $ordered){$stored=@($taskSetReset.targets|Where-Object{$_.kind-ceq$target.kind-and$_.projectRoot-ceq$target.projectRoot});if($stored.Count-ne1-or-not(Test-CanonicalValueEqual $stored[0].finalHandoff $target.finalHandoff)){throw 'state'}}
        break
      }
      $taskSetReset.targets=@($ordered);$taskSetReset.finalActiveChains=@($chains);$taskSetReset.finalExternalQuiescence=$quiet;$taskSetReset.finalEvidenceHash=[string]$payload.finalEvidenceHash;$taskSetReset.finalizedAt=[string]$payload.finalizedAt;$taskSetReset.phase='finalized'
    }
    'record-task-set-runtime-prepared' {
      $payload=Convert-Payload $Json @('operationId','runtimeReadback','runtimeReadbackHash')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or-not(Test-Hash $payload.runtimeReadbackHash)){throw 'state'}
      $readback=try{Convert-RuntimeReadback $payload.runtimeReadback $Root 'payload'}catch{throw 'payload'}
      if((Get-Hash $utf8.GetBytes(($readback|ConvertTo-Json -Depth 20 -Compress)))-cne$payload.runtimeReadbackHash){throw 'payload'}
      $evidence=[pscustomobject][ordered]@{runtimeReadback=$readback;runtimeReadbackHash=[string]$payload.runtimeReadbackHash}
      if ($null -ne $taskSetReset.runtimePrepared) {
        if (-not (Test-CanonicalValueEqual $taskSetReset.runtimePrepared $evidence)) { throw 'state' }
        break
      }
      $controllerTarget=@($taskSetReset.targets|Where-Object{$_.kind-ceq'controller'})[0]
      if($taskSetReset.phase-cne'finalized'-or@($taskSetReset.targets|Where-Object{$null-eq$_.replacement-or$null-eq$_.standbyProof}).Count-gt0-or$readback.replacementState-cne'prepared'-or
         $readback.fenceState-cne'prepared'-or$readback.fenceOperationId-cne$taskSetReset.operationId-or$readback.fencePlanHash-cne$taskSetReset.planHash-or$readback.fenceManifestExpectedHash-cne$taskSetReset.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash-or
         $readback.operationId-cne$taskSetReset.operationId-or$readback.replacementSetHash-cne$taskSetReset.replacementSetHash-or$readback.manifestPreparedHash-cne$CurrentHash-or
         $readback.oldControllerThreadId-cne$taskSetReset.expectedController.threadId-or$readback.oldHostId-cne$taskSetReset.expectedController.hostId-or
         $readback.newControllerThreadId-cne$controllerTarget.replacement.threadId-or$readback.newHostId-cne$controllerTarget.replacement.hostId-or
          -not(Test-TimeOnOrAfter $readback.preparedAt $taskSetReset.finalizedAt)){throw 'state'}
      foreach($target in $taskSetReset.targets){if($null-ne$target.standbyProof-and-not(Test-TimeOnOrAfter $readback.preparedAt $target.standbyProof.observedAt)){throw 'state'}}
      $taskSetReset.runtimePrepared = $evidence; $taskSetReset.phase = 'runtime-prepared'
    }
    'switch-task-set' {
      $payload = Convert-Payload $Json @('operationId','replacementSetHash','runtimePrepareToken','switchedAt')
      if ($null -eq $taskSetReset -or $taskSetReset.operationId -cne $payload.operationId -or -not (Test-UtcIso8601 $payload.switchedAt) -or
          $payload.replacementSetHash -cne $taskSetReset.replacementSetHash -or $payload.runtimePrepareToken -cne $taskSetReset.runtimePrepared.runtimeReadback.prepareToken -or
          -not (Test-TimeOnOrAfter $payload.switchedAt $taskSetReset.runtimePrepared.runtimeReadback.preparedAt)) { throw 'state' }
      if ($taskSetReset.phase -in @('switched','runtime-committed','archiving','completed')) {
        if ($taskSetReset.switchedAt -cne $payload.switchedAt) { throw 'state' }
        break
      }
      if ($taskSetReset.phase -cne 'runtime-prepared' -or @($taskSetReset.targets|Where-Object{$null-eq$_.standbyProof}).Count-gt0) { throw 'state' }
      $controllerTarget = @($taskSetReset.targets | Where-Object { $_.kind -ceq 'controller' })[0]
      $binding = [pscustomobject][ordered]@{
        threadId=[string]$controllerTarget.replacement.threadId; codexProjectId=[string]$controllerTarget.replacement.codexProjectId
        hostId=[string]$controllerTarget.replacement.hostId; projectRoot=[string]$controllerTarget.projectRoot
      }
      for ($index = 0; $index -lt $projects.Count; $index++) {
        $target = @($taskSetReset.targets | Where-Object { $_.kind -ceq 'project' -and $_.projectRoot -ceq $projects[$index].projectRoot })[0]
        $projects[$index] = [pscustomobject][ordered]@{
          entryThreadId=[string]$target.replacement.threadId; codexProjectId=[string]$target.replacement.codexProjectId
          hostId=[string]$target.replacement.hostId; projectRoot=[string]$target.projectRoot
        }
      }
      $taskSetId=[string]$taskSetReset.toTaskSetId; $taskSetReset.phase='switched'; $taskSetReset.switchedAt=[string]$payload.switchedAt
    }
    'record-task-set-runtime-committed' {
      $payload=Convert-Payload $Json @('operationId','runtimeReadback','runtimeReadbackHash')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or-not(Test-Hash $payload.runtimeReadbackHash)){throw 'state'}
      $readback=try{Convert-RuntimeReadback $payload.runtimeReadback $Root 'payload'}catch{throw 'payload'}
      if((Get-Hash $utf8.GetBytes(($readback|ConvertTo-Json -Depth 20 -Compress)))-cne$payload.runtimeReadbackHash){throw 'payload'}
      $evidence=[pscustomobject][ordered]@{runtimeReadback=$readback;runtimeReadbackHash=[string]$payload.runtimeReadbackHash}
      if ($null -ne $taskSetReset.runtimeCommitted) {
        if (-not (Test-CanonicalValueEqual $taskSetReset.runtimeCommitted $evidence)) { throw 'state' }
        break
      }
      $prepared=$taskSetReset.runtimePrepared.runtimeReadback
      if($taskSetReset.phase-cne'switched'-or$readback.replacementState-cne'committed'-or$readback.operationId-cne$taskSetReset.operationId-or
         $readback.fenceState-cne'prepared'-or$readback.fenceOperationId-cne$taskSetReset.operationId-or$readback.fencePlanHash-cne$taskSetReset.planHash-or$readback.fenceManifestExpectedHash-cne$taskSetReset.initialExternalQuiescence.runtimeReadback.fenceManifestExpectedHash-or
         $readback.replacementSetHash-cne$taskSetReset.replacementSetHash-or$readback.manifestSwitchedHash-cne$CurrentHash-or
         $readback.oldControllerThreadId-cne$prepared.oldControllerThreadId-or$readback.oldHostId-cne$prepared.oldHostId-or
         $readback.newControllerThreadId-cne$prepared.newControllerThreadId-or$readback.newHostId-cne$prepared.newHostId-or
         $readback.manifestPreparedHash-cne$prepared.manifestPreparedHash-or$readback.prepareToken-cne$prepared.prepareToken-or
         $readback.preparedAt-cne$prepared.preparedAt-or-not(Test-TimeOnOrAfter $readback.committedAt $taskSetReset.switchedAt)){throw 'state'}
      $taskSetReset.runtimeCommitted=$evidence; $taskSetReset.phase='runtime-committed'
    }
    'record-task-set-archive' {
      $payload=Convert-Payload $Json @('operationId','kind','snapshot','snapshotHash','archivedAt')
      if($null-eq$taskSetReset-or$taskSetReset.operationId-cne$payload.operationId-or$payload.kind-cnotin@('controller','project')-or-not(Test-Hash $payload.snapshotHash)-or-not(Test-UtcIso8601 $payload.archivedAt)){throw 'state'}
      $snapshot=try{Convert-ArchiveSnapshot $payload.snapshot 'payload'}catch{throw 'payload'}
      if((Get-Hash $utf8.GetBytes(($snapshot|ConvertTo-Json -Depth 10 -Compress)))-cne$payload.snapshotHash){throw 'payload'}
      $expected=if($payload.kind-ceq'controller'){$taskSetReset.expectedController}else{@($taskSetReset.expectedProjectBindings|Where-Object{$_.projectRoot-ceq$snapshot.projectRoot})[0]}
      $expectedThread=if($payload.kind-ceq'controller'){$expected.threadId}else{$expected.entryThreadId}
      $target=@($taskSetReset.targets|Where-Object{$_.kind-ceq$payload.kind-and$_.projectRoot-ceq$snapshot.projectRoot})
      if($null-eq$expected-or$target.Count-ne1-or$null-eq$target[0].bootstrapProof-or-not(Test-TimeOnOrAfter $payload.archivedAt $target[0].bootstrapProof.observedAt)-or
         $snapshot.threadId-cne$expectedThread-or$snapshot.codexProjectId-cne$expected.codexProjectId-or$snapshot.hostId-cne$expected.hostId-or$snapshot.projectRoot-cne$expected.projectRoot){throw 'state'}
      $evidence=[pscustomobject][ordered]@{kind=[string]$payload.kind;snapshot=$snapshot;snapshotHash=[string]$payload.snapshotHash;archivedAt=[string]$payload.archivedAt}
      $existing=@($taskSetReset.archives|Where-Object{$_.kind-ceq$payload.kind-and$_.snapshot.projectRoot-ceq$snapshot.projectRoot})
      if ($existing.Count -eq 1) {
        if (-not (Test-CanonicalValueEqual $existing[0] $evidence)) { throw 'state' }
        break
      }
      if($taskSetReset.phase-notin@('prepared','archiving')-or$existing.Count-ne0-or-not(Test-TimeOnOrAfter $payload.archivedAt $taskSetReset.preparedAt)-or@($taskSetReset.targets|Where-Object{$null-eq$_.bootstrapProof}).Count-gt0){throw 'state'}
      $retired=@([string]$taskSetReset.expectedController.threadId)+@($taskSetReset.expectedProjectBindings|ForEach-Object{[string]$_.entryThreadId})+@([string]$taskSetReset.fromTaskSetId)
      Assert-ActiveChainHeads -Root $Root -Chains @($taskSetReset.initialActiveChains) -RetiredIdentifiers @($retired)
      if ($payload.kind -ceq 'controller' -and @($taskSetReset.expectedProjectBindings | Where-Object {
        $root=[string]$_.projectRoot; @($taskSetReset.archives | Where-Object { $_.kind -ceq 'project' -and $_.snapshot.projectRoot -ceq $root }).Count -ne 1
      }).Count -gt 0) { throw 'state' }
      if ($payload.kind -ceq 'controller' -and @($taskSetReset.archives | Where-Object {
        $_.kind -ceq 'project' -and -not (Test-TimeOnOrAfter $payload.archivedAt $_.archivedAt)
      }).Count -gt 0) { throw 'state' }
      $taskSetReset.archives=@($taskSetReset.archives)+@($evidence); $taskSetReset.phase=if(@($taskSetReset.archives).Count-eq@($taskSetReset.targets).Count){'archived'}else{'archiving'}
    }
    'complete-task-set-reset' {
      $payload = Convert-Payload $Json @('operationId','completedAt')
      if(-not(Test-UtcIso8601 $payload.completedAt)){throw 'state'}
      if($null-eq$taskSetReset){
        $sealed=try{Read-TaskSetResetHistory $Root}catch{throw 'state'}
        $existing=@($sealed.Items|Where-Object{$_.record.operationId-ceq$payload.operationId})
        if($existing.Count-ne1-or$existing[0].record.completedAt-cne$payload.completedAt){throw 'state'}
        break
      }
      if($taskSetReset.operationId-cne$payload.operationId){throw 'state'}
      if ($taskSetReset.phase -ceq 'completed') {
        if ($taskSetReset.completedAt -cne $payload.completedAt) { throw 'state' }
        break
      }
      if ($taskSetReset.phase -cne 'runtime-committed' -or $null -eq $taskSetReset.runtimeCommitted) { throw 'state' }
      $retired=@([string]$taskSetReset.expectedController.threadId)+@($taskSetReset.expectedProjectBindings|ForEach-Object{[string]$_.entryThreadId})+@([string]$taskSetReset.fromTaskSetId)
      Assert-ActiveChainHeads -Root $Root -Chains @($taskSetReset.finalActiveChains) -RetiredIdentifiers @($retired)
      if(-not(Test-TimeOnOrAfter $payload.completedAt $taskSetReset.runtimeCommitted.runtimeReadback.committedAt)){throw 'state'}
      $taskSetReset.completedAt=[string]$payload.completedAt; $taskSetReset.phase='completed'
    }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
      if ($version -lt 2) { throw 'migration' }
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
  if ($version -ge 2) { $result.dispatchQueues = @($queues) }
  if ($version -eq 3) { $result.taskSetId = $taskSetId; $result.taskSetReset = $taskSetReset }
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
  if ($Action -cnotin @('Read','ReadTaskSetResetHistory','GetTaskSetResetHistory','RecoverTaskSetResetSeal','PlanTaskSetReset','RuntimeInfo','ExportDispatch','PrepareCandidate','ApplyCandidate','RemoveCandidate')) { Finish-Invalid }
  $sealPath=Get-TaskSetResetSealPath $normalizedRoot
  if($Action-cne'RecoverTaskSetResetSeal'-and(Test-Path -LiteralPath $sealPath)){Finish-Conflict 'controller-task-set-reset-seal-recovery-required' $normalizedRoot}

  if($Action-ceq'RecoverTaskSetResetSeal'){
    if(-not(Test-Path -LiteralPath $sealPath)){Finish-Conflict 'controller-task-set-reset-seal-not-found' $normalizedRoot}
    $runtimeEvidence=$null
    if(-not[string]::IsNullOrWhiteSpace($PayloadJson)){
      try{$runtimeEvidence=Convert-Payload $PayloadJson @('runtimeReadback','runtimeReadbackHash')}catch{Finish-Invalid 'controller-payload-invalid' $normalizedRoot}
    }
    try{$gate=Enter-ControllerMutex $normalizedRoot}catch{Finish-Blocked 'controller-io-failure' $normalizedRoot}
    if(-not$gate.Acquired){$gate.Mutex.Dispose();Finish-Conflict 'controller-mutex-timeout' $normalizedRoot}
    try{
      try{$recovered=Recover-TaskSetResetSeal $normalizedRoot $runtimeEvidence}catch{Finish-Conflict 'controller-task-set-reset-seal-conflict' $normalizedRoot}
      if(-not$recovered.Released){Write-StateResult applied 'controller-task-set-reset-seal-runtime-pending' $normalizedRoot $null $null $null $recovered.Readback.Hash $recovered.Readback.Data 'Complete the matching runtime reset fence with this exact manifest hash, read it back, then rerun recovery with that exact readback packet.' @() 0}
      Write-StateResult applied 'controller-task-set-reset-seal-recovered' $normalizedRoot $null $null $null $recovered.Readback.Hash $recovered.Readback.Data 'The manifest, CHAIN store, and runtime reset fences are verified and ordinary work may resume.' @() 0
    }finally{try{$gate.Mutex.ReleaseMutex()}catch{};$gate.Mutex.Dispose()}
  }

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

  if($Action-in@('ReadTaskSetResetHistory','GetTaskSetResetHistory')){
    try{$current=Read-Manifest $normalizedRoot;$history=Read-TaskSetResetHistory $normalizedRoot}catch{Finish-Conflict 'controller-task-set-reset-history-invalid' $normalizedRoot}
    if($Action-ceq'GetTaskSetResetHistory'){
      try{$payload=Convert-Payload $PayloadJson @('operationId')}catch{Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash}
      if(-not(Test-ControllerText $payload.operationId 200)){Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash}
      $match=@($history.Items|Where-Object{$_.record.operationId-ceq$payload.operationId})
      if($match.Count-ne1){Finish-Conflict 'controller-task-set-reset-history-not-found' $normalizedRoot $current.Hash}
      Write-StateResult verified 'controller-task-set-reset-history-entry-read' $normalizedRoot $current.Hash $null $null $current.Hash $match[0] 'Use this immutable event as reset audit evidence.' @() 0
    }
    $summaries=@($history.Items|ForEach-Object{[pscustomobject][ordered]@{seq=$_.seq;operationId=$_.record.operationId;fromTaskSetId=$_.record.fromTaskSetId;toTaskSetId=$_.record.toTaskSetId;completedAt=$_.record.completedAt;entryHash=$_.entryHash}})
    $head=if($history.Items.Count-eq0){$null}else{[string]$history.Items[-1].entryHash}
    Write-StateResult verified 'controller-task-set-reset-history-read' $normalizedRoot $current.Hash $null $null $current.Hash ([pscustomobject][ordered]@{count=$history.Items.Count;headEntryHash=$head;items=@($summaries)}) 'Use GetTaskSetResetHistory with one operationId for the full immutable event.' @() 0
  }

  if($Action-ceq'PlanTaskSetReset'){
    try{$current=Read-Manifest $normalizedRoot}catch{if($_.Exception.Message-ceq'manifest'){Finish-Conflict 'controller-manifest-invalid' $normalizedRoot};Finish-Blocked 'controller-io-failure' $normalizedRoot}
    if($current.Data.schemaVersion-ne3){Finish-Conflict 'controller-capability-unavailable' $normalizedRoot $current.Hash}
    try{
      $payload=Convert-Payload $PayloadJson @('operationId','fromTaskSetId','toTaskSetId','coordinator','expectedController','expectedProjectBindings','targets')
      foreach($field in @('operationId','fromTaskSetId','toTaskSetId')){if(-not(Test-ControllerText $payload.$field 200)){throw 'payload'}}
      $history=Read-TaskSetResetHistory $normalizedRoot
      if(@($history.Items|Where-Object{$_.record.operationId-ceq$payload.operationId}).Count-ne0){throw 'state'}
      if($payload.toTaskSetId-cne(Get-NextTaskSetId $normalizedRoot $payload.fromTaskSetId $payload.operationId)){throw 'payload'}
      $coordinator=Convert-TaskSetCoordinator $payload.coordinator 'payload';$expectedController=Convert-ControllerBinding $payload.expectedController $normalizedRoot
      $expectedProjects=@(Convert-ProjectBindings $payload.expectedProjectBindings $normalizedRoot)
      if($null-eq$expectedController-or$expectedProjects.Count-ne@($current.Data.projectBindings).Count-or$payload.targets-isnot[Array]-or@($payload.targets).Count-ne($expectedProjects.Count+1)){throw 'payload'}
      $targetKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$creationIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$inputTargets=@()
      foreach($target in @($payload.targets)){
        if(-not(Test-ClosedObject $target @('kind','projectRoot','creationOperationId','expectedCodexProjectId','expectedHostId'))-or$target.kind-cnotin@('controller','project')-or-not(Test-NormalizedWindowsRoot $target.projectRoot)-or
           -not(Test-ControllerText $target.creationOperationId 200)-or-not(Test-ControllerText $target.expectedCodexProjectId 200)-or-not(Test-ControllerText $target.expectedHostId 200)-or
           -not$targetKeys.Add(([string]$target.kind+"`n"+[string]$target.projectRoot))-or-not$creationIds.Add([string]$target.creationOperationId)){throw 'payload'}
        $inputTargets+=[pscustomobject][ordered]@{kind=[string]$target.kind;projectRoot=[string]$target.projectRoot;creationOperationId=[string]$target.creationOperationId;expectedCodexProjectId=[string]$target.expectedCodexProjectId;expectedHostId=[string]$target.expectedHostId}
      }
      $targets=@();foreach($definition in @([pscustomobject]@{kind='controller';projectRoot=$normalizedRoot;expected=$expectedController})+@($expectedProjects|ForEach-Object{[pscustomobject]@{kind='project';projectRoot=$_.projectRoot;expected=$_}})){
        $target=@($inputTargets|Where-Object{$_.kind-ceq$definition.kind-and$_.projectRoot-ceq$definition.projectRoot})
        if($target.Count-ne1-or$target[0].expectedCodexProjectId-cne$definition.expected.codexProjectId-or$target[0].expectedHostId-cne$definition.expected.hostId){throw 'project'}
        $targets+=$target[0]
      }
      $oldThreads=@([string]$expectedController.threadId)+@($expectedProjects|ForEach-Object{[string]$_.entryThreadId})
      if($coordinator.threadId-in$oldThreads-or$payload.fromTaskSetId-cne$current.Data.taskSetId-or$payload.toTaskSetId-ceq$current.Data.taskSetId-or$null-eq$current.Data.controllerBinding-or$null-ne$current.Data.controllerTaskIntent-or
         -not(Test-CanonicalValueEqual $current.Data.controllerBinding $expectedController)-or-not(Test-CanonicalValueEqual @($current.Data.projectBindings) @($expectedProjects))-or@($current.Data.dispatchQueues|Where-Object{$null-ne$_.active-or@($_.pending).Count-gt0}).Count-gt0){throw 'state'}
      $planHash=Get-TaskSetPlanHash $payload.operationId $payload.fromTaskSetId $payload.toTaskSetId $coordinator $expectedController $expectedProjects $targets
      if($null-ne$current.Data.taskSetReset-and$current.Data.taskSetReset.phase-cne'completed'-and$current.Data.taskSetReset.planHash-cne$planHash){throw 'state'}
      $initialActiveChains=@(Get-ActiveChainHeads $normalizedRoot)
      $plan=[pscustomobject][ordered]@{
        operationId=[string]$payload.operationId;fromTaskSetId=[string]$payload.fromTaskSetId;toTaskSetId=[string]$payload.toTaskSetId;coordinator=$coordinator
        expectedController=$expectedController;expectedProjectBindings=@($expectedProjects);targets=@($targets)
      }
    }catch{
      switch -CaseSensitive ($_.Exception.Message){'payload'{Finish-Invalid 'controller-plan-payload-invalid' $normalizedRoot $current.Hash};'payload-quiescence'{Finish-Invalid 'controller-plan-quiescence-invalid' $normalizedRoot $current.Hash};'payload-plan-hash'{Finish-Invalid 'controller-plan-hash-invalid' $normalizedRoot $current.Hash};'project'{Finish-Conflict 'project-binding-conflict' $normalizedRoot $current.Hash};'state'{Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash};default{Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash}}
    }
    Write-StateResult verified 'controller-task-set-reset-planned' $normalizedRoot $current.Hash $null $null $current.Hash ([pscustomobject][ordered]@{planHash=[string]$planHash;plan=$plan;initialActiveChains=@($initialActiveChains)}) 'Authorize Apply with this exact stable planHash, then provide fresh handoffs and quiescence evidence.' @() 0
  }

  if ($Action -ceq 'ExportDispatch') {
    if (-not (Test-Hash $ExpectedHash)) { Finish-Invalid }
    try { $current = Read-Manifest $normalizedRoot }
    catch {
      if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot }
      Finish-Blocked 'controller-io-failure' $normalizedRoot
    }
    if ($current.Hash -cne $ExpectedHash) { Finish-Conflict 'controller-hash-conflict' $normalizedRoot $current.Hash }
    if ($current.Data.schemaVersion -eq 3 -and $null -ne $current.Data.taskSetReset -and $current.Data.taskSetReset.phase -cne 'completed') {
      Finish-Conflict 'controller-task-set-reset-in-progress' $normalizedRoot $current.Hash
    }
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
    try { $gate = Enter-ControllerMutex $normalizedRoot } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot }
    if (-not $gate.Acquired) { $gate.Mutex.Dispose(); Finish-Conflict 'controller-mutex-timeout' $normalizedRoot $null $null $null 'Wait for the current controller writer to finish, then retry.' }
    try {
    if (Test-Path -LiteralPath (Get-TaskSetResetSealPath $normalizedRoot)) { Finish-Conflict 'controller-task-set-reset-seal-recovery-required' $normalizedRoot }
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
    try { $mutated = New-MutatedManifest $current.Data $Operation $PayloadJson $normalizedRoot $current.Hash }
    catch {
      $mutationFailure = $_.Exception.Message
      switch -CaseSensitive ($mutationFailure) {
        'payload' { Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash }
        'payload-quiescence' { Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash }
        'payload-plan-hash' { Finish-Invalid 'controller-payload-invalid' $normalizedRoot $current.Hash }
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
        'reset-capability' { Finish-Conflict 'controller-capability-unavailable' $normalizedRoot $current.Hash }
        'reset' { Finish-Conflict 'controller-task-set-reset-in-progress' $normalizedRoot $current.Hash }
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
    finally {
      try { $gate.Mutex.ReleaseMutex() } catch {}
      $gate.Mutex.Dispose()
    }
  }

  if ($Action -ceq 'ApplyCandidate') {
    if (-not (Test-Hash $ExpectedHash) -or -not (Test-Hash $CandidateHash) -or -not (Test-CandidateArgument $normalizedRoot $CandidatePath)) { Finish-Invalid 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
    try { $candidate = Resolve-Candidate $normalizedRoot $CandidatePath } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
    if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $CandidatePath $CandidateHash }
    try { $candidateBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if ((Get-Hash $candidateBytes) -cne $CandidateHash) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
    try { $candidateValidated = Convert-ManifestBytes $candidateBytes $normalizedRoot } catch { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $candidate $CandidateHash }
    try { $gate = Enter-ControllerMutex $normalizedRoot } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
    if (-not $gate.Acquired) { $gate.Mutex.Dispose(); Finish-Conflict 'controller-mutex-timeout' $normalizedRoot $null $candidate $CandidateHash 'Wait for the current controller writer to finish, then retry.' }
    try {
      try { $candidate = Resolve-Candidate $normalizedRoot $candidate } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $CandidatePath $CandidateHash }
      if ($null -eq $candidate) { Finish-Conflict 'controller-candidate-changed' $normalizedRoot $null $CandidatePath $CandidateHash }
      try { $lockedCandidateBytes = [IO.File]::ReadAllBytes($candidate) } catch { Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash }
      if ((Get-Hash $lockedCandidateBytes) -cne $CandidateHash -or -not (Test-BytesEqual $candidateBytes $lockedCandidateBytes)) { Finish-Conflict 'controller-candidate-hash-mismatch' $normalizedRoot $null $candidate $CandidateHash }
      try { $lockedValidated = Convert-ManifestBytes $lockedCandidateBytes $normalizedRoot } catch { Finish-Conflict 'controller-candidate-invalid' $normalizedRoot $null $candidate $CandidateHash }
      try { $current = Read-Manifest $normalizedRoot }
      catch {
        if ($_.Exception.Message -ceq 'manifest') { Finish-Conflict 'controller-manifest-invalid' $normalizedRoot $null $candidate $CandidateHash }
        Finish-Blocked 'controller-io-failure' $normalizedRoot $null $candidate $CandidateHash
      }
      if ($current.Hash -cne $ExpectedHash) { Finish-Conflict 'controller-hash-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash }
      try { Assert-TaskSetResetHistory $normalizedRoot $lockedValidated.Data } catch { Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash }
      if($lockedValidated.Data.schemaVersion-eq3-and$null-ne$lockedValidated.Data.taskSetReset-and$lockedValidated.Data.taskSetReset.phase-cne'completed'){
        $reset=$lockedValidated.Data.taskSetReset;$chains=if($reset.phase-in@('finalized','runtime-prepared','switched','runtime-committed')){$reset.finalActiveChains}else{$reset.initialActiveChains}
        $retired=@([string]$reset.expectedController.threadId)+@($reset.expectedProjectBindings|ForEach-Object{[string]$_.entryThreadId})+@([string]$reset.fromTaskSetId)
        try{Assert-ActiveChainHeads -Root $normalizedRoot -Chains @($chains) -RetiredIdentifiers @($retired)}catch{Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash}
      }
      if($lockedValidated.Data.schemaVersion-eq3-and$null-ne$lockedValidated.Data.taskSetReset-and$lockedValidated.Data.taskSetReset.phase-ceq'completed'){
        if($null-eq$current.Data.taskSetReset-or$current.Data.taskSetReset.operationId-cne$lockedValidated.Data.taskSetReset.operationId-or$current.Data.taskSetReset.phase-cne'runtime-committed'){
          Finish-Conflict 'controller-task-state-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash
        }
        try{$sealed=Invoke-TaskSetResetSeal $normalizedRoot $current $lockedValidated $CandidateHash $candidate}catch{
          if(Test-Path -LiteralPath (Get-TaskSetResetSealPath $normalizedRoot)){Finish-Blocked 'controller-task-set-reset-seal-recovery-required' $normalizedRoot $current.Hash $candidate $CandidateHash}
          Finish-Conflict 'controller-task-set-reset-seal-conflict' $normalizedRoot $current.Hash $candidate $CandidateHash
        }
        Write-StateResult applied 'controller-state-applied' $normalizedRoot $current.Hash $candidate $CandidateHash $sealed.Hash $sealed.Data 'Complete the matching runtime reset fence with this exact resultHash, then continue ordinary work.' @() 0
      }
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
