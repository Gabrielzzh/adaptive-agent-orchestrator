# Project knowledge

Use project knowledge only for durable work. Do not create it for a one-off
task.

Enable it when at least one condition is true:

- two or more workstreams will reuse the same decision, verified fact,
  interface, or unresolved risk;
- the project crosses turns, context compaction, or session rotation;
- multiple background threads need a shared verified result;
- the user explicitly requests durable project knowledge.

Store the catalog at:

```text
.orchestrator/
└── knowledge/
    ├── catalog.json
    └── INDEX.md
```

The catalog is a pointer layer, not a copied project summary. Keep only:

- `decision`;
- `verified-fact`;
- `interface`;
- `unresolved-risk`.

Each adopted entry contains a stable ID, short summary, tags, source pointers,
source hashes when the source is a local file, verification time, and optional
`supersedes`. `INDEX.md` is generated from the catalog; never maintain two
independent truths.

Workers may return `knowledge_candidates` in their result receipt. Only the
main agent may adopt, supersede, or invalidate a candidate. A Worker must not
write directly to `.orchestrator/knowledge`.

Use the deterministic manager:

```powershell
pwsh -File scripts/Manage-ProjectKnowledge.ps1 `
  -Action Initialize -ProjectRoot <project-root>

pwsh -File scripts/Manage-ProjectKnowledge.ps1 `
  -Action Adopt -ProjectRoot <project-root> `
  -Id decision-api-boundary -Type decision `
  -Summary "Keep external writes in the main agent." `
  -Tags orchestration,safety `
  -SourceRefs path:docs/architecture.md

pwsh -File scripts/Manage-ProjectKnowledge.ps1 `
  -Action Find -ProjectRoot <project-root> -Query orchestration -Limit 5

pwsh -File scripts/Manage-ProjectKnowledge.ps1 `
  -Action Validate -ProjectRoot <project-root> -RefreshStale
```

Search metadata first and return at most five records. Open original
`source_refs` only after selecting a record. A summary is navigation; the
source remains the factual authority.

When a local source hash changes, mark an adopted entry `stale`. A replacement
entry points to the old ID with `supersedes`; never silently overwrite prior
knowledge. Session rotation carries knowledge IDs and artifact pointers, not
the entire catalog or prior transcript.

Obsidian may display `INDEX.md`, but it is not a dependency. Do not add a vector
database, embedding service, memory Agent, or automatic whole-project scan.
