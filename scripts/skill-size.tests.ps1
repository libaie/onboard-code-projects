[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$skillPath = Join-Path $skillRoot 'SKILL.md'
$runtimeReference = Join-Path $skillRoot 'references\controller-runtime.md'
$skill = Get-Content -Raw -Encoding UTF8 -LiteralPath $skillPath
$wordCount = [regex]::Matches($skill, '\S+').Count

if ($wordCount -gt 5000) {
  throw "SKILL.md exceeds the 5000-word progressive-disclosure ceiling: $wordCount"
}
if (-not (Test-Path -LiteralPath $runtimeReference -PathType Leaf)) {
  throw 'Controller runtime detail must live in references/controller-runtime.md'
}
if ($skill -notmatch '(?is)controller input.{0,300}read.{0,160}references/controller-runtime\.md') {
  throw 'SKILL.md must route controller work to the runtime reference'
}

Write-Output "PASS skill-size words=$wordCount"
