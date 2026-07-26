# Release validation receipt

Release: `0.7.0`
Policy version: `0.7.0`
Date: `2026-07-27`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

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

pwsh -NoProfile -File "$skill\scripts\Test-Self.ps1"

python `
  "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  $skill
```

## Results

- Exit code: 0
- PowerShell scripts parsed: 25
- Self-test assertions: 515 passed
- Intentional invalid-plan negative cases: 50 correctly rejected
- Strict reference JSON files parsed: 7
- Skill Creator validation: `Skill is valid!`
- Windows Junction fixture: created and correctly rejected as a reparse-point
  input boundary
- Symbolic-link fixture: skipped because this Windows session did not permit
  symbolic-link creation

The release was validated from the repository Skill directory. The tests
cover deterministic mode/model selection, capacity isolation, strict JSON,
real-path boundaries, Worker packets, project knowledge control, lifecycle,
journal recovery, handoff, completion gates, retry authorization,
reconciliation calibration, non-materializing dispatch preview,
Worker-packet injection of the output-as-data policy and provenance labels,
and result-receipt verification before durable-task archive. The Worker-output
policy is enforced by main-agent review, not by parsing free-form text as a
security sandbox.

The release also covers the successful-create/returned-task-ID retry guard,
platform-independent write-scope overlap comparison, and read-only run
measurement. Linux path behavior is source-guarded but not execution-verified
because Linux PowerShell 7 is not installed in the available WSL environment.

This receipt does not claim measured production Token savings. Synthetic and
local validation prove contract and implementation behavior, not a universal
end-to-end savings percentage. GitHub publication is verified separately after
the release is created.
