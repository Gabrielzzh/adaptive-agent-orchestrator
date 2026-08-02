[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationReceiptPath,
    [Parameter(Mandatory)][string] $SelectionMaterialPath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $CorrectionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
if ($CorrectionKey -cnotmatch
    '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Milestone revision lifecycle correction requires a stable authority key.'
}
foreach ($candidate in @(
    $AuthorizationReceiptPath,
    $SelectionMaterialPath,
    $AuthorizationMaterialPath
)) {
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw (
            'Milestone revision lifecycle correction inputs must be files ' +
            'inside the run.'
        )
    }
}
if ([string]::IsNullOrWhiteSpace(
    (Get-Content -LiteralPath $AuthorizationMaterialPath -Raw)
)) {
    throw 'Milestone revision lifecycle correction authorization is empty.'
}

$authorization = Read-DurableReviewMilestoneRevisionAuthorization `
    -Path $AuthorizationReceiptPath -RunDirectory $runRoot
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$eventsPath = Join-Path $runRoot 'events.jsonl'
$events = @(Read-OrchestrationJournal $eventsPath)
$authorizationEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-authorized' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$selectionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-selected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$correctionEvents = @($events | Where-Object {
    [string]$_.event -eq
        'milestone-revision-lifecycle-evidence-corrected' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$supersessionEvents = @($events | Where-Object {
    [string]$_.event -eq 'milestone-revision-inventory-superseded' -and
    [string]$_.milestone_revision_id -eq [string]$authorization.revision_id
})
$supersessionReceiptPath = Join-Path (Join-Path $runRoot 'receipts') (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).inventory-supersession.json"
)
if ($authorizationEvents.Count -ne 1 -or $selectionEvents.Count -ne 0 -or
    $correctionEvents.Count -ne 0 -or $supersessionEvents.Count -ne 0 -or
    (Test-Path -LiteralPath $supersessionReceiptPath -PathType Leaf)) {
    throw (
        'Milestone revision lifecycle correction requires one pending, ' +
        'uncorrected authorization.'
    )
}
$selectionItems = @(
    Get-Content -LiteralPath $SelectionMaterialPath -Raw |
        ConvertFrom-Json -Depth 100 -DateKind String
)
$sourceCorrections =
    Get-MilestoneRevisionLifecycleCorrectionSources `
        -RunDirectory $runRoot -Plan $plan -Authorization $authorization `
        -Events $events -SelectionItems $selectionItems

$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptName = (
    "durable-review-milestone.$($authorization.milestone_id)." +
    "revision-$($authorization.revision_id).lifecycle-correction.json"
)
$receiptPath = Join-Path $receiptDirectory $receiptName
if (Test-Path -LiteralPath $receiptPath) {
    throw 'Milestone revision lifecycle correction receipt already exists.'
}
$relative = {
    param([string] $Path)
    [IO.Path]::GetRelativePath($runRoot, $Path).Replace('\', '/')
}
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    genesis_hash = [string]$events[0].hash
    milestone_id = [string]$authorization.milestone_id
    milestone_index = 0
    revision_id = [string]$authorization.revision_id
    revision_index = [int]$authorization.revision_index
    authorization_receipt_path = & $relative $AuthorizationReceiptPath
    authorization_receipt_hash = [string]$authorization.receipt_hash
    selection_key = [string]$authorization.selection_key
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    checkpoint_material_path = [string]$authorization.checkpoint_material_path
    checkpoint_material_hash = [string]$authorization.checkpoint_material_hash
    input_manifest_path = [string]$authorization.input_manifest_path
    input_manifest_hash = [string]$authorization.input_manifest_hash
    selection_material_path = & $relative $SelectionMaterialPath
    selection_material_hash = (
        Get-FileHash -LiteralPath $SelectionMaterialPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    source_corrections = @($sourceCorrections)
    source_corrections_hash = Get-TextSha256 (
        ConvertTo-Json -InputObject @($sourceCorrections) -Compress -Depth 100
    )
    authorization_material_path = & $relative $AuthorizationMaterialPath
    authorization_material_hash = (
        Get-FileHash -LiteralPath $AuthorizationMaterialPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    correction_key = $CorrectionKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
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
        throw 'The journal changed while lifecycle correction was prepared.'
    }
    Move-Item -LiteralPath $temp -Destination $receiptPath
    $event = New-MilestoneRevisionJournalEvent -Plan $plan -Run $run `
        -Events $current -RunDirectory $runRoot `
        -EventName 'milestone-revision-lifecycle-evidence-corrected' `
        -ReceiptName $receiptName -Receipt $receipt `
        -Message (
            "Corrected lifecycle evidence binding for revision " +
            "'$($authorization.revision_id)'."
        ) -IdempotencyKey $CorrectionKey
    try {
        Add-Content -LiteralPath $eventsPath -Value (
            $event | ConvertTo-Json -Compress -Depth 100
        )
    } catch {
        Remove-Item -LiteralPath $receiptPath -Force
        throw
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
$verified = Read-DurableReviewMilestoneRevisionLifecycleCorrection `
    -Path $receiptPath -RunDirectory $runRoot
$verified | ConvertTo-Json -Depth 100
