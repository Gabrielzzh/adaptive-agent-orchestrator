[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AbandonedRunDirectory,
    [Parameter(Mandatory)][string] $SuccessorPlanPath,
    [Parameter(Mandatory)][string] $SuccessorRunDirectory,
    [Parameter(Mandatory)][string] $CheckpointMaterialPath,
    [Parameter(Mandatory)][string] $AdditionalFindingRecordsPath,
    [Parameter(Mandatory)][string] $UnactivatedEvidenceManifestPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

if ($ActivationKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Abandoned successor authorization requires a stable authority key.'
}
$runRoot = [IO.Path]::GetFullPath($AbandonedRunDirectory).TrimEnd('\', '/')
$planPath = [IO.Path]::GetFullPath($SuccessorPlanPath)
$successorRun = [IO.Path]::GetFullPath(
    $SuccessorRunDirectory
).TrimEnd('\', '/')
$snapshot = Get-AbandonedSuccessorSnapshot -RunDirectory $runRoot
$materials = [ordered]@{
    checkpoint_material = [IO.Path]::GetFullPath($CheckpointMaterialPath)
    additional_findings = [IO.Path]::GetFullPath($AdditionalFindingRecordsPath)
    unactivated_evidence_manifest =
        [IO.Path]::GetFullPath($UnactivatedEvidenceManifestPath)
    authorization_material = [IO.Path]::GetFullPath($AuthorizationMaterialPath)
}
foreach ($entry in $materials.GetEnumerator()) {
    if (-not $entry.Value.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $entry.Value -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $entry.Value -Raw)
        )) {
        throw "Authorization material '$($entry.Key)' must be run-local."
    }
}
$null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $planPath -WorkspaceRoot ([string]$snapshot.run.workspace_root)
$planRaw = Get-Content -LiteralPath $planPath -Raw
$plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
$checkpointHash = (
    Get-FileHash -LiteralPath $materials.checkpoint_material -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$plan.successor_review_profile.predecessor_run_id -ne
        [string]$snapshot.run.run_id -or
    [string]$plan.successor_review_profile.predecessor_active_milestone_id -ne
        'abandoned-before-first-milestone' -or
    [string]$plan.successor_review_profile.predecessor_checkpoint_material_hash -ne
        $checkpointHash -or
    (@($plan.successor_review_profile.source_node_ids) -join "`n") -ne
        (@($snapshot.source_bindings |
            ForEach-Object { [string]$_.source_node_id }) -join "`n")) {
    throw 'Authorization target plan does not bind the abandoned successor.'
}
foreach ($binding in @($snapshot.source_bindings)) {
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq [string]$binding.source_node_id
    })
    $role = @($plan.roles | Where-Object {
        [string]$_.id -eq [string]$binding.role_id
    })
    if ($node.Count -ne 1 -or $role.Count -ne 1 -or
        [string]$node[0].role_id -ne [string]$binding.role_id -or
        [string]$node[0].context.session_policy -ne 'reuse' -or
        [string]$node[0].context.prior_thread_id -ne
            [string]$binding.source_thread_id -or
        [bool]$node[0].read_only -ne $true -or
        [bool]$node[0].allow_delegation -ne $false -or
        [int]$node[0].max_attempts -le
            [int]$binding.inherited_attempt_count -or
        [int]$plan.limits.max_attempts_per_node -le
            [int]$binding.inherited_attempt_count -or
        (Get-TextSha256 (
            $role[0] | ConvertTo-Json -Compress -Depth 100
        )) -ne [string]$binding.role_contract_hash) {
        throw 'Authorization target changed source continuity or consumed attempts.'
    }
}
$additional = @(Get-Content -LiteralPath $materials.additional_findings -Raw |
    ConvertFrom-Json -Depth 50 -DateKind String)
if ($additional.Count -lt 1) {
    throw 'Authorization requires at least one additional P1 finding.'
}
$seen = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($item in @($snapshot.adoption_receipt.inherited_obligations)) {
    $null = $seen.Add(
        [string]$item.source_node_id + "`n" + [string]$item.source_finding_id
    )
}
foreach ($item in $additional) {
    $sourceId = [string]$item.source_node_id
    if (@($snapshot.source_bindings | Where-Object {
            [string]$_.source_node_id -eq $sourceId
        }).Count -ne 1 -or
        [string]$item.severity -ne 'P1' -or
        [string]$item.resolution_status -eq 'resolved' -or
        [string]$item.finding_hash -ne (Get-TextSha256 (
            [string]$item.finding
        )) -or -not $seen.Add(
            $sourceId + "`n" + [string]$item.source_finding_id
        )) {
        throw 'Authorization additional finding identity or severity is invalid.'
    }
}
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = 'durable-review-abandoned-successor.authorization.json'
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'The abandoned successor already has an authorization anchor.'
}
function Relative([string] $Path) {
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$payload = [ordered]@{
    schema_version = '1.0'
    lineage_kind = 'abandoned-successor-authorization'
    abandoned_run_path = $runRoot
    abandoned_run_id = [string]$snapshot.run.run_id
    abandoned_plan_hash = [string]$snapshot.plan_hash
    authorization_journal_head = [string]$snapshot.journal_head
    authorization_journal_event_count = [int]$snapshot.journal_event_count
    source_bindings_hash = [string]$snapshot.source_bindings_hash
    checkpoint_material_path = Relative $materials.checkpoint_material
    checkpoint_material_hash = $checkpointHash
    additional_findings_path = Relative $materials.additional_findings
    additional_findings_hash = (
        Get-FileHash -LiteralPath $materials.additional_findings `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    unactivated_evidence_manifest_path =
        Relative $materials.unactivated_evidence_manifest
    unactivated_evidence_manifest_hash = (
        Get-FileHash -LiteralPath $materials.unactivated_evidence_manifest `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    successor_run_id = [string]$plan.run_id
    successor_plan_hash = Get-TextSha256 $planRaw
    successor_run_path = $successorRun
    successor_milestone_ids = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    authorization_material_path = Relative $materials.authorization_material
    authorization_material_hash = (
        Get-FileHash -LiteralPath $materials.authorization_material `
            -Algorithm SHA256
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
$temp = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $temp -Encoding utf8
$eventsPath = Join-Path $runRoot 'events.jsonl'
$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the authorization journal lock.'
    }
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -ne [int]$receipt.authorization_journal_event_count -or
        [string]$events[-1].hash -ne
            [string]$receipt.authorization_journal_head) {
        throw 'Abandoned successor changed before authorization was recorded.'
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw 'The abandoned successor already has an authorization anchor.'
    }
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = [string]$events[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'durable-review-abandoned-successor-authorized'
        run_id = [string]$snapshot.run.run_id
        plan_hash = [string]$snapshot.plan_hash
        workspace_root = [string]$snapshot.run.workspace_root
        policy_version = [string]$snapshot.plan.policy_version
        actor = [string]$snapshot.plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'cancelled'
        message = "Authorized fresh successor '$($plan.run_id)'."
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
            "artifact:$($payload.authorization_material_path)"
        )
        result_receipt_path = "receipts/$receiptName"
        result_receipt_hash = [string]$receipt.receipt_hash
        idempotency_key = $ActivationKey
        request_fingerprint = [string]$receipt.receipt_hash
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
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
Read-AbandonedSuccessorAuthorizationReceipt -Path $receiptPath `
    -AbandonedRunDirectory $runRoot -SuccessorPlanPath $planPath `
    -ExpectedSuccessorRunDirectory $successorRun |
    ConvertTo-Json -Depth 100
