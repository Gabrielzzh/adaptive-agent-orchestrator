# Release validation receipt

Release: `0.7.2`
Policy version: `0.7.2`
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Commands

```powershell
$skill = '.\skills\adaptive-agent-orchestrator'

Get-ChildItem "$skill\scripts" -Filter '*.ps1' | ForEach-Object {
  $tokens = $null
  $errors = $null
  [Management.Automation.Language.Parser]::ParseFile(
    $_.FullName,
    [ref]$tokens,
    [ref]$errors
  ) | Out-Null
  if ($errors) { throw $errors }
}

pwsh -NoProfile -File "$skill\scripts\Test-Self.ps1"

pwsh -NoProfile -File "$skill\scripts\Test-RecoveryProtocol.ps1"

python `
  "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  $skill
```

## Results

- Exit code: 0
- PowerShell scripts parsed: 33
- Recovery-protocol assertions: 30 passed
- Self-test assertions: 601 passed
- Intentional invalid negative cases: 57 correctly rejected
- Strict reference JSON files parsed: 8
- Skill Creator validation: `Skill is valid!`
- Windows Junction fixture: created and correctly rejected as a reparse-point
  input boundary
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

The release was validated from the repository Skill directory. The tests
cover deterministic mode/model selection, capacity isolation, strict JSON,
real-path boundaries, Worker packets, project knowledge control, lifecycle,
journal recovery, handoff, completion gates, retry authorization,
reconciliation calibration, non-materializing dispatch preview,
Worker-packet injection of the output-as-data policy and provenance labels,
result-receipt verification before durable-task archive, durable-task surface
selection, usable-HEAD worktree preflight, queued worktree setup, model
availability fallback, task-level completion receipts, durable domain/dissent
review, source-bound finding disposition, immutable P0/P1 blocking severity,
bounded missing-final recovery, legacy source adoption, authorized replacement
continuity, and cross-source isolation. The Worker-output policy is enforced by
main-agent review, not by parsing free-form text as a security sandbox.

The release also covers the successful-create/returned-task-ID retry guard,
platform-bound model launch, platform-independent write-scope overlap
comparison, and read-only run measurement. The reviewed Skill-only archive
contained 52/52 files matching commit
`5e2f2a9ce86493567083c0d1fe5ee3558854ff7b`. An independent dynamic re-attack
ended GREEN with P0=0, P1=0, and P2=0.

This receipt does not claim measured production Token savings. Synthetic and
local validation prove contract and implementation behavior, not a universal
end-to-end savings percentage. GitHub publication is verified separately after
the release is created.

The Skill does not repair platform `systemError` or missing-final behavior. It
fails closed, preserves evidence, and constrains recovery or replacement. The
symbolic-link fixture was skipped because this Windows session did not permit
link creation. Linux and macOS were not dynamically validated.
