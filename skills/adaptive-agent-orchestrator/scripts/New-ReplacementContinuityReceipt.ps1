[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $SourceNodeId,
    [Parameter(Mandatory)][string] $OriginalThreadId,
    [Parameter(Mandatory)][string] $ReplacementThreadId,
    [Parameter(Mandatory)][string] $CheckpointManifestPath,
    [Parameter(Mandatory)][string] $InputManifestPath,
    [Parameter(Mandatory)][string[]] $RecoveryReceiptPaths,
    [Parameter(Mandatory)][string] $AuthorizationMaterialPath,
    [Parameter(Mandatory)][string] $ActivationKey,
    [string] $LegacySourceAdoptionReceiptPath,
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
$role = if ($null -eq $node) { $null } else {
    @($plan.roles | Where-Object {
        [string]$_.id -eq [string]$node.role_id
    }) | Select-Object -First 1
}
if ($null -eq $node -or $null -eq $role -or
    [string]$node.kind -ne 'agent' -or
    [string]$node.topology -ne 'background-thread' -or
    -not [bool]$node.read_only -or
    [bool]$node.allow_delegation -or
    @($node.write_scope).Count -gt 0 -or
    $OriginalThreadId -eq $ReplacementThreadId) {
    throw (
        'Replacement requires one read-only, non-delegating durable source ' +
        'and a distinct new thread.'
    )
}
if ($RecoveryReceiptPaths.Count -ne 3) {
    throw 'Replacement requires exactly three recovery receipts.'
}
if ($ActivationKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
    throw 'Replacement requires a stable activation key.'
}

function Resolve-BoundPath {
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

$checkpointPath = Resolve-BoundPath $CheckpointManifestPath (
    'Checkpoint manifest'
)
$inputPath = Resolve-BoundPath $InputManifestPath 'Input manifest'
$authorizationPath = Resolve-BoundPath $AuthorizationMaterialPath (
    'Authorization material'
)
$authorizationMaterial = Get-Content -LiteralPath $authorizationPath -Raw
if ([string]::IsNullOrWhiteSpace($authorizationMaterial)) {
    throw 'Authorization material cannot be empty.'
}
$checkpointHash = Get-TextSha256 (
    Get-Content -LiteralPath $checkpointPath -Raw
)
$inputHash = Get-TextSha256 (Get-Content -LiteralPath $inputPath -Raw)

$relativeRecoveryPaths = [Collections.Generic.List[string]]::new()
$recoveryHashes = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt 3; $index++) {
    $recoveryPath = Resolve-BoundPath $RecoveryReceiptPaths[$index] (
        'Recovery receipt'
    )
    $recovery = Read-ThreadResultRecoveryReceipt -Path $recoveryPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId `
        -ExpectedRecoveryStage 'original'
    if ([int]$recovery.attempt -ne ($index + 1) -or
        [string]$recovery.checkpoint_hash -ne $checkpointHash -or
        [string]$recovery.input_manifest_hash -ne $inputHash) {
        throw 'Recovery chain changed attempt, checkpoint, or input.'
    }
    $relativeRecoveryPaths.Add(
        [IO.Path]::GetRelativePath($runRoot, $recoveryPath).Replace('\', '/')
    )
    $recoveryHashes.Add([string]$recovery.receipt_hash)
}
if ([string]$recovery.outcome -ne 'recovery-exhausted') {
    throw 'Replacement is not eligible before recovery attempt 3 is exhausted.'
}

$legacyRelativePath = ''
$legacyHash = ''
$roleHash = Get-TextSha256 (
    $role | ConvertTo-Json -Compress -Depth 50
)
if (-not [string]::IsNullOrWhiteSpace($LegacySourceAdoptionReceiptPath)) {
    $legacyPath = Resolve-BoundPath $LegacySourceAdoptionReceiptPath (
        'Legacy source adoption receipt'
    )
    $legacy = Read-LegacySourceAdoptionReceipt -Path $legacyPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedOriginalThreadId $OriginalThreadId
    if ([string]$legacy.checkpoint_hash -ne $checkpointHash -or
        [string]$legacy.input_material_hash -ne $inputHash) {
        throw 'Legacy source adoption changed checkpoint or input material.'
    }
    $roleHash = [string]$legacy.role_contract_hash
    $legacyRelativePath = [IO.Path]::GetRelativePath(
        $runRoot, $legacyPath
    ).Replace('\', '/')
    $legacyHash = [string]$legacy.receipt_hash
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $outputFullPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or [IO.Path]::GetFileName($outputFullPath) -ne
    "$SourceNodeId.replacement-continuity.json") {
    throw 'Replacement continuity receipt path or filename is invalid.'
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Replacement continuity receipt already exists: $outputFullPath"
}
$payload = [ordered]@{
    schema_version = '1.0'
    run_id = [string]$run.run_id
    source_node_id = $SourceNodeId
    role_id = [string]$node.role_id
    original_thread_id = $OriginalThreadId
    replacement_thread_id = $ReplacementThreadId
    continuity_key = [string]$node.context.continuity_key
    checkpoint_path = [IO.Path]::GetRelativePath(
        $runRoot, $checkpointPath
    ).Replace('\', '/')
    checkpoint_hash = $checkpointHash
    input_manifest_path = [IO.Path]::GetRelativePath(
        $runRoot, $inputPath
    ).Replace('\', '/')
    input_manifest_hash = $inputHash
    recovery_receipt_paths = @($relativeRecoveryPaths)
    recovery_receipt_hashes = @($recoveryHashes)
    recovery_chain_hash = Get-TextSha256 (
        @($recoveryHashes) -join "`n"
    )
    role_contract_hash = $roleHash
    authorization_material_path = [IO.Path]::GetRelativePath(
        $runRoot, $authorizationPath
    ).Replace('\', '/')
    authorization_material_hash = Get-TextSha256 (
        $authorizationMaterial
    )
    activation_key = $ActivationKey
    legacy_adoption_receipt_path = $legacyRelativePath
    legacy_adoption_receipt_hash = $legacyHash
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
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
$receipt | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8
try {
    $verified = Read-ReplacementContinuityReceipt -Path $outputFullPath `
        -RunDirectory $runRoot -ExpectedSourceNodeId $SourceNodeId `
        -ExpectedReplacementThreadId $ReplacementThreadId
} catch {
    Remove-Item -LiteralPath $outputFullPath -Force
    throw
}
$verified | ConvertTo-Json -Depth 30
