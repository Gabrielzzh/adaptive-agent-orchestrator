[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorkspaceRoot,
    [switch] $RequiresIndependentWrite,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "WorkspaceRoot does not exist: $WorkspaceRoot"
}
$root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Invoke-GitProbe {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $lines = @(& git -c "safe.directory=$root" -C $root @Arguments 2>&1 | ForEach-Object {
        [string]$_
    })
    return [pscustomobject]@{
        exit_code = $LASTEXITCODE
        lines = $lines
    }
}

$repoProbe = Invoke-GitProbe @('rev-parse', '--is-inside-work-tree')
$isGitRepository = $repoProbe.exit_code -eq 0 -and
    @($repoProbe.lines | Where-Object { $_.Trim() -eq 'true' }).Count -gt 0
$hasUsableHead = $false
$headCommit = $null
$branch = $null
$statusLines = @()
$worktreePaths = @()

if ($isGitRepository) {
    $headProbe = Invoke-GitProbe @('rev-parse', '--verify', 'HEAD')
    $hasUsableHead = $headProbe.exit_code -eq 0 -and
        $headProbe.lines.Count -gt 0 -and
        $headProbe.lines[0].Trim() -match '^[0-9a-fA-F]{40,64}$'
    if ($hasUsableHead) {
        $headCommit = $headProbe.lines[0].Trim().ToLowerInvariant()
    }
    $branchProbe = Invoke-GitProbe @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branchProbe.exit_code -eq 0 -and $branchProbe.lines.Count -gt 0) {
        $branch = $branchProbe.lines[0].Trim()
    } elseif ($hasUsableHead) {
        $branch = '(detached)'
    } else {
        $branch = '(unborn)'
    }
    $statusProbe = Invoke-GitProbe @('status', '--short')
    if ($statusProbe.exit_code -eq 0) {
        $statusLines = @($statusProbe.lines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
    }
    $worktreeProbe = Invoke-GitProbe @('worktree', 'list', '--porcelain')
    if ($worktreeProbe.exit_code -eq 0) {
        $worktreePaths = @($worktreeProbe.lines | Where-Object {
            $_ -like 'worktree *'
        } | ForEach-Object {
            $_.Substring('worktree '.Length)
        })
    }
}

$worktreeEligible = $isGitRepository -and $hasUsableHead
$recommendedEnvironment = if ($worktreeEligible -and $RequiresIndependentWrite) {
    'worktree'
} elseif (-not $RequiresIndependentWrite) {
    'local'
} else {
    'main-agent'
}
$reason = if (-not $isGitRepository) {
    if ($RequiresIndependentWrite) {
        'non-git workspace cannot provide an isolated worktree writer'
    } else {
        'read-only durable work may share the saved local project'
    }
} elseif (-not $hasUsableHead) {
    if ($RequiresIndependentWrite) {
        'git repository has no usable HEAD; establish a user-approved baseline before worktree creation'
    } else {
        'git repository has no usable HEAD; read-only durable work should use the local project'
    }
} elseif ($RequiresIndependentWrite) {
    'usable HEAD is available for an isolated writer worktree'
} else {
    'read-only durable work does not require a worktree'
}

$receipt = [ordered]@{
    schema_version = '1.0'
    workspace_root = $root
    is_git_repository = $isGitRepository
    has_usable_head = $hasUsableHead
    head_commit = $headCommit
    branch = $branch
    status_short = $statusLines
    worktree_paths = $worktreePaths
    requires_independent_write = [bool]$RequiresIndependentWrite
    worktree_eligible = $worktreeEligible
    recommended_environment = $recommendedEnvironment
    reason = $reason
}
$receipt.preflight_hash = Get-TextSha256 (
    $receipt | ConvertTo-Json -Compress -Depth 20
)
$json = $receipt | ConvertTo-Json -Depth 20

if ($OutputPath) {
    if ([IO.Path]::GetFileName($OutputPath) -notlike
        '*.worktree-preflight.json') {
        throw 'OutputPath must end with .worktree-preflight.json.'
    }
    if (Test-Path -LiteralPath $OutputPath) {
        throw "Worktree preflight receipt already exists: $OutputPath"
    }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent
    }
    Set-Content -LiteralPath $OutputPath -Value $json
}

$json
