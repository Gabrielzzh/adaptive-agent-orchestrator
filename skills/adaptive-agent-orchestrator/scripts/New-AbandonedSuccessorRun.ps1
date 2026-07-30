[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $WorkspaceRoot,
    [Parameter(Mandatory)][string] $AbandonedRunDirectory,
    [Parameter(Mandatory)][string] $AbandonedExportReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$planPath = [IO.Path]::GetFullPath($PlanPath)
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$abandonedRoot = [IO.Path]::GetFullPath(
    $AbandonedRunDirectory
).TrimEnd('\', '/')
$exportPath = [IO.Path]::GetFullPath($AbandonedExportReceiptPath)
if (Test-Path -LiteralPath $runRoot) {
    throw "Fresh successor run directory already exists: $runRoot"
}
$null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $planPath -WorkspaceRoot $WorkspaceRoot
$export = Read-AbandonedSuccessorExportReceipt -Path $exportPath `
    -AbandonedRunDirectory $abandonedRoot -SuccessorPlanPath $planPath `
    -ExpectedSuccessorRunDirectory $runRoot

try {
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $planPath -RunDirectory $runRoot `
        -WorkspaceRoot $WorkspaceRoot | Out-Null
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $events = @(Read-OrchestrationJournal $eventsPath)
    $abandonedEvents = @(Read-OrchestrationJournal (
        Join-Path $abandonedRoot 'events.jsonl'
    ))
    $receiptDirectory = Join-Path $runRoot 'receipts'
    if (-not (Test-Path -LiteralPath $receiptDirectory)) {
        $null = New-Item -ItemType Directory -Path $receiptDirectory
    }
    $receiptName = 'durable-review-successor.adoption.json'
    $receiptPath = Join-Path $receiptDirectory $receiptName
    $payload = [ordered]@{
        schema_version = '1.1'
        lineage_kind = 'abandoned-successor'
        run_path = $runRoot
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        genesis_hash = [string]$events[0].hash
        predecessor_run_path = $abandonedRoot
        predecessor_run_id = [string]$export.abandoned_run_id
        predecessor_final_journal_head = [string]$abandonedEvents[-1].hash
        predecessor_final_journal_event_count = $abandonedEvents.Count
        export_receipt_path = [IO.Path]::GetRelativePath(
            $abandonedRoot, $exportPath
        ).Replace('\', '/')
        export_receipt_hash = [string]$export.receipt_hash
        export_receipt_file_hash = (
            Get-FileHash -LiteralPath $exportPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        predecessor_active_milestone_id = 'abandoned-before-first-milestone'
        checkpoint_material_hash = [string]$export.checkpoint_material_hash
        source_bindings = @($export.source_bindings)
        source_bindings_hash = [string]$export.source_bindings_hash
        inherited_obligations = @($export.inherited_obligations)
        inherited_obligations_hash =
            [string]$export.inherited_obligations_hash
        successor_milestone_ids = @(
            $plan.durable_review_profile.milestone_ids |
                ForEach-Object { [string]$_ }
        )
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $receipt = [ordered]@{}
    foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
    $receipt.receipt_hash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8
    $event = [ordered]@{
        sequence = 1
        prev_hash = [string]$events[0].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'durable-review-successor-adopted'
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        workspace_root = [string]$run.workspace_root
        policy_version = [string]$plan.policy_version
        actor = [string]$plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        message = "Adopted abandoned successor '$($export.abandoned_run_id)'."
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
        evidence = @("artifact:receipts/$receiptName")
        result_receipt_path = "receipts/$receiptName"
        result_receipt_hash = [string]$receipt.receipt_hash
        idempotency_key = 'controller:abandoned-successor-adoption'
        request_fingerprint = [string]$receipt.receipt_hash
    }
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    Add-Content -LiteralPath $eventsPath -Value (
        $event | ConvertTo-Json -Compress -Depth 50
    )
    $previous = $event
    $sequence = 2
    foreach ($binding in @($export.source_bindings)) {
        $carried = [ordered]@{
            sequence = $sequence
            prev_hash = [string]$previous.hash
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            event = 'source-attempt-carried'
            run_id = [string]$run.run_id
            plan_hash = [string]$run.plan_hash
            workspace_root = [string]$run.workspace_root
            policy_version = [string]$plan.policy_version
            actor = [string]$plan.orchestrator.id
            node_id = [string]$binding.source_node_id
            role_id = [string]$binding.role_id
            prior_state = 'planned'
            status = 'planned'
            message = 'Carried consumed attempts from the abandoned successor.'
            thread_id = [string]$binding.source_thread_id
            model_id = $null
            artifact = "receipts/$receiptName"
            topology = 'background-thread'
            capability = $null
            effort = $null
            wave = 0
            attempt = [int]$binding.inherited_attempt_count
            execution_slot_delta = 0
            input_tokens_delta = 0
            output_tokens_delta = 0
            coordination_tokens_delta = 0
            usage_source = 'none'
            error_class = $null
            evidence = @("artifact:receipts/$receiptName")
            result_receipt_path = "receipts/$receiptName"
            result_receipt_hash = [string]$receipt.receipt_hash
            idempotency_key = "controller:carry-attempt:$(
                [string]$binding.source_node_id
            )"
            request_fingerprint = [string]$receipt.receipt_hash
        }
        $carried.hash = Get-OrchestrationEventHash ([pscustomobject]$carried)
        Add-Content -LiteralPath $eventsPath -Value (
            $carried | ConvertTo-Json -Compress -Depth 50
        )
        $previous = $carried
        $sequence++
    }
    Read-DurableReviewSuccessorAdoptionReceipt -RunDirectory $runRoot |
        ConvertTo-Json -Depth 100
}
catch {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
    throw
}
