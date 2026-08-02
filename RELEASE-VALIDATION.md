# Release validation receipt

Release: `0.7.18`
Policy version: `0.7.6` (unchanged)
Date: `2026-08-02`

## Scope

v0.7.18 closes append-only durable-review recovery gaps accumulated after
v0.7.17 and makes structured lifecycle-correction mode/source identity exact.
The final case fix changes PowerShell comparisons from case-insensitive matching
to ordinal case-sensitive matching across authorization, correction event,
receipt readback, and revision selection.

The release also documents a task-shaped company organization. The invoking
Agent leads the current task; simple work stays one layer, while complex or
multi-project work may add project leads and isolated executors. Executors ask
upward for staffing. Luna is the ordinary execution tier, Sol handles complex
leadership and formal review, Terra is non-default, and Ultra needs explicit
per-node approval. Writers use isolated worktrees and are retired after safe
integration.

## Fixed candidate

- Case-fix parent: `66c5f06be775ccf79d0229bf0eef7323e67ebdc6`
- Case-fix commit: `5deda9151ef5f5303d278fe417330c2950bbcb5d`
- Dynamic-organization docs commit: `9c5622106b2b783b488d64f84d0a41b0a38ef3c8`
- Release archive: `adaptive-agent-orchestrator-v0.7.18.zip`
- Release archive SHA-256:
  `4c64b83155f9e833d8fbfa8e60d9791209f9f1f83a7ff4bab7a3c8e042a929d5`
- Installable Skill files: 76
- Source/install comparison: 76/76; missing/extra/different = 0/0/0

## Gates

- PowerShell scripts parsed: 57/57
- Durable milestone assertions: 359 passed
- Recovery assertions: 91 passed
- Materialization assertions: 45 passed; 13 negative cases passed
- Run-policy assertions: 15 passed
- Self-test assertions: 1100 passed
- Intentional invalid cases: 60 rejected
- Reference JSON files: 8/8 parsed
- Skill Creator: `Skill is valid!`
- `git diff --check`: passed
- Symbolic-link fixture: skipped because this Windows session denied creation

The exact lowercase `single_source_omission` path and its selection continue to
pass. Case variants, surrounding whitespace, and Unicode lookalikes for mode or
omission source are rejected before write while journal count, head, file SHA,
and correction-receipt inventory stay unchanged.

## Installed copy

- Install path:
  `C:\Users\Administrator\.codex\skills\adaptive-agent-orchestrator`
- Backup:
  `C:\Users\Administrator\Documents\skills设计\backups\adaptive-agent-orchestrator-before-v0718-20260802-225104`
- Source/install comparison: 76/76; missing/extra/different = 0/0/0
- Installed parse57, JSON8, Skill Creator, Milestone359, Recovery91,
  Materialization45/negative13, Policy15, and Self1100/invalid60 passed.

## Boundaries

- Only public Codex GPT routes are documented.
- This release does not repair platform `systemError` or make business findings.
- It does not weaken open P0/P1 or final main-owner acceptance gates.
- It does not embed a fixed two-project hierarchy.
- Linux/macOS were not dynamically validated.
