[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PredecessorRunDirectory,
    [Parameter(Mandatory)][string] $SuccessorPlanPath,
    [Parameter(Mandatory)][string] $SuccessorRunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

if ($ActivationKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Successor export requires a stable user: or controller: key.'
}
$runRoot = [IO.Path]::GetFullPath(
    $PredecessorRunDirectory
).TrimEnd('\', '/')
$successorPlanFullPath = [IO.Path]::GetFullPath($SuccessorPlanPath)
$successorRunFullPath = [IO.Path]::GetFullPath(
    $SuccessorRunDirectory
).TrimEnd('\', '/')
$authorizationFullPath = [IO.Path]::GetFullPath($AuthorizationMaterialPath)
if (-not (Test-Path -LiteralPath $successorPlanFullPath -PathType Leaf)) {
    throw 'Successor export requires an existing successor plan.'
}
if (-not $authorizationFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $authorizationFullPath -PathType Leaf) -or
    [string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $authorizationFullPath -Raw)
    )) {
    throw 'Successor export authorization must be a non-empty run-local file.'
}
$snapshot = Get-DurableReviewSuccessorSnapshot -RunDirectory $runRoot
$null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $successorPlanFullPath `
    -WorkspaceRoot ([string]$snapshot.run.workspace_root)
$successorPlanRaw = Get-Content -LiteralPath $successorPlanFullPath -Raw
$successorPlan = $successorPlanRaw |
    ConvertFrom-Json -Depth 100 -DateKind String
if ([string]$successorPlan.run_id -eq [string]$snapshot.run.run_id) {
    throw 'Successor run_id must differ from the predecessor run_id.'
}
if ($null -eq $successorPlan.PSObject.Properties['successor_review_profile']) {
    throw 'Successor plan must declare successor_review_profile.'
}
$successorProfile = $successorPlan.successor_review_profile
$declaredSourceIds = @(
    $successorProfile.source_node_ids | ForEach-Object { [string]$_ }
)
$boundSourceIds = @(
    $snapshot.source_bindings |
        ForEach-Object { [string]$_.source_node_id }
)
if ([string]$successorProfile.predecessor_run_id -ne
        [string]$snapshot.run.run_id -or
    [string]$successorProfile.predecessor_active_milestone_id -ne
        [string]$snapshot.active_milestone_id -or
    [string]$successorProfile.predecessor_checkpoint_material_hash -ne
        [string]$snapshot.checkpoint_material_hash -or
    ($declaredSourceIds -join "`n") -ne ($boundSourceIds -join "`n")) {
    throw 'Successor plan declaration does not match the predecessor.'
}
foreach ($binding in @($snapshot.source_bindings)) {
    $nodeMatches = @($successorPlan.nodes | Where-Object {
        [string]$_.id -eq [string]$binding.source_node_id
    })
    $roleMatches = @($successorPlan.roles | Where-Object {
        [string]$_.id -eq [string]$binding.role_id
    })
    if ($nodeMatches.Count -ne 1 -or $roleMatches.Count -ne 1 -or
        [string]$nodeMatches[0].role_id -ne [string]$binding.role_id -or
        [string]$nodeMatches[0].context.session_policy -ne 'reuse' -or
        [string]$nodeMatches[0].context.prior_thread_id -ne
            [string]$binding.source_thread_id -or
        (Get-TextSha256 (
            $roleMatches[0] | ConvertTo-Json -Compress -Depth 100
        )) -ne [string]$binding.role_contract_hash) {
        throw 'Successor plan does not preserve source role/thread continuity.'
    }
}

$eventsPath = Join-Path $runRoot 'events.jsonl'
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = 'durable-review-successor.export.json'
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'The predecessor already has a successor export.'
}
$authorizationRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, $authorizationFullPath
).Replace('\', '/')
$payload = [ordered]@{
    schema_version = '1.0'
    predecessor_run_path = $runRoot
    predecessor_run_id = [string]$snapshot.run.run_id
    predecessor_plan_hash = [string]$snapshot.plan_hash
    predecessor_run_file_hash = [string]$snapshot.run_file_hash
    predecessor_genesis_hash = [string]$snapshot.genesis_hash
    predecessor_journal_head = [string]$snapshot.events[-1].hash
    predecessor_journal_event_count = @($snapshot.events).Count
    effective_policy_version = [string]$snapshot.effective_policy_version
    active_milestone_id = [string]$snapshot.active_milestone_id
    active_milestone_receipt_path =
        [string]$snapshot.active_milestone_receipt_path
    active_milestone_receipt_hash =
        [string]$snapshot.active_milestone_receipt_hash
    checkpoint_material_path = [string]$snapshot.checkpoint_material_path
    checkpoint_material_hash = [string]$snapshot.checkpoint_material_hash
    source_bindings = @($snapshot.source_bindings)
    source_bindings_hash = [string]$snapshot.source_bindings_hash
    open_obligations = @($snapshot.open_obligations)
    open_obligations_hash = [string]$snapshot.open_obligations_hash
    successor_run_id = [string]$successorPlan.run_id
    successor_plan_hash = Get-TextSha256 $successorPlanRaw
    successor_run_path = $successorRunFullPath
    successor_milestone_ids = @(
        $successorPlan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    authorization_material_path = $authorizationRelativePath
    authorization_material_hash = (
        Get-FileHash -LiteralPath $authorizationFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
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
$tempPath = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $tempPath -Encoding utf8
$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the predecessor journal lock.'
    }
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -ne [int]$receipt.predecessor_journal_event_count -or
        [string]$events[-1].hash -ne
            [string]$receipt.predecessor_journal_head) {
        throw 'Predecessor journal changed while successor export was prepared.'
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw 'The predecessor already has a successor export.'
    }
    Move-Item -LiteralPath $tempPath -Destination $receiptPath
    $policy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot `
        -Events $events
    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = [string]$events[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'durable-review-successor-exported'
        run_id = [string]$snapshot.run.run_id
        plan_hash = [string]$snapshot.plan_hash
        workspace_root = [string]$snapshot.run.workspace_root
        policy_version = [string]$policy.source_policy_version
        actor = [string]$snapshot.plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        message = "Exported successor '$($successorPlan.run_id)'."
        thread_id = $null
        model_id = $null
        artifact = "receipts/$receiptName"
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
            "artifact:receipts/$receiptName",
            "artifact:$authorizationRelativePath"
        )
        result_receipt_path = "receipts/$receiptName"
        result_receipt_hash = [string]$receipt.receipt_hash
        idempotency_key = $ActivationKey
        request_fingerprint = [string]$receipt.receipt_hash
    }
    if (-not [string]::IsNullOrWhiteSpace(
        [string]$policy.activation_receipt_path
    )) {
        $event.runtime_policy_version = [string]$policy.effective_policy_version
        $event.policy_activation_receipt_path =
            [string]$policy.activation_receipt_path
        $event.policy_activation_receipt_hash =
            [string]$policy.activation_receipt_hash
    }
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    try {
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 50
        )
    } catch {
        Remove-Item -LiteralPath $receiptPath -Force
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
$verified = Read-DurableReviewSuccessorExportReceipt -Path $receiptPath `
    -PredecessorRunDirectory $runRoot `
    -SuccessorPlanPath $successorPlanFullPath
$verified | ConvertTo-Json -Depth 100
