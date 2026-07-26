[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [Parameter(Mandatory)]
    [string] $SkillRoot,

    [string] $OutputPath,

    [string[]] $PacketPaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only aggregation over one durable run directory. Never writes into the
# run; the only optional write is the report itself to -OutputPath.

$stateScript = Join-Path (Join-Path $SkillRoot 'scripts') (
    'Get-OrchestrationState.ps1'
)
if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
    throw "Get-OrchestrationState.ps1 not found under: $SkillRoot"
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}

$state = & $stateScript -RunDirectory $RunDirectory |
    ConvertFrom-Json -Depth 100

$eventsPath = Join-Path $RunDirectory 'events.jsonl'
$eventCount = 0
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $eventCount = @(
        Get-Content -LiteralPath $eventsPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ).Count
}

$reconciliations = @()
$resultReceipts = @()
$receiptsRoot = Join-Path $RunDirectory 'receipts'
if (Test-Path -LiteralPath $receiptsRoot -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $receiptsRoot -Recurse -File) {
        if ($file.Name -like '*.thread-reconciliation.json') {
            $doc = Get-Content -LiteralPath $file.FullName -Raw |
                ConvertFrom-Json -Depth 50
            $reconciliations += [ordered]@{
                file = $file.Name
                decision = [string]$doc.decision
                snapshot_count = [int]$doc.snapshot_count
                visibility_delay_seconds = (
                    [double]$doc.visibility_delay_seconds
                )
            }
        }
        elseif ($file.Name -like '*.thread-result-receipt.json') {
            $doc = Get-Content -LiteralPath $file.FullName -Raw |
                ConvertFrom-Json -Depth 50
            $findings = @()
            foreach ($fieldName in @('adopted_findings', 'rejected_findings')) {
                if ($null -ne $doc.PSObject.Properties[$fieldName]) {
                    $findings += @($doc.$fieldName)
                }
            }
            $inputRefs = @($findings | Where-Object {
                [string]$_ -match '^source:input-ref:.+$'
            } | ForEach-Object { ([string]$_).Substring(17) })
            $resultReceipts += [ordered]@{
                file = $file.Name
                thread_id = [string]$doc.thread_id
                finding_count = @($findings).Count
                input_refs = $inputRefs
            }
        }
    }
}

$refCounts = @{}
foreach ($receipt in $resultReceipts) {
    foreach ($ref in @($receipt.input_refs)) {
        if ($refCounts.ContainsKey($ref)) {
            $refCounts[$ref] += 1
        }
        else {
            $refCounts[$ref] = 1
        }
    }
}
$repeatedRefs = @(
    $refCounts.GetEnumerator() |
        Where-Object { $_.Value -gt 1 } |
        Sort-Object -Property Value -Descending |
        ForEach-Object {
            [ordered]@{
                reference = [string]$_.Key
                worker_count = [int]$_.Value
            }
        }
)

$packetSizes = @()
foreach ($packetPath in $PacketPaths) {
    if (Test-Path -LiteralPath $packetPath -PathType Leaf) {
        $packetSizes += [ordered]@{
            path = $packetPath
            chars = (Get-Content -LiteralPath $packetPath -Raw).Length
        }
    }
    else {
        $packetSizes += [ordered]@{
            path = $packetPath
            chars = $null
        }
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    run_directory = $RunDirectory
    run_id = [string]$state.run_id
    policy_version = [string]$state.policy_version
    journal_event_count = $eventCount
    launch_attempts = $state.launch_attempts
    materialized_workers = $state.materialized_workers
    node_states = @($state.nodes | ForEach-Object {
        [ordered]@{
            id = [string]$_.id
            status = [string]$_.status
        }
    })
    reconciliations = $reconciliations
    observed_visibility_delays_seconds = @(
        $reconciliations | ForEach-Object { $_.visibility_delay_seconds }
    )
    result_receipts = $resultReceipts
    repeated_input_refs = $repeatedRefs
    packet_sizes = $packetSizes
}

$json = $report | ConvertTo-Json -Depth 100
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    if (Test-Path -LiteralPath $OutputPath) {
        throw "Report already exists: $OutputPath"
    }
    Set-Content -LiteralPath $OutputPath -Value $json
}
$json
