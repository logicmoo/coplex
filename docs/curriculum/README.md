# Curriculum: How Codex/Copilot-Style Coding Agents Work

This is a teaching track, not a reference manual (that's `../` — the six
numbered design docs). It uses `coplex` as a hands-on lab: every concept
below maps directly onto real, runnable Prolog you can trace, break, and
extend, using the deterministic `scripted` adapter so **no API key or
network access is ever required**.

## Who this is for

Students who want to understand, concretely, how tools like GitHub
Copilot's coding agent, OpenAI's Codex CLI, Anthropic's Claude Code, or
similar "AI pair programmer" products actually work under the hood --
not at the level of "it's magic," but at the level of "here is the
literal loop, here is the literal JSON, here is the literal permission
check, and here is the literal predicate that enforces it."

**Prerequisites:** basic Prolog (facts, rules, lists). SWI-Prolog
dicts (`_{key:value}`) are used throughout `codex_harness.pl`; you'll
pick them up from the examples even if you haven't used them before.

## How to follow along

Everything in this track can be typed at a `swipl` top-level from the
repository root. The `scripted` adapter (see
[02-anatomy-of-a-turn.md](02-anatomy-of-a-turn.md)) is a fully
deterministic stand-in model: you supply its exact replies up front
(`mock_replies`), so every example below is 100% reproducible -- run it
yourself, don't just read it.

```
swipl
?- [prolog/coplex/codex_harness].
```

Turning on `?- debug(codex_harness).` before a run prints every
internal event (`run_start`, `model_request`, `model_response`,
`tool_start`, `tool_finish`, `final_answer`) as it happens -- use this
liberally while working through the labs.

## Syllabus

| # | Lesson | Type | What you'll understand |
|---|---|---|---|
| 1 | [What Is a Coding Agent?](01-what-is-a-coding-agent.md) | Concept | The agent loop (a.k.a. ReAct / "tool calling"): why it exists, and why the model never touches the real world directly. |
| 2 | [Anatomy of a Turn](02-anatomy-of-a-turn.md) | Concept + worked example | The exact Request/Reply dicts, message history, and control flow of one loop iteration. |
| 3 | [Tools Are a Contract](03-tools-are-a-contract.md) | Concept | Tool schemas, the tool-call wire format, and defensive parsing. |
| 4 | [How File Editing Works](04-how-file-editing-works.md) | Concept + mini lab | Whole-file rewrite vs. diff/patch editing, why real agents prefer patches, atomic writes, and all-or-nothing hunk application. |
| 5 | [Planning and Todo-List Tracking](05-planning-and-todo-tracking.md) | Concept + lab | Why long-horizon agents need an explicit, persistent plan instead of relying on scrollback -- and how to add a `todo_write` tool. |
| 6 | [MCP and External Tools](06-mcp-and-external-tools.md) | Concept | The Model Context Protocol: dynamic, third-party tool discovery, and how it compares to this harness's tool table. |
| 7 | [Lab: Trace a Run](07-lab-trace-a-run.md) | Lab | Enable debug logging and narrate a real scripted run turn by turn. |
| 8 | [Lab: Build a Tool](08-lab-build-a-tool.md) | Lab | Add a brand-new, stateless tool end-to-end, with a test. |
| 9 | [Connecting a Real Model](09-connecting-a-real-model.md) | Concept + lab | The adapter pattern: how the loop stays provider-agnostic, and how to wire up a real LLM API. |
| 10 | [Subagents and Orchestration](10-subagents-and-orchestration.md) | Concept | Fan-out/fan-in multi-agent concurrency. |
| 11 | [Glossary and Further Reading](11-glossary-and-further-reading.md) | Reference | Terms, and where the ideas above come from in the wider literature/industry. |

Suggested pacing: 1-4 in one sitting (they build on each other), then
5-6 together (both are about "what's beyond the basic loop"), then the
two labs (7-8) hands-on, then 9-10 as a second session. 11 is a
standing reference.

A note on permissions: a harness instance *can* be configured with
gates around shell/network/writes (see
[`../03-tools-and-permissions.md`](../03-tools-and-permissions.md) if
you're curious), but that's an operations concern, not part of how the
loop works. Every example in this track assumes you've already granted
full permissions (`allow_shell(true), allow_network(true)`, default
writable/readable paths), so you can focus on the loop itself instead
of on what's turned on or off.
