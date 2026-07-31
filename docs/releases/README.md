# Release history / 版本历史

This index is permanent. New releases add a row; they do not replace older
release records.

此页面永久保留。发布新版本时只新增记录，不覆盖旧版本历史。

| Version | Channel | Focus | Details |
| --- | --- | --- | --- |
| `v0.7.15` | Stable | Append-only durable-review lifecycle evidence correction | [Notes](v0.7.15.md) |
| `v0.7.14` | Stable | Durable reviewer continuity, source rotation, and materialization reconciliation | [Notes](v0.7.14.md) |
| `v0.7.13` | Stable | Historical recovery epochs and immutable review-selection replay | [Notes](v0.7.13.md) |
| `v0.7.12` | Stable | Active-milestone durable-source recovery re-entry | [Notes](v0.7.12.md) |
| `v0.7.11` | Stable | Scoped durable-review milestone progression | [Notes](v0.7.11.md) |
| `v0.7.10` | Stable | First-milestone review revisions and verified recovery re-entry | [Notes](v0.7.10.md) |
| `v0.7.9` | Stable | Per-review-cycle durable-source recovery | [Notes](v0.7.9.md) |
| `v0.7.8` | Stable | Append-only abandoned-successor recovery | [Notes](v0.7.8.md) |
| `v0.7.7` | Stable | Raw Codex `thread.id` capture compatibility | [Notes](v0.7.7.md) |
| `v0.7.6` | Stable | Auditable durable-review successor runs | [Notes](v0.7.6.md) |
| `v0.7.5` | Stable | Append-only cross-milestone durable review | [Notes](v0.7.5.md) |
| `v0.7.4` | Stable | Auditable activation of immutable older runs | [Notes](v0.7.4.md) |
| `v0.7.3` | Stable | Honest unverified model materialization and bounded replacement recovery epochs | [Notes](v0.7.3.md) |
| `v0.7.2` | Stable | Durable domain/dissent review, finding disposition, bounded missing-final recovery, authorized replacement continuity | [Notes](v0.7.2.md) |
| `v0.7.1` | Engineering milestone included in v0.7.2 | Durable-task intent, worktree preflight, queued setup, model availability, task-level receipts | [Notes](v0.7.1.md) |
| `v0.7.0` | Stable | Context-efficient delegation, reliable task materialization, static model routing, release diagnostics | [Notes](v0.7.0.md) |
| `v0.6.0` | Stable | General work ownership, isolated context, lightweight project knowledge | [Notes](v0.6.0.md) |
| `v0.5.1` | Stable | Thread reconciliation, result receipts, deterministic retry guard | [Notes](v0.5.1.md) |
| `v0.5.0` | Stable | Deterministic modes, model routing, protected 4+2 active capacity, reusable research evidence | [Notes](v0.5.0.md) |
| `v0.4.2-beta.1` | Prerelease | Visible role activation, compact industry role packs, manuscript co-authorship | [Notes](v0.4.2-beta.1.md) |
| `v0.4.1-beta.1` | Prerelease | Context selection, opt-in handoffs, progressive dispatch | [Changelog](../../CHANGELOG.md#041-beta1---2026-07-18) |
| `v0.4.0-beta.1` | Prerelease | Main-agent fast path, reference-first context, delta retry | [Changelog](../../CHANGELOG.md#040-beta1---2026-07-18) |
| `v0.3.0-beta.1` | Prerelease | Durable workflow contracts, recovery, lifecycle validation | [Changelog](../../CHANGELOG.md#030-beta1---2026-07-18) |

## Versioning policy / 版本规则

- Follow semantic versioning while the public contract evolves.
- Releases without a suffix are stable-channel releases.
- `-alpha`, `-beta`, and `-rc` are reserved for builds that still require
  prerelease validation.
- Every release keeps a Git tag, GitHub Release, changelog entry, and retained
  release note.
- Engineering milestones document validated development baselines folded into a
  later release; they do not claim a separate tag or GitHub Release.
- README files describe the current product and link here; they are not the
  version archive.

- 在公开契约演进期间遵循语义化版本。
- 不带后缀的版本属于正式稳定通道。
- `-alpha`、`-beta`、`-rc` 只用于仍需预发布验证的版本。
- 每个版本保留 Git 标签、GitHub Release、CHANGELOG 条目和独立版本说明。
- 工程里程碑记录已验证、随后并入正式版的开发基线，不代表单独发布了标签或
  GitHub Release。
- README 介绍当前产品并链接到这里，不承担版本档案功能。
