[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $ThreadId,
    [Parameter(Mandatory)][string] $HostId,
    [Parameter(Mandatory)][string] $ThreadReadPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $PendingFindingRecordsPath,
    [string[]] $PendingFindings = @(),
    [string[]] $AdoptedFindings = @(),
    [string[]] $RejectedFindings = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

foreach ($value in @($ThreadId, $HostId)) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Thread and host IDs must be non-empty.'
    }
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}
if (-not (Test-Path -LiteralPath $ThreadReadPath -PathType Leaf)) {
    throw "Thread-read capture does not exist: $ThreadReadPath"
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Thread result receipt already exists: $OutputPath"
}
if ([IO.Path]::GetFileName($OutputPath) -notlike '*.thread-result-receipt.json') {
    throw 'OutputPath must end with .thread-result-receipt.json.'
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$captureFullPath = [IO.Path]::GetFullPath($ThreadReadPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
foreach ($candidate in @($captureFullPath, $outputFullPath)) {
    if (-not $candidate.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Thread-read capture and receipt must remain inside the run.'
    }
}
$captureRelativePath = $captureFullPath.Substring($runRoot.Length + 1)
$captureSegments = $captureRelativePath -split '[\\/]'
if (@($captureSegments | Where-Object {
    $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
}).Count -gt 0) {
    throw 'Thread-read capture path contains an unsafe segment.'
}
$final = Read-ThreadReadCapture -Path $captureFullPath `
    -ExpectedThreadId $ThreadId
$structuredPending = @()
if (-not [string]::IsNullOrWhiteSpace($PendingFindingRecordsPath)) {
    if (@($PendingFindings + $AdoptedFindings + $RejectedFindings).Count -gt 0) {
        throw (
            'PendingFindingRecordsPath cannot be combined with legacy ' +
            'string finding parameters.'
        )
    }
    $findingRecordsFullPath = [IO.Path]::GetFullPath(
        $PendingFindingRecordsPath
    )
    if (-not $findingRecordsFullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $findingRecordsFullPath -PathType Leaf)) {
        throw 'Pending finding records must be an existing file inside the run.'
    }
    $findingRecords = @(
        Get-Content -LiteralPath $findingRecordsFullPath -Raw |
            ConvertFrom-Json -Depth 30 -DateKind String
    )
    if ($findingRecords.Count -eq 0) {
        throw 'Pending finding records require at least one finding.'
    }
    $seenFindingIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $structuredPending = @($findingRecords | ForEach-Object {
        foreach ($name in @('finding_id', 'severity', 'text')) {
            if ($null -eq $_.PSObject.Properties[$name]) {
                throw "Pending finding record is missing '$name'."
            }
        }
        $findingId = [string]$_.finding_id
        $severity = [string]$_.severity
        $text = [string]$_.text
        if ($findingId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
            -not $seenFindingIds.Add($findingId)) {
            throw 'Pending findings require unique stable finding_id values.'
        }
        if ($severity -notin @('P0', 'P1', 'P2') -or
            [string]::IsNullOrWhiteSpace($text)) {
            throw 'Pending findings require P0/P1/P2 severity and non-empty text.'
        }
        [ordered]@{
            finding_id = $findingId
            severity = $severity
            text = $text
            text_hash = Get-TextSha256 $text
        }
    })
}
$adopted = @($AdoptedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$rejected = @($RejectedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$pending = @($PendingFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$allFindings = if ($structuredPending.Count -gt 0) {
    @($structuredPending)
} else {
    @($pending + $adopted + $rejected)
}
if ($allFindings.Count -eq 0) {
    throw 'At least one pending, adopted, or rejected finding is required.'
}
if ($structuredPending.Count -eq 0 -and
    @($allFindings | Select-Object -Unique).Count -ne $allFindings.Count) {
    throw 'Thread result findings must be unique across disposition groups.'
}
$receiptAdopted = [object[]]@($adopted)
$receiptRejected = [object[]]@($rejected)
$receiptPending = [object[]]@($pending)
if ($structuredPending.Count -gt 0) {
    $receiptAdopted = [object[]]@()
    $receiptRejected = [object[]]@()
    $receiptPending = [object[]]@($structuredPending)
}
$receipt = [ordered]@{
    schema_version = if ($structuredPending.Count -gt 0) { '1.3' } else { '1.2' }
    thread_id = $ThreadId
    host_id = $HostId
    collection_method = 'read_thread'
    thread_read_path = $captureRelativePath.Replace('\', '/')
    thread_read_hash = $final.capture_hash
    final_turn_id = $final.final_turn_id
    final_status = 'completed'
    final_content_hash = $final.final_content_hash
    adopted_findings = $receiptAdopted
    rejected_findings = $receiptRejected
    pending_findings = $receiptPending
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
