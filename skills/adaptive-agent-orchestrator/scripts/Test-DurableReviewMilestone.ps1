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
    param([string] $Path)
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
        milestone_ids = @('method-1', 'method-2')
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
        [string] $CanonicalFindingId = ''
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
    @(
        [ordered]@{
            finding_id = $FindingId
            severity = $Severity
            text = $FindingText
        }
    ) | ConvertTo-Json -Depth 10 |
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
    @(
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
    ) | ConvertTo-Json -Depth 20 |
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
        -FindingText 'baseline-review-p0' -Resolution 'resolved'
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
