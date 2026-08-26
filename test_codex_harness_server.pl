:- encoding(utf8).
/*  test_codex_harness_server.pl

    plunit tests for codex_harness_server.pl, the JSON REST facade
    over codex_harness.pl.  Starts a real server on an ephemeral
    localhost port and drives it with library(http/http_client), so
    these are true end-to-end HTTP tests, not just unit tests of the
    Prolog predicates.

    Run with:
        swipl -g run_tests -t halt test_codex_harness_server.pl
*/

:- use_module(codex_harness).
:- use_module(codex_harness_server).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/json)).
:- use_module(library(http/http_json)).
:- use_module(library(filesex)).

:- begin_tests(codex_harness_server).

test_port(8797).

setup_server :-
    test_port(Port),
    catch(server_stop, _, true),
    server_start(Port, localhost),
    wait_healthy(Port, 50).

wait_healthy(_, 0) :- !, fail.
wait_healthy(Port, N) :-
    format(atom(Url), 'http://localhost:~w/health', [Port]),
    (   catch(http_get_json(Url, _{}, _), _, fail)
    ->  true
    ;   sleep(0.05),
        N1 is N - 1,
        wait_healthy(Port, N1)
    ).

teardown_server :-
    catch(server_stop, _, true).

%   Minimal GET/POST-JSON helpers (independent of the server's own
%   with_json_body/2 so the test exercises the real wire format).
http_get_json(Url, _Options, Reply) :-
    setup_call_cleanup(
        http_open(Url, In, []),
        json_read_dict(In, Reply),
        close(In)).

http_post_json(Url, Body, Reply) :-
    setup_call_cleanup(
        http_open(Url, In,
                   [ post(json(Body)),
                     status_code(_),
                     header(content_type, _)
                   ]),
        json_read_dict(In, Reply),
        close(In)).

http_delete_json(Url, Reply) :-
    setup_call_cleanup(
        http_open(Url, In, [method(delete)]),
        json_read_dict(In, Reply),
        close(In)).

base_url(Base) :-
    test_port(Port),
    format(atom(Base), 'http://localhost:~w', [Port]).

test(health, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/health'], Url),
    http_get_json(Url, _{}, Reply),
    assertion(Reply.ok == true).

test(tools_nonempty, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/tools'], Url),
    http_get_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(is_list(Reply.tools)),
    assertion(Reply.tools \== []).

test(create_run_snapshot_delete, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", adapter:"scripted",
                     mock_replies:[_{content:"hi from test", tool_calls:[]}]},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(RunUrl), '~w/harnesses/~w/run', [Base, Id]),
    http_post_json(RunUrl, _{task:"say hi"}, RunReply),
    assertion(RunReply.ok == true),
    assertion(RunReply.answer == "hi from test"),
    format(atom(ItemUrl), '~w/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, Snap),
    assertion(Snap.ok == true),
    assertion(Snap.iteration >= 0),
    format(atom(MsgUrl), '~w/harnesses/~w/messages', [Base, Id]),
    http_get_json(MsgUrl, _{}, MsgReply),
    assertion(is_list(MsgReply.messages)),
    http_delete_json(ItemUrl, DelReply),
    assertion(DelReply.ok == true),
    http_get_json(HarnessesUrl, _{}, ListReply),
    assertion(\+ memberchk(Id, ListReply.ids)).

test(unknown_harness_is_404, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    format(atom(Url), '~w/harnesses/does-not-exist', [Base]),
    catch(
        ( http_open(Url, In, [status_code(Code)]),
          close(In)
        ),
        _,
        Code = error),
    assertion(Code == 404).

test(tool_dispatch_over_rest, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:"."}, Created),
    Id = Created.id,
    format(atom(ToolUrl), '~w/harnesses/~w/tools/git_status', [Base, Id]),
    http_post_json(ToolUrl, _{}, Reply),
    assertion(Reply.tool == "git_status"),
    format(atom(ItemUrl), '~w/harnesses/~w', [Base, Id]),
    http_delete_json(ItemUrl, _).

test(goal_shaped_options_are_ignored, [setup(setup_server), cleanup(teardown_server)]) :-
    % approval/on_event/parent/web_search_backend must never be
    % constructible from JSON: the create call must still succeed
    % (extra keys are just dropped) rather than erroring out or, worse,
    % being turned into a callable goal.
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", approval:"shell(rm)", on_event:"shell(rm)",
                     web_search_backend:"shell(rm)"},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(ItemUrl), '~w/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, Snap),
    assertion(Snap.ok == true),
    http_delete_json(ItemUrl, _).

:- end_tests(codex_harness_server).
