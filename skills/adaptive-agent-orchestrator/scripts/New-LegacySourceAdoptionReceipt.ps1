[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $OriginalThreadId,
    [Parameter(Mandatory)][string] $RoleMaterialPath,
    [Parameter(Mandatory)][string] $CheckpointMaterialPath,
    [Parameter(Mandatory)][string] $InputMaterialPath,
    [Parameter(Mandatory)][string] $TurnEvidencePath,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey,
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw |
    ConvertFrom-Json -Depth 20 -DateKind String
$plan = Get-Content -LiteralPath (Join-Path $runRoot 'plan.json') -Raw |
    ConvertFrom-Json -Depth 100 -DateKind String
$node = @($plan.nodes | Where-Object {
    [string]$_.id -eq $SourceNodeId
}) | Select-Object -First 1
if ($null -eq $node -or [string]$node.kind -ne 'agent' -or
    [string]$node.topology -ne 'background-thread' -or
    -not [bool]$node.read_only -or [bool]$node.allow_delegation -or
    @($node.write_scope).Count -gt 0 -or
    $SourceNodeId -eq $OriginalThreadId) {
    throw (
        'Legacy adoption requires a new stable, read-only, non-delegating ' +
        'durable source node.'
    )
}
if ($ActivationKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
    throw 'Legacy adoption requires a stable activation key.'
}

function Resolve-MaterialPath {
    param([string] $Path, [string] $Label)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label must be an existing file inside the run."
    }
    return $fullPath
}

$rolePath = Resolve-MaterialPath $RoleMaterialPath 'Role material'
$checkpointPath = Resolve-MaterialPath $CheckpointMaterialPath (
    'Checkpoint material'
)
$inputPath = Resolve-MaterialPath $InputMaterialPath 'Input material'
$turnPath = Resolve-MaterialPath $TurnEvidencePath 'Turn evidence'
$authorizationPath = Resolve-MaterialPath $AuthorizationMaterialPath (
    'Authorization material'
)
foreach ($materialPath in @(
    $rolePath, $checkpointPath, $inputPath, $authorizationPath
)) {
    if ([string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $materialPath -Raw)
    )) {
        throw 'Legacy adoption material captures cannot be empty.'
    }
}
$turnEvidence = @(
    Get-Content -LiteralPath $turnPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
)
if ($turnEvidence.Count -ne 4 -or
    @($turnEvidence.turn_id | Select-Object -Unique).Count -ne 4) {
    throw 'Legacy adoption requires exactly four unique turn records.'
}
foreach ($turn in $turnEvidence) {
    foreach ($name in @(
        'turn_id', 'status', 'error_state', 'final_state', 'progress_evidence'
    )) {
        if ($null -eq $turn.PSObject.Properties[$name]) {
            throw "Legacy turn evidence is missing '$name'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$turn.turn_id) -or
        [string]$turn.status -ne 'completed' -or
        [string]$turn.error_state -ne 'null' -or
        [string]$turn.final_state -ne 'missing') {
        throw 'Legacy turn evidence does not prove completed/no-final state.'
    }
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $outputFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or [IO.Path]::GetFileName($outputFullPath) -ne
    "$SourceNodeId.legacy-source-adoption.json") {
    throw 'Legacy adoption receipt path or filename is invalid.'
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Legacy adoption receipt already exists: $outputFullPath"
}
$roleHash = Get-TextSha256 (Get-Content -LiteralPath $rolePath -Raw)
$checkpointHash = Get-TextSha256 (
    Get-Content -LiteralPath $checkpointPath -Raw
)
$existingDirectory = Split-Path -Parent $outputFullPath
if (Test-Path -LiteralPath $existingDirectory -PathType Container) {
    $duplicate = @(
        Get-ChildItem -LiteralPath $existingDirectory `
            -Filter '*.legacy-source-adoption.json' -File |
            ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw |
                    ConvertFrom-Json -Depth 30 -DateKind String
            } | Where-Object {
                [string]$_.original_thread_id -eq $OriginalThreadId -and
                [string]$_.checkpoint_hash -eq $checkpointHash -and
                [string]$_.role_contract_hash -eq $roleHash
            }
    )
    if ($duplicate.Count -gt 0) {
        throw 'Legacy source identity was already adopted.'
    }
}

$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    source_node_id = $SourceNodeId
    role_id = [string]$node.role_id
    original_thread_id = $OriginalThreadId
    role_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $rolePath
    ).Replace('\', '/')
    role_contract_hash = $roleHash
    checkpoint_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $checkpointPath
    ).Replace('\', '/')
    checkpoint_hash = $checkpointHash
    input_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $inputPath
    ).Replace('\', '/')
    input_material_hash = Get-TextSha256 (
        Get-Content -LiteralPath $inputPath -Raw
    )
    turn_evidence_path = [IO.Path]::GetRelativePath(
        $runRoot, $turnPath
    ).Replace('\', '/')
    turn_evidence_hash = Get-TextSha256 (
        Get-Content -LiteralPath $turnPath -Raw
    )
    turn_ids = @($turnEvidence.turn_id)
    unknown_fields = @(
        'machine_source_node_id', 'machine_role_id', 'original_input_hash',
        'immutable_read_capture_hash'
    )
    authorization_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $authorizationPath
    ).Replace('\', '/')
    authorization_material_hash = Get-TextSha256 (
        Get-Content -LiteralPath $authorizationPath -Raw
    )
    activation_key = $ActivationKey
    outcome = 'replacement-eligible'
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$receipt = [ordered]@{}
foreach ($key in $payload.Keys) { $receipt[$key] = $payload[$key] }
$receipt.receipt_hash = Get-TextSha256 (
    $payload | ConvertTo-Json -Compress -Depth 30
)
if (-not (Test-Path -LiteralPath $existingDirectory)) {
    $null = New-Item -ItemType Directory -Path $existingDirectory
}
$receipt | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8
try {
    $verified = Read-LegacySourceAdoptionReceipt -Path $outputFullPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId
} catch {
    Remove-Item -LiteralPath $outputFullPath -Force
    throw
}
$verified | ConvertTo-Json -Depth 30
