# 3. Tools Are a Contract

## Two separate questions

Every tool call actually answers two independent questions, and it's
worth keeping them apart in your head:

1. **"What is the model asking for?"** -- a name and some arguments,
   in a fixed wire format.
2. **"What predicate actually runs, and what does it return?"** -- a
   completely separate lookup, done by the harness, not the model.

This lesson is about question 1: the *shape* of a tool call and a tool
result -- the contract both sides agree to. (Question 2 -- how a name
gets routed to code -- is `dispatch_tool/5`, covered briefly here and
in depth in [`../03-tools-and-permissions.md`](../03-tools-and-permissions.md)
if you want the full reference later.)

## The catalog the model sees

`harness_tool_specs/1` is a flat list of `spec(Name, Risk, Description,
Parameters)` terms -- e.g.:

```prolog
spec(read_file, read_only, "Read a UTF-8 file under the repository root.",
     _{path:string, offset:integer, limit:integer}),
spec(write_file, write, "Create or atomically replace a UTF-8 file.",
     _{path:string, content:string}),
```

`call_model/3` maps every entry through `public_spec/2` into
`_{name, risk, description, parameters}` dicts and includes the whole
list in the Request's `tools` field on **every** call -- this is the
model's only source of truth about what actions exist. If a tool isn't
in this list, the model has no way to know it could ask for it.

This is the same idea as a function signature in any typed language:
it tells the caller (here, the model) what's callable and what
arguments it expects, without saying anything about what the
implementation actually does when called.

## The wire format for a call

When the model wants to act, it doesn't return prose -- it returns
(or the provider's API returns on its behalf) a small JSON object:

```json
{"id": "c1", "name": "read_file", "arguments": {"path": "README.md"}}
```

`normalize_call/2` turns this into `_{id, name, arguments}` with two
defensive touches worth noticing:

- If `id` is missing/empty, the harness invents one (`uuid/1`) rather
  than failing -- `id` only exists so a *result* can be matched back to
  its *call* (useful when a turn makes several calls at once); nothing
  breaks if the model omits it.
- `arguments` is coerced through `ensure_dict/2` even if the model (or
  a sloppier adapter) handed back something JSON-ish but not quite a
  dict, e.g. a `json(Pairs)` term.

**Why bother being defensive about something that's "supposed" to
always be well-formed?** Because "supposed to" and "always is" are
different claims. Real model output occasionally omits an optional
field, or a different adapter you write later might not normalize as
carefully as the built-in one. Default-and-continue is a much better
failure mode here than crashing the whole run over a missing `id`.

## The wire format for a result

Whatever a tool implementation returns gets one thing added
uniformly -- `run_named_tool/5` stamps every result with
`tool`, `duration_ms`, and `tool_call_id` -- then it's wrapped as a new
conversation message:

```prolog
_{role:tool, tool:read_file, tool_call_id:"c1", content:Result}
```

Every tool result dict also carries an `ok` boolean plus, on failure,
an `error:_{type:..., message:...}` -- a small, consistent shape the
model can learn to recognize across *any* tool, success or failure,
without needing per-tool special-casing.

## Where "name" turns into "code"

`dispatch_tool/5` is a flat, fixed table:

```prolog
dispatch_tool(read_file, _, S, A, R)      :- tool_read_file(S, A, R).
dispatch_tool(write_file, write, S, A, R) :- tool_write_file(S, A, R).
...
```

An unrecognized `Name` simply doesn't match any clause and falls
through to an `unknown_tool` error -- there's no path from "a string
the model made up" to "an arbitrary predicate gets called." That's the
one load-bearing property of this table worth remembering: *the model
picks a name off a fixed menu; it can never construct new code to run.*

## Checkpoint

1. Why is `tools` re-sent on every single call instead of once at the
   start of a run?
2. What happens (mechanically) if a model reply names a tool that
   isn't in `harness_tool_specs/1` at all?
3. Two different tool calls in the same turn -- how does the harness
   know which result belongs to which call once both are back in the
   conversation as messages?
