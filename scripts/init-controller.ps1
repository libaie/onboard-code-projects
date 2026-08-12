[CmdletBinding()]
param(
  [string]$Action = 'Plan',
  [string]$ControllerRoot,
  [string]$ControllerName = 'Multi-Project Control Center',
  [string[]]$BusinessProjectRoots = @(),
  [switch]$AllowUpgrade
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $skillRoot 'templates\controller'
$legacyScaffoldPaths = @('.codex-controller.json', '.gitignore', 'AGENTS.md', 'docs\cross-project-contracts.md', 'tools\control-state.ps1')
$generatedStorePaths = @('TASKS.md', 'memory\MEMORY.md', 'state\index.json', 'state\experience-index.json')
$runtimePath = 'tools\dispatch-return-runtime.mjs'
$templatePaths = $legacyScaffoldPaths + @('.chain-store.json', 'tools\chain-store.ps1', $runtimePath)
$templateSources = @{ $runtimePath = Join-Path $skillRoot 'scripts\dispatch-return-runtime.mjs' }
$scaffoldPaths = $templatePaths + $generatedStorePaths
$scaffoldDirectories = @('docs', 'tools', 'memory', 'state', 'state\active', 'state\archive', 'state\goals')
$byteManagedPaths = @('.gitignore', 'AGENTS.md', 'tools\control-state.ps1', '.chain-store.json', 'tools\chain-store.ps1', $runtimePath)
$legacyV1ManagedHashes = @{
  '.gitignore' = 'c9efd1b656a3619ec7a56375bb0e674c2ccc9bc34979d2f52d6199911b41199b'
  'AGENTS.md' = 'd6d3ab613c3cfee0d7e69293f930fe56bac6dd4ceb33985600c851eaca1ee3a5'
  'tools\control-state.ps1' = '79734061284859b738ba9b3e95fd971deac50d2382e2497a234651b8462c1088'
}
$legacyV2ManagedHashes = @{
  '.gitignore' = 'c9efd1b656a3619ec7a56375bb0e674c2ccc9bc34979d2f52d6199911b41199b'
  'AGENTS.md' = '474595a2afb7f8652c40b2211bbdc8d5b973e955613b14f568ed2adcded3c3bd'
  'tools\control-state.ps1' = 'b9f486df41b3a05398ca11a6a77025e0c184219286d6b79544816db178ac05af'
}
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$templateBytes = $null

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

function Read-CanonicalTemplates {
  $bytes = [ordered]@{}
  try {
    foreach ($relativePath in $templatePaths) {
      $path = if ($templateSources.ContainsKey($relativePath)) { $templateSources[$relativePath] } else { Join-Path $templateRoot $relativePath }
      if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-ReparseComponents $path)) {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Restore the regular canonical template $relativePath."; Bytes=$null }
      }
      $contentBytes = [IO.File]::ReadAllBytes($path)
      if ($contentBytes.Length -eq 0 -or ($contentBytes.Length -ge 3 -and $contentBytes[0] -eq 0xEF -and $contentBytes[1] -eq 0xBB -and $contentBytes[2] -eq 0xBF)) {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Restore the UTF-8 no-BOM canonical template $relativePath."; Bytes=$null }
      }
      $text = $utf8.GetString($contentBytes)
      if ($text.Contains("`r") -or -not $text.EndsWith("`n") -or $text -match '(?i)(?:[A-Z]:[\\/]|/Users/|/home/)') {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Remove non-canonical encoding or local data from template $relativePath."; Bytes=$null }
      }
      $tokens = @([regex]::Matches($text, '__[A-Z0-9_]+__') | ForEach-Object { $_.Value })
      if ($relativePath -ceq '.codex-controller.json') {
        if ($tokens.Count -ne 1 -or $tokens[0] -cne '__CONTROLLER_NAME_JSON__') {
          return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the single canonical controller-name placeholder in the manifest template.'; Bytes=$null }
        }
        $encodedName = $ControllerName | ConvertTo-Json -Compress
        $bytes[$relativePath] = $utf8.GetBytes($text.Replace('__CONTROLLER_NAME_JSON__', $encodedName))
      }
      else {
        if ($tokens.Count -ne 0) {
          return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Remove unresolved tokens from canonical template $relativePath."; Bytes=$null }
        }
        $bytes[$relativePath] = $contentBytes
      }
    }
    $adapter = Join-Path $templateRoot 'tools\control-state.ps1'
    $validationRoot = Join-Path ([IO.Path]::GetTempPath()) ('onboard-controller-template-' + [guid]::NewGuid().ToString('N'))
    try {
      [IO.Directory]::CreateDirectory($validationRoot) | Out-Null
      foreach ($directory in $scaffoldDirectories) { [IO.Directory]::CreateDirectory((Join-Path $validationRoot $directory)) | Out-Null }
      foreach ($relativePath in $templatePaths) {
        $validationPath = Join-Path $validationRoot $relativePath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $validationPath)) | Out-Null
        [IO.File]::WriteAllBytes($validationPath, [byte[]]$bytes[$relativePath])
      }
      $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Action Read -ControllerRoot $validationRoot 2>$null
      $exitCode = $LASTEXITCODE
      try { $validation = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
      catch { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the closed canonical manifest template.'; Bytes=$null } }
      if ($exitCode -ne 0 -or $validation.status -cne 'verified') {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the closed canonical manifest template.'; Bytes=$null }
      }
      $chainAdapter = Join-Path $validationRoot 'tools\chain-store.ps1'
      $chainOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chainAdapter -Action Rebuild -ControllerRoot $validationRoot 2>$null
      $chainExit = $LASTEXITCODE
      try { $chainValidation = (($chainOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
      catch { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the canonical chain-store templates.'; Bytes=$null } }
      if ($chainExit -ne 0 -or $chainValidation.status -cne 'applied') {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the canonical chain-store templates.'; Bytes=$null }
      }
      $chainOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chainAdapter -Action Verify -ControllerRoot $validationRoot 2>$null
      $chainExit = $LASTEXITCODE
      try { $chainValidation = (($chainOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
      catch { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the canonical chain-store templates.'; Bytes=$null } }
      if ($chainExit -ne 0 -or $chainValidation.status -cne 'verified') {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the canonical chain-store templates.'; Bytes=$null }
      }
    }
    finally {
      $resolvedValidationRoot = [IO.Path]::GetFullPath($validationRoot)
      $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
      if ((Test-Path -LiteralPath $validationRoot) -and $resolvedValidationRoot.StartsWith($resolvedTempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        try { if (Test-ReparseComponents $validationRoot) { [IO.Directory]::Delete($validationRoot, $true) } }
        catch {}
      }
    }
  }
  catch {
    return [pscustomobject]@{ Ready=$false; Reason='controller-io-failure'; Next='Restore readable canonical controller templates, then rerun.'; Bytes=$null }
  }
  return [pscustomobject]@{ Ready=$true; Reason=$null; Next=$null; Bytes=$bytes }
}

function Finish {
  param(
    [string]$Status,
    [string]$ReasonCode,
    [AllowNull()][object]$Root,
    [bool]$Changed,
    [string[]]$PlannedCreates,
    [AllowNull()][object]$CurrentHash,
    [AllowNull()][object]$ResultHash,
    [string]$NextAction,
    [string[]]$Warnings = @(),
    [int]$ExitCode
  )
  [pscustomobject][ordered]@{
    schemaVersion = 1
    action = $Action
    status = $Status
    reasonCode = $ReasonCode
    controllerRoot = $Root
    changed = $Changed
    plannedCreates = @($PlannedCreates)
    currentManifestHash = $CurrentHash
    resultManifestHash = $ResultHash
    nextAction = $NextAction
    warnings = @($Warnings)
  } | ConvertTo-Json -Depth 8 -Compress
  exit $ExitCode
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

function Test-LosslessWindowsPath {
  param([string]$Path)
  if ($Path.Contains('/') -or $Path.Length -lt 4) { return $false }
  $components = $Path.Substring(3).Split(@('\'), [StringSplitOptions]::None)
  for ($index = 0; $index -lt $components.Count; $index++) {
    $component = $components[$index]
    if ([string]::IsNullOrEmpty($component)) {
      if ($index -eq $components.Count - 1 -and $index -gt 0) { continue }
      return $false
    }
    if ($component -in @('.', '..') -or
        $component.EndsWith('.') -or $component.EndsWith(' ') -or
        $component -match '[<>:"/\\|?*\x00-\x1f]' -or
        $component -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') { return $false }
  }
  return $true
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

function Resolve-ControllerRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
    return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$null; Next='Use a fixed or removable local-drive absolute path.' }
  }
  if (-not (Test-LosslessWindowsPath $Path)) {
    return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$null; Next='Use a lossless Windows path without dot segments, trailing dots or spaces, or reserved device names.' }
  }
  try { $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\') }
  catch { return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$null; Next='Use a valid local-drive absolute path.' } }
  $driveRoot = [IO.Path]::GetPathRoot($normalized)
  if ($normalized -ieq $driveRoot.TrimEnd('\')) {
    return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$normalized; Next='Choose a child directory, not a filesystem root.' }
  }
  $leaf = [IO.Path]::GetFileName($normalized)
  if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '[<>:"/\\|?*\x00-\x1f]' -or
      $leaf -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$' -or $leaf.EndsWith('.') -or $leaf.EndsWith(' ')) {
    return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$normalized; Next='Choose a valid controller directory name.' }
  }
  $drive = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $driveRoot } | Select-Object -First 1)
  if ($drive.Count -ne 1 -or $drive[0].DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) {
    return [pscustomobject]@{ Ready=$false; Status='invalid'; Reason='controller-root-unsupported'; Root=$normalized; Next='Use a fixed or removable local drive, not a mapped or network drive.' }
  }
  $parent = Split-Path -Parent $normalized
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    return [pscustomobject]@{ Ready=$false; Status='blocked'; Reason='controller-root-unsupported'; Root=$normalized; Next='Create the parent directory, then rerun.' }
  }
  if (-not (Test-ReparseComponents $normalized)) {
    return [pscustomobject]@{ Ready=$false; Status='conflict'; Reason='controller-filesystem-conflict'; Root=$normalized; Next='Choose a path with no symlink, junction, or other reparse-point component.' }
  }
  return [pscustomobject]@{ Ready=$true; Status=$null; Reason=$null; Root=$normalized; Next=$null }
}

function Test-Overlap {
  param([string]$Root, [string[]]$BusinessRoots)
  $physicalRoot = Resolve-PhysicalWindowsPath $Root
  foreach ($businessRoot in $BusinessRoots) {
    if ([string]::IsNullOrWhiteSpace($businessRoot) -or $businessRoot -notmatch '^[A-Za-z]:\\' -or $businessRoot.Substring(2).Contains(':')) { throw 'invalid-business-root' }
    try { $business = [IO.Path]::GetFullPath($businessRoot).TrimEnd('\') }
    catch { throw 'invalid-business-root' }
    $physicalBusiness = Resolve-PhysicalWindowsPath $business
    $rootPrefix = $physicalRoot + '\'
    $businessPrefix = $physicalBusiness + '\'
    if ($physicalRoot.Equals($physicalBusiness, [StringComparison]::OrdinalIgnoreCase) -or
        $physicalRoot.StartsWith($businessPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $physicalBusiness.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-ExpectedBytes {
  param([string]$RelativePath)
  return [byte[]]$templateBytes[$RelativePath]
}

function Invoke-StateRead {
  param([string]$Root, [bool]$PreferGenerated)
  $generated = Join-Path $Root 'tools\control-state.ps1'
  $adapter = if ($PreferGenerated -and (Test-Path -LiteralPath $generated -PathType Leaf)) { $generated } else { Join-Path $templateRoot 'tools\control-state.ps1' }
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Action Read -ControllerRoot $Root 2>$null
  $exitCode = $LASTEXITCODE
  try { $result = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
  catch { return [pscustomobject]@{ Ready=$false; Hash=$null; Manifest=$null; Reason='invalid-adapter-output' } }
  if ($exitCode -ne 0 -or $result.status -cne 'verified') { return [pscustomobject]@{ Ready=$false; Hash=$null; Manifest=$null; Reason=[string]$result.reasonCode } }
  return [pscustomobject]@{ Ready=$true; Hash=[string]$result.currentHash; Manifest=$result.data; Reason=$null }
}

function Invoke-ChainStoreVerify {
  param([string]$Root)
  $adapter = Join-Path $Root 'tools\chain-store.ps1'
  if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { return [pscustomobject]@{ Ready=$false; Result=$null } }
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Action Verify -ControllerRoot $Root 2>$null
  $exitCode = $LASTEXITCODE
  try { $result = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
  catch { return [pscustomobject]@{ Ready=$false; Result=$null } }
  return [pscustomobject]@{ Ready=($exitCode -eq 0 -and $result.status -ceq 'verified'); Result=$result }
}

function Get-Inventory {
  param([string]$Root, [bool]$RequireComplete, [bool]$EnforceName)
  $missing = New-Object Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Root)) {
    $allScaffold = @($scaffoldDirectories) + @($scaffoldPaths)
    if ($RequireComplete) { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Initialize the controller before verification.'; Missing=$allScaffold; CurrentHash=$null } }
    foreach ($path in $allScaffold) { $missing.Add($path) }
    return [pscustomobject]@{ Ready=$true; Reason=$null; Next=$null; Missing=@($missing); CurrentHash=$null; Manifest=$null }
  }
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='The controller root must be a directory.'; Missing=@(); CurrentHash=$null }
  }
  $manifestPath = Join-Path $Root '.codex-controller.json'
  $currentHash = if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-ReparseComponents $manifestPath)) {
    Get-Hash ([IO.File]::ReadAllBytes($manifestPath))
  } else { $null }

  $orphan = @(Get-ChildItem -Force -LiteralPath $Root | Where-Object { $_.Name -cmatch '^\.codex-controller\.[0-9a-f]{32}\.tmp$' })
  if ($orphan.Count -gt 0) {
    $candidate = $orphan[0]
    if ($candidate.PSIsContainer -or ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-Path -LiteralPath $candidate.FullName -PathType Leaf) -or -not (Test-ReparseComponents $candidate.FullName)) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Replace the unsafe orphan candidate $($candidate.Name) with no automatic read or removal."; Missing=@(); CurrentHash=$currentHash }
    }
    $hash = Get-Hash ([IO.File]::ReadAllBytes($candidate.FullName))
    return [pscustomobject]@{ Ready=$false; Reason='controller-candidate-orphaned'; Next="Inspect and explicitly remove $($candidate.Name) only if its SHA-256 is $hash, then rerun."; Missing=@(); CurrentHash=$currentHash }
  }

  $allowedRoot = @('.git', '.codex-controller.json', '.gitignore', '.chain-store.json', 'AGENTS.md', 'TASKS.md', 'docs', 'tools', 'memory', 'state', 'legacy')
  foreach ($item in @(Get-ChildItem -Force -LiteralPath $Root)) {
    if ($allowedRoot -cnotcontains $item.Name) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Remove or relocate the unknown inventory item $($item.Name), then rerun."; Missing=@(); CurrentHash=$currentHash }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Replace the reparse-point inventory item $($item.Name) with an in-root regular item."; Missing=@(); CurrentHash=$currentHash }
    }
    if ($item.Name -ceq '.git') { continue }
    if ($item.Name -in @('docs', 'tools', 'memory')) {
      if (-not $item.PSIsContainer) { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="$($item.Name) must be an in-root directory."; Missing=@(); CurrentHash=$currentHash } }
      $allowedChild = if ($item.Name -ceq 'docs') { @('cross-project-contracts.md') } elseif ($item.Name -ceq 'tools') { @('control-state.ps1','chain-store.ps1','dispatch-return-runtime.mjs') } else { @('MEMORY.md') }
      foreach ($child in @(Get-ChildItem -Force -LiteralPath $item.FullName)) {
        if ($allowedChild -cnotcontains $child.Name -or $child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Remove or relocate unknown or unsafe inventory under $($item.Name)."; Missing=@(); CurrentHash=$currentHash }
        }
      }
    }
    elseif ($item.Name -in @('state','legacy')) {
      if (-not $item.PSIsContainer) { return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="$($item.Name) must be an in-root directory."; Missing=@(); CurrentHash=$currentHash } }
    }
    elseif ($item.PSIsContainer) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="$($item.Name) must be an in-root regular file."; Missing=@(); CurrentHash=$currentHash }
    }
  }

  foreach ($relativePath in $scaffoldDirectories) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path)) { $missing.Add($relativePath); continue }
    if (-not (Test-Path -LiteralPath $path -PathType Container) -or -not (Test-ReparseComponents $path)) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Replace unsafe managed directory $relativePath only after manual review."; Missing=@(); CurrentHash=$currentHash }
    }
  }

  foreach ($relativePath in $scaffoldPaths) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing.Add($relativePath); continue }
    if (-not (Test-ReparseComponents $path)) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Replace unsafe managed path $relativePath only after manual review."; Missing=@(); CurrentHash=$currentHash }
    }
    if ($byteManagedPaths -ccontains $relativePath) {
      if (-not (Test-BytesEqual ([IO.File]::ReadAllBytes($path)) ([byte[]](Get-ExpectedBytes $relativePath)))) {
        return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next="Preserve and review differing managed file $relativePath; it will not be overwritten."; Missing=@(); CurrentHash=$currentHash }
      }
    }
  }
  if ($RequireComplete -and $missing.Count -gt 0) {
    return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Restore the missing scaffold files, then verify again.'; Missing=@($missing); CurrentHash=$currentHash }
  }

  $state = $null
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $state = Invoke-StateRead -Root $Root -PreferGenerated ($missing -cnotcontains 'tools\control-state.ps1')
    if (-not $state.Ready -or ($EnforceName -and [string]$state.Manifest.controllerName -cne $ControllerName)) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Preserve and review the invalid or differently named manifest; it will not be overwritten.'; Missing=@(); CurrentHash=$currentHash }
    }
  }
  $storeRequired = @($scaffoldDirectories | Where-Object { $_ -in @('memory','state','state\active','state\archive','state\goals') }) + @('.chain-store.json','tools\chain-store.ps1') + @($generatedStorePaths)
  if (@($storeRequired | Where-Object { $missing -ccontains $_ }).Count -eq 0) {
    $store = Invoke-ChainStoreVerify -Root $Root
    if (-not $store.Ready) {
      return [pscustomobject]@{ Ready=$false; Reason='controller-filesystem-conflict'; Next='Run the chain-store verifier and rebuild only derived state after inspecting its exact failure.'; Missing=@(); CurrentHash=$currentHash }
    }
  }
  return [pscustomobject]@{ Ready=$true; Reason=$null; Next=$null; Missing=@($missing); CurrentHash=$currentHash; Manifest=if ($null -ne $state) { $state.Manifest } else { $null } }
}

function Get-LegacyInventory {
  param([string]$Root, [bool]$EnforceName)
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
  $allowedRoot = @('.git', '.codex-controller.json', '.gitignore', 'AGENTS.md', 'docs', 'tools')
  foreach ($item in @(Get-ChildItem -Force -LiteralPath $Root)) {
    if ($allowedRoot -cnotcontains $item.Name -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
    if ($item.Name -ceq '.git') { continue }
    if ($item.Name -in @('docs','tools')) {
      if (-not $item.PSIsContainer) { return $null }
      $allowedChild = if ($item.Name -ceq 'docs') { 'cross-project-contracts.md' } else { 'control-state.ps1' }
      foreach ($child in @(Get-ChildItem -Force -LiteralPath $item.FullName)) {
        if ($child.Name -cne $allowedChild -or $child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
      }
    }
    elseif ($item.PSIsContainer) { return $null }
  }
  foreach ($relativePath in $legacyScaffoldPaths) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-ReparseComponents $path)) { return $null }
  }
  foreach ($relativePath in @('.gitignore','AGENTS.md','tools\control-state.ps1')) {
    $hash = Get-Hash ([IO.File]::ReadAllBytes((Join-Path $Root $relativePath)))
    $currentHash = Get-Hash (Get-ExpectedBytes $relativePath)
    if ($hash -cne $legacyV1ManagedHashes[$relativePath] -and $hash -cne $legacyV2ManagedHashes[$relativePath] -and $hash -cne $currentHash) { return $null }
  }
  $state = Invoke-StateRead -Root $Root -PreferGenerated $false
  if (-not $state.Ready -or $state.Manifest.schemaVersion -notin @(1,2) -or $state.Manifest.templateVersion -ne $state.Manifest.schemaVersion -or
      ($EnforceName -and [string]$state.Manifest.controllerName -cne $ControllerName)) { return $null }
  return [pscustomobject]@{ Manifest=$state.Manifest; CurrentHash=$state.Hash }
}

function Test-ControllerQuiescent {
  param($Manifest)
  if ($Manifest.schemaVersion -ne 2) { return $true }
  return @($Manifest.dispatchQueues | Where-Object { $null -ne $_.active -or @($_.pending).Count -gt 0 }).Count -eq 0
}

function Write-NewFile {
  param([string]$Path, [byte[]]$Bytes)
  $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() }
  finally { $stream.Dispose() }
}

function Get-ControllerMutexName {
  param([string]$Root)
  return 'Local\onboard-code-projects-' + (Get-Hash $utf8.GetBytes($Root.ToUpperInvariant()))
}

function Invoke-LegacyUpgrade {
  param([string]$Root, [object]$Legacy)
  $mutex = New-Object Threading.Mutex($false, (Get-ControllerMutexName $Root))
  $acquired = $false
  $candidates = @()
  $backups = @()
  $replaced = @()
  $createdPaths = @()
  $createdDirectories = @()
  try {
    try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'upgrade-mutex-timeout' }
    $current = Get-LegacyInventory -Root $Root -EnforceName $true
    if ($null -eq $current -or $current.CurrentHash -cne $Legacy.CurrentHash) { throw 'upgrade-state-changed' }

    $queues = @()
    if ($current.Manifest.schemaVersion -eq 2) { $queues = @($current.Manifest.dispatchQueues) }
    $manifest = [pscustomobject][ordered]@{
      schemaVersion=2; generator='onboard-code-projects'; templateVersion=2; controllerName=[string]$current.Manifest.controllerName
      controllerBinding=$current.Manifest.controllerBinding; controllerTaskIntent=$current.Manifest.controllerTaskIntent
      projectBindings=@($current.Manifest.projectBindings); dispatchQueues=$queues
    }
    $replacementBytes = [ordered]@{
      '.codex-controller.json' = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress) + "`n")
      '.gitignore' = [byte[]](Get-ExpectedBytes '.gitignore')
      'AGENTS.md' = [byte[]](Get-ExpectedBytes 'AGENTS.md')
      'tools\control-state.ps1' = [byte[]](Get-ExpectedBytes 'tools\control-state.ps1')
    }
    foreach ($relativePath in $replacementBytes.Keys) {
      $target = Join-Path $Root $relativePath
      $directory = Split-Path -Parent $target
      $leaf = Split-Path -Leaf $target
      $id = [guid]::NewGuid().ToString('N').ToLowerInvariant()
      $candidate = Join-Path $directory ('.' + $leaf + '.' + $id + '.upgrade.tmp')
      $backup = Join-Path $directory ('.' + $leaf + '.' + $id + '.upgrade.bak')
      Write-NewFile -Path $candidate -Bytes ([byte[]]$replacementBytes[$relativePath])
      $candidates += $candidate; $backups += $backup
    }
    for ($index = 0; $index -lt $replacementBytes.Count; $index++) {
      $target = Join-Path $Root @($replacementBytes.Keys)[$index]
      [IO.File]::Replace($candidates[$index], $target, $backups[$index])
      $replaced += $index
    }
    foreach ($directory in @('memory','state','state\active','state\archive','state\goals')) {
      $directoryPath = Join-Path $Root $directory
      [IO.Directory]::CreateDirectory($directoryPath) | Out-Null
      $createdDirectories += $directoryPath
    }
    foreach ($relativePath in @('.chain-store.json','tools\chain-store.ps1',$runtimePath)) {
      $path = Join-Path $Root $relativePath
      Write-NewFile -Path $path -Bytes (Get-ExpectedBytes $relativePath)
      $createdPaths += $path
    }
    $createdPaths += @($generatedStorePaths | ForEach-Object { Join-Path $Root $_ })
    $createdPaths += Join-Path $Root 'state\.rebuild-required'
    $chainAdapter = Join-Path $Root 'tools\chain-store.ps1'
    $chainOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chainAdapter -Action Rebuild -ControllerRoot $Root 2>$null
    $chainExit = $LASTEXITCODE
    if ($chainExit -ne 0) { throw 'upgrade-chain-store-failed' }
    foreach ($relativePath in $byteManagedPaths) {
      if (-not (Test-BytesEqual ([IO.File]::ReadAllBytes((Join-Path $Root $relativePath))) (Get-ExpectedBytes $relativePath))) { throw "upgrade-managed-readback-failed:$relativePath" }
    }
    $state = Invoke-StateRead -Root $Root -PreferGenerated $true
    if (-not $state.Ready) { throw "upgrade-manifest-readback-failed:$($state.Reason)" }
    if ($state.Manifest.schemaVersion -ne 2 -or @($state.Manifest.dispatchQueues).Count -ne $queues.Count) { throw 'upgrade-manifest-readback-failed:content' }
    $store = Invoke-ChainStoreVerify -Root $Root
    if (-not $store.Ready) { throw 'upgrade-store-readback-failed' }
    foreach ($backup in $backups) { if (Test-Path -LiteralPath $backup -PathType Leaf) { [IO.File]::Delete($backup) } }
    return [pscustomobject]@{ Ready=$true; CurrentHash=$state.Hash; Manifest=$state.Manifest }
  }
  catch {
    foreach ($index in @($replaced | Sort-Object -Descending)) {
      if (Test-Path -LiteralPath $backups[$index] -PathType Leaf) {
        try { [IO.File]::Replace($backups[$index], (Join-Path $Root @($replacementBytes.Keys)[$index]), [System.Management.Automation.Language.NullString]::Value) } catch {}
      }
    }
    foreach ($path in @($createdPaths | Sort-Object -Unique -Descending)) {
      if (Test-Path -LiteralPath $path -PathType Leaf) { try { [IO.File]::Delete($path) } catch {} }
    }
    foreach ($path in @($createdDirectories | Sort-Object { $_.Length } -Descending)) {
      if ((Test-Path -LiteralPath $path -PathType Container) -and @(Get-ChildItem -Force -LiteralPath $path).Count -eq 0) { try { [IO.Directory]::Delete($path) } catch {} }
    }
    throw
  }
  finally {
    foreach ($path in @($candidates) + @($backups)) { if (Test-Path -LiteralPath $path -PathType Leaf) { try { [IO.File]::Delete($path) } catch {} } }
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

$didWrite = $false
$reportedCurrentHash = $null
$normalizedRoot = $ControllerRoot
try {
  if ($Action -cnotin @('Plan', 'Apply', 'Verify')) {
    Finish -Status 'invalid' -ReasonCode 'invalid-controller-input' -Root $ControllerRoot -Changed $false -PlannedCreates @() -CurrentHash $null -ResultHash $null -NextAction 'Use Action Plan, Apply, or Verify.' -ExitCode 2
  }
  if ([string]::IsNullOrWhiteSpace($ControllerName) -or $ControllerName.Length -gt 80 -or $ControllerName -match '[\x00-\x1f\x7f/\\]') {
    Finish -Status 'invalid' -ReasonCode 'invalid-controller-input' -Root $ControllerRoot -Changed $false -PlannedCreates @() -CurrentHash $null -ResultHash $null -NextAction 'Use a non-blank controller name of at most 80 characters without control characters or slashes.' -ExitCode 2
  }

  $rootResult = Resolve-ControllerRoot $ControllerRoot
  if (-not $rootResult.Ready) {
    $exitCode = if ($rootResult.Status -ceq 'invalid') { 2 } else { 1 }
    Finish -Status $rootResult.Status -ReasonCode $rootResult.Reason -Root $rootResult.Root -Changed $false -PlannedCreates @() -CurrentHash $null -ResultHash $null -NextAction $rootResult.Next -ExitCode $exitCode
  }
  $normalizedRoot = $rootResult.Root

  $templates = Read-CanonicalTemplates
  if (-not $templates.Ready) {
    $templateStatus = if ($templates.Reason -ceq 'controller-io-failure') { 'blocked' } else { 'conflict' }
    Finish -Status $templateStatus -ReasonCode $templates.Reason -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $null -ResultHash $null -NextAction $templates.Next -ExitCode 1
  }
  $templateBytes = $templates.Bytes

  $legacy = Get-LegacyInventory -Root $normalizedRoot -EnforceName ($Action -in @('Plan','Apply'))
  if ($null -ne $legacy) {
    $reportedCurrentHash = $legacy.CurrentHash
    $legacyRoots = @($BusinessProjectRoots) + @($legacy.Manifest.projectBindings | ForEach-Object { [string]$_.projectRoot })
    try { $legacyOverlaps = Test-Overlap -Root $normalizedRoot -BusinessRoots $legacyRoots }
    catch {
      Finish -Status 'invalid' -ReasonCode 'invalid-controller-input' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Use valid absolute Windows paths for BusinessProjectRoots.' -ExitCode 2
    }
    if ($legacyOverlaps) {
      Finish -Status 'conflict' -ReasonCode 'controller-root-overlap' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Choose a controller root outside every business project root.' -ExitCode 1
    }
    if (-not (Test-ControllerQuiescent $legacy.Manifest)) {
      Finish -Status 'conflict' -ReasonCode 'controller-upgrade-active-work' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Finish, terminally cancel, or reconcile every active and pending dispatch before changing the pinned controller runtime.' -ExitCode 1
    }
    $upgradePaths = @('.codex-controller.json','.gitignore','AGENTS.md','tools\control-state.ps1','.chain-store.json','tools\chain-store.ps1',$runtimePath,'memory','state','state\active','state\archive','state\goals') + $generatedStorePaths
    if ($Action -ceq 'Verify') {
      Finish -Status 'conflict' -ReasonCode 'controller-upgrade-required' -Root $normalizedRoot -Changed $false -PlannedCreates $upgradePaths -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Run Plan with AllowUpgrade after explicit authorization; Verify never migrates files.' -ExitCode 1
    }
    if (-not $AllowUpgrade) {
      Finish -Status 'authorization-required' -ReasonCode 'controller-upgrade-authorization-required' -Root $normalizedRoot -Changed $false -PlannedCreates $upgradePaths -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Obtain explicit controller-template upgrade authorization, then rerun Plan with AllowUpgrade.' -ExitCode 1
    }
    if ($Action -ceq 'Plan') {
      Finish -Status 'planned' -ReasonCode 'controller-upgrade-plan-ready' -Root $normalizedRoot -Changed $true -PlannedCreates $upgradePaths -CurrentHash $legacy.CurrentHash -ResultHash $null -NextAction 'Run Apply with AllowUpgrade and the same controller root, name, and business project roots.' -ExitCode 0
    }
    $upgraded = Invoke-LegacyUpgrade -Root $normalizedRoot -Legacy $legacy
    Finish -Status 'applied' -ReasonCode 'controller-upgraded' -Root $normalizedRoot -Changed $true -PlannedCreates $upgradePaths -CurrentHash $legacy.CurrentHash -ResultHash $upgraded.CurrentHash -NextAction 'Continue with the preserved bindings and the empty v2 per-project dispatch queues.' -ExitCode 0
  }

  $inventory = Get-Inventory -Root $normalizedRoot -RequireComplete ($Action -ceq 'Verify') -EnforceName ($Action -in @('Plan', 'Apply'))
  $reportedCurrentHash = $inventory.CurrentHash
  if (-not $inventory.Ready) {
    Finish -Status 'conflict' -ReasonCode $inventory.Reason -Root $normalizedRoot -Changed $false -PlannedCreates @($inventory.Missing) -CurrentHash $inventory.CurrentHash -ResultHash $null -NextAction $inventory.Next -ExitCode 1
  }

  if ($Action -in @('Plan', 'Apply')) {
    $overlapRoots = @($BusinessProjectRoots)
    if ($null -ne $inventory.Manifest) {
      $overlapRoots += @($inventory.Manifest.projectBindings | ForEach-Object { [string]$_.projectRoot })
    }
    try { $overlaps = Test-Overlap -Root $normalizedRoot -BusinessRoots $overlapRoots }
    catch {
      Finish -Status 'invalid' -ReasonCode 'invalid-controller-input' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $inventory.CurrentHash -ResultHash $null -NextAction 'Use valid absolute Windows paths for BusinessProjectRoots.' -ExitCode 2
    }
    if ($overlaps) {
      Finish -Status 'conflict' -ReasonCode 'controller-root-overlap' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $inventory.CurrentHash -ResultHash $null -NextAction 'Choose a controller root outside every business project root.' -ExitCode 1
    }
  }

  $planned = @($inventory.Missing)
  if ($Action -ceq 'Plan') {
    Finish -Status 'planned' -ReasonCode 'controller-plan-ready' -Root $normalizedRoot -Changed ($planned.Count -gt 0) -PlannedCreates $planned -CurrentHash $inventory.CurrentHash -ResultHash $inventory.CurrentHash -NextAction 'Run Apply with the same controller root, name, and business project roots.' -ExitCode 0
  }
  if ($Action -ceq 'Verify') {
    $state = Invoke-StateRead -Root $normalizedRoot -PreferGenerated $true
    if (-not $state.Ready) {
      Finish -Status 'conflict' -ReasonCode 'controller-filesystem-conflict' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $inventory.CurrentHash -ResultHash $null -NextAction 'Review the generated state adapter and manifest before retrying.' -ExitCode 1
    }
    Finish -Status 'verified' -ReasonCode 'controller-verified' -Root $normalizedRoot -Changed $false -PlannedCreates @() -CurrentHash $inventory.CurrentHash -ResultHash $state.Hash -NextAction 'Use this exact saved controller project for controller-bound onboarding.' -ExitCode 0
  }

  $changed = $planned.Count -gt 0
  if (-not (Test-Path -LiteralPath $normalizedRoot)) {
    if (-not (Test-ReparseComponents $normalizedRoot)) { throw 'A reparse point appeared before root creation' }
    [IO.Directory]::CreateDirectory($normalizedRoot) | Out-Null
    $didWrite = $true
  }
  foreach ($directory in $scaffoldDirectories) {
    $directoryPath = Join-Path $normalizedRoot $directory
    if (-not (Test-Path -LiteralPath $directoryPath)) {
      if (-not (Test-ReparseComponents $directoryPath)) { throw "A reparse point appeared before creating $directory" }
      [IO.Directory]::CreateDirectory($directoryPath) | Out-Null
      $didWrite = $true
    }
  }
  foreach ($relativePath in $scaffoldPaths) {
    if ($planned -cnotcontains $relativePath) { continue }
    if ($generatedStorePaths -ccontains $relativePath) { continue }
    $path = Join-Path $normalizedRoot $relativePath
    if (-not (Test-ReparseComponents $path)) { throw "A reparse point appeared before creating $relativePath" }
    Write-NewFile -Path $path -Bytes (Get-ExpectedBytes $relativePath)
    $didWrite = $true
  }
  $storePlanItems = @('.chain-store.json','tools\chain-store.ps1','memory','state','state\active','state\archive','state\goals') + $generatedStorePaths
  if (@($planned | Where-Object { $storePlanItems -ccontains $_ }).Count -gt 0) {
    $chainAdapter = Join-Path $normalizedRoot 'tools\chain-store.ps1'
    $chainOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chainAdapter -Action Rebuild -ControllerRoot $normalizedRoot 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Generated chain-store rebuild failed' }
    $didWrite = $true
  }
  $verified = Get-Inventory -Root $normalizedRoot -RequireComplete $true -EnforceName $true
  if (-not $verified.Ready) { throw 'Post-write verification failed' }
  $state = Invoke-StateRead -Root $normalizedRoot -PreferGenerated $true
  if (-not $state.Ready -or [string]$state.Manifest.controllerName -cne $ControllerName) { throw 'Generated state adapter verification failed' }
  Finish -Status 'applied' -ReasonCode 'controller-initialized' -Root $normalizedRoot -Changed $changed -PlannedCreates $planned -CurrentHash $inventory.CurrentHash -ResultHash $state.Hash -NextAction 'Save this directory as a Codex project, then request controller task creation.' -ExitCode 0
}
catch {
  Finish -Status 'blocked' -ReasonCode 'controller-io-failure' -Root $normalizedRoot -Changed $didWrite -PlannedCreates @() -CurrentHash $reportedCurrentHash -ResultHash $null -NextAction 'Inspect the controller root for a concurrent change or I/O failure, then rerun Plan.' -Warnings @('An I/O operation failed within the controller boundary.') -ExitCode 1
}
