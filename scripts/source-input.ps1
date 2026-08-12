[CmdletBinding()]
param([string]$SourcesJson, [string]$SourcesJsonBase64)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
$secretPattern = '(?is)(?:authorization\s*:\s*(?:bearer|basic)\s+\S+|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+|https?://[^/\s:@]+:[^/\s@]+@|https?://\S+[?&](?:access_token|refresh_token|api[_-]?key|client[_-]?secret|password)=\S+|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b)'

function Finish([string]$Status, [string]$ReasonCode, [object[]]$Sources, [int]$ExitCode) {
  [pscustomobject][ordered]@{ schemaVersion=1; status=$Status; reasonCode=$ReasonCode; sources=@($Sources); warnings=@() } |
    ConvertTo-Json -Depth 6 -Compress
  exit $ExitCode
}

function Test-ClosedSource([object]$Value) {
  if ($null -eq $Value -or $Value -is [Array] -or $Value -is [string] -or $Value -is [ValueType]) { return $false }
  $allowed = @('source','cloneRoot','branch','ref','fullLfsCheckout')
  foreach ($name in @($Value.PSObject.Properties.Name)) { if ($name -cnotin $allowed) { return $false } }
  return @($Value.PSObject.Properties.Name) -ccontains 'source'
}

function Test-SafeText([object]$Value, [int]$Maximum=2048) {
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum) { return $false }
  try { $decoded = [Uri]::UnescapeDataString($Value) } catch { return $false }
  return $Value -notmatch '[\x00-\x1f\x7f]' -and $Value -notmatch $secretPattern -and $decoded -notmatch '[\x00-\x1f\x7f]' -and $decoded -notmatch $secretPattern
}

function Resolve-LocalRoot([string]$Value, [bool]$MustExist) {
  if (-not (Test-SafeText $Value 1024) -or $Value -notmatch '^[A-Za-z]:\\' -or $Value.Contains('/') -or $Value.Substring(2).Contains(':')) { return $null }
  try { $root = [IO.Path]::GetFullPath($Value).TrimEnd('\') } catch { return $null }
  if ($root -ieq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { return $null }
  if ($MustExist -and -not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
  return $root
}

function Test-GitRef([object]$Value) {
  if (-not (Test-SafeText $Value 255) -or $Value.StartsWith('-') -or $Value.StartsWith('/') -or $Value.EndsWith('/') -or $Value.EndsWith('.') -or
      $Value.Contains('..') -or $Value.Contains('@{') -or $Value -match '[ ~^:?*\[\\]' -or $Value -match '(^|/)\.|\.lock($|/)') { return $false }
  return $true
}

function Resolve-GitSource([string]$Value) {
  if (-not (Test-SafeText $Value) -or $Value -match '[?#]' -or $Value -match '^(?i:http|git)://') { return $null }
  if ($Value -match '^https://') {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.AbsolutePath -ceq '/' -or $uri.AbsolutePath.Contains('\')) { return $null }
    try { $decoded = [Uri]::UnescapeDataString($uri.AbsolutePath) } catch { return $null }
    if ($decoded -match '[\x00-\x1f\x7f]') { return $null }
    return $uri.AbsoluteUri
  }
  if ($Value -match '^ssh://') {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'ssh' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        $uri.UserInfo.Contains(':') -or $uri.AbsolutePath -ceq '/' -or $uri.AbsolutePath.Contains('\')) { return $null }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -and $uri.UserInfo -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    try { $decoded = [Uri]::UnescapeDataString($uri.AbsolutePath) } catch { return $null }
    if ($decoded -match '[\x00-\x1f\x7f]') { return $null }
    return $uri.AbsoluteUri
  }
  $match = [regex]::Match($Value, '^(?<user>[A-Za-z0-9._-]+)@(?<host>[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):(?<path>[^\\\s:#?]+(?:/[^\\\s:#?]+)*)$')
  if (-not $match.Success -or $match.Groups['path'].Value.StartsWith('/') -or $match.Groups['path'].Value.StartsWith('-') -or $match.Groups['path'].Value.Contains('..')) { return $null }
  return $match.Groups['user'].Value + '@' + $match.Groups['host'].Value.ToLowerInvariant() + ':' + $match.Groups['path'].Value
}

try {
  $hasJson = -not [string]::IsNullOrWhiteSpace($SourcesJson)
  $hasBase64 = -not [string]::IsNullOrWhiteSpace($SourcesJsonBase64)
  if ($hasJson -eq $hasBase64) { Finish invalid 'source-input-invalid' @() 2 }
  try { $inputJson = if ($hasBase64) { $strictUtf8.GetString([Convert]::FromBase64String($SourcesJsonBase64)) } else { $SourcesJson } }
  catch { Finish invalid 'source-input-invalid' @() 2 }
  if ($inputJson.Length -gt 1MB) { Finish invalid 'source-input-invalid' @() 2 }
  try { $inputValue = $inputJson | ConvertFrom-Json -ErrorAction Stop } catch { Finish invalid 'source-input-invalid' @() 2 }
  if ($inputValue -isnot [Array] -or @($inputValue).Count -lt 1 -or @($inputValue).Count -gt 1000) { Finish invalid 'source-input-invalid' @() 2 }

  # ponytail: a plain array is sufficient for the hard 1000-source input cap.
  $normalized = @()
  $seen = @{}
  foreach ($item in @($inputValue)) {
    if (-not (Test-ClosedSource $item) -or -not (Test-SafeText $item.source)) { Finish invalid 'source-input-invalid' @() 2 }
    $names = @($item.PSObject.Properties.Name)
    $hasCloneRoot = $names -ccontains 'cloneRoot'
    $hasBranch = $names -ccontains 'branch'
    $hasRef = $names -ccontains 'ref'
    $hasLfs = $names -ccontains 'fullLfsCheckout'
    if ($hasBranch -and $hasRef) { Finish invalid 'source-input-invalid' @() 2 }
    if ($hasLfs -and $item.fullLfsCheckout -isnot [bool]) { Finish invalid 'source-input-invalid' @() 2 }

    $localRoot = Resolve-LocalRoot ([string]$item.source) $true
    if ($null -ne $localRoot) {
      if ($hasCloneRoot -or $hasBranch -or $hasRef -or $hasLfs) { Finish invalid 'source-input-invalid' @() 2 }
      $record = [pscustomobject][ordered]@{ sourceKind='local'; source=$localRoot; cloneRoot=$null; branch=$null; ref=$null; fullLfsCheckout=$false }
      $key = 'local|' + $localRoot.ToUpperInvariant()
      $signature = $key
    }
    else {
      $gitSource = Resolve-GitSource ([string]$item.source)
      $cloneRoot = if ($hasCloneRoot) { Resolve-LocalRoot ([string]$item.cloneRoot) $true } else { $null }
      if ($null -eq $gitSource -or $null -eq $cloneRoot -or ($hasBranch -and -not (Test-GitRef $item.branch)) -or ($hasRef -and -not (Test-GitRef $item.ref))) { Finish invalid 'source-input-invalid' @() 2 }
      $record = [pscustomobject][ordered]@{
        sourceKind='git'; source=$gitSource; cloneRoot=$cloneRoot
        branch=if ($hasBranch) { [string]$item.branch } else { $null }
        ref=if ($hasRef) { [string]$item.ref } else { $null }
        fullLfsCheckout=if ($hasLfs) { [bool]$item.fullLfsCheckout } else { $false }
      }
      $key = 'git|' + $gitSource
      $signature = $key + "`0" + $cloneRoot.ToUpperInvariant() + "`0" + [string]$record.branch + "`0" + [string]$record.ref + "`0" + [string]$record.fullLfsCheckout
    }
    if ($seen.ContainsKey($key)) {
      if ($seen[$key] -cne $signature) { Finish invalid 'source-duplicate-conflict' @() 2 }
      continue
    }
    $seen[$key] = $signature
    $normalized += $record
  }
  Finish ready 'source-input-ready' @($normalized) 0
}
catch {
  Finish invalid 'source-input-invalid' @() 2
}
