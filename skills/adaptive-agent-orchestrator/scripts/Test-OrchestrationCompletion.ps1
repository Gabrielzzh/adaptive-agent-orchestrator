[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$planPath = Join-Path $RunDirectory 'plan.json'
$runPath = Join-Path $RunDirectory 'run.json'
if (-not (Test-Path -LiteralPath $planPath) -or
    -not (Test-Path -LiteralPath $runPath)) {
    throw "Run directory is incomplete: $RunDirectory"
}

$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 100
$run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
$state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
    -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 100
$root = (Resolve-Path -LiteralPath $run.workspace_root).Path.TrimEnd('\', '/')
$errors = [Collections.Generic.List[string]]::new()
$successStates = @('validated', 'adopted', 'archived')
$unverifiedActualModels = @(
    $state.nodes | Where-Object {
        $_.kind -eq 'agent' -and
        $_.actual_model_verification -eq 'unverified'
    } | Select-Object -ExpandProperty id
)

foreach ($nodeId in @($plan.completion.required_nodes)) {
    $planNode = @($plan.nodes | Where-Object { $_.id -eq $nodeId }) |
        Select-Object -First 1
    $nodeState = @($state.nodes | Where-Object { $_.id -eq $nodeId }) |
        Select-Object -First 1
    if ($null -eq $nodeState -or $nodeState.status -notin $successStates) {
        $errors.Add("Required node '$nodeId' is not validated.")
        continue
    }
    if ($planNode.kind -eq 'agent' -and
        $planNode.topology -eq 'background-thread') {
        $receiptEvidence = @($nodeState.evidence | Where-Object {
            $_ -like 'artifact:receipts/*.thread-result-receipt.json'
        }) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$receiptEvidence)) {
            $errors.Add(
                "Background node '$nodeId' lacks a thread result receipt."
            )
            continue
        }
        $relativeReceipt = [string]$receiptEvidence -replace '^artifact:', ''
        $receiptSegments = $relativeReceipt -split '[\\/]'
        if (@($receiptSegments | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
        }).Count -gt 0) {
            $errors.Add(
                "Background node '$nodeId' has an unsafe result receipt path."
            )
            continue
        }
        $receiptPath = [IO.Path]::GetFullPath(
            (Join-Path $RunDirectory $relativeReceipt)
        )
        $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
        if (-not $receiptPath.StartsWith(
            $runRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $errors.Add(
                "Background node '$nodeId' result receipt escapes the run."
            )
            continue
        }
        try {
            $null = Read-ThreadResultReceipt `
                -Path $receiptPath -ExpectedThreadId $nodeState.thread_id `
                -ExpectedSourceNodeId $nodeId `
                -RunDirectory $RunDirectory
        } catch {
            $errors.Add(
                "Background node '$nodeId' result receipt is invalid: " +
                $_.Exception.Message
            )
        }
    }
}

foreach ($check in @($plan.completion.artifact_checks)) {
    $segments = $check.path -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        $errors.Add("Artifact check contains an unsafe path segment: '$($check.path)'.")
        continue
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $check.path))
    if (-not $candidate.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $errors.Add("Artifact check escapes workspace root: '$($check.path)'.")
        continue
    }
    $cursor = $root
    $unsafeAncestor = $false
    foreach ($segment in $segments) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $ancestor = Get-Item -LiteralPath $cursor -Force
            if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $errors.Add("Artifact path crosses a link or reparse point: '$($check.path)'.")
                $unsafeAncestor = $true
                break
            }
        }
    }
    if ($unsafeAncestor) { continue }
    if (-not (Test-Path -LiteralPath $candidate)) {
        $errors.Add("Required artifact is missing: '$($check.path)'.")
        continue
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($check.type -eq 'file' -and -not $item.PSIsContainer) {
        if ($null -ne $check.PSObject.Properties['minimum_bytes'] -and
            $item.Length -lt [int64]$check.minimum_bytes) {
            $errors.Add("Artifact '$($check.path)' is smaller than minimum_bytes.")
        }
    } elseif ($check.type -eq 'file') {
        $errors.Add("Artifact '$($check.path)' must be a file.")
    }
    if ($check.type -eq 'directory' -and -not $item.PSIsContainer) {
        $errors.Add("Artifact '$($check.path)' must be a directory.")
    } elseif ($check.type -eq 'directory' -and
        $null -ne $check.PSObject.Properties['minimum_items']) {
        $count = @(Get-ChildItem -LiteralPath $candidate -Force).Count
        if ($count -lt [int]$check.minimum_items) {
            $errors.Add("Artifact '$($check.path)' has fewer than minimum_items.")
        }
    }
}

foreach ($check in @($plan.completion.evidence_checks)) {
    $nodeState = @($state.nodes | Where-Object { $_.id -eq $check.node_id }) |
        Select-Object -First 1
    $count = if ($null -eq $nodeState) { 0 } else { @($nodeState.evidence).Count }
    if ($count -lt [int]$check.minimum_entries) {
        $errors.Add("Node '$($check.node_id)' lacks required evidence entries.")
    }
}

$reviewDispositionChecks = if (
    $null -ne $plan.completion.PSObject.Properties[
        'review_disposition_checks'
    ]
) {
    @($plan.completion.review_disposition_checks)
} else { @() }
$canonicalReviewFindings = @{}
$reviewSourceCount = 0
$reviewDecisionCount = 0
$durableReviewNodeIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
if ($null -ne $plan.PSObject.Properties['durable_review_profile']) {
    foreach ($durableNodeId in @(
        @($plan.durable_review_profile.domain_node_ids) +
        @($plan.durable_review_profile.dissent_node_ids)
    )) {
        $null = $durableReviewNodeIds.Add([string]$durableNodeId)
    }
}
$checkedDurableReviewNodeIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$durableMilestoneChain = $null
$durableMilestoneError = ''
$activeDurableBindings = @{}
if ($durableReviewNodeIds.Count -gt 0) {
    try {
        $durableMilestoneChain =
            Read-DurableReviewMilestoneActivationChain `
                -RunDirectory $RunDirectory
        foreach ($binding in @(
            $durableMilestoneChain.active_source_bindings
        )) {
            $activeDurableBindings[[string]$binding.source_node_id] = $binding
        }
    } catch {
        $durableMilestoneError = $_.Exception.Message
        $errors.Add(
            'Durable review milestone chain is invalid: ' +
            $durableMilestoneError
        )
    }
}
foreach ($check in $reviewDispositionChecks) {
    $nodeId = [string]$check.source_node_id
    if ($durableReviewNodeIds.Contains($nodeId)) {
        $null = $checkedDurableReviewNodeIds.Add($nodeId)
    }
    $nodeState = @($state.nodes | Where-Object { $_.id -eq $nodeId }) |
        Select-Object -First 1
    if ($null -eq $nodeState -or
        [string]::IsNullOrWhiteSpace([string]$nodeState.thread_id)) {
        $errors.Add(
            "Review disposition source node '$nodeId' has no materialized thread."
        )
        continue
    }
    if ($durableReviewNodeIds.Contains($nodeId) -and
        -not [string]::IsNullOrWhiteSpace($durableMilestoneError)) {
        continue
    }
    $activeBinding = if ($activeDurableBindings.ContainsKey($nodeId)) {
        $activeDurableBindings[$nodeId]
    } else { $null }
    $relativeReceipt = if ($null -ne $activeBinding) {
        [string]$activeBinding.disposition_receipt_path
    } else {
        [string]$check.path
    }
    $expectedThreadId = if ($null -ne $activeBinding) {
        [string]$activeBinding.source_thread_id
    } else {
        [string]$nodeState.thread_id
    }
    if ($null -ne $activeBinding -and
        [string]$nodeState.thread_id -ne $expectedThreadId) {
        $errors.Add(
            "Active milestone source '$nodeId' does not match the current thread."
        )
        continue
    }
    $segments = $relativeReceipt -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        $errors.Add("Review disposition check has an unsafe path: '$relativeReceipt'.")
        continue
    }
    $receiptPath = [IO.Path]::GetFullPath(
        (Join-Path $RunDirectory $relativeReceipt)
    )
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    if (-not $receiptPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $errors.Add("Review disposition check escapes the run: '$relativeReceipt'.")
        continue
    }
    try {
        $receipt = Read-ReviewDispositionReceipt -Path $receiptPath `
            -RunDirectory $RunDirectory -ExpectedSourceNodeId $nodeId `
            -ExpectedThreadId $expectedThreadId
        if ($null -ne $activeBinding -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$durableMilestoneChain.activation_receipt_hash
            ) -and
            [string]$receipt.milestone_id -ne
                [string]$durableMilestoneChain.active_milestone_id) {
            throw 'Disposition does not match the active milestone.'
        }
        $reviewSourceCount++
        foreach ($decision in @($receipt.decisions)) {
            $reviewDecisionCount++
            $canonicalId = [string]$decision.canonical_finding_id
            if (-not $canonicalReviewFindings.ContainsKey($canonicalId)) {
                $canonicalReviewFindings[$canonicalId] =
                    [Collections.Generic.List[object]]::new()
            }
            $canonicalReviewFindings[$canonicalId].Add([pscustomobject]@{
                source_node_id = $nodeId
                source_thread_id = [string]$receipt.source_thread_id
                source_finding_id = [string]$decision.source_finding_id
                finding = [string]$decision.finding
                finding_hash = [string]$decision.finding_hash
                severity = [string]$decision.severity
                disposition = [string]$decision.disposition
                resolution_status = [string]$decision.resolution_status
            })
        }
        $blockingSeverities = @($check.blocking_severities)
        if ($durableReviewNodeIds.Contains($nodeId)) {
            if ('P0' -notin $blockingSeverities -or
                'P1' -notin $blockingSeverities) {
                $errors.Add(
                    "Durable review source '$nodeId' must always block P0 and P1."
                )
            }
            $blockingSeverities = @(
                @('P0', 'P1') + $blockingSeverities | Select-Object -Unique
            )
        }
        $openBlocking = @($receipt.decisions | Where-Object {
            [string]$_.severity -in $blockingSeverities -and
            [string]$_.resolution_status -ne 'resolved'
        })
        if ($openBlocking.Count -gt 0) {
            $errors.Add(
                "Review disposition check '$relativeReceipt' has unresolved " +
                (@($openBlocking | ForEach-Object {
                    "$($_.severity):$($_.finding)"
                }) -join ', ')
            )
        }
    } catch {
        $errors.Add(
            "Review disposition check '$relativeReceipt' is invalid: " +
            $_.Exception.Message
        )
    }
}
foreach ($durableNodeId in $durableReviewNodeIds) {
    if (-not $checkedDurableReviewNodeIds.Contains($durableNodeId)) {
        $errors.Add(
            "Durable review source '$durableNodeId' lacks a disposition check."
        )
    }
}

if ($errors.Count) {
    throw ($errors -join [Environment]::NewLine)
}

[pscustomobject]@{
    complete = $true
    run_id = $plan.run_id
    required_nodes = @($plan.completion.required_nodes).Count
    artifact_checks = @($plan.completion.artifact_checks).Count
    evidence_checks = @($plan.completion.evidence_checks).Count
    review_disposition_checks = $reviewDispositionChecks.Count
    review_sources = $reviewSourceCount
    review_decisions = $reviewDecisionCount
    canonical_review_findings = $canonicalReviewFindings.Count
    active_review_milestone = if ($null -ne $durableMilestoneChain) {
        [string]$durableMilestoneChain.active_milestone_id
    } else { '' }
    model_verification = [ordered]@{
        all_actual_models_verified = ($unverifiedActualModels.Count -eq 0)
        unverified_node_ids = $unverifiedActualModels
    }
    journal_head = $state.journal_head
} | ConvertTo-Json -Depth 10
