[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$script:assertions = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'adaptive-agent-recovery-' + [guid]::NewGuid().ToString('N')
)

# Attack matrix:
# A result_pending without a verified receipt; B recovery beyond same source;
# C checkpoint/authorization mutation; D incomplete legacy turn evidence;
# E thread ID masquerading as source ID; F fabricated legacy fields;
# G replacement before 3/3; H cross-source result reuse;
# I replacement result masquerading as original.

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertions++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Action,
        [string] $ExpectedMessage,
        [string] $Message
    )
    $caught = $false
    try { & $Action } catch {
        $caught = $_.Exception.Message -like "*$ExpectedMessage*"
    }
    Assert-True $caught $Message
}

function New-RecoveryCyclePlan {
    param([string] $Path)
    $cyclePlan = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/example-plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $cyclePlan.run_id = 'recovery-cycle-test'
    $cyclePlan.roles[1].lifetime = 'project'
    $domainRole = @{}
    foreach ($entry in $cyclePlan.roles[1].GetEnumerator()) {
        $domainRole[$entry.Key] = $entry.Value
    }
    $domainRole.id = 'domain-role'
    $domainRole.display_name = 'Domain Role'
    $domainRole.mission = 'Maintain reusable read-only domain checks.'
    $domainRole.identity_statement = 'I return read-only domain findings.'
    $cyclePlan.roles += $domainRole

    $review = $cyclePlan.nodes[1]
    $review.wave = 1
    $review.topology = 'background-thread'
    $review.workflow = 'parallel'
    $review.depends_on = @()
    $review.context.continuity_key = 'cycle-dissent'
    $review.context.inputs = @('source:dissent-input')
    $domain = @{}
    foreach ($entry in $review.GetEnumerator()) {
        $domain[$entry.Key] = $entry.Value
    }
    $domain.id = 'domain'
    $domain.role_id = 'domain-role'
    $domain.context = @{}
    foreach ($entry in $review.context.GetEnumerator()) {
        $domain.context[$entry.Key] = $entry.Value
    }
    $domain.context.continuity_key = 'cycle-domain'
    $domain.context.inputs = @('source:domain-input')
    $main = $cyclePlan.nodes[2]
    $main.depends_on = @('review', 'domain')
    $cyclePlan.nodes = @($review, $domain, $main)
    $cyclePlan.completion.required_nodes = @('review', 'domain', 'integrate')
    $cyclePlan.completion.evidence_checks = @(
        @{ node_id = 'review'; minimum_entries = 1 },
        @{ node_id = 'domain'; minimum_entries = 1 },
        @{ node_id = 'integrate'; minimum_entries = 1 }
    )
    $cyclePlan.completion.review_disposition_checks = @(
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
    $cyclePlan.durable_review_profile = @{
        mode = 'domain-dissent'
        main_owner_node_id = 'integrate'
        domain_node_ids = @('domain')
        dissent_node_ids = @('review')
        milestone_ids = @('group-1', 'final-gate')
        consumer_output = 'result-only'
    }
    $cyclePlan | ConvertTo-Json -Depth 100 |
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

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $plan = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/example-plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $plan.run_id = 'recovery-protocol-test'
    $plan.nodes[1].topology = 'background-thread'
    $plan.nodes[1].wave = 1
    $plan.nodes[1].depends_on = @()
    $plan.nodes[1].context.continuity_key = 'durable-review-source'
    $plan.nodes[0].wave = 2
    $plan.nodes[0].depends_on = @('review')
    $planPath = Join-Path $testRoot 'recovery-plan.json'
    $plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $planPath
    $run = Join-Path $testRoot 'run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $planPath -RunDirectory $run -WorkspaceRoot $testRoot |
        Out-Null

    $receipts = Join-Path $run 'receipts'
    $materials = Join-Path $run 'materials'
    $null = New-Item -ItemType Directory -Path $receipts, $materials
    $rolePath = Join-Path $materials 'legacy-role.txt'
    $checkpointPath = Join-Path $materials 'checkpoint.txt'
    $inputPath = Join-Path $materials 'input.txt'
    $authorizationPath = Join-Path $materials 'authorization.txt'
    Set-Content -LiteralPath $rolePath -Value (
        'Role: adversarial reviewer; read-only; no delegation; same checkpoint.'
    )
    Set-Content -LiteralPath $checkpointPath -Value (
        'd254e4476c682a7762136061e1f54453282b719d8c26798619ac0b323eeb334f'
    )
    Set-Content -LiteralPath $inputPath -Value (
        'Review the frozen checkpoint without expanding scope.'
    )
    Set-Content -LiteralPath $authorizationPath -Value (
        'Controller authorizes one same-role read-only replacement for this ' +
        'checkpoint; no write, delegation, or cross-source substitution.'
    )
    $turnEvidencePath = Join-Path $materials 'legacy-turn-evidence.json'
    @(
        [ordered]@{
            turn_id = 'legacy-original'
            status = 'completed'
            error_state = 'null'
            final_state = 'missing'
            progress_evidence = @()
        },
        [ordered]@{
            turn_id = 'legacy-recovery-1'
            status = 'completed'
            error_state = 'null'
            final_state = 'missing'
            progress_evidence = @(
                'commentary:recover existing evidence or preserve FAIL'
            )
        },
        [ordered]@{
            turn_id = 'legacy-recovery-2'
            status = 'completed'
            error_state = 'null'
            final_state = 'missing'
            progress_evidence = @()
        },
        [ordered]@{
            turn_id = 'legacy-recovery-3'
            status = 'completed'
            error_state = 'null'
            final_state = 'missing'
            progress_evidence = @()
        }
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $turnEvidencePath

    $legacyPath = Join-Path $receipts 'review.legacy-source-adoption.json'
    $legacy = & (Join-Path $scriptRoot 'New-LegacySourceAdoptionReceipt.ps1') `
        -RunDirectory $run -SourceNodeId 'review' `
        -OriginalThreadId 'legacy-review-thread' `
        -RoleMaterialPath $rolePath -CheckpointMaterialPath $checkpointPath `
        -InputMaterialPath $inputPath -TurnEvidencePath $turnEvidencePath `
        -AuthorizationMaterialPath $authorizationPath `
        -ActivationKey 'controller:legacy-review-adoption' `
        -OutputPath $legacyPath | ConvertFrom-Json -Depth 30
    Assert-True ($legacy.outcome -eq 'replacement-eligible') (
        'Legacy adoption should only establish replacement eligibility.'
    )
    Assert-True (
        @($legacy.unknown_fields).Count -eq 4 -and
        'original_input_hash' -in @($legacy.unknown_fields)
    ) 'Legacy adoption must preserve unavailable machine fields as unknown.'
    Assert-True (
        $legacy.source_node_id -ne $legacy.original_thread_id
    ) 'A legacy thread ID must not masquerade as a source node ID.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-LegacySourceAdoptionReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'review' -RoleMaterialPath $rolePath `
            -CheckpointMaterialPath $checkpointPath `
            -InputMaterialPath $inputPath -TurnEvidencePath $turnEvidencePath `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:thread-as-source' `
            -OutputPath $legacyPath | Out-Null
    } 'stable' 'A thread ID cannot be adopted as its own source node.'
    Assert-ThrowsLike {
        Read-ThreadResultReceipt -Path $legacyPath `
            -ExpectedThreadId 'legacy-review-thread' `
            -ExpectedSourceNodeId 'review' -RunDirectory $run | Out-Null
    } "missing 'thread_id'" (
        'Legacy adoption itself can never be used as a final result receipt.'
    )

    $legacyOriginal = Get-Content -LiteralPath $legacyPath -Raw
    $legacyTampered = $legacyOriginal |
        ConvertFrom-Json -AsHashtable -Depth 30
    $legacyTampered.input_material_hash = '0' * 64
    $legacyTamperedPayload = [ordered]@{}
    foreach ($entry in $legacyTampered.GetEnumerator()) {
        if ($entry.Key -ne 'receipt_hash') {
            $legacyTamperedPayload[$entry.Key] = $entry.Value
        }
    }
    $legacyTampered.receipt_hash = Get-TextSha256 (
        $legacyTamperedPayload | ConvertTo-Json -Compress -Depth 30
    )
    $legacyTampered | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $legacyPath
    Assert-ThrowsLike {
        Read-LegacySourceAdoptionReceipt -Path $legacyPath `
            -RunDirectory $run -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'legacy-review-thread' | Out-Null
    } 'Input material is missing or changed' (
        'A fabricated legacy input hash must fail closed.'
    )
    Set-Content -LiteralPath $legacyPath -Value $legacyOriginal -NoNewline
    foreach ($attack in @(
        [ordered]@{
            name = 'role'
            mutate = {
                param($receipt)
                $receipt.role_id = 'different-role'
            }
            expected = 'changed assigned role'
        },
        [ordered]@{
            name = 'unknown'
            mutate = {
                param($receipt)
                $receipt.unknown_fields = @(
                    'machine_source_node_id', 'machine_role_id'
                )
            }
            expected = 'preserve all unknown'
        }
    )) {
        $attacked = $legacyOriginal |
            ConvertFrom-Json -AsHashtable -Depth 30
        $mutator = $attack.mutate
        & $mutator $attacked
        $attackedPayload = [ordered]@{}
        foreach ($entry in $attacked.GetEnumerator()) {
            if ($entry.Key -ne 'receipt_hash') {
                $attackedPayload[$entry.Key] = $entry.Value
            }
        }
        $attacked.receipt_hash = Get-TextSha256 (
            $attackedPayload | ConvertTo-Json -Compress -Depth 30
        )
        $attacked | ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $legacyPath
        Assert-ThrowsLike {
            Read-LegacySourceAdoptionReceipt -Path $legacyPath `
                -RunDirectory $run -ExpectedSourceNodeId 'review' `
                -ExpectedOriginalThreadId 'legacy-review-thread' | Out-Null
        } $attack.expected (
            "Legacy adoption must reject the $($attack.name) mutation."
        )
        Set-Content -LiteralPath $legacyPath -Value $legacyOriginal -NoNewline
    }

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-LegacySourceAdoptionReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'legacy-review-thread' `
            -RoleMaterialPath $rolePath -CheckpointMaterialPath $checkpointPath `
            -InputMaterialPath $inputPath -TurnEvidencePath $turnEvidencePath `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:duplicate' -OutputPath $legacyPath |
            Out-Null
    } 'already exists' 'The same legacy source may only be adopted once.'
    $alternateReceiptDirectory = Join-Path $run 'alternate-receipts'
    $null = New-Item -ItemType Directory -Path $alternateReceiptDirectory
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-LegacySourceAdoptionReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'legacy-review-thread' `
            -RoleMaterialPath $rolePath -CheckpointMaterialPath $checkpointPath `
            -InputMaterialPath $inputPath -TurnEvidencePath $turnEvidencePath `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:cross-directory-duplicate' `
            -OutputPath (Join-Path $alternateReceiptDirectory (
                'review.legacy-source-adoption.json'
            )) | Out-Null
    } 'canonical run receipts directory' (
        'Legacy adoption cannot bypass uniqueness through another receipt directory.'
    )

    $missingTurnPath = Join-Path $materials 'missing-turn.json'
    @(
        (Get-Content -LiteralPath $turnEvidencePath -Raw |
            ConvertFrom-Json -Depth 20)[0..2]
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $missingTurnPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-LegacySourceAdoptionReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'different-legacy-thread' `
            -RoleMaterialPath $rolePath -CheckpointMaterialPath $checkpointPath `
            -InputMaterialPath $inputPath -TurnEvidencePath $missingTurnPath `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:missing-turn' `
            -OutputPath (Join-Path $receipts (
                'review.legacy-source-adoption.json'
            )) | Out-Null
    } 'exactly four' 'Legacy adoption must reject incomplete recovery evidence.'

    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $modelArguments = if ($status -eq 'materialized') {
            @{
                ModelVerificationState = 'unverified'
                ModelVerificationEvidence = (
                    'observation:platform-model-not-exposed'
                )
            }
        } else { @{} }
        $thread = if ($status -in @('materialized', 'running')) {
            'legacy-review-thread'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status $status `
            -Message "legacy review $status" -ThreadId $thread `
            @modelArguments `
            -IdempotencyKey "legacy-review-$status" |
            Out-Null
    }
    $unverifiedMaterializationState = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $run | ConvertFrom-Json -Depth 50
    $unverifiedReview = @($unverifiedMaterializationState.nodes |
        Where-Object { $_.id -eq 'review' }) | Select-Object -First 1
    Assert-True (
        $null -eq $unverifiedReview.actual_model -and
        $unverifiedReview.actual_model_verification -eq 'unverified'
    ) (
        'Recovery lifecycle must accept an honest unverified actual model.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'result_pending' `
            -Message 'final is missing' -ThreadId 'legacy-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -IdempotencyKey 'missing-recovery-receipt' | Out-Null
    } 'RecoveryReceiptPath' (
        'result_pending must fail closed without a recovery receipt.'
    )

    $recoveryPaths = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $recoveryPath = Join-Path $receipts (
            "review.attempt-$attempt.result-recovery.json"
        )
        $recovery = & (
            Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
        ) -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'legacy-review-thread' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -LegacySourceAdoptionReceiptPath $legacyPath `
            -Attempt $attempt -OutputPath $recoveryPath |
            ConvertFrom-Json -Depth 30
        $recoveryPaths.Add($recoveryPath)
        Assert-True ([int]$recovery.attempt -eq $attempt) (
            "Recovery receipt $attempt must preserve its bounded attempt."
        )
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'result_pending' `
            -Message "final missing after recovery $attempt" `
            -ThreadId 'legacy-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($run, $recoveryPath)
            ) -IdempotencyKey "legacy-result-pending-$attempt" | Out-Null
        if ($attempt -lt 3) {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $run -NodeId 'review' -Status 'running' `
                -Message "bounded same-source recovery $($attempt + 1)" `
                -ThreadId 'legacy-review-thread' `
                -IdempotencyKey "legacy-recovery-running-$attempt" | Out-Null
        }
        if ($attempt -eq 1) {
            Assert-ThrowsLike {
                & (
                    Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1'
                ) -RunDirectory $run | Out-Null
            } 'not validated' (
                'A result_pending source must never satisfy completion.'
            )
        }
    }
    Assert-True ($recovery.outcome -eq 'recovery-exhausted') (
        'Only the third bounded recovery may establish recovery exhaustion.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'running' `
            -Message 'switch thread during same-source recovery' `
            -ThreadId 'wrong-thread' `
            -IdempotencyKey 'wrong-same-source-thread' | Out-Null
    } 'original thread' 'Same-source recovery must not switch thread identity.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReplacementContinuityReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'legacy-review-thread' `
            -ReplacementThreadId 'early-replacement-thread' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -RecoveryReceiptPaths @($recoveryPaths[0], $recoveryPaths[1]) `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:early-replacement' `
            -LegacySourceAdoptionReceiptPath $legacyPath `
            -OutputPath (Join-Path $receipts (
                'review.replacement-continuity.json'
            )) | Out-Null
    } 'exactly three' (
        'Replacement must remain unavailable before a complete 3/3 chain.'
    )

    $changedCheckpointPath = Join-Path $materials 'changed-checkpoint.txt'
    Set-Content -LiteralPath $changedCheckpointPath -Value 'changed-checkpoint'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReplacementContinuityReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'legacy-review-thread' `
            -ReplacementThreadId 'wrong-checkpoint-thread' `
            -CheckpointManifestPath $changedCheckpointPath `
            -InputManifestPath $inputPath `
            -RecoveryReceiptPaths @($recoveryPaths) `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:wrong-checkpoint' `
            -LegacySourceAdoptionReceiptPath $legacyPath `
            -OutputPath (Join-Path $receipts (
                'review.replacement-continuity.json'
            )) | Out-Null
    } 'changed attempt, checkpoint, or input' (
        'Replacement continuity must reject a changed checkpoint.'
    )

    $replacementPath = Join-Path $receipts (
        'review.replacement-continuity.json'
    )
    $replacement = & (
        Join-Path $scriptRoot 'New-ReplacementContinuityReceipt.ps1'
    ) -RunDirectory $run -SourceNodeId 'review' `
        -OriginalThreadId 'legacy-review-thread' `
        -ReplacementThreadId 'replacement-review-thread' `
        -CheckpointManifestPath $checkpointPath -InputManifestPath $inputPath `
        -RecoveryReceiptPaths @($recoveryPaths) `
        -AuthorizationMaterialPath $authorizationPath `
        -ActivationKey 'controller:replacement-review' `
        -LegacySourceAdoptionReceiptPath $legacyPath `
        -OutputPath $replacementPath | ConvertFrom-Json -Depth 30
    Assert-True ($replacement.recovery_receipt_hashes.Count -eq 3) (
        'Replacement continuity must bind the full 3/3 recovery chain.'
    )
    Assert-True (
        $replacement.legacy_adoption_receipt_hash -eq $legacy.receipt_hash
    ) 'Replacement continuity must bind the legacy adoption receipt.'
    $authorizationOriginal = Get-Content -LiteralPath $authorizationPath -Raw
    Set-Content -LiteralPath $authorizationPath -Value 'changed authorization'
    Assert-ThrowsLike {
        Read-ReplacementContinuityReceipt -Path $replacementPath `
            -RunDirectory $run -ExpectedSourceNodeId 'review' `
            -ExpectedReplacementThreadId 'replacement-review-thread' |
            Out-Null
    } 'Authorization material is missing or changed' (
        'Replacement continuity must bind the captured authorization material.'
    )
    Set-Content -LiteralPath $authorizationPath `
        -Value $authorizationOriginal -NoNewline

    $activatedRun = Join-Path $testRoot 'activated-legacy-run'
    Copy-Item -LiteralPath $run -Destination $activatedRun -Recurse
    $activatedPlanPath = Join-Path $activatedRun 'plan.json'
    $activatedPlan = Get-Content -LiteralPath $activatedPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $activatedPlan.policy_version = '0.7.2'
    $activatedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $activatedPlanPath
    $activatedPlanRaw = Get-Content -LiteralPath $activatedPlanPath -Raw
    $activatedPlanHash = Get-TextSha256 $activatedPlanRaw
    $activatedRunMetadataPath = Join-Path $activatedRun 'run.json'
    $activatedRunMetadata = Get-Content -LiteralPath (
        $activatedRunMetadataPath
    ) -Raw | ConvertFrom-Json -AsHashtable
    $activatedRunMetadata.policy_version = '0.7.2'
    $activatedRunMetadata.plan_hash = $activatedPlanHash
    $activatedRunMetadata | ConvertTo-Json |
        Set-Content -LiteralPath $activatedRunMetadataPath
    $activatedGenesis = [ordered]@{
        sequence = 0
        prev_hash = $null
        timestamp = '2026-07-30T00:00:00.0000000+00:00'
        event = 'run-created'
        run_id = [string]$activatedPlan.run_id
        plan_hash = $activatedPlanHash
        workspace_root = [string]$activatedRunMetadata.workspace_root
        policy_version = '0.7.2'
        actor = [string]$activatedPlan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        message = 'Validated orchestration run created.'
        thread_id = $null
        model_id = $null
        artifact = $null
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
        evidence = @()
        idempotency_key = "$($activatedPlan.run_id):run-created"
        request_fingerprint = $null
    }
    $activatedGenesis.hash = Get-OrchestrationEventHash (
        [pscustomobject]$activatedGenesis
    )
    $activatedGenesis | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $activatedRun 'events.jsonl')
    $activatedAuthorizationPath = Join-Path $activatedRun (
        'materials/authorization.txt'
    )
    $activationReceipt = & (
        Join-Path $scriptRoot 'New-RunPolicyActivationReceipt.ps1'
    ) -RunDirectory $activatedRun `
        -AuthorizationMaterialPath $activatedAuthorizationPath `
        -ActivationKey 'controller:legacy-run-policy-activation' |
        ConvertFrom-Json -Depth 100
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $activatedRun -NodeId 'review' `
            -Status replacement_pending `
            -Message 'attempt unbound lifecycle adoption' `
            -ThreadId 'replacement-review-thread' `
            -ReplacementContinuityReceiptPath (
                'receipts/review.replacement-continuity.json'
            ) -IdempotencyKey 'unbound-activated-lifecycle' | Out-Null
    } 'Illegal state transition' (
        'A migrated run cannot skip lifecycle without explicit adoption.'
    )
    $activatedLifecycle = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $activatedRun -NodeId 'review' `
        -Status replacement_pending `
        -Message 'adopt exact pre-existing replacement lifecycle' `
        -ThreadId 'replacement-review-thread' `
        -ReplacementContinuityReceiptPath (
            'receipts/review.replacement-continuity.json'
        ) -AdoptActivatedLifecycle `
        -ModelVerificationState unverified `
        -ModelVerificationEvidence (
            'observation:platform-did-not-expose-actual-model'
        ) -IdempotencyKey 'bound-activated-lifecycle' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        $activatedLifecycle.runtime_policy_version -eq '0.7.6' -and
        $activatedLifecycle.policy_activation_receipt_hash -eq
            $activationReceipt.receipt_hash -and
        $activatedLifecycle.replacement_receipt_hash -eq
            $replacement.receipt_hash
    ) 'Activated lifecycle must bind policy and replacement continuity.'
    $activatedState = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $activatedRun | ConvertFrom-Json -Depth 100
    $activatedNode = @($activatedState.nodes | Where-Object {
        $_.id -eq 'review'
    }) | Select-Object -First 1
    Assert-True (
        $activatedNode.status -eq 'replacement_pending' -and
        $activatedNode.actual_model_verification -eq 'unverified' -and
        [string]::IsNullOrWhiteSpace([string]$activatedNode.actual_model)
    ) 'Activated lifecycle must preserve an unverified actual model.'
    Assert-True (
        [int]$activatedState.materialized_workers -eq 1
    ) 'An adopted replacement lifecycle must consume one Worker slot.'

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $run -NodeId 'review' -Status 'replacement_pending' `
        -Message 'authorized same-role replacement materialized' `
        -ThreadId 'replacement-review-thread' `
        -ReplacementContinuityReceiptPath (
            [IO.Path]::GetRelativePath($run, $replacementPath)
        ) -IdempotencyKey 'replacement-pending' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $run -NodeId 'review' -Status 'running' `
        -Message 'replacement review running' `
        -ThreadId 'replacement-review-thread' `
        -IdempotencyKey 'replacement-running' | Out-Null

    $replacementRecoveryPaths = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $replacementProgressPath = Join-Path $materials (
            "replacement-progress-$attempt.json"
        )
        [ordered]@{
            schemaVersion = 1
            thread = [ordered]@{ threadId = 'replacement-review-thread' }
            page = [ordered]@{ order = 'newest_first' }
            latestAssistantMessageId = $null
            turns = @(
                [ordered]@{
                    id = "replacement-progress-turn-$attempt"
                    status = 'completed'
                    items = @(
                        [ordered]@{
                            type = 'agentMessage'
                            phase = 'commentary'
                            text = "Replacement progress without final $attempt."
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $replacementProgressPath
        $replacementRecoveryPath = Join-Path $receipts (
            "review.replacement.attempt-$attempt.result-recovery.json"
        )
        $replacementRecovery = & (
            Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
        ) -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'replacement-review-thread' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -ThreadReadPath $replacementProgressPath `
            -RecoveryStage 'replacement' `
            -ReplacementContinuityReceiptPath $replacementPath `
            -Attempt $attempt -OutputPath $replacementRecoveryPath |
            ConvertFrom-Json -Depth 30
        $replacementRecoveryPaths.Add($replacementRecoveryPath)
        Assert-True (
            $replacementRecovery.recovery_stage -eq 'replacement' -and
            $replacementRecovery.replacement_continuity_receipt_hash -eq
                $replacement.receipt_hash
        ) (
            'Replacement recovery must bind its stage and parent continuity.'
        )
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'result_pending' `
            -Message "replacement final missing after recovery $attempt" `
            -ThreadId 'replacement-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($run, $replacementRecoveryPath)
            ) -IdempotencyKey "replacement-result-pending-$attempt" | Out-Null
        if ($attempt -lt 3) {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $run -NodeId 'review' -Status 'running' `
                -Message "bounded replacement recovery $($attempt + 1)" `
                -ThreadId 'replacement-review-thread' `
                -IdempotencyKey "replacement-recovery-running-$attempt" |
                Out-Null
        }
    }
    Assert-True ($replacementRecovery.outcome -eq 'recovery-exhausted') (
        'A replacement source receives its own bounded 3/3 recovery epoch.'
    )
    $alternateRecoveryDirectory = Join-Path $run 'alternate-recovery'
    $null = New-Item -ItemType Directory -Path $alternateRecoveryDirectory
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'replacement-review-thread' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -ThreadReadPath $replacementProgressPath `
            -RecoveryStage 'replacement' `
            -ReplacementContinuityReceiptPath $replacementPath `
            -Attempt 1 -OutputPath (Join-Path $alternateRecoveryDirectory (
                'review.replacement.attempt-1.result-recovery.json'
            )) | Out-Null
    } 'canonical run receipts directory' (
        'A new directory cannot reset an exhausted replacement recovery epoch.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'replacement-review-thread' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -ThreadReadPath $replacementProgressPath `
            -RecoveryStage 'original' -Attempt 1 `
            -OutputPath (Join-Path $alternateRecoveryDirectory (
                'review.attempt-1.result-recovery.json'
            )) | Out-Null
    } 'does not match lifecycle-derived stage' (
        'A replacement thread cannot relabel recovery as original.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'running' `
            -Message 'forbidden fourth replacement recovery' `
            -ThreadId 'replacement-review-thread' `
            -IdempotencyKey 'forbidden-fourth-replacement-recovery' |
            Out-Null
    } 'attempt 3 is exhausted' (
        'An exhausted replacement recovery epoch cannot return to running.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $run | Out-Null
    } 'not validated' (
        'Exhausted replacement recovery must keep completion blocked.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReplacementContinuityReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -OriginalThreadId 'replacement-review-thread' `
            -ReplacementThreadId 'forbidden-second-replacement' `
            -CheckpointManifestPath $checkpointPath `
            -InputManifestPath $inputPath `
            -RecoveryReceiptPaths @($replacementRecoveryPaths) `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:replacement-of-replacement' `
            -OutputPath (Join-Path $receipts (
                'review.second-replacement-continuity.json'
            )) | Out-Null
    } 'recovery stage' (
        'Replacement-stage recovery cannot authorize replacement-of-replacement.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status 'replacement_pending' `
            -Message 'forbidden replacement-of-replacement' `
            -ThreadId 'replacement-review-thread' `
            -ReplacementContinuityReceiptPath (
                [IO.Path]::GetRelativePath($run, $replacementPath)
            ) -IdempotencyKey 'forbidden-replacement-of-replacement' |
            Out-Null
    } 'cannot authorize a replacement-of-replacement' (
        'The lifecycle must remain blocked after replacement recovery exhausts.'
    )

    $finalCapturePath = Join-Path $materials 'replacement-final.json'
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ threadId = 'replacement-review-thread' }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = 'replacement-final-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'Replacement source reports one bounded finding.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $finalCapturePath
    $findingsPath = Join-Path $materials 'replacement-findings.json'
    @(
        [ordered]@{
            finding_id = 'replacement-finding-001'
            severity = 'P1'
            text = 'The replacement found a bounded unresolved issue.'
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $findingsPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $run -SourceNodeId 'review' `
            -ThreadId 'replacement-review-thread' -HostId 'test-host' `
            -ThreadReadPath $finalCapturePath `
            -OutputPath (Join-Path $receipts (
                'omitted-continuity.thread-result-receipt.json'
            )) -PendingFindingRecordsPath $findingsPath | Out-Null
    } 'requires its continuity receipt' (
        'A replacement result cannot omit continuity and masquerade as original.'
    )
    $resultPath = Join-Path $receipts (
        'review.thread-result-receipt.json'
    )
    $result = & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
        -RunDirectory $run -SourceNodeId 'review' `
        -ThreadId 'replacement-review-thread' -HostId 'test-host' `
        -ThreadReadPath $finalCapturePath -OutputPath $resultPath `
        -ReplacementContinuityReceiptPath $replacementPath `
        -PendingFindingRecordsPath $findingsPath |
        ConvertFrom-Json -Depth 30
    Assert-True (
        $result.source_kind -eq 'replacement' -and
        $result.source_node_id -eq 'review'
    ) 'Replacement result must identify its logical source and replacement kind.'
    Assert-ThrowsLike {
        Read-ThreadResultReceipt -Path $resultPath `
            -ExpectedThreadId 'replacement-review-thread' `
            -ExpectedSourceNodeId 'draft' -RunDirectory $run | Out-Null
    } 'logical source' 'A replacement result cannot satisfy another source.'

    $tamperedResultPath = Join-Path $receipts (
        'tampered.thread-result-receipt.json'
    )
    $tampered = Get-Content -LiteralPath $resultPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 30
    $tampered.source_kind = 'original'
    $tamperedPayload = [ordered]@{}
    foreach ($entry in $tampered.GetEnumerator()) {
        if ($entry.Key -ne 'receipt_hash') {
            $tamperedPayload[$entry.Key] = $entry.Value
        }
    }
    $tampered.receipt_hash = Get-TextSha256 (
        $tamperedPayload | ConvertTo-Json -Compress -Depth 30
    )
    $tampered | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $tamperedResultPath
    Assert-ThrowsLike {
        Read-ThreadResultReceipt -Path $tamperedResultPath `
            -ExpectedThreadId 'replacement-review-thread' `
            -ExpectedSourceNodeId 'review' -RunDirectory $run | Out-Null
    } 'Original result cannot claim replacement continuity' (
        'A replacement result cannot masquerade as an original PASS.'
    )

    $state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $run | ConvertFrom-Json -Depth 50
    $reviewState = @($state.nodes | Where-Object {
        [string]$_.id -eq 'review'
    }) | Select-Object -First 1
    Assert-True (
        $reviewState.status -eq 'result_pending'
    ) 'Replacement execution should remain blocked until a final result event.'

    # A durable original source can open a fresh bounded recovery cycle for a
    # new checkpoint without consuming or replaying the preceding checkpoint.
    $cyclePlanPath = Join-Path $testRoot 'recovery-cycle-plan.json'
    New-RecoveryCyclePlan -Path $cyclePlanPath
    $cycleRun = Join-Path $testRoot 'recovery-cycle-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $cyclePlanPath -RunDirectory $cycleRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $modelArguments = if ($status -eq 'materialized') {
            @{
                ModelVerificationState = 'unverified'
                ModelVerificationEvidence = 'observation:model-not-exposed'
            }
        } else { @{} }
        $thread = if ($status -in @('materialized', 'running')) {
            'cycle-review-thread'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status $status `
            -Message "cycle review $status" -ThreadId $thread `
            @modelArguments -IdempotencyKey "cycle-review-$status" |
            Out-Null
    }
    $cycleMaterials = Join-Path $cycleRun 'materials'
    $cycleReceipts = Join-Path $cycleRun 'receipts'
    $null = New-Item -ItemType Directory -Path $cycleMaterials, $cycleReceipts
    $checkpointA = Join-Path $cycleMaterials 'checkpoint-a.json'
    $inputA = Join-Path $cycleMaterials 'input-a.json'
    $captureA = Join-Path $cycleMaterials 'capture-a.json'
    Set-Content -LiteralPath $checkpointA -Value '{"checkpoint":"a"}'
    Set-Content -LiteralPath $inputA -Value '{"input":"a"}'
    New-ProgressCapture -Path $captureA -ThreadId 'cycle-review-thread' `
        -TurnId 'checkpoint-a-turn'
    $cycleA = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $cycleRun -SourceNodeId 'review' `
        -OriginalThreadId 'cycle-review-thread' `
        -CheckpointManifestPath $checkpointA `
        -InputManifestPath $inputA -ThreadReadPath $captureA `
        -MilestoneId 'group-1' -Attempt 1 |
        ConvertFrom-Json -Depth 30
    $cycleAPath = Join-Path $cycleReceipts (
        "review.cycle-$($cycleA.recovery_cycle_id)." +
        'attempt-1.result-recovery.json'
    )
    Assert-True (
        $cycleA.schema_version -eq '1.2' -and
        $cycleA.milestone_id -eq 'group-1' -and
        (Test-Path -LiteralPath $cycleAPath -PathType Leaf)
    ) 'Original recovery should create a milestone-bound cycle receipt.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
        -Message 'checkpoint A final missing' `
        -ThreadId 'cycle-review-thread' `
        -ErrorClass 'final_missing_with_progress_evidence' `
        -RecoveryReceiptPath (
            [IO.Path]::GetRelativePath($cycleRun, $cycleAPath)
        ) -IdempotencyKey 'checkpoint-a-result-pending' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $cycleRun -NodeId 'review' -Status 'running' `
        -Message 'checkpoint A recovery returned a final' `
        -ThreadId 'cycle-review-thread' `
        -IdempotencyKey 'checkpoint-a-recovered-running' | Out-Null
    $finalCaptureA = Join-Path $cycleMaterials 'checkpoint-a-final.json'
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = 'cycle-review-thread' }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = 'checkpoint-a-final-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'Checkpoint A review completed with one finding.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $finalCaptureA
    $findingTextA = 'Checkpoint A requires one bounded correction.'
    $findingsA = Join-Path $cycleMaterials 'checkpoint-a-findings.json'
    @(
        [ordered]@{
            finding_id = 'cycle-a-finding-001'
            severity = 'P1'
            text = $findingTextA
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $findingsA
    $resultAPath = Join-Path $cycleReceipts (
        'review.checkpoint-a.thread-result-receipt.json'
    )
    $resultA = & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
        -RunDirectory $cycleRun -SourceNodeId 'review' `
        -ThreadId 'cycle-review-thread' -HostId 'test-host' `
        -ThreadReadPath $finalCaptureA -OutputPath $resultAPath `
        -MilestoneId 'group-1' -CheckpointMaterialPath $checkpointA `
        -PendingFindingRecordsPath $findingsA |
        ConvertFrom-Json -Depth 30
    $decisionsAPath = Join-Path $cycleMaterials 'checkpoint-a-decisions.json'
    @(
        [ordered]@{
            source_finding_id = 'cycle-a-finding-001'
            finding = $findingTextA
            finding_hash = Get-TextSha256 $findingTextA
            canonical_finding_id = 'cycle-a.finding-001'
            severity = 'P1'
            disposition = 'adopted'
            rationale = 'The bounded correction was incorporated.'
            resolution_status = 'resolved'
            evidence = @('test:checkpoint-a-correction')
            re_review_status = 'completed'
            re_review_source_node_id = 'review'
            re_review_evidence = @('test:checkpoint-a-rereview')
        }
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $decisionsAPath
    $dispositionAPath = Join-Path $cycleReceipts (
        'review.checkpoint-a.disposition.json'
    )
    $dispositionA = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $cycleRun -MilestoneId 'group-1' `
        -SourceNodeId 'review' -SourceThreadId 'cycle-review-thread' `
        -SourceResultReceiptPath $resultAPath -DecisionsPath $decisionsAPath `
        -OutputPath $dispositionAPath | ConvertFrom-Json -Depth 30
    foreach ($status in @('completed', 'validated', 'adopted')) {
        $evidence = if ($status -eq 'completed') {
            @(
                "artifact:receipts/$([IO.Path]::GetFileName($resultAPath))"
            )
        } else {
            @(
                "artifact:receipts/$([IO.Path]::GetFileName($resultAPath))"
                "artifact:receipts/$([IO.Path]::GetFileName($dispositionAPath))"
            )
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status $status `
            -Message "checkpoint A review $status" `
            -ThreadId 'cycle-review-thread' -Evidence $evidence `
            -IdempotencyKey "checkpoint-a-$status" | Out-Null
    }
    Assert-True (
        $resultA.receipt_hash -match '^[0-9a-f]{64}$' -and
        $dispositionA.receipt_hash -match '^[0-9a-f]{64}$'
    ) 'Checkpoint A must have a verified result and disposition before re-entry.'

    $checkpointB = Join-Path $cycleMaterials 'checkpoint-b.json'
    $inputB = Join-Path $cycleMaterials 'input-b.json'
    $captureB1 = Join-Path $cycleMaterials 'capture-b-1.json'
    Set-Content -LiteralPath $checkpointB -Value '{"checkpoint":"b"}'
    Set-Content -LiteralPath $inputB -Value '{"input":"b"}'
    New-ProgressCapture -Path $captureB1 -ThreadId 'cycle-review-thread' `
        -TurnId 'checkpoint-b-turn-1'
    $cycleB1 = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $cycleRun -SourceNodeId 'review' `
        -OriginalThreadId 'cycle-review-thread' `
        -CheckpointManifestPath $checkpointB `
        -InputManifestPath $inputB -ThreadReadPath $captureB1 `
        -MilestoneId 'group-1' -Attempt 1 |
        ConvertFrom-Json -Depth 30
    Assert-True (
        $cycleB1.recovery_cycle_id -ne $cycleA.recovery_cycle_id -and
        $cycleB1.attempt -eq 1
    ) 'A new checkpoint must start a distinct bounded cycle at attempt one.'

    $changedInputB = Join-Path $cycleMaterials 'input-b-changed.json'
    Set-Content -LiteralPath $changedInputB -Value '{"input":"changed"}'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $cycleRun -SourceNodeId 'review' `
            -OriginalThreadId 'cycle-review-thread' `
            -CheckpointManifestPath $checkpointB `
            -InputManifestPath $changedInputB -ThreadReadPath $captureB1 `
            -MilestoneId 'group-1' -Attempt 1 | Out-Null
    } 'different input or milestone identity' (
        'The same checkpoint cannot reset attempts by changing its input.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $cycleRun -SourceNodeId 'review' `
            -OriginalThreadId 'cycle-review-thread' `
            -CheckpointManifestPath $checkpointB `
            -InputManifestPath $inputB -ThreadReadPath $captureB1 `
            -MilestoneId 'final-gate' -Attempt 1 | Out-Null
    } 'active durable milestone' (
        'A recovery cycle cannot relabel the active milestone.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $cycleRun -SourceNodeId 'review' `
            -OriginalThreadId 'cycle-review-thread' `
            -CheckpointManifestPath $checkpointB `
            -InputManifestPath $inputB -ThreadReadPath $captureB1 `
            -MilestoneId 'group-1' -Attempt 1 | Out-Null
    } 'already exists' (
        'Attempt one cannot reset an existing checkpoint recovery cycle.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $cycleRun -SourceNodeId 'domain' `
            -OriginalThreadId 'cycle-review-thread' `
            -CheckpointManifestPath $checkpointB `
            -InputManifestPath $inputB -ThreadReadPath $captureB1 `
            -MilestoneId 'group-1' -Attempt 1 | Out-Null
    } 'lifecycle binding' (
        'A recovery cycle cannot cross logical source ownership.'
    )
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt -Path $cycleAPath `
            -RunDirectory $cycleRun -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'other-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'does not match its source' (
        'A recovery cycle cannot replay across durable thread identity.'
    )

    $cycleB1Path = Join-Path $cycleReceipts (
        "review.cycle-$($cycleB1.recovery_cycle_id)." +
        'attempt-1.result-recovery.json'
    )
    $eventsPath = Join-Path $cycleRun 'events.jsonl'
    $adoptedJournal = Get-Content -LiteralPath $eventsPath -Raw
    $nonCanonicalCyclePath = Join-Path $cycleMaterials (
        [IO.Path]::GetFileName($cycleB1Path)
    )
    Copy-Item -LiteralPath $cycleB1Path -Destination $nonCanonicalCyclePath
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt -Path $nonCanonicalCyclePath `
            -RunDirectory $cycleRun -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'cycle-review-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'canonical run receipts directory' (
        'A recovery receipt reader must reject a canonical filename outside ' +
        'the canonical run receipts directory.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
            -Message 'attempt non-canonical recovery receipt' `
            -ThreadId 'cycle-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($cycleRun, $nonCanonicalCyclePath)
            ) -IdempotencyKey 'non-canonical-cycle-receipt' | Out-Null
    } 'canonical run receipts directory' (
        'The event entry point must reject a recovery receipt copied outside ' +
        'the canonical namespace.'
    )
    Assert-True (
        (Get-Content -LiteralPath $eventsPath -Raw) -eq $adoptedJournal
    ) 'Rejected non-canonical recovery receipts must not change the journal.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
            -Message 'ordinary adopted reopening' `
            -ThreadId 'cycle-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -IdempotencyKey 'ordinary-adopted-reopening' | Out-Null
    } 'requires a verified RecoveryReceiptPath' (
        'Ordinary adopted state cannot reopen without a recovery-cycle receipt.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
            -Message 'replay checkpoint A recovery cycle' `
            -ThreadId 'cycle-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($cycleRun, $cycleAPath)
            ) -IdempotencyKey 'replay-checkpoint-a-cycle' | Out-Null
    } 'requires a new checkpoint' (
        'The prior checkpoint recovery cycle cannot reopen adopted state.'
    )
    $hiddenDispositionAPath = "$dispositionAPath.hidden"
    Move-Item -LiteralPath $dispositionAPath -Destination $hiddenDispositionAPath
    try {
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $cycleRun -NodeId 'review' `
                -Status 'result_pending' `
                -Message 'checkpoint B without prior disposition' `
                -ThreadId 'cycle-review-thread' `
                -ErrorClass 'final_missing_with_progress_evidence' `
                -RecoveryReceiptPath (
                    [IO.Path]::GetRelativePath($cycleRun, $cycleB1Path)
                ) -IdempotencyKey 'checkpoint-b-missing-disposition' |
                Out-Null
        } 'does not exist' (
            'A missing prior disposition must block recovery-cycle re-entry.'
        )
    }
    finally {
        Move-Item -LiteralPath $hiddenDispositionAPath `
            -Destination $dispositionAPath
    }
    Assert-True (
        (Get-Content -LiteralPath $eventsPath -Raw) -eq $adoptedJournal
    ) 'Rejected re-entry attempts must not change the journal.'

    $captureB2 = Join-Path $cycleMaterials 'capture-b-2.json'
    New-ProgressCapture -Path $captureB2 -ThreadId 'cycle-review-thread' `
        -TurnId 'checkpoint-b-turn-2'
    $cycleB2 = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $cycleRun -SourceNodeId 'review' `
        -OriginalThreadId 'cycle-review-thread' `
        -CheckpointManifestPath $checkpointB `
        -InputManifestPath $inputB -ThreadReadPath $captureB2 `
        -MilestoneId 'group-1' -Attempt 2 |
        ConvertFrom-Json -Depth 30
    $cycleB2Path = Join-Path $cycleReceipts (
        "review.cycle-$($cycleB2.recovery_cycle_id)." +
        'attempt-2.result-recovery.json'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
            -Message 'checkpoint B direct attempt two' `
            -ThreadId 'cycle-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($cycleRun, $cycleB2Path)
            ) -IdempotencyKey 'checkpoint-b-direct-attempt-2' | Out-Null
    } 'attempt one' (
        'Attempt two cannot directly reopen an adopted source.'
    )
    Assert-True (
        (Get-Content -LiteralPath $eventsPath -Raw) -eq $adoptedJournal
    ) 'Direct attempt-two rejection must not change the journal.'

    $cycleBEvent = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
        -Message 'checkpoint B final missing' `
        -ThreadId 'cycle-review-thread' `
        -ErrorClass 'final_missing_with_progress_evidence' `
        -RecoveryReceiptPath (
            [IO.Path]::GetRelativePath($cycleRun, $cycleB1Path)
        ) -IdempotencyKey 'checkpoint-b-result-pending-1' |
        ConvertFrom-Json -Depth 30
    Assert-True (
        [string]$cycleBEvent.recovery_cycle_id -eq
            [string]$cycleB1.recovery_cycle_id -and
        [string]$cycleBEvent.recovery_checkpoint_hash -eq
            [string]$cycleB1.checkpoint_hash -and
        [string]$cycleBEvent.recovery_input_manifest_hash -eq
            [string]$cycleB1.input_manifest_hash -and
        [int]$cycleBEvent.previous_adopted_event_sequence -ge 1 -and
        [string]$cycleBEvent.previous_adopted_event_hash -match
            '^[0-9a-f]{64}$'
    ) (
        'Recovery-cycle re-entry must hash-bind the prior adopted event and ' +
        'new checkpoint/input cycle.'
    )
    $cycleBEventRetry = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
        -Message 'checkpoint B final missing' `
        -ThreadId 'cycle-review-thread' `
        -ErrorClass 'final_missing_with_progress_evidence' `
        -RecoveryReceiptPath (
            [IO.Path]::GetRelativePath($cycleRun, $cycleB1Path)
        ) -IdempotencyKey 'checkpoint-b-result-pending-1' |
        ConvertFrom-Json -Depth 30
    Assert-True (
        [string]$cycleBEventRetry.hash -eq [string]$cycleBEvent.hash
    ) 'An exact retry must return the existing recovery-cycle re-entry event.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $cycleRun -NodeId 'review' -Status 'result_pending' `
            -Message 'reuse checkpoint B attempt one' `
            -ThreadId 'cycle-review-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($cycleRun, $cycleB1Path)
            ) -IdempotencyKey 'checkpoint-b-reuse-attempt-1' | Out-Null
    } 'Illegal state transition' (
        'A used recovery cycle cannot append a second result_pending event.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $cycleRun | Out-Null
    } 'not validated' (
        'A new recovery cycle must preserve result_pending completion blocking.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $cycleRun -NodeId 'review' -Status 'running' `
        -Message 'checkpoint B bounded recovery attempt two' `
        -ThreadId 'cycle-review-thread' `
        -IdempotencyKey 'checkpoint-b-running-2' | Out-Null
    Assert-True (
        $cycleB2.recovery_cycle_id -eq $cycleB1.recovery_cycle_id -and
        $cycleB2.previous_receipt_hash -eq $cycleB1.receipt_hash
    ) 'Attempts inside one cycle must chain to the prior cycle receipt.'
    $cycleB2Original = Get-Content -LiteralPath $cycleB2Path -Raw
    $crossCheckpoint = $cycleB2Original |
        ConvertFrom-Json -AsHashtable -Depth 30
    $crossCheckpoint.previous_receipt_path = [IO.Path]::GetRelativePath(
        $cycleRun, $cycleAPath
    ).Replace('\', '/')
    $crossCheckpoint.previous_receipt_hash = $cycleA.receipt_hash
    $crossCheckpointPayload = [ordered]@{}
    foreach ($entry in $crossCheckpoint.GetEnumerator()) {
        if ($entry.Key -ne 'receipt_hash') {
            $crossCheckpointPayload[$entry.Key] = $entry.Value
        }
    }
    $crossCheckpoint.receipt_hash = Get-TextSha256 (
        $crossCheckpointPayload | ConvertTo-Json -Compress -Depth 30
    )
    $crossCheckpoint | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $cycleB2Path
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt -Path $cycleB2Path `
            -RunDirectory $cycleRun -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'cycle-review-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'chain is invalid' (
        'A later attempt cannot chain to a prior checkpoint recovery receipt.'
    )
    Set-Content -LiteralPath $cycleB2Path -Value $cycleB2Original -NoNewline

    $replayedCycle = $cycleB2Original |
        ConvertFrom-Json -AsHashtable -Depth 30
    $replayedCycle.recovery_cycle_id = $cycleA.recovery_cycle_id
    $replayedPayload = [ordered]@{}
    foreach ($entry in $replayedCycle.GetEnumerator()) {
        if ($entry.Key -ne 'receipt_hash') {
            $replayedPayload[$entry.Key] = $entry.Value
        }
    }
    $replayedCycle.receipt_hash = Get-TextSha256 (
        $replayedPayload | ConvertTo-Json -Compress -Depth 30
    )
    $replayedCycle | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $cycleB2Path
    Assert-ThrowsLike {
        Read-ThreadResultRecoveryReceipt -Path $cycleB2Path `
            -RunDirectory $cycleRun -ExpectedSourceNodeId 'review' `
            -ExpectedOriginalThreadId 'cycle-review-thread' `
            -ExpectedRecoveryStage original | Out-Null
    } 'cycle binding is invalid' (
        'An old recovery cycle identity cannot be replayed at a new checkpoint.'
    )
    Set-Content -LiteralPath $cycleB2Path -Value $cycleB2Original -NoNewline

    # A same-role replacement is checkpoint-scoped. After its verified result
    # is adopted, the same replacement thread may review the next declared
    # milestone only through one append-only roll-forward receipt. The receipt
    # also creates a separate bounded recovery namespace for the new checkpoint.
    $rollPlanPath = Join-Path $testRoot 'replacement-roll-forward-plan.json'
    New-RecoveryCyclePlan -Path $rollPlanPath
    $rollRun = Join-Path $testRoot 'replacement-roll-forward-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $rollPlanPath -RunDirectory $rollRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $modelArguments = if ($status -eq 'materialized') {
            @{
                ModelVerificationState = 'unverified'
                ModelVerificationEvidence = 'observation:model-not-exposed'
            }
        } else { @{} }
        $thread = if ($status -in @('materialized', 'running')) {
            'roll-original-thread'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rollRun -NodeId 'review' -Status $status `
            -Message "roll-forward original $status" -ThreadId $thread `
            @modelArguments -IdempotencyKey "roll-original-$status" |
            Out-Null
    }
    $rollMaterials = Join-Path $rollRun 'materials'
    $rollReceipts = Join-Path $rollRun 'receipts'
    $null = New-Item -ItemType Directory -Path $rollMaterials, $rollReceipts
    $rollCheckpointA = Join-Path $rollMaterials 'checkpoint-a.json'
    $rollInputA = Join-Path $rollMaterials 'input-a.json'
    $rollAuthorizationA = Join-Path $rollMaterials 'replacement-auth-a.md'
    Set-Content -LiteralPath $rollCheckpointA -Value '{"checkpoint":"a"}'
    Set-Content -LiteralPath $rollInputA -Value '{"input":"a"}'
    Set-Content -LiteralPath $rollAuthorizationA -Value (
        'Controller authorizes one same-role read-only replacement for ' +
        'checkpoint A only.'
    )
    $rollOriginalRecoveryPaths =
        [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $progressPath = Join-Path $rollMaterials (
            "original-progress-$attempt.json"
        )
        New-ProgressCapture -Path $progressPath `
            -ThreadId 'roll-original-thread' `
            -TurnId "roll-original-progress-$attempt"
        $recovery = & (
            Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
        ) -RunDirectory $rollRun -SourceNodeId 'review' `
            -OriginalThreadId 'roll-original-thread' `
            -CheckpointManifestPath $rollCheckpointA `
            -InputManifestPath $rollInputA -ThreadReadPath $progressPath `
            -MilestoneId 'group-1' -Attempt $attempt |
            ConvertFrom-Json -Depth 50
        $recoveryPath = Join-Path $rollReceipts (
            "review.cycle-$($recovery.recovery_cycle_id)." +
            "attempt-$attempt.result-recovery.json"
        )
        $rollOriginalRecoveryPaths.Add($recoveryPath)
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rollRun -NodeId 'review' `
            -Status 'result_pending' `
            -Message "roll original final missing $attempt" `
            -ThreadId 'roll-original-thread' `
            -ErrorClass 'final_missing_with_progress_evidence' `
            -RecoveryReceiptPath (
                [IO.Path]::GetRelativePath($rollRun, $recoveryPath)
            ) -IdempotencyKey "roll-original-pending-$attempt" | Out-Null
        if ($attempt -lt 3) {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
                -Message "roll original recovery $attempt" `
                -ThreadId 'roll-original-thread' `
                -IdempotencyKey "roll-original-running-$attempt" | Out-Null
        }
    }
    $rollContinuityPath = Join-Path $rollReceipts (
        'review.replacement-continuity.json'
    )
    $rollContinuity = & (
        Join-Path $scriptRoot 'New-ReplacementContinuityReceipt.ps1'
    ) -RunDirectory $rollRun -SourceNodeId 'review' `
        -OriginalThreadId 'roll-original-thread' `
        -ReplacementThreadId 'roll-replacement-thread' `
        -CheckpointManifestPath $rollCheckpointA `
        -InputManifestPath $rollInputA `
        -RecoveryReceiptPaths @($rollOriginalRecoveryPaths) `
        -AuthorizationMaterialPath $rollAuthorizationA `
        -ActivationKey 'controller:roll-replacement-a' `
        -OutputPath $rollContinuityPath | ConvertFrom-Json -Depth 50
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $rollRun -NodeId 'review' `
        -Status 'replacement_pending' `
        -Message 'checkpoint A replacement materialized' `
        -ThreadId 'roll-replacement-thread' `
        -ReplacementContinuityReceiptPath (
            [IO.Path]::GetRelativePath($rollRun, $rollContinuityPath)
        ) -Evidence @(
            'observation:requested-route:gpt-5.6-sol/high',
            'observation:actual-model:unverified'
        ) -IdempotencyKey 'roll-replacement-pending' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
        -Message 'checkpoint A replacement running' `
        -ThreadId 'roll-replacement-thread' `
        -IdempotencyKey 'roll-replacement-running' | Out-Null

    $rollFinalA = Join-Path $rollMaterials 'replacement-final-a.json'
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = 'roll-replacement-thread' }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = 'roll-replacement-final-a'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'Replacement checkpoint A result.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rollFinalA
    $rollFindingText = 'One carry-forward finding remains open.'
    $rollFindingsA = Join-Path $rollMaterials 'replacement-findings-a.json'
    @(
        [ordered]@{
            finding_id = 'roll-finding-001'
            severity = 'P1'
            text = $rollFindingText
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rollFindingsA
    $rollResultAPath = Join-Path $rollReceipts (
        'review.roll-a.thread-result-receipt.json'
    )
    $rollResultA = & (
        Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1'
    ) -RunDirectory $rollRun -SourceNodeId 'review' `
        -ThreadId 'roll-replacement-thread' -HostId 'test-host' `
        -ThreadReadPath $rollFinalA -OutputPath $rollResultAPath `
        -MilestoneId 'final-gate' `
        -CheckpointMaterialPath $rollCheckpointA `
        -ReplacementContinuityReceiptPath $rollContinuityPath `
        -PendingFindingRecordsPath $rollFindingsA |
        ConvertFrom-Json -Depth 50
    $rollDecisionsA = Join-Path $rollMaterials 'replacement-decisions-a.json'
    @(
        [ordered]@{
            source_finding_id = 'roll-finding-001'
            finding = $rollFindingText
            finding_hash = Get-TextSha256 $rollFindingText
            canonical_finding_id = 'roll.finding-001'
            severity = 'P1'
            disposition = 'adopted'
            rationale = 'The next checkpoint must re-review the finding.'
            resolution_status = 'open'
            evidence = @('source:replacement-checkpoint-a')
            re_review_status = 'requested'
            re_review_source_node_id = 'review'
            re_review_evidence = @()
        }
    ) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rollDecisionsA
    $rollDispositionAPath = Join-Path $rollReceipts (
        'review.roll-a.disposition.json'
    )
    $rollDispositionA = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $rollRun -MilestoneId 'final-gate' `
        -SourceNodeId 'review' -SourceThreadId 'roll-replacement-thread' `
        -SourceResultReceiptPath $rollResultAPath `
        -DecisionsPath $rollDecisionsA -OutputPath $rollDispositionAPath |
        ConvertFrom-Json -Depth 50
    foreach ($status in @('completed', 'validated', 'adopted')) {
        $evidence = if ($status -eq 'completed') {
            @("artifact:receipts/$([IO.Path]::GetFileName($rollResultAPath))")
        } else {
            @(
                "artifact:receipts/$([IO.Path]::GetFileName($rollResultAPath))",
                "artifact:receipts/$([IO.Path]::GetFileName(
                    $rollDispositionAPath
                ))"
            )
        }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rollRun -NodeId 'review' -Status $status `
            -Message "replacement checkpoint A $status" `
            -ThreadId 'roll-replacement-thread' -Evidence $evidence `
            -IdempotencyKey "roll-replacement-a-$status" | Out-Null
    }

    $rollCheckpointB = Join-Path $rollMaterials 'checkpoint-b.json'
    $rollInputB = Join-Path $rollMaterials 'input-b.json'
    $rollAuthorizationB = Join-Path $rollMaterials 'roll-forward-auth-b.md'
    Set-Content -LiteralPath $rollCheckpointB -Value '{"checkpoint":"b"}'
    Set-Content -LiteralPath $rollInputB -Value '{"input":"b"}'
    Set-Content -LiteralPath $rollAuthorizationB -Value (
        'Controller authorizes the adopted replacement seat, on the same ' +
        'thread and role, to review checkpoint B for final-gate.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
            -Message 'ordinary adopted replacement reopen' `
            -ThreadId 'roll-replacement-thread' `
            -IdempotencyKey 'ordinary-replacement-reopen' | Out-Null
    } 'terminal' (
        'An adopted replacement must stay terminal without checkpoint roll-forward.'
    )
    $rollForward = & (
        Join-Path $scriptRoot 'New-ReplacementCheckpointRollForwardReceipt.ps1'
    ) -RunDirectory $rollRun -SourceNodeId 'review' `
        -ReplacementThreadId 'roll-replacement-thread' `
        -ReplacementContinuityReceiptPath $rollContinuityPath `
        -PriorResultReceiptPath $rollResultAPath `
        -PriorDispositionReceiptPath $rollDispositionAPath `
        -TargetMilestoneId 'final-gate' `
        -CheckpointManifestPath $rollCheckpointB `
        -InputManifestPath $rollInputB `
        -AuthorizationMaterialPath $rollAuthorizationB `
        -ActivationKey 'controller:roll-replacement-checkpoint-b' |
        ConvertFrom-Json -Depth 50
    $rollForwardPath = Join-Path $rollReceipts (
        "review.replacement-roll-forward-$($rollForward.roll_forward_id).json"
    )
    Assert-True (
        $rollForward.source_kind -eq 'replacement' -and
        $rollForward.replacement_thread_id -eq 'roll-replacement-thread' -and
        $rollForward.previous_result_receipt_hash -eq
            $rollResultA.receipt_hash -and
        $rollForward.previous_disposition_receipt_hash -eq
            $rollDispositionA.receipt_hash -and
        $rollForward.target_milestone_id -eq 'final-gate' -and
        (Test-Path -LiteralPath $rollForwardPath -PathType Leaf)
    ) 'Replacement roll-forward must bind prior adoption and the new checkpoint.'
    $rollForwardOriginal = Get-Content -LiteralPath $rollForwardPath -Raw
    function Assert-RollForwardMutationRejected {
        param(
            [string] $Field,
            [object] $Value,
            [string] $ExpectedMessage,
            [string] $AssertionMessage
        )
        $mutatedRollForward = $rollForwardOriginal |
            ConvertFrom-Json -AsHashtable -Depth 100
        $mutatedRollForward[$Field] = $Value
        $mutatedPayload = [ordered]@{}
        foreach ($entry in $mutatedRollForward.GetEnumerator()) {
            if ($entry.Key -ne 'receipt_hash') {
                $mutatedPayload[$entry.Key] = $entry.Value
            }
        }
        $mutatedRollForward.receipt_hash = Get-TextSha256 (
            $mutatedPayload | ConvertTo-Json -Compress -Depth 100
        )
        $mutatedRollForward | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $rollForwardPath
        try {
            Assert-ThrowsLike {
                Read-ReplacementCheckpointRollForwardReceipt `
                    -Path $rollForwardPath -RunDirectory $rollRun `
                    -ExpectedSourceNodeId 'review' `
                    -ExpectedReplacementThreadId 'roll-replacement-thread' |
                    Out-Null
            } $ExpectedMessage $AssertionMessage
        } finally {
            Set-Content -LiteralPath $rollForwardPath `
                -Value $rollForwardOriginal -NoNewline
        }
    }
    Assert-RollForwardMutationRejected -Field 'source_kind' -Value 'original' `
        -ExpectedMessage 'logical source' `
        -AssertionMessage 'A roll-forward cannot relabel replacement as original.'
    Assert-RollForwardMutationRejected -Field 'role_id' -Value 'other-role' `
        -ExpectedMessage 'changed source role' `
        -AssertionMessage 'A roll-forward cannot change the durable role.'
    Assert-RollForwardMutationRejected `
        -Field 'replacement_continuity_receipt_hash' -Value ('0' * 64) `
        -ExpectedMessage 'changed parent continuity' `
        -AssertionMessage 'A roll-forward cannot detach from parent continuity.'
    Assert-RollForwardMutationRejected `
        -Field 'previous_result_receipt_hash' -Value ('1' * 64) `
        -ExpectedMessage 'changed the prior verified result' `
        -AssertionMessage 'A roll-forward cannot replace the prior result.'
    Assert-RollForwardMutationRejected `
        -Field 'previous_disposition_receipt_hash' -Value ('2' * 64) `
        -ExpectedMessage 'changed the prior verified result' `
        -AssertionMessage 'A roll-forward cannot replace the prior disposition.'
    Assert-RollForwardMutationRejected `
        -Field 'previous_adopted_event_hash' -Value ('3' * 64) `
        -ExpectedMessage 'terminal adopted replacement result chain' `
        -AssertionMessage 'A roll-forward cannot rewrite the prior adopted event.'
    Assert-RollForwardMutationRejected -Field 'checkpoint_hash' `
        -Value ('4' * 64) -ExpectedMessage 'Checkpoint manifest is missing or changed' `
        -AssertionMessage 'A roll-forward cannot change the new checkpoint.'
    Assert-RollForwardMutationRejected -Field 'input_manifest_hash' `
        -Value ('5' * 64) -ExpectedMessage 'Input manifest is missing or changed' `
        -AssertionMessage 'A roll-forward cannot change the new input.'
    Assert-RollForwardMutationRejected `
        -Field 'active_milestone_activation_receipt_hash' -Value ('6' * 64) `
        -ExpectedMessage 'baseline binding is invalid' `
        -AssertionMessage 'A roll-forward cannot change the active activation epoch.'
    Assert-ThrowsLike {
        & (
            Join-Path $scriptRoot 'New-ReplacementCheckpointRollForwardReceipt.ps1'
        ) -RunDirectory $rollRun -SourceNodeId 'review' `
            -ReplacementThreadId 'roll-replacement-thread' `
            -ReplacementContinuityReceiptPath $rollContinuityPath `
            -PriorResultReceiptPath $rollResultAPath `
            -PriorDispositionReceiptPath $rollDispositionAPath `
            -TargetMilestoneId 'final-gate' `
            -CheckpointManifestPath $rollCheckpointA `
            -InputManifestPath $rollInputB `
            -AuthorizationMaterialPath $rollAuthorizationB `
            -ActivationKey 'controller:roll-replacement-checkpoint-a-replay' |
            Out-Null
    } 'requires a new checkpoint' (
        'A replacement roll-forward cannot replay its prior checkpoint.'
    )
    Assert-ThrowsLike {
        & (
            Join-Path $scriptRoot 'New-ReplacementCheckpointRollForwardReceipt.ps1'
        ) -RunDirectory $rollRun -SourceNodeId 'review' `
            -ReplacementThreadId 'roll-replacement-thread' `
            -ReplacementContinuityReceiptPath $rollContinuityPath `
            -PriorResultReceiptPath $rollResultAPath `
            -PriorDispositionReceiptPath $rollDispositionAPath `
            -TargetMilestoneId 'final-gate' `
            -CheckpointManifestPath $rollCheckpointB `
            -InputManifestPath $rollInputB `
            -AuthorizationMaterialPath $rollAuthorizationB `
            -ActivationKey 'controller:roll-replacement-checkpoint-b-fork' |
            Out-Null
    } 'already has a checkpoint roll-forward' (
        'A replacement seat cannot fork the same next-milestone roll-forward.'
    )
    Assert-ThrowsLike {
        Read-ReplacementCheckpointRollForwardReceipt `
            -Path $rollForwardPath -RunDirectory $rollRun `
            -ExpectedSourceNodeId 'domain' `
            -ExpectedReplacementThreadId 'roll-replacement-thread' | Out-Null
    } 'logical source' 'A roll-forward cannot cross source ownership.'
    Assert-ThrowsLike {
        Read-ReplacementCheckpointRollForwardReceipt `
            -Path $rollForwardPath -RunDirectory $rollRun `
            -ExpectedSourceNodeId 'review' `
            -ExpectedReplacementThreadId 'other-thread' | Out-Null
    } 'logical source' 'A roll-forward cannot cross replacement thread identity.'

    $rollForwardEvent = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
        -Message 'replacement seat rolled forward to checkpoint B' `
        -ThreadId 'roll-replacement-thread' `
        -ReplacementCheckpointRollForwardReceiptPath (
            [IO.Path]::GetRelativePath($rollRun, $rollForwardPath)
        ) -IdempotencyKey 'roll-replacement-b-running' |
        ConvertFrom-Json -Depth 50
    Assert-True (
        $rollForwardEvent.replacement_roll_forward_receipt_hash -eq
            $rollForward.receipt_hash -and
        $rollForwardEvent.replacement_roll_forward_id -eq
            $rollForward.roll_forward_id -and
        $rollForwardEvent.replacement_checkpoint_hash -eq
            $rollForward.checkpoint_hash
    ) 'The adopted-to-running event must immutably bind the roll-forward receipt.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
            -Message 'duplicate replacement roll-forward' `
            -ThreadId 'roll-replacement-thread' `
            -ReplacementCheckpointRollForwardReceiptPath (
                [IO.Path]::GetRelativePath($rollRun, $rollForwardPath)
            ) -IdempotencyKey 'duplicate-roll-replacement-b' | Out-Null
    } 'only valid for adopted-to-running' (
        'A used replacement checkpoint roll-forward cannot be consumed twice.'
    )

    $rollProgressB = Join-Path $rollMaterials 'replacement-progress-b.json'
    New-ProgressCapture -Path $rollProgressB `
        -ThreadId 'roll-replacement-thread' `
        -TurnId 'roll-replacement-progress-b'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1') `
            -RunDirectory $rollRun -SourceNodeId 'review' `
            -OriginalThreadId 'roll-replacement-thread' `
            -CheckpointManifestPath $rollCheckpointB `
            -InputManifestPath $rollInputB -ThreadReadPath $rollProgressB `
            -RecoveryStage 'replacement' `
            -ReplacementContinuityReceiptPath $rollContinuityPath `
            -Attempt 1 | Out-Null
    } 'roll-forward receipt' (
        'Replacement recovery at a new checkpoint requires its roll-forward.'
    )
    $rollRecoveryB = & (
        Join-Path $scriptRoot 'New-ThreadResultRecoveryReceipt.ps1'
    ) -RunDirectory $rollRun -SourceNodeId 'review' `
        -OriginalThreadId 'roll-replacement-thread' `
        -CheckpointManifestPath $rollCheckpointB `
        -InputManifestPath $rollInputB -ThreadReadPath $rollProgressB `
        -RecoveryStage 'replacement' `
        -ReplacementContinuityReceiptPath $rollContinuityPath `
        -ReplacementCheckpointRollForwardReceiptPath $rollForwardPath `
        -Attempt 1 | ConvertFrom-Json -Depth 50
    $rollRecoveryBPath = Join-Path $rollReceipts (
        "review.replacement-cycle-$($rollRecoveryB.recovery_cycle_id)." +
        'attempt-1.result-recovery.json'
    )
    Assert-True (
        $rollRecoveryB.schema_version -eq '1.3' -and
        $rollRecoveryB.recovery_stage -eq 'replacement' -and
        $rollRecoveryB.replacement_checkpoint_roll_forward_receipt_hash -eq
            $rollForward.receipt_hash -and
        (Test-Path -LiteralPath $rollRecoveryBPath -PathType Leaf)
    ) 'Replacement roll-forward recovery needs an independent bounded cycle.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $rollRun -NodeId 'review' -Status 'result_pending' `
        -Message 'replacement checkpoint B final missing' `
        -ThreadId 'roll-replacement-thread' `
        -ErrorClass 'final_missing_with_progress_evidence' `
        -RecoveryReceiptPath (
            [IO.Path]::GetRelativePath($rollRun, $rollRecoveryBPath)
        ) -IdempotencyKey 'roll-replacement-b-pending-1' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $rollRun -NodeId 'review' -Status 'running' `
        -Message 'replacement checkpoint B recovery returned a final' `
        -ThreadId 'roll-replacement-thread' `
        -IdempotencyKey 'roll-replacement-b-recovered' | Out-Null

    $rollFinalB = Join-Path $rollMaterials 'replacement-final-b.json'
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{ id = 'roll-replacement-thread' }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = 'roll-replacement-final-b'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'Replacement checkpoint B result.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rollFinalB
    $rollFindingsB = Join-Path $rollMaterials 'replacement-findings-b.json'
    Copy-Item -LiteralPath $rollFindingsA -Destination $rollFindingsB
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $rollRun -SourceNodeId 'review' `
            -ThreadId 'roll-replacement-thread' -HostId 'test-host' `
            -ThreadReadPath $rollFinalB `
            -OutputPath (Join-Path $rollReceipts (
                'review.roll-b-unbound.thread-result-receipt.json'
            )) -MilestoneId 'final-gate' `
            -CheckpointMaterialPath $rollCheckpointB `
            -ReplacementContinuityReceiptPath $rollContinuityPath `
            -PendingFindingRecordsPath $rollFindingsB | Out-Null
    } 'roll-forward receipt' (
        'A new-checkpoint replacement result cannot omit its roll-forward.'
    )
    $rollResultBPath = Join-Path $rollReceipts (
        'review.roll-b.thread-result-receipt.json'
    )
    $rollResultB = & (
        Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1'
    ) -RunDirectory $rollRun -SourceNodeId 'review' `
        -ThreadId 'roll-replacement-thread' -HostId 'test-host' `
        -ThreadReadPath $rollFinalB -OutputPath $rollResultBPath `
        -MilestoneId 'final-gate' -CheckpointMaterialPath $rollCheckpointB `
        -ReplacementContinuityReceiptPath $rollContinuityPath `
        -ReplacementCheckpointRollForwardReceiptPath $rollForwardPath `
        -PendingFindingRecordsPath $rollFindingsB |
        ConvertFrom-Json -Depth 50
    Assert-True (
        $rollResultB.schema_version -eq '1.4' -and
        $rollResultB.source_kind -eq 'replacement' -and
        $rollResultB.replacement_checkpoint_roll_forward_receipt_hash -eq
            $rollForward.receipt_hash
    ) 'Checkpoint B result must retain replacement kind and roll-forward binding.'
    $rollDecisionsB = Join-Path $rollMaterials 'replacement-decisions-b.json'
    Copy-Item -LiteralPath $rollDecisionsA -Destination $rollDecisionsB
    $rollDispositionBPath = Join-Path $rollReceipts (
        'review.roll-b.disposition.json'
    )
    $rollDispositionB = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $rollRun -MilestoneId 'final-gate' `
        -SourceNodeId 'review' -SourceThreadId 'roll-replacement-thread' `
        -SourceResultReceiptPath $rollResultBPath `
        -DecisionsPath $rollDecisionsB -OutputPath $rollDispositionBPath |
        ConvertFrom-Json -Depth 50
    $rollBinding = Get-DurableReviewDispositionBinding `
        -RunDirectory $rollRun `
        -Plan (Get-Content -LiteralPath (Join-Path $rollRun 'plan.json') -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String) `
        -SourceNodeId 'review' `
        -DispositionRelativePath (
            [IO.Path]::GetRelativePath($rollRun, $rollDispositionBPath)
        ) -ExpectedMilestoneId 'final-gate' `
        -RequireResultMilestoneBinding
    Assert-True (
        $rollBinding.result_receipt_hash -eq $rollResultB.receipt_hash -and
        $rollBinding.disposition_receipt_hash -eq
            $rollDispositionB.receipt_hash
    ) 'Milestone selection must accept only the roll-forward-bound result chain.'

    $fixturePath = Join-Path $skillRoot (
        'references/durable-recovery-adoption-fixtures.json'
    )
    $fixtures = Get-Content -LiteralPath $fixturePath -Raw |
        ConvertFrom-Json -Depth 30
    Assert-True (@($fixtures.cases).Count -eq 3) (
        'Recovery protocol must retain three real adoption summaries.'
    )
    Assert-True (
        @($fixtures.cases | Where-Object {
            $_.completion_state -ne 'blocked'
        }).Count -eq 0
    ) 'Every missing-final adoption fixture must remain blocked.'

    [ordered]@{
        passed = $true
        assertions = $script:assertions
        legacy_adoption_verified = $true
        bounded_recovery_verified = $true
        replacement_continuity_verified = $true
        replacement_recovery_epoch_verified = $true
        replacement_checkpoint_roll_forward_verified = $true
        original_recovery_cycles_verified = $true
        cross_source_rejected = $true
        consumer_result_only = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
