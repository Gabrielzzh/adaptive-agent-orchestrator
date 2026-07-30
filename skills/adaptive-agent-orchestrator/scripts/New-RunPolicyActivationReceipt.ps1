[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$planPath = Join-Path $runRoot 'plan.json'
$runPath = Join-Path $runRoot 'run.json'
$eventsPath = Join-Path $runRoot 'events.jsonl'
foreach ($path in @($planPath, $runPath, $eventsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Run-policy activation requires an existing immutable run.'
    }
}
$planRaw = Get-Content -LiteralPath $planPath -Raw
$plan = $planRaw | ConvertFrom-Json -Depth 100 -DateKind String
$run = Get-Content -LiteralPath $runPath -Raw |
    ConvertFrom-Json -Depth 30 -DateKind String
$events = @(Read-OrchestrationJournal $eventsPath)
if ($events.Count -lt 1 -or
    (Get-TextSha256 $planRaw) -ne [string]$run.plan_hash -or
    [string]$events[0].plan_hash -ne [string]$run.plan_hash -or
    [string]$run.run_id -ne [string]$plan.run_id -or
    [string]$events[0].run_id -ne [string]$run.run_id -or
    [string]$run.policy_version -ne [string]$plan.policy_version -or
    [string]$events[0].policy_version -ne [string]$run.policy_version -or
    [string]$events[0].workspace_root -ne [string]$run.workspace_root) {
    throw 'Immutable predecessor plan, run metadata, or journal is inconsistent.'
}
if ([string]$plan.policy_version -notin
    $script:OrchestrationMigratablePolicyVersions) {
    throw (
        "Policy '$($plan.policy_version)' cannot be activated as " +
        "'$script:OrchestrationCurrentPolicyVersion'."
    )
}
if ($ActivationKey -notmatch '^(user|controller):[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$') {
    throw 'Run-policy activation requires a stable user: or controller: activation key.'
}

$authorization = [IO.Path]::GetFullPath($AuthorizationMaterialPath)
if (-not $authorization.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $authorization -PathType Leaf) -or
    [string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $authorization -Raw)
    )) {
    throw 'Authorization material must be a non-empty file inside the run.'
}
$receiptDirectory = Join-Path $runRoot 'receipts'
$receiptFileName = (
    'run-policy-activation.' +
    $script:OrchestrationCurrentPolicyVersion + '.json'
)
$receiptPath = Join-Path $receiptDirectory $receiptFileName
if (Test-Path -LiteralPath $receiptPath) {
    throw "Run-policy activation receipt already exists: $receiptPath"
}

$excludedNames = @('plan.json', 'run.json', 'events.jsonl', 'state.json')
$bindings = [Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $runRoot -Recurse -File |
    Sort-Object -Property FullName)) {
    $relative = [IO.Path]::GetRelativePath($runRoot, $file.FullName).
        Replace('\', '/')
    if ($relative -eq ('receipts/' + $receiptFileName) -or
        $relative -in $excludedNames) {
        continue
    }
    $bindings.Add([ordered]@{
        path = $relative
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).
            Hash.ToLowerInvariant()
    })
}
$authorizationRelative = [IO.Path]::GetRelativePath(
    $runRoot, $authorization
).Replace('\', '/')
$authorizationBinding = @($bindings | Where-Object {
    [string]$_.path -eq $authorizationRelative
}) | Select-Object -First 1
if ($null -eq $authorizationBinding) {
    throw 'Authorization material was not captured in the activation manifest.'
}
$sourceObligations = Get-RunPolicySourceObligations `
    -RunDirectory $runRoot -Plan $plan
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    plan_hash = [string]$run.plan_hash
    workspace_root = [string]$run.workspace_root
    source_policy_version = [string]$plan.policy_version
    target_policy_version = $script:OrchestrationCurrentPolicyVersion
    source_journal_head = [string]$events[-1].hash
    source_journal_event_count = $events.Count
    source_obligations = @($sourceObligations)
    source_obligations_hash = Get-TextSha256 (
        @($sourceObligations) | ConvertTo-Json -Compress -Depth 30
    )
    artifact_bindings = @($bindings)
    artifact_bindings_hash = Get-TextSha256 (
        @($bindings) | ConvertTo-Json -Compress -Depth 10
    )
    authorization_material_path = $authorizationRelative
    authorization_material_hash = [string]$authorizationBinding.sha256
    activation_key = $ActivationKey
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 100
)
if (-not (Test-Path -LiteralPath $receiptDirectory)) {
    $null = New-Item -ItemType Directory -Path $receiptDirectory
}
$receipt | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $receiptPath -Encoding utf8
try {
    $verified = Read-RunPolicyActivationReceipt `
        -RunDirectory $runRoot -Events $events
} catch {
    Remove-Item -LiteralPath $receiptPath -Force
    throw
}
$verified | ConvertTo-Json -Depth 100
