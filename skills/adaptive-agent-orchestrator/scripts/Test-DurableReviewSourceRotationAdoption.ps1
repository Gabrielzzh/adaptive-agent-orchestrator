[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PredecessorRunDirectory,
    [Parameter(Mandatory)][string] $CheckpointRelativePath,
    [Parameter(Mandatory)][string] $IndependenceCaptureRelativePath,
    [Parameter(Mandatory)][string] $IndependenceInputRelativePath,
    [Parameter(Mandatory)][string] $ExhaustedInputRelativePath,
    [Parameter(Mandatory)][string[]] $ExhaustedRecoveryReceiptRelativePaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aao-source-rotation-adoption-' + [guid]::NewGuid().ToString('N')
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
        $caught = $actual -like "*$Expected*"
    }
    Assert-True $caught ($Message + $(if ($caught) { '' } else {
        " Actual: $actual"
    }))
}

function Set-ReceiptHash {
    param([hashtable] $Receipt)
    $Receipt.Remove('receipt_hash')
    $payload = [ordered]@{}
    foreach ($entry in $Receipt.GetEnumerator()) {
        $payload[$entry.Key] = $entry.Value
    }
    $Receipt.receipt_hash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 100
    )
}

function Assert-AdoptionMutationRejected {
    param(
        [string] $RunDirectory,
        [scriptblock] $Mutation,
        [string] $Expected,
        [string] $Message
    )
    $receiptPath = Join-Path $RunDirectory (
        'receipts/durable-review-successor.adoption.json'
    )
    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    $receiptRaw = Get-Content -LiteralPath $receiptPath -Raw
    $originalEventLines = @(Get-Content -LiteralPath $eventsPath)
    $eventLines = @($originalEventLines)
    try {
        $receipt = $receiptRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $Mutation $receipt
        $receipt.source_bindings_hash = Get-TextSha256 (
            @($receipt.source_bindings) |
                ConvertTo-Json -Compress -Depth 100
        )
        $receipt.inherited_obligations_hash = Get-TextSha256 (
            @($receipt.inherited_obligations) |
                ConvertTo-Json -Compress -Depth 100
        )
        Set-ReceiptHash -Receipt $receipt
        $receipt | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $receiptPath -Encoding utf8
        $event = $eventLines[1] |
            ConvertFrom-Json -AsHashtable -Depth 100
        $event.result_receipt_hash = $receipt.receipt_hash
        $event.request_fingerprint = $receipt.receipt_hash
        $event.Remove('hash')
        $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
        $eventLines[1] = $event | ConvertTo-Json -Compress -Depth 100
        $eventLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
        Assert-ThrowsLike {
            Read-DurableReviewSuccessorAdoptionReceipt `
                -RunDirectory $RunDirectory | Out-Null
        } $Expected $Message
    }
    finally {
        Set-Content -LiteralPath $receiptPath -Value $receiptRaw -Encoding utf8
        $originalEventLines | Set-Content -LiteralPath $eventsPath -Encoding utf8
    }
}

function Get-RelativeCopyPath {
    param([string] $OriginalRoot, [string] $CopyRoot, [string] $RelativePath)
    $source = Get-RunLocalReceiptPath -RunDirectory $OriginalRoot `
        -RelativePath $RelativePath -Label 'Real source-rotation fixture'
    $relative = [IO.Path]::GetRelativePath(
        [IO.Path]::GetFullPath($OriginalRoot).TrimEnd('\', '/'),
        $source
    )
    return Join-Path $CopyRoot $relative
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $originalRoot = [IO.Path]::GetFullPath(
        $PredecessorRunDirectory
    ).TrimEnd('\', '/')
    $predecessorCopy = Join-Path $testRoot 'predecessor'
    Copy-Item -LiteralPath $originalRoot -Destination $predecessorCopy -Recurse

    if ($ExhaustedRecoveryReceiptRelativePaths.Count -ne 3) {
        throw 'The real source-rotation fixture requires exactly three recoveries.'
    }
    $planPath = Join-Path $predecessorCopy 'plan.json'
    $plan = Get-Content -LiteralPath $planPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $run = Get-Content -LiteralPath (Join-Path $predecessorCopy 'run.json') -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $events = @(Read-OrchestrationJournal (
        Join-Path $predecessorCopy 'events.jsonl'
    ))
    $chain = Read-DurableReviewMilestoneActivationChain `
        -RunDirectory $predecessorCopy
    if ([string]::IsNullOrWhiteSpace([string]$chain.next_milestone_id)) {
        throw 'The real source-rotation fixture requires a next declared milestone.'
    }

    $checkpointPath = Get-RelativeCopyPath -OriginalRoot $originalRoot `
        -CopyRoot $predecessorCopy -RelativePath $CheckpointRelativePath
    $checkpointHash = Get-TextSha256 (
        Get-Content -LiteralPath $checkpointPath -Raw
    )
    $independenceCapturePath = Get-RelativeCopyPath `
        -OriginalRoot $originalRoot -CopyRoot $predecessorCopy `
        -RelativePath $IndependenceCaptureRelativePath
    $independenceCaptureRaw = Get-Content -LiteralPath (
        $independenceCapturePath
    ) -Raw
    $independenceCapture = $independenceCaptureRaw |
        ConvertFrom-Json -Depth 100 -DateKind String
    $independenceThreadId = Get-ThreadCaptureId `
        -Capture $independenceCapture -CaptureKind 'Independence-failure'
    $null = Read-ThreadReadCapture -Path $independenceCapturePath `
        -ExpectedThreadId $independenceThreadId

    $recoveryReceipts = [Collections.Generic.List[object]]::new()
    $recoveryPaths = [Collections.Generic.List[string]]::new()
    foreach ($relativePath in $ExhaustedRecoveryReceiptRelativePaths) {
        $path = Get-RelativeCopyPath -OriginalRoot $originalRoot `
            -CopyRoot $predecessorCopy -RelativePath $relativePath
        $recoveryPaths.Add(
            [IO.Path]::GetRelativePath($predecessorCopy, $path).Replace('\', '/')
        )
        $recoveryReceipt = Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        $recoveryReceipts.Add($recoveryReceipt)
    }
    $exhaustedThreadId = [string]$recoveryReceipts[0].original_thread_id
    $exhaustedSourceId = [string]$recoveryReceipts[0].source_node_id
    for ($index = 0; $index -lt 3; $index++) {
        $verified = Read-ThreadResultRecoveryReceipt `
            -Path (Join-Path $predecessorCopy $recoveryPaths[$index]) `
            -RunDirectory $predecessorCopy `
            -ExpectedSourceNodeId $exhaustedSourceId `
            -ExpectedOriginalThreadId $exhaustedThreadId `
            -ExpectedRecoveryStage replacement
        if ([int]$verified.attempt -ne ($index + 1)) {
            throw 'The real source-rotation fixture recovery order changed.'
        }
    }

    $sourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids) |
            ForEach-Object { [string]$_ }
    )
    $independenceSourceCandidates = @($sourceIds | Where-Object {
        $candidateSourceId = [string]$_
        $candidateSourceId -ne $exhaustedSourceId -and
        @($events | Where-Object {
            [string]$_.node_id -eq $candidateSourceId -and
            [string]$_.thread_id -eq $independenceThreadId
        }).Count -gt 0
    })
    if ($sourceIds.Count -ne 2 -or $independenceSourceCandidates.Count -ne 1) {
        throw 'The real fixture must identify exactly two distinct durable sources.'
    }
    $independenceSourceId = [string]$independenceSourceCandidates[0]

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($definition in @(
        [ordered]@{
            source_node_id = $independenceSourceId
            thread_id = $independenceThreadId
            failure_class = 'independence-contaminated'
            input_relative_path = $IndependenceInputRelativePath
            failure_capture_relative_path = $IndependenceCaptureRelativePath
            recovery_paths = @()
        },
        [ordered]@{
            source_node_id = $exhaustedSourceId
            thread_id = $exhaustedThreadId
            failure_class = 'replacement-recovery-exhausted'
            input_relative_path = $ExhaustedInputRelativePath
            failure_capture_relative_path = ''
            recovery_paths = @($recoveryPaths)
        }
    )) {
        $sourceId = [string]$definition.source_node_id
        $node = @($plan.nodes | Where-Object {
            [string]$_.id -eq $sourceId
        })
        if ($node.Count -ne 1) {
            throw "Fixture source '$sourceId' is missing or repeated."
        }
        $threadId = [string]$definition.thread_id
        $rollForwardCandidates = @(
            Get-ChildItem -LiteralPath (Join-Path $predecessorCopy 'receipts') `
                -Filter "$sourceId.replacement-roll-forward-*.json" -File |
                ForEach-Object {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw |
                        ConvertFrom-Json -Depth 100 -DateKind String
                    if (
                        [string]$candidate.replacement_thread_id -eq $threadId -and
                        [string]$candidate.target_milestone_id -eq
                            [string]$chain.next_milestone_id -and
                        [string]$candidate.checkpoint_hash -eq $checkpointHash
                    ) {
                        [pscustomobject]@{
                            path = $_.FullName
                            receipt = $candidate
                        }
                    }
                }
        )
        if ($rollForwardCandidates.Count -ne 1) {
            throw "Fixture source '$sourceId' lacks one checkpoint roll-forward."
        }
        $rollForwardPath = $rollForwardCandidates[0].path
        $rollForward = Read-ReplacementCheckpointRollForwardReceipt `
            -Path $rollForwardPath -RunDirectory $predecessorCopy `
            -ExpectedSourceNodeId $sourceId `
            -ExpectedReplacementThreadId $threadId
        $inputPath = Get-RelativeCopyPath -OriginalRoot $originalRoot `
            -CopyRoot $predecessorCopy `
            -RelativePath ([string]$definition.input_relative_path)
        $latestEvent = @($events | Where-Object {
            [string]$_.node_id -eq $sourceId
        })[-1]
        $entry = [ordered]@{
            source_node_id = $sourceId
            role_id = [string]$node[0].role_id
            failed_source_kind = 'replacement'
            failed_thread_id = $threadId
            failure_class = [string]$definition.failure_class
            input_manifest_path = [IO.Path]::GetRelativePath(
                $predecessorCopy, $inputPath
            ).Replace('\', '/')
            input_manifest_hash = Get-TextSha256 (
                Get-Content -LiteralPath $inputPath -Raw
            )
            replacement_continuity_receipt_path = [string](
                $rollForward.replacement_continuity_receipt_path
            )
            replacement_continuity_receipt_hash = [string](
                $rollForward.replacement_continuity_receipt_hash
            )
            replacement_roll_forward_receipt_path =
                [IO.Path]::GetRelativePath(
                    $predecessorCopy, $rollForwardPath
                ).Replace('\', '/')
            replacement_roll_forward_receipt_hash =
                [string]$rollForward.receipt_hash
            latest_event_sequence = [int]$latestEvent.sequence
            latest_event_hash = [string]$latestEvent.hash
            failure_capture_path = ''
            failure_capture_file_hash = ''
            recovery_receipt_paths = @()
            recovery_receipt_hashes = @()
        }
        if ($definition.failure_class -eq 'independence-contaminated') {
            $entry.failure_capture_path = [IO.Path]::GetRelativePath(
                $predecessorCopy, $independenceCapturePath
            ).Replace('\', '/')
            $entry.failure_capture_file_hash = (
                Get-FileHash -LiteralPath $independenceCapturePath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        } else {
            $entry.recovery_receipt_paths = @($recoveryPaths)
            $entry.recovery_receipt_hashes = @(
                $recoveryReceipts | ForEach-Object {
                    [string]$_.receipt_hash
                }
            )
        }
        $entries.Add($entry)
    }
    $orderedEntries = @($sourceIds | ForEach-Object {
        $sourceId = [string]$_
        @($entries | Where-Object {
            [string]$_.source_node_id -eq $sourceId
        })[0]
    })

    $manifestPath = Join-Path $predecessorCopy (
        'materials/durable-review-source-rotation-manifest.json'
    )
    [ordered]@{
        schema_version = '1.0'
        active_milestone_id = [string]$chain.active_milestone_id
        target_milestone_id = [string]$chain.next_milestone_id
        checkpoint_material_path = [IO.Path]::GetRelativePath(
            $predecessorCopy, $checkpointPath
        ).Replace('\', '/')
        checkpoint_material_hash = $checkpointHash
        sources = $orderedEntries
    } | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $manifestPath -Encoding utf8

    $successorPlan = $plan
    $successorPlan.policy_version = $script:OrchestrationCurrentPolicyVersion
    $successorPlan.run_id = [string]$run.run_id + '-source-rotation-fixture'
    $successorPlan.goal = (
        'Replace two failed durable review seats without dropping open findings.'
    )
    $milestones = @(
        $plan.durable_review_profile.milestone_ids |
            ForEach-Object { [string]$_ }
    )
    $targetIndex = [Array]::IndexOf(
        $milestones, [string]$chain.next_milestone_id
    )
    $successorPlan.durable_review_profile.milestone_ids = @(
        $milestones[$targetIndex..($milestones.Count - 1)]
    )
    foreach ($sourceId in $sourceIds) {
        $node = @($successorPlan.nodes | Where-Object {
            [string]$_.id -eq $sourceId
        })[0]
        $node.context.session_policy = 'fresh'
        $node.context.max_prior_turns = 0
        foreach ($name in @(
            'prior_thread_id', 'prior_handoff', 'prior_handoff_hash',
            'reuse_reason'
        )) {
            $null = $node.context.Remove($name)
        }
    }
    $successorPlan.successor_review_profile = [ordered]@{
        lineage_kind = 'source-rotation'
        predecessor_run_id = [string]$run.run_id
        predecessor_active_milestone_id = [string]$chain.active_milestone_id
        predecessor_checkpoint_material_hash =
            [string]$chain.active_source_bindings[0].checkpoint_material_hash
        rotation_target_milestone_id = [string]$chain.next_milestone_id
        rotation_checkpoint_material_hash = $checkpointHash
        source_node_ids = $sourceIds
    }
    $successorPlanPath = Join-Path $testRoot 'source-rotation-successor.json'
    $successorPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $successorPlanPath -Encoding utf8
    $successorRun = Join-Path $testRoot 'successor'
    $authorizationPath = Join-Path $predecessorCopy (
        'materials/source-rotation-controller-authorization.md'
    )
    Set-Content -LiteralPath $authorizationPath -Value (
        'Controller authorizes exactly one two-seat source rotation for this ' +
        'checkpoint and successor run.'
    )

    $reusePlanPath = Join-Path $testRoot 'source-rotation-reuse-invalid.json'
    $reusePlan = Get-Content -LiteralPath $successorPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $reuseNode = @($reusePlan.nodes | Where-Object {
        [string]$_.id -eq [string]$sourceIds[0]
    })[0]
    $reuseNode.context.session_policy = 'reuse'
    $reuseNode.context.max_prior_turns = 1
    $reuseNode.context.prior_thread_id =
        [string]$orderedEntries[0].failed_thread_id
    $reuseNode.context.prior_handoff = 'handoffs/forbidden-old-seat.md'
    $reuseNode.context.prior_handoff_hash = 'a' * 64
    $reuseNode.context.reuse_reason = 'Attempt to reuse the failed reviewer.'
    $reusePlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $reusePlanPath -Encoding utf8
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $reusePlanPath `
            -WorkspaceRoot ([string]$run.workspace_root) | Out-Null
    } 'must use a fresh session' (
        'A source-rotation successor cannot reuse an original or replacement ' +
        'reviewer thread.'
    )

    $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
    $manifestOriginal = $manifestRaw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $manifestMutationCases = @(
        [pscustomobject]@{
            name = 'cross-source'
            expected = 'exact ordered pair'
            action = {
                param($value)
                $swap = $value.sources[0]
                $value.sources[0] = $value.sources[1]
                $value.sources[1] = $swap
            }
        },
        [pscustomobject]@{
            name = 'cross-thread'
            expected = 'does not match its source'
            action = {
                param($value)
                $value.sources[0].failed_thread_id =
                    [string]$value.sources[1].failed_thread_id
            }
        },
        [pscustomobject]@{
            name = 'checkpoint-drift'
            expected = 'checkpoint is missing or changed'
            action = {
                param($value)
                $value.checkpoint_material_hash = '0' * 64
            }
        },
        [pscustomobject]@{
            name = 'missing-recovery'
            expected = 'exactly three recoveries'
            action = {
                param($value)
                $exhausted = @($value.sources | Where-Object {
                    [string]$_.failure_class -eq
                        'replacement-recovery-exhausted'
                })[0]
                $exhausted.recovery_receipt_paths =
                    @($exhausted.recovery_receipt_paths | Select-Object -First 2)
                $exhausted.recovery_receipt_hashes =
                    @($exhausted.recovery_receipt_hashes | Select-Object -First 2)
            }
        },
        [pscustomobject]@{
            name = 'failure-class-fork'
            expected = 'invalid terminal state'
            action = {
                param($value)
                $value.sources[0].failure_class =
                    'replacement-recovery-exhausted'
            }
        }
    )
    foreach ($case in $manifestMutationCases) {
        $mutatedManifest = $manifestRaw |
            ConvertFrom-Json -AsHashtable -Depth 100
        & $case.action $mutatedManifest
        $mutatedPath = Join-Path $predecessorCopy (
            "materials/source-rotation-$($case.name)-invalid.json"
        )
        $mutatedManifest | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $mutatedPath -Encoding utf8
        Assert-ThrowsLike {
            Get-DurableReviewSourceRotationSnapshot `
                -RunDirectory $predecessorCopy `
                -RotationManifestPath $mutatedPath | Out-Null
        } ([string]$case.expected) (
            "Source-rotation manifest mutation '$($case.name)' must fail closed."
        )
    }

    $export = & (Join-Path $scriptRoot (
        'New-DurableReviewSourceRotationExportReceipt.ps1'
    )) -PredecessorRunDirectory $predecessorCopy `
        -SuccessorPlanPath $successorPlanPath `
        -SuccessorRunDirectory $successorRun `
        -RotationManifestPath $manifestPath `
        -AuthorizationMaterialPath $authorizationPath `
        -ActivationKey 'controller:real-source-rotation-fixture' |
        ConvertFrom-Json -Depth 100
    $adoption = & (Join-Path $scriptRoot (
        'New-OrchestrationSourceRotationSuccessorRun.ps1'
    )) -PlanPath $successorPlanPath -RunDirectory $successorRun `
        -WorkspaceRoot ([string]$run.workspace_root) `
        -PredecessorRunDirectory $predecessorCopy `
        -PredecessorExportReceiptPath (Join-Path $predecessorCopy (
            'receipts/durable-review-source-rotation.export.json'
        )) | ConvertFrom-Json -Depth 100

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot (
            'New-DurableReviewSourceRotationExportReceipt.ps1'
        )) -PredecessorRunDirectory $predecessorCopy `
            -SuccessorPlanPath $successorPlanPath `
            -SuccessorRunDirectory $successorRun `
            -RotationManifestPath $manifestPath `
            -AuthorizationMaterialPath $authorizationPath `
            -ActivationKey 'controller:duplicate-source-rotation' | Out-Null
    } 'already has a source-rotation export' (
        'A predecessor may export exactly one source rotation.'
    )
    Assert-ThrowsLike {
        Read-DurableReviewSourceRotationExportReceipt `
            -Path (Join-Path $predecessorCopy (
                'receipts/durable-review-source-rotation.export.json'
            )) -PredecessorRunDirectory $predecessorCopy `
            -SuccessorPlanPath $successorPlanPath `
            -ExpectedSuccessorRunDirectory (
                Join-Path $testRoot 'forked-successor'
            ) | Out-Null
    } 'cannot be replayed' (
        'A source-rotation export cannot fork into another successor run.'
    )
    Assert-AdoptionMutationRejected -RunDirectory $successorRun `
        -Expected 'changed source identities or findings' `
        -Message 'A fresh successor cannot omit one inherited occurrence.' `
        -Mutation {
            param($receipt)
            $receipt.inherited_obligations = @(
                $receipt.inherited_obligations | Select-Object -Skip 1
            )
        }
    Assert-AdoptionMutationRejected -RunDirectory $successorRun `
        -Expected 'changed source identities or findings' `
        -Message 'A fresh successor cannot downgrade an inherited P1.' `
        -Mutation {
            param($receipt)
            $receipt.inherited_obligations[0].severity = 'P2'
        }
    Assert-AdoptionMutationRejected -RunDirectory $successorRun `
        -Expected 'changed source identities or findings' `
        -Message 'A fresh successor cannot move an occurrence across sources.' `
        -Mutation {
            param($receipt)
            $receipt.inherited_obligations[0].source_node_id =
                [string]$receipt.inherited_obligations[-1].source_node_id
        }
    Assert-AdoptionMutationRejected -RunDirectory $successorRun `
        -Expected 'changed source identities or findings' `
        -Message 'A fresh successor cannot relabel the failed reviewer thread.' `
        -Mutation {
            param($receipt)
            $receipt.source_bindings[0].failed_thread_id =
                [string]$receipt.source_bindings[1].failed_thread_id
        }

    $completionError = ''
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $successorRun | Out-Null
    } catch {
        $completionError = $_.Exception.Message
    }
    $inherited = @($adoption.inherited_obligations)
    $reported = @(
        [regex]::Matches($completionError, 'Inherited P1 ')
    ).Count
    if ($inherited.Count -lt 1 -or
        $inherited.Count -ne @($export.open_obligations).Count -or
        $reported -ne $inherited.Count -or
        @($adoption.source_bindings | Where-Object {
            [string]$_.fresh_session_policy -ne 'fresh'
        }).Count -gt 0) {
        throw 'Source rotation failed to preserve every open source occurrence.'
    }
    [pscustomobject]@{
        pass = $true
        assertions = $script:assertions
        predecessor_run_id = [string]$export.predecessor_run_id
        active_milestone_id = [string]$export.active_milestone_id
        target_milestone_id = [string]$export.rotation_target_milestone_id
        inherited_p1_count = $inherited.Count
        rotated_source_count = @($adoption.source_bindings).Count
        new_seats_are_fresh = $true
        completion_blocked = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
