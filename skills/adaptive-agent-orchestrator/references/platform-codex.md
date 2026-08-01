# Codex platform adapter

Read this file only when selecting a concrete Codex model, choosing between a
native subagent and a user-owned Codex task, or handling platform-specific
creation and collection failures. General policy uses capability classes; this
file binds those classes to the current Codex surface.

## Model binding

| Class | Default Codex model / effort |
| --- | --- |
| `economy` | `gpt-5.6-luna` / `medium` |
| `standard` | `gpt-5.6-luna` / `max` |
| `strong` | `gpt-5.6-sol` / `high` |
| `ultra` | `gpt-5.6-sol` / `ultra` |

Use `standard` for bounded ordinary execution where Luna's lower-cost route is
appropriate and `max` effort preserves reasoning depth. Formal domain/dissent
review, adversarial acceptance, architecture, and ambiguous debugging use at
least `strong`; a standard node cannot silently become a durable reviewer.
Overriding an `economy` or `standard` Luna default with Sol is an escalation and
requires the normal user or bounded-policy evidence.
The resolver enforces this for every new launch. Existing immutable plans that
were valid when `standard` defaulted to Sol remain readable; do not rewrite or
invalidate a live run merely to adopt the new cost preference.

Prefer Sol `max` over `ultra` when deeper reasoning is sufficient. In the
current runtime, Ultra also enables automatic task delegation and therefore
changes execution topology rather than merely adding one reasoning step. Use it
only as a last resort when that delegation is materially useful, the resolver
records a concrete reason, and the user explicitly authorizes that node.

`gpt-5.6-terra` remains experimental: explicit user request only, never an
automatic selection or fallback. `Resolve-WorkerModel.ps1`,
`Test-OrchestrationPlan.ps1`, and event validation implement this Codex model
contract and must be updated together if the supported pool changes. Never
invent a model ID that the runtime does not expose.

Every concrete native-subagent or durable-task launch route must come from a
current `Resolve-WorkerModel.ps1` invocation that binds this exact file through
`PlatformBindingPath`. Loading `routing-policy.md`, describing a node as
bounded, or preferring lower cost does not authorize a model. If this binding
or resolver output is missing, do not launch. Terra additionally requires the
user to request Terra explicitly and the resolver call to carry the matching
`user:` evidence; policy authorization is insufficient.

This binding is the current conservative runtime contract, not an inference
from tier names. Select directly from this table during user work: do not run a
benchmark, A/B test, or model-selection Worker first. Public benchmarks are
release-development signals only. Change the table only during a Skill release
after the offline protocol in [evaluation.md](evaluation.md) repeatedly
demonstrates improvement without a material regression.

## Execution surfaces

Use a native subagent for a subtask of the current request:

- create with `spawn_agent`;
- inspect with `list_agents`;
- collect with `wait_agent`;
- keep it temporary, non-recursive, and bounded by the current task.

If native-subagent creation reports only the requested route and agent ID,
record `actual model: unverified`. Do not claim the requested model was
observed. A later platform result may replace this label only when it exposes
the actual model explicitly.

An independent Codex task/thread is user-owned and appears separately in the
application. Create one only when the user explicitly asks for, or explicitly
confirms, that separate task lifecycle after seeing the activation preview.
Automatic teaming policy alone is not authority to create a user-owned task.
When thread tools are available:

- enumerate with `list_threads`;
- create with `create_thread`;
- collect primarily with `read_thread`;
- use `wait_threads` only as an optional bounded wait optimization.

If the user says `thread`, first resolve whether they mean this user-owned,
sidebar-visible task or merely an internal temporary worker. A request for
independent history, direct follow-up, long-lived role ownership, or a visible
task is unambiguously a user-owned Codex task and must not be downgraded to a
native subagent.

For a project task, choose the environment in this order:

1. independent writer or branch delivery: worktree, after
   `Test-CodexWorktreePreflight.ps1` confirms a Git repository and usable HEAD;
2. read-only durable research over a shared saved snapshot: local project;
3. temporary read-only work without useful independent history: native
   subagent;
4. non-Git or unborn-branch writer: main agent, or stop for a user-approved Git
   baseline.

`startingState=working-tree` may include uncommitted state but cannot replace a
base commit. One writer owns each path. If multiple local tasks would write the
same or overlapping paths, stop or switch to isolated worktrees.

If thread tools are unavailable, do not simulate a durable task with repeated
native subagents. Keep durable state in project artifacts and continue in the
main agent, or ask the user whether to create a separate task when that
lifecycle is essential.

## Preflight without throwaway Workers

Before the first dispatch on a surface, make one read-only enumeration call.
If enumeration fails, do not plan a team on that surface.

For a planned wave of two or more Workers, use the first real, low-risk,
independently useful workstream as the canary. Run it through the complete
create, reconcile, collect, and receipt path before dispatching the rest. Never
create a synthetic or disposable canary Worker solely to test the platform.

## Durable activation and reconciliation

Put the exact markers

```text
<activation_key>...</activation_key>
<source_thread_id>...</source_thread_id>
```

in every durable task prompt. If creation returns a task ID, read that ID
directly and verify the full prompt markers instead of waiting for task-list
visibility. Enumerate any remaining candidates with `list_threads`, then read
each candidate to confirm the markers; a marker mismatch must never be
declared from a list summary alone.

Make one creation call for a reserved activation key, then reconcile recent
tasks using source task, creation window, and task summary regardless of
whether the call returned success or error. A successful creation result with
a stable returned task ID may remain `unknown` if verification is unavailable,
but it must never become `no_match` and must never authorize a replacement
task.

One Codex App 26.721 forward test observed that a successfully created task was
still absent from `list_threads` nineteen seconds after creation and visible
by thirty-seven seconds. Until multiple verified samples support calibration,
use forty seconds as a provisional minimum absence-observation span for error,
timeout, or unknown creation results. This is a safety floor, not a claim that
visibility latency has been statistically calibrated. A single immediate list
miss is normal and never authorizes a retry.

- one match: adopt it;
- multiple matches: stop, archive duplicates, and record disposition;
- no match: retry only after the provisional visibility floor and immutable
  reconciliation receipt prove absence, and never when creation reported
  success with a stable returned task ID;
- unavailable or ambiguous reconciliation: stop with `unknown`.

A confirmed no-match retry uses a new attempt activation key. Never retry by
switching project scope or by editing Codex internal state stores.

A queued worktree response with only `clientThreadId` is `setup_pending`, not a
materialized task. It cannot be passed to `read_thread` or `wait_threads` and
does not count as a live Worker. Reconcile `list_threads` for the eventual real
task ID. Because the current platform exposes no client-ID setup-status reader,
a bounded observation window with no matching task becomes
`setup_failed_or_unresolved`; it never authorizes blind duplicate creation.

## Result collection

Background tasks do not push results into the parent automatically. Register
the actual task ID, collect the final turn through `read_thread`, and bind it to
`New-ThreadResultReceipt.ps1` before integration. If `wait_threads` is
unavailable, fall back once to bounded reads; do not retry the unavailable
handler. Native subagents never depend on `wait_threads`.

Save the raw `read_thread` JSON without converting its identity fields. Current
captures use `thread.id`; historical `thread.threadId` and top-level `threadId`
remain readable. If more than one form is present, every value must match
exactly or capture validation fails closed.

Poll with bounded intervals while the main agent continues its own ready work.
The first read should normally occur about thirty seconds after materialized
existence is confirmed, followed by sixty seconds and then five-minute
intervals unless the node declares another cadence. Prefer `wait_threads` when
its handler is available, but collect final evidence with `read_thread`. Do not
stream unchanged snapshots into the parent context, and do not interpret
silence as completion.

At durable-run termination, use `New-OrchestrationTaskReceipt.ps1`. Record
`completed` only after the deterministic completion gate passes. Otherwise
record `fallback-main`, `blocked`, or `cancelled` with a supported failure class
and a concrete fallback action.
