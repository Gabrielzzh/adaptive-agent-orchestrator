[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $MilestoneId,
    [Parameter(Mandatory)][string] $EvidenceMaterialPath,
    [Parameter(Mandatory)][string] $AcceptanceKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$eventsPath = Join-Path $runRoot 'events.jsonl'
$events = @(Read-OrchestrationJournal $eventsPath)
$chain = Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
if ([string]$chain.active_milestone_id -ne $MilestoneId -or
    [string]::IsNullOrWhiteSpace([string]$chain.activation_receipt_hash)) {
    throw 'Main-owner acceptance requires the active non-baseline milestone.'
}
if ($AcceptanceKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone acceptance requires a stable user: or controller: key.'
}
$mainNodes = @($plan.nodes | Where-Object { [string]$_.kind -eq 'main' })
if ($mainNodes.Count -ne 1) {
    throw 'Milestone acceptance requires exactly one main-owner node.'
}
foreach ($binding in @($chain.active_source_bindings)) {
    $dispositionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$binding.disposition_receipt_path) `
        -Label 'Active milestone disposition'
    $disposition = Read-ReviewDispositionReceipt -Path $dispositionPath `
        -RunDirectory $runRoot `
        -ExpectedSourceNodeId ([string]$binding.source_node_id) `
        -ExpectedThreadId ([string]$binding.source_thread_id)
    $openBlocking = @($disposition.decisions | Where-Object {
        [string]$_.severity -in @('P0', 'P1') -and
        [string]$_.resolution_status -ne 'resolved'
    })
    if ($openBlocking.Count -gt 0) {
        throw (
            "Milestone '$MilestoneId' still has unresolved P0/P1 findings."
        )
    }
}

$evidenceFullPath = [IO.Path]::GetFullPath($EvidenceMaterialPath)
if (-not $evidenceFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $evidenceFullPath -PathType Leaf) -or
    [string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $evidenceFullPath -Raw)
    )) {
    throw 'Milestone acceptance evidence must be a non-empty run-local file.'
}
$evidenceRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, $evidenceFullPath
).Replace('\', '/')
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = "durable-review-milestone.$MilestoneId.acceptance.json"
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw "Milestone acceptance receipt already exists: $receiptPath"
}
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    milestone_id = $MilestoneId
    main_node_id = [string]$mainNodes[0].id
    activation_receipt_path = [string]$chain.activation_receipt_path
    activation_receipt_hash = [string]$chain.activation_receipt_hash
    source_bindings_hash = Get-TextSha256 (
        @($chain.active_source_bindings) |
            ConvertTo-Json -Compress -Depth 30
    )
    checkpoint_material_path = [string](
        $chain.activation_receipt.checkpoint_material_path
    )
    checkpoint_material_hash = [string](
        $chain.activation_receipt.checkpoint_material_hash
    )
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    evidence_material_path = $evidenceRelativePath
    evidence_material_hash = (
        Get-FileHash -LiteralPath $evidenceFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    acceptance_key = $AcceptanceKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) {
    $receipt[$key] = $payload[$key]
}
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
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
        throw 'The journal changed while milestone acceptance was prepared.'
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw "Milestone acceptance receipt already exists: $receiptPath"
    }
    Move-Item -LiteralPath $tempReceiptPath -Destination $receiptPath
    $runPolicy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot `
        -Events $currentEvents
    $priorMainEvent = @($currentEvents | Where-Object {
        [string]$_.node_id -eq [string]$mainNodes[0].id
    }) | Select-Object -Last 1
    $event = [ordered]@{
        sequence = $currentEvents.Count
        prev_hash = [string]$currentEvents[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'milestone-accepted'
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        workspace_root = [string]$run.workspace_root
        policy_version = [string]$runPolicy.source_policy_version
        actor = [string]$plan.orchestrator.id
        node_id = [string]$mainNodes[0].id
        role_id = [string]$mainNodes[0].role_id
        prior_state = if ($null -eq $priorMainEvent) {
            'planned'
        } else {
            [string]$priorMainEvent.status
        }
        status = 'validated'
        milestone_id = $MilestoneId
        milestone_activation_receipt_path = [string](
            $chain.activation_receipt_path
        )
        milestone_activation_receipt_hash = [string](
            $chain.activation_receipt_hash
        )
        milestone_acceptance_receipt_path = "receipts/$receiptName"
        milestone_acceptance_receipt_hash = [string]$receipt.receipt_hash
        message = "Main owner accepted milestone '$MilestoneId'."
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
            "artifact:$evidenceRelativePath"
        )
        idempotency_key = $AcceptanceKey
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
            $event | ConvertTo-Json -Compress -Depth 30
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
$verified = Read-DurableReviewMilestoneAcceptance `
    -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
