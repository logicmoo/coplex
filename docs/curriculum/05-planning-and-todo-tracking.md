# 5. Planning and Todo-List Tracking

## The problem: long tasks and short memory

Lesson 2 established that the model has no memory of its own -- every
turn, it only knows what's sitting in `messages`. That's fine for a
three-turn task. It gets shaky on a *fifty*-turn task: "refactor this
module, update its six call sites, fix the tests, update the docs" is
easy to lose the thread of if the only record of "what's left to do"
is buried somewhere in fifty screens of scrollback.

Production coding agents solve this the same way a human would: keep
an explicit, short, structured **plan** -- a todo list -- as its own
piece of state, updated as work happens, and shown back to the model
fresh every turn instead of trusting it to remember. You'll see this
same pattern (sometimes called a "plan tool," a "task list," or
similar) across essentially every serious coding-agent product. It's
not a model capability -- it's a harness-side bookkeeping trick that
happens to make the model perform much better on long tasks, for
exactly the same reason a checklist helps a person: it turns "did I
already do the thing I think I did?" into "let me look."

## What this harness has today (and doesn't, yet)

`codex_harness.pl` already does something structurally similar for a
*different* purpose: `detect_repeat_failures/2` automatically injects
a `system`-role message ("stop retrying the same call") when it
notices the model repeating a failing action. That's the harness
steering the model with injected state -- the same mechanism a todo
list would use -- just for a narrower problem (loop detection, not
planning).

There is **no todo-list tool yet**. That's today's lab: add one,
following the exact same pattern every other tool in this codebase
follows.

## Lab: add a `todo_write` tool

All edits are in `prolog/coplex/codex_harness.pl`.

**1. Add a `todos` field to the state dict**, in `harness_new/2`'s
`State = _{...}`, next to the other list-valued fields:

```prolog
tool_activity:[], subagents:[], todos:[],
```

**2. Teach `mutate/2` how to update it.** Add a new clause next to
the other `apply_mut/3` clauses:

```prolog
apply_mut(set_todos(Items), S0, S1) :-
    S1 = S0.put(todos, Items).
```

**3. Advertise it to the model.** Add an entry to
`harness_tool_specs/1`, next to `subagents`:

```prolog
spec(todo_write, write, "Replace the current todo list.",
     _{items:list})
```

**4. Wire it into dispatch.** Add a clause to `dispatch_tool/5`:

```prolog
dispatch_tool(todo_write, write, S, A, R)   :- tool_todo_write(S, A, R).
```

**5. Implement it**, next to the dispatch table:

```prolog
tool_todo_write(S, A, R) :-
    flex_get(items, A, Items0, []),
    (   is_list(Items0)
    ->  mutate(S.id, set_todos(Items0)),
        R = _{ok:true, tool:todo_write, todos:Items0}
    ;   R = _{ok:false, tool:todo_write,
              error:_{type:validation_error, message:"items must be a list"}}
    ).
```

**6. Make it observable.** Add `todos:S.todos,` to the `Snap` dict in
`harness_snapshot/2`, next to `subagents:S.subagents,`.

### Try it

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new([root('.'), adapter(scripted)], H),
   harness_tool(H, todo_write,
                _{items:[_{step:"read spec", status:"completed"},
                         _{step:"write code", status:"in_progress"}]}, R),
   harness_snapshot(H, Snap),
   format("~p~n", [Snap.todos]).
```

You should see the two-item list echoed back from `Snap.todos`.

## What would make this actually useful (stretch goals, not required)

- **Re-inject the plan into context.** `gather_context/3` already
  builds a "here's the state of the world" string prepended to every
  task; add the current `todos` to it, formatted as a checklist, so
  the model is reminded of its own plan on turn 30 without having to
  scroll back through `messages` to reconstruct it.
- **A `todo_read` tool** (or just always including it in context, per
  above, and skipping a separate read tool entirely).
- **Surface it in `harness_summary/2`** too, so a REST-driven UI
  (Lesson in [`../04-rest-api.md`](../04-rest-api.md)) can show a live
  progress checklist per running harness, the same way `message_count`
  is surfaced today.
- **A plunit test** mirroring the ones in `test/test_codex_harness.pl`
  -- create a harness, call the tool, assert on the snapshot.

## Checkpoint

1. Why does the todo list need to be *state* (something `mutate/2`
   updates) rather than just something the model writes as ordinary
   conversational text?
2. What's the difference between this and `detect_repeat_failures/2`'s
   injected system message -- why is one harness-initiated and the
   other model-initiated?
3. If two turns from now the model calls `todo_write` again with a
   shorter list, what happens to the items it left out? Is that the
   right behavior for a "replace" tool, or would you want a
   `todo_update` that merges instead?
