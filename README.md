# Adaptive Agent Orchestrator

[简体中文](README.zh-CN.md) · [v0.7.1 release notes](docs/releases/v0.7.1.md) · [Release history](docs/releases/README.md) · [Installation](#installation) · [How it works](#how-it-works) · [Limitations](#current-limitations)

![Adaptive Agent Orchestrator v0.7.0 launch visual](docs/assets/adaptive-agent-orchestrator-v0.7.0-launch.png)

`adaptive-agent-orchestrator` improves research, coding, writing, analysis,
creative, and operational work. The main agent remains a core producer while
bounded subagents or durable tasks isolate only the work that can be completed
and verified with less context.

The goal is lower total task Token use. Users do not configure a Token budget,
and the Skill does not pretend it can predict the total cost of an open-ended
task. Savings must be demonstrated by fair end-to-end benchmarks.

## Why use it?

- **Less context duplication:** workers receive paths, source IDs, artifact
  pointers, and selected excerpts instead of repeated full conversations.
- **Bounded context selection:** project-wide placeholder references are
  rejected; optional selection diagnostics stay in the controller, not worker
  prompts.
- **Progressive disclosure:** the Skill body stays compact; references and
  project files are read only when a workstream needs them.
- **Single-agent by default:** small, sequential, high-overlap, and narrow-edit
  tasks remain in the main agent.
- **Durable work when it pays:** independent, bounded, checkable work that can
  use smaller context or a lower-cost model is proposed as a visible durable
  Codex task instead of silently staying in the expensive main context.
- **Dynamic work ownership:** the main agent owns the global spine and final
  integration, then re-evaluates delegation only at meaningful task events.
- **Zero to two first-wave Workers:** dispatch none for simple work, one for
  one isolated lane, or two only when both are ready and context-disjoint.
- **Isolated context by default:** native subagents receive compact packets and
  stable references rather than full inherited conversation history.
- **Direct-worker fast path:** one temporary read-only worker does not require
  a durable plan, journal, stored role, or miniature lifecycle.
- **Visible role activation:** every Worker is explained before creation and
  reported after materialization; choosing a role never forces a Worker.
- **Creation reconciliation:** every background creation call is reconciled
  against the visible task list. Unknown state does not trigger blind retry,
  and duplicate materializations are detected before expansion continues.
- **Result collection gate:** required independent-background results must be
  explicitly read and recorded in a hash-bound receipt before completion.
- **Untrusted-result boundary:** the main-agent control policy treats Worker
  outputs as untrusted data, never direct authorization; verified, inferred,
  and assumed findings have different review and adoption rules.
- **Receipt-bound archive:** a durable background task cannot be archived after
  its collected result receipt disappears or changes.
- **Pre-dispatch inspection:** preview role, topology, model, permissions,
  reference count, and initial packet characters before durable
  materialization without presenting characters as Tokens or money.
- **Platform observation calibration:** append de-identified reconciliation
  intervals inside a project and group diagnostics by runtime environment
  while suppressing window advice that current evidence cannot support.
- **Protected active capacity:** target six active Workers while keeping two
  transient-subagent slots available beside four active persistent Workers;
  actual capacity is clamped to the runtime.
- **Static model routing:** Luna handles bounded mechanical work; Sol handles
  judgment, writing, implementation, and review. Terra remains
  explicit-request-only, and no benchmark Agent is launched before work.
- **Deterministic modes:** `auto` resolves to a lightweight quick path,
  independent team, or recoverable workflow without another routing Agent.
- **Reusable research evidence:** an on-demand curator builds a source
  registry only when multiple downstream workstreams will reuse it.
- **On-demand professional roles:** built-in industry role packs expose only
  the selected contract and can expand without bloating every Worker prompt.
- **General producer ownership:** specialists may own bounded sections,
  modules, investigations, datasets, or design surfaces while the main agent
  preserves the global spine and final delivery.
- **Lightweight project knowledge:** durable projects may reuse sourced
  decisions, verified facts, interfaces, and unresolved risks; one-off work
  creates no knowledge store.
- **Explicit role lifetime:** task, project, and user-owned roles cannot be
  silently conflated; user-owned reusable roles are never auto-downgraded.
- **Risk-based review:** low-risk work skips a reviewer; medium-risk work
  samples critical output; high-risk work may use one independent reviewer.
- **Delta retry:** retries carry the previous-output pointer, failure evidence,
  and repair instruction rather than replaying the full packet; delta mode is
  accepted only for the same node in a hash-checked failed run, and an
  every deterministic Worker failure requires event-bound user authorization
  before another Worker launch.
- **One controller:** workers cannot recursively create workers.
- **Recoverable execution:** immutable plans, hash-chained events, handoffs
  only when resume/reuse needs them, write-scope checks, and completion gates.

## Design inputs

v0.4 adopts narrow mechanisms from primary GitHub sources:

- [Agent Skills specification](https://github.com/agentskills/agentskills):
  metadata → Skill body → resources-on-demand progressive disclosure;
- [OpenAI Skill Creator](https://github.com/openai/skills/blob/main/skills/.system/skill-creator/SKILL.md):
  keep only task-essential instructions in the Skill and execute scripts
  without loading them into model context;
- [Supabase Agent Skills guidance](https://github.com/supabase/agent-skills/blob/main/AGENTS.md):
  make every paragraph justify its Token cost and move advanced detail into
  references;
- [Superpowers parallel-agent guidance](https://github.com/obra/superpowers/blob/main/skills/dispatching-parallel-agents/SKILL.md):
  dispatch only independent domains and isolate worker context;
- [Acontext](https://github.com/memodb-io/Acontext): retrieve explicit skill
  files on demand instead of injecting opaque memory into every context;
- [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex): treat economy
  routing as a product concern.

We intentionally do not copy long mandatory reasoning rituals, live DAG
rewrites, reviewer ensembles, full-log replay, or user-facing Token budgets.
GPT-5.6 already performs ordinary decomposition and tool choice; repeating
those instructions increases overthinking and context cost.

## Included files

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md          # compact runtime policy
├── agents/           # Codex presentation metadata
├── references/       # contracts loaded only when relevant
└── scripts/          # deterministic validation, state, and diagnostics
```

## Installation

Ask Codex:

```text
$skill-installer install https://github.com/Gabrielzzh/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

Restart Codex after installation. Manual installation copies the complete
`skills/adaptive-agent-orchestrator` directory into
`$HOME/.codex/skills/adaptive-agent-orchestrator`.

PowerShell 7.5 or later is required for the deterministic scripts.

## Quick start

```text
Use $adaptive-agent-orchestrator only if this migration contains genuinely
independent workstreams. Keep shared context in the main agent, give workers
references instead of copied content, and dispatch progressively.
```

```text
Use $adaptive-agent-orchestrator to create a custom demand-forecasting reviewer
role. Help me define its identity, non-goals, evidence rules, questions, and
escalation conditions before dispatch.
```

```text
Use $adaptive-agent-orchestrator for this supply-chain study. Show the compact
role map first, explain which responsibilities stay with the main agent, and
ask before creating any Worker I have not auto-authorized.
```

```text
Use $adaptive-agent-orchestrator to recover this interrupted workflow from its
plan and event journal without replaying failed context.
```

## Compared with official Codex subagents

Official Codex subagents are the execution primitive. This Skill is a
context-efficiency and governance layer above that primitive; it does not
replace the official feature.

| Capability | Official subagents | Adaptive Agent Orchestrator |
| --- | --- | --- |
| One-off delegation | Built in and simpler | Stays out of the way |
| Context selection | Controller judgment | Reference-first inputs, exclusions, overlap check |
| Dispatch timing | Prompt-driven | Dynamic ownership, zero to two independent first-wave Workers |
| Review | Controller judgment | Risk-only or sampled; no default reviewer ensemble |
| Retry | Session-dependent | Delta repair packet and failure-class rules |
| Write ownership | Prompt/sandbox dependent | Rejects overlapping writer scopes |
| Recovery | Thread history and summaries | Hashed plan, append-only journal, immutable handoff |
| Completion | Main agent consolidation | Node, artifact, evidence, and human-gate checks |
| Token savings | Not automatically measured | Offline end-to-end benchmark gate |

Use official subagents directly for short, obvious delegation. Use this Skill
when coordination itself creates risk or repeated context.

## How it works

```text
request
   ↓
main agent claims the global spine and productive work
   ↓
find independently checkable work that needs less context
   ↓
start zero to two context-disjoint first-wave Workers
   ↓
main agent keeps producing and validates Worker evidence
   ↓
optional later wave only when it adds new accepted value
   ↓
risk-based review + main-agent integration
   ↓
artifact/evidence/human-gate completion checks
```

The scripts validate structure and lifecycle state. The Codex controller still
selects available execution tools, materializes workers, reads real thread
state, integrates results, and performs authorized external actions.

## Validation

The v0.7.1 release passes:

- PowerShell parser validation for all 28 scripts;
- 535 self-test assertions;
- 50 intentionally invalid negative-test plans correctly rejected;
- plan, metadata, journal, handoff, dependency, idempotency, ownership,
  context-overlap, progressive-dispatch, short-packet, durable-task selection,
  queued setup, worktree preflight, task receipt, and completion tests;
- strict JSON parsing and a real Windows Junction/reparse-point fixture;
- a synthetic single-case benchmark test.

Run:

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## Current limitations

- This is a governance Skill, not a standalone agent host.
- Natural-language exclusions cannot erase history already injected by a host;
  use fresh workers and explicit input references.
- Exact context-overlap checks cannot detect two differently named references
  that contain the same semantics; the main agent must still reject them.
- Separate projects do not share a machine-level calibration ledger. The
  controller enforces the root-task Worker ceiling and must reconcile visible
  state after recovery.
- Calibration records snapshot-observation intervals, not exact platform
  visibility latency.
- Token usage is diagnostic only when the execution surface exposes it.
- The 20% median savings target is a release benchmark target, not yet a
  production claim. Synthetic tests do not prove real Token savings.
- Windows 10 with PowerShell 7.6.3 is verified; macOS and Linux are not yet.

## Security model

The Skill rejects recursive delegation, overlapping writer scopes, unsafe
paths, forged run metadata, journal tampering, unverified handoff hashes, and
human-gate completion without recorded user evidence. External publication,
deletion, payments, account changes, and production operations remain
controller-owned and require user authority.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Reproducible failure cases and compact
tests are preferred over broad feature requests.

## License

MIT. See [LICENSE](LICENSE).
