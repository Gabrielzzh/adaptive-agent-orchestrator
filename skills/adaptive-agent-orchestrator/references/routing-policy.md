# Routing policy

## Decision axes

Do not compare all mechanisms on one axis.

| Axis | Choices | Governing question |
| --- | --- | --- |
| Topology | main, native subagent, durable thread | Where should the work and history live? |
| Workflow | direct, parallel, pipeline, DAG, loop, race, human gate | How do results and decisions depend on one another? |
| Compute | model class and reasoning effort | How much capability is justified for this node? |

The main agent is always the only orchestrator and a core producer. It owns the
global spine, high-coupling work, final integration, and user-facing delivery.
Do not create a persistent Router Agent.

## Model-native minimum

Do not duplicate capabilities the host model already supplies. The Skill should
decide and enforce only what needs a durable or deterministic guarantee. Keep
decomposition, prompt phrasing, and ordinary tool choice implicit unless a
failure makes one of them material.

Avoid live DAG rewriting, reviewer ensembles, repeated dynamic role creation,
and model-facing full journal replay. Each adds another reasoning loop without
a default economic case.

## Modes and verification profiles

Do not create a worker until
[context-efficiency.md](context-efficiency.md) clears the plan. Do not predict
a task-total Token budget. Reduce total use by limiting duplicated context,
unnecessary workers, repeated reviews, full-packet retries, and transcript
replay.

Resolve `auto` once with `Resolve-OrchestrationPreset.ps1`; never create a
Router Agent. `quick` keeps work in the main agent or one temporary read-only
Worker. `team` is for at least two independent workstreams. `workflow` is for
recovery, stage dependencies, multiple writers, or an approval gate.

Profiles control verification, not team size:

| Profile | Review strategy |
| --- | --- |
| `lean` | `risk-only` |
| `balanced` | `sampled` |
| `quality` | `always`, meaning one independent critical quality gate |

Do not expose a mode-by-profile configuration matrix to ordinary users.

## Effort scaling

Scale the team to the question before selecting a topology:

- a single lookup, small fix, or one-source summary: main agent only, zero
  Workers;
- a direct comparison or one bounded independent verification: at most one
  Worker alongside continuing main-agent production;
- genuinely divisible breadth with independent deliverables and disjoint
  selected context: start within the first-wave limit and expand only through
  progressive dispatch after adopted results.

Each isolated Worker adds coordination and context cost, so its deliverable
must provide value that a low-cost main-agent pass would not. When uncertain,
start one level lower. Give every Worker an explicit objective, deliverable,
and boundary; vague mandates produce duplicated or tangential work.

## Topology selection

Choose `main` when any of these dominates:

- coordination is likely larger than the independently useful work;
- most workers would receive substantially the same input context;
- the task is strongly sequential;
- one small write surface cannot be isolated;
- external or irreversible action is central;
- available agent tools cannot be verified.

Choose `native-subagent` when all are true:

- the work is temporary and bounded;
- a concise result can return to the current task;
- durable independent history is unnecessary;
- the node has a clear acceptance test.

Choose `background-thread` when any are true:

- independent history, pinning, or recovery matters;
- the task is long-running or has a separate workspace;
- explicit per-worker routing or lifecycle inspection is required;
- a bounded, independently checkable workstream can use materially smaller
  context or a lower-cost model and the user authorizes a visible durable task.

When the last condition holds, proactively recommend the durable task instead
of silently retaining every workstream in the main agent. A recommendation is
not creation authority: user-owned tasks still require an explicit thread
request or confirmation. Use a native subagent only when the work is temporary,
read-only, and a separately visible history is not useful.

A persistent role alone does not justify a persistent thread. Preserve role
identity in its contract; choose a background thread only when the workstream
history, recovery, or cross-turn execution itself must persist.

## Model and effort classes

Use capability classes in plans so the skill remains portable:

| Class | Intent |
| --- | --- |
| `economy` | extraction, classification, formatting, broad scans |
| `standard` | normal implementation, research, drafting, testing |
| `strong` | architecture, ambiguous debugging, adversarial review |
| `ultra` | one exceptional escalation or final high-risk adjudication |

Resolve a class to a currently available model with
`Resolve-WorkerModel.ps1`. The Codex binding and supported execution surfaces
are defined in [platform-codex.md](platform-codex.md). Experimental models are
explicit-request-only: never select one automatically or as a fallback, and
never invent an unavailable model ID. An escalation to a stronger class, an
effort increase, or an unavailable-model substitution requires user
confirmation unless the user granted a bounded automatic-escalation policy.
Ultra always requires explicit
per-node confirmation. Pass the confirming `user:` message pointer or verified
`policy:path:` file into the resolver; a boolean switch cannot self-authorize
an upgrade. A `user:` pointer remains a controller-checked audit reference,
not cryptographic proof. A `policy:path:` pointer must resolve to an existing,
safe project-relative file. Retry resolution reads the prior failed node's
actual model from its validated immutable journal and its effort from the
sealed plan; callers cannot supply either value directly.

Do not inherit the main agent's model as a default. If the selected capability
model is unavailable, keep the work in the main agent or request confirmation
for a model actually exposed by the destination. Do not silently escalate a
mechanical node to a high-cost model.

`ultra` requires all of the following:

- the selected surface and model actually support it;
- the plan states a concrete quality reason;
- `limits.max_ultra_nodes` has remaining capacity;
- the node is read-only; v0.4 does not permit Ultra writers;
- the node cannot delegate or orchestrate;
- the user explicitly requested Ultra for this node.

Ultra is a reasoning allocation, not permission to create more agents.

## Default limits

Use stricter project instructions when present.

```text
max_concurrent_nodes: 6
max_total_agent_nodes: 8
persistent_active_limit: 4
transient_reserved_slots: 2
max_new_nodes_per_wave: 2
max_attempts_per_node: 2
retry_reserve: 1
verification_reserve: 1
max_ultra_nodes: 1
max_agent_depth: 1
max_graph_depth: 6
max_dynamic_nodes: 1
max_forks: 0
```

At least one verification slot is mandatory for a high-risk run. A
multi-artifact run reserves verification only when cross-artifact consistency
is a material risk. Low-risk lean runs set `verification_reserve` to zero.
A worker may never consume a reserved slot without a revised, validated plan.

These are safety ceilings, not targets. Start zero Workers when delegation
would not reduce duplicated reading, elapsed time, or material risk. Wave 1 may
start one Worker, or two when both are ready and own disjoint context. In lean
mode, do not use speculative races and do not allocate a reviewer to merely
summarize or approve another worker.

The six active slots are a target, not a platform promise. Clamp
`max_concurrent_nodes` to the runtime child capacity. At most four active
background-thread Workers may run, leaving two slots for native subagents.
Registered but idle roles or threads do not consume active slots. A persistent
Worker may borrow a transient reserve only after explicit user approval.
Before any launch, call `Resolve-WorkerCapacity.ps1` with the observed active
persistent and transient counts. This is the cross-run admission check; a
single durable journal can enforce only its own run.

`max_total_agent_nodes` is a separate cumulative materialization ceiling,
including direct, durable, later-wave, and retry Workers. The deterministic
journal enforces it within one run; separate runs do not share a ledger. An
ambiguous or failed creation receipt remains pending until task-list
reconciliation proves whether a Worker materialized.

## Escalation ladder

1. Check whether the task packet, inputs, and acceptance test were defective.
2. Send one bounded clarification to the same materialized worker.
3. Retry once with a stronger effort/model or let the main agent take over.
4. Use Ultra only when its gate is satisfied.
5. Stop when the evidence says the plan is wrong or a wave adds no new value;
   do not complete the original graph merely because it exists.

Do not retry missing inputs, malformed packets, permission failures, or
unavailable tools with a stronger model. Correct the input or return to the
main agent.
