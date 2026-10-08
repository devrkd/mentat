# Rules

Cross-cutting policies shared across all agents. Skills and prompts reference these files rather than repeating the policy inline.

| File | What it governs |
|---|---|
| `approval-gate.md` | ADR human approval gate: how it works, who enforces it, state transitions |
| `cleanup.md` | `.tmp/<task-id>/` directory lifecycle: who removes what and when |
| `design-conflict.md` | How agents handle conflicts between UX/design data and ADR content |
