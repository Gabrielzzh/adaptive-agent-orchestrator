[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $MilestoneId,
    [Parameter(Mandatory)][string] $CheckpointMaterialPath,
    [Parameter(Mandatory)][string] $InputManifestPath,
    [Parameter(Mandatory)][string] $ReviewMaterialManifestPath,
    [Parameter(Mandatory)][string] $ExcludedEvidenceManifestPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $AcceptanceAuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $SelectionKey,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$planRaw = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw
$plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$eventsPath = Join-Path $runRoot 'events.jsonl'
$events = @(Read-OrchestrationJournal $eventsPath)
if ((Get-TextSha256 $planRaw) -ne [string]$run.plan_hash -or
    [string]$plan.run_id -ne [string]$run.run_id -or $events.Count -lt 1) {
    throw 'Milestone revision authorization run identity is inconsistent.'
}
if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
    throw 'Milestone revision authorization requires durable_review_profile.'
}
$milestoneIds = @(
    $plan.durable_review_profile.milestone_ids |
        ForEach-Object { [string]$_ }
)
if ($MilestoneId -ne $milestoneIds[0]) {
    throw 'Only the immutable first milestone can use checkpoint revision.'
}
if ($ActivationKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone revision requires a stable user: or controller: key.'
}
if ($SelectionKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone revision must pre-bind a stable selection key.'
}
$chain = Read-DurableReviewMilestoneActivationChain -RunDirectory $runRoot
if ([string]$chain.active_milestone_id -ne $MilestoneId) {
    throw 'A first-milestone revision cannot replace or skip a later milestone.'
}
$authorizedEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-authorized'
})
$selectedEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-selected'
})
if ($authorizedEvents.Count -ne $selectedEvents.Count) {
    throw 'A prior milestone revision authorization is still pending selection.'
}
$previousSelection = $null
$previousSelectionEvent = $null
$previousOpenInventory = $null
$finalAcceptancePresent = $false
if ($selectedEvents.Count -gt 0) {
    $acceptanceReceiptPath = Join-Path $runRoot (
        "receipts/durable-review-milestone.$MilestoneId.acceptance.json"
    )
    if (Test-Path -LiteralPath $acceptanceReceiptPath -PathType Leaf) {
        $null = Read-DurableReviewMilestoneAcceptance `
            -RunDirectory $runRoot -MilestoneChain $chain
        $finalAcceptancePresent = $true
    }
    if (@($events | Where-Object {
        [string]$_.event -eq 'milestone-accepted' -and
        [string]$_.milestone_id -eq $MilestoneId
    }).Count -gt 0) {
        $finalAcceptancePresent = $true
    }
    $previousSelection = $chain.activation_receipt
    $previousSelectionEvent = $selectedEvents[-1]
    if ($null -eq $previousSelection -or
        [string]$chain.activation_receipt_path -ne
            [string]$previousSelectionEvent.milestone_activation_receipt_path -or
        [string]$chain.activation_receipt_hash -ne
            [string]$previousSelectionEvent.milestone_activation_receipt_hash -or
        [int]$previousSelection.revision_index -ne $selectedEvents.Count) {
        throw 'The previous first-milestone revision selection is incomplete.'
    }
    $previousOpenInventory = Get-MilestoneRevisionOpenOccurrenceInventory `
        -RunDirectory $runRoot -Plan $plan -MilestoneId $MilestoneId `
        -SourceBindings @($chain.active_source_bindings)
} elseif (-not [string]::IsNullOrWhiteSpace(
    [string]$chain.activation_receipt_hash
)) {
    throw 'The first-milestone revision chain is inconsistent.'
}

function Resolve-RunFile {
    param([string] $Path, [string] $Label)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Label must be an existing file inside the run."
    }
    return $full
}

$checkpointPath = Resolve-RunFile $CheckpointMaterialPath 'Revision checkpoint'
$inputPath = Resolve-RunFile $InputManifestPath 'Revision input manifest'
$reviewManifestPath = Resolve-RunFile (
    $ReviewMaterialManifestPath
) 'Revision review material manifest'
$excludedManifestPath = Resolve-RunFile (
    $ExcludedEvidenceManifestPath
) 'Revision excluded evidence manifest'
$authorizationPath = Resolve-RunFile (
    $AuthorizationMaterialPath
) 'Revision controller authorization'
$acceptanceAuthorizationPath = Resolve-RunFile (
    $AcceptanceAuthorizationMaterialPath
) 'Revision acceptance authorization'
if ([string]::IsNullOrWhiteSpace(
    (Get-Content -LiteralPath $authorizationPath -Raw)
)) {
    throw 'Revision controller authorization cannot be empty.'
}

$requiredSourceIds = @(
    @($plan.durable_review_profile.domain_node_ids) +
    @($plan.durable_review_profile.dissent_node_ids) |
        ForEach-Object { [string]$_ }
)
$state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
    -RunDirectory $runRoot | ConvertFrom-Json -Depth 100
$reviewMaterials = @(
    Get-Content -LiteralPath $reviewManifestPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
)
if ($reviewMaterials.Count -ne $requiredSourceIds.Count) {
    throw 'Revision review material must bind every required source exactly once.'
}
$sourceBindings = [Collections.Generic.List[object]]::new()
$materialBindings = [Collections.Generic.List[object]]::new()
foreach ($sourceNodeId in $requiredSourceIds) {
    $node = @($plan.nodes | Where-Object {
        [string]$_.id -eq $sourceNodeId
    }) | Select-Object -First 1
    $nodeState = @($state.nodes | Where-Object {
        [string]$_.id -eq $sourceNodeId
    }) | Select-Object -First 1
    $material = @($reviewMaterials | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
    })
    $previousBinding = @($chain.active_source_bindings | Where-Object {
        [string]$_.source_node_id -eq $sourceNodeId
    })
    if ($null -eq $node -or $null -eq $nodeState -or
        [string]$nodeState.status -ne 'adopted' -or
        [string]::IsNullOrWhiteSpace([string]$nodeState.thread_id) -or
        $material.Count -ne 1 -or $previousBinding.Count -ne 1 -or
        [string]$previousBinding[0].source_thread_id -ne
            [string]$nodeState.thread_id) {
        throw (
            "Revision source '$sourceNodeId' must be uniquely materialized, " +
            'adopted on its existing durable thread, and assigned one review ' +
            'material.'
        )
    }
    $materialPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$material[0].material_path) `
        -Label "Revision material for '$sourceNodeId'"
    if (-not (Test-Path -LiteralPath $materialPath -PathType Leaf)) {
        throw "Revision material for '$sourceNodeId' does not exist."
    }
    $sourceBindings.Add([pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        role_id = [string]$node.role_id
        thread_id = [string]$nodeState.thread_id
    })
    $materialBindings.Add([pscustomobject][ordered]@{
        source_node_id = $sourceNodeId
        material_path = [IO.Path]::GetRelativePath(
            $runRoot, $materialPath
        ).Replace('\', '/')
        material_hash = (
            Get-FileHash -LiteralPath $materialPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    })
}

$checkpointHash = (
    Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$inputHash = (
    Get-FileHash -LiteralPath $inputPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$activeCheckpointHashes = @($chain.active_source_bindings |
    ForEach-Object { [string]$_.checkpoint_material_hash } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique)
if ($activeCheckpointHashes.Count -eq 1 -and
    $activeCheckpointHashes[0] -eq $checkpointHash) {
    throw 'The active first-milestone checkpoint cannot be revised in place.'
}
if ($null -ne $previousSelection -and
    [string]$previousSelection.input_manifest_hash -eq $inputHash) {
    throw 'A subsequent first-milestone revision requires a new input manifest.'
}
$expectedInventory = Get-MilestoneRevisionExcludedInventory `
    -RunDirectory $runRoot -Events $events `
    -RequiredSourceIds $requiredSourceIds -CheckpointHash $checkpointHash `
    -EventCount $events.Count
$expectedExcludedEvents = @($expectedInventory.events)
$expectedExcludedArtifacts = @($expectedInventory.artifacts)

$excluded = @(
    Get-Content -LiteralPath $excludedManifestPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
)
$seenExcluded = [Collections.Generic.HashSet[string]]::new()
$actualExcludedEvents = [Collections.Generic.List[object]]::new()
$actualExcludedArtifacts = [Collections.Generic.List[object]]::new()
foreach ($item in $excluded) {
    foreach ($name in @(
        'source_node_id', 'reason', 'event_bindings', 'artifacts'
    )) {
        if ($null -eq $item.PSObject.Properties[$name]) {
            throw "Excluded evidence entry is missing '$name'."
        }
    }
    $sourceNodeId = [string]$item.source_node_id
    if ($sourceNodeId -notin $requiredSourceIds -or
        [string]$item.reason -ne
            'caller-timing-error/non-completion evidence' -or
        -not $seenExcluded.Add($sourceNodeId)) {
        throw 'Revision excluded evidence manifest is invalid.'
    }
    foreach ($eventBinding in @($item.event_bindings)) {
        $sequence = [int]$eventBinding.sequence
        if ($sequence -lt 0 -or $sequence -ge $events.Count -or
            [string]$events[$sequence].hash -ne
                [string]$eventBinding.event_hash -or
            [string]$events[$sequence].node_id -ne $sourceNodeId) {
            throw 'Revision excluded event binding is invalid.'
        }
        $actualExcludedEvents.Add([pscustomobject]@{
            source_node_id = $sourceNodeId
            event_sequence = $sequence
            event_hash = [string]$eventBinding.event_hash
        })
    }
    foreach ($artifact in @($item.artifacts)) {
        foreach ($name in @('type', 'path', 'file_hash', 'internal_hash')) {
            if ($null -eq $artifact.PSObject.Properties[$name]) {
                throw "Excluded artifact binding is missing '$name'."
            }
        }
        $artifactPath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
            -RelativePath ([string]$artifact.path) `
            -Label 'Excluded pre-authorization artifact'
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
            [string]$artifact.file_hash -ne (
                Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()) {
            throw 'Revision excluded artifact file binding changed.'
        }
        if ([string]$artifact.type -ne 'capture') {
            $document = Get-Content -LiteralPath $artifactPath -Raw |
                ConvertFrom-Json -Depth 100 -DateKind String
            if ([string]$artifact.internal_hash -ne
                [string]$document.receipt_hash) {
                throw 'Revision excluded artifact internal hash changed.'
            }
        } elseif (-not [string]::IsNullOrEmpty(
            [string]$artifact.internal_hash
        )) {
            throw 'Raw excluded captures cannot claim an internal receipt hash.'
        }
        $actualExcludedArtifacts.Add([pscustomobject]@{
            key = "$sourceNodeId`n$([string]$artifact.path)"
            source_node_id = $sourceNodeId
            type = [string]$artifact.type
            path = ([string]$artifact.path).Replace('\', '/')
            file_hash = [string]$artifact.file_hash
            internal_hash = [string]$artifact.internal_hash
        })
    }
}
if ((ConvertTo-Json -InputObject @($actualExcludedEvents |
        Sort-Object source_node_id, event_sequence) -Compress -Depth 100) -ne
    (ConvertTo-Json -InputObject @($expectedExcludedEvents |
        Sort-Object source_node_id, event_sequence) -Compress -Depth 100) -or
    (ConvertTo-Json -InputObject @($actualExcludedArtifacts |
        Sort-Object key) -Compress -Depth 100) -ne
    (ConvertTo-Json -InputObject @($expectedExcludedArtifacts |
        Sort-Object key) -Compress -Depth 100)) {
    throw (
        'Revision excluded evidence manifest omitted or changed a related ' +
        'pre-authorization event or artifact.'
    )
}

$acceptanceAuthorization = Get-Content -LiteralPath (
    $acceptanceAuthorizationPath
) -Raw | ConvertFrom-Json -Depth 30 -DateKind String
$mainNodes = @($plan.nodes | Where-Object { [string]$_.kind -eq 'main' })
foreach ($name in @(
    'schema_version', 'milestone_id', 'main_node_id', 'acceptance_key',
    'evidence_material_path', 'evidence_material_hash'
)) {
    if ($null -eq $acceptanceAuthorization.PSObject.Properties[$name]) {
        throw "Revision acceptance authorization is missing '$name'."
    }
}
if ([string]$acceptanceAuthorization.schema_version -ne '1.0' -or
    [string]$acceptanceAuthorization.milestone_id -ne $MilestoneId -or
    $mainNodes.Count -ne 1 -or
    [string]$acceptanceAuthorization.main_node_id -ne
        [string]$mainNodes[0].id -or
    [string]$acceptanceAuthorization.acceptance_key -notmatch
        '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Revision acceptance authorization is invalid.'
}
$acceptanceEvidencePath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
    -RelativePath ([string]$acceptanceAuthorization.evidence_material_path) `
    -Label 'Revision acceptance evidence'
if (-not (Test-Path -LiteralPath $acceptanceEvidencePath -PathType Leaf) -or
    [string]$acceptanceAuthorization.evidence_material_hash -ne (
        Get-FileHash -LiteralPath $acceptanceEvidencePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()) {
    throw 'Revision acceptance evidence binding changed.'
}

if (@($selectedEvents | Where-Object {
    [string]$_.milestone_revision_checkpoint_hash -eq $checkpointHash
}).Count -gt 0) {
    throw 'The same checkpoint already has a selected milestone revision.'
}
if ($finalAcceptancePresent) {
    throw 'A finally accepted first milestone cannot be revised again.'
}
if ($selectedEvents.Count -gt 0 -and
    [int]$previousOpenInventory.count -lt 1) {
    throw (
        'A subsequent first-milestone revision requires unresolved P0/P1 ' +
        'occurrences from the selected predecessor.'
    )
}
$revisionSeed = [ordered]@{
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    milestone_id = $MilestoneId
    previous_activation_receipt_hash = [string]$chain.activation_receipt_hash
    checkpoint_material_hash = $checkpointHash
    input_manifest_hash = $inputHash
}
$revisionId = Get-TextSha256 (
    $revisionSeed | ConvertTo-Json -Compress -Depth 20
)
$selectionAuthorityPrefix = $SelectionKey.Split(':', 2)[0]
$boundSelectionKey = (
    "$selectionAuthorityPrefix`:milestone-revision-selection:$revisionId"
)
$receiptName = (
    "durable-review-milestone.$MilestoneId.revision-$revisionId." +
    'authorization.json'
)
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'Milestone revision authorization already exists.'
}
$relative = {
    param([string] $Path)
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$payload = [ordered]@{
    schema_version = if ($selectedEvents.Count -eq 0) { '1.0' } else { '1.1' }
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    genesis_hash = [string]$events[0].hash
    milestone_id = $MilestoneId
    milestone_index = 0
    revision_id = $revisionId
    revision_index = $selectedEvents.Count + 1
    previous_activation_receipt_path = [string]$chain.activation_receipt_path
    previous_activation_receipt_hash = [string]$chain.activation_receipt_hash
    previous_source_bindings = @($chain.active_source_bindings)
    previous_source_bindings_hash = Get-TextSha256 (
        @($chain.active_source_bindings) |
            ConvertTo-Json -Compress -Depth 30
    )
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    checkpoint_material_path = & $relative $checkpointPath
    checkpoint_material_hash = $checkpointHash
    input_manifest_path = & $relative $inputPath
    input_manifest_hash = $inputHash
    required_sources = @($sourceBindings)
    required_sources_hash = Get-TextSha256 (
        @($sourceBindings) | ConvertTo-Json -Compress -Depth 30
    )
    review_material_manifest_path = & $relative $reviewManifestPath
    review_material_manifest_hash = (
        Get-FileHash -LiteralPath $reviewManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    review_material_bindings = @($materialBindings)
    review_material_bindings_hash = Get-TextSha256 (
        @($materialBindings) | ConvertTo-Json -Compress -Depth 30
    )
    excluded_evidence_manifest_path = & $relative $excludedManifestPath
    excluded_evidence_manifest_hash = (
        Get-FileHash -LiteralPath $excludedManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    excluded_evidence = @($excluded)
    authorization_material_path = & $relative $authorizationPath
    authorization_material_hash = (
        Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    acceptance_authorization_material_path = & $relative (
        $acceptanceAuthorizationPath
    )
    acceptance_authorization_material_hash = (
        Get-FileHash -LiteralPath $acceptanceAuthorizationPath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    main_node_id = [string]$acceptanceAuthorization.main_node_id
    acceptance_key = [string]$acceptanceAuthorization.acceptance_key
    acceptance_evidence_material_path = [string](
        $acceptanceAuthorization.evidence_material_path
    )
    acceptance_evidence_material_hash = [string](
        $acceptanceAuthorization.evidence_material_hash
    )
    selection_authority_key = $SelectionKey
    selection_key = $boundSelectionKey
    activation_key = $ActivationKey
}
if ($selectedEvents.Count -gt 0) {
    $payload.previous_revision_selection_receipt_path =
        [string]$chain.activation_receipt_path
    $payload.previous_revision_selection_receipt_hash =
        [string]$previousSelection.receipt_hash
    $payload.previous_revision_selection_event_sequence =
        [int]$previousSelectionEvent.sequence
    $payload.previous_revision_selection_event_hash =
        [string]$previousSelectionEvent.hash
    $payload.previous_open_occurrences =
        @($previousOpenInventory.occurrences)
    $payload.previous_open_occurrences_hash =
        [string]$previousOpenInventory.hash
    $payload.previous_open_occurrence_count =
        [int]$previousOpenInventory.count
}
$payload.created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
if (-not (Test-Path -LiteralPath $receiptDirectory)) {
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
        throw 'The journal changed while revision authorization was prepared.'
    }
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $event = New-MilestoneRevisionJournalEvent -Plan $plan -Run $run `
        -Events $current -RunDirectory $runRoot `
        -EventName 'milestone-revision-authorized' `
        -ReceiptName $receiptName -Receipt $receipt `
        -Message "Authorized revision '$revisionId' for '$MilestoneId'." `
        -IdempotencyKey $ActivationKey
    try {
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 100
        )
    } catch {
        Remove-Item -LiteralPath $receiptPath -Force
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
$verified = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $receiptPath -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
