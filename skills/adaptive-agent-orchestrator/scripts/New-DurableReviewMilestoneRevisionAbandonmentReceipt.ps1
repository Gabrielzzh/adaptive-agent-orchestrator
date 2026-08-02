[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationReceiptPath,
    [Parameter(Mandatory)][string] $InvalidityAuditMaterialPath,
    [Parameter(Mandatory)][string] $AbandonmentKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$eventsPath = Join-Path $runRoot 'events.jsonl'
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$events = @(Read-OrchestrationJournal $eventsPath)
if ($AbandonmentKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Revision abandonment requires a stable user: or controller: key.'
}

function Resolve-RunLocalFile {
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

$authorizationPath = Resolve-RunLocalFile `
    -Path $AuthorizationReceiptPath -Label 'Revision authorization receipt'
$auditPath = Resolve-RunLocalFile `
    -Path $InvalidityAuditMaterialPath -Label 'Revision invalidity audit material'
$authorizationRelative = [IO.Path]::GetRelativePath(
    $runRoot, $authorizationPath
).Replace('\', '/')
$auditRelative = [IO.Path]::GetRelativePath($runRoot, $auditPath).Replace('\', '/')
$authorization = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $authorizationPath -RunDirectory $runRoot
$audit = Get-Content -LiteralPath $auditPath -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String

$authEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-authorized' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id -and
    [string]$_.milestone_revision_authorization_receipt_path -eq
        $authorizationRelative -and
    [string]$_.milestone_revision_authorization_receipt_hash -eq
        [string]$authorization.receipt_hash
})
if ($authEvents.Count -ne 1) {
    throw 'Pending revision abandonment requires one exact authorization event.'
}
$authEvent = $authEvents[0]
$selectionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-selected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$existingAbandonment = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-abandoned' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
if ($selectionEvents.Count -gt 0 -or $existingAbandonment.Count -gt 0) {
    throw 'Only an unselected, not-yet-abandoned revision may be abandoned.'
}

$requiredSources = @($authorization.required_sources)
$rearmBindings = [Collections.Generic.List[object]]::new()
foreach ($requiredSource in $requiredSources) {
    $sourceNodeId = [string]$requiredSource.source_node_id
    $sourceEvents = @($events | Where-Object {
        [string]$_.node_id -eq $sourceNodeId -and
        [int]$_.sequence -gt [int]$authEvent.sequence
    })
    $rearms = @($sourceEvents | Where-Object {
        [string]$_.prior_state -eq 'adopted' -and
        [string]$_.status -eq 'running' -and
        [string]$_.thread_id -eq [string]$requiredSource.thread_id -and
        [string]$_.role_id -eq [string]$requiredSource.role_id -and
        [string]$_.milestone_revision_id -eq [string]$authorization.revision_id -and
        [string]$_.milestone_revision_authorization_receipt_hash -eq
            [string]$authorization.receipt_hash
    })
    if ($rearms.Count -ne 1 -or $sourceEvents.Count -ne 1) {
        throw (
            "Revision '$($authorization.revision_id)' has a result, lifecycle, " +
            "duplicate re-arm, or incomplete source '$sourceNodeId'."
        )
    }
    $rearmBindings.Add([ordered]@{
        source_node_id = $sourceNodeId
        role_id = [string]$requiredSource.role_id
        thread_id = [string]$requiredSource.thread_id
        event_sequence = [int]$rearms[0].sequence
        event_hash = [string]$rearms[0].hash
        prior_state = 'adopted'
        status = 'running'
    })
}

foreach ($name in @('failed_input_binding', 'source_finding')) {
    if ($null -eq $audit.PSObject.Properties[$name]) {
        throw "Revision invalidity audit is missing '$name'."
    }
}
$failedInput = $audit.failed_input_binding
$finding = $audit.source_finding
$failureClass = [string]$failedInput.failure_class
if ($failureClass -notin @(
    'matrix_path_hash_object_mismatch',
    'control-material-path-hash-mismatch'
)) {
    throw 'Revision invalidity audit failure class is not a control-material mismatch.'
}
$inputPath = Resolve-RunLocalFile `
    -Path (Join-Path $runRoot ([string]$authorization.input_manifest_path)) `
    -Label 'Revision input manifest'
$inputText = Get-Content -LiteralPath $inputPath -Raw
$inputHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($inputHash -ne [string]$authorization.input_manifest_hash -or
    [string]$failedInput.input_manifest_path -ne
        [string]$authorization.input_manifest_path -or
    [string]$failedInput.input_manifest_sha256 -ne $inputHash) {
    throw 'Revision invalidity audit input binding changed.'
}
$input = $inputText | ConvertFrom-Json -Depth 50 -DateKind String
$controlPathProperty = if ($null -ne $failedInput.PSObject.Properties['control_path_property']) {
    [string]$failedInput.control_path_property
} else { 'matrix_path' }
$controlHashProperty = if ($null -ne $failedInput.PSObject.Properties['control_hash_property']) {
    [string]$failedInput.control_hash_property
} else { 'matrix_hash' }
if ($null -eq $input.PSObject.Properties[$controlPathProperty] -or
    $null -eq $input.PSObject.Properties[$controlHashProperty]) {
    throw 'Revision input does not contain the audited control path/hash properties.'
}
$declaredPath = [string]$input.$controlPathProperty
$declaredHash = [string]$input.$controlHashProperty
$declaredFile = Resolve-RunLocalFile -Path (Join-Path $runRoot $declaredPath) `
    -Label 'Audited control file'
$actualHash = (Get-FileHash -LiteralPath $declaredFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -eq $declaredHash) {
    throw 'Revision input control path and hash are already consistent.'
}
if ($null -ne $failedInput.PSObject.Properties['declared_matrix_path'] -and
    [string]$failedInput.declared_matrix_path -ne $declaredPath) {
    throw 'Revision invalidity audit declared path changed.'
}
if ($null -ne $failedInput.PSObject.Properties['declared_matrix_hash'] -and
    [string]$failedInput.declared_matrix_hash -ne $declaredHash) {
    throw 'Revision invalidity audit declared hash changed.'
}
if ($null -ne $failedInput.PSObject.Properties[
    'actual_declared_matrix_path_sha256'
]) {
    if ([string]$failedInput.actual_declared_matrix_path_sha256 -ne $actualHash) {
        throw 'Revision invalidity audit actual control hash changed.'
    }
}
$otherObjectPath = $null
if ($null -ne $failedInput.PSObject.Properties[
    'actual_object_for_declared_matrix_hash'
]) {
    $otherObjectPath = [string]$failedInput.actual_object_for_declared_matrix_hash
}
if ([string]::IsNullOrWhiteSpace($otherObjectPath) -or
    [string]$otherObjectPath -eq [string]$declaredPath -or
    $declaredHash -notmatch '^[0-9a-fA-F]{64}$' -or
    $actualHash -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'Revision invalidity audit must bind two distinct SHA-256 objects.'
}
$otherObjectFull = Resolve-RunLocalFile `
    -Path (Join-Path $runRoot $otherObjectPath) `
    -Label 'Audited declared-hash object'
$otherObjectHash = (Get-FileHash -LiteralPath $otherObjectFull -Algorithm SHA256).
    Hash.ToLowerInvariant()
if ($otherObjectHash -ne $declaredHash.ToLowerInvariant()) {
    throw 'Revision invalidity audit declared hash object does not match its hash.'
}
foreach ($name in @('source_finding_id', 'canonical_finding_id', 'severity', 'status', 'exact_text')) {
    if ($null -eq $finding.PSObject.Properties[$name]) {
        throw "Revision invalidity audit finding is missing '$name'."
    }
}
if ([string]$finding.severity -notin @('P0', 'P1') -or
    [string]$finding.status -ne 'open' -or
    [string]::IsNullOrWhiteSpace([string]$finding.exact_text) -or
    ($null -ne $finding.PSObject.Properties['finding_hash'] -and
        [string]$finding.finding_hash -ne (Get-TextSha256 ([string]$finding.exact_text)))) {
    throw 'Revision invalidity audit finding identity or status changed.'
}
if ($null -ne $finding.PSObject.Properties['source_node_id'] -and
    [string]$finding.source_node_id -notin @($requiredSources.source_node_id)) {
    throw 'Revision invalidity audit finding source changed.'
}
$pendingFindingPath = $null
if ($null -ne $finding.PSObject.Properties['pending_finding_material_path']) {
    $pendingFindingPath = Resolve-RunLocalFile `
        -Path (Join-Path $runRoot ([string]$finding.pending_finding_material_path)) `
        -Label 'Pending finding material'
    $pendingFindingHash = (Get-FileHash -LiteralPath $pendingFindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($null -ne $finding.PSObject.Properties['pending_finding_material_sha256'] -and
        [string]$finding.pending_finding_material_sha256 -ne $pendingFindingHash) {
        throw 'Revision pending finding material changed.'
    }
    $pendingRecords = @(
        Get-Content -LiteralPath $pendingFindingPath -Raw |
            ConvertFrom-Json -Depth 50 -DateKind String
    ) | Where-Object {
        [string]$_.finding_id -eq [string]$finding.source_finding_id
    }
    if ($pendingRecords.Count -ne 1 -or
        [string]$pendingRecords[0].severity -ne [string]$finding.severity -or
        [string]$pendingRecords[0].text -ne [string]$finding.exact_text) {
        throw 'Revision invalidity audit finding is not bound to its pending material.'
    }
} else {
    $priorDecisionMatches = [Collections.Generic.List[object]]::new()
    foreach ($previousBinding in @($authorization.previous_source_bindings)) {
        if ([string]$previousBinding.source_node_id -ne
                [string]$finding.source_node_id) { continue }
        $previousDispositionPath = Resolve-RunLocalFile `
            -Path (Join-Path $runRoot ([string]$previousBinding.disposition_receipt_path)) `
            -Label 'Previous source disposition'
        $previousDisposition = Get-Content -LiteralPath $previousDispositionPath -Raw |
            ConvertFrom-Json -Depth 100 -DateKind String
        $priorDecisionMatches.AddRange(@($previousDisposition.decisions | Where-Object {
            [string]$_.source_finding_id -eq [string]$finding.source_finding_id
        }))
    }
    if ($priorDecisionMatches.Count -ne 1 -or
        [string]$priorDecisionMatches[0].canonical_finding_id -ne
            [string]$finding.canonical_finding_id -or
        [string]$priorDecisionMatches[0].severity -ne [string]$finding.severity -or
        [string]$priorDecisionMatches[0].finding -ne [string]$finding.exact_text -or
        [string]$priorDecisionMatches[0].finding_hash -ne
            (Get-TextSha256 ([string]$finding.exact_text)) -or
        [string]$priorDecisionMatches[0].resolution_status -ne
            [string]$finding.status) {
        throw 'Revision invalidity audit finding is not bound to prior source inventory.'
    }
}
$cumulative = [Collections.Generic.List[object]]::new()
$cumulativeKeys = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$expectedCumulativeKeys = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
if ($null -eq $audit.PSObject.Properties['cumulative_source_inventory']) {
    throw 'Revision invalidity audit must carry the simple cumulative source inventory.'
}
foreach ($previousBinding in @($authorization.previous_source_bindings)) {
    $previousDispositionPath = Resolve-RunLocalFile `
        -Path (Join-Path $runRoot ([string]$previousBinding.disposition_receipt_path)) `
        -Label 'Previous source disposition'
    $previousDisposition = Read-ReviewDispositionReceipt `
        -Path $previousDispositionPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId ([string]$previousBinding.source_node_id) `
        -ExpectedThreadId ([string]$previousBinding.source_thread_id)
    foreach ($decision in @($previousDisposition.decisions)) {
        if ([string]::IsNullOrWhiteSpace([string]$decision.source_finding_id) -or
            -not $expectedCumulativeKeys.Add(
                "$($previousBinding.source_node_id)`n$($decision.source_finding_id)"
            )) {
            throw 'Previous source disposition contains a duplicate or empty finding.'
        }
        $cumulative.Add(
            (New-DurableReviewOccurrenceDescriptor `
                -SourceNodeId ([string]$previousBinding.source_node_id) `
                -Decision $decision)
        )
    }
}

if ($cumulative.Count -lt 1) {
    throw 'Revision cumulative source inventory is incomplete or duplicated.'
}
$auditDescriptors = @($audit.cumulative_source_occurrence_descriptors)
$expectedJson = ConvertTo-Json -InputObject @($cumulative) -Compress -Depth 50
$auditJson = ConvertTo-Json -InputObject @(
    $auditDescriptors | ForEach-Object {
        ConvertTo-DurableReviewOccurrenceDescriptor `
            -SourceNodeId ([string]$_.source_node_id) -Descriptor $_
    }
) -Compress -Depth 50
if ($auditDescriptors.Count -ne $cumulative.Count -or $auditJson -ne $expectedJson) {
    throw 'Revision cumulative source occurrence descriptors changed.'
}
$auditInventoryKeys = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($property in $audit.cumulative_source_inventory.PSObject.Properties) {
    if ([string]$property.Name -eq 'total_source_occurrences') { continue }
    $sourceNodeId = switch ([string]$property.Name) {
        'traditional' { 'liuyao-traditional-source' }
        'adversarial' { 'liuyao-adversarial-source' }
        default { [string]$property.Name }
    }
    foreach ($findingId in @($property.Value)) {
        $null = $auditInventoryKeys.Add(
            "$sourceNodeId`n$([string]$findingId)"
        )
    }
}
if ([int]$audit.cumulative_source_inventory.total_source_occurrences -ne
        $expectedCumulativeKeys.Count -or
    $auditInventoryKeys.Count -ne $expectedCumulativeKeys.Count -or
    @($auditInventoryKeys | Where-Object {
        -not $expectedCumulativeKeys.Contains($_)
    }).Count -gt 0) {
    throw 'Revision cumulative source inventory changed.'
}
$cumulativeKeys = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($descriptor in @($cumulative)) {
    if (-not $cumulativeKeys.Add(
        "$($descriptor.source_node_id)`n$($descriptor.source_finding_id)"
    )) {
        throw 'Revision cumulative source inventory is incomplete or duplicated.'
    }
}
if ($expectedCumulativeKeys.Count -eq 0 -or
    $expectedCumulativeKeys.Count -ne $cumulativeKeys.Count -or
    @($expectedCumulativeKeys | Where-Object {
        -not $cumulativeKeys.Contains($_)
    }).Count -gt 0 -or
    @($cumulativeKeys | Where-Object {
        -not $expectedCumulativeKeys.Contains($_)
    }).Count -gt 0) {
    throw (
        'Revision cumulative source inventory must conserve every prior source ' +
        'finding occurrence exactly.'
    )
}
$cumulativeJson = ConvertTo-Json -InputObject @($cumulative) -Compress -Depth 50

$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = (
    "durable-review-milestone.$($authorization.milestone_id).revision-" +
    "$($authorization.revision_id).abandonment.json"
)
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    throw 'The milestone revision already has an abandonment receipt.'
}
$relative = { param([string]$Path) [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/') }
$payload = [ordered]@{
    schema_version = '1.0'
    receipt_type = 'milestone-revision-abandonment'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    genesis_hash = [string]$events[0].hash
    milestone_id = [string]$authorization.milestone_id
    milestone_index = [int]$authorization.milestone_index
    revision_id = [string]$authorization.revision_id
    revision_index = [int]$authorization.revision_index
    authorization_receipt_path = $authorizationRelative
    authorization_receipt_hash = [string]$authorization.receipt_hash
    authorization_receipt_file_hash = (Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    authorization_event_sequence = [int]$authEvent.sequence
    authorization_event_hash = [string]$authEvent.hash
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    source_journal_file_hash = (Get-FileHash -LiteralPath $eventsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    checkpoint_material_path = [string]$authorization.checkpoint_material_path
    checkpoint_material_hash = [string]$authorization.checkpoint_material_hash
    input_manifest_path = [string]$authorization.input_manifest_path
    input_manifest_hash = [string]$authorization.input_manifest_hash
    required_sources = @($requiredSources)
    required_sources_hash = [string]$authorization.required_sources_hash
    source_rearm_events = @($rearmBindings)
    source_rearm_events_hash = Get-TextSha256 (ConvertTo-Json -InputObject @($rearmBindings) -Compress -Depth 30)
    invalidity_audit_material_path = $auditRelative
    invalidity_audit_material_hash = (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash.ToLowerInvariant()
    invalidity_audit = [ordered]@{
        failure_class = $failureClass
        control_path_property = $controlPathProperty
        control_hash_property = $controlHashProperty
        declared_path = $declaredPath
        declared_hash = $declaredHash
        actual_file_hash = $actualHash
        declared_hash_object_path = $otherObjectPath
        finding = [ordered]@{
            source_node_id = if ($null -ne $finding.PSObject.Properties['source_node_id']) { [string]$finding.source_node_id } else { $null }
            source_finding_id = [string]$finding.source_finding_id
            canonical_finding_id = [string]$finding.canonical_finding_id
            severity = [string]$finding.severity
            status = [string]$finding.status
            exact_text = [string]$finding.exact_text
            finding_hash = Get-TextSha256 ([string]$finding.exact_text)
        }
        pending_finding_material_path = if ($pendingFindingPath) { & $relative $pendingFindingPath } else { $null }
        pending_finding_material_hash = if ($pendingFindingPath) { (Get-FileHash -LiteralPath $pendingFindingPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        raw_evidence_non_adoptable = $true
    }
    cumulative_source_occurrences = @($cumulative)
    cumulative_source_occurrences_hash = Get-TextSha256 $cumulativeJson
    cumulative_source_occurrence_count = $cumulative.Count
    decision = 'abandoned'
    completion_eligible = $false
    source_evidence_eligible = $false
    abandonment_key = $AbandonmentKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 100)
if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $receiptDirectory -Force
}
$temp = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
$receipt | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temp -Encoding utf8
$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the orchestration journal lock.'
    }
    $current = @(Read-OrchestrationJournal $eventsPath)
    if ($current.Count -ne $events.Count -or
        [string]$current[-1].hash -ne [string]$events[-1].hash) {
        throw 'The journal changed while revision abandonment was prepared.'
    }
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $append = [Collections.Generic.List[string]]::new()
    $abandonmentEvent = [ordered]@{
        sequence = $current.Count
        prev_hash = [string]$current[-1].hash
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'milestone-revision-abandoned'
        run_id = [string]$run.run_id
        plan_hash = [string]$run.plan_hash
        workspace_root = [string]$run.workspace_root
        policy_version = [string]$plan.policy_version
        actor = [string]$plan.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'cancelled'
        milestone_id = [string]$authorization.milestone_id
        milestone_revision_id = [string]$authorization.revision_id
        milestone_revision_authorization_receipt_path = $authorizationRelative
        milestone_revision_authorization_receipt_hash = [string]$authorization.receipt_hash
        milestone_revision_checkpoint_hash = [string]$authorization.checkpoint_material_hash
        milestone_revision_input_hash = [string]$authorization.input_manifest_hash
        milestone_revision_selection_key = [string]$authorization.selection_key
        milestone_revision_abandonment_receipt_path = "receipts/$receiptName"
        milestone_revision_abandonment_receipt_hash = [string]$receipt.receipt_hash
        message = "Abandoned invalid pending revision '$($authorization.revision_id)'."
        thread_id = $null
        model_id = $null
        artifact = "receipts/$receiptName"
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
        error_class = 'invalid_revision_control_material'
        decision = 'abandoned'
        human_actor = $AbandonmentKey
        evidence = @(
            "artifact:receipts/$receiptName",
            "artifact:$auditRelative",
            'observation:no-result-adoptable'
        )
        recovery_receipt_path = $null
        recovery_receipt_hash = $null
        replacement_receipt_path = $null
        replacement_receipt_hash = $null
        result_receipt_path = $null
        result_receipt_hash = $null
        idempotency_key = $AbandonmentKey
        request_fingerprint = [string]$receipt.receipt_hash
    }
    $abandonmentEvent.hash = Get-OrchestrationEventHash ([pscustomobject]$abandonmentEvent)
    $append.Add(($abandonmentEvent | ConvertTo-Json -Compress -Depth 100))
    $next = $current + @([pscustomobject]$abandonmentEvent)
    foreach ($binding in @($rearmBindings)) {
        $sourceEvent = [ordered]@{
            sequence = $next.Count
            prev_hash = [string]$next[-1].hash
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            event = 'node-status'
            run_id = [string]$run.run_id
            plan_hash = [string]$run.plan_hash
            workspace_root = [string]$run.workspace_root
            policy_version = [string]$plan.policy_version
            actor = [string]$plan.orchestrator.id
            node_id = [string]$binding.source_node_id
            role_id = [string]$binding.role_id
            prior_state = 'running'
            status = 'cancelled'
            milestone_id = [string]$authorization.milestone_id
            milestone_revision_id = [string]$authorization.revision_id
            milestone_revision_authorization_receipt_path = $authorizationRelative
            milestone_revision_authorization_receipt_hash = [string]$authorization.receipt_hash
            milestone_revision_checkpoint_hash = [string]$authorization.checkpoint_material_hash
            milestone_revision_input_hash = [string]$authorization.input_manifest_hash
            milestone_revision_selection_key = [string]$authorization.selection_key
            milestone_revision_abandonment_receipt_path = "receipts/$receiptName"
            milestone_revision_abandonment_receipt_hash = [string]$receipt.receipt_hash
            message = "Cancelled source '$($binding.source_node_id)' with the abandoned revision."
            thread_id = [string]$binding.thread_id
            model_id = $null
            artifact = "receipts/$receiptName"
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
            error_class = 'invalid_revision_control_material'
            decision = 'abandoned'
            human_actor = $AbandonmentKey
            evidence = @(
                "artifact:receipts/$receiptName",
                "artifact:$auditRelative",
                'observation:no-result-adoptable'
            )
            recovery_receipt_path = $null
            recovery_receipt_hash = $null
            replacement_receipt_path = $null
            replacement_receipt_hash = $null
            result_receipt_path = $null
            result_receipt_hash = $null
            idempotency_key = "$($AbandonmentKey):$($binding.source_node_id)"
            request_fingerprint = Get-TextSha256 (
                "$($receipt.receipt_hash)|$($binding.source_node_id)|cancelled"
            )
        }
        $sourceEvent.hash = Get-OrchestrationEventHash ([pscustomobject]$sourceEvent)
        $append.Add(($sourceEvent | ConvertTo-Json -Compress -Depth 100))
        $next += [pscustomobject]$sourceEvent
    }
    Add-Content -LiteralPath $eventsPath -Value ($append -join [Environment]::NewLine)
}
catch {
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Remove-Item -LiteralPath $receiptPath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String |
    ConvertTo-Json -Depth 100
