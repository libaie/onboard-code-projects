[CmdletBinding()]
param(
  [ValidateSet('Initialize','Read','Get','Put','GoalGet','GoalPut','ExperienceRead','ExperienceImport','Verify','Rebuild','PrepareMigration','VerifyMigration','ApplyMigration')]
  [string]$Action = 'Read',
  [string]$ControllerRoot,
  [string]$ChainId,
  [string]$CandidatePath,
  [string]$ExpectedEntryHash,
  [switch]$ConfirmTerminal,
  [string]$LedgerPath,
  [string]$ArchiveRoot,
  [string]$MigrationPath,
  [string]$ExpectedSourceHash,
  [switch]$ConfirmMigration,
  [string]$ValidatorPath,
  [string]$GoalLineageId
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ControllerRoot)) { $ControllerRoot = Split-Path -Parent $PSScriptRoot }
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:ConfigName = '.chain-store.json'
$script:StateName = 'state'
$script:IndexName = 'index.json'
$script:GoalDirectoryName = 'goals'
$script:ExperienceIndexName = 'experience-index.json'
$script:ExperienceImportName = 'experience-imports.jsonl'
$script:MarkerName = '.rebuild-required'
$script:MaxRecordBytes = 1MB
$script:MaxLogBytes = 64MB
$script:MaxIndexBytes = 8MB
$script:SecretFields = @('password','passwd','pwd','secret','clientsecret','apisecret','token','accesstoken','refreshtoken','authorization','cookie','privatekey','credential','credentials','connectionstring')
$script:SecretPattern = '(?is)(?:authorization\s*:\s*(?:bearer|basic)\s+\S+|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+|https?://[^/\s:@]+:[^/\s@]+@|https?://\S+[?&](?:access_token|refresh_token|api[_-]?key|client[_-]?secret|password)=\S+|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b)'

function Throw-StoreError {
  param([int]$Code, [string]$Reason, [string]$Message)
  $error = New-Object Exception($Message)
  $error.Data['ExitCode'] = $Code
  $error.Data['ReasonCode'] = $Reason
  throw $error
}

function Write-StoreResult {
  param(
    [string]$Status,
    [string]$Reason,
    [string]$Root,
    [AllowNull()][string]$Id,
    [AllowNull()][string]$CurrentHash,
    [AllowNull()][string]$ResultHash,
    [AllowNull()][string]$SourceHash,
    [AllowNull()]$Data,
    [string]$Next,
    [object[]]$Warnings,
    [int]$ExitCode
  )
  $result = [pscustomobject][ordered]@{
    schemaVersion=1; action=$Action; status=$Status; reasonCode=$Reason; controllerRoot=$Root; chainId=$Id
    currentEntryHash=$CurrentHash; resultEntryHash=$ResultHash; sourceHash=$SourceHash; data=$Data
    nextAction=$Next; warnings=@($Warnings)
  }
  [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 20 -Compress))
  exit $ExitCode
}

function Get-HashBytes {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-HashText {
  param([string]$Text)
  return Get-HashBytes $script:Utf8.GetBytes($Text)
}

function Test-Hash {
  param($Value)
  return ($Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$')
}

function Get-Names {
  param($Object)
  if ($null -eq $Object) { return @() }
  return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-ClosedObject {
  param($Object, [string[]]$Fields)
  if ($null -eq $Object -or $Object -is [Array] -or $Object -is [string]) { return $false }
  $names = @(Get-Names $Object)
  if ($names.Count -ne $Fields.Count) { return $false }
  foreach ($field in $Fields) { if ($names -cnotcontains $field) { return $false } }
  return $true
}

function Get-PropertyValue {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $property = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1)
  if ($property.Count -eq 0) { return $null }
  return $property[0].Value
}

function Test-Rfc3339 {
  param($Value)
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') { return $false }
  try { [void][DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind); return $true }
  catch { return $false }
}

function Resolve-Root {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { Throw-StoreError 2 'controller-root-invalid' 'ControllerRoot is required' }
  try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }
  catch { Throw-StoreError 2 'controller-root-invalid' 'ControllerRoot is invalid' }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { Throw-StoreError 2 'controller-root-invalid' 'ControllerRoot must be an existing directory' }
  $drive = [IO.Path]::GetPathRoot($full).TrimEnd('\','/')
  if ($full -ieq $drive) { Throw-StoreError 2 'controller-root-invalid' 'A filesystem root cannot be a controller root' }
  $current = $full
  while (-not [string]::IsNullOrEmpty($current)) {
    $item = Get-Item -LiteralPath $current -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-StoreError 2 'controller-path-unsafe' 'Reparse points are not allowed in ControllerRoot' }
    $parent = Split-Path -Parent $current
    if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
    $current = $parent
  }
  return $full
}

function Resolve-ChildPath {
  param([string]$Root, [string]$Path, [switch]$MustExist, [switch]$FileOnly)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]'*?[]') -ge 0 -or @($Path -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
    Throw-StoreError 2 'path-invalid' 'Path is empty or contains unsafe syntax'
  }
  try { $full = [IO.Path]::GetFullPath($Path) } catch { Throw-StoreError 2 'path-invalid' 'Path is invalid' }
  $prefix = $Root.TrimEnd('\') + '\'
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Throw-StoreError 2 'path-outside-controller' 'Path is outside ControllerRoot' }
  if ($MustExist -and -not (Test-Path -LiteralPath $full)) { Throw-StoreError 2 'path-missing' 'Required path does not exist' }
  if ($FileOnly -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { Throw-StoreError 2 'path-invalid' 'Path must be a file' }
  $current = if (Test-Path -LiteralPath $full) { $full } else { Split-Path -Parent $full }
  while ($current.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $current -ieq $Root) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-StoreError 2 'controller-path-unsafe' 'Reparse points are not allowed' }
    }
    if ($current -ieq $Root) { break }
    $current = Split-Path -Parent $current
  }
  return $full
}

function Resolve-RelativePath {
  param([string]$Root, [string]$Relative, [string]$Kind)
  if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or
      $Relative.IndexOfAny([char[]]'*?[]') -ge 0 -or @($Relative -split '[\\/]' | Where-Object { $_ -in @('','..','.') }).Count -gt 0) {
    Throw-StoreError 1 'store-config-invalid' "$Kind path is unsafe"
  }
  $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
  $prefix = $Root.TrimEnd('\') + '\'
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Throw-StoreError 1 'store-config-invalid' "$Kind path escapes ControllerRoot" }
  return $full
}

function Read-StrictBytes {
  param([string]$Path, [int64]$MaxBytes, [string]$Reason)
  try { $bytes = [IO.File]::ReadAllBytes($Path) }
  catch { Throw-StoreError 3 'store-io-failure' "Cannot read $Path" }
  if ($bytes.Length -gt $MaxBytes -or ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    Throw-StoreError 2 $Reason "Invalid size or UTF-8 BOM: $Path"
  }
  try { [void]$script:Utf8.GetString($bytes) }
  catch { Throw-StoreError 2 $Reason "Invalid UTF-8: $Path" }
  return [byte[]]$bytes
}

function Read-StrictJson {
  param([string]$Path, [int64]$MaxBytes, [string]$Reason)
  $bytes = Read-StrictBytes $Path $MaxBytes $Reason
  try { return [pscustomobject]@{ Bytes=$bytes; Object=($script:Utf8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop); Hash=(Get-HashBytes $bytes) } }
  catch { Throw-StoreError 2 $Reason "Malformed JSON: $Path" }
}

function Write-AtomicBytes {
  param([string]$Path, [byte[]]$Bytes)
  $parent = Split-Path -Parent $Path
  [IO.Directory]::CreateDirectory($parent) | Out-Null
  $temp = Join-Path $parent ('.chain-store.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $backup = Join-Path $parent ('.chain-store.' + [guid]::NewGuid().ToString('N') + '.bak')
  try {
    [IO.File]::WriteAllBytes($temp, $Bytes)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      [IO.File]::Replace($temp, $Path, $backup, $true)
      if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) }
    } elseif (Test-Path -LiteralPath $Path) { Throw-StoreError 3 'store-io-failure' "Target is not a file: $Path" }
    else { [IO.File]::Move($temp, $Path) }
    if ((Get-HashBytes ([IO.File]::ReadAllBytes($Path))) -cne (Get-HashBytes $Bytes)) { Throw-StoreError 3 'store-io-failure' "Readback hash mismatch: $Path" }
  }
  finally {
    if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) }
    if (Test-Path -LiteralPath $backup -PathType Leaf) { [IO.File]::Delete($backup) }
  }
}

function Write-AtomicText {
  param([string]$Path, [string]$Text)
  Write-AtomicBytes $Path $script:Utf8.GetBytes($Text)
}

function Get-DefaultConfig {
  param([string]$DashboardPath = 'TASKS.md', $HookPath = $null, $HookHash = $null)
  return [pscustomobject][ordered]@{
    schemaVersion=1; generator='onboard-code-projects'; dashboardPath=$DashboardPath; memoryPath='memory\MEMORY.md'
    maxMemoryLines=200; maxMemoryBytes=25600; maxMemoryItems=100; maxDashboardItems=500
    validatorPath=$HookPath; validatorHash=$HookHash
  }
}

function Test-Config {
  param($Config, [string]$Root)
  $fields=@('schemaVersion','generator','dashboardPath','memoryPath','maxMemoryLines','maxMemoryBytes','maxMemoryItems','maxDashboardItems','validatorPath','validatorHash')
  if (-not (Test-ClosedObject $Config $fields) -or $Config.schemaVersion -isnot [int] -or $Config.schemaVersion -ne 1 -or $Config.generator -cne 'onboard-code-projects' -or
      $Config.maxMemoryLines -isnot [int] -or $Config.maxMemoryLines -lt 20 -or $Config.maxMemoryLines -gt 200 -or
      $Config.maxMemoryBytes -isnot [int] -or $Config.maxMemoryBytes -lt 4096 -or $Config.maxMemoryBytes -gt 25600 -or
      $Config.maxMemoryItems -isnot [int] -or $Config.maxMemoryItems -lt 1 -or $Config.maxMemoryItems -gt 150 -or
      $Config.maxDashboardItems -isnot [int] -or $Config.maxDashboardItems -lt 20 -or $Config.maxDashboardItems -gt 1000) {
    Throw-StoreError 1 'store-config-invalid' 'Invalid closed chain-store config'
  }
  $dashboard = Resolve-RelativePath $Root ([string]$Config.dashboardPath) 'dashboard'
  $memory = Resolve-RelativePath $Root ([string]$Config.memoryPath) 'memory'
  if ([IO.Path]::GetExtension($dashboard) -ine '.md' -or [IO.Path]::GetExtension($memory) -ine '.md' -or
      $dashboard.StartsWith((Join-Path $Root $script:StateName) + '\',[StringComparison]::OrdinalIgnoreCase) -or
      $memory.StartsWith((Join-Path $Root $script:StateName) + '\',[StringComparison]::OrdinalIgnoreCase)) {
    Throw-StoreError 1 'store-config-invalid' 'View paths must be Markdown files outside state/'
  }
  $validatorPathEmpty = $null -eq $Config.validatorPath -or [string]::IsNullOrWhiteSpace([string]$Config.validatorPath)
  $validatorHashEmpty = $null -eq $Config.validatorHash -or [string]::IsNullOrWhiteSpace([string]$Config.validatorHash)
  if ($validatorPathEmpty -xor $validatorHashEmpty) { Throw-StoreError 1 'store-config-invalid' 'Validator path/hash must both be empty or both present' }
  if (-not $validatorPathEmpty) {
    if ($Config.validatorPath -isnot [string] -or -not (Test-Hash $Config.validatorHash)) { Throw-StoreError 1 'store-config-invalid' 'Invalid validator path/hash' }
    $validator = Resolve-RelativePath $Root ([string]$Config.validatorPath) 'validator'
    $toolsPrefix=(Join-Path $Root 'tools')+'\'
    if (-not $validator.StartsWith($toolsPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($validator) -ine '.ps1') { Throw-StoreError 1 'store-config-invalid' 'Validator must be a PowerShell file under tools/' }
  }
  return [pscustomobject]@{ Config=$Config; Dashboard=$dashboard; Memory=$memory }
}

function Read-Config {
  param([string]$Root)
  $path=Join-Path $Root $script:ConfigName
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Throw-StoreError 1 'store-not-initialized' 'Chain store is not initialized' }
  $read=Read-StrictJson $path 65536 'store-config-invalid'
  return Test-Config $read.Object $Root
}

function ConvertTo-CanonicalRecord {
  param($Record)
  return ($Record | ConvertTo-Json -Depth 50 -Compress)
}

function Test-NoSecrets {
  param($Value, [int]$Depth = 0)
  if ($Depth -gt 50) { Throw-StoreError 2 'task-record-invalid' 'Task record nesting is too deep' }
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    if ($Value -match $script:SecretPattern) {
      Throw-StoreError 2 'task-secret-rejected' 'Secret-shaped value cannot be stored'
    }
    return
  }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      if ($script:SecretFields -ccontains ([string]$key).ToLowerInvariant()) { Throw-StoreError 2 'task-secret-rejected' "Secret-shaped field cannot be stored: $key" }
      Test-NoSecrets $Value[$key] ($Depth+1)
    }
    return
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
    foreach ($item in @($Value)) { Test-NoSecrets $item ($Depth+1) }
    return
  }
  foreach ($property in @($Value.PSObject.Properties)) {
    if ($script:SecretFields -ccontains $property.Name.ToLowerInvariant()) { Throw-StoreError 2 'task-secret-rejected' "Secret-shaped field cannot be stored: $($property.Name)" }
    Test-NoSecrets $property.Value ($Depth+1)
  }
}

function Test-Record {
  param($Record)
  $fields=@('schemaVersion','chainId','state','phase','status','createdAt','updatedAt','objective','nextAction','payload')
  if (-not (Test-ClosedObject $Record $fields) -or $Record.schemaVersion -isnot [int] -or $Record.schemaVersion -ne 1 -or
      $Record.chainId -isnot [string] -or $Record.chainId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
      $Record.state -cnotin @('active','terminal')) { Throw-StoreError 2 'task-record-invalid' 'Invalid closed task record' }
  foreach ($field in @('phase','status','objective','nextAction')) {
    if ($Record.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Record.$field)) { Throw-StoreError 2 'task-record-invalid' "Task $field is empty" }
  }
  if ($Record.phase.Length -gt 100 -or $Record.status.Length -gt 100 -or $Record.objective.Length -gt 4000 -or $Record.nextAction.Length -gt 4000 -or
      -not (Test-Rfc3339 $Record.createdAt) -or -not (Test-Rfc3339 $Record.updatedAt) -or
      [DateTimeOffset]::Parse($Record.updatedAt) -lt [DateTimeOffset]::Parse($Record.createdAt) -or
      $null -eq $Record.payload -or $Record.payload -is [string] -or $Record.payload -is [Array]) {
    Throw-StoreError 2 'task-record-invalid' 'Invalid task summary, time, or payload'
  }
  foreach ($pair in @(
    @('id','chainId'),@('phase','phase'),@('status','status'),@('createdAt','createdAt'),@('updatedAt','updatedAt'),@('nextAction','nextAction')
  )) {
    $value=Get-PropertyValue $Record.payload $pair[0]
    if ($null -ne $value -and ($value -isnot [string] -or $value -cne [string]$Record.($pair[1]))) { Throw-StoreError 2 'task-record-invalid' "Payload $($pair[0]) disagrees with wrapper" }
  }
  $payloadGoal=Get-PropertyValue $Record.payload 'goal'
  $payloadObjective=Get-PropertyValue $Record.payload 'objective'
  if (($null -ne $payloadGoal -and $payloadGoal -cne $Record.objective) -or ($null -ne $payloadObjective -and $payloadObjective -cne $Record.objective)) {
    Throw-StoreError 2 'task-record-invalid' 'Payload objective disagrees with wrapper'
  }
  Test-NoSecrets $Record
  $json=ConvertTo-CanonicalRecord $Record
  if ($script:Utf8.GetByteCount($json) -gt $script:MaxRecordBytes) { Throw-StoreError 2 'task-record-invalid' 'Task record exceeds 1 MiB' }
  return [pscustomobject]@{ Record=$Record; Json=$json; Hash=(Get-HashText $json) }
}

function Test-SemanticTerminalSummary {
  param($Record)
  return ([string]$Record.phase -match '^(?:closed|\u5173\u95ed)$') -or
    ([string]$Record.status -match '^(?:completed|cancelled|\u5b8c\u6210|\u53d6\u6d88)$')
}

function Get-Key {
  param([string]$Id)
  return Get-HashText $Id
}

function New-Event {
  param($ValidatedRecord, [int]$Sequence, $PreviousHash, [string]$Operation, [string]$At)
  $prefix=[pscustomobject][ordered]@{
    schemaVersion=1; seq=$Sequence; chainId=[string]$ValidatedRecord.Record.chainId; at=$At; operation=$Operation
    previousEntryHash=$PreviousHash; recordHash=[string]$ValidatedRecord.Hash; record=$ValidatedRecord.Record
  }
  $entryHash=Get-HashText ($prefix|ConvertTo-Json -Depth 60 -Compress)
  $event=[pscustomobject][ordered]@{
    schemaVersion=1; seq=$Sequence; chainId=[string]$ValidatedRecord.Record.chainId; at=$At; operation=$Operation
    previousEntryHash=$PreviousHash; recordHash=[string]$ValidatedRecord.Hash; record=$ValidatedRecord.Record; entryHash=$entryHash
  }
  return [pscustomobject]@{Event=$event;Line=(($event|ConvertTo-Json -Depth 60 -Compress)+"`n");EntryHash=$entryHash}
}

function Read-Log {
  param([string]$Path)
  $bytes=Read-StrictBytes $Path $script:MaxLogBytes 'store-log-invalid'
  $text=$script:Utf8.GetString($bytes)
  if ([string]::IsNullOrEmpty($text) -or -not $text.EndsWith("`n",[StringComparison]::Ordinal) -or $text.Contains("`r")) { Throw-StoreError 1 'store-log-invalid' "Log must be LF-terminated JSONL: $Path" }
  $lines=@($text.Substring(0,$text.Length-1).Split("`n"))
  $previous=$null;$last=$null;$id=$null
  for($i=0;$i -lt $lines.Count;$i++) {
    if ([string]::IsNullOrWhiteSpace($lines[$i])) { Throw-StoreError 1 'store-log-invalid' "Blank JSONL entry: $Path" }
    try{$event=$lines[$i]|ConvertFrom-Json -ErrorAction Stop}catch{Throw-StoreError 1 'store-log-invalid' "Malformed JSONL entry: $Path"}
    $fields=@('schemaVersion','seq','chainId','at','operation','previousEntryHash','recordHash','record','entryHash')
    if(-not(Test-ClosedObject $event $fields)-or $event.schemaVersion -isnot [int]-or $event.schemaVersion -ne 1-or $event.seq -isnot [int]-or $event.seq -ne ($i+1)-or
       $event.chainId -isnot[string]-or -not(Test-Rfc3339 $event.at)-or $event.operation -cnotin @('create','update','archive','import')-or
       (($i -eq 0)-and $null -ne $event.previousEntryHash)-or (($i -gt 0)-and $event.previousEntryHash -cne $previous)-or -not(Test-Hash $event.recordHash)-or -not(Test-Hash $event.entryHash)) {
      Throw-StoreError 1 'store-log-invalid' "Invalid event envelope: $Path"
    }
    $validated=Test-Record $event.record
    if($validated.Hash -cne $event.recordHash-or $event.chainId -cne $event.record.chainId){Throw-StoreError 1 'store-log-invalid' "Record hash or identity mismatch: $Path"}
    $prefix=[pscustomobject][ordered]@{schemaVersion=1;seq=$event.seq;chainId=$event.chainId;at=$event.at;operation=$event.operation;previousEntryHash=$event.previousEntryHash;recordHash=$event.recordHash;record=$event.record}
    if((Get-HashText ($prefix|ConvertTo-Json -Depth 60 -Compress))-cne$event.entryHash){Throw-StoreError 1 'store-log-invalid' "Entry hash mismatch: $Path"}
    if($null-eq$id){$id=[string]$event.chainId}elseif($id-cne$event.chainId){Throw-StoreError 1 'store-log-invalid' "Mixed identities: $Path"}
    if($i -lt ($lines.Count-1)-and $event.record.state -cne 'active'){Throw-StoreError 1 'store-log-invalid' "Only the last event may be terminal: $Path"}
    $previous=[string]$event.entryHash;$last=$event
  }
  return [pscustomobject]@{Path=$Path;Bytes=$bytes;ChainId=$id;Head=$last;HeadHash=$previous;Record=$last.record;RecordHash=$last.recordHash;Count=$lines.Count}
}

function Test-ContainsExactEvidence {
  param($Value,[string]$EvidenceHash,[string]$ObservedAt)
  if($null-eq$Value){return $false}
  if($Value-is[string]){return $false}
  if($Value-is[System.Collections.IEnumerable]-and$Value-isnot[pscustomobject]-and$Value-isnot[System.Collections.IDictionary]){foreach($item in @($Value)){if(Test-ContainsExactEvidence $item $EvidenceHash $ObservedAt){return $true}};return $false}
  $properties=@{};if($Value-is[System.Collections.IDictionary]){foreach($key in $Value.Keys){$properties[[string]$key]=$Value[$key]}}else{foreach($property in @($Value.PSObject.Properties)){$properties[$property.Name]=$property.Value}}
  $hashMatches=@($properties.Keys|Where-Object{$_-match'(?i)(?:evidence|proof|result).*hash$'-and$properties[$_]-is[string]-and$properties[$_]-ceq$EvidenceHash}).Count-gt0
  $timeMatches=@($properties.Keys|Where-Object{$_-match'(?i)^(?:at|observedAt|occurredAt|finishedAt|updatedAt)$'-and$properties[$_]-is[string]-and$properties[$_]-ceq$ObservedAt}).Count-gt0
  if($hashMatches-and$timeMatches){return $true}
  if($timeMatches-and$properties.ContainsKey('reason')-and$properties['reason']-is[string]){$matches=[regex]::Matches([string]$properties['reason'],'(?<![0-9a-f])evidenceHash=([0-9a-f]{64})(?![0-9a-f])');if($matches.Count-eq1-and$matches[0].Groups[1].Value-ceq$EvidenceHash){return $true}}
  foreach($value in $properties.Values){if(Test-ContainsExactEvidence $value $EvidenceHash $ObservedAt){return $true}}
  return $false
}

function Test-ContainsMaterialEvidence {
  param($Value,[string]$Field,[string]$PreviousHash,[string]$CurrentHash,[string]$EvidenceHash,[string]$ObservedAt)
  if($null-eq$Value-or$Value-is[string]){return $false}
  if($Value-is[System.Collections.IEnumerable]-and$Value-isnot[pscustomobject]-and$Value-isnot[System.Collections.IDictionary]){foreach($item in @($Value)){if(Test-ContainsMaterialEvidence $item $Field $PreviousHash $CurrentHash $EvidenceHash $ObservedAt){return $true}};return $false}
  $properties=@{};if($Value-is[System.Collections.IDictionary]){foreach($key in $Value.Keys){$properties[[string]$key]=$Value[$key]}}else{foreach($property in @($Value.PSObject.Properties)){$properties[$property.Name]=$property.Value}}
  if($properties.ContainsKey('field')-and$properties.ContainsKey('previousHash')-and$properties.ContainsKey('currentHash')-and$properties.ContainsKey('evidenceHash')-and$properties.ContainsKey('at')-and
     [string]$properties['field']-ceq$Field-and[string]$properties['previousHash']-ceq$PreviousHash-and[string]$properties['currentHash']-ceq$CurrentHash-and[string]$properties['evidenceHash']-ceq$EvidenceHash-and[string]$properties['at']-ceq$ObservedAt){return $true}
  foreach($value in $properties.Values){if(Test-ContainsMaterialEvidence $value $Field $PreviousHash $CurrentHash $EvidenceHash $ObservedAt){return $true}}
  return $false
}

function Get-CanonicalChainEvidence {
  param([string]$Root,[string]$ChainId,[string]$EntryHash,[string]$EvidenceHash,[string]$ObservedAt)
  if(-not(Test-GoalIdentifier $ChainId)-or-not(Test-Hash $EntryHash)-or-not(Test-Hash $EvidenceHash)-or-not(Test-Rfc3339 $ObservedAt)){Throw-StoreError 1 'experience-import-evidence-invalid' 'Evidence must reference one canonical CHAIN event'}
  $key=(Get-Key $ChainId)+'.jsonl';$paths=@();$active=Join-Path (Join-Path (Join-Path $Root $script:StateName) 'active') $key
  if(Test-Path -LiteralPath $active -PathType Leaf){$paths+=@($active)}
  $archive=Join-Path (Join-Path $Root $script:StateName) 'archive'
  foreach($month in @(Get-ChildItem -LiteralPath $archive -Force)){
    if(-not$month.PSIsContainer-or($month.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$month.Name-cnotmatch'^\d{4}-(?:0[1-9]|1[0-2])$'){Throw-StoreError 1 'store-layout-invalid' "Invalid archive child: $($month.FullName)"}
    $candidate=Join-Path $month.FullName $key;if(Test-Path -LiteralPath $candidate -PathType Leaf){$paths+=@($candidate)}
  }
  if($paths.Count-ne1){Throw-StoreError 1 'experience-import-evidence-invalid' 'Evidence CHAIN is missing or ambiguous'}
  $log=Read-Log $paths[0];$events=@($script:Utf8.GetString($log.Bytes).TrimEnd("`n").Split("`n")|ForEach-Object{$_|ConvertFrom-Json -ErrorAction Stop});$event=@($events|Where-Object{$_.entryHash-ceq$EntryHash})
  if($log.ChainId-cne$ChainId-or$event.Count-ne1-or-not(Test-ContainsExactEvidence $event[0].record $EvidenceHash $ObservedAt)){Throw-StoreError 1 'experience-import-evidence-invalid' 'Evidence hash and observed time must be present together in the exact canonical CHAIN event'}
  return $event[0]
}

function Test-GoalIdentifier {
  param($Value)
  return $Value -is [string] -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
}

function Test-GoalProjectRoot {
  param($Value)
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathRooted($Value)) { return $false }
  try { $full=[IO.Path]::GetFullPath($Value).TrimEnd('\','/') } catch { return $false }
  $drive=[IO.Path]::GetPathRoot($full).TrimEnd('\','/')
  return $full -ceq $Value.TrimEnd('\','/') -and $full -cne $drive
}

function Convert-GoalStringList {
  param($Value,[int]$Maximum,[bool]$RequireItem)
  if ($Value -isnot [Array] -or @($Value).Count -gt $Maximum -or ($RequireItem -and @($Value).Count -eq 0)) { Throw-StoreError 2 'goal-record-invalid' 'Invalid goal string list' }
  $items=@();$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($item in @($Value)){
    if($item -isnot[string]-or[string]::IsNullOrWhiteSpace($item)-or$item.Length-gt1000-or$item-match'[\x00-\x1f\x7f]'-or-not$seen.Add([string]$item)){Throw-StoreError 2 'goal-record-invalid' 'Invalid or duplicate goal string'}
    $items += [string]$item
  }
  return @($items)
}

function Convert-GoalReservation {
  param($Value)
  $fields=@('reservationId','chainId','dispatchId','problemInvariantId','strategyFamilyId','strategy','attemptNumber','retryOrdinal','executionFingerprint','acceptanceIds','acceptanceHash','materialPreconditions','materialPreconditionHash','operationCoverage','operationCoverageHash','controllerRuntimeHash','capabilityBundleHash','reservedAt')
  $hasMaterialEvidence=@(Get-Names $Value)-ccontains'materialChangeEvidence';$closedFields=if($hasMaterialEvidence){@($fields)+@('materialChangeEvidence')}else{$fields}
  if(-not(Test-ClosedObject $Value $closedFields)-or-not(Test-GoalIdentifier $Value.reservationId)-or-not(Test-GoalIdentifier $Value.chainId)-or-not(Test-GoalIdentifier $Value.dispatchId)-or
     -not(Test-GoalIdentifier $Value.problemInvariantId)-or-not(Test-GoalIdentifier $Value.strategyFamilyId)-or$Value.strategy-cnotin@('initial','repair','rebaseline')-or
     $Value.attemptNumber-isnot[int]-or$Value.attemptNumber-lt1-or$Value.attemptNumber-gt3-or$Value.retryOrdinal-isnot[int]-or$Value.retryOrdinal-ne0-or
     -not(Test-Hash $Value.executionFingerprint)-or-not(Test-Hash $Value.acceptanceHash)-or-not(Test-Hash $Value.materialPreconditionHash)-or
     -not(Test-Hash $Value.operationCoverageHash)-or-not(Test-Hash $Value.controllerRuntimeHash)-or-not(Test-Hash $Value.capabilityBundleHash)-or-not(Test-Rfc3339 $Value.reservedAt)){
    Throw-StoreError 2 'goal-record-invalid' 'Invalid goal reservation envelope'
  }
  $expectedStrategy=@('initial','repair','rebaseline')[$Value.attemptNumber-1]
  if($Value.strategy-cne$expectedStrategy){Throw-StoreError 2 'goal-record-invalid' 'Reservation strategy does not match its bounded attempt'}
  $acceptanceIds=@(Convert-GoalStringList $Value.acceptanceIds 50 $true)
  foreach($id in $acceptanceIds){if(-not(Test-Hash $id)){Throw-StoreError 2 'goal-record-invalid' 'Acceptance IDs must be SHA-256 values'}}
  $acceptanceHash=Get-HashText (ConvertTo-Json -InputObject @($acceptanceIds) -Compress)
  if($acceptanceHash-cne$Value.acceptanceHash){Throw-StoreError 2 'goal-record-invalid' 'Acceptance hash mismatch'}

  $materialFields=@('contractVersionHash','targetSetHash','capabilitySetHash','runtimeVersionHash','toolchainVersionHash','authorizationBoundaryHash','failureOracleHash','relevantContentHash')
  if(-not(Test-ClosedObject $Value.materialPreconditions $materialFields)){Throw-StoreError 2 'goal-record-invalid' 'Invalid material preconditions'}
  $material=[ordered]@{}
  foreach($field in $materialFields){if(-not(Test-Hash $Value.materialPreconditions.$field)){Throw-StoreError 2 'goal-record-invalid' 'Material preconditions must be SHA-256 values'};$material[$field]=[string]$Value.materialPreconditions.$field}
  $material=[pscustomobject]$material
  $materialHash=Get-HashText ($material|ConvertTo-Json -Compress)
  if($materialHash-cne$Value.materialPreconditionHash-or$Value.controllerRuntimeHash-cne$material.runtimeVersionHash-or$Value.capabilityBundleHash-cne$material.capabilitySetHash){Throw-StoreError 2 'goal-record-invalid' 'Material, runtime, or capability hash mismatch'}
  $materialEvidence=@()
  if($hasMaterialEvidence){
    if($Value.materialChangeEvidence-isnot[Array]-or@($Value.materialChangeEvidence).Count-gt$materialFields.Count){Throw-StoreError 2 'goal-record-invalid' 'Material change evidence must be a bounded array'}
    $evidenceFields=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($row in @($Value.materialChangeEvidence)){
      if(-not(Test-ClosedObject $row @('field','previousHash','currentHash','sourceChainId','sourceEntryHash','evidenceHash','observedAt'))-or$materialFields-cnotcontains$row.field-or-not$evidenceFields.Add([string]$row.field)-or
         -not(Test-Hash $row.previousHash)-or-not(Test-Hash $row.currentHash)-or$row.previousHash-ceq$row.currentHash-or-not(Test-GoalIdentifier $row.sourceChainId)-or-not(Test-Hash $row.sourceEntryHash)-or-not(Test-Hash $row.evidenceHash)-or-not(Test-Rfc3339 $row.observedAt)){Throw-StoreError 2 'goal-record-invalid' 'Invalid field-bound material change evidence'}
      $materialEvidence += [pscustomobject][ordered]@{field=[string]$row.field;previousHash=[string]$row.previousHash;currentHash=[string]$row.currentHash;sourceChainId=[string]$row.sourceChainId;sourceEntryHash=[string]$row.sourceEntryHash;evidenceHash=[string]$row.evidenceHash;observedAt=[string]$row.observedAt}
    }
  }

  if($Value.operationCoverage-isnot[Array]-or@($Value.operationCoverage).Count-lt1-or@($Value.operationCoverage).Count-gt100){Throw-StoreError 2 'goal-record-invalid' 'Operation coverage must be a bounded array'}
  $coverage=@();$covered=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$operations=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($row in @($Value.operationCoverage)){
    $rowFields=@('acceptanceId','operationId','operationClass','targets','capabilityRefs','authorizationRef','verification','rollback')
    if(-not(Test-ClosedObject $row $rowFields)-or-not(Test-Hash $row.acceptanceId)-or$acceptanceIds-cnotcontains$row.acceptanceId-or-not(Test-GoalIdentifier $row.operationId)-or$row.operationClass-cnotin@('read','repository-write','external-write')-or
       $row.authorizationRef-isnot[string]-or[string]::IsNullOrWhiteSpace($row.authorizationRef)-or$row.authorizationRef.Length-gt300-or-not$operations.Add([string]$row.operationId)-or-not$covered.Add([string]$row.acceptanceId)){Throw-StoreError 2 'goal-record-invalid' 'Invalid or duplicate operation coverage row'}
    $targets=@(Convert-GoalStringList $row.targets 50 $true);$capabilityRefs=@(Convert-GoalStringList $row.capabilityRefs 20 $false);$verification=@(Convert-GoalStringList $row.verification 50 $true);$rollback=@(Convert-GoalStringList $row.rollback 50 ($row.operationClass-cne'read'))
    if($row.operationClass-ceq'external-write'-and($capabilityRefs.Count-eq0-or$row.authorizationRef-ceq'N/A')){Throw-StoreError 2 'goal-record-invalid' 'External writes require declared capability and authorization'}
    if($row.operationClass-ceq'read'-and$rollback.Count-ne0){Throw-StoreError 2 'goal-record-invalid' 'Read operations cannot declare write rollback'}
    $coverage += [pscustomobject][ordered]@{acceptanceId=[string]$row.acceptanceId;operationId=[string]$row.operationId;operationClass=[string]$row.operationClass;targets=@($targets);capabilityRefs=@($capabilityRefs);authorizationRef=[string]$row.authorizationRef;verification=@($verification);rollback=@($rollback)}
  }
  foreach($id in $acceptanceIds){if(-not$covered.Contains($id)){Throw-StoreError 2 'goal-record-invalid' 'Every acceptance must map to a declared operation'}}
  $coverageHash=Get-HashText (ConvertTo-Json -InputObject @($coverage) -Depth 10 -Compress)
  if($coverageHash-cne$Value.operationCoverageHash){Throw-StoreError 2 'goal-record-invalid' 'Operation coverage hash mismatch'}
  $canonical=[ordered]@{
    reservationId=[string]$Value.reservationId;chainId=[string]$Value.chainId;dispatchId=[string]$Value.dispatchId
    problemInvariantId=[string]$Value.problemInvariantId;strategyFamilyId=[string]$Value.strategyFamilyId;strategy=[string]$Value.strategy
    attemptNumber=[int]$Value.attemptNumber;retryOrdinal=[int]$Value.retryOrdinal;executionFingerprint=[string]$Value.executionFingerprint
    acceptanceIds=@($acceptanceIds);acceptanceHash=[string]$acceptanceHash;materialPreconditions=$material;materialPreconditionHash=[string]$materialHash
    operationCoverage=@($coverage);operationCoverageHash=[string]$coverageHash;controllerRuntimeHash=[string]$Value.controllerRuntimeHash
    capabilityBundleHash=[string]$Value.capabilityBundleHash;reservedAt=[string]$Value.reservedAt
  }
  if($hasMaterialEvidence){$canonical.materialChangeEvidence=@($materialEvidence)}
  return [pscustomobject]$canonical
}

function Convert-GoalOutcome {
  param($Value)
  if(-not(Test-ClosedObject $Value @('reservation','outcome','failureClass','evidenceHash','finishedAt'))-or
     $Value.outcome-cnotin@('accepted-success','deterministic-failure','transient-failure','environment-block','authorization-declined','superseded','cancelled')-or
     $Value.failureClass-isnot[string]-or[string]::IsNullOrWhiteSpace($Value.failureClass)-or$Value.failureClass.Length-gt80-or-not(Test-Hash $Value.evidenceHash)-or-not(Test-Rfc3339 $Value.finishedAt)){
    Throw-StoreError 2 'goal-record-invalid' 'Invalid goal outcome'
  }
  $successLike=$Value.outcome-in@('accepted-success','superseded','cancelled')
  if(($successLike-and$Value.failureClass-cne'N/A')-or(-not$successLike-and$Value.failureClass-ceq'N/A')-or($Value.outcome-ceq'authorization-declined'-and$Value.failureClass-cne'authorization')){Throw-StoreError 2 'goal-record-invalid' 'Outcome failure class mismatch'}
  $reservation=Convert-GoalReservation $Value.reservation
  if([DateTimeOffset]::Parse($Value.finishedAt)-lt[DateTimeOffset]::Parse($reservation.reservedAt)){Throw-StoreError 2 'goal-record-invalid' 'Outcome precedes reservation'}
  return [pscustomobject][ordered]@{reservation=$reservation;outcome=[string]$Value.outcome;failureClass=[string]$Value.failureClass;evidenceHash=[string]$Value.evidenceHash;finishedAt=[string]$Value.finishedAt}
}

function Convert-GoalLane {
  param($Value)
  if(-not(Test-ClosedObject $Value @('projectRoot','attemptsUsed','transientRetriesUsed','activeReservation','outcomes'))-or-not(Test-GoalProjectRoot $Value.projectRoot)-or
     $Value.attemptsUsed-isnot[int]-or$Value.attemptsUsed-lt0-or$Value.attemptsUsed-gt3-or$Value.transientRetriesUsed-isnot[int]-or$Value.transientRetriesUsed-ne0-or
     $Value.outcomes-isnot[Array]-or@($Value.outcomes).Count-gt4){Throw-StoreError 2 'goal-record-invalid' 'Invalid goal lane'}
  $outcomes=@();$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$previousTime=$null
  foreach($item in @($Value.outcomes)){
    $outcome=Convert-GoalOutcome $item
    if(-not$ids.Add($outcome.reservation.reservationId)-or($null-ne$previousTime-and[DateTimeOffset]::Parse($outcome.finishedAt)-lt[DateTimeOffset]::Parse($previousTime))){Throw-StoreError 2 'goal-record-invalid' 'Duplicate or unordered goal outcome'}
    $outcomes+=$outcome;$previousTime=$outcome.finishedAt
  }
  $active=if($null-eq$Value.activeReservation){$null}else{Convert-GoalReservation $Value.activeReservation}
  if($null-ne$active-and(-not$ids.Add($active.reservationId)-or($null-ne$previousTime-and[DateTimeOffset]::Parse($active.reservedAt)-lt[DateTimeOffset]::Parse($previousTime)))){Throw-StoreError 2 'goal-record-invalid' 'Duplicate or stale active reservation'}
  # ponytail: v1 keeps the sealed zero fields for compatibility; the sole transient replay lives in dispatch reconciliation.
  $primaries=@($outcomes|ForEach-Object{$_.reservation});if($null-ne$active){$primaries+=@($active)}
  if($primaries.Count-ne$Value.attemptsUsed){Throw-StoreError 2 'goal-record-invalid' 'Lane counters disagree with reservations'}
  for($attempt=1;$attempt-le$Value.attemptsUsed;$attempt++){
    $primary=@($primaries|Where-Object{$_.attemptNumber-eq$attempt});if($primary.Count-ne1){Throw-StoreError 2 'goal-record-invalid' 'Business attempts must be contiguous and unique'}
  }
  return [pscustomobject][ordered]@{projectRoot=[string]$Value.projectRoot;attemptsUsed=[int]$Value.attemptsUsed;transientRetriesUsed=[int]$Value.transientRetriesUsed;activeReservation=$active;outcomes=@($outcomes)}
}

function Test-GoalRecord {
  param($Record)
  $fields=@('schemaVersion','goalLineageId','objectiveFingerprint','state','createdAt','updatedAt','budget','readinessFailures','lanes')
  if(-not(Test-ClosedObject $Record $fields)-or$Record.schemaVersion-isnot[int]-or$Record.schemaVersion-ne1-or-not(Test-GoalIdentifier $Record.goalLineageId)-or-not(Test-Hash $Record.objectiveFingerprint)-or
     $Record.state-cnotin@('active','terminal')-or-not(Test-Rfc3339 $Record.createdAt)-or-not(Test-Rfc3339 $Record.updatedAt)-or[DateTimeOffset]::Parse($Record.updatedAt)-lt[DateTimeOffset]::Parse($Record.createdAt)-or
     -not(Test-ClosedObject $Record.budget @('readinessReplansUsed','crossProjectRebaselinesUsed'))-or$Record.budget.readinessReplansUsed-isnot[int]-or$Record.budget.readinessReplansUsed-lt0-or$Record.budget.readinessReplansUsed-gt1-or
     $Record.budget.crossProjectRebaselinesUsed-isnot[int]-or$Record.budget.crossProjectRebaselinesUsed-lt0-or$Record.budget.crossProjectRebaselinesUsed-gt1-or$Record.readinessFailures-isnot[Array]-or@($Record.readinessFailures).Count-gt2-or
     $Record.lanes-isnot[Array]-or@($Record.lanes).Count-lt1-or@($Record.lanes).Count-gt100){Throw-StoreError 2 'goal-record-invalid' 'Invalid closed goal lineage'}
  $readiness=@();$readinessIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$previousFailureTime=$null
  foreach($failure in @($Record.readinessFailures)){
    if(-not(Test-ClosedObject $failure @('projectRoot','chainId','dispatchId','failureClass','evidenceHash','occurredAt'))-or-not(Test-GoalProjectRoot $failure.projectRoot)-or-not(Test-GoalIdentifier $failure.chainId)-or-not(Test-GoalIdentifier $failure.dispatchId)-or
       $failure.failureClass-cne'controller-readiness-failed'-or-not(Test-Hash $failure.evidenceHash)-or-not(Test-Rfc3339 $failure.occurredAt)-or-not$readinessIds.Add([string]$failure.dispatchId)-or
       ($null-ne$previousFailureTime-and[DateTimeOffset]::Parse($failure.occurredAt)-lt[DateTimeOffset]::Parse($previousFailureTime))){Throw-StoreError 2 'goal-record-invalid' 'Invalid readiness failure'}
    $readiness += [pscustomobject][ordered]@{projectRoot=[string]$failure.projectRoot;chainId=[string]$failure.chainId;dispatchId=[string]$failure.dispatchId;failureClass='controller-readiness-failed';evidenceHash=[string]$failure.evidenceHash;occurredAt=[string]$failure.occurredAt};$previousFailureTime=$failure.occurredAt
  }
  if(@($readiness).Count-lt$Record.budget.readinessReplansUsed){Throw-StoreError 2 'goal-record-invalid' 'Readiness replan counter has no failure evidence'}
  $lanes=@();$roots=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$reservationIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$dispatchIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($value in @($Record.lanes)){
    $lane=Convert-GoalLane $value;if(-not$roots.Add($lane.projectRoot)){Throw-StoreError 2 'goal-record-invalid' 'Duplicate goal lane'}
    foreach($reservation in @($lane.outcomes|ForEach-Object{$_.reservation})+@($lane.activeReservation)){
      if($null-ne$reservation-and(-not$reservationIds.Add($reservation.reservationId)-or-not$dispatchIds.Add($reservation.dispatchId))){Throw-StoreError 2 'goal-record-invalid' 'Reservation or dispatch identity is reused'}
    }
    $lanes+=$lane
  }
  if($Record.state-ceq'terminal'-and@($lanes|Where-Object{$null-ne$_.activeReservation}).Count-gt0){Throw-StoreError 2 'goal-record-invalid' 'Terminal goal retains an active reservation'}
  Test-NoSecrets $Record
  $canonical=[pscustomobject][ordered]@{schemaVersion=1;goalLineageId=[string]$Record.goalLineageId;objectiveFingerprint=[string]$Record.objectiveFingerprint;state=[string]$Record.state;createdAt=[string]$Record.createdAt;updatedAt=[string]$Record.updatedAt;budget=[pscustomobject][ordered]@{readinessReplansUsed=[int]$Record.budget.readinessReplansUsed;crossProjectRebaselinesUsed=[int]$Record.budget.crossProjectRebaselinesUsed};readinessFailures=@($readiness);lanes=@($lanes)}
  $json=ConvertTo-CanonicalRecord $canonical;if($script:Utf8.GetByteCount($json)-gt$script:MaxRecordBytes){Throw-StoreError 2 'goal-record-invalid' 'Goal record exceeds 1 MiB'}
  return [pscustomobject]@{Record=$canonical;Json=$json;Hash=(Get-HashText $json)}
}

function New-GoalEvent {
  param($ValidatedRecord,[int]$Sequence,$PreviousHash,[string]$Operation,[string]$At)
  $prefix=[pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;goalLineageId=[string]$ValidatedRecord.Record.goalLineageId;at=$At;operation=$Operation;previousEntryHash=$PreviousHash;recordHash=[string]$ValidatedRecord.Hash;record=$ValidatedRecord.Record}
  $entryHash=Get-HashText ($prefix|ConvertTo-Json -Depth 60 -Compress)
  $event=[pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;goalLineageId=[string]$ValidatedRecord.Record.goalLineageId;at=$At;operation=$Operation;previousEntryHash=$PreviousHash;recordHash=[string]$ValidatedRecord.Hash;record=$ValidatedRecord.Record;entryHash=$entryHash}
  return [pscustomobject]@{Event=$event;Line=(($event|ConvertTo-Json -Depth 60 -Compress)+"`n");EntryHash=$entryHash}
}

function Read-GoalLog {
  param([string]$Path)
  $bytes=Read-StrictBytes $Path $script:MaxLogBytes 'goal-log-invalid';$text=$script:Utf8.GetString($bytes)
  if([string]::IsNullOrEmpty($text)-or-not$text.EndsWith("`n",[StringComparison]::Ordinal)-or$text.Contains("`r")){Throw-StoreError 1 'goal-log-invalid' "Goal log must be LF-terminated JSONL: $Path"}
  $lines=@($text.Substring(0,$text.Length-1).Split("`n"));$previous=$null;$last=$null;$id=$null
  for($i=0;$i-lt$lines.Count;$i++){
    try{$event=$lines[$i]|ConvertFrom-Json -ErrorAction Stop}catch{Throw-StoreError 1 'goal-log-invalid' "Malformed goal JSONL entry: $Path"}
    $fields=@('schemaVersion','seq','goalLineageId','at','operation','previousEntryHash','recordHash','record','entryHash')
    if(-not(Test-ClosedObject $event $fields)-or$event.schemaVersion-isnot[int]-or$event.schemaVersion-ne1-or$event.seq-isnot[int]-or$event.seq-ne($i+1)-or-not(Test-GoalIdentifier $event.goalLineageId)-or-not(Test-Rfc3339 $event.at)-or
       $event.operation-cnotin@('create','update','terminal')-or(($i-eq0)-and$null-ne$event.previousEntryHash)-or(($i-gt0)-and$event.previousEntryHash-cne$previous)-or-not(Test-Hash $event.recordHash)-or-not(Test-Hash $event.entryHash)){Throw-StoreError 1 'goal-log-invalid' "Invalid goal event envelope: $Path"}
    $validated=Test-GoalRecord $event.record
    if($validated.Hash-cne$event.recordHash-or$event.goalLineageId-cne$event.record.goalLineageId){Throw-StoreError 1 'goal-log-invalid' "Goal record hash or identity mismatch: $Path"}
    $prefix=[pscustomobject][ordered]@{schemaVersion=1;seq=$event.seq;goalLineageId=$event.goalLineageId;at=$event.at;operation=$event.operation;previousEntryHash=$event.previousEntryHash;recordHash=$event.recordHash;record=$event.record}
    if((Get-HashText ($prefix|ConvertTo-Json -Depth 60 -Compress))-cne$event.entryHash){Throw-StoreError 1 'goal-log-invalid' "Goal entry hash mismatch: $Path"}
    if($null-eq$id){$id=[string]$event.goalLineageId}elseif($id-cne$event.goalLineageId){Throw-StoreError 1 'goal-log-invalid' "Mixed goal identities: $Path"}
    if($i-lt($lines.Count-1)-and$event.record.state-cne'active'){Throw-StoreError 1 'goal-log-invalid' 'Only the last goal event may be terminal'}
    $previous=[string]$event.entryHash;$last=$event
  }
  return [pscustomobject]@{Path=$Path;Bytes=$bytes;GoalLineageId=$id;Head=$last;HeadHash=$previous;Record=$last.record;RecordHash=$last.recordHash;Count=$lines.Count}
}

function Convert-ExperienceImportRecord {
  param([string]$Root,$Record)
  Test-NoSecrets $Record
  if(-not(Test-ClosedObject $Record @('schemaVersion','importId','curatedAt','entries'))-or$Record.schemaVersion-isnot[int]-or$Record.schemaVersion-ne1-or-not(Test-GoalIdentifier $Record.importId)-or-not(Test-Rfc3339 $Record.curatedAt)-or
     $Record.entries-isnot[Array]-or@($Record.entries).Count-lt1-or@($Record.entries).Count-gt100){Throw-StoreError 2 'experience-import-invalid' 'Invalid closed curated experience import'}
  $entries=@();$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$semantics=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach($value in @($Record.entries)){
    if(-not(Test-ClosedObject $value @('experienceId','problemInvariantId','strategyFamilyId','materialPreconditions','materialPreconditionHash','outcome','failureClass','sourceChainId','sourceEntryHash','evidenceHash','observedAt'))-or
       -not(Test-GoalIdentifier $value.experienceId)-or-not$ids.Add([string]$value.experienceId)-or-not(Test-GoalIdentifier $value.problemInvariantId)-or-not(Test-GoalIdentifier $value.strategyFamilyId)-or-not(Test-Hash $value.materialPreconditionHash)-or
       $value.outcome-cnotin@('accepted-success','deterministic-failure')-or$value.failureClass-isnot[string]-or[string]::IsNullOrWhiteSpace($value.failureClass)-or$value.failureClass.Length-gt80-or
       ($value.outcome-ceq'accepted-success'-and$value.failureClass-cne'N/A')-or($value.outcome-ceq'deterministic-failure'-and$value.failureClass-ceq'N/A')-or
       -not(Test-GoalIdentifier $value.sourceChainId)-or-not(Test-Hash $value.sourceEntryHash)-or-not(Test-Hash $value.evidenceHash)-or-not(Test-Rfc3339 $value.observedAt)){Throw-StoreError 2 'experience-import-invalid' 'Invalid curated experience entry'}
    $materialFields=@('contractVersionHash','targetSetHash','capabilitySetHash','runtimeVersionHash','toolchainVersionHash','authorizationBoundaryHash','failureOracleHash','relevantContentHash')
    if(-not(Test-ClosedObject $value.materialPreconditions $materialFields)){Throw-StoreError 2 'experience-import-invalid' 'Imported material preconditions must be closed'}
    $material=[ordered]@{};foreach($field in $materialFields){if(-not(Test-Hash $value.materialPreconditions.$field)){Throw-StoreError 2 'experience-import-invalid' 'Imported material preconditions must be SHA-256 values'};$material[$field]=[string]$value.materialPreconditions.$field};$material=[pscustomobject]$material
    if((Get-HashText ($material|ConvertTo-Json -Compress))-cne$value.materialPreconditionHash){Throw-StoreError 2 'experience-import-invalid' 'Imported material precondition hash mismatch'}
    $semantic=('{0}|{1}|{2}|{3}'-f$value.problemInvariantId,$value.strategyFamilyId,$value.materialPreconditionHash,$value.outcome)
    if(-not$semantics.Add($semantic)){Throw-StoreError 1 'experience-import-duplicate' 'One import cannot repeat the same semantic experience'}
    [void](Get-CanonicalChainEvidence $Root ([string]$value.sourceChainId) ([string]$value.sourceEntryHash) ([string]$value.evidenceHash) ([string]$value.observedAt))
    if([DateTimeOffset]::Parse($Record.curatedAt)-lt[DateTimeOffset]::Parse($value.observedAt)){Throw-StoreError 1 'experience-import-evidence-invalid' 'Curated experience predates its canonical CHAIN evidence'}
    $entries += [pscustomobject][ordered]@{experienceId=[string]$value.experienceId;problemInvariantId=[string]$value.problemInvariantId;strategyFamilyId=[string]$value.strategyFamilyId;materialPreconditions=$material;materialPreconditionHash=[string]$value.materialPreconditionHash;outcome=[string]$value.outcome;failureClass=[string]$value.failureClass;sourceChainId=[string]$value.sourceChainId;sourceEntryHash=[string]$value.sourceEntryHash;evidenceHash=[string]$value.evidenceHash;observedAt=[string]$value.observedAt}
  }
  $canonical=[pscustomobject][ordered]@{schemaVersion=1;importId=[string]$Record.importId;curatedAt=[string]$Record.curatedAt;entries=@($entries)}
  $json=ConvertTo-CanonicalRecord $canonical
  if($script:Utf8.GetByteCount($json)-gt$script:MaxRecordBytes){Throw-StoreError 2 'experience-import-invalid' 'Curated import exceeds 1 MiB'}
  return [pscustomobject]@{Record=$canonical;Json=$json;Hash=(Get-HashText $json)}
}

function New-ExperienceImportEvent {
  param($Validated,[int]$Sequence,$PreviousHash,[string]$At)
  $prefix=[pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;importId=[string]$Validated.Record.importId;at=$At;previousEntryHash=$PreviousHash;recordHash=[string]$Validated.Hash;record=$Validated.Record}
  $entryHash=Get-HashText ($prefix|ConvertTo-Json -Depth 40 -Compress)
  $event=[pscustomobject][ordered]@{schemaVersion=1;seq=$Sequence;importId=[string]$Validated.Record.importId;at=$At;previousEntryHash=$PreviousHash;recordHash=[string]$Validated.Hash;record=$Validated.Record;entryHash=$entryHash}
  return [pscustomobject]@{Event=$event;Line=(($event|ConvertTo-Json -Depth 40 -Compress)+"`n");EntryHash=$entryHash}
}

function Get-ExperienceImportSnapshot {
  param([string]$Root)
  $path=Join-Path (Join-Path $Root $script:StateName) $script:ExperienceImportName
  if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Path=$path;Bytes=[byte[]]@();HeadHash=$null;Count=0;Records=@()}}
  $bytes=Read-StrictBytes $path $script:MaxLogBytes 'experience-import-log-invalid';$text=$script:Utf8.GetString($bytes)
  if([string]::IsNullOrEmpty($text)-or-not$text.EndsWith("`n",[StringComparison]::Ordinal)-or$text.Contains("`r")){Throw-StoreError 1 'experience-import-log-invalid' 'Experience import log must be LF-terminated JSONL'}
  $lines=@($text.Substring(0,$text.Length-1).Split("`n"));$previous=$null;$records=@();$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$semantics=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  for($i=0;$i-lt$lines.Count;$i++){
    try{$event=$lines[$i]|ConvertFrom-Json -ErrorAction Stop}catch{Throw-StoreError 1 'experience-import-log-invalid' 'Malformed experience import JSONL'}
    if(-not(Test-ClosedObject $event @('schemaVersion','seq','importId','at','previousEntryHash','recordHash','record','entryHash'))-or$event.schemaVersion-ne1-or$event.seq-isnot[int]-or$event.seq-ne($i+1)-or-not(Test-GoalIdentifier $event.importId)-or-not(Test-Rfc3339 $event.at)-or
       (($i-eq0)-and$null-ne$event.previousEntryHash)-or(($i-gt0)-and$event.previousEntryHash-cne$previous)-or-not(Test-Hash $event.recordHash)-or-not(Test-Hash $event.entryHash)){Throw-StoreError 1 'experience-import-log-invalid' 'Invalid experience import event envelope'}
    try{$validated=Convert-ExperienceImportRecord $Root $event.record}catch{if($_.Exception.Data.Contains('ExitCode')){Throw-StoreError 1 'experience-import-log-invalid' $_.Exception.Message};throw}
    $prefix=[pscustomobject][ordered]@{schemaVersion=1;seq=$event.seq;importId=$event.importId;at=$event.at;previousEntryHash=$event.previousEntryHash;recordHash=$event.recordHash;record=$event.record}
    if($validated.Hash-cne$event.recordHash-or$validated.Record.importId-cne$event.importId-or(Get-HashText ($prefix|ConvertTo-Json -Depth 40 -Compress))-cne$event.entryHash-or-not$ids.Add([string]$event.importId)){Throw-StoreError 1 'experience-import-log-invalid' 'Experience import hash chain or identity is invalid'}
    foreach($entry in @($validated.Record.entries)){$semantic=('{0}|{1}|{2}|{3}'-f$entry.problemInvariantId,$entry.strategyFamilyId,$entry.materialPreconditionHash,$entry.outcome);if(-not$semantics.Add($semantic)){Throw-StoreError 1 'experience-import-log-invalid' 'Experience import log repeats a semantic identity'}}
    $records+=@($validated.Record);$previous=[string]$event.entryHash
  }
  return [pscustomobject]@{Path=$path;Bytes=$bytes;HeadHash=$previous;Count=$lines.Count;Records=@($records)}
}

function Get-GoalSnapshot {
  param([string]$Root,[switch]$RepairLayout)
  $state=Join-Path $Root $script:StateName;$goals=Join-Path $state $script:GoalDirectoryName
  if(-not(Test-Path -LiteralPath $goals -PathType Container)){if($RepairLayout){[IO.Directory]::CreateDirectory($goals)|Out-Null}else{Throw-StoreError 1 'store-upgrade-required' 'Goal lineage directory is missing; run Rebuild at an idle controller safe point'}}
  $item=Get-Item -LiteralPath $goals -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-StoreError 1 'controller-path-unsafe' 'Goal directory is a reparse point'}
  $heads=@();$ids=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
  foreach($child in @(Get-ChildItem -LiteralPath $goals -Force)){
    if($child.PSIsContainer-or($child.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$child.Name-cnotmatch'^[0-9a-f]{64}\.jsonl$'){Throw-StoreError 1 'goal-layout-invalid' "Invalid goal child: $($child.FullName)"}
    $log=Read-GoalLog $child.FullName;if((Get-Key $log.GoalLineageId)+'.jsonl'-cne$child.Name-or$ids.ContainsKey($log.GoalLineageId)){Throw-StoreError 1 'goal-layout-invalid' "Goal identity conflict: $($child.FullName)"};$ids[$log.GoalLineageId]=$true;$heads+=$log
  }
  $descriptors=@($heads|Sort-Object GoalLineageId|ForEach-Object{[pscustomobject][ordered]@{goalLineageId=$_.GoalLineageId;headEntryHash=$_.HeadHash;recordHash=$_.RecordHash}})
  $goalWatermark=Get-HashText (ConvertTo-Json -InputObject @($descriptors) -Depth 5 -Compress);$imports=Get-ExperienceImportSnapshot $Root;$importWatermark=if($null-eq$imports.HeadHash){Get-HashText 'EMPTY'}else{[string]$imports.HeadHash}
  $watermark=Get-HashText (([pscustomobject][ordered]@{goalWatermark=$goalWatermark;importWatermark=$importWatermark})|ConvertTo-Json -Compress)
  $map=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal);$total=0;$latest='1970-01-01T00:00:00Z'
  foreach($head in $heads){
    if([DateTimeOffset]::Parse($head.Record.updatedAt)-gt[DateTimeOffset]::Parse($latest)){$latest=[string]$head.Record.updatedAt}
    foreach($lane in @($head.Record.lanes)){foreach($outcome in @($lane.outcomes|Where-Object{$_.outcome-in@('accepted-success','deterministic-failure')})){
      $total++;$r=$outcome.reservation;$key=('{0}|{1}|{2}|{3}'-f$r.problemInvariantId,$r.strategyFamilyId,$r.materialPreconditionHash,$outcome.outcome)
      if($map.ContainsKey($key)){$count=[int]$map[$key].count+1}else{$count=1}
      if(-not$map.ContainsKey($key)-or[DateTimeOffset]::Parse($outcome.finishedAt)-ge[DateTimeOffset]::Parse($map[$key].observedAt)){
        $map[$key]=[pscustomobject][ordered]@{problemInvariantId=$r.problemInvariantId;strategyFamilyId=$r.strategyFamilyId;materialPreconditions=$r.materialPreconditions;materialPreconditionHash=$r.materialPreconditionHash;outcome=$outcome.outcome;failureClass=$outcome.failureClass;evidenceHash=$outcome.evidenceHash;sourceGoalLineageId=$head.GoalLineageId;sourceReservationId=$r.reservationId;sourceImportId=$null;sourceExperienceId=$null;sourceChainId=$null;sourceEntryHash=$null;observedAt=$outcome.finishedAt;count=$count}
      }else{$map[$key].count=$count}
    }}
  }
  foreach($import in @($imports.Records)){foreach($entry in @($import.entries)){
    $total++;$key=('{0}|{1}|{2}|{3}'-f$entry.problemInvariantId,$entry.strategyFamilyId,$entry.materialPreconditionHash,$entry.outcome);$count=if($map.ContainsKey($key)){[int]$map[$key].count+1}else{1}
    if(-not$map.ContainsKey($key)-or[DateTimeOffset]::Parse($entry.observedAt)-ge[DateTimeOffset]::Parse($map[$key].observedAt)){$map[$key]=[pscustomobject][ordered]@{problemInvariantId=$entry.problemInvariantId;strategyFamilyId=$entry.strategyFamilyId;materialPreconditions=$entry.materialPreconditions;materialPreconditionHash=$entry.materialPreconditionHash;outcome=$entry.outcome;failureClass=$entry.failureClass;evidenceHash=$entry.evidenceHash;sourceGoalLineageId=$null;sourceReservationId=$null;sourceImportId=$import.importId;sourceExperienceId=$entry.experienceId;sourceChainId=$entry.sourceChainId;sourceEntryHash=$entry.sourceEntryHash;observedAt=$entry.observedAt;count=$count}}else{$map[$key].count=$count}
    if([DateTimeOffset]::Parse($entry.observedAt)-gt[DateTimeOffset]::Parse($latest)){$latest=[string]$entry.observedAt}
  }}
  $entries=@($map.Values|Sort-Object @{Expression={[DateTimeOffset]::Parse($_.observedAt)};Descending=$true},problemInvariantId,strategyFamilyId|Select-Object -First 1000)
  $index=[pscustomobject][ordered]@{schemaVersion=1;generator='onboard-code-projects';sourceWatermark=$watermark;sourceGoalCount=$heads.Count;sourceImportWatermark=$importWatermark;sourceImportCount=$imports.Count;totalExperienceCount=$total;updatedAt=$latest;entries=@($entries)}
  return [pscustomobject]@{Heads=@($heads);Imports=$imports;Watermark=$watermark;ExperienceIndex=$index}
}

function Get-ExperienceBytes {
  param($GoalSnapshot)
  return $script:Utf8.GetBytes(($GoalSnapshot.ExperienceIndex|ConvertTo-Json -Depth 20 -Compress)+"`n")
}

function Write-GoalDerived {
  param([string]$Root,$GoalSnapshot)
  Write-AtomicBytes (Join-Path (Join-Path $Root $script:StateName) $script:ExperienceIndexName) (Get-ExperienceBytes $GoalSnapshot)
}

function Read-ExperienceIndex {
  param([string]$Root,$GoalSnapshot)
  $path=Join-Path (Join-Path $Root $script:StateName) $script:ExperienceIndexName
  $read=Read-StrictJson $path $script:MaxIndexBytes 'experience-index-invalid';$fields=@('schemaVersion','generator','sourceWatermark','sourceGoalCount','sourceImportWatermark','sourceImportCount','totalExperienceCount','updatedAt','entries')
  if(-not(Test-ClosedObject $read.Object $fields)-or$read.Object.schemaVersion-ne1-or$read.Object.generator-cne'onboard-code-projects'-or-not(Test-Hash $read.Object.sourceWatermark)-or$read.Object.sourceGoalCount-isnot[int]-or$read.Object.sourceGoalCount-lt0-or
     -not(Test-Hash $read.Object.sourceImportWatermark)-or$read.Object.sourceImportCount-isnot[int]-or$read.Object.sourceImportCount-lt0-or
     $read.Object.totalExperienceCount-isnot[int]-or$read.Object.totalExperienceCount-lt0-or-not(Test-Rfc3339 $read.Object.updatedAt)-or$read.Object.entries-isnot[Array]-or@($read.Object.entries).Count-gt1000){Throw-StoreError 1 'experience-index-invalid' 'Invalid experience index'}
  $expected=Get-ExperienceBytes $GoalSnapshot
  if($read.Object.sourceWatermark-cne$GoalSnapshot.Watermark-or$read.Object.sourceGoalCount-ne@($GoalSnapshot.Heads).Count-or
     (Get-HashBytes $read.Bytes)-cne(Get-HashBytes $expected)){Throw-StoreError 1 'experience-index-stale' 'Experience index does not exactly match canonical goal logs; run Rebuild'}
  return $read.Object
}

function Test-GoalEqual {
  param($Left,$Right)
  return (ConvertTo-CanonicalRecord $Left)-ceq(ConvertTo-CanonicalRecord $Right)
}

function Test-KnownDeterministicFailure {
  param($GoalSnapshot,$Reservation)
  # ponytail: linear canonical scan keeps the derived index bounded; shard it only if dispatch latency becomes material above thousands of goals.
  foreach($head in @($GoalSnapshot.Heads)){foreach($lane in @($head.Record.lanes)){foreach($outcome in @($lane.outcomes|Where-Object{$_.outcome-ceq'deterministic-failure'})){$prior=$outcome.reservation;if($prior.problemInvariantId-ceq$Reservation.problemInvariantId-and$prior.strategyFamilyId-ceq$Reservation.strategyFamilyId-and$prior.materialPreconditionHash-ceq$Reservation.materialPreconditionHash){return $true}}}}
  foreach($import in @($GoalSnapshot.Imports.Records)){foreach($entry in @($import.entries|Where-Object{$_.outcome-ceq'deterministic-failure'})){if($entry.problemInvariantId-ceq$Reservation.problemInvariantId-and$entry.strategyFamilyId-ceq$Reservation.strategyFamilyId-and$entry.materialPreconditionHash-ceq$Reservation.materialPreconditionHash){return $true}}}
  return $false
}

function Assert-MaterialChangeEvidence {
  param([string]$Root,$Previous,$Candidate)
  $fields=@('contractVersionHash','targetSetHash','capabilitySetHash','runtimeVersionHash','toolchainVersionHash','authorizationBoundaryHash','failureOracleHash','relevantContentHash');$changed=@()
  foreach($field in $fields){if($Previous.materialPreconditions.$field-cne$Candidate.materialPreconditions.$field){$changed+=@($field)}}
  $evidence=@();if(@(Get-Names $Candidate)-ccontains'materialChangeEvidence'){$evidence=@($Candidate.materialChangeEvidence)}
  if($evidence.Count-ne$changed.Count){Throw-StoreError 2 'goal-transition-invalid' 'Every changed material precondition requires one direct evidence row'}
  foreach($field in $changed){
    $rows=@($evidence|Where-Object{$_.field-ceq$field})
    if($rows.Count-ne1-or$rows[0].previousHash-cne$Previous.materialPreconditions.$field-or$rows[0].currentHash-cne$Candidate.materialPreconditions.$field){Throw-StoreError 2 'goal-transition-invalid' 'Material evidence does not bind the exact previous and current field values'}
    try{$source=Get-CanonicalChainEvidence $Root ([string]$rows[0].sourceChainId) ([string]$rows[0].sourceEntryHash) ([string]$rows[0].evidenceHash) ([string]$rows[0].observedAt)}catch{Throw-StoreError 2 'goal-transition-invalid' $_.Exception.Message}
    if(-not(Test-ContainsMaterialEvidence $source.record $field ([string]$rows[0].previousHash) ([string]$rows[0].currentHash) ([string]$rows[0].evidenceHash) ([string]$rows[0].observedAt))){Throw-StoreError 2 'goal-transition-invalid' 'Material evidence does not directly prove the exact changed field values'}
    if([DateTimeOffset]::Parse($rows[0].observedAt)-gt[DateTimeOffset]::Parse($Candidate.reservedAt)){Throw-StoreError 2 'goal-transition-invalid' 'Material evidence is newer than the reservation'}
  }
}

function Test-GoalTransition {
  param([string]$Root,$Current,$Candidate,$GoalSnapshot)
  if($Current.state-ceq'terminal'){Throw-StoreError 1 'goal-terminal' 'Terminal goal lineage is immutable'}
  if($Candidate.goalLineageId-cne$Current.goalLineageId-or$Candidate.objectiveFingerprint-cne$Current.objectiveFingerprint-or$Candidate.createdAt-cne$Current.createdAt-or@($Candidate.lanes).Count-ne@($Current.lanes).Count){Throw-StoreError 2 'goal-transition-invalid' 'Goal identity or lane set changed'}
  if([DateTimeOffset]::Parse($Candidate.updatedAt)-le[DateTimeOffset]::Parse($Current.updatedAt)){Throw-StoreError 2 'goal-transition-invalid' 'Goal update time must advance'}
  for($i=0;$i-lt@($Current.lanes).Count;$i++){if($Candidate.lanes[$i].projectRoot-cne$Current.lanes[$i].projectRoot){Throw-StoreError 2 'goal-transition-invalid' 'Goal lane order or identity changed'}}
  if($Candidate.budget.readinessReplansUsed-lt$Current.budget.readinessReplansUsed-or$Candidate.budget.readinessReplansUsed-gt($Current.budget.readinessReplansUsed+1)-or
     $Candidate.budget.crossProjectRebaselinesUsed-lt$Current.budget.crossProjectRebaselinesUsed-or$Candidate.budget.crossProjectRebaselinesUsed-gt($Current.budget.crossProjectRebaselinesUsed+1)){Throw-StoreError 2 'goal-transition-invalid' 'Goal budget changed outside one bounded transition'}
  $currentReadiness=@($Current.readinessFailures);$candidateReadiness=@($Candidate.readinessFailures)
  if($candidateReadiness.Count-lt$currentReadiness.Count-or$candidateReadiness.Count-gt($currentReadiness.Count+1)){Throw-StoreError 2 'goal-transition-invalid' 'Readiness evidence was removed or batched'}
  for($i=0;$i-lt$currentReadiness.Count;$i++){if(-not(Test-GoalEqual $currentReadiness[$i] $candidateReadiness[$i])){Throw-StoreError 2 'goal-transition-invalid' 'Readiness history changed'}}
  $readinessAdded=$candidateReadiness.Count-$currentReadiness.Count
  if($readinessAdded-eq1){
    if($currentReadiness.Count-eq0){if($Candidate.budget.readinessReplansUsed-ne1){Throw-StoreError 2 'goal-transition-invalid' 'First readiness failure must consume the single replan'}}
    elseif($Candidate.budget.readinessReplansUsed-ne$Current.budget.readinessReplansUsed){Throw-StoreError 2 'goal-transition-invalid' 'Second readiness failure cannot create another replan'}
  }elseif($Candidate.budget.readinessReplansUsed-ne$Current.budget.readinessReplansUsed){Throw-StoreError 2 'goal-transition-invalid' 'Readiness budget changed without evidence'}
  $laneChanges=0;$newRebaselines=0
  for($i=0;$i-lt@($Current.lanes).Count;$i++){
    $before=$Current.lanes[$i];$after=$Candidate.lanes[$i]
    if(Test-GoalEqual $before $after){continue}
    $laneChanges++
    $beforeOutcomes=@($before.outcomes);$afterOutcomes=@($after.outcomes)
    if($afterOutcomes.Count-lt$beforeOutcomes.Count-or$afterOutcomes.Count-gt($beforeOutcomes.Count+1)){Throw-StoreError 2 'goal-transition-invalid' 'Lane outcomes were removed or batched'}
    for($j=0;$j-lt$beforeOutcomes.Count;$j++){if(-not(Test-GoalEqual $beforeOutcomes[$j] $afterOutcomes[$j])){Throw-StoreError 2 'goal-transition-invalid' 'Lane history changed'}}
    if($null-ne$before.activeReservation){
      if($null-ne$after.activeReservation-or$afterOutcomes.Count-ne($beforeOutcomes.Count+1)-or-not(Test-GoalEqual $afterOutcomes[-1].reservation $before.activeReservation)-or$after.attemptsUsed-ne$before.attemptsUsed-or$after.transientRetriesUsed-ne$before.transientRetriesUsed){Throw-StoreError 2 'goal-transition-invalid' 'Only the exact active reservation may finish'}
    }else{
      if($null-eq$after.activeReservation-or$afterOutcomes.Count-ne$beforeOutcomes.Count){Throw-StoreError 2 'goal-transition-invalid' 'Lane transition must reserve one strategy or finish one active strategy'}
      if($beforeOutcomes.Count-gt0-and$beforeOutcomes[-1].outcome-in@('accepted-success','cancelled','authorization-declined')){Throw-StoreError 2 'goal-transition-invalid' 'A completed, cancelled, or authorization-declined lane cannot reserve another strategy'}
      $reservation=$after.activeReservation
      if($after.attemptsUsed-ne($before.attemptsUsed+1)-or$after.transientRetriesUsed-ne$before.transientRetriesUsed-or$reservation.attemptNumber-ne$after.attemptsUsed){Throw-StoreError 2 'goal-transition-invalid' 'Business strategy budget changed incorrectly'}
      if($beforeOutcomes.Count-gt0){$previousReservation=$beforeOutcomes[-1].reservation;if($reservation.problemInvariantId-cne$previousReservation.problemInvariantId){Throw-StoreError 2 'goal-transition-invalid' 'A goal lane cannot rename its problem invariant'};Assert-MaterialChangeEvidence $Root $previousReservation $reservation}
      elseif(@(Get-Names $reservation)-ccontains'materialChangeEvidence'-and@($reservation.materialChangeEvidence).Count-gt0){Throw-StoreError 2 'goal-transition-invalid' 'An initial reservation cannot claim predecessor material changes'}
      if($reservation.strategy-ceq'rebaseline'){$newRebaselines++}
      if(Test-KnownDeterministicFailure $GoalSnapshot $reservation){Throw-StoreError 1 'goal-known-deterministic-failure' 'The same deterministic strategy family already failed under identical material preconditions'}
    }
  }
  if($readinessAdded-gt0-and$laneChanges-gt0){Throw-StoreError 2 'goal-transition-invalid' 'Readiness replan and implementation reservation must be separate atomic decisions'}
  $crossDelta=$Candidate.budget.crossProjectRebaselinesUsed-$Current.budget.crossProjectRebaselinesUsed
  if(($newRebaselines-ge2-and$crossDelta-ne1)-or($newRebaselines-lt2-and$crossDelta-ne0)){Throw-StoreError 2 'goal-transition-invalid' 'Cross-project rebaseline must reserve every affected lane atomically'}
  if($Candidate.state-ceq'terminal'){
    if($laneChanges-ne0-or$readinessAdded-ne0-or@($Candidate.lanes|Where-Object{$null-ne$_.activeReservation}).Count-gt0){Throw-StoreError 2 'goal-transition-invalid' 'Goal terminal transition must be a separate decision with no active reservation'}
  }elseif($Candidate.state-cne'active'){Throw-StoreError 2 'goal-transition-invalid' 'Invalid goal state transition'}
  if($laneChanges-eq0-and$readinessAdded-eq0-and$Candidate.state-ceq$Current.state){Throw-StoreError 2 'goal-transition-invalid' 'Goal update has no canonical state change'}
}

function Get-Relative {
  param([string]$Root,[string]$Path)
  return $Path.Substring($Root.TrimEnd('\').Length+1).Replace('\','/')
}

function Get-StoreSnapshot {
  param([string]$Root,[switch]$RepairLayout,[int]$MaxRecentTerminal=500)
  $state=Join-Path $Root $script:StateName;$active=Join-Path $state 'active';$archive=Join-Path $state 'archive'
  if(-not(Test-Path -LiteralPath $active -PathType Container)-or -not(Test-Path -LiteralPath $archive -PathType Container)){Throw-StoreError 1 'store-not-initialized' 'Store directories are missing'}
  foreach($directory in @($state,$active,$archive)){if(((Get-Item -LiteralPath $directory -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-StoreError 1 'controller-path-unsafe' 'Store directory is a reparse point'}}
  $heads=@();$ids=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
  $activeFiles=@(Get-ChildItem -LiteralPath $active -Force)
  foreach($item in $activeFiles){
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$item.Name-cnotmatch'^[0-9a-f]{64}\.jsonl$'){Throw-StoreError 1 'store-layout-invalid' "Invalid active child: $($item.FullName)"}
    $log=Read-Log $item.FullName
    if((Get-Key $log.ChainId)+'.jsonl'-cne$item.Name){Throw-StoreError 1 'store-layout-invalid' "Active key mismatch: $($item.FullName)"}
    if($log.Record.state -cne 'active'){
      if(-not$RepairLayout){Throw-StoreError 1 'store-layout-invalid' "Terminal log remains in active/: $($item.FullName)"}
      $month=([DateTimeOffset]::Parse($log.Record.updatedAt)).ToString('yyyy-MM');$destDir=Join-Path $archive $month;[IO.Directory]::CreateDirectory($destDir)|Out-Null;$dest=Join-Path $destDir $item.Name
      if(Test-Path -LiteralPath $dest){Throw-StoreError 1 'store-layout-invalid' "Archive destination already exists: $dest"}
      [IO.File]::Move($item.FullName,$dest);$log.Path=$dest
    }
    if($ids.ContainsKey($log.ChainId)){Throw-StoreError 1 'store-layout-invalid' "Duplicate CHAIN: $($log.ChainId)"};$ids[$log.ChainId]=$true;$heads+=$log
  }
  foreach($monthItem in @(Get-ChildItem -LiteralPath $archive -Force)){
    if(-not$monthItem.PSIsContainer-or($monthItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$monthItem.Name-cnotmatch'^\d{4}-(?:0[1-9]|1[0-2])$'){Throw-StoreError 1 'store-layout-invalid' "Invalid archive child: $($monthItem.FullName)"}
    foreach($item in @(Get-ChildItem -LiteralPath $monthItem.FullName -Force)){
      if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$item.Name-cnotmatch'^[0-9a-f]{64}\.jsonl$'){Throw-StoreError 1 'store-layout-invalid' "Invalid archive log: $($item.FullName)"}
      $log=Read-Log $item.FullName
      if((Get-Key $log.ChainId)+'.jsonl' -cne $item.Name-or $log.Record.state -cne 'terminal'-or([DateTimeOffset]::Parse($log.Record.updatedAt)).ToString('yyyy-MM') -cne $monthItem.Name){Throw-StoreError 1 'store-layout-invalid' "Archive identity/state/month mismatch: $($item.FullName)"}
      if($ids.ContainsKey($log.ChainId)){Throw-StoreError 1 'store-layout-invalid' "Duplicate CHAIN: $($log.ChainId)"};$ids[$log.ChainId]=$true;$heads+=$log
    }
  }
  $allItems=@()
  foreach($head in @($heads|Sort-Object ChainId)){
    $allItems += [pscustomobject][ordered]@{chainId=$head.ChainId;state=$head.Record.state;phase=$head.Record.phase;status=$head.Record.status;updatedAt=$head.Record.updatedAt;objective=$head.Record.objective;nextAction=$head.Record.nextAction;headEntryHash=$head.HeadHash;recordHash=$head.RecordHash;path=(Get-Relative $Root $head.Path)}
  }
  $activeItems=@($allItems|Where-Object{$_.state -ceq 'active'}|Sort-Object chainId)
  $terminalItems=@($allItems|Where-Object{$_.state -ceq 'terminal'}|Sort-Object @{Expression={[DateTimeOffset]::Parse($_.updatedAt)};Descending=$true},chainId|Select-Object -First $MaxRecentTerminal)
  $items=@($activeItems)+@($terminalItems);$activeCount=$activeItems.Count;$terminalCount=$allItems.Count-$activeCount
  $latest='1970-01-01T00:00:00Z';if($allItems.Count -gt 0){$latest=[string]((@($allItems|Sort-Object @{Expression={[DateTimeOffset]::Parse($_.updatedAt)};Descending=$true},chainId))[0].updatedAt)}
  $index=[pscustomobject][ordered]@{schemaVersion=1;generator='onboard-code-projects';updatedAt=$latest;activeCount=$activeCount;terminalCount=$terminalCount;items=@($items)}
  return [pscustomobject]@{Index=$index;Heads=@($heads)}
}

function ConvertTo-SafeLine {
  param([string]$Value,[int]$Limit=220)
  $line = (($Value -replace '[\r\n|]+', ' ') -replace '\s+', ' ').Trim()
  if ($line.Length -gt $Limit) { return $line.Substring(0, $Limit - 1) + '...' }
  return $line
}

function Get-ViewBytes {
  param($Index, $ConfigInfo)
  $sort = @(
    @{ Expression = { [DateTimeOffset]::Parse($_.updatedAt) }; Descending = $true },
    @{ Expression = { $_.chainId }; Descending = $false }
  )
  $active = @($Index.items | Where-Object { $_.state -ceq 'active' } | Sort-Object -Property $sort)
  $terminal = @($Index.items | Where-Object { $_.state -ceq 'terminal' } | Sort-Object -Property $sort)
  $memory = New-Object Collections.Generic.List[string]
  $memoryHeader = @(
    '# Controller Memory',
    '',
    '- Canonical task truth: state/active and state/archive; use tools/chain-store.ps1 -Action Get -ChainId ID.',
    '- state/index.json, this file, and the task dashboard are generated and rebuildable.',
    ('- Active tasks: {0}; terminal tasks: {1}.' -f $Index.activeCount, $Index.terminalCount),
    '- Never store credentials, secrets, full logs, or full diffs here.',
    '',
    '## Active tasks'
  )
  foreach ($line in $memoryHeader) { [void]$memory.Add($line) }
  $shown = 0
  foreach ($item in $active) {
    if ($shown -ge $ConfigInfo.Config.maxMemoryItems) { break }
    $line = '- {0} | {1} / {2} | next: {3}' -f $item.chainId, (ConvertTo-SafeLine $item.phase 50), (ConvertTo-SafeLine $item.status 50), (ConvertTo-SafeLine $item.nextAction 220)
    [void]$memory.Add($line)
    $shown++
    $candidate = [string]::Join("`n", [string[]]$memory) + "`n"
    if ($memory.Count -gt $ConfigInfo.Config.maxMemoryLines -or $script:Utf8.GetByteCount($candidate) -gt $ConfigInfo.Config.maxMemoryBytes) {
      $memory.RemoveAt($memory.Count - 1)
      $shown--
      break
    }
  }
  if ($active.Count -eq 0) { [void]$memory.Add('- None.') }
  elseif ($shown -lt $active.Count) { [void]$memory.Add(('- ... {0} more active tasks; query state/index.json.' -f ($active.Count - $shown))) }
  $memoryText = [string]::Join("`n", [string[]]$memory) + "`n"
  while (($memory.Count -gt $ConfigInfo.Config.maxMemoryLines -or $script:Utf8.GetByteCount($memoryText) -gt $ConfigInfo.Config.maxMemoryBytes) -and $memory.Count -gt 8) {
    $memory.RemoveAt($memory.Count - 2)
    $memoryText = [string]::Join("`n", [string[]]$memory) + "`n"
  }
  if ($memory.Count -gt $ConfigInfo.Config.maxMemoryLines -or $script:Utf8.GetByteCount($memoryText) -gt $ConfigInfo.Config.maxMemoryBytes) {
    Throw-StoreError 1 'store-view-limit' 'Unable to satisfy startup memory limits'
  }

  $dashboard = New-Object Collections.Generic.List[string]
  $dashboardHeader = @(
    '# Controller Tasks',
    '',
    '- Generated view; canonical records live under state/.',
    ('- Active: {0}; terminal: {1}; generated from state at {2}.' -f $Index.activeCount, $Index.terminalCount, $Index.updatedAt),
    '',
    '## Active tasks'
  )
  foreach ($line in $dashboardHeader) { [void]$dashboard.Add($line) }
  $limit = [int]$ConfigInfo.Config.maxDashboardItems
  $shown = 0
  foreach ($item in $active) {
    if ($shown -ge $limit) { break }
    [void]$dashboard.Add(('- {0} | {1} / {2} | {3} | next: {4}' -f $item.chainId, (ConvertTo-SafeLine $item.phase 50), (ConvertTo-SafeLine $item.status 50), (ConvertTo-SafeLine $item.objective 180), (ConvertTo-SafeLine $item.nextAction 180)))
    $shown++
  }
  if ($active.Count -eq 0) { [void]$dashboard.Add('- None.') }
  elseif ($shown -lt $active.Count) { [void]$dashboard.Add(('- ... {0} more; query state/index.json.' -f ($active.Count - $shown))) }
  [void]$dashboard.Add('')
  [void]$dashboard.Add('## Recent terminal tasks')
  $recent = @($terminal | Select-Object -First 20)
  foreach ($item in $recent) {
    [void]$dashboard.Add(('- {0} | {1} | {2}' -f $item.chainId, (ConvertTo-SafeLine $item.status 50), (ConvertTo-SafeLine $item.objective 220)))
  }
  if ($recent.Count -eq 0) { [void]$dashboard.Add('- None.') }
  return [pscustomobject]@{
    Index = $script:Utf8.GetBytes(($Index | ConvertTo-Json -Depth 20 -Compress) + "`n")
    Memory = $script:Utf8.GetBytes($memoryText)
    Dashboard = $script:Utf8.GetBytes(([string]::Join("`n", [string[]]$dashboard)) + "`n")
  }
}

function Write-Derived {
  param([string]$Root,$Snapshot,$ConfigInfo)
  $bytes=Get-ViewBytes $Snapshot.Index $ConfigInfo
  Write-AtomicBytes (Join-Path (Join-Path $Root $script:StateName) $script:IndexName) $bytes.Index
  Write-AtomicBytes $ConfigInfo.Memory $bytes.Memory
  Write-AtomicBytes $ConfigInfo.Dashboard $bytes.Dashboard
  return $bytes
}

function Read-Index {
  param([string]$Root,[int]$MaxRecentTerminal=500)
  $marker=Join-Path (Join-Path $Root $script:StateName) $script:MarkerName
  if(Test-Path -LiteralPath $marker){Throw-StoreError 1 'store-rebuild-required' 'A prior canonical write requires Rebuild'}
  $read=Read-StrictJson (Join-Path (Join-Path $Root $script:StateName) $script:IndexName) $script:MaxIndexBytes 'store-index-invalid'
  $fields=@('schemaVersion','generator','updatedAt','activeCount','terminalCount','items')
  $items=@($read.Object.items);$indexedActive=@($items|Where-Object{$_.state -ceq 'active'}).Count;$indexedTerminal=@($items|Where-Object{$_.state -ceq 'terminal'}).Count
  if(-not(Test-ClosedObject $read.Object $fields)-or $read.Object.schemaVersion -ne 1-or $read.Object.generator -cne 'onboard-code-projects'-or $read.Object.activeCount -isnot [int]-or $read.Object.activeCount -lt 0-or $read.Object.terminalCount -isnot [int]-or $read.Object.terminalCount -lt 0-or $read.Object.items -is [string]-or $read.Object.items -isnot [System.Collections.IEnumerable]-or $indexedActive -ne $read.Object.activeCount-or $indexedTerminal -ne [Math]::Min($read.Object.terminalCount,$MaxRecentTerminal)-or $items.Count -ne ($indexedActive+$indexedTerminal)){Throw-StoreError 1 'store-index-invalid' 'Invalid derived index'}
  return $read.Object
}

function Enter-StoreLock {
  param([string]$Root)
  $name='Local\onboard-code-projects-'+(Get-HashText $Root.ToUpperInvariant())
  $mutex=New-Object Threading.Mutex($false,$name);$acquired=$false
  try { $acquired = $mutex.WaitOne(5000) }
  catch [Threading.AbandonedMutexException] { $acquired = $true }
  if(-not$acquired){$mutex.Dispose();Throw-StoreError 3 'store-lock-timeout' 'Another controller writer holds the store lock'}
  return $mutex
}

function Assert-CanonicalWriteAllowed {
  param([string]$Root)
  if(Test-Path -LiteralPath (Join-Path (Join-Path $Root $script:StateName) '.task-set-reset-seal.json')){Throw-StoreError 1 'store-task-set-reset-seal-recovery-required' 'Task-set reset seal recovery is required before canonical CHAIN writes'}
  $path=Join-Path $Root '.codex-controller.json'
  if(-not(Test-Path -LiteralPath $path)){return}
  $item=Get-Item -Force -LiteralPath $path
  if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-StoreError 2 'store-controller-manifest-invalid' 'Controller manifest must be a regular file'}
  $read=Read-StrictJson $path 8MB 'store-controller-manifest-invalid';$manifest=$read.Object;$version=Get-PropertyValue $manifest 'schemaVersion';$names=@(Get-Names $manifest)
  if($manifest-is[Array]-or$manifest-is[string]-or$version-isnot[int]-or$version-lt1-or($version-ge3-and$names-cnotcontains'taskSetReset')){Throw-StoreError 2 'store-controller-manifest-invalid' 'Controller manifest reset state is invalid'}
  if($names-cnotcontains'taskSetReset'){return}
  $reset=Get-PropertyValue $manifest 'taskSetReset'
  if($null-eq$reset){return}
  $phase=Get-PropertyValue $reset 'phase'
  if($reset-is[Array]-or$reset-is[string]-or$phase-isnot[string]-or[string]::IsNullOrWhiteSpace($phase)){Throw-StoreError 2 'store-controller-manifest-invalid' 'Controller manifest reset state is invalid'}
  if($phase-cne'completed'){Throw-StoreError 1 'store-task-set-reset-in-progress' 'Canonical CHAIN writes are frozen during task-set reset'}
}

function Exit-StoreLock {
  param($Mutex)
  if($null-eq$Mutex){return};try{$Mutex.ReleaseMutex()}catch{};$Mutex.Dispose()
}

function Invoke-Process {
  param([string]$File,[string[]]$Arguments)
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$File;$info.Arguments=($Arguments|ForEach-Object{'"'+([string]$_).Replace('"','\"')+'"'})-join' ';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try{if(-not$process.WaitForExit(30000)){$process.Kill();Throw-StoreError 3 'validator-timeout' 'Semantic validator timed out'};$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult();$exit=$process.ExitCode}finally{$process.Dispose()}
  return [pscustomobject]@{ExitCode=$exit;Output=$out;Error=$err}
}

function Test-ValidatorFile {
  param([string]$Root,$Config)
  if($null-eq$Config.validatorPath){return $null}
  $path=Resolve-RelativePath $Root ([string]$Config.validatorPath) 'validator'
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or(Get-HashBytes([IO.File]::ReadAllBytes($path)))-cne$Config.validatorHash){Throw-StoreError 1 'validator-changed' 'Semantic validator is missing or changed'}
  return $path
}

function Invoke-TransitionValidator {
  param([string]$Root,$ConfigInfo,$Snapshot,$Candidate)
  $validator=Test-ValidatorFile $Root $ConfigInfo.Config;if($null-eq$validator){return}
  $batchPath=Join-Path $Root ('.chain-store-validation.'+[guid]::NewGuid().ToString('N')+'.json')
  $batch=[pscustomobject][ordered]@{schemaVersion=1;currentRecords=@($Snapshot.Heads|ForEach-Object{$_.Record});candidateRecord=$Candidate}
  try{Write-AtomicText $batchPath (($batch|ConvertTo-Json -Depth 60 -Compress)+"`n");$call=Invoke-Process 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$validator,'-Action','ValidateTransition','-ControllerRoot',$Root,'-BatchPath',$batchPath);if($call.ExitCode -ne 0){Throw-StoreError 1 'task-semantic-invalid' ('Semantic validator rejected the candidate: '+$call.Error.Trim())}}
  finally{if(Test-Path -LiteralPath $batchPath -PathType Leaf){[IO.File]::Delete($batchPath)}}
}

function Get-SourceFiles {
  param([string]$Root,[string]$Ledger,[string]$Archive)
  $ledgerFull=Resolve-ChildPath $Root $Ledger -MustExist -FileOnly;$archiveFull=Resolve-ChildPath $Root $Archive -MustExist
  if(-not(Test-Path -LiteralPath $archiveFull -PathType Container)){Throw-StoreError 2 'migration-source-invalid' 'ArchiveRoot must be a directory'}
  $files=@($ledgerFull)
  foreach($item in @(Get-ChildItem -LiteralPath $archiveFull -Force)){
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$item.Name-cnotmatch'^\d{4}-(?:0[1-9]|1[0-2])\.md$'){Throw-StoreError 2 'migration-source-invalid' "Invalid archive source child: $($item.FullName)"};$files+=$item.FullName
  }
  return [pscustomobject]@{Ledger=$ledgerFull;Archive=$archiveFull;Files=@($files|Sort-Object)}
}

function Get-SourceManifest {
  param([string]$Root,$Sources)
  $entries=@();$parts=@('chain-store-source-v1')
  foreach($file in $Sources.Files){$bytes=Read-StrictBytes $file 16MB 'migration-source-invalid';$relative=Get-Relative $Root $file;$hash=Get-HashBytes $bytes;$entries+=[pscustomobject][ordered]@{relativePath=$relative;hash=$hash;length=[int64]$bytes.Length};$parts+=@($relative,$hash,[string]$bytes.Length)}
  return [pscustomobject]@{Hash=(Get-HashText ($parts-join[char]0));Files=$entries}
}

function Get-MarkdownRecords {
  param([string]$Path)
  $text=$script:Utf8.GetString((Read-StrictBytes $Path 16MB 'migration-source-invalid'))
  $pattern='(?ms)^###[ \t]+(?<id>[A-Za-z0-9][A-Za-z0-9._:-]{0,127})[ \t]*\r?\n(?:[^\r\n]*\r?\n)*?^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$'
  $result=@()
  foreach($match in [regex]::Matches($text,$pattern)){
    try{$payload=$match.Groups['json'].Value|ConvertFrom-Json -ErrorAction Stop}catch{Throw-StoreError 2 'migration-source-invalid' "Malformed task JSON: $Path"}
    $id=Get-PropertyValue $payload 'id';if($null-eq$id){continue}
    if($id-cne$match.Groups['id'].Value){Throw-StoreError 2 'migration-source-invalid' "Heading/task identity mismatch: $Path"}
    $schema=Get-PropertyValue $payload 'schemaVersion';$archiveState=Get-PropertyValue $payload 'archiveState'
    if($null-eq$schema-and$archiveState-ceq'final'){continue}
    $result+=[pscustomobject]@{Id=[string]$id;Payload=$payload;Canonical=($payload|ConvertTo-Json -Depth 60 -Compress);Path=$Path}
  }
  return @($result)
}

function New-ImportedRecord {
  param($Entry,[string]$State)
  $payload=$Entry.Payload;$objective=Get-PropertyValue $payload 'goal';if($null-eq$objective){$objective=Get-PropertyValue $payload 'objective'}
  $record=[pscustomobject][ordered]@{schemaVersion=1;chainId=$Entry.Id;state=$State;phase=[string](Get-PropertyValue $payload 'phase');status=[string](Get-PropertyValue $payload 'status');createdAt=[string](Get-PropertyValue $payload 'createdAt');updatedAt=[string](Get-PropertyValue $payload 'updatedAt');objective=[string]$objective;nextAction=[string](Get-PropertyValue $payload 'nextAction');payload=$payload}
  if (Test-SemanticTerminalSummary $record) { $record.state='terminal' }
  return (Test-Record $record).Record
}

function Resolve-Migration {
  param([string]$Root,[string]$Path)
  $full=Resolve-ChildPath $Root $Path -MustExist
  if(-not(Test-Path -LiteralPath $full -PathType Container)-or(Split-Path -Parent $full)-ine$Root-or[IO.Path]::GetFileName($full)-cnotmatch'^\.chain-store-migration\.[0-9a-f]{32}$'){Throw-StoreError 2 'migration-path-invalid' 'MigrationPath must be an exact generated direct child'}
  return $full
}

function Write-InitialLog {
  param([string]$Root,$Record)
  $validated=Test-Record $Record;$event=New-Event $validated 1 $null 'import' $Record.updatedAt;$key=Get-Key $Record.chainId
  $path=if($Record.state -ceq 'active'){Join-Path (Join-Path (Join-Path $Root $script:StateName) 'active') ($key+'.jsonl')}else{$month=([DateTimeOffset]::Parse($Record.updatedAt)).ToString('yyyy-MM');Join-Path (Join-Path (Join-Path (Join-Path $Root $script:StateName) 'archive') $month) ($key+'.jsonl')}
  [IO.Directory]::CreateDirectory((Split-Path -Parent $path))|Out-Null;[IO.File]::WriteAllBytes($path,$script:Utf8.GetBytes($event.Line))
}

function Prepare-Migration {
  param([string]$Root)
  if([string]::IsNullOrWhiteSpace($LedgerPath)-or[string]::IsNullOrWhiteSpace($ArchiveRoot)){Throw-StoreError 2 'migration-arguments-invalid' 'LedgerPath and ArchiveRoot are required'}
  if((Test-Path -LiteralPath (Join-Path $Root $script:ConfigName)) -or (Test-Path -LiteralPath (Join-Path $Root $script:StateName))){Throw-StoreError 1 'store-already-initialized' 'Existing chain store cannot be migrated over'}
  $hookRelative=$null;$hookHash=$null
  if(-not[string]::IsNullOrWhiteSpace($ValidatorPath)){
    $hook=Resolve-ChildPath $Root $ValidatorPath -MustExist -FileOnly;$toolsPrefix=(Join-Path $Root 'tools')+'\';if(-not$hook.StartsWith($toolsPrefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetExtension($hook)-ine'.ps1'){Throw-StoreError 2 'validator-invalid' 'Validator must be under controller tools/'}
    $hookRelative=Get-Relative $Root $hook;$hookHash=Get-HashBytes ([IO.File]::ReadAllBytes($hook))
    $legacyCall=Invoke-Process 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$hook,'-Action','ValidateLegacy','-ControllerRoot',$Root)
    if($legacyCall.ExitCode -ne 0){Throw-StoreError 1 'migration-semantic-invalid' ('Legacy validator rejected source: '+$legacyCall.Error.Trim())}
  }
  $sources=Get-SourceFiles $Root $LedgerPath $ArchiveRoot;$sourceManifest=Get-SourceManifest $Root $sources
  $activeEntries=Get-MarkdownRecords $sources.Ledger;$archiveEntries=@();foreach($file in $sources.Files){if($file-ine$sources.Ledger){$archiveEntries+=@(Get-MarkdownRecords $file)}}
  $activeMap=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal);foreach($entry in $activeEntries){if($activeMap.ContainsKey($entry.Id)){Throw-StoreError 2 'migration-source-invalid' "Duplicate active CHAIN: $($entry.Id)"};$activeMap[$entry.Id]=$entry}
  $archiveMap=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal);foreach($entry in $archiveEntries){if($archiveMap.ContainsKey($entry.Id)){Throw-StoreError 2 'migration-source-invalid' "Duplicate archive CHAIN: $($entry.Id)"};$archiveMap[$entry.Id]=$entry}
  foreach($id in @($archiveMap.Keys)){if($activeMap.ContainsKey($id)){if($activeMap[$id].Canonical -cne $archiveMap[$id].Canonical){Throw-StoreError 2 'migration-source-invalid' "Pending active/archive records differ: $id"};$activeMap.Remove($id)}}
  $migration=Join-Path $Root ('.chain-store-migration.'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory((Join-Path (Join-Path $migration $script:StateName) 'active'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path (Join-Path $migration $script:StateName) 'archive'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path (Join-Path $migration $script:StateName) $script:GoalDirectoryName))|Out-Null
  $dashboardRelative=Get-Relative $Root $sources.Ledger;$config=Get-DefaultConfig $dashboardRelative $hookRelative $hookHash;$configInfo=Test-Config $config $migration
  Write-AtomicText (Join-Path $migration $script:ConfigName) (($config|ConvertTo-Json -Depth 10 -Compress)+"`n")
  foreach($entry in $activeMap.Values){Write-InitialLog $migration (New-ImportedRecord $entry 'active')};foreach($entry in $archiveMap.Values){Write-InitialLog $migration (New-ImportedRecord $entry 'terminal')}
  $snapshot=Get-StoreSnapshot $migration -MaxRecentTerminal $config.maxDashboardItems;[void](Write-Derived $migration $snapshot $configInfo);$goalSnapshot=Get-GoalSnapshot $migration;Write-GoalDerived $migration $goalSnapshot
  $manifest=[pscustomobject][ordered]@{schemaVersion=1;sourceHash=$sourceManifest.Hash;ledgerPath=(Get-Relative $Root $sources.Ledger);archiveRoot=(Get-Relative $Root $sources.Archive);files=$sourceManifest.Files;activeCount=$snapshot.Index.activeCount;terminalCount=$snapshot.Index.terminalCount;totalCount=($snapshot.Index.activeCount+$snapshot.Index.terminalCount);validatorHash=$hookHash}
  Write-AtomicText (Join-Path $migration '.migration.json') (($manifest|ConvertTo-Json -Depth 10 -Compress)+"`n")
  return [pscustomobject]@{Migration=$migration;Manifest=$manifest;Snapshot=$snapshot}
}

function Verify-Migration {
  param([string]$Root,[string]$Path,[string]$Expected)
  $migration=Resolve-Migration $Root $Path;$manifestRead=Read-StrictJson (Join-Path $migration '.migration.json') 1MB 'migration-invalid';$manifest=$manifestRead.Object
  $fields=@('schemaVersion','sourceHash','ledgerPath','archiveRoot','files','activeCount','terminalCount','totalCount','validatorHash')
  if(-not(Test-ClosedObject $manifest $fields)-or $manifest.schemaVersion -ne 1-or -not(Test-Hash $manifest.sourceHash)-or(-not[string]::IsNullOrWhiteSpace($Expected)-and $manifest.sourceHash -cne $Expected)){Throw-StoreError 1 'migration-invalid' 'Migration manifest is invalid or does not match expected source'}
  $sources=Get-SourceFiles $Root (Join-Path $Root $manifest.ledgerPath) (Join-Path $Root $manifest.archiveRoot);$current=Get-SourceManifest $Root $sources
  if($current.Hash -cne $manifest.sourceHash){Throw-StoreError 1 'migration-source-conflict' 'Legacy source changed after migration preparation'}
  $configInfo=Read-Config $migration;$snapshot=Get-StoreSnapshot $migration -MaxRecentTerminal $configInfo.Config.maxDashboardItems;$bytes=Get-ViewBytes $snapshot.Index $configInfo;$goalSnapshot=Get-GoalSnapshot $migration;$experienceBytes=Get-ExperienceBytes $goalSnapshot
  if($snapshot.Index.activeCount -ne $manifest.activeCount-or $snapshot.Index.terminalCount -ne $manifest.terminalCount-or ($snapshot.Index.activeCount+$snapshot.Index.terminalCount) -ne $manifest.totalCount){Throw-StoreError 1 'migration-invalid' 'Migration record counts changed'}
  foreach($pair in @(@((Join-Path (Join-Path $migration $script:StateName) $script:IndexName),$bytes.Index),@((Join-Path (Join-Path $migration $script:StateName) $script:ExperienceIndexName),$experienceBytes),@($configInfo.Memory,$bytes.Memory),@($configInfo.Dashboard,$bytes.Dashboard))){if(-not(Test-Path -LiteralPath $pair[0] -PathType Leaf)-or(Get-HashBytes([IO.File]::ReadAllBytes($pair[0])))-cne(Get-HashBytes([byte[]]$pair[1]))){Throw-StoreError 1 'migration-invalid' "Migration derived file mismatch: $($pair[0])"}}
  return [pscustomobject]@{Migration=$migration;Manifest=$manifest;Snapshot=$snapshot;ConfigInfo=$configInfo;Sources=$sources}
}

$root=$null
try{
  $root=Resolve-Root $ControllerRoot
  if($Action-ceq'Initialize'){
    $mutex=Enter-StoreLock $root
    try{
      Assert-CanonicalWriteAllowed $root
      $configPath=Join-Path $root $script:ConfigName
      if(Test-Path -LiteralPath $configPath){$configInfo=Read-Config $root}else{$config=Get-DefaultConfig;Write-AtomicText $configPath (($config|ConvertTo-Json -Depth 10 -Compress)+"`n");$configInfo=Test-Config $config $root}
      [IO.Directory]::CreateDirectory((Join-Path (Join-Path $root $script:StateName) 'active'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path (Join-Path $root $script:StateName) 'archive'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path (Join-Path $root $script:StateName) $script:GoalDirectoryName))|Out-Null
      $snapshot=Get-StoreSnapshot $root -MaxRecentTerminal $configInfo.Config.maxDashboardItems;[void](Write-Derived $root $snapshot $configInfo);$goalSnapshot=Get-GoalSnapshot $root;Write-GoalDerived $root $goalSnapshot
    }finally{Exit-StoreLock $mutex}
    Write-StoreResult initialized 'store-initialized' $root $null $null $null $null $snapshot.Index 'Use Read for the compact index or Put with ExpectedEntryHash=MISSING.' @() 0
  }
  if($Action-ceq'Read'){$configInfo=Read-Config $root;$index=Read-Index $root $configInfo.Config.maxDashboardItems;$goalSnapshot=Get-GoalSnapshot $root;[void](Read-ExperienceIndex $root $goalSnapshot);Write-StoreResult verified 'store-read' $root $null $null $null $null $index 'Use Get with one exact ChainId or GoalGet with one exact GoalLineageId.' @() 0}
  if($Action-ceq'Get'){
    if([string]::IsNullOrWhiteSpace($ChainId)-or$ChainId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'){Throw-StoreError 2 'chain-id-invalid' 'Get requires a valid ChainId'}
    $configInfo=Read-Config $root;$index=Read-Index $root $configInfo.Config.maxDashboardItems;$item=@($index.items|Where-Object{$_.chainId -ceq $ChainId}|Select-Object -First 1)
    if($item.Count -eq 1){$path=Join-Path $root ([string]$item[0].path).Replace('/','\');$log=Read-Log $path;if($log.HeadHash -cne $item[0].headEntryHash-or $log.RecordHash -cne $item[0].recordHash){Throw-StoreError 1 'store-index-stale' 'Index and task head differ; run Rebuild'}}
    else{$key=(Get-Key $ChainId)+'.jsonl';if(Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $root $script:StateName) 'active') $key)){Throw-StoreError 1 'store-index-stale' 'Active task is missing from the compact index; run Rebuild'};$foundPaths=@();$archive=Join-Path (Join-Path $root $script:StateName) 'archive';foreach($month in @(Get-ChildItem -LiteralPath $archive -Force)){if(-not$month.PSIsContainer-or($month.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$month.Name-cnotmatch'^\d{4}-(?:0[1-9]|1[0-2])$'){Throw-StoreError 1 'store-layout-invalid' "Invalid archive child: $($month.FullName)"};$candidate=Join-Path $month.FullName $key;if(Test-Path -LiteralPath $candidate){$candidateItem=Get-Item -LiteralPath $candidate -Force;if($candidateItem.PSIsContainer-or($candidateItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-StoreError 1 'store-layout-invalid' "Invalid archived task: $candidate"};$foundPaths+=$candidate}};if($foundPaths.Count -eq 0){Throw-StoreError 1 'task-not-found' "Task not found: $ChainId"};if($foundPaths.Count -ne 1){Throw-StoreError 1 'store-layout-invalid' "Duplicate archived task: $ChainId"};$path=$foundPaths[0];$log=Read-Log $path;if($log.ChainId -cne $ChainId-or$log.Record.state -cne'terminal'-or([DateTimeOffset]::Parse($log.Record.updatedAt)).ToString('yyyy-MM') -cne(Split-Path -Leaf (Split-Path -Parent $path))){Throw-StoreError 1 'store-layout-invalid' "Archived task identity mismatch: $ChainId"}}
    $data=[pscustomobject][ordered]@{path=$path;eventCount=$log.Count;record=$log.Record}
    Write-StoreResult verified 'task-read' $root $ChainId $log.HeadHash $log.HeadHash $null $data 'Use this head entry hash as ExpectedEntryHash for the next update.' @() 0
  }
  if($Action-ceq'Put'){
    if([string]::IsNullOrWhiteSpace($CandidatePath)-or[string]::IsNullOrWhiteSpace($ExpectedEntryHash)-or($ExpectedEntryHash-ine'MISSING'-and-not(Test-Hash $ExpectedEntryHash))){Throw-StoreError 2 'put-arguments-invalid' 'Put requires CandidatePath and ExpectedEntryHash'}
    $configInfo=Read-Config $root;$candidateFull=Resolve-ChildPath $root $CandidatePath -MustExist -FileOnly
    if($candidateFull.StartsWith((Join-Path $root $script:StateName)+'\',[StringComparison]::OrdinalIgnoreCase)-or$candidateFull-ieq(Join-Path $root $script:ConfigName)-or$candidateFull-ieq$configInfo.Memory-or$candidateFull-ieq$configInfo.Dashboard){Throw-StoreError 2 'candidate-path-invalid' 'Candidate cannot be canonical or derived state'}
    $candidateRead=Read-StrictJson $candidateFull $script:MaxRecordBytes 'candidate-encoding-invalid';$validated=Test-Record $candidateRead.Object;$ChainId=[string]$validated.Record.chainId
    if($validated.Record.state -ceq 'active'-and(Test-SemanticTerminalSummary $validated.Record)){Throw-StoreError 2 'task-state-summary-mismatch' 'An active task cannot carry a terminal phase or status'}
    if($validated.Record.state -ceq 'terminal'-and -not $ConfirmTerminal){Throw-StoreError 2 'terminal-confirmation-required' 'Terminal transition requires -ConfirmTerminal'}
    $mutex=Enter-StoreLock $root
    try{
      Assert-CanonicalWriteAllowed $root
      $snapshot=Get-StoreSnapshot $root -MaxRecentTerminal $configInfo.Config.maxDashboardItems;$current=@($snapshot.Heads|Where-Object{$_.ChainId -ceq $ChainId}|Select-Object -First 1)
      if($current.Count -eq 1-and $current[0].RecordHash -ceq $validated.Hash){Write-StoreResult applied 'task-replay' $root $ChainId $current[0].HeadHash $current[0].HeadHash $null ([pscustomobject]@{path=$current[0].Path;eventCount=$current[0].Count}) 'No change; the exact current record was already applied.' @() 0}
      if($current.Count -eq 0){if($ExpectedEntryHash -ine 'MISSING'){Throw-StoreError 1 'task-head-conflict' 'Task does not exist at the expected head'};if($validated.Record.state -cne 'active'){Throw-StoreError 1 'task-terminal-create' 'A new task must start active'}}
      else{
        if($current[0].Record.state -ceq 'terminal'){Throw-StoreError 1 'task-terminal' 'Terminal task is immutable'}
        if($ExpectedEntryHash -cne $current[0].HeadHash){Throw-StoreError 1 'task-head-conflict' 'Task head changed'}
      }
      Invoke-TransitionValidator $root $configInfo $snapshot $validated.Record
      $marker=Join-Path (Join-Path $root $script:StateName) $script:MarkerName;Write-AtomicText $marker (([DateTimeOffset]::UtcNow.ToString('o'))+"`n")
      try{
        $key=Get-Key $ChainId
        if($current.Count -eq 0){$path=Join-Path (Join-Path (Join-Path $root $script:StateName) 'active') ($key+'.jsonl');$event=New-Event $validated 1 $null 'create' ([DateTimeOffset]::UtcNow.ToString('o'));$oldHash=$null}
        else{$path=$current[0].Path;$operation=if($validated.Record.state -ceq 'terminal'){'archive'}else{'update'};$event=New-Event $validated ($current[0].Count+1) $current[0].HeadHash $operation ([DateTimeOffset]::UtcNow.ToString('o'));$oldHash=$current[0].HeadHash}
        $newBytes=if($current.Count -eq 0){$script:Utf8.GetBytes($event.Line)}else{[byte[]](@($current[0].Bytes)+@($script:Utf8.GetBytes($event.Line)))}
        if($newBytes.Length -gt $script:MaxLogBytes){Throw-StoreError 1 'task-log-limit' 'CHAIN log exceeds 64 MiB'}
        Write-AtomicBytes $path $newBytes
        if($validated.Record.state -ceq 'terminal'){$month=([DateTimeOffset]::Parse($validated.Record.updatedAt)).ToString('yyyy-MM');$destinationDir=Join-Path (Join-Path (Join-Path $root $script:StateName) 'archive') $month;[IO.Directory]::CreateDirectory($destinationDir)|Out-Null;$destination=Join-Path $destinationDir ([IO.Path]::GetFileName($path));if(Test-Path -LiteralPath $destination){Throw-StoreError 1 'store-layout-invalid' 'Archive destination already exists'};[IO.File]::Move($path,$destination);$path=$destination}
        $nextSnapshot=Get-StoreSnapshot $root -MaxRecentTerminal $configInfo.Config.maxDashboardItems;[void](Write-Derived $root $nextSnapshot $configInfo);[IO.File]::Delete($marker)
      }catch{Throw-StoreError 3 'store-rebuild-required' ('Canonical event may have been written; run Rebuild before retrying. '+$_.Exception.Message)}
    }finally{Exit-StoreLock $mutex}
    $reason=if($null -eq $oldHash){'task-created'}elseif($validated.Record.state -ceq 'terminal'){'task-archived'}else{'task-updated'}
    $head=Read-Log $path;$data=[pscustomobject][ordered]@{path=$path;eventCount=$head.Count}
    Write-StoreResult applied $reason $root $ChainId $oldHash $head.HeadHash $null $data 'Use the returned resultEntryHash for the next exact update.' @() 0
  }
  if($Action-ceq'GoalGet'){
    if(-not(Test-GoalIdentifier $GoalLineageId)){Throw-StoreError 2 'goal-lineage-id-invalid' 'GoalGet requires a valid GoalLineageId'}
    [void](Read-Config $root);$goalSnapshot=Get-GoalSnapshot $root;[void](Read-ExperienceIndex $root $goalSnapshot);$current=@($goalSnapshot.Heads|Where-Object{$_.GoalLineageId-ceq$GoalLineageId}|Select-Object -First 1)
    if($current.Count-ne1){Throw-StoreError 1 'goal-not-found' "Goal lineage not found: $GoalLineageId"}
    $data=[pscustomobject][ordered]@{path=$current[0].Path;eventCount=$current[0].Count;record=$current[0].Record}
    Write-StoreResult verified 'goal-read' $root $null $current[0].HeadHash $current[0].HeadHash $goalSnapshot.Watermark $data 'Use this head entry hash as ExpectedEntryHash for the next GoalPut.' @() 0
  }
  if($Action-ceq'GoalPut'){
    if(-not(Test-GoalIdentifier $GoalLineageId)-or[string]::IsNullOrWhiteSpace($CandidatePath)-or[string]::IsNullOrWhiteSpace($ExpectedEntryHash)-or($ExpectedEntryHash-ine'MISSING'-and-not(Test-Hash $ExpectedEntryHash))){Throw-StoreError 2 'goal-put-arguments-invalid' 'GoalPut requires GoalLineageId, CandidatePath, and ExpectedEntryHash'}
    $configInfo=Read-Config $root;$candidateFull=Resolve-ChildPath $root $CandidatePath -MustExist -FileOnly
    if($candidateFull.StartsWith((Join-Path $root $script:StateName)+'\',[StringComparison]::OrdinalIgnoreCase)-or$candidateFull-ieq(Join-Path $root $script:ConfigName)-or$candidateFull-ieq$configInfo.Memory-or$candidateFull-ieq$configInfo.Dashboard){Throw-StoreError 2 'candidate-path-invalid' 'Goal candidate cannot be canonical or derived state'}
    $candidateRead=Read-StrictJson $candidateFull $script:MaxRecordBytes 'candidate-encoding-invalid';$validated=Test-GoalRecord $candidateRead.Object
    if($validated.Record.goalLineageId-cne$GoalLineageId){Throw-StoreError 2 'goal-lineage-id-invalid' 'Candidate goal identity does not match GoalLineageId'}
    if($validated.Record.state-ceq'terminal'-and-not$ConfirmTerminal){Throw-StoreError 2 'terminal-confirmation-required' 'Goal terminal transition requires -ConfirmTerminal'}
    $mutex=Enter-StoreLock $root
    try{
      Assert-CanonicalWriteAllowed $root
      $goalSnapshot=Get-GoalSnapshot $root;[void](Read-ExperienceIndex $root $goalSnapshot);$current=@($goalSnapshot.Heads|Where-Object{$_.GoalLineageId-ceq$GoalLineageId}|Select-Object -First 1)
      if($current.Count-eq1-and$current[0].RecordHash-ceq$validated.Hash){$data=[pscustomobject][ordered]@{path=$current[0].Path;eventCount=$current[0].Count;record=$current[0].Record};Write-StoreResult applied 'goal-replay' $root $null $current[0].HeadHash $current[0].HeadHash $goalSnapshot.Watermark $data 'No change; the exact current goal record was already applied.' @() 0}
      if($current.Count-eq0){
        if($ExpectedEntryHash-ine'MISSING'){Throw-StoreError 1 'goal-head-conflict' 'Goal lineage does not exist at the expected head'}
        if(@($goalSnapshot.Heads|Where-Object{$_.Record.objectiveFingerprint-ceq$validated.Record.objectiveFingerprint}).Count-gt0){Throw-StoreError 1 'goal-objective-exists' 'The same objective already has a canonical goal lineage'}
        if($validated.Record.state-cne'active'-or$validated.Record.budget.readinessReplansUsed-ne0-or$validated.Record.budget.crossProjectRebaselinesUsed-ne0-or@($validated.Record.readinessFailures).Count-ne0-or
           @($validated.Record.lanes|Where-Object{$_.attemptsUsed-ne0-or$_.transientRetriesUsed-ne0-or$null-ne$_.activeReservation-or@($_.outcomes).Count-ne0}).Count-ne0){Throw-StoreError 2 'goal-transition-invalid' 'A new goal lineage must start with empty lane history and budget'}
      }else{
        if($ExpectedEntryHash-cne$current[0].HeadHash){Throw-StoreError 1 'goal-head-conflict' 'Goal lineage head changed'}
        Test-GoalTransition $root $current[0].Record $validated.Record $goalSnapshot
      }
      $marker=Join-Path (Join-Path $root $script:StateName) $script:MarkerName;Write-AtomicText $marker (([DateTimeOffset]::UtcNow.ToString('o'))+"`n")
      try{
        $key=Get-Key $GoalLineageId;$path=Join-Path (Join-Path (Join-Path $root $script:StateName) $script:GoalDirectoryName) ($key+'.jsonl')
        if($current.Count-eq0){$event=New-GoalEvent $validated 1 $null 'create' ([DateTimeOffset]::UtcNow.ToString('o'));$oldHash=$null;$newBytes=$script:Utf8.GetBytes($event.Line)}
        else{$operation=if($validated.Record.state-ceq'terminal'){'terminal'}else{'update'};$event=New-GoalEvent $validated ($current[0].Count+1) $current[0].HeadHash $operation ([DateTimeOffset]::UtcNow.ToString('o'));$oldHash=$current[0].HeadHash;$newBytes=[byte[]](@($current[0].Bytes)+@($script:Utf8.GetBytes($event.Line)))}
        if($newBytes.Length-gt$script:MaxLogBytes){Throw-StoreError 1 'goal-log-limit' 'Goal lineage log exceeds 64 MiB'}
        Write-AtomicBytes $path $newBytes;$nextGoalSnapshot=Get-GoalSnapshot $root;Write-GoalDerived $root $nextGoalSnapshot;[IO.File]::Delete($marker)
      }catch{Throw-StoreError 3 'store-rebuild-required' ('Canonical goal event may have been written; run Rebuild before retrying. '+$_.Exception.Message)}
    }finally{Exit-StoreLock $mutex}
    $head=Read-GoalLog $path;$reason=if($null-eq$oldHash){'goal-created'}else{'goal-updated'};$data=[pscustomobject][ordered]@{path=$path;eventCount=$head.Count;record=$head.Record}
    Write-StoreResult applied $reason $root $null $oldHash $head.HeadHash $nextGoalSnapshot.Watermark $data 'Use the returned resultEntryHash for the next exact GoalPut.' @() 0
  }
  if($Action-ceq'ExperienceRead'){
    [void](Read-Config $root);$goalSnapshot=Get-GoalSnapshot $root;$experience=Read-ExperienceIndex $root $goalSnapshot
    Write-StoreResult verified 'experience-read' $root $null $null $null $goalSnapshot.Watermark $experience 'Hard strategy decisions still verify canonical goal logs; this index is bounded and rebuildable.' @() 0
  }
  if($Action-ceq'ExperienceImport'){
    if([string]::IsNullOrWhiteSpace($CandidatePath)-or[string]::IsNullOrWhiteSpace($ExpectedEntryHash)-or($ExpectedEntryHash-ine'MISSING'-and-not(Test-Hash $ExpectedEntryHash))){Throw-StoreError 2 'experience-import-arguments-invalid' 'ExperienceImport requires CandidatePath and ExpectedEntryHash'}
    $configInfo=Read-Config $root;$candidateFull=Resolve-ChildPath $root $CandidatePath -MustExist -FileOnly
    if($candidateFull.StartsWith((Join-Path $root $script:StateName)+'\',[StringComparison]::OrdinalIgnoreCase)-or$candidateFull-ieq(Join-Path $root $script:ConfigName)-or$candidateFull-ieq$configInfo.Memory-or$candidateFull-ieq$configInfo.Dashboard){Throw-StoreError 2 'candidate-path-invalid' 'Experience candidate cannot be canonical or derived state'}
    $candidateRead=Read-StrictJson $candidateFull $script:MaxRecordBytes 'candidate-encoding-invalid';$validated=Convert-ExperienceImportRecord $root $candidateRead.Object;$mutex=Enter-StoreLock $root
    try{
      Assert-CanonicalWriteAllowed $root
      $imports=Get-ExperienceImportSnapshot $root;$sameId=@($imports.Records|Where-Object{$_.importId-ceq$validated.Record.importId})
      if($sameId.Count-gt0){$existingJson=ConvertTo-CanonicalRecord $sameId[0];if((Get-HashText $existingJson)-ceq$validated.Hash){$goalSnapshot=Get-GoalSnapshot $root;$data=[pscustomobject][ordered]@{path=$imports.Path;eventCount=$imports.Count;record=$sameId[0]};Write-StoreResult applied 'experience-import-replay' $root $null $imports.HeadHash $imports.HeadHash $goalSnapshot.Watermark $data 'No change; this exact curated import already exists.' @() 0};Throw-StoreError 1 'experience-import-duplicate' 'Import identity already exists with different content'}
      if(($imports.Count-eq0-and$ExpectedEntryHash-ine'MISSING')-or($imports.Count-gt0-and$ExpectedEntryHash-cne$imports.HeadHash)){Throw-StoreError 1 'experience-import-head-conflict' 'Experience import head changed'}
      $known=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$goalSnapshot=Get-GoalSnapshot $root
      foreach($entry in @($goalSnapshot.ExperienceIndex.entries)){[void]$known.Add(('{0}|{1}|{2}|{3}'-f$entry.problemInvariantId,$entry.strategyFamilyId,$entry.materialPreconditionHash,$entry.outcome))}
      foreach($entry in @($validated.Record.entries)){$semantic=('{0}|{1}|{2}|{3}'-f$entry.problemInvariantId,$entry.strategyFamilyId,$entry.materialPreconditionHash,$entry.outcome);if(-not$known.Add($semantic)){Throw-StoreError 1 'experience-import-duplicate' 'Semantic experience already exists'} }
      $marker=Join-Path (Join-Path $root $script:StateName) $script:MarkerName;Write-AtomicText $marker (([DateTimeOffset]::UtcNow.ToString('o'))+"`n")
      try{$event=New-ExperienceImportEvent $validated ($imports.Count+1) $imports.HeadHash ([DateTimeOffset]::UtcNow.ToString('o'));$newBytes=[byte[]](@($imports.Bytes)+@($script:Utf8.GetBytes($event.Line)));if($newBytes.Length-gt$script:MaxLogBytes){Throw-StoreError 1 'experience-import-log-limit' 'Experience import log exceeds 64 MiB'};Write-AtomicBytes $imports.Path $newBytes;$nextGoalSnapshot=Get-GoalSnapshot $root;Write-GoalDerived $root $nextGoalSnapshot;[IO.File]::Delete($marker)}catch{Throw-StoreError 3 'store-rebuild-required' ('Canonical experience import may have been written; run Rebuild before retrying. '+$_.Exception.Message)}
    }finally{Exit-StoreLock $mutex}
    $nextImports=$nextGoalSnapshot.Imports;$data=[pscustomobject][ordered]@{path=$nextImports.Path;eventCount=$nextImports.Count;record=$validated.Record}
    Write-StoreResult applied 'experience-imported' $root $null $imports.HeadHash $nextImports.HeadHash $nextGoalSnapshot.Watermark $data 'Use the returned resultEntryHash as the next exact ExperienceImport CAS head.' @() 0
  }
  if($Action-ceq'Verify'-or$Action-ceq'Rebuild'){
    $configInfo=Read-Config $root;$mutex=$null;if($Action-ceq'Rebuild'){$mutex=Enter-StoreLock $root}
    try{if($Action-ceq'Rebuild'){Assert-CanonicalWriteAllowed $root};$snapshot=Get-StoreSnapshot $root -RepairLayout:($Action-ceq'Rebuild') -MaxRecentTerminal $configInfo.Config.maxDashboardItems;$bytes=Get-ViewBytes $snapshot.Index $configInfo;$goalSnapshot=Get-GoalSnapshot $root -RepairLayout:($Action-ceq'Rebuild');$experienceBytes=Get-ExperienceBytes $goalSnapshot
      if($Action-ceq'Rebuild'){[void](Write-Derived $root $snapshot $configInfo);Write-GoalDerived $root $goalSnapshot;$marker=Join-Path (Join-Path $root $script:StateName) $script:MarkerName;if(Test-Path -LiteralPath $marker -PathType Leaf){[IO.File]::Delete($marker)}}
      else{if(Test-Path -LiteralPath (Join-Path (Join-Path $root $script:StateName) $script:MarkerName)){Throw-StoreError 1 'store-rebuild-required' 'A prior canonical write requires Rebuild'};foreach($pair in @(@((Join-Path (Join-Path $root $script:StateName) $script:IndexName),$bytes.Index),@((Join-Path (Join-Path $root $script:StateName) $script:ExperienceIndexName),$experienceBytes),@($configInfo.Memory,$bytes.Memory),@($configInfo.Dashboard,$bytes.Dashboard))){if(-not(Test-Path -LiteralPath $pair[0] -PathType Leaf)-or(Get-HashBytes([IO.File]::ReadAllBytes($pair[0])))-cne(Get-HashBytes([byte[]]$pair[1]))){Throw-StoreError 1 'store-derived-mismatch' "Derived file mismatch: $($pair[0])"}}}
    }finally{Exit-StoreLock $mutex}
    $reason=if($Action-ceq'Rebuild'){'store-rebuilt'}else{'store-verified'};$status=if($Action-ceq'Rebuild'){'applied'}else{'verified'}
    Write-StoreResult $status $reason $root $null $null $null $null $snapshot.Index 'Use Read/Get for normal operation; rebuild only after a verified mismatch or interrupted write.' @() 0
  }
  if($Action-ceq'PrepareMigration'){$prepared=Prepare-Migration $root;$data=[pscustomobject][ordered]@{migrationPath=$prepared.Migration;activeCount=$prepared.Manifest.activeCount;terminalCount=$prepared.Manifest.terminalCount;totalCount=$prepared.Manifest.totalCount};Write-StoreResult prepared 'migration-prepared' $root $null $null $null $prepared.Manifest.sourceHash $data 'Verify the shadow migration, require the controller task to be idle, then apply with the same source hash.' @() 0}
  if($Action-ceq'VerifyMigration'){
    if([string]::IsNullOrWhiteSpace($MigrationPath)-or-not(Test-Hash $ExpectedSourceHash)){Throw-StoreError 2 'migration-arguments-invalid' 'VerifyMigration requires MigrationPath and ExpectedSourceHash'}
    $verified=Verify-Migration $root $MigrationPath $ExpectedSourceHash;$data=[pscustomobject][ordered]@{migrationPath=$verified.Migration;activeCount=$verified.Manifest.activeCount;terminalCount=$verified.Manifest.terminalCount;totalCount=$verified.Manifest.totalCount}
    Write-StoreResult verified 'migration-verified' $root $null $null $null $verified.Manifest.sourceHash $data 'Apply only while the controller is idle and source hashes remain unchanged.' @() 0
  }
  if($Action-ceq'ApplyMigration'){
    if(-not$ConfirmMigration-or[string]::IsNullOrWhiteSpace($MigrationPath)-or-not(Test-Hash $ExpectedSourceHash)){Throw-StoreError 2 'migration-confirmation-required' 'ApplyMigration requires exact path/hash and -ConfirmMigration'}
    $mutex=Enter-StoreLock $root;$movedState=$false;$installedConfig=$false;$verified=$null;$backup=$null
    try{
      Assert-CanonicalWriteAllowed $root
      if((Test-Path -LiteralPath (Join-Path $root $script:ConfigName)) -or (Test-Path -LiteralPath (Join-Path $root $script:StateName))){Throw-StoreError 1 'store-already-initialized' 'Controller already has a chain store'}
      $verified=Verify-Migration $root $MigrationPath $ExpectedSourceHash
      $backup=Join-Path (Join-Path $root 'legacy') (([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss'))+'-'+$ExpectedSourceHash.Substring(0,8));[IO.Directory]::CreateDirectory($backup)|Out-Null
      foreach($file in $verified.Manifest.files){$source=Join-Path $root ([string]$file.relativePath).Replace('/','\');$destination=Join-Path $backup ([string]$file.relativePath).Replace('/','\');[IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null;[IO.File]::Copy($source,$destination,$false);if((Get-HashBytes([IO.File]::ReadAllBytes($destination)))-cne$file.hash){Throw-StoreError 3 'migration-backup-failed' 'Legacy backup hash mismatch'}}
      [IO.Directory]::Move((Join-Path $verified.Migration $script:StateName),(Join-Path $root $script:StateName));$movedState=$true
      $shadowConfig=Read-StrictBytes (Join-Path $verified.Migration $script:ConfigName) 65536 'migration-invalid';$config=($script:Utf8.GetString($shadowConfig)|ConvertFrom-Json);$rootConfigInfo=Test-Config $config $root
      $shadowConfigInfo=Test-Config $config $verified.Migration
      Write-AtomicBytes $rootConfigInfo.Memory ([IO.File]::ReadAllBytes($shadowConfigInfo.Memory));Write-AtomicBytes $rootConfigInfo.Dashboard ([IO.File]::ReadAllBytes($shadowConfigInfo.Dashboard))
      Write-AtomicBytes (Join-Path $root $script:ConfigName) $shadowConfig;$installedConfig=$true
      $post=Get-StoreSnapshot $root -MaxRecentTerminal $rootConfigInfo.Config.maxDashboardItems;[void](Read-Index $root $rootConfigInfo.Config.maxDashboardItems)
      [IO.Directory]::Delete($verified.Migration,$true)
    }catch{
      $failure=$_
      if(-not$installedConfig-and$movedState-and(Test-Path -LiteralPath (Join-Path $root $script:StateName) -PathType Container)-and(Test-Path -LiteralPath $verified.Migration -PathType Container)){
        try{[IO.Directory]::Move((Join-Path $root $script:StateName),(Join-Path $verified.Migration $script:StateName));$movedState=$false}catch{}
      }
      if(-not$installedConfig-and$null-ne$backup-and$null-ne$verified){foreach($file in $verified.Manifest.files){$original=Join-Path $root ([string]$file.relativePath).Replace('/','\');$copy=Join-Path $backup ([string]$file.relativePath).Replace('/','\');if(Test-Path -LiteralPath $copy -PathType Leaf){try{Write-AtomicBytes $original ([IO.File]::ReadAllBytes($copy))}catch{}}}}
      throw $failure
    }finally{Exit-StoreLock $mutex}
    $data=[pscustomobject][ordered]@{legacyBackup=$backup;activeCount=$verified.Manifest.activeCount;terminalCount=$verified.Manifest.terminalCount;totalCount=$verified.Manifest.totalCount}
    Write-StoreResult applied 'migration-applied' $root $null $null $null $verified.Manifest.sourceHash $data 'Use Read and Get; the Markdown ledger is now a generated view.' @() 0
  }
}catch{
  $code=1;$reason='store-unexpected-failure';if($_.Exception.Data.Contains('ExitCode')){$code=[int]$_.Exception.Data['ExitCode']};if($_.Exception.Data.Contains('ReasonCode')){$reason=[string]$_.Exception.Data['ReasonCode']}
  $status=if($code-eq2){'invalid'}elseif($code-eq3){'blocked'}else{'conflict'}
  Write-StoreResult $status $reason $root $ChainId $null $null $null $null $_.Exception.Message @() $code
}
