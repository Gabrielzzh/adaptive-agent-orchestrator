[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationReceiptPath,
    [Parameter(Mandatory)][string] $SelectionMaterialPath,
    [Parameter(Mandatory)][string] $SelectionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
if ($SelectionKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone revision selection requires a stable authority key.'
}
foreach ($candidate in @($AuthorizationReceiptPath, $SelectionMaterialPath)) {
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw 'Milestone revision selection inputs must be files inside the run.'
    }
}
$validationToken = Enter-OrchestrationValidationContext -RunDirectory $runRoot
try {
$authorization = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $AuthorizationReceiptPath -RunDirectory $runRoot
$authorizationRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, [IO.Path]::GetFullPath($AuthorizationReceiptPath)
).Replace('\', '/')
if ($SelectionKey -cne [string]$authorization.selection_key) {
    throw 'Milestone revision selection key does not match its authorization.'
}
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$eventsPath = Join-Path $runRoot 'events.jsonl'
$events = @(Read-OrchestrationJournal $eventsPath)
$authorizationEvent = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-authorized' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$existingSelection = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-selected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
if ($authorizationEvent.Count -ne 1 -or $existingSelection.Count -ne 0) {
    throw 'Milestone revision authorization is absent, already selected, or forked.'
}
$correctionReceiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).lifecycle-correction.json"
)
$correctionReceiptPath = Join-Path (
    Join-Path $runRoot 'receipts'
) $correctionReceiptName
$correctionEvents = @($events | Where-Object {
    [string]$_.event -eq
        'milestone-revision-lifecycle-evidence-corrected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$lifecycleCorrection = $null
if ((Test-Path -LiteralPath $correctionReceiptPath -PathType Leaf) -or
    $correctionEvents.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $correctionReceiptPath -PathType Leaf) -or
        $correctionEvents.Count -ne 1) {
        throw 'Milestone revision lifecycle correction is missing or forked.'
    }
    $lifecycleCorrection =
        Read-DurableReviewMilestoneRevisionLifecycleCorrection `
            -Path $correctionReceiptPath -RunDirectory $runRoot
}
$standaloneSupersessionReceiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).inventory-supersession.json"
)
$combinedSupersessionReceiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).cumulative-correction.json"
)
$useCombinedSupersession = $null -ne $lifecycleCorrection
$supersessionReceiptName = if ($useCombinedSupersession) {
    $combinedSupersessionReceiptName
} else {
    $standaloneSupersessionReceiptName
}
$supersessionReceiptPath = Join-Path (
    Join-Path $runRoot 'receipts'
) $supersessionReceiptName
$supersessionEventName = if ($useCombinedSupersession) {
    'milestone-revision-cumulative-corrected'
} else {
    'milestone-revision-inventory-superseded'
}
$supersessionEvents = @($events | Where-Object {
    [string]$_.event -eq $supersessionEventName -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$legacySupersessionPath = Join-Path (Join-Path $runRoot 'receipts') `
    $standaloneSupersessionReceiptName
$dedicatedSupersessionPath = Join-Path (Join-Path $runRoot 'receipts') `
    $combinedSupersessionReceiptName
$legacySupersessionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$dedicatedSupersessionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-cumulative-corrected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
if ($useCombinedSupersession -and
    ((Test-Path -LiteralPath $legacySupersessionPath -PathType Leaf) -or
        $legacySupersessionEvents.Count -gt 0)) {
    throw 'Combined revision selection cannot consume a standalone inventory supersession.'
}
if (-not $useCombinedSupersession -and
    ((Test-Path -LiteralPath $dedicatedSupersessionPath -PathType Leaf) -or
        $dedicatedSupersessionEvents.Count -gt 0)) {
    throw 'Standalone revision selection cannot consume a cumulative correction.'
}
$inventorySupersession = $null
if ((Test-Path -LiteralPath $supersessionReceiptPath -PathType Leaf) -or
    $supersessionEvents.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $supersessionReceiptPath -PathType Leaf) -or
        $supersessionEvents.Count -ne 1) {
        throw 'Milestone revision inventory supersession is missing or forked.'
    }
    $inventorySupersession = if ($useCombinedSupersession) {
        Read-DurableReviewMilestoneRevisionCumulativeCorrection `
            -Path $supersessionReceiptPath -RunDirectory $runRoot
    } else {
        Read-DurableReviewMilestoneRevisionInventorySupersession `
            -Path $supersessionReceiptPath -RunDirectory $runRoot
    }
    $supersededSelectionPath = Get-RunLocalReceiptPath `
        -RunDirectory $runRoot -RelativePath (
            [string]$inventorySupersession.superseded_selection_material_path
        ) -Label 'Superseded milestone revision selection material'
    if ([IO.Path]::GetFullPath($SelectionMaterialPath) -cne
            [IO.Path]::GetFullPath($supersededSelectionPath) -or
        [string]$inventorySupersession.superseded_selection_material_hash -ne (
            Get-FileHash -LiteralPath $SelectionMaterialPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()) {
        throw (
            'Milestone revision selection does not use its bound inventory ' +
            'supersession material.'
        )
    }
}
$selectionItems = @(
    Get-Content -LiteralPath $SelectionMaterialPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
)
$requiredSources = @($authorization.required_sources)
if ($selectionItems.Count -ne $requiredSources.Count) {
    throw 'Milestone revision selection must include every required source.'
}
$excludedSequences = @($authorization.excluded_evidence |
    ForEach-Object { @($_.event_bindings) } |
    ForEach-Object { [int]$_.sequence })
$excludedPaths = @(
    $authorization.excluded_evidence | ForEach-Object {
        @($_.artifacts) | ForEach-Object { [string]$_.path }
    }
)
$sourceBindings = [Collections.Generic.List[object]]::new()
$lifecycleCandidates = [Collections.Generic.List[object]]::new()
$hasReplacement = $false
foreach ($requiredSource in $requiredSources) {
    $sourceNodeId = [string]$requiredSource.source_node_id
    $matches = @($selectionItems | Where-Object {
        [string]$_.source_node_id -ceq $sourceNodeId
    })
    if ($matches.Count -ne 1) {
        throw "Milestone revision source '$sourceNodeId' is missing or repeated."
    }
    $binding = Get-DurableReviewDispositionBinding -RunDirectory $runRoot `
        -Plan $plan -SourceNodeId $sourceNodeId `
        -DispositionRelativePath (
            [string]$matches[0].disposition_receipt_path
        ) -ExpectedMilestoneId ([string]$authorization.milestone_id) `
        -RequireResultMilestoneBinding
    if ([string]$binding.checkpoint_material_path -ne
            [string]$authorization.checkpoint_material_path -or
        [string]$binding.checkpoint_material_hash -ne
            [string]$authorization.checkpoint_material_hash -or
        [string]$binding.result_receipt_path -in $excludedPaths -or
        [string]$binding.disposition_receipt_path -in $excludedPaths) {
        throw 'Milestone revision selection changed source, checkpoint, or used excluded evidence.'
    }

    $sourceEvents = @($events | Where-Object {
        [string]$_.node_id -ceq $sourceNodeId -and
        [int]$_.sequence -gt [int]$authorizationEvent[0].sequence
    })
    $rearms = @(
        Get-DurableReviewMilestoneRevisionRearmEvent `
            -RunDirectory $runRoot -Events $events `
            -Authorization $authorization -RequiredSource $requiredSource `
            -AuthorizationEventSequence ([int]$authorizationEvent[0].sequence)
    )
    $continuity = Get-DurableReviewRevisionSourceContinuityBinding `
        -RunDirectory $runRoot -RequiredSource $requiredSource `
        -DispositionBinding $binding -Authorization $authorization `
        -AuthorizationReceiptRelativePath $authorizationRelativePath `
        -Events $events `
        -AuthorizationEventSequence ([int]$authorizationEvent[0].sequence) `
        -RearmEventSequence ([int]$rearms[0].sequence)
    if ([string]$continuity.source_kind -eq 'replacement') {
        $hasReplacement = $true
    }
    $selectedThreadId = [string]$continuity.source_thread_id
    $lifecycleStartSequence = [int]$continuity.lifecycle_start_sequence
    $completed = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'completed' -and
        [string]$_.thread_id -ceq $selectedThreadId -and
        [int]$_.sequence -gt $lifecycleStartSequence
    }) | Select-Object -Last 1
    $validated = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'validated' -and
        [string]$_.thread_id -ceq $selectedThreadId -and
        [int]$_.sequence -gt $lifecycleStartSequence
    }) | Select-Object -Last 1
    $adopted = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'adopted' -and
        [string]$_.thread_id -ceq $selectedThreadId -and
        [int]$_.sequence -gt $lifecycleStartSequence
    }) | Select-Object -Last 1
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
    if ($null -eq $completed -or $null -eq $validated -or
        $null -eq $adopted -or
        [string]$completed.prior_state -ne 'running' -or
        [string]$validated.prior_state -ne 'completed' -or
        [string]$adopted.prior_state -ne 'validated' -or
        [int]$completed.sequence -ge [int]$validated.sequence -or
        [int]$validated.sequence -ge [int]$adopted.sequence -or
        [int]$lifecycleStartSequence -ge [int]$completed.sequence -or
        @($rearms[0], $completed, $validated, $adopted |
            Where-Object { [int]$_.sequence -in $excludedSequences }).Count -gt 0) {
        throw "Milestone revision source '$sourceNodeId' has no valid post-anchor lifecycle."
    }
    if (@($continuitySequences | Where-Object {
        [int]$_ -in $excludedSequences
    }).Count -gt 0) {
        throw (
            "Milestone revision source '$sourceNodeId' used excluded " +
            'replacement evidence.'
        )
    }
    $evidenceBinding = $binding
    if ($null -ne $inventorySupersession) {
        $sourceSupersession = @(
            $inventorySupersession.source_supersessions | Where-Object {
                [string]$_.source_node_id -ceq $sourceNodeId
            }
        )
        if ($sourceSupersession.Count -ne 1 -or
            (ConvertTo-Json -InputObject (
                $sourceSupersession[0].superseded_binding
            ) -Compress -Depth 100) -cne
            (ConvertTo-Json -InputObject $binding -Compress -Depth 100)) {
            throw (
                "Milestone revision source '$sourceNodeId' inventory " +
                'supersession binding changed.'
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
                'Milestone revision lifecycle does not bind the selected ' +
                'receipts.'
            )
        }
    } else {
        $sourceCorrection = @(
            $lifecycleCorrection.source_corrections | Where-Object {
                [string]$_.source_node_id -ceq $sourceNodeId
            }
        )
        if ($sourceCorrection.Count -ne 1 -or
            [int]$sourceCorrection[0].rearm_event_sequence -ne
                [int]$rearms[0].sequence -or
            [string]$sourceCorrection[0].rearm_event_hash -ne
                [string]$rearms[0].hash -or
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
                [string]$evidenceBinding.result_receipt_path -or
            [string]$sourceCorrection[0].result_receipt_hash -ne
                [string]$evidenceBinding.result_receipt_hash -or
            [string]$sourceCorrection[0].result_file_hash -ne
                [string]$evidenceBinding.result_file_hash -or
            [string]$sourceCorrection[0].disposition_receipt_path -ne
                [string]$evidenceBinding.disposition_receipt_path -or
            [string]$sourceCorrection[0].disposition_receipt_hash -ne
                [string]$evidenceBinding.disposition_receipt_hash -or
            [string]$sourceCorrection[0].disposition_file_hash -ne
                [string]$evidenceBinding.disposition_file_hash) {
            throw (
                "Milestone revision source '$sourceNodeId' correction " +
                'does not bind the selected lifecycle and receipts.'
            )
        }
    }

    $previous = @($authorization.previous_source_bindings | Where-Object {
        [string]$_.source_node_id -ceq $sourceNodeId
    })
    if ($previous.Count -ne 1) {
        throw 'Milestone revision predecessor source binding is incomplete.'
    }
    $previousDispositionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$previous[0].disposition_receipt_path) `
        -Label 'Previous milestone revision disposition'
    $previousDisposition = Read-ReviewDispositionReceipt `
        -Path $previousDispositionPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $sourceNodeId `
        -ExpectedThreadId ([string]$previous[0].source_thread_id)
    $newDispositionPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$binding.disposition_receipt_path) `
        -Label 'Selected milestone revision disposition'
    $newDisposition = Read-ReviewDispositionReceipt -Path $newDispositionPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $sourceNodeId `
        -ExpectedThreadId $selectedThreadId
    foreach ($oldDecision in @($previousDisposition.decisions)) {
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
            throw (
                "Milestone revision source '$sourceNodeId' did not conserve " +
                "finding occurrence '$($oldDecision.source_finding_id)'."
            )
        }
    }
    $sourceBindings.Add($binding)
    $lifecycleCandidates.Add([pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        role_id = [string]$requiredSource.role_id
        source_kind = [string]$continuity.source_kind
        authorized_thread_id = [string]$continuity.authorized_thread_id
        source_thread_id = $selectedThreadId
        rearm_event_sequence = [int]$rearms[0].sequence
        rearm_event_hash = [string]$rearms[0].hash
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
    })
}

$lifecycleBindings = [Collections.Generic.List[object]]::new()
foreach ($candidate in @($lifecycleCandidates)) {
    if ($hasReplacement -or $null -ne $inventorySupersession) {
        $lifecycleBindings.Add($candidate)
    } else {
        $lifecycleBindings.Add([pscustomobject][ordered]@{
            source_node_id = [string]$candidate.source_node_id
            role_id = [string]$candidate.role_id
            source_thread_id = [string]$candidate.source_thread_id
            rearm_event_sequence = [int]$candidate.rearm_event_sequence
            rearm_event_hash = [string]$candidate.rearm_event_hash
            completed_event_sequence = [int]$candidate.completed_event_sequence
            completed_event_hash = [string]$candidate.completed_event_hash
            validated_event_sequence = [int]$candidate.validated_event_sequence
            validated_event_hash = [string]$candidate.validated_event_hash
            adopted_event_sequence = [int]$candidate.adopted_event_sequence
            adopted_event_hash = [string]$candidate.adopted_event_hash
        })
    }
}

$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).selection.json"
)
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'Milestone revision selection receipt already exists.'
}
$relative = {
    param([string] $Path)
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$payload = [ordered]@{
    schema_version = if ($null -ne $inventorySupersession -and $null -ne $lifecycleCorrection) {
        '1.6'
    } elseif ($null -ne $inventorySupersession) {
        '1.4'
    } elseif ($hasReplacement -and $null -ne $lifecycleCorrection) {
        '1.5'
    } elseif ($hasReplacement) {
        '1.3'
    } elseif ($null -eq $lifecycleCorrection) { '1.1' } else { '1.2' }
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    milestone_id = [string]$authorization.milestone_id
    milestone_index = 0
    revision_id = [string]$authorization.revision_id
    revision_index = [int]$authorization.revision_index
    authorization_receipt_path = & $relative $AuthorizationReceiptPath
    authorization_receipt_hash = [string]$authorization.receipt_hash
    previous_activation_receipt_path =
        [string]$authorization.previous_activation_receipt_path
    previous_activation_receipt_hash =
        [string]$authorization.previous_activation_receipt_hash
    previous_source_bindings_hash =
        [string]$authorization.previous_source_bindings_hash
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    selection_material_path = & $relative $SelectionMaterialPath
    selection_material_hash = (
        Get-FileHash -LiteralPath $SelectionMaterialPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    source_bindings = @($sourceBindings)
    source_bindings_hash = Get-TextSha256 (
        ConvertTo-Json -InputObject @($sourceBindings) -Compress -Depth 100
    )
    source_lifecycle_bindings = @($lifecycleBindings)
    source_lifecycle_bindings_hash = Get-TextSha256 (
        ConvertTo-Json -InputObject @($lifecycleBindings) -Compress -Depth 100
    )
    checkpoint_material_path = [string]$authorization.checkpoint_material_path
    checkpoint_material_hash = [string]$authorization.checkpoint_material_hash
    input_manifest_path = [string]$authorization.input_manifest_path
    input_manifest_hash = [string]$authorization.input_manifest_hash
    acceptance_authorization_material_path =
        [string]$authorization.acceptance_authorization_material_path
    acceptance_authorization_material_hash =
        [string]$authorization.acceptance_authorization_material_hash
    main_node_id = [string]$authorization.main_node_id
    acceptance_key = [string]$authorization.acceptance_key
    acceptance_evidence_material_path =
        [string]$authorization.acceptance_evidence_material_path
    acceptance_evidence_material_hash =
        [string]$authorization.acceptance_evidence_material_hash
    selection_key = [string]$authorization.selection_key
    activation_key = $SelectionKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
if ($null -ne $lifecycleCorrection) {
    $payload.lifecycle_correction_receipt_path =
        "receipts/$correctionReceiptName"
    $payload.lifecycle_correction_receipt_hash =
        [string]$lifecycleCorrection.receipt_hash
    $payload.lifecycle_correction_event_sequence =
        [int]$correctionEvents[0].sequence
    $payload.lifecycle_correction_event_hash =
        [string]$correctionEvents[0].hash
    if ([string]$lifecycleCorrection.schema_version -ceq '1.1') {
        $payload.lifecycle_correction_mode =
            [string]$lifecycleCorrection.correction_mode
        $payload.lifecycle_correction_omission_source_node_id =
            $lifecycleCorrection.omission_source_node_id
    }
}
if ($null -ne $inventorySupersession) {
    if ($useCombinedSupersession) {
        $payload.cumulative_correction_receipt_path =
            "receipts/$supersessionReceiptName"
        $payload.cumulative_correction_receipt_hash =
            [string]$inventorySupersession.receipt_hash
        $payload.cumulative_correction_event_sequence =
            [int]$supersessionEvents[0].sequence
        $payload.cumulative_correction_event_hash =
            [string]$supersessionEvents[0].hash
    } else {
        $payload.inventory_supersession_receipt_path =
            "receipts/$supersessionReceiptName"
        $payload.inventory_supersession_receipt_hash =
            [string]$inventorySupersession.receipt_hash
        $payload.inventory_supersession_event_sequence =
            [int]$supersessionEvents[0].sequence
        $payload.inventory_supersession_event_hash =
            [string]$supersessionEvents[0].hash
    }
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
} finally {
    Exit-OrchestrationValidationContext -Token $validationToken
}
if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $receiptDirectory
}
$temp = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $temp -Encoding utf8
$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the orchestration journal lock.'
    }
    $current = @(Read-OrchestrationJournal $eventsPath)
    if ($current.Count -ne $events.Count -or
        [string]$current[-1].hash -ne [string]$events[-1].hash) {
        throw 'The journal changed while revision selection was prepared.'
    }
    Assert-OrchestrationValidationContextUnchanged `
        -Context $validationToken.context -AllowAdditionalFiles
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $event = New-MilestoneRevisionJournalEvent -Plan $plan -Run $run `
        -Events $current -RunDirectory $runRoot `
        -EventName 'milestone-revision-selected' -ReceiptName $receiptName `
        -Receipt $receipt `
        -Message "Selected revision '$($authorization.revision_id)'." `
        -IdempotencyKey $SelectionKey
    try {
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 100
        )
    } catch {
        Remove-Item -LiteralPath $receiptPath -Force
        throw
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
$verified = Read-DurableReviewMilestoneRevisionSelection `
    -Path $receiptPath -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
