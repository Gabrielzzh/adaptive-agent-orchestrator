# Release validation receipt

Release: `0.7.5`
Policy version: `0.7.5`
Date: `2026-07-30`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Scope

v0.7.5 fixes two verified behaviors:

1. a long-lived durable review run can activate the next milestone declared by
   its immutable plan and select exact milestone-bound source chains; and
2. multiple typed evidence pointers accidentally joined into one CLI string are
   rejected before the immutable journal is written.

Milestone activation binds the prior journal head, current milestone,
source/thread/checkpoint identities, result and disposition receipts, and
acceptance authority/evidence. Each activated milestone requires a fresh
main-owner acceptance. Earlier main validation, another source, an unresolved
P0/P1 finding, or a coherently re-signed acceptance tail cannot satisfy it.

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

## Repository results

- Exit code: 0
- PowerShell scripts parsed: 38
- Durable-milestone assertions: 19 passed
- Run-policy activation assertions: 15 passed
- Recovery-protocol assertions: 45 passed
- Self-test assertions: 704 passed
- Intentional invalid negative cases: 59 correctly rejected
- Strict reference JSON files parsed: 8
- Markdown links checked: 81, with 0 missing local targets
- Skill Creator validation: `Skill is valid!`
- `git diff --check`: passed
- Windows Junction fixture: created and correctly rejected as a reparse-point
  input boundary
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

## Independent acceptance

Functional candidate
`17963d2401f21f7e4724d110e1d7533d0507dfd7` was exported as a clean
57-file Skill archive and re-attacked by the same independent Noether reviewer.
The result was GREEN with P0=0, P1=0, and P2=0.

The reviewer dynamically verified:

- baseline compatibility and exact active-milestone selection;
- rejection of mtime/latest-file guessing, skipped or duplicate activation,
  source/checkpoint substitution, receipt tampering, and cross-source replay;
- rejection of earlier main `validated` state for a later milestone;
- rejection of acceptance when any active P0/P1 remains;
- pre-binding of main owner, acceptance key, evidence path, evidence hash, and
  authorization material in the activation receipt;
- rejection when an attacker changes and coherently re-signs only the
  acceptance receipt and journal tail;
- rejection when activation, authorization, or evidence content changes; and
- one legal anchored acceptance path.

The reviewer's additional attack set passed 30/30. The previously verified
comma-joined evidence fix from `bc23ef8` remains included.

## Final Skill archive

Release-preparation commit:
`45667080afb8db7ff293276a28a65886d11c45cb`

Skill tree:
`96ef2ef2dbad211a4618d3073a4ab529997a64b9`

Archive:
`adaptive-agent-orchestrator-v0.7.5.zip`

Archive SHA-256:
`73eeadb30b5dcae475cabb8bfa4f21d77119ca9f1596195ebd907207aa030924`

The archive has 61 ZIP entries, including directory entries, and 57 files.
Git for Windows exported text with CRLF line endings. After CRLF normalization,
all 57/57 extracted files match the Git blobs from the recorded Skill tree.

The archive was extracted into a clean directory and passed the same 38-script
parser, 19-assertion milestone suite, 15-assertion policy suite, 45-assertion
recovery suite, 704-assertion self-test with 59 rejected invalid cases, strict
parsing of 8 JSON references, and Skill Creator validation.

## Boundaries

This receipt does not claim measured production Token savings. It proves the
tested contract and implementation behavior only.

The Skill does not repair platform `systemError` or missing-final behavior,
migrate business artifacts, or modify the multi-divination project. It
preserves evidence and fails closed.

The local append-only hash chain detects changes relative to the retained
activation and journal head. It does not claim cryptographic resistance when an
attacker can rewrite the earliest activation and every later journal entry
without an externally retained head/hash anchor.

The Windows symbolic-link fixture was skipped because this session could not
create symbolic links. Linux and macOS were not dynamically validated.
