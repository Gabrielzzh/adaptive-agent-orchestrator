[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aao-durable-milestone-' + [guid]::NewGuid().ToString('N')
)
$script:assertions = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertions++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Action,
        [string] $Expected,
        [string] $Message
    )
    $caught = $false
    $actual = ''
    try { & $Action } catch {
        $actual = $_.Exception.Message
        $caught = $_.Exception.Message -like "*$Expected*"
    }
    Assert-True $caught ($Message + $(if ($caught) { '' } else {
        " Actual: $actual"
    }))
}

function New-ReviewPlan {
    param(
        [string] $Path,
        [string[]] $MilestoneIds = @('method-1', 'method-2')
    )
    $plan = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/example-plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $plan.run_id = 'durable-milestone-self-test'
    $plan.goal = 'Exercise two durable review milestones without editing the plan.'
    $plan.roles[1].lifetime = 'project'
    $domainRole = @{}
    foreach ($entry in $plan.roles[1].GetEnumerator()) {
        $domainRole[$entry.Key] = $entry.Value
    }
    $domainRole.id = 'domain-role'
    $domainRole.display_name = 'Domain Role'
    $domainRole.mission = 'Maintain reusable domain checks across milestones.'
    $domainRole.identity_statement = 'I return read-only domain findings.'
    $plan.roles += $domainRole

    $review = $plan.nodes[1]
    $review.wave = 1
    $review.topology = 'background-thread'
    $review.workflow = 'parallel'
    $review.depends_on = @()
    $review.context.continuity_key = 'durable-dissent'
    $review.context.inputs = @('source:dissent-input')
    $domain = @{}
    foreach ($entry in $review.GetEnumerator()) {
        $domain[$entry.Key] = $entry.Value
    }
    $domain.id = 'domain'
    $domain.role_id = 'domain-role'
    $domain.purpose = 'research'
    $domain.task = 'Return source-specific domain findings.'
    $domain.context = @{}
    foreach ($entry in $review.context.GetEnumerator()) {
        $domain.context[$entry.Key] = $entry.Value
    }
    $domain.context.continuity_key = 'durable-domain'
    $domain.context.inputs = @('source:domain-input')
    $main = $plan.nodes[2]
    $main.depends_on = @('review', 'domain')
    $plan.nodes = @($review, $domain, $main)
    $plan.completion.required_nodes = @('review', 'domain', 'integrate')
    $plan.completion.evidence_checks = @(
        @{ node_id = 'review'; minimum_entries = 1 },
        @{ node_id = 'domain'; minimum_entries = 1 },
        @{ node_id = 'integrate'; minimum_entries = 1 }
    )
    $plan.completion.review_disposition_checks = @(
        @{
            source_node_id = 'review'
            path = 'receipts/review.disposition.json'
            blocking_severities = @('P0', 'P1')
        },
        @{
            source_node_id = 'domain'
            path = 'receipts/domain.disposition.json'
            blocking_severities = @('P0', 'P1')
        }
    )
    $plan.durable_review_profile = @{
        mode = 'domain-dissent'
        main_owner_node_id = 'integrate'
        domain_node_ids = @('domain')
        dissent_node_ids = @('review')
        milestone_ids = @($MilestoneIds)
        consumer_output = 'result-only'
    }
    $plan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $Path -Encoding utf8
}

function New-ThreadCapture {
    param([string] $Path, [string] $ThreadId, [string] $Text)
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ threadId = $ThreadId }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = "$ThreadId-final"
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = $Text
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $Path -Encoding utf8
}

function New-ProgressCapture {
    param([string] $Path, [string] $ThreadId, [string] $TurnId)
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = $ThreadId }
        page = [ordered]@{ order = 'newest_first' }
        latestAssistantMessageId = $null
        turns = @(
            [ordered]@{
                id = $TurnId
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'commentary'
                        text = "Progress for $TurnId without a final answer."
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $Path -Encoding utf8
}

function New-SourceChain {
    param(
        [string] $Run,
        [string] $SourceNodeId,
        [string] $ThreadId,
        [string] $MilestoneId,
        [string] $CheckpointPath,
        [string] $Stem,
        [string] $Severity,
        [string] $FindingText,
        [string] $Resolution,
        [string] $FindingId = '',
        [string] $CanonicalFindingId = '',
        [string] $AdditionalFindingId = '',
        [string] $AdditionalFindingText = '',
        [string] $AdditionalSeverity = '',
        [string] $AdditionalCanonicalFindingId = '',
        [string] $ReplacementContinuityReceiptPath = '',
        [string] $MilestoneRevisionAuthorizationReceiptPath = ''
    )
    $capturePath = Join-Path $Run "thread-reads/$Stem.json"
    New-ThreadCapture -Path $capturePath -ThreadId $ThreadId `
        -Text "Report for $SourceNodeId at $MilestoneId."
    if ([string]::IsNullOrWhiteSpace($FindingId)) {
        $FindingId = "$SourceNodeId-$MilestoneId-finding"
    }
    if ([string]::IsNullOrWhiteSpace($CanonicalFindingId)) {
        $CanonicalFindingId = "canonical-$FindingId"
    }
    $findingPath = Join-Path $Run "materials/$Stem-findings.json"
    $findingRecords = [Collections.Generic.List[object]]::new()
    $findingRecords.Add(
        [ordered]@{
            finding_id = $FindingId
            severity = $Severity
            text = $FindingText
        }
    )
    if (-not [string]::IsNullOrWhiteSpace($AdditionalFindingId)) {
        $findingRecords.Add([ordered]@{
            finding_id = $AdditionalFindingId
            severity = $AdditionalSeverity
            text = $AdditionalFindingText
        })
    }
    @($findingRecords) | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $findingPath -Encoding utf8
    $resultPath = Join-Path $Run (
        "receipts/$Stem.thread-result-receipt.json"
    )
    $resultArguments = @{
        RunDirectory = $Run
        SourceNodeId = $SourceNodeId
        ThreadId = $ThreadId
        HostId = 'local'
        ThreadReadPath = $capturePath
        OutputPath = $resultPath
        MilestoneId = $MilestoneId
        CheckpointMaterialPath = $CheckpointPath
        PendingFindingRecordsPath = $findingPath
    }
    if (-not [string]::IsNullOrWhiteSpace(
        $ReplacementContinuityReceiptPath
    )) {
        $resultArguments.ReplacementContinuityReceiptPath =
            $ReplacementContinuityReceiptPath
    }
    if (-not [string]::IsNullOrWhiteSpace(
        $MilestoneRevisionAuthorizationReceiptPath
    )) {
        $resultArguments.MilestoneRevisionAuthorizationReceiptPath =
            $MilestoneRevisionAuthorizationReceiptPath
    }
    $result = & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
        @resultArguments |
        ConvertFrom-Json -Depth 50
    $decisionPath = Join-Path $Run "materials/$Stem-decisions.json"
    $reReviewStatus = if ($Resolution -eq 'resolved') {
        'completed'
    } else { 'requested' }
    $decisionRecords = [Collections.Generic.List[object]]::new()
    $decisionRecords.Add(
        [ordered]@{
            source_finding_id = $FindingId
            finding = $FindingText
            finding_hash = Get-TextSha256 $FindingText
            canonical_finding_id = $CanonicalFindingId
            severity = $Severity
            disposition = 'adopted'
            rationale = 'Self-test decision.'
            resolution_status = $Resolution
            evidence = @("test:$Stem")
            re_review_status = $reReviewStatus
            re_review_source_node_id = $SourceNodeId
            re_review_evidence = if ($Resolution -eq 'resolved') {
                @("test:$Stem-rereview")
            } else { @() }
        }
    )
    if (-not [string]::IsNullOrWhiteSpace($AdditionalFindingId)) {
        $decisionRecords.Add([ordered]@{
            source_finding_id = $AdditionalFindingId
            finding = $AdditionalFindingText
            finding_hash = Get-TextSha256 $AdditionalFindingText
            canonical_finding_id = $AdditionalCanonicalFindingId
            severity = $AdditionalSeverity
            disposition = 'adopted'
            rationale = 'Self-test second source occurrence.'
            resolution_status = $Resolution
            evidence = @("test:$Stem-additional")
            re_review_status = $reReviewStatus
            re_review_source_node_id = $SourceNodeId
            re_review_evidence = if ($Resolution -eq 'resolved') {
                @("test:$Stem-additional-rereview")
            } else { @() }
        })
    }
    @($decisionRecords) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $decisionPath -Encoding utf8
    $dispositionPath = Join-Path $Run "receipts/$Stem.disposition.json"
    $disposition = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $Run -MilestoneId $MilestoneId `
        -SourceNodeId $SourceNodeId -SourceThreadId $ThreadId `
        -SourceResultReceiptPath $resultPath `
        -DecisionsPath $decisionPath -OutputPath $dispositionPath |
        ConvertFrom-Json -Depth 50
    return [pscustomobject]@{
        result_path = [IO.Path]::GetRelativePath(
            $Run, $resultPath
        ).Replace('\', '/')
        result_hash = [string]$result.receipt_hash
        disposition_path = [IO.Path]::GetRelativePath(
            $Run, $dispositionPath
        ).Replace('\', '/')
        disposition_hash = [string]$disposition.receipt_hash
    }
}

function Invoke-ScopeTransitionActivation {
    param(
        [Parameter(Mandatory)][string] $Run,
        [Parameter(Mandatory)][string] $SelectionPath,
        [Parameter(Mandatory)][string] $ScopeTransitionKey,
        [Parameter(Mandatory)][string] $ActivationKey
    )
    & (Join-Path $scriptRoot (
        'New-DurableReviewScopeTransitionAuthorizationReceipt.ps1'
    )) -RunDirectory $Run -MilestoneId 'scope-3' `
        -SelectionPath $SelectionPath `
        -ScopeTransitionAuthorizationMaterialPath (
            Join-Path $Run 'materials/scope-2-to-scope-3-transition.md'
        ) -ScopeTransitionKey $ScopeTransitionKey `
        -ActivationKey "$ActivationKey.authorization" | Out-Null
    $scopeAuthorizationReceiptPath = Join-Path $Run (
        'receipts/durable-review-milestone.scope-3.' +
        'scope-transition-authorization.json'
    )
    & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneActivationReceipt.ps1'
    )) -RunDirectory $Run -MilestoneId 'scope-3' `
        -SelectionPath $SelectionPath `
        -AuthorizationMaterialPath (
            Join-Path $Run 'materials/scope-3-authorization.md'
        ) -AcceptanceAuthorizationMaterialPath (
            Join-Path $Run (
                'materials/scope-3-acceptance-authorization.json'
            )
        ) -ScopeTransitionAuthorizationReceiptPath (
            $scopeAuthorizationReceiptPath
        ) `
        -ActivationKey $ActivationKey
}

function Convert-SourceChainToHistoricalAlias {
    param(
        [string] $Run,
        [object] $Chain,
        [string] $Alias
    )
    $resultPath = Join-Path $Run $Chain.result_path
    $result = Get-Content -LiteralPath $resultPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 50
    foreach ($name in @(
        'milestone_id', 'checkpoint_material_path',
        'checkpoint_material_hash', 'receipt_hash'
    )) {
        $result.Remove($name)
    }
    $result.receipt_hash = Get-TextSha256 (
        $result | ConvertTo-Json -Compress -Depth 50
    )
    $result | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $resultPath -Encoding utf8

    $dispositionPath = Join-Path $Run $Chain.disposition_path
    $disposition = Get-Content -LiteralPath $dispositionPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 50
    $disposition.milestone_id = $Alias
    $disposition.source_result_receipt_hash = $result.receipt_hash
    $disposition.Remove('receipt_hash')
    $disposition.receipt_hash = Get-TextSha256 (
        $disposition | ConvertTo-Json -Compress -Depth 50
    )
    $disposition | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $dispositionPath -Encoding utf8
}

function Resign-AcceptanceTail {
    param(
        [string] $Run,
        [scriptblock] $ReceiptMutation
    )
    $receiptPath = Join-Path $Run (
        'receipts/durable-review-milestone.method-2.acceptance.json'
    )
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    & $ReceiptMutation $receipt
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $eventLines = @(Get-Content -LiteralPath $eventsPath)
    $event = $eventLines[-1] |
        ConvertFrom-Json -AsHashtable -Depth 100
    $event.milestone_acceptance_receipt_hash = $receipt.receipt_hash
    $event.milestone_acceptance_key = $receipt.acceptance_key
    $event.milestone_acceptance_evidence_path =
        $receipt.evidence_material_path
    $event.milestone_acceptance_evidence_hash =
        $receipt.evidence_material_hash
    $event.idempotency_key = $receipt.acceptance_key
    $event.request_fingerprint = $receipt.receipt_hash
    $event.Remove('hash')
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    $eventLines[-1] = $event | ConvertTo-Json -Compress -Depth 100
    $eventLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Resign-ScopeActivationTail {
    param(
        [string] $Run,
        [scriptblock] $ReceiptMutation
    )
    $receiptPath = Join-Path $Run (
        'receipts/durable-review-milestone.scope-3.activation.json'
    )
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $oldMaterialPath =
        [string]$receipt.scope_transition_authorization_material_path
    & $ReceiptMutation $receipt
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $eventLines = @(Get-Content -LiteralPath $eventsPath)
    $event = $eventLines[-1] |
        ConvertFrom-Json -AsHashtable -Depth 100
    $event.milestone_activation_receipt_hash = $receipt.receipt_hash
    $event.scope_transition_authorization_receipt_path =
        $receipt.scope_transition_authorization_receipt_path
    $event.scope_transition_authorization_receipt_hash =
        $receipt.scope_transition_authorization_receipt_hash
    $event.scope_transition_authorization_material_path =
        $receipt.scope_transition_authorization_material_path
    $event.scope_transition_authorization_material_hash =
        $receipt.scope_transition_authorization_material_hash
    $event.scope_transition_key = $receipt.scope_transition_key
    $event.request_fingerprint = $receipt.receipt_hash
    if ($oldMaterialPath -ne
        [string]$receipt.scope_transition_authorization_material_path) {
        $oldPointer = "artifact:$oldMaterialPath"
        $newPointer = (
            'artifact:' +
            [string]$receipt.scope_transition_authorization_material_path
        )
        $event.evidence = @($event.evidence | ForEach-Object {
            if ([string]$_ -eq $oldPointer) { $newPointer } else { $_ }
        })
    }
    $event.Remove('hash')
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    $eventLines[-1] = $event | ConvertTo-Json -Compress -Depth 100
    $eventLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Resign-SuccessorExportTail {
    param(
        [string] $Run,
        [scriptblock] $ReceiptMutation
    )
    $receiptPath = Join-Path $Run (
        'receipts/durable-review-successor.export.json'
    )
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    & $ReceiptMutation $receipt
    $receipt.open_obligations_hash = Get-TextSha256 (
        @($receipt.open_obligations) |
            ConvertTo-Json -Compress -Depth 100
    )
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $lines = @(Get-Content -LiteralPath $eventsPath)
    $event = $lines[-1] | ConvertFrom-Json -AsHashtable -Depth 100
    $event.result_receipt_hash = $receipt.receipt_hash
    $event.request_fingerprint = $receipt.receipt_hash
    $event.Remove('hash')
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    $lines[-1] = $event | ConvertTo-Json -Compress -Depth 100
    $lines | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Resign-RevisionLifecycleCorrectionTail {
    param(
        [Parameter(Mandatory)][string] $Run,
        [Parameter(Mandatory)][scriptblock] $ReceiptMutation
    )
    $receiptFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $Run 'receipts') -File |
            Where-Object { $_.Name -like '*.lifecycle-correction.json' }
    )
    if ($receiptFiles.Count -ne 1) {
        throw 'Correction mutation fixture needs exactly one receipt.'
    }
    $receiptPath = $receiptFiles[0].FullName
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    & $ReceiptMutation $receipt
    $receipt.source_corrections_hash = Get-TextSha256 (
        ConvertTo-Json -InputObject @($receipt.source_corrections) `
            -Compress -Depth 100
    )
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $events = @(
        Get-Content -LiteralPath $eventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    $correctionIndex = [Array]::FindIndex(
        [object[]]$events,
        [Predicate[object]]{
            param($event)
            [string]$event.event -eq
                'milestone-revision-lifecycle-evidence-corrected'
        }
    )
    if ($correctionIndex -ne ($events.Count - 1)) {
        throw 'Correction mutation fixture requires the correction at the tail.'
    }
    $event = $events[$correctionIndex]
    $event.milestone_id = [string]$receipt.milestone_id
    $event.milestone_activation_receipt_hash = [string]$receipt.receipt_hash
    $event.milestone_revision_id = [string]$receipt.revision_id
    $event.milestone_revision_authorization_receipt_hash =
        [string]$receipt.authorization_receipt_hash
    $event.milestone_revision_checkpoint_hash =
        [string]$receipt.checkpoint_material_hash
    $event.milestone_revision_input_hash = [string]$receipt.input_manifest_hash
    $event.milestone_revision_selection_key = [string]$receipt.selection_key
    $event.idempotency_key = [string]$receipt.correction_key
    $event.request_fingerprint = [string]$receipt.receipt_hash
    $event.Remove('hash')
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    @($events | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Resign-RevisionInventorySupersessionTail {
    param(
        [Parameter(Mandatory)][string] $Run,
        [Parameter(Mandatory)][scriptblock] $ReceiptMutation
    )
    $legacyReceiptFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $Run 'receipts') -File |
            Where-Object { $_.Name -like '*.inventory-supersession.json' }
    )
    $dedicatedReceiptFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $Run 'receipts') -File |
            Where-Object { $_.Name -like '*.cumulative-correction.json' }
    )
    if (($legacyReceiptFiles.Count -eq 1) -and
        ($dedicatedReceiptFiles.Count -eq 0)) {
        $dedicated = $false
        $receiptPath = $legacyReceiptFiles[0].FullName
    } elseif (($legacyReceiptFiles.Count -eq 0) -and
        ($dedicatedReceiptFiles.Count -eq 1)) {
        $dedicated = $true
        $receiptPath = $dedicatedReceiptFiles[0].FullName
    } else {
        throw 'Inventory supersession fixture needs exactly one receipt.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    & $ReceiptMutation $receipt
    $sourceField = if ($dedicated) {
        'cumulative_correction_sources'
    } else {
        'source_supersessions'
    }
    $sourceHashField = if ($dedicated) {
        'cumulative_correction_sources_hash'
    } else {
        'source_supersessions_hash'
    }
    $keyField = if ($dedicated) {
        'cumulative_correction_key'
    } else {
        'supersession_key'
    }
    $receipt[$sourceHashField] = Get-TextSha256 (
        ConvertTo-Json -InputObject @($receipt[$sourceField]) `
            -Compress -Depth 100
    )
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $events = @(
        Get-Content -LiteralPath $eventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    $eventIndex = [Array]::FindIndex(
        [object[]]$events,
        [Predicate[object]]{
            param($event)
            [string]$event.event -eq $(if ($dedicated) {
                'milestone-revision-cumulative-corrected'
            } else {
                'milestone-revision-inventory-superseded'
            })
        }
    )
    if ($eventIndex -ne ($events.Count - 1)) {
        throw 'Inventory supersession mutation fixture requires a tail event.'
    }
    $events[$eventIndex].milestone_activation_receipt_hash =
        [string]$receipt.receipt_hash
    $events[$eventIndex].milestone_revision_authorization_receipt_hash =
        [string]$receipt.authorization_receipt_hash
    $events[$eventIndex].milestone_revision_checkpoint_hash =
        [string]$receipt.checkpoint_material_hash
    $events[$eventIndex].milestone_revision_input_hash =
        [string]$receipt.input_manifest_hash
    $events[$eventIndex].milestone_revision_selection_key =
        [string]$receipt.selection_key
    $events[$eventIndex].idempotency_key = [string]$receipt[$keyField]
    $events[$eventIndex].request_fingerprint = [string]$receipt.receipt_hash
    $events[$eventIndex].Remove('hash')
    $events[$eventIndex].hash = Get-OrchestrationEventHash (
        [pscustomobject]$events[$eventIndex]
    )
    @($events | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Resign-RevisionAuthorizationTail {
    param(
        [Parameter(Mandatory)][string] $Run,
        [Parameter(Mandatory)][string] $ReceiptRelativePath,
        [Parameter(Mandatory)][scriptblock] $ReceiptMutation
    )
    $receiptPath = Join-Path $Run $ReceiptRelativePath
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    & $ReceiptMutation $receipt
    if ($receipt.ContainsKey('previous_open_occurrences')) {
        $receipt.previous_open_occurrence_count =
            @($receipt.previous_open_occurrences).Count
        $receipt.previous_open_occurrences_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @(
                $receipt.previous_open_occurrences
            ) -Compress -Depth 100
        )
    }
    $receipt.Remove('receipt_hash')
    $receipt.receipt_hash = Get-TextSha256 (
        $receipt | ConvertTo-Json -Compress -Depth 100
    )
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptPath -Encoding utf8

    $eventsPath = Join-Path $Run 'events.jsonl'
    $events = @(
        Get-Content -LiteralPath $eventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    $eventIndex = [Array]::FindIndex(
        [object[]]$events,
        [Predicate[object]]{
            param($event)
            [string]$event.event -eq 'milestone-revision-authorized' -and
            [string]$event.milestone_revision_id -eq
                [string]$receipt.revision_id
        }
    )
    if ($eventIndex -ne ($events.Count - 1)) {
        throw 'Authorization mutation fixture requires the target at the tail.'
    }
    $events[$eventIndex].milestone_revision_authorization_receipt_hash =
        [string]$receipt.receipt_hash
    $events[$eventIndex].milestone_revision_checkpoint_hash =
        [string]$receipt.checkpoint_material_hash
    $events[$eventIndex].milestone_revision_input_hash =
        [string]$receipt.input_manifest_hash
    $events[$eventIndex].milestone_revision_selection_key =
        [string]$receipt.selection_key
    $events[$eventIndex].request_fingerprint = [string]$receipt.receipt_hash
    $events[$eventIndex].Remove('hash')
    $events[$eventIndex].hash = Get-OrchestrationEventHash (
        [pscustomobject]$events[$eventIndex]
    )
    @($events | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $eventsPath -Encoding utf8
}

function Assert-AdoptionMutationRejected {
    param(
        [string] $Run,
        [scriptblock] $ReceiptMutation,
        [string] $Message
    )
    $receiptPath = Join-Path $Run (
        'receipts/durable-review-successor.adoption.json'
    )
    $eventsPath = Join-Path $Run 'events.jsonl'
    $receiptRaw = Get-Content -LiteralPath $receiptPath -Raw
    $eventLines = @(Get-Content -LiteralPath $eventsPath)
    try {
        $receipt = $receiptRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $ReceiptMutation $receipt
        $receipt.Remove('receipt_hash')
        $receipt.receipt_hash = Get-TextSha256 (
            $receipt | ConvertTo-Json -Compress -Depth 100
        )
        $receipt | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $receiptPath -Encoding utf8
        $mutatedLines = @($eventLines)
        $previous = $eventLines[0] |
            ConvertFrom-Json -AsHashtable -Depth 100
        for ($index = 1; $index -lt $eventLines.Count; $index++) {
            $event = $eventLines[$index] |
                ConvertFrom-Json -AsHashtable -Depth 100
            $event.prev_hash = $previous.hash
            if ($index -eq 1) {
                $event.result_receipt_hash = $receipt.receipt_hash
                $event.request_fingerprint = $receipt.receipt_hash
            }
            $event.Remove('hash')
            $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
            $mutatedLines[$index] =
                $event | ConvertTo-Json -Compress -Depth 100
            $previous = $event
        }
        $mutatedLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
        Assert-ThrowsLike {
            Read-DurableReviewSuccessorAdoptionReceipt `
                -RunDirectory $Run | Out-Null
        } 'lineage declaration changed' $Message
    }
    finally {
        Set-Content -LiteralPath $receiptPath -Value $receiptRaw -Encoding utf8
        $eventLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
    }
}

function Complete-SourceLifecycle {
    param(
        [string] $Run,
        [string] $SourceNodeId,
        [string] $ThreadId,
        [string] $ResultRelativePath
    )
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running', 'completed',
        'validated', 'adopted'
    )) {
        $arguments = @{
            RunDirectory = $Run
            NodeId = $SourceNodeId
            Status = $status
            Message = "$SourceNodeId $status"
            IdempotencyKey = "$SourceNodeId-$status"
        }
        if ($status -eq 'materialized') {
            $arguments.ThreadId = $ThreadId
            $arguments.ModelId = 'gpt-5.6-sol'
        }
        if ($status -eq 'completed') {
            $arguments.Evidence = @("artifact:$ResultRelativePath")
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
            Out-Null
    }
}

function Add-SyntheticPreAuthorizationChain {
    param(
        [string] $Run,
        [string] $SourceNodeId,
        [string] $ThreadId,
        [string] $ResultPath,
        [string] $DispositionPath
    )
    $plan = Get-Content -LiteralPath (Join-Path $Run 'plan.json') -Raw |
        ConvertFrom-Json -Depth 100
    $metadata = Get-Content -LiteralPath (Join-Path $Run 'run.json') -Raw |
        ConvertFrom-Json -Depth 30
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $SourceNodeId
    }) | Select-Object -First 1
    $eventsPath = Join-Path $Run 'events.jsonl'
    foreach ($transition in @(
        @{ prior = 'adopted'; status = 'completed'; path = $ResultPath },
        @{ prior = 'completed'; status = 'validated'; path = $DispositionPath },
        @{ prior = 'validated'; status = 'adopted'; path = $DispositionPath }
    )) {
        $events = @(Read-OrchestrationJournal $eventsPath)
        $event = [ordered]@{
            sequence = $events.Count
            prev_hash = [string]$events[-1].hash
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            event = 'node-status'
            run_id = [string]$plan.run_id
            plan_hash = [string]$metadata.plan_hash
            workspace_root = [string]$metadata.workspace_root
            policy_version = [string]$plan.policy_version
            actor = [string]$plan.orchestrator.id
            node_id = $SourceNodeId
            role_id = [string]$node.role_id
            prior_state = [string]$transition.prior
            status = [string]$transition.status
            message = 'Caller timing error before revision authorization.'
            thread_id = $ThreadId
            model_id = $null
            artifact = [string]$transition.path
            topology = [string]$node.topology
            capability = [string]$node.capability
            effort = [string]$node.effort
            wave = [int]$node.wave
            attempt = 1
            execution_slot_delta = 0
            input_tokens_delta = 0
            output_tokens_delta = 0
            coordination_tokens_delta = 0
            usage_source = 'none'
            error_class = $null
            decision = $null
            human_actor = $null
            evidence = @("artifact:$([string]$transition.path)")
            recovery_receipt_path = $null
            recovery_receipt_hash = $null
            replacement_receipt_path = $null
            replacement_receipt_hash = $null
            result_receipt_path = $null
            result_receipt_hash = $null
            idempotency_key = (
                "caller-timing-error-$SourceNodeId-$($transition.status)"
            )
            request_fingerprint = Get-TextSha256 (
                "$SourceNodeId|$([string]$transition.status)|" +
                [string]$transition.path
            )
        }
        $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 50
        )
    }
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $planPath = Join-Path $testRoot 'plan.json'
    New-ReviewPlan -Path $planPath
    $run = Join-Path $testRoot 'run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $planPath -RunDirectory $run `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($directory in @('materials', 'thread-reads', 'receipts')) {
        $path = Join-Path $run $directory
        if (-not (Test-Path -LiteralPath $path)) {
            $null = New-Item -ItemType Directory -Path $path
        }
    }
    $checkpoint1 = Join-Path $run 'materials/checkpoint-method-1.json'
    Set-Content -LiteralPath $checkpoint1 -Value '{"milestone":"method-1"}'
    $baselineReview = New-SourceChain -Run $run -SourceNodeId 'review' `
        -ThreadId 'review-thread' -MilestoneId 'method-1' `
        -CheckpointPath $checkpoint1 -Stem 'review' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'resolved' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding'
    $baselineDomain = New-SourceChain -Run $run -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' -MilestoneId 'method-1' `
        -CheckpointPath $checkpoint1 -Stem 'domain' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'resolved'
    Convert-SourceChainToHistoricalAlias -Run $run -Chain $baselineReview `
        -Alias 'method-1-historical-round'
    Convert-SourceChainToHistoricalAlias -Run $run -Chain $baselineDomain `
        -Alias 'method-1-historical-round'
    Complete-SourceLifecycle -Run $run -SourceNodeId 'review' `
        -ThreadId 'review-thread' `
        -ResultRelativePath $baselineReview.result_path
    Complete-SourceLifecycle -Run $run -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' `
        -ResultRelativePath $baselineDomain.result_path
    foreach ($status in @('running', 'completed', 'validated')) {
        $arguments = @{
            RunDirectory = $run
            NodeId = 'integrate'
            Status = $status
            Message = "integrate $status"
            IdempotencyKey = "integrate-$status"
        }
        if ($status -eq 'completed') {
            $arguments.Evidence = @('observation:baseline-integrated')
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
            Out-Null
    }
    $finalDirectory = Join-Path $testRoot 'artifacts/final'
    $null = New-Item -ItemType Directory -Path $finalDirectory -Force
    Set-Content -LiteralPath (Join-Path $finalDirectory 'result.md') `
        -Value 'baseline result'
    $baselineCompletion = & (
        Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1'
    ) -RunDirectory $run | ConvertFrom-Json -Depth 30
    Assert-True (
        $baselineCompletion.complete -and
        $baselineCompletion.active_review_milestone -eq 'method-1'
    ) (
        'The immutable plan paths, including historical receipt milestone ' +
        'aliases, must remain the first milestone baseline.'
    )

    # A later checkpoint inside the immutable first milestone needs an
    # append-only authorization before either durable source is re-armed.
    $revisionRun = Join-Path $testRoot 'first-milestone-revision-run'
    Copy-Item -LiteralPath $run -Destination $revisionRun -Recurse
    $revisionCheckpoint = Join-Path $revisionRun (
        'materials/checkpoint-method-1-revision-1.json'
    )
    $revisionInput = Join-Path $revisionRun (
        'materials/input-method-1-revision-1.json'
    )
    Set-Content -LiteralPath $revisionCheckpoint `
        -Value '{"milestone":"method-1","revision":1}'
    Set-Content -LiteralPath $revisionInput `
        -Value '{"scope":"method-1-revision-1"}'
    $preAnchorReview = New-SourceChain -Run $revisionRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revisionCheckpoint `
        -Stem 'review.method-1-revision-1-preanchor' -Severity 'P0' `
        -FindingText 'pre-anchor review must not be selected' `
        -Resolution 'resolved' -FindingId 'preanchor-review' `
        -CanonicalFindingId 'preanchor-review'
    $preAnchorDomain = New-SourceChain -Run $revisionRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revisionCheckpoint `
        -Stem 'domain.method-1-revision-1-preanchor' -Severity 'P0' `
        -FindingText 'pre-anchor domain must not be selected' `
        -Resolution 'resolved' -FindingId 'preanchor-domain' `
        -CanonicalFindingId 'preanchor-domain'
    Add-SyntheticPreAuthorizationChain -Run $revisionRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -ResultPath $preAnchorReview.result_path `
        -DispositionPath $preAnchorReview.disposition_path
    Add-SyntheticPreAuthorizationChain -Run $revisionRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -ResultPath $preAnchorDomain.result_path `
        -DispositionPath $preAnchorDomain.disposition_path
    $reviewPrompt = Join-Path $revisionRun 'materials/review-revision-1.md'
    $domainPrompt = Join-Path $revisionRun 'materials/domain-revision-1.md'
    Set-Content -LiteralPath $reviewPrompt -Value 'Review revision one.'
    Set-Content -LiteralPath $domainPrompt -Value 'Audit revision one.'
    $reviewMaterialManifest = Join-Path $revisionRun (
        'materials/method-1-revision-1-review-materials.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            material_path = 'materials/review-revision-1.md'
        },
        [ordered]@{
            source_node_id = 'domain'
            material_path = 'materials/domain-revision-1.md'
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $reviewMaterialManifest
    $excludedEvidenceManifest = Join-Path $revisionRun (
        'materials/method-1-revision-1-excluded-evidence.json'
    )
    $revisionPlanForInventory = Get-Content -LiteralPath (
        Join-Path $revisionRun 'plan.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $revisionEventsForInventory = @(Read-OrchestrationJournal (
        Join-Path $revisionRun 'events.jsonl'
    ))
    $excludedInventory = Get-MilestoneRevisionExcludedInventory `
        -RunDirectory $revisionRun -Events $revisionEventsForInventory `
        -RequiredSourceIds @('domain', 'review') `
        -CheckpointHash (
            Get-FileHash -LiteralPath $revisionCheckpoint -Algorithm SHA256
        ).Hash.ToLowerInvariant() `
        -EventCount $revisionEventsForInventory.Count
    $excludedManifestEntries = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in @('domain', 'review')) {
        $eventBindings = @($excludedInventory.events | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        } | ForEach-Object {
            [ordered]@{
                sequence = [int]$_.event_sequence
                event_hash = [string]$_.event_hash
            }
        })
        $artifacts = @($excludedInventory.artifacts | Where-Object {
            [string]$_.source_node_id -eq $sourceNodeId
        } | ForEach-Object {
            [ordered]@{
                type = [string]$_.type
                path = [string]$_.path
                file_hash = [string]$_.file_hash
                internal_hash = [string]$_.internal_hash
            }
        })
        $excludedManifestEntries.Add([ordered]@{
            source_node_id = $sourceNodeId
            reason = 'caller-timing-error/non-completion evidence'
            event_bindings = $eventBindings
            artifacts = $artifacts
        })
    }
    @($excludedManifestEntries) | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $excludedEvidenceManifest
    $revisionAuthorizationMaterial = Join-Path $revisionRun (
        'materials/method-1-revision-1-controller-authorization.md'
    )
    Set-Content -LiteralPath $revisionAuthorizationMaterial -Value (
        'Controller authorizes a first-milestone checkpoint revision.'
    )
    $revisionAcceptanceEvidence = Join-Path $revisionRun (
        'materials/method-1-revision-1-main-acceptance.md'
    )
    Set-Content -LiteralPath $revisionAcceptanceEvidence `
        -Value 'Main owner must independently accept revision one.'
    $revisionAcceptanceAuthorization = Join-Path $revisionRun (
        'materials/method-1-revision-1-acceptance-authorization.json'
    )
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'method-1'
        main_node_id = 'integrate'
        acceptance_key = 'controller:method-1-revision-1-acceptance'
        evidence_material_path = [IO.Path]::GetRelativePath(
            $revisionRun, $revisionAcceptanceEvidence
        ).Replace('\', '/')
        evidence_material_hash = (
            Get-FileHash -LiteralPath $revisionAcceptanceEvidence `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $revisionAcceptanceAuthorization
    $revisionPreAuthorizationRun = Join-Path $testRoot (
        'revision-pre-authorization-snapshot'
    )
    Copy-Item -LiteralPath $revisionRun `
        -Destination $revisionPreAuthorizationRun -Recurse
    $revisionAuthorization = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
    )) -RunDirectory $revisionRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $revisionCheckpoint `
        -InputManifestPath $revisionInput `
        -ReviewMaterialManifestPath $reviewMaterialManifest `
        -ExcludedEvidenceManifestPath $excludedEvidenceManifest `
        -AuthorizationMaterialPath $revisionAuthorizationMaterial `
        -AcceptanceAuthorizationMaterialPath $revisionAcceptanceAuthorization `
        -SelectionKey 'controller:select-method-1-revision-1' `
        -ActivationKey 'controller:method-1-revision-1' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$revisionAuthorization.schema_version -eq '1.0' -and
        [string]$revisionAuthorization.milestone_id -eq 'method-1' -and
        [string]$revisionAuthorization.receipt_hash -match '^[0-9a-f]{64}$'
    ) 'First-milestone revision authorization must be created before review.'
    $authorizedSelectionKey = [string]$revisionAuthorization.selection_key
    Assert-True (
        $authorizedSelectionKey -ceq (
            'controller:milestone-revision-selection:' +
            [string]$revisionAuthorization.revision_id
        )
    ) 'The authorization must derive a run/revision-unique selection key.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $revisionRun | Out-Null
    } 'authorized but not yet selected' (
        'A pending first-milestone revision must block completion.'
    )
    $revisionAuthorizedRun = Join-Path $testRoot 'revision-authorized-snapshot'
    Copy-Item -LiteralPath $revisionRun -Destination $revisionAuthorizedRun `
        -Recurse
    $revisionAuthorizationRelative = [IO.Path]::GetRelativePath(
        $revisionRun, (
            Join-Path $revisionRun (
                "receipts/durable-review-milestone.method-1.revision-" +
                "$($revisionAuthorization.revision_id).authorization.json"
            )
        )
    ).Replace('\', '/')
    foreach ($keyMutation in @('missing', 'empty')) {
        $keyRun = Join-Path $testRoot "revision-selection-key-$keyMutation"
        Copy-Item -LiteralPath $revisionAuthorizedRun -Destination $keyRun `
            -Recurse
        $keyReceiptPath = Join-Path $keyRun $revisionAuthorizationRelative
        $keyReceipt = Get-Content -LiteralPath $keyReceiptPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        if ($keyMutation -eq 'missing') {
            $keyReceipt.Remove('selection_key')
        } else {
            $keyReceipt.selection_key = ''
        }
        $keyPayload = [ordered]@{}
        foreach ($key in $keyReceipt.Keys | Where-Object {
            $_ -ne 'receipt_hash'
        }) {
            $keyPayload[$key] = $keyReceipt[$key]
        }
        $keyReceipt.receipt_hash = Get-TextSha256 (
            $keyPayload | ConvertTo-Json -Compress -Depth 100
        )
        $keyReceipt | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $keyReceiptPath
        Assert-ThrowsLike {
            Read-DurableReviewMilestoneRevisionAuthorization `
                -Path $keyReceiptPath -RunDirectory $keyRun | Out-Null
        } $(if ($keyMutation -eq 'missing') {
            "missing 'selection_key'"
        } else {
            'run or milestone binding is invalid'
        }) "Authorization selection_key $keyMutation must fail closed."
    }
    foreach ($source in @(
        @{ id = 'review'; thread = 'review-thread' },
        @{ id = 'domain'; thread = 'domain-thread' }
    )) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $revisionRun -NodeId $source.id -Status running `
            -ThreadId $source.thread `
            -MilestoneRevisionAuthorizationReceiptPath (
                $revisionAuthorizationRelative
            ) -Message "Fresh revision review for $($source.id)." `
            -Evidence @('observation:fresh-post-authorization-review') `
            -IdempotencyKey "revision-rearm-$($source.id)" | Out-Null
    }
    $revisionReview = New-SourceChain -Run $revisionRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revisionCheckpoint `
        -Stem 'review.method-1-revision-1' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'resolved' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding'
    $revisionDomain = New-SourceChain -Run $revisionRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revisionCheckpoint `
        -Stem 'domain.method-1-revision-1' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'resolved' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    foreach ($source in @(
        @{
            id = 'review'; thread = 'review-thread'
            result = $revisionReview.result_path
            disposition = $revisionReview.disposition_path
        },
        @{
            id = 'domain'; thread = 'domain-thread'
            result = $revisionDomain.result_path
            disposition = $revisionDomain.disposition_path
        }
    )) {
        foreach ($status in @('completed', 'validated', 'adopted')) {
            $pointer = if ($status -eq 'completed') {
                "artifact:$($source.result)"
            } else {
                "artifact:$($source.disposition)"
            }
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $revisionRun -NodeId $source.id `
                -Status $status -ThreadId $source.thread `
                -Message "Revision $($source.id) $status." `
                -Evidence @($pointer) `
                -IdempotencyKey "revision-$($source.id)-$status" | Out-Null
        }
    }
    $revisionReadyRun = Join-Path $testRoot 'revision-ready-snapshot'
    Copy-Item -LiteralPath $revisionRun -Destination $revisionReadyRun -Recurse
    $revisionSelectionMaterial = Join-Path $revisionRun (
        'materials/method-1-revision-1-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $revisionReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $revisionDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $revisionSelectionMaterial

    # A caller may have correctly bound the result at completed and the
    # disposition at adopted, but accidentally repeated the result pointer at
    # validated. The immutable events remain evidence; one append-only,
    # whole-source-set correction must be required before selection.
    $evidenceCorrectionRun = Join-Path $testRoot (
        'revision-validated-evidence-correction'
    )
    Copy-Item -LiteralPath $revisionReadyRun `
        -Destination $evidenceCorrectionRun -Recurse
    $evidenceCorrectionSelection = Join-Path $evidenceCorrectionRun (
        'materials/method-1-revision-1-selection.json'
    )
    Copy-Item -LiteralPath $revisionSelectionMaterial `
        -Destination $evidenceCorrectionSelection
    $evidenceCorrectionEventsPath = Join-Path (
        $evidenceCorrectionRun
    ) 'events.jsonl'
    $evidenceCorrectionEvents = @(
        Get-Content -LiteralPath $evidenceCorrectionEventsPath |
            ForEach-Object {
                $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            }
    )
    foreach ($source in @(
        @{
            id = 'review'
            result = $revisionReview.result_path
            disposition = $revisionReview.disposition_path
        },
        @{
            id = 'domain'
            result = $revisionDomain.result_path
            disposition = $revisionDomain.disposition_path
        }
    )) {
        $resultReceipt = Get-Content -LiteralPath (
            Join-Path $evidenceCorrectionRun $source.result
        ) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
        $completedIndex = [Array]::FindLastIndex(
            [object[]]$evidenceCorrectionEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'completed'
            }
        )
        $validatedIndex = [Array]::FindLastIndex(
            [object[]]$evidenceCorrectionEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'validated'
            }
        )
        $adoptedIndex = [Array]::FindLastIndex(
            [object[]]$evidenceCorrectionEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'adopted'
            }
        )
        Assert-True ($completedIndex -ge 0 -and
            $validatedIndex -ge 0 -and $adoptedIndex -ge 0) (
            "The correction fixture needs all lifecycle events for '$($source.id)'."
        )
        $evidenceCorrectionEvents[$completedIndex].evidence = @(
            "artifact:$($source.result)",
            "artifact:$($resultReceipt.thread_read_path)"
        )
        Assert-True ($validatedIndex -ge 0) (
            "The correction fixture needs a validated event for '$($source.id)'."
        )
        $evidenceCorrectionEvents[$validatedIndex].evidence = @(
            "artifact:$($source.result)",
            "test:lifecycle-correction-extra-test-$($source.id)",
            "source:lifecycle-correction-extra-source-$($source.id)",
            "observation:lifecycle-correction-extra-observation-$($source.id)"
        )
        $evidenceCorrectionEvents[$adoptedIndex].evidence = @(
            "artifact:$($source.disposition)",
            "observation:lifecycle-correction-adopted-$($source.id)"
        )
    }
    for ($eventIndex = 0; $eventIndex -lt $evidenceCorrectionEvents.Count;
        $eventIndex++) {
        $evidenceCorrectionEvents[$eventIndex].prev_hash = if (
            $eventIndex -eq 0
        ) { $null } else {
            [string]$evidenceCorrectionEvents[$eventIndex - 1].hash
        }
        $evidenceCorrectionEvents[$eventIndex].hash =
            Get-OrchestrationEventHash (
                [pscustomobject]$evidenceCorrectionEvents[$eventIndex]
            )
    }
    @($evidenceCorrectionEvents | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $evidenceCorrectionEventsPath
    $evidenceCorrectionAuthorizationPath = Join-Path (
        $evidenceCorrectionRun
    ) $revisionAuthorizationRelative
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $evidenceCorrectionRun `
            -AuthorizationReceiptPath $evidenceCorrectionAuthorizationPath `
            -SelectionMaterialPath $evidenceCorrectionSelection `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'lifecycle does not bind' (
        'A validated event that repeats the result pointer must fail closed.'
    )
    $evidenceCorrectionAuthorization = Join-Path (
        $evidenceCorrectionRun
    ) 'materials/revision-lifecycle-correction-authorization.md'
    Set-Content -LiteralPath $evidenceCorrectionAuthorization -Value (
        'Controller authorizes only the validated evidence pointer correction.'
    )
    $evidenceCorrectionBeforeRun = Join-Path $testRoot (
        'revision-validated-evidence-before-correction'
    )
    Copy-Item -LiteralPath $evidenceCorrectionRun `
        -Destination $evidenceCorrectionBeforeRun -Recurse
    $validatedEvidenceMutations = @(
        @{
            name = 'second-artifact'
            build = {
                param($source)
                @(
                    "artifact:$($source.result)",
                    "artifact:$($source.disposition)",
                    "observation:second-artifact"
                )
            }
        },
        @{
            name = 'zero-artifact'
            build = {
                param($source)
                @(
                    "test:zero-artifact-$($source.id)",
                    'observation:zero-artifact'
                )
            }
        },
        @{
            name = 'artifact-non-result'
            build = {
                param($source)
                @(
                    "artifact:$($source.disposition)",
                    'observation:artifact-non-result'
                )
            }
        }
    )
    foreach ($mutation in $validatedEvidenceMutations) {
        $mutationRun = Join-Path $testRoot (
            "revision-lifecycle-correction-validated-$($mutation.name)"
        )
        Copy-Item -LiteralPath $evidenceCorrectionBeforeRun `
            -Destination $mutationRun -Recurse
        $mutationEventsPath = Join-Path $mutationRun 'events.jsonl'
        $mutationEvents = @(
            Get-Content -LiteralPath $mutationEventsPath | ForEach-Object {
                $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            }
        )
        foreach ($source in @(
            @{
                id = 'review'
                result = $revisionReview.result_path
                disposition = $revisionReview.disposition_path
            },
            @{
                id = 'domain'
                result = $revisionDomain.result_path
                disposition = $revisionDomain.disposition_path
            }
        )) {
            $validatedIndex = [Array]::FindLastIndex(
                [object[]]$mutationEvents,
                [Predicate[object]]{
                    param($event)
                    [string]$event.node_id -eq [string]$source.id -and
                    [string]$event.status -eq 'validated'
                }
            )
            Assert-True ($validatedIndex -ge 0) (
                "The '$($mutation.name)' fixture needs a validated event."
            )
            $mutationEvents[$validatedIndex].evidence = @(
                & $mutation.build $source
            )
        }
        for ($eventIndex = 0; $eventIndex -lt $mutationEvents.Count;
            $eventIndex++) {
            $mutationEvents[$eventIndex].prev_hash = if (
                $eventIndex -eq 0
            ) { $null } else {
                [string]$mutationEvents[$eventIndex - 1].hash
            }
            $mutationEvents[$eventIndex].hash = Get-OrchestrationEventHash (
                [pscustomobject]$mutationEvents[$eventIndex]
            )
        }
        @($mutationEvents | ForEach-Object {
            [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
        }) | Set-Content -LiteralPath $mutationEventsPath
        $beforeCount = $mutationEvents.Count
        $beforeHead = [string]$mutationEvents[-1].hash
        $beforeFileHash = (Get-FileHash -LiteralPath $mutationEventsPath `
            -Algorithm SHA256).Hash
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
            )) -RunDirectory $mutationRun `
                -AuthorizationReceiptPath (
                    Join-Path $mutationRun $revisionAuthorizationRelative
                ) -SelectionMaterialPath (
                    Join-Path $mutationRun (
                        'materials/method-1-revision-1-selection.json'
                    )
                ) -AuthorizationMaterialPath (
                    Join-Path $mutationRun (
                        'materials/revision-lifecycle-correction-authorization.md'
                    )
                ) -CorrectionKey "controller:reject-$($mutation.name)" |
                Out-Null
        } 'exact validated-result-pointer error shape' (
            "The '$($mutation.name)' validated evidence mutation must fail closed."
        )
        $afterEvents = @(Read-OrchestrationJournal $mutationEventsPath)
        Assert-True (
            $afterEvents.Count -eq $beforeCount -and
            [string]$afterEvents[-1].hash -eq $beforeHead -and
            (Get-FileHash -LiteralPath $mutationEventsPath `
                -Algorithm SHA256).Hash -eq $beforeFileHash
        ) "The '$($mutation.name)' rejection must not mutate the journal."
    }
    $completedEvidenceMutations = @(
        @{
            name = 'third-artifact'
            build = {
                param($source)
                @(
                    "artifact:$($source.result)",
                    "artifact:$($source.raw)",
                    'artifact:receipts/third-artifact.json'
                )
            }
        },
        @{
            name = 'wrong-raw-path'
            build = {
                param($source)
                @(
                    "artifact:$($source.result)",
                    'artifact:thread-reads/wrong.raw.json'
                )
            }
        },
        @{
            name = 'raw-other-artifact'
            build = {
                param($source)
                @(
                    "artifact:$($source.result)",
                    "artifact:$($source.disposition)"
                )
            }
        },
        @{
            name = 'zero-result'
            build = {
                param($source)
                @("artifact:$($source.raw)")
            }
        }
    )
    foreach ($mutation in $completedEvidenceMutations) {
        $mutationRun = Join-Path $testRoot (
            "revision-lifecycle-correction-completed-$($mutation.name)"
        )
        Copy-Item -LiteralPath $evidenceCorrectionBeforeRun `
            -Destination $mutationRun -Recurse
        $mutationEventsPath = Join-Path $mutationRun 'events.jsonl'
        $mutationEvents = @(
            Get-Content -LiteralPath $mutationEventsPath | ForEach-Object {
                $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            }
        )
        foreach ($source in @(
            @{
                id = 'review'
                result = $revisionReview.result_path
                disposition = $revisionReview.disposition_path
            },
            @{
                id = 'domain'
                result = $revisionDomain.result_path
                disposition = $revisionDomain.disposition_path
            }
        )) {
            $receipt = Get-Content -LiteralPath (
                Join-Path $mutationRun $source.result
            ) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
            $source.raw = [string]$receipt.thread_read_path
            $completedIndex = [Array]::FindLastIndex(
                [object[]]$mutationEvents,
                [Predicate[object]]{
                    param($event)
                    [string]$event.node_id -eq [string]$source.id -and
                    [string]$event.status -eq 'completed'
                }
            )
            Assert-True ($completedIndex -ge 0) (
                "The '$($mutation.name)' fixture needs a completed event."
            )
            $mutationEvents[$completedIndex].evidence = @(
                & $mutation.build $source
            )
        }
        for ($eventIndex = 0; $eventIndex -lt $mutationEvents.Count;
            $eventIndex++) {
            $mutationEvents[$eventIndex].prev_hash = if (
                $eventIndex -eq 0
            ) { $null } else {
                [string]$mutationEvents[$eventIndex - 1].hash
            }
            $mutationEvents[$eventIndex].hash = Get-OrchestrationEventHash (
                [pscustomobject]$mutationEvents[$eventIndex]
            )
        }
        @($mutationEvents | ForEach-Object {
            [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
        }) | Set-Content -LiteralPath $mutationEventsPath
        $beforeCount = $mutationEvents.Count
        $beforeHead = [string]$mutationEvents[-1].hash
        $beforeFileHash = (Get-FileHash -LiteralPath $mutationEventsPath `
            -Algorithm SHA256).Hash
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
            )) -RunDirectory $mutationRun `
                -AuthorizationReceiptPath (
                    Join-Path $mutationRun $revisionAuthorizationRelative
                ) -SelectionMaterialPath (
                    Join-Path $mutationRun (
                        'materials/method-1-revision-1-selection.json'
                    )
                ) -AuthorizationMaterialPath (
                    Join-Path $mutationRun (
                        'materials/revision-lifecycle-correction-authorization.md'
                    )
                ) -CorrectionKey "controller:reject-completed-$($mutation.name)" |
                Out-Null
        } 'exact validated-result-pointer error shape' (
            "The completed '$($mutation.name)' mutation must fail closed."
        )
        $afterEvents = @(Read-OrchestrationJournal $mutationEventsPath)
        Assert-True (
            $afterEvents.Count -eq $beforeCount -and
            [string]$afterEvents[-1].hash -eq $beforeHead -and
            (Get-FileHash -LiteralPath $mutationEventsPath `
                -Algorithm SHA256).Hash -eq $beforeFileHash
        ) "The completed '$($mutation.name)' rejection must not mutate the journal."
    }
    $evidenceCorrection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
    )) -RunDirectory $evidenceCorrectionRun `
        -AuthorizationReceiptPath $evidenceCorrectionAuthorizationPath `
        -SelectionMaterialPath $evidenceCorrectionSelection `
        -AuthorizationMaterialPath $evidenceCorrectionAuthorization `
        -CorrectionKey 'controller:revision-validated-evidence-correction' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$evidenceCorrection.schema_version -eq '1.0' -and
        @($evidenceCorrection.source_corrections).Count -eq 2
    ) 'One correction receipt must bind the complete durable source set.'
    foreach ($source in @('review', 'domain')) {
        $validatedEvent = @($evidenceCorrectionEvents | Where-Object {
            [string]$_.node_id -eq $source -and
            [string]$_.status -eq 'validated'
        }) | Select-Object -Last 1
        Assert-True (
            @($validatedEvent.evidence).Count -eq 4 -and
            [string]$validatedEvent.evidence[1] -eq
                "test:lifecycle-correction-extra-test-$source" -and
            [string]$validatedEvent.evidence[2] -eq
                "source:lifecycle-correction-extra-source-$source" -and
            [string]$validatedEvent.evidence[3] -eq
                "observation:lifecycle-correction-extra-observation-$source"
        ) 'Lifecycle correction must preserve extra non-artifact evidence.'
    }
    $evidenceCorrectionPendingRun = Join-Path $testRoot (
        'revision-validated-evidence-corrected-pending-selection'
    )
    Copy-Item -LiteralPath $evidenceCorrectionRun `
        -Destination $evidenceCorrectionPendingRun -Recurse
    $correctedRevisionSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $evidenceCorrectionRun `
        -AuthorizationReceiptPath $evidenceCorrectionAuthorizationPath `
        -SelectionMaterialPath $evidenceCorrectionSelection `
        -SelectionKey $authorizedSelectionKey |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$correctedRevisionSelection.schema_version -eq '1.2' -and
        [string]$correctedRevisionSelection.lifecycle_correction_receipt_hash -eq
            [string]$evidenceCorrection.receipt_hash
    ) (
        'A corrected selection must bind the exact append-only correction ' +
        'without rewriting lifecycle events.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $evidenceCorrectionRun | Out-Null
    } 'lacks main-owner acceptance' (
        'Lifecycle evidence correction cannot replace independent main acceptance.'
    )

    $pendingCorrectionPath = @(
        Get-ChildItem -LiteralPath (
            Join-Path $evidenceCorrectionPendingRun 'receipts'
        ) -File | Where-Object {
            $_.Name -like '*.lifecycle-correction.json'
        }
    )[0].FullName
    $pendingCorrectionEvents = @(Read-OrchestrationJournal (
        Join-Path $evidenceCorrectionPendingRun 'events.jsonl'
    ))
    $pendingCorrectionState = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $evidenceCorrectionPendingRun |
        ConvertFrom-Json -Depth 100
    $pendingCorrectionEvent = $pendingCorrectionEvents[-1]
    Assert-True (
        [string]$pendingCorrectionEvent.event -eq
            'milestone-revision-lifecycle-evidence-corrected' -and
        $null -eq $pendingCorrectionEvent.node_id -and
        $null -eq $pendingCorrectionEvent.prior_state -and
        [string]$pendingCorrectionEvent.status -eq 'planned' -and
        @($pendingCorrectionState.nodes | Where-Object {
            [string]$_.id -in @('review', 'domain') -and
            [string]$_.status -eq 'adopted'
        }).Count -eq 2
    ) (
        'Lifecycle evidence correction must append a non-state event and leave ' +
        'both durable sources adopted.'
    )
    $pendingCorrectionJournalHash = (
        Get-FileHash -LiteralPath (
            Join-Path $evidenceCorrectionPendingRun 'events.jsonl'
        ) -Algorithm SHA256
    ).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
        )) -RunDirectory $evidenceCorrectionPendingRun `
            -AuthorizationReceiptPath (
                Join-Path $evidenceCorrectionPendingRun (
                    $revisionAuthorizationRelative
                )
            ) -SelectionMaterialPath (
                Join-Path $evidenceCorrectionPendingRun (
                    'materials/method-1-revision-1-selection.json'
                )
            ) -AuthorizationMaterialPath (
                Join-Path $evidenceCorrectionPendingRun (
                    'materials/revision-lifecycle-correction-authorization.md'
                )
            ) -CorrectionKey 'controller:duplicate-lifecycle-correction' |
            Out-Null
    } 'requires one pending, uncorrected authorization' (
        'A revision lifecycle correction cannot be repeated or forked.'
    )
    Assert-True (
        $pendingCorrectionJournalHash -eq (
            Get-FileHash -LiteralPath (
                Join-Path $evidenceCorrectionPendingRun 'events.jsonl'
            ) -Algorithm SHA256
        ).Hash
    ) 'A rejected duplicate correction must not mutate the journal.'

    # A valid lifecycle correction and a later result that omits previously
    # resolved source occurrences must compose through one non-state cumulative
    # supersession.  Old receipts/events remain immutable and the combined
    # selection still cannot satisfy independent main acceptance.
    $combinedCumulativeRun = Join-Path $testRoot (
        'revision-lifecycle-plus-cumulative-supersession'
    )
    Copy-Item -LiteralPath $evidenceCorrectionBeforeRun `
        -Destination $combinedCumulativeRun -Recurse
    $combinedResultPath = Join-Path $combinedCumulativeRun $revisionReview.result_path
    $combinedResult = Get-Content -LiteralPath $combinedResultPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $combinedOmittedFindingId = 'review-method-1-finding-r08'
    $combinedResult.pending_findings = @(
        $combinedResult.pending_findings | Where-Object {
            [string]$_.finding_id -ne $combinedOmittedFindingId
        }
    )
    $combinedResult.Remove('receipt_hash')
    $combinedResult.receipt_hash = Get-ThreadResultReceiptCanonicalHash `
        -Receipt ([pscustomobject]$combinedResult)
    $combinedResult | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $combinedResultPath -Encoding utf8
    $combinedDispositionPath = Join-Path $combinedCumulativeRun `
        $revisionReview.disposition_path
    $combinedDisposition = Get-Content -LiteralPath $combinedDispositionPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $combinedDisposition.source_result_receipt_hash =
        [string]$combinedResult.receipt_hash
    $combinedDisposition.decisions = @(
        $combinedDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -ne $combinedOmittedFindingId
        }
    )
    $combinedDisposition.blocking_open = @(
        $combinedDisposition.decisions | Where-Object {
            [string]$_.severity -in @('P0', 'P1') -and
            [string]$_.resolution_status -ne 'resolved'
        } | ForEach-Object { [string]$_.finding }
    )
    $combinedDisposition.Remove('receipt_hash')
    $combinedDisposition.receipt_hash = Get-TextSha256 (
        $combinedDisposition | ConvertTo-Json -Compress -Depth 100
    )
    $combinedDisposition | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $combinedDispositionPath -Encoding utf8
    $combinedEventsPath = Join-Path $combinedCumulativeRun 'events.jsonl'
    $combinedEventsBefore = @(Read-OrchestrationJournal $combinedEventsPath)
    $combinedPrefixHash = (Get-FileHash -LiteralPath $combinedEventsPath `
        -Algorithm SHA256).Hash
    $combinedOldResultHash = (Get-FileHash -LiteralPath $combinedResultPath `
        -Algorithm SHA256).Hash
    $combinedOldDispositionHash = (Get-FileHash -LiteralPath $combinedDispositionPath `
        -Algorithm SHA256).Hash
    $combinedAuthorizationPath = Join-Path $combinedCumulativeRun `
        $revisionAuthorizationRelative
    $combinedSelectionPath = Join-Path $combinedCumulativeRun `
        'materials/method-1-revision-1-selection.json'
    $combinedAuthorizationMaterial = Join-Path $combinedCumulativeRun `
        'materials/revision-lifecycle-correction-authorization.md'
    $combinedEvents = @(
        Get-Content -LiteralPath $combinedEventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    foreach ($source in @(
        @{ id = 'review'; result = $revisionReview.result_path; disposition = $revisionReview.disposition_path },
        @{ id = 'domain'; result = $revisionDomain.result_path; disposition = $revisionDomain.disposition_path }
    )) {
        $resultReceipt = Get-Content -LiteralPath (
            Join-Path $combinedCumulativeRun $source.result
        ) -Raw | ConvertFrom-Json -Depth 100
        $completedIndex = [Array]::FindLastIndex(
            [object[]]$combinedEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'completed'
            }
        )
        $validatedIndex = [Array]::FindLastIndex(
            [object[]]$combinedEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'validated'
            }
        )
        $adoptedIndex = [Array]::FindLastIndex(
            [object[]]$combinedEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'adopted'
            }
        )
        $combinedEvents[$completedIndex].evidence = @(
            "artifact:$($source.result)",
            "artifact:$($resultReceipt.thread_read_path)"
        )
        $combinedEvents[$validatedIndex].evidence = @(
            "artifact:$($source.result)",
            "test:combined-lifecycle-$($source.id)",
            "source:combined-lifecycle-$($source.id)",
            "observation:combined-lifecycle-$($source.id)"
        )
        $combinedEvents[$adoptedIndex].evidence = @(
            "artifact:$($source.disposition)",
            "observation:combined-adopted-$($source.id)"
        )
    }
    for ($eventIndex = 0; $eventIndex -lt $combinedEvents.Count; $eventIndex++) {
        $combinedEvents[$eventIndex].prev_hash = if ($eventIndex -eq 0) {
            $null
        } else { [string]$combinedEvents[$eventIndex - 1].hash }
        $combinedEvents[$eventIndex].hash = Get-OrchestrationEventHash (
            [pscustomobject]$combinedEvents[$eventIndex]
        )
    }
    @($combinedEvents | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $combinedEventsPath
    $combinedLifecycleCorrection = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1') `
        -RunDirectory $combinedCumulativeRun `
        -AuthorizationReceiptPath $combinedAuthorizationPath `
        -SelectionMaterialPath $combinedSelectionPath `
        -AuthorizationMaterialPath $combinedAuthorizationMaterial `
            -CorrectionKey 'controller:revision-1-combined-lifecycle-correction' |
        ConvertFrom-Json -Depth 100
    $combinedSupersession = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionCumulativeCorrectionReceipt.ps1') `
        -RunDirectory $combinedCumulativeRun `
        -AuthorizationReceiptPath $combinedAuthorizationPath `
        -SelectionMaterialPath $combinedSelectionPath `
        -AuthorizationMaterialPath $combinedAuthorizationMaterial `
        -CumulativeCorrectionKey 'controller:revision-1-combined-supersession' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$combinedSupersession.schema_version -eq '1.0' -and
        @($combinedSupersession.cumulative_correction_sources).Count -eq 2 -and
        (@($combinedSupersession.cumulative_correction_sources |
            ForEach-Object { [int]$_.restored_occurrence_count }) |
            Measure-Object -Sum).Sum -eq 1 -and
        $combinedEventsBefore.Count + 2 -eq @(
            Read-OrchestrationJournal $combinedEventsPath
        ).Count
    ) 'Lifecycle correction plus cumulative supersession must restore one exact occurrence.'
    Assert-True (
        (Get-FileHash -LiteralPath $combinedResultPath -Algorithm SHA256).Hash -eq
            $combinedOldResultHash -and
        (Get-FileHash -LiteralPath $combinedDispositionPath -Algorithm SHA256).Hash -eq
            $combinedOldDispositionHash -and
        $combinedPrefixHash -ne (Get-FileHash -LiteralPath $combinedEventsPath `
            -Algorithm SHA256).Hash
    ) 'Combined supersession must preserve current receipts and append one event.'
    $combinedSupersessionEvent = @(
        Read-OrchestrationJournal $combinedEventsPath | Where-Object {
            [string]$_.event -eq 'milestone-revision-cumulative-corrected'
        }
    )
    Assert-True (
        $combinedSupersessionEvent.Count -eq 1 -and
        $null -eq $combinedSupersessionEvent[0].node_id -and
        [string]$combinedSupersessionEvent[0].status -eq 'planned'
    ) 'Combined supersession must remain non-state.'
    $combinedSelectionPathEffective = Join-Path $combinedCumulativeRun `
        ([string]$combinedSupersession.effective_selection_material_path)
    $combinedSelection = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1') `
        -RunDirectory $combinedCumulativeRun `
        -AuthorizationReceiptPath $combinedAuthorizationPath `
        -SelectionMaterialPath $combinedSelectionPathEffective `
        -SelectionKey $authorizedSelectionKey |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$combinedSelection.schema_version -eq '1.6' -and
        [string]$combinedSelection.lifecycle_correction_receipt_hash -eq
            [string]$combinedLifecycleCorrection.receipt_hash -and
        [string]$combinedSelection.cumulative_correction_receipt_hash -eq
            [string]$combinedSupersession.receipt_hash
    ) 'Combined selection must bind both correction receipts.'
    $combinedBlocked = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $combinedCumulativeRun | Out-Null
    } catch { $combinedBlocked = $true }
    Assert-True $combinedBlocked (
        'Combined correction and supersession must not satisfy main acceptance.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot `
            'New-DurableReviewMilestoneRevisionCumulativeCorrectionReceipt.ps1') `
            -RunDirectory $combinedCumulativeRun `
            -AuthorizationReceiptPath $combinedAuthorizationPath `
            -SelectionMaterialPath $combinedSelectionPath `
            -AuthorizationMaterialPath $combinedAuthorizationMaterial `
            -CumulativeCorrectionKey 'controller:revision-1-combined-replay' |
            Out-Null
    } 'unsuperseded authorization' 'A combined cumulative supersession cannot be replayed.'
    $noLifecycleRun = Join-Path $testRoot 'cumulative-without-lifecycle-correction'
    Copy-Item -LiteralPath $revisionRun -Destination $noLifecycleRun -Recurse
    $noLifecycleBefore = (Get-FileHash -LiteralPath (
        Join-Path $noLifecycleRun 'events.jsonl'
    ) -Algorithm SHA256).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot `
            'New-DurableReviewMilestoneRevisionCumulativeCorrectionReceipt.ps1') `
            -RunDirectory $noLifecycleRun `
            -AuthorizationReceiptPath (Join-Path $noLifecycleRun `
                $revisionAuthorizationRelative) `
            -SelectionMaterialPath (Join-Path $noLifecycleRun `
                'materials/method-1-revision-1-selection.json') `
            -AuthorizationMaterialPath (Join-Path $noLifecycleRun `
                'materials/method-1-revision-1-controller-authorization.md') `
            -CumulativeCorrectionKey 'controller:combined-without-lifecycle' |
            Out-Null
    } 'exact lifecycle correction' (
        'Combined supersession must require the exact lifecycle correction.'
    )
    Assert-True (
        $noLifecycleBefore -eq (Get-FileHash -LiteralPath (
            Join-Path $noLifecycleRun 'events.jsonl'
        ) -Algorithm SHA256).Hash
    ) 'A missing lifecycle correction must fail before journal write.'
    $combinedMutationRun = Join-Path $testRoot `
        'combined-supersession-restored-text-mutation'
    Copy-Item -LiteralPath $combinedCumulativeRun `
        -Destination $combinedMutationRun -Recurse
    $combinedMutationEventsPath = Join-Path $combinedMutationRun 'events.jsonl'
    $combinedMutationEvents = @(Read-OrchestrationJournal $combinedMutationEventsPath)
    if ([string]$combinedMutationEvents[-1].event -eq
        'milestone-revision-selected') {
        $selectionReceiptRelative = [string]$combinedMutationEvents[-1].
            milestone_activation_receipt_path
        $selectionReceiptPath = Join-Path $combinedMutationRun `
            $selectionReceiptRelative
        if (Test-Path -LiteralPath $selectionReceiptPath -PathType Leaf) {
            Remove-Item -LiteralPath $selectionReceiptPath -Force
        }
        $combinedMutationEvents = @(
            $combinedMutationEvents | Select-Object -SkipLast 1
        )
        @($combinedMutationEvents | ForEach-Object {
            $_ | ConvertTo-Json -Compress -Depth 100
        }) | Set-Content -LiteralPath $combinedMutationEventsPath
    }
    $combinedMutationReceipt = @(
        Get-ChildItem -LiteralPath (Join-Path $combinedMutationRun 'receipts') `
            -File -Filter '*.cumulative-correction.json'
    )[0].FullName
    Resign-RevisionInventorySupersessionTail -Run $combinedMutationRun `
        -ReceiptMutation {
            param($receipt)
            $restored = @($receipt.cumulative_correction_sources | Where-Object {
                [int]$_.restored_occurrence_count -gt 0
            })[0]
            $restored.restored_occurrences[0].pending_finding.text =
                'forged combined occurrence text'
        }
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionCumulativeCorrection `
            -Path $combinedMutationReceipt -RunDirectory $combinedMutationRun |
            Out-Null
    } 'changed finding status, evidence, or effective artifacts' (
        'A re-signed combined supersession with changed restored text must fail closed.'
    )

    $partialCorrectionRun = Join-Path $testRoot (
        'revision-lifecycle-correction-partial-source'
    )
    Copy-Item -LiteralPath $evidenceCorrectionBeforeRun `
        -Destination $partialCorrectionRun -Recurse
    $partialSelectionPath = Join-Path $partialCorrectionRun (
        'materials/method-1-revision-1-selection.json'
    )
    $partialSelection = @(
        Get-Content -LiteralPath $partialSelectionPath -Raw |
            ConvertFrom-Json -Depth 100
    )
    @($partialSelection | Select-Object -First 1) |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $partialSelectionPath
    $partialJournalHash = (
        Get-FileHash -LiteralPath (
            Join-Path $partialCorrectionRun 'events.jsonl'
        ) -Algorithm SHA256
    ).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
        )) -RunDirectory $partialCorrectionRun `
            -AuthorizationReceiptPath (
                Join-Path $partialCorrectionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $partialSelectionPath `
            -AuthorizationMaterialPath (
                Join-Path $partialCorrectionRun (
                    'materials/revision-lifecycle-correction-authorization.md'
                )
            ) -CorrectionKey 'controller:partial-lifecycle-correction' |
            Out-Null
    } 'source set is incomplete' (
        'A lifecycle correction must include every required source.'
    )
    Assert-True (
        $partialJournalHash -eq (
            Get-FileHash -LiteralPath (
                Join-Path $partialCorrectionRun 'events.jsonl'
            ) -Algorithm SHA256
        ).Hash
    ) 'A rejected partial correction must not mutate the journal.'

    $otherShapeRun = Join-Path $testRoot (
        'revision-lifecycle-correction-other-error-shape'
    )
    Copy-Item -LiteralPath $evidenceCorrectionBeforeRun `
        -Destination $otherShapeRun -Recurse
    $otherShapeEventsPath = Join-Path $otherShapeRun 'events.jsonl'
    $otherShapeEvents = @(
        Get-Content -LiteralPath $otherShapeEventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    $otherShapeIndex = [Array]::FindLastIndex(
        [object[]]$otherShapeEvents,
        [Predicate[object]]{
            param($event)
            [string]$event.node_id -eq 'review' -and
            [string]$event.status -eq 'adopted'
        }
    )
    $otherShapeEvents[$otherShapeIndex].evidence = @(
        "artifact:$($revisionReview.result_path)"
    )
    for ($eventIndex = 0; $eventIndex -lt $otherShapeEvents.Count;
        $eventIndex++) {
        $otherShapeEvents[$eventIndex].prev_hash = if ($eventIndex -eq 0) {
            $null
        } else { [string]$otherShapeEvents[$eventIndex - 1].hash }
        $otherShapeEvents[$eventIndex].Remove('hash')
        $otherShapeEvents[$eventIndex].hash = Get-OrchestrationEventHash (
            [pscustomobject]$otherShapeEvents[$eventIndex]
        )
    }
    @($otherShapeEvents | ForEach-Object {
        [pscustomobject]$_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $otherShapeEventsPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
        )) -RunDirectory $otherShapeRun `
            -AuthorizationReceiptPath (
                Join-Path $otherShapeRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath (
                Join-Path $otherShapeRun (
                    'materials/method-1-revision-1-selection.json'
                )
            ) -AuthorizationMaterialPath (
                Join-Path $otherShapeRun (
                    'materials/revision-lifecycle-correction-authorization.md'
                )
            ) -CorrectionKey 'controller:reject-other-error-shape' |
            Out-Null
    } 'exact validated-result-pointer error shape' (
        'The correction cannot repair a wrong adopted evidence pointer.'
    )

    foreach ($mutation in @(
        @{
            name = 'partial-receipt'
            expected = 'source set is incomplete'
            action = {
                param($receipt)
                $receipt.source_corrections =
                    @($receipt.source_corrections | Select-Object -First 1)
            }
        },
        @{
            name = 'cross-source'
            expected = 'missing or repeated'
            action = {
                param($receipt)
                $receipt.source_corrections[0].source_node_id = 'review'
            }
        },
        @{
            name = 'cross-thread'
            expected = 'binding changed'
            action = {
                param($receipt)
                $receipt.source_corrections[0].source_thread_id =
                    'another-thread'
            }
        },
        @{
            name = 'cross-role'
            expected = 'binding changed'
            action = {
                param($receipt)
                $receipt.source_corrections[0].role_id = 'another-role'
            }
        },
        @{
            name = 'cross-run'
            expected = 'binding is invalid'
            action = {
                param($receipt)
                $receipt.run_id = 'another-run'
            }
        },
        @{
            name = 'cross-revision'
            expected = 'binding is invalid'
            action = {
                param($receipt)
                $receipt.revision_id = 'another-revision'
            }
        },
        @{
            name = 'cross-checkpoint'
            expected = 'binding is invalid'
            action = {
                param($receipt)
                $receipt.checkpoint_material_hash = ('0' * 64)
            }
        },
        @{
            name = 'cross-input'
            expected = 'binding is invalid'
            action = {
                param($receipt)
                $receipt.input_manifest_hash = ('1' * 64)
            }
        },
        @{
            name = 'selection-key'
            expected = 'binding is invalid'
            action = {
                param($receipt)
                $receipt.selection_key =
                    'controller:milestone-revision-selection:another-revision'
            }
        }
    )) {
        $mutationRun = Join-Path $testRoot (
            "revision-lifecycle-correction-$($mutation.name)"
        )
        Copy-Item -LiteralPath $evidenceCorrectionPendingRun `
            -Destination $mutationRun -Recurse
        Resign-RevisionLifecycleCorrectionTail -Run $mutationRun `
            -ReceiptMutation $mutation.action
        $mutationReceiptPath = @(
            Get-ChildItem -LiteralPath (Join-Path $mutationRun 'receipts') -File |
                Where-Object {
                    $_.Name -like '*.lifecycle-correction.json'
                }
        )[0].FullName
        Assert-ThrowsLike {
            Read-DurableReviewMilestoneRevisionLifecycleCorrection `
                -Path $mutationReceiptPath -RunDirectory $mutationRun |
                Out-Null
        } $mutation.expected (
            "A $($mutation.name) correction mutation must fail closed."
        )
    }

    $artifactDriftRun = Join-Path $testRoot (
        'revision-lifecycle-correction-artifact-drift'
    )
    Copy-Item -LiteralPath $evidenceCorrectionPendingRun `
        -Destination $artifactDriftRun -Recurse
    Add-Content -LiteralPath (
        Join-Path $artifactDriftRun $revisionReview.disposition_path
    ) -Value ' '
    $artifactDriftReceipt = @(
        Get-ChildItem -LiteralPath (Join-Path $artifactDriftRun 'receipts') -File |
            Where-Object {
                $_.Name -like '*.lifecycle-correction.json'
            }
    )[0].FullName
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionLifecycleCorrection `
            -Path $artifactDriftReceipt -RunDirectory $artifactDriftRun |
            Out-Null
    } 'binding changed' (
        'Selected result and disposition file hashes must remain immutable.'
    )

    $preboundSelectionJournalHash = (
        Get-FileHash -LiteralPath (Join-Path $revisionRun 'events.jsonl') `
            -Algorithm SHA256
    ).Hash
    foreach ($wrongSelectionKey in @(
        (
            'controller:' +
            $authorizedSelectionKey.Substring(11).ToUpperInvariant()
        ),
        $authorizedSelectionKey.Replace('controller:', 'user:'),
        ($authorizedSelectionKey + ':other-revision')
    )) {
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
            )) -RunDirectory $revisionRun `
                -AuthorizationReceiptPath (
                    Join-Path $revisionRun $revisionAuthorizationRelative
                ) -SelectionMaterialPath $revisionSelectionMaterial `
                -SelectionKey $wrongSelectionKey | Out-Null
        } 'does not match its authorization' (
            'A revision selection cannot replace its pre-bound selection key.'
        )
        Assert-True (
            $preboundSelectionJournalHash -eq (
                Get-FileHash -LiteralPath (
                    Join-Path $revisionRun 'events.jsonl'
                ) -Algorithm SHA256
            ).Hash
        ) 'Rejected selection-key variants must not mutate the journal.'
    }
    $revisionSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $revisionRun `
        -AuthorizationReceiptPath (
            Join-Path $revisionRun $revisionAuthorizationRelative
        ) -SelectionMaterialPath $revisionSelectionMaterial `
        -SelectionKey $authorizedSelectionKey |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$revisionSelection.schema_version -eq '1.1' -and
        @($revisionSelection.source_bindings).Count -eq 2
    ) 'A revision selection must bind both fresh source lifecycles.'

    # The revision-authorized original may exhaust its exact 3/3 recovery
    # cycle. One same-role replacement may then supply the selected result,
    # while the authorization and fresh re-arm stay bound to the original.
    $replacementRevisionRun = Join-Path $testRoot (
        'first-milestone-revision-replacement'
    )
    Copy-Item -LiteralPath $revisionAuthorizedRun `
        -Destination $replacementRevisionRun -Recurse
    $replacementCheckpoint = Join-Path $replacementRevisionRun (
        'materials/checkpoint-method-1-revision-1.json'
    )
    $replacementInput = Join-Path $replacementRevisionRun (
        'materials/input-method-1-revision-1.json'
    )
    $replacementAuthorizationPath = Join-Path $replacementRevisionRun (
        $revisionAuthorizationRelative
    )
    foreach ($source in @(
        @{ id = 'review'; thread = 'review-thread' },
        @{ id = 'domain'; thread = 'domain-thread' }
    )) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $replacementRevisionRun -NodeId $source.id `
            -Status running -ThreadId $source.thread `
            -Message "Fresh replacement-case review for $($source.id)." `
            -Evidence @("artifact:$revisionAuthorizationRelative") `
            -MilestoneRevisionAuthorizationReceiptPath (
                $revisionAuthorizationRelative
            ) -IdempotencyKey "replacement-case-rearm-$($source.id)" |
            Out-Null
    }
    $replacementRecoveryPaths = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $progressPath = Join-Path $replacementRevisionRun (
            "thread-reads/review-replacement-progress-$attempt.json"
        )
        New-ProgressCapture -Path $progressPath -ThreadId 'review-thread' `
            -TurnId "review-replacement-progress-$attempt"
        $recovery = & (Join-Path $scriptRoot (
            'New-ThreadResultRecoveryReceipt.ps1'
        )) -RunDirectory $replacementRevisionRun -SourceNodeId 'review' `
            -OriginalThreadId 'review-thread' `
            -CheckpointManifestPath $replacementCheckpoint `
            -InputManifestPath $replacementInput -ThreadReadPath $progressPath `
            -MilestoneId 'method-1' -Attempt $attempt |
            ConvertFrom-Json -Depth 100
        $recoveryPath = Join-Path $replacementRevisionRun (
            "receipts/review.cycle-$($recovery.recovery_cycle_id)." +
            "attempt-$attempt.result-recovery.json"
        )
        $replacementRecoveryPaths.Add($recoveryPath)
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $replacementRevisionRun -NodeId 'review' `
            -Status result_pending -ThreadId 'review-thread' `
            -Message "Replacement-case final missing attempt $attempt." `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath ([IO.Path]::GetRelativePath(
                $replacementRevisionRun, $recoveryPath
            )) -IdempotencyKey "replacement-case-pending-$attempt" |
            Out-Null
        if ($attempt -lt 3) {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $replacementRevisionRun -NodeId 'review' `
                -Status running -ThreadId 'review-thread' `
                -Message "Replacement-case retry $($attempt + 1)." `
                -IdempotencyKey "replacement-case-retry-$attempt" |
                Out-Null
        }
    }
    $replacementControllerMaterial = Join-Path $replacementRevisionRun (
        'materials/review-replacement-controller-authorization.md'
    )
    Set-Content -LiteralPath $replacementControllerMaterial -Value (
        'Controller authorizes one same-role replacement after exact 3/3.'
    )
    $replacementContinuityPath = Join-Path $replacementRevisionRun (
        'receipts/review.replacement-continuity.json'
    )
    $replacementContinuity = & (Join-Path $scriptRoot (
        'New-ReplacementContinuityReceipt.ps1'
    )) -RunDirectory $replacementRevisionRun -SourceNodeId 'review' `
        -OriginalThreadId 'review-thread' `
        -ReplacementThreadId 'review-replacement-thread' `
        -CheckpointManifestPath $replacementCheckpoint `
        -InputManifestPath $replacementInput `
        -RecoveryReceiptPaths @($replacementRecoveryPaths) `
        -AuthorizationMaterialPath $replacementControllerMaterial `
        -ActivationKey 'controller:revision-review-replacement' `
        -OutputPath $replacementContinuityPath |
        ConvertFrom-Json -Depth 100
    $replacementContinuityRelative = [IO.Path]::GetRelativePath(
        $replacementRevisionRun, $replacementContinuityPath
    ).Replace('\', '/')
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $replacementRevisionRun -NodeId 'review' `
        -Status replacement_pending -ThreadId 'review-replacement-thread' `
        -Message 'Revision review replacement materialized.' `
        -ReplacementContinuityReceiptPath $replacementContinuityRelative `
        -IdempotencyKey 'revision-review-replacement-pending' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $replacementRevisionRun -NodeId 'review' `
        -Status running -ThreadId 'review-replacement-thread' `
        -Message 'Revision review replacement running.' `
        -Evidence @(
            "artifact:replacement-continuity:$replacementContinuityRelative",
            (
                'observation:replacement-continuity-hash:' +
                [string]$replacementContinuity.receipt_hash
            )
        ) `
        -IdempotencyKey 'revision-review-replacement-running' | Out-Null

    $replacementReview = New-SourceChain -Run $replacementRevisionRun `
        -SourceNodeId 'review' -ThreadId 'review-replacement-thread' `
        -MilestoneId 'method-1' -CheckpointPath $replacementCheckpoint `
        -Stem 'review.method-1-revision-1-replacement' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'resolved' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding' `
        -ReplacementContinuityReceiptPath $replacementContinuityPath
    $replacementDomain = New-SourceChain -Run $replacementRevisionRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-1' -CheckpointPath $replacementCheckpoint `
        -Stem 'domain.method-1-revision-1-replacement' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'resolved' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    foreach ($source in @(
        @{
            id = 'review'; thread = 'review-replacement-thread'
            result = $replacementReview.result_path
            disposition = $replacementReview.disposition_path
        },
        @{
            id = 'domain'; thread = 'domain-thread'
            result = $replacementDomain.result_path
            disposition = $replacementDomain.disposition_path
        }
    )) {
        foreach ($status in @('completed', 'validated', 'adopted')) {
            $pointer = if ($status -eq 'completed') {
                "artifact:$($source.result)"
            } else { "artifact:$($source.disposition)" }
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $replacementRevisionRun -NodeId $source.id `
                -Status $status -ThreadId $source.thread `
                -Message "Replacement revision $($source.id) $status." `
                -Evidence @($pointer) `
                -IdempotencyKey "replacement-revision-$($source.id)-$status" |
                Out-Null
        }
    }
    $replacementSelectionMaterial = Join-Path $replacementRevisionRun (
        'materials/method-1-revision-1-replacement-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $replacementReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $replacementDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $replacementSelectionMaterial
    $replacementReadyRun = Join-Path $testRoot (
        'first-milestone-revision-replacement-ready'
    )
    Copy-Item -LiteralPath $replacementRevisionRun `
        -Destination $replacementReadyRun -Recurse

    # A legitimate same-revision replacement can need the narrow validated
    # evidence correction. The correction still has to cover every source and
    # the replacement must retain its full continuity/recovery/re-arm chain.
    $replacementCorrectionRun = Join-Path $testRoot (
        'first-milestone-revision-replacement-lifecycle-correction'
    )
    Copy-Item -LiteralPath $replacementReadyRun `
        -Destination $replacementCorrectionRun -Recurse
    $replacementCorrectionEventsPath = Join-Path $replacementCorrectionRun (
        'events.jsonl'
    )
    $replacementCorrectionEvents = @(
        Get-Content -LiteralPath $replacementCorrectionEventsPath |
            ForEach-Object {
                $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            }
    )
    foreach ($source in @(
        @{ id = 'review'; result = $replacementReview.result_path },
        @{ id = 'domain'; result = $replacementDomain.result_path }
    )) {
        $validatedIndex = [Array]::FindLastIndex(
            [object[]]$replacementCorrectionEvents,
            [Predicate[object]]{
                param($event)
                [string]$event.node_id -eq [string]$source.id -and
                [string]$event.status -eq 'validated'
            }
        )
        Assert-True ($validatedIndex -ge 0) (
            "The replacement correction fixture needs '$($source.id)' validated."
        )
        $replacementCorrectionEvents[$validatedIndex].evidence = @(
            "artifact:$($source.result)"
        )
    }
    for ($eventIndex = 0; $eventIndex -lt $replacementCorrectionEvents.Count;
        $eventIndex++) {
        $replacementCorrectionEvents[$eventIndex].prev_hash = if (
            $eventIndex -eq 0
        ) { $null } else {
            [string]$replacementCorrectionEvents[$eventIndex - 1].hash
        }
        $replacementCorrectionEvents[$eventIndex].Remove('hash')
        $replacementCorrectionEvents[$eventIndex].hash =
            Get-OrchestrationEventHash (
                [pscustomobject]$replacementCorrectionEvents[$eventIndex]
            )
    }
    @($replacementCorrectionEvents | ForEach-Object {
        $_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $replacementCorrectionEventsPath
    $replacementCorrectionJournalHash = (
        Get-FileHash -LiteralPath $replacementCorrectionEventsPath `
            -Algorithm SHA256
    ).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $replacementCorrectionRun `
            -AuthorizationReceiptPath (
                Join-Path $replacementCorrectionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath (
                Join-Path $replacementCorrectionRun (
                    'materials/method-1-revision-1-replacement-selection.json'
                )
            ) -SelectionKey $authorizedSelectionKey | Out-Null
    } 'lifecycle does not bind' (
        'A replacement selection still requires the whole-source correction.'
    )
    Assert-True (
        $replacementCorrectionJournalHash -eq (
            Get-FileHash -LiteralPath $replacementCorrectionEventsPath `
                -Algorithm SHA256
        ).Hash
    ) 'A rejected pre-correction replacement selection must not mutate the journal.'
    $replacementCorrectionAuthorization = Join-Path $replacementCorrectionRun (
        'materials/replacement-lifecycle-correction-authorization.md'
    )
    Set-Content -LiteralPath $replacementCorrectionAuthorization -Value (
        'Controller authorizes only the whole-source validated evidence correction.'
    )
    $replacementCorrection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionLifecycleCorrectionReceipt.ps1'
    )) -RunDirectory $replacementCorrectionRun `
        -AuthorizationReceiptPath (
            Join-Path $replacementCorrectionRun $revisionAuthorizationRelative
        ) -SelectionMaterialPath (
            Join-Path $replacementCorrectionRun (
                'materials/method-1-revision-1-replacement-selection.json'
            )
        ) -AuthorizationMaterialPath $replacementCorrectionAuthorization `
        -CorrectionKey 'controller:replacement-lifecycle-correction' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        @($replacementCorrection.source_corrections).Count -eq 2 -and
        [string](@($replacementCorrection.source_corrections | Where-Object {
            [string]$_.source_node_id -eq 'review'
        })[0].source_thread_id) -eq 'review-replacement-thread'
    ) 'A replacement correction must bind the selected replacement thread.'
    $replacementCorrectionPendingRun = Join-Path $testRoot (
        'first-milestone-revision-replacement-corrected-pending-selection'
    )
    Copy-Item -LiteralPath $replacementCorrectionRun `
        -Destination $replacementCorrectionPendingRun -Recurse
    $replacementCorrectionPreSelectionEvents = @(
        Read-OrchestrationJournal (
            Join-Path $replacementCorrectionRun 'events.jsonl'
        )
    )
    $replacementCorrectionSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $replacementCorrectionRun `
        -AuthorizationReceiptPath (
            Join-Path $replacementCorrectionRun $revisionAuthorizationRelative
        ) -SelectionMaterialPath (
            Join-Path $replacementCorrectionRun (
                'materials/method-1-revision-1-replacement-selection.json'
            )
        ) -SelectionKey $authorizedSelectionKey |
        ConvertFrom-Json -Depth 100
    $replacementCorrectionLifecycle = @(
        $replacementCorrectionSelection.source_lifecycle_bindings | Where-Object {
            [string]$_.source_node_id -eq 'review'
        }
    )[0]
    Assert-True (
        [string]$replacementCorrectionSelection.schema_version -eq '1.5' -and
        [string]$replacementCorrectionSelection.
            lifecycle_correction_receipt_hash -eq
            [string]$replacementCorrection.receipt_hash -and
        [string]$replacementCorrectionLifecycle.source_kind -eq 'replacement' -and
        [string]$replacementCorrectionLifecycle.source_thread_id -eq
            'review-replacement-thread' -and
        @($replacementCorrectionLifecycle.recovery_event_bindings).Count -eq 3 -and
        [int]$replacementCorrectionLifecycle.replacement_running_event_sequence -gt
            [int]$replacementCorrectionLifecycle.
                replacement_pending_event_sequence -and
        @(Read-OrchestrationJournal (
            Join-Path $replacementCorrectionRun 'events.jsonl'
        )).Count -eq ($replacementCorrectionPreSelectionEvents.Count + 1)
    ) (
        'One schema 1.5 selection must bind the complete correction and the ' +
        'same replacement continuity chain.'
    )
    $replacementCorrectionSelectionPath = Join-Path $replacementCorrectionRun (
        "receipts/durable-review-milestone.method-1.revision-" +
        "$($revisionAuthorization.revision_id).selection.json"
    )
    $replacementCorrectionReadback =
        Read-DurableReviewMilestoneRevisionSelection `
            -Path $replacementCorrectionSelectionPath `
            -RunDirectory $replacementCorrectionRun
    Assert-True (
        [string]$replacementCorrectionReadback.receipt_hash -eq
            [string]$replacementCorrectionSelection.receipt_hash
    ) 'A schema 1.5 replacement correction selection must read back.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $replacementCorrectionRun `
            -AuthorizationReceiptPath (
                Join-Path $replacementCorrectionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath (
                Join-Path $replacementCorrectionRun (
                    'materials/method-1-revision-1-replacement-selection.json'
                )
            ) -SelectionKey $authorizedSelectionKey | Out-Null
    } 'already selected' (
        'A corrected replacement revision cannot create a duplicate selection.'
    )

    foreach ($correctionAttack in @(
        @{
            name = 'partial-source-set'
            expected = 'source set is incomplete'
            mutate = {
                param($receipt)
                $receipt.source_corrections = @(
                    $receipt.source_corrections | Select-Object -First 1
                )
            }
        },
        @{
            name = 'cross-thread'
            expected = 'lifecycle correction source'
            mutate = {
                param($receipt)
                @($receipt.source_corrections | Where-Object {
                    [string]$_.source_node_id -eq 'review'
                })[0].source_thread_id = 'domain-thread'
            }
        },
        @{
            name = 'completed-hash'
            expected = 'lifecycle correction source'
            mutate = {
                param($receipt)
                @($receipt.source_corrections | Where-Object {
                    [string]$_.source_node_id -eq 'review'
                })[0].completed_event_hash = ('0' * 64)
            }
        }
    )) {
        $correctionAttackRun = Join-Path $testRoot (
            "revision-replacement-correction-$($correctionAttack.name)"
        )
        Copy-Item -LiteralPath $replacementCorrectionPendingRun `
            -Destination $correctionAttackRun -Recurse
        Resign-RevisionLifecycleCorrectionTail -Run $correctionAttackRun `
            -ReceiptMutation $correctionAttack.mutate
        $correctionAttackJournal = Join-Path $correctionAttackRun 'events.jsonl'
        $correctionAttackJournalHash = (
            Get-FileHash -LiteralPath $correctionAttackJournal -Algorithm SHA256
        ).Hash
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
            )) -RunDirectory $correctionAttackRun `
                -AuthorizationReceiptPath (
                    Join-Path $correctionAttackRun $revisionAuthorizationRelative
                ) -SelectionMaterialPath (
                    Join-Path $correctionAttackRun (
                        'materials/method-1-revision-1-replacement-selection.json'
                    )
                ) -SelectionKey $authorizedSelectionKey | Out-Null
        } ([string]$correctionAttack.expected) (
            "A $($correctionAttack.name) replacement correction must fail closed."
        )
        Assert-True (
            $correctionAttackJournalHash -eq (
                Get-FileHash -LiteralPath $correctionAttackJournal `
                    -Algorithm SHA256
            ).Hash
        ) (
            "A rejected $($correctionAttack.name) replacement correction " +
            'must not mutate the journal.'
        )
    }
    $replacementPreSelectionEvents = @(
        Read-OrchestrationJournal (
            Join-Path $replacementRevisionRun 'events.jsonl'
        )
    )
    $replacementSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $replacementRevisionRun `
        -AuthorizationReceiptPath $replacementAuthorizationPath `
        -SelectionMaterialPath $replacementSelectionMaterial `
        -SelectionKey $authorizedSelectionKey |
        ConvertFrom-Json -Depth 100
    $replacementLifecycle = @(
        $replacementSelection.source_lifecycle_bindings | Where-Object {
            [string]$_.source_node_id -eq 'review'
        }
    )[0]
    Assert-True (
        [string]$replacementSelection.schema_version -eq '1.3' -and
        [string]$replacementLifecycle.source_kind -eq 'replacement' -and
        [string]$replacementLifecycle.authorized_thread_id -eq
            'review-thread' -and
        [string]$replacementLifecycle.source_thread_id -eq
            'review-replacement-thread' -and
        @($replacementLifecycle.recovery_event_bindings).Count -eq 3 -and
        [int]$replacementLifecycle.replacement_pending_event_sequence -gt 0 -and
        [int]$replacementLifecycle.replacement_running_event_sequence -gt
            [int]$replacementLifecycle.replacement_pending_event_sequence
    ) (
        'A revision selection must bind the authorized original, its exact ' +
        '3/3 recovery, and the one same-role replacement lifecycle.'
    )
    $replacementSelectionPath = Join-Path $replacementRevisionRun (
        "receipts/durable-review-milestone.method-1.revision-" +
        "$($revisionAuthorization.revision_id).selection.json"
    )
    $replacementReadback = Read-DurableReviewMilestoneRevisionSelection `
        -Path $replacementSelectionPath -RunDirectory $replacementRevisionRun
    Assert-True (
        [string]$replacementReadback.receipt_hash -eq
            [string]$replacementSelection.receipt_hash -and
        @(Read-OrchestrationJournal (
            Join-Path $replacementRevisionRun 'events.jsonl'
        )).Count -eq ($replacementPreSelectionEvents.Count + 1)
    ) 'The replacement selection must read back and append exactly one event.'

    foreach ($resultCompatibilityCase in @('property-order', 'extension-field')) {
        $compatibilityRun = Join-Path $testRoot (
            "revision-replacement-result-$resultCompatibilityCase"
        )
        Copy-Item -LiteralPath $replacementReadyRun `
            -Destination $compatibilityRun -Recurse
        $compatibilityResultPath = Join-Path $compatibilityRun (
            [string]$replacementReview.result_path
        )
        $compatibilityResult = Get-Content -LiteralPath (
            $compatibilityResultPath
        ) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
        if ($resultCompatibilityCase -eq 'property-order') {
            $propertyNames = @(
                $compatibilityResult.PSObject.Properties.Name
            )
            [array]::Reverse($propertyNames)
            $reorderedResult = [ordered]@{}
            foreach ($propertyName in $propertyNames) {
                $reorderedResult[$propertyName] =
                    $compatibilityResult.$propertyName
            }
            $compatibilityResult = [pscustomobject]$reorderedResult
        } else {
            $compatibilityResult | Add-Member -NotePropertyName (
                'compatible_extension'
            ) -NotePropertyValue 'ignored-by-schema-reader'
        }
        $compatibilityResult | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $compatibilityResultPath
        $compatibilityPlan = Get-Content -LiteralPath (
            Join-Path $compatibilityRun 'plan.json'
        ) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
        $compatibilityBinding = Get-DurableReviewDispositionBinding `
            -RunDirectory $compatibilityRun -Plan $compatibilityPlan `
            -SourceNodeId 'review' `
            -DispositionRelativePath $replacementReview.disposition_path `
            -ExpectedMilestoneId 'method-1' `
            -RequireResultMilestoneBinding
        Assert-True (
            [string]$compatibilityBinding.source_thread_id -eq
                'review-replacement-thread'
        ) (
            'Schema-aware result hashing must preserve compatibility for ' +
            "$resultCompatibilityCase without weakening disposition binding."
        )
    }

    foreach ($selectionAttack in @(
        @{
            name = 'authorized-thread-binding'
            mutate = {
                param($lifecycle)
                $lifecycle.authorized_thread_id = 'domain-thread'
            }
        },
        @{
            name = 'recovery-event-binding'
            mutate = {
                param($lifecycle)
                $lifecycle.recovery_event_bindings[0].result_pending_event_hash =
                    ('f' * 64)
            }
        }
    )) {
        $selectionAttackRun = Join-Path $testRoot (
            "revision-replacement-selection-$($selectionAttack.name)"
        )
        Copy-Item -LiteralPath $replacementRevisionRun `
            -Destination $selectionAttackRun -Recurse
        $selectionAttackPath = Join-Path $selectionAttackRun (
            "receipts/durable-review-milestone.method-1.revision-" +
            "$($revisionAuthorization.revision_id).selection.json"
        )
        $selectionAttackReceipt = Get-Content -LiteralPath (
            $selectionAttackPath
        ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $selectionAttackLifecycle = @(
            $selectionAttackReceipt.source_lifecycle_bindings |
                Where-Object { [string]$_.source_node_id -eq 'review' }
        )[0]
        & $selectionAttack.mutate $selectionAttackLifecycle
        $selectionAttackReceipt.source_lifecycle_bindings_hash =
            Get-TextSha256 (
                ConvertTo-Json -InputObject @(
                    $selectionAttackReceipt.source_lifecycle_bindings
                ) -Compress -Depth 100
            )
        $selectionAttackPayload = [ordered]@{}
        foreach ($key in $selectionAttackReceipt.Keys | Where-Object {
            $_ -ne 'receipt_hash'
        }) { $selectionAttackPayload[$key] = $selectionAttackReceipt[$key] }
        $selectionAttackReceipt.receipt_hash = Get-TextSha256 (
            $selectionAttackPayload | ConvertTo-Json -Compress -Depth 100
        )
        $selectionAttackReceipt | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $selectionAttackPath
        $selectionAttackEventsPath = Join-Path $selectionAttackRun (
            'events.jsonl'
        )
        $selectionAttackEvents = @(
            Get-Content -LiteralPath $selectionAttackEventsPath | ForEach-Object {
                $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            }
        )
        $selectionAttackEvent = $selectionAttackEvents[-1]
        $selectionAttackEvent.milestone_activation_receipt_hash =
            [string]$selectionAttackReceipt.receipt_hash
        $selectionAttackEvent.request_fingerprint =
            [string]$selectionAttackReceipt.receipt_hash
        $selectionAttackEvent.Remove('hash')
        $selectionAttackEvent.hash = Get-OrchestrationEventHash (
            [pscustomobject]$selectionAttackEvent
        )
        @($selectionAttackEvents | ForEach-Object {
            $_ | ConvertTo-Json -Compress -Depth 100
        }) | Set-Content -LiteralPath $selectionAttackEventsPath
        Assert-ThrowsLike {
            Read-DurableReviewMilestoneRevisionSelection `
                -Path $selectionAttackPath -RunDirectory $selectionAttackRun |
                Out-Null
        } 'lifecycle binding changed' (
            "A self-rehashed $($selectionAttack.name) mutation must fail closed."
        )
    }

    foreach ($attack in @(
        @{
            name = 'changed-original-thread'
            expected = 'does not match its source'
            mutate = {
                param($receipt)
                $receipt.original_thread_id = 'domain-thread'
            }
        },
        @{
            name = 'changed-checkpoint'
            expected = 'Checkpoint manifest is missing or changed'
            mutate = {
                param($receipt)
                $receipt.checkpoint_hash = ('0' * 64)
            }
        },
        @{
            name = 'replacement-of-replacement'
            expected = 'does not match its source'
            mutate = {
                param($receipt)
                $receipt.original_thread_id = 'review-replacement-thread'
                $receipt.replacement_thread_id = 'second-replacement-thread'
            }
        }
    )) {
        $attackRun = Join-Path $testRoot (
            "revision-replacement-$($attack.name)"
        )
        Copy-Item -LiteralPath $replacementReadyRun -Destination $attackRun `
            -Recurse
        $attackContinuityPath = Join-Path $attackRun (
            'receipts/review.replacement-continuity.json'
        )
        $attackContinuity = Get-Content -LiteralPath $attackContinuityPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $attack.mutate $attackContinuity
        $attackPayload = [ordered]@{}
        foreach ($key in $attackContinuity.Keys | Where-Object {
            $_ -ne 'receipt_hash'
        }) { $attackPayload[$key] = $attackContinuity[$key] }
        $attackContinuity.receipt_hash = Get-TextSha256 (
            $attackPayload | ConvertTo-Json -Compress -Depth 100
        )
        $attackContinuity | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $attackContinuityPath
        $attackJournal = Join-Path $attackRun 'events.jsonl'
        $beforeAttackHash = (
            Get-FileHash -LiteralPath $attackJournal -Algorithm SHA256
        ).Hash
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
            )) -RunDirectory $attackRun `
                -AuthorizationReceiptPath (
                    Join-Path $attackRun $revisionAuthorizationRelative
                ) -SelectionMaterialPath (
                    Join-Path $attackRun (
                        'materials/method-1-revision-1-replacement-selection.json'
                    )
                ) -SelectionKey $authorizedSelectionKey | Out-Null
        } ([string]$attack.expected) (
            "A $($attack.name) replacement continuity mutation must fail closed."
        )
        Assert-True (
            $beforeAttackHash -eq (
                Get-FileHash -LiteralPath $attackJournal -Algorithm SHA256
            ).Hash
        ) 'Rejected replacement continuity attacks must not mutate the journal.'
    }
    $laterLifecycleRun = Join-Path $testRoot (
        'revision-selection-with-later-source-lifecycle'
    )
    Copy-Item -LiteralPath $revisionRun -Destination $laterLifecycleRun -Recurse
    $laterEventsPath = Join-Path $laterLifecycleRun 'events.jsonl'
    $laterEvents = @(Read-OrchestrationJournal $laterEventsPath)
    $declaredReviewLifecycle = @(
        $revisionSelection.source_lifecycle_bindings | Where-Object {
            [string]$_.source_node_id -eq 'review'
        }
    )[0]
    foreach ($laterStatus in @('completed', 'validated', 'adopted')) {
        $templateSequence = switch ($laterStatus) {
            'completed' { [int]$declaredReviewLifecycle.completed_event_sequence }
            'validated' { [int]$declaredReviewLifecycle.validated_event_sequence }
            'adopted' { [int]$declaredReviewLifecycle.adopted_event_sequence }
        }
        $laterEvent = @(
            $laterEvents | Where-Object {
                [int]$_.sequence -eq $templateSequence
            }
        )[0] | ConvertTo-Json -Depth 30 |
            ConvertFrom-Json -AsHashtable -Depth 30
        $laterEvent.sequence = $laterEvents.Count
        $laterEvent.prev_hash = [string]$laterEvents[-1].hash
        $laterEvent.timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        $laterEvent.milestone_id = 'method-2'
        $laterEvent.message = "Later milestone review $laterStatus."
        $laterEvent.evidence = if ($laterStatus -eq 'completed') {
            @('artifact:receipts/review.method-2-later-result.json')
        } else {
            @('artifact:receipts/review.method-2-later-disposition.json')
        }
        $laterEvent.idempotency_key = "later-review-$laterStatus"
        $laterEvent.request_fingerprint = Get-TextSha256 (
            "later-review-$laterStatus"
        )
        $laterEvent.hash = Get-OrchestrationEventHash (
            [pscustomobject]$laterEvent
        )
        Add-Content -LiteralPath $laterEventsPath -Value (
            [pscustomobject]$laterEvent | ConvertTo-Json -Compress -Depth 30
        )
        $laterEvents += [pscustomobject]$laterEvent
    }
    $laterSelectionPath = Join-Path $laterLifecycleRun (
        "receipts/durable-review-milestone.method-1.revision-" +
        "$($revisionAuthorization.revision_id).selection.json"
    )
    $laterSelectionReadback =
        Read-DurableReviewMilestoneRevisionSelection `
            -Path $laterSelectionPath -RunDirectory $laterLifecycleRun
    $laterReviewLifecycle = @(
        $laterSelectionReadback.source_lifecycle_bindings | Where-Object {
            [string]$_.source_node_id -eq 'review'
        }
    )[0]
    Assert-True (
        [int]$laterReviewLifecycle.completed_event_sequence -eq
            [int]$declaredReviewLifecycle.completed_event_sequence -and
        [string]$laterReviewLifecycle.completed_event_hash -eq
            [string]$declaredReviewLifecycle.completed_event_hash -and
        [int]$laterReviewLifecycle.adopted_event_sequence -eq
            [int]$declaredReviewLifecycle.adopted_event_sequence -and
        [string]$laterReviewLifecycle.adopted_event_hash -eq
            [string]$declaredReviewLifecycle.adopted_event_hash
    ) (
        'A revision selection must revalidate its bound lifecycle events ' +
        'instead of later valid source events.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $revisionRun `
            -AuthorizationReceiptPath (
                Join-Path $revisionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $revisionSelectionMaterial `
            -SelectionKey $authorizedSelectionKey |
            Out-Null
    } 'already selected' 'A milestone revision cannot fork or select twice.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $revisionRun | Out-Null
    } 'lacks main-owner acceptance' (
        'Revision selection does not replace independent main acceptance.'
    )
    & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
    )) -RunDirectory $revisionRun -MilestoneId 'method-1' | Out-Null
    $revisionCompletion = & (
        Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1'
    ) -RunDirectory $revisionRun | ConvertFrom-Json -Depth 30
    Assert-True (
        $revisionCompletion.complete -and
        $revisionCompletion.active_review_milestone -eq 'method-1'
    ) 'A selected revision plus independent acceptance may complete method-1.'

    # A selected first-milestone revision may retain open P0/P1 occurrences.
    # Those blockers keep final acceptance closed, but must not deadlock a
    # later checkpoint revision of that same first milestone.
    $consecutiveRevisionRun = Join-Path $testRoot (
        'consecutive-first-milestone-revision'
    )
    Copy-Item -LiteralPath $revisionReadyRun `
        -Destination $consecutiveRevisionRun -Recurse
    foreach ($relativePath in @(
        $revisionReview.disposition_path,
        $revisionDomain.disposition_path
    )) {
        $dispositionPath = Join-Path $consecutiveRevisionRun $relativePath
        $disposition = Get-Content -LiteralPath $dispositionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($decision in @($disposition.decisions)) {
            $decision.resolution_status = 'open'
            $decision.re_review_status = 'requested'
            $decision.re_review_evidence = @()
        }
        $disposition.blocking_open = @(
            $disposition.decisions | ForEach-Object { [string]$_.finding }
        )
        $disposition.Remove('receipt_hash')
        $disposition.receipt_hash = Get-TextSha256 (
            $disposition | ConvertTo-Json -Compress -Depth 100
        )
        $disposition | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $dispositionPath -Encoding utf8
    }
    $consecutiveSelectionMaterial = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-1-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $revisionReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $revisionDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $consecutiveSelectionMaterial
    $consecutiveAuthorizationPath = Join-Path (
        $consecutiveRevisionRun
    ) $revisionAuthorizationRelative
    $consecutiveAuthorization =
        Read-DurableReviewMilestoneRevisionAuthorization `
            -Path $consecutiveAuthorizationPath `
            -RunDirectory $consecutiveRevisionRun
    $consecutiveSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $consecutiveRevisionRun `
        -AuthorizationReceiptPath $consecutiveAuthorizationPath `
        -SelectionMaterialPath $consecutiveSelectionMaterial `
        -SelectionKey ([string]$consecutiveAuthorization.selection_key) |
        ConvertFrom-Json -Depth 100
    $consecutiveSelectedRun = Join-Path $testRoot (
        'consecutive-first-milestone-selected'
    )
    Copy-Item -LiteralPath $consecutiveRevisionRun `
        -Destination $consecutiveSelectedRun -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
        )) -RunDirectory $consecutiveRevisionRun -MilestoneId 'method-1' |
            Out-Null
    } 'unresolved P0/P1' (
        'Open findings must still block final main-owner acceptance.'
    )

    $revision2Checkpoint = Join-Path $consecutiveRevisionRun (
        'materials/checkpoint-method-1-revision-2.json'
    )
    $revision2Input = Join-Path $consecutiveRevisionRun (
        'materials/input-method-1-revision-2.json'
    )
    $revision2ReviewPrompt = Join-Path $consecutiveRevisionRun (
        'materials/review-revision-2.md'
    )
    $revision2DomainPrompt = Join-Path $consecutiveRevisionRun (
        'materials/domain-revision-2.md'
    )
    $revision2ReviewManifest = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-review-materials.json'
    )
    $revision2ExcludedManifest = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-excluded-evidence.json'
    )
    $revision2AuthorizationMaterial = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-controller-authorization.md'
    )
    $revision2AcceptanceEvidence = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-main-acceptance.md'
    )
    $revision2AcceptanceAuthorization = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-acceptance-authorization.json'
    )
    Set-Content -LiteralPath $revision2Checkpoint `
        -Value '{"milestone":"method-1","revision":2}'
    Set-Content -LiteralPath $revision2Input `
        -Value '{"scope":"method-1-revision-2"}'
    Set-Content -LiteralPath $revision2ReviewPrompt `
        -Value 'Review revision two with all prior open occurrences.'
    Set-Content -LiteralPath $revision2DomainPrompt `
        -Value 'Audit revision two with all prior open occurrences.'
    @(
        [ordered]@{
            source_node_id = 'review'
            material_path = 'materials/review-revision-2.md'
        },
        [ordered]@{
            source_node_id = 'domain'
            material_path = 'materials/domain-revision-2.md'
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $revision2ReviewManifest
    ConvertTo-Json -InputObject @() |
        Set-Content -LiteralPath $revision2ExcludedManifest
    Set-Content -LiteralPath $revision2AuthorizationMaterial `
        -Value 'Controller authorizes the next checkpoint revision.'
    Set-Content -LiteralPath $revision2AcceptanceEvidence `
        -Value 'Main owner must independently accept revision two.'
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'method-1'
        main_node_id = 'integrate'
        acceptance_key = 'controller:method-1-revision-2-acceptance'
        evidence_material_path = [IO.Path]::GetRelativePath(
            $consecutiveRevisionRun, $revision2AcceptanceEvidence
        ).Replace('\', '/')
        evidence_material_hash = (
            Get-FileHash -LiteralPath $revision2AcceptanceEvidence `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $revision2AcceptanceAuthorization
    $revision2ReadyRun = Join-Path $testRoot (
        'consecutive-first-milestone-revision-2-ready'
    )
    Copy-Item -LiteralPath $consecutiveRevisionRun `
        -Destination $revision2ReadyRun -Recurse
    $beforeRevision2JournalHash = (
        Get-FileHash -LiteralPath (
            Join-Path $consecutiveRevisionRun 'events.jsonl'
        ) -Algorithm SHA256
    ).Hash
    $revision2Authorization = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
    )) -RunDirectory $consecutiveRevisionRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $revision2Checkpoint `
        -InputManifestPath $revision2Input `
        -ReviewMaterialManifestPath $revision2ReviewManifest `
        -ExcludedEvidenceManifestPath $revision2ExcludedManifest `
        -AuthorizationMaterialPath $revision2AuthorizationMaterial `
        -AcceptanceAuthorizationMaterialPath (
            $revision2AcceptanceAuthorization
        ) -SelectionKey 'controller:select-method-1-revision-2' `
        -ActivationKey 'controller:method-1-revision-2' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$revision2Authorization.schema_version -eq '1.1' -and
        [int]$revision2Authorization.revision_index -eq 2 -and
        [string]$revision2Authorization.
            previous_revision_selection_receipt_hash -eq
            [string]$consecutiveSelection.receipt_hash -and
        @($revision2Authorization.previous_open_occurrences).Count -eq 3
    ) (
        'A selected revision with open findings must authorize a bound next ' +
        'checkpoint revision without weakening final acceptance.'
    )
    Assert-True (
        $beforeRevision2JournalHash -ne (
            Get-FileHash -LiteralPath (
                Join-Path $consecutiveRevisionRun 'events.jsonl'
            ) -Algorithm SHA256
        ).Hash
    ) 'The valid second revision authorization must append one journal event.'
    $revision2AuthorizationRelative = (
        "receipts/durable-review-milestone.method-1.revision-" +
        "$($revision2Authorization.revision_id).authorization.json"
    )
    $revision2Readback =
        Read-DurableReviewMilestoneRevisionAuthorization -Path (
            Join-Path $consecutiveRevisionRun $revision2AuthorizationRelative
        ) -RunDirectory $consecutiveRevisionRun
    Assert-True (
        [string]$revision2Readback.receipt_hash -eq
            [string]$revision2Authorization.receipt_hash
    ) 'The second revision authorization must survive deterministic readback.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $consecutiveRevisionRun | Out-Null
    } 'authorized but not yet selected' (
        'A second revision authorization cannot satisfy completion by itself.'
    )

    $sameCheckpointRun = Join-Path $testRoot (
        'consecutive-revision-same-checkpoint'
    )
    Copy-Item -LiteralPath $revision2ReadyRun `
        -Destination $sameCheckpointRun -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $sameCheckpointRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath (Join-Path $sameCheckpointRun (
                'materials/checkpoint-method-1-revision-1.json'
            )) -InputManifestPath (Join-Path $sameCheckpointRun (
                'materials/input-method-1-revision-2.json'
            )) -ReviewMaterialManifestPath (Join-Path $sameCheckpointRun (
                'materials/method-1-revision-2-review-materials.json'
            )) -ExcludedEvidenceManifestPath (Join-Path $sameCheckpointRun (
                'materials/method-1-revision-2-excluded-evidence.json'
            )) -AuthorizationMaterialPath (Join-Path $sameCheckpointRun (
                'materials/method-1-revision-2-controller-authorization.md'
            )) -AcceptanceAuthorizationMaterialPath (Join-Path (
                $sameCheckpointRun
            ) (
                'materials/method-1-revision-2-acceptance-authorization.json'
            )) -SelectionKey 'controller:reject-revision-2-checkpoint-replay' `
            -ActivationKey 'controller:reject-revision-2-checkpoint-replay' |
            Out-Null
    } 'cannot be revised in place' (
        'A selected revision checkpoint cannot be replayed.'
    )

    $sameInputRun = Join-Path $testRoot 'consecutive-revision-same-input'
    Copy-Item -LiteralPath $revision2ReadyRun `
        -Destination $sameInputRun -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $sameInputRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath (Join-Path $sameInputRun (
                'materials/checkpoint-method-1-revision-2.json'
            )) -InputManifestPath (Join-Path $sameInputRun (
                'materials/input-method-1-revision-1.json'
            )) -ReviewMaterialManifestPath (Join-Path $sameInputRun (
                'materials/method-1-revision-2-review-materials.json'
            )) -ExcludedEvidenceManifestPath (Join-Path $sameInputRun (
                'materials/method-1-revision-2-excluded-evidence.json'
            )) -AuthorizationMaterialPath (Join-Path $sameInputRun (
                'materials/method-1-revision-2-controller-authorization.md'
            )) -AcceptanceAuthorizationMaterialPath (Join-Path $sameInputRun (
                'materials/method-1-revision-2-acceptance-authorization.json'
            )) -SelectionKey 'controller:reject-revision-2-input-replay' `
            -ActivationKey 'controller:reject-revision-2-input-replay' |
            Out-Null
    } 'requires a new input manifest' (
        'A selected revision input cannot be replayed with a new checkpoint.'
    )

    $forgedAcceptanceRun = Join-Path $testRoot (
        'consecutive-revision-forged-final-acceptance'
    )
    Copy-Item -LiteralPath $revision2ReadyRun `
        -Destination $forgedAcceptanceRun -Recurse
    Set-Content -LiteralPath (Join-Path $forgedAcceptanceRun (
        'receipts/durable-review-milestone.method-1.acceptance.json'
    )) -Value '{}'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $forgedAcceptanceRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath (Join-Path $forgedAcceptanceRun (
                'materials/checkpoint-method-1-revision-2.json'
            )) -InputManifestPath (Join-Path $forgedAcceptanceRun (
                'materials/input-method-1-revision-2.json'
            )) -ReviewMaterialManifestPath (Join-Path $forgedAcceptanceRun (
                'materials/method-1-revision-2-review-materials.json'
            )) -ExcludedEvidenceManifestPath (Join-Path $forgedAcceptanceRun (
                'materials/method-1-revision-2-excluded-evidence.json'
            )) -AuthorizationMaterialPath (Join-Path $forgedAcceptanceRun (
                'materials/method-1-revision-2-controller-authorization.md'
            )) -AcceptanceAuthorizationMaterialPath (Join-Path (
                $forgedAcceptanceRun
            ) (
                'materials/method-1-revision-2-acceptance-authorization.json'
            )) -SelectionKey 'controller:reject-forged-final-acceptance' `
            -ActivationKey 'controller:reject-forged-final-acceptance' |
            Out-Null
    } 'Milestone acceptance receipt is missing' (
        'A forged final acceptance cannot unlock another revision.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $consecutiveRevisionRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath $revision2Checkpoint `
            -InputManifestPath $revision2Input `
            -ReviewMaterialManifestPath $revision2ReviewManifest `
            -ExcludedEvidenceManifestPath $revision2ExcludedManifest `
            -AuthorizationMaterialPath $revision2AuthorizationMaterial `
            -AcceptanceAuthorizationMaterialPath (
                $revision2AcceptanceAuthorization
            ) -SelectionKey 'controller:reject-pending-revision-fork' `
            -ActivationKey 'controller:reject-pending-revision-fork' |
            Out-Null
    } 'authorized but not yet selected' (
        'A pending revision cannot be forked by another authorization.'
    )

    $authorizationMutations = @(
        @{
            name = 'missing-open-occurrence'
            expected = 'open finding occurrence conservation changed'
            mutate = {
                param($receipt)
                $receipt.previous_open_occurrences = @(
                    $receipt.previous_open_occurrences | Select-Object -Skip 1
                )
            }
        },
        @{
            name = 'severity-downgrade'
            expected = 'open finding occurrence conservation changed'
            mutate = {
                param($receipt)
                $receipt.previous_open_occurrences[0].severity = 'P2'
            }
        },
        @{
            name = 'finding-text-rewrite'
            expected = 'open finding occurrence conservation changed'
            mutate = {
                param($receipt)
                $replacement = 'self-consistent rewritten finding'
                $receipt.previous_open_occurrences[0].finding = $replacement
                $receipt.previous_open_occurrences[0].finding_hash =
                    Get-TextSha256 $replacement
            }
        },
        @{
            name = 'cross-source-move'
            expected = 'open finding occurrence conservation changed'
            mutate = {
                param($receipt)
                $receipt.previous_open_occurrences[0].source_node_id = 'review'
            }
        },
        @{
            name = 'thread-substitution'
            expected = 'open finding occurrence conservation changed'
            mutate = {
                param($receipt)
                $receipt.previous_open_occurrences[0].source_thread_id =
                    'another-thread'
            }
        },
        @{
            name = 'selection-receipt-substitution'
            expected = 'previous selection binding changed'
            mutate = {
                param($receipt)
                $receipt.previous_revision_selection_receipt_hash = ('f' * 64)
            }
        },
        @{
            name = 'selection-event-substitution'
            expected = 'previous selection binding changed'
            mutate = {
                param($receipt)
                $receipt.previous_revision_selection_event_hash = ('e' * 64)
            }
        },
        @{
            name = 'revision-index-rewrite'
            expected = 'predecessor state is invalid'
            mutate = {
                param($receipt)
                $receipt.revision_index = [int]$receipt.revision_index + 1
            }
        },
        @{
            name = 'cross-run-replay'
            expected = 'run or milestone binding is invalid'
            mutate = {
                param($receipt)
                $receipt.run_id = 'another-run'
            }
        }
    )
    foreach ($mutation in $authorizationMutations) {
        $mutationRun = Join-Path $testRoot (
            'consecutive-revision-' + [string]$mutation.name
        )
        Copy-Item -LiteralPath $consecutiveRevisionRun `
            -Destination $mutationRun -Recurse
        Resign-RevisionAuthorizationTail -Run $mutationRun `
            -ReceiptRelativePath $revision2AuthorizationRelative `
            -ReceiptMutation $mutation.mutate
        $mutationJournalPath = Join-Path $mutationRun 'events.jsonl'
        $mutationEventsBefore = @(Read-OrchestrationJournal $mutationJournalPath)
        $mutationJournalHashBefore = (
            Get-FileHash -LiteralPath $mutationJournalPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        Assert-ThrowsLike {
            Read-DurableReviewMilestoneRevisionAuthorization -Path (
                Join-Path $mutationRun $revision2AuthorizationRelative
            ) -RunDirectory $mutationRun | Out-Null
        } ([string]$mutation.expected) (
            "A re-signed $([string]$mutation.name) must fail closed."
        )
        $mutationEventsAfter = @(Read-OrchestrationJournal $mutationJournalPath)
        Assert-True (
            $mutationEventsAfter.Count -eq $mutationEventsBefore.Count -and
            [string]$mutationEventsAfter[-1].hash -eq
                [string]$mutationEventsBefore[-1].hash -and
            (Get-FileHash -LiteralPath $mutationJournalPath -Algorithm SHA256).
                Hash.ToLowerInvariant() -eq $mutationJournalHashBefore
        ) "Rejected $([string]$mutation.name) must not mutate the journal."
    }

    foreach ($source in @(
        @{ id = 'review'; thread = 'review-thread' },
        @{ id = 'domain'; thread = 'domain-thread' }
    )) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $consecutiveRevisionRun -NodeId $source.id `
            -Status running -ThreadId $source.thread `
            -MilestoneRevisionAuthorizationReceiptPath (
                $revision2AuthorizationRelative
            ) -Message \"Second revision review for $($source.id).\" `
            -Evidence @('observation:fresh-second-revision-review') `
            -IdempotencyKey \"revision-2-rearm-$($source.id)\" | Out-Null
    }
    $revision2Review = New-SourceChain -Run $consecutiveRevisionRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revision2Checkpoint `
        -Stem 'review.method-1-revision-2' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'open' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding'
    $revision2Domain = New-SourceChain -Run $consecutiveRevisionRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-1' -CheckpointPath $revision2Checkpoint `
        -Stem 'domain.method-1-revision-2' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'open' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    foreach ($source in @(
        @{
            id = 'review'; thread = 'review-thread'
            result = $revision2Review.result_path
            disposition = $revision2Review.disposition_path
        },
        @{
            id = 'domain'; thread = 'domain-thread'
            result = $revision2Domain.result_path
            disposition = $revision2Domain.disposition_path
        }
    )) {
        foreach ($status in @('completed', 'validated', 'adopted')) {
            $pointer = if ($status -eq 'completed') {
                "artifact:$($source.result)"
            } else {
                "artifact:$($source.disposition)"
            }
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $consecutiveRevisionRun -NodeId $source.id `
                -Status $status -ThreadId $source.thread `
                -Message \"Second revision $($source.id) $status.\" `
                -Evidence @($pointer) `
                -IdempotencyKey \"revision-2-$($source.id)-$status\" |
                Out-Null
        }
    }
    $revision2SelectionMaterial = Join-Path $consecutiveRevisionRun (
        'materials/method-1-revision-2-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $revision2Review.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $revision2Domain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $revision2SelectionMaterial

    # A correct lifecycle can still be unusable when the caller builds the
    # current result/disposition from only the presently open finding and drops
    # a previously resolved source occurrence. The repair must be one
    # append-only, all-source, non-state supersession derived from immutable
    # predecessor/current receipts; it may not let the caller rewrite findings.
    $inventoryOmissionRun = Join-Path $testRoot (
        'same-revision-cumulative-inventory-omission'
    )
    Copy-Item -LiteralPath $consecutiveRevisionRun `
        -Destination $inventoryOmissionRun -Recurse
    $omittedFindingId = 'review-method-1-finding-r08'
    $omittedResultPath = Join-Path $inventoryOmissionRun (
        $revision2Review.result_path
    )
    $omittedResult = Get-Content -LiteralPath $omittedResultPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $omittedResult.pending_findings = @(
        $omittedResult.pending_findings | Where-Object {
            [string]$_.finding_id -ne $omittedFindingId
        }
    )
    $omittedResult.Remove('receipt_hash')
    $omittedResult.receipt_hash = Get-ThreadResultReceiptCanonicalHash `
        -Receipt ([pscustomobject]$omittedResult)
    $omittedResult | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $omittedResultPath -Encoding utf8
    $omittedDispositionPath = Join-Path $inventoryOmissionRun (
        $revision2Review.disposition_path
    )
    $omittedDisposition = Get-Content -LiteralPath $omittedDispositionPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $omittedDisposition.source_result_receipt_hash =
        [string]$omittedResult.receipt_hash
    $omittedDisposition.decisions = @(
        $omittedDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -ne $omittedFindingId
        }
    )
    $omittedDisposition.blocking_open = @(
        $omittedDisposition.decisions | Where-Object {
            [string]$_.severity -in @('P0', 'P1') -and
            [string]$_.resolution_status -ne 'resolved'
        } | ForEach-Object { [string]$_.finding }
    )
    $omittedDisposition.Remove('receipt_hash')
    $omittedDisposition.receipt_hash = Get-TextSha256 (
        $omittedDisposition | ConvertTo-Json -Compress -Depth 100
    )
    $omittedDisposition | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $omittedDispositionPath -Encoding utf8
    $inventoryAuthorizationPath = Join-Path $inventoryOmissionRun (
        $revision2AuthorizationRelative
    )
    $inventorySelectionMaterial = Join-Path $inventoryOmissionRun (
        'materials/method-1-revision-2-selection.json'
    )
    $inventoryAuthorizationMaterial = Join-Path $inventoryOmissionRun (
        'materials/method-1-revision-2-controller-authorization.md'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $inventoryOmissionRun `
            -AuthorizationReceiptPath $inventoryAuthorizationPath `
            -SelectionMaterialPath $inventorySelectionMaterial `
            -SelectionKey ([string]$revision2Authorization.selection_key) |
            Out-Null
    } 'did not conserve finding occurrence' (
        'A same-revision cumulative inventory omission must reproduce before repair.'
    )
    $inventoryJournalBefore = (
        Get-FileHash -LiteralPath (
            Join-Path $inventoryOmissionRun 'events.jsonl'
        ) -Algorithm SHA256
    ).Hash
    $omittedResultHashBefore = (
        Get-FileHash -LiteralPath $omittedResultPath -Algorithm SHA256
    ).Hash
    $omittedDispositionHashBefore = (
        Get-FileHash -LiteralPath $omittedDispositionPath -Algorithm SHA256
    ).Hash
    $inventorySupersession = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionInventorySupersessionReceipt.ps1'
    )) -RunDirectory $inventoryOmissionRun `
        -AuthorizationReceiptPath $inventoryAuthorizationPath `
        -SelectionMaterialPath $inventorySelectionMaterial `
        -AuthorizationMaterialPath $inventoryAuthorizationMaterial `
        -SupersessionKey 'controller:revision-2-inventory-supersession' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$inventorySupersession.schema_version -eq '1.0' -and
        @($inventorySupersession.source_supersessions).Count -eq 2 -and
        (@($inventorySupersession.source_supersessions |
            ForEach-Object { [int]$_.restored_occurrence_count }) |
            Measure-Object -Sum).Sum -eq 1
    ) (
        'Inventory supersession must restore exactly the omitted occurrence ' +
        'while binding every required source.'
    )
    Assert-True (
        $omittedResultHashBefore -eq (
            Get-FileHash -LiteralPath $omittedResultPath -Algorithm SHA256
        ).Hash -and
        $omittedDispositionHashBefore -eq (
            Get-FileHash -LiteralPath $omittedDispositionPath -Algorithm SHA256
        ).Hash -and
        $inventoryJournalBefore -ne (
            Get-FileHash -LiteralPath (
                Join-Path $inventoryOmissionRun 'events.jsonl'
            ) -Algorithm SHA256
        ).Hash
    ) (
        'Inventory supersession must preserve old receipts and append only one ' +
        'non-state journal event.'
    )
    $inventoryEvent = @(
        Read-OrchestrationJournal (Join-Path $inventoryOmissionRun 'events.jsonl') |
            Where-Object {
                [string]$_.event -eq
                    'milestone-revision-inventory-superseded'
            }
    )
    Assert-True (
        $inventoryEvent.Count -eq 1 -and
        $null -eq $inventoryEvent[0].node_id -and
        $null -eq $inventoryEvent[0].prior_state -and
        [string]$inventoryEvent[0].status -eq 'planned'
    ) 'Inventory supersession must not mutate any source lifecycle state.'
    $reviewSupersession = @(
        $inventorySupersession.source_supersessions | Where-Object {
            [string]$_.source_node_id -eq 'review'
        }
    )[0]
    $supersededReviewDisposition = Get-Content -LiteralPath (
        Join-Path $inventoryOmissionRun (
            [string]$reviewSupersession.superseded_binding.
                disposition_receipt_path
        )
    ) -Raw | ConvertFrom-Json -Depth 100
    $restoredDecision = @(
        $supersededReviewDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -eq $omittedFindingId
        }
    )
    $previousReviewDisposition = Get-Content -LiteralPath (
        Join-Path $inventoryOmissionRun (
            [string]$reviewSupersession.previous_binding.
                disposition_receipt_path
        )
    ) -Raw | ConvertFrom-Json -Depth 100
    $previousRestoredDecision = @(
        $previousReviewDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -eq $omittedFindingId
        }
    )
    Assert-True (
        $restoredDecision.Count -eq 1 -and
        $previousRestoredDecision.Count -eq 1 -and
        (ConvertTo-Json -InputObject $restoredDecision[0] `
            -Compress -Depth 100) -ceq
        (ConvertTo-Json -InputObject $previousRestoredDecision[0] `
            -Compress -Depth 100)
    ) (
        'A restored occurrence must retain its exact identity, status, and evidence.'
    )
    $supersededReviewResult = Get-Content -LiteralPath (
        Join-Path $inventoryOmissionRun (
            [string]$reviewSupersession.superseded_binding.result_receipt_path
        )
    ) -Raw | ConvertFrom-Json -Depth 100
    $currentReviewResult = Get-Content -LiteralPath $omittedResultPath -Raw |
        ConvertFrom-Json -Depth 100
    $currentReviewDisposition =
        Get-Content -LiteralPath $omittedDispositionPath -Raw |
            ConvertFrom-Json -Depth 100
    $existingFindingId = 'review-method-1-finding'
    $currentFinding = @($currentReviewResult.pending_findings | Where-Object {
        [string]$_.finding_id -eq $existingFindingId
    })[0]
    $effectiveFinding = @(
        $supersededReviewResult.pending_findings | Where-Object {
            [string]$_.finding_id -eq $existingFindingId
        }
    )[0]
    $currentDecision = @($currentReviewDisposition.decisions | Where-Object {
        [string]$_.source_finding_id -eq $existingFindingId
    })[0]
    $effectiveDecision = @(
        $supersededReviewDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -eq $existingFindingId
        }
    )[0]
    Assert-True (
        (ConvertTo-Json -InputObject $currentFinding -Compress -Depth 100) -ceq
            (ConvertTo-Json -InputObject $effectiveFinding -Compress -Depth 100) -and
        (ConvertTo-Json -InputObject $currentDecision -Compress -Depth 100) -ceq
            (ConvertTo-Json -InputObject $effectiveDecision -Compress -Depth 100)
    ) (
        'Inventory supersession must preserve every existing current finding ' +
        'and decision exactly.'
    )
    $inventorySupersededSnapshot = Join-Path $testRoot (
        'same-revision-cumulative-inventory-superseded'
    )
    Copy-Item -LiteralPath $inventoryOmissionRun `
        -Destination $inventorySupersededSnapshot -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $inventoryOmissionRun `
            -AuthorizationReceiptPath $inventoryAuthorizationPath `
            -SelectionMaterialPath $inventorySelectionMaterial `
            -SelectionKey ([string]$revision2Authorization.selection_key) |
            Out-Null
    } 'does not use its bound inventory supersession material' (
        'Selection cannot ignore the superseded cumulative material.'
    )
    $supersededSelectionMaterial = Join-Path $inventoryOmissionRun (
        [string]$inventorySupersession.superseded_selection_material_path
    )
    $inventorySelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $inventoryOmissionRun `
        -AuthorizationReceiptPath $inventoryAuthorizationPath `
        -SelectionMaterialPath $supersededSelectionMaterial `
        -SelectionKey ([string]$revision2Authorization.selection_key) |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$inventorySelection.schema_version -eq '1.4' -and
        [string]$inventorySelection.inventory_supersession_receipt_hash -eq
            [string]$inventorySupersession.receipt_hash -and
        @($inventorySelection.source_bindings).Count -eq 2
    ) 'Selection must bind and revalidate the complete supersession chain.'
    $inventorySelectionReceiptPath = Join-Path $inventoryOmissionRun (
        'receipts/durable-review-milestone.' +
        "$($revision2Authorization.milestone_id).revision-" +
        "$($revision2Authorization.revision_id).selection.json"
    )
    $cacheToken = Enter-OrchestrationValidationContext `
        -RunDirectory $inventoryOmissionRun
    $cacheSucceeded = $false
    try {
        $firstCachedSelection =
            Read-DurableReviewMilestoneRevisionSelection `
                -Path $inventorySelectionReceiptPath `
                -RunDirectory $inventoryOmissionRun
        $firstCachedSelection.source_bindings[0].source_node_id =
            'memory-only-mutation'
        $secondCachedSelection =
            Read-DurableReviewMilestoneRevisionSelection `
                -Path $inventorySelectionReceiptPath `
                -RunDirectory $inventoryOmissionRun
        Assert-True (
            [string]$secondCachedSelection.source_bindings[0].source_node_id -ne
                'memory-only-mutation'
        ) 'The validation cache must return a serialized verified-object copy.'
        $cacheSucceeded = $true
    } finally {
        Exit-OrchestrationValidationContext -Token $cacheToken `
            -ValidateSnapshot:$cacheSucceeded
    }
    Assert-True ($null -eq $script:OrchestrationValidationContext) (
        'A successful top-level validation must clear its context.'
    )

    $cacheIsolationRun = Join-Path $testRoot (
        'same-process-validation-cache-isolation'
    )
    Copy-Item -LiteralPath $inventoryOmissionRun `
        -Destination $cacheIsolationRun -Recurse
    $cacheIsolationSelectionPath = Join-Path $cacheIsolationRun (
        [IO.Path]::GetRelativePath(
            $inventoryOmissionRun, $inventorySelectionReceiptPath
        )
    )
    Read-DurableReviewMilestoneRevisionSelection `
        -Path $cacheIsolationSelectionPath -RunDirectory $cacheIsolationRun |
        Out-Null
    $mutatedSelection = Get-Content -LiteralPath $cacheIsolationSelectionPath `
        -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    $mutatedSelection.created_at_utc = '2099-01-01T00:00:00.0000000Z'
    $mutatedSelection | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $cacheIsolationSelectionPath -Encoding utf8
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionSelection `
            -Path $cacheIsolationSelectionPath -RunDirectory $cacheIsolationRun |
            Out-Null
    } 'receipt hash mismatch' (
        'A second top-level call in the same process must not use stale cache data.'
    )
    Assert-True ($null -eq $script:OrchestrationValidationContext) (
        'A failed top-level validation must clear its context.'
    )

    $toctouRun = Join-Path $testRoot 'validation-context-toctou'
    Copy-Item -LiteralPath $inventoryOmissionRun -Destination $toctouRun -Recurse
    $toctouSelectionPath = Join-Path $toctouRun (
        [IO.Path]::GetRelativePath(
            $inventoryOmissionRun, $inventorySelectionReceiptPath
        )
    )
    Assert-ThrowsLike {
        $toctouToken = Enter-OrchestrationValidationContext `
            -RunDirectory $toctouRun
        $toctouSucceeded = $false
        try {
            Read-DurableReviewMilestoneRevisionSelection `
                -Path $toctouSelectionPath -RunDirectory $toctouRun |
                Out-Null
            Add-Content -LiteralPath $toctouSelectionPath -Value ''
            $toctouSucceeded = $true
        } finally {
            Exit-OrchestrationValidationContext -Token $toctouToken `
                -ValidateSnapshot:$toctouSucceeded
        }
    } 'inputs changed during verification' (
        'A bound input mutation before top-level exit must fail the TOCTOU check.'
    )
    Assert-True ($null -eq $script:OrchestrationValidationContext) (
        'A TOCTOU rejection must clear its validation context.'
    )

    $aliasRun = Join-Path $testRoot 'validation-context-same-content-alias'
    Copy-Item -LiteralPath $inventoryOmissionRun -Destination $aliasRun -Recurse
    $canonicalAliasSource = Join-Path $aliasRun (
        [IO.Path]::GetRelativePath(
            $inventoryOmissionRun, $inventorySelectionReceiptPath
        )
    )
    $sameContentAlias = Join-Path (Join-Path $aliasRun 'receipts') (
        'same-content-alias.selection.json'
    )
    Copy-Item -LiteralPath $canonicalAliasSource -Destination $sameContentAlias
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionSelection -Path $sameContentAlias `
            -RunDirectory $aliasRun | Out-Null
    } 'lacks its exact journal event' (
        'A same-content receipt at a different path must not satisfy canonical binding.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $inventoryOmissionRun | Out-Null
    } 'unresolved P0' (
        'Supersession and selection must retain open P0/P1 completion blockers.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionInventorySupersessionReceipt.ps1'
        )) -RunDirectory $inventorySupersededSnapshot `
            -AuthorizationReceiptPath (Join-Path $inventorySupersededSnapshot (
                $revision2AuthorizationRelative
            )) -SelectionMaterialPath (Join-Path $inventorySupersededSnapshot (
                'materials/method-1-revision-2-selection.json'
            )) -AuthorizationMaterialPath (Join-Path $inventorySupersededSnapshot (
                'materials/method-1-revision-2-controller-authorization.md'
            )) -SupersessionKey 'controller:duplicate-inventory-supersession' |
            Out-Null
    } 'unsuperseded authorization' (
        'A revision inventory may be superseded only once.'
    )
    $partialInventoryRun = Join-Path $testRoot (
        'same-revision-cumulative-inventory-partial-source'
    )
    Copy-Item -LiteralPath $consecutiveRevisionRun `
        -Destination $partialInventoryRun -Recurse
    $partialSelectionPath = Join-Path $partialInventoryRun (
        'materials/method-1-revision-2-selection.json'
    )
    @([ordered]@{
        source_node_id = 'review'
        disposition_receipt_path = $revision2Review.disposition_path
    }) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $partialSelectionPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionInventorySupersessionReceipt.ps1'
        )) -RunDirectory $partialInventoryRun `
            -AuthorizationReceiptPath (Join-Path $partialInventoryRun (
                $revision2AuthorizationRelative
            )) -SelectionMaterialPath $partialSelectionPath `
            -AuthorizationMaterialPath (Join-Path $partialInventoryRun (
                'materials/method-1-revision-2-controller-authorization.md'
            )) -SupersessionKey 'controller:partial-inventory-supersession' |
            Out-Null
    } 'requires every source' (
        'A partial-source inventory supersession must fail before journal write.'
    )
    $statusMutationRun = Join-Path $testRoot (
        'same-revision-cumulative-inventory-status-mutation'
    )
    Copy-Item -LiteralPath $inventorySupersededSnapshot `
        -Destination $statusMutationRun -Recurse
    Resign-RevisionInventorySupersessionTail -Run $statusMutationRun `
        -ReceiptMutation {
            param($receipt)
            $restoredSource = @(
                $receipt.source_supersessions | Where-Object {
                    [int]$_.restored_occurrence_count -gt 0
                }
            )[0]
            $restoredSource.restored_occurrences[0].
                decision.resolution_status = 'resolved'
        }
    $statusReceiptPath = @(
        Get-ChildItem -LiteralPath (Join-Path $statusMutationRun 'receipts') `
            -File -Filter '*.inventory-supersession.json'
    )[0].FullName
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionInventorySupersession `
            -Path $statusReceiptPath -RunDirectory $statusMutationRun |
            Out-Null
    } 'finding status, evidence, or effective artifacts' (
        'A re-signed restored status change must fail closed.'
    )
    $crossSourceMutationRun = Join-Path $testRoot (
        'same-revision-cumulative-inventory-cross-source'
    )
    Copy-Item -LiteralPath $inventorySupersededSnapshot `
        -Destination $crossSourceMutationRun -Recurse
    Resign-RevisionInventorySupersessionTail -Run $crossSourceMutationRun `
        -ReceiptMutation {
            param($receipt)
            $movedSource = @(
                $receipt.source_supersessions | Where-Object {
                    [string]$_.source_node_id -ne 'domain'
                }
            )[0]
            $movedSource.source_node_id = 'domain'
        }
    $crossSourceReceiptPath = @(
        Get-ChildItem -LiteralPath (Join-Path $crossSourceMutationRun 'receipts') `
            -File -Filter '*.inventory-supersession.json'
    )[0].FullName
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneRevisionInventorySupersession `
            -Path $crossSourceReceiptPath -RunDirectory $crossSourceMutationRun |
            Out-Null
    } 'is not unique' (
        'A re-signed cross-source inventory move must fail closed.'
    )

    $revision2Selection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $consecutiveRevisionRun `
        -AuthorizationReceiptPath (
            Join-Path $consecutiveRevisionRun $revision2AuthorizationRelative
        ) -SelectionMaterialPath $revision2SelectionMaterial `
        -SelectionKey ([string]$revision2Authorization.selection_key) |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [int]$revision2Selection.revision_index -eq 2 -and
        @($revision2Selection.source_bindings).Count -eq 2
    ) 'The second revision must select both fresh source lifecycles in order.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
        )) -RunDirectory $consecutiveRevisionRun -MilestoneId 'method-1' |
            Out-Null
    } 'unresolved P0/P1' (
        'The second revision cannot close its conserved open P0/P1 findings.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $consecutiveRevisionRun | Out-Null
    } 'lacks main-owner acceptance' (
        'Selecting the second revision must not manufacture final acceptance.'
    )

    # A source that was already replaced in revision one may remain the same
    # logical, same-role reviewer in revision two. Its new-checkpoint result
    # must bind the consecutive revision authorization and exact re-arm event;
    # the ordinary checkpoint roll-forward route remains a different contract.
    $replacementConsecutiveRun = Join-Path $testRoot (
        'replacement-consecutive-first-milestone-revision'
    )
    Copy-Item -LiteralPath $replacementReadyRun `
        -Destination $replacementConsecutiveRun -Recurse
    foreach ($relativePath in @(
        $replacementReview.disposition_path,
        $replacementDomain.disposition_path
    )) {
        $dispositionPath = Join-Path $replacementConsecutiveRun $relativePath
        $disposition = Get-Content -LiteralPath $dispositionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($decision in @($disposition.decisions)) {
            $decision.resolution_status = 'open'
            $decision.re_review_status = 'requested'
            $decision.re_review_evidence = @()
        }
        $disposition.blocking_open = @(
            $disposition.decisions | ForEach-Object { [string]$_.finding }
        )
        $disposition.Remove('receipt_hash')
        $disposition.receipt_hash = Get-TextSha256 (
            $disposition | ConvertTo-Json -Compress -Depth 100
        )
        $disposition | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $dispositionPath -Encoding utf8
    }
    $replacementConsecutiveSelectionMaterial = Join-Path (
        $replacementConsecutiveRun
    ) 'materials/method-1-revision-1-replacement-selection.json'
    $replacementConsecutiveAuthorizationPath = Join-Path (
        $replacementConsecutiveRun
    ) $revisionAuthorizationRelative
    $replacementConsecutiveAuthorization =
        Read-DurableReviewMilestoneRevisionAuthorization -Path (
            $replacementConsecutiveAuthorizationPath
        ) -RunDirectory $replacementConsecutiveRun
    $replacementConsecutiveSelection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $replacementConsecutiveRun `
        -AuthorizationReceiptPath $replacementConsecutiveAuthorizationPath `
        -SelectionMaterialPath $replacementConsecutiveSelectionMaterial `
        -SelectionKey ([string]$replacementConsecutiveAuthorization.selection_key) |
        ConvertFrom-Json -Depth 100

    $replacementRevision2Checkpoint = Join-Path $replacementConsecutiveRun (
        'materials/checkpoint-method-1-replacement-revision-2.json'
    )
    $replacementRevision2Input = Join-Path $replacementConsecutiveRun (
        'materials/input-method-1-replacement-revision-2.json'
    )
    $replacementRevision2ReviewPrompt = Join-Path $replacementConsecutiveRun (
        'materials/review-replacement-revision-2.md'
    )
    $replacementRevision2DomainPrompt = Join-Path $replacementConsecutiveRun (
        'materials/domain-replacement-revision-2.md'
    )
    $replacementRevision2Manifest = Join-Path $replacementConsecutiveRun (
        'materials/method-1-replacement-revision-2-review-materials.json'
    )
    $replacementRevision2Excluded = Join-Path $replacementConsecutiveRun (
        'materials/method-1-replacement-revision-2-excluded-evidence.json'
    )
    $replacementRevision2Controller = Join-Path $replacementConsecutiveRun (
        'materials/method-1-replacement-revision-2-controller.md'
    )
    $replacementRevision2AcceptanceEvidence = Join-Path (
        $replacementConsecutiveRun
    ) 'materials/method-1-replacement-revision-2-acceptance.md'
    $replacementRevision2Acceptance = Join-Path $replacementConsecutiveRun (
        'materials/method-1-replacement-revision-2-acceptance.json'
    )
    Set-Content -LiteralPath $replacementRevision2Checkpoint `
        -Value '{"milestone":"method-1","replacement_revision":2}'
    Set-Content -LiteralPath $replacementRevision2Input `
        -Value '{"scope":"method-1-replacement-revision-2"}'
    Set-Content -LiteralPath $replacementRevision2ReviewPrompt `
        -Value 'Continue the same replacement reviewer at revision two.'
    Set-Content -LiteralPath $replacementRevision2DomainPrompt `
        -Value 'Continue the same domain reviewer at revision two.'
    @(
        [ordered]@{
            source_node_id = 'review'
            material_path = 'materials/review-replacement-revision-2.md'
        },
        [ordered]@{
            source_node_id = 'domain'
            material_path = 'materials/domain-replacement-revision-2.md'
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $replacementRevision2Manifest
    ConvertTo-Json -InputObject @() |
        Set-Content -LiteralPath $replacementRevision2Excluded
    Set-Content -LiteralPath $replacementRevision2Controller `
        -Value 'Controller authorizes the next replacement-backed revision.'
    Set-Content -LiteralPath $replacementRevision2AcceptanceEvidence `
        -Value 'Main owner independently accepts only after blockers close.'
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'method-1'
        main_node_id = 'integrate'
        acceptance_key = 'controller:replacement-revision-2-acceptance'
        evidence_material_path = [IO.Path]::GetRelativePath(
            $replacementConsecutiveRun,
            $replacementRevision2AcceptanceEvidence
        ).Replace('\\', '/')
        evidence_material_hash = (
            Get-FileHash -LiteralPath $replacementRevision2AcceptanceEvidence `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $replacementRevision2Acceptance
    $replacementRevision2Authorization = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
    )) -RunDirectory $replacementConsecutiveRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $replacementRevision2Checkpoint `
        -InputManifestPath $replacementRevision2Input `
        -ReviewMaterialManifestPath $replacementRevision2Manifest `
        -ExcludedEvidenceManifestPath $replacementRevision2Excluded `
        -AuthorizationMaterialPath $replacementRevision2Controller `
        -AcceptanceAuthorizationMaterialPath $replacementRevision2Acceptance `
        -SelectionKey 'controller:select-replacement-revision-2' `
        -ActivationKey 'controller:replacement-revision-2' |
        ConvertFrom-Json -Depth 100
    $replacementRevision2AuthorizationRelative = (
        'receipts/durable-review-milestone.method-1.revision-' +
        "$($replacementRevision2Authorization.revision_id).authorization.json"
    )
    foreach ($source in @(
        @{ id = 'review'; thread = 'review-replacement-thread' },
        @{ id = 'domain'; thread = 'domain-thread' }
    )) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $replacementConsecutiveRun -NodeId $source.id `
            -Status running -ThreadId $source.thread `
            -MilestoneRevisionAuthorizationReceiptPath (
                $replacementRevision2AuthorizationRelative
            ) -Message "Replacement-backed revision two for $($source.id)." `
            -Evidence @('observation:fresh-replacement-backed-review') `
            -IdempotencyKey "replacement-revision-2-rearm-$($source.id)" |
            Out-Null
    }
    $replacementRevision2ReadyRun = Join-Path $testRoot (
        'replacement-consecutive-revision-2-ready'
    )
    Copy-Item -LiteralPath $replacementConsecutiveRun `
        -Destination $replacementRevision2ReadyRun -Recurse
    Assert-ThrowsLike {
        New-SourceChain -Run $replacementRevision2ReadyRun `
            -SourceNodeId 'review' -ThreadId 'review-replacement-thread' `
            -MilestoneId 'method-1' -CheckpointPath (
                Join-Path $replacementRevision2ReadyRun (
                    'materials/checkpoint-method-1-replacement-revision-2.json'
                )
            ) -Stem 'review.replacement-revision-2-without-authorization' `
            -Severity 'P0' -FindingText 'baseline-review-p0' `
            -Resolution 'open' -FindingId 'review-method-1-finding' `
            -CanonicalFindingId 'canonical-review-method-1-finding' `
            -ReplacementContinuityReceiptPath (Join-Path (
                $replacementRevision2ReadyRun
            ) 'receipts/review.replacement-continuity.json') | Out-Null
    } 'checkpoint roll-forward receipt' (
        'An ordinary replacement result cannot reuse a new checkpoint without ' +
        'its exact consecutive revision authorization.'
    )

    $replacementRevision2Review = New-SourceChain `
        -Run $replacementConsecutiveRun -SourceNodeId 'review' `
        -ThreadId 'review-replacement-thread' -MilestoneId 'method-1' `
        -CheckpointPath $replacementRevision2Checkpoint `
        -Stem 'review.method-1-replacement-revision-2' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'open' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding' `
        -ReplacementContinuityReceiptPath (Join-Path (
            $replacementConsecutiveRun
        ) 'receipts/review.replacement-continuity.json') `
        -MilestoneRevisionAuthorizationReceiptPath (Join-Path (
            $replacementConsecutiveRun
        ) $replacementRevision2AuthorizationRelative)
    $replacementRevision2Domain = New-SourceChain `
        -Run $replacementConsecutiveRun -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' -MilestoneId 'method-1' `
        -CheckpointPath $replacementRevision2Checkpoint `
        -Stem 'domain.method-1-replacement-revision-2' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'open' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    $replacementRevision2Result = Read-ThreadResultReceipt -Path (
        Join-Path $replacementConsecutiveRun $replacementRevision2Review.result_path
    ) -RunDirectory $replacementConsecutiveRun -ExpectedThreadId (
        'review-replacement-thread'
    ) -ExpectedSourceNodeId 'review'
    Assert-True (
        [string]$replacementRevision2Result.schema_version -eq '1.5' -and
        [string]$replacementRevision2Result.milestone_revision_id -eq
            [string]$replacementRevision2Authorization.revision_id -and
        [string]$replacementRevision2Result.replacement_continuity_receipt_hash -eq
            [string]$replacementContinuity.receipt_hash
    ) (
        'A replacement result at a consecutive checkpoint must bind both its ' +
        'parent continuity and the exact revision authorization.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $replacementConsecutiveRun -SourceNodeId 'review' `
            -ThreadId 'review-replacement-thread' -HostId 'local' `
            -ThreadReadPath (Join-Path $replacementConsecutiveRun (
                'thread-reads/review.method-1-replacement-revision-2.json'
            )) -OutputPath (Join-Path $replacementConsecutiveRun (
                'receipts/review.replacement-revision-2-mixed.thread-result-receipt.json'
            )) -MilestoneId 'method-1' `
            -CheckpointMaterialPath $replacementRevision2Checkpoint `
            -PendingFindingRecordsPath (Join-Path $replacementConsecutiveRun (
                'materials/review.method-1-replacement-revision-2-findings.json'
            )) -ReplacementContinuityReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) 'receipts/review.replacement-continuity.json') `
            -ReplacementCheckpointRollForwardReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) 'receipts/review.replacement-continuity.json') `
            -MilestoneRevisionAuthorizationReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) $replacementRevision2AuthorizationRelative) | Out-Null
    } 'cannot be combined' (
        'A result cannot mix checkpoint roll-forward and consecutive revision ' +
        'authority.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $replacementConsecutiveRun -SourceNodeId 'review' `
            -ThreadId 'review-replacement-thread' -HostId 'local' `
            -ThreadReadPath (Join-Path $replacementConsecutiveRun (
                'thread-reads/review.method-1-replacement-revision-2.json'
            )) -OutputPath (Join-Path $replacementConsecutiveRun (
                'receipts/review.replacement-revision-2-old-auth.thread-result-receipt.json'
            )) -MilestoneId 'method-1' `
            -CheckpointMaterialPath $replacementRevision2Checkpoint `
            -PendingFindingRecordsPath (Join-Path $replacementConsecutiveRun (
                'materials/review.method-1-replacement-revision-2-findings.json'
            )) -ReplacementContinuityReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) 'receipts/review.replacement-continuity.json') `
            -MilestoneRevisionAuthorizationReceiptPath (
                $replacementConsecutiveAuthorizationPath
            ) | Out-Null
    } 'does not match its milestone or checkpoint' (
        'A previous checkpoint authorization cannot be replayed for a new result.'
    )
    foreach ($source in @(
        @{
            id = 'review'; thread = 'review-replacement-thread'
            result = $replacementRevision2Review.result_path
            disposition = $replacementRevision2Review.disposition_path
        },
        @{
            id = 'domain'; thread = 'domain-thread'
            result = $replacementRevision2Domain.result_path
            disposition = $replacementRevision2Domain.disposition_path
        }
    )) {
        foreach ($status in @('completed', 'validated', 'adopted')) {
            $pointer = if ($status -eq 'completed') {
                "artifact:$($source.result)"
            } else { "artifact:$($source.disposition)" }
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $replacementConsecutiveRun -NodeId $source.id `
                -Status $status -ThreadId $source.thread `
                -Message "Replacement-backed revision two $($source.id) $status." `
                -Evidence @($pointer) `
                -IdempotencyKey (
                    "replacement-revision-2-$($source.id)-$status"
                ) | Out-Null
        }
    }
    $replacementRevision2SelectionMaterial = Join-Path (
        $replacementConsecutiveRun
    ) 'materials/method-1-replacement-revision-2-selection.json'
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path =
                $replacementRevision2Review.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path =
                $replacementRevision2Domain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $replacementRevision2SelectionMaterial
    $replacementRevision2Selection = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
    )) -RunDirectory $replacementConsecutiveRun `
        -AuthorizationReceiptPath (Join-Path $replacementConsecutiveRun (
            $replacementRevision2AuthorizationRelative
        )) -SelectionMaterialPath $replacementRevision2SelectionMaterial `
        -SelectionKey ([string]$replacementRevision2Authorization.selection_key) |
        ConvertFrom-Json -Depth 100
    $replacementRevision2Lifecycle = @(
        $replacementRevision2Selection.source_lifecycle_bindings |
            Where-Object { [string]$_.source_node_id -eq 'review' }
    )[0]
    Assert-True (
        [string]$replacementRevision2Selection.schema_version -eq '1.3' -and
        [string]$replacementRevision2Lifecycle.source_kind -eq 'replacement' -and
        [string]$replacementRevision2Lifecycle.authorized_thread_id -eq
            'review-replacement-thread' -and
        [string]$replacementRevision2Lifecycle.source_thread_id -eq
            'review-replacement-thread' -and
        @($replacementRevision2Lifecycle.recovery_event_bindings).Count -eq 0
    ) (
        'Selection must preserve the same replacement seat without creating ' +
        'another replacement or replaying the original recovery chain.'
    )
    $selectedReplayOutput = Join-Path $replacementConsecutiveRun (
        'receipts/review.replacement-revision-2-after-selection.' +
        'thread-result-receipt.json'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $replacementConsecutiveRun -SourceNodeId 'review' `
            -ThreadId 'review-replacement-thread' -HostId 'local' `
            -ThreadReadPath (Join-Path $replacementConsecutiveRun (
                'thread-reads/review.method-1-replacement-revision-2.json'
            )) -OutputPath $selectedReplayOutput -MilestoneId 'method-1' `
            -CheckpointMaterialPath $replacementRevision2Checkpoint `
            -PendingFindingRecordsPath (Join-Path $replacementConsecutiveRun (
                'materials/review.method-1-replacement-revision-2-findings.json'
            )) -ReplacementContinuityReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) 'receipts/review.replacement-continuity.json') `
            -MilestoneRevisionAuthorizationReceiptPath (Join-Path (
                $replacementConsecutiveRun
            ) $replacementRevision2AuthorizationRelative) | Out-Null
    } 'already selected' (
        'A selected consecutive revision cannot mint another result receipt.'
    )
    Assert-True (-not (Test-Path -LiteralPath $selectedReplayOutput)) (
        'Rejected selected-revision replay must fail before writing a receipt.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $replacementConsecutiveRun | Out-Null
    } 'lacks main-owner acceptance' (
        'A replacement-backed consecutive revision remains blocked by open ' +
        'findings and missing final acceptance.'
    )

    foreach ($field in @(
        'milestone_revision_authorization_receipt_hash',
        'milestone_revision_rearm_event_hash'
    )) {
        $tamperRun = Join-Path $testRoot (
            "replacement-consecutive-result-$field"
        )
        Copy-Item -LiteralPath $replacementConsecutiveRun `
            -Destination $tamperRun -Recurse
        $tamperPath = Join-Path $tamperRun (
            $replacementRevision2Review.result_path
        )
        $tamper = Get-Content -LiteralPath $tamperPath -Raw |
            ConvertFrom-Json -Depth 100
        $tamper.$field = ('f' * 64)
        $tamper.receipt_hash = Get-ThreadResultReceiptCanonicalHash `
            -Receipt $tamper
        $tamper | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $tamperPath
        Assert-ThrowsLike {
            Read-ThreadResultReceipt -Path $tamperPath `
                -RunDirectory $tamperRun `
                -ExpectedThreadId 'review-replacement-thread' `
                -ExpectedSourceNodeId 'review' | Out-Null
        } 'revision' (
            "A self-rehashed $field mutation must fail closed."
        )
    }

    $resignedTailRun = Join-Path $testRoot 'revision-resigned-tail'
    Copy-Item -LiteralPath $revisionRun -Destination $resignedTailRun -Recurse
    $selectionReceiptPath = Join-Path $resignedTailRun (
        "receipts/durable-review-milestone.method-1.revision-" +
        "$($revisionAuthorization.revision_id).selection.json"
    )
    $resignedSelection = Get-Content -LiteralPath $selectionReceiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $resignedSelection.activation_key = 'controller:self-resigned-selection'
    $resignedSelectionPayload = [ordered]@{}
    foreach ($key in $resignedSelection.Keys | Where-Object {
        $_ -ne 'receipt_hash'
    }) {
        $resignedSelectionPayload[$key] = $resignedSelection[$key]
    }
    $resignedSelection.receipt_hash = Get-TextSha256 (
        $resignedSelectionPayload | ConvertTo-Json -Compress -Depth 100
    )
    $resignedSelection | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $selectionReceiptPath

    $resignedEventsPath = Join-Path $resignedTailRun 'events.jsonl'
    $resignedEvents = @(
        Get-Content -LiteralPath $resignedEventsPath | ForEach-Object {
            $_ | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        }
    )
    $selectionEventIndex = [Array]::FindIndex(
        [object[]]$resignedEvents,
        [Predicate[object]]{
            param($event)
            [string]$event.event -eq 'milestone-revision-selected'
        }
    )
    $resignedEvents[$selectionEventIndex].milestone_activation_receipt_hash =
        [string]$resignedSelection.receipt_hash
    $resignedEvents[$selectionEventIndex].request_fingerprint =
        [string]$resignedSelection.receipt_hash
    $resignedEvents[$selectionEventIndex].hash = Get-OrchestrationEventHash (
        [pscustomobject]$resignedEvents[$selectionEventIndex]
    )

    $acceptanceReceiptPath = Join-Path $resignedTailRun (
        'receipts/durable-review-milestone.method-1.acceptance.json'
    )
    $resignedAcceptance = Get-Content -LiteralPath $acceptanceReceiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $resignedAcceptance.activation_receipt_hash =
        [string]$resignedSelection.receipt_hash
    $resignedAcceptance.source_journal_head =
        [string]$resignedEvents[$selectionEventIndex].hash
    $resignedAcceptancePayload = [ordered]@{}
    foreach ($key in $resignedAcceptance.Keys | Where-Object {
        $_ -ne 'receipt_hash'
    }) {
        $resignedAcceptancePayload[$key] = $resignedAcceptance[$key]
    }
    $resignedAcceptance.receipt_hash = Get-TextSha256 (
        $resignedAcceptancePayload | ConvertTo-Json -Compress -Depth 100
    )
    $resignedAcceptance | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $acceptanceReceiptPath

    $acceptanceEventIndex = $selectionEventIndex + 1
    $resignedEvents[$acceptanceEventIndex].prev_hash =
        [string]$resignedEvents[$selectionEventIndex].hash
    $resignedEvents[$acceptanceEventIndex].milestone_activation_receipt_hash =
        [string]$resignedSelection.receipt_hash
    $resignedEvents[$acceptanceEventIndex].milestone_acceptance_receipt_hash =
        [string]$resignedAcceptance.receipt_hash
    $resignedEvents[$acceptanceEventIndex].request_fingerprint =
        [string]$resignedAcceptance.receipt_hash
    $resignedEvents[$acceptanceEventIndex].hash = Get-OrchestrationEventHash (
        [pscustomobject]$resignedEvents[$acceptanceEventIndex]
    )
    @($resignedEvents | ForEach-Object {
        $_ | ConvertTo-Json -Compress -Depth 100
    }) | Set-Content -LiteralPath $resignedEventsPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $resignedTailRun | Out-Null
    } 'selection run or milestone binding is invalid' (
        'Re-signing selection and downstream tail cannot replace the pre-bound key.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $revisionRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath $revisionCheckpoint `
            -InputManifestPath $revisionInput `
            -ReviewMaterialManifestPath $reviewMaterialManifest `
            -ExcludedEvidenceManifestPath $excludedEvidenceManifest `
            -AuthorizationMaterialPath $revisionAuthorizationMaterial `
            -AcceptanceAuthorizationMaterialPath (
                $revisionAcceptanceAuthorization
            ) -SelectionKey 'controller:reject-same-checkpoint-selection' `
            -ActivationKey 'controller:reject-same-checkpoint-revision' |
            Out-Null
    } 'cannot be revised in place' (
        'A selected checkpoint cannot be replayed as another revision.'
    )

    $omittedExcludedRun = Join-Path $testRoot 'revision-omitted-excluded'
    Copy-Item -LiteralPath $revisionPreAuthorizationRun `
        -Destination $omittedExcludedRun -Recurse
    $omittedManifestPath = Join-Path $omittedExcludedRun (
        'materials/method-1-revision-1-excluded-evidence.json'
    )
    $omittedManifest = @(
        Get-Content -LiteralPath $omittedManifestPath -Raw |
            ConvertFrom-Json -Depth 100
    )
    $omittedManifest[0].event_bindings = @(
        $omittedManifest[0].event_bindings | Select-Object -Skip 1
    )
    $omittedManifest | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $omittedManifestPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $omittedExcludedRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath (
                Join-Path $omittedExcludedRun (
                    'materials/checkpoint-method-1-revision-1.json'
                )
            ) -InputManifestPath (
                Join-Path $omittedExcludedRun (
                    'materials/input-method-1-revision-1.json'
                )
            ) -ReviewMaterialManifestPath (
                Join-Path $omittedExcludedRun (
                    'materials/method-1-revision-1-review-materials.json'
                )
            ) -ExcludedEvidenceManifestPath $omittedManifestPath `
            -AuthorizationMaterialPath (
                Join-Path $omittedExcludedRun (
                    'materials/method-1-revision-1-controller-authorization.md'
                )
            ) -AcceptanceAuthorizationMaterialPath (
                Join-Path $omittedExcludedRun (
                    'materials/method-1-revision-1-acceptance-authorization.json'
                )
            ) -SelectionKey 'controller:reject-omitted-selection' `
            -ActivationKey 'controller:reject-omitted-excluded' | Out-Null
    } 'omitted or changed' (
        'Authorization must reject an omitted pre-anchor event binding.'
    )

    $relabeledExcludedRun = Join-Path $testRoot 'revision-relabeled-excluded'
    Copy-Item -LiteralPath $revisionPreAuthorizationRun `
        -Destination $relabeledExcludedRun -Recurse
    $relabeledManifestPath = Join-Path $relabeledExcludedRun (
        'materials/method-1-revision-1-excluded-evidence.json'
    )
    $relabeledManifest = @(
        Get-Content -LiteralPath $relabeledManifestPath -Raw |
            ConvertFrom-Json -Depth 100
    )
    $relabeledManifest[0].reason = 'caller-selected harmless evidence'
    $relabeledManifest | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $relabeledManifestPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $relabeledExcludedRun -MilestoneId 'method-1' `
            -CheckpointMaterialPath (
                Join-Path $relabeledExcludedRun (
                    'materials/checkpoint-method-1-revision-1.json'
                )
            ) -InputManifestPath (
                Join-Path $relabeledExcludedRun (
                    'materials/input-method-1-revision-1.json'
                )
            ) -ReviewMaterialManifestPath (
                Join-Path $relabeledExcludedRun (
                    'materials/method-1-revision-1-review-materials.json'
                )
            ) -ExcludedEvidenceManifestPath $relabeledManifestPath `
            -AuthorizationMaterialPath (
                Join-Path $relabeledExcludedRun (
                    'materials/method-1-revision-1-controller-authorization.md'
                )
            ) -AcceptanceAuthorizationMaterialPath (
                Join-Path $relabeledExcludedRun (
                    'materials/method-1-revision-1-acceptance-authorization.json'
                )
            ) -SelectionKey 'controller:reject-relabeled-selection' `
            -ActivationKey 'controller:reject-relabeled-excluded' | Out-Null
    } 'manifest is invalid' (
        'Authorization must reject caller-relabelled excluded evidence.'
    )

    $excludedSelectionRun = Join-Path $testRoot 'revision-excluded-selection'
    Copy-Item -LiteralPath $revisionReadyRun `
        -Destination $excludedSelectionRun -Recurse
    $excludedSelectionMaterial = Join-Path $excludedSelectionRun (
        'materials/excluded-chain-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $preAnchorReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $preAnchorDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $excludedSelectionMaterial
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $excludedSelectionRun `
            -AuthorizationReceiptPath (
                Join-Path $excludedSelectionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $excludedSelectionMaterial `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'used excluded evidence' (
        'Selection must not reference an excluded pre-authorization chain.'
    )

    $partialSelectionRun = Join-Path $testRoot 'revision-partial-selection'
    Copy-Item -LiteralPath $revisionReadyRun -Destination $partialSelectionRun `
        -Recurse
    $partialSelectionMaterial = Join-Path $partialSelectionRun (
        'materials/partial-revision-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $revisionReview.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $partialSelectionMaterial
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $partialSelectionRun `
            -AuthorizationReceiptPath (
                Join-Path $partialSelectionRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $partialSelectionMaterial `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'include every required source' (
        'Partial-source revision selection must be rejected.'
    )

    $partialRearmRun = Join-Path $testRoot 'revision-partial-rearm'
    Copy-Item -LiteralPath $revisionAuthorizedRun `
        -Destination $partialRearmRun -Recurse
    foreach ($relativePath in @(
        $revisionReview.result_path, $revisionReview.disposition_path,
        $revisionDomain.result_path, $revisionDomain.disposition_path,
        'thread-reads/review.method-1-revision-1.json',
        'thread-reads/domain.method-1-revision-1.json'
    )) {
        Copy-Item -LiteralPath (Join-Path $revisionReadyRun $relativePath) `
            -Destination (Join-Path $partialRearmRun $relativePath) -Force
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $partialRearmRun -NodeId 'domain' -Status running `
        -ThreadId 'domain-thread' `
        -MilestoneRevisionAuthorizationReceiptPath (
            $revisionAuthorizationRelative
        ) -Message 'Only one source is re-armed.' `
        -Evidence @('observation:partial-rearm') `
        -IdempotencyKey 'revision-partial-rearm-domain' | Out-Null
    foreach ($status in @('completed', 'validated', 'adopted')) {
        $pointer = if ($status -eq 'completed') {
            "artifact:$($revisionDomain.result_path)"
        } else { "artifact:$($revisionDomain.disposition_path)" }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $partialRearmRun -NodeId 'domain' `
            -Status $status -ThreadId 'domain-thread' `
            -Message "Partial rearm domain $status." -Evidence @($pointer) `
            -IdempotencyKey "revision-partial-domain-$status" | Out-Null
    }
    $partialRearmSelection = Join-Path $partialRearmRun (
        'materials/partial-rearm-selection.json'
    )
    Copy-Item -LiteralPath $revisionSelectionMaterial `
        -Destination $partialRearmSelection
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $partialRearmRun `
            -AuthorizationReceiptPath (
                Join-Path $partialRearmRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $partialRearmSelection `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'lacks one fresh re-arm' (
        'Selection must reject a revision that re-armed only one source.'
    )

    $missingOccurrenceRun = Join-Path $testRoot (
        'revision-missing-source-occurrence'
    )
    Copy-Item -LiteralPath $revisionReadyRun `
        -Destination $missingOccurrenceRun -Recurse
    foreach ($relativePath in @(
        $revisionReview.result_path, $revisionReview.disposition_path
    )) {
        Remove-Item -LiteralPath (Join-Path $missingOccurrenceRun $relativePath)
    }
    $null = New-SourceChain -Run $missingOccurrenceRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath (
            Join-Path $missingOccurrenceRun (
                'materials/checkpoint-method-1-revision-1.json'
            )
        ) -Stem 'review.method-1-revision-1' -Severity 'P0' `
        -FindingText 'replacement summary that omits the source occurrence' `
        -Resolution 'resolved' -FindingId 'review-summary-only' `
        -CanonicalFindingId 'canonical-review-method-1-finding'
    $missingSelectionMaterial = Join-Path $missingOccurrenceRun (
        'materials/missing-occurrence-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            disposition_receipt_path = $revisionReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            disposition_receipt_path = $revisionDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $missingSelectionMaterial
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $missingOccurrenceRun `
            -AuthorizationReceiptPath (
                Join-Path $missingOccurrenceRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $missingSelectionMaterial `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'did not conserve finding occurrence' (
        'Canonical merging must not delete a source_finding_id occurrence.'
    )

    $downgradeRun = Join-Path $testRoot 'revision-severity-downgrade'
    Copy-Item -LiteralPath $revisionReadyRun -Destination $downgradeRun -Recurse
    foreach ($relativePath in @(
        $revisionReview.result_path, $revisionReview.disposition_path
    )) {
        Remove-Item -LiteralPath (Join-Path $downgradeRun $relativePath)
    }
    $null = New-SourceChain -Run $downgradeRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath (
            Join-Path $downgradeRun (
                'materials/checkpoint-method-1-revision-1.json'
            )
        ) -Stem 'review.method-1-revision-1' -Severity 'P1' `
        -FindingText 'baseline-review-p0' -Resolution 'resolved' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding'
    $downgradeSelectionMaterial = Join-Path $downgradeRun (
        'materials/downgrade-selection.json'
    )
    Copy-Item -LiteralPath $revisionSelectionMaterial `
        -Destination $downgradeSelectionMaterial
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $downgradeRun `
            -AuthorizationReceiptPath (
                Join-Path $downgradeRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $downgradeSelectionMaterial `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'did not conserve finding occurrence' (
        'A revision must reject source occurrence severity downgrade.'
    )

    $textDriftRun = Join-Path $testRoot 'revision-text-drift'
    Copy-Item -LiteralPath $revisionReadyRun -Destination $textDriftRun -Recurse
    foreach ($relativePath in @(
        $revisionReview.result_path, $revisionReview.disposition_path
    )) {
        Remove-Item -LiteralPath (Join-Path $textDriftRun $relativePath)
    }
    $null = New-SourceChain -Run $textDriftRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath (
            Join-Path $textDriftRun (
                'materials/checkpoint-method-1-revision-1.json'
            )
        ) -Stem 'review.method-1-revision-1' -Severity 'P0' `
        -FindingText 'rewritten text cannot replace the old occurrence' `
        -Resolution 'resolved' -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding'
    $textDriftSelection = Join-Path $textDriftRun (
        'materials/text-drift-selection.json'
    )
    Copy-Item -LiteralPath $revisionSelectionMaterial `
        -Destination $textDriftSelection
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $textDriftRun `
            -AuthorizationReceiptPath (
                Join-Path $textDriftRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $textDriftSelection `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'did not conserve finding occurrence' (
        'A revision must reject exact finding text or text-hash drift.'
    )

    $crossSourceRun = Join-Path $testRoot 'revision-cross-source-move'
    Copy-Item -LiteralPath $revisionReadyRun -Destination $crossSourceRun `
        -Recurse
    foreach ($relativePath in @(
        $revisionReview.result_path, $revisionReview.disposition_path
    )) {
        Remove-Item -LiteralPath (Join-Path $crossSourceRun $relativePath)
    }
    $null = New-SourceChain -Run $crossSourceRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath (
            Join-Path $crossSourceRun (
                'materials/checkpoint-method-1-revision-1.json'
            )
        ) -Stem 'review.method-1-revision-1' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'resolved' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    $crossSourceSelection = Join-Path $crossSourceRun (
        'materials/cross-source-selection.json'
    )
    Copy-Item -LiteralPath $revisionSelectionMaterial `
        -Destination $crossSourceSelection
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1'
        )) -RunDirectory $crossSourceRun `
            -AuthorizationReceiptPath (
                Join-Path $crossSourceRun $revisionAuthorizationRelative
            ) -SelectionMaterialPath $crossSourceSelection `
            -SelectionKey $authorizedSelectionKey | Out-Null
    } 'did not conserve finding occurrence' (
        'A finding occurrence cannot move from one durable source to another.'
    )

    $rearmReuseRun = Join-Path $testRoot 'revision-rearm-reuse'
    Copy-Item -LiteralPath $revisionReadyRun -Destination $rearmReuseRun -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rearmReuseRun -NodeId 'review' -Status running `
            -ThreadId 'review-thread' `
            -MilestoneRevisionAuthorizationReceiptPath (
                $revisionAuthorizationRelative
            ) -Message 'Attempt duplicate revision re-arm.' `
            -Evidence @('observation:duplicate-rearm') `
            -IdempotencyKey 'controller:duplicate-rearm' | Out-Null
    } 'already used' 'Each source may be re-armed only once per revision.'

    $checkpoint2 = Join-Path $run 'materials/checkpoint-method-2.json'
    Set-Content -LiteralPath $checkpoint2 -Value '{"milestone":"method-2"}'
    $currentReview = New-SourceChain -Run $run -SourceNodeId 'review' `
        -ThreadId 'review-thread' -MilestoneId 'method-2' `
        -CheckpointPath $checkpoint2 -Stem 'review.method-2' -Severity 'P1' `
        -FindingText 'current-review-p1' -Resolution 'open'
    $currentDomain = New-SourceChain -Run $run -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' -MilestoneId 'method-2' `
        -CheckpointPath $checkpoint2 -Stem 'domain.method-2' -Severity 'P1' `
        -FindingText 'current-domain-p1' -Resolution 'open'
    $selectionPath = Join-Path $run 'materials/method-2-selection.json'
    @(
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $currentReview.result_path
            disposition_receipt_path = $currentReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $currentDomain.result_path
            disposition_receipt_path = $currentDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $selectionPath -Encoding utf8
    $authorizationPath = Join-Path $run 'materials/method-2-authorization.md'
    Set-Content -LiteralPath $authorizationPath `
        -Value 'Controller activates exactly method-2.'
    $acceptanceEvidencePath = Join-Path $run (
        'materials/method-2-main-acceptance.md'
    )
    Set-Content -LiteralPath $acceptanceEvidencePath -Value (
        'Main owner integrated the exact method-2 source reports.'
    )
    $acceptanceAuthorizationPath = Join-Path $run (
        'materials/method-2-acceptance-authorization.json'
    )
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'method-2'
        main_node_id = 'integrate'
        acceptance_key = 'controller:accept-method-2'
        evidence_material_path = 'materials/method-2-main-acceptance.md'
        evidence_material_hash = (
            Get-FileHash -LiteralPath $acceptanceEvidencePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $acceptanceAuthorizationPath -Encoding utf8

    $unselectedCompletion = & (
        Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1'
    ) -RunDirectory $run | ConvertFrom-Json -Depth 30
    Assert-True (
        $unselectedCompletion.complete -and
        $unselectedCompletion.active_review_milestone -eq 'method-1'
    ) (
        'Unactivated versioned receipts must not be selected merely because ' +
        'their files exist.'
    )
    $preActivation = Join-Path $testRoot 'pre-activation'
    Copy-Item -LiteralPath $run -Destination $preActivation -Recurse
    $resolvedRun = Join-Path $testRoot 'resolved-acceptance'
    Copy-Item -LiteralPath $preActivation -Destination $resolvedRun -Recurse
    $resolvedCheckpoint = Join-Path $resolvedRun (
        'materials/checkpoint-method-2.json'
    )
    $resolvedReview = New-SourceChain -Run $resolvedRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-2' -CheckpointPath $resolvedCheckpoint `
        -Stem 'review.method-2.resolved' -Severity 'P1' `
        -FindingText 'resolved-review-p1' -Resolution 'resolved'
    $resolvedDomain = New-SourceChain -Run $resolvedRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-2' -CheckpointPath $resolvedCheckpoint `
        -Stem 'domain.method-2.resolved' -Severity 'P1' `
        -FindingText 'resolved-domain-p1' -Resolution 'resolved'
    $resolvedSelectionPath = Join-Path $resolvedRun (
        'materials/method-2-resolved-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $resolvedReview.result_path
            disposition_receipt_path = $resolvedReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $resolvedDomain.result_path
            disposition_receipt_path = $resolvedDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $resolvedSelectionPath -Encoding utf8
    $resolvedAuthorizationPath = Join-Path $resolvedRun (
        'materials/method-2-resolved-authorization.md'
    )
    Set-Content -LiteralPath $resolvedAuthorizationPath `
        -Value 'Controller activates resolved method-2.'
    & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneActivationReceipt.ps1'
    )) -RunDirectory $resolvedRun -MilestoneId 'method-2' `
        -SelectionPath $resolvedSelectionPath `
        -AuthorizationMaterialPath $resolvedAuthorizationPath `
        -AcceptanceAuthorizationMaterialPath (
            Join-Path $resolvedRun (
                'materials/method-2-acceptance-authorization.json'
            )
        ) `
        -ActivationKey 'controller:resolved-method-2' | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $resolvedRun | Out-Null
    } 'lacks main-owner acceptance' (
        'A later milestone cannot reuse the main acceptance from its baseline.'
    )
    $acceptance = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
    )) -RunDirectory $resolvedRun -MilestoneId 'method-2' |
        ConvertFrom-Json -Depth 100
    $resolvedCompletion = & (
        Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1'
    ) -RunDirectory $resolvedRun | ConvertFrom-Json -Depth 30
    Assert-True (
        $resolvedCompletion.complete -and
        $acceptance.milestone_id -eq 'method-2'
    ) 'A fresh bound main-owner acceptance may complete the active milestone.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
        )) -RunDirectory $resolvedRun -MilestoneId 'method-2' |
            Out-Null
    } 'already exists' 'A milestone acceptance cannot be recorded twice.'
    $resignedKeyRun = Join-Path $testRoot 'resigned-acceptance-key'
    Copy-Item -LiteralPath $resolvedRun -Destination $resignedKeyRun -Recurse
    Resign-AcceptanceTail -Run $resignedKeyRun -ReceiptMutation {
        param($receipt)
        $receipt.acceptance_key = 'controller:forged-method-2'
    }
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $resignedKeyRun | Out-Null
    } 'does not match the active review chain' (
        'A coherently re-signed acceptance key cannot replace the activation ' +
        'authorization anchor.'
    )
    $resignedEvidenceRun = Join-Path $testRoot 'resigned-acceptance-evidence'
    Copy-Item -LiteralPath $resolvedRun -Destination $resignedEvidenceRun `
        -Recurse
    $alternateEvidencePath = Join-Path $resignedEvidenceRun (
        'materials/alternate-main-acceptance.md'
    )
    Set-Content -LiteralPath $alternateEvidencePath `
        -Value 'A different run-local file must not replace anchored evidence.'
    $alternateEvidenceHash = (
        Get-FileHash -LiteralPath $alternateEvidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Resign-AcceptanceTail -Run $resignedEvidenceRun -ReceiptMutation {
        param($receipt)
        $receipt.evidence_material_path =
            'materials/alternate-main-acceptance.md'
        $receipt.evidence_material_hash = $alternateEvidenceHash
    }
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $resignedEvidenceRun | Out-Null
    } 'does not match the active review chain' (
        'Coherently re-signed evidence cannot replace the activation anchor.'
    )

    # Keep one valid recovery-cycle receipt from the baseline milestone. After
    # method-2 becomes active, this immutable method-1 receipt must still
    # validate against its own activation epoch without blocking a new
    # method-2/checkpoint recovery cycle.
    $historicalRecoveryCheckpoint = Join-Path $run (
        'materials/checkpoint-method-1-historical-recovery.json'
    )
    $historicalRecoveryInput = Join-Path $run (
        'materials/input-method-1-historical-recovery.json'
    )
    $historicalRecoveryCapture = Join-Path $run (
        'thread-reads/review.method-1-historical-recovery-progress.json'
    )
    Set-Content -LiteralPath $historicalRecoveryCheckpoint -Value (
        '{"milestone":"method-1","checkpoint":"historical-recovery"}'
    )
    Set-Content -LiteralPath $historicalRecoveryInput -Value (
        '{"scope":"method-1-historical-recovery"}'
    )
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = 'review-thread' }
        page = [ordered]@{ order = 'newest_first' }
        latestAssistantMessageId = $null
        turns = @(
            [ordered]@{
                id = 'method-1-historical-recovery-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'commentary'
                        text = 'Method-1 recovery had progress but no final.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $historicalRecoveryCapture -Encoding utf8
    $historicalRecovery = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $run -SourceNodeId 'review' `
        -OriginalThreadId 'review-thread' `
        -CheckpointManifestPath $historicalRecoveryCheckpoint `
        -InputManifestPath $historicalRecoveryInput `
        -ThreadReadPath $historicalRecoveryCapture `
        -MilestoneId 'method-1' -Attempt 1 |
        ConvertFrom-Json -Depth 50

    $activation = & (
        Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )
    ) -RunDirectory $run -MilestoneId 'method-2' `
        -SelectionPath $selectionPath `
        -AuthorizationMaterialPath $authorizationPath `
        -AcceptanceAuthorizationMaterialPath $acceptanceAuthorizationPath `
        -ActivationKey 'controller:self-test-method-2' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        $activation.milestone_id -eq 'method-2' -and
        @($activation.source_bindings).Count -eq 2
    ) 'Activation must bind the next milestone and every durable source.'
    $activeChain = Read-DurableReviewMilestoneActivationChain `
        -RunDirectory $run
    Assert-True (
        $activeChain.active_milestone_id -eq 'method-2' -and
        $activeChain.activation_receipt_hash -eq $activation.receipt_hash
    ) 'The append-only chain must select the activated milestone.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
        )) -RunDirectory $run -MilestoneId 'method-1' `
            -CheckpointMaterialPath $checkpoint2 `
            -InputManifestPath $selectionPath `
            -ReviewMaterialManifestPath $selectionPath `
            -ExcludedEvidenceManifestPath $selectionPath `
            -AuthorizationMaterialPath $authorizationPath `
            -AcceptanceAuthorizationMaterialPath $acceptanceAuthorizationPath `
            -SelectionKey 'controller:reject-revision-after-later-milestone' `
            -ActivationKey 'controller:reject-revision-after-later-milestone' |
            Out-Null
    } 'cannot replace or skip a later milestone' (
        'A first-milestone revision cannot be authorized after a later ' +
        'milestone activation.'
    )

    # A later checkpoint can lose its final after a milestone activation selected
    # source receipts without appending another node lifecycle chain. The active
    # source binding, not the older node-level receipt, is the verified prior
    # review in this shape.
    $activeRecoveryRun = Join-Path $testRoot 'active-milestone-recovery'
    Copy-Item -LiteralPath $run -Destination $activeRecoveryRun -Recurse
    $activeRecoveryCheckpoint = Join-Path $activeRecoveryRun (
        'materials/checkpoint-method-2-recovery.json'
    )
    $activeRecoveryInput = Join-Path $activeRecoveryRun (
        'materials/input-method-2-recovery.json'
    )
    $activeRecoveryCapture = Join-Path $activeRecoveryRun (
        'thread-reads/review.method-2-recovery-progress.json'
    )
    Set-Content -LiteralPath $activeRecoveryCheckpoint -Value (
        '{"milestone":"method-2","checkpoint":"recovery"}'
    )
    Set-Content -LiteralPath $activeRecoveryInput -Value (
        '{"scope":"method-2-recovery"}'
    )
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = 'review-thread' }
        page = [ordered]@{ order = 'newest_first' }
        latestAssistantMessageId = $null
        turns = @(
            [ordered]@{
                id = 'method-2-recovery-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'commentary'
                        text = 'Method-2 recovery has progress but no final.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $activeRecoveryCapture -Encoding utf8
    $activeRecovery = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $activeRecoveryRun -SourceNodeId 'review' `
        -OriginalThreadId 'review-thread' `
        -CheckpointManifestPath $activeRecoveryCheckpoint `
        -InputManifestPath $activeRecoveryInput `
        -ThreadReadPath $activeRecoveryCapture `
        -MilestoneId 'method-2' -Attempt 1 |
        ConvertFrom-Json -Depth 50
    $historicalRecoveryPath = Join-Path $run (
        'receipts/review.cycle-' +
        [string]$historicalRecovery.recovery_cycle_id +
        '.attempt-1.result-recovery.json'
    )
    $historicalRecoveryReadback = Read-ThreadResultRecoveryReceipt `
        -Path $historicalRecoveryPath -RunDirectory $run `
        -ExpectedSourceNodeId 'review' `
        -ExpectedOriginalThreadId 'review-thread' `
        -ExpectedRecoveryStage 'original'
    Assert-True (
        [string]$historicalRecoveryReadback.milestone_id -eq 'method-1' -and
        [string]$activeRecovery.milestone_id -eq 'method-2' -and
        [string]$historicalRecoveryReadback.recovery_cycle_id -ne
            [string]$activeRecovery.recovery_cycle_id
    ) (
        'A historical recovery cycle must retain its own milestone epoch while ' +
        'a later active milestone starts a distinct attempt-one cycle.'
    )
    $historicalCycleTamperRun = Join-Path $testRoot (
        'historical-recovery-cycle-tamper'
    )
    Copy-Item -LiteralPath $activeRecoveryRun `
        -Destination $historicalCycleTamperRun -Recurse
    $historicalCycleTamperPath = Join-Path $historicalCycleTamperRun (
        'receipts/' + [IO.Path]::GetFileName($historicalRecoveryPath)
    )
    $historicalCycleTamper = Get-Content -LiteralPath (
        $historicalCycleTamperPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    $historicalCycleTamper.recovery_cycle_id = ('f' * 64)
    $historicalCycleTamper.Remove('receipt_hash')
    $historicalCycleTamper.receipt_hash = Get-TextSha256 (
        $historicalCycleTamper | ConvertTo-Json -Compress -Depth 50
    )
    $historicalCycleTamper | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $historicalCycleTamperPath -Encoding utf8
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt `
            -Path $historicalCycleTamperPath `
            -RunDirectory $historicalCycleTamperRun `
            -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'review-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'cycle binding is invalid' (
        'A self-rehashed historical receipt cannot replace its recovery cycle.'
    )

    $historicalEpochTamperRun = Join-Path $testRoot (
        'historical-recovery-activation-epoch-tamper'
    )
    Copy-Item -LiteralPath $activeRecoveryRun `
        -Destination $historicalEpochTamperRun -Recurse
    $historicalEpochTamperPath = Join-Path $historicalEpochTamperRun (
        'receipts/' + [IO.Path]::GetFileName($historicalRecoveryPath)
    )
    $historicalEpochTamper = Get-Content -LiteralPath (
        $historicalEpochTamperPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    $historicalEpochTamper.milestone_activation_receipt_hash =
        [string]$activation.receipt_hash
    $historicalEpochTamper.Remove('receipt_hash')
    $historicalEpochTamper.receipt_hash = Get-TextSha256 (
        $historicalEpochTamper | ConvertTo-Json -Compress -Depth 50
    )
    $historicalEpochTamper | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $historicalEpochTamperPath -Encoding utf8
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt `
            -Path $historicalEpochTamperPath `
            -RunDirectory $historicalEpochTamperRun `
            -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'review-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'Historical baseline recovery activation is invalid' (
        'A historical receipt cannot claim the current milestone activation epoch.'
    )
    $activeRecoveryRelativePath = (
        'receipts/review.cycle-' +
        [string]$activeRecovery.recovery_cycle_id +
        '.attempt-1.result-recovery.json'
    )
    $activeRecoveryEvent = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $activeRecoveryRun -NodeId 'review' `
        -Status 'result_pending' -ThreadId 'review-thread' `
        -Message 'Method-2 checkpoint final missing.' `
        -ErrorClass 'final_missing_with_progress_evidence' `
        -RecoveryReceiptPath $activeRecoveryRelativePath `
        -IdempotencyKey 'method-2-active-binding-result-pending' |
        ConvertFrom-Json -Depth 50
    Assert-True (
        [string]$activeRecoveryEvent.previous_review_binding_kind -eq
            'active-milestone-source-binding' -and
        [string]$activeRecoveryEvent.previous_result_receipt_hash -eq
            [string]$currentReview.result_hash -and
        [string]$activeRecoveryEvent.previous_disposition_receipt_hash -eq
            [string]$currentReview.disposition_hash -and
        [string]$activeRecoveryEvent.
            previous_milestone_activation_receipt_hash -eq
            [string]$activation.receipt_hash -and
        [int]$activeRecoveryEvent.
            previous_milestone_activation_event_sequence -ge 1 -and
        [string]$activeRecoveryEvent.
            previous_milestone_activation_event_hash -match '^[0-9a-f]{64}$'
    ) (
        'Recovery re-entry must bind the active milestone source result, ' +
        'disposition, and activation event instead of the older lifecycle.'
    )

    $sameCheckpointRun = Join-Path $testRoot (
        'active-milestone-recovery-same-checkpoint'
    )
    Copy-Item -LiteralPath $run -Destination $sameCheckpointRun -Recurse
    $sameCheckpointInput = Join-Path $sameCheckpointRun (
        'materials/input-method-2-same-checkpoint.json'
    )
    $sameCheckpointCapture = Join-Path $sameCheckpointRun (
        'thread-reads/review.method-2-same-checkpoint-progress.json'
    )
    Set-Content -LiteralPath $sameCheckpointInput -Value (
        '{"scope":"method-2-same-checkpoint"}'
    )
    Copy-Item -LiteralPath $activeRecoveryCapture `
        -Destination $sameCheckpointCapture
    $sameCheckpointRecovery = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $sameCheckpointRun -SourceNodeId 'review' `
        -OriginalThreadId 'review-thread' `
        -CheckpointManifestPath (
            Join-Path $sameCheckpointRun 'materials/checkpoint-method-2.json'
        ) -InputManifestPath $sameCheckpointInput `
        -ThreadReadPath $sameCheckpointCapture `
        -MilestoneId 'method-2' -Attempt 1 |
        ConvertFrom-Json -Depth 50
    $sameCheckpointRelativePath = (
        'receipts/review.cycle-' +
        [string]$sameCheckpointRecovery.recovery_cycle_id +
        '.attempt-1.result-recovery.json'
    )
    $sameCheckpointJournal = Get-Content -LiteralPath (
        Join-Path $sameCheckpointRun 'events.jsonl'
    ) -Raw
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $sameCheckpointRun -NodeId 'review' `
            -Status 'result_pending' -ThreadId 'review-thread' `
            -Message 'Replay the selected checkpoint.' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath $sameCheckpointRelativePath `
            -IdempotencyKey 'reject-active-binding-checkpoint-replay' |
            Out-Null
    } 'requires a new checkpoint' (
        'The active milestone source binding cannot reopen its own checkpoint.'
    )
    Assert-True (
        (Get-Content -LiteralPath (
            Join-Path $sameCheckpointRun 'events.jsonl'
        ) -Raw) -eq $sameCheckpointJournal
    ) 'Rejected active-binding checkpoint replay must not change the journal.'

    $selectionTamperRun = Join-Path $testRoot (
        'active-milestone-recovery-selection-tamper'
    )
    Copy-Item -LiteralPath $activeRecoveryRun `
        -Destination $selectionTamperRun -Recurse
    Copy-Item -LiteralPath (Join-Path $run 'events.jsonl') `
        -Destination (Join-Path $selectionTamperRun 'events.jsonl') -Force
    Add-Content -LiteralPath (
        Join-Path $selectionTamperRun 'materials/method-2-selection.json'
    ) -Value ' '
    $selectionTamperJournal = Get-Content -LiteralPath (
        Join-Path $selectionTamperRun 'events.jsonl'
    ) -Raw
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $selectionTamperRun -NodeId 'review' `
            -Status 'result_pending' -ThreadId 'review-thread' `
            -Message 'Use a changed milestone selection.' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath $activeRecoveryRelativePath `
            -IdempotencyKey 'reject-active-selection-tamper' |
            Out-Null
    } 'selection binding changed' (
        'A changed active milestone selection must fail before journal write.'
    )
    Assert-True (
        (Get-Content -LiteralPath (
            Join-Path $selectionTamperRun 'events.jsonl'
        ) -Raw) -eq $selectionTamperJournal
    ) 'Rejected active selection tamper must not change the journal.'

    $activationTamperRun = Join-Path $testRoot (
        'active-milestone-recovery-activation-tamper'
    )
    Copy-Item -LiteralPath $activeRecoveryRun `
        -Destination $activationTamperRun -Recurse
    Copy-Item -LiteralPath (Join-Path $run 'events.jsonl') `
        -Destination (Join-Path $activationTamperRun 'events.jsonl') -Force
    $activationTamperPath = Join-Path $activationTamperRun (
        'receipts/durable-review-milestone.method-2.activation.json'
    )
    $activationTamper = Get-Content -LiteralPath $activationTamperPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $activationTamper.activation_key = 'controller:changed-after-activation'
    $activationTamper | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $activationTamperPath -Encoding utf8
    $activationTamperJournal = Get-Content -LiteralPath (
        Join-Path $activationTamperRun 'events.jsonl'
    ) -Raw
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $activationTamperRun -NodeId 'review' `
            -Status 'result_pending' -ThreadId 'review-thread' `
            -Message 'Use a changed activation receipt.' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath $activeRecoveryRelativePath `
            -IdempotencyKey 'reject-active-activation-tamper' |
            Out-Null
    } 'Milestone activation receipt binding is invalid' (
        'A changed milestone activation must invalidate its recovery cycle.'
    )
    Assert-True (
        (Get-Content -LiteralPath (
            Join-Path $activationTamperRun 'events.jsonl'
        ) -Raw) -eq $activationTamperJournal
    ) 'Rejected active activation tamper must not change the journal.'

    foreach ($materialAttack in @(
        [ordered]@{
            name = 'checkpoint'
            path = 'materials/checkpoint-method-2-recovery.json'
            expected = 'Checkpoint manifest is missing or changed'
        },
        [ordered]@{
            name = 'input'
            path = 'materials/input-method-2-recovery.json'
            expected = 'Input manifest is missing or changed'
        }
    )) {
        $materialTamperRun = Join-Path $testRoot (
            'active-milestone-recovery-' + $materialAttack.name + '-tamper'
        )
        Copy-Item -LiteralPath $activeRecoveryRun `
            -Destination $materialTamperRun -Recurse
        Copy-Item -LiteralPath (Join-Path $run 'events.jsonl') `
            -Destination (Join-Path $materialTamperRun 'events.jsonl') -Force
        Add-Content -LiteralPath (
            Join-Path $materialTamperRun $materialAttack.path
        ) -Value 'changed'
        $materialTamperJournal = Get-Content -LiteralPath (
            Join-Path $materialTamperRun 'events.jsonl'
        ) -Raw
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $materialTamperRun -NodeId 'review' `
                -Status 'result_pending' -ThreadId 'review-thread' `
                -Message "Use changed $($materialAttack.name) material." `
                -ErrorClass 'final_missing_with_progress_evidence' `
                -RecoveryReceiptPath $activeRecoveryRelativePath `
                -IdempotencyKey (
                    'reject-active-' + $materialAttack.name + '-tamper'
                ) | Out-Null
        } $materialAttack.expected (
            "A changed recovery $($materialAttack.name) must fail closed."
        )
        Assert-True (
            (Get-Content -LiteralPath (
                Join-Path $materialTamperRun 'events.jsonl'
            ) -Raw) -eq $materialTamperJournal
        ) "Rejected $($materialAttack.name) tamper must not change the journal."
    }

    $currentError = ''
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $run | Out-Null
    } catch { $currentError = $_.Exception.Message }
    Assert-True (
        $currentError -like '*current-review-p1*' -and
        $currentError -like '*current-domain-p1*' -and
        $currentError -like '*lacks main-owner acceptance*' -and
        $currentError -notlike '*baseline-review-p0*' -and
        $currentError -notlike '*baseline-domain-p0*'
    ) 'Completion must report only the active milestone findings.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneAcceptanceReceipt.ps1'
        )) -RunDirectory $run -MilestoneId 'method-2' | Out-Null
    } 'unresolved P0/P1' (
        'Main-owner acceptance cannot precede resolution of active blockers.'
    )

    # A later declared milestone may resolve part of the active P1 inventory
    # while carrying the rest forward. Requiring final main acceptance before
    # that transition would deadlock the declared milestone sequence.
    $scopePlanPath = Join-Path $testRoot 'scope-transition-plan.json'
    New-ReviewPlan -Path $scopePlanPath -MilestoneIds @(
        'scope-1', 'scope-2', 'scope-3'
    )
    $scopeRun = Join-Path $testRoot 'scope-transition-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $scopePlanPath -RunDirectory $scopeRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($directory in @('materials', 'thread-reads', 'receipts')) {
        $path = Join-Path $scopeRun $directory
        if (-not (Test-Path -LiteralPath $path)) {
            $null = New-Item -ItemType Directory -Path $path
        }
    }
    $scopeCheckpoint1 = Join-Path $scopeRun 'materials/scope-1.json'
    Set-Content -LiteralPath $scopeCheckpoint1 -Value '{"scope":1}'
    $scopeBaselineReview = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-1' -CheckpointPath $scopeCheckpoint1 `
        -Stem 'review' -Severity 'P1' `
        -FindingText 'scope-baseline-review' -Resolution 'resolved'
    $scopeBaselineDomain = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-1' -CheckpointPath $scopeCheckpoint1 `
        -Stem 'domain' -Severity 'P1' `
        -FindingText 'scope-baseline-domain' -Resolution 'resolved'
    Convert-SourceChainToHistoricalAlias -Run $scopeRun `
        -Chain $scopeBaselineReview -Alias 'scope-1-historical'
    Convert-SourceChainToHistoricalAlias -Run $scopeRun `
        -Chain $scopeBaselineDomain -Alias 'scope-1-historical'
    Complete-SourceLifecycle -Run $scopeRun -SourceNodeId 'review' `
        -ThreadId 'review-thread' `
        -ResultRelativePath $scopeBaselineReview.result_path
    Complete-SourceLifecycle -Run $scopeRun -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' `
        -ResultRelativePath $scopeBaselineDomain.result_path
    foreach ($status in @('running', 'completed', 'validated')) {
        $arguments = @{
            RunDirectory = $scopeRun
            NodeId = 'integrate'
            Status = $status
            Message = "scope integrate $status"
            IdempotencyKey = "scope-integrate-$status"
        }
        if ($status -eq 'completed') {
            $arguments.Evidence = @('observation:scope-baseline-integrated')
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
            Out-Null
    }
    $scopeArtifact = Join-Path $testRoot 'artifacts/final'
    if (-not (Test-Path -LiteralPath $scopeArtifact)) {
        $null = New-Item -ItemType Directory -Path $scopeArtifact -Force
    }
    Set-Content -LiteralPath (Join-Path $scopeArtifact 'result.md') `
        -Value 'scope transition result'

    $scopeCheckpoint2 = Join-Path $scopeRun 'materials/scope-2.json'
    Set-Content -LiteralPath $scopeCheckpoint2 -Value '{"scope":2}'
    $scopeReview2 = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-2' -CheckpointPath $scopeCheckpoint2 `
        -Stem 'scope-2-review' -Severity 'P1' `
        -FindingText 'scope-review-p1' -Resolution 'open' `
        -FindingId 'scope-review-p1' `
        -CanonicalFindingId 'scope-review-p1'
    $scopeDomain2 = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-2' -CheckpointPath $scopeCheckpoint2 `
        -Stem 'scope-2-domain' -Severity 'P1' `
        -FindingText 'scope-domain-p1' -Resolution 'open' `
        -FindingId 'scope-domain-p1' `
        -CanonicalFindingId 'scope-domain-p1'
    $scopeSelection2 = Join-Path $scopeRun 'materials/scope-2-selection.json'
    @(
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $scopeReview2.result_path
            disposition_receipt_path = $scopeReview2.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $scopeDomain2.result_path
            disposition_receipt_path = $scopeDomain2.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $scopeSelection2
    $scopeAuthorization2 = Join-Path $scopeRun (
        'materials/scope-2-authorization.md'
    )
    Set-Content -LiteralPath $scopeAuthorization2 `
        -Value 'Controller activates scope-2.'
    $scopeAcceptanceEvidence2 = Join-Path $scopeRun (
        'materials/scope-2-main-acceptance.md'
    )
    Set-Content -LiteralPath $scopeAcceptanceEvidence2 `
        -Value 'Main owner acceptance evidence for scope-2.'
    $scopeAcceptanceAuthorization2 = Join-Path $scopeRun (
        'materials/scope-2-acceptance-authorization.json'
    )
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'scope-2'
        main_node_id = 'integrate'
        acceptance_key = 'controller:accept-scope-2'
        evidence_material_path = 'materials/scope-2-main-acceptance.md'
        evidence_material_hash = (
            Get-FileHash -LiteralPath $scopeAcceptanceEvidence2 `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $scopeAcceptanceAuthorization2
    & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneActivationReceipt.ps1'
    )) -RunDirectory $scopeRun -MilestoneId 'scope-2' `
        -SelectionPath $scopeSelection2 `
        -AuthorizationMaterialPath $scopeAuthorization2 `
        -AcceptanceAuthorizationMaterialPath $scopeAcceptanceAuthorization2 `
        -ActivationKey 'controller:activate-scope-2' | Out-Null

    $scopeCheckpoint3 = Join-Path $scopeRun 'materials/scope-3.json'
    Set-Content -LiteralPath $scopeCheckpoint3 -Value '{"scope":3}'
    $scopeReview3 = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-3' -CheckpointPath $scopeCheckpoint3 `
        -Stem 'scope-3-review' -Severity 'P1' `
        -FindingText 'scope-review-p1' -Resolution 'resolved' `
        -FindingId 'scope-review-p1' `
        -CanonicalFindingId 'scope-review-p1'
    $scopeDomain3 = New-SourceChain -Run $scopeRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-3' -CheckpointPath $scopeCheckpoint3 `
        -Stem 'scope-3-domain' -Severity 'P1' `
        -FindingText 'scope-domain-p1' -Resolution 'open' `
        -FindingId 'scope-domain-p1' `
        -CanonicalFindingId 'scope-domain-p1'
    $scopeSelection3 = Join-Path $scopeRun 'materials/scope-3-selection.json'
    @(
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $scopeReview3.result_path
            disposition_receipt_path = $scopeReview3.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $scopeDomain3.result_path
            disposition_receipt_path = $scopeDomain3.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $scopeSelection3
    $scopeAuthorization3 = Join-Path $scopeRun (
        'materials/scope-3-authorization.md'
    )
    Set-Content -LiteralPath $scopeAuthorization3 `
        -Value 'Controller activates scope-3.'
    $scopeTransitionAuthorization = Join-Path $scopeRun (
        'materials/scope-2-to-scope-3-transition.md'
    )
    Set-Content -LiteralPath $scopeTransitionAuthorization -Value (
        'Controller accepts the scope-2 boundary and carries unresolved ' +
        'source occurrences into scope-3 without final acceptance.'
    )
    $scopeAcceptanceEvidence3 = Join-Path $scopeRun (
        'materials/scope-3-main-acceptance.md'
    )
    Set-Content -LiteralPath $scopeAcceptanceEvidence3 `
        -Value 'Main owner acceptance evidence for scope-3.'
    $scopeAcceptanceAuthorization3 = Join-Path $scopeRun (
        'materials/scope-3-acceptance-authorization.json'
    )
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'scope-3'
        main_node_id = 'integrate'
        acceptance_key = 'controller:accept-scope-3'
        evidence_material_path = 'materials/scope-3-main-acceptance.md'
        evidence_material_hash = (
            Get-FileHash -LiteralPath $scopeAcceptanceEvidence3 `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $scopeAcceptanceAuthorization3
    $scopeReadyRun = Join-Path $testRoot 'scope-transition-ready'
    Copy-Item -LiteralPath $scopeRun -Destination $scopeReadyRun -Recurse
    $scopeJournalHash = (
        Get-FileHash -LiteralPath (Join-Path $scopeRun 'events.jsonl') `
            -Algorithm SHA256
    ).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )) -RunDirectory $scopeRun -MilestoneId 'scope-3' `
            -SelectionPath $scopeSelection3 `
            -AuthorizationMaterialPath $scopeAuthorization3 `
            -AcceptanceAuthorizationMaterialPath $scopeAcceptanceAuthorization3 `
            -ActivationKey 'controller:scope-3-without-transition' | Out-Null
    } 'lacks main-owner acceptance' (
        'Ordinary activation cannot bypass the prior final acceptance gate.'
    )
    Assert-True (
        $scopeJournalHash -eq (
            Get-FileHash -LiteralPath (Join-Path $scopeRun 'events.jsonl') `
                -Algorithm SHA256
        ).Hash
    ) 'Rejected ordinary activation must not mutate the journal.'

    $missingCarryRun = Join-Path $testRoot 'scope-transition-missing-carry'
    Copy-Item -LiteralPath $scopeReadyRun -Destination $missingCarryRun -Recurse
    $missingDomain = New-SourceChain -Run $missingCarryRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $missingCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-domain-missing' -Severity 'P1' `
        -FindingText 'replacement cannot erase the old occurrence' `
        -Resolution 'open' -FindingId 'different-domain-p1' `
        -CanonicalFindingId 'different-domain-p1'
    $missingSelectionPath = Join-Path $missingCarryRun (
        'materials/scope-3-selection.json'
    )
    $missingSelection = @(
        Get-Content -LiteralPath $missingSelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $missingSelection[1].result_receipt_path = $missingDomain.result_path
    $missingSelection[1].disposition_receipt_path =
        $missingDomain.disposition_path
    $missingSelection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $missingSelectionPath
    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $missingCarryRun `
            -SelectionPath $missingSelectionPath `
            -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-missing-carry' | Out-Null
    } 'lost a carry-forward occurrence' (
        'A later milestone cannot omit an open source finding occurrence.'
    )

    $downgradedCarryRun = Join-Path $testRoot (
        'scope-transition-severity-downgrade'
    )
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $downgradedCarryRun -Recurse
    $downgradedReview = New-SourceChain -Run $downgradedCarryRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $downgradedCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-review-downgraded' -Severity 'P2' `
        -FindingText 'scope-review-p1' -Resolution 'resolved' `
        -FindingId 'scope-review-p1' `
        -CanonicalFindingId 'scope-review-p1'
    $downgradedSelectionPath = Join-Path $downgradedCarryRun (
        'materials/scope-3-selection.json'
    )
    $downgradedSelection = @(
        Get-Content -LiteralPath $downgradedSelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $downgradedSelection[0].result_receipt_path =
        $downgradedReview.result_path
    $downgradedSelection[0].disposition_receipt_path =
        $downgradedReview.disposition_path
    $downgradedSelection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $downgradedSelectionPath
    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $downgradedCarryRun `
            -SelectionPath $downgradedSelectionPath `
            -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-carry-downgrade' | Out-Null
    } 'changed a carry-forward occurrence' (
        'A carried P1 cannot be downgraded to P2.'
    )

    $textDriftCarryRun = Join-Path $testRoot 'scope-transition-text-drift'
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $textDriftCarryRun -Recurse
    $textDriftReview = New-SourceChain -Run $textDriftCarryRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $textDriftCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-review-text-drift' -Severity 'P1' `
        -FindingText 'scope-review-p1-rewritten' -Resolution 'resolved' `
        -FindingId 'scope-review-p1' `
        -CanonicalFindingId 'scope-review-p1'
    $textDriftCarrySelectionPath = Join-Path $textDriftCarryRun (
        'materials/scope-3-selection.json'
    )
    $textDriftCarrySelection = @(
        Get-Content -LiteralPath $textDriftCarrySelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $textDriftCarrySelection[0].result_receipt_path =
        $textDriftReview.result_path
    $textDriftCarrySelection[0].disposition_receipt_path =
        $textDriftReview.disposition_path
    $textDriftCarrySelection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $textDriftCarrySelectionPath
    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $textDriftCarryRun `
            -SelectionPath $textDriftCarrySelectionPath `
            -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-carry-text-drift' | Out-Null
    } 'changed a carry-forward occurrence' (
        'A carried finding cannot change its exact text or text hash.'
    )

    $crossSourceCarryRun = Join-Path $testRoot (
        'scope-transition-cross-source'
    )
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $crossSourceCarryRun -Recurse
    $crossSourceReview = New-SourceChain -Run $crossSourceCarryRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $crossSourceCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-review-cross-source' -Severity 'P1' `
        -FindingText 'scope-domain-p1' -Resolution 'open' `
        -FindingId 'scope-domain-p1' `
        -CanonicalFindingId 'scope-domain-p1'
    $crossSourceDomain = New-SourceChain -Run $crossSourceCarryRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $crossSourceCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-domain-cross-source' -Severity 'P1' `
        -FindingText 'scope-review-p1' -Resolution 'resolved' `
        -FindingId 'scope-review-p1' `
        -CanonicalFindingId 'scope-review-p1'
    $crossSourceSelectionPath = Join-Path $crossSourceCarryRun (
        'materials/scope-3-selection.json'
    )
    @(
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $crossSourceReview.result_path
            disposition_receipt_path = $crossSourceReview.disposition_path
        },
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $crossSourceDomain.result_path
            disposition_receipt_path = $crossSourceDomain.disposition_path
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $crossSourceSelectionPath
    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $crossSourceCarryRun `
            -SelectionPath $crossSourceSelectionPath `
            -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-cross-source-carry' | Out-Null
    } 'lost a carry-forward occurrence' (
        'Canonical overlap cannot move a source occurrence to another source.'
    )

    $fullyResolvedCarryRun = Join-Path $testRoot (
        'scope-transition-fully-resolved'
    )
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $fullyResolvedCarryRun -Recurse
    $resolvedDomain = New-SourceChain -Run $fullyResolvedCarryRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'scope-3' -CheckpointPath (
            Join-Path $fullyResolvedCarryRun 'materials/scope-3.json'
        ) -Stem 'scope-3-domain-resolved' -Severity 'P1' `
        -FindingText 'scope-domain-p1' -Resolution 'resolved' `
        -FindingId 'scope-domain-p1' `
        -CanonicalFindingId 'scope-domain-p1'
    $fullyResolvedSelectionPath = Join-Path $fullyResolvedCarryRun (
        'materials/scope-3-selection.json'
    )
    $fullyResolvedSelection = @(
        Get-Content -LiteralPath $fullyResolvedSelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $fullyResolvedSelection[1].result_receipt_path = $resolvedDomain.result_path
    $fullyResolvedSelection[1].disposition_receipt_path =
        $resolvedDomain.disposition_path
    $fullyResolvedSelection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $fullyResolvedSelectionPath
    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $fullyResolvedCarryRun `
            -SelectionPath $fullyResolvedSelectionPath `
            -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-final-acceptance-bypass' |
            Out-Null
    } 'cannot bypass final main acceptance' (
        'Once every prior blocker is resolved, final main acceptance is required.'
    )

    Assert-ThrowsLike {
        Invoke-ScopeTransitionActivation -Run $scopeReadyRun `
            -SelectionPath (
                Join-Path $scopeReadyRun 'materials/scope-3-selection.json'
            ) -ScopeTransitionKey 'Controller:scope-2-to-scope-3' `
            -ActivationKey 'controller:reject-scope-key-case' | Out-Null
    } 'stable, exact user: or controller: keys' (
        'Scope transition keys are exact and cannot use a case variant.'
    )

    $scopeActivation = Invoke-ScopeTransitionActivation `
        -Run $scopeReadyRun -SelectionPath (
            Join-Path $scopeReadyRun 'materials/scope-3-selection.json'
        ) -ScopeTransitionKey 'controller:scope-2-to-scope-3' `
        -ActivationKey 'controller:activate-scope-3' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$scopeActivation.schema_version -eq '1.2' -and
        [string]$scopeActivation.previous_milestone_gate -eq
            'scoped-carry-forward' -and
        [int]$scopeActivation.previous_open_occurrence_count -eq 2 -and
        [int]$scopeActivation.remaining_open_occurrence_count -eq 1
    ) (
        'Scoped activation must record exact prior and remaining occurrence ' +
        'counts without claiming final acceptance.'
    )
    $scopeCompletionError = ''
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $scopeReadyRun | Out-Null
    } catch { $scopeCompletionError = $_.Exception.Message }
    Assert-True (
        $scopeCompletionError -like '*scope-domain-p1*' -and
        $scopeCompletionError -like '*lacks main-owner acceptance*' -and
        $scopeCompletionError -notlike '*scope-review-p1*'
    ) (
        'Completion must select the next milestone, keep only its unresolved ' +
        'occurrences, and still require independent final main acceptance.'
    )

    $resignedScopeKeyRun = Join-Path $testRoot (
        'scope-transition-resigned-key'
    )
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $resignedScopeKeyRun -Recurse
    Resign-ScopeActivationTail -Run $resignedScopeKeyRun `
        -ReceiptMutation {
            param($receipt)
            $receipt.scope_transition_key =
                'user:replacement-scope-authority'
        }
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneActivationChain `
            -RunDirectory $resignedScopeKeyRun | Out-Null
    } 'pre-existing authorization' (
        'Changing the scope key in the activation receipt and journal tail ' +
        'cannot replace the earlier authorization.'
    )

    $resignedScopePathRun = Join-Path $testRoot (
        'scope-transition-resigned-material'
    )
    Copy-Item -LiteralPath $scopeReadyRun `
        -Destination $resignedScopePathRun -Recurse
    $alternateScopeMaterial = Join-Path $resignedScopePathRun (
        'materials/alternate-scope-transition.md'
    )
    Set-Content -LiteralPath $alternateScopeMaterial `
        -Value 'A different scope transition authority.'
    $alternateScopeMaterialHash = (
        Get-FileHash -LiteralPath $alternateScopeMaterial -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Resign-ScopeActivationTail -Run $resignedScopePathRun `
        -ReceiptMutation {
            param($receipt)
            $receipt.scope_transition_authorization_material_path =
                'materials/alternate-scope-transition.md'
            $receipt.scope_transition_authorization_material_hash =
                $alternateScopeMaterialHash
        }
    Assert-ThrowsLike {
        Read-DurableReviewMilestoneActivationChain `
            -RunDirectory $resignedScopePathRun | Out-Null
    } 'pre-existing authorization' (
        'Changing the scope material path and hash in the activation tail ' +
        'cannot replace the earlier authorization.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )) -RunDirectory $run -MilestoneId 'method-2' `
            -SelectionPath $selectionPath `
            -AuthorizationMaterialPath $authorizationPath `
            -AcceptanceAuthorizationMaterialPath $acceptanceAuthorizationPath `
            -ActivationKey 'controller:duplicate-method-2' | Out-Null
    } 'not the next declared milestone' (
        'A milestone cannot be activated twice.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )) -RunDirectory $preActivation -MilestoneId 'method-3' `
            -SelectionPath (
                Join-Path $preActivation 'materials/method-2-selection.json'
            ) -AuthorizationMaterialPath (
                Join-Path $preActivation 'materials/method-2-authorization.md'
            ) -AcceptanceAuthorizationMaterialPath (
                Join-Path $preActivation (
                    'materials/method-2-acceptance-authorization.json'
                )
            ) -ActivationKey 'controller:skip-method-2' | Out-Null
    } 'not the next declared milestone' (
        'An undeclared or skipped milestone must fail closed.'
    )

    $duplicateSourceRun = Join-Path $testRoot 'duplicate-source'
    Copy-Item -LiteralPath $preActivation -Destination $duplicateSourceRun `
        -Recurse
    $duplicateSelection = Join-Path $duplicateSourceRun (
        'materials/method-2-selection.json'
    )
    $duplicate = @(
        Get-Content -LiteralPath $duplicateSelection -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $duplicate[1].source_node_id = 'review'
    $duplicate | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $duplicateSelection
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )) -RunDirectory $duplicateSourceRun -MilestoneId 'method-2' `
            -SelectionPath $duplicateSelection `
            -AuthorizationMaterialPath (
                Join-Path $duplicateSourceRun (
                    'materials/method-2-authorization.md'
                )
            ) -AcceptanceAuthorizationMaterialPath (
                Join-Path $duplicateSourceRun (
                    'materials/method-2-acceptance-authorization.json'
                )
            ) -ActivationKey 'controller:duplicate-source' | Out-Null
    } 'missing or repeated' (
        'One durable source cannot replace another source binding.'
    )

    $differentCheckpointRun = Join-Path $testRoot 'different-checkpoint'
    Copy-Item -LiteralPath $preActivation `
        -Destination $differentCheckpointRun -Recurse
    $otherCheckpoint = Join-Path $differentCheckpointRun (
        'materials/checkpoint-method-2-other.json'
    )
    Set-Content -LiteralPath $otherCheckpoint `
        -Value '{"milestone":"method-2","different":true}'
    $differentDomain = New-SourceChain -Run $differentCheckpointRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-2' -CheckpointPath $otherCheckpoint `
        -Stem 'domain.method-2.other' -Severity 'P1' `
        -FindingText 'current-domain-other-checkpoint' -Resolution 'open'
    $differentSelectionPath = Join-Path $differentCheckpointRun (
        'materials/method-2-selection.json'
    )
    $differentSelection = @(
        Get-Content -LiteralPath $differentSelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $differentSelection[1].result_receipt_path =
        $differentDomain.result_path
    $differentSelection[1].disposition_receipt_path =
        $differentDomain.disposition_path
    $differentSelection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $differentSelectionPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneActivationReceipt.ps1'
        )) -RunDirectory $differentCheckpointRun `
            -MilestoneId 'method-2' `
            -SelectionPath $differentSelectionPath `
            -AuthorizationMaterialPath (
                Join-Path $differentCheckpointRun (
                    'materials/method-2-authorization.md'
                )
            ) -AcceptanceAuthorizationMaterialPath (
                Join-Path $differentCheckpointRun (
                    'materials/method-2-acceptance-authorization.json'
                )
            ) -ActivationKey 'controller:different-checkpoint' | Out-Null
    } 'same checkpoint material' (
        'Sources from different checkpoints cannot share one activation.'
    )

    $unboundResultRun = Join-Path $testRoot 'unbound-result'
    Copy-Item -LiteralPath $preActivation -Destination $unboundResultRun `
        -Recurse
    $unboundResultPath = Join-Path $unboundResultRun (
        'receipts/review.method-2.thread-result-receipt.json'
    )
    $unboundResult = Get-Content -LiteralPath $unboundResultPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 50
    foreach ($name in @(
        'milestone_id', 'checkpoint_material_path',
        'checkpoint_material_hash'
    )) {
        $unboundResult.Remove($name)
    }
    $unboundPayload = [ordered]@{}
    foreach ($key in $unboundResult.Keys | Where-Object {
        $_ -ne 'receipt_hash'
    }) {
        $unboundPayload[$key] = $unboundResult[$key]
    }
    $unboundResult.receipt_hash = Get-TextSha256 (
        $unboundPayload | ConvertTo-Json -Compress -Depth 30
    )
    $unboundResult | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $unboundResultPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
            -RunDirectory $unboundResultRun -MilestoneId 'method-2' `
            -SourceNodeId 'review' -SourceThreadId 'review-thread' `
            -SourceResultReceiptPath $unboundResultPath `
            -DecisionsPath (
                Join-Path $unboundResultRun (
                    'materials/review.method-2-decisions.json'
                )
            ) -OutputPath (
                Join-Path $unboundResultRun (
                    'receipts/review.method-2.unbound.disposition.json'
                )
            ) | Out-Null
    } 'milestone and checkpoint binding' (
        'A new durable disposition cannot use an unbound result receipt.'
    )

    $deletedReceiptRun = Join-Path $testRoot 'deleted-activation'
    Copy-Item -LiteralPath $run -Destination $deletedReceiptRun -Recurse
    Remove-Item -LiteralPath (
        Join-Path $deletedReceiptRun (
            'receipts/durable-review-milestone.method-2.activation.json'
        )
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $deletedReceiptRun | Out-Null
    } 'receipt and journal event counts do not match' (
        'Deleting an activation receipt must not roll completion back.'
    )

    $tamperedSelectionRun = Join-Path $testRoot 'tampered-selection'
    Copy-Item -LiteralPath $run -Destination $tamperedSelectionRun -Recurse
    Add-Content -LiteralPath (
        Join-Path $tamperedSelectionRun 'materials/method-2-selection.json'
    ) -Value ' '
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $tamperedSelectionRun | Out-Null
    } 'selection binding changed' (
        'Changed selection material must invalidate the active milestone.'
    )

    $tamperedDispositionRun = Join-Path $testRoot 'tampered-disposition'
    Copy-Item -LiteralPath $run -Destination $tamperedDispositionRun -Recurse
    $tamperedDispositionPath = Join-Path $tamperedDispositionRun (
        'receipts/review.method-2.disposition.json'
    )
    $tamperedDisposition = Get-Content -LiteralPath $tamperedDispositionPath `
        -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    $tamperedDisposition.decisions[0].rationale = 'changed after activation'
    $tamperedDisposition | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $tamperedDispositionPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $tamperedDispositionRun | Out-Null
    } 'receipt hash mismatch' (
        'Changed active disposition content must fail closed.'
    )

    $successorPlanPath = Join-Path $testRoot 'successor-plan.json'
    New-ReviewPlan -Path $successorPlanPath
    $successorPlan = Get-Content -LiteralPath $successorPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $successorPlan.run_id = 'durable-successor-self-test'
    $successorPlan.goal = 'Adopt unresolved predecessor P1 obligations.'
    $successorPlan.durable_review_profile.milestone_ids = @(
        'group-1', 'group-2'
    )
    foreach ($node in @($successorPlan.nodes | Where-Object {
        $_.id -in @('review', 'domain')
    })) {
        $node.context.session_policy = 'reuse'
        $node.context.max_prior_turns = 1
        $node.context.prior_thread_id = "$($node.id)-thread"
        $node.context.prior_handoff = "handoffs/$($node.id).md"
        $node.context.prior_handoff_hash = ('a' * 64)
        $node.context.reuse_reason = 'Continue the same durable source.'
    }
    $successorPlan.successor_review_profile = [ordered]@{
        predecessor_run_id = 'durable-milestone-self-test'
        predecessor_active_milestone_id = 'method-2'
        predecessor_checkpoint_material_hash = (
            Get-FileHash -LiteralPath $checkpoint2 -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        source_node_ids = @('domain', 'review')
    }
    $successorPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $successorPlanPath -Encoding utf8
    $authorizationPath = Join-Path $run (
        'materials/successor-authorization.md'
    )
    Set-Content -LiteralPath $authorizationPath -Value (
        'Controller authorizes one successor run for the unresolved P1 set.'
    )
    $predecessorBeforeExport = Join-Path $testRoot (
        'predecessor-before-successor-export'
    )
    Copy-Item -LiteralPath $run -Destination $predecessorBeforeExport -Recurse
    $export = & (Join-Path $scriptRoot (
        'New-DurableReviewSuccessorExportReceipt.ps1'
    )) -PredecessorRunDirectory $run `
        -SuccessorPlanPath $successorPlanPath `
        -SuccessorRunDirectory (Join-Path $testRoot 'successor-run') `
        -AuthorizationMaterialPath $authorizationPath `
        -ActivationKey 'controller:self-test-successor' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        @($export.open_obligations).Count -eq 2 -and
        @($export.source_bindings).Count -eq 2
    ) 'Successor export must bind every source and unresolved P1.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewSuccessorExportReceipt.ps1'
        )) -PredecessorRunDirectory $run `
            -SuccessorPlanPath $successorPlanPath `
            -SuccessorRunDirectory (Join-Path $testRoot 'successor-run') `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:self-test-successor-fork' | Out-Null
    } 'already has a successor export' (
        'A predecessor cannot export duplicate or forked successors.'
    )

    $wrongThreadPlanPath = Join-Path $testRoot 'wrong-thread-successor.json'
    $wrongThreadPlan = Get-Content -LiteralPath $successorPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    @($wrongThreadPlan.nodes | Where-Object {
        $_.id -eq 'review'
    })[0].context.prior_thread_id = 'different-review-thread'
    $wrongThreadPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $wrongThreadPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewSuccessorExportReceipt.ps1'
        )) -PredecessorRunDirectory $predecessorBeforeExport `
            -SuccessorPlanPath $wrongThreadPlanPath `
            -SuccessorRunDirectory (
                Join-Path $testRoot 'wrong-thread-successor-run'
            ) `
            -AuthorizationMaterialPath (
                Join-Path $predecessorBeforeExport (
                    'materials/successor-authorization.md'
                )
            ) -ActivationKey 'controller:wrong-thread-successor' | Out-Null
    } 'role/thread continuity' (
        'A successor cannot reuse a different or unbound source thread.'
    )
    $freshPlanPath = Join-Path $testRoot 'fresh-successor.json'
    $freshPlan = Get-Content -LiteralPath $successorPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshNode = @($freshPlan.nodes | Where-Object {
        $_.id -eq 'review'
    })[0]
    $freshNode.context.session_policy = 'fresh'
    $freshNode.context.max_prior_turns = 0
    foreach ($name in @(
        'prior_thread_id', 'prior_handoff', 'prior_handoff_hash',
        'reuse_reason'
    )) {
        $freshNode.context.Remove($name)
    }
    $freshPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $freshPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $freshPlanPath -WorkspaceRoot $testRoot | Out-Null
    } 'must explicitly reuse' (
        'A successor durable source cannot silently start a fresh thread.'
    )
    $openP0Run = Join-Path $testRoot 'open-p0-predecessor'
    Copy-Item -LiteralPath $preActivation -Destination $openP0Run -Recurse
    $openP0Checkpoint = Join-Path $openP0Run (
        'materials/checkpoint-method-2.json'
    )
    $openP0Review = New-SourceChain -Run $openP0Run `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-2' -CheckpointPath $openP0Checkpoint `
        -Stem 'review.method-2.open-p0' -Severity 'P0' `
        -FindingText 'open-review-p0' -Resolution 'open'
    $openP0SelectionPath = Join-Path $openP0Run (
        'materials/method-2-selection.json'
    )
    $openP0Selection = @(
        Get-Content -LiteralPath $openP0SelectionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $openP0Selection[0].result_receipt_path = $openP0Review.result_path
    $openP0Selection[0].disposition_receipt_path =
        $openP0Review.disposition_path
    $openP0Selection | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $openP0SelectionPath
    & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneActivationReceipt.ps1'
    )) -RunDirectory $openP0Run -MilestoneId 'method-2' `
        -SelectionPath $openP0SelectionPath `
        -AuthorizationMaterialPath (
            Join-Path $openP0Run 'materials/method-2-authorization.md'
        ) -AcceptanceAuthorizationMaterialPath (
            Join-Path $openP0Run (
                'materials/method-2-acceptance-authorization.json'
            )
        ) -ActivationKey 'controller:open-p0-method-2' | Out-Null
    Set-Content -LiteralPath (
        Join-Path $openP0Run 'materials/successor-authorization.md'
    ) -Value 'Controller must not export unresolved P0.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewSuccessorExportReceipt.ps1'
        )) -PredecessorRunDirectory $openP0Run `
            -SuccessorPlanPath $successorPlanPath `
            -SuccessorRunDirectory (
                Join-Path $testRoot 'open-p0-successor'
            ) -AuthorizationMaterialPath (
                Join-Path $openP0Run 'materials/successor-authorization.md'
            ) -ActivationKey 'controller:open-p0-successor' | Out-Null
    } 'cannot carry unresolved P0' (
        'A successor cannot move unresolved P0 into a later run.'
    )

    $genesisOnly = Join-Path $testRoot 'successor-genesis-only'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $successorPlanPath -RunDirectory $genesisOnly `
        -WorkspaceRoot $testRoot | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $genesisOnly | Out-Null
    } 'successor adoption' (
        'A successor plan cannot complete from a copied or bare genesis.'
    )

    $successorRun = Join-Path $testRoot 'successor-run'
    $adoption = & (Join-Path $scriptRoot (
        'New-OrchestrationSuccessorRun.ps1'
    )) -PlanPath $successorPlanPath -RunDirectory $successorRun `
        -WorkspaceRoot $testRoot -PredecessorRunDirectory $run `
        -PredecessorExportReceiptPath (
            Join-Path $run 'receipts/durable-review-successor.export.json'
        ) | ConvertFrom-Json -Depth 100
    Assert-True (
        @($adoption.inherited_obligations).Count -eq 2 -and
        $adoption.predecessor_run_id -eq 'durable-milestone-self-test'
    ) 'Successor adoption must preserve the predecessor obligation set.'

    # Build a separate first-generation successor, cancel one source before any
    # review message, then roll it forward without rewriting its history.
    $abandonedPredecessor = Join-Path $testRoot 'abandoned-predecessor'
    Copy-Item -LiteralPath $predecessorBeforeExport `
        -Destination $abandonedPredecessor -Recurse
    $abandonedPlanPath = Join-Path $testRoot 'abandoned-successor-plan.json'
    $abandonedPlan = Get-Content -LiteralPath $successorPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $abandonedPlan.run_id = 'durable-abandoned-self-test'
    $abandonedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $abandonedPlanPath -Encoding utf8
    $abandonedRun = Join-Path $testRoot 'abandoned-successor-run'
    & (Join-Path $scriptRoot 'New-DurableReviewSuccessorExportReceipt.ps1') `
        -PredecessorRunDirectory $abandonedPredecessor `
        -SuccessorPlanPath $abandonedPlanPath `
        -SuccessorRunDirectory $abandonedRun `
        -AuthorizationMaterialPath (
            Join-Path $abandonedPredecessor (
                'materials/successor-authorization.md'
            )
        ) -ActivationKey 'controller:abandoned-base-export' | Out-Null
    & (Join-Path $scriptRoot 'New-OrchestrationSuccessorRun.ps1') `
        -PlanPath $abandonedPlanPath -RunDirectory $abandonedRun `
        -WorkspaceRoot $testRoot -PredecessorRunDirectory $abandonedPredecessor `
        -PredecessorExportReceiptPath (
            Join-Path $abandonedPredecessor (
                'receipts/durable-review-successor.export.json'
            )
        ) | Out-Null
    foreach ($directory in @('materials', 'thread-reads')) {
        $path = Join-Path $abandonedRun $directory
        if (-not (Test-Path -LiteralPath $path)) {
            $null = New-Item -ItemType Directory -Path $path
        }
    }
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $arguments = @{
            RunDirectory = $abandonedRun
            NodeId = 'review'
            Status = $status
            Message = "prospective review $status"
            IdempotencyKey = "abandoned-review-$status"
        }
        if ($status -eq 'materialized') {
            $arguments.ThreadId = 'review-thread'
            $arguments.ModelId = 'gpt-5.6-sol'
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
            Out-Null
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $abandonedRun -NodeId 'review' -Status 'cancelled' `
        -Message 'Controller changed checkpoint before review dispatch.' `
        -Evidence @(
            'source:controller-checkpoint-ruling',
            'observation:no-review-message-dispatched'
        ) -IdempotencyKey 'controller:cancel-undispatched-review' | Out-Null

    $abandonedCheckpoint = Join-Path $abandonedRun (
        'materials/checkpoint-next.json'
    )
    Set-Content -LiteralPath $abandonedCheckpoint -Value (
        '{"milestone":"next"}'
    )
    $unactivatedReview = New-SourceChain -Run $abandonedRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'group-1' `
        -CheckpointPath $abandonedCheckpoint -Stem 'unactivated-review' `
        -Severity 'P1' -FindingText 'unactivated-review-p1' -Resolution 'open'
    $unactivatedDomain = New-SourceChain -Run $abandonedRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'group-1' `
        -CheckpointPath $abandonedCheckpoint -Stem 'unactivated-domain' `
        -Severity 'P1' -FindingText 'unactivated-domain-p1' -Resolution 'open'
    $unactivatedManifestPath = Join-Path $abandonedRun (
        'materials/unactivated-evidence.json'
    )
    @(
        [ordered]@{
            source_node_id = 'domain'
            result_receipt_path = $unactivatedDomain.result_path
            result_receipt_file_hash = (
                Get-FileHash -LiteralPath (
                    Join-Path $abandonedRun $unactivatedDomain.result_path
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            disposition_receipt_path = $unactivatedDomain.disposition_path
            disposition_receipt_file_hash = (
                Get-FileHash -LiteralPath (
                    Join-Path $abandonedRun $unactivatedDomain.disposition_path
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            completion_eligible = $false
        },
        [ordered]@{
            source_node_id = 'review'
            result_receipt_path = $unactivatedReview.result_path
            result_receipt_file_hash = (
                Get-FileHash -LiteralPath (
                    Join-Path $abandonedRun $unactivatedReview.result_path
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            disposition_receipt_path = $unactivatedReview.disposition_path
            disposition_receipt_file_hash = (
                Get-FileHash -LiteralPath (
                    Join-Path $abandonedRun $unactivatedReview.disposition_path
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            completion_eligible = $false
        }
    ) | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $unactivatedManifestPath -Encoding utf8
    $additionalPath = Join-Path $abandonedRun (
        'materials/additional-findings.json'
    )
    $additionalText = 'new controller P1 after the abandoned review cycle'
    @(
        [ordered]@{
            source_node_id = 'review'
            source_finding_id = 'LY-ADV-R06-P1-001'
            canonical_finding_id = 'canonical-LY-ADV-R06-P1-001'
            severity = 'P1'
            finding = $additionalText
            finding_hash = Get-TextSha256 $additionalText
            resolution_status = 'open'
        }
    ) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $additionalPath -Encoding utf8
    $abandonmentAuthorization = Join-Path $abandonedRun (
        'materials/abandonment-authorization.md'
    )
    Set-Content -LiteralPath $abandonmentAuthorization -Value (
        'Controller authorizes one fresh successor for the next checkpoint.'
    )

    $freshAbandonedPlanPath = Join-Path $testRoot (
        'fresh-after-abandonment-plan.json'
    )
    $freshAbandonedPlan = Get-Content -LiteralPath $abandonedPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshAbandonedPlan.run_id = 'durable-fresh-after-abandonment'
    $freshAbandonedPlan.durable_review_profile.milestone_ids = @(
        'next-group', 'final-gate'
    )
    foreach ($node in @($freshAbandonedPlan.nodes | Where-Object {
        $_.id -in @('review', 'domain')
    })) {
        $node.max_attempts = 2
    }
    $freshAbandonedPlan.successor_review_profile = [ordered]@{
        predecessor_run_id = 'durable-abandoned-self-test'
        predecessor_active_milestone_id =
            'abandoned-before-first-milestone'
        predecessor_checkpoint_material_hash = (
            Get-FileHash -LiteralPath $abandonedCheckpoint -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        source_node_ids = @('domain', 'review')
    }
    $freshAbandonedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $freshAbandonedPlanPath -Encoding utf8
    $freshAbandonedRun = Join-Path $testRoot (
        'fresh-after-abandonment-run'
    )

    $abandonedEventsPath = Join-Path $abandonedRun 'events.jsonl'
    $abandonedEventLines = @(Get-Content -LiteralPath $abandonedEventsPath)
    try {
        $cancelledEvent = $abandonedEventLines[-1] |
            ConvertFrom-Json -AsHashtable -Depth 100
        $cancelledEvent.evidence = @(
            'source:controller-checkpoint-ruling',
            'observation:review-message-dispatched'
        )
        $cancelledEvent.Remove('hash')
        $cancelledEvent.hash = Get-OrchestrationEventHash (
            [pscustomobject]$cancelledEvent
        )
        $changed = @($abandonedEventLines)
        $changed[-1] = $cancelledEvent |
            ConvertTo-Json -Compress -Depth 100
        $changed | Set-Content -LiteralPath $abandonedEventsPath -Encoding utf8
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-AbandonedSuccessorAuthorizationReceipt.ps1'
            )) -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath `
                -SuccessorRunDirectory $freshAbandonedRun `
                -CheckpointMaterialPath $abandonedCheckpoint `
                -AdditionalFindingRecordsPath $additionalPath `
                -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
                -AuthorizationMaterialPath $abandonmentAuthorization `
                -ActivationKey 'controller:dispatched-review-rejected' |
                Out-Null
        } 'no-dispatch evidence' (
            'A dispatched review cannot use abandoned-successor recovery.'
        )
    }
    finally {
        $abandonedEventLines |
            Set-Content -LiteralPath $abandonedEventsPath -Encoding utf8
    }

    try {
        $tail = $abandonedEventLines[-1] |
            ConvertFrom-Json -AsHashtable -Depth 100
        $activated = @{}
        foreach ($entry in $tail.GetEnumerator()) {
            $activated[$entry.Key] = $entry.Value
        }
        $activated.sequence = $abandonedEventLines.Count
        $activated.prev_hash = $tail.hash
        $activated.event = 'durable-review-milestone-activated'
        $activated.status = 'planned'
        $activated.idempotency_key = 'controller:forged-existing-activation'
        $activated.request_fingerprint = ('f' * 64)
        $activated.Remove('hash')
        $activated.hash = Get-OrchestrationEventHash (
            [pscustomobject]$activated
        )
        Add-Content -LiteralPath $abandonedEventsPath -Value (
            $activated | ConvertTo-Json -Compress -Depth 100
        )
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-AbandonedSuccessorAuthorizationReceipt.ps1'
            )) -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath `
                -SuccessorRunDirectory $freshAbandonedRun `
                -CheckpointMaterialPath $abandonedCheckpoint `
                -AdditionalFindingRecordsPath $additionalPath `
                -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
                -AuthorizationMaterialPath $abandonmentAuthorization `
                -ActivationKey 'controller:activated-run-rejected' | Out-Null
        } 'activated or accepted milestone' (
            'An activated durable milestone forbids abandonment recovery.'
        )
    }
    finally {
        $abandonedEventLines |
            Set-Content -LiteralPath $abandonedEventsPath -Encoding utf8
    }

    $additionalRaw = Get-Content -LiteralPath $additionalPath -Raw
    try {
        $badAdditional = @($additionalRaw |
            ConvertFrom-Json -AsHashtable -Depth 20)
        $badAdditional[0].severity = 'P2'
        $badAdditional | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $additionalPath -Encoding utf8
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-AbandonedSuccessorAuthorizationReceipt.ps1'
            )) -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath `
                -SuccessorRunDirectory $freshAbandonedRun `
                -CheckpointMaterialPath $abandonedCheckpoint `
                -AdditionalFindingRecordsPath $additionalPath `
                -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
                -AuthorizationMaterialPath $abandonmentAuthorization `
                -ActivationKey 'controller:downgraded-new-finding' | Out-Null
        } 'severity' 'A new inherited P1 cannot be downgraded.'
    }
    finally {
        Set-Content -LiteralPath $additionalPath -Value $additionalRaw `
            -Encoding utf8
    }

    $freshPlanRaw = Get-Content -LiteralPath $freshAbandonedPlanPath -Raw
    try {
        $badAttemptPlan = $freshPlanRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        @($badAttemptPlan.nodes | Where-Object {
            $_.id -eq 'review'
        })[0].max_attempts = 1
        $badAttemptPlan | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $freshAbandonedPlanPath -Encoding utf8
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-AbandonedSuccessorAuthorizationReceipt.ps1'
            )) -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath `
                -SuccessorRunDirectory $freshAbandonedRun `
                -CheckpointMaterialPath $abandonedCheckpoint `
                -AdditionalFindingRecordsPath $additionalPath `
                -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
                -AuthorizationMaterialPath $abandonmentAuthorization `
                -ActivationKey 'controller:attempt-reset-rejected' | Out-Null
        } 'consumed attempts' 'A fresh run cannot reset a consumed attempt.'
    }
    finally {
        Set-Content -LiteralPath $freshAbandonedPlanPath -Value $freshPlanRaw `
            -Encoding utf8
    }

    try {
        $wrongContinuityPlan = $freshPlanRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        @($wrongContinuityPlan.nodes | Where-Object {
            $_.id -eq 'review'
        })[0].context.prior_thread_id = 'substituted-review-thread'
        $wrongContinuityPlan | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $freshAbandonedPlanPath -Encoding utf8
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-AbandonedSuccessorAuthorizationReceipt.ps1'
            )) -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath `
                -SuccessorRunDirectory $freshAbandonedRun `
                -CheckpointMaterialPath $abandonedCheckpoint `
                -AdditionalFindingRecordsPath $additionalPath `
                -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
                -AuthorizationMaterialPath $abandonmentAuthorization `
                -ActivationKey 'controller:thread-substitution-rejected' |
                Out-Null
        } 'source continuity' (
            'A fresh successor cannot substitute a durable source thread.'
        )
    }
    finally {
        Set-Content -LiteralPath $freshAbandonedPlanPath -Value $freshPlanRaw `
            -Encoding utf8
    }

    $authorizationAnchor = & (Join-Path $scriptRoot (
        'New-AbandonedSuccessorAuthorizationReceipt.ps1'
    )) -AbandonedRunDirectory $abandonedRun `
        -SuccessorPlanPath $freshAbandonedPlanPath `
        -SuccessorRunDirectory $freshAbandonedRun `
        -CheckpointMaterialPath $abandonedCheckpoint `
        -AdditionalFindingRecordsPath $additionalPath `
        -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
        -AuthorizationMaterialPath $abandonmentAuthorization `
        -ActivationKey 'controller:abandon-successor-once' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        $authorizationAnchor.lineage_kind -eq
            'abandoned-successor-authorization'
    ) 'Abandoned successor authorization must be recorded before export.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-AbandonedSuccessorAuthorizationReceipt.ps1'
        )) -AbandonedRunDirectory $abandonedRun `
            -SuccessorPlanPath $freshAbandonedPlanPath `
            -SuccessorRunDirectory $freshAbandonedRun `
            -CheckpointMaterialPath $abandonedCheckpoint `
            -AdditionalFindingRecordsPath $additionalPath `
            -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
            -AuthorizationMaterialPath $abandonmentAuthorization `
            -ActivationKey 'controller:duplicate-authorization' | Out-Null
    } 'already has an authorization anchor' (
        'An abandoned successor cannot authorize two fresh runs.'
    )
    $authorizationReceiptPath = Join-Path $abandonedRun (
        'receipts/durable-review-abandoned-successor.authorization.json'
    )
    $abandonedExport = & (Join-Path $scriptRoot (
        'New-AbandonedSuccessorExportReceipt.ps1'
    )) -AbandonedRunDirectory $abandonedRun `
        -SuccessorPlanPath $freshAbandonedPlanPath `
        -SuccessorRunDirectory $freshAbandonedRun `
        -CheckpointMaterialPath $abandonedCheckpoint `
        -AdditionalFindingRecordsPath $additionalPath `
        -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
        -AuthorizationReceiptPath $authorizationReceiptPath |
        ConvertFrom-Json -Depth 100
    Assert-True (
        @($abandonedExport.inherited_obligations).Count -eq 3 -and
        @($abandonedExport.source_bindings | Where-Object {
            $_.source_node_id -eq 'review'
        })[0].inherited_attempt_count -eq 1
    ) 'Abandoned export must preserve obligations and consumed attempts.'

    $abandonedExportPath = Join-Path $abandonedRun (
        'receipts/durable-review-abandoned-successor.export.json'
    )
    $abandonedExportRaw = Get-Content -LiteralPath $abandonedExportPath -Raw
    $postExportLines = @(Get-Content -LiteralPath $abandonedEventsPath)
    try {
        $mutatedExport = $abandonedExportRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $mutatedExport.activation_key = 'controller:resigned-export-key'
        $mutatedExport.Remove('receipt_hash')
        $mutatedExport.receipt_hash = Get-TextSha256 (
            $mutatedExport | ConvertTo-Json -Compress -Depth 100
        )
        $mutatedExport | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $abandonedExportPath -Encoding utf8
        $mutatedLines = @($postExportLines)
        $tail = $mutatedLines[-1] |
            ConvertFrom-Json -AsHashtable -Depth 100
        $tail.result_receipt_hash = $mutatedExport.receipt_hash
        $tail.request_fingerprint = $mutatedExport.receipt_hash
        $tail.idempotency_key = $mutatedExport.activation_key
        $tail.Remove('hash')
        $tail.hash = Get-OrchestrationEventHash ([pscustomobject]$tail)
        $mutatedLines[-1] = $tail | ConvertTo-Json -Compress -Depth 100
        $mutatedLines |
            Set-Content -LiteralPath $abandonedEventsPath -Encoding utf8
        Assert-ThrowsLike {
            Read-AbandonedSuccessorExportReceipt `
                -Path $abandonedExportPath `
                -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath | Out-Null
        } 'authorization anchor changed' (
            'A re-signed export cannot replace the pre-bound activation key.'
        )
    }
    finally {
        Set-Content -LiteralPath $abandonedExportPath `
            -Value $abandonedExportRaw -Encoding utf8
        $postExportLines |
            Set-Content -LiteralPath $abandonedEventsPath -Encoding utf8
    }

    $authorizationMaterialRaw = Get-Content `
        -LiteralPath $abandonmentAuthorization -Raw
    try {
        Set-Content -LiteralPath $abandonmentAuthorization `
            -Value 'changed controller authorization' -Encoding utf8
        Assert-ThrowsLike {
            Read-AbandonedSuccessorExportReceipt `
                -Path $abandonedExportPath `
                -AbandonedRunDirectory $abandonedRun `
                -SuccessorPlanPath $freshAbandonedPlanPath | Out-Null
        } 'authorization material' (
            'Authorization material cannot change after its anchor event.'
        )
    }
    finally {
        Set-Content -LiteralPath $abandonmentAuthorization `
            -Value $authorizationMaterialRaw -Encoding utf8 -NoNewline
    }

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-AbandonedSuccessorExportReceipt.ps1') `
            -AbandonedRunDirectory $abandonedRun `
            -SuccessorPlanPath $freshAbandonedPlanPath `
            -SuccessorRunDirectory $freshAbandonedRun `
            -CheckpointMaterialPath $abandonedCheckpoint `
            -AdditionalFindingRecordsPath $additionalPath `
            -UnactivatedEvidenceManifestPath $unactivatedManifestPath `
            -AuthorizationReceiptPath $authorizationReceiptPath | Out-Null
    } 'already has an export' (
        'An abandoned successor cannot fork or export twice.'
    )
    $freshAdoption = & (Join-Path $scriptRoot (
        'New-AbandonedSuccessorRun.ps1'
    )) -PlanPath $freshAbandonedPlanPath -RunDirectory $freshAbandonedRun `
        -WorkspaceRoot $testRoot -AbandonedRunDirectory $abandonedRun `
        -AbandonedExportReceiptPath (
            Join-Path $abandonedRun (
                'receipts/durable-review-abandoned-successor.export.json'
            )
        ) | ConvertFrom-Json -Depth 100
    Assert-True (
        $freshAdoption.lineage_kind -eq 'abandoned-successor' -and
        @($freshAdoption.inherited_obligations).Count -eq 3
    ) 'Fresh successor adoption must preserve the abandoned lineage.'
    $freshState = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $freshAbandonedRun | ConvertFrom-Json -Depth 30
    Assert-True (
        @($freshState.nodes | Where-Object {
            $_.id -eq 'review'
        })[0].attempts -eq 1
    ) 'Fresh successor state must expose the consumed review attempt.'
    $carriedLaunch = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $freshAbandonedRun -NodeId 'review' `
        -Status 'launch_reserved' -Message 'launch after carried attempt' `
        -IdempotencyKey 'fresh-review-attempt-two' |
        ConvertFrom-Json -Depth 30
    Assert-True ($carriedLaunch.attempt -eq 2) (
        'The next launch after abandonment must use attempt two.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $freshAbandonedRun | Out-Null
    } 'Inherited P1' (
        'Fresh successor genesis and adoption cannot complete inherited P1.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-OrchestrationSuccessorRun.ps1'
        )) -PlanPath $successorPlanPath `
            -RunDirectory (Join-Path $testRoot 'successor-run-fork') `
            -WorkspaceRoot $testRoot -PredecessorRunDirectory $run `
            -PredecessorExportReceiptPath (
                Join-Path $run (
                    'receipts/durable-review-successor.export.json'
                )
            ) | Out-Null
    } 'another run directory' (
        'One export cannot materialize a parallel successor directory.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $successorRun | Out-Null
    } 'Inherited P1' (
        'Inherited P1 obligations must block a new successor run.'
    )

    foreach ($directory in @('materials', 'thread-reads')) {
        $path = Join-Path $successorRun $directory
        if (-not (Test-Path -LiteralPath $path)) {
            $null = New-Item -ItemType Directory -Path $path
        }
    }
    $successorCheckpoint = Join-Path $successorRun (
        'materials/checkpoint-group-1.json'
    )
    Set-Content -LiteralPath $successorCheckpoint -Value (
        '{"milestone":"group-1"}'
    )
    $resolvedSuccessorReview = New-SourceChain -Run $successorRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'group-1' -CheckpointPath $successorCheckpoint `
        -Stem 'review' -Severity 'P1' `
        -FindingText 'current-review-p1' -Resolution 'resolved' `
        -FindingId 'review-method-2-finding' `
        -CanonicalFindingId 'canonical-review-method-2-finding'
    $resolvedSuccessorDomain = New-SourceChain -Run $successorRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'group-1' -CheckpointPath $successorCheckpoint `
        -Stem 'domain' -Severity 'P1' `
        -FindingText 'current-domain-p1' -Resolution 'resolved' `
        -FindingId 'domain-method-2-finding' `
        -CanonicalFindingId 'canonical-domain-method-2-finding'
    Complete-SourceLifecycle -Run $successorRun -SourceNodeId 'review' `
        -ThreadId 'review-thread' `
        -ResultRelativePath $resolvedSuccessorReview.result_path
    Complete-SourceLifecycle -Run $successorRun -SourceNodeId 'domain' `
        -ThreadId 'domain-thread' `
        -ResultRelativePath $resolvedSuccessorDomain.result_path
    foreach ($status in @('running', 'completed', 'validated')) {
        $arguments = @{
            RunDirectory = $successorRun
            NodeId = 'integrate'
            Status = $status
            Message = "successor integrate $status"
            IdempotencyKey = "successor-integrate-$status"
        }
        if ($status -eq 'completed') {
            $arguments.Evidence = @('observation:successor-integrated')
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
            Out-Null
    }
    $successorCompletion = & (Join-Path $scriptRoot (
        'Test-OrchestrationCompletion.ps1'
    )) -RunDirectory $successorRun | ConvertFrom-Json -Depth 30
    Assert-True $successorCompletion.complete (
        'Same-source resolved and re-reviewed inherited P1 may complete.'
    )
    Assert-AdoptionMutationRejected -Run $successorRun -ReceiptMutation {
        param($receipt)
        $receipt.predecessor_run_id = 'other-predecessor'
    } -Message 'Adoption cannot relabel its predecessor run.'
    Assert-AdoptionMutationRejected -Run $successorRun -ReceiptMutation {
        param($receipt)
        $receipt.predecessor_active_milestone_id = 'other-milestone'
    } -Message 'Adoption cannot relabel the predecessor terminal milestone.'
    Assert-AdoptionMutationRejected -Run $successorRun -ReceiptMutation {
        param($receipt)
        $receipt.checkpoint_material_hash = ('c' * 64)
    } -Message 'Adoption cannot relabel the inherited checkpoint.'
    Assert-AdoptionMutationRejected -Run $successorRun -ReceiptMutation {
        param($receipt)
        $receipt.successor_milestone_ids = @('other-1', 'other-2')
    } -Message 'Adoption cannot relabel the successor milestone declaration.'
    $copiedSuccessor = Join-Path $testRoot 'copied-successor-run'
    Copy-Item -LiteralPath $successorRun -Destination $copiedSuccessor -Recurse
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $copiedSuccessor | Out-Null
    } 'adoption run identity changed' (
        'Copying a successor directory cannot preserve its adoption identity.'
    )

    $tamperedExportRun = Join-Path $testRoot 'tampered-successor-export'
    Copy-Item -LiteralPath $predecessorBeforeExport `
        -Destination $tamperedExportRun -Recurse
    & (Join-Path $scriptRoot (
        'New-DurableReviewSuccessorExportReceipt.ps1'
    )) -PredecessorRunDirectory $tamperedExportRun `
        -SuccessorPlanPath $successorPlanPath `
        -SuccessorRunDirectory (
            Join-Path $testRoot 'tampered-successor-run'
        ) `
        -AuthorizationMaterialPath (
            Join-Path $tamperedExportRun (
                'materials/successor-authorization.md'
            )
        ) -ActivationKey 'controller:tampered-export-fixture' | Out-Null
    $tamperedExportPath = Join-Path $tamperedExportRun (
        'receipts/durable-review-successor.export.json'
    )
    Resign-SuccessorExportTail -Run $tamperedExportRun -ReceiptMutation {
        param($receipt)
        $receipt.open_obligations =
            @($receipt.open_obligations | Select-Object -Skip 1)
    }
    Assert-ThrowsLike {
        Read-DurableReviewSuccessorExportReceipt -Path $tamperedExportPath `
            -PredecessorRunDirectory $tamperedExportRun `
            -SuccessorPlanPath $successorPlanPath | Out-Null
    } 'bound runs' (
        'Omitting an inherited P1 must invalidate the export chain.'
    )
    $severityRun = Join-Path $testRoot 'downgraded-successor-severity'
    Copy-Item -LiteralPath $predecessorBeforeExport `
        -Destination $severityRun -Recurse
    & (Join-Path $scriptRoot (
        'New-DurableReviewSuccessorExportReceipt.ps1'
    )) -PredecessorRunDirectory $severityRun `
        -SuccessorPlanPath $successorPlanPath `
        -SuccessorRunDirectory (
            Join-Path $testRoot 'severity-successor-run'
        ) `
        -AuthorizationMaterialPath (
            Join-Path $severityRun 'materials/successor-authorization.md'
        ) -ActivationKey 'controller:severity-export-fixture' | Out-Null
    Resign-SuccessorExportTail -Run $severityRun -ReceiptMutation {
        param($receipt)
        $receipt.open_obligations[0].severity = 'P2'
    }
    Assert-ThrowsLike {
        Read-DurableReviewSuccessorExportReceipt -Path (
            Join-Path $severityRun (
                'receipts/durable-review-successor.export.json'
            )
        ) -PredecessorRunDirectory $severityRun `
            -SuccessorPlanPath $successorPlanPath | Out-Null
    } 'bound runs' (
        'An inherited P1 severity cannot be downgraded and re-signed.'
    )

    $copiedPredecessor = Join-Path $testRoot 'copied-predecessor'
    Copy-Item -LiteralPath $run -Destination $copiedPredecessor -Recurse
    Assert-ThrowsLike {
        Read-DurableReviewSuccessorExportReceipt -Path (
            Join-Path $copiedPredecessor (
                'receipts/durable-review-successor.export.json'
            )
        ) -PredecessorRunDirectory $copiedPredecessor `
            -SuccessorPlanPath $successorPlanPath | Out-Null
    } 'bound runs' (
        'Copying a predecessor directory cannot replay its export.'
    )

    # A pending revision whose control material is self-contradictory may be
    # abandoned exactly once.  The audit must bind two run-local objects and
    # the full prior source inventory before any cancellation event is written.
    $abandonmentRun = Join-Path $testRoot 'pending-revision-abandonment'
    Copy-Item -LiteralPath $revision2ReadyRun -Destination $abandonmentRun -Recurse
    $abandonmentCheckpoint = Join-Path $abandonmentRun (
        'materials/checkpoint-method-1-abandonment.json'
    )
    $abandonmentInput = Join-Path $abandonmentRun (
        'materials/input-method-1-abandonment.json'
    )
    $abandonmentReviewManifest = Join-Path $abandonmentRun (
        'materials/method-1-revision-2-review-materials.json'
    )
    $abandonmentExcludedManifest = Join-Path $abandonmentRun (
        'materials/method-1-revision-2-excluded-evidence.json'
    )
    $abandonmentAuthorizationMaterial = Join-Path $abandonmentRun (
        'materials/method-1-revision-2-controller-authorization.md'
    )
    $abandonmentAcceptanceAuthorization = Join-Path $abandonmentRun (
        'materials/method-1-revision-2-acceptance-authorization.json'
    )
    $abandonmentActualMatrix = Join-Path $abandonmentRun (
        'materials/abandonment-matrix.json'
    )
    $abandonmentDeclaredMatrix = Join-Path $abandonmentRun (
        'references/abandonment-declared-matrix.json'
    )
    Set-Content -LiteralPath $abandonmentCheckpoint `
        -Value '{"milestone":"method-1","revision":"abandonment"}'
    Set-Content -LiteralPath $abandonmentActualMatrix `
        -Value '{"object":"actual-run-local-matrix"}'
    $null = New-Item -ItemType Directory -Force -Path (
        Split-Path -Parent $abandonmentDeclaredMatrix
    )
    Set-Content -LiteralPath $abandonmentDeclaredMatrix `
        -Value '{"object":"declared-hash-object"}'
    $abandonmentDeclaredHash = (
        Get-FileHash -LiteralPath $abandonmentDeclaredMatrix -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $abandonmentActualHash = (
        Get-FileHash -LiteralPath $abandonmentActualMatrix -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [ordered]@{
        scope = 'method-1-abandonment'
        matrix_path = 'materials/abandonment-matrix.json'
        matrix_hash = $abandonmentDeclaredHash
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $abandonmentInput
    $abandonmentAuthorization = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1'
    )) -RunDirectory $abandonmentRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $abandonmentCheckpoint `
        -InputManifestPath $abandonmentInput `
        -ReviewMaterialManifestPath $abandonmentReviewManifest `
        -ExcludedEvidenceManifestPath $abandonmentExcludedManifest `
        -AuthorizationMaterialPath $abandonmentAuthorizationMaterial `
        -AcceptanceAuthorizationMaterialPath $abandonmentAcceptanceAuthorization `
        -SelectionKey 'controller:select-method-1-abandonment' `
        -ActivationKey 'controller:method-1-abandonment' |
        ConvertFrom-Json -Depth 100
    $abandonmentAuthorizationRelative = (
        'receipts/durable-review-milestone.method-1.revision-' +
        "$($abandonmentAuthorization.revision_id).authorization.json"
    )
    foreach ($source in @($abandonmentAuthorization.required_sources)) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $abandonmentRun `
            -NodeId ([string]$source.source_node_id) -Status running `
            -ThreadId ([string]$source.thread_id) `
            -MilestoneRevisionAuthorizationReceiptPath $abandonmentAuthorizationRelative `
            -Message "Re-armed $($source.source_node_id) for abandonment test." `
            -Evidence @("artifact:$abandonmentAuthorizationRelative") `
            -IdempotencyKey "abandonment-rearm-$($source.source_node_id)" |
            Out-Null
    }
    $abandonmentEventsBefore = @(
        Read-OrchestrationJournal (Join-Path $abandonmentRun 'events.jsonl')
    )
    $firstAbandonmentSource = @(
        $abandonmentAuthorization.previous_source_bindings
    )[0]
    $firstAbandonmentDisposition = Get-Content -LiteralPath (
        Join-Path $abandonmentRun $firstAbandonmentSource.disposition_receipt_path
    ) -Raw | ConvertFrom-Json -Depth 100
    $firstAbandonmentDecision = @(
        $firstAbandonmentDisposition.decisions
    )[0]
    $inventory = [ordered]@{}
    $descriptorInventory = [Collections.Generic.List[object]]::new()
    $inventoryTotal = 0
    foreach ($source in @($abandonmentAuthorization.previous_source_bindings)) {
        $disposition = Get-Content -LiteralPath (
            Join-Path $abandonmentRun $source.disposition_receipt_path
        ) -Raw | ConvertFrom-Json -Depth 100
        $inventory[[string]$source.source_node_id] = @(
            $disposition.decisions | ForEach-Object {
                [string]$_.source_finding_id
            }
        )
        foreach ($decision in @($disposition.decisions)) {
            $descriptorInventory.Add(
                (New-DurableReviewOccurrenceDescriptor `
                    -SourceNodeId ([string]$source.source_node_id) `
                    -Decision $decision)
            )
        }
        $inventoryTotal += @($disposition.decisions).Count
    }
    $inventory.total_source_occurrences = $inventoryTotal
    $abandonmentAudit = Join-Path $abandonmentRun (
        'materials/method-1-abandonment-audit.json'
    )
    $abandonmentPendingFinding = Join-Path $abandonmentRun (
        'materials/method-1-abandonment-pending-finding.json'
    )
    @([ordered]@{
        finding_id = [string]$firstAbandonmentDecision.source_finding_id
        severity = [string]$firstAbandonmentDecision.severity
        text = [string]$firstAbandonmentDecision.finding
    }) | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $abandonmentPendingFinding
    [ordered]@{
        failed_input_binding = [ordered]@{
            input_manifest_path = 'materials/input-method-1-abandonment.json'
            input_manifest_sha256 = (
                Get-FileHash -LiteralPath $abandonmentInput -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            declared_matrix_path = 'materials/abandonment-matrix.json'
            actual_declared_matrix_path_sha256 = $abandonmentActualHash
            declared_matrix_hash = $abandonmentDeclaredHash
            actual_object_for_declared_matrix_hash =
                'references/abandonment-declared-matrix.json'
            failure_class = 'matrix_path_hash_object_mismatch'
        }
        source_finding = [ordered]@{
            source_node_id = [string]$firstAbandonmentSource.source_node_id
            source_finding_id = [string]$firstAbandonmentDecision.source_finding_id
            canonical_finding_id = [string]$firstAbandonmentDecision.canonical_finding_id
            severity = [string]$firstAbandonmentDecision.severity
            status = [string]$firstAbandonmentDecision.resolution_status
            exact_text = [string]$firstAbandonmentDecision.finding
            finding_hash = Get-TextSha256 ([string]$firstAbandonmentDecision.finding)
            pending_finding_material_path =
                'materials/method-1-abandonment-pending-finding.json'
            pending_finding_material_sha256 = (
                Get-FileHash -LiteralPath $abandonmentPendingFinding -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
        cumulative_source_inventory = $inventory
        cumulative_source_occurrence_descriptors = @($descriptorInventory)
    } | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $abandonmentAudit
    $abandonmentPreRun = Join-Path $testRoot 'pending-revision-abandonment-pre'
    Copy-Item -LiteralPath $abandonmentRun -Destination $abandonmentPreRun -Recurse
    $abandonmentReceipt = & (Join-Path $scriptRoot (
        'New-DurableReviewMilestoneRevisionAbandonmentReceipt.ps1'
    )) -RunDirectory $abandonmentRun `
        -AuthorizationReceiptPath (Join-Path $abandonmentRun $abandonmentAuthorizationRelative) `
        -InvalidityAuditMaterialPath $abandonmentAudit `
        -AbandonmentKey 'controller:method-1-abandonment' |
        ConvertFrom-Json -Depth 100
    $abandonmentEventsAfter = @(
        Read-OrchestrationJournal (Join-Path $abandonmentRun 'events.jsonl')
    )
    Assert-True (
        [string]$abandonmentReceipt.decision -eq 'abandoned' -and
        [bool]$abandonmentReceipt.invalidity_audit.raw_evidence_non_adoptable -and
        $abandonmentEventsAfter.Count -eq ($abandonmentEventsBefore.Count + 3)
    ) 'A contradictory pending revision must append one abandonment and two cancellations.'
    $abandonmentReceiptPath = Join-Path $abandonmentRun (
        'receipts/durable-review-milestone.method-1.revision-' +
        "$($abandonmentAuthorization.revision_id).abandonment.json"
    )
    $abandonmentReadback = Read-DurableReviewMilestoneRevisionAbandonment `
        -Path $abandonmentReceiptPath -RunDirectory $abandonmentRun
    Assert-True (
        [string]$abandonmentReadback.receipt_hash -eq
            [string]$abandonmentReceipt.receipt_hash
    ) 'Abandonment receipt must survive full pure-reader validation.'
    $abandonmentJournalHash = (
        Get-FileHash -LiteralPath (Join-Path $abandonmentRun 'events.jsonl') `
            -Algorithm SHA256
    ).Hash
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewMilestoneRevisionAbandonmentReceipt.ps1'
        )) -RunDirectory $abandonmentRun `
            -AuthorizationReceiptPath (Join-Path $abandonmentRun $abandonmentAuthorizationRelative) `
            -InvalidityAuditMaterialPath $abandonmentAudit `
            -AbandonmentKey 'controller:duplicate-abandonment' | Out-Null
    } 'not-yet-abandoned' (
        'A pending revision may be abandoned only once.'
    )
    Assert-True (
        $abandonmentJournalHash -eq (
            Get-FileHash -LiteralPath (Join-Path $abandonmentRun 'events.jsonl') `
                -Algorithm SHA256
        ).Hash
    ) 'A duplicate abandonment must not append to the journal.'

    function Assert-AbandonmentAuditMutationRejected {
        param(
            [string] $Name,
            [scriptblock] $Mutation,
            [string] $Expected
        )
        $mutationRun = Join-Path $testRoot "abandonment-$Name"
        Copy-Item -LiteralPath $abandonmentPreRun -Destination $mutationRun -Recurse
        $mutationAudit = Join-Path $mutationRun 'materials/method-1-abandonment-audit.json'
        $audit = Get-Content -LiteralPath $abandonmentAudit -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $Mutation $audit
        $audit | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $mutationAudit
        $before = (Get-FileHash -LiteralPath (Join-Path $mutationRun 'events.jsonl') -Algorithm SHA256).Hash
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot (
                'New-DurableReviewMilestoneRevisionAbandonmentReceipt.ps1'
            )) -RunDirectory $mutationRun `
                -AuthorizationReceiptPath (Join-Path $mutationRun $abandonmentAuthorizationRelative) `
                -InvalidityAuditMaterialPath $mutationAudit `
                -AbandonmentKey "controller:abandonment-$Name" | Out-Null
        } $Expected "Abandonment audit mutation '$Name' must fail before journal write."
        Assert-True (
            $before -eq (Get-FileHash -LiteralPath (Join-Path $mutationRun 'events.jsonl') -Algorithm SHA256).Hash
        ) "Abandonment audit mutation '$Name' must not change the journal."
    }
    Assert-AbandonmentAuditMutationRejected -Name 'outside-object' -Expected 'existing file inside the run' -Mutation {
        param($audit)
        $audit.failed_input_binding.actual_object_for_declared_matrix_hash = 'C:\outside-declared-object.json'
    }
    Assert-AbandonmentAuditMutationRejected -Name 'actual-hash-drift' -Expected 'actual control hash changed' -Mutation {
        param($audit)
        $audit.failed_input_binding.actual_declared_matrix_path_sha256 = ('0' * 64)
    }
    Assert-AbandonmentAuditMutationRejected -Name 'partial-inventory' -Expected 'cumulative source inventory' -Mutation {
        param($audit)
        $audit.cumulative_source_inventory[[string]$firstAbandonmentSource.source_node_id] = @(
            $audit.cumulative_source_inventory[[string]$firstAbandonmentSource.source_node_id] |
                Select-Object -Skip 1
        )
        $audit.cumulative_source_inventory.total_source_occurrences =
            [int]$audit.cumulative_source_inventory.total_source_occurrences - 1
    }
    Assert-AbandonmentAuditMutationRejected -Name 'missing-simple-inventory' `
        -Expected 'simple cumulative source inventory' -Mutation {
        param($audit)
        $audit.Remove('cumulative_source_inventory')
    }

    function Assert-AbandonmentReaderMutationRejected {
        param(
            [string] $Name,
            [scriptblock] $Mutation,
            [string] $Expected
        )
        $mutationRun = Join-Path $testRoot "abandonment-reader-$Name"
        Copy-Item -LiteralPath $abandonmentRun -Destination $mutationRun -Recurse
        $mutationReceiptPath = Join-Path $mutationRun (
            'receipts/durable-review-milestone.method-1.revision-' +
            "$($abandonmentAuthorization.revision_id).abandonment.json"
        )
        $receipt = Get-Content -LiteralPath $mutationReceiptPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $Mutation $mutationRun $receipt
        $receiptPayload = [ordered]@{}
        foreach ($key in $receipt.Keys) {
            if ($key -ne 'receipt_hash') { $receiptPayload[$key] = $receipt[$key] }
        }
        $receipt.receipt_hash = Get-TextSha256 (
            $receiptPayload | ConvertTo-Json -Compress -Depth 100
        )
        $receipt | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $mutationReceiptPath
        # Keep the copied journal internally consistent with the mutated
        # receipt so the reader reaches the specific binding under test.
        $mutationEvents = @(
            Read-OrchestrationJournal (Join-Path $mutationRun 'events.jsonl')
        )
        $abandonmentEventIndex = [int]$receipt.source_journal_event_count
        if ($abandonmentEventIndex -lt $mutationEvents.Count) {
            $mutationEvents[$abandonmentEventIndex].
                milestone_revision_abandonment_receipt_hash =
                [string]$receipt.receipt_hash
            $previousHash = $null
            foreach ($mutationEvent in $mutationEvents) {
                $mutationEvent.prev_hash = $previousHash
                $mutationEvent.hash = Get-OrchestrationEventHash $mutationEvent
                $previousHash = [string]$mutationEvent.hash
            }
            $mutationEvents | ForEach-Object {
                $_ | ConvertTo-Json -Compress -Depth 100
            } | Set-Content -LiteralPath (Join-Path $mutationRun 'events.jsonl')
        }
        $before = (Get-FileHash -LiteralPath (Join-Path $mutationRun 'events.jsonl') `
            -Algorithm SHA256).Hash
        Assert-ThrowsLike {
            Read-DurableReviewMilestoneRevisionAbandonment `
                -Path $mutationReceiptPath -RunDirectory $mutationRun | Out-Null
        } $Expected "Reader mutation '$Name' must fail closed."
        Assert-True (
            $before -eq (Get-FileHash -LiteralPath (Join-Path $mutationRun 'events.jsonl') `
                -Algorithm SHA256).Hash
        ) "Reader mutation '$Name' must not change the journal."
    }
    Assert-AbandonmentReaderMutationRejected -Name 'authorization-binding-rehash' `
        -Expected 'authorization binding changed' -Mutation {
        param($mutationRun, $receipt)
        $receipt.authorization_receipt_hash = '0' * 64
    }
    Assert-AbandonmentReaderMutationRejected -Name 'prior-disposition-rehash' `
        -Expected 'identity, text hash, and severity' -Mutation {
        param($mutationRun, $receipt)
        $previous = @($abandonmentAuthorization.previous_source_bindings)[0]
        $dispositionPath = Join-Path $mutationRun $previous.disposition_receipt_path
        $disposition = Get-Content -LiteralPath $dispositionPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $decision = $disposition.decisions[0]
        $decision.finding = 'mutated prior occurrence text'
        $decision.finding_hash = Get-TextSha256 ([string]$decision.finding)
        $dispositionPayload = [ordered]@{
            schema_version = [string]$disposition.schema_version
            run_id = [string]$disposition.run_id
            milestone_id = [string]$disposition.milestone_id
            source_node_id = [string]$disposition.source_node_id
            source_thread_id = [string]$disposition.source_thread_id
            source_result_receipt_path = [string]$disposition.source_result_receipt_path
            source_result_receipt_hash = [string]$disposition.source_result_receipt_hash
            decisions = $disposition.decisions
            blocking_open = $disposition.blocking_open
            created_at_utc = [string]$disposition.created_at_utc
        }
        $disposition.receipt_hash = Get-TextSha256 (
            $dispositionPayload | ConvertTo-Json -Compress -Depth 50
        )
        $disposition | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $dispositionPath
    }
    Assert-AbandonmentReaderMutationRejected -Name 'missing-simple-inventory' `
        -Expected 'lacks the simple cumulative source inventory' -Mutation {
        param($mutationRun, $receipt)
        $auditPath = Join-Path $mutationRun $receipt.invalidity_audit_material_path
        $audit = Get-Content -LiteralPath $auditPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $audit.Remove('cumulative_source_inventory')
        $audit | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $auditPath
        $receipt.invalidity_audit_material_hash = (
            Get-FileHash -LiteralPath $auditPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    Assert-AbandonmentReaderMutationRejected -Name 'rehashed-simple-inventory' `
        -Expected 'invalidity audit inventory changed' -Mutation {
        param($mutationRun, $receipt)
        $auditPath = Join-Path $mutationRun $receipt.invalidity_audit_material_path
        $audit = Get-Content -LiteralPath $auditPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $sourceKey = [string]$firstAbandonmentSource.source_node_id
        $audit.cumulative_source_inventory[$sourceKey][0] = 'mutated-same-slot'
        $audit | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $auditPath
        $receipt.invalidity_audit_material_hash = (
            Get-FileHash -LiteralPath $auditPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }

    # The abandoned pending revision is non-adoptable evidence only.  A fresh
    # same-milestone authorization must bind the abandonment and start both
    # original source seats again with new result/disposition artifacts.
    $freshAfterAbandonmentCheckpoint = Join-Path $abandonmentRun (
        'materials/checkpoint-method-1-after-abandonment.json'
    )
    $freshAfterAbandonmentInput = Join-Path $abandonmentRun (
        'materials/input-method-1-after-abandonment.json'
    )
    Set-Content -LiteralPath $freshAfterAbandonmentCheckpoint `
        -Value '{"milestone":"method-1","revision":"after-abandonment"}'
    Set-Content -LiteralPath $freshAfterAbandonmentInput `
        -Value '{"scope":"method-1-after-abandonment"}'
    $freshReviewPrompt = Join-Path $abandonmentRun `
        'materials/review-after-abandonment.md'
    $freshDomainPrompt = Join-Path $abandonmentRun `
        'materials/domain-after-abandonment.md'
    Set-Content -LiteralPath $freshReviewPrompt `
        -Value 'Fresh review after the invalid pending revision was abandoned.'
    Set-Content -LiteralPath $freshDomainPrompt `
        -Value 'Fresh domain audit after the invalid pending revision was abandoned.'
    $freshReviewManifest = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-review-materials.json'
    @(
        [ordered]@{
            source_node_id = 'review'
            material_path = 'materials/review-after-abandonment.md'
        },
        [ordered]@{
            source_node_id = 'domain'
            material_path = 'materials/domain-after-abandonment.md'
        }
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $freshReviewManifest
    $freshExcludedManifest = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-excluded-evidence.json'
    $freshEventsForInventory = @(
        Read-OrchestrationJournal (Join-Path $abandonmentRun 'events.jsonl')
    )
    $freshExcludedInventory = Get-MilestoneRevisionExcludedInventory `
        -RunDirectory $abandonmentRun -Events $freshEventsForInventory `
        -RequiredSourceIds @('domain', 'review') `
        -CheckpointHash (
            Get-FileHash -LiteralPath $freshAfterAbandonmentCheckpoint `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant() `
        -EventCount $freshEventsForInventory.Count
    $freshExcludedEntries = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in @('domain', 'review')) {
        $freshExcludedEntries.Add([ordered]@{
            source_node_id = $sourceNodeId
            reason = 'caller-timing-error/non-completion evidence'
            event_bindings = @($freshExcludedInventory.events | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            } | ForEach-Object {
                [ordered]@{
                    sequence = [int]$_.event_sequence
                    event_hash = [string]$_.event_hash
                }
            })
            artifacts = @($freshExcludedInventory.artifacts | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            } | ForEach-Object {
                [ordered]@{
                    type = [string]$_.type
                    path = [string]$_.path
                    file_hash = [string]$_.file_hash
                    internal_hash = [string]$_.internal_hash
                }
            })
        })
    }
    @($freshExcludedEntries) | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $freshExcludedManifest
    $freshAuthorizationMaterial = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-controller-authorization.md'
    Set-Content -LiteralPath $freshAuthorizationMaterial `
        -Value 'Controller authorizes one fresh same-milestone review after abandonment.'
    $freshAcceptanceEvidence = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-main-acceptance.md'
    Set-Content -LiteralPath $freshAcceptanceEvidence `
        -Value 'Main owner acceptance remains independent and is intentionally absent.'
    $freshAcceptanceAuthorization = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-acceptance-authorization.json'
    [ordered]@{
        schema_version = '1.0'
        milestone_id = 'method-1'
        main_node_id = 'integrate'
        acceptance_key = 'controller:method-1-after-abandonment-acceptance'
        evidence_material_path = [IO.Path]::GetRelativePath(
            $abandonmentRun, $freshAcceptanceEvidence
        ).Replace('\', '/')
        evidence_material_hash = (
            Get-FileHash -LiteralPath $freshAcceptanceEvidence -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $freshAcceptanceAuthorization
    $freshAuthorization = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1') `
        -RunDirectory $abandonmentRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $freshAfterAbandonmentCheckpoint `
        -InputManifestPath $freshAfterAbandonmentInput `
        -ReviewMaterialManifestPath $freshReviewManifest `
        -ExcludedEvidenceManifestPath $freshExcludedManifest `
        -AuthorizationMaterialPath $freshAuthorizationMaterial `
        -AcceptanceAuthorizationMaterialPath $freshAcceptanceAuthorization `
        -SelectionKey 'controller:select-method-1-after-abandonment' `
        -ActivationKey 'controller:method-1-after-abandonment' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [int]$freshAuthorization.revision_index -gt
            [int]$abandonmentAuthorization.revision_index -and
        [string]$freshAuthorization.previous_abandonment_revision_id -eq
            [string]$abandonmentAuthorization.revision_id
    ) 'A fresh authorization must bind the abandoned pending revision.'
    $freshAuthorizationRelative = (
        'receipts/durable-review-milestone.method-1.revision-' +
        "$($freshAuthorization.revision_id).authorization.json"
    )
    foreach ($source in @(
        @{ id = 'review'; thread = 'review-thread' },
        @{ id = 'domain'; thread = 'domain-thread' }
    )) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $abandonmentRun -NodeId $source.id -Status running `
            -ThreadId $source.thread `
            -MilestoneRevisionAuthorizationReceiptPath $freshAuthorizationRelative `
            -Message "Fresh post-abandonment review for $($source.id)." `
            -Evidence @('observation:fresh-post-abandonment-review') `
            -IdempotencyKey "fresh-after-abandonment-rearm-$($source.id)" |
            Out-Null
    }
    $freshReview = New-SourceChain -Run $abandonmentRun `
        -SourceNodeId 'review' -ThreadId 'review-thread' `
        -MilestoneId 'method-1' -CheckpointPath $freshAfterAbandonmentCheckpoint `
        -Stem 'review.method-1-after-abandonment' -Severity 'P0' `
        -FindingText 'baseline-review-p0' -Resolution 'open' `
        -FindingId 'review-method-1-finding' `
        -CanonicalFindingId 'canonical-review-method-1-finding' `
        -AdditionalFindingId 'review-method-1-finding-r08' `
        -AdditionalFindingText 'baseline-review-p0-second-occurrence' `
        -AdditionalSeverity 'P0' `
        -AdditionalCanonicalFindingId 'canonical-review-method-1-finding'
    $freshDomain = New-SourceChain -Run $abandonmentRun `
        -SourceNodeId 'domain' -ThreadId 'domain-thread' `
        -MilestoneId 'method-1' -CheckpointPath $freshAfterAbandonmentCheckpoint `
        -Stem 'domain.method-1-after-abandonment' -Severity 'P0' `
        -FindingText 'baseline-domain-p0' -Resolution 'open' `
        -FindingId 'domain-method-1-finding' `
        -CanonicalFindingId 'canonical-domain-method-1-finding'
    foreach ($source in @(
        @{ id = 'review'; thread = 'review-thread'; result = $freshReview.result_path; disposition = $freshReview.disposition_path },
        @{ id = 'domain'; thread = 'domain-thread'; result = $freshDomain.result_path; disposition = $freshDomain.disposition_path }
    )) {
        foreach ($status in @('completed', 'validated', 'adopted')) {
            $pointer = if ($status -eq 'completed') {
                "artifact:$($source.result)"
            } else {
                "artifact:$($source.disposition)"
            }
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $abandonmentRun -NodeId $source.id `
                -Status $status -ThreadId $source.thread `
                -Message "Fresh post-abandonment $($source.id) $status." `
                -Evidence @($pointer) `
                -IdempotencyKey "fresh-after-abandonment-$($source.id)-$status" |
                Out-Null
        }
    }
    Assert-True (
        [string]$freshReview.result_path -ne [string]$firstAbandonmentSource.result_receipt_path -and
        [string]$freshDomain.result_path -ne [string]$firstAbandonmentSource.result_receipt_path
    ) 'Fresh review must not reuse the abandoned revision result artifacts.'
    $freshSelectionMaterial = Join-Path $abandonmentRun `
        'materials/method-1-after-abandonment-selection.json'
    @(
        [ordered]@{ source_node_id = 'review'; disposition_receipt_path = $freshReview.disposition_path },
        [ordered]@{ source_node_id = 'domain'; disposition_receipt_path = $freshDomain.disposition_path }
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $freshSelectionMaterial
    $freshSelection = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionSelectionReceipt.ps1') `
        -RunDirectory $abandonmentRun `
        -AuthorizationReceiptPath (Join-Path $abandonmentRun $freshAuthorizationRelative) `
        -SelectionMaterialPath $freshSelectionMaterial `
        -SelectionKey ([string]$freshAuthorization.selection_key) |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$freshSelection.schema_version -in @('1.1', '1.2', '1.3', '1.4') -and
        [string]$freshSelection.revision_id -eq [string]$freshAuthorization.revision_id
    ) 'A fresh post-abandonment result/disposition pair must be selectable.'

    # An abandoned revision still consumes its authorization ordinal.  The
    # next authorization must follow the selected revision's bound
    # authorization, not the smaller count of selection events.
    $postAbandonmentCheckpoint = Join-Path $abandonmentRun (
        'materials/checkpoint-method-1-post-abandonment-selection.json'
    )
    $postAbandonmentInput = Join-Path $abandonmentRun (
        'materials/input-method-1-post-abandonment-selection.json'
    )
    Set-Content -LiteralPath $postAbandonmentCheckpoint `
        -Value '{"milestone":"method-1","revision":"post-abandonment-selection"}'
    Set-Content -LiteralPath $postAbandonmentInput `
        -Value '{"scope":"method-1-post-abandonment-selection"}'
    $postAbandonmentEvents = @(
        Read-OrchestrationJournal (Join-Path $abandonmentRun 'events.jsonl')
    )
    $postAbandonmentInventory = Get-MilestoneRevisionExcludedInventory `
        -RunDirectory $abandonmentRun -Events $postAbandonmentEvents `
        -RequiredSourceIds @('domain', 'review') `
        -CheckpointHash (
            Get-FileHash -LiteralPath $postAbandonmentCheckpoint -Algorithm SHA256
        ).Hash.ToLowerInvariant() -EventCount $postAbandonmentEvents.Count
    $postAbandonmentExcludedEntries = [Collections.Generic.List[object]]::new()
    foreach ($sourceNodeId in @('domain', 'review')) {
        $postAbandonmentExcludedEntries.Add([ordered]@{
            source_node_id = $sourceNodeId
            reason = 'caller-timing-error/non-completion evidence'
            event_bindings = @($postAbandonmentInventory.events | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            } | ForEach-Object {
                [ordered]@{
                    sequence = [int]$_.event_sequence
                    event_hash = [string]$_.event_hash
                }
            })
            artifacts = @($postAbandonmentInventory.artifacts | Where-Object {
                [string]$_.source_node_id -eq $sourceNodeId
            } | ForEach-Object {
                [ordered]@{
                    type = [string]$_.type
                    path = [string]$_.path
                    file_hash = [string]$_.file_hash
                    internal_hash = [string]$_.internal_hash
                }
            })
        })
    }
    $postAbandonmentExcludedManifest = Join-Path $abandonmentRun (
        'materials/method-1-post-abandonment-selection-excluded-evidence.json'
    )
    @($postAbandonmentExcludedEntries) | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $postAbandonmentExcludedManifest
    $postAbandonmentAuthorizationMaterial = Join-Path $abandonmentRun (
        'materials/method-1-post-abandonment-selection-controller-authorization.md'
    )
    Set-Content -LiteralPath $postAbandonmentAuthorizationMaterial -Value (
        'Controller authorizes the revision after a selected post-abandonment review.'
    )
    $postAbandonmentAuthorization = & (Join-Path $scriptRoot `
        'New-DurableReviewMilestoneRevisionAuthorizationReceipt.ps1') `
        -RunDirectory $abandonmentRun -MilestoneId 'method-1' `
        -CheckpointMaterialPath $postAbandonmentCheckpoint `
        -InputManifestPath $postAbandonmentInput `
        -ReviewMaterialManifestPath $freshReviewManifest `
        -ExcludedEvidenceManifestPath $postAbandonmentExcludedManifest `
        -AuthorizationMaterialPath $postAbandonmentAuthorizationMaterial `
        -AcceptanceAuthorizationMaterialPath $freshAcceptanceAuthorization `
        -SelectionKey 'controller:select-method-1-post-abandonment-selection' `
        -ActivationKey 'controller:method-1-post-abandonment-selection' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [int]$postAbandonmentAuthorization.revision_index -eq
            ([int]$freshAuthorization.revision_index + 1)
    ) 'An abandoned revision ordinal must not deadlock the next authorization.'

    $freshEvents = @(Read-OrchestrationJournal (Join-Path $abandonmentRun 'events.jsonl'))
    $freshAuthorizationEvent = @($freshEvents | Where-Object {
        [string]$_.event -eq 'milestone-revision-authorized' -and
        [string]$_.milestone_revision_id -eq [string]$freshAuthorization.revision_id
    })[0]
    $freshDomainSource = @($freshAuthorization.required_sources | Where-Object {
        [string]$_.source_node_id -eq 'domain'
    })[0]
    $ordinaryCancelledAuthorization = $freshAuthorization |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    foreach ($name in @(
        'previous_abandonment_receipt_path',
        'previous_abandonment_receipt_hash',
        'previous_abandonment_event_sequence',
        'previous_abandonment_event_hash',
        'previous_abandonment_revision_id'
    )) {
        $ordinaryCancelledAuthorization.PSObject.Properties.Remove($name)
    }
    Assert-ThrowsLike {
        Get-DurableReviewMilestoneRevisionRearmEvent `
            -RunDirectory $abandonmentRun -Events $freshEvents `
            -Authorization $ordinaryCancelledAuthorization `
            -RequiredSource $freshDomainSource `
            -AuthorizationEventSequence ([int]$freshAuthorizationEvent.sequence) |
            Out-Null
    } 'lacks one fresh re-arm' (
        'An ordinary cancelled source cannot re-arm without abandonment continuity.'
    )
    $wrongAbandonmentAuthorization = $freshAuthorization |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $wrongAbandonmentAuthorization.previous_abandonment_receipt_hash =
        ('0' * 64)
    Assert-ThrowsLike {
        Get-DurableReviewMilestoneRevisionRearmEvent `
            -RunDirectory $abandonmentRun -Events $freshEvents `
            -Authorization $wrongAbandonmentAuthorization `
            -RequiredSource $freshDomainSource `
            -AuthorizationEventSequence ([int]$freshAuthorizationEvent.sequence) |
            Out-Null
    } 'abandonment binding changed' (
        'A cancelled re-arm with the wrong abandonment receipt must fail closed.'
    )
    $crossSource = [pscustomobject]@{
        source_node_id = 'domain'
        role_id = 'adversarial-reviewer'
        thread_id = 'review-thread'
    }
    Assert-ThrowsLike {
        Get-DurableReviewMilestoneRevisionRearmEvent `
            -RunDirectory $abandonmentRun -Events $freshEvents `
            -Authorization $freshAuthorization `
            -RequiredSource $crossSource `
            -AuthorizationEventSequence ([int]$freshAuthorizationEvent.sequence) |
            Out-Null
    } 'abandonment source binding changed' (
        'A cancelled re-arm cannot borrow another source or thread.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $abandonmentRun | Out-Null
    } 'main' (
        'Fresh selection must not satisfy independent main acceptance.'
    )

    [pscustomobject]@{
        pass = $true
        assertions = $script:assertions
        baseline_milestone = 'method-1'
        active_milestone = 'method-2'
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
