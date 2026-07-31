[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PredecessorRunDirectory,
    [Parameter(Mandatory)][string] $SuccessorPlanPath,
    [Parameter(Mandatory)][string] $SuccessorRunDirectory,
    [Parameter(Mandatory)][string] $RotationManifestPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

if ($ActivationKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Source rotation requires a stable user: or controller: key.'
}
$runRoot = [IO.Path]::GetFullPath(
    $PredecessorRunDirectory
).TrimEnd('\', '/')
$successorPlanFullPath = [IO.Path]::GetFullPath($SuccessorPlanPath)
$successorRunFullPath = [IO.Path]::GetFullPath(
    $SuccessorRunDirectory
).TrimEnd('\', '/')
$manifestFullPath = [IO.Path]::GetFullPath($RotationManifestPath)
$authorizationFullPath = [IO.Path]::GetFullPath($AuthorizationMaterialPath)
foreach ($path in @($successorPlanFullPath, $manifestFullPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Source rotation requires an existing plan and failure manifest.'
    }
}
if (-not $authorizationFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $authorizationFullPath -PathType Leaf) -or
    [string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $authorizationFullPath -Raw)
    )) {
    throw 'Source-rotation authorization must be a non-empty run-local file.'
}

$snapshot = Get-DurableReviewSourceRotationSnapshot `
    -RunDirectory $runRoot -RotationManifestPath $manifestFullPath
$null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $successorPlanFullPath `
    -WorkspaceRoot ([string]$snapshot.run.workspace_root)
$successorPlanRaw = Get-Content -LiteralPath $successorPlanFullPath -Raw
$successorPlan = $successorPlanRaw |
    ConvertFrom-Json -Depth 100 -DateKind String
$profile = $successorPlan.successor_review_profile
$sourceIds = @($snapshot.rotated_source_bindings |
    ForEach-Object { [string]$_.source_node_id })
$oldMilestones = @(
    $snapshot.plan.durable_review_profile.milestone_ids |
        ForEach-Object { [string]$_ }
)
$targetIndex = [Array]::IndexOf(
    $oldMilestones, [string]$snapshot.rotation_target_milestone_id
)
$expectedMilestones = @(
    $oldMilestones[$targetIndex..($oldMilestones.Count - 1)]
)
if ([string]$successorPlan.run_id -eq [string]$snapshot.run.run_id -or
    [string]$profile.lineage_kind -ne 'source-rotation' -or
    [string]$profile.predecessor_run_id -ne [string]$snapshot.run.run_id -or
    [string]$profile.predecessor_active_milestone_id -ne
        [string]$snapshot.active_milestone_id -or
    [string]$profile.predecessor_checkpoint_material_hash -ne
        [string]$snapshot.active_checkpoint_material_hash -or
    [string]$profile.rotation_target_milestone_id -ne
        [string]$snapshot.rotation_target_milestone_id -or
    [string]$profile.rotation_checkpoint_material_hash -ne
        [string]$snapshot.rotation_checkpoint_material_hash -or
    (@($profile.source_node_ids) -join "`n") -ne ($sourceIds -join "`n") -or
    (@($successorPlan.durable_review_profile.milestone_ids) -join "`n") -ne
        ($expectedMilestones -join "`n")) {
    throw 'Source-rotation successor plan does not match the predecessor.'
}
foreach ($binding in @($snapshot.rotated_source_bindings)) {
    $node = @($successorPlan.nodes | Where-Object {
        [string]$_.id -eq [string]$binding.source_node_id
    })
    $role = @($successorPlan.roles | Where-Object {
        [string]$_.id -eq [string]$binding.role_id
    })
    if ($node.Count -ne 1 -or $role.Count -ne 1 -or
        [string]$node[0].role_id -ne [string]$binding.role_id -or
        [string]$node[0].context.session_policy -ne 'fresh' -or
        [int]$node[0].context.max_prior_turns -ne 0 -or
        $null -ne $node[0].context.PSObject.Properties['prior_thread_id'] -or
        [bool]$node[0].read_only -ne $true -or
        [bool]$node[0].allow_delegation -ne $false -or
        (Get-TextSha256 (
            $role[0] | ConvertTo-Json -Compress -Depth 100
        )) -ne [string]$binding.role_contract_hash) {
        throw 'Source-rotation successor must preserve roles but use fresh seats.'
    }
}

$eventsPath = Join-Path $runRoot 'events.jsonl'
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = 'durable-review-source-rotation.export.json'
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'The predecessor already has a source-rotation export.'
}
$authorizationRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, $authorizationFullPath
).Replace('\', '/')
$payload = [ordered]@{
    schema_version = '1.0'
    lineage_kind = 'source-rotation'
    predecessor_run_path = $runRoot
    predecessor_run_id = [string]$snapshot.run.run_id
    predecessor_plan_hash = [string]$snapshot.plan_hash
    predecessor_run_file_hash = [string]$snapshot.run_file_hash
    predecessor_genesis_hash = [string]$snapshot.genesis_hash
    predecessor_journal_head = [string]$snapshot.journal_head
    predecessor_journal_event_count = [int]$snapshot.journal_event_count
    effective_policy_version = [string]$snapshot.effective_policy_version
    active_milestone_id = [string]$snapshot.active_milestone_id
    active_milestone_receipt_path =
        [string]$snapshot.active_milestone_receipt_path
    active_milestone_receipt_hash =
        [string]$snapshot.active_milestone_receipt_hash
    active_checkpoint_material_path =
        [string]$snapshot.active_checkpoint_material_path
    active_checkpoint_material_hash =
        [string]$snapshot.active_checkpoint_material_hash
    rotation_target_milestone_id =
        [string]$snapshot.rotation_target_milestone_id
    rotation_checkpoint_material_path =
        [string]$snapshot.rotation_checkpoint_material_path
    rotation_checkpoint_material_hash =
        [string]$snapshot.rotation_checkpoint_material_hash
    rotation_manifest_path = [string]$snapshot.rotation_manifest_path
    rotation_manifest_file_hash =
        [string]$snapshot.rotation_manifest_file_hash
    formal_source_bindings = @($snapshot.formal_source_bindings)
    formal_source_bindings_hash =
        [string]$snapshot.formal_source_bindings_hash
    rotated_source_bindings = @($snapshot.rotated_source_bindings)
    rotated_source_bindings_hash =
        [string]$snapshot.rotated_source_bindings_hash
    open_obligations = @($snapshot.open_obligations)
    open_obligations_hash = [string]$snapshot.open_obligations_hash
    successor_run_id = [string]$successorPlan.run_id
    successor_plan_hash = Get-TextSha256 $successorPlanRaw
    successor_run_path = $successorRunFullPath
    successor_milestone_ids = $expectedMilestones
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
        throw 'Predecessor journal changed while source rotation was prepared.'
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw 'The predecessor already has a source-rotation export.'
    }
    Move-Item -LiteralPath $tempPath -Destination $receiptPath
    $policy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot `
        -Events $events
    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = [string]$events[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'durable-review-source-rotation-exported'
        run_id = [string]$snapshot.run.run_id
        plan_hash = [string]$snapshot.plan_hash
        workspace_root = [string]$snapshot.run.workspace_root
        policy_version = [string]$policy.source_policy_version
        actor = [string]$snapshot.plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        message = "Exported fresh reviewer rotation '$($successorPlan.run_id)'."
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
            "artifact:$([string]$snapshot.rotation_manifest_path)",
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
            $event | ConvertTo-Json -Compress -Depth 100
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
$verified = Read-DurableReviewSourceRotationExportReceipt `
    -Path $receiptPath -PredecessorRunDirectory $runRoot `
    -SuccessorPlanPath $successorPlanFullPath
$verified | ConvertTo-Json -Depth 100
