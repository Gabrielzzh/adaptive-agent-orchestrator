[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $OriginalThreadId,
    [Parameter(Mandatory)][string] $CheckpointManifestPath,
    [Parameter(Mandatory)][string] $InputManifestPath,
    [string] $ThreadReadPath,
    [string] $LegacySourceAdoptionReceiptPath,
    [ValidateSet('original', 'replacement')]
    [string] $RecoveryStage = 'original',
    [string] $ReplacementContinuityReceiptPath,
    [string] $MilestoneId,
    [Parameter(Mandatory)][ValidateRange(1, 3)][int] $Attempt,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 20 -DateKind String
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$node = @($plan.nodes | Where-Object {
    [string]$_.id -eq $SourceNodeId
}) | Select-Object -First 1
if ($null -eq $node -or [string]$node.kind -ne 'agent' -or
    [string]$node.topology -ne 'background-thread') {
    throw 'Recovery source must be a durable background-thread node.'
}
$events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
$history = @($events | Where-Object {
    [string]$_.node_id -eq $SourceNodeId
})
$derivedRecoveryStage = if (@($history | Where-Object {
    [string]$_.status -eq 'replacement_pending' -and
    [string]$_.thread_id -eq $OriginalThreadId
}).Count -gt 0) {
    'replacement'
} elseif (@($history | Where-Object {
    [string]$_.status -eq 'materialized' -and
    [string]$_.thread_id -eq $OriginalThreadId
}).Count -gt 0) {
    'original'
} else {
    throw (
        'Recovery thread has no materialized or replacement_pending ' +
        'lifecycle binding.'
    )
}
if ($RecoveryStage -ne $derivedRecoveryStage) {
    throw (
        "RecoveryStage '$RecoveryStage' does not match lifecycle-derived " +
        "stage '$derivedRecoveryStage'."
    )
}

function Resolve-InputPath {
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

$checkpointPath = Resolve-InputPath $CheckpointManifestPath (
    'Checkpoint manifest'
)
$inputPath = Resolve-InputPath $InputManifestPath 'Input manifest'
$checkpointHash = Get-TextSha256 (
    Get-Content -LiteralPath $checkpointPath -Raw
)
$inputManifestHash = Get-TextSha256 (
    Get-Content -LiteralPath $inputPath -Raw
)
$cycleAwareOriginal = (
    $RecoveryStage -eq 'original' -and
    [string]::IsNullOrWhiteSpace($LegacySourceAdoptionReceiptPath)
)
$cycle = $null
if ($cycleAwareOriginal) {
    $cycle = Get-OriginalRecoveryCycleBinding `
        -RunDirectory $runRoot -SourceNodeId $SourceNodeId `
        -OriginalThreadId $OriginalThreadId `
        -CheckpointHash $checkpointHash `
        -InputManifestHash $inputManifestHash -MilestoneId $MilestoneId
} elseif (-not [string]::IsNullOrWhiteSpace($MilestoneId)) {
    throw 'MilestoneId is only valid for cycle-aware original recovery.'
}
$expectedName = if ($RecoveryStage -eq 'replacement') {
    "$SourceNodeId.replacement.attempt-$Attempt.result-recovery.json"
} elseif ($cycleAwareOriginal) {
    "$SourceNodeId.cycle-$([string]$cycle.recovery_cycle_id)." +
        "attempt-$Attempt.result-recovery.json"
} else {
    "$SourceNodeId.attempt-$Attempt.result-recovery.json"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $runRoot 'receipts') $expectedName
}
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $outputFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Recovery receipt must remain inside the run.'
}
$canonicalReceiptDirectory = [IO.Path]::GetFullPath(
    (Join-Path $runRoot 'receipts')
).TrimEnd('\', '/')
if ([IO.Path]::GetFullPath(
    (Split-Path -Parent $outputFullPath)
).TrimEnd('\', '/') -ne $canonicalReceiptDirectory) {
    throw 'Recovery receipt must use the canonical run receipts directory.'
}
if ([IO.Path]::GetFileName($outputFullPath) -ne $expectedName) {
    throw "Recovery receipt filename must be '$expectedName'."
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Recovery receipt already exists: $outputFullPath"
}
$evidenceSource = ''
$legacyRelativePath = ''
$legacyHash = ''
$replacementRelativePath = ''
$replacementHash = ''
if ($RecoveryStage -eq 'replacement') {
    if (-not [string]::IsNullOrWhiteSpace($LegacySourceAdoptionReceiptPath) -or
        [string]::IsNullOrWhiteSpace($ReplacementContinuityReceiptPath)) {
        throw (
            'Replacement-stage recovery requires replacement continuity and ' +
            'cannot use legacy adoption directly.'
        )
    }
    $replacementPath = Resolve-InputPath $ReplacementContinuityReceiptPath (
        'Replacement continuity receipt'
    )
    $replacement = Read-ReplacementContinuityReceipt -Path $replacementPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $OriginalThreadId
    $replacementRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $replacementPath
    ).Replace('\', '/')
    $replacementHash = [string]$replacement.receipt_hash
} elseif (-not [string]::IsNullOrWhiteSpace(
    $ReplacementContinuityReceiptPath
)) {
    throw 'Original-stage recovery cannot bind replacement continuity.'
}
if (-not [string]::IsNullOrWhiteSpace($LegacySourceAdoptionReceiptPath)) {
    if (-not [string]::IsNullOrWhiteSpace($ThreadReadPath)) {
        throw 'Use either a platform progress capture or legacy adoption.'
    }
    $legacyPath = Resolve-InputPath $LegacySourceAdoptionReceiptPath (
        'Legacy source adoption receipt'
    )
    $legacy = Read-LegacySourceAdoptionReceipt -Path $legacyPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId
    $turnEvidencePath = Get-RunLocalReceiptPath -RunDirectory $runRoot `
        -RelativePath ([string]$legacy.turn_evidence_path) `
        -Label 'Legacy turn evidence'
    $turnEvidence = @(
        Get-Content -LiteralPath $turnEvidencePath -Raw |
            ConvertFrom-Json -Depth 30 -DateKind String
    )
    $selectedTurn = $turnEvidence[$Attempt]
    $capture = [pscustomobject]@{
        capture_hash = [string]$legacy.turn_evidence_hash
        progress_evidence_hash = Get-TextSha256 (
            ConvertTo-Json -InputObject @(
                $selectedTurn.progress_evidence
            ) -Compress -Depth 20
        )
        progress_evidence_count = @($selectedTurn.progress_evidence).Count
        latest_assistant_message_id_state = 'missing'
    }
    $capturePath = $turnEvidencePath
    $evidenceSource = 'legacy-adoption'
    $legacyRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $legacyPath
    ).Replace('\', '/')
    $legacyHash = [string]$legacy.receipt_hash
} else {
    if ([string]::IsNullOrWhiteSpace($ThreadReadPath)) {
        throw 'Platform recovery requires ThreadReadPath.'
    }
    $capturePath = Resolve-InputPath $ThreadReadPath 'Thread progress capture'
    $capture = Read-ThreadProgressCapture -Path $capturePath `
        -ExpectedThreadId $OriginalThreadId
    $evidenceSource = 'platform-read-capture'
}

if ($cycleAwareOriginal) {
    $existingCycleStarts = @(
        Get-ChildItem -LiteralPath $canonicalReceiptDirectory -File `
            -Filter "$SourceNodeId.cycle-*.attempt-1.result-recovery.json" `
            -ErrorAction SilentlyContinue
    )
    foreach ($existingCycleStart in $existingCycleStarts) {
        $existing = Read-ThreadResultRecoveryReceipt `
            -Path $existingCycleStart.FullName -RunDirectory $runRoot `
            -ExpectedSourceNodeId $SourceNodeId `
            -ExpectedOriginalThreadId $OriginalThreadId `
            -ExpectedRecoveryStage 'original'
        if ([string]$existing.checkpoint_hash -eq $checkpointHash -and
            [string]$existing.recovery_cycle_id -ne
                [string]$cycle.recovery_cycle_id) {
            throw (
                'An original recovery cycle already binds this source, thread, ' +
                'and checkpoint with different input or milestone identity.'
            )
        }
    }
}

$previousPath = ''
$previousHash = ''
if ($Attempt -gt 1) {
    $previousName = if ($RecoveryStage -eq 'replacement') {
        "$SourceNodeId.replacement.attempt-$($Attempt - 1).result-recovery.json"
    } elseif ($cycleAwareOriginal) {
        "$SourceNodeId.cycle-$([string]$cycle.recovery_cycle_id)." +
            "attempt-$($Attempt - 1).result-recovery.json"
    } else {
        "$SourceNodeId.attempt-$($Attempt - 1).result-recovery.json"
    }
    $previousFullPath = Join-Path (Split-Path -Parent $outputFullPath) (
        $previousName
    )
    $previous = Read-ThreadResultRecoveryReceipt -Path $previousFullPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId `
        -ExpectedRecoveryStage $RecoveryStage
    $previousPath = [IO.Path]::GetRelativePath(
        $runRoot, $previousFullPath
    ).Replace('\', '/')
    $previousHash = [string]$previous.receipt_hash
}

$payload = [ordered]@{
    schema_version = if ($RecoveryStage -eq 'replacement') {
        '1.1'
    } elseif ($cycleAwareOriginal) {
        '1.2'
    } else {
        '1.0'
    }
    run_id = [string]$run.run_id
    source_node_id = $SourceNodeId
    role_id = [string]$node.role_id
    original_thread_id = $OriginalThreadId
    continuity_key = [string]$node.context.continuity_key
    checkpoint_path = [IO.Path]::GetRelativePath(
        $runRoot, $checkpointPath
    ).Replace('\', '/')
    checkpoint_hash = $checkpointHash
    input_manifest_path = [IO.Path]::GetRelativePath(
        $runRoot, $inputPath
    ).Replace('\', '/')
    input_manifest_hash = $inputManifestHash
    thread_read_path = [IO.Path]::GetRelativePath(
        $runRoot, $capturePath
    ).Replace('\', '/')
    thread_read_hash = [string]$capture.capture_hash
    progress_evidence_hash = [string]$capture.progress_evidence_hash
    progress_evidence_count = [int]$capture.progress_evidence_count
    latest_assistant_message_id_state = (
        [string]$capture.latest_assistant_message_id_state
    )
    evidence_source = $evidenceSource
    legacy_adoption_receipt_path = $legacyRelativePath
    legacy_adoption_receipt_hash = $legacyHash
    attempt = $Attempt
    outcome = if ($Attempt -eq 3) {
        'recovery-exhausted'
    } else {
        'result-pending'
    }
    previous_receipt_path = $previousPath
    previous_receipt_hash = $previousHash
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
if ($RecoveryStage -eq 'replacement') {
    $payload['recovery_stage'] = 'replacement'
    $payload['replacement_continuity_receipt_path'] = $replacementRelativePath
    $payload['replacement_continuity_receipt_hash'] = $replacementHash
} elseif ($cycleAwareOriginal) {
    $payload['recovery_stage'] = 'original'
    $payload['recovery_cycle_id'] = [string]$cycle.recovery_cycle_id
    $payload['milestone_id'] = [string]$cycle.milestone_id
    $payload['milestone_activation_receipt_path'] =
        [string]$cycle.milestone_activation_receipt_path
    $payload['milestone_activation_receipt_hash'] =
        [string]$cycle.milestone_activation_receipt_hash
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 30
)
$parent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
$receipt | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8
try {
    $verified = Read-ThreadResultRecoveryReceipt -Path $outputFullPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId `
        -ExpectedRecoveryStage $RecoveryStage
} catch {
    Remove-Item -LiteralPath $outputFullPath -Force
    throw
}
$verified | ConvertTo-Json -Depth 30
