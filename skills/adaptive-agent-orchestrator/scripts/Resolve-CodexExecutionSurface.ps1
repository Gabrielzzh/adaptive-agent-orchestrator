[CmdletBinding()]
param(
    [switch] $Independent,
    [switch] $Bounded,
    [switch] $IndependentlyCheckable,
    [switch] $MateriallySmallerContext,
    [switch] $LowerCostModelAvailable,
    [switch] $ReadOnly,
    [switch] $TemporaryOnly,
    [switch] $ExplicitThreadRequest,
    [switch] $UserConfirmedDurable,
    [switch] $NeedsVisibleHistory,
    [switch] $NeedsCrossTurnReuse,
    [ValidateSet('eligible', 'ineligible', 'unknown', 'not-applicable')]
    [string] $WorktreePreflight = 'not-applicable'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$delegationEligible = $Independent -and $Bounded -and
    $IndependentlyCheckable -and (
        $MateriallySmallerContext -or $LowerCostModelAvailable -or
        $NeedsVisibleHistory -or $NeedsCrossTurnReuse
    )
$durableValue = $ExplicitThreadRequest -or $NeedsVisibleHistory -or
    $NeedsCrossTurnReuse -or ($delegationEligible -and -not $TemporaryOnly)
$durableAuthorized = $ExplicitThreadRequest -or $UserConfirmedDurable

$surface = 'main-agent'
$action = 'main-owns'
$reason = (
    'work is not independently checkable with smaller context, a lower-cost ' +
    'model, or useful durable history'
)
$requiresConfirmation = $false
$fallback = 'main-agent'

if ($delegationEligible) {
    if ($durableValue -and -not $durableAuthorized) {
        $surface = 'durable-task-proposal'
        $action = 'request-durable-confirmation'
        $reason = (
            'independent bounded work has a context, model-cost, or durable-' +
            'history benefit; ' +
            'a user-owned durable task is recommended but not yet authorized'
        )
        $requiresConfirmation = $true
    } elseif ($durableAuthorized) {
        if ($ReadOnly) {
            $surface = 'durable-local-task'
            $action = 'create-durable-local'
            $reason = (
                'a visible durable task is authorized and read-only work can ' +
                'share the saved local project'
            )
        } elseif ($WorktreePreflight -eq 'eligible') {
            $surface = 'durable-worktree-task'
            $action = 'create-durable-worktree'
            $reason = (
                'a visible durable writer is authorized and worktree ' +
                'preflight confirmed a usable Git HEAD'
            )
        } elseif ($WorktreePreflight -eq 'ineligible') {
            $surface = 'blocked-worktree-preflight'
            $action = 'stop-and-report'
            $reason = (
                'independent write work requires isolation, but worktree ' +
                'preflight is ineligible'
            )
        } else {
            $surface = 'worktree-preflight-required'
            $action = 'run-worktree-preflight'
            $reason = (
                'independent write work needs a verified worktree preflight ' +
                'before task creation'
            )
        }
    } elseif ($ReadOnly) {
        $surface = 'native-subagent'
        $action = 'spawn-native'
        $reason = (
            'temporary read-only work is bounded and does not require a ' +
            'user-owned visible history'
        )
    } else {
        $reason = 'temporary write work remains with the main agent'
    }
} elseif ($ExplicitThreadRequest) {
    $surface = 'blocked-invalid-task-split'
    $action = 'clarify-or-main'
    $reason = (
        'the user requested a thread, but the proposed workstream is not yet ' +
        'bounded, independently checkable, and context-isolated'
    )
}

[ordered]@{
    surface = $surface
    action = $action
    reason = $reason
    delegation_eligible = [bool]$delegationEligible
    durable_authorized = [bool]$durableAuthorized
    requires_user_confirmation = $requiresConfirmation
    fallback = $fallback
} | ConvertTo-Json -Depth 5
