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
        [string] $AdditionalCanonicalFindingId = ''
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
    $result = & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
        -RunDirectory $Run -SourceNodeId $SourceNodeId `
        -ThreadId $ThreadId -HostId 'local' `
        -ThreadReadPath $capturePath -OutputPath $resultPath `
        -MilestoneId $MilestoneId `
        -CheckpointMaterialPath $CheckpointPath `
        -PendingFindingRecordsPath $findingPath |
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
