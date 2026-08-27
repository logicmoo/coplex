:- encoding(utf8).
/*  test_codex_harness_server.pl

    plunit tests for coplex_server.pl, the JSON REST facade
    over codex_harness.pl.  Starts a real server on an ephemeral
    localhost port and drives it with library(http/http_client), so
    these are true end-to-end HTTP tests, not just unit tests of the
    Prolog predicates.

    Run with:
        swipl -g run_tests -t halt test/test_codex_harness_server.pl
*/

:- use_module('../prolog/coplex/codex_harness').
:- use_module('../prolog/coplex_server').
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

test(tools_advertise_real_endpoint, [setup(setup_server), cleanup(teardown_server)]) :-
    % Every tool in the catalog must carry a method + endpoint that
    % actually resolves to a route (see tool_endpoint_is_callable),
    % not just a name a UI would have to guess a URL for.
    base_url(Base),
    atomic_list_concat([Base, '/tools'], Url),
    http_get_json(Url, _{}, Reply),
    spec_for_name(Reply.tools, "read_file", ReadFileSpec),
    assertion(ReadFileSpec.method == "POST"),
    assertion(ReadFileSpec.endpoint == "/coplex/tools/read_file").

spec_for_name([D|_], Name, D) :- D.name == Name, !.
spec_for_name([_|Ds], Name, Spec) :- spec_for_name(Ds, Name, Spec).

test(tool_endpoint_is_callable, [setup(setup_server), cleanup(teardown_server)]) :-
    % POST /tools/<name> must work with no harness id at all -- this
    % is the endpoint GET /tools advertises for each entry.
    base_url(Base),
    atomic_list_concat([Base, '/tools/git_status'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(Reply.tool == "git_status").

test(direct_tool_endpoint_coplex_prefix, [setup(setup_server), cleanup(teardown_server)]) :-
    % Same handler, reached through the /coplex-prefixed parity route.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools/git_status'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(Reply.tool == "git_status").

test(direct_tool_endpoint_unknown_tool_is_200, [setup(setup_server), cleanup(teardown_server)]) :-
    % An unknown tool name is a normal JSON error reply, matching the
    % existing per-harness POST /harnesses/<id>/tools/<name> behavior
    % -- not a 404, since the route itself did match.
    base_url(Base),
    atomic_list_concat([Base, '/tools/does_not_exist'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == false),
    assertion(Reply.error.type == "unknown_tool").

test(direct_tool_endpoint_reuses_shared_harness, [setup(setup_server), cleanup(teardown_server)]) :-
    % Two direct calls share one lazily-created harness rather than
    % leaking a fresh one per request.
    base_url(Base),
    atomic_list_concat([Base, '/tools/git_status'], Url),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_get_json(HarnessesUrl, _{}, Before),
    length(Before.ids, NBefore),
    http_post_json(Url, _{}, _),
    http_post_json(Url, _{}, _),
    http_get_json(HarnessesUrl, _{}, After),
    length(After.ids, NAfter),
    assertion(NAfter =< NBefore + 1).

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
    assertion(Snap.created_at > 0),
    format(atom(MsgUrl), '~w/harnesses/~w/messages', [Base, Id]),
    http_get_json(MsgUrl, _{}, MsgReply),
    assertion(is_list(MsgReply.messages)),
    http_delete_json(ItemUrl, DelReply),
    assertion(DelReply.ok == true),
    http_get_json(HarnessesUrl, _{}, ListReply),
    assertion(\+ memberchk(Id, ListReply.ids)).

test(harnesses_list_has_summaries, [setup(setup_server), cleanup(teardown_server)]) :-
    % GET /harnesses must return a lightweight per-harness summary
    % (running/current_task/message_count/...) alongside the plain id
    % list, so a UI can render a dashboard table without an extra
    % request per row.
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:".", adapter:"scripted"}, Created),
    Id = Created.id,
    http_get_json(HarnessesUrl, _{}, ListReply),
    assertion(is_list(ListReply.harnesses)),
    summary_for_id(ListReply.harnesses, Id, Summary),
    assertion(Summary.running == false),
    assertion(Summary.message_count == 0),
    format(atom(ItemUrl), '~w/harnesses/~w', [Base, Id]),
    http_delete_json(ItemUrl, _).

summary_for_id([D|_], Id, D) :- D.id == Id, !.
summary_for_id([_|Ds], Id, Summary) :- summary_for_id(Ds, Id, Summary).

test(async_run_completes_in_background, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", adapter:"scripted",
                     mock_replies:[_{content:"async hi", tool_calls:[]}]},
                   Created),
    Id = Created.id,
    format(atom(RunUrl), '~w/harnesses/~w/run', [Base, Id]),
    http_post_json(RunUrl, _{task:"say hi", async:true}, RunReply),
    assertion(RunReply.ok == true),
    assertion(RunReply.started == true),
    format(atom(ItemUrl), '~w/harnesses/~w', [Base, Id]),
    wait_run_finished(ItemUrl, 100, Snap),
    assertion(Snap.last_answer == "async hi"),
    http_delete_json(ItemUrl, _).

wait_run_finished(_, 0, _) :- !, fail.
wait_run_finished(Url, N, Snap) :-
    http_get_json(Url, _{}, Snap0),
    (   Snap0.running == false, Snap0.last_answer \== ""
    ->  Snap = Snap0
    ;   sleep(0.05),
        N1 is N - 1,
        wait_run_finished(Url, N1, Snap)
    ).

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

test(cors_preflight_and_headers, [setup(setup_server), cleanup(teardown_server)]) :-
    % A browser-based UI on another origin sends an OPTIONS preflight
    % before its real POST/DELETE; the server must answer 200 with
    % Access-Control-Allow-Origin, and normal replies must carry the
    % same header so the browser doesn't block reading the response.
    base_url(Base),
    atomic_list_concat([Base, '/harnesses'], HarnessesUrl),
    setup_call_cleanup(
        http_open(HarnessesUrl, In,
                   [ method(options),
                     status_code(PreCode),
                     header(access_control_allow_origin, PreOrigin)
                   ]),
        true,
        close(In)),
    assertion(PreCode == 200),
    assertion(PreOrigin == '*'),
    format(atom(HealthUrl), '~w/health', [Base]),
    setup_call_cleanup(
        http_open(HealthUrl, In2,
                   [ status_code(GetCode),
                     header(access_control_allow_origin, GetOrigin)
                   ]),
        true,
        close(In2)),
    assertion(GetCode == 200),
    assertion(GetOrigin == '*').

:- end_tests(codex_harness_server).
