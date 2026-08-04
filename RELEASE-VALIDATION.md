# Release validation receipt

Release: `0.7.19`
Policy version: `0.7.6` (unchanged)
Date: `2026-08-04`

## Scope

v0.7.19 adds a goal-first, plain-language user layer. Users describe the
outcome they want; simple work stays direct, while a useful complex split is
explained without requiring orchestration vocabulary. Internal ownership,
worktree, recovery, receipt, hash, review, and completion controls are unchanged.

## Fixed candidate

- Functional candidate: `983a9d83619247ae261ca2b9bd83ddef2bd37310`
- Release-preparation commit: `75110a9f067baa2741152867265e4baf3e60c3cf`
- Release archive: `adaptive-agent-orchestrator-v0.7.19.zip`
- Release archive SHA-256:
  `207cd873a09082ef74b7526fdc63f9c7e0b99b262002fb5fc2452b5b329bb366`
- Installable Skill files: 76
- Git/archive path comparison: 76/76; missing/extra = 0/0

## User validation

- ChatGPT Pro ordinary-user simulation: PASS; P0/P1 = 0/0.
- Isolated simple Excel-formula first response: passed without delegation.
- Isolated personal-finance web first response: passed with a plain-language
  two-part proposal and one confirmation.
- Deferred P2: the README first screen remains engineering-oriented. It does
  not block this goal-first quick-start update.

## Gates

- PowerShell scripts parsed: 57/57
- Durable milestone assertions: 359 passed
- Recovery assertions: 91 passed
- Materialization assertions: 45 passed; 13 negative cases passed
- Run-policy assertions: 15 passed
- Thread-capture assertions: 13 passed
- Self-test assertions: 1105 passed
- Intentional invalid cases: 60 rejected
- Reference JSON files: 8/8 parsed
- Skill Creator: `Skill is valid!`
- `git diff --check`: passed
- Source, staged-diff, and archive prohibited-provider/key scans: 0/0/0
- Symbolic-link fixture: skipped because this Windows session denied creation

## Boundaries

- Only public Codex GPT routes are documented.
- No lifecycle, recovery, receipt, hash, ownership, review, or completion gate
  changed.
- No multi-divination file or workflow changed.
- Linux/macOS were not dynamically validated.
