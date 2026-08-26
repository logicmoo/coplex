:- encoding(utf8).
:- use_module('../prolog/coplex/codex_harness').

%!  demo is det.
%   Scripted adapter: read README.md then answer. No paid API.
demo :-
    absolute_file_name('.', Root),
    harness_new(
        [ root(Root),
          adapter(scripted),
          mock_replies([
              _{content:"Inspecting README",
                tool_calls:[_{id:"c1", name:read_file,
                              arguments:_{path:"README.md"}}]},
              _{content:"README exists. Demo complete.", tool_calls:[]}
          ])
        ],
        H),
    setup_call_cleanup(
        true,
        (   harness_run(H, "Summarize this plugin in one sentence.", Answer),
            format("Answer: ~s~n", [Answer]),
            harness_snapshot(H, Snap),
            format("Iterations: ~w~n", [Snap.iteration])
        ),
        harness_close(H)).

:- initialization(demo, main).
