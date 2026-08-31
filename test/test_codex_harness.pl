:- encoding(utf8).
:- use_module('../prolog/coplex/codex_harness').
:- use_module(library(plunit)).
:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).

% Every mutate/2 call now persists a JSON snapshot (see
% codex_harness.pl's persist_state/1) unless redirected -- so this
% suite must redirect it to a throwaway temp directory *before*
% creating a single harness, or it would read/write the real
% production runtime directory a live server might be using
% concurrently. A fresh uuid-named directory per suite run keeps
% consecutive runs from ever seeing each other's leftovers too.
:- initialization(( current_prolog_flag(tmp_dir, Tmp),
                     uuid(StateUid),
                     directory_file_path(Tmp, StateUid, StateDir),
                     set_coplex_state_dir(StateDir)
                   )).

:- begin_tests(codex_harness).

tmp_repo(Dir) :-
    current_prolog_flag(tmp_dir, Tmp),
    uuid(Id),
    directory_file_path(Tmp, Id, Dir),
    make_directory(Dir),
    directory_file_path(Dir, 'README.md', Readme),
    setup_call_cleanup(
        open(Readme, write, Out, [encoding(utf8)]),
        write(Out, "hello harness\nline two\n"),
        close(Out)),
    directory_file_path(Dir, 'src', Src),
    make_directory(Src),
    directory_file_path(Src, 'app.pl', App),
    setup_call_cleanup(
        open(App, write, Out2, [encoding(utf8)]),
        write(Out2, "main :- writeln(ok).\n"),
        close(Out2)).

cleanup_repo(Dir) :-
    catch(delete_directory_and_contents(Dir), _, true).

with_h(Opts, Goal) :-
    harness_new(Opts, H),
    setup_call_cleanup(true, once(call(Goal, H)), harness_close(H)).

test(new_close) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        once((  harness_new([root(Dir)], H),
                H = codex_harness(_),
                harness_close(H)
             )),
        cleanup_repo(Dir)).

test(scripted_final_answer) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"done", tool_calls:[]}])],
               run_eq("task", "done")),
        cleanup_repo(Dir)).

run_eq(Task, Expected, H) :-
    harness_run(H, Task, Answer),
    assertion(Answer == Expected).

test(read_file_tool) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)],
               call_tool(read_file, _{path:"README.md"}, ok_content("hello harness"))),
        cleanup_repo(Dir)).

ok_content(Prefix, R) :-
    assertion(R.ok == true),
    sub_string(R.content, 0, _, _, Prefix).

call_tool(Name, Args, Check, H) :-
    harness_tool(H, Name, Args, R),
    call(Check, R).

test(write_and_read_roundtrip) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], write_read),
        cleanup_repo(Dir)).

write_read(H) :-
    harness_tool(H, write_file, _{path:"notes.txt", content:"abc"}, W),
    assertion(W.ok == true),
    harness_tool(H, read_file, _{path:"notes.txt"}, R),
    assertion(R.content == "abc").

test(list_files_and_info) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], list_info),
        cleanup_repo(Dir)).

list_info(H) :-
    harness_tool(H, list_files, _{path:".", max_entries:50}, L),
    assertion(L.ok == true),
    assertion(is_list(L.files)),
    harness_tool(H, file_info, _{path:"README.md"}, I),
    assertion(I.ok == true),
    assertion(I.type == file),
    assertion(I.size > 0).

test(make_directory) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], mkdir),
        cleanup_repo(Dir)).

mkdir(H) :-
    harness_tool(H, make_directory, _{path:"out/nested"}, R),
    assertion(R.ok == true).

test(search_fallback) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], search_hello),
        cleanup_repo(Dir)).

search_hello(H) :-
    harness_tool(H, search, _{query:"hello", path:"."}, R),
    assertion(R.ok == true),
    assertion(R.matches \== []).

test(path_escape_denied) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], escape_denied),
        cleanup_repo(Dir)).

escape_denied(H) :-
    harness_tool(H, read_file, _{path:"../secret.txt"}, R),
    assertion(R.ok == false),
    assertion(R.error.type == permission_error).

test(apply_patch_ok) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], patch_ok),
        cleanup_repo(Dir)).

patch_ok(H) :-
    Patch = "--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n-hello harness\n+hello patched\n line two\n",
    harness_tool(H, apply_patch, _{patch:Patch}, R),
    assertion(R.ok == true),
    harness_tool(H, read_file, _{path:"README.md"}, F),
    sub_string(F.content, _, _, _, "hello patched").

test(apply_patch_reject_no_write) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], patch_bad),
        cleanup_repo(Dir)).

patch_bad(H) :-
    harness_tool(H, read_file, _{path:"README.md"}, Before),
    Patch = "--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n-NOT IN FILE\n+changed\n line two\n",
    harness_tool(H, apply_patch, _{patch:Patch}, R),
    assertion(R.ok == false),
    harness_tool(H, read_file, _{path:"README.md"}, After),
    assertion(After.content == Before.content).

test(shell_disabled_by_default) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], shell_off),
        cleanup_repo(Dir)).

shell_off(H) :-
    harness_tool(H, shell, _{command:"swipl", args:["--version"]}, R),
    assertion(R.ok == false),
    assertion(R.error.type == permission_error).

test(shell_enabled_argv) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), allow_shell(true)], shell_on),
        cleanup_repo(Dir)).

shell_on(H) :-
    harness_tool(H, shell, _{command:"swipl", args:["--version"]}, R),
    assertion(R.ok == true),
    assertion(R.exit_code == 0),
    string_concat(R.stdout, R.stderr, Out),
    sub_string(Out, _, _, _, "SWI-Prolog").

test(network_disabled) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], net_off),
        cleanup_repo(Dir)).

net_off(H) :-
    harness_tool(H, web_get, _{url:"https://example.com/"}, R),
    assertion(R.ok == false),
    assertion(R.error.type == permission_error).

test(loopback_blocked_even_with_network) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), allow_network(true)], loopback),
        cleanup_repo(Dir)).

loopback(H) :-
    harness_tool(H, web_get, _{url:"http://127.0.0.1/"}, R),
    assertion(R.ok == false).

test(unknown_tool) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], unk),
        cleanup_repo(Dir)).

unk(H) :-
    harness_tool(H, explode_disk, _{}, R),
    assertion(R.ok == false),
    assertion(R.error.type == unknown_tool).

test(approval_deny) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval(user:deny_write)], deny_w),
        cleanup_repo(Dir)).

user:deny_write(write_file, _, deny("no writes")) :- !.
user:deny_write(_, _, allow).

deny_w(H) :-
    harness_tool(H, write_file, _{path:"x.txt", content:"z"}, R),
    assertion(R.ok == false),
    assertion(R.error.type == denied).

test(max_steps_stops) :-
    tmp_repo(Dir),
    Replies = [
        _{content:"again",
          tool_calls:[_{id:"1", name:file_info, arguments:_{path:"README.md"}}]},
        _{content:"again",
          tool_calls:[_{id:"2", name:file_info, arguments:_{path:"README.md"}}]},
        _{content:"again",
          tool_calls:[_{id:"3", name:file_info, arguments:_{path:"README.md"}}]}
    ],
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted), max_steps(2), mock_replies(Replies)],
               max_stop),
        cleanup_repo(Dir)).

max_stop(H) :-
    harness_run(H, "loop", Answer),
    sub_string(Answer, _, _, _, "maximum iteration").

test(messages_persist_and_reset) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"a", tool_calls:[]}])],
               persist_reset),
        cleanup_repo(Dir)).

persist_reset(H) :-
    harness_run(H, "one", _),
    harness_messages(H, Ms1),
    assertion(Ms1 \== []),
    harness_reset(H),
    harness_messages(H, Ms2),
    assertion(Ms2 == []).

test(snapshot_shape) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], snap),
        cleanup_repo(Dir)).

snap(H) :-
    harness_snapshot(H, S),
    assertion(get_dict(running, S, false)),
    assertion(get_dict(iteration, S, 0)),
    assertion(get_dict(messages, S, [])).

test(scripted_tool_loop) :-
    tmp_repo(Dir),
    Replies = [
        _{content:"reading",
          tool_calls:[_{id:"c1", name:read_file, arguments:_{path:"README.md"}}]},
        _{content:"README mentions harness", tool_calls:[]}
    ],
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted), mock_replies(Replies)],
               tool_loop),
        cleanup_repo(Dir)).

tool_loop(H) :-
    harness_run(H, "What is in README?", Answer),
    assertion(Answer == "README mentions harness"),
    harness_messages(H, Msgs),
    include(is_tool_msg, Msgs, ToolMsgs),
    assertion(ToolMsgs \== []).

is_tool_msg(M) :- get_dict(role, M, tool).

test(subagents_analysis_only) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"child done", tool_calls:[]}])],
               sub_only),
        cleanup_repo(Dir)).

sub_only(H) :-
    harness_tool(H, subagents, _{tasks:["Describe README"]}, R),
    assertion(R.ok == true),
    assertion(is_list(R.results)).

test(web_search_backend) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), allow_network(true),
                web_search_backend(user:fake_search)],
               search_back),
        cleanup_repo(Dir)).

user:fake_search(Query, [_{title:"hit", query:Query}]).

search_back(H) :-
    harness_tool(H, web_search, _{query:"swipl"}, R),
    assertion(R.ok == true),
    assertion(R.results \== []).

test(run_tests_explicit_command) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), default_test_command(["swipl","--version"])],
               run_t),
        cleanup_repo(Dir)).

run_t(H) :-
    harness_tool(H, run_tests, _{}, R),
    assertion(R.exit_code == 0).

test(run_tests_ignores_override_without_shell) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), default_test_command(["swipl","--version"])],
               run_t_override_ignored),
        cleanup_repo(Dir)).

run_t_override_ignored(H) :-
    % allow_shell defaults to false, so an explicit command/args override
    % must be ignored in favor of the configured/auto-detected test
    % command -- otherwise run_tests would bypass tool_shell's permission
    % gate entirely.
    harness_tool(H, run_tests, _{command:"this-binary-does-not-exist-xyz", args:[]}, R),
    assertion(R.exit_code == 0).

test(tool_specs_nonempty) :-
    harness_tool_specs(S),
    assertion(S \== []).

test(git_status_and_log) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), allow_shell(true)], git_ops),
        cleanup_repo(Dir)).

git_ops(H) :-
    harness_tool(H, git_status, _{}, R),
    assertion(R.ok == true),
    assertion(R.tool == git_status),
    harness_tool(H, git_log, _{max_count:5}, L),
    assertion(L.ok == true),
    harness_tool(H, git_diff, _{}, D),
    assertion(D.ok == true).

test(git_show_head) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_git_repo(Dir),
        cleanup_repo(Dir)).

with_git_repo(Dir) :-
    init_git_repo(Dir),
    harness_new([root(Dir), allow_shell(true)], H),
    setup_call_cleanup(
        true,
        (   harness_tool(H, git_show, _{revision:"HEAD"}, R),
            assertion(R.ok == true)
        ),
        harness_close(H)).

init_git_repo(Dir) :-
    process_create(path(git), ["init","-q"],
                   [cwd(Dir), stdout(null), stderr(null), process(P1)]),
    process_wait(P1, _),
    process_create(path(git), ["-c","user.email=t@example.com",
                               "-c","user.name=Test",
                               "add","."],
                   [cwd(Dir), stdout(null), stderr(null), process(P2)]),
    process_wait(P2, _),
    process_create(path(git), ["-c","user.email=t@example.com",
                               "-c","user.name=Test",
                               "commit","-q","-m","init"],
                   [cwd(Dir), stdout(null), stderr(null), process(P3)]),
    process_wait(P3, _).

test(cancel_stops_run) :-
    tmp_repo(Dir),
    Replies = [
        _{content:"step",
          tool_calls:[_{id:"1", name:file_info, arguments:_{path:"README.md"}}]},
        _{content:"step",
          tool_calls:[_{id:"2", name:file_info, arguments:_{path:"README.md"}}]},
        _{content:"step",
          tool_calls:[_{id:"3", name:file_info, arguments:_{path:"README.md"}}]}
    ],
    setup_call_cleanup(
        true,
        with_cancel_h(Dir, Replies),
        cleanup_repo(Dir)).

with_cancel_h(Dir, Replies) :-
    context_module(M),
    harness_new([root(Dir), adapter(scripted), mock_replies(Replies),
                 on_event(M:cancel_after_first_tool(H))],
                H),
    setup_call_cleanup(
        true,
        once(cancel_run(H)),
        harness_close(H)).

cancel_after_first_tool(H, Event) :-
    (   get_dict(type, Event, tool_finish)
    ->  harness_cancel(H)
    ;   true
    ).

cancel_run(H) :-
    harness_run(H, "loop", Answer),
    assertion(sub_string(Answer, _, _, _, "cancel")),
    harness_snapshot(H, S),
    assertion(S.cancelled == true).

test(transcript_written) :-
    tmp_repo(Dir),
    directory_file_path(Dir, 'transcript.jsonl', Transcript),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted), transcript(Transcript),
                mock_replies([_{content:"logged", tool_calls:[]}])],
               transcript_run(Transcript)),
        cleanup_repo(Dir)).

transcript_run(Transcript, H) :-
    harness_run(H, "say something", _),
    assertion(exists_file(Transcript)),
    read_file_to_string(Transcript, Text, [encoding(utf8)]),
    assertion(Text \== ""),
    sub_string(Text, _, _, _, "logged").

test(harness_list_tracks_live_instances) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        once(( harness_list(Before),
               harness_new([root(Dir)], codex_harness(Id)),
               harness_list(During),
               assertion(\+ memberchk(Id, Before)),
               assertion(memberchk(Id, During)),
               harness_close(codex_harness(Id)),
               harness_list(After),
               assertion(\+ memberchk(Id, After))
             )),
        cleanup_repo(Dir)).

/* ---------------- openai_chat_adapter ---------------- */

%   A minimal stand-in for a real OpenAI-compatible endpoint: a real
%   localhost HTTP server (not a mock/stub function call), so these
%   tests exercise the *entire* pipeline -- request translation, the
%   actual HTTP POST with an Authorization header, response parsing,
%   and the harness's own tool-execution loop -- exactly like talking
%   to a real hosted model, without costing an API call or requiring
%   network egress (staying within this file's "everything is
%   hermetic" testing philosophy; see docs/06-testing.md).
:- dynamic openai_stub_turn/1.
:- dynamic openai_stub_auth/1.

openai_stub_port(8798).

start_openai_stub :-
    retractall(openai_stub_turn(_)),
    retractall(openai_stub_auth(_)),
    asserta(openai_stub_turn(0)),
    openai_stub_port(Port),
    catch(http_stop_server(Port, []), _, true),
    http_server(http_dispatch, [port(Port)]).

stop_openai_stub :-
    openai_stub_port(Port),
    catch(http_stop_server(Port, []), _, true).

openai_stub_url(Url) :-
    openai_stub_port(Port),
    format(atom(Url), 'http://localhost:~w/v1/chat/completions', [Port]).

:- http_handler('/v1/chat/completions', openai_stub_handler, []).

%   Turn 1: "decide" to call read_file(README.md); turn 2 (once it
%   sees the tool result in the incoming messages): give a final
%   plain-text answer. This proves the harness really drove a genuine
%   multi-turn tool-calling loop against the wire format an actual
%   OpenAI-compatible API uses (JSON-*string* `arguments`, `null`
%   content alongside tool_calls, etc.), not just a single canned
%   reply.
openai_stub_handler(Request) :-
    (   memberchk(authorization(Auth), Request)
    ->  true
    ;   Auth = none
    ),
    assertz(openai_stub_auth(Auth)),
    http_read_json_dict(Request, _Body),
    retract(openai_stub_turn(N0)),
    N is N0 + 1,
    asserta(openai_stub_turn(N)),
    openai_stub_reply(N, Reply),
    reply_json_dict(Reply).

openai_stub_reply(1,
    _{choices:[_{message:_{
        role:"assistant", content:null,
        tool_calls:[_{id:"call_1", type:"function",
                      function:_{name:"read_file",
                                 arguments:"{\"path\":\"README.md\"}"}}]}}]}) :- !.
openai_stub_reply(_,
    _{choices:[_{message:_{
        role:"assistant", content:"Task complete: file has 2 lines."}}]}).

test(openai_adapter_full_tool_loop) :-
    tmp_repo(Dir),
    openai_stub_url(Url),
    setup_call_cleanup(
        start_openai_stub,
        openai_loop(Dir, Url),
        (   stop_openai_stub,
            cleanup_repo(Dir)
        )).

openai_loop(Dir, Url) :-
    harness_new([root(Dir), adapter(openai), allow_network(true),
                 allowed_hosts([localhost]),
                 adapter_url(Url), adapter_api_key("sk-test-123")], H),
    setup_call_cleanup(
        true,
        (   harness_run(H, "Read the README", Answer),
            assertion(sub_string(Answer, _, _, _, "Task complete")),
            assertion(openai_stub_turn(2)),
        once(openai_stub_auth(SeenAuth)),
            assertion(SeenAuth \== none),
            harness_messages(H, Msgs),
            assertion(is_list(Msgs)),
            length(Msgs, L),
            assertion(L >= 4)   % user + assistant(call) + tool + assistant(final)
        ),
        harness_close(H)).

test(openai_adapter_requires_allow_network) :-
    % adapter(openai) must not silently attempt a network call when
    % allow_network is left at its (secure) default of false.
    tmp_repo(Dir),
    openai_stub_url(Url),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(openai), adapter_url(Url)],
               network_off_adapter),
        cleanup_repo(Dir)).

network_off_adapter(H) :-
    harness_run(H, "do something", Answer),
    harness_snapshot(H, Snap),
    assertion(sub_string(Answer, _, _, _, "Harness error")),
    assertion(Snap.last_error.type == harness_error),
    assertion(sub_string(Snap.last_error.message, _, _, _, "Network access is disabled")).

test(openai_adapter_respects_allowed_hosts) :-
    % adapter_url must be checked against allowed_hosts exactly like
    % any other outbound URL a caller chooses to restrict.
    tmp_repo(Dir),
    openai_stub_url(Url),
    setup_call_cleanup(
        start_openai_stub,
        disallowed_host_adapter(Dir, Url),
        (   stop_openai_stub,
            cleanup_repo(Dir)
        )).

disallowed_host_adapter(Dir, Url) :-
    harness_new([root(Dir), adapter(openai), allow_network(true),
                 allowed_hosts(['example.com']), adapter_url(Url)], H),
    setup_call_cleanup(
        true,
        (   harness_run(H, "do something", Answer),
            harness_snapshot(H, Snap),
            assertion(sub_string(Answer, _, _, _, "Harness error")),
            assertion(sub_string(Snap.last_error.message, _, _, _, "allowlist")),
            assertion(openai_stub_turn(0))   % stub was never actually hit
        ),
        harness_close(H)).

test(openai_json_schema_of_params) :-
    % Pure translation check for the lightweight per-tool param dicts
    % (see harness_tool_specs/1) -> JSON Schema, independent of any
    % networking.
    codex_harness:json_schema_of_params(
        _{path:string, offset:integer, ok:boolean, args:list}, Schema),
    assertion(Schema.type == "object"),
    assertion(Schema.properties.path.type == "string"),
    assertion(Schema.properties.offset.type == "integer"),
    assertion(Schema.properties.ok.type == "boolean"),
    assertion(Schema.properties.args.type == "array").

% -- interactive approval workflow ------------------------------------
%
% approval_mode(interactive) makes a risky tool call block (in its own
% thread -- harness_tool/4 is synchronous from the caller's point of
% view) until harness_decide_approval/3 resolves it from elsewhere, so
% these tests always drive the blocked call from a background thread
% and resolve it from the main test thread, polling harness_snapshot/2
% for the pending_approvals entry the way a real REST client would.

wait_for_pending(_, 0, _) :- !, fail.
wait_for_pending(H, N, CallId) :-
    harness_snapshot(H, Snap),
    get_dict(pending_approvals, Snap, Pending),
    (   Pending = [First|_]
    ->  get_dict(call_id, First, CallId)
    ;   sleep(0.05),
        N1 is N - 1,
        wait_for_pending(H, N1, CallId)
    ).

test(approval_interactive_allow) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(interactive), approval_timeout(10)],
               interactive_allow),
        cleanup_repo(Dir)).

interactive_allow(H) :-
    thread_create(harness_tool(H, write_file, _{path:"a.txt", content:"hi"}, _), Tid, []),
    wait_for_pending(H, 100, CallId),
    harness_decide_approval(H, CallId, allow),
    thread_join(Tid, _),
    harness_tool(H, read_file, _{path:"a.txt"}, R),
    assertion(get_dict(ok, R, true)),
    assertion(get_dict(content, R, "hi")).

test(approval_interactive_deny) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(interactive), approval_timeout(10)],
               interactive_deny),
        cleanup_repo(Dir)).

interactive_deny(H) :-
    thread_create(harness_tool(H, write_file, _{path:"b.txt", content:"hi"}, _), Tid, []),
    wait_for_pending(H, 100, CallId),
    harness_decide_approval(H, CallId, deny),
    thread_join(Tid, _),
    harness_tool(H, read_file, _{path:"b.txt"}, R),
    assertion(get_dict(ok, R, false)),
    get_dict(error, R, Error),
    assertion(get_dict(type, Error, not_found)).

test(approval_read_only_bypasses_gating) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(interactive), approval_timeout(10)],
               read_only_bypass),
        cleanup_repo(Dir)).

read_only_bypass(H) :-
    % git_status is read_only risk -- must run immediately, never
    % appearing in pending_approvals, regardless of approval_mode.
    harness_tool(H, git_status, _{}, R),
    assertion(get_dict(ok, R, true)),
    harness_snapshot(H, Snap),
    assertion(get_dict(pending_approvals, Snap, [])).

test(approval_deny_risky_denies_without_pause) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(deny_risky)], deny_risky_fast),
        cleanup_repo(Dir)).

deny_risky_fast(H) :-
    get_time(T0),
    harness_tool(H, write_file, _{path:"c.txt", content:"hi"}, R),
    get_time(T1),
    assertion(get_dict(ok, R, false)),
    get_dict(error, R, Error),
    assertion(get_dict(type, Error, denied)),
    assertion((T1 - T0) < 1.0).

test(approval_timeout_auto_denies) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(interactive), approval_timeout(1)],
               timeout_auto_deny),
        cleanup_repo(Dir)).

timeout_auto_deny(H) :-
    get_time(T0),
    harness_tool(H, write_file, _{path:"d.txt", content:"hi"}, R),
    get_time(T1),
    assertion(get_dict(ok, R, false)),
    get_dict(error, R, Error),
    assertion(get_dict(type, Error, denied)),
    assertion(sub_string(Error.message, _, _, _, "timed out")),
    assertion((T1 - T0) >= 0.9).

test(approval_visible_in_snapshot_and_summary) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), approval_mode(interactive), approval_timeout(10)],
               visible_pending),
        cleanup_repo(Dir)).

visible_pending(H) :-
    thread_create(harness_tool(H, write_file, _{path:"f.txt", content:"hi"}, _), Tid, []),
    wait_for_pending(H, 100, CallId),
    harness_snapshot(H, Snap),
    get_dict(pending_approvals, Snap, [Pending|_]),
    assertion(get_dict(call_id, Pending, CallId)),
    assertion(get_dict(tool, Pending, write_file)),
    assertion(get_dict(risk, Pending, write)),
    harness_summary(H, Summary),
    assertion(get_dict(pending_approval_count, Summary, 1)),
    harness_decide_approval(H, CallId, deny),
    thread_join(Tid, _).

test(approval_harness_close_denies_pending) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_close_h(Dir),
        cleanup_repo(Dir)).

with_close_h(Dir) :-
    harness_new([root(Dir), approval_mode(interactive), approval_timeout(30)], H),
    thread_create(harness_tool(H, write_file, _{path:"g.txt", content:"hi"}, _), Tid, []),
    wait_for_pending(H, 100, _CallId),
    get_time(T0),
    harness_close(H),
    get_time(T1),
    assertion((T1 - T0) < 2.0),
    thread_join(Tid, _).

test(approval_unknown_call_id_errors, [error(existence_error(pending_approval, "does-not-exist"), _)]) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], unknown_call_id),
        cleanup_repo(Dir)).

unknown_call_id(H) :-
    harness_decide_approval(H, "does-not-exist", allow).

% -- disk persistence (survive a server restart) ----------------------
%
% This whole file's coplex_state_dir is already redirected to an
% isolated temp directory by the :- initialization/1 directive near
% the top -- every test below shares that one directory (a fresh
% per-harness uuid filename means no collision), so none of these
% need their own setup for that part. rehydrate_harnesses/0,
% harness_state_file/2, and mutate/2 aren't part of this module's
% public API (see the export list) -- these tests reach them via
% module-qualification the same way openai_json_schema_of_params
% above already reaches codex_harness:json_schema_of_params/2, since
% this *is* the whitebox test suite for codex_harness itself.

state_file_for(codex_harness(Id), File) :-
    codex_harness:harness_state_file(Id, File).

forget_in_memory(codex_harness(Id)) :-
    codex_harness:harness_rec(Id, Mutex, _),
    retractall(codex_harness:harness_rec(Id, _, _)),
    catch(mutex_destroy(Mutex), _, true).

force_running_true(codex_harness(Id)) :-
    codex_harness:mutate(Id, start_run("simulated in-flight task")).

same_text(A, B) :- atom_string(A, S), atom_string(B, S), !.

test(persist_writes_json_file) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"hi", tool_calls:[]}])],
               persist_writes),
        cleanup_repo(Dir)).

persist_writes(H) :-
    harness_run(H, "say hi", _),
    state_file_for(H, File),
    assertion(exists_file(File)).

test(persist_never_writes_secrets) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(openai), allow_network(true),
                adapter_api_key("sk-super-secret-value")],
               persist_no_secrets),
        cleanup_repo(Dir)).

persist_no_secrets(H) :-
    harness_tool(H, git_status, _{}, _),
    state_file_for(H, File),
    read_file_to_string(File, Text, []),
    assertion(\+ sub_string(Text, _, _, _, "sk-super-secret-value")).

test(harness_close_deletes_persisted_file) :-
    tmp_repo(Dir),
    harness_new([root(Dir)], H),
    harness_tool(H, git_status, _{}, _),
    state_file_for(H, File),
    assertion(exists_file(File)),
    harness_close(H),
    assertion(\+ exists_file(File)),
    cleanup_repo(Dir).

test(rehydrate_restores_messages_and_answer) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"final answer", tool_calls:[]}])],
               rehydrate_restores),
        cleanup_repo(Dir)).

rehydrate_restores(H) :-
    harness_run(H, "do the thing", Answer),
    harness_snapshot(H, SnapBefore),
    % Simulate a process restart: forget the in-memory fact WITHOUT
    % deleting the disk file, then rehydrate.
    forget_in_memory(H),
    rehydrate_harnesses,
    harness_snapshot(H, SnapAfter),
    assertion(same_text(SnapAfter.last_answer, Answer)),
    length(SnapAfter.messages, Len),
    length(SnapBefore.messages, Len0),
    assertion(Len == Len0),
    assertion(SnapAfter.running == false).

test(rehydrate_marks_interrupted_run) :-
    tmp_repo(Dir),
    harness_new([root(Dir)], H),
    force_running_true(H),
    forget_in_memory(H),
    rehydrate_harnesses,
    harness_snapshot(H, Snap),
    assertion(Snap.running == false),
    assertion(Snap.last_error.type == harness_error),
    assertion(sub_atom(Snap.last_error.message, _, _, _, restart)),
    harness_close(H),
    cleanup_repo(Dir).

test(rehydrate_is_idempotent) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], rehydrate_idempotent),
        cleanup_repo(Dir)).

rehydrate_idempotent(H) :-
    harness_tool(H, git_status, _{}, _),
    rehydrate_harnesses,
    rehydrate_harnesses,
    harness_list(Ids),
    H = codex_harness(Id),
    include(==(Id), Ids, Matches),
    length(Matches, 1).

test(rehydrated_harness_stays_functional) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted),
                mock_replies([_{content:"first run", tool_calls:[]}])],
               rehydrated_still_works),
        cleanup_repo(Dir)).

rehydrated_still_works(H) :-
    harness_run(H, "one", _),
    forget_in_memory(H),
    rehydrate_harnesses,
    % A rehydrated scripted-adapter harness already consumed its
    % original mock_replies, so drive it via harness_tool/4 instead of
    % a second harness_run/3 -- this still proves the adapter is
    % genuinely live (adapter_kind round-tripped through
    % wrap_adapter/3), not a dead placeholder.
    harness_tool(H, git_status, _{}, Result),
    assertion(Result.ok == true).

test(rehydrate_preserves_sentinel_option_values) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir)], rehydrate_sentinels),
        cleanup_repo(Dir)).

rehydrate_sentinels(H) :-
    % allowed_tools defaults to `all`, transcript defaults to `none` --
    % both come back from disk as JSON *strings* unless
    % rehydrate_harnesses/0 reads them back as atoms
    % (json_read_dict/3's value_string_as(atom)), which is exactly the
    % bug this guards against: allowed_tool_name/2 checks
    % `S.allowed_tools == all` and persist_msg/2 checks
    % `S.transcript == none`, both plain atom `==/2` comparisons that
    % would silently break (denying every tool / trying to open a file
    % literally named "none") if either sentinel came back as a string.
    harness_tool(H, git_status, _{}, R0),
    assertion(R0.ok == true),
    forget_in_memory(H),
    rehydrate_harnesses,
    harness_tool(H, git_status, _{}, R1),
    assertion(R1.ok == true),
    harness_tool(H, write_file, _{path:"s.txt", content:"x"}, R2),
    assertion(R2.ok == true).

:- end_tests(codex_harness).
