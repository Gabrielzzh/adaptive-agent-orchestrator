[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$examplePath = Join-Path $skillRoot 'references/example-plan.json'
$script:assertionCount = 0
$script:invalidPlanCount = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'adaptive-agent-orchestrator-' + [guid]::NewGuid().ToString('N')
)

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )
    $script:assertionCount++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-InvalidPlan {
    param(
        [hashtable] $Plan,
        [string] $Name,
        [string] $ExpectedMessage
    )
    $path = Join-Path $testRoot "$Name.json"
    $Plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
    $caught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $path -WorkspaceRoot $skillRoot | Out-Null
    }
    catch {
        $caught = $true
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") (
            "Invalid plan '$Name' failed for the wrong reason: $($_.Exception.Message)"
        )
    }
    Assert-True $caught "Invalid plan '$Name' unexpectedly passed."
    $script:invalidPlanCount++
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Action,
        [string] $ExpectedMessage,
        [string] $Message
    )
    $caught = $false
    try {
        & $Action
    } catch {
        $caught = $_.Exception.Message -like "*$ExpectedMessage*"
    }
    Assert-True $caught $Message
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot

    $captureCompatibility = & (
        Join-Path $scriptRoot 'Test-ThreadCaptureCompatibility.ps1'
    ) | ConvertFrom-Json
    Assert-True $captureCompatibility.pass (
        'Thread capture compatibility tests must pass.'
    )

    $materializationContinuity = & (
        Join-Path $scriptRoot 'Test-MaterializationContinuity.ps1'
    ) | ConvertFrom-Json
    Assert-True $materializationContinuity.pass (
        'Fresh materialization continuity tests must pass.'
    )

    $valid = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
        -PlanPath $examplePath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $valid.valid 'Example plan should be valid.'
    Assert-True ($valid.agent_node_count -eq 2) 'Example should contain two agent nodes.'
    $activationPreview = & (
        Join-Path $scriptRoot 'New-RoleActivationPreview.ps1'
    ) -PlanPath $examplePath -NodeId 'draft'
    foreach ($requiredPreviewLabel in @(
        'Role:', 'Mission:', 'Identity:', 'Why a Worker is needed:', 'Concrete task:',
        'Responsibilities:', 'Non-goals:', 'Inputs and context scope:',
        'Excluded context:', 'Execution form:', 'Why this execution form:',
        'Topology/session:',
        'Planned model/effort:', 'Model reason:', 'Model authorization:',
        'Model authorization evidence:',
        'Deliverables:', 'Evidence rules:', 'Permissions and write scope:',
        'Dependencies:', 'If omitted:', 'Authorization basis:',
        'Authorization evidence:'
    )) {
        Assert-True ($activationPreview -like "*$requiredPreviewLabel*") (
            "Role activation preview should include '$requiredPreviewLabel'."
        )
    }
    Assert-True ($activationPreview -like '*scoped-write: artifacts/draft*') (
        'Role activation preview should expose the exact write scope.'
    )
    Assert-True ($activationPreview -like '*background-thread / fresh*') (
        'Role activation preview should expose topology and session policy.'
    )
    Assert-True ($activationPreview -like '*independent background agent*') (
        'Role activation preview should name the user-facing execution form.'
    )
    Assert-True (
        $activationPreview -like '*independent history, recovery, or reuse across turns is required*'
    ) 'Role activation preview should explain why the execution form was selected.'
    Assert-True ($activationPreview -like '*Prior reviewer reasoning*') (
        'Role activation preview should expose excluded context.'
    )
    Assert-True ($activationPreview -match 'Architecture Owner \[architecture-owner\]') (
        'Role activation preview should render the selected role ID exactly.'
    )

    $knowledgeProject = Join-Path $testRoot 'knowledge-project'
    $null = New-Item -ItemType Directory -Path $knowledgeProject
    $knowledgeSource = Join-Path $knowledgeProject 'decision.md'
    'Keep final integration in the main agent.' |
        Set-Content -LiteralPath $knowledgeSource -Encoding utf8
    $knowledgeManager = Join-Path $scriptRoot 'Manage-ProjectKnowledge.ps1'
    $knowledgeInit = & $knowledgeManager -Action Initialize `
        -ProjectRoot $knowledgeProject | ConvertFrom-Json
    Assert-True $knowledgeInit.initialized (
        'Durable project knowledge should initialize explicitly.'
    )
    $knowledgeEntry = & $knowledgeManager -Action Adopt `
        -ProjectRoot $knowledgeProject -Id 'decision-main-integration' `
        -Type 'decision' -Summary 'Keep final integration in the main agent.' `
        -Tags @('ownership', 'integration') `
        -SourceRefs @('path:decision.md') | ConvertFrom-Json
    Assert-True ($knowledgeEntry.status -eq 'adopted') (
        'The main agent should be able to adopt a sourced knowledge entry.'
    )
    $knowledgeFind = & $knowledgeManager -Action Find `
        -ProjectRoot $knowledgeProject -Query 'ownership' -Limit 5 |
        ConvertFrom-Json
    Assert-True ($knowledgeFind.count -eq 1) (
        'Knowledge lookup should return the selected adopted entry.'
    )
    'Changed source.' | Set-Content -LiteralPath $knowledgeSource -Encoding utf8
    $knowledgeStale = & $knowledgeManager -Action Validate `
        -ProjectRoot $knowledgeProject -RefreshStale | ConvertFrom-Json
    Assert-True (-not $knowledgeStale.valid) (
        'A changed local source should make project knowledge stale.'
    )
    $knowledgeAfterStale = & $knowledgeManager -Action Find `
        -ProjectRoot $knowledgeProject -Query 'ownership' -Limit 5 |
        ConvertFrom-Json
    Assert-True ($knowledgeAfterStale.count -eq 0) (
        'Default lookup should exclude stale project knowledge.'
    )

    $reconcileSummary = 'Review the candidate release.'
    $reconcileRun = Join-Path $testRoot 'thread-reconcile-run'
    $null = New-Item -ItemType Directory -Path $reconcileRun
    $reconcilePreviewPath = Join-Path $reconcileRun 'role-preview.md'
    & (Join-Path $scriptRoot 'New-RoleActivationPreview.ps1') `
        -PlanPath $examplePath -NodeId 'review' `
        -OutputPath $reconcilePreviewPath | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadActivationReservation.ps1') `
            -RunDirectory $reconcileRun `
            -ActivationKey 'missing-preview' `
            -SourceThreadId 'source-thread-1' `
            -TaskSummary $reconcileSummary `
            -RolePreviewPath (Join-Path $reconcileRun 'missing-preview.md') |
            Out-Null
    } 'Role preview must be an existing file' (
        'A durable Worker cannot be reserved before its role preview exists.'
    )
    $reconcileReservation = & (
        Join-Path $scriptRoot 'New-ThreadActivationReservation.ps1'
    ) -RunDirectory $reconcileRun -ActivationKey 'review-release-v051' `
        -SourceThreadId 'source-thread-1' -TaskSummary $reconcileSummary `
        -RolePreviewPath $reconcilePreviewPath |
        ConvertFrom-Json -Depth 20
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadActivationReservation.ps1') `
            -RunDirectory $reconcileRun `
            -ActivationKey 'review-release-v051' `
            -SourceThreadId 'source-thread-1' `
            -TaskSummary $reconcileSummary `
            -RolePreviewPath $reconcilePreviewPath | Out-Null
    } 'already reserved' (
        'One activation key must permit only one atomic creation reservation.'
    )
    $reconcileInputPath = Join-Path $reconcileRun 'thread-reconcile.json'
    [ordered]@{
        activation_key = 'review-release-v051'
        source_thread_id = 'source-thread-1'
        task_summary = $reconcileSummary
        window_start_utc = '2026-07-20T00:00:00Z'
        window_end_utc = '2026-07-20T00:02:00Z'
        reservation_path = $reconcileReservation.reservation_path
        create_call = [ordered]@{
            status = 'error'
            returned_thread_id = $null
        }
        snapshots = @(
            [ordered]@{
                captured_at = '2026-07-20T00:00:10Z'
                threads = @()
            },
            [ordered]@{
                captured_at = '2026-07-20T00:00:20Z'
                threads = @(
                    [ordered]@{
                        thread_id = 'review-thread-1'
                        host_id = 'opaque-host-1'
                        created_at = '2026-07-20T00:00:15Z'
                        preview = (
                            '<activation_key>review-release-v051</activation_key> ' +
                            '<source_thread_id>source-thread-1</source_thread_id> ' +
                            $reconcileSummary
                        )
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reconcileInputPath
    $reconciled = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $reconcileInputPath -OutputPath (
        Join-Path $reconcileRun 'receipts/adopted.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True (
        $reconciled.decision -eq 'adopted' -and
        $reconciled.adopted_thread_id -eq 'review-thread-1' -and
        $reconciled.adopted_host_id -eq 'opaque-host-1'
    ) 'A later visible unique thread must be adopted after a create-call error.'
    Assert-True ($reconciled.receipt_hash -match '^[0-9a-f]{64}$') (
        'Thread reconciliation must return a hash-bound receipt.'
    )

    $wrongActivation = Get-Content -LiteralPath $reconcileInputPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $wrongActivation.snapshots[1].threads[0].preview = (
        '<activation_key>another-activation</activation_key> ' +
        '<source_thread_id>source-thread-1</source_thread_id> ' +
        $reconcileSummary
    )
    $wrongActivationPath = Join-Path $reconcileRun (
        'thread-reconcile-wrong-activation.json'
    )
    $wrongActivation | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $wrongActivationPath
    $wrongActivationResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $wrongActivationPath -OutputPath (
        Join-Path $reconcileRun 'receipts/wrong.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($wrongActivationResult.decision -eq 'unknown') (
        'A different activation key must not match or prove absence before the window ends.'
    )

    $singleEmpty = Get-Content -LiteralPath $reconcileInputPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $singleEmpty.snapshots = @($singleEmpty.snapshots[0])
    $singleEmptyPath = Join-Path $reconcileRun 'thread-reconcile-single-empty.json'
    $singleEmpty | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $singleEmptyPath
    $singleEmptyResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $singleEmptyPath -OutputPath (
        Join-Path $reconcileRun 'receipts/single.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($singleEmptyResult.decision -eq 'unknown') (
        'One empty snapshot must not prove that no task materialized.'
    )

    $doubleEmpty = Get-Content -LiteralPath $reconcileInputPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $doubleEmpty.snapshots[1].threads = @()
    $doubleEmptyPath = Join-Path $reconcileRun 'thread-reconcile-double-empty.json'
    $doubleEmpty | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $doubleEmptyPath
    $doubleEmptyResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $doubleEmptyPath -OutputPath (
        Join-Path $reconcileRun 'receipts/empty.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($doubleEmptyResult.decision -eq 'unknown') (
        'Two empty snapshots before the visibility-window end remain unknown.'
    )
    $endedEmpty = Get-Content -LiteralPath $doubleEmptyPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $endedEmpty.snapshots[1].captured_at = '2026-07-20T00:02:00Z'
    $endedEmptyPath = Join-Path $reconcileRun (
        'thread-reconcile-window-ended-empty.json'
    )
    $endedEmpty | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $endedEmptyPath
    $endedEmptyResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $endedEmptyPath -OutputPath (
        Join-Path $reconcileRun 'receipts/window-ended.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($endedEmptyResult.decision -eq 'no_match') (
        'Only repeated empty snapshots through the visibility-window end prove no match.'
    )
    $successfulButInvisible = Get-Content -LiteralPath $endedEmptyPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $successfulButInvisible.create_call.status = 'success'
    $successfulButInvisible.create_call.returned_thread_id = 'returned-thread-1'
    $successfulButInvisiblePath = Join-Path $reconcileRun (
        'thread-reconcile-success-returned-id-invisible.json'
    )
    $successfulButInvisible | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $successfulButInvisiblePath
    $successfulButInvisibleResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $successfulButInvisiblePath -OutputPath (
        Join-Path $reconcileRun (
            'receipts/success-returned-id-invisible.thread-reconciliation.json'
        )
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($successfulButInvisibleResult.decision -eq 'unknown') (
        'A successful create call with a returned task ID must never be ' +
        'converted into no_match merely because list visibility is delayed.'
    )
    $queuedSetup = Get-Content -LiteralPath $doubleEmptyPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $queuedSetup.create_call.status = 'success'
    $queuedSetup.create_call.returned_thread_id = $null
    $queuedSetup.create_call.client_thread_id = 'queued-worktree-client-1'
    $queuedSetupPath = Join-Path $reconcileRun (
        'thread-reconcile-queued-setup.json'
    )
    $queuedSetup | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $queuedSetupPath
    $queuedSetupResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $queuedSetupPath -OutputPath (
        Join-Path $reconcileRun (
            'receipts/queued-setup.thread-reconciliation.json'
        )
    ) | ConvertFrom-Json -Depth 20
    Assert-True (
        $queuedSetupResult.decision -eq 'setup_pending' -and
        $queuedSetupResult.returned_thread_id -eq $null -and
        $queuedSetupResult.returned_client_thread_id -eq
            'queued-worktree-client-1'
    ) 'A clientThreadId alone must remain setup_pending, not materialized.'
    $queuedEnded = Get-Content -LiteralPath $queuedSetupPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $queuedEnded.snapshots[1].captured_at = '2026-07-20T00:02:00Z'
    $queuedEndedPath = Join-Path $reconcileRun (
        'thread-reconcile-queued-setup-ended.json'
    )
    $queuedEnded | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $queuedEndedPath
    $queuedEndedResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $queuedEndedPath -OutputPath (
        Join-Path $reconcileRun (
            'receipts/queued-setup-ended.thread-reconciliation.json'
        )
    ) | ConvertFrom-Json -Depth 20
    Assert-True (
        $queuedEndedResult.decision -eq 'setup_failed_or_unresolved' -and
        $queuedEndedResult.decision -ne 'no_match'
    ) (
        'A queued worktree that never materializes must not authorize a ' +
        'blind replacement task.'
    )
    $tooFastEmpty = Get-Content -LiteralPath $doubleEmptyPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $tooFastEmpty.snapshots[1].captured_at = '2026-07-20T00:00:10.001Z'
    $tooFastEmptyPath = Join-Path $reconcileRun (
        'thread-reconcile-too-fast-empty.json'
    )
    $tooFastEmpty | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $tooFastEmptyPath
    $tooFastEmptyResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $tooFastEmptyPath -OutputPath (
        Join-Path $reconcileRun 'receipts/too-fast.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True ($tooFastEmptyResult.decision -eq 'unknown') (
        'Nearly simultaneous empty snapshots must not prove non-materialization.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1') `
            -InputPath $endedEmptyPath -OutputPath (
                Join-Path $reconcileRun 'receipts/unsafe-delay.thread-reconciliation.json'
            ) -MinVisibilityDelaySeconds 1 | Out-Null
    } 'MinVisibilityDelaySeconds' (
        'The visibility delay may be increased but must never be reduced below forty seconds.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1') `
            -InputPath $endedEmptyPath -OutputPath (
                Join-Path $reconcileRun 'receipts/long-delay.thread-reconciliation.json'
            ) -MinVisibilityDelaySeconds 15 | Out-Null
    } 'MinVisibilityDelaySeconds' (
        'A fifteen-second no-match window must not override the Codex safety floor.'
    )
    $longDelayResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $endedEmptyPath -OutputPath (
        Join-Path $reconcileRun 'receipts/long-delay.thread-reconciliation.json'
    ) -MinVisibilityDelaySeconds 60 | ConvertFrom-Json -Depth 20
    Assert-True ($longDelayResult.decision -eq 'no_match') (
        'A longer platform visibility delay should remain supported.'
    )

    $multiple = Get-Content -LiteralPath $reconcileInputPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $multiple.create_call.status = 'success'
    $multiple.create_call.returned_thread_id = 'review-thread-2'
    $multiple.snapshots[1].threads = @(
        [ordered]@{
            thread_id = 'review-thread-1'
            host_id = 'opaque-host-1'
            created_at = '2026-07-20T00:00:15Z'
            source_thread_id = 'source-thread-1'
            activation_key = 'review-release-v051'
            task_summary = $reconcileSummary
        },
        [ordered]@{
            thread_id = 'review-thread-2'
            host_id = 'opaque-host-1'
            created_at = '2026-07-20T00:00:16Z'
            source_thread_id = 'source-thread-1'
            activation_key = 'review-release-v051'
            task_summary = $reconcileSummary
        }
    )
    $multiplePath = Join-Path $reconcileRun 'thread-reconcile-multiple.json'
    $multiple | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $multiplePath
    $multipleResult = & (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -InputPath $multiplePath -OutputPath (
        Join-Path $reconcileRun 'receipts/duplicates.thread-reconciliation.json'
    ) | ConvertFrom-Json -Depth 20
    Assert-True (
        $multipleResult.decision -eq 'duplicates_pending' -and
        $multipleResult.adopted_thread_id -eq 'review-thread-2' -and
        'review-thread-1' -in @($multipleResult.duplicate_thread_ids)
    ) 'The matching create-call ID must be canonical when duplicates exist.'

    $calibrationProject = Join-Path $testRoot 'calibration-project'
    $null = New-Item -ItemType Directory -Path $calibrationProject
    $calibrationScript = Join-Path $scriptRoot 'Manage-CalibrationLedger.ps1'
    $verifiedReceiptCount = @(
        Get-ChildItem -LiteralPath (Join-Path $reconcileRun 'receipts') `
            -Recurse -File |
            Where-Object Name -Like '*.thread-reconciliation.json'
    ).Count
    $uniqueReceiptHashCount = @(
        Get-ChildItem -LiteralPath (Join-Path $reconcileRun 'receipts') `
            -Recurse -File |
            Where-Object Name -Like '*.thread-reconciliation.json' |
            ForEach-Object {
                (Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -Depth 30).receipt_hash
            } |
            Select-Object -Unique
    ).Count
    $calibrationAdd = & $calibrationScript -Action Add `
        -ProjectRoot $calibrationProject -RunDirectory $reconcileRun `
        -MinWindowUsed 20 -AppVersion '26.7.26' -HostKind 'desktop' `
        -ExecutionMode local -PolicyVersion '0.7.6' |
        ConvertFrom-Json -Depth 30
    Assert-True (
        $verifiedReceiptCount -gt 0 -and
        $calibrationAdd.added -eq $uniqueReceiptHashCount -and
        $calibrationAdd.total_samples -eq $uniqueReceiptHashCount
    ) 'Calibration should add each verified reconciliation receipt once.'
    $calibrationLedgerPath = Join-Path (
        Join-Path $calibrationProject '.orchestrator'
    ) 'calibration.jsonl'
    $calibrationLedgerRaw = Get-Content -LiteralPath $calibrationLedgerPath -Raw
    Assert-True (
        $calibrationLedgerRaw -like '*observation_window_span_seconds*' -and
        $calibrationLedgerRaw -notlike '*visibility_delay_seconds*' -and
        $calibrationLedgerRaw -notlike '*review-thread-*' -and
        $calibrationLedgerRaw -notlike "*$reconcileSummary*"
    ) (
        'Calibration must store interval observations without task text or ' +
        'thread identifiers.'
    )
    $calibrationRepeat = & $calibrationScript -Action Add `
        -ProjectRoot $calibrationProject -RunDirectory $reconcileRun `
        -MinWindowUsed 20 -AppVersion '26.7.26' -HostKind 'desktop' `
        -ExecutionMode local -PolicyVersion '0.7.6' |
        ConvertFrom-Json -Depth 30
    Assert-True (
        $calibrationRepeat.added -eq 0 -and
        $calibrationRepeat.skipped_duplicates -eq $verifiedReceiptCount
    ) 'Calibration Add must be idempotent by reconciliation receipt hash.'
    $adoptedReceiptPath = Join-Path $reconcileRun (
        'receipts/adopted.thread-reconciliation.json'
    )
    $adoptedReceiptRaw = Get-Content -LiteralPath $adoptedReceiptPath -Raw
    $tamperedReceipt = $adoptedReceiptRaw |
        ConvertFrom-Json -AsHashtable -Depth 30
    $tamperedReceipt.snapshot_count = 99
    $tamperedReceipt | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $adoptedReceiptPath
    Assert-ThrowsLike {
        & $calibrationScript -Action Add -ProjectRoot $calibrationProject `
            -RunDirectory $reconcileRun -AppVersion '26.7.26' `
            -HostKind 'desktop' -ExecutionMode local `
            -PolicyVersion '0.7.6' | Out-Null
    } 'hash mismatch' 'Calibration must reject a tampered receipt.'
    Set-Content -LiteralPath $adoptedReceiptPath -Value $adoptedReceiptRaw

    $seedCalibrationProject = Join-Path $testRoot 'seed-calibration-project'
    $seedCalibrationRoot = Join-Path $seedCalibrationProject '.orchestrator'
    $null = New-Item -ItemType Directory -Path $seedCalibrationRoot -Force
    $seedCalibrationPath = Join-Path $seedCalibrationRoot 'calibration.jsonl'
    $seedCalibrationLines = [Collections.Generic.List[string]]::new()
    for ($index = 1; $index -le 12; $index++) {
        $seedCalibrationLines.Add(([ordered]@{
            schema_version = '1.0'
            run_directory_hash = ('a' * 62) + $index.ToString('x2')
            reconciliation_receipt_hash = ('b' * 62) + $index.ToString('x2')
            recorded_at_utc = '2026-07-26T00:00:00Z'
            decision = 'no_match'
            snapshot_count = 2
            observation_window_span_seconds = [double](10 + $index)
            min_window_used_seconds = 20
            app_version = '26.7.26'
            host_kind = 'desktop'
            execution_mode = 'local'
            policy_version = '0.7.6'
        } | ConvertTo-Json -Compress))
    }
    $seedCalibrationLines.Add(([ordered]@{
        schema_version = '1.0'
        run_directory_hash = 'c' * 64
        reconciliation_receipt_hash = 'd' * 64
        recorded_at_utc = '2026-07-26T00:00:00Z'
        decision = 'adopted'
        snapshot_count = 2
        observation_window_span_seconds = 60
        min_window_used_seconds = 20
        app_version = 'different'
        host_kind = 'remote-host'
        execution_mode = 'remote'
        policy_version = 'other'
    } | ConvertTo-Json -Compress))
    $seedCalibrationLines | Set-Content -LiteralPath $seedCalibrationPath
    $calibrationSummary = & $calibrationScript -Action Summary `
        -ProjectRoot $seedCalibrationProject | ConvertFrom-Json -Depth 30
    $localCalibrationGroup = @($calibrationSummary.groups | Where-Object {
        $_.environment.app_version -eq '26.7.26'
    })[0]
    Assert-True (
        $calibrationSummary.groups.Count -eq 2 -and
        $calibrationSummary.percentile_algorithm -eq 'nearest-rank' -and
        $localCalibrationGroup.sample_count -eq 12 -and
        $localCalibrationGroup.observation_window_span_seconds.p90 -eq 21 -and
        $localCalibrationGroup.recommendation -eq
            'insufficient-visibility-evidence' -and
        -not $localCalibrationGroup.recommendation_basis.exact_visibility_latency_claimed
    ) (
        'Calibration summary must isolate environments and reject a window ' +
        'recommendation unsupported by observation spans.'
    )
    Add-Content -LiteralPath $seedCalibrationPath -Value '{bad json'
    $degradedCalibration = & $calibrationScript -Action Summary `
        -ProjectRoot $seedCalibrationProject | ConvertFrom-Json -Depth 30
    Assert-True (
        $degradedCalibration.integrity -eq 'degraded' -and
        $degradedCalibration.bad_lines -eq 1 -and
        @($degradedCalibration.groups | Where-Object {
            $_.recommendation -ne 'suppressed-integrity-degraded'
        }).Count -eq 0
    ) 'Malformed calibration lines must suppress every recommendation.'

    $dispatchPreviewScript = Join-Path $scriptRoot (
        'Preview-OrchestrationDispatch.ps1'
    )
    $workspaceBeforePreview = @(
        Get-ChildItem -LiteralPath $testRoot -Recurse -Force |
            ForEach-Object { $_.FullName } |
            Sort-Object
    )
    $waveOnePreview = & $dispatchPreviewScript -PlanPath $examplePath `
        -WorkspaceRoot $testRoot -Wave 1 | ConvertFrom-Json -Depth 100
    $workspaceAfterPreview = @(
        Get-ChildItem -LiteralPath $testRoot -Recurse -Force |
            ForEach-Object { $_.FullName } |
            Sort-Object
    )
    Assert-True (
        $waveOnePreview.worker_count -eq 1 -and
        $waveOnePreview.workers[0].node_id -eq 'draft' -and
        $waveOnePreview.workers[0].initial_packet_chars -gt 0 -and
        $waveOnePreview.workers[0].reference_count -eq 3 -and
        $waveOnePreview.workers[0].model -eq 'gpt-5.6-sol' -and
        $waveOnePreview.workers[0].effort -eq 'high' -and
        $waveOnePreview.workers[0].topology -eq 'background-thread' -and
        $waveOnePreview.workers[0].runtime_readiness -eq 'not-evaluated'
    ) 'Wave-one dispatch preview must report the bounded planned Worker.'
    Assert-True (
        ($workspaceBeforePreview -join "`n") -eq
        ($workspaceAfterPreview -join "`n")
    ) 'Dispatch preview must not change the workspace.'
    Assert-True (
        ($waveOnePreview.notes -join ' ') -notmatch '\btokens?\b' -and
        ($waveOnePreview.notes -join ' ') -like
            '*bounded context proxy, not total usage or monetary cost*'
    ) 'Dispatch preview must not claim Token or monetary cost measurement.'
    $waveTwoPreview = & $dispatchPreviewScript -PlanPath $examplePath `
        -WorkspaceRoot $testRoot -Wave 2 | ConvertFrom-Json -Depth 100
    Assert-True (
        $waveTwoPreview.worker_count -eq 1 -and
        $waveTwoPreview.workers[0].node_id -eq 'review' -and
        $waveTwoPreview.workers[0].plan_eligible -and
        $waveTwoPreview.workers[0].runtime_readiness -eq 'not-evaluated'
    ) (
        'Earlier-wave dependencies make a Worker plan-eligible without ' +
        'claiming runtime readiness.'
    )
    $reusePreviewPlanPath = Join-Path $testRoot 'dispatch-preview-reuse.json'
    $reusePreviewPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -Depth 100
    $reusePreviewNode = @($reusePreviewPlan.nodes | Where-Object {
        $_.id -eq 'draft'
    })[0]
    $reusePreviewNode.context.session_policy = 'reuse'
    $reusePreviewNode.context.max_prior_turns = 1
    $reusePreviewNode.context | Add-Member `
        -NotePropertyName prior_thread_id -NotePropertyValue 'not-materialized'
    $reusePreviewNode.context | Add-Member `
        -NotePropertyName prior_handoff `
        -NotePropertyValue 'artifacts/missing-handoff.json'
    $reusePreviewNode.context | Add-Member `
        -NotePropertyName prior_handoff_hash -NotePropertyValue ('a' * 64)
    $reusePreviewNode.context | Add-Member `
        -NotePropertyName reuse_reason `
        -NotePropertyValue 'Preview defers runtime reuse verification.'
    $reusePreviewPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $reusePreviewPlanPath
    $reusePreview = & $dispatchPreviewScript `
        -PlanPath $reusePreviewPlanPath -WorkspaceRoot $testRoot -Wave 1 |
        ConvertFrom-Json -Depth 100
    Assert-True (
        $reusePreview.workers[0].note -eq
            'reuse-verification-deferred' -and
        $null -eq $reusePreview.workers[0].initial_packet_chars
    ) 'Dispatch preview must defer reuse verification without inventing size.'
    Assert-ThrowsLike {
        & $dispatchPreviewScript `
            -PlanPath (Join-Path $testRoot 'missing-plan.json') `
            -WorkspaceRoot $testRoot -Wave 1 | Out-Null
    } 'Cannot find path' 'Dispatch preview must propagate plan validation failure.'

    $roleCatalog = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/role-pack-catalog.json'
    ) -Raw | ConvertFrom-Json -Depth 20
    Assert-True (@($roleCatalog.packs).Count -eq 5) (
        'The compact catalog should contain four industry packs and one research pack.'
    )
    foreach ($rolePack in @($roleCatalog.packs)) {
        $packRoles = @(Get-Content -LiteralPath (
            Join-Path (Join-Path $skillRoot 'references') $rolePack.file
        ) -Raw | ConvertFrom-Json -Depth 50)
        if ($rolePack.id -eq 'research-evidence') {
            Assert-True ($packRoles.Count -eq 1) (
                'The research evidence pack should contain one reusable role.'
            )
        } else {
            Assert-True ($packRoles.Count -ge 3 -and $packRoles.Count -le 4) (
                "Industry role pack '$($rolePack.id)' should contain three or four roles."
            )
        }
        Assert-True (@($packRoles.id | Select-Object -Unique).Count -eq $packRoles.Count) (
            "Role pack '$($rolePack.id)' should use unique role IDs."
        )
        foreach ($presetRole in $packRoles) {
            foreach ($field in @(
                'id', 'display_name', 'mission', 'responsibilities', 'non_goals',
                'required_inputs', 'deliverables', 'evidence_rules',
                'tool_policy', 'question_policy', 'escalation_conditions',
                'identity_statement', 'user_defined'
            )) {
                Assert-True ($null -ne $presetRole.PSObject.Properties[$field]) (
                    "Preset role '$($presetRole.id)' requires '$field'."
                )
            }
        }
    }
    $equityRole = & (Join-Path $scriptRoot 'Get-AgentRolePreset.ps1') `
        -Domain 'equity-research' -RoleId 'valuation-analyst'
    Assert-True ($equityRole -like '*valuation-analyst*') (
        'An exact role query should return the selected contract.'
    )
    Assert-True ($equityRole -notlike '*thesis-risk-reviewer*') (
        'An exact role query should not inject neighboring role contracts.'
    )
    $researchRole = & (Join-Path $scriptRoot 'Get-AgentRolePreset.ps1') `
        -Domain 'research-evidence' -RoleId 'research-evidence-curator'
    Assert-True ($researchRole -like '*reusable, auditable evidence base*') (
        'The research evidence role should return its bounded reusable mission.'
    )

    $quickPreset = & (
        Join-Path $scriptRoot 'Resolve-OrchestrationPreset.ps1'
    ) -RuntimeWorkerCapacity 6 | ConvertFrom-Json
    Assert-True ($quickPreset.mode -eq 'quick') (
        'Auto should resolve a small task to quick.'
    )
    Assert-True ($quickPreset.profile -eq 'lean') (
        'A low-risk quick task should use lean verification.'
    )
    Assert-True (
        $quickPreset.limits.persistent_active_limit -eq 4 -and
        $quickPreset.limits.transient_reserved_slots -eq 2
    ) 'Six-slot capacity should reserve four persistent and two transient slots.'

    $teamPreset = & (
        Join-Path $scriptRoot 'Resolve-OrchestrationPreset.ps1'
    ) -IndependentWorkstreams 3 -Risk medium | ConvertFrom-Json
    Assert-True (
        $teamPreset.mode -eq 'team' -and $teamPreset.profile -eq 'balanced'
    ) 'Independent medium-risk workstreams should resolve to team/balanced.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-OrchestrationPreset.ps1') `
            -Mode team -IndependentWorkstreams 2 -NeedsRecovery | Out-Null
    } 'team conflicts with durable requirements' (
        'Explicit team mode must not carry workflow-only recovery.'
    )

    $workflowPreset = & (
        Join-Path $scriptRoot 'Resolve-OrchestrationPreset.ps1'
    ) -NeedsRecovery -RuntimeWorkerCapacity 3 | ConvertFrom-Json
    Assert-True ($workflowPreset.mode -eq 'workflow') (
        'Recovery should resolve to workflow.'
    )
    Assert-True (
        $workflowPreset.limits.max_concurrent_nodes -eq 3 -and
        $workflowPreset.limits.persistent_active_limit -eq 1 -and
        $workflowPreset.limits.transient_reserved_slots -eq 2
    ) 'Runtime capacity should clamp the 4+2 target without hiding transient reserve.'

    $surfaceScript = Join-Path $scriptRoot 'Resolve-CodexExecutionSurface.ps1'
    $durableProposal = & $surfaceScript -Independent -Bounded `
        -IndependentlyCheckable -MateriallySmallerContext -ReadOnly |
        ConvertFrom-Json
    Assert-True (
        $durableProposal.surface -eq 'durable-task-proposal' -and
        $durableProposal.requires_user_confirmation
    ) (
        'An independent cost-beneficial workstream should proactively propose ' +
        'a durable task instead of silently staying in the main agent.'
    )
    $lowerCostProposal = & $surfaceScript -Independent -Bounded `
        -IndependentlyCheckable -LowerCostModelAvailable -ReadOnly |
        ConvertFrom-Json
    Assert-True (
        $lowerCostProposal.surface -eq 'durable-task-proposal'
    ) (
        'A lower-cost independently checkable lane should qualify even when ' +
        'context size alone is not the benefit.'
    )
    $explicitLocalThread = & $surfaceScript -Independent -Bounded `
        -IndependentlyCheckable -MateriallySmallerContext -ReadOnly `
        -ExplicitThreadRequest | ConvertFrom-Json
    Assert-True (
        $explicitLocalThread.surface -eq 'durable-local-task' -and
        $explicitLocalThread.action -eq 'create-durable-local'
    ) 'An explicit read-only thread request must not become a native subagent.'
    $temporaryNative = & $surfaceScript -Independent -Bounded `
        -IndependentlyCheckable -MateriallySmallerContext -ReadOnly `
        -TemporaryOnly | ConvertFrom-Json
    Assert-True ($temporaryNative.surface -eq 'native-subagent') (
        'Temporary read-only work may use a native subagent when durable ' +
        'history is not useful.'
    )
    $explicitWriterNeedsPreflight = & $surfaceScript -Independent -Bounded `
        -IndependentlyCheckable -MateriallySmallerContext `
        -ExplicitThreadRequest | ConvertFrom-Json
    Assert-True (
        $explicitWriterNeedsPreflight.surface -eq 'worktree-preflight-required'
    ) 'An independent durable writer must require worktree preflight.'

    $unbornRepo = Join-Path $testRoot 'unborn-repo'
    $null = New-Item -ItemType Directory -Path $unbornRepo
    & git -C $unbornRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize unborn Git fixture.' }
    'untracked' | Set-Content -LiteralPath (Join-Path $unbornRepo 'draft.txt')
    $unbornPreflight = & (
        Join-Path $scriptRoot 'Test-CodexWorktreePreflight.ps1'
    ) -WorkspaceRoot $unbornRepo -RequiresIndependentWrite | ConvertFrom-Json
    Assert-True (
        $unbornPreflight.is_git_repository -and
        -not $unbornPreflight.has_usable_head -and
        -not $unbornPreflight.worktree_eligible -and
        $unbornPreflight.recommended_environment -eq 'main-agent'
    ) 'An unborn Git branch must be rejected for worktree creation.'
    $readOnlyPreflight = & (
        Join-Path $scriptRoot 'Test-CodexWorktreePreflight.ps1'
    ) -WorkspaceRoot $unbornRepo | ConvertFrom-Json
    Assert-True (
        $readOnlyPreflight.recommended_environment -eq 'local'
    ) 'Read-only durable work may fall back to the saved local project.'

    & git -C $unbornRepo config user.email 'test@example.invalid'
    & git -C $unbornRepo config user.name 'AAO Test'
    & git -C $unbornRepo add -- draft.txt
    & git -C $unbornRepo commit --quiet -m baseline
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit Git preflight fixture.' }
    $eligiblePreflight = & (
        Join-Path $scriptRoot 'Test-CodexWorktreePreflight.ps1'
    ) -WorkspaceRoot $unbornRepo -RequiresIndependentWrite | ConvertFrom-Json
    Assert-True (
        $eligiblePreflight.has_usable_head -and
        $eligiblePreflight.worktree_eligible -and
        $eligiblePreflight.recommended_environment -eq 'worktree' -and
        $eligiblePreflight.preflight_hash -match '^[0-9a-f]{64}$'
    ) 'A committed Git repository should pass writer worktree preflight.'

    $modelIds = @('gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra')
    $platformBindingPath = Join-Path $skillRoot (
        'references/platform-codex.md'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
            -Capability standard -RequestedModel 'gpt-5.6-terra' `
            -AllowExperimentalTerra `
            -AuthorizationEvidence 'user:not-a-real-request-without-binding' `
            -AvailableModelIds $modelIds | Out-Null
    } 'requires PlatformBindingPath' (
        'Loading routing-policy without the platform binding must not ' +
        'authorize any concrete model, including Terra.'
    )
    $economyModel = & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
        -Capability economy -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $economyModel.model -eq 'gpt-5.6-luna' -and
        $economyModel.effort -eq 'medium' -and
        -not $economyModel.inherits_main_agent_model -and
        $economyModel.platform_binding_sha256 -match '^[0-9a-f]{64}$'
    ) 'Economy should resolve to Luna medium through a hashed platform binding.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability economy -AvailableModelIds @('gpt-5.6-sol') |
            Out-Null
    } 'never inherit the main-agent model silently' (
        'An unavailable economy model must fall back to main or user choice, ' +
        'not silently inherit the expensive main model.'
    )
    $standardModel = & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
        -Capability standard -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $standardModel.model -eq 'gpt-5.6-luna' -and
        $standardModel.effort -eq 'max'
    ) (
        'Standard bounded execution should resolve to Luna max.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
            -PlatformBindingPath $platformBindingPath `
            -Capability standard -RequestedModel 'gpt-5.6-sol' `
            -AvailableModelIds $modelIds | Out-Null
    } 'requires explicit user confirmation' (
        'A standard Luna-to-Sol override must require confirmation.'
    )
    $confirmedStandardSol = & (
        Join-Path $scriptRoot 'Resolve-WorkerModel.ps1'
    ) -PlatformBindingPath $platformBindingPath `
        -Capability standard -RequestedModel 'gpt-5.6-sol' `
        -UserConfirmedEscalation `
        -AuthorizationEvidence 'user:explicit-standard-sol-escalation' `
        -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $confirmedStandardSol.model -eq 'gpt-5.6-sol' -and
        $confirmedStandardSol.authorization -eq 'escalation-confirmed'
    ) 'Explicit user evidence should permit standard-to-Sol escalation.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability standard -RequestedModel 'gpt-5.6-terra' `
            -AvailableModelIds $modelIds | Out-Null
    } 'Terra requires an explicit request' (
        'Terra must never enter routing without user evidence.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability standard -RequestedModel 'gpt-5.6-terra' `
            -AllowExperimentalTerra -AvailableModelIds $modelIds | Out-Null
    } 'user: authorization evidence' (
        'A Terra switch alone must not self-authorize the experimental model.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability ultra -AvailableModelIds $modelIds | Out-Null
    } 'user: confirmation evidence' (
        'Ultra must require explicit per-node confirmation.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
            -PlatformBindingPath $platformBindingPath `
            -Capability ultra -UserConfirmedUltra `
            -AuthorizationEvidence 'user:explicit-ultra-test-request' `
            -AvailableModelIds $modelIds | Out-Null
    } 'requires a concrete automatic-delegation reason' (
        'Ultra confirmation alone must not omit why automatic delegation is needed.'
    )
    $confirmedUltra = & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
        -Capability ultra -UserConfirmedUltra `
        -UltraReason 'The bounded max route failed and automatic delegation is necessary.' `
        -AuthorizationEvidence 'user:explicit-ultra-test-request' `
        -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $confirmedUltra.model -eq 'gpt-5.6-sol' -and
        $confirmedUltra.effort -eq 'ultra' -and
        $confirmedUltra.authorization -eq 'ultra-confirmed'
    ) 'Explicit confirmation plus a delegation reason should permit Ultra.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability economy -RequestedModel 'gpt-5.6-sol' `
            -AvailableModelIds $modelIds | Out-Null
    } 'requires explicit user confirmation' (
        'An initial economy-to-Sol override must require confirmation.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability strong -PriorRunDirectory $testRoot `
            -AvailableModelIds $modelIds | Out-Null
    } 'must be provided together' (
        'Prior retry state must identify both its run and node.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability economy -RequestedModel 'gpt-5.6-sol' `
            -UserConfirmedEscalation `
            -AuthorizationEvidence 'policy:path:missing-policy.md' `
            -WorkspaceRoot $skillRoot -AvailableModelIds $modelIds | Out-Null
    } 'existing safe project-relative file' (
        'A policy pointer must identify a real project file.'
    )
    $confirmedTerra = & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
        -Capability standard -RequestedModel 'gpt-5.6-terra' `
        -AllowExperimentalTerra `
        -AuthorizationEvidence 'user:explicit-terra-test-request' `
        -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $confirmedTerra.model -eq 'gpt-5.6-terra' -and
        $confirmedTerra.authorization -eq 'experimental-user-request'
    ) 'Explicit user evidence should permit an experimental Terra request.'

    $lunaRetryPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $lunaRetryPlan.run_id = 'luna-retry-routing-001'
    $lunaRetryPlan.nodes[0].capability = 'economy'
    $lunaRetryPlan.nodes[0].model = 'gpt-5.6-luna'
    $lunaRetryPlan.nodes[0].model_reason = (
        'The first attempt is bounded mechanical extraction.'
    )
    $lunaRetryPlan.nodes[0].effort = 'medium'
    $lunaRetryPlanPath = Join-Path $testRoot 'luna-retry-routing-plan.json'
    $lunaRetryPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $lunaRetryPlanPath
    $lunaRetryRun = Join-Path $testRoot 'luna-retry-routing-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $lunaRetryPlanPath -RunDirectory $lunaRetryRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $threadId = if ($status -eq 'materialized') {
            'luna-routing-attempt'
        } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-luna'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $lunaRetryRun -NodeId 'draft' -Status $status `
            -Message "luna routing $status" -ThreadId $threadId `
            -ModelId $modelId `
            -IdempotencyKey "luna-routing-$status" | Out-Null
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $lunaRetryRun -NodeId 'draft' -Status 'failed' `
        -Message 'Luna attempt lacked the required reasoning capability.' `
        -ErrorClass 'runtime_transient' `
        -IdempotencyKey 'luna-routing-failed' | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
            -Capability strong -PriorRunDirectory $lunaRetryRun `
            -PriorNodeId 'draft' -AvailableModelIds $modelIds | Out-Null
    } 'requires explicit user confirmation' (
        'A journal-derived Luna-to-Sol escalation must require confirmation.'
    )
    $confirmedRetry = & (Join-Path $scriptRoot 'Resolve-WorkerModel.ps1') `
        -PlatformBindingPath $platformBindingPath `
        -Capability strong -PriorRunDirectory $lunaRetryRun `
        -PriorNodeId 'draft' `
        -UserConfirmedEscalation `
        -AuthorizationEvidence 'user:explicit-escalation-test-request' `
        -AvailableModelIds $modelIds | ConvertFrom-Json
    Assert-True (
        $confirmedRetry.model -eq 'gpt-5.6-sol' -and
        $confirmedRetry.prior_model -eq 'gpt-5.6-luna' -and
        $confirmedRetry.prior_effort -eq 'medium' -and
        $confirmedRetry.authorization -eq 'escalation-confirmed'
    ) 'Immutable retry state plus user evidence should permit escalation.'

    $capacityWithTransientReserve = & (
        Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1'
    ) -ActivePersistentWorkers 4 -RequestedKind transient | ConvertFrom-Json
    Assert-True $capacityWithTransientReserve.allowed (
        'Four active persistent Workers should still leave a transient slot.'
    )
    $persistentFifth = & (
        Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1'
    ) -ActivePersistentWorkers 4 -RequestedKind persistent | ConvertFrom-Json
    Assert-True (
        -not $persistentFifth.allowed -and
        $persistentFifth.reason -eq 'persistent-active-limit-exhausted'
    ) 'A fifth persistent Worker should be rejected.'
    $orderIndependentCapacity = & (
        Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1'
    ) -ActivePersistentWorkers 2 -ActiveTransientWorkers 2 `
        -RequestedKind persistent | ConvertFrom-Json
    Assert-True $orderIndependentCapacity.allowed (
        'Persistent admission must not depend on whether transient Workers started first.'
    )
    $clampedReserve = & (
        Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1'
    ) -RuntimeWorkerCapacity 3 -ActivePersistentWorkers 1 `
        -RequestedKind persistent | ConvertFrom-Json
    Assert-True (
        -not $clampedReserve.allowed -and
        $clampedReserve.reason -eq 'transient-reserve-protected'
    ) 'Runtime clamping should still protect transient capacity.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1') `
            -RuntimeWorkerCapacity 3 -ActivePersistentWorkers 1 `
            -RequestedKind persistent -BorrowTransientReserve | Out-Null
    } 'requires explicit user confirmation' (
        'Borrowing a transient reserve must require user confirmation.'
    )
    $confirmedBorrow = & (
        Join-Path $scriptRoot 'Resolve-WorkerCapacity.ps1'
    ) -RuntimeWorkerCapacity 3 -ActivePersistentWorkers 1 `
        -RequestedKind persistent -BorrowTransientReserve `
        -UserConfirmedBorrow | ConvertFrom-Json
    Assert-True $confirmedBorrow.allowed (
        'Explicit user confirmation should permit bounded reserve borrowing.'
    )
    $efficiency = & (Join-Path $scriptRoot 'Test-OrchestrationEfficiency.ps1') `
        -PlanPath $examplePath | ConvertFrom-Json
    Assert-True $efficiency.valid 'Example efficiency policy should be valid.'
    Assert-True ($efficiency.decision -eq 'orchestrate') (
        'Valid context-efficiency policy should permit orchestration.'
    )
    Assert-True ($efficiency.maximum_context_overlap_ratio -le 0.5) (
        'Example should stay under the context-overlap ceiling.'
    )
    Assert-True ($efficiency.receipt -like '*reference-first*') (
        'Efficiency receipt should expose the context strategy.'
    )
    $baselineMetricsPath = Join-Path $testRoot 'baseline-metrics.json'
    $candidateMetricsPath = Join-Path $testRoot 'candidate-metrics.json'
    $comparisonManifestPath = Join-Path $testRoot 'comparison-manifest.json'
    @{
        task = 'example-case'
        input_manifest = @('source:test-fixture')
        acceptance = @('test:self-test')
        output_scope = 'benchmark receipt'
        environment = 'local-test'
        tool_policy = 'same'
        cache_policy = 'fresh'
        failure_policy = 'same'
    } | ConvertTo-Json | Set-Content -LiteralPath $comparisonManifestPath
    $comparisonFingerprint = (
        Get-FileHash -LiteralPath $comparisonManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    @{
        case_id = 'example-case'
        comparison_manifest_path = $comparisonManifestPath
        comparison_fingerprint = $comparisonFingerprint
        variant = 'single-agent'
        input_tokens = 40000
        output_tokens = 10000
        useful_output_tokens = 7000
        coordination_tokens = 0
        repeated_tokens = 3000
        recovery_tokens = 0
        wall_clock_seconds = 120
        quality_score = 90
    } | ConvertTo-Json | Set-Content -LiteralPath $baselineMetricsPath
    @{
        case_id = 'example-case'
        comparison_manifest_path = $comparisonManifestPath
        comparison_fingerprint = $comparisonFingerprint
        variant = 'adaptive-agent-orchestrator'
        input_tokens = 25000
        output_tokens = 8000
        useful_output_tokens = 6500
        coordination_tokens = 2000
        repeated_tokens = 2000
        recovery_tokens = 1000
        wall_clock_seconds = 90
        quality_score = 91
    } | ConvertTo-Json | Set-Content -LiteralPath $candidateMetricsPath
    $benchmark = & (Join-Path $scriptRoot 'Test-OrchestrationBenchmark.ps1') `
        -BaselinePath $baselineMetricsPath -CandidatePath $candidateMetricsPath |
        ConvertFrom-Json
    Assert-True $benchmark.passed 'Efficient candidate benchmark should pass.'
    Assert-True ($benchmark.token_savings_ratio -ge 0.2) (
        'Benchmark should report material Token savings.'
    )
    Assert-True ($benchmark.recovery_tokens -eq 1000) (
        'Benchmark must expose recovery cost.'
    )
    $forgedMetricsPath = Join-Path $testRoot 'forged-metrics.json'
    $forgedMetrics = Get-Content -LiteralPath $candidateMetricsPath -Raw |
        ConvertFrom-Json -AsHashtable
    $forgedMetrics.comparison_fingerprint = ('f' * 64)
    $forgedMetrics | ConvertTo-Json |
        Set-Content -LiteralPath $forgedMetricsPath
    $forgedFingerprintCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmark.ps1') `
            -BaselinePath $baselineMetricsPath `
            -CandidatePath $forgedMetricsPath | Out-Null
    }
    catch {
        $forgedFingerprintCaught = $_.Exception.Message -like (
            '*does not match its manifest file*'
        )
    }
    Assert-True $forgedFingerprintCaught (
        'Benchmark fingerprints must be derived from an actual manifest file.'
    )
    $baselineSuitePath = Join-Path $testRoot 'baseline-suite.json'
    $candidateSuitePath = Join-Path $testRoot 'candidate-suite.json'
    $suiteManifests = @{}
    foreach ($caseId in @('a', 'b', 'c')) {
        $manifestPath = Join-Path $testRoot "comparison-$caseId.json"
        @{
            task = "suite-$caseId"
            input_manifest = @("source:fixture-$caseId")
            acceptance = @("test:case-$caseId")
            output_scope = 'benchmark receipt'
            environment = 'local-test'
            tool_policy = 'same'
            cache_policy = 'fresh'
            failure_policy = 'same'
        } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
        $suiteManifests[$caseId] = @{
            path = $manifestPath
            hash = (
                Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'b'; comparison_manifest_path = $suiteManifests.b.path; comparison_fingerprint = $suiteManifests.b.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 91 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $baselineSuitePath
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 5500; output_tokens = 1500; quality_score = 90 },
        @{ case_id = 'b'; comparison_manifest_path = $suiteManifests.b.path; comparison_fingerprint = $suiteManifests.b.hash; input_tokens = 6000; output_tokens = 1500; quality_score = 91 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 6500; output_tokens = 1500; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $candidateSuitePath
    $benchmarkSuite = & (
        Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1'
    ) -BaselinePath $baselineSuitePath -CandidatePath $candidateSuitePath |
        ConvertFrom-Json
    Assert-True $benchmarkSuite.passed (
        'A benchmark suite with median savings and no P90 regression should pass.'
    )
    Assert-True ($benchmarkSuite.p90_token_ratio -le 1) (
        'Benchmark suite must enforce the P90 no-regression gate.'
    )
    $weakenedBenchmarkGateCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1') `
            -BaselinePath $baselineSuitePath -CandidatePath $candidateSuitePath `
            -MinimumMedianSavingsRatio 0 | Out-Null
    }
    catch {
        $weakenedBenchmarkGateCaught = $_.Exception.Message -like (
            '*MinimumMedianSavingsRatio*'
        )
    }
    Assert-True $weakenedBenchmarkGateCaught (
        'Release benchmark thresholds must not be weakened by parameters.'
    )
    $duplicateBaselineSuitePath = Join-Path $testRoot (
        'duplicate-baseline-suite.json'
    )
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $duplicateBaselineSuitePath
    $duplicateBaselineCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1') `
            -BaselinePath $duplicateBaselineSuitePath `
            -CandidatePath $candidateSuitePath | Out-Null
    }
    catch {
        $duplicateBaselineCaught = $_.Exception.Message -like (
            '*Duplicate baseline case_id*'
        )
    }
    Assert-True $duplicateBaselineCaught (
        'Benchmark suites must reject duplicated baseline cases.'
    )

    $handoffPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $handoffPlan.nodes[0].context.handoff_required = $true
    $handoffPlan.nodes[0].context.handoff_path =
        'artifacts/handoffs/draft.json'
    $handoffPlan.nodes[0].context.handoff_max_chars = 4000
    $handoffPlan.completion.review_disposition_checks = @(
        @{
            source_node_id = 'draft'
            path = 'receipts/draft.review-disposition.json'
            blocking_severities = @('P0', 'P1')
        }
    )
    $handoffPlanPath = Join-Path $testRoot 'handoff-plan.json'
    $handoffPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $handoffPlanPath

    $runDirectory = Join-Path $testRoot 'run'
    $initial = & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $handoffPlanPath -RunDirectory $runDirectory `
        -WorkspaceRoot $testRoot | ConvertFrom-Json
    Assert-True ('draft' -in @($initial.ready_nodes)) 'Draft should initially be ready.'
    Assert-True ('review' -notin @($initial.ready_nodes)) 'Review should wait for draft.'
    $draftReadDirectory = Join-Path $runDirectory 'thread-reads'
    $null = New-Item -ItemType Directory -Path $draftReadDirectory
    $draftReadPath = Join-Path $draftReadDirectory 'draft.json'
    [ordered]@{
        schemaVersion = 1
        thread = [ordered]@{
            id = 'test-thread-draft'
        }
        page = [ordered]@{
            order = 'newest_first'
        }
        turns = @(
            [ordered]@{
                id = 'draft-final-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = (
                            'The draft defines interfaces, limits, and ' +
                            'failure handling.'
                        )
                    }
                )
            },
            [ordered]@{
                id = 'draft-older-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'An older result that must not be selected.'
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $draftReadPath
    $draftFindingText = 'Draft satisfies the bounded section contract.'
    $draftFindingHash = Get-TextSha256 $draftFindingText
    $draftFindingId = 'draft-contract-001'
    $draftFindingsPath = Join-Path $runDirectory 'draft-findings.json'
    @(
        [ordered]@{
            finding_id = $draftFindingId
            severity = 'P1'
            text = $draftFindingText
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $draftFindingsPath
    $draftReceiptRelative = 'receipts/draft.thread-result-receipt.json'
    $draftReceiptPath = Join-Path $runDirectory $draftReceiptRelative
    $draftReceipt = & (
        Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1'
    ) -RunDirectory $runDirectory -SourceNodeId 'draft' `
        -ThreadId 'test-thread-draft' `
        -HostId 'opaque-host-1' -ThreadReadPath $draftReadPath `
        -OutputPath $draftReceiptPath `
        -PendingFindingRecordsPath $draftFindingsPath |
        ConvertFrom-Json -Depth 20
    Assert-True ($draftReceipt.receipt_hash -match '^[0-9a-f]{64}$') (
        'Thread result collection must produce an immutable receipt.'
    )
    Assert-True ($draftReceipt.final_turn_id -eq 'draft-final-turn') (
        'Result collection must select the newest completed turn.'
    )
    Assert-True (
        @($draftReceipt.pending_findings).Count -eq 1 -and
        @($draftReceipt.adopted_findings).Count -eq 0
    ) 'Initial result collection may bind findings before adoption decisions.'
    $singleFindingReceipt = & (
        Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1'
    ) -RunDirectory $runDirectory -SourceNodeId 'draft' `
        -ThreadId 'test-thread-draft' `
        -HostId 'opaque-host-1' -ThreadReadPath $draftReadPath `
        -OutputPath (
            Join-Path $runDirectory (
                'receipts/draft.single-finding.thread-result-receipt.json'
            )
        ) -AdoptedFindings @($draftFindingText) |
        ConvertFrom-Json -Depth 20
    Assert-True (
        @($singleFindingReceipt.adopted_findings).Count -eq 1 -and
        [string]$singleFindingReceipt.adopted_findings[0] -eq $draftFindingText
    ) 'A single legacy finding must remain an array in the result receipt.'
    $legacyReceiptPath = Join-Path $runDirectory (
        'receipts/legacy.thread-result-receipt.json'
    )
    $legacyPayload = [ordered]@{
        schema_version = '1.1'
        thread_id = [string]$draftReceipt.thread_id
        host_id = [string]$draftReceipt.host_id
        collection_method = [string]$draftReceipt.collection_method
        thread_read_path = [string]$draftReceipt.thread_read_path
        thread_read_hash = [string]$draftReceipt.thread_read_hash
        final_turn_id = [string]$draftReceipt.final_turn_id
        final_status = [string]$draftReceipt.final_status
        final_content_hash = [string]$draftReceipt.final_content_hash
        adopted_findings = @($draftFindingText)
        rejected_findings = @()
    }
    $legacyReceipt = [ordered]@{}
    foreach ($key in $legacyPayload.Keys) {
        $legacyReceipt[$key] = $legacyPayload[$key]
    }
    $legacyReceipt.receipt_hash = Get-TextSha256 (
        $legacyPayload | ConvertTo-Json -Compress -Depth 20
    )
    $legacyReceipt | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $legacyReceiptPath
    $legacyVerified = Read-ThreadResultReceipt -Path $legacyReceiptPath `
        -ExpectedThreadId 'test-thread-draft' -ExpectedSourceNodeId 'draft' `
        -RunDirectory $runDirectory
    Assert-True ($legacyVerified.schema_version -eq '1.1') (
        'The pending-findings schema must preserve legacy receipt readability.'
    )
    $legacy12ReceiptPath = Join-Path $runDirectory (
        'receipts/legacy-1.2.thread-result-receipt.json'
    )
    $legacy12Payload = [ordered]@{
        schema_version = '1.2'
        thread_id = [string]$draftReceipt.thread_id
        host_id = [string]$draftReceipt.host_id
        collection_method = [string]$draftReceipt.collection_method
        thread_read_path = [string]$draftReceipt.thread_read_path
        thread_read_hash = [string]$draftReceipt.thread_read_hash
        final_turn_id = [string]$draftReceipt.final_turn_id
        final_status = [string]$draftReceipt.final_status
        final_content_hash = [string]$draftReceipt.final_content_hash
        adopted_findings = @()
        rejected_findings = @()
        pending_findings = @($draftFindingText)
    }
    $legacy12Receipt = [ordered]@{}
    foreach ($key in $legacy12Payload.Keys) {
        $legacy12Receipt[$key] = $legacy12Payload[$key]
    }
    $legacy12Receipt.receipt_hash = Get-TextSha256 (
        $legacy12Payload | ConvertTo-Json -Compress -Depth 20
    )
    $legacy12Receipt | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $legacy12ReceiptPath
    $legacy12Verified = Read-ThreadResultReceipt -Path $legacy12ReceiptPath `
        -ExpectedThreadId 'test-thread-draft' -ExpectedSourceNodeId 'draft' `
        -RunDirectory $runDirectory
    Assert-True ($legacy12Verified.schema_version -eq '1.2') (
        'Schema 1.2 receipts should remain readable as historical evidence.'
    )
    $resolvedDecisionsPath = Join-Path $runDirectory (
        'draft-review-decisions-resolved.json'
    )
    @(
        [ordered]@{
            source_finding_id = $draftFindingId
            finding = $draftFindingText
            finding_hash = $draftFindingHash
            canonical_finding_id = 'draft.bounded-section-contract'
            severity = 'P1'
            disposition = 'adopted'
            rationale = 'The main owner incorporated the bounded contract.'
            resolution_status = 'resolved'
            evidence = @('test:self-test-draft-contract')
            re_review_status = 'completed'
            re_review_source_node_id = 'draft'
            re_review_evidence = @('observation:source-role-accepted-revision')
        }
    ) | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $resolvedDecisionsPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
            -RunDirectory $runDirectory -MilestoneId 'self-test-legacy-source' `
            -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
            -SourceResultReceiptPath $legacyReceiptPath `
            -DecisionsPath $resolvedDecisionsPath -OutputPath (
                Join-Path $runDirectory (
                    'receipts/draft.review-disposition.legacy-source.json'
                )
            ) | Out-Null
    } 'requires a schema 1.3 source receipt' (
        'Legacy result receipts must fail closed for durable disposition.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
            -RunDirectory $runDirectory -MilestoneId 'self-test-legacy-1.2' `
            -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
            -SourceResultReceiptPath $legacy12ReceiptPath `
            -DecisionsPath $resolvedDecisionsPath -OutputPath (
                Join-Path $runDirectory (
                    'receipts/draft.review-disposition.legacy-1.2.json'
                )
            ) | Out-Null
    } 'requires a schema 1.3 source receipt' (
        'Schema 1.2 must fail closed for durable disposition.'
    )
    $resolvedDispositionPath = Join-Path $runDirectory (
        'receipts/draft.review-disposition.json'
    )
    $resolvedDisposition = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $runDirectory -MilestoneId 'self-test' `
        -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
        -SourceResultReceiptPath $draftReceiptPath `
        -DecisionsPath $resolvedDecisionsPath `
        -OutputPath $resolvedDispositionPath | ConvertFrom-Json -Depth 30
    Assert-True (
        $resolvedDisposition.blocking_open.Count -eq 0 -and
        $resolvedDisposition.receipt_hash -match '^[0-9a-f]{64}$'
    ) 'Resolved review findings should produce a bound immutable receipt.'
    $wrongSourceHashReceiptPath = Join-Path $runDirectory (
        'receipts/draft.review-disposition.wrong-source-hash.json'
    )
    $wrongSourceHashReceipt = Get-Content -LiteralPath (
        $resolvedDispositionPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $wrongSourceHashReceipt.source_result_receipt_hash = '0' * 64
    $wrongSourceHashReceipt | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $wrongSourceHashReceiptPath
    Assert-ThrowsLike {
        Read-ReviewDispositionReceipt -Path $wrongSourceHashReceiptPath `
            -RunDirectory $runDirectory -ExpectedSourceNodeId 'draft' `
            -ExpectedThreadId 'test-thread-draft' | Out-Null
    } 'not bound to its source result receipt' (
        'Disposition must reject a changed source receipt hash.'
    )
    $wrongSourceNodeReceiptPath = Join-Path $runDirectory (
        'receipts/draft.review-disposition.wrong-node.json'
    )
    $wrongSourceNodeReceipt = Get-Content -LiteralPath (
        $resolvedDispositionPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $wrongSourceNodeReceipt.source_node_id = 'another-source'
    $wrongSourceNodeReceipt | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $wrongSourceNodeReceiptPath
    Assert-ThrowsLike {
        Read-ReviewDispositionReceipt -Path $wrongSourceNodeReceiptPath `
            -RunDirectory $runDirectory -ExpectedSourceNodeId 'draft' `
            -ExpectedThreadId 'test-thread-draft' | Out-Null
    } 'current run or source node' (
        'Disposition must reject a changed source node binding.'
    )

    $openDecisionsPath = Join-Path $runDirectory (
        'draft-review-decisions-open.json'
    )
    @(
        [ordered]@{
            source_finding_id = $draftFindingId
            finding = $draftFindingText
            finding_hash = $draftFindingHash
            canonical_finding_id = 'draft.bounded-section-contract'
            severity = 'P1'
            disposition = 'deferred'
            rationale = 'The finding is intentionally left open for the gate test.'
            resolution_status = 'open'
            evidence = @('observation:self-test-open-finding')
            re_review_status = 'requested'
            re_review_source_node_id = 'draft'
            re_review_evidence = @('observation:re-review-request-sent')
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $openDecisionsPath
    $openDispositionPath = Join-Path $runDirectory (
        'receipts/draft.review-disposition.open.json'
    )
    $openDisposition = & (
        Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1'
    ) -RunDirectory $runDirectory -MilestoneId 'self-test-open' `
        -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
        -SourceResultReceiptPath $draftReceiptPath `
        -DecisionsPath $openDecisionsPath -OutputPath $openDispositionPath |
        ConvertFrom-Json -Depth 30
    Assert-True (
        @($openDisposition.blocking_open).Count -eq 1
    ) 'Open P1 findings must be identified as completion blockers.'

    $missingReReviewPath = Join-Path $runDirectory (
        'draft-review-decisions-missing-rereview.json'
    )
    @(
        [ordered]@{
            source_finding_id = $draftFindingId
            finding = $draftFindingText
            finding_hash = $draftFindingHash
            canonical_finding_id = 'draft.bounded-section-contract'
            severity = 'P1'
            disposition = 'partially-adopted'
            rationale = 'The main owner claims the revision is complete.'
            resolution_status = 'resolved'
            evidence = @('test:self-test-unreviewed-revision')
            re_review_status = 'requested'
            re_review_source_node_id = 'draft'
            re_review_evidence = @('observation:re-review-request-sent')
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingReReviewPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
            -RunDirectory $runDirectory -MilestoneId 'self-test-no-rereview' `
            -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
            -SourceResultReceiptPath $draftReceiptPath `
            -DecisionsPath $missingReReviewPath -OutputPath (
                Join-Path $runDirectory (
                    'receipts/draft.review-disposition.no-rereview.json'
                )
            ) | Out-Null
    } 'require completed re-review' (
        'Resolved adopted P0/P1 findings must return to the source role.'
    )

    $wrongReviewSourcePath = Join-Path $runDirectory (
        'draft-review-decisions-wrong-source.json'
    )
    $wrongReviewSource = Get-Content -LiteralPath $openDecisionsPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $wrongReviewSource.re_review_source_node_id = 'another-reviewer'
    $wrongReviewSource | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $wrongReviewSourcePath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
            -RunDirectory $runDirectory -MilestoneId 'self-test-wrong-source' `
            -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
            -SourceResultReceiptPath $draftReceiptPath `
            -DecisionsPath $wrongReviewSourcePath -OutputPath (
                Join-Path $runDirectory (
                    'receipts/draft.review-disposition.wrong-source.json'
                )
            ) | Out-Null
    } 'original source node' (
        'One durable role cannot satisfy another role re-review requirement.'
    )
    $sourceBindingMutations = @(
        @{
            name = 'finding-id'
            property = 'source_finding_id'
            value = 'unknown-source-finding'
            expected = 'duplicate or unknown finding'
        },
        @{
            name = 'text'
            property = 'finding'
            value = 'Changed finding text.'
            expected = 'must exactly match source'
        },
        @{
            name = 'text-hash'
            property = 'finding_hash'
            value = '0' * 64
            expected = 'must exactly match source'
        },
        @{
            name = 'severity'
            property = 'severity'
            value = 'P2'
            expected = 'must exactly match source'
        }
    )
    foreach ($mutation in $sourceBindingMutations) {
        $mutationPath = Join-Path $runDirectory (
            'draft-review-decisions-mutated-' + $mutation.name + '.json'
        )
        $mutatedDecision = Get-Content -LiteralPath $openDecisionsPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
        $mutatedDecision[$mutation.property] = $mutation.value
        $mutatedDecision | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $mutationPath
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'New-ReviewDispositionReceipt.ps1') `
                -RunDirectory $runDirectory `
                -MilestoneId ('self-test-mutated-' + $mutation.name) `
                -SourceNodeId 'draft' -SourceThreadId 'test-thread-draft' `
                -SourceResultReceiptPath $draftReceiptPath `
                -DecisionsPath $mutationPath -OutputPath (
                    Join-Path $runDirectory (
                        'receipts/draft.review-disposition.mutated-' +
                        $mutation.name + '.json'
                    )
                ) | Out-Null
        } $mutation.expected (
            "Durable disposition must reject mutated $($mutation.name)."
        )
    }
    $runningReadPath = Join-Path $draftReadDirectory 'draft-running.json'
    $runningCapture = Get-Content -LiteralPath $draftReadPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    $runningCapture.turns[0].status = 'running'
    $runningCapture | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $runningReadPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-ThreadResultReceipt.ps1') `
            -RunDirectory $runDirectory -SourceNodeId 'draft' `
            -ThreadId 'test-thread-draft' `
            -HostId 'opaque-host-1' -ThreadReadPath $runningReadPath `
            -OutputPath (
                Join-Path $runDirectory 'receipts/running.thread-result-receipt.json'
            ) -AdoptedFindings @('Must not be accepted.') | Out-Null
    } 'Newest thread turn is not completed' (
        'An older completed turn cannot mask a newer running turn.'
    )

    $reconciliationSource = Get-Content -LiteralPath (
        Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1'
    ) -Raw
    Assert-True (
        $reconciliationSource -match '\$MinVisibilityDelaySeconds = 40'
    ) (
        'The provisional creation-visibility safety floor must not drift silently.'
    )
    Assert-True (
        $reconciliationSource -match '\$createReturnedStableId' -and
        $reconciliationSource -match '-not \$createReturnedStableId'
    ) (
        'A successful create call with a returned task ID must block no-match retry.'
    )

    $planValidatorSource = Get-Content -LiteralPath (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -Raw
    Assert-True (
        $planValidatorSource -match '\[IO\.Path\]::DirectorySeparatorChar' -and
        $planValidatorSource -notmatch 'StartsWith\(\$right \+ ''\\\\'''
    ) (
        'Write-scope overlap checks must use the current platform separator.'
    )

    foreach ($sourceFile in Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1') {
        $sourceLines = Get-Content -LiteralPath $sourceFile.FullName
        for ($lineIndex = 0; $lineIndex -lt $sourceLines.Count; $lineIndex++) {
            $sourceLine = $sourceLines[$lineIndex]
            $previousLine = if ($lineIndex -gt 0) {
                $sourceLines[$lineIndex - 1]
            } else { '' }
            if (($sourceLine -match 'Join-Path' -or
                    $previousLine -match 'Join-Path') -and
                $sourceLine -match "'[A-Za-z0-9._-]+\\[A-Za-z0-9._-]") {
                Assert-True $false (
                    "Windows-only backslash path literal in " +
                    "$($sourceFile.Name):$($lineIndex + 1); use forward slashes " +
                    'or nested Join-Path so the suite runs on Linux pwsh.'
                )
            }
        }
    }

    $measureReport = & (
        Join-Path $scriptRoot 'Measure-OrchestrationRun.ps1'
    ) -RunDirectory $runDirectory -SkillRoot $skillRoot |
        ConvertFrom-Json -Depth 100
    Assert-True (
        [string]$measureReport.policy_version -eq '0.7.6' -and
        @($measureReport.result_receipts).Count -ge 1
    ) (
        'Measure-OrchestrationRun must report the run policy version and receipts.'
    )

    $waveBindingRun = Join-Path $testRoot 'wave-binding-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $waveBindingRun `
        -WorkspaceRoot $testRoot | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $waveBindingRun -NodeId 'draft' `
            -Status 'materialized' -Message 'missing actual model' `
            -IdempotencyKey 'missing-actual-model' | Out-Null
    } "requires ModelVerificationState 'unverified'" (
        'A hidden platform model must use the explicit unverified path.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $waveBindingRun -NodeId 'draft' `
            -Status 'materialized' -Message 'model silently changed' `
            -ModelId 'gpt-5.6-luna' `
            -IdempotencyKey 'mismatched-actual-model' | Out-Null
    } 'differs from planned model' (
        'Materialization must reject an unapproved model substitution.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $waveBindingRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'attempt forged wave' -Wave 99 `
        -IdempotencyKey 'wave-binding-draft' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $waveBindingRun -NodeId 'draft' `
        -Status 'materializing' -Message 'creation accepted' `
        -IdempotencyKey 'wave-binding-materializing' | Out-Null
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $waveBindingRun -NodeId 'draft' `
            -Status 'materialized' -Message 'unverified with requested model' `
            -ThreadId 'opaque-thread-unverified' -ModelId 'gpt-5.6-sol' `
            -ModelVerificationState 'unverified' `
            -ModelVerificationEvidence 'observation:platform-model-not-exposed' `
            -IdempotencyKey 'unverified-with-model' | Out-Null
    } 'must leave ModelId empty' (
        'An unverified route must not relabel the requested model as actual.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $waveBindingRun -NodeId 'draft' `
            -Status 'materialized' -Message 'unverified without evidence' `
            -ThreadId 'opaque-thread-unverified' `
            -ModelVerificationState 'unverified' `
            -IdempotencyKey 'unverified-without-evidence' | Out-Null
    } 'requires ModelVerificationEvidence' (
        'An unverified route must bind evidence for the platform limitation.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $waveBindingRun -NodeId 'draft' `
        -Status 'materialized' -Message 'platform omitted actual model' `
        -ThreadId 'opaque-thread-unverified' `
        -ModelVerificationState 'unverified' `
        -ModelVerificationEvidence 'observation:platform-model-not-exposed' `
        -IdempotencyKey 'unverified-materialization' | Out-Null
    $unverifiedState = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $waveBindingRun | ConvertFrom-Json -Depth 100
    $unverifiedDraft = $unverifiedState.nodes |
        Where-Object { $_.id -eq 'draft' }
    Assert-True (
        $null -eq $unverifiedDraft.actual_model -and
        $unverifiedDraft.planned_model -eq 'gpt-5.6-sol' -and
        $unverifiedDraft.actual_model_verification -eq 'unverified' -and
        $unverifiedDraft.actual_model_verification_evidence -eq
            'observation:platform-model-not-exposed'
    ) (
        'State must keep the requested model separate from an unverified actual model.'
    )
    $unverifiedEventsPath = Join-Path $waveBindingRun 'events.jsonl'
    $originalUnverifiedEventLines = @(
        Get-Content -LiteralPath $unverifiedEventsPath
    )
    $tamperedUnverifiedEventLines = @($originalUnverifiedEventLines)
    $tamperedUnverifiedEvent = $tamperedUnverifiedEventLines[-1] |
        ConvertFrom-Json -AsHashtable -Depth 30
    $tamperedUnverifiedEvent.model_verification_evidence =
        'observation:requested-model-treated-as-actual'
    $tamperedUnverifiedEventLines[-1] = (
        $tamperedUnverifiedEvent | ConvertTo-Json -Compress -Depth 30
    )
    Set-Content -LiteralPath $unverifiedEventsPath `
        -Value $tamperedUnverifiedEventLines
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $waveBindingRun | Out-Null
    } 'Journal event hash mismatch' (
        'Unverified-model evidence must be protected by the journal hash.'
    )
    Set-Content -LiteralPath $unverifiedEventsPath `
        -Value $originalUnverifiedEventLines
    $unverifiedReceipt = & (
        Join-Path $scriptRoot 'New-OrchestrationTaskReceipt.ps1'
    ) -RunDirectory $waveBindingRun -Outcome 'fallback-main' `
        -Summary 'Platform did not expose the replacement model.' `
        -FailureClass 'other' -FallbackAction 'Main agent retains ownership.' `
        -Evidence @('observation:platform-model-not-exposed') `
        -OutputPath (Join-Path $waveBindingRun (
            'receipts/unverified.task-completion-receipt.json'
        )) | ConvertFrom-Json -Depth 20
    Assert-True (
        $unverifiedReceipt.schema_version -eq '1.1' -and
        -not $unverifiedReceipt.model_verification.all_actual_models_verified -and
        'draft' -in @($unverifiedReceipt.model_verification.unverified_node_ids)
    ) (
        'Task receipts must preserve unverified actual-model status.'
    )
    $waveBindingEvent = Get-Content -LiteralPath (
        Join-Path $waveBindingRun 'events.jsonl'
    ) | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True (
        $waveBindingEvent.wave -eq 1 -and
        $waveBindingEvent.model_verification_state -eq 'unverified'
    ) (
        'Runtime events must use the immutable plan wave, not caller input.'
    )

    $coordinationDoubleCountCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status 'launch_reserved' `
            -Message 'invalid standalone coordination usage' `
            -CoordinationTokensDelta 10 -UsageSource 'estimate' `
            -IdempotencyKey 'draft-invalid-coordination' | Out-Null
    }
    catch {
        $coordinationDoubleCountCaught = $_.Exception.Message -like (
            '*must be a subset*'
        )
    }
    Assert-True $coordinationDoubleCountCaught (
        'Coordination diagnostics must not be counted outside total usage.'
    )

    $dependencyCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
            -Message 'start review too early' -IdempotencyKey 'review-too-early' |
            Out-Null
    }
    catch {
        $dependencyCaught = $_.Exception.Message -like '*before dependency*'
    }
    Assert-True $dependencyCaught 'A node must not launch before dependencies validate.'

    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized',
        'running', 'completed', 'validated'
    )) {
        $threadId = if ($status -eq 'materialized') { 'test-thread-draft' } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        $artifact = if ($status -eq 'completed') {
            'artifacts/draft/output.md'
        } else { $null }
        $evidence = if ($status -eq 'completed') {
            @(
                'artifact:artifacts/draft/output.md',
                "artifact:$draftReceiptRelative"
            )
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 1200 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 600 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status $status `
            -Message "draft $status" -ThreadId $threadId -ModelId $modelId `
            -Artifact $artifact `
            -Evidence $evidence -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "draft-1-$status" | Out-Null
    }
    $afterDraft = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True ('review' -notin @($afterDraft.ready_nodes)) (
        'Validation alone must not unlock a dependent worker before adoption.'
    )
    $draftState = $afterDraft.nodes | Where-Object { $_.id -eq 'draft' }
    Assert-True ($draftState.thread_id -eq 'test-thread-draft') (
        'Reducer should retain the last non-null thread id.'
    )
    Assert-True (
        $draftState.planned_model -eq 'gpt-5.6-sol' -and
        $draftState.actual_model -eq 'gpt-5.6-sol' -and
        $draftState.actual_model_verification -eq 'verified'
    ) 'Reducer should retain planned and actual model identity.'
    Assert-True ($draftState.artifact -eq 'artifacts/draft/output.md') (
        'Reducer should retain the last non-null artifact.'
    )
    Assert-True ($afterDraft.usage.total_tokens -eq 1800) (
        'Reducer should sum input and output without re-adding coordination.'
    )
    $draftHandoff = & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' `
        -Summary 'The draft defines interfaces, limits, and failure handling.' `
        -Decisions @('Use one controller') `
        -Evidence @('artifact:artifacts/draft/output.md') `
        -UnresolvedRisks @('Runtime adapter remains pending') `
        -RiskDisposition 'mitigated' `
        -NextAction 'Give the validated draft to the review node.' |
        ConvertFrom-Json
    Assert-True ($draftHandoff.handoff.continuity_key -eq 'architecture-proposal') (
        'Handoff should retain the declared continuity key.'
    )
    Assert-True ($draftHandoff.handoff_sha256 -match '^[0-9a-f]{64}$') (
        'Handoff creation should return a SHA-256 binding.'
    )
    Assert-True (Test-Path -LiteralPath (
        Join-Path $testRoot 'artifacts/handoffs/draft.json'
    )) 'Handoff should be written to the declared project-relative path.'
    $handoffOverwriteCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' `
            -Summary 'Attempt to replace the original handoff.' `
            -Evidence @('artifact:artifacts/draft/output.md') `
            -RiskDisposition 'none' -NextAction 'Do not replace it.' | Out-Null
    }
    catch {
        $handoffOverwriteCaught = $_.Exception.Message -like '*immutable*'
    }
    Assert-True $handoffOverwriteCaught 'A handoff must be immutable once written.'

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' -Status 'adopted' `
        -Message 'adopted because the draft closes the required architecture gap' `
        -IdempotencyKey 'draft-1-adopted' | Out-Null
    $missingArchiveReceiptPath = "$draftReceiptPath.archive-missing"
    Move-Item -LiteralPath $draftReceiptPath -Destination $missingArchiveReceiptPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status 'archived' `
            -Message 'archive without collected result' `
            -IdempotencyKey 'draft-archive-missing-receipt' | Out-Null
    } 'result receipt does not exist' (
        'A durable background task cannot be archived after its result receipt disappears.'
    )
    Move-Item -LiteralPath $missingArchiveReceiptPath -Destination $draftReceiptPath
    $archiveReceiptOriginal = Get-Content -LiteralPath $draftReceiptPath -Raw
    $archiveReceiptTampered = $archiveReceiptOriginal |
        ConvertFrom-Json -AsHashtable -Depth 20
    $archiveReceiptTampered.host_id = 'tampered-host'
    $archiveReceiptTampered | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $draftReceiptPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status 'archived' `
            -Message 'archive with tampered result' `
            -IdempotencyKey 'draft-archive-tampered-receipt' | Out-Null
    } 'receipt hash mismatch' (
        'A durable background task cannot be archived with a tampered result receipt.'
    )
    Set-Content -LiteralPath $draftReceiptPath `
        -Value $archiveReceiptOriginal -NoNewline
    $draftArchiveEvent = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $runDirectory -NodeId 'draft' -Status 'archived' `
        -Message 'result collected and adopted' `
        -IdempotencyKey 'draft-1-archived' | ConvertFrom-Json
    Assert-True (
        $draftArchiveEvent.result_receipt_hash -eq $draftReceipt.receipt_hash -and
        $draftArchiveEvent.result_receipt_path -eq $draftReceiptRelative
    ) 'Archive events must bind the verified thread result receipt.'
    $archiveJournalPath = Join-Path $runDirectory 'events.jsonl'
    $archiveJournalOriginal = Get-Content -LiteralPath $archiveJournalPath -Raw
    $tamperedReceiptHash = '0' * 64
    $archiveJournalTampered = $archiveJournalOriginal.Replace(
        [string]$draftReceipt.receipt_hash,
        $tamperedReceiptHash
    )
    Set-Content -LiteralPath $archiveJournalPath `
        -Value $archiveJournalTampered -NoNewline
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $runDirectory | Out-Null
    } 'Journal event hash mismatch' (
        'Changing an archived result receipt binding must break the journal hash chain.'
    )
    Set-Content -LiteralPath $archiveJournalPath `
        -Value $archiveJournalOriginal -NoNewline
    $draftArchiveReplay = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $runDirectory -NodeId 'draft' -Status 'archived' `
        -Message 'result collected and adopted' `
        -IdempotencyKey 'draft-1-archived' | ConvertFrom-Json
    Assert-True (
        $draftArchiveReplay.sequence -eq $draftArchiveEvent.sequence -and
        $draftArchiveReplay.result_receipt_hash -eq $draftReceipt.receipt_hash
    ) 'Archive idempotency replay must revalidate the bound result receipt.'
    $afterDraftAdoption = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True ('review' -in @($afterDraftAdoption.ready_nodes)) (
        'A dependent worker should become ready only after explicit adoption.'
    )

    $reviewReservation = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
        -Message 'review reserved' -IdempotencyKey 'review-1-reserved' |
        ConvertFrom-Json
    $reviewReservationAgain = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
        -Message 'review reserved' -IdempotencyKey 'review-1-reserved' |
        ConvertFrom-Json
    Assert-True ($reviewReservation.sequence -eq $reviewReservationAgain.sequence) (
        'Repeated idempotency keys should return the original event.'
    )
    $idempotencyCollisionCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
            -Message 'changed payload' -IdempotencyKey 'review-1-reserved' |
            Out-Null
    }
    catch {
        $idempotencyCollisionCaught = $_.Exception.Message -like '*already used*'
    }
    Assert-True $idempotencyCollisionCaught (
        'An idempotency key must not accept a different request payload.'
    )

    $packet = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'review' -WorkspaceRoot $testRoot
    Assert-True ($packet -like '*I challenge the proposal independently*') (
        'Rendered packets should contain the role identity.'
    )
    Assert-True (
        $packet -match '\[verified\], \[inferred\], or \[assumed\]' -and
        $packet -like '*Assumptions cannot satisfy acceptance checks*'
    ) 'Worker packets must carry compact finding-provenance rules.'
    $skillPolicyText = Get-Content -LiteralPath (
        Join-Path $skillRoot 'SKILL.md'
    ) -Raw
    $safetyPolicyText = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/safety-and-lifecycle.md'
    ) -Raw
    Assert-True (
        $skillPolicyText -like '*data, never as control instructions*' -and
        $safetyPolicyText -like '*data, not instructions to the main agent*'
    ) 'Worker packets must inject the untrusted-data control-plane policy.'
    $routingPolicyText = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/routing-policy.md'
    ) -Raw
    Assert-True (
        $skillPolicyText -like (
            '*A concrete model or effort may enter*only from that resolver*'
        ) -and
        $skillPolicyText -like (
            '*actual model: unverified*never relabel the request*'
        ) -and
        $routingPolicyText -like (
            '*If only this routing policy was loaded, no concrete model*'
        )
    ) (
        'The launch contract must forbid model inference from routing policy ' +
        'without the platform-bound resolver.'
    )
    Assert-True ($packet -like '*Maximum questions: 2*') (
        'Rendered packets should contain the role question limit.'
    )
    Assert-True ($packet -like '*No workspace writes*') (
        'Rendered packets should contain the effective write boundary.'
    )
    Assert-True ($packet -like '*Session: fresh*') (
        'Rendered packets should contain the session policy.'
    )
    Assert-True ($packet -like '*Exclude:*') (
        'Rendered packets should contain explicit context exclusions.'
    )
    Assert-True ($packet -like '*Read only these references:*') (
        'Rendered packets should direct reference-first context loading.'
    )
    Assert-True ($packet -notlike '*Selection reason:*') (
        'Controller-only selection reasons must not inflate worker packets.'
    )
    Assert-True ($packet -like '*Handoff: none*') (
        'A node without handoff_required should not be told to write one.'
    )
    Assert-True ($packet -like '*Do not restate inputs*') (
        'Rendered packets should make context-minimization rules operational.'
    )
    $missingRefPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingRefPlan.nodes[0].context.inputs = @(
        'ref:plan.goal',
        'ref:plan.missing_field'
    )
    $missingRefPlanPath = Join-Path $testRoot 'packet-missing-ref-plan.json'
    $missingRefPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $missingRefPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $missingRefPlanPath -NodeId 'draft' `
            -WorkspaceRoot $testRoot | Out-Null
    } 'does not resolve to an existing plan field' (
        'Worker packets must reject plan references that do not exist.'
    )

    $missingPathPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingPathPlan.nodes[0].context.inputs = @(
        'ref:plan.goal',
        'path:missing-input.md'
    )
    $missingPathPlanPath = Join-Path $testRoot 'packet-missing-path-plan.json'
    $missingPathPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $missingPathPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $missingPathPlanPath -NodeId 'draft' `
            -WorkspaceRoot $testRoot | Out-Null
    } 'does not exist at packet-render time' (
        'Worker packets must reject missing local path inputs.'
    )

    $unsafePathPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unsafePathPlan.nodes[0].context.inputs = @(
        'ref:plan.goal',
        'path:../outside.md'
    )
    $unsafePathPlanPath = Join-Path $testRoot 'packet-unsafe-path-plan.json'
    $unsafePathPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $unsafePathPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $unsafePathPlanPath -NodeId 'draft' `
            -WorkspaceRoot $testRoot | Out-Null
    } 'unsafe path' (
        'Worker packets must reject traversal in local path inputs.'
    )

    # ConvertFrom-Json accepts some non-standard input. Parse every bundled
    # reference with System.Text.Json so strict consumers see valid JSON too.
    foreach ($jsonFile in Get-ChildItem -LiteralPath (
        Join-Path $skillRoot 'references'
    ) -Filter '*.json') {
        $strictJsonValid = $true
        $strictJsonError = ''
        $jsonDocument = $null
        try {
            $rawJson = Get-Content -LiteralPath $jsonFile.FullName -Raw
            $jsonDocument = [System.Text.Json.JsonDocument]::Parse($rawJson)
        }
        catch {
            $strictJsonValid = $false
            $strictJsonError = $_.Exception.Message
        }
        finally {
            if ($null -ne $jsonDocument) {
                $jsonDocument.Dispose()
            }
        }
        Assert-True $strictJsonValid (
            "Reference JSON '$($jsonFile.Name)' is not strict JSON: " +
            $strictJsonError
        )
    }

    $linkTarget = Join-Path $testRoot 'link-target.md'
    Set-Content -LiteralPath $linkTarget -Value 'link fixture target'
    $linkPath = Join-Path $testRoot 'linked-input.md'
    $linkCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $linkPath `
            -Target $linkTarget -ErrorAction Stop
        $linkCreated = $true
    }
    catch {
        Write-Host (
            'Symbolic-link fixture skipped: link creation is not permitted ' +
            'in this environment.'
        )
    }
    if ($linkCreated) {
        $linkedInputPlan = Get-Content -LiteralPath $examplePath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $linkedInputPlan.nodes[0].context.inputs = @(
            'ref:plan.goal',
            'path:linked-input.md'
        )
        $linkedInputPlanPath = Join-Path $testRoot (
            'packet-linked-input-plan.json'
        )
        $linkedInputPlan | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $linkedInputPlanPath
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
                -PlanPath $linkedInputPlanPath -NodeId 'draft' `
                -WorkspaceRoot $testRoot | Out-Null
        } 'crosses a link or reparse point' (
            'Worker packets must reject inputs that cross symbolic links.'
        )
    }

    $junctionTarget = Join-Path $testRoot 'junction-target'
    $null = New-Item -ItemType Directory -Path $junctionTarget -Force
    Set-Content -LiteralPath (
        Join-Path $junctionTarget 'payload.md'
    ) -Value 'junction fixture target'
    $junctionPath = Join-Path $testRoot 'junction-input'
    $junctionCreated = $false
    try {
        $null = New-Item -ItemType Junction -Path $junctionPath `
            -Target $junctionTarget -ErrorAction Stop
        $junctionCreated = $true
    }
    catch {
        Write-Host (
            'Junction fixture skipped: junction creation is not permitted ' +
            'in this environment.'
        )
    }
    if ($junctionCreated) {
        $junctionInputPlan = Get-Content -LiteralPath $examplePath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $junctionInputPlan.nodes[0].context.inputs = @(
            'ref:plan.goal',
            'path:junction-input/payload.md'
        )
        $junctionInputPlanPath = Join-Path $testRoot (
            'packet-junction-input-plan.json'
        )
        $junctionInputPlan | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $junctionInputPlanPath
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
                -PlanPath $junctionInputPlanPath -NodeId 'draft' `
                -WorkspaceRoot $testRoot | Out-Null
        } 'crosses a link or reparse point' (
            'Worker packets must reject inputs that cross Windows junctions.'
        )
    }

    $unownedArtifactPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unownedArtifactPlan.nodes[1].context.inputs = @(
        'artifact:artifacts/unowned/output.md',
        'ref:plan.completion'
    )
    $unownedArtifactPlanPath = Join-Path $testRoot (
        'packet-unowned-artifact-plan.json'
    )
    $unownedArtifactPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $unownedArtifactPlanPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $unownedArtifactPlanPath -NodeId 'review' `
            -WorkspaceRoot $testRoot | Out-Null
    } 'neither exists nor is produced by a declared dependency' (
        'Future artifact inputs must belong to a declared dependency write scope.'
    )

    $existingInputPath = Join-Path $testRoot 'bounded-input.md'
    'bounded input' | Set-Content -LiteralPath $existingInputPath
    $existingPathPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $existingPathPlan.nodes[0].context.inputs = @(
        'ref:plan.goal',
        'path:bounded-input.md'
    )
    $existingPathPlanPath = Join-Path $testRoot (
        'packet-existing-path-plan.json'
    )
    $existingPathPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $existingPathPlanPath
    $existingPathPacket = & (
        Join-Path $scriptRoot 'New-WorkerPacket.ps1'
    ) -PlanPath $existingPathPlanPath -NodeId 'draft' `
        -WorkspaceRoot $testRoot
    Assert-True ($existingPathPacket -like '*path:bounded-input.md*') (
        'A bounded existing project-relative path should render successfully.'
    )
    $startupRetryPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $startupRetryPlan.limits.retry_reserve = 0
    $startupRetryPlan.nodes[0].max_attempts = 2
    $startupRetryPlanPath = Join-Path $testRoot 'startup-retry-plan.json'
    $startupRetryPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $startupRetryPlanPath
    $startupRetryRun = Join-Path $testRoot 'startup-retry-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $startupRetryPlanPath -RunDirectory $startupRetryRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $startupPreviewPath = Join-Path $startupRetryRun (
        'receipts/draft-role-preview.md'
    )
    & (Join-Path $scriptRoot 'New-RoleActivationPreview.ps1') `
        -PlanPath $startupRetryPlanPath -NodeId 'draft' `
        -OutputPath $startupPreviewPath | Out-Null
    $startupActivation = & (
        Join-Path $scriptRoot 'New-ThreadActivationReservation.ps1'
    ) -RunDirectory $startupRetryRun -ActivationKey 'startup-attempt-1' `
        -SourceThreadId 'startup-source-thread' `
        -TaskSummary 'Materialize the draft worker.' `
        -RolePreviewPath $startupPreviewPath | ConvertFrom-Json -Depth 20
    $startupReconciliationInputPath = Join-Path $startupRetryRun (
        'startup-reconciliation-input.json'
    )
    [ordered]@{
        activation_key = 'startup-attempt-1'
        source_thread_id = 'startup-source-thread'
        task_summary = 'Materialize the draft worker.'
        window_start_utc = '2026-07-20T00:00:00Z'
        window_end_utc = '2026-07-20T00:00:45Z'
        reservation_path = $startupActivation.reservation_path
        create_call = [ordered]@{ status = 'error' }
        snapshots = @(
            [ordered]@{
                captured_at = '2026-07-20T00:00:01Z'
                threads = @()
            },
            [ordered]@{
                captured_at = '2026-07-20T00:00:45Z'
                threads = @()
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $startupReconciliationInputPath
    $startupReconciliationRelative = (
        'receipts/startup.thread-reconciliation.json'
    )
    & (Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1') `
        -InputPath $startupReconciliationInputPath `
        -OutputPath (
            Join-Path $startupRetryRun $startupReconciliationRelative
        ) | Out-Null
    $startupInputOriginal = Get-Content -LiteralPath (
        $startupReconciliationInputPath
    ) -Raw
    Add-Content -LiteralPath $startupReconciliationInputPath -Value ' '
    Assert-ThrowsLike {
        Read-ThreadReconciliationReceipt -Path (
            Join-Path $startupRetryRun $startupReconciliationRelative
        ) -RunDirectory $startupRetryRun -ExpectedDecision 'no_match' |
            Out-Null
    } 'input hash mismatch' (
        'A reconciliation receipt must remain bound to its raw list input.'
    )
    Set-Content -LiteralPath $startupReconciliationInputPath `
        -Value $startupInputOriginal -NoNewline
    $validStartupReceiptPath = Join-Path $startupRetryRun (
        $startupReconciliationRelative
    )
    $forgedStartupReceipt = Get-Content -LiteralPath $validStartupReceiptPath `
        -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $forgedStartupReceipt.activation_reservation_hash = '0' * 64
    $forgedStartupPayload = [ordered]@{
        schema_version = [string]$forgedStartupReceipt.schema_version
        reconciliation_input_path = (
            [string]$forgedStartupReceipt.reconciliation_input_path
        )
        reconciliation_input_hash = (
            [string]$forgedStartupReceipt.reconciliation_input_hash
        )
        activation_key = [string]$forgedStartupReceipt.activation_key
        activation_reservation_hash = (
            [string]$forgedStartupReceipt.activation_reservation_hash
        )
        source_thread_id = [string]$forgedStartupReceipt.source_thread_id
        task_summary_hash = [string]$forgedStartupReceipt.task_summary_hash
        window_start_utc = [string]$forgedStartupReceipt.window_start_utc
        window_end_utc = [string]$forgedStartupReceipt.window_end_utc
        create_call_status = [string]$forgedStartupReceipt.create_call_status
        returned_thread_id = $forgedStartupReceipt.returned_thread_id
        snapshot_count = [int]$forgedStartupReceipt.snapshot_count
        visibility_delay_seconds = (
            [double]$forgedStartupReceipt.visibility_delay_seconds
        )
        snapshot_captured_at = @($forgedStartupReceipt.snapshot_captured_at)
        matched_thread_ids = @($forgedStartupReceipt.matched_thread_ids)
        decision = [string]$forgedStartupReceipt.decision
        adopted_thread_id = $forgedStartupReceipt.adopted_thread_id
        adopted_host_id = $forgedStartupReceipt.adopted_host_id
        duplicate_thread_ids = @($forgedStartupReceipt.duplicate_thread_ids)
    }
    $forgedStartupReceipt.receipt_hash = Get-TextSha256 (
        $forgedStartupPayload | ConvertTo-Json -Compress -Depth 20
    )
    $forgedStartupReceiptPath = Join-Path $startupRetryRun (
        'receipts/forged.thread-reconciliation.json'
    )
    $forgedStartupReceipt | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $forgedStartupReceiptPath
    Assert-ThrowsLike {
        Read-ThreadReconciliationReceipt -Path $forgedStartupReceiptPath `
            -RunDirectory $startupRetryRun -ExpectedDecision 'no_match' |
            Out-Null
    } 'activation reservation hash mismatch' (
        'A self-consistent fake receipt cannot replace a real reservation.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'first startup reserved' `
        -IdempotencyKey 'startup-first-reserved' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'materializing' -Message 'first startup materializing' `
        -IdempotencyKey 'startup-first-materializing' | Out-Null
    Assert-ThrowsLike -Action {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $startupRetryRun -NodeId 'draft' -Status 'failed' `
            -Message 'ambiguous creation receipt' `
            -ErrorClass 'startup_unmaterialized' `
            -IdempotencyKey 'startup-ambiguous-failed' | Out-Null
    } -ExpectedMessage 'ReconciliationReceiptPath' -Message (
        'An ambiguous creation receipt must not authorize a duplicate launch.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' -Status 'failed' `
        -Message 'health probe confirmed no worker' `
        -ErrorClass 'startup_unmaterialized' `
        -ReconciliationReceiptPath $startupReconciliationRelative `
        -IdempotencyKey 'startup-first-failed' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'replacement startup reserved' `
        -IdempotencyKey 'startup-second-reserved' | Out-Null
    $startupRetryState = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $startupRetryRun | ConvertFrom-Json
    Assert-True ($startupRetryState.launch_attempts -eq 2) (
        'A confirmed unmaterialized startup should permit a replacement attempt.'
    )
    Assert-True ($startupRetryState.materialized_workers -eq 0) (
        'A reconciled no-match startup must not count as a materialized Worker.'
    )
    $fullPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'review' -WorkspaceRoot $testRoot -Full
    Assert-True ($packet.Length -lt ($fullPacket.Length * 0.75)) (
        'Default worker packet should be materially smaller than debug mode.'
    )
    $deltaRun = Join-Path $testRoot 'delta-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $deltaRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $threadId = if ($status -eq 'materialized') {
            'delta-failed-thread'
        } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $deltaRun -NodeId 'draft' -Status $status `
            -Message "delta retry $status" -ThreadId $threadId -ModelId $modelId `
            -IdempotencyKey "delta-retry-1-$status" | Out-Null
    }
    [ordered]@{
        schema_version = '1.0'
        node_id = 'draft'
        action_key = 'draft-output-validation'
        input_refs = @('test:draft-schema-v1')
        repair_instruction = 'Repair the draft schema failure.'
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $deltaRun 'delta-premise.json')
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $deltaRun -NodeId 'draft' -Status 'failed' `
        -Message 'draft output failed validation' -ErrorClass 'output_invalid' `
        -ActionKey 'draft-output-validation' `
        -PremiseManifestPath 'delta-premise.json' `
        -FailureCode 'schema.invalid' `
        -IdempotencyKey 'delta-retry-1-failed' | Out-Null
    $deltaPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'draft' -WorkspaceRoot $testRoot `
        -RetryOutputRef 'artifact:artifacts/draft/output.md' `
        -FailureEvidence 'test:draft-schema-failed' `
        -RepairInstruction 'Add the missing failure-handling section.' `
        -RetryRunDirectory $deltaRun
    Assert-True ($deltaPacket.Length -lt ($packet.Length * 0.65)) (
        'Delta retry should be materially smaller than the initial packet.'
    )
    Assert-True ($deltaPacket -notlike '*Read only these references:*') (
        'Delta retry should not replay the original context list.'
    )
    $unboundDeltaCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $examplePath -NodeId 'draft' -WorkspaceRoot $testRoot `
            -RetryOutputRef 'artifact:artifacts/draft/output.md' `
            -FailureEvidence 'test:draft-schema-failed' `
            -RepairInstruction 'Add the missing failure-handling section.' |
            Out-Null
    }
    catch {
        $unboundDeltaCaught = $_.Exception.Message -like (
            '*requires RetryRunDirectory*'
        )
    }
    Assert-True $unboundDeltaCaught (
        'Delta retry must bind to a real failed execution.'
    )

    $retryGuardPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $retryGuardPlan.run_id = 'retry-guard-001'
    $retryGuardPlan.nodes[0].max_attempts = 2
    $retryGuardPlan.limits.max_attempts_per_node = 2
    $retryGuardPlan.limits.retry_reserve = 1
    $retryGuardPlanPath = Join-Path $testRoot 'retry-guard-plan.json'
    $retryGuardPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $retryGuardPlanPath
    $retryGuardRun = Join-Path $testRoot 'retry-guard-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $retryGuardPlanPath -RunDirectory $retryGuardRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $threadId = if ($status -eq 'materialized') {
            'retry-guard-thread-1'
        } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $retryGuardRun -NodeId 'draft' -Status $status `
            -Message "retry guard $status" -ThreadId $threadId `
            -ModelId $modelId -IdempotencyKey "retry-guard-$status" |
            Out-Null
    }
    [ordered]@{
        schema_version = '1.0'
        node_id = 'draft'
        action_key = 'draft-schema-validation'
        input_refs = @(
            'artifact:artifacts/draft/output.md',
            'test:draft-schema-failed'
        )
        repair_instruction = 'Add the missing required section.'
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (
            Join-Path $retryGuardRun 'guard-premise.json'
        )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $retryGuardRun -NodeId 'draft' -Status 'failed' `
            -Message 'deterministic failure without fingerprint' `
            -ErrorClass 'output_invalid' -IdempotencyKey 'guard-missing' |
            Out-Null
    } 'require ActionKey' (
        'Deterministic failures must provide stable action and premise data.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $retryGuardRun -NodeId 'draft' -Status 'failed' `
        -Message 'deterministic output failure' `
        -ErrorClass 'output_invalid' -ActionKey 'draft-schema-validation' `
        -PremiseManifestPath 'guard-premise.json' `
        -FailureCode 'schema.missing-section' `
        -IdempotencyKey 'retry-guard-failed' | Out-Null
    [ordered]@{
        repair_instruction = '  Add  the missing required section.  '
        input_refs = @(
            ' test:draft-schema-failed ',
            ' artifact:artifacts/draft/output.md '
        )
        action_key = ' draft-schema-validation '
        node_id = 'draft'
        schema_version = '1.0'
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (
            Join-Path $retryGuardRun 'same-guard-premise.json'
        )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $retryGuardRun -NodeId 'draft' `
            -Status 'launch_reserved' -Message 'repeat same failed repair' `
            -ActionKey ' draft-schema-validation ' `
            -PremiseManifestPath 'same-guard-premise.json' `
            -IdempotencyKey 'retry-guard-blocked' | Out-Null
    } 'Retry after a deterministic failure requires explicit authorization' (
        'A deterministic failure must not launch again without user authorization.'
    )
    $guardFailure = Get-Content -LiteralPath (
        Join-Path $retryGuardRun 'events.jsonl'
    ) | Select-Object -Last 1 | ConvertFrom-Json -Depth 20
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $retryGuardRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'authorized retry' `
        -ActionKey 'draft-schema-validation' `
        -PremiseManifestPath 'guard-premise.json' `
        -RetryAuthorization "user:$($guardFailure.hash)" `
        -IdempotencyKey 'retry-guard-authorized' | Out-Null
    $authorizedEvent = Get-Content -LiteralPath (
        Join-Path $retryGuardRun 'events.jsonl'
    ) | Select-Object -Last 1 | ConvertFrom-Json -Depth 20
    Assert-True (
        "source:retry-authorization:user:$($guardFailure.hash)" -in
        @($authorizedEvent.evidence)
    ) 'Explicit user retry authorization must be journaled and hash-bound.'

    $crowdedFirstWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $crowdedFirstWave.nodes[1].wave = 1
    Assert-InvalidPlan $crowdedFirstWave 'crowded-first-wave' (
        "must be in a later wave than dependency 'draft'"
    )

    $twoWorkerFirstWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $twoWorkerFirstWave.mode = 'team'
    $twoWorkerFirstWave.nodes[1].wave = 1
    $twoWorkerFirstWave.nodes[1].depends_on = @()
    $twoWorkerFirstWave.nodes[1].context.inputs = @(
        'source:independent-review-rules'
    )
    $twoWorkerFirstWave.nodes[2].depends_on = @('draft', 'review')
    $twoWorkerPlanPath = Join-Path $testRoot 'two-worker-first-wave.json'
    $twoWorkerFirstWave | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $twoWorkerPlanPath
    $twoWorkerValid = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $twoWorkerPlanPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $twoWorkerValid.valid (
        'Two ready Wave 1 workers with disjoint context should be valid.'
    )

    $missingMainOwner = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingMainOwner.nodes = @(
        $missingMainOwner.nodes | Where-Object { $_.kind -ne 'main' }
    )
    $missingMainOwner.completion.required_nodes = @('draft', 'review')
    $missingMainOwner.completion.evidence_checks = @(
        $missingMainOwner.completion.evidence_checks |
            Where-Object { $_.node_id -ne 'integrate' }
    )
    Assert-InvalidPlan $missingMainOwner 'missing-main-owner' (
        'requires a substantive main-agent node'
    )

    $missingRoleActivation = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingRoleActivation.nodes[0].Remove('role_activation')
    Assert-InvalidPlan $missingRoleActivation 'missing-role-activation' (
        'requires role_activation'
    )

    $invalidRoleDisposition = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidRoleDisposition.nodes[0].role_activation.user_disposition = 'assumed'
    Assert-InvalidPlan $invalidRoleDisposition 'invalid-role-disposition' (
        'must be approved or auto-authorized'
    )

    $missingAuthorizationEvidence = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingAuthorizationEvidence.nodes[0].role_activation.Remove(
        'authorization_evidence'
    )
    Assert-InvalidPlan $missingAuthorizationEvidence (
        'missing-authorization-evidence'
    ) 'requires non-empty authorization_evidence'

    $wrongAuthorizationEvidence = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $wrongAuthorizationEvidence.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    Assert-InvalidPlan $wrongAuthorizationEvidence (
        'wrong-authorization-evidence'
    ) 'requires authorization_evidence formatted as policy:path:<file>'

    $missingAuthorizationPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingAuthorizationPolicy.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    $missingAuthorizationPolicy.nodes[0].role_activation.authorization_evidence = (
        'policy:path:missing-policy.md'
    )
    Assert-InvalidPlan $missingAuthorizationPolicy (
        'missing-authorization-policy'
    ) 'authorization policy does not exist'

    $validAuthorizationPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $validAuthorizationPolicy.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    $validAuthorizationPolicy.nodes[0].role_activation.authorization_evidence = (
        'policy:path:SKILL.md'
    )
    $validAuthorizationPolicyPath = Join-Path $testRoot (
        'valid-authorization-policy.json'
    )
    $validAuthorizationPolicy | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $validAuthorizationPolicyPath
    $validAuthorizationResult = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $validAuthorizationPolicyPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $validAuthorizationResult.valid (
        'Auto-authorization should accept a real project policy file.'
    )
    $missingWorkspaceRootCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $validAuthorizationPolicyPath | Out-Null
    }
    catch {
        $missingWorkspaceRootCaught = $_.Exception.Message -like (
            '*requires -WorkspaceRoot to verify its policy*'
        )
    }
    Assert-True $missingWorkspaceRootCaught (
        'Auto-authorization must not validate without a policy workspace root.'
    )

    $validManuscript = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $validManuscript.manuscript_profile = @{
        mode = 'coauthoring'
        lead_author_node_id = 'integrate'
        lead_author_owns = @(
            'argument-spine', 'abstract', 'conclusion', 'final-merge'
        )
    }
    $validManuscript.nodes[0].manuscript_contribution = @{
        mode = 'co-author'
        section_scope = 'Architecture methods section'
    }
    $validManuscript.nodes[1].manuscript_contribution = @{
        mode = 'independent-review'
    }
    $validManuscriptPath = Join-Path $testRoot 'valid-manuscript.json'
    $validManuscript | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $validManuscriptPath
    $validManuscriptResult = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $validManuscriptPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $validManuscriptResult.valid (
        'A bounded co-author plus independent reviewer manuscript should pass.'
    )

    $reviewOnlyCoauthoring = Get-Content -LiteralPath (
        $validManuscriptPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $reviewOnlyCoauthoring.nodes[0].manuscript_contribution = @{
        mode = 'research'
    }
    Assert-InvalidPlan $reviewOnlyCoauthoring 'review-only-coauthoring' (
        'requires at least one co-author'
    )

    $readOnlyCoauthor = Get-Content -LiteralPath $validManuscriptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $readOnlyCoauthor.nodes[1].manuscript_contribution = @{
        mode = 'co-author'
        section_scope = 'Review-authored methods section'
    }
    Assert-InvalidPlan $readOnlyCoauthor 'read-only-manuscript-coauthor' (
        'must use a proposal-only or scoped-write role'
    )

    $excessWorkerLimit = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $excessWorkerLimit.limits.max_total_agent_nodes = 9
    Assert-InvalidPlan $excessWorkerLimit 'excess-worker-limit' (
        'max_total_agent_nodes must be between 1 and 8'
    )

    $unresolvedAuto = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unresolvedAuto.mode = 'auto'
    Assert-InvalidPlan $unresolvedAuto 'unresolved-auto-mode' (
        'mode auto must be resolved'
    )

    $oversizedQuick = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $oversizedQuick.mode = 'quick'
    Assert-InvalidPlan $oversizedQuick 'oversized-quick-mode' (
        'quick mode allows at most one agent node'
    )

    $dependentTeam = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $dependentTeam.mode = 'team'
    Assert-InvalidPlan $dependentTeam 'dependent-team-mode' (
        'team mode requires independent agent workstreams'
    )

    $multiWriterTeam = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $multiWriterTeam.mode = 'team'
    $multiWriterTeam.nodes[1].depends_on = @()
    $multiWriterTeam.nodes[1].context.inputs = @(
        'source:independent-security-advisory'
    )
    $multiWriterTeam.nodes[1].read_only = $false
    $multiWriterTeam.nodes[1].write_scope = @('artifacts/review')
    Assert-InvalidPlan $multiWriterTeam 'multi-writer-team-mode' (
        'team mode cannot carry workflow-only'
    )

    $emptyWorkflow = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $emptyWorkflow.nodes[0].topology = 'native-subagent'
    $emptyWorkflow.nodes[1].depends_on = @()
    $emptyWorkflow.nodes[1].context.inputs = @(
        'source:independent-security-advisory'
    )
    Assert-InvalidPlan $emptyWorkflow 'workflow-without-durable-reason' (
        'workflow mode requires recovery'
    )

    $profileMismatch = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $profileMismatch.efficiency.profile = 'balanced'
    Assert-InvalidPlan $profileMismatch 'profile-review-mismatch' (
        "requires review_strategy 'sampled'"
    )

    $unauthorizedTerra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unauthorizedTerra.nodes[0].model = 'gpt-5.6-terra'
    Assert-InvalidPlan $unauthorizedTerra 'unauthorized-terra' (
        'experimental-user-request authorization'
    )

    $selfAuthorizedTerra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $selfAuthorizedTerra.nodes[0].model = 'gpt-5.6-terra'
    $selfAuthorizedTerra.nodes[0].model_authorization =
        'experimental-user-request'
    Assert-InvalidPlan $selfAuthorizedTerra 'self-authorized-terra' (
        'model authorization requires user: evidence'
    )

    $unconfirmedEconomySol = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unconfirmedEconomySol.nodes[0].capability = 'economy'
    Assert-InvalidPlan $unconfirmedEconomySol 'unconfirmed-economy-sol' (
        'requires confirmed escalation'
    )

    $selfAuthorizedEconomySol = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $selfAuthorizedEconomySol.nodes[0].capability = 'economy'
    $selfAuthorizedEconomySol.nodes[0].model_authorization = 'user-confirmed'
    Assert-InvalidPlan $selfAuthorizedEconomySol 'self-authorized-economy-sol' (
        'model authorization requires user: evidence'
    )

    $missingResolvedModel = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingResolvedModel.nodes[0].Remove('model')
    Assert-InvalidPlan $missingResolvedModel 'missing-resolved-model' (
        'requires non-empty model'
    )

    $overlappingContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $overlappingContext.nodes[1].context.inputs =
        @($overlappingContext.nodes[0].context.inputs)
    Assert-InvalidPlan $overlappingContext 'overlapping-context' (
        'Context overlap'
    )

    $untypedContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $untypedContext.nodes[0].context.inputs = @('Plan goal')
    Assert-InvalidPlan $untypedContext 'untyped-context' (
        'context inputs must be typed references'
    )

    $broadContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $broadContext.nodes[0].context.inputs = @('path:.')
    Assert-InvalidPlan $broadContext 'broad-context' (
        'uses broad context reference'
    )

    $missingSelectionReason = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingSelectionReason.nodes[0].context.Remove('selection_reason')
    $missingSelectionReasonPath = Join-Path $testRoot 'optional-selection-reason.json'
    $missingSelectionReason | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $missingSelectionReasonPath
    $optionalSelectionReason = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $missingSelectionReasonPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $optionalSelectionReason.valid (
        'selection_reason should remain optional controller metadata.'
    )

    $unneededHandoffFields = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unneededHandoffFields.nodes[1].context.handoff_path =
        'artifacts/handoffs/unneeded.json'
    $unneededHandoffFields.nodes[1].context.handoff_max_chars = 2000
    Assert-InvalidPlan $unneededHandoffFields 'unneeded-handoff-fields' (
        'without handoff_required cannot set'
    )

    $weakOverlapPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $weakOverlapPolicy.efficiency.max_context_overlap_ratio = 0.9
    Assert-InvalidPlan $weakOverlapPolicy 'weak-overlap-policy' (
        'cannot exceed 0.5'
    )

    $unearnedNextWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unearnedNextWave.nodes[1].depends_on = @()
    Assert-InvalidPlan $unearnedNextWave 'unearned-next-wave' (
        'must depend on an earlier adopted result or own disjoint context'
    )

    $disjointNextWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $disjointNextWave.nodes[1].depends_on = @()
    $disjointNextWave.nodes[1].context.inputs = @(
        'source:independent-security-advisory'
    )
    $disjointNextWavePath = Join-Path $testRoot 'disjoint-next-wave.json'
    $disjointNextWave | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $disjointNextWavePath
    $disjointEfficiency = & (
        Join-Path $scriptRoot 'Test-OrchestrationEfficiency.ps1'
    ) -PlanPath $disjointNextWavePath | ConvertFrom-Json
    Assert-True $disjointEfficiency.valid (
        'A later worker with truly disjoint context should not need a fake dependency.'
    )
    $disjointWaveRun = Join-Path $testRoot 'disjoint-wave-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $disjointNextWavePath -RunDirectory $disjointWaveRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $earlyDisjointWaveCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $disjointWaveRun -NodeId 'review' `
            -Status 'launch_reserved' -Message 'start wave 2 too early' `
            -IdempotencyKey 'disjoint-wave-too-early' | Out-Null
    }
    catch {
        $earlyDisjointWaveCaught = $_.Exception.Message -like (
            '*cannot start before earlier-wave node*'
        )
    }
    Assert-True $earlyDisjointWaveCaught (
        'Disjoint context must not let a later wave bypass progressive dispatch.'
    )

    $fullRetryPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $fullRetryPolicy.efficiency.retry_strategy = 'full'
    Assert-InvalidPlan $fullRetryPolicy 'full-retry-policy' (
        'retry_strategy must be delta'
    )

    $missingDependency = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingDependency.nodes[1].depends_on = @('does-not-exist')
    Assert-InvalidPlan $missingDependency 'missing-dependency' 'depends on missing node'

    $recursiveWorker = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $recursiveWorker.nodes[0].allow_delegation = $true
    Assert-InvalidPlan $recursiveWorker 'recursive-worker' 'allow_delegation'

    $unjustifiedUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unjustifiedUltra.nodes[1].capability = 'ultra'
    Assert-InvalidPlan $unjustifiedUltra 'unjustified-ultra' 'requires ultra_reason'

    $automaticUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $automaticUltra.nodes[1].capability = 'ultra'
    $automaticUltra.nodes[1].effort = 'ultra'
    $automaticUltra.nodes[1].ultra_reason = 'A cheaper attempt failed.'
    $automaticUltra.nodes[1].ultra_authorization = 'escalated-after-failure'
    $automaticUltra.nodes[1].prior_attempt_node_id = 'draft'
    Assert-InvalidPlan $automaticUltra 'automatic-ultra' 'user-requested'

    $economyUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $economyUltra.nodes[1].capability = 'ultra'
    $economyUltra.nodes[1].effort = 'ultra'
    $economyUltra.nodes[1].ultra_reason = 'The user explicitly requested it.'
    $economyUltra.nodes[1].ultra_authorization = 'user-requested'
    $economyUltra.nodes[1].model_authorization = 'user-confirmed'
    $economyUltra.nodes[1].model_authorization_evidence =
        'user:explicit-ultra-test-request'
    Assert-InvalidPlan $economyUltra 'economy-ultra' 'Lean profile forbids Ultra'

    $overlappingWriters = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $overlappingWriters.nodes[1].read_only = $false
    $overlappingWriters.nodes[1].write_scope = @('artifacts')
    Assert-InvalidPlan $overlappingWriters 'overlapping-writers' 'Write scope overlap'

    $pathTraversal = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $pathTraversal.nodes[0].write_scope = @('artifacts/../secrets')
    Assert-InvalidPlan $pathTraversal 'path-traversal' "cannot traverse with '..'"

    $controlPlaneWriter = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $controlPlaneWriter.nodes[0].write_scope = @('.orchestrator/knowledge')
    Assert-InvalidPlan $controlPlaneWriter 'control-plane-writer' (
        'cannot target control-plane state'
    )

    $mainControlPlaneWriter = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $mainControlPlaneWriter.nodes[2].write_scope = @(
        '.orchestrator/knowledge'
    )
    Assert-InvalidPlan $mainControlPlaneWriter 'main-control-plane-writer' (
        'cannot target control-plane state'
    )

    $invalidGate = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidGate.nodes += @{
        id = 'approve'
        kind = 'human-gate'
        depends_on = @('review')
        question = 'Publish now?'
        choices = @('publish', 'stop')
        default_safe_action = 'publish'
        action_class = 'external-write'
    }
    $invalidGate.completion.required_nodes += 'approve'
    Assert-InvalidPlan $invalidGate 'invalid-gate' 'must default to stop'

    $mainOverlap = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $mainOverlap.nodes[2].write_scope = @('artifacts')
    Assert-InvalidPlan $mainOverlap 'main-overlap' 'Write scope overlap'

    $roleWriteEscalation = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $roleWriteEscalation.nodes[1].read_only = $false
    $roleWriteEscalation.nodes[1].write_scope = @('artifacts/reviewer-write')
    Assert-InvalidPlan $roleWriteEscalation 'role-write-escalation' (
        "cannot write under role 'adversarial-reviewer'"
    )

    $trailingDotScope = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $trailingDotScope.nodes[0].write_scope = @('artifacts/draft.')
    Assert-InvalidPlan $trailingDotScope 'trailing-dot-scope' 'Windows path alias'

    $emptyArtifactThreshold = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $emptyArtifactThreshold.completion.artifact_checks[0].minimum_items = 0
    Assert-InvalidPlan $emptyArtifactThreshold 'empty-artifact-threshold' (
        'minimum_items >= 1'
    )

    $missingContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingContext.nodes[0].Remove('context')
    Assert-InvalidPlan $missingContext 'missing-context' 'context.session_policy'

    $nativeReuse = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $nativeReuse.nodes[1].context.session_policy = 'reuse'
    $nativeReuse.nodes[1].context.max_prior_turns = 2
    $nativeReuse.nodes[1].context.prior_thread_id = 'old-thread'
    $nativeReuse.nodes[1].context.prior_handoff = 'artifacts/handoffs/old.json'
    $nativeReuse.nodes[1].context.reuse_reason = 'same workstream'
    Assert-InvalidPlan $nativeReuse 'native-reuse' 'Only background-thread'

    $reuseWithoutHash = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $reuseWithoutHash.nodes[0].context.session_policy = 'reuse'
    $reuseWithoutHash.nodes[0].context.max_prior_turns = 2
    $reuseWithoutHash.nodes[0].context.prior_thread_id = 'old-thread'
    $reuseWithoutHash.nodes[0].context.prior_handoff = 'artifacts/handoffs/old.json'
    $reuseWithoutHash.nodes[0].context.reuse_reason = 'same bounded workstream'
    Assert-InvalidPlan $reuseWithoutHash 'reuse-without-hash' 'prior_handoff_hash'

    $freshWithReuseField = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshWithReuseField.nodes[0].context.reuse_reason = 'stale context'
    Assert-InvalidPlan $freshWithReuseField 'fresh-with-reuse-field' (
        'cannot set context.reuse_reason'
    )

    $missingRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingRole.nodes[0].role_id = 'does-not-exist'
    Assert-InvalidPlan $missingRole 'missing-role' 'references missing role'

    $invalidRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidRole.roles[0].non_goals = @()
    Assert-InvalidPlan $invalidRole 'invalid-role' 'non_goals'

    $invalidLifetime = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidLifetime.roles[0].lifetime = 'forever'
    Assert-InvalidPlan $invalidLifetime 'invalid-role-lifetime' (
        'lifetime must be task, project, or user-owned'
    )

    $unownedUserRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unownedUserRole.roles[0].lifetime = 'user-owned'
    Assert-InvalidPlan $unownedUserRole 'unowned-user-role' (
        'user-owned lifetime requires user_defined true'
    )

    $generatedRole = & (Join-Path $scriptRoot 'New-AgentRole.ps1') `
        -Id 'inventory-auditor' -DisplayName 'Inventory Auditor' `
        -Mission 'Find unsupported inventory claims.' `
        -Responsibilities @('Inspect evidence') -NonGoals @('Modify production data') `
        -RequiredInputs @('Inventory report') -Deliverables @('Finding list') `
        -EvidenceRules @('Cite each source row') -ToolPolicy 'read-only' `
        -Lifetime 'user-owned' `
        -EscalationConditions @('Source data is missing') `
        -IdentityStatement 'You are an evidence-first inventory auditor.' `
        -UserDefined | ConvertFrom-Json
    Assert-True ($generatedRole.id -eq 'inventory-auditor') (
        'Role generator should preserve the requested id.'
    )
    Assert-True $generatedRole.user_defined (
        'Role generator should mark a custom role as user-defined.'
    )
    Assert-True ($generatedRole.lifetime -eq 'user-owned') (
        'Role generator should preserve the requested lifetime.'
    )

    $durableReviewPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $durableReviewPlan.roles[1].lifetime = 'project'
    $domainRole = @{}
    foreach ($entry in $durableReviewPlan.roles[1].GetEnumerator()) {
        $domainRole[$entry.Key] = $entry.Value
    }
    $domainRole.id = 'domain-specialist'
    $domainRole.display_name = 'Domain Specialist'
    $domainRole.mission = 'Maintain reusable domain evidence across milestones.'
    $domainRole.identity_statement = (
        'I maintain domain evidence and do not edit or approve project output.'
    )
    $durableReviewPlan.roles += $domainRole
    $durableReviewPlan.nodes[1].topology = 'background-thread'
    $durableReviewPlan.nodes[1].context.continuity_key =
        'durable-adversarial-review'
    $durableReviewPlan.nodes[0].read_only = $true
    $durableReviewPlan.nodes[0].write_scope = @()
    $domainNode = @{}
    foreach ($entry in $durableReviewPlan.nodes[1].GetEnumerator()) {
        $domainNode[$entry.Key] = $entry.Value
    }
    $domainNode.id = 'domain-research'
    $domainNode.role_id = 'domain-specialist'
    $domainNode.purpose = 'research'
    $domainNode.task = 'Maintain domain evidence for each named milestone.'
    $domainNode.context = @{}
    foreach ($entry in $durableReviewPlan.nodes[1].context.GetEnumerator()) {
        $domainNode.context[$entry.Key] = $entry.Value
    }
    $domainNode.context.continuity_key = 'durable-domain-research'
    $domainNode.context.inputs = @('source:domain-evidence')
    $domainNode.context.excluded = @('Implementation reasoning')
    $durableReviewPlan.nodes += $domainNode
    $durableReviewPlan.nodes[2].depends_on = @('review', 'domain-research')
    $durableReviewPlan.completion.required_nodes += 'domain-research'
    $durableReviewPlan.completion.review_disposition_checks = @(
        @{
            source_node_id = 'review'
            path = 'receipts/review.disposition.json'
            blocking_severities = @('P0', 'P1')
        },
        @{
            source_node_id = 'domain-research'
            path = 'receipts/domain-research.disposition.json'
            blocking_severities = @('P0', 'P1')
        }
    )
    $durableReviewPlan.durable_review_profile = @{
        mode = 'domain-dissent'
        main_owner_node_id = 'integrate'
        domain_node_ids = @('domain-research')
        dissent_node_ids = @('review')
        milestone_ids = @('method-1', 'method-2')
        consumer_output = 'result-only'
    }
    $durableReviewPlanPath = Join-Path $testRoot 'durable-review-plan.json'
    $durableReviewPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $durableReviewPlanPath
    $durableReviewValidation = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $durableReviewPlanPath -WorkspaceRoot $testRoot |
        ConvertFrom-Json
    Assert-True $durableReviewValidation.valid (
        'A bounded durable domain-and-dissent profile should validate.'
    )

    $weakDurableReviewRoute = Get-Content `
        -LiteralPath $durableReviewPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $weakDurableReviewRoute.nodes[-1].capability = 'standard'
    $weakDurableReviewRoute.nodes[-1].model = 'gpt-5.6-luna'
    $weakDurableReviewRoute.nodes[-1].effort = 'max'
    Assert-InvalidPlan $weakDurableReviewRoute (
        'durable-review-weak-model-route'
    ) 'requires strong Sol review routing'

    $missingDurableDisposition = Get-Content `
        -LiteralPath $durableReviewPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingDurableDisposition.completion.review_disposition_checks = @(
        $missingDurableDisposition.completion.review_disposition_checks[0]
    )
    Assert-InvalidPlan $missingDurableDisposition (
        'durable-review-missing-disposition'
    ) 'requires a completion review disposition check'

    $sharedDurableDisposition = Get-Content `
        -LiteralPath $durableReviewPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $sharedDurableDisposition.completion.review_disposition_checks[1].path =
        $sharedDurableDisposition.completion.review_disposition_checks[0].path
    Assert-InvalidPlan $sharedDurableDisposition (
        'durable-review-shared-disposition'
    ) 'Each source role requires its own receipt'

    $narrowDurableBlocking = Get-Content `
        -LiteralPath $durableReviewPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $narrowDurableBlocking.completion.review_disposition_checks[0].blocking_severities =
        @('P0')
    Assert-InvalidPlan $narrowDurableBlocking (
        'durable-review-narrow-blocking'
    ) 'must always block P0 and P1'

    $writableDurableProducer = Get-Content `
        -LiteralPath $durableReviewPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $writableDurableProducer.nodes[0].read_only = $false
    $writableDurableProducer.nodes[0].write_scope = @('artifacts/draft')
    Assert-InvalidPlan $writableDurableProducer (
        'durable-review-writable-producer'
    ) 'only its main owner may write'

    $writableDurableReviewer = Get-Content -LiteralPath (
        $durableReviewPlanPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $writableDurableReviewer.nodes[1].read_only = $false
    $writableDurableReviewer.nodes[1].write_scope = @('review-output')
    Assert-InvalidPlan $writableDurableReviewer (
        'durable-review-writable-worker'
    ) 'must be a read-only background-thread agent'

    $shortLivedDurableReviewer = Get-Content -LiteralPath (
        $durableReviewPlanPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $shortLivedDurableReviewer.roles[1].lifetime = 'task'
    Assert-InvalidPlan $shortLivedDurableReviewer (
        'durable-review-task-lifetime'
    ) 'requires a project or user-owned role lifetime'

    $internalDebateOutput = Get-Content -LiteralPath (
        $durableReviewPlanPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $internalDebateOutput.durable_review_profile.consumer_output =
        'include-internal-debate'
    Assert-InvalidPlan $internalDebateOutput (
        'durable-review-consumer-output'
    ) 'consumer_output must be result-only'

    $duplicateMilestones = Get-Content -LiteralPath (
        $durableReviewPlanPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $duplicateMilestones.durable_review_profile.milestone_ids = @(
        'method-1', 'method-1'
    )
    Assert-InvalidPlan $duplicateMilestones (
        'durable-review-duplicate-milestone'
    ) 'milestone_ids must be unique safe IDs'

    $unsafeMilestones = Get-Content -LiteralPath (
        $durableReviewPlanPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $unsafeMilestones.durable_review_profile.milestone_ids = @(
        'method-1', '../method-2'
    )
    Assert-InvalidPlan $unsafeMilestones (
        'durable-review-unsafe-milestone'
    ) 'milestone_ids must be unique safe IDs'

    $illegalTransitionCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'adopted' `
            -Message 'skip every gate' -IdempotencyKey 'review-skip-adopted' |
            Out-Null
    }
    catch {
        $illegalTransitionCaught = $_.Exception.Message -like '*Illegal state transition*'
    }
    Assert-True $illegalTransitionCaught 'Illegal state transition should be rejected.'

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'materializing' `
        -Message 'review materializing' `
        -IdempotencyKey 'review-1-materializing' | Out-Null
    $freshReuseCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'materialized' `
            -Message 'reuse draft thread' -ThreadId 'test-thread-draft' `
            -ModelId 'gpt-5.6-sol' `
            -IdempotencyKey 'review-reused-thread' | Out-Null
    }
    catch {
        $freshReuseCaught = $_.Exception.Message -like '*cannot reuse thread*'
    }
    Assert-True $freshReuseCaught 'Fresh nodes must not reuse another node thread.'
    foreach ($status in @('materialized', 'running', 'completed', 'validated')) {
        $threadId = if ($status -eq 'materialized') { 'test-thread-review' } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        $evidence = if ($status -eq 'completed') {
            @('observation:Review contains reproducible failure scenarios.')
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 700 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 400 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status $status `
            -Message "review $status" -ThreadId $threadId -ModelId $modelId `
            -Evidence $evidence `
            -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "review-1-$status" | Out-Null
    }
    $unneededHandoffCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' `
            -Summary ('x' * 5000) `
            -Evidence @('observation:Review contains reproducible failure scenarios.') `
            -RiskDisposition 'none' `
            -NextAction 'Return the finding.' | Out-Null
    }
    catch {
        $unneededHandoffCaught = $_.Exception.Message -like '*does not require a handoff*'
    }
    Assert-True $unneededHandoffCaught (
        'A node without handoff_required must not create a handoff artifact.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'adopted' `
        -Message 'adopted because the findings close the verification gap' `
        -IdempotencyKey 'review-1-adopted' | Out-Null
    foreach ($status in @('running', 'completed', 'validated')) {
        $evidence = if ($status -eq 'completed') {
            @('observation:Every review finding has a recorded disposition.')
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 500 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 600 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'integrate' -Status $status `
            -Message "integrate $status" -Evidence $evidence `
            -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "integrate-1-$status" | Out-Null
    }
    $missingArtifactCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $missingArtifactCaught = $_.Exception.Message -like '*artifact is missing*'
    }
    Assert-True $missingArtifactCaught (
        'Completion must fail when a required artifact is missing.'
    )
    $finalDirectory = Join-Path $testRoot 'artifacts/final'
    $null = New-Item -ItemType Directory -Path $finalDirectory
    $emptyDirectoryCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $emptyDirectoryCaught = $_.Exception.Message -like '*fewer than minimum_items*'
    }
    Assert-True $emptyDirectoryCaught (
        'Completion must fail when a required artifact directory is empty.'
    )
    'validated proposal' | Set-Content -LiteralPath (
        Join-Path $finalDirectory 'proposal.md'
    )
    $missingReceiptPath = "$draftReceiptPath.missing"
    Move-Item -LiteralPath $draftReceiptPath -Destination $missingReceiptPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    } 'result receipt does not exist' (
        'Completion must reject a missing background-thread result receipt.'
    )
    Move-Item -LiteralPath $missingReceiptPath -Destination $draftReceiptPath
    $receiptOriginal = Get-Content -LiteralPath $draftReceiptPath -Raw
    $receiptTampered = $receiptOriginal |
        ConvertFrom-Json -AsHashtable -Depth 20
    $receiptTampered.host_id = 'silently-replaced-host'
    $receiptTampered | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $draftReceiptPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    } 'receipt hash mismatch' (
        'Completion must reject a tampered background-thread result receipt.'
    )
    Set-Content -LiteralPath $draftReceiptPath -Value $receiptOriginal
    $captureOriginal = Get-Content -LiteralPath $draftReadPath -Raw
    $captureTampered = $captureOriginal |
        ConvertFrom-Json -AsHashtable -Depth 20
    $captureTampered.turns[0].items[0].text = 'silently replaced final answer'
    $captureTampered | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $draftReadPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    } 'does not match its read-thread capture' (
        'Completion must reject a result capture changed after receipt creation.'
    )
    Set-Content -LiteralPath $draftReadPath -Value $captureOriginal -NoNewline
    $resolvedDispositionBackup = "$resolvedDispositionPath.resolved"
    Move-Item -LiteralPath $resolvedDispositionPath `
        -Destination $resolvedDispositionBackup
    Move-Item -LiteralPath $openDispositionPath `
        -Destination $resolvedDispositionPath
    $openReviewGateError = ''
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    } catch {
        $openReviewGateError = $_.Exception.Message
    }
    Assert-True ($openReviewGateError -like '*unresolved P1:*') (
        'Completion must block an unresolved P0/P1 review finding. Actual: ' +
        $openReviewGateError
    )
    Move-Item -LiteralPath $resolvedDispositionPath `
        -Destination $openDispositionPath
    Move-Item -LiteralPath $resolvedDispositionBackup `
        -Destination $resolvedDispositionPath
    $completion = & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
        -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True $completion.complete (
        'Completion gate should pass only after nodes, artifacts, and evidence pass.'
    )
    $taskReceiptPath = Join-Path $runDirectory (
        'receipts/final.task-completion-receipt.json'
    )
    $taskReceipt = & (
        Join-Path $scriptRoot 'New-OrchestrationTaskReceipt.ps1'
    ) -RunDirectory $runDirectory -Outcome completed `
        -Summary 'All required nodes and artifacts passed acceptance.' `
        -OutputPath $taskReceiptPath | ConvertFrom-Json -Depth 20
    $verifiedTaskReceipt = Read-OrchestrationTaskReceipt `
        -Path $taskReceiptPath -RunDirectory $runDirectory
    Assert-True (
        $taskReceipt.outcome -eq 'completed' -and
        $taskReceipt.schema_version -eq '1.1' -and
        $taskReceipt.model_verification.all_actual_models_verified -and
        $verifiedTaskReceipt.receipt_hash -eq $taskReceipt.receipt_hash
    ) 'A completed durable run must produce a verifiable task-level receipt.'
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'New-OrchestrationTaskReceipt.ps1') `
            -RunDirectory $runDirectory -Outcome completed `
            -Summary 'duplicate outcome' -OutputPath (
                Join-Path $runDirectory (
                    'receipts/duplicate.task-completion-receipt.json'
                )
            ) | Out-Null
    } 'already exists for this run' (
        'A durable run must not produce multiple competing task-level outcomes.'
    )
    $taskReceiptOriginal = Get-Content -LiteralPath $taskReceiptPath -Raw
    $taskReceiptTampered = $taskReceiptOriginal |
        ConvertFrom-Json -AsHashtable -Depth 20
    $taskReceiptTampered.summary = 'silently changed outcome'
    $taskReceiptTampered | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $taskReceiptPath
    Assert-ThrowsLike {
        Read-OrchestrationTaskReceipt -Path $taskReceiptPath `
            -RunDirectory $runDirectory | Out-Null
    } 'receipt hash mismatch' (
        'A changed task-level outcome receipt must be rejected.'
    )
    Set-Content -LiteralPath $taskReceiptPath `
        -Value $taskReceiptOriginal -NoNewline

    $fallbackClasses = @(
        'creation-failed', 'model-unavailable', 'worktree-preflight-failed',
        'write-conflict', 'timeout-no-result', 'independent-review-failed'
    )
    foreach ($failureClass in $fallbackClasses) {
        $fallbackRun = Join-Path $testRoot (
            'fallback-run-' + $failureClass
        )
        & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
            -PlanPath $examplePath -RunDirectory $fallbackRun `
            -WorkspaceRoot $skillRoot | Out-Null
        $fallbackReceiptPath = Join-Path $fallbackRun (
            "receipts/$failureClass.task-completion-receipt.json"
        )
        $fallbackReceipt = & (
            Join-Path $scriptRoot 'New-OrchestrationTaskReceipt.ps1'
        ) -RunDirectory $fallbackRun -Outcome fallback-main `
            -FailureClass $failureClass `
            -FallbackAction 'Main agent retains ownership and reports the boundary.' `
            -Summary "Fallback recorded for $failureClass." `
            -Evidence @("observation:$failureClass") `
            -OutputPath $fallbackReceiptPath | ConvertFrom-Json -Depth 20
        $verifiedFallback = Read-OrchestrationTaskReceipt `
            -Path $fallbackReceiptPath -RunDirectory $fallbackRun
        Assert-True (
            $fallbackReceipt.failure_class -eq $failureClass -and
            $verifiedFallback.outcome -eq 'fallback-main'
        ) "Failure class '$failureClass' must produce a verifiable fallback receipt."
    }

    $tamperedPlanRun = Join-Path $testRoot 'tampered-plan-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $tamperedPlanRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $tamperedPlanPath = Join-Path $tamperedPlanRun 'plan.json'
    $tamperedPlan = Get-Content -LiteralPath $tamperedPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $tamperedPlan.goal = 'silently replaced goal'
    $tamperedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $tamperedPlanPath
    $planTamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $tamperedPlanRun | Out-Null
    }
    catch {
        $planTamperCaught = $_.Exception.Message -like '*changed after run creation*'
    }
    Assert-True $planTamperCaught 'Silent plan replacement should be rejected.'

    $gatePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $gatePlan.run_id = 'gate-test-001'
    $gatePlan.nodes += @{
        id = 'human-approval'
        kind = 'human-gate'
        depends_on = @()
        question = 'Continue with the reversible local step?'
        choices = @('continue', 'stop')
        default_safe_action = 'stop'
        action_class = 'local-reversible'
    }
    $gatePlan.completion.required_nodes += 'human-approval'
    $gatePlanPath = Join-Path $testRoot 'gate-plan.json'
    $gatePlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $gatePlanPath
    $gateRun = Join-Path $testRoot 'gate-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $gatePlanPath -RunDirectory $gateRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $gateBypassCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
            -Message 'bypass user' -IdempotencyKey 'gate-bypass' | Out-Null
    }
    catch {
        $gateBypassCaught = $_.Exception.Message -like '*must enter needs_input*'
    }
    Assert-True $gateBypassCaught 'Human gate must not complete without waiting for input.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $gateRun -NodeId 'human-approval' -Status 'needs_input' `
        -Message 'waiting for user' -IdempotencyKey 'gate-waiting' | Out-Null
    $missingHumanCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
            -Message 'no actor evidence' -IdempotencyKey 'gate-no-actor' | Out-Null
    }
    catch {
        $missingHumanCaught = $_.Exception.Message -like '*Decision and HumanActor*'
    }
    Assert-True $missingHumanCaught 'Human gate completion requires decision evidence.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
        -Message 'user selected continue' -IdempotencyKey 'gate-completed' `
        -Decision 'continue' -HumanActor 'user' | Out-Null

    $questionPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $questionPlan.run_id = 'question-limit-001'
    $questionPlan.roles[0].question_policy.max_questions = 0
    $questionMainNode = $questionPlan.nodes[2]
    $questionMainNode.depends_on = @('draft')
    $questionPlan.nodes = @($questionPlan.nodes[0], $questionMainNode)
    $questionPlan.completion.required_nodes = @('draft')
    $questionPlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $questionPlanPath = Join-Path $testRoot 'question-plan.json'
    $questionPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $questionPlanPath
    $questionRun = Join-Path $testRoot 'question-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $questionPlanPath -RunDirectory $questionRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing', 'materialized', 'running')) {
        $threadId = if ($status -eq 'materialized') { 'question-thread' } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status $status `
            -Message "question test $status" -ThreadId $threadId `
            -ModelId $modelId `
            -IdempotencyKey "question-$status" | Out-Null
    }
    $questionLimitCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status 'needs_input' `
            -Message 'question beyond contract' -IdempotencyKey 'question-denied' |
            Out-Null
    }
    catch {
        $questionLimitCaught = $_.Exception.Message -like '*question limit*'
    }
    Assert-True $questionLimitCaught 'Runtime should enforce the role question limit.'
    $emptyEvidenceCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status 'completed' `
            -Message 'unsupported completion' -Evidence @('success') `
            -IdempotencyKey 'question-empty-evidence' | Out-Null
    }
    catch {
        $emptyEvidenceCaught = $_.Exception.Message -like '*kind:value*'
    }
    Assert-True $emptyEvidenceCaught (
        'Completion evidence must use a typed evidence pointer.'
    )
    $joinedJournalPath = Join-Path $questionRun 'events.jsonl'
    $joinedEvidenceVariants = [Collections.Generic.List[string]]::new()
    foreach ($leftType in @('artifact', 'test', 'source', 'observation')) {
        foreach ($rightType in @('artifact', 'test', 'source', 'observation')) {
            $joinedEvidenceVariants.Add(
                "${leftType}:primary, ${rightType}:secondary"
            )
        }
    }
    foreach ($variant in @(
        'artifact:primary,observation:zero-space',
        'artifact:primary,   observation:multi-space',
        "artifact:primary,`ttest:tab",
        'ArTiFaCt:primary, TeSt:mixed-case',
        'source:first, observation:second, test:third, artifact:fourth'
    )) {
        $joinedEvidenceVariants.Add($variant)
    }
    $joinedVariantIndex = 0
    foreach ($joinedEvidenceValue in $joinedEvidenceVariants) {
        $joinedVariantIndex += 1
        $joinedJournalHashBefore = (
            Get-FileHash -LiteralPath $joinedJournalPath -Algorithm SHA256
        ).Hash
        $joinedEvidenceCaught = $false
        try {
            & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
                -RunDirectory $questionRun -NodeId 'draft' -Status 'completed' `
                -Message 'joined evidence must fail before journal append' `
                -Evidence @($joinedEvidenceValue) `
                -IdempotencyKey "question-joined-evidence-$joinedVariantIndex" |
                Out-Null
        }
        catch {
            $joinedEvidenceCaught = (
                $_.Exception.Message -like '*multiple typed pointers*'
            )
        }
        Assert-True $joinedEvidenceCaught (
            "Joined Evidence variant $joinedVariantIndex must be rejected."
        )
        Assert-True (
            (
                Get-FileHash -LiteralPath $joinedJournalPath -Algorithm SHA256
            ).Hash -eq $joinedJournalHashBefore
        ) (
            "Rejected Evidence variant $joinedVariantIndex must not change " +
            'the immutable journal.'
        )
    }
    $commaObservationEvent = & (
        Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1'
    ) -RunDirectory $questionRun -NodeId 'draft' -Status 'completed' `
        -Message 'ordinary comma remains valid inside one observation' `
        -Evidence @(
            'artifact:artifacts/draft/output.md',
            'observation:summary,with-comma'
        ) -IdempotencyKey 'question-valid-comma-evidence' |
        ConvertFrom-Json -Depth 50
    Assert-True (
        @($commaObservationEvent.evidence).Count -eq 2
    ) 'A comma without another typed prefix must remain valid evidence text.'

    $metadataRun = Join-Path $testRoot 'metadata-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $metadataRun `
        -WorkspaceRoot $testRoot | Out-Null
    $metadataPath = Join-Path $metadataRun 'run.json'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw |
        ConvertFrom-Json -AsHashtable
    $metadata.policy_version = 'forged'
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath
    $metadataTamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $metadataRun | Out-Null
    }
    catch {
        $metadataTamperCaught = $_.Exception.Message -like '*metadata is inconsistent*'
    }
    Assert-True $metadataTamperCaught 'run.json metadata tampering should be rejected.'

    $reusePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $reusePlan.run_id = 'reuse-thread-001'
    $reuseMainNode = $reusePlan.nodes[2]
    $reuseMainNode.depends_on = @('draft')
    $reusePlan.nodes = @($reusePlan.nodes[0], $reuseMainNode)
    $reusePlan.nodes[0].context.session_policy = 'reuse'
    $reusePlan.nodes[0].context.max_prior_turns = 2
    $reusePlan.nodes[0].context.prior_thread_id = 'declared-prior-thread'
    $reusePlan.nodes[0].context.prior_handoff = 'artifacts/handoffs/prior.json'
    $reusePlan.nodes[0].context.prior_handoff_hash = ('0' * 64)
    $reusePlan.nodes[0].context.reuse_reason = 'Continue the same bounded draft.'
    $reusePlan.completion.required_nodes = @('draft')
    $reusePlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $reusePlanPath = Join-Path $testRoot 'reuse-plan.json'
    $reusePlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $reusePlanPath
    $reuseRun = Join-Path $testRoot 'reuse-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $reusePlanPath -RunDirectory $reuseRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing')) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $reuseRun -NodeId 'draft' -Status $status `
            -Message "reuse $status" -IdempotencyKey "reuse-$status" | Out-Null
    }
    $wrongReuseThreadCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $reuseRun -NodeId 'draft' -Status 'materialized' `
            -Message 'wrong prior thread' -ThreadId 'different-thread' `
            -ModelId 'gpt-5.6-sol' `
            -IdempotencyKey 'reuse-wrong-thread' | Out-Null
    }
    catch {
        $wrongReuseThreadCaught = $_.Exception.Message -like '*declared prior_thread_id*'
    }
    Assert-True $wrongReuseThreadCaught (
        'Reuse must materialize the exact declared prior thread.'
    )

    $boundReusePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $boundReusePlan.run_id = 'bound-reuse-001'
    $boundReuseMainNode = $boundReusePlan.nodes[2]
    $boundReuseMainNode.depends_on = @('draft')
    $boundReusePlan.nodes = @(
        $boundReusePlan.nodes[0],
        $boundReuseMainNode
    )
    $boundReusePlan.nodes[0].context.session_policy = 'reuse'
    $boundReusePlan.nodes[0].context.max_prior_turns = 2
    $boundReusePlan.nodes[0].context.prior_thread_id = 'test-thread-draft'
    $boundReusePlan.nodes[0].context.prior_handoff = (
        'artifacts/handoffs/draft.json'
    )
    $boundReusePlan.nodes[0].context.prior_handoff_hash = (
        $draftHandoff.handoff_sha256
    )
    $boundReusePlan.nodes[0].context.reuse_reason = (
        'Continue only from the validated compact handoff.'
    )
    $boundReusePlan.completion.required_nodes = @('draft')
    $boundReusePlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $boundReusePlanPath = Join-Path $testRoot 'bound-reuse-plan.json'
    $boundReusePlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $boundReusePlanPath
    $boundPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $boundReusePlanPath -NodeId 'draft' -WorkspaceRoot $testRoot
    Assert-True ($boundPacket -like "*$($draftHandoff.handoff_sha256)*") (
        'Reuse packets must verify and render the exact handoff hash.'
    )

    $freshRetryPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshRetryPlan.run_id = 'fresh-retry-001'
    $freshRetryMainNode = $freshRetryPlan.nodes[2]
    $freshRetryMainNode.depends_on = @('draft')
    $freshRetryPlan.nodes = @(
        $freshRetryPlan.nodes[0],
        $freshRetryMainNode
    )
    $freshRetryPlan.nodes[0].max_attempts = 2
    $freshRetryPlan.completion.required_nodes = @('draft')
    $freshRetryPlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $freshRetryPlanPath = Join-Path $testRoot 'fresh-retry-plan.json'
    $freshRetryPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $freshRetryPlanPath
    $freshRetryRun = Join-Path $testRoot 'fresh-retry-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $freshRetryPlanPath -RunDirectory $freshRetryRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing', 'materialized', 'running')) {
        $threadId = if ($status -eq 'materialized') { 'first-attempt-thread' } else { $null }
        $modelId = if ($status -eq 'materialized') {
            'gpt-5.6-sol'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status $status `
            -Message "fresh retry $status" -ThreadId $threadId `
            -ModelId $modelId `
            -IdempotencyKey "fresh-retry-1-$status" | Out-Null
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $freshRetryRun -NodeId 'draft' -Status 'failed' `
        -Message 'first attempt failed' -ErrorClass 'runtime_transient' `
        -IdempotencyKey 'fresh-retry-1-failed' | Out-Null
    foreach ($status in @('launch_reserved', 'materializing')) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status $status `
            -Message "fresh retry 2 $status" `
            -IdempotencyKey "fresh-retry-2-$status" | Out-Null
    }
    $sameNodeThreadReuseCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status 'materialized' `
            -Message 'reuse failed attempt thread' -ThreadId 'first-attempt-thread' `
            -ModelId 'gpt-5.6-sol' `
            -IdempotencyKey 'fresh-retry-reused-thread' | Out-Null
    }
    catch {
        $sameNodeThreadReuseCaught = $_.Exception.Message -like '*cannot reuse thread*'
    }
    Assert-True $sameNodeThreadReuseCaught (
        'Fresh retries must rotate away from the failed attempt thread.'
    )

    $eventsPath = Join-Path $runDirectory 'events.jsonl'
    Add-Content -LiteralPath $eventsPath -Value '{"sequence":999,"hash":"tampered"}'
    $tamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $tamperCaught = $_.Exception.Message -like '*sequence gap*'
    }
    Assert-True $tamperCaught 'Tampered journal should be rejected.'

    $recoveryProtocol = & (
        Join-Path $scriptRoot 'Test-RecoveryProtocol.ps1'
    ) | ConvertFrom-Json -Depth 20
    Assert-True $recoveryProtocol.passed (
        'Durable missing-final recovery protocol should pass its attack suite.'
    )
    $script:assertionCount += [int]$recoveryProtocol.assertions
    $policyActivation = & (
        Join-Path $scriptRoot 'Test-RunPolicyActivation.ps1'
    ) | ConvertFrom-Json -Depth 20
    Assert-True $policyActivation.pass (
        'Immutable predecessor run policy activation should pass its attack suite.'
    )
    $script:assertionCount += [int]$policyActivation.assertions
    $durableMilestone = & (
        Join-Path $scriptRoot 'Test-DurableReviewMilestone.ps1'
    ) | ConvertFrom-Json -Depth 20
    Assert-True $durableMilestone.pass (
        'Durable review milestone roll-forward should pass its attack suite.'
    )
    $script:assertionCount += [int]$durableMilestone.assertions

    [pscustomobject]@{
        passed = $true
        assertions = $script:assertionCount
        journal_recovery_verified = $true
        intentional_invalid_cases_rejected = $script:invalidPlanCount
        role_contracts_verified = $true
        worker_packet_verified = $true
        completion_gate_verified = $true
        question_limit_verified = $true
        typed_evidence_verified = $true
        metadata_tamper_rejected = $true
        context_contract_verified = $true
        compact_handoff_verified = $true
        thread_rotation_verified = $true
        dependency_gate_verified = $true
        idempotency_verified = $true
        plan_tamper_rejected = $true
        human_gate_evidence_verified = $true
        illegal_transition_rejected = $true
        journal_tamper_rejected = $true
        context_efficiency_verified = $true
        token_benchmark_verified = $true
        usage_diagnostics_verified = $true
        role_activation_verified = $true
        industry_role_packs_verified = $true
        calibration_ledger_verified = $true
        dispatch_preview_verified = $true
        execution_surface_verified = $true
        worktree_preflight_verified = $true
        queued_setup_verified = $true
        task_completion_receipt_verified = $true
        durable_review_profile_verified = $true
        durable_result_recovery_verified = $true
        run_policy_activation_verified = $true
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path
        if (-not $resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to remove test directory outside TEMP: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
