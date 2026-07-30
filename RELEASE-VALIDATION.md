# Release validation receipt

Release: `0.7.4`
Policy version: `0.7.4`
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

pwsh -NoProfile -File "$skill\scripts\Test-RunPolicyActivation.ps1"

python `
  "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  $skill
```

## Results

- Exit code: 0
- PowerShell scripts parsed: 35
- Run-policy activation assertions: 15 passed
- Recovery-protocol assertions: 45 passed
- Self-test assertions: 637 passed
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
comparison, read-only run measurement, honest unverified actual-model
materialization, a separate replacement recovery epoch, lifecycle-derived
recovery stage, canonical receipt uniqueness, and rejection of
replacement-of-replacement. v0.7.4 adds immutable predecessor policy
activation, artifact and source-obligation binding, existing-replacement
lifecycle adoption, source/runtime policy separation, and fail-closed replay,
downgrade, tamper, duplicate, and concurrent-activation checks.

Functional candidate `e580b6ab71afed0a56c916aefd6ad71219b10ddd`
was independently re-attacked before release preparation. The Reviewer used a
clean 54-file archive matching that commit and ended GREEN with P0=0, P1=0,
and P2=0. The dynamic attack set included 27 activation assertions, 55
recovery/adoption assertions, and 12 synchronized concurrent-activation
rounds; each round produced exactly one writer.

The final v0.7.4 Skill content was last changed by functional commit
`e580b6ab71afed0a56c916aefd6ad71219b10ddd` and is bound to Git tree
`5a090450cc0b5ee0ca0c554fa544a769bb12b437`. The final Skill-only archive
contains 54 files and has SHA-256
`51281eab92cea8ebc3625fbde6f70a514d8e594d5b75077393b0c348e64d651e`.
Git for Windows exported text files with CRLF line endings; after normalizing
CRLF to the repository's LF blob form, all 54/54 archive files match that
Skill tree. The archive was extracted and the 35-script parser, 15-assertion
activation suite, 45-assertion recovery suite, 637-assertion self-test with 57
rejected invalid cases, and Skill Creator validation all passed again.

This receipt does not claim measured production Token savings. Synthetic and
local validation prove contract and implementation behavior, not a universal
end-to-end savings percentage. GitHub publication is verified separately after
the release is created.

The Skill does not repair platform `systemError` or missing-final behavior,
migrate business artifacts, or modify the multi-divination project. It fails
closed, preserves evidence, and constrains recovery or replacement. The
symbolic-link fixture was skipped because this Windows session did not permit
link creation. Linux and macOS were not dynamically validated.
