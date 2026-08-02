# Adaptive Agent Orchestrator

[简体中文](README.zh-CN.md) · [v0.7.18 release notes](docs/releases/v0.7.18.md) · [Release history](docs/releases/README.md) · [Installation](#installation) · [How it works](#how-it-works) · [Limitations](#current-limitations)

![Adaptive Agent Orchestrator v0.7.0 launch visual](docs/assets/adaptive-agent-orchestrator-v0.7.0-launch.png)

`adaptive-agent-orchestrator` improves research, coding, writing, analysis,
creative, and operational work. The Agent that invokes the Skill owns the
current task: it understands the goal, splits independent workflows, and
chooses the required hierarchy, roles, and models. Simple tasks may stay in one
layer; complex tasks may form a project lead -> executors, while multiple
project leads are reserved for multiple projects.

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
- **Single-layer by default:** small, sequential, high-overlap, and narrow-edit
  tasks remain with the responsible task Agent.
- **Durable work when it pays:** independent, bounded, checkable work that can
  use smaller context or a lower-cost model is proposed as a visible durable
  Codex task instead of silently staying in the expensive main context.
- **Dynamic company-style organization:** the responsible task Agent creates
  only the hierarchy the task needs. A project lead coordinates its project and
  executors own bounded workflows; multiple project leads appear only for
  multiple projects.
- **Upward staffing boundary:** a non-lead executor cannot recursively recruit.
  It submits a bounded request for more capacity to its immediate superior,
  who decides whether to add people and where the work belongs.
- **Writer isolation and cleanup:** every writer uses an independent worktree.
  After completion, the responsible task or project owner verifies and adopts
  the result, archives the completed task, and cleans the worktree and temporary
  artifacts.
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
- **Adjacent materialization recovery:** if a newly created task ID was recorded
  one lifecycle step early, only the immediately adjacent
  `materializing -> materialized` transition may adopt that same ID. A unique
  task-list match, activation reservation, exact handshake, and no earlier or
  cross-node use are required; conflicting task identity fields fail closed.
- **Result collection gate:** required independent-background results must be
  explicitly read and recorded in a hash-bound receipt before completion.
- **Durable review loop:** long-running research or Skill development can keep
  read-only domain and dissent roles across milestones. The responsible task or
  project owner remains accountable for adopting every captured finding.
- **Independent-source integrity:** each review source keeps its own report,
  evidence, disposition, and re-review obligation. One source cannot replace
  another, and unresolved P0/P1 findings always block completion.
- **Replacement-seat continuity:** an adopted replacement reviewer may move to a
  later checkpoint only through a one-time, same-source/role/thread
  roll-forward. If current durable reviewers can no longer provide independent
  results, one append-only source rotation carries every open occurrence into a
  fresh run with new read-only, nondelegating seats instead of reusing old tasks.
- **Cross-milestone review roll-forward:** the same durable review run can
  activate its next declared milestone through an append-only receipt. Exact
  source chains and fresh responsible-owner acceptance replace stale fixed paths
  without rewriting the plan or guessing from file timestamps.
- **Scoped finding conservation:** when the current milestone has finished its
  own scope but retains P0/P1 assigned to later stages, one pre-bound scope
  transition may advance to the next declared milestone. Every finding remains
  bound to its source, severity, and exact text unless resolved by that same
  source; stage progression is not final responsible-owner acceptance.
- **First-milestone review revisions:** before advancing to a later milestone,
  one pre-authorized revision may re-arm every required read-only source and
  select one exact set of fresh cumulative results. Older evidence remains
  retained but cannot be retroactively promoted into the selected review.
- **Cumulative inventory repair:** if a valid new checkpoint accidentally lists
  only its currently open findings, one pre-bound all-source supersession may
  mechanically restore omitted prior occurrences. It cannot change their
  source, severity, text/hash, status, or evidence, and selection can consume it
  only once.
- **Auditable successor runs:** after the final declared milestone, a new run
  can inherit every unresolved P1 through a hash-bound predecessor export and
  successor adoption. The old run stays immutable, source/thread continuity is
  preserved, and completion remains blocked until the same sources resolve and
  re-review those obligations.
- **Missing-final recovery:** a completed task without a final answer becomes
  `result_pending`, never success. Each new checkpoint/input for the same
  original durable source opens a separate hash-bound recovery cycle with at
  most three same-thread attempts; an earlier cycle cannot extend or reset a
  later one. An already adopted source may re-enter recovery only through an
  unused attempt-1 cycle for a different checkpoint/input; ordinary `adopted`
  remains terminal. If a later milestone selected a newer same-source review
  without adding another node lifecycle, re-entry binds that exact active
  result, disposition, and activation event instead of stale prior-stage
  evidence. Historical recovery receipts are revalidated against their own
  recorded milestone and activation epoch, and an immutable review revision is
  re-read by its exact recorded lifecycle sequence/hash rather than later
  same-source events. An authorized replacement must preserve source, role,
  checkpoint, input, and recovery-chain continuity. If the replacement also
  loses its final, it receives one separate bounded recovery epoch—not another
  replacement.
- **Honest legacy adoption:** older tasks can capture the role, checkpoint,
  input, observed turns, and authorization that actually exist while listing
  unavailable machine identity fields as unknown instead of inventing them.
- **Auditable run-policy activation:** a consistent older run can adopt the
  current runtime policy through an append-only receipt without rewriting its
  plan, run metadata, genesis event, or journal. Existing replacements remain
  bound to their source and continuity evidence.
- **Untrusted-result boundary:** the task-owner control policy treats Worker
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
- **Cost-aware model routing:** ordinary execution prefers Luna High/Max.
  Complex management, judgment, architecture, and formal review use Sol
  High/Max. Terra is not a default and requires an explicit user request or
  authorization. Ultra requires explicit per-node approval. Requested and
  actual models remain separate when the runtime does not expose the actual
  model.
- **Deterministic modes:** `auto` resolves to a lightweight quick path,
  independent team, or recoverable workflow without another routing Agent.
- **Reusable research evidence:** an on-demand curator builds a source
  registry only when multiple downstream workstreams will reuse it.
- **On-demand professional roles:** built-in industry role packs expose only
  the selected contract and can expand without bloating every Worker prompt.
- **General producer ownership:** the responsible task Agent owns task-wide
  integration; a project lead owns project integration; executors may own
  bounded sections, modules, investigations, datasets, or design surfaces.
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
- **Upward staffing control:** non-lead executors may request additional
  capacity only from their immediate superior and cannot recursively create an
  unlimited organization.
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
independent workstreams. Let the current Agent choose the required hierarchy,
give workers references instead of copied content, and dispatch progressively.
```

```text
Use $adaptive-agent-orchestrator to create a custom demand-forecasting reviewer
role. Help me define its identity, non-goals, evidence rules, questions, and
escalation conditions before dispatch.
```

```text
Use $adaptive-agent-orchestrator for this supply-chain study. Show the compact
role map first, explain the task and project ownership, and ask before creating
any Worker I have not auto-authorized.
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
| Context selection | Owner judgment | Reference-first inputs, exclusions, overlap check |
| Dispatch timing | Prompt-driven | Dynamic ownership, zero to two independent first-wave Workers |
| Review | Controller judgment | Risk-only or sampled; no default reviewer ensemble |
| Retry | Session-dependent | Delta repair packet and failure-class rules |
| Write ownership | Prompt/sandbox dependent | Rejects overlapping writer scopes |
| Recovery | Thread history and summaries | Hashed plan, append-only journal, immutable handoff |
| Completion | Task/project owner integration | Node, artifact, evidence, and human-gate checks |
| Token savings | Not automatically measured | Offline end-to-end benchmark gate |

Use official subagents directly for short, obvious delegation. Use this Skill
when coordination itself creates risk or repeated context.

## How it works

```text
request
   ↓
current Agent takes responsibility, understands the goal, and chooses one layer
or a project lead -> executor hierarchy
   ↓
find independent workflows and assign bounded ownership
   ↓
start only the workers that add accepted value
   ↓
responsible task/project owner validates and adopts the results
   ↓
writer worktrees are archived and cleaned by the responsible owner
   ↓
risk-based review and owner integration
   ↓
artifact/evidence/human-gate completion checks
```

The scripts validate structure and lifecycle state. The responsible task Agent
and any project leads select available execution tools, materialize workers,
read real thread state, integrate results, and perform authorized external
actions within their assigned scope.

## Validation

The v0.7.16 release passes:

- PowerShell parser validation for all 54 scripts;
- 45 materialization-continuity assertions, including 13 invalid cases;
- 91 recovery-protocol assertions;
- 149 durable-milestone, revision, and successor-run assertions;
- 15 run-policy activation assertions;
- 883 self-test assertions;
- 59 intentionally invalid negative-test cases correctly rejected;
- strict parsing for all 8 bundled reference JSON files;
- plan, metadata, journal, handoff, dependency, idempotency, ownership,
  context-overlap, progressive-dispatch, short-packet, durable-task selection,
  queued setup, worktree preflight, task receipt, durable review, result
  recovery, replacement continuity, immutable-run policy activation, and
  completion tests;
- strict JSON parsing and a real Windows Junction/reparse-point fixture;
- Skill Creator validation;
- 13 focused raw-capture compatibility assertions and an independent 27/27
  re-attack covering current `thread.id`, both historical identity shapes,
  conflicting or empty identities, case-only differences, and expected-ID
  mismatches;
- independent dynamic re-attack of predecessor export, successor adoption,
  lineage fields, source continuity, and coherent receipt re-signing, ending
  GREEN with P0=0, P1=0, and P2=0; an additional 28/28 attack set passed;
- a temporary-copy adoption test of the real durable-review run inherited
  17/17 P1 findings across two sources and remained correctly `BLOCKED`;
- two real raw Codex captures generated separate schema 1.3 result and
  disposition receipts without caller-side conversion.
- a real abandoned successor rolled forward through authorization, export, and
  fresh adoption: all 18 P1 source occurrences were preserved, consumed
  attempts carried forward, zero P0 reappeared, and completion remained
  correctly `BLOCKED`.
- a real long-lived original source opened a checkpoint08 recovery cycle
  isolated from its completed checkpoint07 cycle, recovered a same-source final,
  generated schema 1.3 result/disposition receipts, and remained correctly
  `BLOCKED` by an open business P1 and unfinished nodes.
- a real first-milestone revision re-armed the same two read-only sources after
  authorization, obtained fresh cumulative reviews, selected exactly one
  checkpoint10 result set, retained all 11 later P1 source occurrences, and did
  not revive resolved older findings. The product then advanced to its next
  group without a new Orchestrator P0/P1.
- the real 37-event run used pre-authorization to enter declared Group2. Four
  of eleven P1 occurrences were resolved by same-source review, seven remained
  open, and completion stayed `BLOCKED` by those seven findings plus missing
  final responsible-owner acceptance. P1-03 through P1-06 did not reappear.
- the real 39-event run preserved its exact prefix, then let the same traditional
  source enter checkpoint12 `result_pending` and `running` by binding the
  current Group2 result, disposition, and activation event. The original
  durable task returned a formal final; its incomplete domain review remained
  unfinished work rather than an Orchestrator success claim.
- a real later-milestone checkpoint13 recovery coexisted with valid historical
  recovery cycles and an older immutable first-milestone selection. The
  original source exhausted 3/3, one authorized same-role replacement recovered
  a formal final through its own bounded epoch, all nine occurrences remained
  open, and completion stayed correctly `BLOCKED`.
- independent source-rotation acceptance returned GREEN with P0=0, P1=0, and
  P2=0. A real active review run then carried all 7/7 open P1 occurrences into
  two fresh read-only reviewer seats without reusing any old task.
- the real fresh-review run reconciled one already-created task through the
  guarded adjacent materialization path, created only one additional reviewer,
  recovered both formal reviews through the same two tasks, and recorded
  source-specific results and dispositions. Completion stayed `BLOCKED` by the
  multi-divination product P0, seven open P1 occurrences, and missing main
  acceptance; no new Orchestrator P0/P1 was found.
- the real checkpoint15 revision appended one whole-source lifecycle evidence
  correction for two misbound `validated` events, then selected schema 1.2
  without changing either adopted source or the old 35-event prefix. Completion
  remained `BLOCKED` by one product P0, six open P1 occurrences, and missing
  main acceptance; a resolved P1 did not reappear.
- the real checkpoint16 review authorized revision index 2 from a complete,
  selected predecessor without inventing final main acceptance. Both durable
  sources returned fresh formal results and dispositions, one schema 1.1
  selection was appended, the original 37-event prefix stayed byte-identical,
  and completion remained `BLOCKED` by one open P0, five open P1 source
  occurrences, and missing final main acceptance. Two same-source findings
  resolved in this revision did not reappear.

Run:

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## Current limitations

- This is a governance Skill, not a standalone agent host.
- Lifecycle evidence correction applies only when every selected source has the
  exact `completed=result`, `validated=result`, `adopted=disposition` error
  shape. It is not a general journal-editing or lifecycle-repair mechanism.
- It does not fix platform `systemError` or missing-final failures; it prevents
  those states from being accepted as success and preserves verifiable recovery
  and replacement continuity.
- Source rotation changes reviewer seats and carries control obligations; it
  does not migrate, judge, or repair the reviewed product.
- It does not migrate business artifacts. Policy activation only authorizes the
  existing immutable run to use the newer orchestration contract.
- Successor adoption carries orchestration obligations and identities, not
  project files or business state. The successor plan must declare its own
  future milestones.
- Abandoned-successor recovery applies only before the first durable milestone
  and before any review message or result lifecycle. It creates a fresh run; it
  never revives the cancelled source in the old run.
- The local hash chain detects in-chain changes, but an attacker able to
  rewrite the earliest activation and every later journal entry still requires
  an externally retained head/hash anchor for full-history resistance.
- Natural-language exclusions cannot erase history already injected by a host;
  use fresh workers and explicit input references.
- Exact context-overlap checks cannot detect two differently named references
  that contain the same semantics; the responsible task Agent must still reject
  them.
- Separate projects do not share a machine-level calibration ledger. Each
  project lead requests additional capacity from the responsible task Agent,
  which reconciles visible state after recovery.
- Calibration records snapshot-observation intervals, not exact platform
  visibility latency.
- Token usage is diagnostic only when the execution surface exposes it.
- The 20% median savings target is a release benchmark target, not yet a
  production claim. Synthetic tests do not prove real Token savings.
- The Windows symbolic-link fixture was skipped because this environment did
  not permit link creation.
- Windows 10 with PowerShell 7.6.3 is dynamically verified; macOS and Linux are
  not dynamically verified.

## Security model

The Skill rejects recursive delegation, overlapping writer scopes, unsafe
paths, forged run metadata, journal tampering, unverified handoff hashes, and
human-gate completion without recorded user evidence. External publication,
deletion, payments, account changes, and production operations remain with the
responsible task owner or an explicitly assigned owner and require user
authority.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Reproducible failure cases and compact
tests are preferred over broad feature requests.

## License

MIT. See [LICENSE](LICENSE).
