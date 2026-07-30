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
        [string] $Resolution
    )
    $capturePath = Join-Path $Run "thread-reads/$Stem.json"
    New-ThreadCapture -Path $capturePath -ThreadId $ThreadId `
        -Text "Report for $SourceNodeId at $MilestoneId."
    $findingId = "$SourceNodeId-$MilestoneId-finding"
    $findingPath = Join-Path $Run "materials/$Stem-findings.json"
    @(
        [ordered]@{
            finding_id = $findingId
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
            source_finding_id = $findingId
            finding = $FindingText
            finding_hash = Get-TextSha256 $FindingText
            canonical_finding_id = "canonical-$findingId"
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
