[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Add', 'Summary')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $ProjectRoot,

    [string] $RunDirectory,

    [ValidateRange(5, 300)]
    [int] $MinWindowUsed = 20,

    [string] $AppVersion,
    [string] $HostKind,
    [ValidateSet('', 'local', 'remote')]
    [string] $ExecutionMode = '',
    [string] $PolicyVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path.TrimEnd('\', '/')
$orchestratorRoot = Join-Path $root '.orchestrator'
$ledgerPath = Join-Path $orchestratorRoot 'calibration.jsonl'

function Get-RequiredEnvironment {
    foreach ($pair in @(
        @{ Name = 'AppVersion'; Value = $AppVersion },
        @{ Name = 'HostKind'; Value = $HostKind },
        @{ Name = 'ExecutionMode'; Value = $ExecutionMode },
        @{ Name = 'PolicyVersion'; Value = $PolicyVersion }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$pair.Value)) {
            throw "Add requires -$($pair.Name)."
        }
    }
    return [ordered]@{
        app_version = $AppVersion.Trim()
        host_kind = $HostKind.Trim()
        execution_mode = $ExecutionMode
        policy_version = $PolicyVersion.Trim()
    }
}

function Get-NearestRank {
    param(
        [Parameter(Mandatory)][double[]] $Values,
        [Parameter(Mandatory)][ValidateRange(0.01, 1.0)][double] $Percentile
    )

    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    return [double]$sorted[$index]
}

function Get-EnvironmentKey {
    param([Parameter(Mandatory)] $Record)
    return @(
        [string]$Record.app_version,
        [string]$Record.host_kind,
        [string]$Record.execution_mode,
        [string]$Record.policy_version
    ) -join [char]0x1f
}

function Read-Ledger {
    $records = [Collections.Generic.List[object]]::new()
    $badLines = 0
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = $line | ConvertFrom-Json -Depth 30 -DateKind String
                $required = @(
                    'schema_version', 'run_directory_hash',
                    'reconciliation_receipt_hash', 'recorded_at_utc',
                    'decision', 'snapshot_count',
                    'observation_window_span_seconds',
                    'min_window_used_seconds', 'app_version', 'host_kind',
                    'execution_mode', 'policy_version'
                )
                foreach ($name in $required) {
                    if ($null -eq $record.PSObject.Properties[$name]) {
                        throw "missing $name"
                    }
                }
                if ([string]$record.schema_version -ne '1.0' -or
                    [string]$record.run_directory_hash -notmatch '^[0-9a-f]{64}$' -or
                    [string]$record.reconciliation_receipt_hash -notmatch
                        '^[0-9a-f]{64}$' -or
                    [double]$record.observation_window_span_seconds -lt 0 -or
                    [int]$record.min_window_used_seconds -lt 5 -or
                    [string]$record.execution_mode -notin @('local', 'remote') -or
                    @(
                        $record.app_version, $record.host_kind,
                        $record.policy_version
                    ).Where({
                        [string]::IsNullOrWhiteSpace([string]$_)
                    }).Count -gt 0) {
                    throw 'invalid record'
                }
                $records.Add($record)
            } catch {
                $badLines++
            }
        }
    }
    return [pscustomobject]@{
        records = @($records)
        bad_lines = $badLines
    }
}

function Get-ThreadId {
    param($Thread)
    if ($null -ne $Thread.PSObject.Properties['thread_id']) {
        return [string]$Thread.thread_id
    }
    if ($null -ne $Thread.PSObject.Properties['id']) {
        return [string]$Thread.id
    }
    return ''
}

function Get-Observation {
    param(
        [Parameter(Mandatory)] $Receipt,
        [Parameter(Mandatory)][string] $RunRoot,
        [Parameter(Mandatory)] $Environment
    )

    $inputPath = [IO.Path]::GetFullPath(
        (Join-Path $RunRoot ([string]$Receipt.reconciliation_input_path))
    )
    $input = Get-Content -LiteralPath $inputPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
    $snapshots = @($input.snapshots)
    $snapshotTimes = @($snapshots | ForEach-Object {
        [DateTimeOffset]::Parse(
            [string]$_.captured_at,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
    })
    $span = if ($snapshotTimes.Count -ge 2) {
        ($snapshotTimes[-1] - $snapshotTimes[0]).TotalSeconds
    } else { 0.0 }

    $matchedIds = @($Receipt.matched_thread_ids | ForEach-Object {
        [string]$_
    })
    $firstPresentIndex = $null
    if ($matchedIds.Count -gt 0) {
        for ($index = 0; $index -lt $snapshots.Count; $index++) {
            $visibleIds = @($snapshots[$index].threads | ForEach-Object {
                Get-ThreadId $_
            })
            if (@($visibleIds | Where-Object { $_ -in $matchedIds }).Count -gt 0) {
                $firstPresentIndex = $index
                break
            }
        }
    }
    $firstPresent = if ($null -ne $firstPresentIndex) {
        $snapshotTimes[$firstPresentIndex].ToString('o')
    } else { $null }
    $lastAbsent = if ($null -ne $firstPresentIndex -and
        $firstPresentIndex -gt 0) {
        $snapshotTimes[$firstPresentIndex - 1].ToString('o')
    } else { $null }
    $intervalWidth = if ($null -ne $firstPresentIndex -and
        $firstPresentIndex -gt 0) {
        (
            $snapshotTimes[$firstPresentIndex] -
            $snapshotTimes[$firstPresentIndex - 1]
        ).TotalSeconds
    } else { $null }

    return [ordered]@{
        schema_version = '1.0'
        run_directory_hash = Get-TextSha256 (
            [IO.Path]::GetFullPath($RunRoot).ToLowerInvariant()
        )
        reconciliation_receipt_hash = [string]$Receipt.receipt_hash
        recorded_at_utc = [DateTime]::UtcNow.ToString('o')
        decision = [string]$Receipt.decision
        snapshot_count = [int]$Receipt.snapshot_count
        observation_window_span_seconds = [double]$span
        last_confirmed_absent_at_utc = $lastAbsent
        first_confirmed_present_at_utc = $firstPresent
        first_present_interval_width_seconds = $intervalWidth
        min_window_used_seconds = $MinWindowUsed
        app_version = [string]$Environment.app_version
        host_kind = [string]$Environment.host_kind
        execution_mode = [string]$Environment.execution_mode
        policy_version = [string]$Environment.policy_version
    }
}

if ($Action -eq 'Add') {
    if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
        throw 'Add requires -RunDirectory.'
    }
    $environment = Get-RequiredEnvironment
    $runRoot = (Resolve-Path -LiteralPath $RunDirectory).Path.TrimEnd('\', '/')
    $receiptsRoot = Join-Path $runRoot 'receipts'
    if (-not (Test-Path -LiteralPath $receiptsRoot -PathType Container)) {
        throw "Run receipts directory does not exist: $receiptsRoot"
    }
    $receiptPaths = @(Get-ChildItem -LiteralPath $receiptsRoot -Recurse -File |
        Where-Object Name -Like '*.thread-reconciliation.json' |
        Select-Object -ExpandProperty FullName)
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($receiptPath in $receiptPaths) {
        try {
            $receipt = Read-ThreadReconciliationReceipt -Path $receiptPath `
                -RunDirectory $runRoot
        } catch {
            throw (
                "Invalid reconciliation receipt '$receiptPath': " +
                $_.Exception.Message
            )
        }
        $observations.Add(
            (Get-Observation -Receipt $receipt -RunRoot $runRoot `
                -Environment $environment)
        )
    }

    $null = New-Item -ItemType Directory -Path $orchestratorRoot -Force
    $mutexName = 'AdaptiveAgentCalibration-' + (
        Get-TextSha256 ([IO.Path]::GetFullPath($ledgerPath))
    ).Substring(0, 24)
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $lockTaken = $false
    try {
        $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $lockTaken) { throw 'Timed out waiting for calibration ledger lock.' }
        $ledger = Read-Ledger
        $known = @{}
        foreach ($record in @($ledger.records)) {
            $known[[string]$record.reconciliation_receipt_hash] = $true
        }
        $added = 0
        $skipped = 0
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($observation in $observations) {
            $hash = [string]$observation.reconciliation_receipt_hash
            if ($known.ContainsKey($hash)) {
                $skipped++
                continue
            }
            [IO.File]::AppendAllText(
                $ledgerPath,
                ($observation | ConvertTo-Json -Compress -Depth 20) +
                    [Environment]::NewLine,
                $utf8
            )
            $known[$hash] = $true
            $added++
        }
        [pscustomobject][ordered]@{
            added = $added
            skipped_duplicates = $skipped
            ledger_path = $ledgerPath
            total_samples = $known.Count
            preexisting_bad_lines = $ledger.bad_lines
        } | ConvertTo-Json -Depth 10
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    exit 0
}

$ledger = Read-Ledger
$filtered = @($ledger.records | Where-Object {
    ([string]::IsNullOrWhiteSpace($AppVersion) -or
        [string]$_.app_version -eq $AppVersion) -and
    ([string]::IsNullOrWhiteSpace($HostKind) -or
        [string]$_.host_kind -eq $HostKind) -and
    ([string]::IsNullOrWhiteSpace($ExecutionMode) -or
        [string]$_.execution_mode -eq $ExecutionMode) -and
    ([string]::IsNullOrWhiteSpace($PolicyVersion) -or
        [string]$_.policy_version -eq $PolicyVersion)
})
$groups = [Collections.Generic.List[object]]::new()
foreach ($group in @($filtered | Group-Object { Get-EnvironmentKey $_ })) {
    $records = @($group.Group)
    $values = [double[]]@($records | ForEach-Object {
        [double]$_.observation_window_span_seconds
    })
    $p90 = Get-NearestRank -Values $values -Percentile 0.90
    $recommendation = if ($ledger.bad_lines -gt 0) {
        'suppressed-integrity-degraded'
    } else { 'insufficient-visibility-evidence' }
    $decisionDistribution = [ordered]@{}
    foreach ($decisionGroup in @($records | Group-Object decision)) {
        $decisionDistribution[[string]$decisionGroup.Name] =
            [int]$decisionGroup.Count
    }
    $sample = $records[0]
    $groups.Add([pscustomobject][ordered]@{
        environment = [ordered]@{
            app_version = [string]$sample.app_version
            host_kind = [string]$sample.host_kind
            execution_mode = [string]$sample.execution_mode
            policy_version = [string]$sample.policy_version
        }
        sample_count = $records.Count
        percentile_algorithm = 'nearest-rank'
        observation_window_span_seconds = [ordered]@{
            min = [double]($values | Measure-Object -Minimum).Minimum
            median = Get-NearestRank -Values $values -Percentile 0.50
            p90 = $p90
            max = [double]($values | Measure-Object -Maximum).Maximum
        }
        decision_distribution = $decisionDistribution
        span_at_or_above_min_window_count = @($records | Where-Object {
            [double]$_.observation_window_span_seconds -ge
                [int]$_.min_window_used_seconds
        }).Count
        recommendation = $recommendation
        recommendation_basis = [ordered]@{
            advisory_only = $true
            exact_visibility_latency_claimed = $false
            reason = (
                'Observation-window spans do not measure creation-to-visibility ' +
                'latency and cannot justify changing the configured window.'
            )
        }
    })
}
[pscustomobject][ordered]@{
    schema_version = '1.0'
    ledger_path = $ledgerPath
    integrity = if ($ledger.bad_lines -gt 0) { 'degraded' } else { 'ok' }
    bad_lines = $ledger.bad_lines
    total_valid_samples = @($ledger.records).Count
    filtered_sample_count = $filtered.Count
    percentile_algorithm = 'nearest-rank'
    groups = @($groups)
} | ConvertTo-Json -Depth 20
