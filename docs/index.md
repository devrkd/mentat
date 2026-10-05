---
title: Mentat
description: A multi-agent development harness for opencode — four coordinated agents, slash commands, skills, schemas, rules, and a Slack bridge
---

# Mentat

*Mentat* is named for the human computers of Frank Herbert's *Dune* — people trained as disciplined reasoning engines — a fitting name for a harness whose coordinated agents work through hard problems under explicit human approval gates.

This repository is a **harness for a multi-agent software-development workflow** run under [opencode](https://opencode.ai/). It contains no application code — only agent definitions, slash commands, skills, schemas, rules, helper scripts, and an opencode plugin for Slack.

Four coordinated agents — **Orchestrator, Architect, Developer, Staff** — are backed by the **GitHub MCP server**:

- The **Orchestrator** classifies user intent and dispatches work to the right subagent via opencode's `task` tool.
- The **Architect** designs and produces ADRs.
- The **Developer** implements scoped functional requirements.
- **Staff** does deep read-only analysis.

A parallel Claude Code harness is retained in `.claude/` for Claude Code users; opencode ignores it. The two harnesses are kept in parallel (`AGENTS.md` for opencode, `CLAUDE.md` for Claude Code).

## The four agents at a glance

| Agent | Mode | Model | Variant | Role |
|---|---|---|---|---|
| `orchestrator` | `primary` | `{env:ORCHESTRATOR_MODEL}` | `{env:ORCHESTRATOR_VARIANT}` | Classifies intent, dispatches via the `task` tool, never edits product code |
| `architect` | `all` | `{env:ARCHITECT_MODEL}` | `{env:ARCHITECT_VARIANT}` | Design, ADR authoring, repo intel |
| `developer` | `all` | `{env:DEVELOPER_MODEL}` | `{env:DEVELOPER_VARIANT}` | Implementation only; requires a task id |
| `staff` | `all` | `{env:STAFF_MODEL}` | `{env:STAFF_VARIANT}` | Read-only cross-source analysis |

The Model / Variant columns show the env var each agent resolves at startup. `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` set the defaults for anything without a per-role entry; the per-role `*_MODEL` / `*_VARIANT` vars override them. Set these in `.env` (copy from `.env.example`) and load it into the shell (`set -a; source .env; set +a` — opencode does not auto-load `.env`), then restart opencode to apply.

Each agent is covered in depth on its page below.

## Pages

- [Agents](agents.md) — the four agents in depth, including the agents table and env-driven model mapping.
- [Commands](commands.md) — the four slash commands and how to use them.
- [Workflow](workflow.md) — the end-to-end flow, the hard gates, and branch naming.
- [Handoff](handoff.md) — the `handoff.json` contract between Architect and Developer, and the `.tmp/` lifecycle.
- [Reference](reference.md) — skills, MCP availability, shared assets, guardrails, and the two parallel harnesses.
- [Slack integration](slack-integration.md) — the Slack bridge plugin: configuration, outbound approval/question cards, and inbound steering.
