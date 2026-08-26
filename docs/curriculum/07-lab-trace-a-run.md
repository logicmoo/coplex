# 7. Lab: Trace a Run

Goal: watch every internal event of a real (scripted) run and narrate
what's happening at each line, connecting it back to Lessons 1-3.

## Setup

```prolog
?- [prolog/coplex/codex_harness].
?- debug(codex_harness).
?- harness_new(
     [ root('.'), adapter(scripted), allow_shell(true),
       mock_replies([
           _{content:"Checking the examples directory.",
             tool_calls:[_{id:"c1", name:list_files, arguments:_{path:"examples"}}]},
           _{content:"Done.", tool_calls:[]}
       ])
     ], H),
   harness_run(H, "List the example files.", Answer).
```

`debug(codex_harness)` turns on every `emit/2` call in the module --
every `run_start`, `model_request`, `model_response`, `tool_start`,
`tool_finish`, and `final_answer` event prints as it happens. (stdout
from `format/2` and the debug stream can interleave slightly
differently than shown below depending on your terminal's buffering --
the *order these events actually occur in* is always the one below.)

## What you should see, in this order

```
created <uuid>
root=<your repo path>

_{task:"List the example files.", type:run_start}

_{request:_{model:default, n_messages:1}, type:model_request}

_{content:"Checking the examples directory.",
  tool_calls:[_{arguments:_{path:examples}, id:c1, name:list_files}],
  type:model_response}

_{arguments:_{path:examples}, id:c1, tool:list_files, type:tool_start}

_{result:_{duration_ms:1, files:["examples/example_codex_harness.pl"],
            ok:true, tool:list_files, tool_call_id:c1, truncated:false},
  type:tool_finish}

_{request:_{model:default, n_messages:3}, type:model_request}

_{content:"Done.", tool_calls:[], type:model_response}

_{content:"Done.", type:final_answer}
```

## Narrate it

Match each event to a place in the code (Lessons 1-3 cover all of
these):

| Event | Emitted by | What just happened |
|---|---|---|
| `run_start` | `run_loop/4` | The user task + gathered repo context became message #1. |
| `model_request` (`n_messages:1`) | `call_model/3` | About to call the adapter with a 1-message conversation. |
| `model_response` | `loop_steps/4` | The (scripted) model asked for one tool call. |
| `tool_start` | `run_named_tool/5` | About to dispatch `list_files` with `{path:examples}`. |
| `tool_finish` | `run_named_tool/5` | The tool ran; note `tool_call_id:c1` -- this is how the *next* message knows which call this result answers. |
| `model_request` (`n_messages:3`) | `call_model/3` | Conversation has grown: user task, assistant's first reply, the tool result. All three are resent. |
| `model_response` | `loop_steps/4` | Empty `tool_calls` this time -- the loop's exit condition. |
| `final_answer` | `loop_steps/4` | `Answer` is bound to `"Done."` and `harness_run/4` returns. |

## Now break it on purpose

Change `mock_replies` to have only **one** entry (the first one, with
the tool call) and re-run. What happens? Read `loop_steps/4` and
`scripted_adapter/3`/`pop_script/2` before you run it, predict the
output, then check yourself. (Hint: `pop_script/2` has an explicit
`Next == none` case -- what does it return, and what does that make
`loop_steps/4` do with it?)

## Checkpoint

1. Which event tells you the model asked for a tool, and which tells
   you the tool actually ran? Could the first happen without the
   second ever happening?
2. `n_messages` goes from 1 to 3 between the two `model_request`
   events. Which two messages were added, and by which code?
3. What's the smallest possible complete run (in terms of number of
   `model_response` events) you can construct with `mock_replies`?
