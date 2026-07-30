[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $MilestoneId,
    [Parameter(Mandatory)][string] $SelectionPath,
    [Parameter(Mandatory)][string] $ScopeTransitionAuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ScopeTransitionKey,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$planPath = Join-Path $runRoot 'plan.json'
$runPath = Join-Path $runRoot 'run.json'
$eventsPath = Join-Path $runRoot 'events.jsonl'
foreach ($path in @($planPath, $runPath, $eventsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Scoped milestone transition requires an existing durable run.'
    }
}
$planRaw = Get-Content -LiteralPath $planPath -Raw
$plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath $runPath -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$events = @(Read-OrchestrationJournal $eventsPath)
if ($null -eq $plan.PSObject.Properties['durable_review_profile'] -or
    (Get-TextSha256 $planRaw) -ne [string]$run.plan_hash -or
    [string]$plan.run_id -ne [string]$run.run_id -or $events.Count -lt 1) {
    throw 'Scoped milestone transition run identity is inconsistent.'
}
if ($ScopeTransitionKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$' -or
    $ActivationKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw (
        'Scoped milestone transition requires stable, exact user: or ' +
        'controller: keys.'
    )
}
$chain = Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
if ([string]$chain.next_milestone_id -ne $MilestoneId -or
    [string]::IsNullOrWhiteSpace(
        [string]$chain.activation_receipt_hash
    )) {
    throw 'Scoped milestone transition must target the next declared milestone.'
}
try {
    $null = Read-DurableReviewMilestoneAcceptance `
        -RunDirectory $runRoot -MilestoneChain $chain
    throw (
        'Scoped milestone transition is unavailable after final main ' +
        'acceptance.'
    )
} catch {
    if ($_.Exception.Message -notlike '*lacks main-owner acceptance.') {
        throw
    }
}
$milestoneIds = @(
    $plan.durable_review_profile.milestone_ids |
        ForEach-Object { [string]$_ }
)
$milestoneIndex = [Array]::IndexOf($milestoneIds, $MilestoneId)
if ($milestoneIndex -lt 1) {
    throw 'Scoped milestone transition cannot replace the baseline milestone.'
}

function Resolve-RunFile {
    param([string] $Path, [string] $Label)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label must be an existing file inside the run."
    }
    return $fullPath
}

$selectionFullPath = Resolve-RunFile (
    $SelectionPath
) 'Scoped milestone transition selection'
$authorizationFullPath = Resolve-RunFile (
    $ScopeTransitionAuthorizationMaterialPath
) 'Scoped milestone transition authorization'
if ([string]::IsNullOrWhiteSpace(
    (Get-Content -LiteralPath $authorizationFullPath -Raw)
)) {
    throw 'Scoped milestone transition authorization cannot be empty.'
}
$requiredSourceIds = @(
    @($plan.durable_review_profile.domain_node_ids) +
    @($plan.durable_review_profile.dissent_node_ids) |
        ForEach-Object { [string]$_ }
)
$selections = @(
    Get-Content -LiteralPath $selectionFullPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
)
if ($selections.Count -ne $requiredSourceIds.Count) {
    throw 'Milestone selection must bind every required source exactly once.'
}
$bindings = [Collections.Generic.List[object]]::new()
foreach ($sourceNodeId in $requiredSourceIds) {
    $matches = @($selections | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
    })
    if ($matches.Count -ne 1 -or
        $null -eq $matches[0].PSObject.Properties[
            'disposition_receipt_path'
        ]) {
        throw "Milestone selection source '$sourceNodeId' is missing or repeated."
    }
    $binding = Get-DurableReviewDispositionBinding `
        -RunDirectory $runRoot -Plan $plan `
        -SourceNodeId $sourceNodeId `
        -DispositionRelativePath (
            [string]$matches[0].disposition_receipt_path
        ) -ExpectedMilestoneId $MilestoneId `
        -RequireResultMilestoneBinding
    if ($null -ne $matches[0].PSObject.Properties[
        'result_receipt_path'
    ] -and [string]$matches[0].result_receipt_path -ne
        [string]$binding.result_receipt_path) {
        throw "Milestone selection source '$sourceNodeId' changed its result path."
    }
    $bindings.Add($binding)
}
$checkpointPaths = @($bindings |
    Select-Object -ExpandProperty checkpoint_material_path -Unique)
$checkpointHashes = @($bindings |
    Select-Object -ExpandProperty checkpoint_material_hash -Unique)
if ($checkpointPaths.Count -ne 1 -or $checkpointHashes.Count -ne 1) {
    throw 'All milestone sources must bind the same checkpoint material.'
}
$carryForward = Get-DurableReviewScopedCarryForward `
    -RunDirectory $runRoot `
    -PreviousSourceBindings @($chain.active_source_bindings) `
    -NextSourceBindings @($bindings)
if ([int]$carryForward.previous_open_count -lt 1) {
    throw (
        'Scoped milestone transition requires at least one prior open P0/P1 ' +
        'occurrence; use final main acceptance otherwise.'
    )
}
if ([int]$carryForward.remaining_open_count -lt 1) {
    throw (
        'Scoped milestone transition cannot bypass final main acceptance ' +
        'after every prior P0/P1 occurrence is resolved.'
    )
}

$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = (
    "durable-review-milestone.$MilestoneId." +
    'scope-transition-authorization.json'
)
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'Scoped milestone transition authorization already exists.'
}
if (@($events | Where-Object {
    [string]$_.event -eq 'milestone-scope-transition-authorized' -and
    [string]$_.milestone_id -eq $MilestoneId
}).Count -gt 0) {
    throw 'Scoped milestone transition authorization cannot fork or repeat.'
}
$relative = {
    param([string] $Path)
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$selectionRelativePath = & $relative $selectionFullPath
$authorizationRelativePath = & $relative $authorizationFullPath
$carryHash = Get-TextSha256 (
    @($carryForward.occurrences) |
        ConvertTo-Json -Compress -Depth 50
)
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    previous_milestone_id = [string]$chain.active_milestone_id
    previous_activation_receipt_path =
        [string]$chain.activation_receipt_path
    previous_activation_receipt_hash =
        [string]$chain.activation_receipt_hash
    previous_source_bindings_hash = Get-TextSha256 (
        @($chain.active_source_bindings) |
            ConvertTo-Json -Compress -Depth 30
    )
    milestone_id = $MilestoneId
    milestone_index = $milestoneIndex
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    selection_material_path = $selectionRelativePath
    selection_material_hash = (
        Get-FileHash -LiteralPath $selectionFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    checkpoint_material_path = [string]$checkpointPaths[0]
    checkpoint_material_hash = [string]$checkpointHashes[0]
    scope_transition_authorization_material_path =
        $authorizationRelativePath
    scope_transition_authorization_material_hash = (
        Get-FileHash -LiteralPath $authorizationFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    scope_transition_key = $ScopeTransitionKey
    carry_forward_occurrences_hash = $carryHash
    previous_open_occurrence_count =
        [int]$carryForward.previous_open_count
    resolved_occurrence_count = [int]$carryForward.resolved_count
    remaining_open_occurrence_count =
        [int]$carryForward.remaining_open_count
    activation_key = $ActivationKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
if (-not (Test-Path -LiteralPath $receiptDirectory)) {
    $null = New-Item -ItemType Directory -Path $receiptDirectory
}
$tempReceiptPath = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $tempReceiptPath -Encoding utf8
$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the orchestration journal lock.'
    }
    $currentEvents = @(Read-OrchestrationJournal $eventsPath)
    if ($currentEvents.Count -ne $events.Count -or
        [string]$currentEvents[-1].hash -ne [string]$events[-1].hash) {
        throw (
            'The journal changed while scoped milestone transition ' +
            'authorization was prepared.'
        )
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw 'Scoped milestone transition authorization already exists.'
    }
    Move-Item -LiteralPath $tempReceiptPath -Destination $receiptPath
    $runPolicy = Resolve-OrchestrationRunPolicy `
        -RunDirectory $runRoot -Events $currentEvents
    $receiptRelativePath = "receipts/$receiptName"
    $event = [ordered]@{
        sequence = $currentEvents.Count
        prev_hash = [string]$currentEvents[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'milestone-scope-transition-authorized'
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        workspace_root = [string]$run.workspace_root
        policy_version = [string]$runPolicy.source_policy_version
        actor = [string]$plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        milestone_id = $MilestoneId
        scope_transition_authorization_receipt_path =
            $receiptRelativePath
        scope_transition_authorization_receipt_hash =
            [string]$receipt.receipt_hash
        scope_transition_key = $ScopeTransitionKey
        scope_transition_selection_material_hash =
            [string]$receipt.selection_material_hash
        message = "Authorized scoped transition to '$MilestoneId'."
        thread_id = $null
        model_id = $null
        artifact = $receiptRelativePath
        topology = $null
        capability = $null
        effort = $null
        wave = 0
        attempt = 0
        execution_slot_delta = 0
        input_tokens_delta = 0
        output_tokens_delta = 0
        coordination_tokens_delta = 0
        usage_source = 'none'
        error_class = $null
        evidence = @(
            "artifact:$receiptRelativePath",
            "artifact:$selectionRelativePath",
            "artifact:$authorizationRelativePath"
        )
        idempotency_key = $ActivationKey
        request_fingerprint = [string]$receipt.receipt_hash
    }
    if (-not [string]::IsNullOrWhiteSpace(
        [string]$runPolicy.activation_receipt_path
    )) {
        $event.runtime_policy_version =
            [string]$runPolicy.effective_policy_version
        $event.policy_activation_receipt_path =
            [string]$runPolicy.activation_receipt_path
        $event.policy_activation_receipt_hash =
            [string]$runPolicy.activation_receipt_hash
    }
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    try {
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 100
        )
    } catch {
        Remove-Item -LiteralPath $receiptPath -Force
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $tempReceiptPath) {
        Remove-Item -LiteralPath $tempReceiptPath -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
$verified = Read-DurableReviewScopeTransitionAuthorization `
    -Path $receiptPath -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
