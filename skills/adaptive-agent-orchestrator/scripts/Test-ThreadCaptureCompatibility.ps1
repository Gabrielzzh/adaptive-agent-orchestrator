[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$script:assertionCount = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'orchestrator-thread-capture-' + [guid]::NewGuid().ToString('N')
)

function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:assertionCount++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Capture {
    param(
        [switch] $HasNestedId,
        [string] $NestedId,
        [switch] $HasNestedThreadId,
        [string] $NestedThreadId,
        [switch] $HasTopThreadId,
        [string] $TopThreadId
    )
    $thread = [ordered]@{}
    if ($HasNestedId) { $thread.id = $NestedId }
    if ($HasNestedThreadId) { $thread.threadId = $NestedThreadId }
    $capture = [ordered]@{
        schemaVersion = 1
        thread = $thread
        page = [ordered]@{ order = 'newest_first' }
        turns = @(
            [ordered]@{
                id = 'final-turn'
                status = 'completed'
                items = @(
                    [ordered]@{
                        type = 'agentMessage'
                        phase = 'final_answer'
                        text = 'Verified final.'
                    }
                )
            }
        )
    }
    if ($HasTopThreadId) { $capture.threadId = $TopThreadId }
    return $capture
}

function Write-And-Read {
    param(
        [Parameter(Mandatory)][hashtable] $Capture,
        [Parameter(Mandatory)][string] $Name,
        [string] $ExpectedThreadId = 'thread-a'
    )
    $path = Join-Path $testRoot "$Name.json"
    $Capture | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $path -Encoding utf8
    return Read-ThreadReadCapture -Path $path `
        -ExpectedThreadId $ExpectedThreadId
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][hashtable] $Capture,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ExpectedMessage,
        [string] $ExpectedThreadId = 'thread-a'
    )
    $caught = $false
    try {
        Write-And-Read -Capture $Capture -Name $Name `
            -ExpectedThreadId $ExpectedThreadId | Out-Null
    } catch {
        $caught = $_.Exception.Message -like "*$ExpectedMessage*"
    }
    Assert-True $caught "$Name must fail closed with '$ExpectedMessage'."
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $validCases = @(
        @{ Name = 'official-thread-id'; Capture = New-Capture `
            -HasNestedId -NestedId 'thread-a' },
        @{ Name = 'legacy-nested-thread-id'; Capture = New-Capture `
            -HasNestedThreadId -NestedThreadId 'thread-a' },
        @{ Name = 'legacy-top-thread-id'; Capture = New-Capture `
            -HasTopThreadId -TopThreadId 'thread-a' },
        @{ Name = 'two-matching-identities'; Capture = New-Capture `
            -HasNestedId -NestedId 'thread-a' `
            -HasNestedThreadId -NestedThreadId 'thread-a' },
        @{ Name = 'three-matching-identities'; Capture = New-Capture `
            -HasNestedId -NestedId 'thread-a' `
            -HasNestedThreadId -NestedThreadId 'thread-a' `
            -HasTopThreadId -TopThreadId 'thread-a' }
    )
    foreach ($case in $validCases) {
        $result = Write-And-Read -Capture $case.Capture -Name $case.Name
        Assert-True ($result.final_turn_id -eq 'final-turn') (
            "$($case.Name) must select the final turn."
        )
    }

    $progressCapture = New-Capture -HasNestedId -NestedId 'thread-a'
    $progressCapture.turns[0].items[0].phase = 'commentary'
    $progressCapture.turns[0].items[0].text = 'Visible progress.'
    $progressPath = Join-Path $testRoot 'official-thread-id-progress.json'
    $progressCapture | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $progressPath -Encoding utf8
    $progress = Read-ThreadProgressCapture -Path $progressPath `
        -ExpectedThreadId 'thread-a'
    Assert-True ($progress.latest_turn_id -eq 'final-turn') (
        'Official thread.id must also work for progress captures.'
    )

    Assert-Rejected -Name 'official-vs-nested-conflict' `
        -ExpectedMessage 'conflicting thread identities' -Capture (
            New-Capture -HasNestedId -NestedId 'thread-a' `
                -HasNestedThreadId -NestedThreadId 'thread-b'
        )
    Assert-Rejected -Name 'official-vs-top-conflict' `
        -ExpectedMessage 'conflicting thread identities' -Capture (
            New-Capture -HasNestedId -NestedId 'thread-a' `
                -HasTopThreadId -TopThreadId 'thread-b'
        )
    Assert-Rejected -Name 'nested-vs-top-conflict' `
        -ExpectedMessage 'conflicting thread identities' -Capture (
            New-Capture -HasNestedThreadId -NestedThreadId 'thread-a' `
                -HasTopThreadId -TopThreadId 'thread-b'
        )
    Assert-Rejected -Name 'three-field-conflict' `
        -ExpectedMessage 'conflicting thread identities' -Capture (
            New-Capture -HasNestedId -NestedId 'thread-a' `
                -HasNestedThreadId -NestedThreadId 'thread-a' `
                -HasTopThreadId -TopThreadId 'thread-b'
        )
    Assert-Rejected -Name 'expected-thread-mismatch' `
        -ExpectedMessage 'does not match the expected thread' `
        -ExpectedThreadId 'thread-b' -Capture (
            New-Capture -HasNestedId -NestedId 'thread-a'
        )
    Assert-Rejected -Name 'missing-identity' `
        -ExpectedMessage 'does not declare a thread identity' `
        -Capture (New-Capture)
    Assert-Rejected -Name 'empty-secondary-identity' `
        -ExpectedMessage 'contains an empty thread identity' -Capture (
            New-Capture -HasNestedId -NestedId 'thread-a' `
                -HasTopThreadId -TopThreadId ''
        )

    [ordered]@{
        pass = $true
        assertions = $script:assertionCount
        official_thread_id = $true
        legacy_nested_thread_id = $true
        legacy_top_thread_id = $true
        conflicting_identities_rejected = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
