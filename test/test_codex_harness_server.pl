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
:- use_module(library(uuid)).

% server_start/2 now calls rehydrate_harnesses/0 (see codex_harness.pl)
% on every setup_server/0 in this suite, so persistence must be
% redirected to a throwaway temp directory before any test runs --
% same reasoning as test_codex_harness.pl's equivalent directive.
:- initialization(( current_prolog_flag(tmp_dir, Tmp),
                     uuid(StateUid),
                     directory_file_path(Tmp, StateUid, StateDir),
                     set_coplex_state_dir(StateDir)
                   )).

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

%   Raw-text GET, for endpoints that don't reply JSON (the admin UI).
http_get_text(Url, Text, ContentType) :-
    setup_call_cleanup(
        http_open(Url, In, [header(content_type, ContentType)]),
        read_string(In, _, Text),
        close(In)).

base_url(Base) :-
    test_port(Port),
    format(atom(Base), 'http://localhost:~w', [Port]).

test(health, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/health'], Url),
    http_get_json(Url, _{}, Reply),
    assertion(Reply.ok == true).

test(admin_ui_serves_html, [setup(setup_server), cleanup(teardown_server)]) :-
    % GET /coplex now serves the admin dashboard (moved from the old
    % JSON status document -- see endpoints_moved_to_coplex_endpoints).
    base_url(Base),
    atomic_list_concat([Base, '/coplex'], Url),
    http_get_text(Url, Text, ContentType),
    assertion(sub_atom(ContentType, _, _, _, 'text/html')),
    string_lower(Text, LowerText),
    assertion(sub_string(LowerText, _, _, _, "<!doctype html>")),
    assertion(sub_string(Text, _, _, _, "coplex")).

test(admin_ui_bare_root_parity, [setup(setup_server), cleanup(teardown_server)]) :-
    % Bare `/` serves the identical admin UI -- the same root/prefix
    % parity every other route in this server already has, needed for
    % the workbench's stripped-prefix proxy mount to reach it too.
    base_url(Base),
    atomic_list_concat([Base, '/coplex'], PrefixedUrl),
    atomic_list_concat([Base, '/'], RootUrl),
    http_get_text(PrefixedUrl, PrefixedText, _),
    http_get_text(RootUrl, RootText, _),
    assertion(PrefixedText == RootText).

test(endpoints_moved_to_coplex_endpoints, [setup(setup_server), cleanup(teardown_server)]) :-
    % The JSON status/endpoint-list document that used to live at
    % GET /coplex moved to GET /coplex/endpoints (and bare
    % /endpoints); GET /coplex itself is HTML now (see
    % admin_ui_serves_html), not JSON.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/endpoints'], PrefixedUrl),
    atomic_list_concat([Base, '/endpoints'], RootUrl),
    http_get_json(PrefixedUrl, _{}, PrefixedReply),
    http_get_json(RootUrl, _{}, RootReply),
    assertion(PrefixedReply.ok == true),
    assertion(PrefixedReply.plugin_id == "coplex"),
    assertion(is_list(PrefixedReply.endpoints)),
    assertion(PrefixedReply.endpoints \== []),
    assertion(RootReply.ok == true),
    atomic_list_concat([Base, '/coplex'], AdminUrl),
    catch(
        ( http_get_json(AdminUrl, _{}, _), AdminIsJson = true ),
        _,
        AdminIsJson = false),
    assertion(AdminIsJson == false).

test(tools_nonempty, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools'], Url),
    http_get_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(is_list(Reply.tools)),
    assertion(Reply.tools \== []).

test(tools_advertise_real_endpoint, [setup(setup_server), cleanup(teardown_server)]) :-
    % Every tool in the catalog must carry a method + endpoint that
    % actually resolves to a route (see tool_endpoint_is_callable),
    % not just a name a UI would have to guess a URL for.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools'], Url),
    http_get_json(Url, _{}, Reply),
    spec_for_name(Reply.tools, "read_file", ReadFileSpec),
    assertion(ReadFileSpec.method == "POST"),
    assertion(ReadFileSpec.endpoint == "/coplex/tools/read_file").

spec_for_name([D|_], Name, D) :- D.name == Name, !.
spec_for_name([_|Ds], Name, Spec) :- spec_for_name(Ds, Name, Spec).

test(tool_endpoint_is_callable, [setup(setup_server), cleanup(teardown_server)]) :-
    % POST /coplex/tools/<name> must work with no harness id at all --
    % this is the endpoint GET /coplex/tools advertises for each entry
    % (the canonical, documented form; direct_tool_endpoint_bare_root_parity
    % below covers the bare-root fallback used by the workbench proxy).
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools/git_status'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(Reply.tool == "git_status").

test(direct_tool_endpoint_bare_root_parity, [setup(setup_server), cleanup(teardown_server)]) :-
    % Same handler, reached through the bare-root parity route kept
    % for the workbench's stripped-prefix proxy mount.
    base_url(Base),
    atomic_list_concat([Base, '/tools/git_status'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == true),
    assertion(Reply.tool == "git_status").

test(direct_tool_endpoint_unknown_tool_is_200, [setup(setup_server), cleanup(teardown_server)]) :-
    % An unknown tool name is a normal JSON error reply, matching the
    % existing per-harness POST /coplex/harnesses/<id>/tools/<name>
    % behavior -- not a 404, since the route itself did match.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools/does_not_exist'], Url),
    http_post_json(Url, _{}, Reply),
    assertion(Reply.ok == false),
    assertion(Reply.error.type == "unknown_tool").

test(direct_tool_endpoint_reuses_shared_harness, [setup(setup_server), cleanup(teardown_server)]) :-
    % Two direct calls share one lazily-created harness rather than
    % leaking a fresh one per request.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/tools/git_status'], Url),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_get_json(HarnessesUrl, _{}, Before),
    length(Before.ids, NBefore),
    http_post_json(Url, _{}, _),
    http_post_json(Url, _{}, _),
    http_get_json(HarnessesUrl, _{}, After),
    length(After.ids, NAfter),
    assertion(NAfter =< NBefore + 1).

test(create_run_snapshot_delete, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", adapter:"scripted",
                     mock_replies:[_{content:"hi from test", tool_calls:[]}]},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(RunUrl), '~w/coplex/harnesses/~w/run', [Base, Id]),
    http_post_json(RunUrl, _{task:"say hi"}, RunReply),
    assertion(RunReply.ok == true),
    assertion(RunReply.answer == "hi from test"),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, Snap),
    assertion(Snap.ok == true),
    assertion(Snap.iteration >= 0),
    assertion(Snap.created_at > 0),
    format(atom(MsgUrl), '~w/coplex/harnesses/~w/messages', [Base, Id]),
    http_get_json(MsgUrl, _{}, MsgReply),
    assertion(is_list(MsgReply.messages)),
    http_delete_json(ItemUrl, DelReply),
    assertion(DelReply.ok == true),
    http_get_json(HarnessesUrl, _{}, ListReply),
    assertion(\+ memberchk(Id, ListReply.ids)).

test(harnesses_list_has_summaries, [setup(setup_server), cleanup(teardown_server)]) :-
    % GET /coplex/harnesses must return a lightweight per-harness
    % summary (running/current_task/message_count/...) alongside the
    % plain id list, so a UI can render a dashboard table without an
    % extra request per row.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:".", adapter:"scripted"}, Created),
    Id = Created.id,
    http_get_json(HarnessesUrl, _{}, ListReply),
    assertion(is_list(ListReply.harnesses)),
    summary_for_id(ListReply.harnesses, Id, Summary),
    assertion(Summary.running == false),
    assertion(Summary.message_count == 0),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_delete_json(ItemUrl, _).

summary_for_id([D|_], Id, D) :- D.id == Id, !.
summary_for_id([_|Ds], Id, Summary) :- summary_for_id(Ds, Id, Summary).

test(async_run_completes_in_background, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", adapter:"scripted",
                     mock_replies:[_{content:"async hi", tool_calls:[]}]},
                   Created),
    Id = Created.id,
    format(atom(RunUrl), '~w/coplex/harnesses/~w/run', [Base, Id]),
    http_post_json(RunUrl, _{task:"say hi", async:true}, RunReply),
    assertion(RunReply.ok == true),
    assertion(RunReply.started == true),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
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
    format(atom(Url), '~w/coplex/harnesses/does-not-exist', [Base]),
    catch(
        ( http_open(Url, In, [status_code(Code)]),
          close(In)
        ),
        _,
        Code = error),
    assertion(Code == 404).

test(tool_dispatch_over_rest, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:"."}, Created),
    Id = Created.id,
    format(atom(ToolUrl), '~w/coplex/harnesses/~w/tools/git_status', [Base, Id]),
    http_post_json(ToolUrl, _{}, Reply),
    assertion(Reply.tool == "git_status"),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_delete_json(ItemUrl, _).

test(goal_shaped_options_are_ignored, [setup(setup_server), cleanup(teardown_server)]) :-
    % approval/on_event/parent/web_search_backend must never be
    % constructible from JSON: the create call must still succeed
    % (extra keys are just dropped) rather than erroring out or, worse,
    % being turned into a callable goal.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", approval:"shell(rm)", on_event:"shell(rm)",
                     web_search_backend:"shell(rm)"},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, Snap),
    assertion(Snap.ok == true),
    http_delete_json(ItemUrl, _).

test(openai_adapter_selectable_and_key_not_leaked, [setup(setup_server), cleanup(teardown_server)]) :-
    % adapter:"openai" (plus adapter_url/adapter_api_key) must be
    % accepted -- this is the real-LLM-adapter surface -- but the API
    % key must never come back out through any harness read, matching
    % the "no secret ever reflected back" contract already covered by
    % goal_shaped_options_are_ignored for approval/on_event/etc.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:".", adapter:"openai",
                     adapter_url:"http://localhost:1/v1/chat/completions",
                     adapter_api_key:"sk-should-never-leak"},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, Snap),
    assertion(Snap.ok == true),
    term_string(Snap, SnapText),
    assertion(\+ sub_string(SnapText, _, _, _, "sk-should-never-leak")),
    http_get_json(HarnessesUrl, _{}, ListReply),
    summary_for_id(ListReply.harnesses, Id, Summary),
    term_string(Summary, SummaryText),
    assertion(\+ sub_string(SummaryText, _, _, _, "sk-should-never-leak")),
    http_delete_json(ItemUrl, _).

test(cors_preflight_and_headers, [setup(setup_server), cleanup(teardown_server)]) :-
    % A browser-based UI on another origin sends an OPTIONS preflight
    % before its real POST/DELETE; the server must answer 200 with
    % Access-Control-Allow-Origin, and normal replies must carry the
    % same header so the browser doesn't block reading the response.
    % Checked on the canonical /coplex-prefixed route (POST/DELETE)
    % and, for the GET side, the bare-root parity route -- covering
    % CORS on both route families in one test.
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
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

% -- interactive approval workflow over REST --------------------------
%
% POST /coplex/harnesses/<id>/tools/<name> blocks the HTTP request
% itself while approval_mode(interactive) waits (there's no async
% variant of the direct tool-call endpoint), so these tests fire that
% POST from a background thread and drive/observe the pause from the
% main test thread via ordinary GET/POST calls, the same way a real
% two-client setup (an agent posting the tool call, a human's browser
% deciding it) would.

wait_pending_rest(_, 0, _) :- !, fail.
wait_pending_rest(ItemUrl, N, CallId) :-
    http_get_json(ItemUrl, _{}, Snap),
    (   Snap.pending_approvals = [First|_]
    ->  CallId = First.call_id
    ;   sleep(0.05),
        N1 is N - 1,
        wait_pending_rest(ItemUrl, N1, CallId)
    ).

http_post_json_status(Url, Body, Reply, Code) :-
    setup_call_cleanup(
        http_open(Url, In,
                   [ post(json(Body)),
                     status_code(Code),
                     header(content_type, _)
                   ]),
        json_read_dict(In, Reply),
        close(In)).

%!  tmp_root(-Dir) is det.
%   A fresh, empty temp directory for the one test that calls it --
%   write_file over REST needs somewhere writable, and unlike this
%   file's many read-only-tool tests, root:"." would actually leave a
%   stray file behind in this very repo checkout.
tmp_root(Dir) :-
    current_prolog_flag(tmp_dir, Tmp),
    uuid(Id),
    directory_file_path(Tmp, Id, Dir),
    make_directory(Dir).

cleanup_tmp_root(Dir) :-
    catch(delete_directory_and_contents(Dir), _, true).

test(approval_over_rest_allow, [setup(setup_server), cleanup(teardown_server)]) :-
    tmp_root(Root),
    setup_call_cleanup(
        true,
        approval_over_rest_allow_(Root),
        cleanup_tmp_root(Root)).

approval_over_rest_allow_(Root) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:Root, approval_mode:"interactive", approval_timeout:10},
                   Created),
    Id = Created.id,
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    format(atom(ToolUrl), '~w/coplex/harnesses/~w/tools/write_file', [Base, Id]),
    thread_create(
        http_post_json(ToolUrl, _{path:"rest_a.txt", content:"hi"}, _ToolReply),
        Tid, []),
    wait_pending_rest(ItemUrl, 100, CallId),
    format(atom(ApprovalUrl), '~w/coplex/harnesses/~w/approvals/~w', [Base, Id, CallId]),
    http_post_json(ApprovalUrl, _{decision:"allow"}, DecideReply),
    assertion(DecideReply.ok == true),
    thread_join(Tid, _),
    format(atom(ReadUrl), '~w/coplex/harnesses/~w/tools/read_file', [Base, Id]),
    http_post_json(ReadUrl, _{path:"rest_a.txt"}, ReadReply),
    assertion(ReadReply.ok == true),
    assertion(ReadReply.content == "hi"),
    http_delete_json(ItemUrl, _).

test(approval_over_rest_deny, [setup(setup_server), cleanup(teardown_server)]) :-
    tmp_root(Root),
    setup_call_cleanup(
        true,
        approval_over_rest_deny_(Root),
        cleanup_tmp_root(Root)).

approval_over_rest_deny_(Root) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:Root, approval_mode:"interactive", approval_timeout:10},
                   Created),
    Id = Created.id,
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    format(atom(ToolUrl), '~w/coplex/harnesses/~w/tools/write_file', [Base, Id]),
    thread_create(
        http_post_json(ToolUrl, _{path:"rest_b.txt", content:"hi"}, _ToolReply),
        Tid, []),
    wait_pending_rest(ItemUrl, 100, CallId),
    format(atom(ApprovalUrl), '~w/coplex/harnesses/~w/approvals/~w', [Base, Id, CallId]),
    http_post_json(ApprovalUrl, _{decision:"deny"}, DecideReply),
    assertion(DecideReply.ok == true),
    thread_join(Tid, _),
    format(atom(ReadUrl), '~w/coplex/harnesses/~w/tools/read_file', [Base, Id]),
    http_post_json(ReadUrl, _{path:"rest_b.txt"}, ReadReply),
    assertion(ReadReply.ok == false),
    assertion(ReadReply.error.type == "not_found"),
    http_delete_json(ItemUrl, _).

test(approval_unknown_call_id_is_404, [setup(setup_server), cleanup(teardown_server)]) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:"."}, Created),
    Id = Created.id,
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    format(atom(ApprovalUrl), '~w/coplex/harnesses/~w/approvals/does-not-exist', [Base, Id]),
    http_post_json_status(ApprovalUrl, _{decision:"allow"}, _Reply, Code),
    assertion(Code == 404),
    http_delete_json(ItemUrl, _).

test(approval_mode_deny_risky_over_rest, [setup(setup_server), cleanup(teardown_server)]) :-
    % approval_mode/approval_timeout must be accepted from JSON like any
    % other safe_option_key/1 -- checked end-to-end via observable
    % behaviour (an immediate denial), not just that harness creation
    % succeeds, since creation never echoes options back.
    tmp_root(Root),
    setup_call_cleanup(
        true,
        approval_mode_deny_risky_over_rest_(Root),
        cleanup_tmp_root(Root)).

approval_mode_deny_risky_over_rest_(Root) :-
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl, _{root:Root, approval_mode:"deny_risky"}, Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(ToolUrl), '~w/coplex/harnesses/~w/tools/write_file', [Base, Id]),
    http_post_json(ToolUrl, _{path:"rest_c.txt", content:"hi"}, Reply),
    assertion(Reply.ok == false),
    assertion(Reply.error.type == "denied"),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_delete_json(ItemUrl, _).

test(harness_survives_a_simulated_server_restart) :-
    % A real process restart doesn't just stop the HTTP listener -- it
    % also wipes every in-memory harness_rec/3 fact, which server_stop
    % alone can't reproduce inside one long-lived test process. So this
    % also forgets the in-memory fact directly (module-qualified --
    % harness_rec/3 isn't part of codex_harness's public API, same as
    % the equivalent whitebox tests in test_codex_harness.pl), leaving
    % ONLY what persist_state/1 already wrote to disk, before
    % restarting the server and confirming GET /coplex/harnesses/<id>
    % still works -- this is the same durability guarantee proven at
    % the Prolog level in test_codex_harness.pl's
    % rehydrate_restores_messages_and_answer, but exercised through a
    % genuine stop/start of the real HTTP server. The server is
    % managed by hand (not the usual setup(setup_server)/
    % cleanup(teardown_server) test options) since the test itself
    % needs to stop and restart it partway through; the outer
    % setup_call_cleanup/3 still guarantees a final server_stop and
    % temp-directory cleanup even if an assertion fails midway.
    tmp_root(Root),
    setup_call_cleanup(
        true,
        harness_survives_restart_(Root),
        ( catch(server_stop, _, true),
          cleanup_tmp_root(Root)
        )).

harness_survives_restart_(Root) :-
    setup_server,
    base_url(Base),
    atomic_list_concat([Base, '/coplex/harnesses'], HarnessesUrl),
    http_post_json(HarnessesUrl,
                   _{root:Root, adapter:"scripted",
                     mock_replies:[_{content:"before restart", tool_calls:[]}]},
                   Created),
    assertion(Created.ok == true),
    Id = Created.id,
    format(atom(RunUrl), '~w/coplex/harnesses/~w/run', [Base, Id]),
    http_post_json(RunUrl, _{task:"say hi"}, RunReply),
    assertion(RunReply.ok == true),
    assertion(RunReply.answer == "before restart"),
    server_stop,
    forget_harness_rec(Id),
    test_port(Port),
    server_start(Port, localhost),
    wait_healthy(Port, 50),
    format(atom(ItemUrl), '~w/coplex/harnesses/~w', [Base, Id]),
    http_get_json(ItemUrl, _{}, SnapAfter),
    assertion(SnapAfter.ok == true),
    assertion(SnapAfter.last_answer == "before restart"),
    assertion(SnapAfter.running == false),
    http_delete_json(ItemUrl, _).

forget_harness_rec(IdAtomOrString) :-
    atom_string(Id, IdAtomOrString),
    codex_harness:harness_rec(Id, Mutex, _),
    retractall(codex_harness:harness_rec(Id, _, _)),
    catch(mutex_destroy(Mutex), _, true).

:- end_tests(codex_harness_server).
