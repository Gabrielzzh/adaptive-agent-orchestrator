[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationReceiptPath,
    [Parameter(Mandatory)][string] $SelectionMaterialPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $SupersessionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
if ($SupersessionKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone revision inventory supersession requires a stable authority key.'
}
foreach ($candidate in @(
    $AuthorizationReceiptPath,
    $SelectionMaterialPath,
    $AuthorizationMaterialPath
)) {
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw (
            'Milestone revision inventory supersession inputs must be files ' +
            'inside the run.'
        )
    }
}
if ([string]::IsNullOrWhiteSpace(
    (Get-Content -LiteralPath $AuthorizationMaterialPath -Raw)
)) {
    throw 'Milestone revision inventory supersession authorization is empty.'
}

$validationToken = Enter-OrchestrationValidationContext -RunDirectory $runRoot
try {
$authorization = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $AuthorizationReceiptPath -RunDirectory $runRoot
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$eventsPath = Join-Path $runRoot 'events.jsonl'
$events = @(Read-OrchestrationJournal $eventsPath)
$authorizationEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-authorized' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$selectionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-selected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$supersessionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$correctionEvents = @($events | Where-Object {
    [string]$_.event -eq
        'milestone-revision-lifecycle-evidence-corrected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$correctionReceiptPath = Join-Path (Join-Path $runRoot 'receipts') (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).lifecycle-correction.json"
)
if ($authorizationEvents.Count -ne 1 -or $selectionEvents.Count -ne 0 -or
    $supersessionEvents.Count -ne 0) {
    throw (
        'Milestone revision inventory supersession requires one pending, ' +
        'unsuperseded authorization.'
    )
}
if ($correctionEvents.Count -gt 0 -or
    (Test-Path -LiteralPath $correctionReceiptPath -PathType Leaf)) {
    throw (
        'Milestone revision inventory supersession cannot be combined with ' +
        'lifecycle correction.'
    )
}
$selectionItems = @(
    Get-Content -LiteralPath $SelectionMaterialPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
)
$requiredSources = @($authorization.required_sources)
if ($selectionItems.Count -ne $requiredSources.Count) {
    throw 'Milestone revision inventory supersession requires every source.'
}
$excludedSequences = @($authorization.excluded_evidence |
    ForEach-Object { @($_.event_bindings) } |
    ForEach-Object { [int]$_.sequence })
$excludedPaths = @($authorization.excluded_evidence |
    ForEach-Object { @($_.artifacts) } |
    ForEach-Object { [string]$_.path })
$receiptDirectory = Join-Path $runRoot 'receipts'
$materialDirectory = Join-Path $runRoot 'materials'
$revisionToken = ([string]$authorization.revision_id).Substring(0, 16)
$artifactPlans = [Collections.Generic.List[object]]::new()
$effectiveSelectionItems = [Collections.Generic.List[object]]::new()
$restoredTotal = 0

foreach ($requiredSource in $requiredSources) {
    $sourceNodeId = [string]$requiredSource.source_node_id
    $items = @($selectionItems | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
    })
    if ($items.Count -ne 1) {
        throw "Inventory supersession source '$sourceNodeId' is missing or repeated."
    }
    $currentBinding = Get-DurableReviewDispositionBinding `
        -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
        -DispositionRelativePath ([string]$items[0].disposition_receipt_path) `
        -ExpectedMilestoneId ([string]$authorization.milestone_id) `
        -RequireResultMilestoneBinding
    if ([string]$currentBinding.source_thread_id -ne
            [string]$requiredSource.thread_id -or
        [string]$currentBinding.checkpoint_material_path -ne
            [string]$authorization.checkpoint_material_path -or
        [string]$currentBinding.checkpoint_material_hash -ne
            [string]$authorization.checkpoint_material_hash -or
        [string]$currentBinding.result_receipt_path -in $excludedPaths -or
        [string]$currentBinding.disposition_receipt_path -in $excludedPaths) {
        throw "Inventory supersession source '$sourceNodeId' changed scope."
    }
    $sourceEvents = @($events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [int]$_.sequence -gt [int]$authorizationEvents[0].sequence
    })
    $rearms = @($sourceEvents | Where-Object {
        [string]$_.prior_state -eq 'adopted' -and
        [string]$_.status -eq 'running' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [string]$_.milestone_revision_id -eq [string]$authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$authorization.receipt_hash
    })
    if ($rearms.Count -ne 1) {
        throw "Inventory supersession source '$sourceNodeId' lacks one fresh re-arm."
    }
    $authorizationRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, [IO.Path]::GetFullPath($AuthorizationReceiptPath)
    ).Replace('\', '/')
    $continuity = Get-DurableReviewRevisionSourceContinuityBinding `
        -RunDirectory $runRoot -RequiredSource $requiredSource `
        -DispositionBinding $currentBinding -Authorization $authorization `
        -AuthorizationReceiptRelativePath $authorizationRelativePath `
        -Events $events `
        -AuthorizationEventSequence ([int]$authorizationEvents[0].sequence) `
        -RearmEventSequence ([int]$rearms[0].sequence)
    if ([string]$continuity.source_thread_id -ne
        [string]$requiredSource.thread_id) {
        throw (
            "Inventory supersession source '$sourceNodeId' cannot change " +
            'thread or create another replacement.'
        )
    }
    $lifecycleStart = [int]$continuity.lifecycle_start_sequence
    $completed = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'completed' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [int]$_.sequence -gt $lifecycleStart
    }) | Select-Object -Last 1
    $validated = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'validated' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [int]$_.sequence -gt $lifecycleStart
    }) | Select-Object -Last 1
    $adopted = @($sourceEvents | Where-Object {
        [string]$_.status -eq 'adopted' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [int]$_.sequence -gt $lifecycleStart
    }) | Select-Object -Last 1
    if ($null -eq $completed -or $null -eq $validated -or $null -eq $adopted -or
        [string]$completed.role_id -ne [string]$requiredSource.role_id -or
        [string]$validated.role_id -ne [string]$requiredSource.role_id -or
        [string]$adopted.role_id -ne [string]$requiredSource.role_id -or
        [string]$completed.prior_state -ne 'running' -or
        [string]$validated.prior_state -ne 'completed' -or
        [string]$adopted.prior_state -ne 'validated' -or
        [int]$rearms[0].sequence -ge [int]$completed.sequence -or
        [int]$completed.sequence -ge [int]$validated.sequence -or
        [int]$validated.sequence -ge [int]$adopted.sequence -or
        @($rearms[0], $completed, $validated, $adopted | Where-Object {
            [int]$_.sequence -in $excludedSequences
        }).Count -gt 0 -or
        "artifact:$($currentBinding.result_receipt_path)" -notin
            @($completed.evidence) -or
        "artifact:$($currentBinding.disposition_receipt_path)" -notin
            @($validated.evidence) -or
        "artifact:$($currentBinding.disposition_receipt_path)" -notin
            @($adopted.evidence)) {
        throw "Inventory supersession source '$sourceNodeId' has invalid lifecycle."
    }
    $previousDeclared = @($authorization.previous_source_bindings |
        Where-Object { [string]$_.source_node_id -eq $sourceNodeId })
    if ($previousDeclared.Count -ne 1) {
        throw 'Inventory supersession predecessor binding is incomplete.'
    }
    $previousBinding = Get-DurableReviewDispositionBinding `
        -RunDirectory $runRoot -Plan $plan -SourceNodeId $sourceNodeId `
        -DispositionRelativePath (
            [string]$previousDeclared[0].disposition_receipt_path
        ) -ExpectedMilestoneId ([string]$authorization.milestone_id) `
        -RequireResultMilestoneBinding
    if ((ConvertTo-Json -InputObject $previousBinding -Compress -Depth 100) -cne
        (ConvertTo-Json -InputObject $previousDeclared[0] -Compress -Depth 100)) {
        throw "Inventory supersession source '$sourceNodeId' predecessor changed."
    }
    $previousResultPath = Join-Path $runRoot $previousBinding.result_receipt_path
    $previousDispositionPath =
        Join-Path $runRoot $previousBinding.disposition_receipt_path
    $currentResultPath = Join-Path $runRoot $currentBinding.result_receipt_path
    $currentDispositionPath =
        Join-Path $runRoot $currentBinding.disposition_receipt_path
    $previousResult = Read-ThreadResultReceipt -Path $previousResultPath `
        -ExpectedThreadId ([string]$previousBinding.source_thread_id) `
        -ExpectedSourceNodeId $sourceNodeId -RunDirectory $runRoot
    $previousDisposition = Read-ReviewDispositionReceipt `
        -Path $previousDispositionPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $sourceNodeId `
        -ExpectedThreadId ([string]$previousBinding.source_thread_id)
    $currentResult = Read-ThreadResultReceipt -Path $currentResultPath `
        -ExpectedThreadId ([string]$currentBinding.source_thread_id) `
        -ExpectedSourceNodeId $sourceNodeId -RunDirectory $runRoot
    $currentDisposition = Read-ReviewDispositionReceipt `
        -Path $currentDispositionPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $sourceNodeId `
        -ExpectedThreadId ([string]$currentBinding.source_thread_id)
    $inventory = Get-MilestoneRevisionCumulativeInventory `
        -PreviousResult $previousResult -PreviousDisposition $previousDisposition `
        -CurrentResult $currentResult -CurrentDisposition $currentDisposition
    $restoredTotal += [int]$inventory.restored_occurrence_count

    $resultRelativePath = (
        "receipts/$sourceNodeId.revision-$revisionToken." +
        'inventory-superseded.thread-result-receipt.json'
    )
    $dispositionRelativePath = (
        "receipts/$sourceNodeId.revision-$revisionToken." +
        'inventory-superseded.disposition.json'
    )
    $resultPath = Join-Path $runRoot $resultRelativePath
    $dispositionPath = Join-Path $runRoot $dispositionRelativePath
    if ((Test-Path -LiteralPath $resultPath) -or
        (Test-Path -LiteralPath $dispositionPath)) {
        throw "Inventory supersession source '$sourceNodeId' output already exists."
    }
    $resultPayload = [ordered]@{}
    foreach ($property in $currentResult.PSObject.Properties) {
        if ($property.Name -eq 'receipt_hash') { continue }
        if ($property.Name -eq 'pending_findings') {
            $resultPayload[$property.Name] = @($inventory.pending_findings)
        } elseif ($property.Name -in @(
            'adopted_findings', 'rejected_findings'
        )) {
            $resultPayload[$property.Name] = @($property.Value)
        } else {
            $resultPayload[$property.Name] = $property.Value
        }
    }
    $result = [ordered]@{}
    foreach ($name in $resultPayload.Keys) { $result[$name] = $resultPayload[$name] }
    $result.receipt_hash = Get-ThreadResultReceiptCanonicalHash `
        -Receipt ([pscustomobject]$result)
    $blocking = @($inventory.decisions | Where-Object {
        [string]$_.severity -in @('P0', 'P1') -and
        [string]$_.resolution_status -ne 'resolved'
    } | ForEach-Object { [string]$_.finding })
    $dispositionPayload = [ordered]@{}
    foreach ($property in $currentDisposition.PSObject.Properties) {
        if ($property.Name -eq 'receipt_hash') { continue }
        switch ($property.Name) {
            'source_result_receipt_path' {
                $dispositionPayload[$property.Name] = $resultRelativePath
            }
            'source_result_receipt_hash' {
                $dispositionPayload[$property.Name] = [string]$result.receipt_hash
            }
            'decisions' {
                $dispositionPayload[$property.Name] = @($inventory.decisions)
            }
            'blocking_open' {
                $dispositionPayload[$property.Name] = $blocking
            }
            default { $dispositionPayload[$property.Name] = $property.Value }
        }
    }
    $disposition = [ordered]@{}
    foreach ($name in $dispositionPayload.Keys) {
        $disposition[$name] = $dispositionPayload[$name]
    }
    $disposition.receipt_hash = Get-TextSha256 (
        $dispositionPayload | ConvertTo-Json -Compress -Depth 100
    )
    $effectiveSelectionItems.Add([pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        disposition_receipt_path = $dispositionRelativePath
    })
    $artifactPlans.Add([pscustomobject]@{
        required_source = $requiredSource
        source_kind = [string]$currentResult.source_kind
        rearm = $rearms[0]
        completed = $completed
        validated = $validated
        adopted = $adopted
        previous_binding = $previousBinding
        current_binding = $currentBinding
        inventory = $inventory
        result = $result
        result_path = $resultPath
        result_relative_path = $resultRelativePath
        disposition = $disposition
        disposition_path = $dispositionPath
        disposition_relative_path = $dispositionRelativePath
    })
}
if ($restoredTotal -lt 1) {
    throw 'Milestone revision inventory supersession found no omitted occurrence.'
}
} finally {
    Exit-OrchestrationValidationContext -Token $validationToken
}

if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $receiptDirectory
}
if (-not (Test-Path -LiteralPath $materialDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $materialDirectory
}
$effectiveSelectionName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$revisionToken.inventory-superseded-selection.json"
)
$effectiveSelectionPath = Join-Path $materialDirectory $effectiveSelectionName
$receiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).inventory-supersession.json"
)
$receiptPath = Join-Path $receiptDirectory $receiptName
if ((Test-Path -LiteralPath $effectiveSelectionPath) -or
    (Test-Path -LiteralPath $receiptPath)) {
    throw 'Milestone revision inventory supersession already exists.'
}
$temporaryPaths = [Collections.Generic.List[string]]::new()
$movedPaths = [Collections.Generic.List[string]]::new()
try {
    foreach ($artifactPlan in @($artifactPlans)) {
        $artifactPlan | Add-Member -NotePropertyName result_temp -NotePropertyValue (
            $artifactPlan.result_path + '.tmp.' + [guid]::NewGuid().ToString('N')
        )
        $artifactPlan | Add-Member -NotePropertyName disposition_temp `
            -NotePropertyValue (
                $artifactPlan.disposition_path + '.tmp.' +
                [guid]::NewGuid().ToString('N')
            )
        $artifactPlan.result | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $artifactPlan.result_temp -Encoding utf8
        $artifactPlan.disposition | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $artifactPlan.disposition_temp -Encoding utf8
        $temporaryPaths.Add([string]$artifactPlan.result_temp)
        $temporaryPaths.Add([string]$artifactPlan.disposition_temp)
    }
    $selectionTemp = $effectiveSelectionPath + '.tmp.' +
        [guid]::NewGuid().ToString('N')
    @($effectiveSelectionItems) | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $selectionTemp -Encoding utf8
    $temporaryPaths.Add($selectionTemp)
    $sourceSupersessions = [Collections.Generic.List[object]]::new()
    foreach ($artifactPlan in @($artifactPlans)) {
        $supersededBinding = [pscustomobject][ordered]@{
            source_node_id = [string]$artifactPlan.required_source.source_node_id
            source_thread_id = [string]$artifactPlan.required_source.thread_id
            milestone_id = [string]$authorization.milestone_id
            checkpoint_material_path =
                [string]$authorization.checkpoint_material_path
            checkpoint_material_hash =
                [string]$authorization.checkpoint_material_hash
            result_receipt_path = [string]$artifactPlan.result_relative_path
            result_receipt_hash = [string]$artifactPlan.result.receipt_hash
            result_file_hash = (
                Get-FileHash -LiteralPath $artifactPlan.result_temp `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            disposition_receipt_path =
                [string]$artifactPlan.disposition_relative_path
            disposition_receipt_hash =
                [string]$artifactPlan.disposition.receipt_hash
            disposition_file_hash = (
                Get-FileHash -LiteralPath $artifactPlan.disposition_temp `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
        $sourceSupersessions.Add([pscustomobject][ordered]@{
            source_node_id =
                [string]$artifactPlan.required_source.source_node_id
            role_id = [string]$artifactPlan.required_source.role_id
            source_thread_id = [string]$artifactPlan.required_source.thread_id
            source_kind = [string]$artifactPlan.source_kind
            rearm_event_sequence = [int]$artifactPlan.rearm.sequence
            rearm_event_hash = [string]$artifactPlan.rearm.hash
            completed_event_sequence = [int]$artifactPlan.completed.sequence
            completed_event_hash = [string]$artifactPlan.completed.hash
            validated_event_sequence = [int]$artifactPlan.validated.sequence
            validated_event_hash = [string]$artifactPlan.validated.hash
            adopted_event_sequence = [int]$artifactPlan.adopted.sequence
            adopted_event_hash = [string]$artifactPlan.adopted.hash
            previous_binding = $artifactPlan.previous_binding
            current_binding = $artifactPlan.current_binding
            superseded_binding = $supersededBinding
            restored_occurrences =
                @($artifactPlan.inventory.restored_occurrences)
            restored_occurrences_hash =
                [string]$artifactPlan.inventory.restored_occurrences_hash
            restored_occurrence_count =
                [int]$artifactPlan.inventory.restored_occurrence_count
            effective_pending_findings_hash =
                [string]$artifactPlan.inventory.pending_findings_hash
            effective_decisions_hash =
                [string]$artifactPlan.inventory.decisions_hash
        })
    }
    $relative = {
        param([string] $Value)
        [IO.Path]::GetRelativePath($runRoot, $Value).Replace('\', '/')
    }
    $payload = [ordered]@{
        schema_version = '1.0'
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        genesis_hash = [string]$events[0].hash
        milestone_id = [string]$authorization.milestone_id
        milestone_index = 0
        revision_id = [string]$authorization.revision_id
        revision_index = [int]$authorization.revision_index
        authorization_receipt_path = & $relative $AuthorizationReceiptPath
        authorization_receipt_hash = [string]$authorization.receipt_hash
        selection_key = [string]$authorization.selection_key
        source_journal_head = [string]$events[-1].hash
        source_journal_event_count = $events.Count
        checkpoint_material_path = [string]$authorization.checkpoint_material_path
        checkpoint_material_hash = [string]$authorization.checkpoint_material_hash
        input_manifest_path = [string]$authorization.input_manifest_path
        input_manifest_hash = [string]$authorization.input_manifest_hash
        original_selection_material_path = & $relative $SelectionMaterialPath
        original_selection_material_hash = (
            Get-FileHash -LiteralPath $SelectionMaterialPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        superseded_selection_material_path =
            "materials/$effectiveSelectionName"
        superseded_selection_material_hash = (
            Get-FileHash -LiteralPath $selectionTemp -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        source_supersessions = @($sourceSupersessions)
        source_supersessions_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @($sourceSupersessions) `
                -Compress -Depth 100
        )
        authorization_material_path = & $relative $AuthorizationMaterialPath
        authorization_material_hash = (
            Get-FileHash -LiteralPath $AuthorizationMaterialPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        supersession_key = $SupersessionKey
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $receipt = [ordered]@{}
    foreach ($name in $payload.Keys) { $receipt[$name] = $payload[$name] }
    $receipt.receipt_hash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 100
    )
    $receiptTemp = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
    $receipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $receiptTemp -Encoding utf8
    $temporaryPaths.Add($receiptTemp)

    $mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
    try {
        if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
            throw 'Timed out waiting for the orchestration journal lock.'
        }
        $current = @(Read-OrchestrationJournal $eventsPath)
        if ($current.Count -ne $events.Count -or
            [string]$current[-1].hash -ne [string]$events[-1].hash) {
            throw 'The journal changed while inventory supersession was prepared.'
        }
        Assert-OrchestrationValidationContextUnchanged `
            -Context $validationToken.context -AllowAdditionalFiles
        try {
            foreach ($artifactPlan in @($artifactPlans)) {
                Move-Item -LiteralPath $artifactPlan.result_temp `
                    -Destination $artifactPlan.result_path
                $movedPaths.Add([string]$artifactPlan.result_path)
                Move-Item -LiteralPath $artifactPlan.disposition_temp `
                    -Destination $artifactPlan.disposition_path
                $movedPaths.Add([string]$artifactPlan.disposition_path)
            }
            Move-Item -LiteralPath $selectionTemp `
                -Destination $effectiveSelectionPath
            $movedPaths.Add($effectiveSelectionPath)
            Move-Item -LiteralPath $receiptTemp -Destination $receiptPath
            $movedPaths.Add($receiptPath)
            $event = New-MilestoneRevisionJournalEvent -Plan $plan -Run $run `
                -Events $current -RunDirectory $runRoot `
                -EventName 'milestone-revision-inventory-superseded' `
                -ReceiptName $receiptName -Receipt $receipt `
                -Message (
                    "Restored cumulative finding inventory for revision " +
                    "'$($authorization.revision_id)' without changing source state."
                ) -IdempotencyKey $SupersessionKey
            Add-Content -LiteralPath $eventsPath -Value (
                $event | ConvertTo-Json -Compress -Depth 100
            )
        } catch {
            foreach ($movedPath in @($movedPaths)) {
                Remove-Item -LiteralPath $movedPath -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
} finally {
    foreach ($temporaryPath in @($temporaryPaths)) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}
$verified = Read-DurableReviewMilestoneRevisionInventorySupersession `
    -Path $receiptPath -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
