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
        $model = if ($status -eq 'materialized') { 'gpt-5.6-sol' } else { $null }
        $thread = if ($status -in @('materialized', 'running')) {
            'legacy-review-thread'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $run -NodeId 'review' -Status $status `
            -Message "legacy review $status" -ThreadId $thread `
            -ModelId $model -IdempotencyKey "legacy-review-$status" |
            Out-Null
    }
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
        $reviewState.status -eq 'running'
    ) 'Replacement execution should remain incomplete until a final result event.'

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
        cross_source_rejected = $true
        consumer_result_only = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
