[CmdletBinding()]
param([switch]$FocusedTaskSetReset)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$skillRootDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'SKILL.md')
$controllerReference = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'references\controller-runtime.md')
$skill = $skillRootDocument + "`n" + $controllerReference
$skillPolicy = $skill
$readme = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'README.md')
$readmeZh = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'README.zh-CN.md')
$contributing = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'CONTRIBUTING.md')
$agentManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'agents\openai.yaml')
$preflight = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'scripts\preflight.ps1')
$initializer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'scripts\init-controller.ps1')
$controllerPolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'templates\controller\AGENTS.md')
$effectiveControllerPolicy = $skillPolicy + "`n" + $controllerPolicy
$dispatchRuntime = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'scripts\dispatch-return-runtime.mjs')
$chainStore = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'templates\controller\tools\chain-store.ps1')
$controlState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'templates\controller\tools\control-state.ps1')
$controllerGitIgnore = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'templates\controller\.gitignore')

function Assert-Contains {
  param([string]$Text, [string]$Pattern, [string]$Message)
  if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-File {
  param([string]$RelativePath)
  if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $RelativePath) -PathType Leaf)) {
    throw "Required package file is missing: $RelativePath"
  }
}

function Assert-InOrder {
  param([string]$Text, [string[]]$Markers, [string]$Message)
  $position = 0
  foreach ($marker in $Markers) {
    $next = $Text.IndexOf($marker, $position, [StringComparison]::Ordinal)
    if ($next -lt 0) { throw "$Message (missing or out of order: $marker)" }
    $position = $next + $marker.Length
  }
}

function Assert-TaskSetResetContract {
  $policyDocuments = @(
    @{ Name = 'root Skill'; Text = $skillRootDocument },
    @{ Name = 'controller runtime reference'; Text = $controllerReference },
    @{ Name = 'generated controller policy'; Text = $controllerPolicy }
  )
  foreach ($document in $policyDocuments) {
    $text = $document.Text
    $name = $document.Name
    Assert-Contains $text 'resetControllerTasks\s*=\s*true' "$name must require explicit reset authorization"
    Assert-Contains $text '(?is)read-only\s+`?PlanTaskSetReset`?.{0,300}canonical\s+`?planHash`?.{0,300}must not call\s+`?PrepareCandidate`?' `
      "$name must use a write-free adapter Plan without leaving a candidate"
    Assert-Contains $text '(?is)separate\s+`?Apply\(planHash\)`?.{0,300}exact returned hash' `
      "$name must require a separate Apply request with the exact canonical planHash"
    Assert-Contains $text '(?is)(?:separate|independent).{0,240}coordinator task.{0,300}outside the scoped reset set.{0,1800}archived last' `
      "$name must require a non-scoped coordinator and archive it last"
    Assert-Contains $text '(?is)exact generated v3.{0,500}(?:custom|legacy).{0,300}store[- ]backed v2.{0,300}(?:unsupported|fail closed|capability unavailable)' `
      "$name must expose reset only for exact generated v3 and fail closed for custom or store-backed adapters"
    Assert-Contains $text '(?is)planHash.{0,300}binds exactly.{0,300}operationId.{0,200}fromTaskSetId.{0,300}(?:strictly derived|deterministic).{0,200}toTaskSetId.{0,300}coordinator identity.{0,300}old controller and project bindings.{0,300}target root.{0,300}creation operation ID.{0,300}(?:saved-project|saved project|codexProjectId).{0,200}host' `
      "$name must bind only the stable authorized replacement scope into planHash"
    Assert-Contains $text '(?is)planHash.{0,1000}(?:does not|must not).{0,120}(?:bind|include).{0,300}(?:summary|summaryHash).{0,300}historyDigest.{0,300}(?:quiescence|externalQuiescence).{0,300}(?:active CHAIN|CHAIN head).{0,300}(?:timestamp|observedAt)' `
      "$name must exclude all dynamic Apply evidence from planHash"
    Assert-Contains $text '(?is)Apply.{0,300}(?:fresh|re-read|resample).{0,500}(?:history|quiescence|CHAIN head).{0,500}(?:gate|audit|evidence)' `
      "$name must collect dynamic evidence as an Apply gate and audit instead of user reauthorization"
    Assert-Contains $text '(?is)historyDigest.{0,300}read_thread.{0,300}hasMore=false.{0,300}non-`?inProgress`?.{0,300}oldest to newest.{0,300}turnId,status,completedAt.{0,300}UTF-8 compact JSON.{0,200}SHA-256.{0,300}oldestTurnId.{0,200}newestTurnId.{0,200}turnCount.{0,200}eofComplete=true' `
      "$name must define one reproducible closed historyDigest algorithm"
    Assert-Contains $text '(?is)(?:Do not|Never).{0,160}message text.{0,120}tool output.{0,240}(?:digest|replacement prompt).{0,300}summaryHash' `
      "$name must keep raw conversation content out of historyDigest and bind the summary separately"
    Assert-Contains $text '(?is)Before prepare.{0,300}before the first archive.{0,300}before complete/unfreeze.{0,300}canonical store.{0,300}same head.{0,300}Never modify, mutate, or rebind a CHAIN' `
      "$name must preserve CHAIN identity and revalidate canonical heads at every destructive boundary"
    Assert-Contains $text '(?is)(?:freeze|frozen).{0,300}project bootstrap replacements first.{0,300}controller bootstrap replacement last.{0,500}standby.{0,300}(?:without|no).{0,160}(?:business summary|handoff)' `
      "$name must create exact bootstrap replacements once without premature business handoff"
    Assert-Contains $text '(?is)(?:fully read|paginate).{0,200}(?:sanitize|redact).{0,200}(?:pre-summarize|pre-summary).{0,200}old histor.{0,400}archive.{0,240}old project task.{0,300}old controller task' `
      "$name must pre-summarize complete old history before freezing it"
    Assert-Contains $text '(?is)(?:digest drift|history drift|drifted).{0,300}(?:re-summarize|rebuild).{0,240}(?:final complete|complete archived|final full).{0,160}histor.{0,300}(?:never|without).{0,120}(?:a )?delta' `
      "$name must rebuild the final handoff from frozen full history rather than append a delta"
    Assert-Contains $text '(?is)(?:persist|record).{0,240}final handoff.{0,300}(?:send|deliver).{0,240}(?:new tasks|new task).{0,300}(?:standby ack|standby acknowledgement).{0,300}runtime replacement prepare.{0,240}atomic whole-set manifest switch.{0,240}runtime replacement commit and exact readback.{0,300}manifest completion seal.{0,300}runtime fence completion.{0,300}RecoverTaskSetResetSeal.{0,300}(?:unfreeze|resume ordinary work).{0,300}archive the non-scoped coordinator last' `
      "$name must persist and acknowledge final handoff before the forward-only cutover"
    Assert-Contains $text '(?is)prepare-task-set-reset-fence.{0,300}before.{0,200}(?:manifest Apply|PrepareCandidate).{0,300}exact runtime readback.{0,300}initialEvidenceHash' `
      "$name must acquire and audit the runtime fence before manifest Apply"
    Assert-Contains $text '(?is)seal marker.{0,300}(?:blocks|freezes).{0,300}(?:controller|CHAIN).{0,120}(?:and|plus).{0,120}runtime.{0,300}complete-task-set-reset-fence.{0,300}exact final manifest hash.{0,300}RecoverTaskSetResetSeal.{0,300}(?:only|sole).{0,160}(?:unfreeze|release)' `
      "$name must use one proof-gated unfreeze boundary across all stores"
    Assert-Contains $text '(?is)(?:archive.{0,240}freez.{0,160}histor).{0,500}(?:never|without).{0,160}(?:delta handoff|incremental handoff|a delta)|(?:never|without).{0,160}(?:delta handoff|incremental handoff|a delta).{0,500}(?:history drift|frozen history|freezing history)' `
      "$name must reject delta handoff and freeze old history before cutover"
    Assert-Contains $text '(?is)initialEvidenceHash.{0,300}(?:Apply|initial).{0,300}(?:history|historyDigest).{0,300}quiescence.{0,300}(?:active CHAIN|CHAIN head).{0,500}finalEvidenceHash.{0,300}(?:archived|final).{0,300}(?:history|historyDigest).{0,300}quiescence.{0,300}(?:active CHAIN|CHAIN head)' `
      "$name must bind initial and final closed execution evidence independently from planHash"
    Assert-Contains $text '(?is)(?:evidence changes|changed evidence).{0,300}(?:recomputation|recompute|recalculate).{0,300}(?:record|audit).{0,300}(?:scope is unchanged|scope unchanged|same scope).{0,300}(?:do not|does not|without).{0,160}(?:new Plan|user reauthor)' `
      "$name must recompute changed evidence without meaningless scope reauthorization"
    Assert-Contains $text '(?is)(?:forged|fake).{0,200}(?:evidence|packet|hash).{0,300}(?:fail|reject)' `
      "$name must fail closed on forged execution evidence"
    Assert-Contains $text '(?is)Codex task-API readback packets.{0,200}audit evidence boundary.{0,300}local adapter.{0,300}closed packet.{0,200}recomputes its hash.{0,300}cannot cryptographically authenticate task APIs' `
      "$name must state the task-API audit boundary without claiming local cryptographic authenticity"
    Assert-Contains $text '(?is)(?:keep|reuse).{0,120}(?:receipt[- ]worker|worker).{0,120}automation unchanged|(?:receipt[- ]worker|worker).{0,120}(?:and|plus).{0,120}automation.{0,120}(?:reuse|unchanged)' `
      "$name must reuse the existing worker and automation"
    Assert-Contains $text '(?is)list_projects.{0,200}read_thread.{0,200}create_thread.{0,200}send_message_to_thread.{0,200}wait_threads.{0,200}set_thread_archived.{0,500}single-root.{0,300}(?:fail closed|instead of guessing cwd)' `
      "$name must fail closed unless exact project task APIs and single-root identity are proven"
    Assert-Contains $text '(?is)Restore the same paused heartbeat/automation only after completion readback.{0,300}never create a second worker or automation.{0,300}failure keeps that automation paused.{0,300}same operation' `
      "$name must resume the reused automation only after truthful completion"
    Assert-Contains $text '(?is)(?:initial|first) prompt.{0,300}creationOperationId.{0,300}(?:only|unique) marker|creationOperationId.{0,300}(?:initial|first) prompt.{0,300}(?:only|unique) marker' `
      "$name must place one creation marker in each bootstrap initial prompt"
    Assert-Contains $text '(?is)(?:client-only|empty|timed-out|timeout).{0,300}(?:never|do not|must never).{0,160}retry.{0,300}list_threads.{0,300}(?:saved project|codexProjectId).{0,200}(?:root|cwd).{0,200}host.{0,300}read_thread.{0,300}(?:initial user turn|first user turn).{0,200}marker' `
      "$name must reconcile an unknown bootstrap creation through authoritative task evidence"
    Assert-Contains $text '(?is)(?:zero|0).{0,100}(?:more than one|>1|multiple).{0,300}(?:frozen|unknown).{0,300}(?:one|unique).{0,240}(?:threadId|real task).{0,300}record the replacement' `
      "$name must bind a bootstrap replacement only after one unique real task match"
  }

  Assert-Contains $skillRootDocument '(?is)Apply accepts only exact known pre-store v1 or pre-store v2.{0,700}store[- ]backed v2.{0,300}(?:unsupported|fail closed).{0,300}separately reviewed migration' `
    'The Skill must limit legacy upgrade to known pre-store v1/v2 and fail closed for store-backed v2'

  Assert-Contains $controllerReference '(?is)PlanTaskSetReset payload.{0,500}operationId.{0,100}fromTaskSetId.{0,100}toTaskSetId.{0,100}coordinator.{0,100}expectedController.{0,100}expectedProjectBindings.{0,100}targets' `
    'The controller reference must publish the exact reset Plan payload'
  foreach ($operation in @(
    'prepare-task-set-reset','record-task-set-creation-issued','record-task-set-client-thread','record-task-set-replacement',
    'record-task-set-bootstrap-proof','record-task-set-archive','record-task-set-final-evidence','record-task-set-standby-proof',
    'record-task-set-runtime-prepared','switch-task-set','record-task-set-runtime-committed','complete-task-set-reset'
  )) {
    Assert-Contains $controllerReference ([regex]::Escape("${operation}:")) "The controller reference must publish the exact $operation payload"
  }
  foreach ($action in @('prepare-task-set-reset-fence','prepare-controller-replacement','read-controller-replacement','commit-controller-replacement','complete-task-set-reset-fence')) {
    Assert-Contains $controllerReference ([regex]::Escape("${action}:")) "The controller reference must publish the exact runtime $action payload"
  }

  foreach ($document in @($readme, $readmeZh)) {
    Assert-Contains $document '(?is)resetControllerTasks:\s*true.{0,900}Action:\s*Plan.{0,900}Action:\s*Apply.{0,300}planHash' `
      'Both READMEs must show the explicit two-request reset trigger'
    Assert-Contains $document '(?is)(?:separate coordinator task|\u72ec\u7acb coordinator \u4efb\u52a1)' `
      'Both READMEs must require a separate reset coordinator'
    Assert-Contains $document '(?is)(?:outside the set being replaced|\u88ab\u66ff\u6362\u96c6\u5408\u4e4b\u5916)' `
      'Both READMEs must keep the reset coordinator outside the replaced set'
    Assert-Contains $document '(?is)(?:archived last|\u6700\u540e\u5f52\u6863)' `
      'Both READMEs must archive the reset coordinator last'
    Assert-Contains $document '(?is)(?:exact generated v3|\u7cbe\u786e\u751f\u6210\u7684 v3)' `
      'Both READMEs must name the exact generated v3 reset boundary'
    Assert-Contains $document '(?is)(?:custom|\u81ea\u5b9a\u4e49).{0,120}(?:legacy|\u65e7\u7248).{0,160}(?:store[- ]backed v2|\u5df2\u6709\u72b6\u6001\u5b58\u50a8\u7684 v2)' `
      'Both READMEs must name unsupported custom, legacy, and store-backed v2 controllers'
    Assert-Contains $document '(?is)(?:block safely|fail closed|\u5b89\u5168\u963b\u65ad|\u5931\u8d25\u5173\u95ed)' `
      'Both READMEs must describe the exact-v3 boundary and fail-closed behavior'
    Assert-Contains $document '(?is)(?:standby|\u5f85\u547d\u4efb\u52a1).{0,500}(?:archives old tasks|freezes the complete old history|\u51bb\u7ed3\u65e7\u5386\u53f2).{0,500}(?:only then activates|\u540e\u624d\u6fc0\u6d3b)' `
      'Both READMEs must summarize standby then archive-old-before-switch behavior'
  }

  $workflowText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot '.github\workflows\windows-tests.yml')
  $releaseText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'docs\release-checklist.md')
  foreach ($entry in @(
    @{ Name = 'CI'; Text = $workflowText },
    @{ Name = 'release checklist'; Text = $releaseText }
  )) {
    Assert-Contains $entry.Text 'task-set-reset\.tests\.ps1' "$($entry.Name) must run task-set-reset.tests.ps1"
  }
  Assert-Contains $preflight "'scripts/task-set-reset\.tests\.ps1'" 'Release package gate must include task-set-reset.tests.ps1'
}

Assert-TaskSetResetContract
if ($FocusedTaskSetReset) {
  Write-Output 'PASS skill-contract task-set-reset'
  exit 0
}

if ($controllerPolicy -match '(?is)project lane.{0,80}exact `?projectTaskId`?') {
  throw 'Generated controller policy must not claim that the goal lane schema stores projectTaskId'
}
Assert-Contains $controllerPolicy '(?is)goal lane.{0,160}(?:keyed|identified).{0,80}`?projectRoot`?.{0,240}sealed dispatch.{0,160}exact `?projectTaskId`?' `
  'Generated controller policy must describe the actual goal-lane and sealed-dispatch identity boundary'

Assert-InOrder $readme @(
  '## Problems this Skill solves',
  '## What it creates',
  '## Quick start',
  '## Git URL onboarding',
  '## How it works',
  '## Requirements and diagnostics',
  '## Permissions and local data',
  '## Troubleshooting',
  '## Documentation'
) 'English README must lead with pain points and the shortest usable journey'
Assert-Contains $readme '(?is)## Problems this Skill solves.{0,4000}Context pollution.{0,700}Repository and baseline drift.{0,700}Task proliferation.{0,700}Lost completion signals.{0,700}Controller memory growth' `
  'English README must name the five primary multi-project pain points'
Assert-Contains $readme '(?is)## Quick start.{0,7000}\$skill-installer.{0,1800}\$onboard-code-projects.{0,1800}sources:.{0,1800}controllerRoot' `
  'English README quick start must cover installation, project onboarding, and optional controller setup'
$englishQuickStart = [regex]::Match($readme, '(?is)## Quick start(?<body>.*?)(?=## Git URL onboarding)').Groups['body'].Value
Assert-Contains $englishQuickStart '(?is)dispatchReturnMode:\s*foreground' 'A Skill-only English quick start must use foreground return without an installed Hook'
if ($englishQuickStart -match '(?is)dispatchReturnMode:\s*receipts-and-wake') { throw 'A Skill-only English quick start must not require the plugin receipt runtime' }

$zhPainHeading = [regex]::Unescape('## \u5b83\u89e3\u51b3\u4ec0\u4e48\u75db\u70b9')
$zhCreatesHeading = [regex]::Unescape('## \u5b83\u4f1a\u521b\u5efa\u4ec0\u4e48')
$zhQuickStartHeading = [regex]::Unescape('## \u5feb\u901f\u5f00\u59cb')
$zhGitHeading = [regex]::Unescape('## Git URL \u63a5\u5165')
$zhHowHeading = [regex]::Unescape('## \u5de5\u4f5c\u65b9\u5f0f')
$zhRequirementsHeading = [regex]::Unescape('## \u73af\u5883\u8981\u6c42\u4e0e\u53ea\u8bfb\u8bca\u65ad')
$zhPermissionsHeading = [regex]::Unescape('## \u6743\u9650\u4e0e\u672c\u5730\u6570\u636e')
$zhTroubleshootingHeading = [regex]::Unescape('## \u5e38\u89c1\u95ee\u9898')
$zhDocsHeading = [regex]::Unescape('## \u6587\u6863')
Assert-InOrder $readmeZh @(
  $zhPainHeading,
  $zhCreatesHeading,
  $zhQuickStartHeading,
  $zhGitHeading,
  $zhHowHeading,
  $zhRequirementsHeading,
  $zhPermissionsHeading,
  $zhTroubleshootingHeading,
  $zhDocsHeading
) 'Chinese README must lead with pain points and the shortest usable journey'
Assert-Contains $readmeZh '(?is)## \u5b83\u89e3\u51b3\u4ec0\u4e48\u75db\u70b9.{0,4000}\u4e0a\u4e0b\u6587\u6c61\u67d3.{0,700}\u4ed3\u5e93\u4e0e\u57fa\u7ebf\u6f02\u79fb.{0,700}\u4efb\u52a1\u81a8\u80c0.{0,700}\u5b8c\u6210\u72b6\u6001\u4e22\u5931.{0,700}\u4e2d\u63a7\u8bb0\u5fc6\u81a8\u80c0' `
  'Chinese README must name the five primary multi-project pain points'
Assert-Contains $readmeZh '(?is)## \u5feb\u901f\u5f00\u59cb.{0,7000}\$skill-installer.{0,1800}\$onboard-code-projects.{0,1800}sources:.{0,1800}controllerRoot' `
  'Chinese README quick start must cover installation, project onboarding, and optional controller setup'
$chineseQuickStart = [regex]::Match($readmeZh, '(?is)## \u5feb\u901f\u5f00\u59cb(?<body>.*?)(?=## Git URL \u63a5\u5165)').Groups['body'].Value
Assert-Contains $chineseQuickStart '(?is)dispatchReturnMode:\s*foreground' 'A Skill-only Chinese quick start must use foreground return without an installed Hook'
if ($chineseQuickStart -match '(?is)dispatchReturnMode:\s*receipts-and-wake') { throw 'A Skill-only Chinese quick start must not require the plugin receipt runtime' }

foreach ($installationReadme in @($readme, $readmeZh)) {
  Assert-Contains $installationReadme '(?is)\$skill-installer.{0,500}--repo\s+libaie/onboard-code-projects.{0,300}--path\s+\..{0,300}--name\s+onboard-code-projects' `
    'Both READMEs must provide the current installer with an executable repository path and destination name'
}

foreach ($intakePolicy in @($skillPolicy, $controllerPolicy)) {
  Assert-InOrder $intakePolicy @(
    'Shared known',
    'User-known / agent-unknown',
    'Agent-known / user-unknown',
    'Shared unknown'
  ) 'The four-quadrant intake protocol must be complete and ordered'
  Assert-Contains $intakePolicy '(?is)four-quadrant.{0,500}before.{0,300}(task.type|task type).{0,240}(risk|model).{0,300}(CHAIN|definition freeze|dispatch)' `
    'Four-quadrant intake must run before routing, model selection, freezing, and dispatch'
  Assert-Contains $intakePolicy '(?is)Shared known.{0,500}(sufficient|complete).{0,180}(execute|proceed).{0,180}(do not|never).{0,120}(ask|question)' `
    'Complete shared context must execute without repeated questions'
  Assert-Contains $intakePolicy '(?is)User-known / agent-unknown.{0,900}(at most|maximum) three.{0,180}(one round|single round).{0,500}materially change.{0,400}(objective|acceptance).{0,240}(scope|authorization|irreversible)' `
    'Material private context may trigger at most three questions in one round'
  Assert-Contains $intakePolicy '(?is)(non-material|does not materially).{0,300}(assumption|assumptions).{0,300}(exploration version|exploratory version)' `
    'Non-material gaps must use explicit assumptions and an exploration version'
  Assert-Contains $intakePolicy '(?is)(exploration version|exploratory version).{0,400}(does not|never).{0,240}(authorize|authorization).{0,240}(production|deploy|final evidence)' `
    'An exploration version must not silently expand authority or become final evidence'
  Assert-Contains $intakePolicy '(?is)Agent-known / user-unknown.{0,700}(challenge|correct).{0,180}(false|wrong).{0,120}(premise|assumption).{0,300}recommend.{0,240}(evidence|trade-off|tradeoff)' `
    'The agent must correct a weak premise and recommend a supported alternative'
  Assert-Contains $intakePolicy '(?is)Shared unknown.{0,500}falsifiable hypothes.{0,500}(one|single) variable.{0,300}success signal.{0,240}failure signal.{0,240}data to collect.{0,240}next decision' `
    'Shared unknowns must become falsifiable single-variable experiments'
  Assert-Contains $intakePolicy '(?is)(not|never).{0,180}(new ledger schema|authorization source).{0,600}objective.{0,120}nonGoals.{0,120}acceptance.{0,160}taskSpec.{0,160}contract' `
    'Intake outcomes must reuse existing controller facts instead of creating another schema or authority source'
}
foreach ($path in @(
  'scripts\chain-store.tests.ps1',
  'scripts\dispatch-return-runtime.mjs',
  'scripts\dispatch-return-runtime.tests.mjs',
  '.codex-plugin\plugin.json',
  'hooks\hooks.json',
  'skills\onboard-code-projects\SKILL.md',
  'templates\controller\.chain-store.json',
  'templates\controller\tools\chain-store.ps1'
)) { Assert-File $path }
foreach ($generatedTemplate in @('templates\controller\TASKS.md','templates\controller\memory\MEMORY.md','templates\controller\state\index.json')) {
  if (Test-Path -LiteralPath (Join-Path $skillRoot $generatedTemplate)) { throw "Derived controller view must be generated by the initializer, not shipped as an ignored template: $generatedTemplate" }
}
foreach ($ignoredView in @('/TASKS.md','/memory/MEMORY.md','/state/')) {
  Assert-Contains $controllerGitIgnore ('(?m)^' + [regex]::Escape($ignoredView) + '$') "Generated controller view must be ignored at runtime: $ignoredView"
}
foreach ($memoryPolicy in @($skillPolicy, $controllerPolicy)) {
  Assert-Contains $memoryPolicy '(?is)state/active.{0,300}state/archive' `
    'Controller policy must separate canonical per-CHAIN state from conversation and Markdown views'
  Assert-Contains $memoryPolicy '(?is)(conversation history|Markdown).{0,200}(never|not).{0,120}authoritative' `
    'Conversation and Markdown views must not override canonical controller state'
  Assert-Contains $memoryPolicy '(?is)memory/MEMORY\.md.{0,500}chain-store\.ps1.{0,120}(?:-Action )?Read.{0,500}(do not|never).{0,200}(preload|load).{0,200}(TASKS\.md|every task payload|archive)' `
    'Controller startup must use compact memory and avoid loading the full ledger or archive'
  Assert-Contains $memoryPolicy '(?is)state/index\.json.{0,300}memory/MEMORY\.md.{0,300}TASKS\.md' `
    'Derived controller views must remain rebuildable and non-authoritative'
  Assert-Contains $memoryPolicy '(?is)(generated|rebuildable).{0,600}(never|do not).{0,160}(edit|authoritative)' `
    'Generated controller views must not be edited or treated as authoritative'
  Assert-Contains $memoryPolicy '(?is)Put.{0,500}ExpectedEntryHash.{0,200}MISSING.{0,500}ConfirmTerminal.{0,400}(immutable|terminal)' `
    'CHAIN writes must use exact CAS and explicit immutable terminal transition'
}
foreach ($initializerPath in @('.chain-store.json','tools\chain-store.ps1','memory\MEMORY.md','state\index.json','TASKS.md')) {
  Assert-Contains $initializer ([regex]::Escape($initializerPath)) "Initializer must manage $initializerPath"
}
Assert-Contains $initializer '(?is)generatedStorePaths.{0,1200}chain-store\.ps1.{0,120}-Action Rebuild' `
  'Initializer must generate derived views through the chain store instead of copying ignored template files'

$expectedPolicyInvariants = @('I1-scope', 'I2-identity', 'I3-authority', 'I4-transition', 'I5-evidence', 'I6-isolation')
$actualPolicyInvariants = @([regex]::Matches($controllerPolicy, '(?m)^\| `(?<id>I[0-9]+-[a-z-]+)` \|') | ForEach-Object { $_.Groups['id'].Value })
if (($actualPolicyInvariants -join ',') -cne ($expectedPolicyInvariants -join ',')) {
  throw "Controller policy must expose exactly the closed invariant set: $($expectedPolicyInvariants -join ', ')"
}
Assert-Contains $controllerPolicy ([regex]::Escape('targetRoot, taskRole, operationClass, authoritySource, preconditions, postconditionEvidence, dependentLanes')) `
  'Every controller action must use one complete decision record'
Assert-Contains $controllerPolicy '(?is)default deny.{0,300}(dependent lane|dependent operation)' `
  'Missing policy proof must deny by default without blocking unrelated lanes'
Assert-Contains $controllerPolicy '(?is)review finding.{0,240}(violated invariant|invariant ID).{0,500}(?:(do not|never).{0,120}(case-specific|counterexample)|(case-specific|counterexample).{0,120}(do not|never))' `
  'Review findings must refine invariant evidence instead of appending counterexample clauses'
Assert-Contains $controllerPolicy '(?is)(no invariant|does not fit).{0,240}(design review|revise the invariant)' `
  'A genuinely new invariant class must trigger one model-level design revision'
Assert-Contains $controllerPolicy '(?is)review (?:is )?complete.{0,500}(new invariant class|existing invariant class)' `
  'Controller review must have a finite invariant-based completion condition'
Assert-Contains $controllerPolicy '(?is)failed review.{0,500}(one batch|single batch).{0,500}reviewMode.{0,160}pending.{0,240}reviewEvidence.{0,160}N/A' `
  'A failed review must remain a non-terminal batch instead of freezing acceptance evidence'
Assert-Contains $controllerPolicy '(?is)same CHAIN.{0,500}(same project entry|same entry task).{0,500}(unreleased|retain).{0,200}(write lease|lease).{0,500}(rework|dispatch generation)' `
  'Same-scope review rework must remain in the same CHAIN while retaining its lease'
foreach ($dispatchPolicy in @($effectiveControllerPolicy)) {
  if ($dispatchPolicy -match '(?is)the first failed review gets.{0,200}(repair|root-cause)') {
    throw 'Review policy must not reset the global retry budget for a first review failure'
  }
  Assert-Contains $dispatchPolicy '(?is)review failures?.{0,500}(consume|share).{0,160}(this|same|shared|global).{0,160}(attempt|retry|business)?.{0,120}budget' `
    'Review failure must consume the same global budget as every other failure class'
  Assert-Contains $dispatchPolicy '(?is)first (?:eligible )?failure.{0,300}(repair|root-cause).{0,400}second(?: (?:eligible )?failure)?.{0,300}(architecture rebaseline|architectural rebaseline)' `
    'Repair and rebaseline must be selected by the global failure ordinal'
}
Assert-Contains $controllerPolicy '(?is)successor CHAIN.{0,500}(objective|contract).{0,300}authorization' `
  'A successor CHAIN must be reserved for a real objective, contract, or authorization change'
Assert-Contains $controllerPolicy '(?is)zero unresolved findings.{0,500}(release|released).{0,200}(write lease|lease).{0,500}(record|confirm).{0,200}reviewEvidence' `
  'Only a clean final review may release the lease and confirm immutable evidence'
Assert-Contains $controllerPolicy '(?is)CONVERGENCE_FAILED.{0,400}(retain|unreleased).{0,200}(write lease|lease).{0,400}(user|authorization|objective|contract)' `
  'Convergence failure must retain the lease until an explicit changed decision prevents an automatic successor'
Assert-Contains $controllerPolicy '(?is)dispatch generation.{0,400}(same|atomic).{0,200}(task phase|state transition).{0,300}(unchanged|without)' `
  'A project generation increment must be coupled to its allowed task transition'
Assert-Contains $controllerPolicy '(?is)CONVERGENCE_FAILED.{0,500}(clean review|reviewEvidence).{0,300}(cannot|must not|never).{0,300}(release|unlock|clear)' `
  'Convergence failure must not be cleared by later clean-review evidence'
Assert-Contains $skill '(?is)implementation and review failures.{0,300}consume.{0,120}(this|business).{0,120}budget' `
  'The Skill and controller reference must route implementation and review failures through one bounded budget'

$retiredGoalProtocolPattern = '(?is)\b(?:GOAL_ACK|GOAL_CONFLICT|GOAL_MODE_UNAVAILABLE|GOAL_COMPLETE_REPLAY|goal-bootstrap|Phase-2 execute continuation|get_goal|create_goal|update_goal)\b'
foreach ($dispatchPolicy in @($effectiveControllerPolicy)) {
  if ($dispatchPolicy -match $retiredGoalProtocolPattern) {
    throw 'Active dispatch policy must not depend on the retired Goal protocol'
  }
  Assert-Contains $dispatchPolicy '(?is)single sealed dispatch.{0,500}chainId.{0,120}projectTaskId.{0,120}dispatchId.{0,120}generation.{0,120}rework.{0,120}taskSpecHash' `
    'Each attempt must use one sealed message bound to the full dispatch identity'
  Assert-Contains $dispatchPolicy '(?is)persist.{0,240}canonical.{0,20}taskSpec.{0,240}taskSpecHash.{0,240}before.{0,160}(send|delivery)' `
    'Canonical task semantics must be persisted before delivery'
  Assert-Contains $dispatchPolicy '(?is)readiness.{0,500}(exact|frozen).{0,240}target.{0,300}(access|capability).{0,300}(rollback|verification).{0,400}before.{0,160}(enqueue|dispatch|attempt)' `
    'Every new dispatch must freeze target readiness before attempt one'
  Assert-Contains $dispatchPolicy '(?is)(discovery|target identity|capability).{0,500}(before|outside).{0,200}(attempt one|attempt budget|three attempts)' `
    'Read-only discovery and capability setup must not consume implementation attempts'
  Assert-Contains $dispatchPolicy '(?is)native(?: |-)callback.{0,500}send_message_to_thread.{0,500}(wake|untrusted).{0,500}read_thread' `
    'Project completion must use a native wake callback that remains non-authoritative'
  Assert-Contains $dispatchPolicy '(?is)returnRoute.{0,400}controllerThreadId.{0,200}hostId.{0,500}(one|once|at-most-once).{0,160}callback' `
    'The sealed return route must bind one callback to the exact controller task'
  Assert-Contains $dispatchPolicy '(?is)(credential-file|credential file|credential locator).{0,300}(forbid|must not|never).{0,500}(opaque|capabilityRef|authorizationRef)' `
    'Controller dispatch must prohibit credential locators and carry only opaque capability references'
  Assert-Contains $dispatchPolicy '(?is)Historical experience import.{0,900}materialPreconditions.{0,600}sourceChainId.{0,200}sourceEntryHash.{0,200}evidenceHash.{0,200}observedAt' `
    'Historical experience import must preserve reconstructable preconditions and canonical evidence'
  Assert-Contains $dispatchPolicy '(?is)ExperienceImport.{0,1800}ExpectedEntryHash.{0,300}(CAS|idempotent)' `
    'Historical experience import must use replay-safe CAS'
  Assert-Contains $dispatchPolicy '(?is)target task.{0,300}AGENTS\.md.{0,300}(project root|targetRoot).{0,300}(branch|HEAD|dirtyHash).{0,300}(authorizedActions|authorized actions).{0,300}taskSpecHash' `
    'The target must validate policy, root, baseline, authority, and task hash before work'
  Assert-Contains $dispatchPolicy '(?is)delivery-unknown.{0,300}at-most-once.{0,300}(must not|never).{0,160}(resend|redispatch).{0,500}authoritative non-delivery.{0,300}(idle|not running)' `
    'Uncertain delivery must never duplicate work; only proven non-delivery may resend the same attempt'
  Assert-Contains $dispatchPolicy '(?is)(ten|10).{0,120}(one-minute|one minute).{0,160}(wait snapshot|wait_threads)' `
    'Foreground monitoring must remain bounded even when event receipts are enabled'
  Assert-Contains $dispatchPolicy '(?is)(foreground|invocation).{0,300}monitoring-paused|monitoring-paused.{0,300}(foreground|invocation)' `
    'Active work must pause after the bounded foreground monitoring window'
  Assert-Contains $dispatchPolicy '(?is)monitoring-paused.{0,240}(does not|must not|without).{0,120}(mutate|mutating|mutation|change|changing).{0,80}(manifest|state)' `
    'Monitoring pause is an invocation result, not an unsupported manifest phase'
  Assert-Contains $dispatchPolicy '(?is)(Stop Hook|Stop hook).{0,500}(receipt|inbox).{0,500}(matching|registered|taskSpecHash|dispatchId)' `
    'Dispatch policy must durably capture exact terminal receipts before controller acceptance'
  Assert-Contains $dispatchPolicy '(?is)receipts-and-wake.{0,500}(only|allowed).{0,500}(Stop Hook|hook).{0,300}Node.{0,500}(otherwise|fallback|downgrade).{0,300}native-callback.{0,300}foreground' `
    'Controller return mode must select durable wake only after capability proof and otherwise downgrade safely'
  Assert-Contains $dispatchPolicy '(?is)ExportDispatch.{0,300}(obtain|generate).{0,120}(not|before).{0,120}(send|delivery).{0,500}register(?:-dispatch)?.{0,500}(complete|full).{0,160}identity.{0,160}dispatchHash.{0,500}read-dispatch.{0,300}verify-dispatch.{0,400}(send|delivery)' `
    'Every controller-bound dispatch must export without sending, register the full identity and dispatch hash, verify readback, then deliver'
  if ($dispatchPolicy.Contains('`tools/dispatch-return-runtime.mjs`')) {
    throw 'Controller-bound dispatch must not invoke a controller-writable relative runtime copy'
  }
  Assert-Contains $dispatchPolicy '(?is)ExportDispatch.{0,500}(closed|exact).{0,180}(one-line|single-line).{0,100}JSON.{0,500}(no|never|must not).{0,120}Base64' `
    'Dispatch transport must use one exact closed JSON envelope without prompt-level parser rules'
  Assert-Contains $dispatchPolicy '(?is)reconcile-preflight-failure.{0,600}(branch|baseline).{0,120}HEAD.{0,120}dirtyHash.{0,500}(same attempt|same generation).{0,300}(without|does not|must not).{0,160}(?:consume|consuming|increment).{0,120}(business|convergence).{0,80}(attempt|budget)' `
    'Proven zero-repository preflight failures must be mechanically separated from business attempts'
  Assert-Contains $dispatchPolicy '(?is)(record-dispatch-outcome|recorded outcome).{0,300}(`?failureClass`?|exact failure).{0,240}(same|exact).{0,120}((terminal )?`?evidenceHash`?|evidence)' `
    'Preflight reconciliation must consume the exact recorded failure class and terminal evidence hash'
  Assert-Contains $dispatchPolicy '(?is)(terminal|returns exactly).{0,500}resultState.{0,120}failureClass.{0,300}(N/A|completed|cancelled)' `
    'Terminal evidence must carry a result-state-bound failure class'
  Assert-Contains $dispatchPolicy '(?is)(receipt.{0,80})?identity.{0,200}(binds|bound|includes).{0,120}(exact )?`?turnId`?' `
    'Durable receipt identity must bind the exact terminal turn'
  Assert-Contains $dispatchPolicy '(?is)(receipt|inbox).{0,500}((does not|must not|never).{0,200}(accept|complete|success)|is not completion).{0,500}(read_thread|evidence)' `
    'A hook receipt must remain receipt-only until controller evidence validation'
  Assert-Contains $dispatchPolicy '(?is)(no|never|must not).{0,180}(controller-bound|controller task).{0,160}(recurring heartbeat|visible heartbeat|self-message)' `
    'Event wakeup must not reintroduce a visible recurring controller heartbeat'
  Assert-Contains $dispatchPolicy '(?is)(dedicated|separate).{0,160}(receipt worker|receipt-worker).{0,300}((saved project|project-bound).{0,240}environment\.type=local|(the )?exact controller project)' `
    'Event wakeup must use one dedicated project-bound local receipt worker task'
  Assert-Contains $dispatchPolicy '(?is)heartbeat.{0,500}(paused|pause).{0,300}foreground.{0,500}(activate|enable|start).{0,500}active dispatch.{0,300}(pause|zero|disable|stop)' `
    'The worker heartbeat must run only after foreground pause and stop when no dispatch remains'
  Assert-Contains $dispatchPolicy '(?is)(receipt worker|receipt-worker|the worker).{0,700}(absolute|fully qualified|exact installed).{0,160}(runtime|dispatch-return-runtime)' `
    'The receipt worker must use an absolute runtime path because a saved project may expose multiple working directories'
  Assert-Contains $dispatchPolicy '(?is)(persist|durable).{0,300}((worker|receipt-worker).{0,240}(intent|operationId).{0,300}(read back|readback)|(read back|readback).{0,160}(worker|receipt-worker).{0,160}(intent|operationId)).{0,300}create_thread' `
    'Receipt worker creation must persist and read back intent before create_thread'
  Assert-Contains $dispatchPolicy '(?is)(unknown|pending).{0,160}(worker|receipt-worker).{0,160}(creation|intent).{0,300}(must not|never).{0,180}(retry|create another)' `
    'Uncertain receipt worker creation must not produce duplicate tasks'
  Assert-Contains $dispatchPolicy '(?is)(must not|never).{0,220}(controller task|project entry|entry task).{0,220}heartbeat|heartbeat.{0,220}(must not|never).{0,220}(controller task|project entry|entry task)' `
    'The heartbeat must target only the dedicated worker, never controller or project-entry tasks'
  Assert-Contains $dispatchPolicy '(?is)(legacy|old).{0,200}(cron|scheduled poller|wake-run|poller).{0,500}(convert|migrate)' `
    'Legacy cron wake runs must be converted and archived instead of retained as active task clutter'
  if ($dispatchPolicy -match '(?is)(may|can|should|must) create (?:one )?standalone scheduled poller') {
    throw 'Active event-return policy must not create a standalone recurring cron task'
  }
  Assert-Contains $dispatchPolicy '(?is)((trusted|installed).{0,200}Skill.{0,200}dispatch-return-runtime|exact installed trusted runtime)' `
    'Event commands must use the installed Skill runtime, not a controller-writable copy'
  Assert-Contains $dispatchPolicy '(?is)(must not|never|do not).{0,300}writable_roots.{0,300}skill-state/onboard-code-projects' `
    'The shared dispatch registry must not become writable to every workspace'
  Assert-Contains $dispatchPolicy '(?is)request-dispatch-cancel.{0,200}cancelRequestedAt.{0,300}(must not|never).{0,160}(claim|report).{0,100}stopped.{0,300}(reject|dismiss).{0,160}(exact|corresponding).{0,160}(approval|permission)' `
    'Cancellation must be truthful while a native runtime approval remains unresolved'
  Assert-Contains $dispatchPolicy '(?is)controller history.{0,200}(never|must not).{0,160}(credential|secret).{0,300}(opaque|reference).{0,160}project' `
    'Controller history must hold only opaque project-scoped authorization references'
  Assert-Contains $dispatchPolicy '(?is)three attempts.{0,300}initial.{0,160}(repair|same-scope repair).{0,160}(rebaseline|architecture rebaseline).{0,300}(fourth|further).{0,160}(reject|forbid|CONVERGENCE_FAILED)' `
    'The complete dispatch lifecycle must have one global three-attempt convergence budget'
  Assert-Contains $dispatchPolicy '(?is)completed.{0,300}(write lease|lease).{0,300}(acceptance|review).{0,300}retry-dispatch.{0,300}blocked.{0,100}completed' `
    'A failed acceptance or review must consume the shared retry budget after implementation completed'
  Assert-Contains $dispatchPolicy '(?is)(two recorded failures|after two).{0,300}completed.{0,300}convergence-failed.{0,300}(cannot|do not).{0,160}(close|release)' `
    'Final review failure must converge without releasing the write lease'
  Assert-Contains $dispatchPolicy '(?is)goal lineage.{0,500}(problem invariant|problemInvariantId).{0,300}(strategy family|strategyFamilyId).{0,400}(material precondition|materialPreconditionHash)' `
    'Dispatch policy must bind one canonical goal lineage to strategy and material evidence'
  Assert-Contains $dispatchPolicy '(?is)(only business strategy sequence|business strategy sequence is).{0,160}initial.{0,80}repair.{0,80}rebaseline' `
    'Dispatch policy must use the bounded initial, repair, and rebaseline sequence'
  Assert-Contains $dispatchPolicy '(?is)(accepted-success|accepted success).{0,300}(deterministic-failure|deterministic failure).{0,500}(experience|reuse)' `
    'Success and deterministic failure must become evidence-backed reusable experience'
  Assert-Contains $dispatchPolicy '(?is)(deterministic failure|deterministic-failure).{0,500}(same|identical).{0,300}(strategy family|strategyFamilyId).{0,300}(material precondition|materialPreconditionHash).{0,300}(reject|block)|(?:reject|block).{0,300}(same|identical).{0,300}(problem invariant|problemInvariantId).{0,300}(strategy family|strategyFamilyId).{0,300}(material precondition|materialPreconditionHash)' `
    'An identical deterministic strategy must be rejected'
  Assert-Contains $dispatchPolicy '(?is)(rename|renaming|paraphras).{0,300}(same problem|same mechanism).{0,300}(retain|reuse|does not create).{0,200}(problemInvariantId|strategyFamilyId)' `
    'Relabeling the same problem or mechanism must not evade experience matching'
  Assert-Contains $dispatchPolicy '(?is)(changed material hash|material retry).{0,300}(direct evidence|prove)' `
    'A claimed material change must carry direct evidence'
  Assert-Contains $dispatchPolicy '(?is)(HEAD-only|different branch|HEAD)' `
    'A material-change rule must address branch or HEAD-only churn'
  Assert-Contains $dispatchPolicy '(?is)self-asserted hash' `
    'A self-asserted hash must not reset deterministic-failure experience'
  Assert-Contains $dispatchPolicy '(?is)(sole|one).{0,100}transient retry.{0,300}reconcile-preflight-failure.{0,300}(same dispatch|same attempt).{0,500}(does not|without|consumes no).{0,220}(business|strategy).{0,120}attempt' `
    'Only one same-dispatch transient preflight replay may sit outside the business strategy budget'
  Assert-Contains $dispatchPolicy '(?is)readiness.{0,240}(one|single).{0,120}replan.{0,400}(second|final).{0,160}(fail|failure).{0,300}(stop|block|no further)' `
    'Readiness work must have one bounded replan rather than its own loop'
  Assert-Contains $dispatchPolicy '(?is)dependencies.{0,300}allowedTerminalStatuses' `
    'Dependencies must use the closed terminal-predicate schema'
  Assert-Contains $dispatchPolicy '(?is)(satisf|dispatch only).{0,300}(canonical CHAIN|dependency).{0,300}terminal|canonical CHAIN.{0,300}terminal.{0,300}(allow-list|listed|satisf)' `
    'Dependencies must be satisfied by an allowed canonical terminal state'
  Assert-Contains $dispatchPolicy '(?is)(unreadable|invalid).{0,200}(dependency state|canonical dependency).{0,200}dispatch-dependency-state-invalid.{0,200}(never|not).{0,100}(silent wait|pending)' `
    'Invalid dependency state must fail distinctly instead of waiting forever'
  Assert-Contains $dispatchPolicy '(?is)(runtime is pinned|pins? (?:the )?exact.{0,120}runtime|controllerRuntimeHash.{0,500}exact runtime hash)' `
    'Every dispatch must pin an exact controller runtime'
  Assert-Contains $dispatchPolicy '(?is)(never|must not|refus).{0,160}(upgrade|replace|change).{0,240}(active|pending)|(active|pending).{0,240}(never|must not|refus).{0,160}(upgrade|replace|change)' `
    'The pinned controller runtime must not change before quiescence'
  Assert-Contains $dispatchPolicy '(?is)before.{0,80}close-dispatch.{0,500}(GoalPut|goal outcome).{0,500}(accepted-success|cancelled)|(GoalPut|goal outcome).{0,500}(accepted-success|cancelled).{0,500}close-dispatch' `
    'Canonical goal outcome must be durable before dispatch close'
}

foreach ($goalAction in @('GoalGet','GoalPut','ExperienceRead')) { Assert-Contains $chainStore ([regex]::Escape($goalAction)) "Chain store must expose $goalAction" }
Assert-Contains $controlState "(?is)'enqueue-dispatch'\s*\{.{0,6000}Assert-GoalReservationBinding" `
  'Goal reservations must gate the real enqueue adapter path'
Assert-Contains $controlState "(?is)'retry-dispatch'\s*\{.{0,6000}Assert-GoalReservationBinding" `
  'Goal reservations must gate the real retry adapter path'
Assert-Contains $controlState '(?is)Assert-TaskDependencies.{0,1000}allowedTerminalStatuses' `
  'The dependency gate must evaluate allowed terminal statuses'
Assert-Contains $controlState "(?is)'enqueue-dispatch'\s*\{.{0,7000}Assert-TaskDependencies" `
  'Dependency predicates must gate the real enqueue adapter path'
Assert-Contains $controlState "(?is)'retry-dispatch'\s*\{.{0,7000}Assert-TaskDependencies" `
  'Dependency predicates must gate the real retry adapter path'
Assert-Contains $initializer 'controller-upgrade-active-work' `
  'Initializer must reject runtime upgrades while active or pending dispatches exist'

foreach ($runtimeAction in @(
  'read-wake-worker',
  'prepare-wake-worker',
  'record-wake-worker-client',
  'bind-wake-worker',
  'prepare-wake-automation',
  'bind-wake-automation',
  'clear-wake-worker'
  'terminal-envelope'
)) { Assert-Contains $dispatchRuntime ([regex]::Escape($runtimeAction)) "Dispatch runtime must expose $runtimeAction" }

foreach ($runtimeMarker in @('single sealed dispatch','taskSpecHash','delivery-unknown','monitoring-paused','confirm-dispatch-not-delivered')) {
  Assert-Contains $effectiveControllerPolicy ([regex]::Escape($runtimeMarker)) "The public runtime contract must define $runtimeMarker"
}

Assert-Contains $effectiveControllerPolicy '(?is)projectless.{0,160}(forbid|never|prohibit)|(?:forbid|never|prohibit).{0,160}projectless' `
  'Repository and review tasks must explicitly forbid projectless creation'
Assert-Contains $effectiveControllerPolicy 'set_thread_archived' 'Temporary review tasks must have an archive lifecycle'
Assert-Contains $effectiveControllerPolicy 'send_message_to_thread' 'Normal project dispatch must explicitly reuse entry tasks'
Assert-Contains $effectiveControllerPolicy '(?is)single-project.{0,300}(environment\.type=local|saved-project local)' `
  'Single-project review tasks must bind to the saved project local environment'
Assert-Contains $effectiveControllerPolicy '(?is)multi-project.{0,300}controller.{0,300}(environment\.type=local|saved-project local|exact controller project)' `
  'Multi-project review tasks must bind to the saved controller project local environment'
foreach ($controllerInput in @('controllerRoot', 'initializeController', 'createControllerTask', 'controllerReconciliation')) {
  Assert-Contains $skill "(?is)$controllerInput.{0,500}schemaVersion.{0,80}2|schemaVersion.{0,80}2.{0,500}$controllerInput" `
    "Controller input $controllerInput must opt into the schemaVersion 2 controller/projects envelope"
}
Assert-Contains $skill '(?is)no controller.{0,240}(v1|per-project)|without controller.{0,240}(v1|per-project)' `
  'No-controller calls must retain the v1 per-project result contract'
Assert-Contains $skill '(?is)(controller failure|controller unavailable|controller blocked).{0,300}(remains ready|must not block).{0,240}pendingControllerRegistration' `
  'Controller failure must not block a ready project and must leave pendingControllerRegistration'
Assert-Contains $skill '(?is)initializeController=false.{0,500}(detect|distinguish).{0,300}generated controller.{0,500}trusted.{0,160}adapter' `
  'initializeController=false must distinguish the generated controller from a legacy trusted adapter'
Assert-Contains $skill '(?is)trusted.{0,160}adapter.{0,700}registry path.{0,300}same-directory candidate.{0,300}(validation|validate).{0,240}apply.{0,240}expected hash.{0,240}stable identity.{0,240}read-after-write' `
  'Legacy trusted-controller candidate/apply/hash/readback behavior must remain supported'
Assert-Contains $skill '(?is)neither adapter.{0,300}state=blocked.{0,200}reasonCode=controller-capability-unavailable.{0,200}safeToRerun=false' `
  'Missing generated and legacy adapters must have one exact non-blocking controller result'
if ($skill -match '(?is)When `?initializeController=false`?,?\s*run only.{0,80}-Action Verify') {
  throw 'initializeController=false must not force a legacy trusted adapter through the generated-controller verifier'
}
Assert-Contains $skill '(?is)(unknown fields|closed object).{0,300}controllerReconciliation|controllerReconciliation.{0,300}(unknown fields|closed object)' `
  'Controller reconciliation must reject unknown fields'
Assert-Contains $skill '(?is)action.{0,160}(only|exactly|one of).{0,120}bind.{0,80}abandon.{0,120}clear-stale-controller.{0,120}replace-project-binding' `
  'Controller reconciliation action must be limited to the four documented recovery actions'
Assert-Contains $skill '(?is)(other|unknown|invalid) action.{0,240}(invalid|unchanged)|(?:invalid|unchanged).{0,240}(other|unknown|invalid) action' `
  'Other reconciliation actions must be invalid and leave state unchanged'
Assert-Contains $skill '(?is)(bind|abandon).{0,500}operationId.{0,100}(must match|matches).{0,100}(exact current|current exact)' `
  'Bind and abandon must require the exact current operationId'
Assert-Contains $skill '(?is)bind.{0,160}(require|required).{0,160}threadId|threadId.{0,160}(require|required).{0,160}bind' `
  'Controller reconciliation bind must require threadId'
Assert-Contains $skill '(?is)abandon.{0,160}(require|required).{0,160}acknowledgeDuplicateRisk.{0,100}=true|acknowledgeDuplicateRisk.{0,100}=true.{0,160}(require|required).{0,160}abandon' `
  'Controller reconciliation abandon must require acknowledgeDuplicateRisk=true'
Assert-Contains $skill '(?is)clear-stale-controller.{0,300}threadId.{0,180}acknowledgeStaleBinding=true.{0,500}clear-controller-task-state.{0,300}read back' `
  'Stale controller recovery must clear only the exact proven stale thread and verify readback'
Assert-Contains $skill '(?is)state=controller-conflict.{0,160}reasonCode=controller-binding-stale.{0,160}safeToRerun=false' `
  'A stale controller binding must return the exact conflict result before cleanup'
Assert-Contains $skill '(?is)replace-project-binding.{0,900}expectedEntryThreadId.{0,220}expectedCodexProjectId.{0,220}expectedHostId.{0,260}replacementEntryThreadId.{0,220}replacementCodexProjectId.{0,220}replacementHostId.{0,260}acknowledgeReplacement=true' `
  'Project binding recovery must carry the full expected and replacement identities'
Assert-Contains $skill '(?is)state=controller-conflict.{0,160}reasonCode=project-binding-conflict.{0,160}safeToRerun=false' `
  'Concurrent project identity drift must return an exact controller conflict result'
Assert-Contains $skill '(?is)controllerRoot.{0,160}(require|required)|(?:require|required).{0,160}controllerRoot' `
  'Controller reconciliation must require controllerRoot'
Assert-Contains $skill '(?is)(matching|matching pending|pending).{0,240}(intent|operationId)|(intent|operationId).{0,240}(matching|matching pending|pending)' `
  'Controller reconciliation must require a matching pending intent'
Assert-Contains $skill '(?is)createControllerTask.{0,300}controllerReconciliation|controllerReconciliation.{0,300}createControllerTask' `
  'Reconciliation and controller task creation must be mutually exclusive'
Assert-Contains $skill '(?is)revalidate.{0,600}read_thread.{0,600}(codexProjectId|projectId).{0,600}hostId.{0,600}(project root|root).{0,600}(non-archived|not archived)' `
  'Task reuse must bind all authoritative evidence in one revalidation rule'
Assert-Contains $skill '(?is)(saved Codex project|saved project).{0,240}environment\.type=local' `
  'Task reuse must require the exact saved project local environment'
foreach ($nonAuthority in @('title', 'clientThreadId')) {
  Assert-Contains $skill "(?is)$nonAuthority.{0,180}(not|never).{0,180}(identity|authoritative)|(not|never).{0,180}$nonAuthority.{0,180}(identity|authoritative)" `
    "$nonAuthority must explicitly be non-authoritative task identity"
}
Assert-Contains $skill '(?is)(durable intent|persist).{0,300}create_thread|create_thread.{0,300}(durable intent|persist)' `
  'Unknown controller creation must persist intent before create_thread'
Assert-Contains $skill '(?is)(persist|durable).{0,240}(read back|read-after-write).{0,240}create_thread' `
  'Controller intent must be persisted and read back before create_thread'
Assert-Contains $skill '(?is)(unresolved|pending) intent.{0,300}(never|must not).{0,160}(retry|create another task)|(?:never|must not).{0,160}(retry|create another task).{0,300}(unresolved|pending) intent' `
  'An unresolved controller intent must never auto-retry or create another task'
Assert-Contains $skill 'controller-thread-unknown' `
  'Unknown controller task creation must have a stable result code'
Assert-Contains $skill '(?is)bind.{0,240}abandon.{0,240}(nextAction|copy)|(?:nextAction|copy).{0,240}bind.{0,240}abandon' `
  'Unknown controller creation must return copyable bind and abandon recovery actions'
Assert-Contains $skill '(?is)(createControllerTask.{0,280}controllerReconciliation|controllerReconciliation.{0,280}createControllerTask).{0,280}(invalid|must not).{0,280}(state|intent)|(invalid|must not).{0,280}(state|intent).{0,280}(createControllerTask.{0,280}controllerReconciliation|controllerReconciliation.{0,280}createControllerTask)' `
  'Mutually exclusive reconciliation must be invalid and leave state and intent unchanged'
Assert-Contains $skill '(?is)(state.{0,120}reasonCode.{0,120}nextAction.{0,120}safeToRerun)' `
  'Every public result must include state, reasonCode, nextAction, and safeToRerun'
foreach ($field in @('schemaVersion','sourceKind','source','projectRoot','repositoryId','worktreeRoot','branch','head','dirty','codexProjectId','hostId','entryThreadId','clientThreadId','memoryProject','memoryRoot','indexCoverage','state','blockReason','verifiedAt')) {
  Assert-Contains $skill "(?is)exact v1.{0,1600}$([regex]::Escape($field))" "Exact v1 record must include $field"
}
foreach ($projectState in @('registered','ready','needs-clone-root','needs-project-add','thread-creation-unknown','index-unavailable','registration-conflict','blocked')) {
  Assert-Contains $skill "(?is)v1 project states.{0,700}$([regex]::Escape($projectState))" "Exact v1 states must include $projectState"
}
Assert-InOrder $skill @('security/input/dependency blocked ->', 'needs-clone-root ->', 'needs-project-add ->', 'thread-creation-unknown ->', 'index-unavailable ->', 'registration-conflict') `
  'Exact v1 primary-state precedence must be preserved'
Assert-Contains $skill '(?is)registered.{0,240}(controller read-after-write|read-after-write controller)' 'registered requires controller read-after-write'
Assert-Contains $skill '(?is)ready.{0,240}(task.{0,80}index|index.{0,80}task).{0,120}verified' 'ready requires verified task and index'
Assert-Contains $skill '(?is)batch.{0,240}(required outcomes|every required outcome)' 'Batch success requires every requested outcome'
Assert-Contains $skill '(?is)v2 project records.{0,300}(retain|same).{0,300}v1.{0,300}pendingControllerRegistration.{0,160}registrationReasonCode' `
  'v2 project records must retain v1 fields and add only pending controller fields'
foreach ($reasonCode in @('needs-project-add', 'index-unavailable', 'authorization-required', 'invalid-controller-input', 'controller-project-not-saved', 'controller-project-ambiguous', 'controller-binding-stale', 'project-binding-conflict', 'controller-task-creation-pending', 'controller-registration-pending', 'controller-root-overlap', 'controller-root-unsupported', 'controller-filesystem-conflict', 'controller-candidate-orphaned', 'controller-io-failure', 'controller-capability-unavailable')) {
  Assert-Contains $skill ([regex]::Escape($reasonCode)) "Stable reason code $reasonCode must remain documented"
}
Assert-Contains $skill '(?is)(do not|never|must not).{0,180}(controller-bound|controller task).{0,160}(recurring heartbeat|visible heartbeat|self-message)' `
  'The onboarding skill must forbid a recurring heartbeat in the controller task while permitting event receipts'
Assert-Contains $skill '(?is)(do not|never|must not|forbid).{0,160}worktree|worktree.{0,160}(do not|never|must not|forbid)' `
  'Repository and controller tasks must explicitly forbid worktree targets'
Assert-Contains $readme '(?is)controller.{0,400}(saved|Codex project|project-bound)' `
  'README must explain that controller work is bound to a saved Codex project'
Assert-Contains $readmeZh '(?is)(controllerRoot|needs-controller-project-add).{0,400}Codex' `
  'Chinese README must explain that controller work is bound to a saved Codex project'
Assert-Contains $agentManifest '(?is)controller|control center' `
  'Agent metadata must describe the controller-capable onboarding workflow'

foreach ($relativePath in @(
  '.github\workflows\windows-tests.yml',
  '.github\ISSUE_TEMPLATE\bug_report.yml',
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'SECURITY.md',
  'docs\release-checklist.md',
  'docs\forward-tests\controller-bootstrap.md'
)) { Assert-File $relativePath }

$workflowPath = Join-Path $skillRoot '.github\workflows\windows-tests.yml'
if (Test-Path -LiteralPath $workflowPath -PathType Leaf) {
  $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
  Assert-Contains $workflow 'windows-latest' 'CI must run on Windows'
  Assert-Contains $workflow 'actions/checkout@[0-9a-f]{40}' 'CI dependencies must use an immutable commit SHA'
  Assert-Contains $workflow '(?is)fetch-depth:\s*0.{0,160}persist-credentials:\s*false' 'The release privacy gate must receive full history without retaining push credentials'
  foreach ($command in @('preflight.ps1 -SelfTest', 'preflight.tests.ps1', 'index-mode.tests.ps1', 'source-input.tests.ps1', 'chain-store.tests.ps1', 'dispatch-return-runtime.tests.mjs', 'init-controller.tests.ps1', 'control-state.tests.ps1', 'task-set-reset.tests.ps1', 'skill-size.tests.ps1', 'skill-contract.tests.ps1', 'preflight.ps1 -ReleaseGate')) {
    Assert-Contains $workflow ([regex]::Escape($command)) "CI must run $command"
  }
  if ($workflow -match '(?i)publish|quick_validate') { throw 'CI must not publish or assume the maintainer-only quick validator' }
}
Assert-Contains $preflight '(?is)RequireNode.{0,1200}(Key=.node.|Command=.node.).{0,1200}missingRequired' `
  'Preflight must verify Node.js only when event return is requested'
Assert-Contains $preflight '(?is)--version.{0,1200}18\.0\.0.{0,1200}node>=18\.0\.0' `
  'Preflight must execute Node.js and enforce the documented minimum version'

foreach ($document in @($readme, $readmeZh)) {
  if (($document -split "`r?`n").Count -gt 260) { throw 'Public README must remain a concise project overview (260 lines maximum)' }
  if ($document -match '(?m)^## (?:Bounded convergence and reusable experience|Four-quadrant request intake|Long-lived controller memory|Results and recovery|Verification|\u6709\u754c\u6536\u655b\u4e0e\u7ecf\u9a8c\u590d\u7528|\u56db\u8c61\u9650\u8bf7\u6c42\u534f\u8bae|\u957f\u671f\u4e2d\u63a7\u8bb0\u5fc6|\u7ed3\u679c\u4e0e\u6062\u590d|\u9a8c\u8bc1)\s*$') {
    throw 'Internal controller and maintainer details must not return to the public README'
  }
  Assert-Contains $document '(?is)controller-thread-unknown.{0,500}nextAction|nextAction.{0,500}controller-thread-unknown' `
    'Both READMEs must give concise controller-thread-unknown recovery guidance'
  Assert-Contains $document '(?is)workflow isolation' 'Both READMEs must distinguish workflow isolation from sandboxing'
  Assert-Contains $document 'references/controller-runtime\.md' 'Both READMEs must link the advanced controller runtime reference'
  Assert-Contains $document 'SECURITY\.md' 'Both READMEs must link the security boundary'
  Assert-Contains $document 'release-checklist\.md' 'Both READMEs must link the release checklist'
  Assert-Contains $document 'CONTRIBUTING\.md' 'Both READMEs must link contribution guidance'
  Assert-Contains $document '(?is)codebase-memory.{0,160}(required|\u5fc5\u9700)|(?:required|\u5fc5\u9700).{0,160}codebase-memory' `
    'Both READMEs must state that codebase-memory is required for onboarding'
  if ($document -match '(?i)safe cleanup guidance|\u5b89\u5168\u6e05\u7406\u65b9\u5f0f') {
    throw 'README must not claim that SECURITY.md contains cleanup instructions it does not provide'
  }
  Assert-Contains $document '(?is)(durable result return|\u8010\u4e45\u7ed3\u679c\u56de\u4f20).{0,300}(Hook).{0,180}(Node.js|Node).{0,500}(automatic wake|\u81ea\u52a8\u5524\u9192).{0,300}(additional|extra|\u989d\u5916|\u8fd8\u9700\u8981)' `
    'Both READMEs must distinguish durable receipts from the extra automatic-wake capabilities'
  foreach ($internalMarker in @(
    '\.codex-controller\.json',
    'state/(?:active|archive|goals|experience-index|dispatch-receipts)',
    '\bCAS\b',
    '\bExportDispatch\b',
    '\btaskSpecHash\b',
    '\bCONVERGENCE_FAILED\b',
    'controller-epoch-rotation-unsupported',
    '\bgoal lineage\b',
    '-ConfirmTerminal',
    'chain-store\.ps1\s+-Action',
    'mapped N/M'
  )) {
    if ($document -match $internalMarker) { throw "Public README contains internal implementation marker: $internalMarker" }
  }
  foreach ($resetInternalMarker in @('taskSetReset', 'replacementSetHash', 'split[- ]brain', 'prepare-reset', 'commit-reset')) {
    if ($document -match "(?i)$resetInternalMarker") { throw "Public README contains reset state-machine mechanics: $resetInternalMarker" }
  }
}
Assert-Contains $contributing 'docs/release-checklist\.md#deterministic-gate' `
  'Contribution guidance must link the maintained deterministic test suite'
if ($contributing -match 'README\.md#verification') { throw 'Contribution guidance must not link the removed README verification section' }
Assert-Contains $skill '(?is)set-task-intent.{0,1200}(mutation protocol|final Read).{0,500}create_thread' `
  'Controller task creation must name the durable state adapter sequence before create_thread'
Assert-Contains $skill '(?is)register-project.{0,500}(read back|readback|read-after-write)' `
  'Project registration must use the adapter and verify a readback'
Assert-Contains $skill '(?is)runtime.{0,200}(approval|permission).{0,500}(exact project|corresponding project)' `
  'Runtime approval must remain attached to the exact project call'
foreach ($dispatchPolicy in @($effectiveControllerPolicy)) {
  Assert-Contains $dispatchPolicy '(?is)approval-wait.{0,300}(non-terminal|same attempt).{0,300}(does not|must not).{0,160}(consume|increment).{0,120}(attempt|generation|rework)' `
    'Runtime approval wait must remain the same non-terminal attempt'
  Assert-Contains $dispatchPolicy '(?is)completed.{0,120}blocked.{0,120}auth-required.{0,120}cancelled.{0,120}convergence-failed' `
    'Dispatch outcome vocabulary must be closed and explicit'
}
Assert-Contains $controllerPolicy '(?is)(FIFO|first-in.first-out).{0,500}(same project|per-project).{0,500}(independent project|other project).{0,300}(continue|concurrent|parallel)' `
  'Generated controllers must queue same-project work while independent projects continue'
foreach ($routingPolicy in @($effectiveControllerPolicy)) {
  Assert-Contains $routingPolicy '(?is)economy.{0,700}balanced.{0,700}frontier' 'Model routing must define three evidence-based classes'
  Assert-Contains $routingPolicy '(?is)((never|not).{0,180}(because|merely).{0,120}(waiting|waited|wait)|(waiting|waited|wait).{0,180}(never|not).{0,120}(escalat|upgrade))' `
    'Model routing must reject wait-based escalation'
}
Assert-File 'scripts\source-input.ps1'
Assert-File 'scripts\source-input.tests.ps1'
Assert-Contains $skill '(?is)source-input\.ps1.{0,160}SourcesJsonBase64.{0,500}(unknown fields|open fields).{0,500}(duplicate|duplicates).{0,300}(conflict|conflicting)' `
  'Source trust-boundary parsing must be executable, closed, and conflict-aware'
Assert-Contains $skill '(?is)controller-upgrade-authorization-required.{0,500}upgradeController=true.{0,500}Plan.{0,160}write-free.{0,500}(rollback|rolls back).{0,500}(unknown|edited).{0,200}(conflict|remain)' `
  'Generated v1 controller migration must be separately authorized, planned, rollback-protected, and exact-signature only'
$shortDescriptionMatch = [regex]::Match($agentManifest, '(?m)^\s*short_description:\s*"(?<value>[^"]+)"\s*$')
if (-not $shortDescriptionMatch.Success -or $shortDescriptionMatch.Groups['value'].Value.Length -lt 25 -or $shortDescriptionMatch.Groups['value'].Value.Length -gt 64) {
  throw 'agents/openai.yaml short_description must be 25-64 characters'
}
foreach ($policy in @($effectiveControllerPolicy)) {
  Assert-Contains $policy '(?is)approval_policy.{0,80}on-request.{0,160}sandbox_mode.{0,80}workspace-write.{0,160}approvals_reviewer.{0,80}auto_review' `
    'Controller policy must define the lower-friction native permission posture without disabling the sandbox'
  Assert-Contains $policy '(?is)unresolved runtime approval.{0,500}send_message_to_thread.{0,300}(must not|never).{0,240}(follow-up|retry|new turn|new invocation)' `
    'An unresolved runtime approval must not create another target continuation or tool boundary'
  Assert-Contains $policy '(?is)auto.review.{0,300}(does not|cannot|never).{0,160}(expand|widen).{0,120}sandbox.{0,240}(does not|cannot|never).{0,160}(transfer|approve).{0,120}(another|other|project)' `
    'Native auto-review must not be described as wider sandbox access or cross-task approval'
  Assert-Contains $policy '(?is)(denied|denial).{0,300}(must not|never).{0,200}(alternate|equivalent).{0,160}(invocation|command|tool)' `
    'A denied native review must not be bypassed through an equivalent invocation'
  Assert-Contains $policy '(?is)(same capability|same external capability).{0,300}(same dispatch|same scope).{0,300}replan.{0,240}(approval loop|repeated approval)' `
    'Repeated approval pressure must trigger replanning instead of an approval loop'
  Assert-Contains $policy '(?is)(must not|never).{0,160}(bundle|batch).{0,160}(unrelated|high-risk)' `
    'Permission-pressure reduction must not hide unrelated or high-risk operations in one batch'
  Assert-Contains $policy '(?is)recurring low-risk.{0,500}writable_roots.{0,300}prefix rule.{0,300}(explicit user authorization|user explicitly authorizes)' `
    'A proven recurring low-risk boundary must use only an explicitly authorized narrow native rule'
  Assert-Contains $policy '(?is)(must not|never).{0,160}danger-full-access.{0,240}approval_policy.{0,80}never.{0,240}(prompt|approval).{0,120}(volume|frequency|workaround)' `
    'Prompt-volume reduction must never disable the sandbox or approval boundary'
}
Assert-Contains $skill '(?is)state.?=.?controller-thread-unknown.{0,200}reasonCode.?=.?controller-task-creation-pending.{0,200}safeToRerun.?=.?false' `
  'Unknown controller intent must return the exact state/reason/safe-to-rerun triple'
Assert-InOrder $skill @('blocked ->', 'controller-conflict ->', 'controller-thread-unknown ->', 'needs-controller-project-add ->', 'controller-initialized ->', 'controller-ready') `
  'Controller state precedence must keep unknown intent ahead of missing saved project'

foreach ($operationContract in @(
  'set-task-intent: operationId, codexProjectId, hostId, projectRoot, startedAt',
  'record-client-thread: operationId, clientThreadId',
  'bind-controller: operationId, threadId, codexProjectId, hostId, projectRoot',
  'register-project: entryThreadId, codexProjectId, hostId, projectRoot',
  'enqueue-dispatch: projectRoot, chainId, projectTaskId, dispatchId, generation, rework, accessMode, modelClass, taskSpec, enqueuedAt',
  'start-next-dispatch: projectRoot, dispatchId, startedAt, leaseId',
  'advance-dispatch: projectRoot, dispatchId, phase',
  'confirm-dispatch-not-delivered: projectRoot, dispatchId, evidenceHash, confirmedAt',
  'reconcile-preflight-failure: projectRoot, dispatchId, failureClass, evidenceHash, confirmedAt, observedBaseline',
  'record-dispatch-outcome: projectRoot, dispatchId, taskSpecHash, resultState, failureClass, evidenceHash, finishedAt',
  'request-dispatch-cancel: projectRoot, dispatchId, requestedAt',
  'resume-dispatch-authorization: projectRoot, dispatchId, authorizationRef, resumedAt',
  'retry-dispatch: projectRoot, expectedDispatchId, dispatchId, generation, rework, modelClass, failureClass, failureFingerprint, strategy, taskSpec, enqueuedAt',
  'close-dispatch: projectRoot, dispatchId, closedAt',
  'replace-project-binding: confirmReconciliation=true, projectRoot, expectedEntryThreadId, expectedCodexProjectId, expectedHostId, replacementEntryThreadId, replacementCodexProjectId, replacementHostId',
  'clear-controller-task-state: confirmReconciliation=true plus exactly one of operationId or threadId'
)) { Assert-Contains $skill ([regex]::Escape($operationContract)) "Missing exact adapter payload contract: $operationContract" }
Assert-Contains $dispatchRuntime 'requireId\(value\.dispatchId, "dispatch-id"\)' `
  'Runtime dispatch IDs must use the documented semantic ID contract rather than a hash-only contract'
Assert-Contains $dispatchRuntime '(?is)ENVELOPE_FIELDS.{0,300}"resultState".{0,120}"failureClass"' `
  'Runtime terminal envelopes must include failureClass'
Assert-Contains $dispatchRuntime '(?is)function receiptIdentity\(envelope, evidenceHash, turnId\).{0,500}envelope\.failureClass.{0,200}evidenceHash.{0,120}turnId' `
  'Runtime receipt identity must bind failure class, evidence hash, and turn ID'
Assert-Contains $effectiveControllerPolicy '(?is)worker-safe.{0,240}(fixed default registry|default registry).{0,240}(no explicit|must not accept|forbid).{0,80}--state-path' `
  'Worker-safe receipt calls must use the fixed default registry and reject an explicit state path'
Assert-Contains $skill '(?is)Read.{0,180}PrepareCandidate.{0,180}Operation.{0,180}PayloadJson.{0,180}ExpectedHash.{0,220}ApplyCandidate.{0,220}CandidatePath.{0,120}CandidateHash.{0,120}ExpectedHash.{0,220}Read' `
  'Every controller mutation must use the exact adapter CAS sequence'
Assert-Contains $skill '(?is)record-client-thread.{0,240}(null.{0,80}value|same value)' `
  'Client-thread diagnostics must be monotonic'
Assert-Contains $skill '(?is)RemoveCandidate.{0,160}ConfirmCleanup' `
  'Candidate cleanup must use the confirmed adapter action'
Assert-Contains $skill '(?is)(never|must not).{0,160}(guess|edit).{0,160}manifest' `
  'The Skill must forbid guessed or direct manifest changes'

foreach ($boundary in @('preflight', 'mapped N/M', 'task verified', 'index running', 'index ready', 'controller pending', 'controller ready')) {
  Assert-Contains $skill ([regex]::Escape($boundary)) "Missing progress boundary: $boundary"
}
Assert-Contains $skill '(?is)only when (?:it|the state|state) changes' 'Progress commentary must be change-only'
if ($skill -match '(?is)projectless.{0,240}unless separately') { throw 'Projectless prohibition must not have an authorization escape hatch' }

foreach ($document in @($readme, $readmeZh)) {
  Assert-Contains $document '(?is)sources\[\]\.source.{0,500}sources\[\]\.cloneRoot.{0,500}sources\[\]\.(branch|ref).{0,500}sources\[\]\.fullLfsCheckout' `
    'Both READMEs must document the closed per-source Git schema'
  Assert-Contains $document '\$skill-installer' 'Both READMEs must use skill-installer as the primary installation journey'
  Assert-Contains $document 'https://github\.com/libaie/onboard-code-projects' 'Both READMEs must name the public repository'
  Assert-Contains $document '(?is)Git URL.{0,1200}cloneRoot.{0,400}(ref|branch).{0,400}fullLfsCheckout' 'Both READMEs must include a standalone Git URL journey'
  Assert-Contains $document '(?is)read-only.{0,600}preflight' 'Both READMEs must include read-only diagnostics'
  Assert-Contains $document '(?is)local.{0,600}HTTPS.{0,600}SSH.{0,600}LFS' 'Both READMEs must map dependencies to example types'
  foreach ($diagnostic in @(
    'preflight.ps1',
    'preflight.ps1 -RequireGit',
    'preflight.ps1 -RequireGit -RequireSsh',
    '-RequireLfs',
    'preflight.ps1 -RequireNode'
  )) { Assert-Contains $document ([regex]::Escape($diagnostic)) "Both READMEs must document diagnostic command $diagnostic" }
  Assert-Contains $document '(?is)fast.{0,160}moderate.{0,160}full' 'Both READMEs must explain the first-run index choices once'
  Assert-Contains $document '(?is)needs-project-add.{0,500}(save|\u4fdd\u5b58).{0,500}(same request|\u76f8\u540c\u8bf7\u6c42)' `
    'Both READMEs must explain the clone-first save-and-rerun journey'
}
Assert-Contains $skill '(?is)nextAction.{0,700}sources.{0,500}(exact local|local exact).{0,500}(credential-free|redacted)' `
  'Unknown-task recovery must carry complete safe replayable sources'
Assert-Contains $skill '(?is)nextAction.{0,1400}Git.{0,300}cloneRoot.{0,300}(branch|ref).{0,300}fullLfsCheckout' `
  'Git recovery must replay cloneRoot, ref identity, and LFS choice'
Assert-Contains $skill '(?is)(bind and abandon|both recovery).{0,400}(same|identical).{0,300}(replay-safe|original request)' `
  'Bind and abandon must carry the same replay-safe original request inputs'
Assert-Contains $skill '(?is)target directory.{0,260}(already exists|exists).{0,500}actual root.{0,300}(credential-free|redacted).{0,200}origin.{0,300}(branch|ref).{0,200}(match|drift)' `
  'Existing clones may be reused only after exact root, origin, and ref validation'
Assert-Contains $skill '(?is)(otherwise|mismatch).{0,160}blocked.{0,200}(not|never).{0,120}(overwrite|re-clone|clone again)' `
  'Mismatched existing clone targets must block without overwrite or reclone'

$forwardTest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'docs\forward-tests\controller-bootstrap.md')
Assert-InOrder $forwardTest @(
  'Shared known',
  'User-known / agent-unknown',
  'Agent-known / user-unknown',
  'Shared unknown'
) 'Forward testing must pressure every four-quadrant intake path'
Assert-Contains $forwardTest '(?is)at most three.{0,300}(one round|single round).{0,500}(assumption|assumptions).{0,300}(exploration version|exploratory version)' `
  'Forward testing must distinguish material questions from safe assumptions'
Assert-Contains $forwardTest '(?is)(one|single) variable.{0,300}success signal.{0,240}failure signal.{0,240}data to collect' `
  'Forward testing must verify a falsifiable minimum experiment'
Assert-Contains $forwardTest '(?is)both copyable bind and abandon.{0,500}(same|complete).{0,160}sources' `
  'Forward test must require same sources in both copyable recovery inputs'
Assert-Contains $forwardTest '(?is)sources.{0,300}(exact local|credential-free|redacted)' `
  'Forward test must enforce safe replayable source values'
Assert-Contains $forwardTest '(?is)legacy.{0,500}(does not run|must not run).{0,300}bundled initializer|(does not run|must not run).{0,300}bundled initializer.{0,500}legacy' `
  'Forward test must cover legacy trusted-adapter non-rewrite behavior'
Assert-Contains $forwardTest '(?is)clear-stale-controller.{0,500}replace-project-binding' `
  'Forward test must cover both stale controller and stale project binding recovery'
Assert-Contains $forwardTest '(?is)routine workspace.{0,300}(without|no).{0,120}(prompt|manual approval).{0,500}eligible.{0,160}auto.review' `
  'Forward test must exercise the native low-friction permission posture'
Assert-Contains $forwardTest '(?is)unresolved manual runtime approval.{0,500}send_message_to_thread.{0,300}(no|zero|must not).{0,240}(follow-up|retry|new invocation)' `
  'Forward test must prove an unresolved approval creates no continuation churn'
Assert-Contains $forwardTest '(?is)(existing task|existing chat).{0,300}(override|permission mode).{0,300}(one-time|once|one in-task)' `
  'Forward test must cover existing task-level permission overrides'
Assert-Contains $forwardTest '(?is)(high-risk|Computer Use).{0,300}(manual|user).{0,120}(approval|confirmation)' `
  'Forward test must retain manual approval for unsupported or high-risk boundaries'
Assert-Contains $forwardTest '(?is)recurring low-risk.{0,500}writable_roots.{0,300}prefix rule.{0,300}(broad|interpreter|network)' `
  'Forward test must cover narrow native rules without broad command trust'
Assert-Contains $forwardTest '(?is)single sealed dispatch.{0,400}taskSpecHash.{0,400}delivery-unknown.{0,500}authoritative non-delivery.{0,300}once' `
  'Forward test must exercise the sealed at-most-once dispatch protocol'
Assert-Contains $forwardTest '(?is)three attempts.{0,300}repair.{0,200}rebaseline.{0,300}(fourth|further).{0,160}(reject|CONVERGENCE_FAILED)' `
  'Forward test must prove the global convergence limit'
Assert-Contains $forwardTest '(?is)cancelRequestedAt.{0,300}(must not|never).{0,160}(claim|report).{0,100}stopped.{0,400}(ten|10).{0,100}(one-minute|one minute).{0,200}monitoring-paused' `
  'Forward test must prove truthful cancellation and bounded foreground monitoring'
Assert-Contains $forwardTest '(?is)controller history.{0,200}(never|must not).{0,160}(credential|secret)' `
  'Forward test must reject credential-bearing controller history'
Assert-Contains $forwardTest '(?is)501.{0,500}(200 lines|200 \u884c).{0,240}(25 KiB).{0,500}500.{0,500}(Get|archived CHAIN)' `
  'Forward test must pressure bounded startup memory and exact lookup beyond the terminal index window'
Assert-Contains $forwardTest '(?is)shadow.{0,500}source.hash.{0,500}(legacy bytes|backup).{0,500}(idle|\u7a7a\u95f2)' `
  'Forward test must cover source-CAS shadow migration and idle cutover'

$releaseChecklist = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'docs\release-checklist.md')
foreach ($field in @('Scenario', 'Date', 'TTHW', 'Manual interventions', 'Tasks created', 'Wrong-project incidents', 'Duplicate-task incidents', 'Reason codes', 'Outcome')) {
  Assert-Contains $releaseChecklist ([regex]::Escape($field)) "Dogfood template must include $field"
}
foreach ($releaseField in @('Candidate commit', 'Codex Desktop version/build', 'codebase-memory version/commit', 'Final immutable tag')) {
  Assert-Contains $releaseChecklist ([regex]::Escape($releaseField)) "Release evidence must include an unfilled $releaseField field"
}
Assert-Contains $releaseChecklist '(?is)3.{0,40}5.{0,300}dogfood|dogfood.{0,300}3.{0,40}5' 'Release gate must require 3-5 unfilled dogfood records'
Assert-Contains $releaseChecklist '(?is)immutable pre-controller.{0,500}(v1|schema)' 'Release gate must rehearse upgrade from an immutable pre-controller revision'
Assert-Contains $releaseChecklist '(?is)trusted-controller.{0,500}(generic controller|migrat)' 'Legacy trusted-controller input must not auto-migrate'
Assert-Contains $releaseChecklist '(?is)rollback rehearsal' 'Release gate must include rollback rehearsal'
Assert-Contains $releaseChecklist '(?is)approval_policy.{0,80}on-request.{0,160}sandbox_mode.{0,80}workspace-write.{0,160}approvals_reviewer.{0,80}auto_review' `
  'Release gate must verify the recommended native permission posture'
Assert-Contains $releaseChecklist '(?is)worker-safe.{0,240}(fixed default registry|default registry).{0,240}(no explicit|must not accept|forbid).{0,80}--state-path' `
  'Release gate must prove worker-safe calls cannot override the fixed default registry'
Assert-Contains $releaseChecklist '(?is)unresolved runtime approval.{0,500}(no|zero|must not).{0,240}(follow-up|retry|new invocation)' `
  'Release gate must verify approval churn suppression'
Assert-Contains $releaseChecklist '(?is)writable_roots.{0,300}prefix rule.{0,300}(explicit|authorized).{0,300}(danger-full-access|approval_policy)' `
  'Release gate must verify narrow native rules and reject unsafe prompt-volume workarounds'
Assert-Contains $releaseChecklist '(?is)four-quadrant.{0,300}(at most|maximum) three.{0,300}(one|single) variable.{0,300}(success|failure)' `
  'Release gate must exercise the complete four-quadrant intake protocol'
Assert-Contains $releaseChecklist '(?is)single sealed dispatch.{0,400}taskSpecHash.{0,400}delivery-unknown.{0,500}three attempts.{0,300}CONVERGENCE_FAILED' `
  'Release gate must cover sealed delivery and the global convergence budget'
Assert-Contains $releaseChecklist '(?is)cancelRequestedAt.{0,300}(must not|never).{0,160}(claim|report).{0,100}stopped.{0,400}monitoring-paused' `
  'Release gate must verify truthful cancellation and foreground-only monitoring'
Assert-Contains $releaseChecklist '(?is)501.{0,500}(200 lines|200 \u884c).{0,240}25 KiB.{0,500}500.{0,500}(Get|archived CHAIN)' `
  'Release gate must verify bounded memory and exact archived lookup at scale'
Assert-Contains $releaseChecklist '(?is)shadow migration.{0,700}source hash.{0,500}(legacy bytes|backup).{0,500}(idle|\u7a7a\u95f2)' `
  'Release gate must rehearse source-CAS migration and idle cutover'

foreach ($document in @($readme, $readmeZh)) {
  Assert-Contains $document '(?is)approval_policy.{0,80}on-request.{0,160}sandbox_mode.{0,80}workspace-write.{0,160}approvals_reviewer.{0,80}auto_review' `
    'Both READMEs must document the recommended native permission posture'
  Assert-Contains $document '(?is)(existing task|existing chat|\u5df2\u6709\u4efb\u52a1|\u5df2\u6709\u4f1a\u8bdd).{0,400}(override|\u8986\u76d6|permission mode|\u6743\u9650\u6a21\u5f0f).{0,300}(one-time|once|\u4e00\u6b21)' `
    'Both READMEs must explain the one-time handling for task-level permission overrides'
}

if (Test-Path -LiteralPath $workflowPath -PathType Leaf) {
  $exitChecks = [regex]::Matches($workflow, '\$LASTEXITCODE\s+-ne\s+0').Count
  if ($exitChecks -lt 5) { throw 'CI must check LASTEXITCODE immediately after every deterministic command' }
}

foreach ($text in @($skill, $readme, $readmeZh, $agentManifest)) {
  if ($text -match '(?i)(?:[A-Z]:[\\/]Users[\\/]|/Users/|/home/)') {
    throw 'Public package text must not contain a private local path or controller name'
  }
  if ($text -match '(?i)no controller adapter (?:is )?bundled') {
    throw 'Public package text still claims that no controller adapter is bundled'
  }
}
$genericTemplatePathCheck = [regex]::Escape('$text -match ''(?i)(?:[A-Z]:[\\/]|/Users/|/home/)''')
Assert-Contains $initializer $genericTemplatePathCheck `
  'Initializer template hygiene must use only generic local-path detection'
$privatePathPattern = '(?i)(?:[A-Z]:[\\/]Users[\\/][A-Za-z0-9._-]+|[A-Z]:[\\/][^\\/\s]+_projects[\\/]|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/)'
$maintainerArtifactPattern = '(?i)\b[a-z0-9._-]+-(?:main|master|develop)-[a-z0-9._-]*review[a-z0-9._-]*-\d{8,}(?:-\d+)?\.md\b'
foreach ($file in @(Get-ChildItem -Recurse -File -LiteralPath $skillRoot | Where-Object {
  $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Extension -in @('.md','.ps1','.yml','.yaml','.json')
})) {
  $publicText = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
  if ($publicText -match $privatePathPattern) { throw "Public package file contains a private local path: $($file.FullName)" }
  if ($publicText -match $maintainerArtifactPattern) { throw "Public package file contains a named maintainer-local artifact: $($file.FullName)" }
  if ($file.Extension -ceq '.ps1' -and $publicText -match '[^\x00-\x7f]') { throw "Public PowerShell must not contain private non-ASCII literals: $($file.FullName)" }
}

if ($readme -match 'currently written in Chinese') {
  throw 'English README contains a stale language limitation'
}
if ($readme -match 'Windows is the only release-tested platform') {
  throw 'README must not claim release testing before the disposable Codex Desktop gate passes'
}
if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'LICENSE') -PathType Leaf)) {
  throw 'Open-source package must include a LICENSE file'
}

Write-Output 'PASS skill-contract'
exit 0
