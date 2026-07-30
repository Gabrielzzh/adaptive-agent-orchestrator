[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AbandonedRunDirectory,
    [Parameter(Mandatory)][string] $SuccessorPlanPath,
    [Parameter(Mandatory)][string] $SuccessorRunDirectory,
    [Parameter(Mandatory)][string] $CheckpointMaterialPath,
    [Parameter(Mandatory)][string] $AdditionalFindingRecordsPath,
    [Parameter(Mandatory)][string] $UnactivatedEvidenceManifestPath,
    [Parameter(Mandatory)][string] $AuthorizationReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($AbandonedRunDirectory).TrimEnd('\', '/')
$planPath = [IO.Path]::GetFullPath($SuccessorPlanPath)
$successorRun = [IO.Path]::GetFullPath(
    $SuccessorRunDirectory
).TrimEnd('\', '/')
$authorizationReceipt = [IO.Path]::GetFullPath($AuthorizationReceiptPath)
$snapshot = Get-AbandonedSuccessorSnapshot -RunDirectory $runRoot
$materials = [ordered]@{
    checkpoint = [IO.Path]::GetFullPath($CheckpointMaterialPath)
    additional = [IO.Path]::GetFullPath($AdditionalFindingRecordsPath)
    unactivated = [IO.Path]::GetFullPath($UnactivatedEvidenceManifestPath)
}
foreach ($entry in $materials.GetEnumerator()) {
    if (-not $entry.Value.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $entry.Value -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $entry.Value -Raw)
        )) {
        throw "Abandoned successor material '$($entry.Key)' must be run-local."
    }
}
$null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $planPath -WorkspaceRoot ([string]$snapshot.run.workspace_root)
$planRaw = Get-Content -LiteralPath $planPath -Raw
$plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
$authorization = Read-AbandonedSuccessorAuthorizationReceipt `
    -Path $authorizationReceipt -AbandonedRunDirectory $runRoot `
    -SuccessorPlanPath $planPath `
    -ExpectedSuccessorRunDirectory $successorRun
if ([string]$plan.run_id -eq [string]$snapshot.run.run_id -or
    $null -eq $plan.PSObject.Properties['successor_review_profile']) {
    throw 'Fresh successor plan identity is invalid.'
}
$sourceIds = @($snapshot.source_bindings |
    ForEach-Object { [string]$_.source_node_id })
if ([string]$plan.successor_review_profile.predecessor_run_id -ne
        [string]$snapshot.run.run_id -or
    [string]$plan.successor_review_profile.predecessor_active_milestone_id -ne
        'abandoned-before-first-milestone' -or
    [string]$plan.successor_review_profile.predecessor_checkpoint_material_hash -ne
        (Get-FileHash -LiteralPath $materials.checkpoint -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
    (@($plan.successor_review_profile.source_node_ids) -join "`n") -ne
        ($sourceIds -join "`n")) {
    throw 'Fresh successor plan does not bind the abandoned run and checkpoint.'
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
        throw 'Fresh successor changed source continuity or consumed attempts.'
    }
}

$additional = @(Get-Content -LiteralPath $materials.additional -Raw |
    ConvertFrom-Json -Depth 50 -DateKind String)
if ($additional.Count -lt 1) {
    throw 'Abandoned successor export requires an additional P1 finding.'
}
$existing = @($snapshot.adoption_receipt.inherited_obligations)
$obligations = [Collections.Generic.List[object]]::new()
foreach ($item in $existing) { $obligations.Add($item) }
$seen = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($item in $existing) {
    $null = $seen.Add(
        [string]$item.source_node_id + "`n" + [string]$item.source_finding_id
    )
}
foreach ($item in $additional) {
    foreach ($name in @(
        'source_node_id', 'source_finding_id', 'canonical_finding_id',
        'severity', 'finding', 'finding_hash', 'resolution_status'
    )) {
        if ($null -eq $item.PSObject.Properties[$name]) {
            throw "Additional finding is missing '$name'."
        }
    }
    $sourceId = [string]$item.source_node_id
    $binding = @($snapshot.source_bindings | Where-Object {
        [string]$_.source_node_id -eq $sourceId
    })
    if ($binding.Count -ne 1 -or [string]$item.severity -ne 'P1' -or
        [string]$item.resolution_status -eq 'resolved' -or
        [string]$item.finding_hash -ne (Get-TextSha256 (
            [string]$item.finding
        )) -or -not $seen.Add(
            $sourceId + "`n" + [string]$item.source_finding_id
        )) {
        throw 'Additional finding identity, severity, hash, or uniqueness failed.'
    }
    $obligations.Add([ordered]@{
        source_node_id = $sourceId
        role_id = [string]$binding[0].role_id
        source_thread_id = [string]$binding[0].source_thread_id
        source_finding_id = [string]$item.source_finding_id
        canonical_finding_id = [string]$item.canonical_finding_id
        severity = 'P1'
        finding = [string]$item.finding
        finding_hash = [string]$item.finding_hash
        resolution_status = [string]$item.resolution_status
    })
}
if ($obligations.Count -ne ($existing.Count + $additional.Count)) {
    throw 'Abandoned successor obligations were omitted or merged.'
}

$unactivated = @(Get-Content -LiteralPath $materials.unactivated -Raw |
    ConvertFrom-Json -Depth 50 -DateKind String)
if ($unactivated.Count -ne $sourceIds.Count) {
    throw 'Unactivated evidence manifest must cover every durable source.'
}
foreach ($sourceId in $sourceIds) {
    $entry = @($unactivated | Where-Object {
        [string]$_.source_node_id -eq $sourceId
    })
    if ($entry.Count -ne 1 -or
        $null -eq $entry[0].PSObject.Properties['completion_eligible'] -or
        [bool]$entry[0].completion_eligible -ne $false) {
        throw "Unactivated evidence for '$sourceId' is invalid."
    }
    foreach ($kind in @('result', 'disposition')) {
        $pathName = "${kind}_receipt_path"
        $hashName = "${kind}_receipt_file_hash"
        $relative = [string]$entry[0].$pathName
        $file = Join-Path $runRoot $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            [string]$entry[0].$hashName -ne (
                Get-FileHash -LiteralPath $file -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw "Unactivated $kind evidence for '$sourceId' changed."
        }
    }
    $binding = @($snapshot.source_bindings | Where-Object {
        [string]$_.source_node_id -eq $sourceId
    })[0]
    $resultFile = Join-Path $runRoot (
        [string]$entry[0].result_receipt_path
    )
    $null = Read-ThreadResultReceipt -Path $resultFile `
        -ExpectedThreadId ([string]$binding.source_thread_id) `
        -ExpectedSourceNodeId $sourceId -RunDirectory $runRoot
    $dispositionFile = Join-Path $runRoot (
        [string]$entry[0].disposition_receipt_path
    )
    $null = Read-ReviewDispositionReceipt -Path $dispositionFile `
        -RunDirectory $runRoot -ExpectedSourceNodeId $sourceId `
        -ExpectedThreadId ([string]$binding.source_thread_id)
}

$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = 'durable-review-abandoned-successor.export.json'
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'The abandoned successor already has an export.'
}
function Relative([string] $Path) {
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$payload = [ordered]@{
    schema_version = '1.0'
    lineage_kind = 'abandoned-successor'
    abandoned_run_path = $runRoot
    abandoned_run_id = [string]$snapshot.run.run_id
    abandoned_plan_hash = [string]$snapshot.plan_hash
    abandoned_run_file_hash = [string]$snapshot.run_file_hash
    abandoned_genesis_hash = [string]$snapshot.genesis_hash
    abandoned_journal_head = [string]$snapshot.journal_head
    abandoned_journal_event_count = [int]$snapshot.journal_event_count
    effective_policy_version = [string]$snapshot.effective_policy_version
    original_adoption_receipt_path = [string]$snapshot.adoption_receipt_path
    original_adoption_receipt_hash =
        [string]$snapshot.adoption_receipt.receipt_hash
    original_adoption_receipt_file_hash =
        [string]$snapshot.adoption_receipt_file_hash
    source_bindings = @($snapshot.source_bindings)
    source_bindings_hash = [string]$snapshot.source_bindings_hash
    inherited_obligations = @($obligations)
    inherited_obligations_hash = Get-TextSha256 (
        @($obligations) | ConvertTo-Json -Compress -Depth 100
    )
    additional_findings_path = Relative $materials.additional
    additional_findings_hash = (
        Get-FileHash -LiteralPath $materials.additional -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    unactivated_evidence_manifest_path = Relative $materials.unactivated
    unactivated_evidence_manifest_hash = (
        Get-FileHash -LiteralPath $materials.unactivated -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    checkpoint_material_path = Relative $materials.checkpoint
    checkpoint_material_hash = (
        Get-FileHash -LiteralPath $materials.checkpoint -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    successor_run_id = [string]$plan.run_id
    successor_plan_hash = Get-TextSha256 $planRaw
    successor_run_path = $successorRun
    successor_milestone_ids = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    authorization_receipt_path = [IO.Path]::GetRelativePath(
        $runRoot, $authorizationReceipt
    ).Replace('\', '/')
    authorization_receipt_hash = [string]$authorization.receipt_hash
    authorization_receipt_file_hash = (
        Get-FileHash -LiteralPath $authorizationReceipt -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    authorization_event_hash = [string]$snapshot.events[-1].hash
    authorization_material_path =
        [string]$authorization.authorization_material_path
    authorization_material_hash =
        [string]$authorization.authorization_material_hash
    activation_key = [string]$authorization.activation_key
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
        throw 'Timed out waiting for the abandoned successor journal lock.'
    }
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -ne [int]$receipt.abandoned_journal_event_count -or
        [string]$events[-1].hash -ne [string]$receipt.abandoned_journal_head) {
        throw 'Abandoned successor changed while export was prepared.'
    }
    if (Test-Path -LiteralPath $receiptPath) {
        throw 'The abandoned successor already has an export.'
    }
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = [string]$events[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'durable-review-abandoned-successor-exported'
        run_id = [string]$snapshot.run.run_id
        plan_hash = [string]$snapshot.plan_hash
        workspace_root = [string]$snapshot.run.workspace_root
        policy_version = [string]$snapshot.plan.policy_version
        actor = [string]$snapshot.plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'cancelled'
        message = "Exported abandoned successor '$($plan.run_id)'."
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
        idempotency_key = [string]$authorization.activation_key
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
Read-AbandonedSuccessorExportReceipt -Path $receiptPath `
    -AbandonedRunDirectory $runRoot -SuccessorPlanPath $planPath |
    ConvertTo-Json -Depth 100
