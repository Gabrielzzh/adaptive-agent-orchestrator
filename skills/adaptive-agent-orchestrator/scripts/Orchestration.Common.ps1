Set-StrictMode -Version Latest
$script:OrchestrationCurrentPolicyVersion = '0.7.6'
$script:OrchestrationMigratablePolicyVersions = @(
    '0.7.2', '0.7.3', '0.7.4', '0.7.5'
)
$script:OrchestrationValidationContext = $null

function Get-TextSha256 {
    param([Parameter(Mandatory)][string] $Text)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text)
        )
    ).ToLowerInvariant()
}

function Get-ThreadResultReceiptCanonicalHash {
    param([Parameter(Mandatory)][object] $Receipt)

    $schemaVersion = [string]$Receipt.schema_version
    $hasSourceContract = $null -ne
        $Receipt.PSObject.Properties['source_node_id']
    $hasPending = $null -ne $Receipt.PSObject.Properties['pending_findings']
    $payload = [ordered]@{
        schema_version = $schemaVersion
    }
    if ($hasSourceContract) {
        $payload.source_node_id = [string]$Receipt.source_node_id
        $payload.source_kind = [string]$Receipt.source_kind
    }
    $payload.thread_id = [string]$Receipt.thread_id
    $payload.host_id = [string]$Receipt.host_id
    $payload.collection_method = [string]$Receipt.collection_method
    $payload.thread_read_path = [string]$Receipt.thread_read_path
    $payload.thread_read_hash = [string]$Receipt.thread_read_hash
    $payload.final_turn_id = [string]$Receipt.final_turn_id
    $payload.final_status = [string]$Receipt.final_status
    $payload.final_content_hash = [string]$Receipt.final_content_hash
    if ($hasSourceContract) {
        $payload.replacement_continuity_receipt_path = [string](
            $Receipt.replacement_continuity_receipt_path
        )
        $payload.replacement_continuity_receipt_hash = [string](
            $Receipt.replacement_continuity_receipt_hash
        )
        if ($null -ne $Receipt.PSObject.Properties['milestone_id']) {
            $payload.milestone_id = [string]$Receipt.milestone_id
            $payload.checkpoint_material_path = [string](
                $Receipt.checkpoint_material_path
            )
            $payload.checkpoint_material_hash = [string](
                $Receipt.checkpoint_material_hash
            )
        }
    }
    $payload.adopted_findings = @($Receipt.adopted_findings)
    $payload.rejected_findings = @($Receipt.rejected_findings)
    if ($hasPending) {
        $payload.pending_findings = @($Receipt.pending_findings)
    }
    if ($schemaVersion -eq '1.4') {
        $payload.replacement_checkpoint_roll_forward_receipt_path =
            [string]$Receipt.replacement_checkpoint_roll_forward_receipt_path
        $payload.replacement_checkpoint_roll_forward_receipt_hash =
            [string]$Receipt.replacement_checkpoint_roll_forward_receipt_hash
    } elseif ($schemaVersion -eq '1.5') {
        $payload.source_role_id = [string]$Receipt.source_role_id
        $payload.milestone_revision_authorization_receipt_path =
            [string]$Receipt.milestone_revision_authorization_receipt_path
        $payload.milestone_revision_authorization_receipt_hash =
            [string]$Receipt.milestone_revision_authorization_receipt_hash
        $payload.milestone_revision_id =
            [string]$Receipt.milestone_revision_id
        $payload.milestone_revision_authorization_event_sequence =
            [int]$Receipt.milestone_revision_authorization_event_sequence
        $payload.milestone_revision_authorization_event_hash =
            [string]$Receipt.milestone_revision_authorization_event_hash
        $payload.milestone_revision_rearm_event_sequence =
            [int]$Receipt.milestone_revision_rearm_event_sequence
        $payload.milestone_revision_rearm_event_hash =
            [string]$Receipt.milestone_revision_rearm_event_hash
        $payload.milestone_revision_input_manifest_path =
            [string]$Receipt.milestone_revision_input_manifest_path
        $payload.milestone_revision_input_manifest_hash =
            [string]$Receipt.milestone_revision_input_manifest_hash
    }
    return Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
}

function Get-JournalMutexName {
    param([Parameter(Mandatory)][string] $EventsPath)
    $resolved = (Resolve-Path -LiteralPath $EventsPath).Path
    return 'AdaptiveAgentOrchestrator-' + (Get-TextSha256 $resolved).Substring(0, 24)
}

function Get-OrchestrationEventHash {
    param([Parameter(Mandatory)][object] $Event)
    $keys = @(
        'sequence', 'prev_hash', 'timestamp', 'event', 'run_id', 'plan_hash',
        'workspace_root',
        'policy_version', 'actor', 'node_id', 'role_id', 'prior_state', 'status',
        'message', 'thread_id', 'model_id', 'artifact', 'topology', 'capability',
        'effort', 'wave', 'attempt', 'execution_slot_delta', 'error_class',
        'input_tokens_delta', 'output_tokens_delta',
        'coordination_tokens_delta', 'usage_source',
        'decision', 'human_actor', 'evidence',
        'recovery_receipt_path', 'recovery_receipt_hash',
        'replacement_receipt_path', 'replacement_receipt_hash',
        'result_receipt_path', 'result_receipt_hash', 'idempotency_key',
        'request_fingerprint'
    )
    if ($null -ne $Event.PSObject.Properties['model_verification_state'] -or
        $null -ne $Event.PSObject.Properties['model_verification_evidence']) {
        $modelIndex = [Array]::IndexOf($keys, 'model_id') + 1
        $keys = @(
            $keys[0..($modelIndex - 1)]
            'model_verification_state'
            'model_verification_evidence'
            $keys[$modelIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties[
        'materialization_reconciliation_receipt_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_reconciliation_receipt_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_activation_reservation_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_activation_reservation_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_activation_key_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_handshake_capture_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_handshake_capture_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_handshake_turn_id'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_launch_event_sequence'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_launch_event_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_prior_event_sequence'
    ] -or $null -ne $Event.PSObject.Properties[
        'materialization_prior_event_hash'
    ]) {
        $materializationIndex = [Array]::IndexOf($keys, 'model_id') + 1
        $keys = @(
            $keys[0..($materializationIndex - 1)]
            'materialization_reconciliation_receipt_path'
            'materialization_reconciliation_receipt_hash'
            'materialization_activation_reservation_path'
            'materialization_activation_reservation_hash'
            'materialization_activation_key_hash'
            'materialization_handshake_capture_path'
            'materialization_handshake_capture_hash'
            'materialization_handshake_turn_id'
            'materialization_launch_event_sequence'
            'materialization_launch_event_hash'
            'materialization_prior_event_sequence'
            'materialization_prior_event_hash'
            $keys[$materializationIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties['recovery_cycle_id'] -or
        $null -ne $Event.PSObject.Properties['recovery_milestone_id'] -or
        $null -ne $Event.PSObject.Properties[
            'recovery_milestone_activation_receipt_hash'
        ] -or $null -ne $Event.PSObject.Properties['recovery_checkpoint_hash'] -or
        $null -ne $Event.PSObject.Properties[
            'recovery_input_manifest_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'previous_adopted_event_sequence'
        ] -or $null -ne $Event.PSObject.Properties[
            'previous_adopted_event_hash'
        ]) {
        $recoveryIndex = [Array]::IndexOf(
            $keys, 'recovery_receipt_hash'
        ) + 1
        $keys = @(
            $keys[0..($recoveryIndex - 1)]
            'recovery_cycle_id'
            'recovery_milestone_id'
            'recovery_milestone_activation_receipt_hash'
            'recovery_checkpoint_hash'
            'recovery_input_manifest_hash'
            'previous_adopted_event_sequence'
            'previous_adopted_event_hash'
            $keys[$recoveryIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties['source_kind'] -or
        $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_receipt_path'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_receipt_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_id'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_active_milestone_id'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_active_milestone_activation_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_roll_forward_target_milestone_id'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_checkpoint_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'replacement_input_manifest_hash'
        ]) {
        $replacementIndex = [Array]::IndexOf(
            $keys, 'replacement_receipt_hash'
        ) + 1
        $keys = @(
            $keys[0..($replacementIndex - 1)]
            'source_kind'
            'replacement_roll_forward_receipt_path'
            'replacement_roll_forward_receipt_hash'
            'replacement_roll_forward_id'
            'replacement_roll_forward_active_milestone_id'
            'replacement_roll_forward_active_milestone_activation_hash'
            'replacement_roll_forward_target_milestone_id'
            'replacement_checkpoint_hash'
            'replacement_input_manifest_hash'
            $keys[$replacementIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties['runtime_policy_version'] -or
        $null -ne $Event.PSObject.Properties['policy_activation_receipt_path'] -or
        $null -ne $Event.PSObject.Properties['policy_activation_receipt_hash']) {
        $policyIndex = [Array]::IndexOf($keys, 'policy_version') + 1
        $keys = @(
            $keys[0..($policyIndex - 1)]
            'runtime_policy_version'
            'policy_activation_receipt_path'
            'policy_activation_receipt_hash'
            $keys[$policyIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties['milestone_id'] -or
        $null -ne $Event.PSObject.Properties[
            'milestone_activation_receipt_path'
        ] -or $null -ne $Event.PSObject.Properties[
            'milestone_activation_receipt_hash'
        ]) {
        $statusIndex = [Array]::IndexOf($keys, 'status') + 1
        $keys = @(
            $keys[0..($statusIndex - 1)]
            'milestone_id'
            'milestone_activation_receipt_path'
            'milestone_activation_receipt_hash'
            $keys[$statusIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties['milestone_revision_id'] -or
        $null -ne $Event.PSObject.Properties[
            'milestone_revision_authorization_receipt_path'
        ] -or $null -ne $Event.PSObject.Properties[
            'milestone_revision_authorization_receipt_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'milestone_revision_checkpoint_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'milestone_revision_input_hash'
        ] -or $null -ne $Event.PSObject.Properties[
            'milestone_revision_selection_key'
        ]) {
        $statusIndex = [Array]::IndexOf($keys, 'status') + 1
        $keys = @(
            $keys[0..($statusIndex - 1)]
            'milestone_revision_id'
            'milestone_revision_authorization_receipt_path'
            'milestone_revision_authorization_receipt_hash'
            'milestone_revision_checkpoint_hash'
            'milestone_revision_input_hash'
            'milestone_revision_selection_key'
            $keys[$statusIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties[
        'scope_transition_authorization_receipt_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'scope_transition_authorization_receipt_hash'
    ] -or $null -ne $Event.PSObject.Properties[
        'scope_transition_key'
    ] -or $null -ne $Event.PSObject.Properties[
        'scope_transition_selection_material_hash'
    ]) {
        $statusIndex = [Array]::IndexOf($keys, 'status') + 1
        $keys = @(
            $keys[0..($statusIndex - 1)]
            'scope_transition_authorization_receipt_path'
            'scope_transition_authorization_receipt_hash'
            'scope_transition_key'
            'scope_transition_selection_material_hash'
            $keys[$statusIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties[
        'milestone_acceptance_receipt_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'milestone_acceptance_receipt_hash'
    ]) {
        $milestoneIndex = [Array]::IndexOf(
            $keys, 'milestone_activation_receipt_hash'
        ) + 1
        $keys = @(
            $keys[0..($milestoneIndex - 1)]
            'milestone_acceptance_receipt_path'
            'milestone_acceptance_receipt_hash'
            $keys[$milestoneIndex..($keys.Count - 1)]
        )
    }
    if ($null -ne $Event.PSObject.Properties[
        'milestone_acceptance_key'
    ] -or $null -ne $Event.PSObject.Properties[
        'milestone_acceptance_evidence_path'
    ] -or $null -ne $Event.PSObject.Properties[
        'milestone_acceptance_evidence_hash'
    ]) {
        $acceptanceIndex = [Array]::IndexOf(
            $keys, 'milestone_acceptance_receipt_hash'
        ) + 1
        $keys = @(
            $keys[0..($acceptanceIndex - 1)]
            'milestone_acceptance_key'
            'milestone_acceptance_evidence_path'
            'milestone_acceptance_evidence_hash'
            $keys[$acceptanceIndex..($keys.Count - 1)]
        )
    }
    $payload = [ordered]@{}
    foreach ($key in $keys) {
        $property = $Event.PSObject.Properties[$key]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        $payload[$key] = $value
    }
    return Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 10)
}

function New-MilestoneRevisionJournalEvent {
    param(
        [Parameter(Mandatory)][object] $Plan,
        [Parameter(Mandatory)][object] $Run,
        [Parameter(Mandatory)][object[]] $Events,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $EventName,
        [Parameter(Mandatory)][string] $ReceiptName,
        [Parameter(Mandatory)][object] $Receipt,
        [Parameter(Mandatory)][string] $Message,
        [Parameter(Mandatory)][string] $IdempotencyKey
    )
    $runPolicy = Resolve-OrchestrationRunPolicy `
        -RunDirectory $RunDirectory -Events $Events
    $event = [ordered]@{
        sequence = $Events.Count
        prev_hash = [string]$Events[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = $EventName
        run_id = [string]$Run.run_id
        plan_hash = [string]$Run.plan_hash
        workspace_root = [string]$Run.workspace_root
        policy_version = [string]$runPolicy.source_policy_version
        actor = [string]$Plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        milestone_id = [string]$Receipt.milestone_id
        milestone_activation_receipt_path = "receipts/$ReceiptName"
        milestone_activation_receipt_hash = [string]$Receipt.receipt_hash
        milestone_revision_id = [string]$Receipt.revision_id
        milestone_revision_authorization_receipt_path = if (
            $EventName -eq 'milestone-revision-authorized'
        ) {
            "receipts/$ReceiptName"
        } else {
            [string]$Receipt.authorization_receipt_path
        }
        milestone_revision_authorization_receipt_hash = if (
            $EventName -eq 'milestone-revision-authorized'
        ) {
            [string]$Receipt.receipt_hash
        } else {
            [string]$Receipt.authorization_receipt_hash
        }
        milestone_revision_checkpoint_hash =
            [string]$Receipt.checkpoint_material_hash
        milestone_revision_input_hash = [string]$Receipt.input_manifest_hash
        milestone_revision_selection_key = [string]$Receipt.selection_key
        message = $Message
        thread_id = $null
        model_id = $null
        artifact = "receipts/$ReceiptName"
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
        decision = $null
        human_actor = $null
        evidence = @("artifact:receipts/$ReceiptName")
        recovery_receipt_path = $null
        recovery_receipt_hash = $null
        replacement_receipt_path = $null
        replacement_receipt_hash = $null
        result_receipt_path = $null
        result_receipt_hash = $null
        idempotency_key = $IdempotencyKey
        request_fingerprint = [string]$Receipt.receipt_hash
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
    return [pscustomobject]$event
}

function Read-OrchestrationTaskReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Task completion receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $payload = [ordered]@{}
    $receiptKeys = @(
        'schema_version', 'run_id', 'plan_hash', 'journal_head', 'outcome',
        'completed_at_utc', 'summary', 'failure_class', 'fallback_action',
        'evidence'
    )
    if ([string]$receipt.schema_version -eq '1.1') {
        $receiptKeys += 'model_verification'
    } elseif ([string]$receipt.schema_version -ne '1.0') {
        throw "Unsupported task completion receipt schema '$($receipt.schema_version)'."
    }
    foreach ($name in $receiptKeys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Task completion receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Task completion receipt hash mismatch.'
    }
    $runPath = Join-Path $RunDirectory 'run.json'
    if (-not (Test-Path -LiteralPath $runPath -PathType Leaf)) {
        throw 'Task completion receipt run metadata is missing.'
    }
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    $state = & (Join-Path $PSScriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 100
    if ([string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.journal_head -ne [string]$state.journal_head) {
        throw 'Task completion receipt does not match the current run.'
    }
    if ([string]$receipt.outcome -eq 'completed') {
        $null = & (Join-Path $PSScriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $RunDirectory
    }
    return $receipt
}

function Read-OrchestrationJournal {
    param([Parameter(Mandatory)][string] $EventsPath)
    $fullEventsPath = [IO.Path]::GetFullPath($EventsPath)
    $context = $script:OrchestrationValidationContext
    if ($null -ne $context -and
        [string]$context.snapshot.journal_path -ceq $fullEventsPath -and
        -not [string]::IsNullOrWhiteSpace([string]$context.journal_json)) {
        return @(
            $context.journal_json |
                ConvertFrom-Json -Depth 100 -DateKind String
        )
    }
    $events = @(
        Get-Content -LiteralPath $EventsPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json -Depth 30 -DateKind String }
    )
    $previousHash = $null
    for ($index = 0; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if ([int]$event.sequence -ne $index) {
            throw "Journal sequence gap at index $index."
        }
        if ([string]$event.prev_hash -ne [string]$previousHash) {
            throw "Journal hash-chain break at sequence $index."
        }
        $expectedHash = Get-OrchestrationEventHash $event
        if ([string]$event.hash -ne $expectedHash) {
            throw "Journal event hash mismatch at sequence $index."
        }
        $previousHash = $event.hash
    }
    if ($null -ne $context -and
        [string]$context.snapshot.journal_path -ceq $fullEventsPath) {
        $currentHash = (
            Get-FileHash -LiteralPath $fullEventsPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($currentHash -ne [string]$context.snapshot.journal_hash -or
            $events.Count -ne [int]$context.snapshot.journal_event_count -or
            [string]$events[-1].hash -ne
                [string]$context.snapshot.journal_head) {
            throw 'Orchestration journal changed after validation context creation.'
        }
        $context.journal_json = ConvertTo-Json -InputObject @($events) `
            -Compress -Depth 100
    }
    return $events
}

function Get-ThreadCaptureId {
    param(
        [Parameter(Mandatory)][object] $Capture,
        [Parameter(Mandatory)][string] $CaptureKind
    )

    $ids = [Collections.Generic.List[string]]::new()
    $threadProperty = $Capture.PSObject.Properties['thread']
    if ($null -ne $threadProperty -and $null -ne $Capture.thread) {
        if ($null -ne $Capture.thread.PSObject.Properties['id']) {
            $ids.Add([string]$Capture.thread.id)
        }
        if ($null -ne $Capture.thread.PSObject.Properties['threadId']) {
            $ids.Add([string]$Capture.thread.threadId)
        }
    }
    if ($null -ne $Capture.PSObject.Properties['threadId']) {
        $ids.Add([string]$Capture.threadId)
    }
    if ($ids.Count -eq 0) {
        throw "$CaptureKind capture does not declare a thread identity."
    }
    if (@($ids | Where-Object {
        [string]::IsNullOrWhiteSpace($_)
    }).Count -gt 0) {
        throw "$CaptureKind capture contains an empty thread identity."
    }
    $first = [string]$ids[0]
    if (@($ids | Where-Object { [string]$_ -cne $first }).Count -gt 0) {
        throw "$CaptureKind capture declares conflicting thread identities."
    }
    return $first
}

function Get-TaskListRecordThreadId {
    param([Parameter(Mandatory)][object] $Thread)

    $ids = [Collections.Generic.List[string]]::new()
    foreach ($name in @('thread_id', 'id', 'threadId')) {
        $property = $Thread.PSObject.Properties[$name]
        if ($null -ne $property) {
            $ids.Add([string]$property.Value)
        }
    }
    if ($ids.Count -eq 0) {
        return ''
    }
    if (@($ids | Where-Object {
        [string]::IsNullOrWhiteSpace($_)
    }).Count -gt 0) {
        throw 'Task-list record contains an empty thread identity.'
    }
    $first = [string]$ids[0]
    if (@($ids | Where-Object { [string]$_ -cne $first }).Count -gt 0) {
        throw 'Task-list record declares conflicting thread identities.'
    }
    return $first
}

function Read-ThreadReadCapture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread-read capture does not exist: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $capture = $raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($null -eq $capture.PSObject.Properties['page'] -or
        [string]$capture.page.order -ne 'newest_first') {
        throw 'Thread-read capture must declare newest_first turn order.'
    }
    $captureThreadId = Get-ThreadCaptureId -Capture $capture `
        -CaptureKind 'Thread-read'
    if ($captureThreadId -cne $ExpectedThreadId) {
        throw 'Thread-read capture does not match the expected thread.'
    }
    $turns = @($capture.turns)
    if ($turns.Count -eq 0) {
        throw 'Thread-read capture has no turns.'
    }
    $finalTurn = $turns[0]
    if ([string]$finalTurn.status -ne 'completed') {
        throw 'Newest thread turn is not completed.'
    }
    $finalMessages = @($finalTurn.items | Where-Object {
        [string]$_.type -eq 'agentMessage' -and
        [string]$_.phase -eq 'final_answer' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.text)
    })
    if ($finalMessages.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$finalTurn.id)) {
        throw 'Completed thread turn lacks a final agent answer.'
    }
    $finalText = [string]$finalMessages[-1].text
    return [pscustomobject]@{
        final_turn_id = [string]$finalTurn.id
        final_content_hash = Get-TextSha256 $finalText
        capture_hash = Get-TextSha256 $raw
    }
}

function Read-ThreadMaterializationHandshakeCapture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Materialization handshake capture does not exist: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $capture = $raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($null -eq $capture.PSObject.Properties['page'] -or
        [string]$capture.page.order -ne 'newest_first') {
        throw 'Materialization handshake capture must declare newest_first turn order.'
    }
    $captureThreadId = Get-ThreadCaptureId -Capture $capture `
        -CaptureKind 'Materialization handshake'
    if ($captureThreadId -cne $ExpectedThreadId) {
        throw 'Materialization handshake capture does not match the expected thread.'
    }
    $turns = @($capture.turns)
    if ($turns.Count -eq 0 -or
        [string]$turns[0].status -ne 'completed' -or
        [string]::IsNullOrWhiteSpace([string]$turns[0].id)) {
        throw 'Materialization handshake capture lacks a completed newest turn.'
    }
    $finalMessages = @($turns[0].items | Where-Object {
        [string]$_.type -eq 'agentMessage' -and
        [string]$_.phase -eq 'final_answer'
    })
    if ($finalMessages.Count -ne 1 -or
        [string]$finalMessages[0].text -cne
            'MATERIALIZED_WAITING_FOR_CONTINUITY') {
        throw (
            'Materialization handshake capture lacks the exact waiting marker ' +
            'MATERIALIZED_WAITING_FOR_CONTINUITY.'
        )
    }
    return [pscustomobject]@{
        final_turn_id = [string]$turns[0].id
        capture_hash = Get-TextSha256 $raw
    }
}

function Read-ThreadResultReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $RunDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread result receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $required = @(
        'schema_version', 'thread_id', 'host_id', 'collection_method',
        'thread_read_path', 'thread_read_hash', 'final_turn_id',
        'final_status', 'final_content_hash',
        'adopted_findings', 'rejected_findings', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Thread result receipt is missing '$name'."
        }
    }
    if ([string]$receipt.thread_id -ne $ExpectedThreadId) {
        throw 'Thread result receipt does not match the materialized thread.'
    }
    if ([string]$receipt.final_status -ne 'completed' -or
        [string]$receipt.collection_method -ne 'read_thread') {
        throw 'Thread result receipt is not a completed supported collection.'
    }
    if ([string]$receipt.final_content_hash -notmatch '^[0-9a-f]{64}$' -or
        [string]$receipt.thread_read_hash -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$receipt.host_id) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.final_turn_id)) {
        throw 'Thread result receipt contains invalid identifiers or hash.'
    }
    $schemaVersion = [string]$receipt.schema_version
    if ($schemaVersion -notin @('1.1', '1.2', '1.3', '1.4', '1.5')) {
        throw 'Thread result receipt has an unsupported schema version.'
    }
    $hasSourceContract = $null -ne
        $receipt.PSObject.Properties['source_node_id']
    if ($schemaVersion -in @('1.3', '1.4', '1.5')) {
        foreach ($name in @(
            'source_node_id', 'source_kind',
            'replacement_continuity_receipt_path',
            'replacement_continuity_receipt_hash'
        )) {
            if ($null -eq $receipt.PSObject.Properties[$name]) {
                throw (
                    "Schema $schemaVersion thread result receipt is missing " +
                    "'$name'."
                )
            }
        }
        if ($schemaVersion -eq '1.4') {
            foreach ($name in @(
                'replacement_checkpoint_roll_forward_receipt_path',
                'replacement_checkpoint_roll_forward_receipt_hash'
            )) {
                if ($null -eq $receipt.PSObject.Properties[$name]) {
                    throw \"Schema 1.4 thread result receipt is missing '$name'.\"
                }
            }
        } elseif ($schemaVersion -eq '1.5') {
            foreach ($name in @(
                'source_role_id',
                'milestone_revision_authorization_receipt_path',
                'milestone_revision_authorization_receipt_hash',
                'milestone_revision_id',
                'milestone_revision_authorization_event_sequence',
                'milestone_revision_authorization_event_hash',
                'milestone_revision_rearm_event_sequence',
                'milestone_revision_rearm_event_hash',
                'milestone_revision_input_manifest_path',
                'milestone_revision_input_manifest_hash'
            )) {
                if ($null -eq $receipt.PSObject.Properties[$name]) {
                    throw "Schema 1.5 thread result receipt is missing '$name'."
                }
            }
        }
        $hasRollForwardFields = @(@(
            'replacement_checkpoint_roll_forward_receipt_path',
            'replacement_checkpoint_roll_forward_receipt_hash'
        ) | Where-Object {
                $null -ne $receipt.PSObject.Properties[$_]
            }
        ).Count -gt 0
        $hasRevisionFields = @(@(
            'source_role_id',
            'milestone_revision_authorization_receipt_path',
            'milestone_revision_authorization_receipt_hash',
            'milestone_revision_id',
            'milestone_revision_authorization_event_sequence',
            'milestone_revision_authorization_event_hash',
            'milestone_revision_rearm_event_sequence',
            'milestone_revision_rearm_event_hash',
            'milestone_revision_input_manifest_path',
            'milestone_revision_input_manifest_hash'
        ) | Where-Object {
                $null -ne $receipt.PSObject.Properties[$_]
            }
        ).Count -gt 0
        if (($schemaVersion -eq '1.5' -and $hasRollForwardFields) -or
            ($schemaVersion -ne '1.5' -and $hasRevisionFields)) {
            throw (
                'Thread result receipt mixes checkpoint roll-forward and ' +
                'milestone revision authority.'
            )
        }
        $plan = Get-Content -LiteralPath (
            Join-Path $RunDirectory 'plan.json'
        ) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
        $milestoneFields = @(
            'milestone_id', 'checkpoint_material_path',
            'checkpoint_material_hash'
        )
        $milestoneFieldCount = @($milestoneFields | Where-Object {
            $null -ne $receipt.PSObject.Properties[$_]
        }).Count
        if ($milestoneFieldCount -notin @(0, $milestoneFields.Count)) {
            throw 'Thread result receipt has a partial milestone binding.'
        }
        if ($milestoneFieldCount -eq $milestoneFields.Count) {
            $allMilestoneFieldsEmpty = @($milestoneFields | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$receipt.$_)
            }).Count -eq 0
            if (-not $allMilestoneFieldsEmpty) {
                if (@($milestoneFields | Where-Object {
                    [string]::IsNullOrWhiteSpace([string]$receipt.$_)
                }).Count -gt 0) {
                    throw 'Thread result receipt has an incomplete milestone binding.'
                }
                if ($null -eq $plan.PSObject.Properties[
                    'durable_review_profile'
                ] -or [string]$receipt.milestone_id -notin @(
                    $plan.durable_review_profile.milestone_ids
                )) {
                    throw (
                        'Thread result receipt milestone is not declared by ' +
                        'the plan.'
                    )
                }
                $checkpointPath = Get-RunLocalReceiptPath `
                    -RunDirectory $RunDirectory `
                    -RelativePath ([string]$receipt.checkpoint_material_path) `
                    -Label 'Checkpoint material'
                if (-not (
                    Test-Path -LiteralPath $checkpointPath -PathType Leaf
                ) -or [string]$receipt.checkpoint_material_hash -ne (
                    Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256
                ).Hash.ToLowerInvariant()) {
                    throw 'Thread result receipt checkpoint binding changed.'
                }
            }
        }
        $sourceNode = @($plan.nodes | Where-Object {
            [string]$_.id -eq [string]$receipt.source_node_id
        }) | Select-Object -First 1
        if ($null -eq $sourceNode -or
            [string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
            [string]$receipt.source_kind -notin @('original', 'replacement')) {
            throw 'Thread result receipt has an invalid logical source.'
        }
        $events = @(Read-OrchestrationJournal (
            Join-Path $RunDirectory 'events.jsonl'
        ))
        $replacementLifecycleEvent = @($events | Where-Object {
            [string]$_.node_id -eq [string]$receipt.source_node_id -and
            [string]$_.status -eq 'replacement_pending' -and
            [string]$_.thread_id -eq $ExpectedThreadId
        }) | Select-Object -Last 1
        if ([string]$receipt.source_kind -eq 'original') {
            if (-not [string]::IsNullOrWhiteSpace(
                [string]$receipt.replacement_continuity_receipt_path
            ) -or -not [string]::IsNullOrWhiteSpace(
                [string]$receipt.replacement_continuity_receipt_hash
            )) {
                throw 'Original result cannot claim replacement continuity.'
            }
            if ($null -ne $replacementLifecycleEvent) {
                throw (
                    'Replacement thread result cannot be accepted as an ' +
                    'original source result.'
                )
            }
        } else {
            $replacementPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath (
                    [string]$receipt.replacement_continuity_receipt_path
                ) -Label 'Replacement continuity receipt'
            $replacement = Read-ReplacementContinuityReceipt `
                -Path $replacementPath -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId ([string]$receipt.source_node_id) `
                -ExpectedReplacementThreadId $ExpectedThreadId
            if ([string]$replacement.receipt_hash -ne
                [string]$receipt.replacement_continuity_receipt_hash -or
                $null -eq $replacementLifecycleEvent -or
                [string]$replacementLifecycleEvent.replacement_receipt_hash -ne
                    [string]$replacement.receipt_hash) {
                throw (
                    'Replacement result is not bound to its continuity receipt.'
                )
            }
            if ($schemaVersion -eq '1.4') {
                $rollForwardPath = Get-RunLocalReceiptPath `
                    -RunDirectory $RunDirectory `
                    -RelativePath ([string]$receipt.
                        replacement_checkpoint_roll_forward_receipt_path) `
                    -Label 'Replacement checkpoint roll-forward receipt'
                $rollForward = Read-ReplacementCheckpointRollForwardReceipt `
                    -Path $rollForwardPath -RunDirectory $RunDirectory `
                    -ExpectedSourceNodeId ([string]$receipt.source_node_id) `
                    -ExpectedReplacementThreadId $ExpectedThreadId
                $rollForwardEvents = @($events | Where-Object {
                    $null -ne $_.PSObject.Properties[
                        'replacement_roll_forward_receipt_path'
                    ] -and
                    $null -ne $_.PSObject.Properties[
                        'replacement_roll_forward_receipt_hash'
                    ] -and
                    $null -ne $_.PSObject.Properties[
                        'replacement_roll_forward_id'
                    ] -and
                    [string]$_.node_id -eq
                        [string]$receipt.source_node_id -and
                    [string]$_.thread_id -eq $ExpectedThreadId -and
                    [string]$_.status -eq 'running' -and
                    [string]$_.replacement_roll_forward_receipt_path -eq
                        [string]$receipt.
                            replacement_checkpoint_roll_forward_receipt_path -and
                    [string]$_.replacement_roll_forward_receipt_hash -eq
                        [string]$rollForward.receipt_hash -and
                    [string]$_.replacement_roll_forward_id -eq
                        [string]$rollForward.roll_forward_id
                })
                if ([string]$receipt.
                        replacement_checkpoint_roll_forward_receipt_hash -ne
                        [string]$rollForward.receipt_hash -or
                    [string]$rollForward.
                        replacement_continuity_receipt_hash -ne
                        [string]$replacement.receipt_hash -or
                    [string]$rollForward.target_milestone_id -ne
                        [string]$receipt.milestone_id -or
                    [string]$rollForward.checkpoint_path -ne
                        [string]$receipt.checkpoint_material_path -or
                    $rollForwardEvents.Count -ne 1) {
                    throw (
                        'Replacement result is not bound to its unique ' +
                        'checkpoint roll-forward lifecycle.'
                    )
                }
            } elseif ($schemaVersion -eq '1.5') {
                $revisionBinding =
                    Get-ReplacementMilestoneRevisionResultBinding `
                        -RunDirectory $RunDirectory `
                        -SourceNodeId ([string]$receipt.source_node_id) `
                        -ThreadId $ExpectedThreadId `
                        -MilestoneId ([string]$receipt.milestone_id) `
                        -CheckpointMaterialPath (
                            [string]$receipt.checkpoint_material_path
                        ) -CheckpointMaterialHash (
                            [string]$receipt.checkpoint_material_hash
                        ) -ReplacementContinuity $replacement `
                        -ReplacementContinuityReceiptRelativePath (
                            [string]$receipt.
                                replacement_continuity_receipt_path
                        ) -AuthorizationReceiptRelativePath (
                            [string]$receipt.
                                milestone_revision_authorization_receipt_path
                        ) -Events $events
                if ([string]$receipt.source_role_id -ne
                        [string]$revisionBinding.source_role_id -or
                    [string]$receipt.
                        milestone_revision_authorization_receipt_hash -ne
                        [string]$revisionBinding.authorization_receipt_hash -or
                    [string]$receipt.milestone_revision_id -ne
                        [string]$revisionBinding.authorization.revision_id -or
                    [int]$receipt.
                        milestone_revision_authorization_event_sequence -ne
                        [int]$revisionBinding.authorization_event_sequence -or
                    [string]$receipt.
                        milestone_revision_authorization_event_hash -ne
                        [string]$revisionBinding.authorization_event_hash -or
                    [int]$receipt.milestone_revision_rearm_event_sequence -ne
                        [int]$revisionBinding.rearm_event_sequence -or
                    [string]$receipt.milestone_revision_rearm_event_hash -ne
                        [string]$revisionBinding.rearm_event_hash -or
                    [string]$receipt.milestone_revision_input_manifest_path -ne
                        [string]$revisionBinding.input_manifest_path -or
                    [string]$receipt.milestone_revision_input_manifest_hash -ne
                        [string]$revisionBinding.input_manifest_hash) {
                    throw (
                        'Replacement result milestone revision binding changed.'
                    )
                }
            } elseif (-not [string]::IsNullOrWhiteSpace(
                [string]$receipt.checkpoint_material_hash
            ) -and [string]$replacement.checkpoint_hash -ne
                [string]$receipt.checkpoint_material_hash) {
                throw (
                    'Replacement result at a new checkpoint requires schema ' +
                    '1.4 checkpoint roll-forward binding.'
                )
            }
        }
    } elseif ($hasSourceContract -and
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId) {
        throw 'Historical thread result receipt changed its logical source.'
    }
    $hasPending = $null -ne $receipt.PSObject.Properties['pending_findings']
    if ($schemaVersion -in @('1.2', '1.3', '1.4', '1.5') -and
        -not $hasPending) {
        throw "Thread result receipt is missing 'pending_findings'."
    }
    $pending = @()
    if ($hasPending) {
        $pending = @($receipt.pending_findings)
    }
    $allFindings = @(
        $pending + @($receipt.adopted_findings) + @($receipt.rejected_findings)
    )
    if ($allFindings.Count -eq 0) {
        throw 'Thread result receipt lacks an adoption disposition.'
    }
    if ($schemaVersion -in @('1.3', '1.4', '1.5')) {
        if (@($receipt.adopted_findings).Count -gt 0 -or
            @($receipt.rejected_findings).Count -gt 0) {
            throw (
                "Schema $schemaVersion source findings must remain pending " +
                'until disposition.'
            )
        }
        $seenFindingIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($finding in $pending) {
            foreach ($name in @(
                'finding_id', 'severity', 'text', 'text_hash'
            )) {
                if ($null -eq $finding.PSObject.Properties[$name]) {
                    throw "Schema $schemaVersion finding is missing '$name'."
                }
            }
            if ([string]$finding.finding_id -notmatch
                '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
                -not $seenFindingIds.Add([string]$finding.finding_id) -or
                [string]$finding.severity -notin @('P0', 'P1', 'P2') -or
                [string]::IsNullOrWhiteSpace([string]$finding.text) -or
                [string]$finding.text_hash -ne (
                    Get-TextSha256 ([string]$finding.text)
                )) {
                throw 'Schema 1.3 finding identity, severity, or text hash is invalid.'
            }
        }
    } elseif (@($allFindings | Select-Object -Unique).Count -ne
        $allFindings.Count) {
        throw 'Thread result receipt contains duplicate findings.'
    }
    $relativeCapture = [string]$receipt.thread_read_path
    $segments = $relativeCapture -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Thread result receipt has an unsafe capture path.'
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $capturePath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $relativeCapture)
    )
    if (-not $capturePath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Thread result capture escapes the run.'
    }
    $final = Read-ThreadReadCapture -Path $capturePath `
        -ExpectedThreadId $ExpectedThreadId
    if ($final.capture_hash -ne [string]$receipt.thread_read_hash -or
        $final.final_turn_id -ne [string]$receipt.final_turn_id -or
        $final.final_content_hash -ne [string]$receipt.final_content_hash) {
        throw 'Thread result receipt does not match its read-thread capture.'
    }
    $expectedHash = Get-ThreadResultReceiptCanonicalHash -Receipt $receipt
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Thread result receipt hash mismatch.'
    }
    return $receipt
}

function Read-ThreadProgressCapture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread progress capture does not exist: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $capture = $raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($null -eq $capture.PSObject.Properties['page'] -or
        [string]$capture.page.order -ne 'newest_first') {
        throw 'Thread progress capture must declare newest_first turn order.'
    }
    $captureThreadId = Get-ThreadCaptureId -Capture $capture `
        -CaptureKind 'Thread progress'
    if ($captureThreadId -cne $ExpectedThreadId) {
        throw 'Thread progress capture does not match the expected thread.'
    }
    $turns = @($capture.turns)
    if ($turns.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$turns[0].id)) {
        throw 'Thread progress capture has no identifiable turns.'
    }
    $finalMessages = @($turns | ForEach-Object {
        @($_.items) | Where-Object {
            [string]$_.type -eq 'agentMessage' -and
            [string]$_.phase -eq 'final_answer' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.text)
        }
    })
    if ($finalMessages.Count -gt 0) {
        throw 'Thread progress capture already contains a final agent answer.'
    }
    $progressItems = [Collections.Generic.List[object]]::new()
    foreach ($turn in $turns) {
        foreach ($item in @($turn.items)) {
            if ([string]$item.type -eq 'agentMessage' -and
                [string]$item.phase -eq 'final_answer') {
                continue
            }
            $itemText = if (
                $null -ne $item.PSObject.Properties['text']
            ) {
                [string]$item.text
            } else {
                $item | ConvertTo-Json -Compress -Depth 30
            }
            $progressItems.Add([ordered]@{
                turn_id = [string]$turn.id
                type = [string]$item.type
                phase = if ($null -ne $item.PSObject.Properties['phase']) {
                    [string]$item.phase
                } else { '' }
                content_hash = Get-TextSha256 $itemText
            })
        }
    }
    $latestAssistantState = 'unreported'
    $latestAssistantProperty = $capture.PSObject.Properties[
        'latestAssistantMessageId'
    ]
    if ($null -ne $latestAssistantProperty) {
        $latestAssistantState = if (
            [string]::IsNullOrWhiteSpace(
                [string]$latestAssistantProperty.Value
            )
        ) { 'missing' } else { 'present' }
    }
    return [pscustomobject]@{
        latest_turn_id = [string]$turns[0].id
        latest_turn_status = [string]$turns[0].status
        latest_assistant_message_id_state = $latestAssistantState
        capture_hash = Get-TextSha256 $raw
        progress_evidence_count = $progressItems.Count
        progress_evidence_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @($progressItems) -Compress -Depth 20
        )
    }
}

function Get-RunLocalReceiptPath {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string] $Label
    )
    $segments = $RelativePath -split '[\\/]'
    if ([IO.Path]::IsPathRooted($RelativePath) -or
        @($segments | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
        }).Count -gt 0) {
        throw "$Label has an unsafe path."
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $runRoot $RelativePath))
    if (-not $fullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label escapes the run."
    }
    return $fullPath
}

function Get-OriginalRecoveryCycleBinding {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $SourceNodeId,
        [Parameter(Mandatory)][string] $OriginalThreadId,
        [Parameter(Mandatory)][string] $CheckpointHash,
        [Parameter(Mandatory)][string] $InputManifestHash,
        [string] $MilestoneId,
        [AllowEmptyString()][string] $BoundMilestoneActivationReceiptPath,
        [AllowEmptyString()][string] $BoundMilestoneActivationReceiptHash
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $SourceNodeId
    }) | Select-Object -First 1
    if ($null -eq $node -or [string]$node.kind -ne 'agent' -or
        [string]$node.topology -ne 'background-thread') {
        throw 'Recovery cycle source must be a durable background-thread node.'
    }

    $activationPath = ''
    $activationHash = ''
    $activeMilestoneId = ''
    $hasBoundActivationPath = $PSBoundParameters.ContainsKey(
        'BoundMilestoneActivationReceiptPath'
    )
    $hasBoundActivationHash = $PSBoundParameters.ContainsKey(
        'BoundMilestoneActivationReceiptHash'
    )
    if ($hasBoundActivationPath -ne $hasBoundActivationHash) {
        throw 'Historical recovery activation binding is incomplete.'
    }
    $useBoundActivation = $hasBoundActivationPath
    if ($null -ne $plan.PSObject.Properties['durable_review_profile']) {
        $milestones = @(
            $plan.durable_review_profile.milestone_ids |
                ForEach-Object { [string]$_ }
        )
        if ($milestones.Count -lt 1 -or
            [string]::IsNullOrWhiteSpace($MilestoneId)) {
            throw 'Durable recovery requires its active MilestoneId.'
        }
        $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
        if ($useBoundActivation) {
            $activeMilestoneId = $MilestoneId
            $activationPath = $BoundMilestoneActivationReceiptPath.Replace(
                '\', '/'
            )
            $activationHash = $BoundMilestoneActivationReceiptHash
            if ($activeMilestoneId -notin $milestones) {
                throw 'Historical recovery milestone is not declared by the plan.'
            }
            if ([string]::IsNullOrWhiteSpace($activationPath)) {
                $expectedBaselineHash = Get-TextSha256 (
                    "baseline|$([string]$run.run_id)|$([string]$run.plan_hash)|" +
                    $milestones[0]
                )
                if ($activeMilestoneId -ne $milestones[0] -or
                    $activationHash -ne $expectedBaselineHash) {
                    throw 'Historical baseline recovery activation is invalid.'
                }
            } else {
                $activationEvents = @($events | Where-Object {
                    [string]$_.event -in @(
                        'milestone-activated', 'milestone-revision-authorized',
                        'milestone-revision-selected'
                    ) -and
                    [string]$_.milestone_id -eq $activeMilestoneId -and
                    [string]$_.milestone_activation_receipt_path -eq
                        $activationPath -and
                    [string]$_.milestone_activation_receipt_hash -eq
                        $activationHash
                })
                if ($activationEvents.Count -ne 1) {
                    throw (
                        'Historical recovery activation is missing or ambiguous ' +
                        'in the immutable journal.'
                    )
                }
                $activeEvent = $activationEvents[0]
                $activationFullPath = Get-RunLocalReceiptPath `
                    -RunDirectory $runRoot -RelativePath $activationPath `
                    -Label 'Historical milestone activation receipt'
                if (-not (Test-Path -LiteralPath $activationFullPath -PathType Leaf)) {
                    throw 'Historical milestone activation receipt is missing.'
                }
                $activation = switch ([string]$activeEvent.event) {
                    'milestone-revision-authorized' {
                        Read-DurableReviewMilestoneRevisionAuthorization `
                            -Path $activationFullPath -RunDirectory $runRoot
                    }
                    'milestone-revision-selected' {
                        Read-DurableReviewMilestoneRevisionSelection `
                            -Path $activationFullPath -RunDirectory $runRoot
                    }
                    default {
                        Get-Content -LiteralPath $activationFullPath -Raw |
                            ConvertFrom-Json -Depth 100 -DateKind String
                    }
                }
                $activationPayload = [ordered]@{}
                foreach ($property in $activation.PSObject.Properties) {
                    if ($property.Name -ne 'receipt_hash') {
                        $activationPayload[$property.Name] = $property.Value
                    }
                }
                if ([string]$activation.receipt_hash -ne $activationHash -or
                    (Get-TextSha256 (
                        $activationPayload | ConvertTo-Json -Compress -Depth 100
                    )) -ne $activationHash -or
                    [string]$activation.run_id -ne [string]$run.run_id -or
                    [string]$activation.plan_hash -ne [string]$run.plan_hash -or
                    [string]$activation.milestone_id -ne $activeMilestoneId) {
                    throw 'Historical milestone activation receipt binding is invalid.'
                }
            }
        } else {
            $activationEvents = @($events | Where-Object {
                [string]$_.event -in @(
                    'milestone-activated', 'milestone-revision-authorized',
                    'milestone-revision-selected'
                )
            })
            if ($activationEvents.Count -eq 0) {
                $activeMilestoneId = $milestones[0]
                $activationHash = Get-TextSha256 (
                    "baseline|$([string]$run.run_id)|$([string]$run.plan_hash)|" +
                    $activeMilestoneId
                )
            } else {
                $activeEvent = $activationEvents[-1]
                $activeMilestoneId = [string]$activeEvent.milestone_id
                $activationPath =
                    [string]$activeEvent.milestone_activation_receipt_path
                $activationHash =
                    [string]$activeEvent.milestone_activation_receipt_hash
                $activationFullPath = Get-RunLocalReceiptPath `
                    -RunDirectory $runRoot -RelativePath $activationPath `
                    -Label 'Milestone activation receipt'
                if (-not (
                    Test-Path -LiteralPath $activationFullPath -PathType Leaf
                )) {
                    throw 'Milestone activation receipt is missing.'
                }
                $activation = switch ([string]$activeEvent.event) {
                    'milestone-revision-authorized' {
                        Read-DurableReviewMilestoneRevisionAuthorization `
                            -Path $activationFullPath -RunDirectory $runRoot
                    }
                    'milestone-revision-selected' {
                        Read-DurableReviewMilestoneRevisionSelection `
                            -Path $activationFullPath -RunDirectory $runRoot
                    }
                    default {
                        Get-Content -LiteralPath $activationFullPath -Raw |
                            ConvertFrom-Json -Depth 100 -DateKind String
                    }
                }
                $activationPayload = [ordered]@{}
                foreach ($property in $activation.PSObject.Properties) {
                    if ($property.Name -ne 'receipt_hash') {
                        $activationPayload[$property.Name] = $property.Value
                    }
                }
                if ([string]$activation.receipt_hash -ne $activationHash -or
                    (Get-TextSha256 (
                        $activationPayload | ConvertTo-Json -Compress -Depth 100
                    )) -ne $activationHash -or
                    [string]$activation.milestone_id -ne $activeMilestoneId) {
                    throw 'Milestone activation receipt binding is invalid.'
                }
            }
            if ($MilestoneId -ne $activeMilestoneId -or
                $MilestoneId -notin $milestones) {
                throw 'Recovery cycle does not match the active durable milestone.'
            }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($MilestoneId)) {
        throw 'A non-durable-review run cannot declare a recovery milestone.'
    } else {
        $activationHash = Get-TextSha256 (
            "non-durable|$([string]$run.run_id)|$([string]$run.plan_hash)"
        )
        if ($useBoundActivation -and (
            -not [string]::IsNullOrWhiteSpace(
                $BoundMilestoneActivationReceiptPath
            ) -or
            $BoundMilestoneActivationReceiptHash -ne $activationHash
        )) {
            throw 'Historical non-durable recovery activation is invalid.'
        }
    }

    $cyclePayload = [ordered]@{
        run_id = [string]$run.run_id
        source_node_id = $SourceNodeId
        role_id = [string]$node.role_id
        original_thread_id = $OriginalThreadId
        continuity_key = [string]$node.context.continuity_key
        recovery_stage = 'original'
        milestone_id = $activeMilestoneId
        milestone_activation_receipt_hash = $activationHash
        checkpoint_hash = $CheckpointHash
        input_manifest_hash = $InputManifestHash
    }
    [pscustomobject]@{
        recovery_cycle_id = Get-TextSha256 (
            $cyclePayload | ConvertTo-Json -Compress -Depth 20
        )
        milestone_id = $activeMilestoneId
        milestone_activation_receipt_path = $activationPath
        milestone_activation_receipt_hash = $activationHash
    }
}

function Read-ThreadResultRecoveryReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedOriginalThreadId,
        [ValidateSet('original', 'replacement')]
        [string] $ExpectedRecoveryStage,
        [switch] $SkipPeerCycleCollisionCheck
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread result recovery receipt does not exist: $Path"
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $canonicalReceiptDirectory = [IO.Path]::GetFullPath(
        (Join-Path $runRoot 'receipts')
    ).TrimEnd('\', '/')
    $receiptFullPath = [IO.Path]::GetFullPath($Path)
    $receiptParent = (Split-Path -Parent $receiptFullPath).TrimEnd('\', '/')
    if (-not [string]::Equals(
        $receiptParent,
        $canonicalReceiptDirectory,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            'Thread result recovery receipt must remain in the canonical run ' +
            'receipts directory.'
        )
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'source_node_id', 'role_id',
        'original_thread_id', 'continuity_key', 'checkpoint_path',
        'checkpoint_hash', 'input_manifest_path', 'input_manifest_hash',
        'thread_read_path', 'thread_read_hash', 'progress_evidence_hash',
        'progress_evidence_count', 'latest_assistant_message_id_state',
        'evidence_source', 'legacy_adoption_receipt_path',
        'legacy_adoption_receipt_hash',
        'attempt', 'outcome', 'previous_receipt_path',
        'previous_receipt_hash', 'created_at_utc', 'receipt_hash'
    )
    $recoveryStage = if ([string]$receipt.schema_version -in @('1.1', '1.3')) {
        'replacement'
    } elseif ([string]$receipt.schema_version -in @('1.0', '1.2')) {
        'original'
    } else {
        throw 'Thread result recovery receipt has an unsupported schema.'
    }
    if ($recoveryStage -eq 'replacement') {
        $required += @(
            'recovery_stage', 'replacement_continuity_receipt_path',
            'replacement_continuity_receipt_hash'
        )
        if ([string]$receipt.schema_version -eq '1.3') {
            $required += @(
                'recovery_cycle_id', 'milestone_id',
                'replacement_checkpoint_roll_forward_receipt_path',
                'replacement_checkpoint_roll_forward_receipt_hash'
            )
        }
    } elseif ([string]$receipt.schema_version -eq '1.2') {
        $required += @(
            'recovery_stage', 'recovery_cycle_id', 'milestone_id',
            'milestone_activation_receipt_path',
            'milestone_activation_receipt_hash'
        )
    }
    $payload = [ordered]@{}
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Thread result recovery receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
        [string]$receipt.original_thread_id -ne $ExpectedOriginalThreadId) {
        throw 'Thread result recovery receipt does not match its source.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRecoveryStage) -and
        $recoveryStage -ne $ExpectedRecoveryStage) {
        throw 'Thread result recovery receipt does not match its recovery stage.'
    }
    if ($recoveryStage -eq 'replacement') {
        if ([string]$receipt.recovery_stage -ne 'replacement') {
            throw 'Replacement recovery receipt has an invalid stage.'
        }
        $replacementPath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.replacement_continuity_receipt_path) `
            -Label 'Replacement continuity receipt'
        $replacement = Read-ReplacementContinuityReceipt -Path $replacementPath `
            -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $ExpectedSourceNodeId `
            -ExpectedReplacementThreadId $ExpectedOriginalThreadId
        if ([string]$replacement.receipt_hash -ne
            [string]$receipt.replacement_continuity_receipt_hash) {
            throw 'Replacement recovery changed its continuity receipt.'
        }
        if ([string]$receipt.schema_version -eq '1.3') {
            $rollForwardPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath ([string]$receipt.
                    replacement_checkpoint_roll_forward_receipt_path) `
                -Label 'Replacement checkpoint roll-forward receipt'
            $rollForward = Read-ReplacementCheckpointRollForwardReceipt `
                -Path $rollForwardPath -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId $ExpectedSourceNodeId `
                -ExpectedReplacementThreadId $ExpectedOriginalThreadId
            $cyclePayload = [ordered]@{
                run_id = [string]$receipt.run_id
                source_node_id = $ExpectedSourceNodeId
                replacement_thread_id = $ExpectedOriginalThreadId
                replacement_continuity_receipt_hash =
                    [string]$replacement.receipt_hash
                replacement_checkpoint_roll_forward_receipt_hash =
                    [string]$rollForward.receipt_hash
                milestone_id = [string]$rollForward.target_milestone_id
                checkpoint_hash = [string]$receipt.checkpoint_hash
                input_manifest_hash = [string]$receipt.input_manifest_hash
            }
            $expectedCycleId = Get-TextSha256 (
                $cyclePayload | ConvertTo-Json -Compress -Depth 20
            )
            if ([string]$receipt.
                    replacement_checkpoint_roll_forward_receipt_hash -ne
                    [string]$rollForward.receipt_hash -or
                [string]$rollForward.
                    replacement_continuity_receipt_hash -ne
                    [string]$replacement.receipt_hash -or
                [string]$rollForward.target_milestone_id -ne
                    [string]$receipt.milestone_id -or
                [string]$rollForward.checkpoint_hash -ne
                    [string]$receipt.checkpoint_hash -or
                [string]$rollForward.input_manifest_hash -ne
                    [string]$receipt.input_manifest_hash -or
                [string]$receipt.recovery_cycle_id -ne $expectedCycleId) {
                throw (
                    'Replacement recovery cycle changed its checkpoint ' +
                    'roll-forward binding.'
                )
            }
            $expectedReplacementCycleName = (
                "$ExpectedSourceNodeId.replacement-cycle-$expectedCycleId." +
                "attempt-$([int]$receipt.attempt).result-recovery.json"
            )
            if ([IO.Path]::GetFileName($receiptFullPath) -ne
                $expectedReplacementCycleName) {
                throw (
                    'Replacement recovery cycle receipt has a non-canonical ' +
                    'filename.'
                )
            }
        } elseif ([string]$replacement.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$replacement.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Replacement recovery changed its continuity receipt.'
        }
    } elseif ([string]$receipt.schema_version -eq '1.2') {
        if ([string]$receipt.recovery_stage -ne 'original') {
            throw 'Original recovery cycle receipt has an invalid stage.'
        }
        $cycle = Get-OriginalRecoveryCycleBinding `
            -RunDirectory $RunDirectory -SourceNodeId $ExpectedSourceNodeId `
            -OriginalThreadId $ExpectedOriginalThreadId `
            -CheckpointHash ([string]$receipt.checkpoint_hash) `
            -InputManifestHash ([string]$receipt.input_manifest_hash) `
            -MilestoneId ([string]$receipt.milestone_id) `
            -BoundMilestoneActivationReceiptPath (
                [string]$receipt.milestone_activation_receipt_path
            ) -BoundMilestoneActivationReceiptHash (
                [string]$receipt.milestone_activation_receipt_hash
            )
        if ([string]$receipt.recovery_cycle_id -ne
                [string]$cycle.recovery_cycle_id -or
            [string]$receipt.milestone_activation_receipt_path -ne
                [string]$cycle.milestone_activation_receipt_path -or
            [string]$receipt.milestone_activation_receipt_hash -ne
                [string]$cycle.milestone_activation_receipt_hash) {
            throw 'Original recovery cycle binding is invalid.'
        }
        $expectedCycleName = (
            "$ExpectedSourceNodeId.cycle-$([string]$receipt.recovery_cycle_id)." +
            "attempt-$([int]$receipt.attempt).result-recovery.json"
        )
        if ([IO.Path]::GetFileName([IO.Path]::GetFullPath($Path)) -ne
            $expectedCycleName) {
            throw 'Original recovery cycle receipt has a non-canonical filename.'
        }
    }
    $run = Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    $plan = Get-Content -LiteralPath (Join-Path $RunDirectory 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $ExpectedSourceNodeId
    }) | Select-Object -First 1
    if ($null -eq $node -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.role_id -ne [string]$node.role_id -or
        [string]$receipt.continuity_key -ne
            [string]$node.context.continuity_key) {
        throw 'Thread result recovery receipt changed source role or continuity.'
    }
    foreach ($binding in @(
        @('checkpoint_path', 'checkpoint_hash', 'Checkpoint manifest'),
        @('input_manifest_path', 'input_manifest_hash', 'Input manifest')
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.($binding[0])) `
            -Label ([string]$binding[2])
        $boundHash = Get-TextSha256 (
            Get-Content -LiteralPath $boundPath -Raw
        )
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            $boundHash -ne [string]$receipt.($binding[1])) {
            throw "$($binding[2]) is missing or changed."
        }
    }
    $attempt = [int]$receipt.attempt
    if ([string]$receipt.evidence_source -eq 'platform-read-capture') {
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$receipt.legacy_adoption_receipt_path
        ) -or -not [string]::IsNullOrWhiteSpace(
            [string]$receipt.legacy_adoption_receipt_hash
        )) {
            throw 'Platform recovery cannot claim a legacy adoption receipt.'
        }
        $capturePath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.thread_read_path) `
            -Label 'Thread progress capture'
        $capture = Read-ThreadProgressCapture -Path $capturePath `
            -ExpectedThreadId $ExpectedOriginalThreadId
        if ($capture.capture_hash -ne [string]$receipt.thread_read_hash -or
            $capture.progress_evidence_hash -ne
                [string]$receipt.progress_evidence_hash -or
            [int]$capture.progress_evidence_count -ne
                [int]$receipt.progress_evidence_count -or
            [string]$capture.latest_assistant_message_id_state -ne
                [string]$receipt.latest_assistant_message_id_state) {
            throw 'Thread result recovery receipt does not match progress evidence.'
        }
    } elseif ([string]$receipt.evidence_source -eq 'legacy-adoption') {
        $legacyPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.legacy_adoption_receipt_path) `
            -Label 'Legacy source adoption receipt'
        $legacy = Read-LegacySourceAdoptionReceipt -Path $legacyPath `
            -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $ExpectedSourceNodeId `
            -ExpectedOriginalThreadId $ExpectedOriginalThreadId
        if ([string]$legacy.receipt_hash -ne
            [string]$receipt.legacy_adoption_receipt_hash -or
            [string]$legacy.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$legacy.input_material_hash -ne
                [string]$receipt.input_manifest_hash -or
            [string]$legacy.turn_evidence_path -ne
                [string]$receipt.thread_read_path -or
            [string]$legacy.turn_evidence_hash -ne
                [string]$receipt.thread_read_hash) {
            throw 'Legacy recovery does not match its adoption receipt.'
        }
        $turnEvidencePath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory `
            -RelativePath ([string]$legacy.turn_evidence_path) `
            -Label 'Legacy turn evidence'
        $turnEvidence = @(
            Get-Content -LiteralPath $turnEvidencePath -Raw |
                ConvertFrom-Json -Depth 30 -DateKind String
        )
        $selectedTurn = $turnEvidence[$attempt]
        $progressHash = Get-TextSha256 (
            ConvertTo-Json -InputObject @(
                $selectedTurn.progress_evidence
            ) -Compress -Depth 20
        )
        $progressCount = @($selectedTurn.progress_evidence).Count
        if ([string]$selectedTurn.final_state -ne 'missing' -or
            [string]$selectedTurn.status -ne 'completed' -or
            [string]$selectedTurn.error_state -ne 'null' -or
            [string]$receipt.progress_evidence_hash -ne $progressHash -or
            [int]$receipt.progress_evidence_count -ne $progressCount -or
            [string]$receipt.latest_assistant_message_id_state -ne 'missing') {
            throw 'Legacy recovery turn evidence is invalid.'
        }
    } else {
        throw 'Thread result recovery receipt has an invalid evidence source.'
    }
    if ($attempt -lt 1 -or $attempt -gt 3 -or
        [string]$receipt.latest_assistant_message_id_state -eq 'present' -or
        [string]$receipt.outcome -notin @(
            'result-pending', 'recovery-exhausted'
        ) -or
        ($attempt -lt 3 -and
            [string]$receipt.outcome -ne 'result-pending') -or
        ($attempt -eq 3 -and
            [string]$receipt.outcome -ne 'recovery-exhausted')) {
        throw 'Thread result recovery receipt has an invalid bounded outcome.'
    }
    if ($attempt -eq 1) {
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$receipt.previous_receipt_path
        ) -or -not [string]::IsNullOrWhiteSpace(
            [string]$receipt.previous_receipt_hash
        )) {
            throw 'First recovery receipt cannot declare a previous receipt.'
        }
    } else {
        $previousPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.previous_receipt_path) `
            -Label 'Previous recovery receipt'
        $previous = Read-ThreadResultRecoveryReceipt -Path $previousPath `
            -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $ExpectedSourceNodeId `
            -ExpectedOriginalThreadId $ExpectedOriginalThreadId `
            -ExpectedRecoveryStage $recoveryStage `
            -SkipPeerCycleCollisionCheck:$SkipPeerCycleCollisionCheck
        if ([int]$previous.attempt -ne ($attempt - 1) -or
            [string]$previous.receipt_hash -ne
                [string]$receipt.previous_receipt_hash -or
            [string]$previous.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$previous.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Thread result recovery receipt chain is invalid.'
        }
        if ([string]$receipt.schema_version -eq '1.2' -and (
            [string]$previous.schema_version -ne '1.2' -or
            [string]$previous.recovery_cycle_id -ne
                [string]$receipt.recovery_cycle_id -or
            [string]$previous.milestone_id -ne
                [string]$receipt.milestone_id -or
            [string]$previous.milestone_activation_receipt_hash -ne
                [string]$receipt.milestone_activation_receipt_hash
        )) {
            throw 'Thread result recovery receipt crossed recovery cycles.'
        }
        if ([string]$receipt.schema_version -eq '1.3' -and (
            [string]$previous.schema_version -ne '1.3' -or
            [string]$previous.recovery_cycle_id -ne
                [string]$receipt.recovery_cycle_id -or
            [string]$previous.milestone_id -ne
                [string]$receipt.milestone_id -or
            [string]$previous.
                replacement_checkpoint_roll_forward_receipt_hash -ne
                [string]$receipt.
                    replacement_checkpoint_roll_forward_receipt_hash
        )) {
            throw 'Thread result recovery receipt crossed replacement cycles.'
        }
    }
    $hashPayload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $hashPayload[$property.Name] = $property.Value
        }
    }
    $expectedHash = Get-TextSha256 (
        $hashPayload | ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Thread result recovery receipt hash mismatch.'
    }
    if ([string]$receipt.schema_version -eq '1.2' -and
        -not $SkipPeerCycleCollisionCheck) {
        $peerStarts = @(
            Get-ChildItem -LiteralPath $canonicalReceiptDirectory -File `
                -Filter (
                    "$ExpectedSourceNodeId.cycle-*.attempt-1.result-recovery.json"
                ) -ErrorAction SilentlyContinue | Where-Object {
                    [IO.Path]::GetFullPath($_.FullName) -ne $receiptFullPath
                }
        )
        foreach ($peerStart in $peerStarts) {
            $peerHeader = Get-Content -LiteralPath $peerStart.FullName -Raw |
                ConvertFrom-Json -Depth 20 -DateKind String
            if ([string]$peerHeader.source_node_id -ne $ExpectedSourceNodeId -or
                [string]$peerHeader.original_thread_id -ne
                    $ExpectedOriginalThreadId -or
                [string]$peerHeader.checkpoint_hash -ne
                    [string]$receipt.checkpoint_hash) {
                continue
            }
            $peer = Read-ThreadResultRecoveryReceipt `
                -Path $peerStart.FullName -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId $ExpectedSourceNodeId `
                -ExpectedOriginalThreadId $ExpectedOriginalThreadId `
                -ExpectedRecoveryStage original `
                -SkipPeerCycleCollisionCheck
            if ([string]$peer.checkpoint_hash -eq
                    [string]$receipt.checkpoint_hash -and
                [string]$peer.recovery_cycle_id -ne
                    [string]$receipt.recovery_cycle_id) {
                throw (
                    'An original recovery cycle already binds this source, ' +
                    'thread, and checkpoint with different input or milestone ' +
                    'identity.'
                )
            }
        }
    }
    return $receipt
}

function Read-LegacySourceAdoptionReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedOriginalThreadId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Legacy source adoption receipt does not exist: $Path"
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $canonicalReceiptDirectory = [IO.Path]::GetFullPath(
        (Join-Path $runRoot 'receipts')
    ).TrimEnd('\', '/')
    $receiptFullPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals(
        (Split-Path -Parent $receiptFullPath).TrimEnd('\', '/'),
        $canonicalReceiptDirectory,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Legacy adoption receipt must use the canonical run receipts directory.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'source_node_id', 'role_id',
        'original_thread_id', 'role_material_path', 'role_contract_hash',
        'checkpoint_material_path', 'checkpoint_hash',
        'input_material_path', 'input_material_hash',
        'turn_evidence_path', 'turn_evidence_hash', 'turn_ids',
        'unknown_fields', 'authorization_material_path',
        'authorization_material_hash', 'activation_key', 'outcome',
        'created_at_utc', 'receipt_hash'
    )
    $payload = [ordered]@{}
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Legacy source adoption receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
        [string]$receipt.original_thread_id -ne $ExpectedOriginalThreadId -or
        [string]$receipt.source_node_id -eq
            [string]$receipt.original_thread_id -or
        [string]$receipt.outcome -ne 'replacement-eligible') {
        throw 'Legacy source adoption does not match its assigned source.'
    }
    $run = Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    $plan = Get-Content -LiteralPath (Join-Path $RunDirectory 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $ExpectedSourceNodeId
    }) | Select-Object -First 1
    if ($null -eq $node -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.role_id -ne [string]$node.role_id -or
        -not [bool]$node.read_only -or
        [bool]$node.allow_delegation -or
        @($node.write_scope).Count -gt 0 -or
        [string]$receipt.activation_key -notmatch
            '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        throw 'Legacy source adoption changed assigned role or activation.'
    }
    foreach ($binding in @(
        @('role_material_path', 'role_contract_hash', 'Role material'),
        @(
            'checkpoint_material_path',
            'checkpoint_hash',
            'Checkpoint material'
        ),
        @('input_material_path', 'input_material_hash', 'Input material'),
        @('turn_evidence_path', 'turn_evidence_hash', 'Turn evidence'),
        @(
            'authorization_material_path',
            'authorization_material_hash',
            'Authorization material'
        )
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.($binding[0])) `
            -Label ([string]$binding[2])
        $boundHash = Get-TextSha256 (
            Get-Content -LiteralPath $boundPath -Raw
        )
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            $boundHash -ne [string]$receipt.($binding[1])) {
            throw "$($binding[2]) is missing or changed."
        }
    }
    $requiredUnknowns = @(
        'machine_source_node_id', 'machine_role_id', 'original_input_hash',
        'immutable_read_capture_hash'
    )
    $unknowns = @($receipt.unknown_fields | ForEach-Object { [string]$_ })
    if (@($requiredUnknowns | Where-Object { $_ -notin $unknowns }).Count -gt 0) {
        throw 'Legacy source adoption must preserve all unknown machine fields.'
    }
    $turnEvidencePath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
        -RelativePath ([string]$receipt.turn_evidence_path) `
        -Label 'Turn evidence'
    $turnEvidence = @(
        Get-Content -LiteralPath $turnEvidencePath -Raw |
            ConvertFrom-Json -Depth 30 -DateKind String
    )
    if ($turnEvidence.Count -ne 4 -or
        @($turnEvidence.turn_id | Select-Object -Unique).Count -ne 4) {
        throw 'Legacy adoption requires exactly four unique turn records.'
    }
    foreach ($turn in $turnEvidence) {
        foreach ($name in @(
            'turn_id', 'status', 'error_state', 'final_state',
            'progress_evidence'
        )) {
            if ($null -eq $turn.PSObject.Properties[$name]) {
                throw "Legacy turn evidence is missing '$name'."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$turn.turn_id) -or
            [string]$turn.status -ne 'completed' -or
            [string]$turn.error_state -ne 'null' -or
            [string]$turn.final_state -ne 'missing') {
            throw 'Legacy turn evidence does not prove completed/no-final state.'
        }
    }
    if ((@($receipt.turn_ids) -join "`n") -ne
        (@($turnEvidence.turn_id) -join "`n")) {
        throw 'Legacy source adoption turn IDs do not match captured evidence.'
    }
    $duplicates = @(
        Get-ChildItem -LiteralPath $canonicalReceiptDirectory `
            -Filter '*.legacy-source-adoption.json' -File |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -Depth 30 -DateKind String
            } | Where-Object {
                [string]$_.original_thread_id -eq
                    [string]$receipt.original_thread_id -and
                [string]$_.checkpoint_hash -eq
                    [string]$receipt.checkpoint_hash -and
                [string]$_.role_contract_hash -eq
                    [string]$receipt.role_contract_hash
            }
    )
    if ($duplicates.Count -ne 1) {
        throw 'Legacy source identity may be adopted exactly once.'
    }
    $hashPayload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $hashPayload[$property.Name] = $property.Value
        }
    }
    $expectedHash = Get-TextSha256 (
        $hashPayload | ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Legacy source adoption receipt hash mismatch.'
    }
    return $receipt
}

function Read-ReplacementContinuityReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedReplacementThreadId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Replacement continuity receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'source_node_id', 'role_id',
        'original_thread_id', 'replacement_thread_id', 'continuity_key',
        'checkpoint_path', 'checkpoint_hash', 'input_manifest_path',
        'input_manifest_hash', 'recovery_receipt_paths',
        'recovery_receipt_hashes', 'recovery_chain_hash',
        'role_contract_hash', 'authorization_material_path',
        'authorization_material_hash', 'activation_key',
        'legacy_adoption_receipt_path', 'legacy_adoption_receipt_hash',
        'created_at_utc', 'receipt_hash'
    )
    $payload = [ordered]@{}
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Replacement continuity receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
        [string]$receipt.replacement_thread_id -ne
            $ExpectedReplacementThreadId -or
        [string]$receipt.original_thread_id -eq
            [string]$receipt.replacement_thread_id) {
        throw 'Replacement continuity receipt does not match its source.'
    }
    $run = Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    $plan = Get-Content -LiteralPath (Join-Path $RunDirectory 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $ExpectedSourceNodeId
    }) | Select-Object -First 1
    $role = if ($null -eq $node) { $null } else {
        @($plan.roles | Where-Object {
            [string]$_.id -eq [string]$node.role_id
        }) | Select-Object -First 1
    }
    $planRoleHash = if ($null -eq $role) { '' } else {
        Get-TextSha256 ($role | ConvertTo-Json -Compress -Depth 50)
    }
    if ($null -eq $node -or $null -eq $role -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.role_id -ne [string]$node.role_id -or
        [string]$receipt.continuity_key -ne
            [string]$node.context.continuity_key -or
        -not [bool]$node.read_only -or
        [bool]$node.allow_delegation -or
        @($node.write_scope).Count -gt 0 -or
        [string]$receipt.activation_key -notmatch
            '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        throw 'Replacement continuity changed role, scope, or activation.'
    }
    foreach ($binding in @(
        @('checkpoint_path', 'checkpoint_hash', 'Checkpoint manifest'),
        @('input_manifest_path', 'input_manifest_hash', 'Input manifest'),
        @(
            'authorization_material_path',
            'authorization_material_hash',
            'Authorization material'
        )
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$receipt.($binding[0])) `
            -Label ([string]$binding[2])
        $boundHash = Get-TextSha256 (
            Get-Content -LiteralPath $boundPath -Raw
        )
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            $boundHash -ne [string]$receipt.($binding[1])) {
            throw "$($binding[2]) is missing or changed."
        }
    }
    $recoveryPaths = @($receipt.recovery_receipt_paths)
    $recoveryHashes = @($receipt.recovery_receipt_hashes)
    if ($recoveryPaths.Count -ne 3 -or $recoveryHashes.Count -ne 3) {
        throw 'Replacement requires the complete three-attempt recovery chain.'
    }
    $verifiedHashes = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $recoveryPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath ([string]$recoveryPaths[$index]) `
            -Label 'Recovery chain receipt'
        $recovery = Read-ThreadResultRecoveryReceipt -Path $recoveryPath `
            -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $ExpectedSourceNodeId `
            -ExpectedOriginalThreadId ([string]$receipt.original_thread_id) `
            -SkipPeerCycleCollisionCheck
        if ([int]$recovery.attempt -ne ($index + 1) -or
            [string]$recovery.receipt_hash -ne
                [string]$recoveryHashes[$index] -or
            [string]$recovery.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$recovery.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Replacement recovery chain changed source or checkpoint.'
        }
        $verifiedHashes.Add([string]$recovery.receipt_hash)
    }
    # The peer-cycle collision scan is identical for all three receipts. Run it
    # once from attempt 1 instead of recursively repeating it for every attempt.
    $firstRecoveryPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
        -RelativePath ([string]$recoveryPaths[0]) `
        -Label 'Recovery chain first receipt'
    $null = Read-ThreadResultRecoveryReceipt -Path $firstRecoveryPath `
        -RunDirectory $RunDirectory `
        -ExpectedSourceNodeId $ExpectedSourceNodeId `
        -ExpectedOriginalThreadId ([string]$receipt.original_thread_id) `
        -ExpectedRecoveryStage original
    if ([string]$receipt.recovery_chain_hash -ne
        (Get-TextSha256 (@($verifiedHashes) -join "`n"))) {
        throw 'Replacement recovery chain hash mismatch.'
    }
    $legacyPath = [string]$receipt.legacy_adoption_receipt_path
    $legacyHash = [string]$receipt.legacy_adoption_receipt_hash
    if ([string]::IsNullOrWhiteSpace($legacyPath) -ne
        [string]::IsNullOrWhiteSpace($legacyHash)) {
        throw 'Legacy adoption path and hash must be supplied together.'
    }
    if (-not [string]::IsNullOrWhiteSpace($legacyPath)) {
        $legacyFullPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath $legacyPath -Label 'Legacy source adoption receipt'
        $legacy = Read-LegacySourceAdoptionReceipt -Path $legacyFullPath `
            -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $ExpectedSourceNodeId `
            -ExpectedOriginalThreadId ([string]$receipt.original_thread_id)
        if ([string]$legacy.receipt_hash -ne $legacyHash -or
            [string]$legacy.role_contract_hash -ne
                [string]$receipt.role_contract_hash -or
            [string]$legacy.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$legacy.input_material_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Replacement does not match its legacy source adoption.'
        }
        $expectedRoleHash = [string]$legacy.role_contract_hash
    } else {
        $expectedRoleHash = $planRoleHash
    }
    if ([string]$receipt.role_contract_hash -ne $expectedRoleHash) {
        throw 'Replacement continuity role contract hash mismatch.'
    }
    $hashPayload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $hashPayload[$property.Name] = $property.Value
        }
    }
    $expectedHash = Get-TextSha256 (
        $hashPayload | ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Replacement continuity receipt hash mismatch.'
    }
    return $receipt
}

function Read-ReplacementCheckpointRollForwardReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedReplacementThreadId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Replacement checkpoint roll-forward receipt does not exist: $Path"
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $canonicalReceiptDirectory = [IO.Path]::GetFullPath(
        (Join-Path $runRoot 'receipts')
    ).TrimEnd('\', '/')
    $receiptFullPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals(
        (Split-Path -Parent $receiptFullPath).TrimEnd('\', '/'),
        $canonicalReceiptDirectory,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            'Replacement checkpoint roll-forward receipt must use the ' +
            'canonical run receipts directory.'
        )
    }
    $receipt = Get-Content -LiteralPath $receiptFullPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'source_node_id', 'role_id',
        'source_kind', 'replacement_thread_id', 'continuity_key',
        'replacement_continuity_receipt_path',
        'replacement_continuity_receipt_hash',
        'replacement_pending_event_sequence',
        'replacement_pending_event_hash', 'actual_model_state',
        'actual_model_id', 'actual_model_evidence_hash',
        'previous_result_receipt_path', 'previous_result_receipt_hash',
        'previous_result_file_hash', 'previous_disposition_receipt_path',
        'previous_disposition_receipt_hash',
        'previous_disposition_file_hash', 'previous_adopted_event_sequence',
        'previous_adopted_event_hash', 'previous_checkpoint_hash',
        'active_milestone_id', 'active_milestone_activation_receipt_path',
        'active_milestone_activation_receipt_hash', 'target_milestone_id',
        'checkpoint_path', 'checkpoint_hash', 'input_manifest_path',
        'input_manifest_hash', 'authorization_material_path',
        'authorization_material_hash', 'activation_key', 'roll_forward_id',
        'created_at_utc', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw (
                "Replacement checkpoint roll-forward receipt is missing '$name'."
            )
        }
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.source_kind -ne 'replacement' -or
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
        [string]$receipt.replacement_thread_id -ne
            $ExpectedReplacementThreadId) {
        throw (
            'Replacement checkpoint roll-forward does not match its logical ' +
            'source or replacement thread.'
        )
    }
    $expectedName = (
        "$ExpectedSourceNodeId.replacement-roll-forward-" +
        "$([string]$receipt.roll_forward_id).json"
    )
    if ([IO.Path]::GetFileName($receiptFullPath) -ne $expectedName) {
        throw 'Replacement checkpoint roll-forward filename is non-canonical.'
    }
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $ExpectedSourceNodeId
    }) | Select-Object -First 1
    if ($null -eq $node -or
        [string]$node.kind -ne 'agent' -or
        [string]$node.topology -ne 'background-thread' -or
        -not [bool]$node.read_only -or [bool]$node.allow_delegation -or
        @($node.write_scope).Count -gt 0 -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.role_id -ne [string]$node.role_id -or
        [string]$receipt.continuity_key -ne
            [string]$node.context.continuity_key -or
        [string]$receipt.activation_key -notmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw (
            'Replacement checkpoint roll-forward changed source role, ' +
            'permissions, or activation identity.'
        )
    }

    if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
        throw 'Replacement checkpoint roll-forward requires durable_review_profile.'
    }
    $milestones = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    $activeIndex = [Array]::IndexOf(
        $milestones, [string]$receipt.active_milestone_id
    )
    if ($activeIndex -lt 0 -or $activeIndex + 1 -ge $milestones.Count -or
        [string]$receipt.target_milestone_id -ne
            [string]$milestones[$activeIndex + 1]) {
        throw (
            'Replacement checkpoint roll-forward must target the immediately ' +
            'next declared durable milestone.'
        )
    }

    foreach ($binding in @(
        @('checkpoint_path', 'checkpoint_hash', 'Checkpoint manifest'),
        @('input_manifest_path', 'input_manifest_hash', 'Input manifest'),
        @(
            'authorization_material_path', 'authorization_material_hash',
            'Authorization material'
        )
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$receipt.($binding[0])) `
            -Label ([string]$binding[2])
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            (Get-TextSha256 (
                Get-Content -LiteralPath $boundPath -Raw
            )) -ne [string]$receipt.($binding[1])) {
            throw "$($binding[2]) is missing or changed."
        }
    }
    if ([string]$receipt.checkpoint_hash -eq
        [string]$receipt.previous_checkpoint_hash) {
        throw 'Replacement checkpoint roll-forward requires a new checkpoint.'
    }

    $continuityPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath (
            [string]$receipt.replacement_continuity_receipt_path
        ) -Label 'Replacement continuity receipt'
    $continuity = Read-ReplacementContinuityReceipt `
        -Path $continuityPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $ExpectedSourceNodeId `
        -ExpectedReplacementThreadId $ExpectedReplacementThreadId
    if ([string]$continuity.receipt_hash -ne
        [string]$receipt.replacement_continuity_receipt_hash) {
        throw 'Replacement checkpoint roll-forward changed parent continuity.'
    }

    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    $replacementPendingEvents = @($events | Where-Object {
        [string]$_.node_id -eq $ExpectedSourceNodeId -and
        [string]$_.status -eq 'replacement_pending' -and
        [string]$_.thread_id -eq $ExpectedReplacementThreadId -and
        [string]$_.replacement_receipt_hash -eq
            [string]$continuity.receipt_hash
    })
    if ($replacementPendingEvents.Count -ne 1) {
        throw (
            'Replacement checkpoint roll-forward has no unique materialized ' +
            'replacement lifecycle.'
        )
    }
    $replacementPending = $replacementPendingEvents[0]
    $replacementModelVerificationState = if (
        $null -ne $replacementPending.PSObject.Properties[
            'model_verification_state'
        ]
    ) {
        [string]$replacementPending.model_verification_state
    } else { '' }
    $actualModelState = if (-not [string]::IsNullOrWhiteSpace(
        [string]$replacementPending.model_id
    )) {
        'verified'
    } elseif (
        $replacementModelVerificationState -eq 'unverified' -or
        @($replacementPending.evidence | Where-Object {
            [string]$_ -match 'actual-model.*unverified|did-not-expose-actual-model'
        }).Count -gt 0
    ) {
        'unverified'
    } else {
        throw (
            'Replacement lifecycle does not honestly identify the actual model ' +
            'as verified or unverified.'
        )
    }
    $actualModelId = if ($actualModelState -eq 'verified') {
        [string]$replacementPending.model_id
    } else { '' }
    $actualModelEvidenceHash = Get-TextSha256 (
        @($replacementPending.evidence) |
            ConvertTo-Json -Compress -Depth 20
    )
    if ([int]$receipt.replacement_pending_event_sequence -ne
            [int]$replacementPending.sequence -or
        [string]$receipt.replacement_pending_event_hash -ne
            [string]$replacementPending.hash -or
        [string]$receipt.actual_model_state -ne $actualModelState -or
        [string]$receipt.actual_model_id -ne $actualModelId -or
        [string]$receipt.actual_model_evidence_hash -ne
            $actualModelEvidenceHash) {
        throw (
            'Replacement checkpoint roll-forward changed materialization or ' +
            'actual-model evidence.'
        )
    }

    $previousResultPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.previous_result_receipt_path) `
        -Label 'Previous replacement result receipt'
    $previousResult = Read-ThreadResultReceipt -Path $previousResultPath `
        -ExpectedThreadId $ExpectedReplacementThreadId `
        -ExpectedSourceNodeId $ExpectedSourceNodeId -RunDirectory $runRoot
    $previousCheckpointPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot `
        -RelativePath ([string]$previousResult.checkpoint_material_path) `
        -Label 'Previous replacement checkpoint material'
    $previousCheckpointHash = Get-TextSha256 (
        Get-Content -LiteralPath $previousCheckpointPath -Raw
    )
    $previousDispositionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.previous_disposition_receipt_path) `
        -Label 'Previous replacement disposition receipt'
    $previousDisposition = Read-ReviewDispositionReceipt `
        -Path $previousDispositionPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $ExpectedSourceNodeId `
        -ExpectedThreadId $ExpectedReplacementThreadId
    if ([string]$previousResult.source_kind -ne 'replacement' -or
        [string]$previousResult.replacement_continuity_receipt_hash -ne
            [string]$continuity.receipt_hash -or
        [string]$previousResult.milestone_id -ne
            [string]$receipt.target_milestone_id -or
        $previousCheckpointHash -ne
            [string]$receipt.previous_checkpoint_hash -or
        [string]$previousResult.receipt_hash -ne
            [string]$receipt.previous_result_receipt_hash -or
        (Get-FileHash -LiteralPath $previousResultPath -Algorithm SHA256).
            Hash.ToLowerInvariant() -ne
            [string]$receipt.previous_result_file_hash -or
        [string]$previousDisposition.source_result_receipt_hash -ne
            [string]$previousResult.receipt_hash -or
        [string]$previousDisposition.receipt_hash -ne
            [string]$receipt.previous_disposition_receipt_hash -or
        (Get-FileHash -LiteralPath $previousDispositionPath -Algorithm SHA256).
            Hash.ToLowerInvariant() -ne
            [string]$receipt.previous_disposition_file_hash) {
        throw (
            'Replacement checkpoint roll-forward changed the prior verified ' +
            'result or disposition.'
        )
    }
    $sourceHistory = @($events | Where-Object {
        [string]$_.node_id -eq $ExpectedSourceNodeId -and
        [int]$_.sequence -le [int]$receipt.previous_adopted_event_sequence
    })
    if ($sourceHistory.Count -lt 3) {
        throw 'Replacement checkpoint roll-forward lacks a prior adopted chain.'
    }
    $adoptedEvent = $sourceHistory[-1]
    $validatedEvent = $sourceHistory[-2]
    $completedEvent = $sourceHistory[-3]
    $resultPointer = (
        'artifact:' + [string]$receipt.previous_result_receipt_path
    )
    $dispositionPointer = (
        'artifact:' + [string]$receipt.previous_disposition_receipt_path
    )
    if ([string]$completedEvent.status -ne 'completed' -or
        [string]$validatedEvent.status -ne 'validated' -or
        [string]$adoptedEvent.status -ne 'adopted' -or
        [string]$completedEvent.thread_id -ne $ExpectedReplacementThreadId -or
        [string]$validatedEvent.thread_id -ne $ExpectedReplacementThreadId -or
        [string]$adoptedEvent.thread_id -ne $ExpectedReplacementThreadId -or
        $resultPointer -notin @($completedEvent.evidence) -or
        $dispositionPointer -notin @($validatedEvent.evidence) -or
        $dispositionPointer -notin @($adoptedEvent.evidence) -or
        [int]$receipt.previous_adopted_event_sequence -ne
            [int]$adoptedEvent.sequence -or
        [string]$receipt.previous_adopted_event_hash -ne
            [string]$adoptedEvent.hash) {
        throw (
            'Replacement checkpoint roll-forward does not match the terminal ' +
            'adopted replacement result chain.'
        )
    }

    $activationPath = [string](
        $receipt.active_milestone_activation_receipt_path
    )
    $activationHash = [string](
        $receipt.active_milestone_activation_receipt_hash
    )
    if ([string]::IsNullOrWhiteSpace($activationPath)) {
        $baselineHash = Get-TextSha256 (
            "baseline|$([string]$run.run_id)|$([string]$run.plan_hash)|" +
            [string]$receipt.active_milestone_id
        )
        if ($activeIndex -ne 0 -or $activationHash -ne $baselineHash) {
            throw 'Replacement checkpoint roll-forward baseline binding is invalid.'
        }
    } else {
        $activationEvents = @($events | Where-Object {
            [string]$_.event -in @(
                'milestone-activated', 'milestone-revision-selected'
            ) -and
            [string]$_.milestone_id -eq
                [string]$receipt.active_milestone_id -and
            [string]$_.milestone_activation_receipt_path -eq $activationPath -and
            [string]$_.milestone_activation_receipt_hash -eq $activationHash
        })
        if ($activationEvents.Count -ne 1) {
            throw (
                'Replacement checkpoint roll-forward active milestone binding ' +
                'is missing or ambiguous.'
            )
        }
        $activationFullPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot -RelativePath $activationPath `
            -Label 'Active milestone activation receipt'
        $activation = Get-Content -LiteralPath $activationFullPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        $activationPayload = [ordered]@{}
        foreach ($property in $activation.PSObject.Properties) {
            if ($property.Name -ne 'receipt_hash') {
                $activationPayload[$property.Name] = $property.Value
            }
        }
        if ([string]$activation.receipt_hash -ne $activationHash -or
            (Get-TextSha256 (
                $activationPayload | ConvertTo-Json -Compress -Depth 100
            )) -ne $activationHash -or
            [string]$activation.run_id -ne [string]$run.run_id -or
            [string]$activation.plan_hash -ne [string]$run.plan_hash -or
            [string]$activation.milestone_id -ne
                [string]$receipt.active_milestone_id) {
            throw (
                'Replacement checkpoint roll-forward active milestone receipt ' +
                'binding is invalid.'
            )
        }
    }

    $identityPayload = [ordered]@{
        run_id = [string]$receipt.run_id
        plan_hash = [string]$receipt.plan_hash
        source_node_id = [string]$receipt.source_node_id
        role_id = [string]$receipt.role_id
        replacement_thread_id = [string]$receipt.replacement_thread_id
        replacement_continuity_receipt_hash = [string](
            $receipt.replacement_continuity_receipt_hash
        )
        previous_adopted_event_hash = [string](
            $receipt.previous_adopted_event_hash
        )
        active_milestone_id = [string]$receipt.active_milestone_id
        active_milestone_activation_receipt_hash = $activationHash
        target_milestone_id = [string]$receipt.target_milestone_id
        checkpoint_hash = [string]$receipt.checkpoint_hash
        input_manifest_hash = [string]$receipt.input_manifest_hash
        authorization_material_hash = [string](
            $receipt.authorization_material_hash
        )
        activation_key = [string]$receipt.activation_key
    }
    if ([string]$receipt.roll_forward_id -ne (Get-TextSha256 (
        $identityPayload | ConvertTo-Json -Compress -Depth 30
    ))) {
        throw 'Replacement checkpoint roll-forward identity hash mismatch.'
    }
    $hashPayload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $hashPayload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (Get-TextSha256 (
        $hashPayload | ConvertTo-Json -Compress -Depth 100
    ))) {
        throw 'Replacement checkpoint roll-forward receipt hash mismatch.'
    }
    $duplicates = @(
        Get-ChildItem -LiteralPath $canonicalReceiptDirectory -File `
            -Filter "$ExpectedSourceNodeId.replacement-roll-forward-*.json" `
            -ErrorAction SilentlyContinue | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -Depth 100 -DateKind String
            } | Where-Object {
                [string]$_.run_id -eq [string]$receipt.run_id -and
                [string]$_.source_node_id -eq $ExpectedSourceNodeId -and
                [string]$_.replacement_thread_id -eq
                    $ExpectedReplacementThreadId -and
                [string]$_.active_milestone_activation_receipt_hash -eq
                    $activationHash -and
                [string]$_.target_milestone_id -eq
                    [string]$receipt.target_milestone_id
            }
    )
    if ($duplicates.Count -ne 1) {
        throw (
            'Replacement seat already has a checkpoint roll-forward for this ' +
            'next milestone, or its authorization forked.'
        )
    }
    return $receipt
}

function Read-ReviewDispositionReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedThreadId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Review disposition receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'milestone_id', 'source_node_id',
        'source_thread_id', 'source_result_receipt_path',
        'source_result_receipt_hash', 'decisions', 'blocking_open',
        'created_at_utc', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Review disposition receipt is missing '$name'."
        }
    }
    $runPath = Join-Path $RunDirectory 'run.json'
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    if ([string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId -or
        [string]$receipt.source_thread_id -ne $ExpectedThreadId) {
        throw 'Review disposition receipt does not match the current run or source node.'
    }

    $relativeSource = [string]$receipt.source_result_receipt_path
    $segments = $relativeSource -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Review disposition receipt has an unsafe source receipt path.'
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $runRoot $relativeSource))
    if (-not $sourcePath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Review disposition source receipt escapes the run.'
    }
    $source = Read-ThreadResultReceipt -Path $sourcePath `
        -ExpectedThreadId $ExpectedThreadId `
        -ExpectedSourceNodeId $ExpectedSourceNodeId `
        -RunDirectory $RunDirectory
    if ([string]$source.schema_version -notin @('1.3', '1.4', '1.5')) {
        throw (
            'Durable review completion requires a schema 1.3, 1.4, or 1.5 ' +
            'source receipt ' +
            'with stable finding identity and severity.'
        )
    }
    if ([string]$source.receipt_hash -ne
        [string]$receipt.source_result_receipt_hash) {
        throw 'Review disposition receipt is not bound to its source result receipt.'
    }
    if ($null -ne $source.PSObject.Properties['milestone_id'] -and
        -not [string]::IsNullOrWhiteSpace([string]$source.milestone_id) -and
        [string]$source.milestone_id -ne [string]$receipt.milestone_id) {
        throw 'Review disposition milestone does not match its source result.'
    }

    $sourceFindings = @($source.pending_findings)
    $sourceById = @{}
    foreach ($sourceFinding in $sourceFindings) {
        $sourceFindingId = [string]$sourceFinding.finding_id
        if ($sourceById.ContainsKey($sourceFindingId)) {
            throw 'Source result receipt contains duplicate finding IDs.'
        }
        $sourceById[$sourceFindingId] = $sourceFinding
    }
    $decisions = @($receipt.decisions)
    if ($decisions.Count -ne $sourceById.Count) {
        throw 'Review disposition receipt must answer every source finding exactly once.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $computedBlocking = [Collections.Generic.List[string]]::new()
    foreach ($decision in $decisions) {
        foreach ($name in @(
            'source_finding_id', 'finding', 'finding_hash',
            'canonical_finding_id', 'severity', 'disposition', 'rationale',
            'resolution_status', 'evidence', 're_review_status',
            're_review_source_node_id', 're_review_evidence'
        )) {
            if ($null -eq $decision.PSObject.Properties[$name]) {
                throw "Review decision is missing '$name'."
            }
        }
        $sourceFindingId = [string]$decision.source_finding_id
        if (-not $seen.Add($sourceFindingId) -or
            -not $sourceById.ContainsKey($sourceFindingId)) {
            throw 'Review disposition contains a duplicate or unknown finding.'
        }
        $sourceFinding = $sourceById[$sourceFindingId]
        $finding = [string]$decision.finding
        if ($finding -ne [string]$sourceFinding.text -or
            [string]$decision.finding_hash -ne
                [string]$sourceFinding.text_hash -or
            [string]$decision.severity -ne
                [string]$sourceFinding.severity) {
            throw (
                'Review disposition identity, text hash, and severity must ' +
                'exactly match source.'
            )
        }
        $canonicalFindingId = [string]$decision.canonical_finding_id
        if ($canonicalFindingId -notmatch
            '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
            throw (
                'Review disposition requires a stable canonical_finding_id. ' +
                'Multiple source occurrences may share one canonical identity.'
            )
        }
        if ([string]$decision.severity -notin @('P0', 'P1', 'P2') -or
            [string]$decision.disposition -notin @(
                'adopted', 'partially-adopted', 'rejected', 'deferred'
            ) -or
            [string]$decision.resolution_status -notin @('open', 'resolved') -or
            [string]::IsNullOrWhiteSpace([string]$decision.rationale)) {
            throw 'Review disposition contains an invalid decision contract.'
        }
        $evidence = @($decision.evidence)
        if ($evidence.Count -eq 0 -or @($evidence | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_)
        }).Count -gt 0) {
            throw 'Every review decision requires non-empty evidence.'
        }
        if ([string]$decision.resolution_status -eq 'resolved' -and
            @($evidence | Where-Object {
                [string]$_ -match '^(test|artifact|source|observation):.+'
            }).Count -eq 0) {
            throw 'A resolved review decision requires typed resolution evidence.'
        }
        $reReviewStatus = [string]$decision.re_review_status
        $reReviewSourceNodeId = [string]$decision.re_review_source_node_id
        $reReviewEvidence = @($decision.re_review_evidence)
        if ($reReviewStatus -notin @(
            'not-required', 'requested', 'completed'
        )) {
            throw 'Review disposition contains an invalid re_review_status.'
        }
        if ($reReviewSourceNodeId -ne $ExpectedSourceNodeId) {
            throw 'Re-review is not bound to the original source node.'
        }
        if ($reReviewStatus -eq 'completed' -and
            @($reReviewEvidence | Where-Object {
                [string]$_ -match '^(test|artifact|source|observation):.+'
            }).Count -eq 0) {
            throw 'Completed re-review requires typed evidence.'
        }
        if ([string]$decision.severity -in @('P0', 'P1') -and
            [string]$decision.disposition -in @(
                'adopted', 'partially-adopted'
            ) -and
            [string]$decision.resolution_status -eq 'resolved' -and
            $reReviewStatus -ne 'completed') {
            throw 'Resolved adopted P0/P1 findings require completed re-review.'
        }
        if ([string]$decision.severity -in @('P0', 'P1') -and
            [string]$decision.resolution_status -ne 'resolved') {
            $computedBlocking.Add($finding)
        }
    }
    $declaredBlocking = @($receipt.blocking_open | ForEach-Object {
        [string]$_
    })
    if (($declaredBlocking -join "`n") -ne
        (@($computedBlocking) -join "`n")) {
        throw 'Review disposition blocking_open does not match unresolved P0/P1 findings.'
    }
    $payload = [ordered]@{
        schema_version = [string]$receipt.schema_version
        run_id = [string]$receipt.run_id
        milestone_id = [string]$receipt.milestone_id
        source_node_id = [string]$receipt.source_node_id
        source_thread_id = [string]$receipt.source_thread_id
        source_result_receipt_path = $relativeSource
        source_result_receipt_hash = [string]$receipt.source_result_receipt_hash
        decisions = $decisions
        blocking_open = $declaredBlocking
        created_at_utc = [string]$receipt.created_at_utc
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Review disposition receipt hash mismatch.'
    }
    return $receipt
}

function Get-DurableReviewDispositionBinding {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Plan,
        [Parameter(Mandatory)][string] $SourceNodeId,
        [Parameter(Mandatory)][string] $DispositionRelativePath,
        [Parameter(Mandatory)][string] $ExpectedMilestoneId,
        [switch] $AllowHistoricalMilestoneAlias,
        [switch] $RequireResultMilestoneBinding
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $validationToken = Enter-OrchestrationValidationContext -RunDirectory $runRoot
    $validationSucceeded = $false
    try {
    $dispositionPath = Get-RunLocalReceiptPath `
        -RunDirectory $RunDirectory -RelativePath $DispositionRelativePath `
        -Label 'Review disposition receipt'
    $cacheDescriptor = Get-OrchestrationValidatedObjectCacheDescriptor `
        -Kind 'durable-review-disposition-binding' -Path $dispositionPath `
        -RunDirectory $runRoot -Expectation (
            $SourceNodeId + '|' + $DispositionRelativePath + '|' +
            $ExpectedMilestoneId + '|' +
            ([bool]$AllowHistoricalMilestoneAlias).ToString() + '|' +
            ([bool]$RequireResultMilestoneBinding).ToString()
        )
    $cached = Get-OrchestrationValidatedObjectCacheValue `
        -Descriptor $cacheDescriptor
    if ($null -ne $cached) {
        return $cached
    }
    if (-not (Test-Path -LiteralPath $dispositionPath -PathType Leaf)) {
        throw "Review disposition receipt does not exist: $DispositionRelativePath"
    }
    $rawDisposition = Get-Content -LiteralPath $dispositionPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $sourceThreadId = [string]$rawDisposition.source_thread_id
    if ([string]::IsNullOrWhiteSpace($sourceThreadId)) {
        throw 'Review disposition receipt lacks a source thread.'
    }
    $disposition = Read-ReviewDispositionReceipt -Path $dispositionPath `
        -RunDirectory $RunDirectory -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedThreadId $sourceThreadId
    if (-not $AllowHistoricalMilestoneAlias -and
        [string]$disposition.milestone_id -ne $ExpectedMilestoneId) {
        throw (
            "Review disposition for '$SourceNodeId' does not match milestone " +
            "'$ExpectedMilestoneId'."
        )
    }
    $resultRelativePath = [string]$disposition.source_result_receipt_path
    $resultPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
        -RelativePath $resultRelativePath -Label 'Thread result receipt'
    # The disposition reader already validated the complete source result and
    # its recovery/replacement chain. Verify the same hash-bound receipt here
    # without recursively walking that graph a second time.
    $result = Get-Content -LiteralPath $resultPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$result.receipt_hash -ne
            [string]$disposition.source_result_receipt_hash -or
        [string]$result.receipt_hash -ne (
            Get-ThreadResultReceiptCanonicalHash -Receipt $result
        ) -or
        [string]$result.thread_id -ne $sourceThreadId -or
        [string]$result.source_node_id -ne $SourceNodeId) {
        throw 'Thread result receipt changed after disposition validation.'
    }

    $checkpointPath = ''
    $checkpointHash = ''
    if ($RequireResultMilestoneBinding) {
        foreach ($name in @(
            'milestone_id', 'checkpoint_material_path',
            'checkpoint_material_hash'
        )) {
            if ($null -eq $result.PSObject.Properties[$name] -or
                [string]::IsNullOrWhiteSpace([string]$result.$name)) {
                throw (
                    "Current milestone result for '$SourceNodeId' lacks its " +
                    'milestone or checkpoint binding.'
                )
            }
        }
        if ([string]$result.milestone_id -ne $ExpectedMilestoneId) {
            throw (
                "Current result for '$SourceNodeId' is bound to another " +
                'milestone.'
            )
        }
        $checkpointPath = [string]$result.checkpoint_material_path
        $checkpointHash = [string]$result.checkpoint_material_hash
    } elseif (-not $AllowHistoricalMilestoneAlias -and
        $null -ne $result.PSObject.Properties['milestone_id'] -and
        -not [string]::IsNullOrWhiteSpace([string]$result.milestone_id)) {
        if ([string]$result.milestone_id -ne $ExpectedMilestoneId) {
            throw (
                "Historical result for '$SourceNodeId' is bound to another " +
                'milestone.'
            )
        }
        $checkpointPath = [string]$result.checkpoint_material_path
        $checkpointHash = [string]$result.checkpoint_material_hash
    }

    $binding = [pscustomobject][ordered]@{
        source_node_id = $SourceNodeId
        source_thread_id = $sourceThreadId
        milestone_id = $ExpectedMilestoneId
        checkpoint_material_path = $checkpointPath
        checkpoint_material_hash = $checkpointHash
        result_receipt_path = $resultRelativePath.Replace('\', '/')
        result_receipt_hash = [string]$result.receipt_hash
        result_file_hash = (
            Get-FileHash -LiteralPath $resultPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        disposition_receipt_path = $DispositionRelativePath.Replace('\', '/')
        disposition_receipt_hash = [string]$disposition.receipt_hash
        disposition_file_hash = (
            Get-FileHash -LiteralPath $dispositionPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    Set-OrchestrationValidatedObjectCacheValue -Descriptor $cacheDescriptor `
        -Value $binding
    $validationSucceeded = $true
    return $binding
    } finally {
        Exit-OrchestrationValidationContext -Token $validationToken `
            -ValidateSnapshot:$validationSucceeded
    }
}

function Get-DurableReviewRevisionSourceContinuityBinding {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $RequiredSource,
        [Parameter(Mandatory)][object] $DispositionBinding,
        [Parameter(Mandatory)][object] $Authorization,
        [Parameter(Mandatory)][string] $AuthorizationReceiptRelativePath,
        [Parameter(Mandatory)][object[]] $Events,
        [Parameter(Mandatory)][int] $AuthorizationEventSequence,
        [Parameter(Mandatory)][int] $RearmEventSequence
    )

    $sourceNodeId = [string]$RequiredSource.source_node_id
    $roleId = [string]$RequiredSource.role_id
    $authorizedThreadId = [string]$RequiredSource.thread_id
    $selectedThreadId = [string]$DispositionBinding.source_thread_id
    $resultPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
        -RelativePath ([string]$DispositionBinding.result_receipt_path) `
        -Label 'Milestone revision thread result receipt'
    # Get-DurableReviewDispositionBinding immediately validated this result and
    # its continuity chain. Read the same hash-bound object here instead of
    # recursively running the expensive receipt graph a second time.
    $result = Get-Content -LiteralPath $resultPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$result.receipt_hash -ne
            [string]$DispositionBinding.result_receipt_hash -or
        [string]$result.thread_id -ne $selectedThreadId -or
        [string]$result.source_node_id -ne $sourceNodeId) {
        throw "Milestone revision source '$sourceNodeId' result changed."
    }
    $sourceKind = [string]$result.source_kind
    if ($sourceKind -eq 'original') {
        if ($selectedThreadId -ne $authorizedThreadId) {
            throw (
                "Milestone revision source '$sourceNodeId' changed thread " +
                'without replacement continuity.'
            )
        }
        return [pscustomobject][ordered]@{
            source_node_id = $sourceNodeId
            role_id = $roleId
            source_kind = 'original'
            authorized_thread_id = $authorizedThreadId
            source_thread_id = $selectedThreadId
            recovery_cycle_id = ''
            recovery_event_bindings = @()
            replacement_continuity_receipt_path = ''
            replacement_continuity_receipt_hash = ''
            replacement_pending_event_sequence = 0
            replacement_pending_event_hash = ''
            replacement_running_event_sequence = 0
            replacement_running_event_hash = ''
            lifecycle_start_sequence = $RearmEventSequence
        }
    }
    if ($sourceKind -eq 'replacement' -and
        $selectedThreadId -eq $authorizedThreadId) {
        if ([string]$result.schema_version -ne '1.5') {
            throw (
                "Milestone revision source '$sourceNodeId' reused a " +
                'replacement thread without its consecutive revision binding.'
            )
        }
        $continuityRelativePath = [string](
            $result.replacement_continuity_receipt_path
        )
        $continuityPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath $continuityRelativePath `
            -Label 'Milestone revision replacement continuity receipt'
        $continuity = Read-ReplacementContinuityReceipt `
            -Path $continuityPath -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedReplacementThreadId $selectedThreadId
        $revisionBinding =
            Get-ReplacementMilestoneRevisionResultBinding `
                -RunDirectory $RunDirectory -SourceNodeId $sourceNodeId `
                -ThreadId $selectedThreadId `
                -MilestoneId ([string]$Authorization.milestone_id) `
                -CheckpointMaterialPath (
                    [string]$Authorization.checkpoint_material_path
                ) -CheckpointMaterialHash (
                    [string]$Authorization.checkpoint_material_hash
                ) -ReplacementContinuity $continuity `
                -ReplacementContinuityReceiptRelativePath (
                    $continuityRelativePath
                ) -AuthorizationReceiptRelativePath (
                    $AuthorizationReceiptRelativePath
                ) -Events $Events
        if ([string]$result.source_role_id -ne $roleId -or
            [string]$result.replacement_continuity_receipt_hash -ne
                [string]$continuity.receipt_hash -or
            [string]$result.milestone_revision_authorization_receipt_path -ne
                $AuthorizationReceiptRelativePath -or
            [string]$result.milestone_revision_authorization_receipt_hash -ne
                [string]$Authorization.receipt_hash -or
            [string]$result.milestone_revision_id -ne
                [string]$Authorization.revision_id -or
            [int]$result.milestone_revision_authorization_event_sequence -ne
                [int]$revisionBinding.authorization_event_sequence -or
            [string]$result.milestone_revision_authorization_event_hash -ne
                [string]$revisionBinding.authorization_event_hash -or
            [int]$result.milestone_revision_rearm_event_sequence -ne
                [int]$revisionBinding.rearm_event_sequence -or
            [string]$result.milestone_revision_rearm_event_hash -ne
                [string]$revisionBinding.rearm_event_hash -or
            [int]$revisionBinding.rearm_event_sequence -ne $RearmEventSequence -or
            [string]$result.milestone_revision_input_manifest_path -ne
                [string]$Authorization.input_manifest_path -or
            [string]$result.milestone_revision_input_manifest_hash -ne
                [string]$Authorization.input_manifest_hash) {
            throw (
                "Milestone revision source '$sourceNodeId' consecutive " +
                'replacement result binding changed.'
            )
        }
        $pendingMatches = @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [string]$_.thread_id -eq $selectedThreadId -and
            [string]$_.status -eq 'replacement_pending' -and
            [string]$_.replacement_receipt_path -eq $continuityRelativePath -and
            [string]$_.replacement_receipt_hash -eq
                [string]$continuity.receipt_hash -and
            [int]$_.sequence -lt $AuthorizationEventSequence
        })
        if ($pendingMatches.Count -ne 1) {
            throw (
                "Milestone revision source '$sourceNodeId' parent replacement " +
                'pending event changed.'
            )
        }
        $replacementPending = $pendingMatches[0]
        $continuityArtifact =
            "artifact:replacement-continuity:$continuityRelativePath"
        $continuityObservation = (
            'observation:replacement-continuity-hash:' +
            [string]$continuity.receipt_hash
        )
        $runningMatches = @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [string]$_.thread_id -eq $selectedThreadId -and
            [string]$_.prior_state -eq 'replacement_pending' -and
            [string]$_.status -eq 'running' -and
            [int]$_.sequence -gt [int]$replacementPending.sequence -and
            [int]$_.sequence -lt $AuthorizationEventSequence -and
            $continuityArtifact -in @($_.evidence) -and
            $continuityObservation -in @($_.evidence)
        })
        if ($runningMatches.Count -ne 1) {
            throw (
                "Milestone revision source '$sourceNodeId' parent replacement " +
                'running event changed.'
            )
        }
        return [pscustomobject][ordered]@{
            source_node_id = $sourceNodeId
            role_id = $roleId
            source_kind = 'replacement'
            authorized_thread_id = $authorizedThreadId
            source_thread_id = $selectedThreadId
            recovery_cycle_id = ''
            recovery_event_bindings = @()
            replacement_continuity_receipt_path = $continuityRelativePath
            replacement_continuity_receipt_hash = [string]$continuity.receipt_hash
            replacement_pending_event_sequence =
                [int]$replacementPending.sequence
            replacement_pending_event_hash = [string]$replacementPending.hash
            replacement_running_event_sequence =
                [int]$runningMatches[0].sequence
            replacement_running_event_hash = [string]$runningMatches[0].hash
            lifecycle_start_sequence = $RearmEventSequence
        }
    }
    if ($sourceKind -ne 'replacement') {
        throw "Milestone revision source '$sourceNodeId' has invalid continuity."
    }

    # A replacement may replace the revision-authorized original exactly once.
    # A thread that was itself introduced as a replacement cannot be replaced
    # again through this narrow selection bridge.
    if (@($Events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.status -eq 'replacement_pending' -and
        [string]$_.thread_id -eq $authorizedThreadId
    }).Count -gt 0) {
        throw (
            "Milestone revision source '$sourceNodeId' cannot create a " +
            'replacement of a replacement.'
        )
    }

    $continuityRelativePath = [string](
        $result.replacement_continuity_receipt_path
    )
    $continuityPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
        -RelativePath $continuityRelativePath `
        -Label 'Milestone revision replacement continuity receipt'
    $continuity = Get-Content -LiteralPath $continuityPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$continuity.receipt_hash -ne
            [string]$result.replacement_continuity_receipt_hash -or
        [string]$continuity.original_thread_id -ne $authorizedThreadId -or
        [string]$continuity.replacement_thread_id -ne $selectedThreadId -or
        [string]$continuity.role_id -ne $roleId -or
        [string]$continuity.checkpoint_path -ne
            [string]$Authorization.checkpoint_material_path -or
        [string]$continuity.checkpoint_hash -ne
            [string]$Authorization.checkpoint_material_hash -or
        [string]$continuity.input_manifest_path -ne
            [string]$Authorization.input_manifest_path -or
        [string]$continuity.input_manifest_hash -ne
            [string]$Authorization.input_manifest_hash) {
        throw (
            "Milestone revision source '$sourceNodeId' replacement changed " +
            'role, thread, checkpoint, or input.'
        )
    }

    $recoveryPaths = @($continuity.recovery_receipt_paths)
    $recoveryHashes = @($continuity.recovery_receipt_hashes)
    $recoveryReceipts = [Collections.Generic.List[object]]::new()
    $recoveryEvents = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $relativeRecoveryPath = [string]$recoveryPaths[$index]
        $recoveryPath = Get-RunLocalReceiptPath -RunDirectory $RunDirectory `
            -RelativePath $relativeRecoveryPath `
            -Label 'Milestone revision original recovery receipt'
        $recovery = Get-Content -LiteralPath $recoveryPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        if ([string]$recovery.schema_version -ne '1.2' -or
            [string]$recovery.source_node_id -ne $sourceNodeId -or
            [string]$recovery.role_id -ne $roleId -or
            [string]$recovery.original_thread_id -ne $authorizedThreadId -or
            [string]$recovery.recovery_stage -ne 'original' -or
            [int]$recovery.attempt -ne ($index + 1) -or
            [string]$recovery.receipt_hash -ne $recoveryHashes[$index] -or
            [string]$recovery.milestone_id -ne
                [string]$Authorization.milestone_id -or
            [string]$recovery.milestone_activation_receipt_path -ne
                $AuthorizationReceiptRelativePath -or
            [string]$recovery.milestone_activation_receipt_hash -ne
                [string]$Authorization.receipt_hash -or
            [string]$recovery.checkpoint_path -ne
                [string]$Authorization.checkpoint_material_path -or
            [string]$recovery.checkpoint_hash -ne
                [string]$Authorization.checkpoint_material_hash -or
            [string]$recovery.input_manifest_path -ne
                [string]$Authorization.input_manifest_path -or
            [string]$recovery.input_manifest_hash -ne
                [string]$Authorization.input_manifest_hash) {
            throw (
                "Milestone revision source '$sourceNodeId' replacement " +
                'recovery chain is not bound to this revision.'
            )
        }
        $matches = @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [string]$_.thread_id -eq $authorizedThreadId -and
            [string]$_.prior_state -eq 'running' -and
            [string]$_.status -eq 'result_pending' -and
            [string]$_.recovery_receipt_path -eq $relativeRecoveryPath -and
            [string]$_.recovery_receipt_hash -eq
                [string]$recovery.receipt_hash -and
            [int]$_.sequence -gt $AuthorizationEventSequence -and
            [int]$_.sequence -gt $RearmEventSequence
        })
        if ($matches.Count -ne 1) {
            throw (
                "Milestone revision source '$sourceNodeId' recovery attempt " +
                "$($index + 1) lacks one journal event."
            )
        }
        $recoveryReceipts.Add($recovery)
        $recoveryEvents.Add($matches[0])
    }
    if (@($recoveryReceipts | ForEach-Object {
        [string]$_.recovery_cycle_id
    } | Select-Object -Unique).Count -ne 1 -or
        [string]$recoveryReceipts[2].outcome -ne 'recovery-exhausted' -or
        [int]$recoveryEvents[0].sequence -ge [int]$recoveryEvents[1].sequence -or
        [int]$recoveryEvents[1].sequence -ge [int]$recoveryEvents[2].sequence) {
        throw (
            "Milestone revision source '$sourceNodeId' replacement recovery " +
            'is incomplete, crossed cycles, or out of order.'
        )
    }

    $recoveryEventBindings = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $resume = $null
        if ($index -lt 2) {
            $between = @($Events | Where-Object {
                [string]$_.node_id -eq $sourceNodeId -and
                [int]$_.sequence -gt [int]$recoveryEvents[$index].sequence -and
                [int]$_.sequence -lt [int]$recoveryEvents[$index + 1].sequence
            })
            $resumeMatches = @($between | Where-Object {
                [string]$_.thread_id -eq $authorizedThreadId -and
                [string]$_.prior_state -eq 'result_pending' -and
                [string]$_.status -eq 'running'
            })
            if ($between.Count -ne 1 -or $resumeMatches.Count -ne 1) {
                throw (
                    "Milestone revision source '$sourceNodeId' recovery " +
                    'resume chain changed.'
                )
            }
            $resume = $resumeMatches[0]
        }
        $recoveryEventBindings.Add([pscustomobject][ordered]@{
            attempt = $index + 1
            recovery_receipt_path = [string]$recoveryPaths[$index]
            recovery_receipt_hash = [string]$recoveryHashes[$index]
            result_pending_event_sequence = [int]$recoveryEvents[$index].sequence
            result_pending_event_hash = [string]$recoveryEvents[$index].hash
            resume_event_sequence = if ($null -eq $resume) {
                0
            } else { [int]$resume.sequence }
            resume_event_hash = if ($null -eq $resume) {
                ''
            } else { [string]$resume.hash }
        })
    }

    $pendingMatches = @($Events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.thread_id -eq $selectedThreadId -and
        [string]$_.prior_state -eq 'result_pending' -and
        [string]$_.status -eq 'replacement_pending' -and
        [string]$_.replacement_receipt_path -eq $continuityRelativePath -and
        [string]$_.replacement_receipt_hash -eq
            [string]$continuity.receipt_hash -and
        [int]$_.sequence -gt [int]$recoveryEvents[2].sequence
    })
    if ($pendingMatches.Count -ne 1 -or
        @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [int]$_.sequence -gt [int]$recoveryEvents[2].sequence -and
            [int]$_.sequence -lt [int]$pendingMatches[0].sequence
        }).Count -gt 0) {
        throw (
            "Milestone revision source '$sourceNodeId' lacks one immediate " +
            'replacement-pending bridge.'
        )
    }
    $replacementPending = $pendingMatches[0]
    $continuityArtifact = "artifact:replacement-continuity:$continuityRelativePath"
    $continuityObservation = (
        "observation:replacement-continuity-hash:" +
        [string]$continuity.receipt_hash
    )
    $runningMatches = @($Events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.thread_id -eq $selectedThreadId -and
        [string]$_.prior_state -eq 'replacement_pending' -and
        [string]$_.status -eq 'running' -and
        [int]$_.sequence -gt [int]$replacementPending.sequence -and
        $continuityArtifact -in @($_.evidence) -and
        $continuityObservation -in @($_.evidence)
    })
    if ($runningMatches.Count -ne 1 -or
        @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [int]$_.sequence -gt [int]$replacementPending.sequence -and
            [int]$_.sequence -lt [int]$runningMatches[0].sequence
        }).Count -gt 0) {
        throw (
            "Milestone revision source '$sourceNodeId' lacks one immediate " +
            'replacement running bridge.'
        )
    }
    $replacementRunning = $runningMatches[0]
    return [pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        role_id = $roleId
        source_kind = 'replacement'
        authorized_thread_id = $authorizedThreadId
        source_thread_id = $selectedThreadId
        recovery_cycle_id = [string]$recoveryReceipts[0].recovery_cycle_id
        recovery_event_bindings = @($recoveryEventBindings)
        replacement_continuity_receipt_path = $continuityRelativePath
        replacement_continuity_receipt_hash = [string]$continuity.receipt_hash
        replacement_pending_event_sequence = [int]$replacementPending.sequence
        replacement_pending_event_hash = [string]$replacementPending.hash
        replacement_running_event_sequence = [int]$replacementRunning.sequence
        replacement_running_event_hash = [string]$replacementRunning.hash
        lifecycle_start_sequence = [int]$replacementRunning.sequence
    }
}

function Get-DurableReviewScopedCarryForward {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object[]] $PreviousSourceBindings,
        [Parameter(Mandatory)][object[]] $NextSourceBindings
    )

    $occurrences = [Collections.Generic.List[object]]::new()
    foreach ($previousBinding in @($PreviousSourceBindings)) {
        $sourceNodeId = [string]$previousBinding.source_node_id
        $sourceThreadId = [string]$previousBinding.source_thread_id
        $nextMatches = @($NextSourceBindings | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        if ($nextMatches.Count -ne 1 -or
            [string]$nextMatches[0].source_thread_id -ne $sourceThreadId) {
            throw (
                "Scoped milestone transition source '$sourceNodeId' changed " +
                'its durable thread or source identity.'
            )
        }
        $previousPath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory -RelativePath (
                [string]$previousBinding.disposition_receipt_path
            ) -Label 'Previous scoped milestone disposition'
        $nextPath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory -RelativePath (
                [string]$nextMatches[0].disposition_receipt_path
            ) -Label 'Next scoped milestone disposition'
        $previousDisposition = Read-ReviewDispositionReceipt `
            -Path $previousPath -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId $sourceThreadId
        $nextDisposition = Read-ReviewDispositionReceipt `
            -Path $nextPath -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId $sourceThreadId
        foreach ($previousDecision in @(
            $previousDisposition.decisions | Where-Object {
                [string]$_.severity -in @('P0', 'P1') -and
                [string]$_.resolution_status -ne 'resolved'
            }
        )) {
            $same = @($nextDisposition.decisions | Where-Object {
                [string]$_.source_finding_id -eq
                    [string]$previousDecision.source_finding_id
            })
            if ($same.Count -ne 1) {
                throw (
                    "Scoped milestone transition source '$sourceNodeId' lost " +
                    'a carry-forward occurrence.'
                )
            }
            $nextDecision = $same[0]
            if ([string]$nextDecision.canonical_finding_id -ne
                    [string]$previousDecision.canonical_finding_id -or
                [string]$nextDecision.severity -ne
                    [string]$previousDecision.severity -or
                [string]$nextDecision.finding -ne
                    [string]$previousDecision.finding -or
                [string]$nextDecision.finding_hash -ne
                    [string]$previousDecision.finding_hash) {
                throw (
                    "Scoped milestone transition source '$sourceNodeId' " +
                    'changed a carry-forward occurrence.'
                )
            }
            if ([string]$nextDecision.resolution_status -eq 'resolved' -and (
                [string]$nextDecision.re_review_status -ne 'completed' -or
                [string]$nextDecision.re_review_source_node_id -ne
                    $sourceNodeId
            )) {
                throw (
                    "Scoped milestone transition source '$sourceNodeId' " +
                    'resolved an occurrence without same-source re-review.'
                )
            }
            $occurrences.Add([ordered]@{
                source_node_id = $sourceNodeId
                source_thread_id = $sourceThreadId
                source_finding_id = [string]$previousDecision.source_finding_id
                canonical_finding_id =
                    [string]$previousDecision.canonical_finding_id
                severity = [string]$previousDecision.severity
                finding = [string]$previousDecision.finding
                finding_hash = [string]$previousDecision.finding_hash
                next_resolution_status =
                    [string]$nextDecision.resolution_status
                next_disposition = [string]$nextDecision.disposition
                next_re_review_status = [string]$nextDecision.re_review_status
            })
        }
    }
    $remaining = @($occurrences | Where-Object {
        [string]$_.next_resolution_status -ne 'resolved'
    })
    return [pscustomobject]@{
        occurrences = @($occurrences)
        previous_open_count = $occurrences.Count
        resolved_count = $occurrences.Count - $remaining.Count
        remaining_open_count = $remaining.Count
    }
}

function Get-MilestoneRevisionOpenOccurrenceInventory {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Plan,
        [Parameter(Mandatory)][string] $MilestoneId,
        [Parameter(Mandatory)][object[]] $SourceBindings
    )

    $requiredSourceIds = @(
        @($Plan.durable_review_profile.domain_node_ids) +
        @($Plan.durable_review_profile.dissent_node_ids) |
            ForEach-Object { [string]$_ }
    )
    if (@($SourceBindings).Count -ne $requiredSourceIds.Count) {
        throw 'Milestone revision open-occurrence source set is incomplete.'
    }
    $occurrences = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in $requiredSourceIds) {
        $bindingMatches = @($SourceBindings | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $nodeMatches = @($Plan.nodes | Where-Object {
            [string]$_.id -eq $sourceNodeId
        })
        if ($bindingMatches.Count -ne 1 -or $nodeMatches.Count -ne 1 -or
            [string]$bindingMatches[0].milestone_id -ne $MilestoneId -or
            [string]::IsNullOrWhiteSpace(
                [string]$bindingMatches[0].source_thread_id
            )) {
            throw (
                "Milestone revision open-occurrence source '$sourceNodeId' " +
                'binding is invalid.'
            )
        }
        $dispositionPath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory -RelativePath (
                [string]$bindingMatches[0].disposition_receipt_path
            ) -Label 'Milestone revision predecessor disposition'
        $disposition = Read-ReviewDispositionReceipt `
            -Path $dispositionPath -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $sourceNodeId -ExpectedThreadId (
                [string]$bindingMatches[0].source_thread_id
            )
        foreach ($decision in @($disposition.decisions | Where-Object {
            [string]$_.severity -in @('P0', 'P1') -and
            [string]$_.resolution_status -ne 'resolved'
        })) {
            if ([string]$decision.resolution_status -ne 'open') {
                throw 'Milestone revision predecessor finding status is invalid.'
            }
            $occurrences.Add([pscustomobject][ordered]@{
                source_node_id = $sourceNodeId
                role_id = [string]$nodeMatches[0].role_id
                source_thread_id =
                    [string]$bindingMatches[0].source_thread_id
                source_finding_id = [string]$decision.source_finding_id
                canonical_finding_id =
                    [string]$decision.canonical_finding_id
                severity = [string]$decision.severity
                finding = [string]$decision.finding
                finding_hash = [string]$decision.finding_hash
                resolution_status = [string]$decision.resolution_status
            })
        }
    }
    $occurrenceJson = ConvertTo-Json -InputObject @($occurrences) `
        -Compress -Depth 50
    return [pscustomobject]@{
        occurrences = @($occurrences)
        count = $occurrences.Count
        hash = Get-TextSha256 $occurrenceJson
    }
}

function Read-DurableReviewScopeTransitionAuthorization {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Scoped milestone transition authorization receipt is missing.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'previous_milestone_id',
        'previous_activation_receipt_path',
        'previous_activation_receipt_hash',
        'previous_source_bindings_hash', 'milestone_id', 'milestone_index',
        'source_journal_head', 'source_journal_event_count',
        'selection_material_path', 'selection_material_hash',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'scope_transition_authorization_material_path',
        'scope_transition_authorization_material_hash',
        'scope_transition_key', 'carry_forward_occurrences_hash',
        'previous_open_occurrence_count', 'resolved_occurrence_count',
        'remaining_open_occurrence_count', 'activation_key',
        'created_at_utc', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw (
                "Scoped milestone transition authorization receipt is missing " +
                "'$name'."
            )
        }
    }
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $milestoneIds = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    $milestoneIndex = [Array]::IndexOf(
        $milestoneIds, [string]$receipt.milestone_id
    )
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        (Get-TextSha256 $planRaw) -ne [string]$run.plan_hash -or
        $milestoneIndex -lt 1 -or
        [int]$receipt.milestone_index -ne $milestoneIndex -or
        [string]$receipt.previous_milestone_id -ne
            $milestoneIds[$milestoneIndex - 1] -or
        [string]$receipt.scope_transition_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$' -or
        [string]$receipt.activation_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Scoped milestone transition authorization identity is invalid.'
    }
    foreach ($binding in @(
        [pscustomobject]@{
            path = [string]$receipt.selection_material_path
            hash = [string]$receipt.selection_material_hash
            label = 'Scoped milestone transition selection'
            require_nonempty = $false
        },
        [pscustomobject]@{
            path = [string](
                $receipt.scope_transition_authorization_material_path
            )
            hash = [string](
                $receipt.scope_transition_authorization_material_hash
            )
            label = 'Scoped milestone transition authorization material'
            require_nonempty = $true
        }
    )) {
        $fullPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath $binding.path -Label $binding.label
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
            [string]$binding.hash -ne (
                Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
            ).Hash.ToLowerInvariant() -or
            ($binding.require_nonempty -and [string]::IsNullOrWhiteSpace(
                (Get-Content -LiteralPath $fullPath -Raw)
            ))) {
            throw "$($binding.label) binding changed."
        }
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        )
    )) {
        throw 'Scoped milestone transition authorization receipt hash mismatch.'
    }
    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    $eventCount = [int]$receipt.source_journal_event_count
    if ($eventCount -lt 1 -or $eventCount -ge $events.Count -or
        [string]$events[$eventCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Scoped milestone transition authorization journal binding changed.'
    }
    $relativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    $matchingEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-scope-transition-authorized' -and
        [string]$_.milestone_id -eq [string]$receipt.milestone_id -and
        [string]$_.scope_transition_authorization_receipt_path -eq
            $relativePath -and
        [string]$_.scope_transition_authorization_receipt_hash -eq
            [string]$receipt.receipt_hash
    })
    if ($matchingEvents.Count -ne 1 -or
        [int]$matchingEvents[0].sequence -ne $eventCount -or
        [string]$matchingEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head -or
        [string]$matchingEvents[0].scope_transition_key -cne
            [string]$receipt.scope_transition_key -or
        [string]$matchingEvents[0].scope_transition_selection_material_hash -ne
            [string]$receipt.selection_material_hash -or
        @($matchingEvents[0].evidence) -notcontains
            "artifact:$relativePath") {
        throw (
            'Scoped milestone transition authorization lacks its exact ' +
            'append-only journal event.'
        )
    }
    return $receipt
}

function Get-MilestoneRevisionExcludedInventory {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object[]] $Events,
        [Parameter(Mandatory)][string[]] $RequiredSourceIds,
        [Parameter(Mandatory)][string] $CheckpointHash,
        [Parameter(Mandatory)][int] $EventCount
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $inventoryEvents = [Collections.Generic.List[object]]::new()
    $inventoryArtifacts = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in $RequiredSourceIds) {
        $direct = [Collections.Generic.List[int]]::new()
        foreach ($event in @($Events | Where-Object {
            [int]$_.sequence -lt $EventCount -and
            [string]$_.node_id -eq $sourceNodeId
        })) {
            $related = (
                $null -ne $event.PSObject.Properties[
                    'recovery_checkpoint_hash'
                ] -and
                [string]$event.recovery_checkpoint_hash -eq $CheckpointHash
            )
            foreach ($pointer in @($event.evidence | Where-Object {
                [string]$_ -like 'artifact:*'
            })) {
                $relativePath = ([string]$pointer).Substring(9)
                if ($relativePath.StartsWith('result-recovery:')) {
                    $relativePath = $relativePath.Substring(16)
                }
                try {
                    $artifactPath = Get-RunLocalReceiptPath `
                        -RunDirectory $runRoot -RelativePath $relativePath `
                        -Label 'Revision excluded artifact'
                } catch { continue }
                if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                    [IO.Path]::GetExtension($artifactPath) -ne '.json') {
                    continue
                }
                try {
                    $document = Get-Content -LiteralPath $artifactPath -Raw |
                        ConvertFrom-Json -Depth 100 -DateKind String
                } catch { continue }
                $type = ''
                $documentCheckpoint = ''
                $internalHash = ''
                $extras = @()
                if ($null -ne $document.PSObject.Properties[
                    'checkpoint_material_hash'
                ] -and $null -ne $document.PSObject.Properties[
                    'thread_read_path'
                ]) {
                    $type = 'result'
                    $documentCheckpoint =
                        [string]$document.checkpoint_material_hash
                    $internalHash = [string]$document.receipt_hash
                    $extras = @([pscustomobject]@{
                        type = 'capture'
                        path = [string]$document.thread_read_path
                        internal_hash = ''
                    })
                } elseif ($null -ne $document.PSObject.Properties[
                    'source_result_receipt_path'
                ]) {
                    $type = 'disposition'
                    $internalHash = [string]$document.receipt_hash
                    $resultPath = Get-RunLocalReceiptPath `
                        -RunDirectory $runRoot -RelativePath (
                            [string]$document.source_result_receipt_path
                        ) -Label 'Revision excluded source result'
                    $result = Get-Content -LiteralPath $resultPath -Raw |
                        ConvertFrom-Json -Depth 100 -DateKind String
                    $documentCheckpoint =
                        [string]$result.checkpoint_material_hash
                    $extras = @(
                        [pscustomobject]@{
                            type = 'result'
                            path = [string]$document.source_result_receipt_path
                            internal_hash = [string]$result.receipt_hash
                        },
                        [pscustomobject]@{
                            type = 'capture'
                            path = [string]$result.thread_read_path
                            internal_hash = ''
                        }
                    )
                } elseif ($null -ne $document.PSObject.Properties[
                    'recovery_cycle_id'
                ]) {
                    $type = 'recovery'
                    $documentCheckpoint = [string]$document.checkpoint_hash
                    $internalHash = [string]$document.receipt_hash
                    $extras = @([pscustomobject]@{
                        type = 'capture'
                        path = [string]$document.thread_read_path
                        internal_hash = ''
                    })
                }
                if ($documentCheckpoint -ne $CheckpointHash) { continue }
                $related = $true
                foreach ($candidate in @([pscustomobject]@{
                    type = $type
                    path = $relativePath.Replace('\', '/')
                    internal_hash = $internalHash
                }) + $extras) {
                    $candidatePath = Get-RunLocalReceiptPath `
                        -RunDirectory $runRoot `
                        -RelativePath ([string]$candidate.path) `
                        -Label 'Revision excluded artifact'
                    $key = "$sourceNodeId`n$([string]$candidate.path)"
                    if (@($inventoryArtifacts | Where-Object {
                        [string]$_.key -eq $key
                    }).Count -eq 0) {
                        $inventoryArtifacts.Add([pscustomobject]@{
                            key = $key
                            source_node_id = $sourceNodeId
                            type = [string]$candidate.type
                            path = ([string]$candidate.path).Replace('\', '/')
                            file_hash = (
                                Get-FileHash -LiteralPath $candidatePath `
                                    -Algorithm SHA256
                            ).Hash.ToLowerInvariant()
                            internal_hash = [string]$candidate.internal_hash
                        })
                    }
                }
            }
            if ($related) { $direct.Add([int]$event.sequence) }
        }
        if ($direct.Count -gt 0) {
            $minimum = ($direct | Measure-Object -Minimum).Minimum
            $maximum = ($direct | Measure-Object -Maximum).Maximum
            foreach ($sequence in $minimum..$maximum) {
                $event = $Events[$sequence]
                if ([string]$event.node_id -eq $sourceNodeId) {
                    $inventoryEvents.Add([pscustomobject]@{
                        source_node_id = $sourceNodeId
                        event_sequence = $sequence
                        event_hash = [string]$event.hash
                    })
                }
            }
        }
    }
    return [pscustomobject]@{
        events = @($inventoryEvents | Sort-Object source_node_id, event_sequence)
        artifacts = @($inventoryArtifacts | Sort-Object key)
    }
}

function New-DurableReviewOccurrenceDescriptor {
    param(
        [Parameter(Mandatory)][string] $SourceNodeId,
        [Parameter(Mandatory)][object] $Decision
    )
    foreach ($name in @(
        'source_finding_id', 'canonical_finding_id', 'severity', 'finding',
        'finding_hash', 'disposition', 'rationale', 'resolution_status',
        'evidence', 're_review_status', 're_review_source_node_id',
        're_review_evidence'
    )) {
        if ($null -eq $Decision.PSObject.Properties[$name]) {
            throw "Review occurrence descriptor is missing '$name'."
        }
    }
    return [ordered]@{
        source_node_id = $SourceNodeId
        source_finding_id = [string]$Decision.source_finding_id
        canonical_finding_id = [string]$Decision.canonical_finding_id
        severity = [string]$Decision.severity
        exact_text = [string]$Decision.finding
        text_hash = [string]$Decision.finding_hash
        finding_hash = [string]$Decision.finding_hash
        disposition = [string]$Decision.disposition
        rationale = [string]$Decision.rationale
        resolution_status = [string]$Decision.resolution_status
        evidence = @($Decision.evidence)
        re_review_status = [string]$Decision.re_review_status
        re_review_source_node_id = [string]$Decision.re_review_source_node_id
        re_review_evidence = @($Decision.re_review_evidence)
    }
}

function ConvertTo-DurableReviewOccurrenceDescriptor {
    param(
        [Parameter(Mandatory)][string] $SourceNodeId,
        [Parameter(Mandatory)][object] $Descriptor
    )
    foreach ($name in @(
        'source_finding_id', 'canonical_finding_id', 'severity', 'exact_text',
        'text_hash', 'finding_hash', 'disposition', 'rationale',
        'resolution_status', 'evidence', 're_review_status',
        're_review_source_node_id', 're_review_evidence'
    )) {
        if ($null -eq $Descriptor.PSObject.Properties[$name]) {
            throw "Review occurrence descriptor is missing '$name'."
        }
    }
    return [ordered]@{
        source_node_id = $SourceNodeId
        source_finding_id = [string]$Descriptor.source_finding_id
        canonical_finding_id = [string]$Descriptor.canonical_finding_id
        severity = [string]$Descriptor.severity
        exact_text = [string]$Descriptor.exact_text
        text_hash = [string]$Descriptor.text_hash
        finding_hash = [string]$Descriptor.finding_hash
        disposition = [string]$Descriptor.disposition
        rationale = [string]$Descriptor.rationale
        resolution_status = [string]$Descriptor.resolution_status
        evidence = @($Descriptor.evidence)
        re_review_status = [string]$Descriptor.re_review_status
        re_review_source_node_id = [string]$Descriptor.re_review_source_node_id
        re_review_evidence = @($Descriptor.re_review_evidence)
    }
}

function Read-DurableReviewMilestoneRevisionAbandonment {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $events = @(Read-OrchestrationJournal $eventsPath)
    $receiptPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([IO.Path]::GetRelativePath($runRoot, [IO.Path]::GetFullPath($Path)).Replace('\', '/')) `
        -Label 'Milestone revision abandonment receipt'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    foreach ($name in @(
        'schema_version', 'receipt_type', 'run_id', 'plan_hash',
        'genesis_hash', 'milestone_id', 'revision_id',
        'authorization_receipt_path', 'authorization_receipt_hash',
        'authorization_receipt_file_hash',
        'authorization_event_sequence', 'authorization_event_hash',
        'source_journal_head', 'source_journal_event_count',
        'source_journal_file_hash', 'required_sources', 'required_sources_hash',
        'source_rearm_events', 'source_rearm_events_hash',
        'invalidity_audit_material_path', 'invalidity_audit_material_hash',
        'invalidity_audit', 'cumulative_source_occurrences',
        'cumulative_source_occurrences_hash', 'cumulative_source_occurrence_count',
        'decision', 'completion_eligible', 'source_evidence_eligible',
        'abandonment_key', 'receipt_hash'
    )) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone revision abandonment is missing '$name'."
        }
    }
    if ($null -eq $receipt.invalidity_audit.PSObject.Properties[
            'raw_evidence_non_adoptable'] -or
        -not [bool]$receipt.invalidity_audit.raw_evidence_non_adoptable -or
        [string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.receipt_type -ne 'milestone-revision-abandonment' -or
        [string]$receipt.decision -ne 'abandoned' -or
        [bool]$receipt.completion_eligible -or
        [bool]$receipt.source_evidence_eligible -or
        [string]$receipt.abandonment_key -notmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Milestone revision abandonment decision or key is invalid.'
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 100
    ))) {
        throw 'Milestone revision abandonment receipt hash changed.'
    }
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.run_id -ne [string]$plan.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$receipt.genesis_hash -ne [string]$events[0].hash) {
        throw 'Milestone revision abandonment run identity changed.'
    }
    $sourceCount = [int]$receipt.source_journal_event_count
    if ($sourceCount -lt 1 -or
        $events.Count -lt ($sourceCount + 1) -or
        [string]$events[$sourceCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision abandonment journal boundary changed.'
    }
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_receipt_path) `
        -Label 'Milestone revision authorization receipt'
    $authorizationRelative = [IO.Path]::GetRelativePath(
        $runRoot, $authorizationPath
    ).Replace('\', '/')
    $authorizationFileHash = (Get-FileHash -LiteralPath $authorizationPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($authorizationRelative -ne [string]$receipt.authorization_receipt_path -or
        $authorizationFileHash -ne [string]$receipt.authorization_receipt_file_hash) {
        throw (
            "Milestone revision abandonment authorization file binding changed: " +
            "path '$authorizationRelative' vs '$($receipt.authorization_receipt_path)'; " +
            "hash '$authorizationFileHash' vs '$($receipt.authorization_receipt_file_hash)'."
        )
    }
    $authorization = Read-DurableReviewMilestoneRevisionAuthorization `
        -Path $authorizationPath -RunDirectory $runRoot
    if ([string]$authorization.receipt_hash -ne
            [string]$receipt.authorization_receipt_hash -or
        [string]$authorization.run_id -ne [string]$receipt.run_id -or
        [string]$authorization.plan_hash -ne [string]$receipt.plan_hash -or
        [string]$authorization.genesis_hash -ne [string]$receipt.genesis_hash -or
        [string]$authorization.milestone_id -ne [string]$receipt.milestone_id -or
        [int]$authorization.milestone_index -ne [int]$receipt.milestone_index -or
        [string]$authorization.revision_id -ne [string]$receipt.revision_id -or
        [int]$authorization.revision_index -ne [int]$receipt.revision_index -or
        [string]$authorization.checkpoint_material_path -ne
            [string]$receipt.checkpoint_material_path -or
        [string]$authorization.checkpoint_material_hash -ne
            [string]$receipt.checkpoint_material_hash -or
        [string]$authorization.input_manifest_path -ne
            [string]$receipt.input_manifest_path -or
        [string]$authorization.input_manifest_hash -ne
            [string]$receipt.input_manifest_hash -or
        [string]$authorization.required_sources_hash -ne
            [string]$receipt.required_sources_hash) {
        throw 'Milestone revision abandonment authorization binding changed.'
    }
    if ((ConvertTo-Json -InputObject @($authorization.required_sources) `
            -Compress -Depth 50) -ne
        (ConvertTo-Json -InputObject @($receipt.required_sources) `
            -Compress -Depth 50)) {
        throw 'Milestone revision abandonment required sources changed.'
    }
    $authorizationEvents = @($events | Where-Object {
        [int]$_.sequence -eq [int]$receipt.authorization_event_sequence -and
        [string]$_.hash -eq [string]$receipt.authorization_event_hash -and
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            $authorizationRelative -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$authorization.receipt_hash -and
        [string]$_.milestone_revision_selection_key -ceq
            [string]$authorization.selection_key
    })
    if ($authorizationEvents.Count -ne 1 -or
        [int]$receipt.authorization_event_sequence -ge $sourceCount) {
        throw 'Milestone revision abandonment authorization event changed.'
    }
    $rawBytes = [IO.File]::ReadAllBytes($eventsPath)
    $lineCount = 0
    $prefixEnd = -1
    for ($index = 0; $index -lt $rawBytes.Length; $index++) {
        if ($rawBytes[$index] -eq 10) {
            $lineCount++
            if ($lineCount -eq $sourceCount) {
                $prefixEnd = $index + 1
                break
            }
        }
    }
    if ($prefixEnd -lt 1) {
        throw 'Milestone revision abandonment source journal prefix is incomplete.'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $prefixHash = [Convert]::ToHexString($sha.ComputeHash(
            $rawBytes[0..($prefixEnd - 1)]
        )).ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ($prefixHash -ne [string]$receipt.source_journal_file_hash) {
        throw 'Milestone revision abandonment source journal file hash changed.'
    }
    $abandonmentEvent = $events[$sourceCount]
    if ([string]$abandonmentEvent.event -ne 'milestone-revision-abandoned' -or
        [string]$abandonmentEvent.milestone_revision_id -ne
            [string]$receipt.revision_id -or
        [string]$abandonmentEvent.milestone_revision_abandonment_receipt_path -ne
            [IO.Path]::GetRelativePath($runRoot, $receiptPath).Replace('\', '/') -or
        [string]$abandonmentEvent.milestone_revision_abandonment_receipt_hash -ne
            [string]$receipt.receipt_hash -or
        [string]$abandonmentEvent.prev_hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision abandonment event changed.'
    }
    if ((Get-TextSha256 (ConvertTo-Json -InputObject @(
        $receipt.required_sources
    ) -Compress -Depth 50)) -ne
        [string]$receipt.required_sources_hash) {
        throw 'Milestone revision abandonment required sources changed.'
    }
    $rearmBindings = @($receipt.source_rearm_events)
    if ($rearmBindings.Count -ne @($receipt.required_sources).Count -or
        (Get-TextSha256 (ConvertTo-Json -InputObject @(
            $rearmBindings
        ) -Compress -Depth 50)) -ne
            [string]$receipt.source_rearm_events_hash) {
        throw 'Milestone revision abandonment re-arm bindings changed.'
    }
    foreach ($binding in $rearmBindings) {
        $matches = @($events | Where-Object {
            [int]$_.sequence -eq [int]$binding.event_sequence -and
            [string]$_.hash -eq [string]$binding.event_hash -and
            [string]$_.node_id -eq [string]$binding.source_node_id -and
            [string]$_.role_id -eq [string]$binding.role_id -and
            [string]$_.thread_id -eq [string]$binding.thread_id -and
            [string]$_.prior_state -eq 'adopted' -and
            [string]$_.status -eq 'running' -and
            [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
        })
        if ($matches.Count -ne 1 -or [int]$binding.event_sequence -ge $sourceCount) {
            throw 'Milestone revision abandonment re-arm event changed.'
        }
    }
    $auditPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.invalidity_audit_material_path) `
        -Label 'Milestone revision invalidity audit'
    if ([string]$receipt.invalidity_audit_material_hash -ne (
        Get-FileHash -LiteralPath $auditPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()) {
        throw 'Milestone revision invalidity audit changed.'
    }
    $audit = Get-Content -LiteralPath $auditPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $failedInput = $audit.failed_input_binding
    $auditInputPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$failedInput.input_manifest_path) `
        -Label 'Milestone revision invalidity audit input'
    if (-not (Test-Path -LiteralPath $auditInputPath -PathType Leaf)) {
        throw 'Milestone revision invalidity audit input is missing.'
    }
    $auditInputHash = (Get-FileHash -LiteralPath $auditInputPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ($auditInputHash -ne [string]$receipt.input_manifest_hash -or
        [string]$failedInput.input_manifest_sha256 -ne $auditInputHash) {
        throw 'Milestone revision invalidity audit input binding changed.'
    }
    $auditControlProperty = if ($null -ne $failedInput.PSObject.Properties['control_path_property']) {
        [string]$failedInput.control_path_property
    } else { 'matrix_path' }
    $auditHashProperty = if ($null -ne $failedInput.PSObject.Properties['control_hash_property']) {
        [string]$failedInput.control_hash_property
    } else { 'matrix_hash' }
    $auditInput = Get-Content -LiteralPath $auditInputPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    if ($null -eq $auditInput.PSObject.Properties[$auditControlProperty] -or
        $null -eq $auditInput.PSObject.Properties[$auditHashProperty]) {
        throw 'Milestone revision invalidity audit control properties are missing.'
    }
    $auditDeclaredPath = [string]$auditInput.$auditControlProperty
    $auditDeclaredHash = [string]$auditInput.$auditHashProperty
    $auditDeclaredFile = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath $auditDeclaredPath `
        -Label 'Milestone revision invalidity audit control file'
    if (-not (Test-Path -LiteralPath $auditDeclaredFile -PathType Leaf)) {
        throw 'Milestone revision invalidity audit control file is missing.'
    }
    $auditActualHash = (Get-FileHash -LiteralPath $auditDeclaredFile -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ($auditActualHash -ne [string]$receipt.invalidity_audit.actual_file_hash -or
        $auditActualHash -eq $auditDeclaredHash -or
        $auditDeclaredHash -ne [string]$receipt.invalidity_audit.declared_hash) {
        throw 'Milestone revision invalidity audit control binding changed.'
    }
    $auditOtherPath = [string]$failedInput.actual_object_for_declared_matrix_hash
    if ([string]::IsNullOrWhiteSpace($auditOtherPath) -or
        $auditOtherPath -eq $auditDeclaredPath) {
        throw 'Milestone revision invalidity audit declared-hash object binding changed.'
    }
    $auditOtherFile = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath $auditOtherPath `
        -Label 'Milestone revision invalidity audit declared-hash object'
    if (-not (Test-Path -LiteralPath $auditOtherFile -PathType Leaf)) {
        throw 'Milestone revision invalidity audit declared-hash object is missing.'
    }
    $auditOtherHash = (Get-FileHash -LiteralPath $auditOtherFile -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ($auditOtherHash -ne $auditDeclaredHash) {
        throw 'Milestone revision invalidity audit declared-hash object changed.'
    }
    if ([string]$audit.failed_input_binding.failure_class -ne
            [string]$receipt.invalidity_audit.failure_class -or
        [string]$audit.failed_input_binding.actual_declared_matrix_path_sha256 -ne
            [string]$receipt.invalidity_audit.actual_file_hash -or
        [string]$audit.failed_input_binding.declared_matrix_hash -ne
            [string]$receipt.invalidity_audit.declared_hash -or
        [string]$audit.source_finding.source_finding_id -ne
            [string]$receipt.invalidity_audit.finding.source_finding_id -or
        [string]$audit.source_finding.exact_text -ne
            [string]$receipt.invalidity_audit.finding.exact_text -or
        [string]$audit.source_finding.severity -ne
            [string]$receipt.invalidity_audit.finding.severity -or
        [string]$audit.source_finding.status -ne
            [string]$receipt.invalidity_audit.finding.status -or
        [string]$receipt.invalidity_audit.finding.finding_hash -ne
            (Get-TextSha256 ([string]$audit.source_finding.exact_text))) {
        throw 'Milestone revision invalidity audit content changed.'
    }
    $pendingFindingRelative = [string]$receipt.invalidity_audit.pending_finding_material_path
    if (-not [string]::IsNullOrWhiteSpace($pendingFindingRelative)) {
        $pendingFindingPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath $pendingFindingRelative `
            -Label 'Milestone revision pending finding material'
        if (-not (Test-Path -LiteralPath $pendingFindingPath -PathType Leaf)) {
            throw 'Milestone revision pending finding material is missing.'
        }
        $pendingHash = (Get-FileHash -LiteralPath $pendingFindingPath -Algorithm SHA256).
            Hash.ToLowerInvariant()
        if ($pendingHash -ne [string]$receipt.invalidity_audit.pending_finding_material_hash) {
            throw 'Milestone revision pending finding material changed.'
        }
        $pendingRecords = @(
            Get-Content -LiteralPath $pendingFindingPath -Raw |
                ConvertFrom-Json -Depth 50 -DateKind String
        ) | Where-Object {
            [string]$_.finding_id -eq
                [string]$receipt.invalidity_audit.finding.source_finding_id
        }
        if ($pendingRecords.Count -ne 1 -or
            [string]$pendingRecords[0].severity -ne
                [string]$receipt.invalidity_audit.finding.severity -or
            [string]$pendingRecords[0].text -ne
                [string]$receipt.invalidity_audit.finding.exact_text) {
            throw 'Milestone revision pending finding identity changed.'
        }
    }
    if ([string]$audit.failed_input_binding.failure_class -notin @(
        'matrix_path_hash_object_mismatch',
        'control-material-path-hash-mismatch'
    )) {
        throw 'Milestone revision invalidity audit failure class is unsupported.'
    }
    if ($null -eq $audit.PSObject.Properties[
        'cumulative_source_occurrence_descriptors'
    ]) {
        throw 'Milestone revision invalidity audit lacks occurrence descriptors.'
    }
    if ($null -eq $audit.PSObject.Properties['cumulative_source_inventory']) {
        throw 'Milestone revision invalidity audit lacks the simple cumulative source inventory.'
    }
    $expectedInventory = [Collections.Generic.List[object]]::new()
    foreach ($previousBinding in @($authorization.previous_source_bindings)) {
        $previousDispositionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$previousBinding.disposition_receipt_path) `
            -Label 'Previous source disposition'
        $previousDisposition = Read-ReviewDispositionReceipt `
            -Path $previousDispositionPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId ([string]$previousBinding.source_node_id) `
            -ExpectedThreadId ([string]$previousBinding.source_thread_id)
        foreach ($decision in @($previousDisposition.decisions)) {
            $expectedInventory.Add(
                (New-DurableReviewOccurrenceDescriptor `
                    -SourceNodeId ([string]$previousBinding.source_node_id) `
                    -Decision $decision)
            )
        }
    }
    $expectedJson = ConvertTo-Json -InputObject @($expectedInventory) `
        -Compress -Depth 50
    $auditInventory = @(
        $audit.cumulative_source_occurrence_descriptors | ForEach-Object {
            ConvertTo-DurableReviewOccurrenceDescriptor `
                -SourceNodeId ([string]$_.source_node_id) -Descriptor $_
        }
    )
    $receiptInventory = @(
        $receipt.cumulative_source_occurrences | ForEach-Object {
            ConvertTo-DurableReviewOccurrenceDescriptor `
                -SourceNodeId ([string]$_.source_node_id) -Descriptor $_
        }
    )
    if ($auditInventory.Count -ne $expectedInventory.Count -or
        (ConvertTo-Json -InputObject @($auditInventory) -Compress -Depth 50) -ne
            $expectedJson -or
        $receiptInventory.Count -ne $expectedInventory.Count -or
        (ConvertTo-Json -InputObject @($receiptInventory) -Compress -Depth 50) -ne
            $expectedJson) {
        throw 'Milestone revision invalidity audit occurrence descriptors changed.'
    }
    $expectedKeys = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($item in @($expectedInventory)) {
        if (-not $expectedKeys.Add(
            "$($item.source_node_id)`n$($item.source_finding_id)"
        )) {
            throw 'Milestone revision abandonment cumulative inventory changed.'
        }
    }
    $auditKeys = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($property in $audit.cumulative_source_inventory.PSObject.Properties) {
        if ([string]$property.Name -eq 'total_source_occurrences') { continue }
        $source = switch ([string]$property.Name) {
            'traditional' { 'liuyao-traditional-source' }
            'adversarial' { 'liuyao-adversarial-source' }
            default { [string]$property.Name }
        }
        foreach ($findingId in @($property.Value)) {
            $null = $auditKeys.Add("$source`n$([string]$findingId)")
        }
    }
    if ([int]$audit.cumulative_source_inventory.total_source_occurrences -ne
            $expectedKeys.Count -or
        $auditKeys.Count -ne $expectedKeys.Count -or
        @($auditKeys | Where-Object { -not $expectedKeys.Contains($_) }).Count -gt 0) {
        throw 'Milestone revision invalidity audit inventory changed.'
    }
    if ($expectedInventory.Count -lt 1 -or
        $expectedInventory.Count -ne [int]$receipt.cumulative_source_occurrence_count -or
        (Get-TextSha256 (ConvertTo-Json -InputObject @($expectedInventory) `
            -Compress -Depth 50)) -ne
            [string]$receipt.cumulative_source_occurrences_hash) {
        throw 'Milestone revision abandonment cumulative inventory changed.'
    }
    return $receipt
}

function Read-DurableReviewMilestoneRevisionAuthorization {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $validationToken = Enter-OrchestrationValidationContext `
        -RunDirectory $runRoot
    $validationSucceeded = $false
    try {
    $cacheDescriptor = Get-OrchestrationValidatedObjectCacheDescriptor `
        -Kind 'milestone-revision-authorization' -Path $Path `
        -RunDirectory $runRoot
    $cached = Get-OrchestrationValidatedObjectCacheValue `
        -Descriptor $cacheDescriptor
    if ($null -ne $cached) {
        $validationSucceeded = $true
        return $cached
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Milestone revision authorization receipt does not exist.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'genesis_hash',
        'milestone_id', 'milestone_index', 'revision_id', 'revision_index',
        'previous_activation_receipt_path',
        'previous_activation_receipt_hash', 'previous_source_bindings',
        'previous_source_bindings_hash', 'source_journal_head',
        'source_journal_event_count', 'checkpoint_material_path',
        'checkpoint_material_hash', 'input_manifest_path',
        'input_manifest_hash', 'required_sources', 'required_sources_hash',
        'review_material_manifest_path', 'review_material_manifest_hash',
        'review_material_bindings', 'review_material_bindings_hash',
        'excluded_evidence_manifest_path', 'excluded_evidence_manifest_hash',
        'excluded_evidence', 'authorization_material_path',
        'authorization_material_hash',
        'acceptance_authorization_material_path',
        'acceptance_authorization_material_hash', 'main_node_id',
        'acceptance_key', 'acceptance_evidence_material_path',
        'acceptance_evidence_material_hash', 'selection_authority_key',
        'selection_key', 'activation_key',
        'created_at_utc', 'receipt_hash'
    )
    if ([string]$receipt.schema_version -eq '1.1') {
        $required += @(
            'previous_revision_selection_receipt_path',
            'previous_revision_selection_receipt_hash',
            'previous_revision_selection_event_sequence',
            'previous_revision_selection_event_hash',
            'previous_open_occurrences',
            'previous_open_occurrences_hash',
            'previous_open_occurrence_count'
        )
    }
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone revision authorization is missing '$name'."
        }
    }
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    $milestoneIds = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    if ([string]$receipt.schema_version -notin @('1.0', '1.1') -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.genesis_hash -ne [string]$events[0].hash -or
        [string]$receipt.milestone_id -ne $milestoneIds[0] -or
        [int]$receipt.milestone_index -ne 0 -or
        [string]$receipt.selection_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$' -or
        [string]$receipt.activation_key -notmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Milestone revision authorization run or milestone binding is invalid.'
    }
    if (([string]$receipt.schema_version -eq '1.0' -and
            [int]$receipt.revision_index -ne 1) -or
        ([string]$receipt.schema_version -eq '1.1' -and
            [int]$receipt.revision_index -lt 2)) {
        throw 'Milestone revision authorization schema/index binding is invalid.'
    }
    $selectionAuthorityPrefix = (
        [string]$receipt.selection_authority_key
    ).Split(':', 2)[0]
    $expectedSelectionKey = (
        "$selectionAuthorityPrefix`:milestone-revision-selection:" +
        [string]$receipt.revision_id
    )
    if ([string]$receipt.selection_authority_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$' -or
        [string]$receipt.selection_key -cne $expectedSelectionKey) {
        throw 'Milestone revision selection key derivation is invalid.'
    }
    $eventCount = [int]$receipt.source_journal_event_count
    if ($eventCount -lt 1 -or $eventCount -ge $events.Count -or
        [string]$events[$eventCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision authorization journal binding changed.'
    }
    $prefixEvents = @($events | Select-Object -First $eventCount)
    $prefixAuthorizations = @($prefixEvents | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized'
    })
    $prefixSelections = @($prefixEvents | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected'
    })
    $prefixAbandonments = @($prefixEvents | Where-Object {
        [string]$_.event -eq 'milestone-revision-abandoned'
    })
    if ($prefixAuthorizations.Count -ne
            ($prefixSelections.Count + $prefixAbandonments.Count) -or
        [int]$receipt.revision_index -ne
            ($prefixAuthorizations.Count + 1) -or
        @($prefixEvents | Where-Object {
            [string]$_.event -eq 'milestone-accepted' -and
            [string]$_.milestone_id -eq [string]$receipt.milestone_id
        }).Count -gt 0 -or
        @($prefixEvents | Where-Object {
            [string]$_.event -eq 'milestone-activated'
        }).Count -gt 0) {
        throw 'Milestone revision authorization predecessor state is invalid.'
    }
    $relativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    $matchingEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            $relativePath -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$receipt.receipt_hash -and
        [string]$_.milestone_revision_selection_key -ceq
            [string]$receipt.selection_key
    })
    if ($matchingEvents.Count -ne 1 -or
        [int]$matchingEvents[0].sequence -ne $eventCount -or
        [string]$matchingEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision authorization lacks its exact journal event.'
    }
    $abandonmentProperties = @(
        'previous_abandonment_receipt_path',
        'previous_abandonment_receipt_hash',
        'previous_abandonment_event_sequence',
        'previous_abandonment_event_hash',
        'previous_abandonment_revision_id'
    )
    $hasAbandonmentBinding = $null -ne
        $receipt.PSObject.Properties['previous_abandonment_receipt_path']
    if ($prefixAbandonments.Count -gt 0 -and -not $hasAbandonmentBinding) {
        throw 'Milestone revision authorization omitted its prior abandonment binding.'
    }
    if ($prefixAbandonments.Count -eq 0 -and $hasAbandonmentBinding) {
        throw 'Milestone revision authorization has an unexpected abandonment binding.'
    }
    if ($hasAbandonmentBinding) {
        foreach ($propertyName in $abandonmentProperties) {
            if ($null -eq $receipt.PSObject.Properties[$propertyName]) {
                throw "Milestone revision authorization is missing '$propertyName'."
            }
        }
        $previousAbandonmentPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot -RelativePath (
                [string]$receipt.previous_abandonment_receipt_path
            ) -Label 'Previous milestone revision abandonment'
        if (-not (Test-Path -LiteralPath $previousAbandonmentPath -PathType Leaf)) {
            throw 'Previous milestone revision abandonment receipt is missing.'
        }
        $previousAbandonment = Get-Content -LiteralPath $previousAbandonmentPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        $previousAbandonmentPayload = [ordered]@{}
        foreach ($property in $previousAbandonment.PSObject.Properties) {
            if ($property.Name -ne 'receipt_hash') {
                $previousAbandonmentPayload[$property.Name] = $property.Value
            }
        }
        $previousAbandonmentEvent = @($prefixAbandonments | Where-Object {
            [int]$_.sequence -eq [int]$receipt.previous_abandonment_event_sequence
        })
        if ($previousAbandonmentEvent.Count -ne 1 -or
            [string]$previousAbandonment.receipt_hash -ne (
                Get-TextSha256 (
                    $previousAbandonmentPayload | ConvertTo-Json -Compress -Depth 100
                )
            ) -or
            [string]$previousAbandonment.run_id -ne [string]$receipt.run_id -or
            [string]$previousAbandonment.milestone_id -ne
                [string]$receipt.milestone_id -or
            [string]$previousAbandonment.decision -ne 'abandoned' -or
            [bool]$previousAbandonment.completion_eligible -or
            [string]$receipt.previous_abandonment_receipt_hash -ne
                [string]$previousAbandonment.receipt_hash -or
            [string]$receipt.previous_abandonment_revision_id -ne
                [string]$previousAbandonment.revision_id -or
            [string]$receipt.previous_abandonment_event_hash -ne
                [string]$previousAbandonmentEvent[0].hash -or
            [string]$previousAbandonmentEvent[0].
                milestone_revision_abandonment_receipt_path -ne
                [string]$receipt.previous_abandonment_receipt_path -or
            [string]$previousAbandonmentEvent[0].
                milestone_revision_abandonment_receipt_hash -ne
                [string]$previousAbandonment.receipt_hash) {
            throw 'Milestone revision authorization previous abandonment binding changed.'
        }
    }
    if ([string]$receipt.schema_version -eq '1.1') {
        $previousSelectionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot -RelativePath (
                [string]$receipt.previous_revision_selection_receipt_path
            ) -Label 'Previous milestone revision selection'
        $previousSelection = Read-DurableReviewMilestoneRevisionSelection `
            -Path $previousSelectionPath -RunDirectory $runRoot
        $previousSelectionEvent = $prefixSelections[-1]
        $expectedPreviousRelative = [IO.Path]::GetRelativePath(
            $runRoot, $previousSelectionPath
        ).Replace('\', '/')
        if ([string]$receipt.previous_revision_selection_receipt_path -ne
                $expectedPreviousRelative -or
            [string]$receipt.previous_activation_receipt_path -ne
                $expectedPreviousRelative -or
            [string]$receipt.previous_revision_selection_receipt_hash -ne
                [string]$previousSelection.receipt_hash -or
            [string]$receipt.previous_activation_receipt_hash -ne
                [string]$previousSelection.receipt_hash -or
            [int]$receipt.previous_revision_selection_event_sequence -ne
                [int]$previousSelectionEvent.sequence -or
            [string]$receipt.previous_revision_selection_event_hash -ne
                [string]$previousSelectionEvent.hash -or
            [string]$previousSelectionEvent.milestone_activation_receipt_path -ne
                $expectedPreviousRelative -or
            [string]$previousSelectionEvent.milestone_activation_receipt_hash -ne
                [string]$previousSelection.receipt_hash -or
            [int]$previousSelection.revision_index -ne
                [int]$prefixSelections.Count -or
            [string]$previousSelection.milestone_id -ne
                [string]$receipt.milestone_id -or
            [string]$receipt.previous_source_bindings_hash -ne
                [string]$previousSelection.source_bindings_hash -or
            [string]$previousSelection.checkpoint_material_hash -eq
                [string]$receipt.checkpoint_material_hash -or
            [string]$previousSelection.input_manifest_hash -eq
                [string]$receipt.input_manifest_hash) {
            throw (
                'Milestone revision authorization previous selection binding ' +
                'changed.'
            )
        }
        $computedOpen = Get-MilestoneRevisionOpenOccurrenceInventory `
            -RunDirectory $runRoot -Plan $plan `
            -MilestoneId ([string]$receipt.milestone_id) `
            -SourceBindings @($previousSelection.source_bindings)
        $computedOpenJson = ConvertTo-Json -InputObject @(
            $computedOpen.occurrences
        ) -Compress -Depth 50
        $declaredOpenJson = ConvertTo-Json -InputObject @(
            $receipt.previous_open_occurrences
        ) -Compress -Depth 50
        if ([int]$computedOpen.count -lt 1 -or
            [int]$receipt.previous_open_occurrence_count -ne
                [int]$computedOpen.count -or
            [string]$receipt.previous_open_occurrences_hash -ne
                [string]$computedOpen.hash -or
            $declaredOpenJson -ne $computedOpenJson) {
            throw (
                'Milestone revision authorization open finding occurrence ' +
                'conservation changed.'
            )
        }
    }

    foreach ($bindingName in @(
        'previous_source_bindings', 'required_sources',
        'review_material_bindings'
    )) {
        $hashName = $bindingName + '_hash'
        if ([string]$receipt.$hashName -ne (
            Get-TextSha256 (
                @($receipt.$bindingName) |
                    ConvertTo-Json -Compress -Depth 50
            )
        )) {
            throw "Milestone revision '$bindingName' hash changed."
        }
    }
    $requiredSourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids) |
            ForEach-Object { [string]$_ }
    )
    if (@($receipt.required_sources).Count -ne $requiredSourceIds.Count) {
        throw 'Milestone revision required source set is incomplete.'
    }
    foreach ($sourceNodeId in $requiredSourceIds) {
        $matches = @($receipt.required_sources | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $node = @($plan.nodes | Where-Object {
            [string]$_.id -eq $sourceNodeId
        }) | Select-Object -First 1
        $sourceHistoryAtAuthorization = @($events |
            Select-Object -First $eventCount | Where-Object {
                [string]$_.node_id -eq $sourceNodeId -and
                -not [string]::IsNullOrWhiteSpace([string]$_.thread_id)
            })
        if ($matches.Count -ne 1 -or $null -eq $node -or
            [string]$matches[0].role_id -ne [string]$node.role_id -or
            [string]::IsNullOrWhiteSpace([string]$matches[0].thread_id) -or
            $sourceHistoryAtAuthorization.Count -eq 0 -or
            [string]$matches[0].thread_id -ne
                [string]$sourceHistoryAtAuthorization[-1].thread_id -or
            -not [bool]$node.read_only -or
            [bool]$node.allow_delegation -or
            @($node.write_scope).Count -gt 0) {
            throw "Milestone revision source '$sourceNodeId' binding is invalid."
        }
        $materialMatches = @($receipt.review_material_bindings |
            Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
        if ($materialMatches.Count -ne 1) {
            throw "Milestone revision source '$sourceNodeId' material is missing."
        }
        $previousMatches = @($receipt.previous_source_bindings |
            Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
        if ($previousMatches.Count -ne 1 -or
            [string]$matches[0].thread_id -ne
                [string]$previousMatches[0].source_thread_id) {
            throw "Milestone revision source '$sourceNodeId' predecessor is missing."
        }
        $previousBindingArguments = @{
            RunDirectory = $runRoot
            Plan = $plan
            SourceNodeId = $sourceNodeId
            DispositionRelativePath =
                [string]$previousMatches[0].disposition_receipt_path
            ExpectedMilestoneId = [string]$receipt.milestone_id
        }
        if ([string]$receipt.schema_version -eq '1.1') {
            $previousBindingArguments.RequireResultMilestoneBinding = $true
        } else {
            $previousBindingArguments.AllowHistoricalMilestoneAlias = $true
        }
        $currentPrevious = Get-DurableReviewDispositionBinding `
            @previousBindingArguments
        if ((ConvertTo-Json -InputObject $currentPrevious -Compress -Depth 50) -ne
            (ConvertTo-Json -InputObject $previousMatches[0] `
                -Compress -Depth 50)) {
            throw "Milestone revision source '$sourceNodeId' predecessor changed."
        }
        $materialPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$materialMatches[0].material_path) `
            -Label 'Milestone revision review material'
        if (-not (Test-Path -LiteralPath $materialPath -PathType Leaf) -or
            [string]$materialMatches[0].material_hash -ne (
                Get-FileHash -LiteralPath $materialPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Milestone revision review material binding changed.'
        }
    }
    foreach ($fileBinding in @(
        @('checkpoint_material_path', 'checkpoint_material_hash'),
        @('input_manifest_path', 'input_manifest_hash'),
        @('review_material_manifest_path', 'review_material_manifest_hash'),
        @('excluded_evidence_manifest_path', 'excluded_evidence_manifest_hash'),
        @('authorization_material_path', 'authorization_material_hash'),
        @(
            'acceptance_authorization_material_path',
            'acceptance_authorization_material_hash'
        ),
        @(
            'acceptance_evidence_material_path',
            'acceptance_evidence_material_hash'
        )
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$receipt.($fileBinding[0])) `
            -Label 'Milestone revision bound material'
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            [string]$receipt.($fileBinding[1]) -ne (
                Get-FileHash -LiteralPath $boundPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Milestone revision bound material changed.'
        }
    }
    $authorizationMaterial = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_material_path) `
        -Label 'Milestone revision authorization material'
    if ([string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $authorizationMaterial -Raw)
    )) {
        throw 'Milestone revision controller authorization is empty.'
    }
    $acceptanceAuthorizationPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot -RelativePath (
            [string]$receipt.acceptance_authorization_material_path
        ) -Label 'Milestone revision acceptance authorization'
    $acceptanceAuthorization = Get-Content -LiteralPath (
        $acceptanceAuthorizationPath
    ) -Raw | ConvertFrom-Json -Depth 30 -DateKind String
    if ([string]$acceptanceAuthorization.schema_version -ne '1.0' -or
        [string]$acceptanceAuthorization.milestone_id -ne
            [string]$receipt.milestone_id -or
        [string]$acceptanceAuthorization.main_node_id -ne
            [string]$receipt.main_node_id -or
        [string]$acceptanceAuthorization.acceptance_key -ne
            [string]$receipt.acceptance_key -or
        [string]$acceptanceAuthorization.evidence_material_path -ne
            [string]$receipt.acceptance_evidence_material_path -or
        [string]$acceptanceAuthorization.evidence_material_hash -ne
            [string]$receipt.acceptance_evidence_material_hash) {
        throw 'Milestone revision acceptance authorization changed.'
    }
    $excludedFile = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.excluded_evidence_manifest_path) `
        -Label 'Milestone revision excluded evidence manifest'
    $excludedFromFile = @(
        Get-Content -LiteralPath $excludedFile -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
    )
    if ((Get-TextSha256 (
        ConvertTo-Json -InputObject @($excludedFromFile) -Compress -Depth 100
    )) -ne (Get-TextSha256 (
        ConvertTo-Json -InputObject @($receipt.excluded_evidence) `
            -Compress -Depth 100
    ))) {
        throw 'Milestone revision excluded evidence content changed.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new()
    $actualEvents = [Collections.Generic.List[object]]::new()
    $actualArtifacts = [Collections.Generic.List[object]]::new()
    foreach ($item in @($receipt.excluded_evidence)) {
        foreach ($name in @(
            'source_node_id', 'reason', 'event_bindings', 'artifacts'
        )) {
            if ($null -eq $item.PSObject.Properties[$name]) {
                throw "Milestone revision excluded entry is missing '$name'."
            }
        }
        $sourceNodeId = [string]$item.source_node_id
        if ($sourceNodeId -notin $requiredSourceIds -or
            -not $seen.Add($sourceNodeId) -or
            [string]$item.reason -ne
                'caller-timing-error/non-completion evidence') {
            throw 'Milestone revision excluded evidence entry changed.'
        }
        foreach ($eventBinding in @($item.event_bindings)) {
            $sequence = [int]$eventBinding.sequence
            if ($sequence -lt 0 -or $sequence -ge $eventCount -or
                [string]$events[$sequence].hash -ne
                    [string]$eventBinding.event_hash -or
                [string]$events[$sequence].node_id -ne $sourceNodeId) {
                throw 'Milestone revision excluded event binding changed.'
            }
            $actualEvents.Add([pscustomobject]@{
                source_node_id = $sourceNodeId
                event_sequence = $sequence
                event_hash = [string]$eventBinding.event_hash
            })
        }
        foreach ($artifact in @($item.artifacts)) {
            foreach ($name in @('type', 'path', 'file_hash', 'internal_hash')) {
                if ($null -eq $artifact.PSObject.Properties[$name]) {
                    throw "Milestone revision excluded artifact lacks '$name'."
                }
            }
            $artifactPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
                -RelativePath ([string]$artifact.path) `
                -Label 'Milestone revision excluded artifact'
            if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                [string]$artifact.file_hash -ne (
                    Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
                ).Hash.ToLowerInvariant()) {
                throw 'Milestone revision excluded artifact file changed.'
            }
            if ([string]$artifact.type -ne 'capture') {
                $document = Get-Content -LiteralPath $artifactPath -Raw |
                    ConvertFrom-Json -Depth 100 -DateKind String
                if ([string]$artifact.internal_hash -ne
                    [string]$document.receipt_hash) {
                    throw 'Milestone revision excluded artifact identity changed.'
                }
            } elseif (-not [string]::IsNullOrEmpty(
                [string]$artifact.internal_hash
            )) {
                throw 'Raw excluded captures cannot claim a receipt hash.'
            }
            $actualArtifacts.Add([pscustomobject]@{
                key = "$sourceNodeId`n$([string]$artifact.path)"
                source_node_id = $sourceNodeId
                type = [string]$artifact.type
                path = ([string]$artifact.path).Replace('\', '/')
                file_hash = [string]$artifact.file_hash
                internal_hash = [string]$artifact.internal_hash
            })
        }
    }
    $inventory = Get-MilestoneRevisionExcludedInventory `
        -RunDirectory $runRoot -Events $events `
        -RequiredSourceIds $requiredSourceIds `
        -CheckpointHash ([string]$receipt.checkpoint_material_hash) `
        -EventCount $eventCount
    if ((ConvertTo-Json -InputObject @($actualEvents |
            Sort-Object source_node_id, event_sequence) `
            -Compress -Depth 100) -ne
        (ConvertTo-Json -InputObject @($inventory.events) `
            -Compress -Depth 100) -or
        (ConvertTo-Json -InputObject @($actualArtifacts |
            Sort-Object key) -Compress -Depth 100) -ne
        (ConvertTo-Json -InputObject @($inventory.artifacts) `
            -Compress -Depth 100)) {
        throw (
            'Milestone revision excluded evidence omitted or changed a related ' +
            'pre-authorization event or artifact.'
        )
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
    )) {
        throw 'Milestone revision authorization receipt hash mismatch.'
    }
    Set-OrchestrationValidatedObjectCacheValue -Descriptor $cacheDescriptor `
        -Value $receipt
    $validationSucceeded = $true
    return $receipt
    } finally {
        Exit-OrchestrationValidationContext -Token $validationToken `
            -ValidateSnapshot:$validationSucceeded
    }
}

function Get-DurableReviewMilestoneRevisionRearmEvent {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object[]] $Events,
        [Parameter(Mandatory)][object] $Authorization,
        [Parameter(Mandatory)][object] $RequiredSource,
        [Parameter(Mandatory)][int] $AuthorizationEventSequence
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $sourceNodeId = [string]$RequiredSource.source_node_id
    $sourceThreadId = [string]$RequiredSource.thread_id
    $sourceRoleId = [string]$RequiredSource.role_id
    $authorizationEvents = @($Events | Where-Object {
        [int]$_.sequence -eq $AuthorizationEventSequence -and
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$Authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$Authorization.receipt_hash
    })
    if ($authorizationEvents.Count -ne 1) {
        throw "Milestone revision source '$sourceNodeId' authorization event is ambiguous."
    }
    $authorizationEvent = $authorizationEvents[0]
    $sourceEvents = @($Events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [int]$_.sequence -gt $AuthorizationEventSequence
    })
    $adopted = @($sourceEvents | Where-Object {
        [string]$_.prior_state -eq 'adopted' -and
        [string]$_.status -eq 'running' -and
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.role_id -eq $sourceRoleId -and
        [string]$_.thread_id -eq $sourceThreadId -and
        [string]$_.milestone_revision_id -eq
            [string]$Authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            [string]$authorizationEvent.milestone_revision_authorization_receipt_path -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$Authorization.receipt_hash -and
        [string]$_.milestone_revision_checkpoint_hash -eq
            [string]$Authorization.checkpoint_material_hash -and
        [string]$_.milestone_revision_input_hash -eq
            [string]$Authorization.input_manifest_hash
    })
    if ($adopted.Count -gt 1) {
        throw "Milestone revision source '$sourceNodeId' has multiple fresh re-arms."
    }
    if ($adopted.Count -eq 1) {
        return $adopted[0]
    }

    if ($null -eq $Authorization.PSObject.Properties['previous_abandonment_receipt_path']) {
        throw "Milestone revision source '$sourceNodeId' lacks one fresh re-arm."
    }
    $abandonmentPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$Authorization.previous_abandonment_receipt_path) `
        -Label 'Previous milestone revision abandonment'
    $abandonment = Read-DurableReviewMilestoneRevisionAbandonment `
        -Path $abandonmentPath -RunDirectory $runRoot
    if ([string]$Authorization.previous_abandonment_receipt_hash -ne
            [string]$abandonment.receipt_hash -or
        [string]$Authorization.previous_abandonment_revision_id -ne
            [string]$abandonment.revision_id) {
        throw "Milestone revision source '$sourceNodeId' abandonment binding changed."
    }
    $oldSource = @($abandonment.required_sources | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
    })
    if ($oldSource.Count -ne 1 -or
        [string]$oldSource[0].role_id -ne $sourceRoleId -or
        [string]$oldSource[0].thread_id -ne $sourceThreadId) {
        throw "Milestone revision source '$sourceNodeId' abandonment source binding changed."
    }
    $abandonmentRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($abandonmentPath)
    ).Replace('\', '/')
    $cancelled = @($Events | Where-Object {
        [int]$_.sequence -lt $AuthorizationEventSequence -and
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.role_id -eq $sourceRoleId -and
        [string]$_.thread_id -eq $sourceThreadId -and
        [string]$_.prior_state -eq 'running' -and
        [string]$_.status -eq 'cancelled' -and
        [string]$_.milestone_id -eq [string]$Authorization.milestone_id -and
        [string]$_.milestone_revision_id -eq [string]$abandonment.revision_id -and
        [string]$_.milestone_revision_abandonment_receipt_path -eq
            $abandonmentRelativePath -and
        [string]$_.milestone_revision_abandonment_receipt_hash -eq
            [string]$abandonment.receipt_hash
    })
    $sourceEventsBeforeAuthorization = @($Events | Where-Object {
        [int]$_.sequence -lt $AuthorizationEventSequence -and
        [string]$_.node_id -eq $sourceNodeId
    } | Sort-Object sequence)
    $lastSourceEvent = if ($sourceEventsBeforeAuthorization.Count -gt 0) {
        $sourceEventsBeforeAuthorization[-1]
    } else { $null }
    $cancelledRearm = @($sourceEvents | Where-Object {
        [string]$_.prior_state -eq 'cancelled' -and
        [string]$_.status -eq 'running' -and
        [string]$_.node_id -eq $sourceNodeId -and
        [string]$_.role_id -eq $sourceRoleId -and
        [string]$_.thread_id -eq $sourceThreadId -and
        [string]$_.milestone_revision_id -eq
            [string]$Authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            [string]$authorizationEvent.milestone_revision_authorization_receipt_path -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$Authorization.receipt_hash -and
        [string]$_.milestone_revision_checkpoint_hash -eq
            [string]$Authorization.checkpoint_material_hash -and
        [string]$_.milestone_revision_input_hash -eq
        [string]$Authorization.input_manifest_hash
    })
    if ($cancelled.Count -ne 1 -or $cancelledRearm.Count -ne 1 -or
        $null -eq $lastSourceEvent -or
        [int]$cancelled[0].sequence -ne [int]$lastSourceEvent.sequence -or
        [int]$cancelled[0].sequence -le
            [int]$abandonment.source_journal_event_count) {
        throw "Milestone revision source '$sourceNodeId' lacks one fresh re-arm."
    }
    return $cancelledRearm[0]
}

function Get-OrchestrationRunContentSnapshot {
    param([Parameter(Mandatory)][string] $RunDirectory)

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
        throw 'Orchestration validation run directory does not exist.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($file in @(
        Get-ChildItem -LiteralPath $runRoot -File -Recurse -Force |
            Sort-Object FullName
    )) {
        $relative = [IO.Path]::GetRelativePath(
            $runRoot, [IO.Path]::GetFullPath($file.FullName)
        ).Replace('\', '/')
        $entries.Add([pscustomobject][ordered]@{
            relative_path = $relative
            length = [long]$file.Length
            file_hash = (
                Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        })
    }
    $entryJson = ConvertTo-Json -InputObject @($entries) -Compress -Depth 10
    $planEntry = @($entries | Where-Object {
        [string]$_.relative_path -ceq 'plan.json'
    })
    $runEntry = @($entries | Where-Object {
        [string]$_.relative_path -ceq 'run.json'
    })
    $journalEntry = @($entries | Where-Object {
        [string]$_.relative_path -ceq 'events.jsonl'
    })
    if ($planEntry.Count -ne 1 -or $runEntry.Count -ne 1 -or
        $journalEntry.Count -ne 1) {
        throw 'Orchestration validation snapshot lacks plan, run, or journal.'
    }
    $journalLines = @(
        Get-Content -LiteralPath (Join-Path $runRoot 'events.jsonl') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($journalLines.Count -lt 1) {
        throw 'Orchestration validation snapshot has an empty journal.'
    }
    $journalHead = $journalLines[-1] |
        ConvertFrom-Json -Depth 30 -DateKind String
    return [pscustomobject]@{
        entries = @($entries)
        snapshot_hash = Get-TextSha256 $entryJson
        plan_hash = [string]$planEntry[0].file_hash
        run_hash = [string]$runEntry[0].file_hash
        journal_path = [IO.Path]::GetFullPath(
            (Join-Path $runRoot 'events.jsonl')
        )
        journal_hash = [string]$journalEntry[0].file_hash
        journal_event_count = $journalLines.Count
        journal_head = [string]$journalHead.hash
    }
}

function Enter-OrchestrationValidationContext {
    param([Parameter(Mandatory)][string] $RunDirectory)

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    if ($null -eq $script:OrchestrationValidationContext) {
        $script:OrchestrationValidationContext = [pscustomobject]@{
            run_root = $runRoot
            depth = 1
            snapshot = Get-OrchestrationRunContentSnapshot `
                -RunDirectory $runRoot
            verified_objects =
                [Collections.Generic.Dictionary[string, string]]::new(
                    [StringComparer]::Ordinal
                )
            journal_json = ''
        }
        return [pscustomobject]@{
            owner = $true
            context = $script:OrchestrationValidationContext
        }
    }
    if ([string]$script:OrchestrationValidationContext.run_root -cne $runRoot) {
        throw 'Nested orchestration validation cannot change run directory.'
    }
    $script:OrchestrationValidationContext.depth =
        [int]$script:OrchestrationValidationContext.depth + 1
    return [pscustomobject]@{
        owner = $false
        context = $script:OrchestrationValidationContext
    }
}

function Assert-OrchestrationValidationContextUnchanged {
    param(
        [Parameter(Mandatory)][object] $Context,
        [switch] $AllowAdditionalFiles
    )

    $current = Get-OrchestrationRunContentSnapshot `
        -RunDirectory ([string]$Context.run_root)
    $expectedEntries = @($Context.snapshot.entries)
    $currentEntries = @($current.entries)
    foreach ($expected in $expectedEntries) {
        $matches = @($currentEntries | Where-Object {
            [string]$_.relative_path -ceq [string]$expected.relative_path
        })
        if ($matches.Count -ne 1 -or
            [long]$matches[0].length -ne [long]$expected.length -or
            [string]$matches[0].file_hash -ne [string]$expected.file_hash) {
            throw 'Orchestration validation inputs changed during verification.'
        }
    }
    if (-not $AllowAdditionalFiles -and
        $currentEntries.Count -ne $expectedEntries.Count) {
        throw 'Orchestration validation file set changed during verification.'
    }
}

function Exit-OrchestrationValidationContext {
    param(
        [Parameter(Mandatory)][object] $Token,
        [switch] $ValidateSnapshot
    )

    $context = $Token.context
    if ($null -eq $script:OrchestrationValidationContext -or
        -not [object]::ReferenceEquals(
            $script:OrchestrationValidationContext, $context
        )) {
        throw 'Orchestration validation context ownership changed.'
    }
    $context.depth = [int]$context.depth - 1
    if ([int]$context.depth -lt 0) {
        $script:OrchestrationValidationContext = $null
        throw 'Orchestration validation context depth is invalid.'
    }
    if ([bool]$Token.owner) {
        try {
            if ([int]$context.depth -ne 0) {
                throw 'Orchestration validation context has unclosed readers.'
            }
            if ($ValidateSnapshot) {
                Assert-OrchestrationValidationContextUnchanged -Context $context
            }
        } finally {
            $context.verified_objects.Clear()
            $context.journal_json = ''
            $script:OrchestrationValidationContext = $null
        }
    }
}

function Get-OrchestrationValidatedObjectCacheDescriptor {
    param(
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [string] $Expectation = ''
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $context = $script:OrchestrationValidationContext
    if ($null -eq $context -or
        [string]$context.run_root -cne $runRoot) {
        throw 'Validated object cache requires an active run-scoped context.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Validated $Kind receipt does not exist."
    }
    $fileHash = (
        Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $relativePath = [IO.Path]::GetRelativePath($runRoot, $fullPath).
        Replace('\', '/')
    $snapshotEntry = @($context.snapshot.entries | Where-Object {
        [string]$_.relative_path -ceq $relativePath
    })
    if ($snapshotEntry.Count -ne 1 -or
        [string]$snapshotEntry[0].file_hash -ne $fileHash) {
        throw "Validated $Kind receipt changed after context creation."
    }
    return [pscustomobject]@{
        cache_key = Get-TextSha256 (
            $Kind + '|' + $runRoot + '|' + $fullPath + '|' +
            $fileHash + '|' + $Expectation + '|' +
            [string]$context.snapshot.plan_hash + '|' +
            [string]$context.snapshot.run_hash + '|' +
            [string]$context.snapshot.journal_hash + '|' +
            [string]$context.snapshot.journal_event_count + '|' +
            [string]$context.snapshot.journal_head
        )
    }
}

function Get-OrchestrationValidatedObjectCacheValue {
    param([Parameter(Mandatory)][object] $Descriptor)

    $key = [string]$Descriptor.cache_key
    $context = $script:OrchestrationValidationContext
    if ($null -eq $context -or
        -not $context.verified_objects.ContainsKey($key)) {
        return $null
    }
    return $context.verified_objects[$key] |
        ConvertFrom-Json -Depth 100 -DateKind String
}

function Set-OrchestrationValidatedObjectCacheValue {
    param(
        [Parameter(Mandatory)][object] $Descriptor,
        [Parameter(Mandatory)][object] $Value
    )

    $context = $script:OrchestrationValidationContext
    if ($null -eq $context) {
        throw 'Validated object cache requires an active run-scoped context.'
    }
    $context.verified_objects[
        [string]$Descriptor.cache_key
    ] = ConvertTo-Json -InputObject $Value -Compress -Depth 100
}

function Get-ReplacementMilestoneRevisionResultBinding {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $SourceNodeId,
        [Parameter(Mandatory)][string] $ThreadId,
        [Parameter(Mandatory)][string] $MilestoneId,
        [Parameter(Mandatory)][string] $CheckpointMaterialPath,
        [Parameter(Mandatory)][string] $CheckpointMaterialHash,
        [Parameter(Mandatory)][object] $ReplacementContinuity,
        [Parameter(Mandatory)][string] $ReplacementContinuityReceiptRelativePath,
        [Parameter(Mandatory)][string] $AuthorizationReceiptRelativePath,
        [Parameter(Mandatory)][object[]] $Events,
        [switch] $RequireUnselected
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath $AuthorizationReceiptRelativePath `
        -Label 'Milestone revision authorization receipt'
    if (-not (Test-Path -LiteralPath $authorizationPath -PathType Leaf)) {
        throw 'Milestone revision authorization receipt does not exist.'
    }
    $authorization = Get-Content -LiteralPath $authorizationPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    foreach ($name in @(
        'schema_version', 'run_id', 'plan_hash', 'genesis_hash',
        'milestone_id', 'milestone_index',
        'revision_id', 'revision_index', 'previous_source_bindings',
        'previous_source_bindings_hash', 'required_sources',
        'required_sources_hash', 'source_journal_head',
        'source_journal_event_count', 'checkpoint_material_path',
        'checkpoint_material_hash', 'input_manifest_path',
        'input_manifest_hash', 'receipt_hash'
    )) {
        if ($null -eq $authorization.PSObject.Properties[$name]) {
            throw "Milestone revision authorization is missing '$name'."
        }
    }
    $authorizationPayload = [ordered]@{}
    foreach ($property in $authorization.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $authorizationPayload[$property.Name] = $property.Value
        }
    }
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    if ([string]$authorization.schema_version -ne '1.1' -or
        [int]$authorization.revision_index -lt 2 -or
        [string]$authorization.run_id -ne [string]$run.run_id -or
        [string]$authorization.plan_hash -ne [string]$run.plan_hash -or
        [string]$authorization.genesis_hash -ne [string]$Events[0].hash -or
        [int]$authorization.milestone_index -ne 0 -or
        [string]$plan.durable_review_profile.milestone_ids[0] -ne $MilestoneId -or
        [string]$authorization.milestone_id -ne $MilestoneId -or
        [string]$authorization.checkpoint_material_path -ne
            $CheckpointMaterialPath -or
        [string]$authorization.checkpoint_material_hash -ne
            $CheckpointMaterialHash -or
        [string]$authorization.previous_source_bindings_hash -ne (
            Get-TextSha256 (
                @($authorization.previous_source_bindings) |
                    ConvertTo-Json -Compress -Depth 50
            )
        ) -or [string]$authorization.required_sources_hash -ne (
            Get-TextSha256 (
                @($authorization.required_sources) |
                    ConvertTo-Json -Compress -Depth 50
            )
        ) -or [string]$authorization.receipt_hash -ne (
            Get-TextSha256 (
                $authorizationPayload | ConvertTo-Json -Compress -Depth 100
            )
        )) {
        throw (
            'Replacement result milestone revision authorization does not ' +
            'match its milestone or checkpoint.'
        )
    }
    foreach ($fileBinding in @(
        @('checkpoint_material_path', 'checkpoint_material_hash'),
        @('input_manifest_path', 'input_manifest_hash')
    )) {
        $boundPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$authorization.($fileBinding[0])) `
            -Label 'Milestone revision result-bound material'
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf) -or
            [string]$authorization.($fileBinding[1]) -ne (
                Get-FileHash -LiteralPath $boundPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Milestone revision result-bound material changed.'
        }
    }
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $SourceNodeId
    })
    $requiredSource = @($authorization.required_sources | Where-Object {
        [string]$_.source_node_id -eq $SourceNodeId
    })
    $previousSource = @($authorization.previous_source_bindings | Where-Object {
        [string]$_.source_node_id -eq $SourceNodeId
    })
    if ($node.Count -ne 1 -or $requiredSource.Count -ne 1 -or
        $previousSource.Count -ne 1 -or
        [string]$requiredSource[0].role_id -ne [string]$node[0].role_id -or
        [string]$requiredSource[0].thread_id -ne $ThreadId -or
        [string]$previousSource[0].source_thread_id -ne $ThreadId -or
        [string]$ReplacementContinuity.source_node_id -ne $SourceNodeId -or
        [string]$ReplacementContinuity.role_id -ne [string]$node[0].role_id -or
        [string]$ReplacementContinuity.replacement_thread_id -ne $ThreadId -or
        [string]$ReplacementContinuity.checkpoint_hash -eq
            $CheckpointMaterialHash -or
        [string]$ReplacementContinuity.input_manifest_hash -eq
            [string]$authorization.input_manifest_hash) {
        throw (
            'Replacement result milestone revision changed source, role, ' +
            'thread, checkpoint, or input.'
        )
    }

    $previousResultPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$previousSource[0].result_receipt_path) `
        -Label 'Previous milestone revision result receipt'
    $previousDispositionPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot -RelativePath (
            [string]$previousSource[0].disposition_receipt_path
        ) -Label 'Previous milestone revision disposition receipt'
    if (-not (Test-Path -LiteralPath $previousResultPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $previousDispositionPath -PathType Leaf) -or
        [string]$previousSource[0].result_file_hash -ne (
            Get-FileHash -LiteralPath $previousResultPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]$previousSource[0].disposition_file_hash -ne (
            Get-FileHash -LiteralPath $previousDispositionPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Previous milestone revision source artifacts changed.'
    }
    $previousResult = Get-Content -LiteralPath $previousResultPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $previousDisposition = Get-Content -LiteralPath $previousDispositionPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$previousResult.source_kind -ne 'replacement' -or
        [string]$previousResult.source_node_id -ne $SourceNodeId -or
        [string]$previousResult.thread_id -ne $ThreadId -or
        [string]$previousResult.receipt_hash -ne
            [string]$previousSource[0].result_receipt_hash -or
        [string]$previousResult.receipt_hash -ne (
            Get-ThreadResultReceiptCanonicalHash -Receipt $previousResult
        ) -or [string]$previousDisposition.receipt_hash -ne
            [string]$previousSource[0].disposition_receipt_hash -or
        [string]$previousResult.replacement_continuity_receipt_path -ne
            $ReplacementContinuityReceiptRelativePath) {
        throw 'Previous milestone revision result is not the same replacement seat.'
    }
    if ([string]$previousResult.replacement_continuity_receipt_hash -ne
            [string]$ReplacementContinuity.receipt_hash) {
        throw 'Previous milestone revision result changed replacement continuity.'
    }

    $authorizationEvents = @($Events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq
            [string]$authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            $AuthorizationReceiptRelativePath -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$authorization.receipt_hash -and
        [string]$_.milestone_revision_checkpoint_hash -eq
            $CheckpointMaterialHash -and
        [string]$_.milestone_revision_input_hash -eq
            [string]$authorization.input_manifest_hash
    })
    if ($authorizationEvents.Count -ne 1 -or
        [int]$authorizationEvents[0].sequence -ne
            [int]$authorization.source_journal_event_count -or
        [string]$authorizationEvents[0].prev_hash -ne
            [string]$authorization.source_journal_head) {
        throw 'Replacement result milestone revision authorization event changed.'
    }
    if ($RequireUnselected -and @($Events | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected' -and
        [string]$_.milestone_revision_id -eq
            [string]$authorization.revision_id
    }).Count -gt 0) {
        throw 'Replacement result milestone revision is already selected.'
    }
    $authorizationEvent = $authorizationEvents[0]
    $rearmEvent = Get-DurableReviewMilestoneRevisionRearmEvent `
        -RunDirectory $runRoot -Events $Events -Authorization $authorization `
        -RequiredSource $requiredSource[0] `
        -AuthorizationEventSequence ([int]$authorizationEvent.sequence)
    if (@($Events | Where-Object {
        [string]$_.node_id -eq $SourceNodeId -and
        [string]$_.thread_id -eq $ThreadId -and
        [int]$_.sequence -ge [int]$authorizationEvent.sequence -and
        $null -ne $_.PSObject.Properties[
            'replacement_roll_forward_receipt_path'
        ]
    }).Count -gt 0) {
        throw (
            'Replacement result cannot combine milestone revision and ' +
            'checkpoint roll-forward authority.'
        )
    }
    return [pscustomobject][ordered]@{
        source_role_id = [string]$node[0].role_id
        authorization = $authorization
        authorization_receipt_path = $AuthorizationReceiptRelativePath
        authorization_receipt_hash = [string]$authorization.receipt_hash
        authorization_event_sequence = [int]$authorizationEvent.sequence
        authorization_event_hash = [string]$authorizationEvent.hash
        rearm_event_sequence = [int]$rearmEvent.sequence
        rearm_event_hash = [string]$rearmEvent.hash
        input_manifest_path = [string]$authorization.input_manifest_path
        input_manifest_hash = [string]$authorization.input_manifest_hash
    }
}

function Get-MilestoneRevisionLifecycleCorrectionSources {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Plan,
        [Parameter(Mandatory)][object] $Authorization,
        [Parameter(Mandatory)][object[]] $Events,
        [Parameter(Mandatory)][object[]] $SelectionItems,
        [object[]] $DeclaredCorrections
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $authorizationEvents = @($Events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$Authorization.revision_id
    })
    if ($authorizationEvents.Count -ne 1) {
        throw 'Milestone revision lifecycle correction authorization is ambiguous.'
    }
    $requiredSources = @($Authorization.required_sources)
    $declaredMode = $PSBoundParameters.ContainsKey('DeclaredCorrections')
    if ($SelectionItems.Count -ne $requiredSources.Count -or
        ($declaredMode -and
            @($DeclaredCorrections).Count -ne $requiredSources.Count)) {
        throw 'Milestone revision lifecycle correction source set is incomplete.'
    }
    $excludedSequences = @($Authorization.excluded_evidence |
        ForEach-Object { @($_.event_bindings) } |
        ForEach-Object { [int]$_.sequence })
    $excludedPaths = @($Authorization.excluded_evidence |
        ForEach-Object { @($_.artifacts) } |
        ForEach-Object { [string]$_.path })
    $corrections = [Collections.Generic.List[object]]::new()
    foreach ($requiredSource in $requiredSources) {
        $sourceNodeId = [string]$requiredSource.source_node_id
        $node = @($Plan.nodes | Where-Object {
            [string]$_.id -eq $sourceNodeId
        })
        $selection = @($SelectionItems | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $declared = @(if ($declaredMode) {
            $DeclaredCorrections | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            }
        })
        if ($node.Count -ne 1 -or $selection.Count -ne 1 -or
            ($declaredMode -and $declared.Count -ne 1)) {
            throw (
                "Milestone revision lifecycle correction source " +
                "'$sourceNodeId' is missing or repeated."
            )
        }
        $binding = Get-DurableReviewDispositionBinding `
            -RunDirectory $runRoot -Plan $Plan -SourceNodeId $sourceNodeId `
            -DispositionRelativePath (
                [string]$selection[0].disposition_receipt_path
            ) -ExpectedMilestoneId ([string]$Authorization.milestone_id) `
            -RequireResultMilestoneBinding
        if ([string]$binding.source_thread_id -ne
                [string]$requiredSource.thread_id -or
            [string]$binding.checkpoint_material_hash -ne
                [string]$Authorization.checkpoint_material_hash -or
            [string]$binding.result_receipt_path -in $excludedPaths -or
            [string]$binding.disposition_receipt_path -in $excludedPaths) {
            throw (
                "Milestone revision lifecycle correction source " +
                "'$sourceNodeId' changed its thread, checkpoint, or evidence."
            )
        }
        $sourceEvents = @($Events | Where-Object {
            [string]$_.node_id -eq $sourceNodeId -and
            [int]$_.sequence -gt [int]$authorizationEvents[0].sequence
        })
        $rearms = @(
            Get-DurableReviewMilestoneRevisionRearmEvent `
                -RunDirectory $runRoot -Events $Events `
                -Authorization $Authorization -RequiredSource $requiredSource `
                -AuthorizationEventSequence ([int]$authorizationEvents[0].sequence)
        )
        if ($declaredMode) {
            foreach ($name in @(
                'source_node_id', 'role_id', 'source_thread_id',
                'rearm_event_sequence', 'rearm_event_hash',
                'completed_event_sequence', 'completed_event_hash',
                'validated_event_sequence', 'validated_event_hash',
                'adopted_event_sequence', 'adopted_event_hash',
                'result_receipt_path', 'result_receipt_hash',
                'result_file_hash', 'disposition_receipt_path',
                'disposition_receipt_hash', 'disposition_file_hash',
                'error_class'
            )) {
                if ($null -eq $declared[0].PSObject.Properties[$name]) {
                    throw (
                        "Milestone revision lifecycle correction source " +
                        "'$sourceNodeId' is missing '$name'."
                    )
                }
            }
            $rearm = @($Events | Where-Object {
                [int]$_.sequence -eq [int]$declared[0].rearm_event_sequence -and
                [string]$_.hash -eq [string]$declared[0].rearm_event_hash
            })
            $completed = @($Events | Where-Object {
                [int]$_.sequence -eq
                    [int]$declared[0].completed_event_sequence -and
                [string]$_.hash -eq [string]$declared[0].completed_event_hash
            })
            $validated = @($Events | Where-Object {
                [int]$_.sequence -eq
                    [int]$declared[0].validated_event_sequence -and
                [string]$_.hash -eq [string]$declared[0].validated_event_hash
            })
            $adopted = @($Events | Where-Object {
                [int]$_.sequence -eq [int]$declared[0].adopted_event_sequence -and
                [string]$_.hash -eq [string]$declared[0].adopted_event_hash
            })
            if ($rearm.Count -ne 1 -or $completed.Count -ne 1 -or
                $validated.Count -ne 1 -or $adopted.Count -ne 1) {
                throw (
                    "Milestone revision lifecycle correction source " +
                    "'$sourceNodeId' event binding changed."
                )
            }
            $rearm = $rearm[0]
            $completed = $completed[0]
            $validated = $validated[0]
            $adopted = $adopted[0]
        } else {
            $rearm = $rearms[0]
            $completed = @($sourceEvents | Where-Object {
                [string]$_.status -eq 'completed' -and
                [int]$_.sequence -gt [int]$rearm.sequence
            }) | Select-Object -Last 1
            $validated = @($sourceEvents | Where-Object {
                [string]$_.status -eq 'validated' -and
                [int]$_.sequence -gt [int]$rearm.sequence
            }) | Select-Object -Last 1
            $adopted = @($sourceEvents | Where-Object {
                [string]$_.status -eq 'adopted' -and
                [int]$_.sequence -gt [int]$rearm.sequence
            }) | Select-Object -Last 1
        }
        if ($null -eq $completed -or $null -eq $validated -or
            $null -eq $adopted -or
            [int]$rearm.sequence -ne [int]$rearms[0].sequence -or
            [string]$rearm.hash -ne [string]$rearms[0].hash -or
            [string]$completed.node_id -ne $sourceNodeId -or
            [string]$validated.node_id -ne $sourceNodeId -or
            [string]$adopted.node_id -ne $sourceNodeId -or
            [string]$completed.role_id -ne [string]$requiredSource.role_id -or
            [string]$validated.role_id -ne [string]$requiredSource.role_id -or
            [string]$adopted.role_id -ne [string]$requiredSource.role_id -or
            [string]$completed.thread_id -ne [string]$requiredSource.thread_id -or
            [string]$validated.thread_id -ne [string]$requiredSource.thread_id -or
            [string]$adopted.thread_id -ne [string]$requiredSource.thread_id -or
            [string]$completed.prior_state -ne 'running' -or
            [string]$completed.status -ne 'completed' -or
            [string]$validated.prior_state -ne 'completed' -or
            [string]$validated.status -ne 'validated' -or
            [string]$adopted.prior_state -ne 'validated' -or
            [string]$adopted.status -ne 'adopted' -or
            [int]$authorizationEvents[0].sequence -ge [int]$rearm.sequence -or
            [int]$rearm.sequence -ge [int]$completed.sequence -or
            [int]$completed.sequence -ge [int]$validated.sequence -or
            [int]$validated.sequence -ge [int]$adopted.sequence -or
            @($rearm, $completed, $validated, $adopted | Where-Object {
                [int]$_.sequence -in $excludedSequences
            }).Count -gt 0) {
            throw (
                "Milestone revision lifecycle correction source " +
                "'$sourceNodeId' has another error shape."
            )
        }
        $resultPointer = "artifact:$($binding.result_receipt_path)"
        $dispositionPointer = "artifact:$($binding.disposition_receipt_path)"
        $validatedEvidence = @($validated.evidence)
        $validatedArtifacts = @($validatedEvidence | Where-Object {
            [string]$_ -match '^artifact:'
        })
        $validatedNonArtifacts = @($validatedEvidence | Where-Object {
            [string]$_ -notmatch '^artifact:'
        })
        if (@($completed.evidence).Count -ne 1 -or
            [string]$completed.evidence[0] -cne $resultPointer -or
            $validatedArtifacts.Count -ne 1 -or
            [string]$validatedArtifacts[0] -cne $resultPointer -or
            @($validatedNonArtifacts | Where-Object {
                [string]$_ -notmatch '^(test|source|observation):\S.+$'
            }).Count -gt 0 -or
            @($adopted.evidence).Count -ne 1 -or
            [string]$adopted.evidence[0] -cne $dispositionPointer) {
            throw (
                'Milestone revision lifecycle correction only accepts the ' +
                'exact validated-result-pointer error shape: one result artifact ' +
                'plus typed non-artifact evidence.'
            )
        }
        $computed = [pscustomobject][ordered]@{
            source_node_id = $sourceNodeId
            role_id = [string]$requiredSource.role_id
            source_thread_id = [string]$requiredSource.thread_id
            rearm_event_sequence = [int]$rearm.sequence
            rearm_event_hash = [string]$rearm.hash
            completed_event_sequence = [int]$completed.sequence
            completed_event_hash = [string]$completed.hash
            validated_event_sequence = [int]$validated.sequence
            validated_event_hash = [string]$validated.hash
            adopted_event_sequence = [int]$adopted.sequence
            adopted_event_hash = [string]$adopted.hash
            result_receipt_path = [string]$binding.result_receipt_path
            result_receipt_hash = [string]$binding.result_receipt_hash
            result_file_hash = [string]$binding.result_file_hash
            disposition_receipt_path =
                [string]$binding.disposition_receipt_path
            disposition_receipt_hash =
                [string]$binding.disposition_receipt_hash
            disposition_file_hash = [string]$binding.disposition_file_hash
            error_class = 'validated-missing-disposition-pointer'
        }
        if ($declaredMode -and
            (ConvertTo-Json -InputObject $computed -Compress -Depth 100) -cne
            (ConvertTo-Json -InputObject $declared[0] -Compress -Depth 100)) {
            throw (
                "Milestone revision lifecycle correction source " +
                "'$sourceNodeId' binding changed."
            )
        }
        $corrections.Add($computed)
    }
    return @($corrections)
}

function Read-DurableReviewMilestoneRevisionLifecycleCorrection {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Milestone revision lifecycle correction receipt does not exist.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    foreach ($name in @(
        'schema_version', 'run_id', 'plan_hash', 'genesis_hash',
        'milestone_id', 'milestone_index', 'revision_id', 'revision_index',
        'authorization_receipt_path', 'authorization_receipt_hash',
        'selection_key', 'source_journal_head', 'source_journal_event_count',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'input_manifest_path', 'input_manifest_hash',
        'selection_material_path', 'selection_material_hash',
        'source_corrections', 'source_corrections_hash',
        'authorization_material_path', 'authorization_material_hash',
        'correction_key', 'created_at_utc', 'receipt_hash'
    )) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone revision lifecycle correction is missing '$name'."
        }
    }
    $plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    $supersessionReceiptPath = Join-Path (Join-Path $runRoot 'receipts') (
        "durable-review-milestone.$($receipt.milestone_id)." +
        "revision-$($receipt.revision_id).inventory-supersession.json"
    )
    if ((Test-Path -LiteralPath $supersessionReceiptPath -PathType Leaf) -or
        @($events | Where-Object {
            [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
            [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
        }).Count -gt 0) {
        throw (
            'Milestone revision lifecycle correction cannot be combined with ' +
            'inventory supersession.'
        )
    }
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_receipt_path) `
        -Label 'Milestone revision lifecycle correction authorization'
    $authorization = Read-DurableReviewMilestoneRevisionAuthorization `
        -Path $authorizationPath -RunDirectory $runRoot
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.genesis_hash -ne [string]$events[0].hash -or
        [string]$receipt.milestone_id -ne [string]$authorization.milestone_id -or
        [int]$receipt.milestone_index -ne 0 -or
        [string]$receipt.revision_id -ne [string]$authorization.revision_id -or
        [int]$receipt.revision_index -ne [int]$authorization.revision_index -or
        [string]$receipt.authorization_receipt_hash -ne
            [string]$authorization.receipt_hash -or
        [string]$receipt.selection_key -cne
            [string]$authorization.selection_key -or
        [string]$receipt.checkpoint_material_path -ne
            [string]$authorization.checkpoint_material_path -or
        [string]$receipt.checkpoint_material_hash -ne
            [string]$authorization.checkpoint_material_hash -or
        [string]$receipt.input_manifest_path -ne
            [string]$authorization.input_manifest_path -or
        [string]$receipt.input_manifest_hash -ne
            [string]$authorization.input_manifest_hash -or
        [string]$receipt.correction_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Milestone revision lifecycle correction binding is invalid.'
    }
    if ([string]$receipt.source_corrections_hash -ne (
        Get-TextSha256 (
            ConvertTo-Json -InputObject @($receipt.source_corrections) `
                -Compress -Depth 100
        )
    )) {
        throw 'Milestone revision lifecycle correction source hash changed.'
    }
    $selectionMaterial = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.selection_material_path) `
        -Label 'Milestone revision lifecycle correction selection material'
    $authorizationMaterial = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_material_path) `
        -Label 'Milestone revision lifecycle correction authorization material'
    if (-not (Test-Path -LiteralPath $selectionMaterial -PathType Leaf) -or
        [string]$receipt.selection_material_hash -ne (
            Get-FileHash -LiteralPath $selectionMaterial -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        -not (Test-Path -LiteralPath $authorizationMaterial -PathType Leaf) -or
        [string]$receipt.authorization_material_hash -ne (
            Get-FileHash -LiteralPath $authorizationMaterial -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $authorizationMaterial -Raw)
        )) {
        throw 'Milestone revision lifecycle correction material changed.'
    }
    $selectionItems = @(
        Get-Content -LiteralPath $selectionMaterial -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
    )
    $computedCorrections =
        Get-MilestoneRevisionLifecycleCorrectionSources `
            -RunDirectory $runRoot -Plan $plan -Authorization $authorization `
            -Events $events -SelectionItems $selectionItems `
            -DeclaredCorrections @($receipt.source_corrections)
    if ((ConvertTo-Json -InputObject @($computedCorrections) `
            -Compress -Depth 100) -cne
        (ConvertTo-Json -InputObject @($receipt.source_corrections) `
            -Compress -Depth 100)) {
        throw 'Milestone revision lifecycle correction sources changed.'
    }
    $eventCount = [int]$receipt.source_journal_event_count
    if ($eventCount -lt 1 -or $eventCount -ge $events.Count -or
        [string]$events[$eventCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision lifecycle correction journal binding changed.'
    }
    $relativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    $expectedPath = (
        "receipts/durable-review-milestone.$($receipt.milestone_id)." +
        "revision-$($receipt.revision_id).lifecycle-correction.json"
    )
    $matchingEvents = @($events | Where-Object {
        [string]$_.event -eq
            'milestone-revision-lifecycle-evidence-corrected' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id -and
        [string]$_.milestone_activation_receipt_path -eq $relativePath -and
        [string]$_.milestone_activation_receipt_hash -eq
            [string]$receipt.receipt_hash -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            [string]$receipt.authorization_receipt_path -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$receipt.authorization_receipt_hash -and
        [string]$_.milestone_revision_selection_key -ceq
            [string]$receipt.selection_key
    })
    if ($relativePath -cne $expectedPath -or $matchingEvents.Count -ne 1 -or
        [int]$matchingEvents[0].sequence -ne $eventCount -or
        [string]$matchingEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head -or
        [string]$matchingEvents[0].idempotency_key -cne
            [string]$receipt.correction_key) {
        throw (
            'Milestone revision lifecycle correction lacks its exact ' +
            'append-only journal event.'
        )
    }
    $selectionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
    })
    if ($selectionEvents.Count -gt 1 -or
        ($selectionEvents.Count -eq 1 -and
            [int]$selectionEvents[0].sequence -le $eventCount)) {
        throw 'Milestone revision lifecycle correction selection order changed.'
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
    )) {
        throw 'Milestone revision lifecycle correction receipt hash mismatch.'
    }
    return $receipt
}

function Get-MilestoneRevisionCumulativeInventory {
    param(
        [Parameter(Mandatory)][object] $PreviousResult,
        [Parameter(Mandatory)][object] $PreviousDisposition,
        [Parameter(Mandatory)][object] $CurrentResult,
        [Parameter(Mandatory)][object] $CurrentDisposition
    )

    $previousFindings = @($PreviousResult.pending_findings)
    $previousDecisions = @($PreviousDisposition.decisions)
    $currentFindings = @($CurrentResult.pending_findings)
    $currentDecisions = @($CurrentDisposition.decisions)
    $previousFindingById = @{}
    $previousDecisionById = @{}
    $currentFindingById = @{}
    $currentDecisionById = @{}
    foreach ($finding in $previousFindings) {
        $previousFindingById[[string]$finding.finding_id] = $finding
    }
    foreach ($decision in $previousDecisions) {
        $previousDecisionById[[string]$decision.source_finding_id] = $decision
    }
    foreach ($finding in $currentFindings) {
        $currentFindingById[[string]$finding.finding_id] = $finding
    }
    foreach ($decision in $currentDecisions) {
        $currentDecisionById[[string]$decision.source_finding_id] = $decision
    }

    $effectiveFindings = [Collections.Generic.List[object]]::new()
    $effectiveDecisions = [Collections.Generic.List[object]]::new()
    $restored = [Collections.Generic.List[object]]::new()
    foreach ($oldDecision in $previousDecisions) {
        $findingId = [string]$oldDecision.source_finding_id
        if (-not $previousFindingById.ContainsKey($findingId)) {
            throw "Previous cumulative finding '$findingId' lacks its result record."
        }
        $hasCurrentFinding = $currentFindingById.ContainsKey($findingId)
        $hasCurrentDecision = $currentDecisionById.ContainsKey($findingId)
        if ($hasCurrentFinding -ne $hasCurrentDecision) {
            throw "Current cumulative finding '$findingId' is only partially declared."
        }
        if ($hasCurrentFinding) {
            $oldFinding = $previousFindingById[$findingId]
            $newFinding = $currentFindingById[$findingId]
            $newDecision = $currentDecisionById[$findingId]
            if ([string]$newFinding.finding_id -ne $findingId -or
                [string]$newFinding.severity -ne [string]$oldFinding.severity -or
                [string]$newFinding.text -ne [string]$oldFinding.text -or
                [string]$newFinding.text_hash -ne [string]$oldFinding.text_hash -or
                [string]$newDecision.source_finding_id -ne $findingId -or
                [string]$newDecision.severity -ne [string]$oldDecision.severity -or
                [string]$newDecision.finding -ne [string]$oldDecision.finding -or
                [string]$newDecision.finding_hash -ne
                    [string]$oldDecision.finding_hash -or
                [string]$newDecision.canonical_finding_id -ne
                    [string]$oldDecision.canonical_finding_id) {
                throw "Cumulative finding '$findingId' changed identity or severity."
            }
            $effectiveFindings.Add($newFinding)
            $effectiveDecisions.Add($newDecision)
        } else {
            $oldFinding = $previousFindingById[$findingId]
            $effectiveFindings.Add($oldFinding)
            $effectiveDecisions.Add($oldDecision)
            $restored.Add([pscustomobject][ordered]@{
                source_finding_id = $findingId
                pending_finding = $oldFinding
                pending_finding_hash = Get-TextSha256 (
                    ConvertTo-Json -InputObject $oldFinding -Compress -Depth 30
                )
                decision = $oldDecision
                decision_hash = Get-TextSha256 (
                    ConvertTo-Json -InputObject $oldDecision -Compress -Depth 30
                )
            })
        }
    }
    foreach ($currentDecision in $currentDecisions) {
        $findingId = [string]$currentDecision.source_finding_id
        if ($previousDecisionById.ContainsKey($findingId)) {
            continue
        }
        if (-not $currentFindingById.ContainsKey($findingId)) {
            throw "Current cumulative finding '$findingId' lacks its result record."
        }
        $effectiveFindings.Add($currentFindingById[$findingId])
        $effectiveDecisions.Add($currentDecision)
    }
    return [pscustomobject][ordered]@{
        pending_findings = @($effectiveFindings)
        pending_findings_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @($effectiveFindings) `
                -Compress -Depth 100
        )
        decisions = @($effectiveDecisions)
        decisions_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @($effectiveDecisions) `
                -Compress -Depth 100
        )
        restored_occurrences = @($restored)
        restored_occurrences_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @($restored) -Compress -Depth 100
        )
        restored_occurrence_count = @($restored).Count
    }
}

function Read-DurableReviewMilestoneRevisionInventorySupersession {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $validationToken = Enter-OrchestrationValidationContext `
        -RunDirectory $runRoot
    $validationSucceeded = $false
    try {
    $cacheDescriptor = Get-OrchestrationValidatedObjectCacheDescriptor `
        -Kind 'milestone-revision-inventory-supersession' -Path $Path `
        -RunDirectory $runRoot
    $cached = Get-OrchestrationValidatedObjectCacheValue `
        -Descriptor $cacheDescriptor
    if ($null -ne $cached) {
        $validationSucceeded = $true
        return $cached
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Milestone revision inventory supersession receipt does not exist.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    foreach ($name in @(
        'schema_version', 'run_id', 'plan_hash', 'genesis_hash',
        'milestone_id', 'milestone_index', 'revision_id', 'revision_index',
        'authorization_receipt_path', 'authorization_receipt_hash',
        'selection_key', 'source_journal_head', 'source_journal_event_count',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'input_manifest_path', 'input_manifest_hash',
        'original_selection_material_path',
        'original_selection_material_hash',
        'superseded_selection_material_path',
        'superseded_selection_material_hash',
        'source_supersessions', 'source_supersessions_hash',
        'authorization_material_path', 'authorization_material_hash',
        'supersession_key', 'created_at_utc', 'receipt_hash'
    )) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone revision inventory supersession is missing '$name'."
        }
    }
    $plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_receipt_path) `
        -Label 'Milestone revision inventory supersession authorization'
    $authorization = Read-DurableReviewMilestoneRevisionAuthorization `
        -Path $authorizationPath -RunDirectory $runRoot
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.genesis_hash -ne [string]$events[0].hash -or
        [string]$receipt.milestone_id -ne [string]$authorization.milestone_id -or
        [int]$receipt.milestone_index -ne 0 -or
        [string]$receipt.revision_id -ne [string]$authorization.revision_id -or
        [int]$receipt.revision_index -ne [int]$authorization.revision_index -or
        [string]$receipt.authorization_receipt_hash -ne
            [string]$authorization.receipt_hash -or
        [string]$receipt.selection_key -cne
            [string]$authorization.selection_key -or
        [string]$receipt.checkpoint_material_path -ne
            [string]$authorization.checkpoint_material_path -or
        [string]$receipt.checkpoint_material_hash -ne
            [string]$authorization.checkpoint_material_hash -or
        [string]$receipt.input_manifest_path -ne
            [string]$authorization.input_manifest_path -or
        [string]$receipt.input_manifest_hash -ne
            [string]$authorization.input_manifest_hash -or
        [string]$receipt.supersession_key -cnotmatch
            '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Milestone revision inventory supersession binding is invalid.'
    }
    $authorizationEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
    })
    if ($authorizationEvents.Count -ne 1) {
        throw 'Milestone revision inventory supersession authorization is ambiguous.'
    }
    $correctionReceiptPath = Join-Path (Join-Path $runRoot 'receipts') (
        "durable-review-milestone.$($receipt.milestone_id)." +
        "revision-$($receipt.revision_id).lifecycle-correction.json"
    )
    if ((Test-Path -LiteralPath $correctionReceiptPath -PathType Leaf) -or
        @($events | Where-Object {
            [string]$_.event -eq
                'milestone-revision-lifecycle-evidence-corrected' -and
            [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
        }).Count -gt 0) {
        throw (
            'Milestone revision inventory supersession cannot be combined ' +
            'with lifecycle correction.'
        )
    }
    if ([string]$receipt.source_supersessions_hash -ne (
        Get-TextSha256 (
            ConvertTo-Json -InputObject @($receipt.source_supersessions) `
                -Compress -Depth 100
        )
    )) {
        throw 'Milestone revision inventory supersession source hash changed.'
    }
    $originalSelectionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.original_selection_material_path) `
        -Label 'Original milestone revision selection material'
    $supersededSelectionPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.superseded_selection_material_path) `
        -Label 'Superseded milestone revision selection material'
    $authorizationMaterialPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_material_path) `
        -Label 'Milestone revision inventory supersession authorization material'
    if ([string]$receipt.original_selection_material_hash -ne (
            Get-FileHash -LiteralPath $originalSelectionPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]$receipt.superseded_selection_material_hash -ne (
            Get-FileHash -LiteralPath $supersededSelectionPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]$receipt.authorization_material_hash -ne (
            Get-FileHash -LiteralPath $authorizationMaterialPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $authorizationMaterialPath -Raw)
        )) {
        throw 'Milestone revision inventory supersession material changed.'
    }
    $originalItems = @(
        Get-Content -LiteralPath $originalSelectionPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
    )
    $supersededItems = @(
        Get-Content -LiteralPath $supersededSelectionPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
    )
    $requiredSources = @($authorization.required_sources)
    if ($originalItems.Count -ne $requiredSources.Count -or
        $supersededItems.Count -ne $requiredSources.Count -or
        @($receipt.source_supersessions).Count -ne $requiredSources.Count) {
        throw 'Milestone revision inventory supersession source set is incomplete.'
    }
    $excludedSequences = @($authorization.excluded_evidence |
        ForEach-Object { @($_.event_bindings) } |
        ForEach-Object { [int]$_.sequence })
    $excludedPaths = @($authorization.excluded_evidence |
        ForEach-Object { @($_.artifacts) } |
        ForEach-Object { [string]$_.path })
    $restoredTotal = 0
    foreach ($requiredSource in $requiredSources) {
        $sourceNodeId = [string]$requiredSource.source_node_id
        $originalItem = @($originalItems | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $supersededItem = @($supersededItems | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $declared = @($receipt.source_supersessions | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        if ($originalItem.Count -ne 1 -or $supersededItem.Count -ne 1 -or
            $declared.Count -ne 1) {
            throw "Inventory supersession source '$sourceNodeId' is not unique."
        }
        foreach ($name in @(
            'source_node_id', 'role_id', 'source_thread_id', 'source_kind',
            'rearm_event_sequence', 'rearm_event_hash',
            'completed_event_sequence', 'completed_event_hash',
            'validated_event_sequence', 'validated_event_hash',
            'adopted_event_sequence', 'adopted_event_hash',
            'previous_binding', 'current_binding', 'superseded_binding',
            'restored_occurrences', 'restored_occurrences_hash',
            'restored_occurrence_count', 'effective_pending_findings_hash',
            'effective_decisions_hash'
        )) {
            if ($null -eq $declared[0].PSObject.Properties[$name]) {
                throw "Inventory supersession source '$sourceNodeId' lacks '$name'."
            }
        }
        if ([string]$declared[0].role_id -ne
                [string]$requiredSource.role_id -or
            [string]$declared[0].source_thread_id -ne
                [string]$requiredSource.thread_id) {
            throw "Inventory supersession source '$sourceNodeId' changed role or thread."
        }
        $currentBinding = Get-DurableReviewDispositionBinding `
            -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
            -DispositionRelativePath (
                [string]$originalItem[0].disposition_receipt_path
            ) -ExpectedMilestoneId ([string]$authorization.milestone_id) `
            -RequireResultMilestoneBinding
        $previousDeclared = @($authorization.previous_source_bindings |
            Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
        if ($previousDeclared.Count -ne 1) {
            throw 'Inventory supersession predecessor binding is incomplete.'
        }
        $previousBinding = Get-DurableReviewDispositionBinding `
            -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
            -DispositionRelativePath (
                [string]$previousDeclared[0].disposition_receipt_path
            ) -ExpectedMilestoneId ([string]$authorization.milestone_id) `
            -RequireResultMilestoneBinding
        $supersededBinding = Get-DurableReviewDispositionBinding `
            -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
            -DispositionRelativePath (
                [string]$supersededItem[0].disposition_receipt_path
            ) -ExpectedMilestoneId ([string]$authorization.milestone_id) `
            -RequireResultMilestoneBinding
        foreach ($comparison in @(
            @($previousBinding, $previousDeclared[0], 'previous'),
            @($currentBinding, $declared[0].current_binding, 'current'),
            @($supersededBinding, $declared[0].superseded_binding, 'superseded'),
            @($previousBinding, $declared[0].previous_binding, 'previous declared')
        )) {
            if ((ConvertTo-Json -InputObject $comparison[0] `
                    -Compress -Depth 100) -cne
                (ConvertTo-Json -InputObject $comparison[1] `
                    -Compress -Depth 100)) {
                throw (
                    "Inventory supersession source '$sourceNodeId' " +
                    "$($comparison[2]) binding changed."
                )
            }
        }
        if ([string]$currentBinding.source_thread_id -ne
                [string]$requiredSource.thread_id -or
            [string]$currentBinding.checkpoint_material_hash -ne
                [string]$authorization.checkpoint_material_hash -or
            [string]$currentBinding.result_receipt_path -in $excludedPaths -or
            [string]$currentBinding.disposition_receipt_path -in $excludedPaths) {
            throw "Inventory supersession source '$sourceNodeId' changed scope."
        }
        $boundEvents = [ordered]@{}
        foreach ($eventBinding in @(
            @{ name = 'rearm'; sequence = 'rearm_event_sequence'; hash = 'rearm_event_hash' },
            @{ name = 'completed'; sequence = 'completed_event_sequence'; hash = 'completed_event_hash' },
            @{ name = 'validated'; sequence = 'validated_event_sequence'; hash = 'validated_event_hash' },
            @{ name = 'adopted'; sequence = 'adopted_event_sequence'; hash = 'adopted_event_hash' }
        )) {
            $bound = @($events | Where-Object {
                [int]$_.sequence -eq [int]$declared[0].$($eventBinding.sequence) -and
                [string]$_.hash -eq [string]$declared[0].$($eventBinding.hash)
            })
            if ($bound.Count -ne 1 -or
                [string]$bound[0].node_id -ne $sourceNodeId) {
                throw "Inventory supersession source '$sourceNodeId' lifecycle changed."
            }
            $boundEvents[$eventBinding.name] = $bound[0]
        }
        $rearm = $boundEvents.rearm
        $completed = $boundEvents.completed
        $validated = $boundEvents.validated
        $adopted = $boundEvents.adopted
        if ([string]$rearm.prior_state -ne 'adopted' -or
            [string]$rearm.status -ne 'running' -or
            [string]$rearm.role_id -ne [string]$requiredSource.role_id -or
            [string]$rearm.thread_id -ne [string]$requiredSource.thread_id -or
            [string]$rearm.milestone_revision_id -ne
                [string]$authorization.revision_id -or
            [string]$rearm.milestone_revision_authorization_receipt_hash -ne
                [string]$authorization.receipt_hash -or
            [string]$completed.prior_state -ne 'running' -or
            [string]$completed.status -ne 'completed' -or
            [string]$validated.prior_state -ne 'completed' -or
            [string]$validated.status -ne 'validated' -or
            [string]$adopted.prior_state -ne 'validated' -or
            [string]$adopted.status -ne 'adopted' -or
            @($completed, $validated, $adopted | Where-Object {
                [string]$_.role_id -ne [string]$requiredSource.role_id -or
                [string]$_.thread_id -ne [string]$requiredSource.thread_id
            }).Count -gt 0 -or
            [int]$authorizationEvents[0].sequence -ge [int]$rearm.sequence -or
            [int]$rearm.sequence -ge [int]$completed.sequence -or
            [int]$completed.sequence -ge [int]$validated.sequence -or
            [int]$validated.sequence -ge [int]$adopted.sequence -or
            @($rearm, $completed, $validated, $adopted | Where-Object {
                [int]$_.sequence -in $excludedSequences
            }).Count -gt 0 -or
            "artifact:$($currentBinding.result_receipt_path)" -notin
                @($completed.evidence) -or
            "artifact:$($currentBinding.disposition_receipt_path)" -notin
                @($validated.evidence) -or
            "artifact:$($currentBinding.disposition_receipt_path)" -notin
                @($adopted.evidence)) {
            throw "Inventory supersession source '$sourceNodeId' lifecycle is invalid."
        }
        $previousResultPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$previousBinding.result_receipt_path) `
            -Label 'Previous cumulative result receipt'
        $previousDispositionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$previousBinding.disposition_receipt_path) `
            -Label 'Previous cumulative disposition receipt'
        $currentResultPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$currentBinding.result_receipt_path) `
            -Label 'Current cumulative result receipt'
        $currentDispositionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$currentBinding.disposition_receipt_path) `
            -Label 'Current cumulative disposition receipt'
        $supersededResultPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$supersededBinding.result_receipt_path) `
            -Label 'Superseded cumulative result receipt'
        $supersededDispositionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$supersededBinding.disposition_receipt_path) `
            -Label 'Superseded cumulative disposition receipt'
        $previousResult = Read-ThreadResultReceipt -Path $previousResultPath `
            -ExpectedThreadId ([string]$previousBinding.source_thread_id) `
            -ExpectedSourceNodeId $sourceNodeId -RunDirectory $runRoot
        $previousDisposition = Read-ReviewDispositionReceipt `
            -Path $previousDispositionPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$previousBinding.source_thread_id)
        $currentResult = Read-ThreadResultReceipt -Path $currentResultPath `
            -ExpectedThreadId ([string]$currentBinding.source_thread_id) `
            -ExpectedSourceNodeId $sourceNodeId -RunDirectory $runRoot
        $currentDisposition = Read-ReviewDispositionReceipt `
            -Path $currentDispositionPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$currentBinding.source_thread_id)
        $supersededResult = Read-ThreadResultReceipt `
            -Path $supersededResultPath `
            -ExpectedThreadId ([string]$supersededBinding.source_thread_id) `
            -ExpectedSourceNodeId $sourceNodeId -RunDirectory $runRoot
        $supersededDisposition = Read-ReviewDispositionReceipt `
            -Path $supersededDispositionPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$supersededBinding.source_thread_id)
        $inventory = Get-MilestoneRevisionCumulativeInventory `
            -PreviousResult $previousResult `
            -PreviousDisposition $previousDisposition `
            -CurrentResult $currentResult `
            -CurrentDisposition $currentDisposition
        $expectedResultPayload = [ordered]@{}
        foreach ($property in $currentResult.PSObject.Properties) {
            if ($property.Name -eq 'receipt_hash') { continue }
            if ($property.Name -eq 'pending_findings') {
                $expectedResultPayload[$property.Name] =
                    @($inventory.pending_findings)
            } elseif ($property.Name -in @(
                'adopted_findings', 'rejected_findings'
            )) {
                $expectedResultPayload[$property.Name] = @($property.Value)
            } else {
                $expectedResultPayload[$property.Name] = $property.Value
            }
        }
        $actualResultPayload = [ordered]@{}
        foreach ($property in $supersededResult.PSObject.Properties) {
            if ($property.Name -ne 'receipt_hash') {
                $actualResultPayload[$property.Name] = $property.Value
            }
        }
        $blocking = @($inventory.decisions | Where-Object {
            [string]$_.severity -in @('P0', 'P1') -and
            [string]$_.resolution_status -ne 'resolved'
        } | ForEach-Object { [string]$_.finding })
        $expectedDispositionPayload = [ordered]@{}
        foreach ($property in $currentDisposition.PSObject.Properties) {
            if ($property.Name -eq 'receipt_hash') { continue }
            switch ($property.Name) {
                'source_result_receipt_path' {
                    $expectedDispositionPayload[$property.Name] =
                        [string]$supersededBinding.result_receipt_path
                }
                'source_result_receipt_hash' {
                    $expectedDispositionPayload[$property.Name] =
                        [string]$supersededResult.receipt_hash
                }
                'decisions' {
                    $expectedDispositionPayload[$property.Name] =
                        @($inventory.decisions)
                }
                'blocking_open' {
                    $expectedDispositionPayload[$property.Name] = $blocking
                }
                default {
                    $expectedDispositionPayload[$property.Name] = $property.Value
                }
            }
        }
        $actualDispositionPayload = [ordered]@{}
        foreach ($property in $supersededDisposition.PSObject.Properties) {
            if ($property.Name -ne 'receipt_hash') {
                $actualDispositionPayload[$property.Name] = $property.Value
            }
        }
        if ((ConvertTo-Json -InputObject $expectedResultPayload `
                -Compress -Depth 100) -cne
            (ConvertTo-Json -InputObject $actualResultPayload `
                -Compress -Depth 100) -or
            (ConvertTo-Json -InputObject $expectedDispositionPayload `
                -Compress -Depth 100) -cne
            (ConvertTo-Json -InputObject $actualDispositionPayload `
                -Compress -Depth 100) -or
            [string]$declared[0].source_kind -ne
                [string]$currentResult.source_kind -or
            [string]$declared[0].restored_occurrences_hash -ne
                [string]$inventory.restored_occurrences_hash -or
            [int]$declared[0].restored_occurrence_count -ne
                [int]$inventory.restored_occurrence_count -or
            [string]$declared[0].effective_pending_findings_hash -ne
                [string]$inventory.pending_findings_hash -or
            [string]$declared[0].effective_decisions_hash -ne
                [string]$inventory.decisions_hash -or
            (ConvertTo-Json -InputObject @(
                $declared[0].restored_occurrences
            ) -Compress -Depth 100) -cne
            (ConvertTo-Json -InputObject @(
                $inventory.restored_occurrences
            ) -Compress -Depth 100)) {
            throw (
                "Inventory supersession source '$sourceNodeId' changed " +
                'finding status, evidence, or effective artifacts.'
            )
        }
        $restoredTotal += [int]$inventory.restored_occurrence_count
    }
    if ($restoredTotal -lt 1) {
        throw 'Milestone revision inventory supersession restored no occurrence.'
    }
    $eventCount = [int]$receipt.source_journal_event_count
    if ($eventCount -lt 1 -or $eventCount -ge $events.Count -or
        [string]$events[$eventCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision inventory supersession journal binding changed.'
    }
    $relativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    $expectedPath = (
        "receipts/durable-review-milestone.$($receipt.milestone_id)." +
        "revision-$($receipt.revision_id).inventory-supersession.json"
    )
    $matchingEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id -and
        [string]$_.milestone_activation_receipt_path -eq $relativePath -and
        [string]$_.milestone_activation_receipt_hash -eq
            [string]$receipt.receipt_hash -and
        [string]$_.milestone_revision_authorization_receipt_path -eq
            [string]$receipt.authorization_receipt_path -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$receipt.authorization_receipt_hash -and
        [string]$_.milestone_revision_selection_key -ceq
            [string]$receipt.selection_key
    })
    if ($relativePath -cne $expectedPath -or $matchingEvents.Count -ne 1 -or
        [int]$matchingEvents[0].sequence -ne $eventCount -or
        [string]$matchingEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head -or
        [string]$matchingEvents[0].idempotency_key -cne
            [string]$receipt.supersession_key) {
        throw (
            'Milestone revision inventory supersession lacks its exact ' +
            'append-only journal event.'
        )
    }
    $selectionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
    })
    if ($selectionEvents.Count -gt 1 -or
        ($selectionEvents.Count -eq 1 -and
            [int]$selectionEvents[0].sequence -le $eventCount)) {
        throw 'Milestone revision inventory supersession selection order changed.'
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
    )) {
        throw 'Milestone revision inventory supersession receipt hash mismatch.'
    }
    Set-OrchestrationValidatedObjectCacheValue -Descriptor $cacheDescriptor `
        -Value $receipt
    $validationSucceeded = $true
    return $receipt
    } finally {
        Exit-OrchestrationValidationContext -Token $validationToken `
            -ValidateSnapshot:$validationSucceeded
    }
}

function Read-DurableReviewMilestoneRevisionSelection {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $validationToken = Enter-OrchestrationValidationContext `
        -RunDirectory $runRoot
    $validationSucceeded = $false
    try {
    $cacheDescriptor = Get-OrchestrationValidatedObjectCacheDescriptor `
        -Kind 'milestone-revision-selection' -Path $Path `
        -RunDirectory $runRoot
    $cached = Get-OrchestrationValidatedObjectCacheValue `
        -Descriptor $cacheDescriptor
    if ($null -ne $cached) {
        $validationSucceeded = $true
        return $cached
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Milestone revision selection receipt does not exist.'
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'milestone_id',
        'milestone_index', 'revision_id', 'revision_index',
        'authorization_receipt_path', 'authorization_receipt_hash',
        'previous_activation_receipt_path',
        'previous_activation_receipt_hash', 'previous_source_bindings_hash',
        'source_journal_head', 'source_journal_event_count',
        'selection_material_path', 'selection_material_hash',
        'source_bindings', 'source_bindings_hash',
        'source_lifecycle_bindings', 'source_lifecycle_bindings_hash',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'input_manifest_path', 'input_manifest_hash',
        'acceptance_authorization_material_path',
        'acceptance_authorization_material_hash', 'main_node_id',
        'acceptance_key', 'acceptance_evidence_material_path',
        'acceptance_evidence_material_hash', 'selection_key', 'activation_key',
        'created_at_utc', 'receipt_hash'
    )
    if ([string]$receipt.schema_version -eq '1.2') {
        $required += @(
            'lifecycle_correction_receipt_path',
            'lifecycle_correction_receipt_hash',
            'lifecycle_correction_event_sequence',
            'lifecycle_correction_event_hash'
        )
    } elseif ([string]$receipt.schema_version -eq '1.4') {
        $required += @(
            'inventory_supersession_receipt_path',
            'inventory_supersession_receipt_hash',
            'inventory_supersession_event_sequence',
            'inventory_supersession_event_hash'
        )
    }
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone revision selection is missing '$name'."
        }
    }
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
    if ([string]$receipt.schema_version -notin @(
            '1.1', '1.2', '1.3', '1.4'
        ) -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [int]$receipt.milestone_index -ne 0 -or
        [string]$receipt.milestone_id -ne
            [string]$plan.durable_review_profile.milestone_ids[0] -or
        [string]$receipt.selection_key -cne [string]$receipt.activation_key) {
        throw 'Milestone revision selection run or milestone binding is invalid.'
    }
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_receipt_path) `
        -Label 'Milestone revision authorization'
    $authorization = Read-DurableReviewMilestoneRevisionAuthorization `
        -Path $authorizationPath -RunDirectory $runRoot
    $abandonedRevisionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-abandoned' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$_.milestone_revision_abandonment_receipt_hash
        )
    })
    if ($abandonedRevisionEvents.Count -gt 0) {
        throw 'Milestone revision selection cannot consume an abandoned revision.'
    }
    if ([string]$authorization.receipt_hash -ne
            [string]$receipt.authorization_receipt_hash -or
        [string]$authorization.revision_id -ne [string]$receipt.revision_id -or
        [int]$authorization.revision_index -ne [int]$receipt.revision_index -or
        [string]$authorization.previous_activation_receipt_path -ne
            [string]$receipt.previous_activation_receipt_path -or
        [string]$authorization.previous_activation_receipt_hash -ne
            [string]$receipt.previous_activation_receipt_hash -or
        [string]$authorization.previous_source_bindings_hash -ne
            [string]$receipt.previous_source_bindings_hash -or
        [string]$authorization.checkpoint_material_hash -ne
            [string]$receipt.checkpoint_material_hash -or
        [string]$authorization.input_manifest_hash -ne
            [string]$receipt.input_manifest_hash -or
        [string]$authorization.acceptance_authorization_material_path -ne
            [string]$receipt.acceptance_authorization_material_path -or
        [string]$authorization.acceptance_authorization_material_hash -ne
            [string]$receipt.acceptance_authorization_material_hash -or
        [string]$authorization.main_node_id -ne
            [string]$receipt.main_node_id -or
        [string]$authorization.acceptance_key -ne
            [string]$receipt.acceptance_key -or
        [string]$authorization.acceptance_evidence_material_path -ne
            [string]$receipt.acceptance_evidence_material_path -or
        [string]$authorization.acceptance_evidence_material_hash -ne
            [string]$receipt.acceptance_evidence_material_hash -or
        [string]$authorization.selection_key -cne
            [string]$receipt.selection_key) {
        throw 'Milestone revision selection changed its authorization.'
    }
    $lifecycleCorrection = $null
    $inventorySupersession = $null
    $supersessionReceiptName = (
        "durable-review-milestone.$($receipt.milestone_id)." +
        "revision-$($receipt.revision_id).inventory-supersession.json"
    )
    $supersessionReceiptPath = Join-Path (
        Join-Path $runRoot 'receipts'
    ) $supersessionReceiptName
    $supersessionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
    })
    if ([string]$receipt.schema_version -eq '1.2') {
        $correctionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath (
                [string]$receipt.lifecycle_correction_receipt_path
            ) -Label 'Milestone revision lifecycle correction'
        $lifecycleCorrection =
            Read-DurableReviewMilestoneRevisionLifecycleCorrection `
                -Path $correctionPath -RunDirectory $runRoot
        $correctionEvents = @($events | Where-Object {
            [string]$_.event -eq
                'milestone-revision-lifecycle-evidence-corrected' -and
            [int]$_.sequence -eq
                [int]$receipt.lifecycle_correction_event_sequence -and
            [string]$_.hash -eq
                [string]$receipt.lifecycle_correction_event_hash
        })
        if ([string]$lifecycleCorrection.receipt_hash -ne
                [string]$receipt.lifecycle_correction_receipt_hash -or
            [string]$lifecycleCorrection.authorization_receipt_hash -ne
                [string]$authorization.receipt_hash -or
            [string]$lifecycleCorrection.selection_key -cne
                [string]$receipt.selection_key -or
            [string]$lifecycleCorrection.checkpoint_material_hash -ne
                [string]$receipt.checkpoint_material_hash -or
            [string]$lifecycleCorrection.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash -or
            [string]$lifecycleCorrection.selection_material_path -ne
                [string]$receipt.selection_material_path -or
            [string]$lifecycleCorrection.selection_material_hash -ne
                [string]$receipt.selection_material_hash -or
            $correctionEvents.Count -ne 1) {
            throw 'Milestone revision selection changed its lifecycle correction.'
        }
    } elseif ([string]$receipt.schema_version -eq '1.4') {
        $supersessionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot -RelativePath (
                [string]$receipt.inventory_supersession_receipt_path
            ) -Label 'Milestone revision inventory supersession'
        $inventorySupersession =
            Read-DurableReviewMilestoneRevisionInventorySupersession `
                -Path $supersessionPath -RunDirectory $runRoot
        $boundSupersessionEvents = @($events | Where-Object {
            [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
            [int]$_.sequence -eq
                [int]$receipt.inventory_supersession_event_sequence -and
            [string]$_.hash -eq
                [string]$receipt.inventory_supersession_event_hash
        })
        if ([string]$inventorySupersession.receipt_hash -ne
                [string]$receipt.inventory_supersession_receipt_hash -or
            [string]$inventorySupersession.authorization_receipt_hash -ne
                [string]$authorization.receipt_hash -or
            [string]$inventorySupersession.selection_key -cne
                [string]$receipt.selection_key -or
            [string]$inventorySupersession.checkpoint_material_hash -ne
                [string]$receipt.checkpoint_material_hash -or
            [string]$inventorySupersession.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash -or
            [string]$inventorySupersession.
                superseded_selection_material_path -ne
                [string]$receipt.selection_material_path -or
            [string]$inventorySupersession.
                superseded_selection_material_hash -ne
                [string]$receipt.selection_material_hash -or
            $boundSupersessionEvents.Count -ne 1) {
            throw 'Milestone revision selection changed its inventory supersession.'
        }
    } elseif ([string]$receipt.schema_version -eq '1.3') {
        $correctionReceiptName = (
            "durable-review-milestone.$($receipt.milestone_id)." +
            "revision-$($receipt.revision_id).lifecycle-correction.json"
        )
        $correctionReceiptPath = Join-Path (
            Join-Path $runRoot 'receipts'
        ) $correctionReceiptName
        $correctionEvents = @($events | Where-Object {
            [string]$_.event -eq
                'milestone-revision-lifecycle-evidence-corrected' -and
            [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
        })
        if ((Test-Path -LiteralPath $correctionReceiptPath -PathType Leaf) -or
            $correctionEvents.Count -gt 0) {
            throw (
                'Milestone revision replacement selection cannot use a ' +
                'lifecycle evidence correction.'
            )
        }
    }
    if ([string]$receipt.schema_version -ne '1.4' -and
        ((Test-Path -LiteralPath $supersessionReceiptPath -PathType Leaf) -or
            $supersessionEvents.Count -gt 0)) {
        throw (
            'Milestone revision selection ignored an inventory supersession.'
        )
    }
    foreach ($bindingName in @('source_bindings', 'source_lifecycle_bindings')) {
        $hashName = $bindingName + '_hash'
        $json = ConvertTo-Json -InputObject @($receipt.$bindingName) `
            -Compress -Depth 100
        if ([string]$receipt.$hashName -ne (Get-TextSha256 $json)) {
            throw "Milestone revision selection '$bindingName' hash changed."
        }
    }
    $selectionMaterial = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.selection_material_path) `
        -Label 'Milestone revision selection material'
    if (-not (Test-Path -LiteralPath $selectionMaterial -PathType Leaf) -or
        [string]$receipt.selection_material_hash -ne (
            Get-FileHash -LiteralPath $selectionMaterial -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Milestone revision selection material changed.'
    }
    $selectionItems = @(
        Get-Content -LiteralPath $selectionMaterial -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
    )
    $requiredSources = @($authorization.required_sources)
    if ($selectionItems.Count -ne $requiredSources.Count -or
        @($receipt.source_bindings).Count -ne $requiredSources.Count -or
        @($receipt.source_lifecycle_bindings).Count -ne
            $requiredSources.Count) {
        throw 'Milestone revision selection source set is incomplete.'
    }
    $authorizationEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id
    })
    if ($authorizationEvents.Count -ne 1) {
        throw 'Milestone revision selection authorization event is ambiguous.'
    }
    $excludedSequences = @($authorization.excluded_evidence |
        ForEach-Object { @($_.event_bindings) } |
        ForEach-Object { [int]$_.sequence })
    $excludedPaths = @($authorization.excluded_evidence |
        ForEach-Object { @($_.artifacts) } |
        ForEach-Object { [string]$_.path })
    foreach ($requiredSource in $requiredSources) {
        $sourceNodeId = [string]$requiredSource.source_node_id
        $item = @($selectionItems | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $declaredBinding = @($receipt.source_bindings | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $declaredLifecycle = @($receipt.source_lifecycle_bindings |
            Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
        if ($item.Count -ne 1 -or $declaredBinding.Count -ne 1 -or
            $declaredLifecycle.Count -ne 1) {
            throw "Milestone revision source '$sourceNodeId' is not unique."
        }
        if ([string]$receipt.schema_version -in @('1.3', '1.4')) {
            foreach ($name in @(
                'source_kind', 'authorized_thread_id', 'source_thread_id',
                'recovery_cycle_id', 'recovery_event_bindings',
                'replacement_continuity_receipt_path',
                'replacement_continuity_receipt_hash',
                'replacement_pending_event_sequence',
                'replacement_pending_event_hash',
                'replacement_running_event_sequence',
                'replacement_running_event_hash'
            )) {
                if ($null -eq $declaredLifecycle[0].PSObject.Properties[$name]) {
                    throw (
                        "Milestone revision source '$sourceNodeId' schema 1.3 " +
                        "lifecycle lacks '$name'."
                    )
                }
            }
        }
        $binding = Get-DurableReviewDispositionBinding `
            -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
            -DispositionRelativePath (
                [string]$item[0].disposition_receipt_path
            ) -ExpectedMilestoneId ([string]$receipt.milestone_id) `
            -RequireResultMilestoneBinding
        if ((ConvertTo-Json -InputObject $binding -Compress -Depth 50) -ne
                (ConvertTo-Json -InputObject $declaredBinding[0] `
                    -Compress -Depth 50) -or
            ([string]$receipt.schema_version -notin @('1.3', '1.4') -and
                [string]$binding.source_thread_id -ne
                    [string]$requiredSource.thread_id) -or
            [string]$binding.checkpoint_material_path -ne
                [string]$receipt.checkpoint_material_path -or
            [string]$binding.checkpoint_material_hash -ne
                [string]$receipt.checkpoint_material_hash -or
            [string]$binding.result_receipt_path -in $excludedPaths -or
            [string]$binding.disposition_receipt_path -in $excludedPaths) {
            throw "Milestone revision source '$sourceNodeId' binding changed."
        }
        $rearmCandidates = @(
            Get-DurableReviewMilestoneRevisionRearmEvent `
                -RunDirectory $runRoot -Events $events `
                -Authorization $authorization -RequiredSource $requiredSource `
                -AuthorizationEventSequence ([int]$authorizationEvents[0].sequence)
        )
        $continuity = Get-DurableReviewRevisionSourceContinuityBinding `
            -RunDirectory $runRoot -RequiredSource $requiredSource `
            -DispositionBinding $binding -Authorization $authorization `
            -AuthorizationReceiptRelativePath (
                [string]$receipt.authorization_receipt_path
            ) -Events $events `
            -AuthorizationEventSequence ([int]$authorizationEvents[0].sequence) `
            -RearmEventSequence ([int]$rearmCandidates[0].sequence)
        if ([string]$receipt.schema_version -in @('1.3', '1.4')) {
            if ([string]$continuity.source_kind -notin @(
                'original', 'replacement'
            )) {
                throw "Milestone revision source '$sourceNodeId' continuity changed."
            }
        } elseif ([string]$continuity.source_kind -ne 'original') {
            throw (
                "Milestone revision source '$sourceNodeId' replacement " +
                'requires selection schema 1.3.'
            )
        }
        $boundEvents = [ordered]@{}
        foreach ($eventBinding in @(
            @{
                name = 'rearm'
                sequence = 'rearm_event_sequence'
                hash = 'rearm_event_hash'
            },
            @{
                name = 'completed'
                sequence = 'completed_event_sequence'
                hash = 'completed_event_hash'
            },
            @{
                name = 'validated'
                sequence = 'validated_event_sequence'
                hash = 'validated_event_hash'
            },
            @{
                name = 'adopted'
                sequence = 'adopted_event_sequence'
                hash = 'adopted_event_hash'
            }
        )) {
            $bound = @($events | Where-Object {
                [int]$_.sequence -eq
                    [int]$declaredLifecycle[0].$($eventBinding.sequence) -and
                [string]$_.hash -eq
                    [string]$declaredLifecycle[0].$($eventBinding.hash)
            })
            if ($bound.Count -ne 1 -or
                [string]$bound[0].node_id -ne $sourceNodeId) {
                throw (
                    "Milestone revision source '$sourceNodeId' lifecycle " +
                    "binding changed."
                )
            }
            $boundEvents[$eventBinding.name] = $bound[0]
        }
        $rearm = $boundEvents.rearm
        $completed = $boundEvents.completed
        $validated = $boundEvents.validated
        $adopted = $boundEvents.adopted
        $selectedThreadId = [string]$continuity.source_thread_id
        $lifecycleStartSequence = [int]$continuity.lifecycle_start_sequence
        $continuitySequences = @(
            @($continuity.recovery_event_bindings) | ForEach-Object {
                @(
                    [int]$_.result_pending_event_sequence,
                    [int]$_.resume_event_sequence
                )
            }
            [int]$continuity.replacement_pending_event_sequence
            [int]$continuity.replacement_running_event_sequence
        ) | Where-Object { [int]$_ -gt 0 }
        if ([int]$rearm.sequence -ne
                [int]$rearmCandidates[0].sequence -or
            [string]$rearm.hash -ne [string]$rearmCandidates[0].hash -or
            [string]$rearm.thread_id -ne
                [string]$requiredSource.thread_id -or
            [string]$completed.prior_state -ne 'running' -or
            [string]$validated.prior_state -ne 'completed' -or
            [string]$adopted.prior_state -ne 'validated' -or
            [string]$completed.status -ne 'completed' -or
            [string]$validated.status -ne 'validated' -or
            [string]$adopted.status -ne 'adopted' -or
            [string]$completed.thread_id -ne $selectedThreadId -or
            [string]$validated.thread_id -ne $selectedThreadId -or
            [string]$adopted.thread_id -ne $selectedThreadId -or
            [int]$authorizationEvents[0].sequence -ge [int]$rearm.sequence -or
            $lifecycleStartSequence -ge [int]$completed.sequence -or
            [int]$completed.sequence -ge [int]$validated.sequence -or
            [int]$validated.sequence -ge [int]$adopted.sequence -or
            @($rearm, $completed, $validated, $adopted |
                Where-Object {
                    [int]$_.sequence -in $excludedSequences
                }).Count -gt 0) {
            throw "Milestone revision source '$sourceNodeId' lifecycle changed."
        }
        if (@($continuitySequences | Where-Object {
            [int]$_ -in $excludedSequences
        }).Count -gt 0) {
            throw (
                "Milestone revision source '$sourceNodeId' replacement used " +
                'excluded evidence.'
            )
        }
        $evidenceBinding = $binding
        if ($null -ne $inventorySupersession) {
            $sourceSupersession = @(
                $inventorySupersession.source_supersessions | Where-Object {
                    [string]$_.source_node_id -eq $sourceNodeId
                }
            )
            if ($sourceSupersession.Count -ne 1 -or
                (ConvertTo-Json -InputObject (
                    $sourceSupersession[0].superseded_binding
                ) -Compress -Depth 100) -cne
                (ConvertTo-Json -InputObject $binding -Compress -Depth 100)) {
                throw (
                    "Milestone revision source '$sourceNodeId' inventory " +
                    'supersession changed.'
                )
            }
            $evidenceBinding = $sourceSupersession[0].current_binding
        }
        $resultPointer = "artifact:$($evidenceBinding.result_receipt_path)"
        $dispositionPointer =
            "artifact:$($evidenceBinding.disposition_receipt_path)"
        if ($null -eq $lifecycleCorrection) {
            if ($resultPointer -notin @($completed.evidence) -or
                $dispositionPointer -notin @($validated.evidence) -or
                $dispositionPointer -notin @($adopted.evidence)) {
                throw (
                    "Milestone revision source '$sourceNodeId' evidence changed."
                )
            }
        } else {
            $sourceCorrection = @(
                $lifecycleCorrection.source_corrections | Where-Object {
                    [string]$_.source_node_id -eq $sourceNodeId
                }
            )
            if ($sourceCorrection.Count -ne 1 -or
                [int]$sourceCorrection[0].rearm_event_sequence -ne
                    [int]$rearm.sequence -or
                [string]$sourceCorrection[0].rearm_event_hash -ne
                    [string]$rearm.hash -or
                [int]$sourceCorrection[0].completed_event_sequence -ne
                    [int]$completed.sequence -or
                [string]$sourceCorrection[0].completed_event_hash -ne
                    [string]$completed.hash -or
                [int]$sourceCorrection[0].validated_event_sequence -ne
                    [int]$validated.sequence -or
                [string]$sourceCorrection[0].validated_event_hash -ne
                    [string]$validated.hash -or
                [int]$sourceCorrection[0].adopted_event_sequence -ne
                    [int]$adopted.sequence -or
                [string]$sourceCorrection[0].adopted_event_hash -ne
                    [string]$adopted.hash -or
                [string]$sourceCorrection[0].result_receipt_path -ne
                    [string]$binding.result_receipt_path -or
                [string]$sourceCorrection[0].result_receipt_hash -ne
                    [string]$binding.result_receipt_hash -or
                [string]$sourceCorrection[0].result_file_hash -ne
                    [string]$binding.result_file_hash -or
                [string]$sourceCorrection[0].disposition_receipt_path -ne
                    [string]$binding.disposition_receipt_path -or
                [string]$sourceCorrection[0].disposition_receipt_hash -ne
                    [string]$binding.disposition_receipt_hash -or
                [string]$sourceCorrection[0].disposition_file_hash -ne
                    [string]$binding.disposition_file_hash) {
                throw (
                    "Milestone revision source '$sourceNodeId' correction changed."
                )
            }
        }
        $computedLifecycle = if ([string]$receipt.schema_version -in @(
            '1.3', '1.4'
        )) {
            [pscustomobject][ordered]@{
                source_node_id = $sourceNodeId
                role_id = [string]$requiredSource.role_id
                source_kind = [string]$continuity.source_kind
                authorized_thread_id = [string]$continuity.authorized_thread_id
                source_thread_id = $selectedThreadId
                rearm_event_sequence = [int]$rearm.sequence
                rearm_event_hash = [string]$rearm.hash
                recovery_cycle_id = [string]$continuity.recovery_cycle_id
                recovery_event_bindings = @($continuity.recovery_event_bindings)
                replacement_continuity_receipt_path =
                    [string]$continuity.replacement_continuity_receipt_path
                replacement_continuity_receipt_hash =
                    [string]$continuity.replacement_continuity_receipt_hash
                replacement_pending_event_sequence =
                    [int]$continuity.replacement_pending_event_sequence
                replacement_pending_event_hash =
                    [string]$continuity.replacement_pending_event_hash
                replacement_running_event_sequence =
                    [int]$continuity.replacement_running_event_sequence
                replacement_running_event_hash =
                    [string]$continuity.replacement_running_event_hash
                completed_event_sequence = [int]$completed.sequence
                completed_event_hash = [string]$completed.hash
                validated_event_sequence = [int]$validated.sequence
                validated_event_hash = [string]$validated.hash
                adopted_event_sequence = [int]$adopted.sequence
                adopted_event_hash = [string]$adopted.hash
            }
        } else {
            [pscustomobject][ordered]@{
                source_node_id = $sourceNodeId
                role_id = [string]$requiredSource.role_id
                source_thread_id = [string]$requiredSource.thread_id
                rearm_event_sequence = [int]$rearm.sequence
                rearm_event_hash = [string]$rearm.hash
                completed_event_sequence = [int]$completed.sequence
                completed_event_hash = [string]$completed.hash
                validated_event_sequence = [int]$validated.sequence
                validated_event_hash = [string]$validated.hash
                adopted_event_sequence = [int]$adopted.sequence
                adopted_event_hash = [string]$adopted.hash
            }
        }
        if ((ConvertTo-Json -InputObject $computedLifecycle `
                -Compress -Depth 50) -ne
            (ConvertTo-Json -InputObject $declaredLifecycle[0] `
                -Compress -Depth 50)) {
            throw "Milestone revision source '$sourceNodeId' lifecycle binding changed."
        }
        $oldBinding = @($authorization.previous_source_bindings |
            Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
        $oldPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$oldBinding[0].disposition_receipt_path) `
            -Label 'Previous milestone revision disposition'
        $oldDisposition = Read-ReviewDispositionReceipt -Path $oldPath `
            -RunDirectory $runRoot -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$oldBinding[0].source_thread_id)
        $newPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$binding.disposition_receipt_path) `
            -Label 'Selected milestone revision disposition'
        $newDisposition = Read-ReviewDispositionReceipt -Path $newPath `
            -RunDirectory $runRoot -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$binding.source_thread_id)
        foreach ($oldDecision in @($oldDisposition.decisions)) {
            $same = @($newDisposition.decisions | Where-Object {
                [string]$_.source_finding_id -eq
                    [string]$oldDecision.source_finding_id
            })
            if ($same.Count -ne 1 -or
                [string]$same[0].severity -ne [string]$oldDecision.severity -or
                [string]$same[0].finding -ne [string]$oldDecision.finding -or
                [string]$same[0].finding_hash -ne
                    [string]$oldDecision.finding_hash -or
                [string]$same[0].canonical_finding_id -ne
                    [string]$oldDecision.canonical_finding_id) {
                throw "Milestone revision source '$sourceNodeId' lost an occurrence."
            }
        }
    }
    $eventCount = [int]$receipt.source_journal_event_count
    if ($eventCount -lt 1 -or $eventCount -ge $events.Count -or
        [string]$events[$eventCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision selection journal binding changed.'
    }
    $relativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($Path)
    ).Replace('\', '/')
    $selectionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected' -and
        [string]$_.milestone_revision_id -eq [string]$receipt.revision_id -and
        [string]$_.milestone_activation_receipt_path -eq $relativePath -and
        [string]$_.milestone_activation_receipt_hash -eq
            [string]$receipt.receipt_hash -and
        [string]$_.milestone_revision_selection_key -ceq
            [string]$receipt.selection_key
    })
    if ($selectionEvents.Count -ne 1 -or
        [int]$selectionEvents[0].sequence -ne $eventCount -or
        [string]$selectionEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone revision selection lacks its exact journal event.'
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
    )) {
        throw 'Milestone revision selection receipt hash mismatch.'
    }
    Set-OrchestrationValidatedObjectCacheValue -Descriptor $cacheDescriptor `
        -Value $receipt
    $validationSucceeded = $true
    return $receipt
    } finally {
        Exit-OrchestrationValidationContext -Token $validationToken `
            -ValidateSnapshot:$validationSucceeded
    }
}

function Read-DurableReviewMilestoneActivationChain {
    param(
        [Parameter(Mandatory)][string] $RunDirectory
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $validationToken = Enter-OrchestrationValidationContext -RunDirectory $runRoot
    $validationSucceeded = $false
    try {
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
        throw 'The run has no durable_review_profile.'
    }
    if ((Get-TextSha256 $planRaw) -ne [string]$run.plan_hash -or
        [string]$run.run_id -ne [string]$plan.run_id) {
        throw 'Durable review milestone chain does not match the immutable run.'
    }
    $milestoneIds = @(
        $plan.durable_review_profile.milestone_ids | ForEach-Object {
            [string]$_
        }
    )
    if ($milestoneIds.Count -lt 2 -or
        @($milestoneIds | Select-Object -Unique).Count -ne
            $milestoneIds.Count -or
        @($milestoneIds | Where-Object {
            $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
        }).Count -gt 0) {
        throw 'Durable review milestone IDs are invalid.'
    }
    $requiredSourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids) |
        ForEach-Object { [string]$_ }
    )
    $checks = @($plan.completion.review_disposition_checks)
    if ($checks.Count -ne $requiredSourceIds.Count) {
        throw 'Durable review completion checks do not match required sources.'
    }
    $baselineBindings = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in $requiredSourceIds) {
        $matchingChecks = @($checks | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        if ($matchingChecks.Count -ne 1) {
            throw "Durable source '$sourceNodeId' needs one baseline check."
        }
        $baselineBindings.Add((
            Get-DurableReviewDispositionBinding -RunDirectory $runRoot `
                -Plan $plan -SourceNodeId $sourceNodeId `
                -DispositionRelativePath ([string]$matchingChecks[0].path) `
                -ExpectedMilestoneId $milestoneIds[0] `
                -AllowHistoricalMilestoneAlias
        ))
    }

    $receiptDirectory = Join-Path $runRoot 'receipts'
    $knownReceiptNames = @($milestoneIds | Select-Object -Skip 1 |
        ForEach-Object { "durable-review-milestone.$_.activation.json" })
    $actualActivationFiles = @()
    if (Test-Path -LiteralPath $receiptDirectory -PathType Container) {
        $actualActivationFiles = @(
            Get-ChildItem -LiteralPath $receiptDirectory -File -Filter (
                'durable-review-milestone.*.activation.json'
            )
        )
    }
    foreach ($activationFile in $actualActivationFiles) {
        if ($activationFile.Name -notin $knownReceiptNames) {
            throw 'A milestone activation receipt targets an unknown milestone.'
        }
    }
    $activationEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-activated'
    })
    if ($activationEvents.Count -ne $actualActivationFiles.Count) {
        throw (
            'Milestone activation receipt and journal event counts do not match.'
        )
    }

    $activeMilestoneId = $milestoneIds[0]
    $activeBindings = @($baselineBindings)
    $previousActivationPath = ''
    $previousActivationHash = ''
    $activeReceipt = $null
    $revisionAuthorizationEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized'
    })
    $revisionSelectionEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-selected'
    })
    $revisionAbandonmentEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-revision-abandoned'
    })
    if ($revisionAuthorizationEvents.Count -lt
            ($revisionSelectionEvents.Count + $revisionAbandonmentEvents.Count) -or
        $revisionAuthorizationEvents.Count -
            ($revisionSelectionEvents.Count + $revisionAbandonmentEvents.Count) -gt 1) {
        throw 'First-milestone revision authorization/selection chain is invalid.'
    }
    foreach ($abandonmentEvent in $revisionAbandonmentEvents) {
        $abandonmentPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$abandonmentEvent.
                milestone_revision_abandonment_receipt_path) `
            -Label 'Milestone revision abandonment'
        $abandonment = Read-DurableReviewMilestoneRevisionAbandonment `
            -Path $abandonmentPath -RunDirectory $runRoot
        if ([string]$abandonment.receipt_hash -ne
                [string]$abandonmentEvent.
                    milestone_revision_abandonment_receipt_hash -or
            [string]$abandonment.revision_id -ne
                [string]$abandonmentEvent.milestone_revision_id) {
            throw 'First-milestone revision abandonment chain is invalid.'
        }
    }
    foreach ($selectionEvent in $revisionSelectionEvents) {
        $selectionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath (
                [string]$selectionEvent.milestone_activation_receipt_path
            ) -Label 'Milestone revision selection'
        $selection = Read-DurableReviewMilestoneRevisionSelection `
            -Path $selectionPath -RunDirectory $runRoot
        $expectedRevisionIndex = @($revisionAuthorizationEvents | Where-Object {
            [int]$_.sequence -le [int]$selectionEvent.sequence
        }).Count
        if ([int]$selection.revision_index -ne $expectedRevisionIndex -or
            [string]$selection.previous_activation_receipt_path -ne
            $previousActivationPath -or
            [string]$selection.previous_activation_receipt_hash -ne
            $previousActivationHash -or
            [string]$selection.previous_source_bindings_hash -ne
            (Get-TextSha256 (
                ConvertTo-Json -InputObject @($activeBindings) `
                    -Compress -Depth 100
            ))) {
            throw 'First-milestone revision selection skipped or forked its chain.'
        }
        $activeBindings = @($selection.source_bindings)
        $previousActivationPath = [IO.Path]::GetRelativePath(
            $runRoot, $selectionPath
        ).Replace('\', '/')
        $previousActivationHash = [string]$selection.receipt_hash
        $activeReceipt = $selection
    }
    if ($revisionAuthorizationEvents.Count -ne
        ($revisionSelectionEvents.Count + $revisionAbandonmentEvents.Count)) {
        throw (
            'A first-milestone revision is authorized but not yet selected; ' +
            'completion and later milestone activation remain blocked.'
        )
    }
    $gapSeen = $false
    for ($index = 1; $index -lt $milestoneIds.Count; $index++) {
        $milestoneId = $milestoneIds[$index]
        $relativePath = (
            "receipts/durable-review-milestone.$milestoneId.activation.json"
        )
        $receiptPath = Join-Path $runRoot $relativePath
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            $gapSeen = $true
            continue
        }
        if ($gapSeen) {
            throw 'Durable review milestone activation skipped a predecessor.'
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        $required = @(
            'schema_version', 'run_id', 'plan_hash', 'milestone_id',
            'milestone_index', 'previous_milestone_id',
            'previous_activation_receipt_path',
            'previous_activation_receipt_hash',
            'previous_source_bindings_hash', 'source_journal_head',
            'source_journal_event_count', 'selection_material_path',
            'selection_material_hash', 'source_bindings',
            'source_bindings_hash', 'checkpoint_material_path',
            'checkpoint_material_hash', 'authorization_material_path',
            'authorization_material_hash', 'activation_key',
            'created_at_utc', 'receipt_hash'
        )
        if ([string]$receipt.schema_version -in @('1.1', '1.2')) {
            $required += @(
                'acceptance_authorization_material_path',
                'acceptance_authorization_material_hash', 'main_node_id',
                'acceptance_key', 'acceptance_evidence_material_path',
                'acceptance_evidence_material_hash'
            )
        }
        if ([string]$receipt.schema_version -eq '1.2') {
            $required += @(
                'previous_milestone_gate',
                'scope_transition_authorization_receipt_path',
                'scope_transition_authorization_receipt_hash',
                'scope_transition_authorization_material_path',
                'scope_transition_authorization_material_hash',
                'scope_transition_key', 'carry_forward_occurrences',
                'carry_forward_occurrences_hash',
                'previous_open_occurrence_count',
                'resolved_occurrence_count',
                'remaining_open_occurrence_count'
            )
        }
        foreach ($name in $required) {
            if ($null -eq $receipt.PSObject.Properties[$name]) {
                throw "Milestone activation receipt is missing '$name'."
            }
        }
        if ([string]$receipt.schema_version -notin @('1.0', '1.1', '1.2') -or
            [string]$receipt.run_id -ne [string]$run.run_id -or
            [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
            [string]$receipt.milestone_id -ne $milestoneId -or
            [int]$receipt.milestone_index -ne $index -or
            [string]$receipt.previous_milestone_id -ne
                $milestoneIds[$index - 1] -or
            [string]$receipt.previous_activation_receipt_path -ne
                $previousActivationPath -or
            [string]$receipt.previous_activation_receipt_hash -ne
                $previousActivationHash -or
            [string]$receipt.previous_source_bindings_hash -ne (
                Get-TextSha256 (
                    @($activeBindings) |
                        ConvertTo-Json -Compress -Depth 30
                )
            )) {
            throw 'Milestone activation predecessor or run binding is invalid.'
        }
        $eventCount = [int]$receipt.source_journal_event_count
        if ($eventCount -lt 1 -or $eventCount -gt $events.Count -or
            [string]$events[$eventCount - 1].hash -ne
                [string]$receipt.source_journal_head) {
            throw 'Milestone activation journal binding changed.'
        }
        $matchingEvents = @($activationEvents | Where-Object {
            [string]$_.milestone_id -eq $milestoneId -and
            [string]$_.milestone_activation_receipt_path -eq $relativePath -and
            [string]$_.milestone_activation_receipt_hash -eq
                [string]$receipt.receipt_hash
        })
        if ($matchingEvents.Count -ne 1 -or
            [int]$matchingEvents[0].sequence -ne $eventCount -or
            [string]$matchingEvents[0].prev_hash -ne
                [string]$receipt.source_journal_head) {
            throw 'Milestone activation lacks its exact append-only journal event.'
        }
        $authorizationPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$receipt.authorization_material_path) `
            -Label 'Milestone authorization material'
        if (-not (Test-Path -LiteralPath $authorizationPath -PathType Leaf) -or
            [string]$receipt.authorization_material_hash -ne (
                Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256
            ).Hash.ToLowerInvariant() -or
            [string]$receipt.activation_key -notmatch (
                '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$'
            )) {
            throw 'Milestone activation authorization binding changed.'
        }
        if ([string]$receipt.schema_version -in @('1.1', '1.2')) {
            $acceptanceAuthorizationPath = Get-RunLocalReceiptPath `
                -RunDirectory $runRoot -RelativePath (
                    [string]$receipt.acceptance_authorization_material_path
                ) -Label 'Milestone acceptance authorization'
            if (-not (
                Test-Path -LiteralPath $acceptanceAuthorizationPath `
                    -PathType Leaf
            ) -or [string]$receipt.acceptance_authorization_material_hash -ne (
                Get-FileHash -LiteralPath $acceptanceAuthorizationPath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
                throw 'Milestone acceptance authorization binding changed.'
            }
            $acceptanceAuthorization = Get-Content -LiteralPath (
                $acceptanceAuthorizationPath
            ) -Raw | ConvertFrom-Json -Depth 30 -DateKind String
            $mainNodes = @($plan.nodes | Where-Object {
                [string]$_.kind -eq 'main'
            })
            if ($mainNodes.Count -ne 1 -or
                [string]$receipt.main_node_id -ne
                    [string]$mainNodes[0].id -or
                [string]$acceptanceAuthorization.milestone_id -ne
                    $milestoneId -or
                [string]$acceptanceAuthorization.main_node_id -ne
                    [string]$receipt.main_node_id -or
                [string]$acceptanceAuthorization.acceptance_key -ne
                    [string]$receipt.acceptance_key -or
                [string]$acceptanceAuthorization.evidence_material_path -ne
                    [string]$receipt.acceptance_evidence_material_path -or
                [string]$acceptanceAuthorization.evidence_material_hash -ne
                    [string]$receipt.acceptance_evidence_material_hash) {
                throw 'Milestone acceptance authorization constraints changed.'
            }
            $acceptanceEvidencePath = Get-RunLocalReceiptPath `
                -RunDirectory $runRoot -RelativePath (
                    [string]$receipt.acceptance_evidence_material_path
                ) -Label 'Milestone acceptance evidence'
            if (-not (Test-Path -LiteralPath $acceptanceEvidencePath `
                -PathType Leaf) -or
                [string]$receipt.acceptance_evidence_material_hash -ne (
                    Get-FileHash -LiteralPath $acceptanceEvidencePath `
                        -Algorithm SHA256
                ).Hash.ToLowerInvariant()) {
                throw 'Milestone acceptance evidence anchor changed.'
            }
        }
        $selectionPath = Get-RunLocalReceiptPath `
            -RunDirectory $runRoot `
            -RelativePath ([string]$receipt.selection_material_path) `
            -Label 'Milestone selection material'
        if (-not (Test-Path -LiteralPath $selectionPath -PathType Leaf) -or
            [string]$receipt.selection_material_hash -ne (
                Get-FileHash -LiteralPath $selectionPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Milestone activation selection binding changed.'
        }
        $sourceBindings = @($receipt.source_bindings)
        if ($sourceBindings.Count -ne $requiredSourceIds.Count -or
            [string]$receipt.source_bindings_hash -ne (
                Get-TextSha256 (
                    $sourceBindings | ConvertTo-Json -Compress -Depth 30
                )
            )) {
            throw 'Milestone activation source binding set is invalid.'
        }
        $verifiedBindings = [Collections.Generic.List[object]]::new()
        foreach ($sourceNodeId in $requiredSourceIds) {
            $matches = @($sourceBindings | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            })
            if ($matches.Count -ne 1) {
                throw "Milestone activation source '$sourceNodeId' is not unique."
            }
            $binding = $matches[0]
            $verified = Get-DurableReviewDispositionBinding `
                -RunDirectory $runRoot -Plan $plan `
                -SourceNodeId $sourceNodeId `
                -DispositionRelativePath (
                    [string]$binding.disposition_receipt_path
                ) -ExpectedMilestoneId $milestoneId `
                -RequireResultMilestoneBinding
            foreach ($name in @(
                'source_thread_id', 'milestone_id',
                'checkpoint_material_path', 'checkpoint_material_hash',
                'result_receipt_path', 'result_receipt_hash',
                'result_file_hash', 'disposition_receipt_path',
                'disposition_receipt_hash', 'disposition_file_hash'
            )) {
                if ([string]$binding.$name -ne [string]$verified.$name) {
                    throw (
                        "Milestone activation source '$sourceNodeId' changed " +
                        "its '$name' binding."
                    )
                }
            }
            $verifiedBindings.Add($verified)
        }
        $checkpointPaths = @($verifiedBindings |
            Select-Object -ExpandProperty checkpoint_material_path -Unique)
        $checkpointHashes = @($verifiedBindings |
            Select-Object -ExpandProperty checkpoint_material_hash -Unique)
        if ($checkpointPaths.Count -ne 1 -or $checkpointHashes.Count -ne 1 -or
            [string]$receipt.checkpoint_material_path -ne $checkpointPaths[0] -or
            [string]$receipt.checkpoint_material_hash -ne $checkpointHashes[0]) {
            throw 'Milestone activation sources do not share one checkpoint.'
        }
        if ([string]$receipt.schema_version -eq '1.2') {
            if ([string]$receipt.previous_milestone_gate -ne
                    'scoped-carry-forward' -or
                [string]$receipt.scope_transition_key -cnotmatch
                    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
                throw 'Scoped milestone transition binding is invalid.'
            }
            $scopeAuthorizationReceiptPath = Get-RunLocalReceiptPath `
                -RunDirectory $runRoot -RelativePath (
                    [string]$receipt.
                        scope_transition_authorization_receipt_path
                ) -Label 'Scoped milestone transition authorization receipt'
            $scopeAuthorizationReceipt =
                Read-DurableReviewScopeTransitionAuthorization `
                    -Path $scopeAuthorizationReceiptPath `
                    -RunDirectory $runRoot
            $scopeAuthorizationEventIndex =
                [int]$receipt.source_journal_event_count - 1
            if ([string]$receipt.scope_transition_authorization_receipt_hash -ne
                    [string]$scopeAuthorizationReceipt.receipt_hash -or
                $scopeAuthorizationEventIndex -lt 0 -or
                [string]$events[$scopeAuthorizationEventIndex].event -ne
                    'milestone-scope-transition-authorized' -or
                [string]$events[$scopeAuthorizationEventIndex].hash -ne
                    [string]$receipt.source_journal_head -or
                [string]$scopeAuthorizationReceipt.previous_milestone_id -ne
                    $activeMilestoneId -or
                [string]$scopeAuthorizationReceipt.
                    previous_activation_receipt_path -ne
                    $previousActivationPath -or
                [string]$scopeAuthorizationReceipt.
                    previous_activation_receipt_hash -ne
                    $previousActivationHash -or
                [string]$scopeAuthorizationReceipt.
                    previous_source_bindings_hash -ne (
                        Get-TextSha256 (
                            @($activeBindings) |
                                ConvertTo-Json -Compress -Depth 30
                        )
                    ) -or
                [string]$scopeAuthorizationReceipt.milestone_id -ne
                    $milestoneId -or
                [int]$scopeAuthorizationReceipt.milestone_index -ne $index -or
                [string]$scopeAuthorizationReceipt.selection_material_path -ne
                    [string]$receipt.selection_material_path -or
                [string]$scopeAuthorizationReceipt.selection_material_hash -ne
                    [string]$receipt.selection_material_hash -or
                [string]$scopeAuthorizationReceipt.
                    scope_transition_authorization_material_path -ne
                    [string]$receipt.
                        scope_transition_authorization_material_path -or
                [string]$scopeAuthorizationReceipt.
                    scope_transition_authorization_material_hash -ne
                    [string]$receipt.
                        scope_transition_authorization_material_hash -or
                [string]$scopeAuthorizationReceipt.scope_transition_key -cne
                    [string]$receipt.scope_transition_key -or
                [string]$scopeAuthorizationReceipt.checkpoint_material_path -ne
                    [string]$receipt.checkpoint_material_path -or
                [string]$scopeAuthorizationReceipt.checkpoint_material_hash -ne
                    [string]$receipt.checkpoint_material_hash) {
                throw (
                    'Scoped milestone transition changed its pre-existing ' +
                    'authorization.'
                )
            }
            $scopeAuthorizationPath = Get-RunLocalReceiptPath `
                -RunDirectory $runRoot -RelativePath (
                    [string]$receipt.scope_transition_authorization_material_path
                ) -Label 'Scoped milestone transition authorization'
            if (-not (Test-Path -LiteralPath $scopeAuthorizationPath `
                -PathType Leaf) -or
                [string]::IsNullOrWhiteSpace(
                    (Get-Content -LiteralPath $scopeAuthorizationPath -Raw)
                ) -or
                [string]$receipt.scope_transition_authorization_material_hash -ne (
                    Get-FileHash -LiteralPath $scopeAuthorizationPath `
                        -Algorithm SHA256
                ).Hash.ToLowerInvariant()) {
                throw 'Scoped milestone transition authorization binding changed.'
            }
            $computedCarry = Get-DurableReviewScopedCarryForward `
                -RunDirectory $runRoot `
                -PreviousSourceBindings @($activeBindings) `
                -NextSourceBindings @($verifiedBindings)
            $computedCarryJson = ConvertTo-Json -InputObject @(
                $computedCarry.occurrences
            ) -Compress -Depth 50
            $declaredCarryJson = ConvertTo-Json -InputObject @(
                $receipt.carry_forward_occurrences
            ) -Compress -Depth 50
            if ([int]$computedCarry.previous_open_count -lt 1 -or
                [int]$computedCarry.remaining_open_count -lt 1 -or
                [string]$receipt.carry_forward_occurrences_hash -ne
                    (Get-TextSha256 $computedCarryJson) -or
                [string]$scopeAuthorizationReceipt.
                    carry_forward_occurrences_hash -ne
                    [string]$receipt.carry_forward_occurrences_hash -or
                $declaredCarryJson -ne $computedCarryJson -or
                [int]$receipt.previous_open_occurrence_count -ne
                    [int]$computedCarry.previous_open_count -or
                [int]$scopeAuthorizationReceipt.
                    previous_open_occurrence_count -ne
                    [int]$receipt.previous_open_occurrence_count -or
                [int]$receipt.resolved_occurrence_count -ne
                    [int]$computedCarry.resolved_count -or
                [int]$scopeAuthorizationReceipt.resolved_occurrence_count -ne
                    [int]$receipt.resolved_occurrence_count -or
                [int]$receipt.remaining_open_occurrence_count -ne
                    [int]$computedCarry.remaining_open_count -or
                [int]$scopeAuthorizationReceipt.
                    remaining_open_occurrence_count -ne
                    [int]$receipt.remaining_open_occurrence_count) {
                throw 'Scoped milestone transition occurrence conservation changed.'
            }
            $activationEvent = $matchingEvents[0]
            if ([string]$activationEvent.previous_milestone_gate -ne
                    [string]$receipt.previous_milestone_gate -or
                [string]$activationEvent.
                    scope_transition_authorization_receipt_path -ne
                    [string]$receipt.
                        scope_transition_authorization_receipt_path -or
                [string]$activationEvent.
                    scope_transition_authorization_receipt_hash -ne
                    [string]$receipt.
                        scope_transition_authorization_receipt_hash -or
                [string]$activationEvent.scope_transition_authorization_material_path -ne
                    [string]$receipt.scope_transition_authorization_material_path -or
                [string]$activationEvent.scope_transition_authorization_material_hash -ne
                    [string]$receipt.scope_transition_authorization_material_hash -or
                [string]$activationEvent.scope_transition_key -cne
                    [string]$receipt.scope_transition_key -or
                [string]$activationEvent.carry_forward_occurrences_hash -ne
                    [string]$receipt.carry_forward_occurrences_hash -or
                [int]$activationEvent.previous_open_occurrence_count -ne
                    [int]$receipt.previous_open_occurrence_count -or
                [int]$activationEvent.resolved_occurrence_count -ne
                    [int]$receipt.resolved_occurrence_count -or
                [int]$activationEvent.remaining_open_occurrence_count -ne
                    [int]$receipt.remaining_open_occurrence_count -or
                @($activationEvent.evidence) -notcontains (
                    'artifact:' +
                    [string]$receipt.
                        scope_transition_authorization_receipt_path
                ) -or
                @($activationEvent.evidence) -notcontains (
                    'artifact:' +
                    [string]$receipt.scope_transition_authorization_material_path
                )) {
                throw 'Scoped milestone transition journal binding changed.'
            }
        }
        $payload = [ordered]@{}
        foreach ($property in $receipt.PSObject.Properties) {
            if ($property.Name -ne 'receipt_hash') {
                $payload[$property.Name] = $property.Value
            }
        }
        if ([string]$receipt.receipt_hash -ne (
            Get-TextSha256 (
                $payload | ConvertTo-Json -Compress -Depth 100
            )
        )) {
            throw 'Milestone activation receipt hash mismatch.'
        }
        $activeMilestoneId = $milestoneId
        $activeBindings = @($verifiedBindings)
        $previousActivationPath = $relativePath
        $previousActivationHash = [string]$receipt.receipt_hash
        $activeReceipt = $receipt
    }
    $result = [pscustomobject]@{
        active_milestone_id = $activeMilestoneId
        active_source_bindings = @($activeBindings)
        activation_receipt = $activeReceipt
        activation_receipt_path = $previousActivationPath
        activation_receipt_hash = $previousActivationHash
        next_milestone_id = if (
            ([Array]::IndexOf($milestoneIds, $activeMilestoneId) + 1) -lt
                $milestoneIds.Count
        ) {
            $milestoneIds[
                [Array]::IndexOf($milestoneIds, $activeMilestoneId) + 1
            ]
        } else { '' }
    }
    $validationSucceeded = $true
    return $result
    } finally {
        Exit-OrchestrationValidationContext -Token $validationToken -ValidateSnapshot:$validationSucceeded
    }
}

function Read-DurableReviewMilestoneAcceptance {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [object] $MilestoneChain
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $chain = if ($null -ne $MilestoneChain) {
        $MilestoneChain
    } else {
        Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
    }
    if ([string]::IsNullOrWhiteSpace(
        [string]$chain.activation_receipt_hash
    )) {
        return $null
    }
    $milestoneId = [string]$chain.active_milestone_id
    $relativePath = (
        "receipts/durable-review-milestone.$milestoneId.acceptance.json"
    )
    $path = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath $relativePath -Label 'Milestone acceptance receipt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Active milestone '$milestoneId' lacks main-owner acceptance."
    }
    $receipt = Get-Content -LiteralPath $path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'milestone_id',
        'main_node_id', 'activation_receipt_path', 'activation_receipt_hash',
        'source_bindings_hash', 'checkpoint_material_path',
        'checkpoint_material_hash', 'source_journal_head',
        'source_journal_event_count', 'evidence_material_path',
        'evidence_material_hash', 'acceptance_key', 'created_at_utc',
        'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Milestone acceptance receipt is missing '$name'."
        }
    }
    $planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $mainNodes = @($plan.nodes | Where-Object {
        [string]$_.kind -eq 'main'
    })
    $expectedBindingsHash = Get-TextSha256 (
        @($chain.active_source_bindings) |
            ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.milestone_id -ne $milestoneId -or
        $mainNodes.Count -ne 1 -or
        [string]$receipt.main_node_id -ne [string]$mainNodes[0].id -or
        [string]$receipt.activation_receipt_path -ne
            [string]$chain.activation_receipt_path -or
        [string]$receipt.activation_receipt_hash -ne
            [string]$chain.activation_receipt_hash -or
        [string]$receipt.source_bindings_hash -ne $expectedBindingsHash -or
        [string]$receipt.checkpoint_material_path -ne
            [string]$chain.activation_receipt.checkpoint_material_path -or
        [string]$receipt.checkpoint_material_hash -ne
            [string]$chain.activation_receipt.checkpoint_material_hash -or
        [string]$chain.activation_receipt.schema_version -notin @(
            '1.1', '1.2'
        ) -or
        [string]$receipt.acceptance_key -ne
            [string]$chain.activation_receipt.acceptance_key -or
        [string]$receipt.evidence_material_path -ne
            [string]$chain.activation_receipt.acceptance_evidence_material_path -or
        [string]$receipt.evidence_material_hash -ne
            [string]$chain.activation_receipt.acceptance_evidence_material_hash) {
        throw 'Milestone acceptance does not match the active review chain.'
    }
    $evidencePath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.evidence_material_path) `
        -Label 'Milestone acceptance evidence'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or
        [string]$receipt.evidence_material_hash -ne (
            Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Milestone acceptance evidence binding changed.'
    }
    if ([string]$receipt.acceptance_key -notmatch
        '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
        throw 'Milestone acceptance key is invalid.'
    }
    $payload = [ordered]@{}
    foreach ($property in $receipt.PSObject.Properties) {
        if ($property.Name -ne 'receipt_hash') {
            $payload[$property.Name] = $property.Value
        }
    }
    if ([string]$receipt.receipt_hash -ne (
        Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
    )) {
        throw 'Milestone acceptance receipt hash mismatch.'
    }
    $events = @(
        Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl')
    )
    $acceptanceEvents = @($events | Where-Object {
        [string]$_.event -eq 'milestone-accepted' -and
        [string]$_.milestone_id -eq $milestoneId -and
        [string]$_.milestone_acceptance_receipt_path -eq $relativePath -and
        [string]$_.milestone_acceptance_receipt_hash -eq
            [string]$receipt.receipt_hash
    })
    $activationEvents = @($events | Where-Object {
        [string]$_.event -in @(
            'milestone-activated', 'milestone-revision-selected'
        ) -and
        [string]$_.milestone_activation_receipt_hash -eq
            [string]$chain.activation_receipt_hash
    })
    $eventIndex = [int]$receipt.source_journal_event_count
    if ($acceptanceEvents.Count -ne 1 -or $activationEvents.Count -ne 1 -or
        $eventIndex -le [int]$activationEvents[0].sequence -or
        $eventIndex -ge $events.Count -or
        [int]$acceptanceEvents[0].sequence -ne $eventIndex -or
        [string]$acceptanceEvents[0].prev_hash -ne
            [string]$receipt.source_journal_head -or
        [string]$acceptanceEvents[0].node_id -ne
            [string]$receipt.main_node_id -or
        [string]$acceptanceEvents[0].status -ne 'validated' -or
        [string]$acceptanceEvents[0].milestone_activation_receipt_hash -ne
            [string]$chain.activation_receipt_hash -or
        [string]$acceptanceEvents[0].milestone_acceptance_key -ne
            [string]$receipt.acceptance_key -or
        [string]$acceptanceEvents[0].milestone_acceptance_evidence_path -ne
            [string]$receipt.evidence_material_path -or
        [string]$acceptanceEvents[0].milestone_acceptance_evidence_hash -ne
            [string]$receipt.evidence_material_hash -or
        $eventIndex -lt 1 -or
        [string]$events[$eventIndex - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Milestone acceptance journal binding is invalid.'
    }
    return $receipt
}

function Read-ThreadReconciliationReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [string] $ExpectedDecision
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $receiptPath = [IO.Path]::GetFullPath($Path)
    if (-not $receiptPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
        [IO.Path]::GetFileName($receiptPath) -notlike
            '*.thread-reconciliation.json') {
        throw 'Thread reconciliation receipt must be an existing run-local receipt.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $inputRelativePath = [string]$receipt.reconciliation_input_path
    $inputSegments = $inputRelativePath -split '[\\/]'
    if (@($inputSegments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Thread reconciliation receipt has an unsafe input path.'
    }
    $inputPath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $inputRelativePath)
    )
    if (-not $inputPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw 'Thread reconciliation input is missing.'
    }
    $inputRaw = Get-Content -LiteralPath $inputPath -Raw
    if ((Get-TextSha256 $inputRaw) -ne
        [string]$receipt.reconciliation_input_hash) {
        throw 'Thread reconciliation input hash mismatch.'
    }
    $input = $inputRaw | ConvertFrom-Json -Depth 50 -DateKind String
    $reservationPath = [IO.Path]::GetFullPath(
        [string]$input.reservation_path
    )
    $activationRoot = [IO.Path]::GetFullPath(
        (Join-Path $runRoot 'receipts/activations')
    ).TrimEnd('\', '/')
    if (-not $reservationPath.StartsWith(
        $activationRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $reservationPath -PathType Leaf)) {
        throw 'Thread reconciliation activation reservation is missing.'
    }
    $reservation = Get-Content -LiteralPath $reservationPath -Raw |
        ConvertFrom-Json -Depth 20 -DateKind String
    $reservationPayload = [ordered]@{
        schema_version = [string]$reservation.schema_version
        activation_key = [string]$reservation.activation_key
        activation_key_hash = [string]$reservation.activation_key_hash
        source_thread_id = [string]$reservation.source_thread_id
        task_summary_hash = [string]$reservation.task_summary_hash
        role_preview_path = [string]$reservation.role_preview_path
        role_preview_hash = [string]$reservation.role_preview_hash
        reserved_at_utc = [string]$reservation.reserved_at_utc
    }
    $reservationHash = Get-TextSha256 (
        $reservationPayload | ConvertTo-Json -Compress -Depth 10
    )
    if ([string]$reservation.reservation_hash -ne $reservationHash -or
        [string]$receipt.activation_reservation_hash -ne $reservationHash) {
        throw 'Thread reconciliation activation reservation hash mismatch.'
    }
    $payload = [ordered]@{
        schema_version = [string]$receipt.schema_version
        reconciliation_input_path = $inputRelativePath
        reconciliation_input_hash = [string]$receipt.reconciliation_input_hash
        activation_key = [string]$receipt.activation_key
        activation_reservation_hash = [string]$receipt.activation_reservation_hash
        source_thread_id = [string]$receipt.source_thread_id
        task_summary_hash = [string]$receipt.task_summary_hash
        window_start_utc = [string]$receipt.window_start_utc
        window_end_utc = [string]$receipt.window_end_utc
        create_call_status = [string]$receipt.create_call_status
        returned_thread_id = $receipt.returned_thread_id
        returned_client_thread_id = $receipt.returned_client_thread_id
        snapshot_count = [int]$receipt.snapshot_count
        visibility_delay_seconds = [double]$receipt.visibility_delay_seconds
        snapshot_captured_at = @($receipt.snapshot_captured_at)
        matched_thread_ids = @($receipt.matched_thread_ids)
        decision = [string]$receipt.decision
        adopted_thread_id = $receipt.adopted_thread_id
        adopted_host_id = $receipt.adopted_host_id
        duplicate_thread_ids = @($receipt.duplicate_thread_ids)
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Thread reconciliation receipt hash mismatch.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDecision) -and
        [string]$receipt.decision -ne $ExpectedDecision) {
        throw "Thread reconciliation decision is not '$ExpectedDecision'."
    }
    $normalizedSummary = [regex]::Replace(
        ([string]$input.task_summary).Trim(),
        '\s+',
        ' '
    ).ToLowerInvariant()
    if ([string]$receipt.activation_key -ne [string]$input.activation_key -or
        [string]$receipt.source_thread_id -ne [string]$input.source_thread_id -or
        [string]$receipt.task_summary_hash -ne
            (Get-TextSha256 $normalizedSummary) -or
        [string]$reservation.activation_key -ne [string]$input.activation_key -or
        [string]$reservation.source_thread_id -ne [string]$input.source_thread_id -or
        [string]$reservation.task_summary_hash -ne
            (Get-TextSha256 $normalizedSummary)) {
        throw 'Thread reconciliation receipt is not bound to its input.'
    }
    if ([string]$receipt.decision -eq 'no_match') {
        $snapshotTimes = @($input.snapshots | ForEach-Object {
            [DateTimeOffset]::Parse(
                [string]$_.captured_at,
                [Globalization.CultureInfo]::InvariantCulture
            ).ToUniversalTime()
        })
        $windowEnd = [DateTimeOffset]::Parse(
            [string]$input.window_end_utc,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
        $hasMatchingThread = $false
        foreach ($snapshot in @($input.snapshots)) {
            foreach ($thread in @($snapshot.threads)) {
                $preview = if ($null -ne
                    $thread.PSObject.Properties['preview']) {
                    [string]$thread.preview
                } else { '' }
                $activation = if ($null -ne
                    $thread.PSObject.Properties['activation_key']) {
                    [string]$thread.activation_key
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<activation_key>([^<]+)</activation_key>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                $source = if ($null -ne
                    $thread.PSObject.Properties['source_thread_id']) {
                    [string]$thread.source_thread_id
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<source_thread_id>([^<]+)</source_thread_id>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                if ($activation -eq [string]$input.activation_key -and
                    $source -eq [string]$input.source_thread_id) {
                    $hasMatchingThread = $true
                }
            }
        }
        if ($snapshotTimes.Count -lt 2 -or
            ($snapshotTimes[-1] - $snapshotTimes[0]).TotalSeconds -lt 40 -or
            $snapshotTimes[-1] -lt $windowEnd -or
            $hasMatchingThread) {
            throw 'Thread reconciliation no-match is not supported by its input.'
        }
    } elseif ([string]$receipt.decision -eq 'adopted') {
        $windowStart = [DateTimeOffset]::Parse(
            [string]$input.window_start_utc,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
        $windowEnd = [DateTimeOffset]::Parse(
            [string]$input.window_end_utc,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
        $expectedSummary = [regex]::Replace(
            ([string]$input.task_summary).Trim(),
            '\s+',
            ' '
        ).ToLowerInvariant()
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($snapshot in @($input.snapshots)) {
            foreach ($thread in @($snapshot.threads)) {
                $threadId = Get-TaskListRecordThreadId -Thread $thread
                $hostId = if ($null -ne
                    $thread.PSObject.Properties['host_id']) {
                    [string]$thread.host_id
                } else { '' }
                $preview = if ($null -ne
                    $thread.PSObject.Properties['preview']) {
                    [string]$thread.preview
                } else { '' }
                $activation = if ($null -ne
                    $thread.PSObject.Properties['activation_key']) {
                    [string]$thread.activation_key
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<activation_key>([^<]+)</activation_key>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                $source = if ($null -ne
                    $thread.PSObject.Properties['source_thread_id']) {
                    [string]$thread.source_thread_id
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<source_thread_id>([^<]+)</source_thread_id>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                $summaryMatches = $false
                if ($null -ne
                    $thread.PSObject.Properties['task_summary_hash']) {
                    $summaryMatches = (
                        [string]$thread.task_summary_hash
                    ).ToLowerInvariant() -eq (
                        Get-TextSha256 $expectedSummary
                    )
                } elseif ($null -ne
                    $thread.PSObject.Properties['task_summary']) {
                    $summaryMatches = (
                        [regex]::Replace(
                            ([string]$thread.task_summary).Trim(),
                            '\s+',
                            ' '
                        ).ToLowerInvariant()
                    ) -eq $expectedSummary
                } elseif (-not [string]::IsNullOrWhiteSpace($preview)) {
                    $summaryMatches = (
                        [regex]::Replace(
                            $preview.Trim(),
                            '\s+',
                            ' '
                        ).ToLowerInvariant()
                    ).Contains($expectedSummary)
                }
                if ([string]::IsNullOrWhiteSpace($threadId) -or
                    [string]::IsNullOrWhiteSpace($hostId) -or
                    $activation -ne [string]$input.activation_key -or
                    $source -ne [string]$input.source_thread_id -or
                    -not $summaryMatches -or
                    $null -eq $thread.PSObject.Properties['created_at']) {
                    continue
                }
                $createdAt = [DateTimeOffset]::Parse(
                    [string]$thread.created_at,
                    [Globalization.CultureInfo]::InvariantCulture
                ).ToUniversalTime()
                if ($createdAt -lt $windowStart -or $createdAt -gt $windowEnd) {
                    continue
                }
                $matches.Add([pscustomobject]@{
                    thread_id = $threadId
                    host_id = $hostId
                })
            }
        }
        $uniqueMatches = @($matches | Sort-Object thread_id -Unique)
        $receiptMatches = @($receipt.matched_thread_ids)
        $returnedThreadId = if ($null -eq $receipt.returned_thread_id) {
            ''
        } else { [string]$receipt.returned_thread_id }
        if ($uniqueMatches.Count -ne 1 -or
            $receiptMatches.Count -ne 1 -or
            [string]$receiptMatches[0] -ne
                [string]$uniqueMatches[0].thread_id -or
            [string]$receipt.adopted_thread_id -ne
                [string]$uniqueMatches[0].thread_id -or
            [string]$receipt.adopted_host_id -ne
                [string]$uniqueMatches[0].host_id -or
            @($receipt.duplicate_thread_ids).Count -ne 0 -or
            (-not [string]::IsNullOrWhiteSpace($returnedThreadId) -and
                $returnedThreadId -ne
                    [string]$uniqueMatches[0].thread_id)) {
            throw (
                'Thread reconciliation adopted decision is not supported by ' +
                'one unique input match.'
            )
        }
    }
    return $receipt
}

function Get-RunPolicySourceObligations {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Plan
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $items = [Collections.Generic.List[object]]::new()
    foreach ($node in @($Plan.nodes | Where-Object {
        [string]$_.kind -eq 'agent'
    } | Sort-Object -Property id)) {
        $legacyPath = Join-Path $runRoot (
            "receipts/$($node.id).legacy-source-adoption.json"
        )
        $replacementPath = Join-Path $runRoot (
            "receipts/$($node.id).replacement-continuity.json"
        )
        $legacy = $null
        $replacement = $null
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            $legacyRaw = Get-Content -LiteralPath $legacyPath -Raw |
                ConvertFrom-Json -Depth 50 -DateKind String
            $legacy = Read-LegacySourceAdoptionReceipt -Path $legacyPath `
                -RunDirectory $runRoot -ExpectedSourceNodeId ([string]$node.id) `
                -ExpectedOriginalThreadId (
                    [string]$legacyRaw.original_thread_id
                )
        }
        if (Test-Path -LiteralPath $replacementPath -PathType Leaf) {
            $replacementRaw = Get-Content -LiteralPath $replacementPath -Raw |
                ConvertFrom-Json -Depth 50 -DateKind String
            $replacement = Read-ReplacementContinuityReceipt `
                -Path $replacementPath -RunDirectory $runRoot `
                -ExpectedSourceNodeId ([string]$node.id) `
                -ExpectedReplacementThreadId (
                    [string]$replacementRaw.replacement_thread_id
                )
        }
        $items.Add([ordered]@{
            source_node_id = [string]$node.id
            role_id = [string]$node.role_id
            original_thread_id = if ($legacy) {
                [string]$legacy.original_thread_id
            } else { $null }
            checkpoint_hash = if ($legacy) {
                [string]$legacy.checkpoint_hash
            } else { $null }
            input_material_hash = if ($legacy) {
                [string]$legacy.input_material_hash
            } else { $null }
            legacy_adoption_receipt_hash = if ($legacy) {
                [string]$legacy.receipt_hash
            } else { $null }
            recovery_chain_hash = if ($replacement) {
                [string]$replacement.recovery_chain_hash
            } else { $null }
            replacement_thread_id = if ($replacement) {
                [string]$replacement.replacement_thread_id
            } else { $null }
            replacement_continuity_receipt_hash = if ($replacement) {
                [string]$replacement.receipt_hash
            } else { $null }
        })
    }
    return @($items)
}

function Read-RunPolicyActivationReceipt {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [object[]] $Events
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $relativeReceiptPath = (
        'receipts/run-policy-activation.' +
        $script:OrchestrationCurrentPolicyVersion + '.json'
    )
    $receiptPath = Join-Path $runRoot $relativeReceiptPath
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw (
            'This immutable run uses an older policy and has no verified ' +
            'run-policy activation receipt.'
        )
    }
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $journal = if ($null -ne $Events) {
        @($Events)
    } else {
        @(Read-OrchestrationJournal $eventsPath)
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $required = @(
        'schema_version', 'run_id', 'plan_hash', 'workspace_root',
        'source_policy_version', 'target_policy_version',
        'source_journal_head', 'source_journal_event_count',
        'source_obligations', 'source_obligations_hash',
        'artifact_bindings', 'artifact_bindings_hash',
        'authorization_material_path', 'authorization_material_hash',
        'activation_key', 'created_at_utc', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Run-policy activation receipt is missing '$name'."
        }
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.target_policy_version -ne
            $script:OrchestrationCurrentPolicyVersion -or
        [string]$receipt.source_policy_version -notin
            $script:OrchestrationMigratablePolicyVersions) {
        throw 'Run-policy activation receipt has an unsupported policy transition.'
    }
    if ([string]$receipt.run_id -ne [string]$plan.run_id -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$receipt.workspace_root -ne [string]$run.workspace_root -or
        [string]$receipt.source_policy_version -ne [string]$plan.policy_version -or
        [string]$run.policy_version -ne [string]$plan.policy_version) {
        throw 'Run-policy activation receipt does not match the immutable run.'
    }
    $sourceCount = [int]$receipt.source_journal_event_count
    if ($sourceCount -lt 1 -or $sourceCount -gt $journal.Count -or
        [string]$journal[$sourceCount - 1].hash -ne
            [string]$receipt.source_journal_head) {
        throw 'Run-policy activation receipt does not match the source journal boundary.'
    }
    $obligations = Get-RunPolicySourceObligations `
        -RunDirectory $runRoot -Plan $plan
    $obligationsHash = Get-TextSha256 (
        $obligations | ConvertTo-Json -Compress -Depth 30
    )
    if ([string]$receipt.source_obligations_hash -ne $obligationsHash -or
        (Get-TextSha256 (
            @($receipt.source_obligations) |
                ConvertTo-Json -Compress -Depth 30
        )) -ne $obligationsHash) {
        throw 'Run-policy source obligations changed after activation.'
    }
    $verifiedBindings = [Collections.Generic.List[object]]::new()
    $bindingPaths = @($receipt.artifact_bindings | ForEach-Object {
        [string]$_.path
    })
    if (@($bindingPaths | Select-Object -Unique).Count -ne
            $bindingPaths.Count -or
        (@($bindingPaths) -join "`n") -ne
            (@($bindingPaths | Sort-Object) -join "`n")) {
        throw 'Run-policy activation artifact bindings must be unique and sorted.'
    }
    foreach ($binding in @($receipt.artifact_bindings)) {
        $relative = [string]$binding.path
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [IO.Path]::IsPathRooted($relative) -or
            @($relative -split '[\\/]' | Where-Object {
                $_ -in @('', '.', '..') -or $_ -match '[. ]$' -or
                $_.Contains(':')
            }).Count -gt 0) {
            throw 'Run-policy activation contains an unsafe artifact path.'
        }
        $full = [IO.Path]::GetFullPath((Join-Path $runRoot $relative))
        if (-not $full.StartsWith(
            $runRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw 'Run-policy activation artifact is missing or escapes the run.'
        }
        $cursor = $runRoot
        foreach ($segment in $relative -split '[\\/]') {
            $cursor = Join-Path $cursor $segment
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Run-policy activation artifact crosses a reparse point.'
            }
        }
        $actualHash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.
            ToLowerInvariant()
        if ($actualHash -ne [string]$binding.sha256) {
            throw "Run-policy activation artifact changed: $relative"
        }
        $verifiedBindings.Add([ordered]@{
            path = $relative.Replace('\', '/')
            sha256 = $actualHash
        })
    }
    $bindingHash = Get-TextSha256 (
        @($verifiedBindings) | ConvertTo-Json -Compress -Depth 10
    )
    if ([string]$receipt.artifact_bindings_hash -ne $bindingHash) {
        throw 'Run-policy activation artifact manifest hash mismatch.'
    }
    $authorization = @($verifiedBindings | Where-Object {
        [string]$_.path -eq [string]$receipt.authorization_material_path
    }) | Select-Object -First 1
    if ($null -eq $authorization -or
        [string]$authorization.sha256 -ne
            [string]$receipt.authorization_material_hash) {
        throw 'Run-policy activation authorization is not bound to its artifacts.'
    }
    $payload = [ordered]@{}
    foreach ($name in $required | Where-Object { $_ -ne 'receipt_hash' }) {
        $payload[$name] = $receipt.$name
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 100
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Run-policy activation receipt hash mismatch.'
    }
    for ($index = $sourceCount; $index -lt $journal.Count; $index++) {
        $event = $journal[$index]
        if ([string]$event.policy_version -ne
                [string]$receipt.source_policy_version -or
            [string]$event.runtime_policy_version -ne
                [string]$receipt.target_policy_version -or
            [string]$event.policy_activation_receipt_path -ne
                $relativeReceiptPath -or
            [string]$event.policy_activation_receipt_hash -ne
                [string]$receipt.receipt_hash) {
            throw 'Post-activation journal event lacks the exact policy binding.'
        }
    }
    return $receipt
}

function Resolve-OrchestrationRunPolicy {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [object[]] $Events
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$plan.policy_version -eq
        $script:OrchestrationCurrentPolicyVersion) {
        return [pscustomobject]@{
            source_policy_version = [string]$plan.policy_version
            effective_policy_version = [string]$plan.policy_version
            activation_receipt_path = $null
            activation_receipt_hash = $null
        }
    }
    $receipt = Read-RunPolicyActivationReceipt -RunDirectory $runRoot `
        -Events $Events
    return [pscustomobject]@{
        source_policy_version = [string]$receipt.source_policy_version
        effective_policy_version = [string]$receipt.target_policy_version
        activation_receipt_path = (
            'receipts/run-policy-activation.' +
            $script:OrchestrationCurrentPolicyVersion + '.json'
        )
        activation_receipt_hash = [string]$receipt.receipt_hash
    }
}

function Get-DurableReviewSuccessorSnapshot {
    param([Parameter(Mandatory)][string] $RunDirectory)

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    foreach ($path in @($planPath, $runPath, $eventsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Successor export requires a complete predecessor run.'
        }
    }
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $runRaw = Get-Content -LiteralPath $runPath -Raw
    $run = $runRaw | ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -lt 1 -or
        [string]$run.run_id -ne [string]$plan.run_id -or
        [string]$run.plan_hash -ne (Get-TextSha256 $planRaw)) {
        throw 'Predecessor run identity is inconsistent.'
    }
    if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
        throw 'Successor export requires durable_review_profile.'
    }
    $chain = Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
    if (-not [string]::IsNullOrWhiteSpace([string]$chain.next_milestone_id)) {
        throw 'Successor export requires the final declared predecessor milestone.'
    }
    $policy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot -Events $events
    $requiredSourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids) |
            ForEach-Object { [string]$_ }
    )
    $sourceBindings = [Collections.Generic.List[object]]::new()
    $openObligations = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in $requiredSourceIds) {
        $bindingMatches = @($chain.active_source_bindings | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        if ($bindingMatches.Count -ne 1) {
            throw "Active milestone source '$sourceNodeId' is missing or repeated."
        }
        $binding = $bindingMatches[0]
        $nodeMatches = @($plan.nodes | Where-Object {
            [string]$_.id -eq $sourceNodeId
        })
        if ($nodeMatches.Count -ne 1) {
            throw "Predecessor source node '$sourceNodeId' is missing or repeated."
        }
        $roleId = [string]$nodeMatches[0].role_id
        $roleMatches = @($plan.roles | Where-Object {
            [string]$_.id -eq $roleId
        })
        if ($roleMatches.Count -ne 1) {
            throw "Predecessor role '$roleId' is missing or repeated."
        }
        $roleHash = Get-TextSha256 (
            $roleMatches[0] | ConvertTo-Json -Compress -Depth 100
        )
        $dispositionPath = Join-Path $runRoot (
            [string]$binding.disposition_receipt_path
        )
        $disposition = Read-ReviewDispositionReceipt -Path $dispositionPath `
            -RunDirectory $runRoot -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$binding.source_thread_id)
        $sourceBindings.Add([ordered]@{
            source_node_id = $sourceNodeId
            role_id = $roleId
            role_contract_hash = $roleHash
            source_thread_id = [string]$binding.source_thread_id
            milestone_id = [string]$chain.active_milestone_id
            checkpoint_material_path =
                [string]$binding.checkpoint_material_path
            checkpoint_material_hash =
                [string]$binding.checkpoint_material_hash
            result_receipt_path = [string]$binding.result_receipt_path
            result_receipt_hash = [string]$binding.result_receipt_hash
            result_file_hash = [string]$binding.result_file_hash
            disposition_receipt_path =
                [string]$binding.disposition_receipt_path
            disposition_receipt_hash =
                [string]$binding.disposition_receipt_hash
            disposition_file_hash = [string]$binding.disposition_file_hash
        })
        foreach ($decision in @($disposition.decisions)) {
            if ([string]$decision.severity -eq 'P0' -and
                [string]$decision.resolution_status -ne 'resolved') {
                throw (
                    "Successor export cannot carry unresolved P0 from " +
                    "'$sourceNodeId'."
                )
            }
            if ([string]$decision.severity -eq 'P1' -and
                [string]$decision.resolution_status -ne 'resolved') {
                $openObligations.Add([ordered]@{
                    source_node_id = $sourceNodeId
                    role_id = $roleId
                    source_thread_id = [string]$binding.source_thread_id
                    source_finding_id = [string]$decision.source_finding_id
                    canonical_finding_id =
                        [string]$decision.canonical_finding_id
                    severity = 'P1'
                    finding = [string]$decision.finding
                    finding_hash = [string]$decision.finding_hash
                    resolution_status = [string]$decision.resolution_status
                })
            }
        }
    }
    if ($openObligations.Count -lt 1) {
        throw 'Successor export requires at least one unresolved P1 obligation.'
    }
    $checkpointPaths = @(
        $sourceBindings |
            ForEach-Object { [string]$_['checkpoint_material_path'] } |
            Select-Object -Unique
    )
    $checkpointHashes = @(
        $sourceBindings |
            ForEach-Object { [string]$_['checkpoint_material_hash'] } |
            Select-Object -Unique
    )
    if ($checkpointPaths.Count -ne 1 -or $checkpointHashes.Count -ne 1) {
        throw 'Successor export sources must bind one checkpoint.'
    }
    return [pscustomobject]@{
        run_root = $runRoot
        plan = $plan
        plan_raw = $planRaw
        plan_hash = [string]$run.plan_hash
        run = $run
        run_raw = $runRaw
        run_file_hash = (
            Get-FileHash -LiteralPath $runPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        events = $events
        genesis_hash = [string]$events[0].hash
        effective_policy_version = [string]$policy.effective_policy_version
        active_milestone_id = [string]$chain.active_milestone_id
        active_milestone_receipt_path =
            [string]$chain.activation_receipt_path
        active_milestone_receipt_hash =
            [string]$chain.activation_receipt_hash
        checkpoint_material_path = [string]$checkpointPaths[0]
        checkpoint_material_hash = [string]$checkpointHashes[0]
        source_bindings = @($sourceBindings)
        source_bindings_hash = Get-TextSha256 (
            @($sourceBindings) | ConvertTo-Json -Compress -Depth 100
        )
        open_obligations = @($openObligations)
        open_obligations_hash = Get-TextSha256 (
            @($openObligations) | ConvertTo-Json -Compress -Depth 100
        )
    }
}

function Read-DurableReviewSuccessorExportReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PredecessorRunDirectory,
        [Parameter(Mandatory)][string] $SuccessorPlanPath,
        [string] $ExpectedSuccessorRunDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Successor export receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $keys = @(
        'schema_version', 'predecessor_run_path', 'predecessor_run_id',
        'predecessor_plan_hash',
        'predecessor_run_file_hash', 'predecessor_genesis_hash',
        'predecessor_journal_head', 'predecessor_journal_event_count',
        'effective_policy_version', 'active_milestone_id',
        'active_milestone_receipt_path', 'active_milestone_receipt_hash',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'source_bindings', 'source_bindings_hash', 'open_obligations',
        'open_obligations_hash', 'successor_run_id', 'successor_plan_hash',
        'successor_run_path',
        'successor_milestone_ids', 'authorization_material_path',
        'authorization_material_hash', 'activation_key', 'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Successor export receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Successor export receipt hash or schema is invalid.'
    }
    $snapshot = Get-DurableReviewSuccessorSnapshot `
        -RunDirectory $PredecessorRunDirectory
    $events = @($snapshot.events)
    if ($events.Count -ne ([int]$receipt.predecessor_journal_event_count + 1) -or
        [string]$events[-2].hash -ne [string]$receipt.predecessor_journal_head) {
        throw 'Predecessor journal changed outside the successor export event.'
    }
    $exportEvent = $events[-1]
    if ([string]$exportEvent.event -ne 'durable-review-successor-exported' -or
        [string]$exportEvent.result_receipt_hash -ne
            [string]$receipt.receipt_hash -or
        [string]$exportEvent.prev_hash -ne
            [string]$receipt.predecessor_journal_head) {
        throw 'Successor export event does not bind the receipt.'
    }
    $successorPlanRaw = Get-Content -LiteralPath $SuccessorPlanPath -Raw
    $successorPlan = $successorPlanRaw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $comparisons = @(
        @([string]$receipt.predecessor_run_path,
            [string]$snapshot.run_root),
        @([string]$receipt.predecessor_run_id, [string]$snapshot.run.run_id),
        @([string]$receipt.predecessor_plan_hash, [string]$snapshot.plan_hash),
        @([string]$receipt.predecessor_run_file_hash,
            [string]$snapshot.run_file_hash),
        @([string]$receipt.predecessor_genesis_hash,
            [string]$snapshot.genesis_hash),
        @([string]$receipt.effective_policy_version,
            [string]$snapshot.effective_policy_version),
        @([string]$receipt.active_milestone_id,
            [string]$snapshot.active_milestone_id),
        @([string]$receipt.active_milestone_receipt_hash,
            [string]$snapshot.active_milestone_receipt_hash),
        @([string]$receipt.checkpoint_material_hash,
            [string]$snapshot.checkpoint_material_hash),
        @([string]$receipt.source_bindings_hash,
            [string]$snapshot.source_bindings_hash),
        @([string]$receipt.open_obligations_hash,
            [string]$snapshot.open_obligations_hash),
        @([string]$receipt.successor_run_id, [string]$successorPlan.run_id),
        @([string]$receipt.successor_plan_hash,
            (Get-TextSha256 $successorPlanRaw))
    )
    if (@($comparisons | Where-Object { $_[0] -ne $_[1] }).Count -gt 0) {
        throw 'Successor export receipt no longer matches its bound runs.'
    }
    if ((@($receipt.source_bindings) | ConvertTo-Json -Compress -Depth 100) -ne
        (@($snapshot.source_bindings) | ConvertTo-Json -Compress -Depth 100) -or
        (@($receipt.open_obligations) |
            ConvertTo-Json -Compress -Depth 100) -ne
        (@($snapshot.open_obligations) |
            ConvertTo-Json -Compress -Depth 100)) {
        throw 'Successor export source identities or P1 obligations changed.'
    }
    $successorMilestones = @(
        $successorPlan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    if ((@($receipt.successor_milestone_ids) -join "`n") -ne
        ($successorMilestones -join "`n")) {
        throw 'Successor export milestone declaration changed.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSuccessorRunDirectory) -and
        [string]$receipt.successor_run_path -ne [IO.Path]::GetFullPath(
            $ExpectedSuccessorRunDirectory
        ).TrimEnd('\', '/')) {
        throw 'Successor export cannot be replayed into another run directory.'
    }
    $authorizationPath = Join-Path $snapshot.run_root (
        [string]$receipt.authorization_material_path
    )
    if (-not (Test-Path -LiteralPath $authorizationPath -PathType Leaf) -or
        [string]$receipt.authorization_material_hash -ne (
            Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Successor export authorization material changed.'
    }
    return $receipt
}

function Get-AbandonedSuccessorSnapshot {
    param([Parameter(Mandatory)][string] $RunDirectory)

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    foreach ($path in @($planPath, $runPath, $eventsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Abandoned successor export requires a complete run.'
        }
    }
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $runRaw = Get-Content -LiteralPath $runPath -Raw
    $run = $runRaw | ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -lt 2 -or
        [string]$run.run_id -ne [string]$plan.run_id -or
        [string]$run.plan_hash -ne (Get-TextSha256 $planRaw)) {
        throw 'Abandoned successor run identity is inconsistent.'
    }
    if ($null -eq $plan.PSObject.Properties['successor_review_profile']) {
        throw 'Abandoned successor export requires a successor run.'
    }
    $adoption = Read-DurableReviewSuccessorAdoptionReceipt -RunDirectory $runRoot
    if ([string]$adoption.schema_version -ne '1.0') {
        throw 'Only a first-generation successor may be abandoned.'
    }
    $exportEvents = @($events | Where-Object {
        [string]$_.event -eq 'durable-review-abandoned-successor-exported'
    })
    if ($exportEvents.Count -gt 1) {
        throw 'The abandoned successor has more than one export event.'
    }
    $baseEvents = if ($exportEvents.Count -eq 1) {
        if ([string]$events[-1].event -ne
            'durable-review-abandoned-successor-exported') {
            throw 'The abandoned successor export must be the journal tail.'
        }
        @($events | Select-Object -First ($events.Count - 1))
    } else { @($events) }
    if (@($baseEvents | Where-Object {
        [string]$_.event -eq 'durable-review-milestone-activated' -or
        [string]$_.event -eq 'durable-review-milestone-accepted'
    }).Count -gt 0) {
        throw 'An activated or accepted milestone cannot be abandoned.'
    }
    $receiptRoot = Join-Path $runRoot 'receipts'
    if (Test-Path -LiteralPath $receiptRoot -PathType Container) {
        $milestoneReceipts = @(Get-ChildItem -LiteralPath $receiptRoot -File |
            Where-Object {
                $_.Name -match
                    '^durable-review-milestone\..+\.(activation|acceptance)\.json$'
            })
        if ($milestoneReceipts.Count -gt 0) {
            throw 'A milestone receipt prevents abandoned-successor recovery.'
        }
    }
    if (@($baseEvents | Where-Object {
        [string]$_.node_id -eq
            [string]$plan.durable_review_profile.main_owner_node_id -and
        [string]$_.status -in @('completed', 'validated', 'adopted', 'archived')
    }).Count -gt 0) {
        throw 'A successor with main acceptance cannot be abandoned.'
    }

    $sourceIds = @($plan.successor_review_profile.source_node_ids |
        ForEach-Object { [string]$_ })
    $bindings = [Collections.Generic.List[object]]::new()
    $cancelledCount = 0
    foreach ($sourceId in $sourceIds) {
        $adoptionBindings = @($adoption.source_bindings | Where-Object {
            [string]$_.source_node_id -eq $sourceId
        })
        $nodeMatches = @($plan.nodes | Where-Object {
            [string]$_.id -eq $sourceId
        })
        if ($adoptionBindings.Count -ne 1 -or $nodeMatches.Count -ne 1) {
            throw "Abandoned successor source '$sourceId' is not uniquely bound."
        }
        $history = @($baseEvents | Where-Object {
            [string]$_.node_id -eq $sourceId
        })
        $state = if ($history.Count) {
            [string]$history[-1].status
        } else { 'planned' }
        if ($state -notin @('planned', 'cancelled')) {
            throw "Abandoned successor source '$sourceId' is not terminal-safe."
        }
        if (@($history | Where-Object {
            [string]$_.status -in @(
                'completed', 'result_pending', 'replacement_pending',
                'validated', 'adopted', 'archived'
            )
        }).Count -gt 0) {
            throw "Abandoned successor source '$sourceId' has a result lifecycle."
        }
        if ($state -eq 'cancelled') {
            $cancelledCount++
            $cancelled = $history[-1]
            $evidence = @($cancelled.evidence | ForEach-Object { [string]$_ })
            if ('observation:no-review-message-dispatched' -notin $evidence) {
                throw "Cancelled source '$sourceId' lacks no-dispatch evidence."
            }
            $dispatched = @($history | ForEach-Object { @($_.evidence) } |
                ForEach-Object { [string]$_ } | Where-Object {
                    $_ -match '(^|:)review-message-dispatched' -and
                    $_ -ne 'observation:no-review-message-dispatched'
                })
            if ($dispatched.Count -gt 0) {
                throw "Cancelled source '$sourceId' has dispatched-review evidence."
            }
        }
        $roleId = [string]$nodeMatches[0].role_id
        $roleMatches = @($plan.roles | Where-Object {
            [string]$_.id -eq $roleId
        })
        if ($roleMatches.Count -ne 1) {
            throw "Abandoned successor role '$roleId' is not uniquely bound."
        }
        $binding = $adoptionBindings[0]
        $attempts = @($history | Where-Object {
            [string]$_.status -eq 'launch_reserved'
        }).Count
        $bindings.Add([ordered]@{
            source_node_id = $sourceId
            role_id = $roleId
            role_contract_hash = Get-TextSha256 (
                $roleMatches[0] | ConvertTo-Json -Compress -Depth 100
            )
            source_thread_id = [string]$binding.source_thread_id
            abandoned_state = $state
            inherited_attempt_count = $attempts
            cancelled_event_hash = if ($state -eq 'cancelled') {
                [string]$history[-1].hash
            } else { '' }
        })
    }
    if ($cancelledCount -lt 1) {
        throw 'Abandoned successor export requires a cancelled durable source.'
    }
    $policy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot `
        -Events $baseEvents
    return [pscustomobject]@{
        run_root = $runRoot
        plan = $plan
        plan_raw = $planRaw
        plan_hash = [string]$run.plan_hash
        run = $run
        run_raw = $runRaw
        run_file_hash = (
            Get-FileHash -LiteralPath $runPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        events = @($events)
        base_events = @($baseEvents)
        genesis_hash = [string]$baseEvents[0].hash
        journal_head = [string]$baseEvents[-1].hash
        journal_event_count = $baseEvents.Count
        effective_policy_version = [string]$policy.effective_policy_version
        adoption_receipt = $adoption
        adoption_receipt_path =
            'receipts/durable-review-successor.adoption.json'
        adoption_receipt_file_hash = (
            Get-FileHash -LiteralPath (Join-Path $runRoot (
                'receipts/durable-review-successor.adoption.json'
            )) -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        source_bindings = @($bindings)
        source_bindings_hash = Get-TextSha256 (
            @($bindings) | ConvertTo-Json -Compress -Depth 100
        )
    }
}

function Read-AbandonedSuccessorAuthorizationReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $AbandonedRunDirectory,
        [Parameter(Mandatory)][string] $SuccessorPlanPath,
        [Parameter(Mandatory)][string] $ExpectedSuccessorRunDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Abandoned successor authorization does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $keys = @(
        'schema_version', 'lineage_kind', 'abandoned_run_path',
        'abandoned_run_id', 'abandoned_plan_hash', 'authorization_journal_head',
        'authorization_journal_event_count', 'source_bindings_hash',
        'checkpoint_material_path', 'checkpoint_material_hash',
        'additional_findings_path', 'additional_findings_hash',
        'unactivated_evidence_manifest_path',
        'unactivated_evidence_manifest_hash', 'successor_run_id',
        'successor_plan_hash', 'successor_run_path', 'successor_milestone_ids',
        'authorization_material_path', 'authorization_material_hash',
        'activation_key', 'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Abandoned successor authorization is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.lineage_kind -ne 'abandoned-successor-authorization' -or
        [string]$receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Abandoned successor authorization hash or schema is invalid.'
    }
    $snapshot = Get-AbandonedSuccessorSnapshot `
        -RunDirectory $AbandonedRunDirectory
    $events = @($snapshot.events)
    $authorizationEvents = @($events | Where-Object {
        [string]$_.event -eq 'durable-review-abandoned-successor-authorized'
    })
    if ($authorizationEvents.Count -ne 1) {
        throw 'Abandoned successor authorization event is missing or repeated.'
    }
    $authorizationIndex = [Array]::IndexOf($events, $authorizationEvents[0])
    if ($authorizationIndex -ne [int]$receipt.authorization_journal_event_count) {
        throw 'Abandoned successor authorization event position changed.'
    }
    $event = $authorizationEvents[0]
    if ([string]$event.prev_hash -ne
            [string]$receipt.authorization_journal_head -or
        [string]$event.result_receipt_hash -ne [string]$receipt.receipt_hash -or
        [string]$event.idempotency_key -ne [string]$receipt.activation_key -or
        [string]$event.request_fingerprint -ne [string]$receipt.receipt_hash) {
        throw 'Abandoned successor authorization event binding changed.'
    }
    $planRaw = Get-Content -LiteralPath $SuccessorPlanPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$receipt.abandoned_run_path -ne [string]$snapshot.run_root -or
        [string]$receipt.abandoned_run_id -ne [string]$snapshot.run.run_id -or
        [string]$receipt.abandoned_plan_hash -ne [string]$snapshot.plan_hash -or
        [string]$receipt.source_bindings_hash -ne
            [string]$snapshot.source_bindings_hash -or
        [string]$receipt.successor_run_id -ne [string]$plan.run_id -or
        [string]$receipt.successor_plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$receipt.successor_run_path -ne [IO.Path]::GetFullPath(
            $ExpectedSuccessorRunDirectory
        ).TrimEnd('\', '/') -or
        (@($receipt.successor_milestone_ids) -join "`n") -ne
            (@($plan.durable_review_profile.milestone_ids) -join "`n")) {
        throw 'Abandoned successor authorization lineage changed.'
    }
    foreach ($property in @(
        'checkpoint_material', 'additional_findings',
        'unactivated_evidence_manifest', 'authorization_material'
    )) {
        $relative = [string]$receipt.("${property}_path")
        $expectedHash = [string]$receipt.("${property}_hash")
        $file = Join-Path $snapshot.run_root $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            $expectedHash -ne (
                Get-FileHash -LiteralPath $file -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw "Abandoned successor authorization material '$property' changed."
        }
    }
    return $receipt
}

function Read-AbandonedSuccessorExportReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $AbandonedRunDirectory,
        [Parameter(Mandatory)][string] $SuccessorPlanPath,
        [string] $ExpectedSuccessorRunDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Abandoned successor export receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $keys = @(
        'schema_version', 'lineage_kind', 'abandoned_run_path',
        'abandoned_run_id', 'abandoned_plan_hash', 'abandoned_run_file_hash',
        'abandoned_genesis_hash', 'abandoned_journal_head',
        'abandoned_journal_event_count', 'effective_policy_version',
        'original_adoption_receipt_path', 'original_adoption_receipt_hash',
        'original_adoption_receipt_file_hash', 'source_bindings',
        'source_bindings_hash', 'inherited_obligations',
        'inherited_obligations_hash', 'additional_findings_path',
        'additional_findings_hash', 'unactivated_evidence_manifest_path',
        'unactivated_evidence_manifest_hash', 'checkpoint_material_path',
        'checkpoint_material_hash', 'successor_run_id',
        'successor_plan_hash', 'successor_run_path', 'successor_milestone_ids',
        'authorization_receipt_path', 'authorization_receipt_hash',
        'authorization_receipt_file_hash', 'authorization_event_hash',
        'authorization_material_path', 'authorization_material_hash',
        'activation_key', 'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Abandoned successor export receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.lineage_kind -ne 'abandoned-successor' -or
        [string]$receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Abandoned successor export receipt hash or schema is invalid.'
    }
    $snapshot = Get-AbandonedSuccessorSnapshot `
        -RunDirectory $AbandonedRunDirectory
    $events = @($snapshot.events)
    if ($events.Count -ne ([int]$receipt.abandoned_journal_event_count + 1) -or
        [string]$events[-2].hash -ne [string]$receipt.abandoned_journal_head) {
        throw 'Abandoned successor journal changed outside its export event.'
    }
    $event = $events[-1]
    if ([string]$event.event -ne
            'durable-review-abandoned-successor-exported' -or
        [string]$event.result_receipt_hash -ne [string]$receipt.receipt_hash -or
        [string]$event.prev_hash -ne [string]$receipt.abandoned_journal_head -or
        [string]$event.idempotency_key -ne [string]$receipt.activation_key) {
        throw 'Abandoned successor export event does not bind the receipt.'
    }
    $planRaw = Get-Content -LiteralPath $SuccessorPlanPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $comparisons = @(
        @([string]$receipt.abandoned_run_path, [string]$snapshot.run_root),
        @([string]$receipt.abandoned_run_id, [string]$snapshot.run.run_id),
        @([string]$receipt.abandoned_plan_hash, [string]$snapshot.plan_hash),
        @([string]$receipt.abandoned_run_file_hash,
            [string]$snapshot.run_file_hash),
        @([string]$receipt.abandoned_genesis_hash,
            [string]$snapshot.genesis_hash),
        @([string]$receipt.effective_policy_version,
            [string]$snapshot.effective_policy_version),
        @([string]$receipt.original_adoption_receipt_hash,
            [string]$snapshot.adoption_receipt.receipt_hash),
        @([string]$receipt.original_adoption_receipt_path,
            [string]$snapshot.adoption_receipt_path),
        @([string]$receipt.original_adoption_receipt_file_hash,
            [string]$snapshot.adoption_receipt_file_hash),
        @([string]$receipt.source_bindings_hash,
            [string]$snapshot.source_bindings_hash),
        @([string]$receipt.successor_run_id, [string]$plan.run_id),
        @([string]$receipt.successor_plan_hash, (Get-TextSha256 $planRaw))
    )
    if (@($comparisons | Where-Object { $_[0] -ne $_[1] }).Count -gt 0) {
        throw 'Abandoned successor export no longer matches its bound runs.'
    }
    $authorizationPath = Join-Path $snapshot.run_root (
        [string]$receipt.authorization_receipt_path
    )
    $authorization = Read-AbandonedSuccessorAuthorizationReceipt `
        -Path $authorizationPath -AbandonedRunDirectory $snapshot.run_root `
        -SuccessorPlanPath $SuccessorPlanPath `
        -ExpectedSuccessorRunDirectory ([string]$receipt.successor_run_path)
    if ([string]$receipt.authorization_receipt_hash -ne
            [string]$authorization.receipt_hash -or
        [string]$receipt.authorization_receipt_file_hash -ne (
            Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        [string]$receipt.authorization_event_hash -ne
            [string]$events[-2].hash -or
        [string]$events[-2].event -ne
            'durable-review-abandoned-successor-authorized' -or
        [string]$receipt.authorization_material_path -ne
            [string]$authorization.authorization_material_path -or
        [string]$receipt.authorization_material_hash -ne
            [string]$authorization.authorization_material_hash -or
        [string]$receipt.activation_key -ne [string]$authorization.activation_key) {
        throw 'Abandoned successor export authorization anchor changed.'
    }
    if ((@($receipt.source_bindings) | ConvertTo-Json -Compress -Depth 100) -ne
        (@($snapshot.source_bindings) | ConvertTo-Json -Compress -Depth 100)) {
        throw 'Abandoned successor source identity or attempt count changed.'
    }
    foreach ($relative in @(
        'additional_findings_path', 'unactivated_evidence_manifest_path',
        'checkpoint_material_path', 'authorization_material_path'
    )) {
        $filePath = Join-Path $snapshot.run_root ([string]$receipt.$relative)
        $hashName = $relative -replace '_path$', '_hash'
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
            [string]$receipt.$hashName -ne (
                Get-FileHash -LiteralPath $filePath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw "Abandoned successor bound material '$relative' changed."
        }
    }
    if ([string]$plan.successor_review_profile.predecessor_run_id -ne
            [string]$snapshot.run.run_id -or
        [string]$plan.successor_review_profile.predecessor_active_milestone_id -ne
            'abandoned-before-first-milestone' -or
        [string]$plan.successor_review_profile.
            predecessor_checkpoint_material_hash -ne
            [string]$receipt.checkpoint_material_hash -or
        (@($plan.successor_review_profile.source_node_ids) -join "`n") -ne
            (@($snapshot.source_bindings |
                ForEach-Object { [string]$_.source_node_id }) -join "`n") -or
        (@($receipt.successor_milestone_ids) -join "`n") -ne
            (@($plan.durable_review_profile.milestone_ids) -join "`n")) {
        throw 'Fresh successor plan changed the abandoned lineage declaration.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSuccessorRunDirectory) -and
        [string]$receipt.successor_run_path -ne [IO.Path]::GetFullPath(
            $ExpectedSuccessorRunDirectory
        ).TrimEnd('\', '/')) {
        throw 'Abandoned export cannot be replayed into another run directory.'
    }
    if ([string]$receipt.inherited_obligations_hash -ne (Get-TextSha256 (
        @($receipt.inherited_obligations) |
            ConvertTo-Json -Compress -Depth 100
    ))) {
        throw 'Abandoned successor obligations changed.'
    }
    $additionalPath = Join-Path $snapshot.run_root (
        [string]$receipt.additional_findings_path
    )
    $additional = @(Get-Content -LiteralPath $additionalPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String)
    $expected = [Collections.Generic.List[object]]::new()
    $seenObligations = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($item in @($snapshot.adoption_receipt.inherited_obligations)) {
        $key = [string]$item.source_node_id + "`n" +
            [string]$item.source_finding_id
        if (-not $seenObligations.Add($key)) {
            throw 'Abandoned successor baseline obligations are duplicated.'
        }
        $expected.Add($item)
    }
    foreach ($item in $additional) {
        $binding = @($snapshot.source_bindings | Where-Object {
            [string]$_.source_node_id -eq [string]$item.source_node_id
        })
        if ($binding.Count -ne 1 -or [string]$item.severity -ne 'P1' -or
            [string]$item.resolution_status -eq 'resolved' -or
            [string]$item.finding_hash -ne (Get-TextSha256 (
                [string]$item.finding
            )) -or -not $seenObligations.Add(
                [string]$item.source_node_id + "`n" +
                [string]$item.source_finding_id
            )) {
            throw 'Abandoned successor additional finding changed.'
        }
        $expected.Add([ordered]@{
            source_node_id = [string]$item.source_node_id
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
    if ((@($receipt.inherited_obligations) |
            ConvertTo-Json -Compress -Depth 100) -ne
        (@($expected) | ConvertTo-Json -Compress -Depth 100)) {
        throw 'Abandoned successor omitted, merged, or changed an obligation.'
    }
    $manifestPath = Join-Path $snapshot.run_root (
        [string]$receipt.unactivated_evidence_manifest_path
    )
    $manifest = @(Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String)
    if ($manifest.Count -ne @($snapshot.source_bindings).Count) {
        throw 'Abandoned successor evidence manifest source count changed.'
    }
    foreach ($binding in @($snapshot.source_bindings)) {
        $entry = @($manifest | Where-Object {
            [string]$_.source_node_id -eq [string]$binding.source_node_id
        })
        if ($entry.Count -ne 1 -or
            [bool]$entry[0].completion_eligible -ne $false) {
            throw 'Abandoned successor evidence manifest changed.'
        }
        $resultPath = Join-Path $snapshot.run_root (
            [string]$entry[0].result_receipt_path
        )
        $dispositionPath = Join-Path $snapshot.run_root (
            [string]$entry[0].disposition_receipt_path
        )
        if ([string]$entry[0].result_receipt_file_hash -ne (
                Get-FileHash -LiteralPath $resultPath -Algorithm SHA256
            ).Hash.ToLowerInvariant() -or
            [string]$entry[0].disposition_receipt_file_hash -ne (
                Get-FileHash -LiteralPath $dispositionPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Abandoned successor unactivated evidence changed.'
        }
        $null = Read-ThreadResultReceipt -Path $resultPath `
            -ExpectedThreadId ([string]$binding.source_thread_id) `
            -ExpectedSourceNodeId ([string]$binding.source_node_id) `
            -RunDirectory $snapshot.run_root
        $null = Read-ReviewDispositionReceipt -Path $dispositionPath `
            -RunDirectory $snapshot.run_root `
            -ExpectedSourceNodeId ([string]$binding.source_node_id) `
            -ExpectedThreadId ([string]$binding.source_thread_id)
    }
    return $receipt
}

function Read-AbandonedSuccessorAdoptionReceipt {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Receipt
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    $keys = @(
        'schema_version', 'lineage_kind', 'run_path', 'run_id', 'plan_hash',
        'genesis_hash', 'predecessor_run_path', 'predecessor_run_id',
        'predecessor_final_journal_head',
        'predecessor_final_journal_event_count', 'export_receipt_path',
        'export_receipt_hash', 'export_receipt_file_hash',
        'predecessor_active_milestone_id', 'checkpoint_material_hash',
        'source_bindings', 'source_bindings_hash', 'inherited_obligations',
        'inherited_obligations_hash', 'successor_milestone_ids',
        'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $Receipt.PSObject.Properties[$name]) {
            throw "Abandoned successor adoption is missing '$name'."
        }
        $payload[$name] = $Receipt.$name
    }
    if ([string]$Receipt.schema_version -ne '1.1' -or
        [string]$Receipt.lineage_kind -ne 'abandoned-successor' -or
        [string]$Receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Abandoned successor adoption receipt hash or schema is invalid.'
    }
    if ($events.Count -lt (2 + @($Receipt.source_bindings).Count) -or
        [string]$events[1].event -ne 'durable-review-successor-adopted' -or
        [string]$events[1].result_receipt_hash -ne
            [string]$Receipt.receipt_hash -or
        [string]$Receipt.run_path -ne $runRoot -or
        [string]$Receipt.run_id -ne [string]$run.run_id -or
        [string]$Receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$Receipt.plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$Receipt.genesis_hash -ne [string]$events[0].hash) {
        throw 'Abandoned successor adoption run identity changed.'
    }
    $predecessorRoot = [IO.Path]::GetFullPath(
        [string]$Receipt.predecessor_run_path
    ).TrimEnd('\', '/')
    $exportPath = Join-Path $predecessorRoot (
        [string]$Receipt.export_receipt_path
    )
    $export = Read-AbandonedSuccessorExportReceipt -Path $exportPath `
        -AbandonedRunDirectory $predecessorRoot `
        -SuccessorPlanPath $planPath -ExpectedSuccessorRunDirectory $runRoot
    $predecessorEvents = @(Read-OrchestrationJournal (
        Join-Path $predecessorRoot 'events.jsonl'
    ))
    if ([string]$Receipt.predecessor_final_journal_head -ne
            [string]$predecessorEvents[-1].hash -or
        [int]$Receipt.predecessor_final_journal_event_count -ne
            $predecessorEvents.Count -or
        [string]$Receipt.export_receipt_hash -ne [string]$export.receipt_hash -or
        [string]$Receipt.export_receipt_file_hash -ne (
            Get-FileHash -LiteralPath $exportPath -Algorithm SHA256
        ).Hash.ToLowerInvariant() -or
        (@($Receipt.source_bindings) | ConvertTo-Json -Compress -Depth 100) -ne
            (@($export.source_bindings) |
                ConvertTo-Json -Compress -Depth 100) -or
        (@($Receipt.inherited_obligations) |
            ConvertTo-Json -Compress -Depth 100) -ne
            (@($export.inherited_obligations) |
                ConvertTo-Json -Compress -Depth 100)) {
        throw 'Abandoned successor adoption lineage changed.'
    }
    foreach ($index in 0..(@($Receipt.source_bindings).Count - 1)) {
        $binding = @($Receipt.source_bindings)[$index]
        $event = $events[$index + 2]
        $node = @($plan.nodes | Where-Object {
            [string]$_.id -eq [string]$binding.source_node_id
        })
        if ($node.Count -ne 1 -or
            [string]$node[0].role_id -ne [string]$binding.role_id -or
            [string]$node[0].context.session_policy -ne 'reuse' -or
            [string]$node[0].context.prior_thread_id -ne
                [string]$binding.source_thread_id -or
            [bool]$node[0].read_only -ne $true -or
            [bool]$node[0].allow_delegation -ne $false -or
            [int]$node[0].max_attempts -le
                [int]$binding.inherited_attempt_count -or
            [string]$event.event -ne 'source-attempt-carried' -or
            [string]$event.node_id -ne [string]$binding.source_node_id -or
            [int]$event.attempt -ne [int]$binding.inherited_attempt_count -or
            [string]$event.prev_hash -ne [string]$events[$index + 1].hash) {
            throw 'Fresh successor did not preserve source continuity or attempts.'
        }
        $role = @($plan.roles | Where-Object {
            [string]$_.id -eq [string]$binding.role_id
        })
        if ($role.Count -ne 1 -or
            (Get-TextSha256 (
                $role[0] | ConvertTo-Json -Compress -Depth 100
            )) -ne [string]$binding.role_contract_hash) {
            throw 'Fresh successor changed a durable role contract.'
        }
    }
    return $Receipt
}

function Get-DurableReviewSourceRotationSnapshot {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $RotationManifestPath
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    foreach ($path in @($planPath, $runPath, $eventsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Source rotation requires a complete predecessor run.'
        }
    }
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $runRaw = Get-Content -LiteralPath $runPath -Raw
    $run = $runRaw | ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -lt 2 -or
        [string]$run.run_id -ne [string]$plan.run_id -or
        [string]$run.plan_hash -ne (Get-TextSha256 $planRaw)) {
        throw 'Source-rotation predecessor identity is inconsistent.'
    }
    if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
        throw 'Source rotation requires durable_review_profile.'
    }
    $exportEvents = @($events | Where-Object {
        [string]$_.event -eq 'durable-review-source-rotation-exported'
    })
    if ($exportEvents.Count -gt 1) {
        throw 'The predecessor has more than one source-rotation export.'
    }
    $baseEvents = if ($exportEvents.Count -eq 1) {
        if ([string]$events[-1].event -ne
            'durable-review-source-rotation-exported') {
            throw 'The source-rotation export must be the predecessor journal tail.'
        }
        @($events | Select-Object -First ($events.Count - 1))
    } else { @($events) }

    $chain = Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
    if ([string]::IsNullOrWhiteSpace([string]$chain.next_milestone_id)) {
        throw 'Source rotation requires an immediately next declared milestone.'
    }
    $targetEvents = @($baseEvents | Where-Object {
        [string]$_.event -in @(
            'durable-review-milestone-activated',
            'durable-review-milestone-revision-selected',
            'milestone-activated',
            'milestone-revision-selected'
        ) -and [string]$_.milestone_id -eq [string]$chain.next_milestone_id
    })
    if ($targetEvents.Count -gt 0) {
        throw 'Source rotation cannot replace an already activated next milestone.'
    }

    $manifestFullPath = [IO.Path]::GetFullPath($RotationManifestPath)
    if (-not $manifestFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
        throw 'Source-rotation manifest must be a run-local file.'
    }
    $manifestRaw = Get-Content -LiteralPath $manifestFullPath -Raw
    $manifest = $manifestRaw |
        ConvertFrom-Json -Depth 100 -DateKind String
    foreach ($name in @(
        'schema_version', 'active_milestone_id', 'target_milestone_id',
        'checkpoint_material_path', 'checkpoint_material_hash', 'sources'
    )) {
        if ($null -eq $manifest.PSObject.Properties[$name]) {
            throw "Source-rotation manifest is missing '$name'."
        }
    }
    if ([string]$manifest.schema_version -ne '1.0' -or
        [string]$manifest.active_milestone_id -ne
            [string]$chain.active_milestone_id -or
        [string]$manifest.target_milestone_id -ne
            [string]$chain.next_milestone_id) {
        throw 'Source-rotation manifest changed the milestone sequence.'
    }
    $checkpointPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$manifest.checkpoint_material_path) `
        -Label 'Source-rotation checkpoint'
    $checkpointHash = Get-TextSha256 (
        Get-Content -LiteralPath $checkpointPath -Raw
    )
    if ($checkpointHash -ne [string]$manifest.checkpoint_material_hash) {
        throw 'Source-rotation checkpoint is missing or changed.'
    }

    $requiredSourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids) |
            ForEach-Object { [string]$_ }
    )
    $manifestSources = @($manifest.sources)
    if ($requiredSourceIds.Count -ne 2 -or
        $manifestSources.Count -ne 2 -or
        (@($manifestSources | ForEach-Object {
            [string]$_.source_node_id
        }) -join "`n") -ne ($requiredSourceIds -join "`n")) {
        throw (
            'Source rotation requires the exact ordered pair of durable review ' +
            'sources.'
        )
    }

    $formalBindings = [Collections.Generic.List[object]]::new()
    $rotatedBindings = [Collections.Generic.List[object]]::new()
    $openObligations = [Collections.Generic.List[object]]::new()
    $failureClasses = [Collections.Generic.List[string]]::new()
    foreach ($sourceNodeId in $requiredSourceIds) {
        $nodeMatches = @($plan.nodes | Where-Object {
            [string]$_.id -eq $sourceNodeId
        })
        $activeMatches = @($chain.active_source_bindings | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        $manifestMatches = @($manifestSources | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        })
        if ($nodeMatches.Count -ne 1 -or $activeMatches.Count -ne 1 -or
            $manifestMatches.Count -ne 1) {
            throw "Source-rotation source '$sourceNodeId' is not uniquely bound."
        }
        $node = $nodeMatches[0]
        $active = $activeMatches[0]
        $entry = $manifestMatches[0]
        $roleId = [string]$node.role_id
        $roleMatches = @($plan.roles | Where-Object {
            [string]$_.id -eq $roleId
        })
        if ($roleMatches.Count -ne 1 -or
            [string]$node.kind -ne 'agent' -or
            [string]$node.topology -ne 'background-thread' -or
            [bool]$node.read_only -ne $true -or
            [bool]$node.allow_delegation -ne $false -or
            @($node.write_scope).Count -gt 0) {
            throw "Source-rotation source '$sourceNodeId' changed its role or scope."
        }
        $roleHash = Get-TextSha256 (
            $roleMatches[0] | ConvertTo-Json -Compress -Depth 100
        )
        foreach ($name in @(
            'source_node_id', 'role_id', 'failed_source_kind',
            'failed_thread_id', 'failure_class', 'input_manifest_path',
            'input_manifest_hash', 'replacement_continuity_receipt_path',
            'replacement_continuity_receipt_hash',
            'replacement_roll_forward_receipt_path',
            'replacement_roll_forward_receipt_hash', 'latest_event_sequence',
            'latest_event_hash', 'failure_capture_path',
            'failure_capture_file_hash', 'recovery_receipt_paths',
            'recovery_receipt_hashes'
        )) {
            if ($null -eq $entry.PSObject.Properties[$name]) {
                throw "Source-rotation source '$sourceNodeId' is missing '$name'."
            }
        }
        $failedThreadId = [string]$entry.failed_thread_id
        $failureClass = [string]$entry.failure_class
        if ([string]$entry.role_id -ne $roleId -or
            [string]$entry.failed_source_kind -ne 'replacement' -or
            [string]::IsNullOrWhiteSpace($failedThreadId) -or
            $failedThreadId -eq [string]$active.source_thread_id -or
            $failureClass -notin @(
                'independence-contaminated',
                'replacement-recovery-exhausted'
            )) {
            throw (
                "Source-rotation source '$sourceNodeId' does not identify one " +
                'failed replacement seat.'
            )
        }
        $failureClasses.Add($failureClass)

        $inputPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$entry.input_manifest_path) `
            -Label 'Source-rotation input manifest'
        $inputHash = Get-TextSha256 (
            Get-Content -LiteralPath $inputPath -Raw
        )
        if ($inputHash -ne [string]$entry.input_manifest_hash) {
            throw "Source-rotation input for '$sourceNodeId' changed."
        }
        $continuityPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath (
                [string]$entry.replacement_continuity_receipt_path
            ) -Label 'Source-rotation replacement continuity'
        $continuity = Read-ReplacementContinuityReceipt `
            -Path $continuityPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedReplacementThreadId $failedThreadId
        $rollForwardPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath (
                [string]$entry.replacement_roll_forward_receipt_path
            ) -Label 'Source-rotation replacement roll-forward'
        $rollForward = Read-ReplacementCheckpointRollForwardReceipt `
            -Path $rollForwardPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedReplacementThreadId $failedThreadId
        if ([string]$continuity.receipt_hash -ne
                [string]$entry.replacement_continuity_receipt_hash -or
            [string]$rollForward.receipt_hash -ne
                [string]$entry.replacement_roll_forward_receipt_hash -or
            [string]$rollForward.replacement_continuity_receipt_hash -ne
                [string]$continuity.receipt_hash -or
            [string]$rollForward.target_milestone_id -ne
                [string]$chain.next_milestone_id -or
            [string]$rollForward.checkpoint_hash -ne $checkpointHash -or
            [string]$rollForward.input_manifest_hash -ne $inputHash) {
            throw (
                "Source-rotation source '$sourceNodeId' changed replacement, " +
                'checkpoint, or input continuity.'
            )
        }

        $sourceHistory = @($baseEvents | Where-Object {
            [string]$_.node_id -eq $sourceNodeId
        })
        if ($sourceHistory.Count -lt 1) {
            throw "Source-rotation source '$sourceNodeId' has no lifecycle."
        }
        $latest = $sourceHistory[-1]
        if ([int]$entry.latest_event_sequence -ne [int]$latest.sequence -or
            [string]$entry.latest_event_hash -ne [string]$latest.hash -or
            [string]$latest.thread_id -ne $failedThreadId) {
            throw "Source-rotation source '$sourceNodeId' lifecycle changed."
        }

        if ($failureClass -eq 'independence-contaminated') {
            if ([string]$latest.status -ne 'running' -or
                @($entry.recovery_receipt_paths).Count -ne 0 -or
                @($entry.recovery_receipt_hashes).Count -ne 0) {
                throw (
                    'Independence-contaminated source must remain running and ' +
                    'cannot claim an exhausted recovery chain.'
                )
            }
            $capturePath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
                -RelativePath ([string]$entry.failure_capture_path) `
                -Label 'Independence failure capture'
            $null = Read-ThreadReadCapture -Path $capturePath `
                -ExpectedThreadId $failedThreadId
            if ((Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).
                    Hash.ToLowerInvariant() -ne
                    [string]$entry.failure_capture_file_hash) {
                throw 'Independence failure capture changed.'
            }
        } else {
            if (-not [string]::IsNullOrWhiteSpace(
                    [string]$entry.failure_capture_path
                ) -or -not [string]::IsNullOrWhiteSpace(
                    [string]$entry.failure_capture_file_hash
                ) -or [string]$latest.status -ne 'result_pending' -or
                [string]$latest.error_class -ne
                    'final_missing_with_progress_evidence') {
                throw 'Exhausted replacement source has an invalid terminal state.'
            }
            $recoveryPaths = @($entry.recovery_receipt_paths)
            $recoveryHashes = @($entry.recovery_receipt_hashes)
            if ($recoveryPaths.Count -ne 3 -or $recoveryHashes.Count -ne 3) {
                throw 'Exhausted replacement source requires exactly three recoveries.'
            }
            $cycleId = ''
            for ($index = 0; $index -lt 3; $index++) {
                $recoveryPath = Get-RunLocalReceiptPath `
                    -RunDirectory $runRoot `
                    -RelativePath ([string]$recoveryPaths[$index]) `
                    -Label 'Exhausted replacement recovery receipt'
                $recovery = Read-ThreadResultRecoveryReceipt `
                    -Path $recoveryPath -RunDirectory $runRoot `
                    -ExpectedSourceNodeId $sourceNodeId `
                    -ExpectedOriginalThreadId $failedThreadId `
                    -ExpectedRecoveryStage replacement
                if ([int]$recovery.attempt -ne ($index + 1) -or
                    [string]$recovery.receipt_hash -ne
                        [string]$recoveryHashes[$index] -or
                    [string]$recovery.milestone_id -ne
                        [string]$chain.next_milestone_id -or
                    [string]$recovery.checkpoint_hash -ne $checkpointHash -or
                    [string]$recovery.input_manifest_hash -ne $inputHash -or
                    [string]$recovery.
                        replacement_checkpoint_roll_forward_receipt_hash -ne
                        [string]$rollForward.receipt_hash) {
                    throw 'Exhausted recovery chain changed source or checkpoint.'
                }
                if ($index -eq 0) {
                    $cycleId = [string]$recovery.recovery_cycle_id
                } elseif ([string]$recovery.recovery_cycle_id -ne $cycleId) {
                    throw 'Exhausted recovery chain crossed recovery cycles.'
                }
                if ($index -eq 2 -and
                    [string]$recovery.outcome -ne 'recovery-exhausted') {
                    throw 'The third recovery receipt is not exhausted.'
                }
            }
            $lastRecoveryPath = [string]$recoveryPaths[-1]
            if ([string]$latest.recovery_receipt_path -ne $lastRecoveryPath -or
                [string]$latest.recovery_receipt_hash -ne
                    [string]$recoveryHashes[-1]) {
                throw 'Exhausted recovery tail event does not bind attempt three.'
            }
        }

        $dispositionPath = Join-Path $runRoot (
            [string]$active.disposition_receipt_path
        )
        $disposition = Read-ReviewDispositionReceipt `
            -Path $dispositionPath -RunDirectory $runRoot `
            -ExpectedSourceNodeId $sourceNodeId `
            -ExpectedThreadId ([string]$active.source_thread_id)
        foreach ($decision in @($disposition.decisions)) {
            if ([string]$decision.severity -eq 'P0' -and
                [string]$decision.resolution_status -ne 'resolved') {
                throw 'Source rotation does not permit an unresolved P0 baseline.'
            }
            if ([string]$decision.severity -eq 'P1' -and
                [string]$decision.resolution_status -ne 'resolved') {
                $openObligations.Add([ordered]@{
                    source_node_id = $sourceNodeId
                    role_id = $roleId
                    source_thread_id = [string]$active.source_thread_id
                    source_finding_id = [string]$decision.source_finding_id
                    canonical_finding_id =
                        [string]$decision.canonical_finding_id
                    severity = 'P1'
                    finding = [string]$decision.finding
                    finding_hash = [string]$decision.finding_hash
                    resolution_status = [string]$decision.resolution_status
                })
            }
        }
        $formalBindings.Add([ordered]@{
            source_node_id = $sourceNodeId
            role_id = $roleId
            role_contract_hash = $roleHash
            source_thread_id = [string]$active.source_thread_id
            milestone_id = [string]$chain.active_milestone_id
            checkpoint_material_path =
                [string]$active.checkpoint_material_path
            checkpoint_material_hash =
                [string]$active.checkpoint_material_hash
            result_receipt_path = [string]$active.result_receipt_path
            result_receipt_hash = [string]$active.result_receipt_hash
            disposition_receipt_path =
                [string]$active.disposition_receipt_path
            disposition_receipt_hash =
                [string]$active.disposition_receipt_hash
        })
        $rotatedBindings.Add([ordered]@{
            source_node_id = $sourceNodeId
            role_id = $roleId
            role_contract_hash = $roleHash
            failed_source_kind = 'replacement'
            failed_thread_id = $failedThreadId
            failure_class = $failureClass
            input_manifest_path = [string]$entry.input_manifest_path
            input_manifest_hash = $inputHash
            replacement_continuity_receipt_path =
                [string]$entry.replacement_continuity_receipt_path
            replacement_continuity_receipt_hash =
                [string]$continuity.receipt_hash
            replacement_roll_forward_receipt_path =
                [string]$entry.replacement_roll_forward_receipt_path
            replacement_roll_forward_receipt_hash =
                [string]$rollForward.receipt_hash
            latest_event_sequence = [int]$latest.sequence
            latest_event_hash = [string]$latest.hash
        })
    }
    if (@($failureClasses | Where-Object {
            $_ -eq 'independence-contaminated'
        }).Count -ne 1 -or
        @($failureClasses | Where-Object {
            $_ -eq 'replacement-recovery-exhausted'
        }).Count -ne 1) {
        throw (
            'Source rotation requires one independence failure and one exhausted ' +
            'replacement.'
        )
    }
    if ($openObligations.Count -lt 1) {
        throw 'Source rotation requires at least one open P1 occurrence.'
    }
    $policy = Resolve-OrchestrationRunPolicy -RunDirectory $runRoot `
        -Events $baseEvents
    return [pscustomobject]@{
        run_root = $runRoot
        plan = $plan
        plan_raw = $planRaw
        plan_hash = [string]$run.plan_hash
        run = $run
        run_raw = $runRaw
        run_file_hash = (
            Get-FileHash -LiteralPath $runPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        events = @($events)
        base_events = @($baseEvents)
        genesis_hash = [string]$baseEvents[0].hash
        journal_head = [string]$baseEvents[-1].hash
        journal_event_count = $baseEvents.Count
        effective_policy_version = [string]$policy.effective_policy_version
        active_milestone_id = [string]$chain.active_milestone_id
        active_milestone_receipt_path =
            [string]$chain.activation_receipt_path
        active_milestone_receipt_hash =
            [string]$chain.activation_receipt_hash
        active_checkpoint_material_path =
            [string]$formalBindings[0].checkpoint_material_path
        active_checkpoint_material_hash =
            [string]$formalBindings[0].checkpoint_material_hash
        rotation_target_milestone_id = [string]$chain.next_milestone_id
        rotation_checkpoint_material_path =
            [string]$manifest.checkpoint_material_path
        rotation_checkpoint_material_hash = $checkpointHash
        rotation_manifest_path = [IO.Path]::GetRelativePath(
            $runRoot, $manifestFullPath
        ).Replace('\', '/')
        rotation_manifest_file_hash = (
            Get-FileHash -LiteralPath $manifestFullPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        formal_source_bindings = @($formalBindings)
        formal_source_bindings_hash = Get-TextSha256 (
            @($formalBindings) | ConvertTo-Json -Compress -Depth 100
        )
        rotated_source_bindings = @($rotatedBindings)
        rotated_source_bindings_hash = Get-TextSha256 (
            @($rotatedBindings) | ConvertTo-Json -Compress -Depth 100
        )
        open_obligations = @($openObligations)
        open_obligations_hash = Get-TextSha256 (
            @($openObligations) | ConvertTo-Json -Compress -Depth 100
        )
    }
}

function Read-DurableReviewSourceRotationExportReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PredecessorRunDirectory,
        [Parameter(Mandatory)][string] $SuccessorPlanPath,
        [string] $ExpectedSuccessorRunDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source-rotation export receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $keys = @(
        'schema_version', 'lineage_kind', 'predecessor_run_path',
        'predecessor_run_id', 'predecessor_plan_hash',
        'predecessor_run_file_hash', 'predecessor_genesis_hash',
        'predecessor_journal_head', 'predecessor_journal_event_count',
        'effective_policy_version', 'active_milestone_id',
        'active_milestone_receipt_path', 'active_milestone_receipt_hash',
        'active_checkpoint_material_path', 'active_checkpoint_material_hash',
        'rotation_target_milestone_id', 'rotation_checkpoint_material_path',
        'rotation_checkpoint_material_hash', 'rotation_manifest_path',
        'rotation_manifest_file_hash', 'formal_source_bindings',
        'formal_source_bindings_hash', 'rotated_source_bindings',
        'rotated_source_bindings_hash', 'open_obligations',
        'open_obligations_hash', 'successor_run_id', 'successor_plan_hash',
        'successor_run_path', 'successor_milestone_ids',
        'authorization_material_path', 'authorization_material_hash',
        'activation_key', 'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Source-rotation export receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.lineage_kind -ne 'source-rotation' -or
        [string]$receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Source-rotation export receipt hash or schema is invalid.'
    }
    $runRoot = [IO.Path]::GetFullPath(
        $PredecessorRunDirectory
    ).TrimEnd('\', '/')
    $manifestPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.rotation_manifest_path) `
        -Label 'Source-rotation manifest'
    $snapshot = Get-DurableReviewSourceRotationSnapshot `
        -RunDirectory $runRoot -RotationManifestPath $manifestPath
    $events = @($snapshot.events)
    if ($events.Count -ne ([int]$receipt.predecessor_journal_event_count + 1) -or
        [string]$events[-2].hash -ne [string]$receipt.predecessor_journal_head) {
        throw 'Predecessor journal changed outside the source-rotation export.'
    }
    $event = $events[-1]
    if ([string]$event.event -ne 'durable-review-source-rotation-exported' -or
        [string]$event.result_receipt_hash -ne [string]$receipt.receipt_hash -or
        [string]$event.prev_hash -ne [string]$receipt.predecessor_journal_head) {
        throw 'Source-rotation export event does not bind the receipt.'
    }
    $successorPlanRaw = Get-Content -LiteralPath $SuccessorPlanPath -Raw
    $successorPlan = $successorPlanRaw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $comparisons = @(
        @([string]$receipt.predecessor_run_path, [string]$snapshot.run_root),
        @([string]$receipt.predecessor_run_id, [string]$snapshot.run.run_id),
        @([string]$receipt.predecessor_plan_hash, [string]$snapshot.plan_hash),
        @([string]$receipt.predecessor_run_file_hash,
            [string]$snapshot.run_file_hash),
        @([string]$receipt.predecessor_genesis_hash,
            [string]$snapshot.genesis_hash),
        @([string]$receipt.effective_policy_version,
            [string]$snapshot.effective_policy_version),
        @([string]$receipt.active_milestone_id,
            [string]$snapshot.active_milestone_id),
        @([string]$receipt.active_milestone_receipt_hash,
            [string]$snapshot.active_milestone_receipt_hash),
        @([string]$receipt.active_checkpoint_material_hash,
            [string]$snapshot.active_checkpoint_material_hash),
        @([string]$receipt.rotation_target_milestone_id,
            [string]$snapshot.rotation_target_milestone_id),
        @([string]$receipt.rotation_checkpoint_material_hash,
            [string]$snapshot.rotation_checkpoint_material_hash),
        @([string]$receipt.rotation_manifest_file_hash,
            [string]$snapshot.rotation_manifest_file_hash),
        @([string]$receipt.formal_source_bindings_hash,
            [string]$snapshot.formal_source_bindings_hash),
        @([string]$receipt.rotated_source_bindings_hash,
            [string]$snapshot.rotated_source_bindings_hash),
        @([string]$receipt.open_obligations_hash,
            [string]$snapshot.open_obligations_hash),
        @([string]$receipt.successor_run_id, [string]$successorPlan.run_id),
        @([string]$receipt.successor_plan_hash,
            (Get-TextSha256 $successorPlanRaw))
    )
    if (@($comparisons | Where-Object { $_[0] -ne $_[1] }).Count -gt 0) {
        throw 'Source-rotation export no longer matches its bound runs.'
    }
    foreach ($pair in @(
        @($receipt.formal_source_bindings, $snapshot.formal_source_bindings),
        @($receipt.rotated_source_bindings, $snapshot.rotated_source_bindings),
        @($receipt.open_obligations, $snapshot.open_obligations)
    )) {
        if ((@($pair[0]) | ConvertTo-Json -Compress -Depth 100) -ne
            (@($pair[1]) | ConvertTo-Json -Compress -Depth 100)) {
            throw 'Source-rotation export changed identities or open findings.'
        }
    }
    $profile = $successorPlan.successor_review_profile
    $sourceIds = @($snapshot.rotated_source_bindings |
        ForEach-Object { [string]$_.source_node_id })
    $expectedMilestones = @(
        $snapshot.plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    $targetIndex = [Array]::IndexOf(
        $expectedMilestones, [string]$snapshot.rotation_target_milestone_id
    )
    $expectedMilestones = @(
        $expectedMilestones[$targetIndex..($expectedMilestones.Count - 1)]
    )
    if ([string]$profile.lineage_kind -ne 'source-rotation' -or
        [string]$profile.predecessor_run_id -ne
            [string]$snapshot.run.run_id -or
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
            ($expectedMilestones -join "`n") -or
        (@($receipt.successor_milestone_ids) -join "`n") -ne
            ($expectedMilestones -join "`n")) {
        throw 'Source-rotation successor plan changed the bound lineage.'
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
            throw 'Source-rotation successor changed role or fresh-session scope.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSuccessorRunDirectory) -and
        [string]$receipt.successor_run_path -ne [IO.Path]::GetFullPath(
            $ExpectedSuccessorRunDirectory
        ).TrimEnd('\', '/')) {
        throw 'Source-rotation export cannot be replayed into another run.'
    }
    $authorizationPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$receipt.authorization_material_path) `
        -Label 'Source-rotation authorization material'
    if ((Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).
            Hash.ToLowerInvariant() -ne
            [string]$receipt.authorization_material_hash) {
        throw 'Source-rotation authorization material changed.'
    }
    return $receipt
}

function Read-DurableReviewSourceRotationAdoptionReceipt {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][object] $Receipt
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    $keys = @(
        'schema_version', 'lineage_kind', 'run_path', 'run_id', 'plan_hash',
        'genesis_hash', 'predecessor_run_path', 'predecessor_run_id',
        'predecessor_final_journal_head',
        'predecessor_final_journal_event_count', 'export_receipt_path',
        'export_receipt_hash', 'export_receipt_file_hash',
        'predecessor_active_milestone_id', 'rotation_target_milestone_id',
        'rotation_checkpoint_material_path',
        'rotation_checkpoint_material_hash', 'source_bindings',
        'source_bindings_hash', 'inherited_obligations',
        'inherited_obligations_hash', 'successor_milestone_ids',
        'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $Receipt.PSObject.Properties[$name]) {
            throw "Source-rotation adoption is missing '$name'."
        }
        $payload[$name] = $Receipt.$name
    }
    if ([string]$Receipt.schema_version -ne '1.2' -or
        [string]$Receipt.lineage_kind -ne 'source-rotation-successor' -or
        [string]$Receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Source-rotation adoption receipt hash or schema is invalid.'
    }
    if ($events.Count -lt 2 -or
        [string]$events[1].event -ne
            'durable-review-source-rotation-adopted' -or
        [string]$events[1].prev_hash -ne [string]$events[0].hash -or
        [string]$events[1].result_receipt_hash -ne
            [string]$Receipt.receipt_hash -or
        [string]$Receipt.run_path -ne $runRoot -or
        [string]$Receipt.run_id -ne [string]$run.run_id -or
        [string]$Receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$Receipt.plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$Receipt.genesis_hash -ne [string]$events[0].hash) {
        throw 'Source-rotation adoption run identity changed.'
    }
    $predecessorRoot = [IO.Path]::GetFullPath(
        [string]$Receipt.predecessor_run_path
    ).TrimEnd('\', '/')
    $exportPath = Get-RunLocalReceiptPath -RunDirectory $predecessorRoot `
        -RelativePath ([string]$Receipt.export_receipt_path) `
        -Label 'Source-rotation export receipt'
    $export = Read-DurableReviewSourceRotationExportReceipt `
        -Path $exportPath -PredecessorRunDirectory $predecessorRoot `
        -SuccessorPlanPath $planPath `
        -ExpectedSuccessorRunDirectory $runRoot
    $predecessorEvents = @(Read-OrchestrationJournal (
        Join-Path $predecessorRoot 'events.jsonl'
    ))
    if ([string]$Receipt.predecessor_final_journal_head -ne
            [string]$predecessorEvents[-1].hash -or
        [int]$Receipt.predecessor_final_journal_event_count -ne
            $predecessorEvents.Count -or
        [string]$Receipt.export_receipt_hash -ne
            [string]$export.receipt_hash -or
        [string]$Receipt.export_receipt_file_hash -ne (
            Get-FileHash -LiteralPath $exportPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Source-rotation adoption predecessor chain changed.'
    }
    $expectedBindings = @($export.rotated_source_bindings |
        ForEach-Object {
            [ordered]@{
                source_node_id = [string]$_.source_node_id
                role_id = [string]$_.role_id
                role_contract_hash = [string]$_.role_contract_hash
                failed_source_kind = [string]$_.failed_source_kind
                failed_thread_id = [string]$_.failed_thread_id
                failure_class = [string]$_.failure_class
                input_manifest_path = [string]$_.input_manifest_path
                input_manifest_hash = [string]$_.input_manifest_hash
                replacement_continuity_receipt_path =
                    [string]$_.replacement_continuity_receipt_path
                replacement_continuity_receipt_hash =
                    [string]$_.replacement_continuity_receipt_hash
                replacement_roll_forward_receipt_path =
                    [string]$_.replacement_roll_forward_receipt_path
                replacement_roll_forward_receipt_hash =
                    [string]$_.replacement_roll_forward_receipt_hash
                latest_event_sequence = [int]$_.latest_event_sequence
                latest_event_hash = [string]$_.latest_event_hash
                fresh_session_policy = 'fresh'
            }
        })
    if ((@($Receipt.source_bindings) |
            ConvertTo-Json -Compress -Depth 100) -ne
        (@($expectedBindings) | ConvertTo-Json -Compress -Depth 100) -or
        [string]$Receipt.source_bindings_hash -ne (Get-TextSha256 (
            @($expectedBindings) | ConvertTo-Json -Compress -Depth 100
        )) -or
        (@($Receipt.inherited_obligations) |
            ConvertTo-Json -Compress -Depth 100) -ne
        (@($export.open_obligations) |
            ConvertTo-Json -Compress -Depth 100) -or
        [string]$Receipt.inherited_obligations_hash -ne
            [string]$export.open_obligations_hash) {
        throw 'Source-rotation adoption changed source identities or findings.'
    }
    $declaredMilestones = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    if ([string]$Receipt.predecessor_run_id -ne
            [string]$export.predecessor_run_id -or
        [string]$Receipt.predecessor_active_milestone_id -ne
            [string]$export.active_milestone_id -or
        [string]$Receipt.rotation_target_milestone_id -ne
            [string]$export.rotation_target_milestone_id -or
        [string]$Receipt.rotation_checkpoint_material_path -ne
            [string]$export.rotation_checkpoint_material_path -or
        [string]$Receipt.rotation_checkpoint_material_hash -ne
            [string]$export.rotation_checkpoint_material_hash -or
        (@($Receipt.successor_milestone_ids) -join "`n") -ne
            ($declaredMilestones -join "`n")) {
        throw 'Source-rotation adoption lineage declaration changed.'
    }
    foreach ($binding in @($Receipt.source_bindings)) {
        $node = @($plan.nodes | Where-Object {
            [string]$_.id -eq [string]$binding.source_node_id
        })
        $role = @($plan.roles | Where-Object {
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
            throw 'Fresh source-rotation successor changed its reviewer contract.'
        }
    }
    return $Receipt
}

function Read-DurableReviewSuccessorAdoptionReceipt {
    param([Parameter(Mandatory)][string] $RunDirectory)

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $planPath = Join-Path $runRoot 'plan.json'
    $runPath = Join-Path $runRoot 'run.json'
    $eventsPath = Join-Path $runRoot 'events.jsonl'
    $receiptPath = Join-Path $runRoot (
        'receipts/durable-review-successor.adoption.json'
    )
    foreach ($path in @($planPath, $runPath, $eventsPath, $receiptPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Successor run lacks its immutable adoption chain.'
        }
    }
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($null -eq $plan.PSObject.Properties['successor_review_profile']) {
        throw 'Successor adoption requires successor_review_profile.'
    }
    $run = Get-Content -LiteralPath $runPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $events = @(Read-OrchestrationJournal $eventsPath)
    if ($events.Count -lt 2) {
        throw 'Successor adoption event is missing.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$receipt.schema_version -eq '1.1' -and
        [string]$receipt.lineage_kind -eq 'abandoned-successor') {
        return Read-AbandonedSuccessorAdoptionReceipt `
            -RunDirectory $runRoot -Receipt $receipt
    }
    if ([string]$receipt.schema_version -eq '1.2' -and
        [string]$receipt.lineage_kind -eq 'source-rotation-successor') {
        return Read-DurableReviewSourceRotationAdoptionReceipt `
            -RunDirectory $runRoot -Receipt $receipt
    }
    $keys = @(
        'schema_version', 'run_path', 'run_id', 'plan_hash', 'genesis_hash',
        'predecessor_run_path', 'predecessor_run_id',
        'predecessor_final_journal_head',
        'predecessor_final_journal_event_count', 'export_receipt_path',
        'export_receipt_hash', 'export_receipt_file_hash',
        'predecessor_active_milestone_id', 'checkpoint_material_hash',
        'source_bindings', 'source_bindings_hash', 'inherited_obligations',
        'inherited_obligations_hash', 'successor_milestone_ids',
        'created_at_utc'
    )
    $payload = [ordered]@{}
    foreach ($name in $keys) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Successor adoption receipt is missing '$name'."
        }
        $payload[$name] = $receipt.$name
    }
    if ([string]$receipt.schema_version -ne '1.0' -or
        [string]$receipt.receipt_hash -ne (Get-TextSha256 (
            $payload | ConvertTo-Json -Compress -Depth 100
        ))) {
        throw 'Successor adoption receipt hash or schema is invalid.'
    }
    $adoptionEvent = $events[1]
    if ([string]$adoptionEvent.event -ne 'durable-review-successor-adopted' -or
        [string]$adoptionEvent.prev_hash -ne [string]$events[0].hash -or
        [string]$adoptionEvent.result_receipt_hash -ne
            [string]$receipt.receipt_hash) {
        throw 'Successor adoption event does not bind the receipt.'
    }
    if ([string]$receipt.run_path -ne $runRoot -or
        [string]$receipt.run_id -ne [string]$run.run_id -or
        [string]$receipt.plan_hash -ne [string]$run.plan_hash -or
        [string]$receipt.plan_hash -ne (Get-TextSha256 $planRaw) -or
        [string]$receipt.genesis_hash -ne [string]$events[0].hash) {
        throw 'Successor adoption run identity changed.'
    }
    $predecessorRoot = [IO.Path]::GetFullPath(
        [string]$receipt.predecessor_run_path
    ).TrimEnd('\', '/')
    $exportPath = Join-Path $predecessorRoot (
        [string]$receipt.export_receipt_path
    )
    $export = Read-DurableReviewSuccessorExportReceipt -Path $exportPath `
        -PredecessorRunDirectory $predecessorRoot `
        -SuccessorPlanPath $planPath `
        -ExpectedSuccessorRunDirectory $runRoot
    $predecessorEvents = @(Read-OrchestrationJournal (
        Join-Path $predecessorRoot 'events.jsonl'
    ))
    if ([string]$receipt.predecessor_final_journal_head -ne
            [string]$predecessorEvents[-1].hash -or
        [int]$receipt.predecessor_final_journal_event_count -ne
            $predecessorEvents.Count -or
        [string]$receipt.export_receipt_hash -ne
            [string]$export.receipt_hash -or
        [string]$receipt.export_receipt_file_hash -ne (
            Get-FileHash -LiteralPath $exportPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw 'Successor adoption predecessor chain changed.'
    }
    if ((@($receipt.source_bindings) | ConvertTo-Json -Compress -Depth 100) -ne
        (@($export.source_bindings) | ConvertTo-Json -Compress -Depth 100) -or
        (@($receipt.inherited_obligations) |
            ConvertTo-Json -Compress -Depth 100) -ne
        (@($export.open_obligations) |
            ConvertTo-Json -Compress -Depth 100)) {
        throw 'Successor adoption changed inherited identities or P1 obligations.'
    }
    $declaredMilestones = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    if ([string]$receipt.predecessor_run_id -ne
            [string]$export.predecessor_run_id -or
        [string]$receipt.predecessor_active_milestone_id -ne
            [string]$export.active_milestone_id -or
        [string]$receipt.checkpoint_material_hash -ne
            [string]$export.checkpoint_material_hash -or
        [string]$receipt.source_bindings_hash -ne
            [string]$export.source_bindings_hash -or
        [string]$receipt.inherited_obligations_hash -ne
            [string]$export.open_obligations_hash -or
        (@($receipt.successor_milestone_ids) -join "`n") -ne
            ($declaredMilestones -join "`n")) {
        throw 'Successor adoption lineage declaration changed.'
    }
    foreach ($binding in @($receipt.source_bindings)) {
        $nodeMatches = @($plan.nodes | Where-Object {
            [string]$_.id -eq [string]$binding.source_node_id
        })
        if ($nodeMatches.Count -ne 1 -or
            [string]$nodeMatches[0].role_id -ne [string]$binding.role_id -or
            [string]$nodeMatches[0].context.session_policy -ne 'reuse' -or
            [string]$nodeMatches[0].context.prior_thread_id -ne
                [string]$binding.source_thread_id -or
            [bool]$nodeMatches[0].read_only -ne $true -or
            [bool]$nodeMatches[0].allow_delegation -ne $false) {
            throw 'Successor plan does not preserve durable source continuity.'
        }
        $roleMatches = @($plan.roles | Where-Object {
            [string]$_.id -eq [string]$binding.role_id
        })
        if ($roleMatches.Count -ne 1 -or
            (Get-TextSha256 (
                $roleMatches[0] | ConvertTo-Json -Compress -Depth 100
            )) -ne [string]$binding.role_contract_hash) {
            throw 'Successor plan changed a durable role contract.'
        }
    }
    return $receipt
}
