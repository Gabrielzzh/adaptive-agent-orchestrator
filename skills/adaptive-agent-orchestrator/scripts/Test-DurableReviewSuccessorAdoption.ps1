[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PredecessorRunDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aao-successor-adoption-' + [guid]::NewGuid().ToString('N')
)

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $predecessorCopy = Join-Path $testRoot 'predecessor'
    Copy-Item -LiteralPath $PredecessorRunDirectory `
        -Destination $predecessorCopy -Recurse
    $policyAuthorization = Join-Path $predecessorCopy (
        'materials/successor-policy-activation.md'
    )
    Set-Content -LiteralPath $policyAuthorization -Value (
        'Controller authorizes this temporary predecessor copy for policy ' +
        "$script:OrchestrationCurrentPolicyVersion successor testing."
    )
    & (Join-Path $scriptRoot 'New-RunPolicyActivationReceipt.ps1') `
        -RunDirectory $predecessorCopy `
        -AuthorizationMaterialPath $policyAuthorization `
        -ActivationKey 'controller:successor-real-fixture-policy' | Out-Null

    $snapshot = Get-DurableReviewSuccessorSnapshot `
        -RunDirectory $predecessorCopy
    $successorPlanPath = Join-Path $testRoot 'successor-plan.json'
    $successorPlan = Get-Content -LiteralPath (
        Join-Path $predecessorCopy 'plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $successorPlan.policy_version = $script:OrchestrationCurrentPolicyVersion
    $successorPlan.run_id = (
        [string]$successorPlan.run_id + '-successor-v076-fixture'
    )
    $successorPlan.goal = (
        'Verify exact adoption of predecessor durable-review P1 obligations.'
    )
    $successorPlan.durable_review_profile.milestone_ids = @(
        'successor-group-1', 'successor-group-2'
    )
    $sourceIds = @(
        $snapshot.source_bindings |
            ForEach-Object { [string]$_.source_node_id }
    )
    foreach ($binding in @($snapshot.source_bindings)) {
        $node = @($successorPlan.nodes | Where-Object {
            [string]$_.id -eq [string]$binding.source_node_id
        })[0]
        $node.context.session_policy = 'reuse'
        $node.context.max_prior_turns = 1
        $node.context.prior_thread_id = [string]$binding.source_thread_id
        $node.context.prior_handoff = (
            'handoffs/' + [string]$binding.source_node_id + '.md'
        )
        $node.context.prior_handoff_hash = ('a' * 64)
        $node.context.reuse_reason = (
            'Continue the exact predecessor durable review source.'
        )
    }
    $successorPlan.successor_review_profile = [ordered]@{
        predecessor_run_id = [string]$snapshot.run.run_id
        predecessor_active_milestone_id =
            [string]$snapshot.active_milestone_id
        predecessor_checkpoint_material_hash =
            [string]$snapshot.checkpoint_material_hash
        source_node_ids = $sourceIds
    }
    $successorPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $successorPlanPath -Encoding utf8
    $workspaceRoot = [string]$snapshot.run.workspace_root
    $null = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
        -PlanPath $successorPlanPath -WorkspaceRoot $workspaceRoot

    $successorRun = Join-Path $testRoot 'successor'
    $successorAuthorization = Join-Path $predecessorCopy (
        'materials/successor-run-authorization.md'
    )
    Set-Content -LiteralPath $successorAuthorization -Value (
        'Controller authorizes exactly this temporary successor run.'
    )
    $export = & (Join-Path $scriptRoot (
        'New-DurableReviewSuccessorExportReceipt.ps1'
    )) -PredecessorRunDirectory $predecessorCopy `
        -SuccessorPlanPath $successorPlanPath `
        -SuccessorRunDirectory $successorRun `
        -AuthorizationMaterialPath $successorAuthorization `
        -ActivationKey 'controller:successor-real-fixture-export' |
        ConvertFrom-Json -Depth 100
    $adoption = & (Join-Path $scriptRoot (
        'New-OrchestrationSuccessorRun.ps1'
    )) -PlanPath $successorPlanPath -RunDirectory $successorRun `
        -WorkspaceRoot $workspaceRoot `
        -PredecessorRunDirectory $predecessorCopy `
        -PredecessorExportReceiptPath (
            Join-Path $predecessorCopy (
                'receipts/durable-review-successor.export.json'
            )
        ) | ConvertFrom-Json -Depth 100
    $completionError = ''
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $successorRun | Out-Null
    } catch {
        $completionError = $_.Exception.Message
    }
    $inheritedCount = @($adoption.inherited_obligations).Count
    $reportedInheritedCount = @(
        [regex]::Matches($completionError, 'Inherited P1 ')
    ).Count
    if ($inheritedCount -ne @($export.open_obligations).Count -or
        $inheritedCount -lt 1 -or
        $reportedInheritedCount -ne $inheritedCount) {
        throw (
            'Real successor adoption did not preserve and block every open P1.'
        )
    }
    [pscustomobject]@{
        pass = $true
        predecessor_run_id = [string]$export.predecessor_run_id
        predecessor_active_milestone_id =
            [string]$export.active_milestone_id
        inherited_p1_count = $inheritedCount
        source_count = @($export.source_bindings).Count
        successor_run_id = [string]$adoption.run_id
        completion_blocked = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
