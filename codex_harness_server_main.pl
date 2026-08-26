:- encoding(utf8).
/*  codex_harness_server_main.pl

    Standalone entry point for codex_harness_server.pl.  This is the
    file plugin.py's process manager spawns as a background swipl
    process; it is intentionally NOT the same file as the library
    module (codex_harness_server.pl), because
    `:- initialization(main, main)` fires whenever *this* file is
    loaded -- including via a plain `use_module/1` from another
    script -- and a library that silently starts a blocking HTTP
    server as a side effect of being loaded would be a nasty surprise
    for anything that just wants to `use_module(codex_harness_server)`
    (e.g. the test suite).  Keeping the runnable entry point in its
    own file avoids that trap entirely.

    Usage:
        swipl codex_harness_server_main.pl --port=8798 --host=localhost
*/

:- use_module(codex_harness_server).

:- initialization(main, main).

main(Argv) :-
    parse_argv(Argv, Port, Host),
    format(user_error, "task_harness_pl REST server listening on ~w:~w~n", [Host, Port]),
    catch(server_start(Port, Host), Error,
          ( print_message(error, Error), halt(1) )),
    block_forever.

%   Keep the process alive; the server threads run in the background.
%   Stopped only by an external kill or the /shutdown endpoint (which
%   calls halt/1 from its own thread).
block_forever :-
    repeat,
    sleep(3600),
    fail.

parse_argv(Argv, Port, Host) :-
    ( arg_value(Argv, '--port', PortA) -> atom_number(PortA, Port) ; Port = 8798 ),
    ( arg_value(Argv, '--host', HostA) -> Host = HostA ; Host = localhost ).

arg_value(Argv, Flag, Value) :-
    atom_concat(Flag, '=', Prefix),
    member(A, Argv),
    atom_concat(Prefix, Value, A), !.
arg_value(Argv, Flag, Value) :-
    append(_, [Flag, Value|_], Argv), !.
