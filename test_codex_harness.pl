:- encoding(utf8).
:- use_module(codex_harness).
:- use_module(library(plunit)).
:- use_module(library(filesex)).
:- use_module(library(uuid)).

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

:- end_tests(codex_harness).
