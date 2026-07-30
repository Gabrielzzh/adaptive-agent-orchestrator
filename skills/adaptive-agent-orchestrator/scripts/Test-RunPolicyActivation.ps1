[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aao-policy-activation-' + [guid]::NewGuid().ToString('N')
)
$script:assertions = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertions++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Action,
        [string] $Expected,
        [string] $Message
    )
    $caught = $false
    try { & $Action } catch {
        $caught = $_.Exception.Message -like "*$Expected*"
    }
    Assert-True $caught $Message
}

function New-LegacyRunFixture {
    param([string] $Path, [string] $RunId)
    $null = New-Item -ItemType Directory -Path $Path
    foreach ($directory in @('inputs', 'materials', 'receipts')) {
        $null = New-Item -ItemType Directory -Path (
            Join-Path $Path $directory
        )
    }
    $plan = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/example-plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $plan.policy_version = '0.7.2'
    $plan.run_id = $RunId
    $planPath = Join-Path $Path 'plan.json'
    $plan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $planPath -Encoding utf8
    $planRaw = Get-Content -LiteralPath $planPath -Raw
    $planObject = $planRaw | ConvertFrom-Json -Depth 100
    $planHash = Get-TextSha256 $planRaw
    $run = [ordered]@{
        run_id = $RunId
        policy_version = '0.7.2'
        plan_hash = $planHash
        workspace_root = $testRoot
    }
    $run | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $Path 'run.json') -Encoding utf8
    $created = [ordered]@{
        sequence = 0
        prev_hash = $null
        timestamp = '2026-07-30T00:00:00.0000000+00:00'
        event = 'run-created'
        run_id = $RunId
        plan_hash = $planHash
        workspace_root = $testRoot
        policy_version = '0.7.2'
        actor = [string]$planObject.orchestrator.id
        node_id = $null
        role_id = $null
        prior_state = $null
        status = 'planned'
        message = 'Validated orchestration run created.'
        thread_id = $null
        model_id = $null
        artifact = $null
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
        error_class = $null
        evidence = @()
        idempotency_key = "$RunId`:run-created"
        request_fingerprint = $null
    }
    $created.hash = Get-OrchestrationEventHash ([pscustomobject]$created)
    $created | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $Path 'events.jsonl') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'inputs/source.json') `
        -Value '{"source_node_id":"draft","role_id":"implementation-owner"}'
    Set-Content -LiteralPath (Join-Path $Path 'inputs/thread.json') `
        -Value '{"original_thread_id":"legacy-thread-1"}'
    Set-Content -LiteralPath (Join-Path $Path 'inputs/input.json') `
        -Value '{"input_hash":"fixture-input"}'
    Set-Content -LiteralPath (Join-Path $Path 'materials/checkpoint.json') `
        -Value '{"checkpoint_hash":"fixture-checkpoint"}'
    Set-Content -LiteralPath (
        Join-Path $Path 'materials/policy-migration-authorization.md'
    ) -Value 'Controller authorizes this exact immutable run to use policy 0.7.6.'
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $run = Join-Path $testRoot 'legacy-run'
    New-LegacyRunFixture -Path $run -RunId 'legacy-policy-fixture'
    $planPath = Join-Path $run 'plan.json'
    $workspace = $testRoot

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $planPath -WorkspaceRoot $workspace | Out-Null
    } 'older immutable run requires' (
        'An old plan must not be accepted as a new plan.'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $planPath -WorkspaceRoot $workspace `
            -ExistingRunDirectory $run | Out-Null
    } 'no verified run-policy activation receipt' (
        'An old run without activation must fail closed.'
    )

    $receipt = & (
        Join-Path $scriptRoot 'New-RunPolicyActivationReceipt.ps1'
    ) -RunDirectory $run -AuthorizationMaterialPath (
        Join-Path $run 'materials/policy-migration-authorization.md'
    ) -ActivationKey 'controller:self-test-policy-activation' |
        ConvertFrom-Json -Depth 100
    Assert-True (
        $receipt.source_policy_version -eq '0.7.2' -and
        $receipt.target_policy_version -eq '0.7.6' -and
        @($receipt.artifact_bindings).Count -eq 5
    ) 'Activation must bind the exact predecessor artifacts and transition.'
    $validation = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $planPath -WorkspaceRoot $workspace `
        -ExistingRunDirectory $run | ConvertFrom-Json
    Assert-True (
        $validation.valid -and
        $validation.policy_version -eq '0.7.2' -and
        $validation.effective_policy_version -eq '0.7.6'
    ) 'Activated old runs must expose source and effective policy separately.'

    $event = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $run -NodeId 'draft' -Status launch_reserved `
        -Message 'reserve migrated source' `
        -IdempotencyKey 'policy-activation-draft-reserved' |
        ConvertFrom-Json -Depth 30
    Assert-True (
        $event.policy_version -eq '0.7.2' -and
        $event.runtime_policy_version -eq '0.7.6' -and
        $event.policy_activation_receipt_hash -eq $receipt.receipt_hash
    ) 'Post-activation events must preserve old identity and bind new runtime.'
    $state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $run | ConvertFrom-Json -Depth 100
    Assert-True (
        $state.policy_version -eq '0.7.2' -and
        $state.effective_policy_version -eq '0.7.6'
    ) 'State must report source and effective policy honestly.'

    foreach ($mutation in @(
        @{ name = 'source'; path = 'inputs/source.json' },
        @{ name = 'thread'; path = 'inputs/thread.json' },
        @{ name = 'input'; path = 'inputs/input.json' },
        @{ name = 'checkpoint'; path = 'materials/checkpoint.json' }
    )) {
        $copy = Join-Path $testRoot ('mutated-' + $mutation.name)
        Copy-Item -LiteralPath $run -Destination $copy -Recurse
        Set-Content -LiteralPath (Join-Path $copy $mutation.path) `
            -Value ('{"mutated":"' + $mutation.name + '"}')
        Assert-ThrowsLike {
            & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
                -RunDirectory $copy | Out-Null
        } 'activation artifact changed' (
            "Activation must reject a changed $($mutation.name) binding."
        )
    }

    $changedPlanRun = Join-Path $testRoot 'changed-plan'
    Copy-Item -LiteralPath $run -Destination $changedPlanRun -Recurse
    $changedPlan = Get-Content -LiteralPath (
        Join-Path $changedPlanRun 'plan.json'
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $changedPlan.goal = 'tampered predecessor plan'
    $changedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath (
            Join-Path $changedPlanRun 'plan.json'
        )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $changedPlanRun | Out-Null
    } 'plan.json or run metadata changed' (
        'Activation must reject an edited predecessor plan.'
    )

    $changedJournalRun = Join-Path $testRoot 'changed-journal'
    Copy-Item -LiteralPath $run -Destination $changedJournalRun -Recurse
    $journal = Get-Content -LiteralPath (
        Join-Path $changedJournalRun 'events.jsonl'
    ) | ForEach-Object {
        $_ | ConvertFrom-Json -AsHashtable -Depth 30
    }
    $journal[0].message = 'tampered predecessor journal'
    $journal | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 30 } |
        Set-Content -LiteralPath (
            Join-Path $changedJournalRun 'events.jsonl'
        )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $changedJournalRun | Out-Null
    } 'Journal event hash mismatch' (
        'Activation must reject an edited predecessor journal.'
    )

    $reusedRun = Join-Path $testRoot 'receipt-reuse'
    New-LegacyRunFixture -Path $reusedRun -RunId 'different-run'
    Copy-Item -LiteralPath (
        Join-Path $run 'receipts/run-policy-activation.0.7.6.json'
    ) -Destination (
        Join-Path $reusedRun 'receipts/run-policy-activation.0.7.6.json'
    )
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $reusedRun | Out-Null
    } 'does not match the immutable run' (
        'An activation receipt cannot be reused for another run.'
    )

    $skipRun = Join-Path $testRoot 'unsupported-skip'
    Copy-Item -LiteralPath $run -Destination $skipRun -Recurse
    $skipReceiptPath = Join-Path $skipRun (
        'receipts/run-policy-activation.0.7.6.json'
    )
    $skipReceipt = Get-Content -LiteralPath $skipReceiptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $skipReceipt.target_policy_version = '0.7.5'
    $skipPayload = [ordered]@{}
    foreach ($key in $skipReceipt.Keys | Where-Object {
        $_ -ne 'receipt_hash'
    }) {
        $skipPayload[$key] = $skipReceipt[$key]
    }
    $skipReceipt.receipt_hash = Get-TextSha256 (
        $skipPayload | ConvertTo-Json -Compress -Depth 100
    )
    $skipReceipt | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $skipReceiptPath
    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $skipRun | Out-Null
    } 'unsupported policy transition' (
        'Activation must reject downgrade or unsupported target skips.'
    )

    Assert-ThrowsLike {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $run | Out-Null
    } 'Required node' (
        'Activation alone cannot satisfy source dispositions or completion.'
    )

    [pscustomobject]@{
        pass = $true
        assertions = $script:assertions
        source_policy = '0.7.2'
        effective_policy = '0.7.6'
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
