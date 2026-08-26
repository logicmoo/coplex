# 11. Glossary and Further Reading

## Glossary

**Agent loop** -- the request/execute/observe cycle at the heart of
every coding agent: ask the model, execute what it asks for, feed the
result back, repeat until it returns plain text with nothing left to
do. See `run_loop/4` + `loop_steps/4`.

**ReAct** -- the academic name (Yao et al., 2022) for interleaving a
model's reasoning with actions and observations of their results,
rather than asking for one big uninterrupted answer. The conceptual
ancestor of modern tool calling.

**Tool calling / function calling** -- a model provider feature where
the model emits a strict, schema-conformant JSON object naming an
action and its arguments, instead of free text a host would have to
parse. This harness's `tool_calls` field is exactly this convention.

**Adapter** -- any goal matching `call(Adapter, RequestDict,
ReplyDict)`; the seam that keeps the agent loop provider-agnostic.
Swapping adapters changes *which model answers* without touching the
loop.

**Tool schema / tool spec** -- the name, description, and parameter
shape of a tool, shown to the model so it knows what's callable.
`harness_tool_specs/1` is this harness's catalog.

**Dispatch table** -- a fixed, closed mapping from a tool *name* to
the code that actually runs (`dispatch_tool/5`). An unrecognized name
simply doesn't match anything, rather than resolving to arbitrary
code.

**Whole-file rewrite vs. patch/diff editing** -- the two ways an agent
can change a file: send the complete new content (`write_file`), or
send only the changed lines as a unified diff (`apply_patch`). Real
agents favor the latter for anything beyond a new file, mainly for
token cost and reliability.

**Atomic write** -- writing to a temporary file and then renaming it
over the real path, so a crash mid-write can never leave a truncated
or corrupted file. `atomic_write/2`.

**Hunk** -- one contiguous block of a unified diff (a starting line
number plus context/added/removed lines). A patch may contain several,
across several files.

**All-or-nothing (patch application)** -- if any hunk in any file of a
patch fails to apply, none of the patch's files are written --
comparable to a database transaction rolling back on any failure.

**Todo list / plan tracking** -- explicit, persistent state recording
an agent's remaining steps, re-shown to the model every turn instead
of relying on it to "remember" its own plan across a long
conversation.

**MCP (Model Context Protocol)** -- an open protocol for an agent host
to discover and call tools exposed by separate, independently-shipped
server processes at runtime, rather than compiling every tool in
ahead of time. See <https://modelcontextprotocol.io> for the formal
specification.

**Worker pool** -- a bounded number of concurrent workers (here,
subagent threads) pulled from a queue of pending tasks, keeping a
fixed number running at once rather than spawning unboundedly.

**Message queue** -- a thread-safe FIFO used here so subagent threads
can report completion to the parent without any thread touching
another's mutable state directly.

**Cooperative cancellation** -- a cancel flag that's only checked at
specific points in the loop (`check_cancelled/1`), rather than a hard
interrupt -- the run stops at the next checkpoint, not instantly.

**Subagent** -- a fully independent `codex_harness(ChildId)` spawned
by a parent harness to handle one task concurrently with siblings; see
Lesson 10.

## Further reading

- Yao, S. et al. *"ReAct: Synergizing Reasoning and Acting in Language
  Models"*, arXiv:2210.03629 (2022) -- the paper that named the
  reasoning/acting interleaving pattern this whole curriculum is built
  around.
- The Model Context Protocol specification: <https://modelcontextprotocol.io>
  -- for the real, current definition referenced in Lesson 6 (this
  harness does not implement MCP; Lesson 6 is a conceptual comparison
  and design sketch only).
- [`../01-architecture.md`](../01-architecture.md) through
  [`../06-testing.md`](../06-testing.md) -- the implementation-level
  reference docs for everything covered conceptually in this track.
- `FEATURE_GUIDE.md` (repo root) -- extension points and pitfalls
  already discovered in this codebase, written for whoever picks up
  maintenance next.
