# Codex platform adapter

Read this file only when selecting a concrete Codex model, choosing between a
native subagent and a user-owned Codex task, or handling platform-specific
creation and collection failures. General policy uses capability classes; this
file binds those classes to the current Codex surface.

## Model binding

| Class | Default Codex model / effort |
| --- | --- |
| `economy` | `gpt-5.6-luna` / `medium` |
| `standard` | `gpt-5.6-sol` / `medium` |
| `strong` | `gpt-5.6-sol` / `high` |
| `ultra` | `gpt-5.6-sol` / `ultra` |

`gpt-5.6-terra` remains experimental: explicit user request only, never an
automatic selection or fallback. `Resolve-WorkerModel.ps1`,
`Test-OrchestrationPlan.ps1`, and event validation implement this Codex model
contract and must be updated together if the supported pool changes. Never
invent a model ID that the runtime does not expose.

## Execution surfaces

Use a native subagent for a subtask of the current request:

- create with `spawn_agent`;
- inspect with `list_agents`;
- collect with `wait_agent`;
- keep it temporary, non-recursive, and bounded by the current task.

An independent Codex task/thread is user-owned and appears separately in the
application. Create one only when the user explicitly asks for, or explicitly
confirms, that separate task lifecycle after seeing the activation preview.
Automatic teaming policy alone is not authority to create a user-owned task.
When thread tools are available:

- enumerate with `list_threads`;
- create with `create_thread`;
- collect primarily with `read_thread`;
- use `wait_threads` only as an optional bounded wait optimization.

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

in every durable task prompt so visible task-list previews can be matched
without guessing. Make one creation call for a reserved activation key, then
reconcile recent tasks using source task, creation window, and task summary
regardless of whether the call returned success or error.

- one match: adopt it;
- multiple matches: stop, archive duplicates, and record disposition;
- no match: retry only after the minimum visibility window and immutable
  reconciliation receipt prove absence;
- unavailable or ambiguous reconciliation: stop with `unknown`.

A confirmed no-match retry uses a new attempt activation key. Never retry by
switching project scope or by editing Codex internal state stores.

## Result collection

Background tasks do not push results into the parent automatically. Register
the actual task ID, collect the final turn through `read_thread`, and bind it to
`New-ThreadResultReceipt.ps1` before integration. If `wait_threads` is
unavailable, fall back once to bounded reads; do not retry the unavailable
handler. Native subagents never depend on `wait_threads`.

Poll with bounded intervals while the main agent continues its own ready work.
Do not stream unchanged snapshots into the parent context, and do not interpret
silence as completion.
