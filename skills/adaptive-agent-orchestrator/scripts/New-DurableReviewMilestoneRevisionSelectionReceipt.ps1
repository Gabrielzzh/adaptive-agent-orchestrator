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
$authorization = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $AuthorizationReceiptPath -RunDirectory $runRoot
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
$lifecycleBindings = [Collections.Generic.List[object]]::new()
foreach ($requiredSource in $requiredSources) {
    $sourceNodeId = [string]$requiredSource.source_node_id
    $matches = @($selectionItems | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
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
    if ([string]$binding.source_thread_id -ne
            [string]$requiredSource.thread_id -or
        [string]$binding.checkpoint_material_hash -ne
            [string]$authorization.checkpoint_material_hash -or
        [string]$binding.result_receipt_path -in $excludedPaths -or
        [string]$binding.disposition_receipt_path -in $excludedPaths) {
        throw 'Milestone revision selection changed source, checkpoint, or used excluded evidence.'
    }

    $sourceEvents = @($events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [int]$_.sequence -gt [int]$authorizationEvent[0].sequence
    })
    $rearms = @($sourceEvents | Where-Object {
        [string]$_.prior_state -eq 'adopted' -and
        [string]$_.status -eq 'running' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [string]$_.milestone_revision_id -eq
            [string]$authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$authorization.receipt_hash
    })
    if ($rearms.Count -ne 1 -or $sourceEvents.Count -lt 4) {
        throw "Milestone revision source '$sourceNodeId' lacks one fresh re-arm."
    }
    $completed = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'completed' -and
        [int]$_.sequence -gt [int]$rearms[0].sequence
    }) | Select-Object -Last 1
    $validated = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'validated' -and
        [int]$_.sequence -gt [int]$rearms[0].sequence
    }) | Select-Object -Last 1
    $adopted = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'adopted' -and
        [int]$_.sequence -gt [int]$rearms[0].sequence
    }) | Select-Object -Last 1
    if ($null -eq $completed -or $null -eq $validated -or
        $null -eq $adopted -or
        [string]$completed.prior_state -ne 'running' -or
        [string]$validated.prior_state -ne 'completed' -or
        [string]$adopted.prior_state -ne 'validated' -or
        [int]$completed.sequence -ge [int]$validated.sequence -or
        [int]$validated.sequence -ge [int]$adopted.sequence -or
        @($rearms[0], $completed, $validated, $adopted |
            Where-Object { [int]$_.sequence -in $excludedSequences }).Count -gt 0) {
        throw "Milestone revision source '$sourceNodeId' has no valid post-anchor lifecycle."
    }
    $resultPointer = "artifact:$($binding.result_receipt_path)"
    $dispositionPointer = "artifact:$($binding.disposition_receipt_path)"
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
                [string]$_.source_node_id -eq $sourceNodeId
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
                [string]$binding.result_receipt_path -or
            [string]$sourceCorrection[0].result_receipt_hash -ne
                [string]$binding.result_receipt_hash -or
            [string]$sourceCorrection[0].result_file_hash -ne
                [string]$binding.result_file_hash -or
            [string]$sourceCorrection[0].disposition_receipt_path -ne
                [string]$binding.disposition_receipt_path -or
            [string]$sourceCorrection[0].disposition_receipt_hash -ne
                [string]$binding.disposition_receipt_hash -or
            [string]$sourceCorrection[0].disposition_file_hash -ne
                [string]$binding.disposition_file_hash) {
            throw (
                "Milestone revision source '$sourceNodeId' correction " +
                'does not bind the selected lifecycle and receipts.'
            )
        }
    }

    $previous = @($authorization.previous_source_bindings | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
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
        -ExpectedThreadId ([string]$requiredSource.thread_id)
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
    $lifecycleBindings.Add([pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        role_id = [string]$requiredSource.role_id
        source_thread_id = [string]$requiredSource.thread_id
        rearm_event_sequence = [int]$rearms[0].sequence
        rearm_event_hash = [string]$rearms[0].hash
        completed_event_sequence = [int]$completed.sequence
        completed_event_hash = [string]$completed.hash
        validated_event_sequence = [int]$validated.sequence
        validated_event_hash = [string]$validated.hash
        adopted_event_sequence = [int]$adopted.sequence
        adopted_event_hash = [string]$adopted.hash
    })
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
    schema_version = if ($null -eq $lifecycleCorrection) { '1.1' } else { '1.2' }
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
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
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
