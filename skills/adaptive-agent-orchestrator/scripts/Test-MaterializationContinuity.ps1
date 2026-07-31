[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$script:assertionCount = 0
$threadId = '019fb64b-c879-7620-8b4f-9362931050bd'
$sourceThreadId = '019fa424-2243-7572-820c-a12129b97977'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'orchestrator-materialization-' + [guid]::NewGuid().ToString('N')
)

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertionCount++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-FileSha {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Add-FixtureEvent {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $EventName,
        [string] $NodeId,
        [string] $RoleId,
        [string] $ThreadId
    )

    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    $events = @(Read-OrchestrationJournal $eventsPath)
    $event = [ordered]@{}
    foreach ($property in $events[-1].PSObject.Properties) {
        $event[$property.Name] = $property.Value
    }
    $event.sequence = $events.Count
    $event.prev_hash = [string]$events[-1].hash
    $event.timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $event.event = $EventName
    $event.node_id = if ($NodeId) { $NodeId } else { $null }
    $event.role_id = if ($RoleId) { $RoleId } else { $null }
    $event.prior_state = $null
    $event.status = 'planned'
    $event.message = 'Historical fixture lineage.'
    $event.thread_id = if ($ThreadId) { $ThreadId } else { $null }
    $event.model_id = $null
    $event.artifact = $null
    $event.topology = $null
    $event.capability = $null
    $event.effort = $null
    $event.wave = 0
    $event.attempt = 0
    $event.execution_slot_delta = 0
    $event.error_class = $null
    $event.input_tokens_delta = 0
    $event.output_tokens_delta = 0
    $event.coordination_tokens_delta = 0
    $event.usage_source = 'none'
    $event.decision = $null
    $event.human_actor = $null
    $event.evidence = @()
    $event.recovery_receipt_path = $null
    $event.recovery_receipt_hash = $null
    $event.replacement_receipt_path = $null
    $event.replacement_receipt_hash = $null
    $event.result_receipt_path = $null
    $event.result_receipt_hash = $null
    $event.idempotency_key = "fixture:$EventName"
    $event.request_fingerprint = Get-TextSha256 $event.idempotency_key
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    Add-Content -LiteralPath $eventsPath -Value (
        $event | ConvertTo-Json -Compress -Depth 20
    )
}

function Add-LegacyMaterializingEvent {
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [string] $RoleId = 'architecture-owner',
        [int] $Attempt = 1
    )

    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    $events = @(Read-OrchestrationJournal $eventsPath)
    $launch = $events[-1]
    $event = [ordered]@{}
    foreach ($property in $launch.PSObject.Properties) {
        $event[$property.Name] = $property.Value
    }
    $event.sequence = $events.Count
    $event.prev_hash = [string]$launch.hash
    $event.timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $event.prior_state = 'launch_reserved'
    $event.status = 'materializing'
    $event.message = (
        'Adopt the one reconciled platform entity returned by the successful ' +
        'create call; no retry or duplicate creation is permitted.'
    )
    $event.thread_id = $threadId
    $event.role_id = $RoleId
    $event.attempt = $Attempt
    $event.execution_slot_delta = 0
    $event.evidence = @(
        "observation:create-thread-returned-id:$threadId",
        'observation:list-threads-single-match',
        'observation:handshake-turn-completed'
    )
    $event.idempotency_key = (
        'controller:liuyao-checkpoint14-source-rotation-traditional-seat-v1:' +
        'materializing'
    )
    $event.request_fingerprint = Get-TextSha256 (
        $event | ConvertTo-Json -Compress -Depth 20
    )
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    Add-Content -LiteralPath $eventsPath -Value (
        $event | ConvertTo-Json -Compress -Depth 20
    )
}

function New-MaterializationFixture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [switch] $LegacyMaterializing,
        [switch] $DuplicateMatch,
        [string] $HandshakeText = 'MATERIALIZED_WAITING_FOR_CONTINUITY',
        [string] $HistoricalThreadId,
        [string] $HistoricalNodeId
    )

    $runDirectory = Join-Path $testRoot $Name
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath (Join-Path $skillRoot 'references/example-plan.json') `
        -RunDirectory $runDirectory -WorkspaceRoot $testRoot | Out-Null

    Add-FixtureEvent -RunDirectory $runDirectory `
        -EventName 'fixture-source-rotation-adopted' `
        -NodeId $HistoricalNodeId `
        -RoleId $(if ($HistoricalNodeId) {
            'adversarial-reviewer'
        } else { '' }) `
        -ThreadId $HistoricalThreadId

    $materialsDirectory = Join-Path $runDirectory 'materials'
    $threadReadDirectory = Join-Path $runDirectory 'thread-reads'
    $receiptDirectory = Join-Path $runDirectory 'receipts'
    foreach ($directory in @(
        $materialsDirectory, $threadReadDirectory, $receiptDirectory
    )) {
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory
        }
    }

    $previewPath = Join-Path $materialsDirectory 'draft.role-preview.md'
    & (Join-Path $scriptRoot 'New-RoleActivationPreview.ps1') `
        -PlanPath (Join-Path $runDirectory 'plan.json') -NodeId 'draft' `
        -OutputPath $previewPath | Out-Null

    $activationKey = (
        'controller:liuyao-checkpoint14-source-rotation-traditional-seat-v1'
    )
    $taskSummary = 'Fresh Liuyao checkpoint14 traditional source review seat'
    $reservation = & (
        Join-Path $scriptRoot 'New-ThreadActivationReservation.ps1'
    ) -RunDirectory $runDirectory -ActivationKey $activationKey `
        -SourceThreadId $sourceThreadId -TaskSummary $taskSummary `
        -RolePreviewPath $previewPath | ConvertFrom-Json -Depth 20
    $reservationRelativePath = [IO.Path]::GetRelativePath(
        $runDirectory,
        [string]$reservation.reservation_path
    ).Replace('\', '/')

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'Reserved unique fresh task.' `
        -Evidence "artifact:$reservationRelativePath" `
        -IdempotencyKey "$activationKey`:launch-reserved" | Out-Null

    if ($LegacyMaterializing) {
        Add-LegacyMaterializingEvent -RunDirectory $runDirectory
    }

    $windowStart = [DateTimeOffset]::Parse('2026-07-31T03:52:00Z')
    $windowEnd = $windowStart.AddMinutes(2)
    $matchingThread = [ordered]@{
        id = $threadId
        host_id = 'local-test-host'
        source_thread_id = $sourceThreadId
        activation_key = $activationKey
        task_summary = $taskSummary
        created_at = $windowStart.AddSeconds(12).ToString('o')
    }
    $threads = @($matchingThread)
    if ($DuplicateMatch) {
        $threads += [ordered]@{
            id = '019fb64b-c879-7620-8b4f-duplicate000'
            host_id = 'local-test-host'
            source_thread_id = $sourceThreadId
            activation_key = $activationKey
            task_summary = $taskSummary
            created_at = $windowStart.AddSeconds(13).ToString('o')
        }
    }
    $reconciliationInputPath = Join-Path (
        $materialsDirectory
    ) 'draft.thread-reconciliation-input.json'
    [ordered]@{
        activation_key = $activationKey
        source_thread_id = $sourceThreadId
        task_summary = $taskSummary
        window_start_utc = $windowStart.ToString('o')
        window_end_utc = $windowEnd.ToString('o')
        reservation_path = [string]$reservation.reservation_path
        create_call = [ordered]@{
            status = 'success'
            returned_thread_id = $threadId
        }
        snapshots = @(
            [ordered]@{
                captured_at = $windowStart.AddSeconds(20).ToString('o')
                threads = $threads
            }
        )
    } | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $reconciliationInputPath -Encoding utf8

    $reconciliationPath = Join-Path (
        $receiptDirectory
    ) 'draft.thread-reconciliation.json'
    & (Join-Path $scriptRoot 'Resolve-ThreadReconciliation.ps1') `
        -InputPath $reconciliationInputPath -OutputPath $reconciliationPath |
        Out-Null

    $handshakePath = Join-Path (
        $threadReadDirectory
    ) 'draft.materialization-handshake.raw.json'
    [ordered]@{
        thread = [ordered]@{ id = $threadId }
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = '019fb64b-c879-7620-handshake-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = $HandshakeText
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $handshakePath -Encoding utf8

    return [pscustomobject]@{
        run_directory = $runDirectory
        events_path = Join-Path $runDirectory 'events.jsonl'
        activation_key = $activationKey
        reconciliation_path = [IO.Path]::GetRelativePath(
            $runDirectory,
            $reconciliationPath
        ).Replace('\', '/')
        handshake_path = [IO.Path]::GetRelativePath(
            $runDirectory,
            $handshakePath
        ).Replace('\', '/')
    }
}

function Invoke-Materializing {
    param(
        [Parameter(Mandatory)] $Fixture,
        [string] $ThreadId = $script:threadId,
        [switch] $OmitReconciliation,
        [switch] $OmitHandshake
    )
    $arguments = @{
        RunDirectory = $Fixture.run_directory
        NodeId = 'draft'
        Status = 'materializing'
        Message = 'Adopt exactly one reconciled fresh task.'
        ThreadId = $ThreadId
        IdempotencyKey = "$($Fixture.activation_key):materializing"
    }
    if (-not $OmitReconciliation) {
        $arguments.MaterializationReconciliationReceiptPath =
            $Fixture.reconciliation_path
    }
    if (-not $OmitHandshake) {
        $arguments.MaterializationHandshakeCapturePath =
            $Fixture.handshake_path
    }
    return & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
        ConvertFrom-Json -Depth 30
}

function Invoke-Materialized {
    param(
        [Parameter(Mandatory)] $Fixture,
        [string] $ThreadId = $script:threadId,
        [switch] $OmitReconciliation,
        [switch] $OmitHandshake,
        [string] $IdempotencySuffix = 'materialized'
    )
    $arguments = @{
        RunDirectory = $Fixture.run_directory
        NodeId = 'draft'
        Status = 'materialized'
        Message = 'Materialized the uniquely reconciled existing task.'
        ThreadId = $ThreadId
        ModelVerificationState = 'unverified'
        ModelVerificationEvidence = 'observation:platform-model-not-exposed'
        IdempotencyKey = (
            "$($Fixture.activation_key):$IdempotencySuffix"
        )
    }
    if (-not $OmitReconciliation) {
        $arguments.MaterializationReconciliationReceiptPath =
            $Fixture.reconciliation_path
    }
    if (-not $OmitHandshake) {
        $arguments.MaterializationHandshakeCapturePath =
            $Fixture.handshake_path
    }
    return & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') @arguments |
        ConvertFrom-Json -Depth 30
}

function Assert-RejectedWithoutJournalWrite {
    param(
        [Parameter(Mandatory)] $Fixture,
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $ExpectedMessage,
        [Parameter(Mandatory)][string] $Message
    )
    $beforeHash = Get-FileSha $Fixture.events_path
    $beforeCount = @(Get-Content -LiteralPath $Fixture.events_path).Count
    $caught = $false
    try {
        & $Action | Out-Null
    } catch {
        $caught = $_.Exception.Message -like "*$ExpectedMessage*"
    }
    Assert-True $caught $Message
    Assert-True ((Get-FileSha $Fixture.events_path) -eq $beforeHash) (
        "$Message Journal bytes must remain unchanged."
    )
    Assert-True (
        @(Get-Content -LiteralPath $Fixture.events_path).Count -eq $beforeCount
    ) "$Message Journal length must remain unchanged."
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot

    $legacy = New-MaterializationFixture -Name 'real-four-event' `
        -LegacyMaterializing
    Assert-True (
        @(Get-Content -LiteralPath $legacy.events_path).Count -eq 4
    ) 'The regression fixture must preserve the real four-event shape.'
    $legacyMaterialized = Invoke-Materialized -Fixture $legacy
    Assert-True (
        $legacyMaterialized.status -eq 'materialized' -and
        $legacyMaterialized.thread_id -eq $threadId -and
        $legacyMaterialized.prior_state -eq 'materializing'
    ) 'The unique existing traditional task must materialize without recreation.'
    Assert-True (
        $legacyMaterialized.materialization_prior_event_sequence -eq 3
    ) 'The recovered materialization must bind the adjacent materializing event.'

    $future = New-MaterializationFixture -Name 'future-first-binding'
    $futureMaterializing = Invoke-Materializing -Fixture $future
    Assert-True (
        $futureMaterializing.status -eq 'materializing' -and
        $futureMaterializing.thread_id -eq $threadId
    ) 'A new materializing event may first bind one uniquely reconciled task.'
    $futureMaterialized = Invoke-Materialized -Fixture $future
    Assert-True (
        $futureMaterialized.status -eq 'materialized' -and
        $futureMaterialized.thread_id -eq $threadId
    ) 'The immediately adjacent materialized event may keep the same bound task.'

    $missingReconciliation = New-MaterializationFixture `
        -Name 'missing-reconciliation' -LegacyMaterializing
    Assert-RejectedWithoutJournalWrite -Fixture $missingReconciliation `
        -ExpectedMessage 'requires reconciliation and handshake captures' `
        -Message 'Same-ID recovery without reconciliation must fail closed.' `
        -Action {
            Invoke-Materialized -Fixture $missingReconciliation `
                -OmitReconciliation
        }

    $missingHandshake = New-MaterializationFixture `
        -Name 'missing-handshake' -LegacyMaterializing
    Assert-RejectedWithoutJournalWrite -Fixture $missingHandshake `
        -ExpectedMessage 'requires reconciliation and handshake captures' `
        -Message 'Same-ID recovery without the handshake must fail closed.' `
        -Action {
            Invoke-Materialized -Fixture $missingHandshake -OmitHandshake
        }

    $wrongHandshake = New-MaterializationFixture `
        -Name 'wrong-handshake' -LegacyMaterializing `
        -HandshakeText 'READY_WITH_EXTRA_TEXT'
    Assert-RejectedWithoutJournalWrite -Fixture $wrongHandshake `
        -ExpectedMessage 'exact waiting marker' `
        -Message 'A changed handshake answer must fail closed.' `
        -Action { Invoke-Materialized -Fixture $wrongHandshake }

    $duplicate = New-MaterializationFixture -Name 'duplicate-reconciliation' `
        -LegacyMaterializing -DuplicateMatch
    Assert-RejectedWithoutJournalWrite -Fixture $duplicate `
        -ExpectedMessage "decision is not 'adopted'" `
        -Message 'Multiple matching tasks must not be materialized.' `
        -Action { Invoke-Materialized -Fixture $duplicate }

    $differentId = New-MaterializationFixture -Name 'different-id' `
        -LegacyMaterializing
    Assert-RejectedWithoutJournalWrite -Fixture $differentId `
        -ExpectedMessage 'must keep the exact thread' `
        -Message 'Materialized cannot replace the adjacent materializing ID.' `
        -Action {
            Invoke-Materialized -Fixture $differentId `
                -ThreadId '019fb64b-c879-7620-8b4f-other000'
        }

    $nonAdjacent = New-MaterializationFixture -Name 'non-adjacent' `
        -LegacyMaterializing
    Add-FixtureEvent -RunDirectory $nonAdjacent.run_directory `
        -EventName 'fixture-interleaving-event'
    Assert-RejectedWithoutJournalWrite -Fixture $nonAdjacent `
        -ExpectedMessage 'immediately adjacent' `
        -Message 'An interleaving event must block same-ID materialization.' `
        -Action { Invoke-Materialized -Fixture $nonAdjacent }

    $wrongRole = New-MaterializationFixture -Name 'wrong-role' `
        -LegacyMaterializing
    $wrongRoleEvents = @(Read-OrchestrationJournal $wrongRole.events_path)
    $wrongRoleTail = $wrongRoleEvents[-1]
    $wrongRoleTail.role_id = 'adversarial-reviewer'
    $wrongRoleTail.hash = Get-OrchestrationEventHash $wrongRoleTail
    $wrongRoleLines = @(
        $wrongRoleEvents | ForEach-Object {
            $_ | ConvertTo-Json -Compress -Depth 30
        }
    )
    Set-Content -LiteralPath $wrongRole.events_path -Value $wrongRoleLines `
        -Encoding utf8
    Assert-RejectedWithoutJournalWrite -Fixture $wrongRole `
        -ExpectedMessage 'same node, role, and attempt' `
        -Message 'A role-changed materializing event must fail closed.' `
        -Action { Invoke-Materialized -Fixture $wrongRole }

    $wrongAttempt = New-MaterializationFixture -Name 'wrong-attempt' `
        -LegacyMaterializing
    $wrongAttemptEvents = @(Read-OrchestrationJournal $wrongAttempt.events_path)
    $wrongAttemptTail = $wrongAttemptEvents[-1]
    $wrongAttemptTail.attempt = 2
    $wrongAttemptTail.hash = Get-OrchestrationEventHash $wrongAttemptTail
    $wrongAttemptLines = @(
        $wrongAttemptEvents | ForEach-Object {
            $_ | ConvertTo-Json -Compress -Depth 30
        }
    )
    Set-Content -LiteralPath $wrongAttempt.events_path `
        -Value $wrongAttemptLines -Encoding utf8
    Assert-RejectedWithoutJournalWrite -Fixture $wrongAttempt `
        -ExpectedMessage 'same node, role, and attempt' `
        -Message 'An attempt-changed materializing event must fail closed.' `
        -Action { Invoke-Materialized -Fixture $wrongAttempt }

    $historicalSameNode = New-MaterializationFixture `
        -Name 'historical-same-node-thread' `
        -HistoricalThreadId $threadId -HistoricalNodeId 'draft'
    Assert-RejectedWithoutJournalWrite -Fixture $historicalSameNode `
        -ExpectedMessage 'was already present in journal history' `
        -Message 'Materializing must reject an old same-node task ID.' `
        -Action { Invoke-Materializing -Fixture $historicalSameNode }

    $historicalOtherNode = New-MaterializationFixture `
        -Name 'historical-other-node-thread' `
        -HistoricalThreadId $threadId -HistoricalNodeId 'review'
    Assert-RejectedWithoutJournalWrite -Fixture $historicalOtherNode `
        -ExpectedMessage 'was already present in journal history' `
        -Message 'Materializing must reject another node task ID.' `
        -Action { Invoke-Materializing -Fixture $historicalOtherNode }

    $repeat = New-MaterializationFixture -Name 'repeat' `
        -LegacyMaterializing
    Invoke-Materialized -Fixture $repeat | Out-Null
    Assert-RejectedWithoutJournalWrite -Fixture $repeat `
        -ExpectedMessage 'Materialization evidence is only valid' `
        -Message 'A completed materialization cannot be repeated.' `
        -Action {
            Invoke-Materialized -Fixture $repeat `
                -IdempotencySuffix 'second-materialized'
        }

    [ordered]@{
        pass = $true
        assertions = $script:assertionCount
        real_thread_id = $threadId
        real_four_event_regression = $true
        future_first_binding = $true
        same_id_adjacent_recovery = $true
        negative_cases = 11
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
