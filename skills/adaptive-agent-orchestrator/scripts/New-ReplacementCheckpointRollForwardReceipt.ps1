[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $ReplacementThreadId,
    [Parameter(Mandatory)][string] $ReplacementContinuityReceiptPath,
    [Parameter(Mandatory)][string] $PriorResultReceiptPath,
    [Parameter(Mandatory)][string] $PriorDispositionReceiptPath,
    [Parameter(Mandatory)][string] $TargetMilestoneId,
    [Parameter(Mandatory)][string] $CheckpointManifestPath,
    [Parameter(Mandatory)][string] $InputManifestPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
$node = @($plan.nodes | Where-Object {
    [string]$_.id -eq $SourceNodeId
}) | Select-Object -First 1
if ($null -eq $node -or
    [string]$node.kind -ne 'agent' -or
    [string]$node.topology -ne 'background-thread' -or
    -not [bool]$node.read_only -or [bool]$node.allow_delegation -or
    @($node.write_scope).Count -gt 0) {
    throw (
        'Replacement checkpoint roll-forward requires one read-only, ' +
        'non-delegating durable source.'
    )
}
if ($null -eq $plan.PSObject.Properties['durable_review_profile']) {
    throw 'Replacement checkpoint roll-forward requires durable_review_profile.'
}
if ($ActivationKey -notmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw (
        'Replacement checkpoint roll-forward requires a stable user: or ' +
        'controller: activation key.'
    )
}

function Resolve-RunFile {
    param([string] $Path, [string] $Label)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label must be an existing file inside the run."
    }
    return $fullPath
}

$continuityFullPath = Resolve-RunFile $ReplacementContinuityReceiptPath (
    'Replacement continuity receipt'
)
$continuity = Read-ReplacementContinuityReceipt `
    -Path $continuityFullPath -RunDirectory $runRoot `
    -ExpectedSourceNodeId $SourceNodeId `
    -ExpectedReplacementThreadId $ReplacementThreadId
$priorResultFullPath = Resolve-RunFile $PriorResultReceiptPath (
    'Prior replacement result receipt'
)
$priorResult = Read-ThreadResultReceipt -Path $priorResultFullPath `
    -ExpectedThreadId $ReplacementThreadId `
    -ExpectedSourceNodeId $SourceNodeId -RunDirectory $runRoot
$priorCheckpointFullPath = Resolve-RunFile (
    Join-Path $runRoot ([string]$priorResult.checkpoint_material_path)
) 'Prior replacement checkpoint material'
$priorCheckpointHash = Get-TextSha256 (
    Get-Content -LiteralPath $priorCheckpointFullPath -Raw
)
$priorDispositionFullPath = Resolve-RunFile $PriorDispositionReceiptPath (
    'Prior replacement disposition receipt'
)
$priorDisposition = Read-ReviewDispositionReceipt `
    -Path $priorDispositionFullPath -RunDirectory $runRoot `
    -ExpectedSourceNodeId $SourceNodeId `
    -ExpectedThreadId $ReplacementThreadId
$checkpointFullPath = Resolve-RunFile $CheckpointManifestPath (
    'Checkpoint manifest'
)
$inputFullPath = Resolve-RunFile $InputManifestPath 'Input manifest'
$authorizationFullPath = Resolve-RunFile $AuthorizationMaterialPath (
    'Authorization material'
)
if ([string]::IsNullOrWhiteSpace(
    (Get-Content -LiteralPath $authorizationFullPath -Raw)
)) {
    throw 'Replacement checkpoint roll-forward authorization cannot be empty.'
}

$milestones = @(
    $plan.durable_review_profile.milestone_ids |
        ForEach-Object { [string]$_ }
)
$activationEvents = @($events | Where-Object {
    [string]$_.event -in @(
        'milestone-activated', 'milestone-revision-selected'
    )
})
if ($activationEvents.Count -eq 0) {
    $activeMilestoneId = $milestones[0]
    $activeActivationPath = ''
    $activeActivationHash = Get-TextSha256 (
        "baseline|$([string]$run.run_id)|$([string]$run.plan_hash)|" +
        $activeMilestoneId
    )
} else {
    $activeActivationEvent = $activationEvents[-1]
    $activeMilestoneId = [string]$activeActivationEvent.milestone_id
    $activeActivationPath =
        [string]$activeActivationEvent.milestone_activation_receipt_path
    $activeActivationHash =
        [string]$activeActivationEvent.milestone_activation_receipt_hash
}
$activeMilestoneIndex = [Array]::IndexOf($milestones, $activeMilestoneId)
$nextMilestoneId = if (
    $activeMilestoneIndex -ge 0 -and
    $activeMilestoneIndex + 1 -lt $milestones.Count
) {
    [string]$milestones[$activeMilestoneIndex + 1]
} else { '' }
$chain = [pscustomobject]@{
    active_milestone_id = $activeMilestoneId
    activation_receipt_path = $activeActivationPath
    activation_receipt_hash = $activeActivationHash
    next_milestone_id = $nextMilestoneId
}
if ([string]$chain.next_milestone_id -ne $TargetMilestoneId) {
    throw (
        "Replacement checkpoint roll-forward target '$TargetMilestoneId' is " +
        "not the next milestone after '$($chain.active_milestone_id)'."
    )
}
if ([string]$priorResult.source_kind -ne 'replacement' -or
    [string]$priorResult.replacement_continuity_receipt_hash -ne
        [string]$continuity.receipt_hash -or
    [string]$priorResult.milestone_id -ne $TargetMilestoneId -or
    [string]$priorDisposition.milestone_id -ne $TargetMilestoneId -or
    [string]$priorDisposition.source_result_receipt_hash -ne
        [string]$priorResult.receipt_hash) {
    throw (
        'Replacement checkpoint roll-forward prior result, disposition, ' +
        'continuity, or target milestone does not match.'
    )
}

$sourceHistory = @($events | Where-Object {
    [string]$_.node_id -eq $SourceNodeId
})
if ($sourceHistory.Count -lt 3) {
    throw 'Replacement checkpoint roll-forward lacks a prior adopted result chain.'
}
$priorAdopted = $sourceHistory[-1]
$priorValidated = $sourceHistory[-2]
$priorCompleted = $sourceHistory[-3]
$priorResultRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, $priorResultFullPath
).Replace('\', '/')
$priorDispositionRelativePath = [IO.Path]::GetRelativePath(
    $runRoot, $priorDispositionFullPath
).Replace('\', '/')
if ([string]$priorCompleted.status -ne 'completed' -or
    [string]$priorValidated.status -ne 'validated' -or
    [string]$priorAdopted.status -ne 'adopted' -or
    [string]$priorCompleted.thread_id -ne $ReplacementThreadId -or
    [string]$priorValidated.thread_id -ne $ReplacementThreadId -or
    [string]$priorAdopted.thread_id -ne $ReplacementThreadId -or
    "artifact:$priorResultRelativePath" -notin @($priorCompleted.evidence) -or
    "artifact:$priorDispositionRelativePath" -notin
        @($priorValidated.evidence) -or
    "artifact:$priorDispositionRelativePath" -notin
        @($priorAdopted.evidence)) {
    throw (
        'Replacement checkpoint roll-forward requires the immediately prior ' +
        'completed, validated, and adopted replacement result chain.'
    )
}

$replacementEvents = @($events | Where-Object {
    [string]$_.node_id -eq $SourceNodeId -and
    [string]$_.status -eq 'replacement_pending' -and
    [string]$_.thread_id -eq $ReplacementThreadId -and
    [string]$_.replacement_receipt_hash -eq
        [string]$continuity.receipt_hash
})
if ($replacementEvents.Count -ne 1) {
    throw (
        'Replacement checkpoint roll-forward requires one unique replacement ' +
        'materialization event.'
    )
}
$replacementEvent = $replacementEvents[0]
$replacementModelVerificationState = if (
    $null -ne $replacementEvent.PSObject.Properties[
        'model_verification_state'
    ]
) {
    [string]$replacementEvent.model_verification_state
} else { '' }
$actualModelState = if (-not [string]::IsNullOrWhiteSpace(
    [string]$replacementEvent.model_id
)) {
    'verified'
} elseif (
    $replacementModelVerificationState -eq 'unverified' -or
    @($replacementEvent.evidence | Where-Object {
        [string]$_ -match 'actual-model.*unverified|did-not-expose-actual-model'
    }).Count -gt 0
) {
    'unverified'
} else {
    throw (
        'Replacement materialization must identify its actual model as ' +
        'verified or unverified before roll-forward.'
    )
}
$actualModelId = if ($actualModelState -eq 'verified') {
    [string]$replacementEvent.model_id
} else { '' }

$checkpointHash = Get-TextSha256 (
    Get-Content -LiteralPath $checkpointFullPath -Raw
)
$inputHash = Get-TextSha256 (
    Get-Content -LiteralPath $inputFullPath -Raw
)
if ($checkpointHash -eq $priorCheckpointHash) {
    throw 'Replacement checkpoint roll-forward requires a new checkpoint.'
}
$authorizationHash = Get-TextSha256 (
    Get-Content -LiteralPath $authorizationFullPath -Raw
)
$identityPayload = [ordered]@{
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    source_node_id = $SourceNodeId
    role_id = [string]$node.role_id
    replacement_thread_id = $ReplacementThreadId
    replacement_continuity_receipt_hash = [string]$continuity.receipt_hash
    previous_adopted_event_hash = [string]$priorAdopted.hash
    active_milestone_id = [string]$chain.active_milestone_id
    active_milestone_activation_receipt_hash = [string](
        $chain.activation_receipt_hash
    )
    target_milestone_id = $TargetMilestoneId
    checkpoint_hash = $checkpointHash
    input_manifest_hash = $inputHash
    authorization_material_hash = $authorizationHash
    activation_key = $ActivationKey
}
$rollForwardId = Get-TextSha256 (
    $identityPayload | ConvertTo-Json -Compress -Depth 30
)
$expectedName = (
    "$SourceNodeId.replacement-roll-forward-$rollForwardId.json"
)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $runRoot 'receipts') $expectedName
}
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$canonicalReceiptDirectory = [IO.Path]::GetFullPath(
    (Join-Path $runRoot 'receipts')
).TrimEnd('\', '/')
if (-not [string]::Equals(
    (Split-Path -Parent $outputFullPath).TrimEnd('\', '/'),
    $canonicalReceiptDirectory,
    [StringComparison]::OrdinalIgnoreCase
) -or [IO.Path]::GetFileName($outputFullPath) -ne $expectedName) {
    throw (
        'Replacement checkpoint roll-forward must use its canonical run ' +
        'receipt path and filename.'
    )
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Replacement checkpoint roll-forward already exists: $outputFullPath"
}
$existingRollForwards = @(
    Get-ChildItem -LiteralPath $canonicalReceiptDirectory -File `
        -Filter "$SourceNodeId.replacement-roll-forward-*.json" `
        -ErrorAction SilentlyContinue
)
foreach ($existingPath in $existingRollForwards) {
    $existing = Read-ReplacementCheckpointRollForwardReceipt `
        -Path $existingPath.FullName -RunDirectory $runRoot `
        -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $ReplacementThreadId
    if ([string]$existing.active_milestone_activation_receipt_hash -eq
            [string]$chain.activation_receipt_hash -and
        [string]$existing.target_milestone_id -eq $TargetMilestoneId) {
        throw (
            'Replacement seat already has a checkpoint roll-forward for this ' +
            'next milestone.'
        )
    }
}

$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    source_node_id = $SourceNodeId
    role_id = [string]$node.role_id
    source_kind = 'replacement'
    replacement_thread_id = $ReplacementThreadId
    continuity_key = [string]$node.context.continuity_key
    replacement_continuity_receipt_path = [IO.Path]::GetRelativePath(
        $runRoot, $continuityFullPath
    ).Replace('\', '/')
    replacement_continuity_receipt_hash = [string]$continuity.receipt_hash
    replacement_pending_event_sequence = [int]$replacementEvent.sequence
    replacement_pending_event_hash = [string]$replacementEvent.hash
    actual_model_state = $actualModelState
    actual_model_id = $actualModelId
    actual_model_evidence_hash = Get-TextSha256 (
        @($replacementEvent.evidence) |
            ConvertTo-Json -Compress -Depth 20
    )
    previous_result_receipt_path = $priorResultRelativePath
    previous_result_receipt_hash = [string]$priorResult.receipt_hash
    previous_result_file_hash = (
        Get-FileHash -LiteralPath $priorResultFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    previous_disposition_receipt_path = $priorDispositionRelativePath
    previous_disposition_receipt_hash = [string]$priorDisposition.receipt_hash
    previous_disposition_file_hash = (
        Get-FileHash -LiteralPath $priorDispositionFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    previous_adopted_event_sequence = [int]$priorAdopted.sequence
    previous_adopted_event_hash = [string]$priorAdopted.hash
    previous_checkpoint_hash = $priorCheckpointHash
    active_milestone_id = [string]$chain.active_milestone_id
    active_milestone_activation_receipt_path = [string](
        $chain.activation_receipt_path
    )
    active_milestone_activation_receipt_hash = [string](
        $chain.activation_receipt_hash
    )
    target_milestone_id = $TargetMilestoneId
    checkpoint_path = [IO.Path]::GetRelativePath(
        $runRoot, $checkpointFullPath
    ).Replace('\', '/')
    checkpoint_hash = $checkpointHash
    input_manifest_path = [IO.Path]::GetRelativePath(
        $runRoot, $inputFullPath
    ).Replace('\', '/')
    input_manifest_hash = $inputHash
    authorization_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $authorizationFullPath
    ).Replace('\', '/')
    authorization_material_hash = $authorizationHash
    activation_key = $ActivationKey
    roll_forward_id = $rollForwardId
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8
try {
    $verified = Read-ReplacementCheckpointRollForwardReceipt `
        -Path $outputFullPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $ReplacementThreadId
} catch {
    Remove-Item -LiteralPath $outputFullPath -Force
    throw
}
$verified | ConvertTo-Json -Depth 100
