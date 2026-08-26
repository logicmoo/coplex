# 2. Anatomy of a Turn

This lesson walks through exactly one call to the model and exactly
one tool execution, in full literal detail, using the deterministic
`scripted` adapter. Type this into `swipl` yourself -- it's fully
reproducible.

## Set the stage

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new(
     [ root('.'), adapter(scripted),
       allow_shell(true), allow_network(true),   % full permissions for this course
       mock_replies([
           _{content:"Let me check the README first.",
             tool_calls:[_{id:"c1", name:read_file,
                            arguments:_{path:"README.md"}}]},
           _{content:"This project is a coding-agent harness.",
             tool_calls:[]}
       ])
     ], H).
?- harness_run(H, "Summarize this project in one sentence.", Answer).
```

Two scripted replies means the loop will run for exactly two
iterations: one that asks for a tool, one that gives a final answer.
Let's take those two iterations apart.

## Turn 1: building the Request

Every iteration starts with `call_model/3` assembling a **Request**
dict -- this is exactly what gets handed to `call(Adapter, Request,
Reply)`:

```prolog
_{ model: default,
   instructions: "You are a coding agent working inside a repository through tools.\n...",
   messages: [ _{role:user, content:"Summarize this project in one sentence.\n\nRepository context:\n..."} ],
   tools: [ _{name:read_file, risk:read_only, description:"...", parameters:_{...}}, ... ],
   options: [] }
```

Four things worth noticing:

- `instructions` is the system prompt (`build_instructions/2`), the
  same on every call.
- `messages` is the **entire conversation so far** -- on turn 1 that's
  just the user's task, prepended with a gathered snapshot of the repo
  (branch, file tree, `AGENTS.md`, etc. -- see `gather_context/3`).
  There is no other "memory" the model has access to.
- `tools` is the full catalog from `harness_tool_specs/1`, shown on
  *every* call -- the model doesn't "learn" what tools exist once and
  remember; it's told again each turn (cheap for the harness to do,
  and it means a mid-run change to `allowed_tools` takes effect on the
  very next turn).
- `options` is whatever the caller passed to `harness_run/4` as
  `RunOptions` (empty here).

## Turn 1: the Reply, and one tool execution

The `scripted` adapter doesn't call a real model -- `scripted_adapter/3`
just pops the next entry off `mock_replies` (`pop_script/2`) and runs
it through `normalize_reply/2`, producing:

```prolog
_{ content:"Let me check the README first.",
   tool_calls:[ _{id:"c1", name:read_file, arguments:_{path:"README.md"}} ] }
```

Back in `loop_steps/4`: the assistant's `content` and `tool_calls` are
appended to the conversation as one new message
(`mutate(Id, add_message(_{role:assistant, ...}))`), then, because
`tool_calls` isn't empty, every call in it is executed:

```
run_one_tool(Id, Call, Result)
  -> guarded_tool(Id, read_file, _{path:"README.md"}, Raw)
  -> dispatch_tool(read_file, _, S, Args, Raw)
  -> tool_read_file(S, Args, Raw)
```

`tool_read_file/3` resolves `"README.md"` against the harness's `root`
(`safe_resolve/3`), reads it, and returns something like:

```prolog
_{ ok:true, tool:read_file, path:"README.md",
   content:"# coplex\n\n...", truncated:false }
```

`run_named_tool/5` wraps that with timing/id metadata, and
`tool_result_message/2` turns it into a new conversation message:

```prolog
_{ role:tool, tool:read_file, tool_call_id:"c1", content:_{ok:true, ...} }
```

That message is appended too. **This is the entire mechanism by which
a tool's output "gets back to the model"** -- not a return value, not
a callback, just one more message in a list that gets resent in full
next turn.

## Turn 2: the model sees its own tool result

Iteration 2's Request now has *three* messages instead of one: the
original user task, the assistant's turn-1 reply (including the
`tool_calls` it made), and the `role:tool` result. The scripted
adapter pops its second entry:

```prolog
_{content:"This project is a coding-agent harness.", tool_calls:[]}
```

Empty `tool_calls` is the loop's exit condition
(`Calls == [] -> Answer = Content`). `harness_run/4` returns
`"This project is a coding-agent harness."` as `Answer`.

## See the whole transcript

```prolog
?- harness_messages(H, Msgs), forall(member(M, Msgs), format("~w: ~p~n", [M.role, M.content])).
```

You'll see, in order: `user` (task+context), `assistant` ("Let me
check..."), `tool` (the file content, wrapped in the result dict),
`assistant` (the final sentence). **That list, resent whole every
turn, is the model's entire working memory.** Nothing else persists
between calls -- which is exactly why later lessons on planning
(5) and repository context matter: anything the model needs to "recall"
on turn 50 has to still be sitting in that list (or reconstructed and
re-injected) on turn 50, because the model itself remembers nothing.

## Checkpoint

1. If `mock_replies` had a *third* entry, would it ever get used in
   the run above? Why or why not?
2. What would `harness_messages/2` return if the model's first reply
   had `tool_calls: []` instead of a read-file call?
3. `call_model/3` includes the *entire* tool catalog on every single
   call, not just the tools used so far. What's the cost of that as a
   conversation gets very long, and can you think of why providers'
   real APIs still do it this way?
