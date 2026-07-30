[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [Parameter(Mandatory)]
    [string] $NodeId,

    [Parameter(Mandatory)]
    [ValidateSet('launch_reserved', 'materializing', 'materialized', 'running',
        'needs_input', 'result_pending', 'replacement_pending',
        'completed', 'validated', 'adopted', 'archived',
        'failed', 'cancelled', 'rejected', 'unknown')]
    [string] $Status,

    [Parameter(Mandatory)]
    [string] $Message,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $IdempotencyKey,

    [string] $ThreadId,
    [string] $ModelId,
    [ValidateSet('verified', 'unverified')]
    [string] $ModelVerificationState,
    [string] $ModelVerificationEvidence,
    [string] $Artifact,
    [string] $Decision,
    [string] $HumanActor,
    [string[]] $Evidence = @(),
    [int] $Wave = 1,

    [ValidateRange(0, 1000000000)]
    [int64] $InputTokensDelta = 0,

    [ValidateRange(0, 1000000000)]
    [int64] $OutputTokensDelta = 0,

    [ValidateRange(0, 1000000000)]
    [int64] $CoordinationTokensDelta = 0,

    [ValidateSet('none', 'estimate', 'actual')]
    [string] $UsageSource = 'none',

    [ValidateSet('startup_unmaterialized', 'runtime_transient',
        'model_incompatible', 'permission_denied', 'task_invalid',
        'output_invalid', 'ownership_conflict',
        'final_missing_with_progress_evidence', 'unknown')]
    [string] $ErrorClass,

    [string] $ActionKey,
    [string] $PremiseManifestPath,
    [string] $FailureCode,
    [string] $RetryAuthorization,
    [string] $ReconciliationReceiptPath,
    [string] $RecoveryReceiptPath,
    [string] $ReplacementContinuityReceiptPath,
    [string] $MilestoneRevisionAuthorizationReceiptPath,
    [switch] $AdoptActivatedLifecycle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$planPath = Join-Path $RunDirectory 'plan.json'
$eventsPath = Join-Path $RunDirectory 'events.jsonl'
$runPath = Join-Path $RunDirectory 'run.json'
if (-not (Test-Path -LiteralPath $planPath) -or
    -not (Test-Path -LiteralPath $eventsPath) -or
    -not (Test-Path -LiteralPath $runPath)) {
    throw "Run directory is missing plan.json, run.json, or events.jsonl: $RunDirectory"
}
$planText = Get-Content -LiteralPath $planPath -Raw
$plan = $planText | ConvertFrom-Json -Depth 100
$runMetadata = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
$node = @($plan.nodes | Where-Object { $_.id -eq $NodeId }) | Select-Object -First 1
if ($null -eq $node) { throw "Unknown node id '$NodeId'." }
$effectiveWave = if ($node.kind -eq 'agent') {
    [int]$node.wave
} else {
    $Wave
}
if ($Status -in @('failed', 'unknown', 'result_pending') -and
    [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw "Status '$Status' requires ErrorClass."
}
if ($Status -notin @('failed', 'unknown', 'result_pending') -and
    -not [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw 'ErrorClass is only valid for failed, unknown, or result_pending.'
}
if ($Status -eq 'result_pending' -and
    $ErrorClass -ne 'final_missing_with_progress_evidence') {
    throw (
        'result_pending requires ' +
        'final_missing_with_progress_evidence.'
    )
}
if ($Status -ne 'result_pending' -and
    $ErrorClass -eq 'final_missing_with_progress_evidence') {
    throw (
        'final_missing_with_progress_evidence is only valid for ' +
        'result_pending.'
    )
}
if ($ModelId -and $ModelId -notin @(
    'gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra'
)) {
    throw "Unsupported actual model '$ModelId'."
}
if (($node.kind -eq 'agent' -and $Status -eq 'materialized') -or
    ($node.kind -eq 'agent' -and $Status -eq 'replacement_pending' -and
        $AdoptActivatedLifecycle)) {
    if ([string]::IsNullOrWhiteSpace($ModelVerificationState)) {
        if ($AdoptActivatedLifecycle -or
            [string]::IsNullOrWhiteSpace($ModelId)) {
            throw (
                'Agent materialization without an exposed actual model requires ' +
                "ModelVerificationState 'unverified'."
            )
        }
        $ModelVerificationState = 'verified'
    }
    if ($AdoptActivatedLifecycle -and
        $ModelVerificationState -ne 'unverified') {
        throw 'Activated existing lifecycle must record the actual model as unverified.'
    }
    if ($ModelVerificationState -eq 'verified') {
        if ([string]::IsNullOrWhiteSpace($ModelId)) {
            throw 'Verified agent materialization requires the actual ModelId.'
        }
        if ($ModelId -ne [string]$node.model) {
            throw (
                "Actual model '$ModelId' differs from planned model " +
                "'$($node.model)'; obtain confirmation and create a revised plan."
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($ModelVerificationEvidence)) {
            throw 'Verified materialization does not accept unverified-model evidence.'
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($ModelId)) {
            throw (
                'Unverified materialization must leave ModelId empty; ' +
                'the requested model is not actual-model evidence.'
            )
        }
        if ([string]::IsNullOrWhiteSpace($ModelVerificationEvidence) -or
            $ModelVerificationEvidence -notmatch '^(source|observation):\S.+$') {
            throw (
                'Unverified materialization requires ModelVerificationEvidence ' +
                'using source:value or observation:value.'
            )
        }
    }
} elseif (-not [string]::IsNullOrWhiteSpace($ModelVerificationState) -or
    -not [string]::IsNullOrWhiteSpace($ModelVerificationEvidence)) {
    throw (
        'ModelVerificationState and ModelVerificationEvidence are only valid ' +
        'for agent materialization.'
    )
}
if ($AdoptActivatedLifecycle -and
    $Status -ne 'replacement_pending') {
    throw 'AdoptActivatedLifecycle is only valid for replacement_pending.'
}
$usageDelta = $InputTokensDelta + $OutputTokensDelta
if ($CoordinationTokensDelta -gt $usageDelta) {
    throw 'Coordination Token delta must be a subset of input plus output Tokens.'
}
if ($UsageSource -eq 'none' -and $usageDelta -gt 0) {
    throw 'Token deltas require UsageSource estimate or actual.'
}
if ($UsageSource -ne 'none' -and $usageDelta -eq 0) {
    throw 'UsageSource estimate or actual requires a non-zero Token delta.'
}
$cleanEvidence = @($Evidence | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$deterministicFailureClasses = @(
    'model_incompatible', 'permission_denied', 'task_invalid',
    'output_invalid', 'ownership_conflict'
)
$normalizedActionKey = if ([string]::IsNullOrWhiteSpace($ActionKey)) {
    $null
} else {
    $ActionKey.Trim()
}
$premiseFingerprint = $null
$premiseRelativePath = $null
if (-not [string]::IsNullOrWhiteSpace($PremiseManifestPath)) {
    if ([IO.Path]::IsPathRooted($PremiseManifestPath)) {
        throw 'PremiseManifestPath must be relative to the run directory.'
    }
    $premiseSegments = $PremiseManifestPath -split '[\\/]'
    if (@($premiseSegments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'PremiseManifestPath is unsafe.'
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $resolvedPremisePath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $PremiseManifestPath)
    )
    if (-not $resolvedPremisePath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $resolvedPremisePath -PathType Leaf)) {
        throw 'Premise manifest must be an existing file inside the run.'
    }
    $cursor = Split-Path -Parent $resolvedPremisePath
    while ($cursor.StartsWith(
        $runRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and $cursor.Length -ge $runRoot.Length) {
        if (((Get-Item -LiteralPath $cursor).Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Premise manifest cannot cross a link or reparse point.'
        }
        if ($cursor -eq $runRoot) { break }
        $cursor = Split-Path -Parent $cursor
    }
    $premise = Get-Content -LiteralPath $resolvedPremisePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 30
    foreach ($requiredPremiseField in @(
        'schema_version', 'node_id', 'action_key', 'input_refs',
        'repair_instruction'
    )) {
        if (-not $premise.ContainsKey($requiredPremiseField)) {
            throw "Premise manifest is missing '$requiredPremiseField'."
        }
    }
    if ([string]$premise.schema_version -ne '1.0' -or
        [string]$premise.node_id -ne $NodeId -or
        ([string]$premise.action_key).Trim() -ne $normalizedActionKey -or
        [string]::IsNullOrWhiteSpace([string]$premise.repair_instruction)) {
        throw 'Premise manifest does not match the current node and action.'
    }
    $premiseInputRefs = @($premise.input_refs | ForEach-Object {
        ([string]$_).Trim()
    } | Sort-Object -Unique)
    if ($premiseInputRefs.Count -eq 0 -or
        @($premiseInputRefs | Where-Object {
            $_ -notmatch '^(artifact|test|source|observation):\S.+$'
        }).Count -gt 0) {
        throw 'Premise manifest requires typed, non-empty input_refs.'
    }
    $canonicalPremise = [ordered]@{
        schema_version = '1.0'
        node_id = [string]$premise.node_id
        action_key = $normalizedActionKey
        input_refs = $premiseInputRefs
        repair_instruction = [regex]::Replace(
            ([string]$premise.repair_instruction).Trim(),
            '\s+',
            ' '
        )
    }
    $premiseFingerprint = Get-TextSha256 (
        $canonicalPremise | ConvertTo-Json -Compress -Depth 10
    )
    $premiseRelativePath = $PremiseManifestPath.Replace('\', '/')
}
if (-not [string]::IsNullOrWhiteSpace($FailureCode) -and
    $FailureCode -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
    throw 'FailureCode must be a stable lowercase code.'
}
if ($Status -eq 'failed' -and
    $ErrorClass -in $deterministicFailureClasses) {
    if ([string]::IsNullOrWhiteSpace($ActionKey) -or
        [string]::IsNullOrWhiteSpace($premiseFingerprint) -or
        [string]::IsNullOrWhiteSpace($FailureCode)) {
        throw (
            'Deterministic failures require ActionKey, PremiseManifestPath, ' +
            'and FailureCode.'
        )
    }
}
$actionHash = if ([string]::IsNullOrWhiteSpace($normalizedActionKey)) {
    $null
} else {
    Get-TextSha256 $normalizedActionKey
}
if ($actionHash) {
    $cleanEvidence += "observation:action-key:$actionHash"
}
if (-not [string]::IsNullOrWhiteSpace($premiseFingerprint)) {
    $cleanEvidence += "artifact:premise-manifest:$premiseRelativePath"
    $cleanEvidence += (
        'observation:premise-fingerprint:' +
        $premiseFingerprint
    )
}
if (-not [string]::IsNullOrWhiteSpace($FailureCode)) {
    $cleanEvidence += "observation:failure-code:$FailureCode"
}
if ($Status -eq 'failed' -and
    $ErrorClass -in $deterministicFailureClasses) {
    $failureFingerprint = Get-TextSha256 (
        "$actionHash|$premiseFingerprint|" +
        "$ErrorClass|$FailureCode"
    )
    $cleanEvidence += "observation:failure-fingerprint:$failureFingerprint"
}
if (-not [string]::IsNullOrWhiteSpace($RetryAuthorization)) {
    $cleanEvidence += "source:retry-authorization:$RetryAuthorization"
}
$reconciliationReceipt = $null
if (-not [string]::IsNullOrWhiteSpace($ReconciliationReceiptPath)) {
    if ([IO.Path]::IsPathRooted($ReconciliationReceiptPath)) {
        throw 'ReconciliationReceiptPath must be relative to the run directory.'
    }
    $reconciliationReceipt = Read-ThreadReconciliationReceipt -Path (
        Join-Path $RunDirectory $ReconciliationReceiptPath
    ) -RunDirectory $RunDirectory -ExpectedDecision 'no_match'
    $normalizedReconciliationPath = $ReconciliationReceiptPath.Replace('\', '/')
    $cleanEvidence += (
        "artifact:thread-reconciliation:$normalizedReconciliationPath"
    )
    $cleanEvidence += (
        'observation:thread-reconciliation-hash:' +
        [string]$reconciliationReceipt.receipt_hash
    )
    $cleanEvidence += 'observation:task-list-reconciled-no-match'
}
$recoveryReceipt = $null
$normalizedRecoveryPath = $null
if (-not [string]::IsNullOrWhiteSpace($RecoveryReceiptPath)) {
    if ([IO.Path]::IsPathRooted($RecoveryReceiptPath)) {
        throw 'RecoveryReceiptPath must be relative to the run directory.'
    }
    $normalizedRecoveryPath = $RecoveryReceiptPath.Replace('\', '/')
    $recoveryReceipt = Read-ThreadResultRecoveryReceipt `
        -Path (Join-Path $RunDirectory $normalizedRecoveryPath) `
        -RunDirectory $RunDirectory -ExpectedSourceNodeId $NodeId `
        -ExpectedOriginalThreadId $ThreadId
    $cleanEvidence += "artifact:result-recovery:$normalizedRecoveryPath"
    $cleanEvidence += (
        'observation:result-recovery-hash:' +
        [string]$recoveryReceipt.receipt_hash
    )
}
$replacementReceipt = $null
$normalizedReplacementPath = $null
if (-not [string]::IsNullOrWhiteSpace(
    $ReplacementContinuityReceiptPath
)) {
    if ([IO.Path]::IsPathRooted($ReplacementContinuityReceiptPath)) {
        throw (
            'ReplacementContinuityReceiptPath must be relative to the run ' +
            'directory.'
        )
    }
    $normalizedReplacementPath = (
        $ReplacementContinuityReceiptPath.Replace('\', '/')
    )
    $replacementReceipt = Read-ReplacementContinuityReceipt `
        -Path (Join-Path $RunDirectory $normalizedReplacementPath) `
        -RunDirectory $RunDirectory -ExpectedSourceNodeId $NodeId `
        -ExpectedReplacementThreadId $ThreadId
    $cleanEvidence += (
        "artifact:replacement-continuity:$normalizedReplacementPath"
    )
    $cleanEvidence += (
        'observation:replacement-continuity-hash:' +
        [string]$replacementReceipt.receipt_hash
    )
}
if ($Status -eq 'result_pending' -and $null -eq $recoveryReceipt) {
    throw 'result_pending requires a verified RecoveryReceiptPath.'
}
if ($Status -ne 'result_pending' -and $null -ne $recoveryReceipt) {
    throw 'RecoveryReceiptPath is only valid for result_pending.'
}
if ($Status -eq 'replacement_pending' -and $null -eq $replacementReceipt) {
    throw (
        'replacement_pending requires a verified ' +
        'ReplacementContinuityReceiptPath.'
    )
}
if ($Status -ne 'replacement_pending' -and $null -ne $replacementReceipt) {
    throw (
        'ReplacementContinuityReceiptPath is only valid for ' +
        'replacement_pending.'
    )
}
foreach ($entry in $cleanEvidence) {
    if ($entry -notmatch '^(artifact|test|source|observation):\S.+$') {
        throw "Evidence must use kind:value format: artifact, test, source, or observation."
    }
    if ($entry -match ',\s*(artifact|test|source|observation):') {
        throw (
            'Evidence contains multiple typed pointers joined into one value. ' +
            'Pass each pointer as a separate Evidence array item.'
        )
    }
}
$revisionAuthorization = $null
$normalizedRevisionAuthorizationPath = $null
if (-not [string]::IsNullOrWhiteSpace(
    $MilestoneRevisionAuthorizationReceiptPath
)) {
    if ([IO.Path]::IsPathRooted($MilestoneRevisionAuthorizationReceiptPath)) {
        throw 'MilestoneRevisionAuthorizationReceiptPath must be run-relative.'
    }
    $normalizedRevisionAuthorizationPath = (
        $MilestoneRevisionAuthorizationReceiptPath.Replace('\', '/')
    )
    $revisionAuthorization = Read-DurableReviewMilestoneRevisionAuthorization `
        -Path (Join-Path $RunDirectory $normalizedRevisionAuthorizationPath) `
        -RunDirectory $RunDirectory
    $cleanEvidence += "artifact:$normalizedRevisionAuthorizationPath"
    $cleanEvidence += (
        'observation:milestone-revision-authorization-hash:' +
        [string]$revisionAuthorization.receipt_hash
    )
}
if ($Status -eq 'failed' -and $ErrorClass -eq 'startup_unmaterialized' -and
    $null -eq $reconciliationReceipt) {
    throw (
        'startup_unmaterialized requires a verified no-match ' +
        'ReconciliationReceiptPath.'
    )
}
$requestPayload = [ordered]@{
        node_id = $NodeId
        status = $Status
        message = $Message
        thread_id = if ($ThreadId) { $ThreadId } else { $null }
        model_id = if ($ModelId) { $ModelId } else { $null }
        artifact = if ($Artifact) { $Artifact } else { $null }
        decision = if ($Decision) { $Decision } else { $null }
        human_actor = if ($HumanActor) { $HumanActor } else { $null }
        evidence = $cleanEvidence
        wave = $effectiveWave
        error_class = if ($ErrorClass) { $ErrorClass } else { $null }
        input_tokens_delta = $InputTokensDelta
        output_tokens_delta = $OutputTokensDelta
        coordination_tokens_delta = $CoordinationTokensDelta
        usage_source = $UsageSource
        recovery_receipt_path = $normalizedRecoveryPath
        recovery_receipt_hash = if ($recoveryReceipt) {
            [string]$recoveryReceipt.receipt_hash
        } else { $null }
        replacement_receipt_path = $normalizedReplacementPath
        replacement_receipt_hash = if ($replacementReceipt) {
            [string]$replacementReceipt.receipt_hash
        } else { $null }
        adopt_activated_lifecycle = [bool]$AdoptActivatedLifecycle
}
if ($revisionAuthorization) {
    $requestPayload['milestone_revision_authorization_receipt_path'] =
        $normalizedRevisionAuthorizationPath
    $requestPayload['milestone_revision_authorization_receipt_hash'] =
        [string]$revisionAuthorization.receipt_hash
}
if ($ModelVerificationState -eq 'unverified') {
    $requestPayload['model_verification_state'] = $ModelVerificationState
    $requestPayload['model_verification_evidence'] = $ModelVerificationEvidence
}
$requestFingerprint = Get-TextSha256 (
    $requestPayload | ConvertTo-Json -Compress -Depth 10
)
$archiveReceiptHash = $null
$archiveReceiptRelativePath = $null

$transitions = @{
    planned = @('launch_reserved', 'running', 'needs_input', 'completed', 'cancelled')
    launch_reserved = @('materializing', 'failed', 'cancelled', 'unknown')
    materializing = @('materialized', 'failed', 'cancelled', 'unknown')
    materialized = @('running', 'failed', 'cancelled')
    running = @(
        'needs_input', 'result_pending', 'completed', 'failed',
        'cancelled', 'unknown'
    )
    result_pending = @('running', 'completed', 'replacement_pending')
    replacement_pending = @('running')
    needs_input = @('running', 'completed', 'failed', 'cancelled', 'unknown')
    completed = @('validated', 'rejected')
    validated = @('adopted', 'rejected')
    adopted = @('archived')
    failed = @('launch_reserved', 'rejected')
    unknown = @('rejected')
    cancelled = @()
    rejected = @()
    archived = @()
}

$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the orchestration journal lock.'
    }
    $events = @(Read-OrchestrationJournal $eventsPath)
    $currentPlanHash = Get-TextSha256 (
        Get-Content -LiteralPath $planPath -Raw
    )
    if ($currentPlanHash -ne $runMetadata.plan_hash -or
        $events[0].plan_hash -ne $runMetadata.plan_hash) {
        throw 'plan.json or run metadata changed after run creation.'
    }
    if ($runMetadata.run_id -ne $plan.run_id -or
        $runMetadata.policy_version -ne $plan.policy_version -or
        $events[0].run_id -ne $runMetadata.run_id -or
        $events[0].policy_version -ne $runMetadata.policy_version) {
        throw 'run.json metadata is inconsistent with the immutable plan or journal.'
    }
    if ($events[0].workspace_root -ne $runMetadata.workspace_root) {
        throw 'Workspace root changed after run creation.'
    }
    $runPolicy = Resolve-OrchestrationRunPolicy -RunDirectory $RunDirectory `
        -Events $events

    $history = @($events | Where-Object { $_.node_id -eq $NodeId })
    $priorState = if ($history.Count) { [string]$history[-1].status } else { 'planned' }
    $isRecoveryCycleReentry = $false
    $isMilestoneRevisionRearm = $false
    $previousAdoptedEvent = $null
    $previousReviewBindingKind = ''
    $previousResultRelativePath = ''
    $previousResultReceiptHash = ''
    $previousDispositionRelativePath = ''
    $previousDispositionReceiptHash = ''
    $previousMilestoneActivationRelativePath = ''
    $previousMilestoneActivationReceiptHash = ''
    $previousMilestoneActivationEvent = $null
    if ($priorState -eq 'adopted' -and $Status -eq 'result_pending') {
        if ($null -eq $recoveryReceipt -or
            [string]$recoveryReceipt.schema_version -ne '1.2' -or
            [string]$recoveryReceipt.recovery_stage -ne 'original' -or
            [int]$recoveryReceipt.attempt -ne 1) {
            throw (
                'An adopted source may re-enter result_pending only through ' +
                'an unused original schema 1.2 recovery cycle at attempt one.'
            )
        }
        if ($history.Count -lt 3) {
            throw 'Recovery-cycle re-entry requires a prior adopted result chain.'
        }
        $previousAdoptedEvent = $history[-1]
        $previousValidatedEvent = $history[-2]
        $previousCompletedEvent = $history[-3]
        if ([string]$previousAdoptedEvent.status -ne 'adopted' -or
            [string]$previousValidatedEvent.status -ne 'validated' -or
            [string]$previousCompletedEvent.status -ne 'completed' -or
            [string]$previousAdoptedEvent.prior_state -ne 'validated' -or
            [string]$previousValidatedEvent.prior_state -ne 'completed' -or
            [string]$previousAdoptedEvent.prev_hash -ne
                [string]$previousValidatedEvent.hash -or
            [string]$previousValidatedEvent.prev_hash -ne
                [string]$previousCompletedEvent.hash) {
            throw (
                'Recovery-cycle re-entry requires the immediately preceding ' +
                'completed, validated, and adopted event chain.'
            )
        }
        $resultPointers = @(
            @($previousCompletedEvent.evidence) | Where-Object {
                [string]$_ -like 'artifact:receipts/*.thread-result-receipt.json'
            }
        )
        $dispositionPointers = @(
            @($previousAdoptedEvent.evidence) | Where-Object {
                [string]$_ -like 'artifact:receipts/*.disposition.json'
            }
        )
        $priorResult = $null
        $priorDisposition = $null
        if ($resultPointers.Count -eq 1 -and $dispositionPointers.Count -eq 1) {
            $priorResultRelativePath = (
                [string]$resultPointers[0]
        ).Substring('artifact:'.Length).Replace('\', '/')
            $priorDispositionRelativePath = (
                [string]$dispositionPointers[0]
        ).Substring('artifact:'.Length).Replace('\', '/')
            $priorResultPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath $priorResultRelativePath `
                -Label 'Prior review result receipt'
            $priorDispositionPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath $priorDispositionRelativePath `
                -Label 'Prior review disposition receipt'
            $priorResult = Read-ThreadResultReceipt -Path $priorResultPath `
                -ExpectedThreadId $ThreadId -ExpectedSourceNodeId $NodeId `
                -RunDirectory $RunDirectory
            $priorDisposition = Read-ReviewDispositionReceipt `
                -Path $priorDispositionPath -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId $NodeId -ExpectedThreadId $ThreadId
            if ([string]$priorResult.schema_version -eq '1.3' -and
                [string]$priorResult.milestone_id -eq
                    [string]$recoveryReceipt.milestone_id -and
                [string]$priorDisposition.milestone_id -eq
                    [string]$recoveryReceipt.milestone_id -and
                [string]$priorDisposition.source_result_receipt_hash -eq
                    [string]$priorResult.receipt_hash) {
                $previousReviewBindingKind = 'node-lifecycle'
            } else {
                $priorResult = $null
                $priorDisposition = $null
            }
        }
        if ($null -eq $priorResult) {
            $milestoneChain = Read-DurableReviewMilestoneActivationChain `
                -RunDirectory $RunDirectory
            $activeBindings = @(
                $milestoneChain.active_source_bindings | Where-Object {
                    [string]$_.source_node_id -eq $NodeId
                }
            )
            if ([string]$milestoneChain.active_milestone_id -ne
                    [string]$recoveryReceipt.milestone_id -or
                [string]::IsNullOrWhiteSpace(
                    [string]$milestoneChain.activation_receipt_path
                ) -or
                [string]$milestoneChain.activation_receipt_path -ne
                    [string]$recoveryReceipt.
                        milestone_activation_receipt_path -or
                [string]$milestoneChain.activation_receipt_hash -ne
                    [string]$recoveryReceipt.
                        milestone_activation_receipt_hash -or
                $activeBindings.Count -ne 1 -or
                [string]$activeBindings[0].source_thread_id -ne $ThreadId) {
                throw (
                    'Recovery-cycle re-entry does not match the prior verified ' +
                    'result, disposition, and active milestone.'
                )
            }
            $activeBinding = $activeBindings[0]
            $activeResultRelativePath =
                [string]$activeBinding.result_receipt_path
            $activeDispositionRelativePath =
                [string]$activeBinding.disposition_receipt_path
            $activeResultPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath $activeResultRelativePath `
                -Label 'Active milestone result receipt'
            $activeDispositionPath = Get-RunLocalReceiptPath `
                -RunDirectory $RunDirectory `
                -RelativePath $activeDispositionRelativePath `
                -Label 'Active milestone disposition receipt'
            $activeResult = Read-ThreadResultReceipt -Path $activeResultPath `
                -ExpectedThreadId $ThreadId -ExpectedSourceNodeId $NodeId `
                -RunDirectory $RunDirectory
            $activeDisposition = Read-ReviewDispositionReceipt `
                -Path $activeDispositionPath -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId $NodeId -ExpectedThreadId $ThreadId
            $matchingActivationEvents = @($events | Where-Object {
                [string]$_.event -in @(
                    'milestone-activated', 'milestone-revision-selected'
                ) -and
                [string]$_.milestone_id -eq
                    [string]$milestoneChain.active_milestone_id -and
                [string]$_.milestone_activation_receipt_path -eq
                    [string]$milestoneChain.activation_receipt_path -and
                [string]$_.milestone_activation_receipt_hash -eq
                    [string]$milestoneChain.activation_receipt_hash
            })
            if ([string]$activeResult.schema_version -ne '1.3' -or
                [string]$activeResult.milestone_id -ne
                    [string]$recoveryReceipt.milestone_id -or
                [string]$activeDisposition.milestone_id -ne
                    [string]$recoveryReceipt.milestone_id -or
                [string]$activeDisposition.source_result_receipt_hash -ne
                    [string]$activeResult.receipt_hash -or
                [string]$activeBinding.result_receipt_hash -ne
                    [string]$activeResult.receipt_hash -or
                [string]$activeBinding.disposition_receipt_hash -ne
                    [string]$activeDisposition.receipt_hash -or
                $matchingActivationEvents.Count -ne 1 -or
                [int]$matchingActivationEvents[0].sequence -le
                    [int]$previousAdoptedEvent.sequence) {
                throw (
                    'Recovery-cycle re-entry active milestone source binding ' +
                    'is incomplete, stale, or ambiguous.'
                )
            }
            $priorResult = $activeResult
            $priorDisposition = $activeDisposition
            $priorResultRelativePath = $activeResultRelativePath
            $priorDispositionRelativePath =
                $activeDispositionRelativePath
            $previousReviewBindingKind =
                'active-milestone-source-binding'
            $previousMilestoneActivationRelativePath =
                [string]$milestoneChain.activation_receipt_path
            $previousMilestoneActivationReceiptHash =
                [string]$milestoneChain.activation_receipt_hash
            $previousMilestoneActivationEvent =
                $matchingActivationEvents[0]
        }
        $previousResultRelativePath = $priorResultRelativePath
        $previousResultReceiptHash = [string]$priorResult.receipt_hash
        $previousDispositionRelativePath = $priorDispositionRelativePath
        $previousDispositionReceiptHash =
            [string]$priorDisposition.receipt_hash
        $priorCheckpointPath = Get-RunLocalReceiptPath `
            -RunDirectory $RunDirectory `
            -RelativePath ([string]$priorResult.checkpoint_material_path) `
            -Label 'Prior review checkpoint material'
        $priorCheckpointTextHash = Get-TextSha256 (
            Get-Content -LiteralPath $priorCheckpointPath -Raw
        )
        if ($priorCheckpointTextHash -eq
            [string]$recoveryReceipt.checkpoint_hash) {
            throw (
                'Recovery-cycle re-entry requires a new checkpoint; the prior ' +
                'checkpoint cannot be replayed.'
            )
        }
        $isRecoveryCycleReentry = $true
    }
    if ($priorState -eq 'adopted' -and $Status -eq 'running') {
        if ($null -eq $revisionAuthorization) {
            throw (
                'An adopted durable source remains terminal unless a pending ' +
                'first-milestone revision authorization explicitly re-arms it.'
            )
        }
        $sourceBinding = @($revisionAuthorization.required_sources |
            Where-Object { [string]$_.source_node_id -eq $NodeId })
        if ($sourceBinding.Count -ne 1 -or
            [string]$sourceBinding[0].role_id -ne [string]$node.role_id -or
            [string]$sourceBinding[0].thread_id -ne $ThreadId -or
            -not [bool]$node.read_only -or [bool]$node.allow_delegation -or
            @($node.write_scope).Count -gt 0) {
            throw 'Milestone revision re-arm changed source identity or permissions.'
        }
        $authorizationEvents = @($events | Where-Object {
            [string]$_.event -eq 'milestone-revision-authorized' -and
            [string]$_.milestone_revision_id -eq
                [string]$revisionAuthorization.revision_id
        })
        $selectionEvents = @($events | Where-Object {
            [string]$_.event -eq 'milestone-revision-selected' -and
            [string]$_.milestone_revision_id -eq
                [string]$revisionAuthorization.revision_id
        })
        $priorRearms = @($history | Where-Object {
            $null -ne $_.PSObject.Properties['milestone_revision_id'] -and
            $null -ne $_.PSObject.Properties[
                'milestone_revision_authorization_receipt_hash'
            ] -and
            [string]$_.milestone_revision_id -eq
                [string]$revisionAuthorization.revision_id -and
            [string]$_.milestone_revision_authorization_receipt_hash -eq
                [string]$revisionAuthorization.receipt_hash
        })
        if ($authorizationEvents.Count -ne 1 -or
            $selectionEvents.Count -ne 0 -or $priorRearms.Count -ne 0) {
            throw 'Milestone revision authorization is not pending or was already used.'
        }
        $isMilestoneRevisionRearm = $true
    } elseif ($null -ne $revisionAuthorization) {
        throw (
            'MilestoneRevisionAuthorizationReceiptPath is only valid for the ' +
            'narrow adopted-to-running revision re-arm.'
        )
    }
    $isActivatedLifecycleAdoption = (
        $AdoptActivatedLifecycle -and
        $priorState -eq 'planned' -and
        $Status -eq 'replacement_pending' -and
        $null -ne $replacementReceipt -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$runPolicy.activation_receipt_path
        )
    )
    if ($AdoptActivatedLifecycle -and -not $isActivatedLifecycleAdoption) {
        throw (
            'Activated lifecycle adoption requires a planned source, a verified ' +
            'replacement continuity receipt, and a run-policy activation receipt.'
        )
    }
    if ($isActivatedLifecycleAdoption) {
        $activation = Read-RunPolicyActivationReceipt `
            -RunDirectory $RunDirectory -Events $events
        $sourceBinding = @($activation.source_obligations | Where-Object {
            [string]$_.source_node_id -eq $NodeId
        }) | Select-Object -First 1
        if ($null -eq $sourceBinding -or
            [string]$sourceBinding.role_id -ne [string]$node.role_id -or
            [string]$sourceBinding.replacement_thread_id -ne $ThreadId -or
            [string]$sourceBinding.replacement_continuity_receipt_hash -ne
                [string]$replacementReceipt.receipt_hash) {
            throw (
                'Activated lifecycle does not match the source obligation ' +
                'captured by the policy activation receipt.'
            )
        }
    }
    if ($Status -eq 'archived' -and $node.kind -eq 'agent' -and
        $node.topology -eq 'background-thread') {
        $receiptEvidence = @(
            $history | ForEach-Object { @($_.evidence) } | Where-Object {
                $_ -like 'artifact:receipts/*.thread-result-receipt.json'
            }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$receiptEvidence)) {
            throw 'Archiving a background thread requires a recorded result receipt.'
        }
        $archiveReceiptRelativePath = (
            [string]$receiptEvidence
        ).Substring('artifact:'.Length).Replace('\', '/')
        $receiptSegments = $archiveReceiptRelativePath -split '[\\/]'
        if (@($receiptSegments | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
        }).Count -gt 0) {
            throw 'Archive result receipt path is unsafe.'
        }
        $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
        $archiveReceiptPath = [IO.Path]::GetFullPath(
            (Join-Path $runRoot $archiveReceiptRelativePath)
        )
        if (-not $archiveReceiptPath.StartsWith(
            $runRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Archive result receipt escapes the run.'
        }
        $resultThreadEvent = @(
            $history | Where-Object {
                $_.status -in @('completed', 'materialized') -and
                -not [string]::IsNullOrWhiteSpace([string]$_.thread_id)
            }
        ) | Select-Object -Last 1
        if ($null -eq $resultThreadEvent) {
            throw 'Archive result receipt has no result thread binding.'
        }
        $archiveReceipt = Read-ThreadResultReceipt `
            -Path $archiveReceiptPath `
            -ExpectedThreadId ([string]$resultThreadEvent.thread_id) `
            -ExpectedSourceNodeId $NodeId `
            -RunDirectory $RunDirectory
        $archiveReceiptHash = [string]$archiveReceipt.receipt_hash
    }
    $existing = @(
        $events | Where-Object { $_.idempotency_key -eq $IdempotencyKey }
    ) | Select-Object -First 1
    if ($null -ne $existing) {
        if ($existing.node_id -ne $NodeId -or $existing.status -ne $Status -or
            $existing.request_fingerprint -ne $requestFingerprint) {
            throw "IdempotencyKey '$IdempotencyKey' was already used for another event."
        }
        if ($Status -eq 'archived' -and (
            [string]$existing.result_receipt_path -ne $archiveReceiptRelativePath -or
            [string]$existing.result_receipt_hash -ne $archiveReceiptHash
        )) {
            throw "IdempotencyKey '$IdempotencyKey' no longer matches the verified result receipt."
        }
        $existing | ConvertTo-Json -Depth 10
        return
    }

    if ($Status -notin @($transitions[$priorState]) -and
        -not $isActivatedLifecycleAdoption -and
        -not $isRecoveryCycleReentry -and
        -not $isMilestoneRevisionRearm) {
        throw "Illegal state transition for '$NodeId': $priorState -> $Status."
    }

    $latestStates = @{}
    foreach ($planNode in $plan.nodes) { $latestStates[$planNode.id] = 'planned' }
    foreach ($journalEvent in $events | Where-Object { $null -ne $_.node_id }) {
        $latestStates[[string]$journalEvent.node_id] = [string]$journalEvent.status
    }
    if ($priorState -eq 'planned') {
        $dependencySuccess = @('adopted', 'archived')
        foreach ($dependency in @($node.depends_on)) {
            if ($latestStates[[string]$dependency] -notin $dependencySuccess) {
                throw "Node '$NodeId' cannot start before dependency '$dependency' is adopted."
            }
        }
        if ($node.kind -eq 'agent' -and $Status -eq 'launch_reserved') {
            $earlierWaveTerminal = @('adopted', 'archived', 'rejected', 'cancelled')
            foreach ($earlierNode in @($plan.nodes | Where-Object {
                $_.kind -eq 'agent' -and [int]$_.wave -lt [int]$node.wave
            })) {
                if ($latestStates[[string]$earlierNode.id] -notin $earlierWaveTerminal) {
                    throw "Node '$NodeId' cannot start before earlier-wave node '$($earlierNode.id)' reaches a terminal state."
                }
            }
        }
    }

    $kind = [string]$node.kind
    if ($kind -eq 'agent' -and $priorState -eq 'planned' -and
        $Status -ne 'launch_reserved' -and
        -not $isActivatedLifecycleAdoption -and
        -not $isRecoveryCycleReentry -and
        -not $isMilestoneRevisionRearm) {
        throw "Agent node '$NodeId' must reserve capacity before launch."
    }
    if ($kind -eq 'main' -and $priorState -eq 'planned' -and
        $Status -notin @('running', 'cancelled')) {
        throw "Main node '$NodeId' must enter running before completion."
    }
    if ($kind -eq 'human-gate' -and $priorState -eq 'planned' -and
        $Status -notin @('needs_input', 'cancelled')) {
        throw "Human gate '$NodeId' must enter needs_input before completion."
    }
    if ($kind -eq 'join' -and $priorState -eq 'planned' -and
        $Status -notin @('completed', 'cancelled')) {
        throw "Join node '$NodeId' may only complete after its dependencies."
    }
    if ($kind -ne 'agent' -and $Status -in @(
        'launch_reserved', 'materializing', 'materialized'
    )) {
        throw "Only agent nodes use launch lifecycle states."
    }
    if ($kind -eq 'agent' -and $Status -eq 'materialized' -and
        [string]::IsNullOrWhiteSpace($ThreadId)) {
        throw "Materialized agent node '$NodeId' requires ThreadId."
    }
    if ($Status -in @('result_pending', 'replacement_pending') -and
        ($kind -ne 'agent' -or
            [string]$node.topology -ne 'background-thread' -or
            [string]::IsNullOrWhiteSpace($ThreadId))) {
        throw (
            \"$Status requires a durable background agent and a concrete thread.\"
        )
    }
    if ($priorState -eq 'result_pending' -and $Status -eq 'running') {
        $lastPending = @($history | Where-Object {
            [string]$_.status -eq 'result_pending'
        }) | Select-Object -Last 1
        if ([string]$lastPending.thread_id -ne $ThreadId) {
            throw 'Same-source recovery must keep the original thread.'
        }
        $lastRecovery = Read-ThreadResultRecoveryReceipt `
            -Path (Join-Path $RunDirectory (
                [string]$lastPending.recovery_receipt_path
            )) -RunDirectory $RunDirectory `
            -ExpectedSourceNodeId $NodeId `
            -ExpectedOriginalThreadId ([string]$lastPending.thread_id)
        if ([string]$lastRecovery.outcome -eq 'recovery-exhausted') {
            throw (
                'Recovery attempt 3 is exhausted; the same recovery epoch ' +
                'cannot return to running.'
            )
        }
    }
    if ($priorState -eq 'result_pending' -and
        $Status -eq 'replacement_pending') {
        $lastPending = @($history | Where-Object {
            [string]$_.status -eq 'result_pending'
        }) | Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$lastPending.recovery_receipt_path
        )) {
            $pendingRecovery = Read-ThreadResultRecoveryReceipt `
                -Path (Join-Path $RunDirectory (
                    [string]$lastPending.recovery_receipt_path
                )) -RunDirectory $RunDirectory `
                -ExpectedSourceNodeId $NodeId `
                -ExpectedOriginalThreadId ([string]$lastPending.thread_id)
            $stageProperty = $pendingRecovery.PSObject.Properties[
                'recovery_stage'
            ]
            if ($null -ne $stageProperty -and
                [string]$stageProperty.Value -eq 'replacement') {
                throw (
                    'A replacement source may use bounded same-thread recovery ' +
                    'but cannot authorize a replacement-of-replacement.'
                )
            }
        }
    }
    if ($priorState -eq 'replacement_pending' -and $Status -eq 'running') {
        $lastReplacement = @($history | Where-Object {
            [string]$_.status -eq 'replacement_pending'
        }) | Select-Object -Last 1
        if ([string]$lastReplacement.thread_id -ne $ThreadId) {
            throw 'Replacement execution must keep the bound replacement thread.'
        }
    }
    if ($kind -eq 'agent' -and $Status -eq 'materialized') {
        if ($node.context.session_policy -eq 'fresh') {
            $alreadyUsed = @($events | Where-Object {
                $_.thread_id -eq $ThreadId
            }).Count -gt 0
            if ($alreadyUsed) {
                throw "Fresh agent node '$NodeId' cannot reuse thread '$ThreadId'."
            }
        } elseif ($ThreadId -ne $node.context.prior_thread_id) {
            throw "Reuse agent node '$NodeId' must materialize its declared prior_thread_id."
        }
    }
    if ($kind -eq 'human-gate' -and $Status -eq 'completed') {
        if ([string]::IsNullOrWhiteSpace($Decision) -or
            [string]::IsNullOrWhiteSpace($HumanActor)) {
            throw "Human gate '$NodeId' completion requires Decision and HumanActor."
        }
        if ($Decision -notin @($node.choices)) {
            throw "Human gate '$NodeId' decision '$Decision' is not an allowed choice."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Decision) -or
        -not [string]::IsNullOrWhiteSpace($HumanActor)) {
        throw 'Decision and HumanActor are only valid when completing a human gate.'
    }
    if ($kind -in @('agent', 'main') -and $Status -eq 'needs_input') {
        $role = @($plan.roles | Where-Object { $_.id -eq $node.role_id }) |
            Select-Object -First 1
        $priorQuestions = @($history | Where-Object { $_.status -eq 'needs_input' }).Count
        if ($priorQuestions -ge [int]$role.question_policy.max_questions) {
            throw "Node '$NodeId' exceeds role '$($node.role_id)' question limit."
        }
    }
    if ($kind -in @('agent', 'main') -and $Status -eq 'completed' -and
        $cleanEvidence.Count -eq 0) {
        throw "Node '$NodeId' completion requires at least one Evidence entry."
    }

    $attemptValues = @($history | ForEach-Object {
        if ($null -ne $_.PSObject.Properties['attempt']) {
            [int]$_.attempt
        }
    })
    $attempt = if ($attemptValues.Count) {
        [int](($attemptValues | Measure-Object -Maximum).Maximum)
    } else { 0 }
    $executionSlotDelta = 0
    if ($Status -eq 'launch_reserved') {
        $attempt++
        if ($attempt -gt [int]$node.max_attempts -or
            $attempt -gt [int]$plan.limits.max_attempts_per_node) {
            throw "Node '$NodeId' exceeds its attempt limit."
        }

        $launchEvents = @($events | Where-Object { $_.status -eq 'launch_reserved' })
        $latestByNode = @{}
        foreach ($event in $events | Where-Object { $null -ne $_.node_id }) {
            $latestByNode[[string]$event.node_id] = [string]$event.status
        }
        $pendingStates = @('launch_reserved', 'materializing')
        $pendingCount = @(
            $latestByNode.Values | Where-Object { $_ -in $pendingStates }
        ).Count
        $materializedCount = @(
            $events | Where-Object { $_.status -eq 'materialized' }
        ).Count
        $adoptedReplacementCount = @(
            $latestByNode.GetEnumerator() | Where-Object {
                $_.Value -eq 'replacement_pending'
            }
        ).Count
        $occupiedWorkerSlots = $pendingCount + $materializedCount +
            $adoptedReplacementCount
        if ($occupiedWorkerSlots -ge [int]$plan.limits.max_total_agent_nodes) {
            throw 'Total agent execution slots are exhausted.'
        }
        $retryCount = 0
        foreach ($nodeEvents in @(
            $events | Where-Object { $null -ne $_.node_id } |
                Group-Object node_id
        )) {
            $attemptSeen = $false
            $attemptMaterialized = $false
            foreach ($nodeEvent in @($nodeEvents.Group)) {
                if ($nodeEvent.status -eq 'launch_reserved') {
                    if ($attemptSeen -and $attemptMaterialized) {
                        $retryCount++
                    }
                    $attemptSeen = $true
                    $attemptMaterialized = $false
                } elseif ($nodeEvent.status -eq 'materialized') {
                    $attemptMaterialized = $true
                }
            }
        }
        if ($priorState -eq 'failed' -and
            $retryCount -ge [int]$plan.limits.retry_reserve) {
            $lastFailure = @(
                $history | Where-Object { $_.status -eq 'failed' }
            ) | Select-Object -Last 1
            if ($lastFailure.error_class -ne 'startup_unmaterialized') {
                throw 'Retry reserve is exhausted.'
            }
        }
        if ($priorState -eq 'failed') {
            $lastFailure = @(
                $history | Where-Object { $_.status -eq 'failed' }
            ) | Select-Object -Last 1
            if ($lastFailure.error_class -eq 'startup_unmaterialized' -and
                'observation:task-list-reconciled-no-match' -notin
                @($lastFailure.evidence)) {
                throw 'Startup retry requires task-list reconciliation evidence.'
            }
            if ($lastFailure.error_class -eq 'startup_unmaterialized') {
                $reconciliationArtifact = @(
                    $lastFailure.evidence | Where-Object {
                        $_ -like 'artifact:thread-reconciliation:*'
                    }
                ) | Select-Object -Last 1
                $reconciliationHashEvidence = @(
                    $lastFailure.evidence | Where-Object {
                        $_ -like 'observation:thread-reconciliation-hash:*'
                    }
                ) | Select-Object -Last 1
                if ([string]::IsNullOrWhiteSpace(
                    [string]$reconciliationArtifact
                ) -or [string]::IsNullOrWhiteSpace(
                    [string]$reconciliationHashEvidence
                )) {
                    throw 'Startup retry lacks a bound reconciliation receipt.'
                }
                $relativeReconciliationPath = (
                    [string]$reconciliationArtifact
                ).Substring('artifact:thread-reconciliation:'.Length)
                $verifiedReconciliation = Read-ThreadReconciliationReceipt `
                    -Path (Join-Path $RunDirectory $relativeReconciliationPath) `
                    -RunDirectory $RunDirectory -ExpectedDecision 'no_match'
                if ([string]$reconciliationHashEvidence -ne (
                    'observation:thread-reconciliation-hash:' +
                    [string]$verifiedReconciliation.receipt_hash
                )) {
                    throw 'Startup retry reconciliation receipt was changed.'
                }
            }
            if ($lastFailure.error_class -in $deterministicFailureClasses) {
                if ([string]::IsNullOrWhiteSpace($ActionKey) -or
                    [string]::IsNullOrWhiteSpace($premiseFingerprint)) {
                    throw (
                        'Retry after a deterministic failure requires ' +
                        'ActionKey and PremiseManifestPath.'
                    )
                }
                $requiredAuthorization = "user:$($lastFailure.hash)"
                if ($RetryAuthorization -ne $requiredAuthorization) {
                    throw (
                        'Retry after a deterministic failure requires ' +
                        "explicit authorization '$requiredAuthorization'."
                    )
                }
                $authorizationEvidence = (
                    "source:retry-authorization:$requiredAuthorization"
                )
                if (@($events | Where-Object {
                    $authorizationEvidence -in @($_.evidence)
                }).Count -gt 0) {
                    throw 'Retry authorization was already consumed.'
                }
            }
        }

        $activeStates = @(
            'launch_reserved', 'materializing', 'materialized', 'running', 'needs_input'
        )
        $activeNodeIds = @(
            $latestByNode.GetEnumerator() | Where-Object {
                $_.Value -in $activeStates
            } | ForEach-Object { $_.Key }
        )
        $activeCount = $activeNodeIds.Count
        if ($activeCount -ge [int]$plan.limits.max_concurrent_nodes) {
            throw 'Concurrent agent slots are exhausted.'
        }
        if ($node.topology -eq 'background-thread') {
            $activePersistentCount = @(
                $plan.nodes | Where-Object {
                    $_.kind -eq 'agent' -and
                    $_.topology -eq 'background-thread' -and
                    $_.id -in $activeNodeIds
                }
            ).Count
            if ($activePersistentCount -ge
                [int]$plan.limits.persistent_active_limit) {
                throw 'Persistent active Worker limit is exhausted.'
            }
        }
        $waveCount = @(
            $launchEvents | Where-Object { [int]$_.wave -eq $effectiveWave }
        ).Count
        if ($waveCount -ge [int]$plan.limits.max_new_nodes_per_wave) {
            throw "Wave $effectiveWave exceeds max_new_nodes_per_wave."
        }

        $launchedNodeIds = @($launchEvents | ForEach-Object { $_.node_id })
        $unlaunchedVerification = @(
            $plan.nodes | Where-Object {
                $_.kind -eq 'agent' -and $_.purpose -eq 'verification' -and
                $_.id -ne $NodeId -and
                $_.id -notin $launchedNodeIds
            }
        ).Count
        $remainingAfterLaunch = [int]$plan.limits.max_total_agent_nodes -
            ($occupiedWorkerSlots + 1)
        if ($remainingAfterLaunch -lt $unlaunchedVerification) {
            throw 'Launch would consume capacity reserved for planned verification nodes.'
        }
        $executionSlotDelta = 1
    }
    if ($isActivatedLifecycleAdoption) {
        $latestByNode = @{}
        foreach ($journalEvent in $events | Where-Object {
            $null -ne $_.node_id
        }) {
            $latestByNode[[string]$journalEvent.node_id] =
                [string]$journalEvent.status
        }
        $activeStates = @(
            'launch_reserved', 'materializing', 'materialized', 'running',
            'needs_input', 'replacement_pending', 'result_pending'
        )
        $activeNodeIds = @($latestByNode.GetEnumerator() | Where-Object {
            $_.Value -in $activeStates
        } | ForEach-Object { $_.Key })
        if ($activeNodeIds.Count -ge
            [int]$plan.limits.max_concurrent_nodes) {
            throw 'Concurrent agent slots are exhausted.'
        }
        $activePersistentCount = @($plan.nodes | Where-Object {
            $_.kind -eq 'agent' -and
            $_.topology -eq 'background-thread' -and
            $_.id -in $activeNodeIds
        }).Count
        if ($activePersistentCount -ge
            [int]$plan.limits.persistent_active_limit) {
            throw 'Persistent active Worker limit is exhausted.'
        }
        $occupiedNodeIds = @($events | Where-Object {
            [int]$_.execution_slot_delta -gt 0
        } | Select-Object -ExpandProperty node_id -Unique)
        if ($occupiedNodeIds.Count -ge
            [int]$plan.limits.max_total_agent_nodes) {
            throw 'Total agent execution slots are exhausted.'
        }
        $executionSlotDelta = 1
    }

    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = if ($events.Count) { $events[-1].hash } else { $null }
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'node-status'
        run_id = $plan.run_id
        plan_hash = $runMetadata.plan_hash
        workspace_root = $runMetadata.workspace_root
        policy_version = $plan.policy_version
        actor = $plan.orchestrator.id
        node_id = $NodeId
        role_id = if ($kind -in @('agent', 'main')) { $node.role_id } else { $null }
        prior_state = $priorState
        status = $Status
        message = $Message
        thread_id = if ($ThreadId) { $ThreadId } else { $null }
        model_id = if ($ModelId) { $ModelId } else { $null }
        artifact = if ($Artifact) { $Artifact } else { $null }
        topology = if ($kind -eq 'agent') { $node.topology } else { $kind }
        capability = if ($kind -in @('agent', 'main')) { $node.capability } else { $null }
        effort = if ($kind -in @('agent', 'main')) { $node.effort } else { $null }
        wave = $effectiveWave
        attempt = $attempt
        execution_slot_delta = $executionSlotDelta
        input_tokens_delta = $InputTokensDelta
        output_tokens_delta = $OutputTokensDelta
        coordination_tokens_delta = $CoordinationTokensDelta
        usage_source = $UsageSource
        error_class = if ($ErrorClass) { $ErrorClass } else { $null }
        decision = if ($Decision) { $Decision } else { $null }
        human_actor = if ($HumanActor) { $HumanActor } else { $null }
        evidence = $cleanEvidence
        recovery_receipt_path = $normalizedRecoveryPath
        recovery_receipt_hash = if ($recoveryReceipt) {
            [string]$recoveryReceipt.receipt_hash
        } else { $null }
        replacement_receipt_path = $normalizedReplacementPath
        replacement_receipt_hash = if ($replacementReceipt) {
            [string]$replacementReceipt.receipt_hash
        } else { $null }
        result_receipt_path = $archiveReceiptRelativePath
        result_receipt_hash = $archiveReceiptHash
        idempotency_key = $IdempotencyKey
        request_fingerprint = $requestFingerprint
    }
    if ($runPolicy.activation_receipt_path) {
        $event['runtime_policy_version'] =
            [string]$runPolicy.effective_policy_version
        $event['policy_activation_receipt_path'] =
            [string]$runPolicy.activation_receipt_path
        $event['policy_activation_receipt_hash'] =
            [string]$runPolicy.activation_receipt_hash
    }
    if ($isMilestoneRevisionRearm) {
        $event['milestone_id'] = [string]$revisionAuthorization.milestone_id
        $event['milestone_activation_receipt_path'] =
            $normalizedRevisionAuthorizationPath
        $event['milestone_activation_receipt_hash'] =
            [string]$revisionAuthorization.receipt_hash
        $event['milestone_revision_id'] =
            [string]$revisionAuthorization.revision_id
        $event['milestone_revision_authorization_receipt_path'] =
            $normalizedRevisionAuthorizationPath
        $event['milestone_revision_authorization_receipt_hash'] =
            [string]$revisionAuthorization.receipt_hash
        $event['milestone_revision_checkpoint_hash'] =
            [string]$revisionAuthorization.checkpoint_material_hash
        $event['milestone_revision_input_hash'] =
            [string]$revisionAuthorization.input_manifest_hash
    }
    if ($kind -eq 'agent' -and $Status -eq 'result_pending') {
        $priorPendingForThread = @($history | Where-Object {
            [string]$_.status -eq 'result_pending' -and
            [string]$_.thread_id -eq $ThreadId
        })
        if ([string]$recoveryReceipt.schema_version -eq '1.2') {
            $sameCyclePending = [Collections.Generic.List[object]]::new()
            foreach ($pendingEvent in $priorPendingForThread) {
                if ([string]::IsNullOrWhiteSpace(
                    [string]$pendingEvent.recovery_receipt_path
                )) {
                    continue
                }
                $pendingPath = Get-RunLocalReceiptPath `
                    -RunDirectory $RunDirectory `
                    -RelativePath ([string]$pendingEvent.recovery_receipt_path) `
                    -Label 'Prior recovery receipt'
                $pendingReceipt = Read-ThreadResultRecoveryReceipt `
                    -Path $pendingPath -RunDirectory $RunDirectory `
                    -ExpectedSourceNodeId $NodeId `
                    -ExpectedOriginalThreadId $ThreadId `
                    -ExpectedRecoveryStage original
                if ([string]$pendingReceipt.schema_version -eq '1.2' -and
                    [string]$pendingReceipt.recovery_cycle_id -eq
                        [string]$recoveryReceipt.recovery_cycle_id) {
                    $sameCyclePending.Add($pendingEvent)
                }
            }
            $priorPendingForThread = @($sameCyclePending)
        }
        if (@($priorPendingForThread | Where-Object {
            [string]$_.recovery_receipt_hash -eq
                [string]$recoveryReceipt.receipt_hash
        }).Count -gt 0) {
            throw 'A recovery receipt cannot be reused for another attempt.'
        }
        if ([int]$recoveryReceipt.attempt -ne
            ($priorPendingForThread.Count + 1)) {
            throw 'Recovery attempts must be recorded once in sequential order.'
        }
        if ([string]$recoveryReceipt.schema_version -eq '1.2') {
            $event['recovery_cycle_id'] =
                [string]$recoveryReceipt.recovery_cycle_id
            $event['recovery_milestone_id'] =
                [string]$recoveryReceipt.milestone_id
            $event['recovery_milestone_activation_receipt_hash'] =
                [string]$recoveryReceipt.milestone_activation_receipt_hash
            $event['recovery_checkpoint_hash'] =
                [string]$recoveryReceipt.checkpoint_hash
            $event['recovery_input_manifest_hash'] =
                [string]$recoveryReceipt.input_manifest_hash
            if ($isRecoveryCycleReentry) {
                $event['previous_adopted_event_sequence'] =
                    [int]$previousAdoptedEvent.sequence
                $event['previous_adopted_event_hash'] =
                    [string]$previousAdoptedEvent.hash
                $event['previous_review_binding_kind'] =
                    $previousReviewBindingKind
                $event['previous_result_receipt_path'] =
                    $previousResultRelativePath
                $event['previous_result_receipt_hash'] =
                    $previousResultReceiptHash
                $event['previous_disposition_receipt_path'] =
                    $previousDispositionRelativePath
                $event['previous_disposition_receipt_hash'] =
                    $previousDispositionReceiptHash
                if ($null -ne $previousMilestoneActivationEvent) {
                    $event['previous_milestone_activation_receipt_path'] =
                        $previousMilestoneActivationRelativePath
                    $event['previous_milestone_activation_receipt_hash'] =
                        $previousMilestoneActivationReceiptHash
                    $event['previous_milestone_activation_event_sequence'] =
                        [int]$previousMilestoneActivationEvent.sequence
                    $event['previous_milestone_activation_event_hash'] =
                        [string]$previousMilestoneActivationEvent.hash
                }
            }
        }
    }
    if ($ModelVerificationState -eq 'unverified') {
        $event['model_verification_state'] = $ModelVerificationState
        $event['model_verification_evidence'] = $ModelVerificationEvidence
    }
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    Add-Content -LiteralPath $eventsPath -Value ($event | ConvertTo-Json -Compress)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

$event | ConvertTo-Json -Depth 10
