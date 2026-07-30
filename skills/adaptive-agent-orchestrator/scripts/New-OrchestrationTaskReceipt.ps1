[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)]
    [ValidateSet('completed', 'fallback-main', 'blocked', 'cancelled')]
    [string] $Outcome,
    [Parameter(Mandatory)][string] $Summary,
    [Parameter(Mandatory)][string] $OutputPath,
    [ValidateSet(
        'none', 'creation-failed', 'model-unavailable',
        'worktree-preflight-failed', 'write-conflict', 'timeout-no-result',
        'independent-review-failed', 'other'
    )]
    [string] $FailureClass = 'none',
    [string] $FallbackAction,
    [string[]] $Evidence = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

if ([string]::IsNullOrWhiteSpace($Summary)) {
    throw 'Summary must be non-empty.'
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}
if ([IO.Path]::GetFileName($OutputPath) -notlike
    '*.task-completion-receipt.json') {
    throw 'OutputPath must end with .task-completion-receipt.json.'
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Task completion receipt already exists: $OutputPath"
}
$existingReceipts = @(
    Get-ChildItem -LiteralPath $RunDirectory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object Name -Like '*.task-completion-receipt.json'
)
if ($existingReceipts.Count -gt 0) {
    throw 'A task-level outcome receipt already exists for this run.'
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $outputFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Task completion receipt must remain inside the run.'
}

if ($Outcome -eq 'completed') {
    if ($FailureClass -ne 'none' -or $FallbackAction) {
        throw 'A completed task cannot declare a failure or fallback action.'
    }
    $completion = & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
        -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 20
} else {
    if ($FailureClass -eq 'none' -or
        [string]::IsNullOrWhiteSpace($FallbackAction)) {
        throw 'A non-completed task requires a failure class and fallback action.'
    }
    if (@($Evidence | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }).Count -eq 0) {
        throw 'A non-completed task requires at least one evidence entry.'
    }
    $completion = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 100
}

$run = Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw |
    ConvertFrom-Json -Depth 20 -DateKind String
$journalHead = [string]$completion.journal_head
$cleanEvidence = @($Evidence | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$receipt = [ordered]@{
    schema_version = '1.1'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    journal_head = $journalHead
    outcome = $Outcome
    completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    summary = $Summary.Trim()
    failure_class = $FailureClass
    fallback_action = if ($FallbackAction) { $FallbackAction.Trim() } else { $null }
    evidence = $cleanEvidence
    model_verification = if ($null -ne $completion.PSObject.Properties[
        'model_verification'
    ]) {
        $completion.model_verification
    } else {
        $unverifiedNodeIds = @(
            $completion.nodes | Where-Object {
                $_.kind -eq 'agent' -and
                $_.actual_model_verification -eq 'unverified'
            } | Select-Object -ExpandProperty id
        )
        [ordered]@{
            all_actual_models_verified = ($unverifiedNodeIds.Count -eq 0)
            unverified_node_ids = $unverifiedNodeIds
        }
    }
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
