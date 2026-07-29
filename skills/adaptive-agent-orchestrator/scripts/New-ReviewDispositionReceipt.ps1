[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $MilestoneId,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $SourceThreadId,
    [Parameter(Mandatory)][string] $SourceResultReceiptPath,
    [Parameter(Mandatory)][string] $DecisionsPath,
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 20 -DateKind String

function Resolve-RunLocalPath {
    param([string] $Candidate, [string] $Label)
    $resolved = [IO.Path]::GetFullPath($Candidate)
    if (-not $resolved.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label must stay inside the run directory."
    }
    return $resolved
}

$sourcePath = Resolve-RunLocalPath $SourceResultReceiptPath (
    'Source result receipt'
)
$outputFullPath = Resolve-RunLocalPath $OutputPath 'Output receipt'
$decisionsFullPath = Resolve-RunLocalPath $DecisionsPath 'Review decisions'
if (-not (Test-Path -LiteralPath $decisionsFullPath -PathType Leaf)) {
    throw "Review decisions do not exist: $decisionsFullPath"
}
$source = Read-ThreadResultReceipt -Path $sourcePath `
    -ExpectedThreadId $SourceThreadId -RunDirectory $runRoot
$decisions = @(
    Get-Content -LiteralPath $decisionsFullPath -Raw |
        ConvertFrom-Json -Depth 50 -DateKind String
)
$pendingFindings = @()
if ($null -ne $source.PSObject.Properties['pending_findings']) {
    $pendingFindings = @($source.pending_findings)
}
$sourceFindings = @(
    $pendingFindings + @($source.adopted_findings) +
    @($source.rejected_findings) |
        ForEach-Object { [string]$_ }
)
if ($sourceFindings.Count -eq 0) {
    throw 'Source result receipt has no findings to disposition.'
}
if (@($sourceFindings | Select-Object -Unique).Count -ne
    $sourceFindings.Count) {
    throw 'Source result receipt contains duplicate findings.'
}

$seen = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$normalized = [Collections.Generic.List[object]]::new()
$blocking = [Collections.Generic.List[string]]::new()
foreach ($decision in $decisions) {
    foreach ($name in @(
        'finding', 'severity', 'disposition', 'rationale',
        'resolution_status', 'evidence', 're_review_status',
        're_review_evidence'
    )) {
        if ($null -eq $decision.PSObject.Properties[$name]) {
            throw "Review decision is missing '$name'."
        }
    }
    $finding = [string]$decision.finding
    if (-not $seen.Add($finding) -or $finding -notin $sourceFindings) {
        throw 'Review decisions contain a duplicate or unknown finding.'
    }
    $severity = [string]$decision.severity
    $disposition = [string]$decision.disposition
    $resolution = [string]$decision.resolution_status
    $rationale = [string]$decision.rationale
    $evidence = @($decision.evidence | ForEach-Object { [string]$_ })
    $reReviewStatus = [string]$decision.re_review_status
    $reReviewEvidence = @(
        $decision.re_review_evidence | ForEach-Object { [string]$_ }
    )
    if ($severity -notin @('P0', 'P1', 'P2') -or
        $disposition -notin @(
            'adopted', 'partially-adopted', 'rejected', 'deferred'
        ) -or
        $resolution -notin @('open', 'resolved') -or
        [string]::IsNullOrWhiteSpace($rationale)) {
        throw 'Review decision contains an invalid contract.'
    }
    if ($evidence.Count -eq 0 -or @($evidence | Where-Object {
        [string]::IsNullOrWhiteSpace($_)
    }).Count -gt 0) {
        throw 'Every review decision requires non-empty evidence.'
    }
    if ($resolution -eq 'resolved' -and @($evidence | Where-Object {
        $_ -match '^(test|artifact|source|observation):.+'
    }).Count -eq 0) {
        throw 'A resolved review decision requires typed resolution evidence.'
    }
    if ($reReviewStatus -notin @(
        'not-required', 'requested', 'completed'
    )) {
        throw 'Review decision contains an invalid re_review_status.'
    }
    if ($reReviewStatus -eq 'completed' -and
        @($reReviewEvidence | Where-Object {
            $_ -match '^(test|artifact|source|observation):.+'
        }).Count -eq 0) {
        throw 'Completed re-review requires typed evidence.'
    }
    if ($severity -in @('P0', 'P1') -and
        $disposition -in @('adopted', 'partially-adopted') -and
        $resolution -eq 'resolved' -and
        $reReviewStatus -ne 'completed') {
        throw 'Resolved adopted P0/P1 findings require completed re-review.'
    }
    if ($severity -in @('P0', 'P1') -and $resolution -ne 'resolved') {
        $blocking.Add($finding)
    }
    $normalized.Add([ordered]@{
        finding = $finding
        severity = $severity
        disposition = $disposition
        rationale = $rationale
        resolution_status = $resolution
        evidence = $evidence
        re_review_status = $reReviewStatus
        re_review_evidence = $reReviewEvidence
    })
}
if ($seen.Count -ne $sourceFindings.Count) {
    throw 'Review decisions must answer every source finding exactly once.'
}

$relativeSource = [IO.Path]::GetRelativePath($runRoot, $sourcePath) -replace '\\', '/'
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    milestone_id = $MilestoneId
    source_node_id = $SourceNodeId
    source_thread_id = $SourceThreadId
    source_result_receipt_path = $relativeSource
    source_result_receipt_hash = [string]$source.receipt_hash
    decisions = @($normalized)
    blocking_open = @($blocking)
    created_at_utc = [DateTime]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 30
)

$parent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Review disposition receipt already exists: $outputFullPath"
}
$receipt | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8
$receipt | ConvertTo-Json -Depth 30
