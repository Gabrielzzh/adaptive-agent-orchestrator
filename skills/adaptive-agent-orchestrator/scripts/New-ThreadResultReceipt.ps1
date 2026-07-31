[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $ThreadId,
    [Parameter(Mandatory)][string] $HostId,
    [Parameter(Mandatory)][string] $ThreadReadPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $MilestoneId,
    [string] $CheckpointMaterialPath,
    [string] $ReplacementContinuityReceiptPath,
    [string] $ReplacementCheckpointRollForwardReceiptPath,
    [string] $PendingFindingRecordsPath,
    [string[]] $PendingFindings = @(),
    [string[]] $AdoptedFindings = @(),
    [string[]] $RejectedFindings = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

foreach ($value in @($ThreadId, $HostId)) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Thread and host IDs must be non-empty.'
    }
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}
if (-not (Test-Path -LiteralPath $ThreadReadPath -PathType Leaf)) {
    throw "Thread-read capture does not exist: $ThreadReadPath"
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Thread result receipt already exists: $OutputPath"
}
if ([IO.Path]::GetFileName($OutputPath) -notlike '*.thread-result-receipt.json') {
    throw 'OutputPath must end with .thread-result-receipt.json.'
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$sourceNode = @($plan.nodes | Where-Object {
    [string]$_.id -eq $SourceNodeId
}) | Select-Object -First 1
if ($null -eq $sourceNode) {
    throw 'Thread result source node does not exist in the run plan.'
}
$durableSourceIds = @()
if ($null -ne $plan.PSObject.Properties['durable_review_profile']) {
    $durableSourceIds = @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids)
    )
}
$isDurableReviewSource = $SourceNodeId -in $durableSourceIds
$checkpointRelativePath = ''
$checkpointHash = ''
if ($isDurableReviewSource) {
    $milestones = @($plan.durable_review_profile.milestone_ids)
    if ([string]::IsNullOrWhiteSpace($MilestoneId) -or
        $MilestoneId -notin $milestones) {
        throw (
            'Durable review result requires a milestone_id declared by the ' +
            'run plan.'
        )
    }
    if ([string]::IsNullOrWhiteSpace($CheckpointMaterialPath)) {
        throw 'Durable review result requires checkpoint material.'
    }
    $checkpointFullPath = [IO.Path]::GetFullPath($CheckpointMaterialPath)
    if (-not $checkpointFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $checkpointFullPath -PathType Leaf)) {
        throw 'Checkpoint material must be an existing file inside the run.'
    }
    $checkpointRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $checkpointFullPath
    ).Replace('\', '/')
    $checkpointSegments = $checkpointRelativePath -split '[\\/]'
    if (@($checkpointSegments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Checkpoint material path contains an unsafe segment.'
    }
    $checkpointHash = (
        Get-FileHash -LiteralPath $checkpointFullPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
} elseif (-not [string]::IsNullOrWhiteSpace($MilestoneId) -or
    -not [string]::IsNullOrWhiteSpace($CheckpointMaterialPath)) {
    throw 'Milestone binding is only valid for a durable review source.'
}
$events = @(Read-OrchestrationJournal (Join-Path $runRoot 'events.jsonl'))
$replacementLifecycleEvent = @($events | Where-Object {
    [string]$_.node_id -eq $SourceNodeId -and
    [string]$_.status -eq 'replacement_pending' -and
    [string]$_.thread_id -eq $ThreadId
}) | Select-Object -Last 1
$captureFullPath = [IO.Path]::GetFullPath($ThreadReadPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
foreach ($candidate in @($captureFullPath, $outputFullPath)) {
    if (-not $candidate.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Thread-read capture and receipt must remain inside the run.'
    }
}
$captureRelativePath = $captureFullPath.Substring($runRoot.Length + 1)
$captureSegments = $captureRelativePath -split '[\\/]'
if (@($captureSegments | Where-Object {
    $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
}).Count -gt 0) {
    throw 'Thread-read capture path contains an unsafe segment.'
}
$final = Read-ThreadReadCapture -Path $captureFullPath `
    -ExpectedThreadId $ThreadId
$sourceKind = 'original'
$replacementRelativePath = ''
$replacementHash = ''
$replacement = $null
if (-not [string]::IsNullOrWhiteSpace($ReplacementContinuityReceiptPath)) {
    $replacementFullPath = [IO.Path]::GetFullPath(
        $ReplacementContinuityReceiptPath
    )
    if (-not $replacementFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Replacement continuity receipt must remain inside the run.'
    }
    $replacement = Read-ReplacementContinuityReceipt `
        -Path $replacementFullPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $ThreadId
    if ($null -eq $replacementLifecycleEvent -or
        [string]$replacementLifecycleEvent.replacement_receipt_hash -ne
            [string]$replacement.receipt_hash) {
        throw (
            'Replacement result lacks its immutable replacement_pending ' +
            'lifecycle binding.'
        )
    }
    $sourceKind = 'replacement'
    $replacementRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $replacementFullPath
    ).Replace('\', '/')
    $replacementHash = [string]$replacement.receipt_hash
} elseif ($null -ne $replacementLifecycleEvent) {
    throw (
        'Replacement thread result requires its continuity receipt; it cannot ' +
        'be recorded as original.'
    )
}
$replacementRollForwardRelativePath = ''
$replacementRollForwardHash = ''
if (-not [string]::IsNullOrWhiteSpace(
    $ReplacementCheckpointRollForwardReceiptPath
)) {
    if ($sourceKind -ne 'replacement') {
        throw (
            'Replacement checkpoint roll-forward requires replacement ' +
            'continuity.'
        )
    }
    $rollForwardFullPath = [IO.Path]::GetFullPath(
        $ReplacementCheckpointRollForwardReceiptPath
    )
    if (-not $rollForwardFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Replacement checkpoint roll-forward receipt must remain inside the run.'
    }
    $rollForward = Read-ReplacementCheckpointRollForwardReceipt `
        -Path $rollForwardFullPath -RunDirectory $runRoot `
        -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $ThreadId
    if ([string]$rollForward.replacement_continuity_receipt_hash -ne
            [string]$replacement.receipt_hash -or
        [string]$rollForward.target_milestone_id -ne $MilestoneId -or
        [string]$rollForward.checkpoint_path -ne $checkpointRelativePath) {
        throw (
            'Replacement checkpoint roll-forward does not match the result ' +
            'milestone, checkpoint, or continuity.'
        )
    }
    $replacementRollForwardRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $rollForwardFullPath
    ).Replace('\', '/')
    $replacementRollForwardHash = [string]$rollForward.receipt_hash
    $rollForwardLifecycle = @($events | Where-Object {
        $null -ne $_.PSObject.Properties[
            'replacement_roll_forward_receipt_path'
        ] -and
        $null -ne $_.PSObject.Properties[
            'replacement_roll_forward_receipt_hash'
        ] -and
        $null -ne $_.PSObject.Properties[
            'replacement_roll_forward_id'
        ] -and
        [string]$_.node_id -eq $SourceNodeId -and
        [string]$_.thread_id -eq $ThreadId -and
        [string]$_.status -eq 'running' -and
        [string]$_.replacement_roll_forward_receipt_path -eq
            $replacementRollForwardRelativePath -and
        [string]$_.replacement_roll_forward_receipt_hash -eq
            $replacementRollForwardHash -and
        [string]$_.replacement_roll_forward_id -eq
            [string]$rollForward.roll_forward_id
    })
    if ($rollForwardLifecycle.Count -ne 1) {
        throw (
            'Replacement result lacks its unique adopted-to-running ' +
            'checkpoint roll-forward lifecycle binding.'
        )
    }
} elseif ($sourceKind -eq 'replacement' -and
    -not [string]::IsNullOrWhiteSpace($checkpointHash) -and
    [string]$replacement.checkpoint_hash -ne $checkpointHash) {
    throw (
        'Replacement result at a new checkpoint requires its checkpoint ' +
        'roll-forward receipt.'
    )
}
$structuredPending = @()
if (-not [string]::IsNullOrWhiteSpace($PendingFindingRecordsPath)) {
    if (@($PendingFindings + $AdoptedFindings + $RejectedFindings).Count -gt 0) {
        throw (
            'PendingFindingRecordsPath cannot be combined with legacy ' +
            'string finding parameters.'
        )
    }
    $findingRecordsFullPath = [IO.Path]::GetFullPath(
        $PendingFindingRecordsPath
    )
    if (-not $findingRecordsFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $findingRecordsFullPath -PathType Leaf)) {
        throw 'Pending finding records must be an existing file inside the run.'
    }
    $findingRecords = @(
        Get-Content -LiteralPath $findingRecordsFullPath -Raw |
            ConvertFrom-Json -Depth 30 -DateKind String
    )
    if ($findingRecords.Count -eq 0) {
        throw 'Pending finding records require at least one finding.'
    }
    $seenFindingIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $structuredPending = @($findingRecords | ForEach-Object {
        foreach ($name in @('finding_id', 'severity', 'text')) {
            if ($null -eq $_.PSObject.Properties[$name]) {
                throw "Pending finding record is missing '$name'."
            }
        }
        $findingId = [string]$_.finding_id
        $severity = [string]$_.severity
        $text = [string]$_.text
        if ($findingId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
            -not $seenFindingIds.Add($findingId)) {
            throw 'Pending findings require unique stable finding_id values.'
        }
        if ($severity -notin @('P0', 'P1', 'P2') -or
            [string]::IsNullOrWhiteSpace($text)) {
            throw 'Pending findings require P0/P1/P2 severity and non-empty text.'
        }
        [ordered]@{
            finding_id = $findingId
            severity = $severity
            text = $text
            text_hash = Get-TextSha256 $text
        }
    })
}
$adopted = @($AdoptedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$rejected = @($RejectedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$pending = @($PendingFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$allFindings = if ($structuredPending.Count -gt 0) {
    @($structuredPending)
} else {
    @($pending + $adopted + $rejected)
}
$allFindings = @($allFindings)
if ($allFindings.Count -eq 0) {
    throw 'At least one pending, adopted, or rejected finding is required.'
}
if ($structuredPending.Count -eq 0 -and
    @($allFindings | Select-Object -Unique).Count -ne $allFindings.Count) {
    throw 'Thread result findings must be unique across disposition groups.'
}
if (-not [string]::IsNullOrWhiteSpace(
    $replacementRollForwardRelativePath
) -and $structuredPending.Count -eq 0) {
    throw (
        'Replacement checkpoint roll-forward results require structured ' +
        'schema findings.'
    )
}
$receiptAdopted = [object[]]@($adopted)
$receiptRejected = [object[]]@($rejected)
$receiptPending = [object[]]@($pending)
if ($structuredPending.Count -gt 0) {
    $receiptAdopted = [object[]]@()
    $receiptRejected = [object[]]@()
    $receiptPending = [object[]]@($structuredPending)
}
$receipt = [ordered]@{
    schema_version = if (-not [string]::IsNullOrWhiteSpace(
        $replacementRollForwardRelativePath
    )) {
        '1.4'
    } elseif ($structuredPending.Count -gt 0) {
        '1.3'
    } else {
        '1.2'
    }
    source_node_id = $SourceNodeId
    source_kind = $sourceKind
    thread_id = $ThreadId
    host_id = $HostId
    collection_method = 'read_thread'
    thread_read_path = $captureRelativePath.Replace('\', '/')
    thread_read_hash = $final.capture_hash
    final_turn_id = $final.final_turn_id
    final_status = 'completed'
    final_content_hash = $final.final_content_hash
    replacement_continuity_receipt_path = $replacementRelativePath
    replacement_continuity_receipt_hash = $replacementHash
    milestone_id = if ($isDurableReviewSource) { $MilestoneId } else { '' }
    checkpoint_material_path = $checkpointRelativePath
    checkpoint_material_hash = $checkpointHash
    adopted_findings = $receiptAdopted
    rejected_findings = $receiptRejected
    pending_findings = $receiptPending
}
if ([string]$receipt.schema_version -eq '1.4') {
    $receipt['replacement_checkpoint_roll_forward_receipt_path'] =
        $replacementRollForwardRelativePath
    $receipt['replacement_checkpoint_roll_forward_receipt_hash'] =
        $replacementRollForwardHash
}
$receipt.receipt_hash = Get-TextSha256 (
    $receipt | ConvertTo-Json -Compress -Depth 20
)
$parent = Split-Path -Parent $outputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
$receipt | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputFullPath
$receipt | ConvertTo-Json -Depth 20
