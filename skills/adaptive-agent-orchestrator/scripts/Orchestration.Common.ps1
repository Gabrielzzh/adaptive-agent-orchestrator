Set-StrictMode -Version Latest
$script:OrchestrationCurrentPolicyVersion = '0.7.6'
$script:OrchestrationMigratablePolicyVersions = @(
    '0.7.2', '0.7.3', '0.7.4', '0.7.5'
)

function Get-TextSha256 {
    param([Parameter(Mandatory)][string] $Text)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text)
        )
    ).ToLowerInvariant()
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
    if ($schemaVersion -notin @('1.1', '1.2', '1.3')) {
        throw 'Thread result receipt has an unsupported schema version.'
    }
    $hasSourceContract = $null -ne
        $receipt.PSObject.Properties['source_node_id']
    if ($schemaVersion -eq '1.3') {
        foreach ($name in @(
            'source_node_id', 'source_kind',
            'replacement_continuity_receipt_path',
            'replacement_continuity_receipt_hash'
        )) {
            if ($null -eq $receipt.PSObject.Properties[$name]) {
                throw \"Schema 1.3 thread result receipt is missing '$name'.\"
            }
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
        }
    } elseif ($hasSourceContract -and
        [string]$receipt.source_node_id -ne $ExpectedSourceNodeId) {
        throw 'Historical thread result receipt changed its logical source.'
    }
    $hasPending = $null -ne $receipt.PSObject.Properties['pending_findings']
    if ($schemaVersion -in @('1.2', '1.3') -and -not $hasPending) {
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
    if ($schemaVersion -eq '1.3') {
        if (@($receipt.adopted_findings).Count -gt 0 -or
            @($receipt.rejected_findings).Count -gt 0) {
            throw 'Schema 1.3 source findings must remain pending until disposition.'
        }
        $seenFindingIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($finding in $pending) {
            foreach ($name in @(
                'finding_id', 'severity', 'text', 'text_hash'
            )) {
                if ($null -eq $finding.PSObject.Properties[$name]) {
                    throw "Schema 1.3 finding is missing '$name'."
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
    $payload = [ordered]@{
        schema_version = [string]$receipt.schema_version
    }
    if ($hasSourceContract) {
        $payload.source_node_id = [string]$receipt.source_node_id
        $payload.source_kind = [string]$receipt.source_kind
    }
    $payload.thread_id = [string]$receipt.thread_id
    $payload.host_id = [string]$receipt.host_id
    $payload.collection_method = [string]$receipt.collection_method
    $payload.thread_read_path = [string]$receipt.thread_read_path
    $payload.thread_read_hash = [string]$receipt.thread_read_hash
    $payload.final_turn_id = [string]$receipt.final_turn_id
    $payload.final_status = [string]$receipt.final_status
    $payload.final_content_hash = [string]$receipt.final_content_hash
    if ($hasSourceContract) {
        $payload.replacement_continuity_receipt_path = [string](
            $receipt.replacement_continuity_receipt_path
        )
        $payload.replacement_continuity_receipt_hash = [string](
            $receipt.replacement_continuity_receipt_hash
        )
        if ($null -ne $receipt.PSObject.Properties['milestone_id']) {
            $payload.milestone_id = [string]$receipt.milestone_id
            $payload.checkpoint_material_path = [string](
                $receipt.checkpoint_material_path
            )
            $payload.checkpoint_material_hash = [string](
                $receipt.checkpoint_material_hash
            )
        }
    }
    $payload.adopted_findings = @($receipt.adopted_findings)
    $payload.rejected_findings = @($receipt.rejected_findings)
    if ($hasPending) {
        $payload.pending_findings = $pending
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
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

function Read-ThreadResultRecoveryReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $ExpectedSourceNodeId,
        [Parameter(Mandatory)][string] $ExpectedOriginalThreadId,
        [ValidateSet('original', 'replacement')]
        [string] $ExpectedRecoveryStage
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread result recovery receipt does not exist: $Path"
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
    $recoveryStage = if ([string]$receipt.schema_version -eq '1.1') {
        'replacement'
    } elseif ([string]$receipt.schema_version -eq '1.0') {
        'original'
    } else {
        throw 'Thread result recovery receipt has an unsupported schema.'
    }
    if ($recoveryStage -eq 'replacement') {
        $required += @(
            'recovery_stage', 'replacement_continuity_receipt_path',
            'replacement_continuity_receipt_hash'
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
            [string]$receipt.replacement_continuity_receipt_hash -or
            [string]$replacement.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$replacement.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Replacement recovery changed its continuity receipt.'
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
            -ExpectedRecoveryStage $recoveryStage
        if ([int]$previous.attempt -ne ($attempt - 1) -or
            [string]$previous.receipt_hash -ne
                [string]$receipt.previous_receipt_hash -or
            [string]$previous.checkpoint_hash -ne
                [string]$receipt.checkpoint_hash -or
            [string]$previous.input_manifest_hash -ne
                [string]$receipt.input_manifest_hash) {
            throw 'Thread result recovery receipt chain is invalid.'
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
            -ExpectedOriginalThreadId ([string]$receipt.original_thread_id)
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
    if ([string]$source.schema_version -ne '1.3') {
        throw (
            'Durable review completion requires a schema 1.3 source receipt ' +
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
    $seenCanonical = [Collections.Generic.HashSet[string]]::new(
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
            '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
            -not $seenCanonical.Add($canonicalFindingId)) {
            throw (
                'Review disposition requires a unique stable ' +
                'canonical_finding_id within each source receipt.'
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

    $dispositionPath = Get-RunLocalReceiptPath `
        -RunDirectory $RunDirectory -RelativePath $DispositionRelativePath `
        -Label 'Review disposition receipt'
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
    $result = Read-ThreadResultReceipt -Path $resultPath `
        -ExpectedThreadId $sourceThreadId `
        -ExpectedSourceNodeId $SourceNodeId -RunDirectory $RunDirectory

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

    return [pscustomobject][ordered]@{
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
}

function Read-DurableReviewMilestoneActivationChain {
    param(
        [Parameter(Mandatory)][string] $RunDirectory
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
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
        if ([string]$receipt.schema_version -eq '1.1') {
            $required += @(
                'acceptance_authorization_material_path',
                'acceptance_authorization_material_hash', 'main_node_id',
                'acceptance_key', 'acceptance_evidence_material_path',
                'acceptance_evidence_material_hash'
            )
        }
        foreach ($name in $required) {
            if ($null -eq $receipt.PSObject.Properties[$name]) {
                throw "Milestone activation receipt is missing '$name'."
            }
        }
        if ([string]$receipt.schema_version -notin @('1.0', '1.1') -or
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
        if ([string]$receipt.schema_version -eq '1.1') {
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
    return [pscustomobject]@{
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
        [string]$chain.activation_receipt.schema_version -ne '1.1' -or
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
        [string]$_.event -eq 'milestone-activated' -and
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
