# Release validation receipt

Release: `0.7.6`
Policy version: `0.7.6`
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.6 adds an auditable successor-run path for a durable review run that has
used its final declared milestone but still owns unresolved P1 obligations.

The predecessor is not edited or copied. An append-only export binds its plan,
run metadata, genesis, final journal boundary, effective policy, active
milestone, checkpoint, control authorization, exact source/role/thread
identities, result and disposition receipts, and every unresolved P1. A
separate command creates a new `0.7.6` run and adoption receipt bound to that
export and a new immutable plan.

Completion treats carried P1 findings as baseline obligations. The same sources
must disposition and re-review them before the successor can finish. P0
carry-forward, omission, mutation, severity downgrade, cross-source replay,
directory-copy adoption, bare genesis, duplicate/forked successors, and
unbound thread reuse fail closed.

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

pwsh -NoProfile -File `
  "$skill\scripts\Test-DurableReviewMilestone.ps1"

pwsh -NoProfile -File `
  "$skill\scripts\Test-RunPolicyActivation.ps1"

pwsh -NoProfile -File `
  "$skill\scripts\Test-RecoveryProtocol.ps1"

pwsh -NoProfile -File "$skill\scripts\Test-Self.ps1"

python `
  "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  $skill
```

`Test-DurableReviewSuccessorAdoption.ps1` is the production validator for a
specific predecessor/successor pair and therefore requires run paths. The
full self-test and durable-milestone suite construct valid and adversarial
fixtures for it.

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 41
- Durable-milestone and successor-run assertions: 37 passed
- Run-policy activation assertions: 15 passed
- Recovery-protocol assertions: 45 passed
- Self-test assertions: 722 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Markdown local links checked: 71, with 0 missing targets
- Skill Creator validation: `Skill is valid!`
- `git diff --check`: passed
- Windows Junction fixture: created and correctly rejected as a reparse-point
  input boundary
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Real adoption fixture

The production multi-divination run remained read-only. Tests used a temporary
copy of its orchestration run and did not change project files.

The successor protocol bound two durable sources and inherited all 17/17 open
P1 findings with exact source identity, canonical ID, severity, text, and text
hash. Completion remained correctly `BLOCKED`.

## Independent acceptance

Functional candidate `e676624` was exported as a clean 60-file Skill archive
and re-attacked by the same independent Noether reviewer. The result was GREEN
with P0=0, P1=0, and P2=0.

The reviewer verified:

- archive SHA and 60/60 files against the fixed commit;
- predecessor plan/run/genesis and final journal boundary binding;
- exact active milestone, checkpoint, source/role/thread, result, disposition,
  authorization, and target-plan binding;
- rejection of missing, changed, downgraded, or cross-source inherited P1;
- rejection of P0 carry-forward, replay, duplicate/fork successor, directory
  copy, bare genesis, and unbound continuity;
- rejection of coherent re-signing attacks against four lineage fields and two
  derived source/obligation hashes; and
- two-source, 17/17-P1 adoption with completion still blocked.

The reviewer's additional attack set passed 28/28 with
`unexpected_acceptances=[]`.

## Fixed Skill archive

Functional commit:
`e676624`

Archive:
`adaptive-agent-orchestrator-v0.7.6.zip`

Archive SHA-256:
`c31e39461a50459219d6d082d9a01037e485368c5379538410f7aafd6e2c62d2`

The archive contains 60 Skill files. The independent reviewer extracted it and
confirmed all 60/60 files against the fixed commit, parsed all 41 PowerShell
scripts, ran the 37-assertion milestone suite and 722-assertion full self-test
with 59 invalid cases rejected, parsed all 8 reference JSON files, and passed
Skill Creator validation.

Root README, changelog, release-note, and this validation receipt are repository
documentation and are intentionally outside the installable Skill archive.

## Boundaries

This receipt does not claim measured production Token savings. It proves the
tested contract and implementation behavior only.

The Skill does not repair platform `systemError` or missing-final behavior,
migrate business artifacts, or modify the multi-divination project. It
preserves orchestration obligations and fails closed.

The local append-only hash chain detects changes relative to retained receipts
and journal heads. It does not claim cryptographic resistance when an attacker
can rewrite the earliest retained anchor and every later event.

The Windows symbolic-link fixture was skipped because this session could not
create symbolic links. Linux and macOS were not dynamically validated.
