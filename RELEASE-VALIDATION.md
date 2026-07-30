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
comparison, and read-only run measurement.

Commit `5e2f2a9ce86493567083c0d1fe5ee3558854ff7b` and its independently
reviewed 52-file archive are the fixed functional GREEN baseline, not the
final v0.7.2 archive binding. The v0.7.2 Skill content was last changed by
release-prep commit `64a5df26a1433c5fb857072e926f42b2beb445bc` and is bound
to Git tree `0f86279a51167ce29dd8c881f0d7c45702967082`. The final
Skill-only archive contains 52 files and has SHA-256
`befc0a2c9ba8ee29b9f066ad1a794ef440071dd517028eb0642d5f11658d1751`.
It was generated with `git archive --mtime=2026-07-30T00:00:00Z` so a
receipt-only repository commit cannot change ZIP metadata for an unchanged
Skill tree.
Git for Windows exported text files with CRLF line endings; after normalizing
CRLF to the repository's LF blob form, all 52/52 archive files match that
Skill tree. The archive was extracted and the complete parser, recovery,
self-test, invalid-case, and Skill Creator gates were run again successfully.

The repository HEAD that adds this receipt-only correction is reported with
the external release-preparation result. It cannot be embedded in the same
tracked file without changing its own commit ID; the immutable Skill-tree
binding above is the artifact identity used for verification. The independent
dynamic re-attack of the functional baseline ended GREEN with P0=0, P1=0, and
P2=0.

This receipt does not claim measured production Token savings. Synthetic and
local validation prove contract and implementation behavior, not a universal
end-to-end savings percentage. GitHub publication is verified separately after
the release is created.

The Skill does not repair platform `systemError` or missing-final behavior. It
fails closed, preserves evidence, and constrains recovery or replacement. The
symbolic-link fixture was skipped because this Windows session did not permit
link creation. Linux and macOS were not dynamically validated.
