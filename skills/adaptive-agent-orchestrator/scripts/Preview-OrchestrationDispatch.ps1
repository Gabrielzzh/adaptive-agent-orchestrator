[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PlanPath,

    [Parameter(Mandatory)]
    [string] $WorkspaceRoot,

    [ValidateRange(1, 100)]
    [int] $Wave = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-PreviewProperty {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$tempDirectory = Join-Path $tempRoot (
    'adaptive-agent-orchestrator-preview-' + [guid]::NewGuid().ToString('N')
)
$null = [IO.Directory]::CreateDirectory($tempDirectory)

try {
    $resolvedPlan = (Resolve-Path -LiteralPath $PlanPath).Path
    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

    & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
        -PlanPath $resolvedPlan -WorkspaceRoot $resolvedWorkspace | Out-Null

    $plan = Get-Content -LiteralPath $resolvedPlan -Raw |
        ConvertFrom-Json -Depth 100
    if ([string](Get-PreviewProperty $plan 'mode') -ne 'workflow') {
        throw (
            'Dispatch preview is limited to durable workflow plans. ' +
            'Quick and temporary delegation should use the normal concise preview.'
        )
    }

    $nodes = @(Get-PreviewProperty $plan 'nodes')
    $nodeIndex = @{}
    foreach ($candidate in $nodes) {
        $candidateId = [string](Get-PreviewProperty $candidate 'id')
        if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
            $nodeIndex[$candidateId] = $candidate
        }
    }

    $workers = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    foreach ($node in @($nodes | Where-Object {
        (Get-PreviewProperty $_ 'kind') -eq 'agent' -and
        [int](Get-PreviewProperty $_ 'wave') -eq $Wave
    })) {
        $dependencyIds = @(
            Get-PreviewProperty $node 'depends_on' | ForEach-Object {
                [string]$_
            }
        )
        $planEligible = $true
        foreach ($dependencyId in $dependencyIds) {
            if (-not $nodeIndex.ContainsKey($dependencyId)) {
                $planEligible = $false
                break
            }
            $dependencyWave = Get-PreviewProperty $nodeIndex[$dependencyId] 'wave'
            if ($null -eq $dependencyWave -or [int]$dependencyWave -ge $Wave) {
                $planEligible = $false
                break
            }
        }
        if (-not $planEligible) {
            $notes.Add(
                "Node '$([string](Get-PreviewProperty $node 'id'))' is not " +
                'plan-eligible because its dependencies are not all assigned ' +
                'to earlier waves.'
            )
            continue
        }

        $context = Get-PreviewProperty $node 'context'
        $inputs = @(Get-PreviewProperty $context 'inputs')
        $writeScope = @(Get-PreviewProperty $node 'write_scope')
        $sessionPolicy = [string](Get-PreviewProperty $context 'session_policy')
        $packetChars = $null
        $note = $null

        if ($sessionPolicy -eq 'reuse') {
            $note = 'reuse-verification-deferred'
        } else {
            $packetPath = Join-Path $tempDirectory (
                [string](Get-PreviewProperty $node 'id') + '.worker-packet.md'
            )
            $packet = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
                -PlanPath $resolvedPlan `
                -NodeId ([string](Get-PreviewProperty $node 'id')) `
                -WorkspaceRoot $resolvedWorkspace
            $packetText = [string]$packet
            $packetText | Set-Content -LiteralPath $packetPath
            $packetChars = $packetText.Length
        }

        $workers.Add([pscustomobject][ordered]@{
            node_id = [string](Get-PreviewProperty $node 'id')
            role_id = [string](Get-PreviewProperty $node 'role_id')
            topology = [string](Get-PreviewProperty $node 'topology')
            model = [string](Get-PreviewProperty $node 'model')
            capability = [string](Get-PreviewProperty $node 'capability')
            effort = [string](Get-PreviewProperty $node 'effort')
            read_only = [bool](Get-PreviewProperty $node 'read_only')
            input_references = @($inputs)
            reference_count = $inputs.Count
            write_scope = @($writeScope)
            dependency_ids = @($dependencyIds)
            plan_eligible = $true
            runtime_readiness = 'not-evaluated'
            session_policy = $sessionPolicy
            initial_packet_chars = $packetChars
            note = $note
        })
    }

    $measuredPackets = @($workers | Where-Object {
        $null -ne $_.initial_packet_chars
    })
    $totalInitialPacketChars = if ($measuredPackets.Count -eq 0) {
        0
    } else {
        [int64](($measuredPackets | Measure-Object `
            -Property initial_packet_chars -Sum).Sum)
    }

    $notes.Add(
        'initial_packet_chars measures only the rendered initial Worker packet ' +
        'and is a bounded context proxy, not total usage or monetary cost.'
    )
    $notes.Add(
        'plan_eligible means dependencies are structurally assigned to earlier ' +
        'waves; runtime readiness is not evaluated before a run exists.'
    )

    [pscustomobject][ordered]@{
        schema_version = '1.0'
        plan_run_id = [string](Get-PreviewProperty $plan 'run_id')
        wave = $Wave
        workers = @($workers)
        worker_count = $workers.Count
        total_initial_packet_chars = $totalInitialPacketChars
        notes = @($notes)
    } | ConvertTo-Json -Depth 20
} finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        $resolvedTempDirectory = [IO.Path]::GetFullPath(
            (Resolve-Path -LiteralPath $tempDirectory).Path
        ).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        $expectedPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
        $expectedLeafPrefix = 'adaptive-agent-orchestrator-preview-'
        if (-not $resolvedTempDirectory.StartsWith(
                $expectedPrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not (Split-Path -Leaf $resolvedTempDirectory).StartsWith(
                $expectedLeafPrefix,
                [StringComparison]::Ordinal
            )) {
            throw 'Refusing to clean a preview directory outside the verified temp root.'
        }
        Remove-Item -LiteralPath $resolvedTempDirectory -Recurse -Force
    }
}
