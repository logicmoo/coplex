:- encoding(utf8).
:- module(codex_harness,
          [ harness_new/2,
            harness_close/1,
            harness_run/3,
            harness_run/4,
            harness_run_async/3,
            harness_cancel/1,
            harness_reset/1,
            harness_messages/2,
            harness_snapshot/2,
            harness_summary/2,
            harness_tool/4,
            harness_tool_specs/1,
            harness_list/1,
            harness_decide_approval/3,
            scripted_adapter/3,
            http_json_adapter/3,
            openai_chat_adapter/3
          ]).

/** <module> Codex/Copilot-style coding-agent harness

One self-contained SWI-Prolog object abstraction: public terms are
`codex_harness(Id)`.  Mutable state lives in private dynamic facts keyed
by Id and is guarded by a per-instance mutex.

The agent loop is provider-agnostic.  A caller supplies

==
adapter(Adapter)
==

and the harness invokes `call(Adapter, RequestDict, ReplyDict)`.

Normalized request:

==
_{ model:Model, instructions:Instructions, messages:Messages,
   tools:ToolSpecs, options:RunOptions }
==

Normalized reply:

==
_{ content:"assistant text",
   tool_calls:[ _{id:"...", name:"read_file", arguments:_{path:"README.md"}} ] }
==

An empty `tool_calls` list is the final answer.

Safe default for `subagents`: concurrent analysis only.  Editing, shell,
and network tools are denied in child harnesses unless
`subagent_allow_writes(true)` is set.  That avoids conflicting writes
without requiring Git worktrees.

@see README.md
*/

:- use_module(library(apply)).
:- use_module(library(debug)).
:- use_module(library(error)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(pairs)).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(thread)).
:- use_module(library(uri)).
:- use_module(library(uuid)).
:- use_module(library(http/json)).

:- dynamic harness_rec/3.          % harness_rec(Id, Mutex, StateDict)

% Enable with ?- debug(codex_harness).

%!  default_instructions(-Text) is det.
default_instructions(Text) :-
    Text = "You are a coding agent working inside a repository through tools.\n\
- Inspect the repository before assuming its structure.\n\
- Search before editing.\n\
- Preserve unrelated user changes.\n\
- Make focused, reviewable edits.\n\
- Use apply_patch for modifications when appropriate.\n\
- Run relevant tests and diagnose failures.\n\
- Never claim a command, edit, or test succeeded without a successful tool result.\n\
- Continue until the requested work is implemented and verified.\n\
- Ask the user only when a material decision or additional authority is required.\n\
- Avoid destructive commands.\n\
- Use parallel subagents only for independent analysis tasks.\n\
- Summarize changes, tests, and remaining limitations at completion.\n".

%!  harness_tool_specs(-Specs) is det.
harness_tool_specs(Specs) :-
    Specs = [
        spec(read_file, read_only, "Read a UTF-8 file under the repository root.",
             _{path:string, offset:integer, limit:integer}),
        spec(write_file, write, "Create or atomically replace a UTF-8 file.",
             _{path:string, content:string}),
        spec(list_files, read_only, "List files under a relative directory.",
             _{path:string, max_entries:integer}),
        spec(search, read_only, "Search file contents. Uses rg when available.",
             _{query:string, path:string, glob:string, max_results:integer, case_sensitive:boolean}),
        spec(apply_patch, write, "Apply a unified diff inside the repository.",
             _{patch:string}),
        spec(file_info, read_only, "Return size, type, and modification time.",
             _{path:string}),
        spec(make_directory, write, "Create a directory under the repository root.",
             _{path:string}),
        spec(shell, process, "Execute a program with an explicit argument list.",
             _{command:string, args:list, env:list, timeout:integer}),
        spec(run_tests, process, "Run the project test command.",
             _{command:string, args:list}),
        spec(git_status, read_only, "Read-only git status.", _{}),
        spec(git_diff, read_only, "Read-only git diff.", _{args:list}),
        spec(git_log, read_only, "Read-only git log.", _{max_count:integer}),
        spec(git_show, read_only, "Read-only git show.", _{revision:string}),
        spec(web_search, network, "Search the web via an injected backend.",
             _{query:string}),
        spec(web_get, network, "HTTP/HTTPS GET of an allowed URL.",
             _{url:string}),
        spec(download, network, "Download an allowed URL into the repository.",
             _{url:string, path:string}),
        spec(subagents, process, "Run independent analysis tasks concurrently.",
             _{tasks:list})
    ].

%!  harness_new(+Options, -Harness) is det.
harness_new(Options, codex_harness(Id)) :-
    must_be(list, Options),
    uuid(Id),
    mutex_create(Mutex, [alias(Id)]),
    default_instructions(DefI),
    option(root(Root0), Options, '.'),
    absolute_file_name(Root0, Root, [file_type(directory)]),
    option(cwd(Cwd0), Options, Root),
    absolute_file_name(Cwd0, Cwd),
    option(adapter(Adapter0), Options, scripted),
    wrap_adapter(Adapter0, Id, Adapter),
    default_model_for_adapter(Adapter0, DefModel),
    option(model(Model), Options, DefModel),
    option(instructions(Instr), Options, DefI),
    option(extra_instructions(Extra), Options, ""),
    option(allow_shell(AllowShell), Options, false),
    option(allow_network(AllowNet), Options, false),
    option(allow_shell_string(AllowSh), Options, false),
    option(allowed_hosts(Hosts), Options, []),
    option(writable_paths(WPaths), Options, []),
    option(readable_paths(RPaths), Options, []),
    option(max_output_bytes(MaxOut), Options, 1000000),
    option(max_download_bytes(MaxDl), Options, 10000000),
    option(timeout(Timeout), Options, 120),
    option(command_timeout(CmdTO), Options, 30),
    option(max_steps(MaxSteps), Options, 50),
    option(subagent_limit(SubLim), Options, 4),
    option(subagent_allow_writes(SubW), Options, false),
    option(approval(Approval), Options, none),
    option(approval_mode(ApprovalMode0), Options, none),
    normalize_approval_mode(ApprovalMode0, ApprovalMode),
    option(approval_timeout(ApprovalTO), Options, 300),
    option(on_event(OnEvent), Options, none),
    option(transcript(Transcript), Options, none),
    option(secrets(Secrets0), Options, []),
    option(default_test_command(TestCmd), Options, auto),
    option(web_search_backend(SearchB), Options, none),
    option(mock_replies(Replies), Options, []),
    option(parent(Parent), Options, none),
    option(allowed_tools(AllowedTools), Options, all),
    option(adapter_url(AdapterUrl0), Options,
           'https://api.openai.com/v1/chat/completions'),
    text_of(AdapterUrl0, AdapterUrl),
    option(adapter_api_key(ApiKey0), Options, ""),
    text_of(ApiKey0, ApiKey),
    secrets_with_adapter_key(Secrets0, ApiKey, Secrets),
    State = _{
        id:Id, adapter:Adapter, model:Model,
        instructions:Instr, extra_instructions:Extra,
        root:Root, cwd:Cwd, messages:[],
        cancelled:false, running:false,
        current_task:"", iteration:0,
        last_answer:"", last_error:null,
        tool_activity:[], subagents:[],
        max_steps:MaxSteps, timeout:Timeout,
        command_timeout:CmdTO,
        max_output_bytes:MaxOut,
        max_download_bytes:MaxDl,
        allow_shell:AllowShell,
        allow_network:AllowNet,
        allow_shell_string:AllowSh,
        allowed_hosts:Hosts,
        writable_paths:WPaths,
        readable_paths:RPaths,
        subagent_limit:SubLim,
        subagent_allow_writes:SubW,
        approval:Approval, on_event:OnEvent,
        approval_mode:ApprovalMode,
        approval_timeout:ApprovalTO,
        transcript:Transcript, secrets:Secrets,
        default_test_command:TestCmd,
        web_search_backend:SearchB,
        mock_script:Replies,
        fail_signatures:[],
        call_seq:0,
        parent:Parent,
        allowed_tools:AllowedTools,
        adapter_url:AdapterUrl,
        adapter_api_key:ApiKey,
        created_at:0
    },
    get_time(Now),
    State1 = State.put(created_at, Now),
    assertz(harness_rec(Id, Mutex, State1)),
    debug(codex_harness, 'created ~w root=~w', [Id, Root]).

%!  normalize_approval_mode(+Raw, -Mode) is det.
%
%   Mode is always one of a fixed, closed set of atoms -- `none`
%   (default: no interactive gating; today's behaviour), `interactive`
%   (any tool call whose risk isn't `read_only` pauses -- see
%   wait_for_approval/6 -- until a REST decision or approval_timeout/1
%   arrives), or `deny_risky` (same risky-tool trigger, but denied
%   immediately with no pause -- for unattended REST automation that
%   still wants read-only-safe behaviour without a human present).
%   Anything else -- including a string from JSON -- normalizes to
%   `none`, mirroring how sanitize_value/3 treats `adapter` in
%   coplex_server.pl: never pass an arbitrary value through unchecked.
normalize_approval_mode(M, M) :- memberchk(M, [none, interactive, deny_risky]), !.
normalize_approval_mode("interactive", interactive) :- !.
normalize_approval_mode("deny_risky", deny_risky) :- !.
normalize_approval_mode(_, none).

%!  default_model_for_adapter(+Adapter, -Model) is det.
%   `scripted`/`mock` never look at `model` at all, so `default` stays
%   an inert placeholder for them; `openai` needs a real, callable
%   model name, so it gets a concrete default a caller can still
%   override with the ordinary `model` option.
default_model_for_adapter(openai, "gpt-4o-mini") :- !.
default_model_for_adapter(_, default).

%!  secrets_with_adapter_key(+Secrets0, +ApiKey, -Secrets) is det.
%   Folds a configured adapter_api_key into the harness's redaction
%   list (see redact_result/3) so it can never leak back out through a
%   tool result or emitted event, on top of never being included in
%   any request body in the first place (see openai_chat_adapter/3 --
%   it's only ever used to build an outbound Authorization header).
secrets_with_adapter_key(Secrets0, "", Secrets0) :- !.
secrets_with_adapter_key(Secrets0, ApiKey, Secrets0) :-
    memberchk(ApiKey, Secrets0), !.
secrets_with_adapter_key(Secrets0, ApiKey, [ApiKey|Secrets0]).


wrap_adapter(scripted, Id, scripted_adapter(Id)) :- !.
wrap_adapter(mock, Id, scripted_adapter(Id)) :- !.
wrap_adapter(scripted_adapter(_), Id, scripted_adapter(Id)) :- !.
wrap_adapter(openai, Id, openai_chat_adapter(Id)) :- !.
wrap_adapter(Adapter, _, Adapter).

%!  harness_list(-Ids) is det.
%   All currently live harness ids, e.g. for an admin/REST listing.
%   Order is unspecified.
harness_list(Ids) :-
    findall(Id, harness_rec(Id, _, _), Ids).

%!  harness_close(+Harness) is det.
harness_close(codex_harness(Id)) :-
    !,
    (   harness_rec(Id, Mutex, _)
    ->  deny_all_pending_approvals(Id),
        with_mutex(Mutex,
                   (   retractall(harness_rec(Id, _, _)),
                       catch(mutex_destroy(Mutex), _, true)))
    ;   true
    ).
harness_close(Other) :-
    type_error(codex_harness, Other).

%!  harness_cancel(+Harness) is det.
harness_cancel(codex_harness(Id)) :-
    mutate(Id, cancel).

%!  harness_reset(+Harness) is det.
harness_reset(codex_harness(Id)) :-
    mutate(Id, reset).

%!  harness_messages(+Harness, -Messages) is det.
harness_messages(codex_harness(Id), Messages) :-
    state(Id, S),
    Messages = S.messages.

%!  harness_snapshot(+Harness, -Snapshot) is det.
%   UI/admin observation surface.  Independent of any HTTP server.
harness_snapshot(codex_harness(Id), Snap) :-
    state(Id, S),
    pending_approvals_for(Id, PendingApprovals),
    Snap = _{
        id:S.id,
        current_task:S.current_task,
        iteration:S.iteration,
        running:S.running,
        cancelled:S.cancelled,
        messages:S.messages,
        tool_activity:S.tool_activity,
        subagents:S.subagents,
        last_answer:S.last_answer,
        last_error:S.last_error,
        pending_approvals:PendingApprovals,
        created_at:S.created_at
    }.

%!  harness_summary(+Harness, -Summary) is det.
%
%   Lightweight per-harness status, sized for list/dashboard views
%   (e.g. a web UI rendering a table of running agents): unlike
%   harness_snapshot/2 it carries message/tool-activity *counts*
%   rather than the full histories, so listing many harnesses stays
%   cheap. `pending_approval_count` is enough for a list view's badge;
%   a detail view fetches the full `pending_approvals` array (with
%   each call's tool/risk/arguments) from harness_snapshot/2 instead.
harness_summary(codex_harness(Id), Summary) :-
    state(Id, S),
    length(S.messages, MessageCount),
    length(S.tool_activity, ToolCallCount),
    pending_approvals_for(Id, PendingApprovals),
    length(PendingApprovals, PendingApprovalCount),
    Summary = _{
        id:S.id,
        current_task:S.current_task,
        iteration:S.iteration,
        running:S.running,
        cancelled:S.cancelled,
        last_answer:S.last_answer,
        last_error:S.last_error,
        message_count:MessageCount,
        tool_call_count:ToolCallCount,
        pending_approval_count:PendingApprovalCount,
        created_at:S.created_at
    }.

%!  harness_run(+Harness, +Task, -Answer) is det.
harness_run(H, Task, Answer) :-
    harness_run(H, Task, [], Answer).

%!  harness_run(+Harness, +Task, +RunOptions, -Answer) is det.
%
%   Run Task to completion and unify Answer with the final answer.
%   Blocks the calling thread for the duration of the run (up to the
%   harness's timeout/1 option) -- see harness_run_async/3 for a
%   non-blocking alternative suited to a UI that wants to poll or
%   stream progress instead of holding a connection open.
harness_run(codex_harness(Id), Task, RunOptions, Answer) :-
    must_be(list, RunOptions),
    guard_not_running(Id),
    mutate(Id, start_run(Task)),
    run_body(Id, Task, RunOptions, Answer),
    mutate(Id, finish_run(Answer)).

%!  harness_run_async(+Harness, +Task, +RunOptions) is det.
%
%   Like harness_run/4, but returns immediately after marking the
%   harness as running/1=true; the agent loop executes to completion
%   in a separate detached thread.  Callers observe progress and the
%   eventual answer via harness_snapshot/2 (running, last_answer,
%   last_error, iteration) or harness_messages/2 -- this is the
%   non-blocking shape a REST-driven web UI needs so a "run" click
%   doesn't have to hold an HTTP request open for the whole agent
%   loop.  Throws permission_error(start, harness_run, already_running)
%   if this harness is already mid-run.
harness_run_async(codex_harness(Id), Task, RunOptions) :-
    must_be(list, RunOptions),
    guard_not_running(Id),
    mutate(Id, start_run(Task)),
    thread_create(
        ( run_body(Id, Task, RunOptions, Answer),
          mutate(Id, finish_run(Answer))
        ),
        _,
        [detached(true)]).

guard_not_running(Id) :-
    state(Id, S),
    (   S.running == true
    ->  throw(error(permission_error(start, harness_run, already_running), _))
    ;   true
    ).

%!  run_body(+Id, +Task, +RunOptions, -Answer) is det.
%   Shared timeout/error-handling wrapper around run_loop/4, used by
%   both the synchronous and async run entry points. Does not touch
%   the running/1 flag; callers are responsible for start_run/finish_run.
run_body(Id, Task, RunOptions, Answer) :-
    state(Id, S0),
    Timeout is max(1, S0.timeout),
    catch(call_with_time_limit(
              Timeout,
              run_loop(Id, Task, RunOptions, Answer)),
          Error,
          handle_run_error(Id, Error, Answer)).

handle_run_error(Id, time_limit_exceeded, Answer) :-
    !,
    Answer = "Run timed out.",
    mutate(Id, set_error(_{type:timeout, message:"overall run timeout"})).
handle_run_error(Id, cancelled, Answer) :-
    !,
    Answer = "Run cancelled.",
    mutate(Id, set_error(_{type:cancelled, message:"cancelled"})).
handle_run_error(Id, Error, Answer) :-
    term_string(Error, Msg),
    format(string(Answer), "Harness error: ~s", [Msg]),
    mutate(Id, set_error(_{type:harness_error, message:Msg})).

run_loop(Id, Task, RunOptions, Answer) :-
    state(Id, S),
    text_of(Task, TaskText),
    gather_context(S, RunOptions, Context),
    format(string(User), "~s~n~nRepository context:~n~s", [TaskText, Context]),
    mutate(Id, add_message(_{role:user, content:User})),
    emit(Id, _{type:run_start, task:TaskText}),
    loop_steps(Id, RunOptions, 0, Answer).

loop_steps(Id, _Opts, _, _) :-
    state(Id, S),
    S.cancelled == true,
    throw(cancelled).
loop_steps(Id, Opts, Step, Answer) :-
    state(Id, S),
    Max = S.max_steps,
    (   Step >= Max
    ->  Answer = "Stopped: maximum iteration count reached.",
        emit(Id, _{type:error, message:Answer})
    ;   mutate(Id, set_iteration(Step)),
        call_model(Id, Opts, Reply),
        Content = Reply.content,
        Calls = Reply.tool_calls,
        mutate(Id, add_message(_{role:assistant, content:Content, tool_calls:Calls})),
        emit(Id, _{type:model_response, content:Content, tool_calls:Calls}),
        (   Calls == []
        ->  Answer = Content,
            emit(Id, _{type:final_answer, content:Content})
        ;   maplist(run_one_tool(Id), Calls, Results),
            maplist(tool_result_message, Results, ToolMsgs),
            foldl(add_msg, ToolMsgs, Id, _),
            detect_repeat_failures(Id, Results),
            Next is Step + 1,
            loop_steps(Id, Opts, Next, Answer)
        )
    ).

add_msg(Msg, Id, Id) :-
    mutate(Id, add_message(Msg)).

tool_result_message(Res, _{role:tool, tool:Res.tool, tool_call_id:Res.get(tool_call_id, ""), content:Res}).

%!  harness_tool(+Harness, +ToolName, +Arguments, -Result) is det.
harness_tool(codex_harness(Id), Name, Args, Result) :-
    run_named_tool(Id, Name, Args, "", Result).

run_one_tool(Id, Call, Result) :-
    flex_get(id, Call, CallId, ""),
    flex_get(name, Call, Name0, unknown),
    flex_get(arguments, Call, Args0, _{}),
    name_atom(Name0, Name),
    ensure_dict(Args0, Args),
    run_named_tool(Id, Name, Args, CallId, Result).

run_named_tool(Id, Name, Args, CallId, Result) :-
    get_time(T0),
    emit(Id, _{type:tool_start, tool:Name, arguments:Args, id:CallId}),
    % A direct/harness_tool call (see harness_tool/4) always arrives
    % with CallId == "" -- fine for the result's tool_call_id field,
    % but approval_mode(interactive)'s pending-approval registry (see
    % wait_for_approval/6) is keyed by this id, so two concurrent
    % direct calls on the same harness would collide on "" and each
    % could resolve the other's approval. ApprovalKey is always
    % genuinely unique; CallId (below, in tool_call_id) is left
    % exactly as the caller passed it, unchanged. uuid/1 returns an
    % atom, but every model-driven call_id (normalize_call/2, via
    % text_of/2) is a string -- ApprovalKey is normalized to a string
    % too so a REST caller can round-trip *either* kind of call_id
    % (read from pending_approvals, posted back to .../approvals/<id>)
    % through plain unification without an atom/string mismatch
    % silently making harness_decide_approval/3 claim it doesn't exist.
    (   CallId == "" -> uuid(ApprovalKey0), atom_string(ApprovalKey0, ApprovalKey) ; ApprovalKey = CallId ),
    (   catch(guarded_tool(Id, Name, Args, ApprovalKey, Raw), E, tool_exception(Name, E, Raw))
    ->  true
    ;   Raw = _{ok:false, tool:Name, error:_{type:failed, message:"tool failed"}}
    ),
    get_time(T1),
    Dur is round((T1-T0)*1000),
    Result0 = Raw.put(_{tool:Name, duration_ms:Dur, tool_call_id:CallId}),
    % An approval_mode(interactive) wait can run for minutes (up to
    % approval_timeout/1), which is long enough for harness_close/1 to
    % have deleted Id out from under this thread in the meantime (it
    % denies every pending approval first, but that's a fire-and-
    % forget thread_send_message/2 -- see deny_all_pending_approvals/1
    % -- not a synchronous handoff). Ordinary tool calls have always
    % had a narrow version of this same race; catch/3 here turns
    % "harness vanished mid-call" into a best-effort result instead of
    % an uncaught existence_error crashing this call's thread.
    (   catch((redact_result(Id, Result0, Result1),
               mutate(Id, record_tool(Result1)),
               emit(Id, _{type:tool_finish, result:Result1})),
              error(existence_error(codex_harness, Id), _),
              fail)
    ->  Result = Result1
    ;   Result = Result0.put(_{note:"harness was deleted before this result could be recorded"})
    ).

tool_exception(Name, Error, _{ok:false, tool:Name,
                              error:_{type:exception, message:Msg}}) :-
    term_string(Error, Msg).

guarded_tool(Id, Name, Args, CallId, Result) :-
    state(Id, S),
    check_cancelled(S),
    (   allowed_tool_name(S, Name)
    ->  known_or_dispatch(S, Name, Args, CallId, Result)
    ;   Result = _{ok:false, tool:Name,
                   error:_{type:permission_error, message:"Tool not permitted in this harness"}}
    ).

known_or_dispatch(S, Name, Args, CallId, Result) :-
    harness_tool_specs(Specs),
    (   memberchk(spec(Name, Risk, _, _), Specs)
    ->  decide_tool(S, Name, Risk, Args, CallId, Result)
    ;   Result = _{ok:false, tool:Name,
                   error:_{type:unknown_tool, message:"Unknown tool"}}
    ).

allowed_tool_name(S, _) :-
    S.allowed_tools == all, !.
allowed_tool_name(S, Name) :-
    is_list(S.allowed_tools),
    memberchk(Name, S.allowed_tools).

%!  approve(+S, +Name, +Args, +Risk, +CallId, -Decision) is det.
%
%   Decision is `allow`, `deny(Why)`, or bare `deny`. Two independent
%   gates, checked in this order:
%
%     1. The existing in-process-only `approval(Goal)` callback (never
%        settable over REST -- see coplex_server.pl's
%        safe_option_key/1). If configured, it alone decides, for
%        every tool regardless of risk, exactly as before this
%        predicate grew a Risk/CallId argument.
%     2. `approval_mode/1` -- a closed, REST-safe enum (see
%        normalize_approval_mode/2) that only ever gates non-
%        `read_only` tools: `deny_risky` denies immediately, and
%        `interactive` pauses the calling thread in
%        wait_for_approval/6 until a REST decision (or
%        approval_timeout/1) arrives. `none` (the default) allows
%        everything, identical to today's behaviour with no approval
%        configured at all.
approve(S, _Name, _Args, _Risk, _CallId, allow) :-
    S.approval == none, S.approval_mode == none, !.
approve(S, Name, Args, _Risk, _CallId, Decision) :-
    S.approval \== none, !,
    Approval = S.approval,
    call(Approval, Name, Args, Decision).
approve(_, _, _, read_only, _CallId, allow) :- !.
approve(S, _, _, _Risk, _CallId, deny("Denied: approval_mode(deny_risky)")) :-
    S.approval_mode == deny_risky, !.
approve(S, Name, Args, Risk, CallId, Decision) :-
    S.approval_mode == interactive, !,
    wait_for_approval(S, Name, Args, Risk, CallId, Decision).
approve(_, Name, _, _, _, deny("Denied: no approval decision available")) :-
    debug(codex_harness, 'approve/6 fell through for tool ~w -- this should be unreachable', [Name]).

decide_tool(S, Name, Risk, Args, CallId, Result) :-
    approve(S, Name, Args, Risk, CallId, Decision),
    (   Decision == allow
    ->  dispatch_tool(Name, Risk, S, Args, Result)
    ;   Decision = deny(Why)
    ->  Result = _{ok:false, tool:Name,
                   error:_{type:denied, message:Why}}
    ;   Result = _{ok:false, tool:Name,
                   error:_{type:denied, message:"approval denied"}}
    ).

/* ---------------- interactive approval (approval_mode(interactive)) ---------------- */

%   pending_approval_rec(HarnessId, CallId, approval(Queue, Info)) --
%   one fact per tool call currently paused in wait_for_approval/6.
%   Guarded by a single global mutex rather than per-harness: creating
%   and resolving an approval is rare and short, so the extra
%   contention this could in theory cause is not worth the complexity
%   of per-harness approval mutexes on top of the per-harness state
%   mutex harness_rec/3 already has.
:- dynamic pending_approval_rec/3.

%!  wait_for_approval(+S, +Name, +Args, +Risk, +CallId, -Decision) is det.
%
%   Registers a pending approval, emits an `approval_requested` event
%   (so a UI polling harness_messages/2/harness_snapshot/2 -- see
%   pending_approvals_for/2 -- learns about it immediately), then
%   polls (poll_approval/4) for either a REST-delivered decision (see
%   harness_decide_approval/3), the harness being cancelled, or
%   approval_timeout/1 elapsing -- whichever comes first. Always
%   cleans up the registry entry and its message queue before
%   returning, even on a timeout, so nothing leaks.
wait_for_approval(S, Name, Args, Risk, CallId, Decision) :-
    Id = S.id,
    message_queue_create(Queue),
    register_pending_approval(Id, CallId, Queue, Name, Risk, Args),
    emit(Id, _{type:approval_requested, tool:Name, risk:Risk, id:CallId, arguments:Args}),
    Timeout = S.approval_timeout,
    get_time(Now),
    Deadline is Now + Timeout,
    poll_approval(Id, Queue, Deadline, Decision0),
    unregister_pending_approval(Id, CallId),
    catch(message_queue_destroy(Queue), _, true),
    % harness_close/1 may have deleted Id while this thread was
    % blocked (it resolves every pending approval as denied first --
    % see deny_all_pending_approvals/1 -- but that's a fire-and-forget
    % thread_send_message/2, so this thread can still wake up after
    % the harness record is already gone); emit/2 would otherwise
    % throw existence_error(codex_harness, Id) via state/2, which
    % would abort this whole tool call's thread instead of just
    % finishing with the decision it already has.
    catch(emit(Id, _{type:approval_resolved, id:CallId, decision:Decision0}), _, true),
    normalize_decision(Decision0, Decision).

%!  poll_approval(+Id, +Queue, +Deadline, -Decision) is det.
%
%   Short-interval polling rather than one indefinite
%   thread_get_message/2 wait, so a harness_cancel/1 during the wait
%   is noticed promptly (within POLL_INTERVAL) instead of only at
%   Deadline -- this thread is the one running the whole agent loop,
%   so cancellation must actually be able to interrupt it here.
poll_approval(Id, Queue, Deadline, Decision) :-
    get_time(Now),
    (   Now >= Deadline
    ->  Decision = deny("Approval request timed out")
    ;   catch(state(Id, S), _, fail), S.cancelled == true
    ->  Decision = deny("Harness cancelled while awaiting approval")
    ;   catch(thread_get_message(Queue, Msg, [timeout(0.25)]), _, fail)
    ->  Decision = Msg
    ;   poll_approval(Id, Queue, Deadline, Decision)
    ).

normalize_decision(allow, allow) :- !.
normalize_decision(deny, deny(_)) :- !.
normalize_decision(deny(Why), deny(Why)) :- !.
normalize_decision(_, deny("Invalid decision")).

register_pending_approval(Id, CallId, Queue, Name, Risk, Args) :-
    get_time(Now),
    Info = _{tool:Name, risk:Risk, arguments:Args, requested_at:Now},
    with_mutex(coplex_pending_approvals,
               assertz(pending_approval_rec(Id, CallId, approval(Queue, Info)))).

unregister_pending_approval(Id, CallId) :-
    with_mutex(coplex_pending_approvals,
               retractall(pending_approval_rec(Id, CallId, _))).

%!  pending_approvals_for(+Id, -List) is det.
%   List of `_{call_id, tool, risk, arguments, requested_at}` dicts
%   for every tool call currently paused for this harness -- surfaced
%   through harness_snapshot/2's `pending_approvals` field so a UI can
%   render Allow/Deny controls without a dedicated poll endpoint.
%   The dict is built *inside* the findall/3 goal, not its template --
%   SWI's dict dot-notation (`Info.tool`) expands into extra goals at
%   the point it's written, and a findall/3 *template* argument is
%   only ever unified against each solution after the fact, never
%   itself re-executed as a goal per solution. Writing the `.tool`
%   access directly in the template would expand to a get_dict/3 call
%   sequenced *before* findall/3 even starts (when Info is still
%   unbound), throwing instantiation_error -- easy to miss because it
%   only manifests once there's at least an attempt to read a field,
%   not at load time.
pending_approvals_for(Id, List) :-
    with_mutex(coplex_pending_approvals,
               findall(Record,
                       ( pending_approval_rec(Id, CallId, approval(_, Info)),
                         Record = _{call_id:CallId, tool:Info.tool, risk:Info.risk,
                                    arguments:Info.arguments, requested_at:Info.requested_at}
                       ),
                       List)).

%!  harness_decide_approval(+Harness, +CallId, +Decision) is det.
%
%   Decision is the atom `allow` or `deny`. Resolves the matching
%   pending approval (see wait_for_approval/6), waking its blocked
%   thread immediately -- no polling delay on this side, since
%   thread_send_message/2 to a queue a receiver is already waiting on
%   is immediate. Throws existence_error(pending_approval, CallId) if
%   CallId names no currently-pending approval for this harness (it
%   may have already resolved, timed out, or the harness may have been
%   cancelled/deleted), which coplex_server.pl maps to HTTP 404.
%   CallId is normalized to a string before matching (every stored
%   call_id is a string -- see run_named_tool/5 and normalize_call/2 --
%   but a caller working directly in Prolog may reasonably pass an
%   atom; REST callers always supply a string via a URL path segment).
harness_decide_approval(codex_harness(Id), CallId0, Decision) :-
    must_be(oneof([allow, deny]), Decision),
    text_of(CallId0, CallId),
    with_mutex(coplex_pending_approvals,
               (   pending_approval_rec(Id, CallId, approval(Queue, _))
               ->  thread_send_message(Queue, Decision)
               ;   throw(error(existence_error(pending_approval, CallId), _))
               )).

%!  deny_all_pending_approvals(+Id) is det.
%   Called from harness_close/1 so a harness being deleted never
%   leaves a thread permanently blocked in wait_for_approval/6 waiting
%   on a call_id nobody can ever address again -- each pending
%   approval for Id is resolved as denied, same as if a human had
%   explicitly said no.
deny_all_pending_approvals(Id) :-
    with_mutex(coplex_pending_approvals,
               forall(pending_approval_rec(Id, _CallId, approval(Queue, _)),
                      catch(thread_send_message(Queue, deny("Harness closed")), _, true))).

dispatch_tool(read_file, _, S, A, R)        :- tool_read_file(S, A, R).
dispatch_tool(write_file, write, S, A, R)   :- tool_write_file(S, A, R).
dispatch_tool(list_files, _, S, A, R)       :- tool_list_files(S, A, R).
dispatch_tool(search, _, S, A, R)           :- tool_search(S, A, R).
dispatch_tool(apply_patch, write, S, A, R)  :- tool_apply_patch(S, A, R).
dispatch_tool(file_info, _, S, A, R)        :- tool_file_info(S, A, R).
dispatch_tool(make_directory, write, S, A, R) :- tool_make_directory(S, A, R).
dispatch_tool(shell, process, S, A, R)      :- tool_shell(S, A, R).
dispatch_tool(run_tests, process, S, A, R)  :- tool_run_tests(S, A, R).
dispatch_tool(git_status, _, S, A, R)       :- tool_git(S, status, A, R).
dispatch_tool(git_diff, _, S, A, R)         :- tool_git(S, diff, A, R).
dispatch_tool(git_log, _, S, A, R)          :- tool_git(S, log, A, R).
dispatch_tool(git_show, _, S, A, R)         :- tool_git(S, show, A, R).
dispatch_tool(web_search, network, S, A, R) :- tool_web_search(S, A, R).
dispatch_tool(web_get, network, S, A, R)    :- tool_web_get(S, A, R).
dispatch_tool(download, network, S, A, R)   :- tool_download(S, A, R).
dispatch_tool(subagents, process, S, A, R)  :- tool_subagents(S, A, R).

check_cancelled(S) :-
    (   S.cancelled == true
    ->  throw(cancelled)
    ;   true
    ).

/* ---------------- model adapter ---------------- */

call_model(Id, RunOptions, Reply) :-
    state(Id, S),
    build_instructions(S, Instr),
    harness_tool_specs(RawSpecs),
    maplist(public_spec, RawSpecs, Tools),
    Request = _{
        model:S.model,
        instructions:Instr,
        messages:S.messages,
        tools:Tools,
        options:RunOptions
    },
    emit(Id, _{type:model_request, request:_{model:S.model, n_messages:N}}),
    length(S.messages, N),
    Adapter = S.adapter,
    catch(call(Adapter, Request, Raw),
          E,
          throw(error(adapter_error(E), _))),
    normalize_reply(Raw, Reply).

public_spec(spec(Name, Risk, Desc, Params),
            _{name:Name, risk:Risk, description:Desc, parameters:Params}).

build_instructions(S, Instr) :-
    string_concat(S.instructions, "\n", A),
    string_concat(A, S.extra_instructions, Instr).

%!  normalize_reply(+Raw, -Reply) is det.
normalize_reply(Raw0, _{content:Content, tool_calls:Calls}) :-
    ensure_dict(Raw0, Raw),
    flex_get(content, Raw, C0, ""),
    text_of(C0, Content),
    flex_get(tool_calls, Raw, TC0, []),
    (   is_list(TC0) -> TC1 = TC0 ; TC1 = [] ),
    maplist(normalize_call, TC1, Calls).

normalize_call(C0, _{id:Id, name:Name, arguments:Args}) :-
    ensure_dict(C0, C),
    flex_get(id, C, Id0, ""),
    (   Id0 == ""
    ->  uuid(Id)
    ;   text_of(Id0, Id)
    ),
    flex_get(name, C, N0, unknown),
    name_atom(N0, Name),
    flex_get(arguments, C, A0, _{}),
    ensure_dict(A0, Args).

%!  scripted_adapter(+Id, +Request, -Reply) is det.
%   Deterministic mock: consumes `mock_script` replies from harness state.
scripted_adapter(Id, _Request, Reply) :-
    pop_script(Id, Next),
    (   Next == none
    ->  Reply = _{content:"(no further mock replies)", tool_calls:[]}
    ;   normalize_reply(Next, Reply)
    ).

pop_script(Id, Next) :-
    harness_rec(Id, Mutex, _),
    with_mutex(Mutex,
               (   retract(harness_rec(Id, Mutex, S0)),
                   (   S0.mock_script = [Head|Rest]
                   ->  Next = Head,
                       S1 = S0.put(mock_script, Rest)
                   ;   Next = none,
                       S1 = S0
                   ),
                   assertz(harness_rec(Id, Mutex, S1)))).

%!  http_json_adapter(+Url, +Request, -Reply) is det.
%   Example provider adapter.  POSTs the normalized request as JSON and
%   expects `{content, tool_calls}` JSON back.  Authorization headers are
%   never persisted by the harness.
http_json_adapter(Url, Request, Reply) :-
    atom_string(Url, UrlS),
    tmp_file_stream(text, Tmp, Out),
    setup_call_cleanup(
        true,
        (   json_write_dict(Out, Request, []),
            close(Out),
            http_post_file(UrlS, Tmp, Codes)
        ),
        catch(close(Out), _, true)),
    catch(delete_file(Tmp), _, true),
    atom_codes(Atom, Codes),
    atom_json_dict(Atom, Raw, []),
    normalize_reply(Raw, Reply).

http_post_file(Url, File, Codes) :-
    setup_call_cleanup(
        open(File, read, In),
        read_string(In, _, Body),
        close(In)),
    catch(http_post_json(Url, Body, Codes),
          error(existence_error(procedure, _), _),
          throw(error(adapter_error("library(http/http_client) not loaded"), _))).

http_post_json(Url, Body, Codes) :-
    use_module(library(http/http_client)),
    http_post(Url, atom(application/json, Body), Reply, []),
    (   atom(Reply) -> atom_codes(Reply, Codes)
    ;   string(Reply) -> string_codes(Reply, Codes)
    ;   format(atom(A), '~w', [Reply]), atom_codes(A, Codes)
    ).

/* ---------------- OpenAI-compatible chat-completions adapter ---------------- */

%!  openai_chat_adapter(+Id, +Request, -Reply) is det.
%
%   Provider adapter for OpenAI-compatible Chat Completions APIs --
%   OpenAI itself, Azure OpenAI, and any self-hosted server speaking
%   the same wire format (vLLM, Ollama's /v1 shim, LM Studio, ...).
%   Selected via `harness_new/2`'s `adapter(openai)`; also reachable
%   *safely* from `POST /harnesses {"adapter": "openai", ...}` because
%   `adapter` is still normalized to one of a fixed, closed set of
%   atoms by coplex_server.pl's sanitize_value/3 -- see that module's
%   docstring for why that matters.
%
%   Translates the harness's normalized Request
%   (`_{model, instructions, messages, tools, options}`) into a Chat
%   Completions request body -- system/user/assistant/tool messages,
%   `tools` in the `{type:"function", function:{name, description,
%   parameters}}` shape -- POSTs it to the harness's `adapter_url`
%   option (default the public OpenAI endpoint) with
%   `Authorization: Bearer <adapter_api_key>`, and hands the first
%   choice's message back through normalize_reply/2, which already
%   knows how to parse a JSON-*string* `arguments` payload -- exactly
%   what this wire format uses for each `tool_calls[].function`.
%
%   Gated by the same `allow_network` a harness already needs for
%   web_search/web_get/download: reaching a real hosted LLM is real,
%   costed network egress, not a local file/process op, so it must be
%   opted into explicitly, same as any other outbound call. Unlike
%   http_fetch/4 (used by the *tools*, where the URL is task/model-
%   controlled input), validate_adapter_url/2 deliberately does *not*
%   block loopback/private-range hosts: `adapter_url` is trusted,
%   operator-supplied configuration set once at harness-creation time
%   -- like `root`/`cwd` -- and a locally-hosted model server (Ollama,
%   vLLM, LM Studio, an internal gateway) is a completely ordinary,
%   legitimate value for it.
openai_chat_adapter(Id, Request, Reply) :-
    state(Id, S),
    (   S.allow_network == true
    ->  true
    ;   throw(error(permission_error(network, adapter,
                    "Network access is disabled -- set allow_network:true to let the openai adapter reach a real model"),
                    _))
    ),
    openai_request_body(Request, Body),
    with_output_to(string(BodyText),
                   json_write_dict(current_output, Body, [])),
    http_fetch_post_json(S, S.adapter_url, S.adapter_api_key, BodyText, Codes),
    string_codes(ReplyText, Codes),
    catch(atom_json_dict(ReplyText, RawReply, []),
          _,
          throw(error(adapter_error("openai adapter got a non-JSON response"), _))),
    openai_extract_message(RawReply, Raw),
    normalize_reply(Raw, Reply).

%!  openai_request_body(+Request, -Body) is det.
%   Request is the harness's normalized `{model, instructions,
%   messages, tools, options}`; Body is a Chat Completions request.
openai_request_body(Request, _{model:Request.model, messages:Messages,
                                tools:Tools, tool_choice:"auto"}) :-
    openai_message_list(Request.instructions, Request.messages, Messages),
    maplist(openai_tool, Request.tools, Tools).

openai_message_list(Instr, Msgs, [_{role:"system", content:Instr}|Out]) :-
    maplist(openai_message, Msgs, Out).

%   role:user   -> plain user turn (task text + repository context).
%   role:assistant -> the model's own prior turn; tool_calls (if any)
%   are re-encoded with JSON-*string* arguments, matching the wire
%   format the API itself used when it originally emitted them.
%   role:tool   -> a tool's result, JSON-encoded as the message's
%   string `content` so the model can read a structured result.
openai_message(M, _{role:"user", content:M.content}) :-
    M.role == user, !.
openai_message(M, _{role:"assistant", content:M.content}) :-
    M.role == assistant, M.tool_calls == [], !.
openai_message(M, _{role:"assistant", content:M.content, tool_calls:Calls}) :-
    M.role == assistant, !,
    maplist(openai_tool_call, M.tool_calls, Calls).
openai_message(M, _{role:"tool", tool_call_id:M.tool_call_id,
                    content:ContentText}) :-
    M.role == tool, !,
    with_output_to(string(ContentText),
                   json_write_dict(current_output, M.content, [])).
openai_message(M, _{role:"user", content:Text}) :-
    % Defensive fallback for any future/unrecognized role: never drop
    % a turn silently, just stringify it as a user message.
    term_string(M, Text).

openai_tool_call(C, _{id:C.id, type:"function",
                      function:_{name:C.name, arguments:ArgsText}}) :-
    with_output_to(string(ArgsText),
                   json_write_dict(current_output, C.arguments, [])).

%!  openai_tool(+ToolSpec, -Tool) is det.
%   ToolSpec is `_{name, risk, description, parameters}` (see
%   public_spec/2); Tool is `{type:"function", function:{name,
%   description, parameters: <JSON Schema object>}}`.
openai_tool(T, _{type:"function",
                 function:_{name:T.name, description:T.description,
                            parameters:Schema}}) :-
    json_schema_of_params(T.parameters, Schema).

%!  json_schema_of_params(+Params, -Schema) is det.
%   Params is one of harness_tool_specs/1's lightweight per-tool
%   dicts, e.g. `_{path:string, offset:integer}`; Schema is a minimal
%   JSON Schema object a real tool-calling API can validate/generate
%   arguments against. Every property is left optional (the schemas
%   here never track required-ness; each tool's own flex_get/4 calls
%   already supply sane defaults for anything omitted).
json_schema_of_params(Params, _{type:"object", properties:Props}) :-
    dict_pairs(Params, _, Pairs),
    maplist(json_schema_property, Pairs, PropPairs),
    dict_pairs(Props, _, PropPairs).

json_schema_property(Name-Type, Name-_{type:JsonType}) :-
    json_schema_type(Type, JsonType).

json_schema_type(string, "string") :- !.
json_schema_type(integer, "integer") :- !.
json_schema_type(boolean, "boolean") :- !.
json_schema_type(list, "array") :- !.
json_schema_type(_, "string").

%!  openai_extract_message(+RawReply, -Raw) is det.
%   RawReply is a decoded Chat Completions response
%   (`atom_json_dict/3` already turns it into nested dicts/lists,
%   JSON `null` into the atom `null`). Raw is the harness's own raw
%   adapter-reply shape (`{content, tool_calls}`, tool_calls still
%   carrying JSON-*string* arguments) that normalize_reply/2 expects.
openai_extract_message(RawReply, _{content:Content, tool_calls:RawCalls}) :-
    flex_get(choices, RawReply, Choices0, []),
    (   Choices0 = [First|_]
    ->  true
    ;   throw(error(adapter_error("openai response had no choices"), _))
    ),
    flex_get(message, First, Message, _{}),
    flex_get(content, Message, Content0, ""),
    (   Content0 == null -> Content = "" ; text_of(Content0, Content) ),
    flex_get(tool_calls, Message, RawCalls0, []),
    (   is_list(RawCalls0) -> RawCalls1 = RawCalls0 ; RawCalls1 = [] ),
    maplist(openai_raw_call, RawCalls1, RawCalls).

openai_raw_call(C, _{id:Id, name:Name, arguments:Args}) :-
    flex_get(id, C, Id, ""),
    flex_get(function, C, Fn, _{}),
    flex_get(name, Fn, Name, unknown),
    flex_get(arguments, Fn, Args, "{}").

%!  validate_adapter_url(+S, +Url) is det.
%
%   Lighter validation than http_fetch/4's SSRF guard -- see
%   openai_chat_adapter/3's docstring for why loopback/private-range
%   hosts are deliberately *not* blocked here. Still requires
%   http/https and still honors `allowed_hosts` if the operator set
%   one (empty, the default, means unrestricted -- same convention as
%   path_allowed/2 and writable_allowed/2).
validate_adapter_url(S, Url) :-
    uri_components(Url, uri_components(Scheme, Auth, _Path, _Q, _F)),
    (   memberchk(Scheme, [http, https])
    ->  true
    ;   throw(error(permission_error(open, url, Url),
                    context(_, "only http/https allowed")))
    ),
    uri_authority_components(Auth, uri_authority(_, _, Host, _)),
    (   Host == '' -> throw(error(permission_error(open, url, Url), _))
    ;   true
    ),
    (   S.allowed_hosts == []
    ->  true
    ;   (   memberchk(Host, S.allowed_hosts) -> true
        ;   throw(error(permission_error(open, url, Url),
                        context(_, "host is not on the allowlist")))
        )
    ).

%!  http_fetch_post_json(+S, +Url, +ApiKey, +BodyText, -Codes) is det.
%
%   POST BodyText (already-serialized JSON) to Url, with an
%   `Authorization: Bearer ApiKey` header when ApiKey is non-empty,
%   returning the raw response body as a code list regardless of HTTP
%   status (status_code/1 suppresses http_open/3's default
%   throw-on-4xx/5xx so a provider's actual JSON error body -- e.g.
%   "invalid_api_key" -- can be surfaced instead of a generic
%   networking exception).
http_fetch_post_json(S, Url, ApiKey, BodyText, Codes) :-
    validate_adapter_url(S, Url),
    (   ApiKey == "" -> AuthOpts = [] ; AuthOpts = [authorization(bearer(ApiKey))] ),
    use_module(library(http/http_open)),
    Limit is max(1000000, S.max_output_bytes),
    setup_call_cleanup(
        http_open(Url, In,
                  [ post(atom(application/json, BodyText)),
                    status_code(Status),
                    timeout(60),
                    size_limit(Limit),
                    redirect(false)
                  | AuthOpts
                  ]),
        read_stream_to_codes(In, Codes),
        close(In)),
    (   Status >= 200, Status < 300
    ->  true
    ;   string_codes(ErrText, Codes),
        throw(error(adapter_error(_{status:Status, body:ErrText}), _))
    ).

/* ---------------- repository context ---------------- */

gather_context(S, RunOptions, Context) :-
    option(context(Extra), RunOptions, ""),
    Root = S.root,
    current_prolog_flag(version_data, swi(Maj,Min,Pat,_)),
    format(string(Ver), "SWI-Prolog ~w.~w.~w", [Maj,Min,Pat]),
    (   current_prolog_flag(windows, true)
    ->  OS = windows
    ;   OS = posix
    ),
    git_one(S, ["rev-parse","--abbrev-ref","HEAD"], Branch),
    git_one(S, ["status","--porcelain"], Status),
    bounded_tree(Root, Tree),
    agents_md(Root, Agents),
    config_files(Root, Configs),
    Max is min(8000, S.max_output_bytes),
    format(string(Raw),
           "root: ~w~ncwd: ~w~nos: ~w~nprolog: ~s~nbranch: ~s~nstatus:~n~s~n~s~n~s~n~s~nextra:~n~w~n",
           [Root, S.cwd, OS, Ver, Branch, Status, Tree, Agents, Configs, Extra]),
    truncate_text(Raw, Max, Context, _).

git_one(S, Args, Out) :-
    (   catch(run_process(S, path(git), Args, 8, Codes, _, 0), _, fail)
    ->  string_codes(Out0, Codes),
        truncate_text(Out0, 2000, Out, _)
    ;   Out = "(git unavailable)"
    ).

bounded_tree(Root, Text) :-
    catch(directory_files(Root, Ents0), _, Ents0 = []),
    exclude(hidden_name, Ents0, Ents),
    include(not_dot, Ents, Names),
    length(Names, N),
    (   N > 40 -> prefix(40, Names, Shown), Extra = "\n..." ; Shown = Names, Extra = "" ),
    atomic_list_concat(Shown, "\n", Joined),
    format(string(Text), "top-level:~n~w~s", [Joined, Extra]).

hidden_name(N) :- N = '.'.
hidden_name(N) :- N = '..'.
not_dot(N) :- \+ hidden_name(N).

agents_md(Root, Text) :-
    findall(P, walk_agents(Root, P), Ps),
    (   Ps == []
    ->  Text = "AGENTS.md: (none)"
    ;   maplist(read_capped(Root, 1500), Ps, Bodies),
        atomic_list_concat(Bodies, "\n---\n", Text)
    ).

walk_agents(Root, Rel) :-
    member(Name, ['AGENTS.md','agents.md']),
    directory_file_path(Root, Name, Abs),
    exists_file(Abs),
    Rel = Name.
walk_agents(Root, Rel) :-
    member(Dir, ['.github', 'docs']),
    directory_file_path(Root, Dir, D),
    exists_directory(D),
    directory_file_path(D, 'AGENTS.md', Abs),
    exists_file(Abs),
    directory_file_path(Dir, 'AGENTS.md', Rel).

config_files(Root, Text) :-
    Candidates = ['package.json','pyproject.toml','Cargo.toml','Makefile',
                  'CMakeLists.txt','go.mod','pack.pl','.editorconfig'],
    findall(N, (member(N, Candidates),
                directory_file_path(Root, N, P), exists_file(P)), Ns),
    format(string(Text), "config files: ~w", [Ns]).

read_capped(Root, Cap, Rel, Out) :-
    directory_file_path(Root, Rel, Abs),
    (   exists_file(Abs)
    ->  read_file_to_string(Abs, S, [encoding(utf8)]),
        truncate_text(S, Cap, Body, _),
        format(string(Out), "~w:~n~s", [Rel, Body])
    ;   Out = ""
    ).

/* ---------------- path safety ---------------- */

safe_resolve(S, Rel0, Abs) :-
    text_of(Rel0, RelS),
    (   RelS == "" -> Rel = '.' ; Rel = RelS ),
    Root = S.root,
    (   is_absolute_filename(Rel)
    ->  Abs0 = Rel
    ;   directory_file_path(Root, Rel, Abs0)
    ),
    absolute_file_name(Abs0, Abs, [access(none)]),
    (   path_allowed(S, Abs)
    ->  true
    ;   throw(error(permission_error(access, file, Rel),
                    context(safe_resolve/3, "Path is outside the repository")))
    ).

path_allowed(S, Abs) :-
    under_root(S.root, Abs),
    (   S.readable_paths == []
    ->  true
    ;   member(P, S.readable_paths),
        under_root_opt(S.root, P, Abs)
    ).

writable_allowed(S, Abs) :-
    under_root(S.root, Abs),
    (   S.writable_paths == []
    ->  true
    ;   member(P, S.writable_paths),
        under_root_opt(S.root, P, Abs)
    ).

under_root_opt(Root, RelOrAbs, Abs) :-
    (   is_absolute_filename(RelOrAbs)
    ->  A = RelOrAbs
    ;   directory_file_path(Root, RelOrAbs, A)
    ),
    absolute_file_name(A, Can, [access(none)]),
    under_root(Can, Abs).

under_root(Root0, Path0) :-
    absolute_file_name(Root0, Root, [access(none)]),
    absolute_file_name(Path0, Path, [access(none)]),
    prolog_to_os_filename(Root, R1),
    prolog_to_os_filename(Path, P1),
    downcase_atom_if(R1, R),
    downcase_atom_if(P1, P),
    (   same_file_safe(R, P)
    ->  true
    ;   atom_concat(R, Rest, P),
        sub_atom(Rest, 0, 1, _, Sep),
        memberchk(Sep, ['/', '\\'])
    ).

same_file_safe(A, B) :-
    catch(same_file(A, B), _, A == B).

downcase_atom_if(A, D) :-
    (   current_prolog_flag(windows, true)
    ->  downcase_atom(A, D)
    ;   D = A
    ).

/* ---------------- file tools ---------------- */

tool_read_file(S, A, R) :-
    flex_get(path, A, Rel, ""),
    catch(safe_resolve(S, Rel, Abs), E, fail_err(read_file, E, R)),
    (   var(R)
    ->  (   exists_file(Abs)
        ->  read_file_to_string(Abs, Text0, [encoding(utf8)]),
            flex_get(offset, A, Off0, 0),
            flex_get(limit, A, Lim0, -1),
            slice_text(Text0, Off0, Lim0, Text1),
            truncate_text(Text1, S.max_output_bytes, Text, Trunc),
            R = _{ok:true, tool:read_file, path:Rel, content:Text, truncated:Trunc}
        ;   R = _{ok:false, tool:read_file,
                  error:_{type:not_found, message:"File does not exist"}}
        )
    ;   true
    ).

tool_write_file(S, A, R) :-
    flex_get(path, A, Rel, ""),
    flex_get(content, A, Content0, ""),
    text_of(Content0, Content),
    catch((safe_resolve(S, Rel, Abs),
           (   writable_allowed(S, Abs)
           ->  true
           ;   throw(error(permission_error(write, file, Rel), _))
           ),
           file_directory_name(Abs, Dir),
           make_directory_path(Dir),
           atomic_write(Abs, Content),
           R = _{ok:true, tool:write_file, path:Rel, bytes:N},
           string_length(Content, N)),
          E, fail_err(write_file, E, R)).

atomic_write(Abs, Content) :-
    atom_concat(Abs, '.tmp-harness', Tmp),
    setup_call_cleanup(
        open(Tmp, write, Out, [encoding(utf8)]),
        write(Out, Content),
        close(Out)),
    (   exists_file(Abs)
    ->  delete_file(Abs)
    ;   true
    ),
    rename_file(Tmp, Abs).

tool_list_files(S, A, R) :-
    flex_get(path, A, Rel, "."),
    flex_get(max_entries, A, Max0, 200),
    Max is max(1, min(2000, Max0)),
    catch((safe_resolve(S, Rel, Abs),
           (   exists_directory(Abs)
           ->  collect_files(Abs, S.root, Max, Files, Trunc),
               R = _{ok:true, tool:list_files, files:Files, truncated:Trunc}
           ;   R = _{ok:false, tool:list_files,
                     error:_{type:not_found, message:"Not a directory"}}
           )),
          E, fail_err(list_files, E, R)).

collect_files(Abs, Root, Max, Files, Trunc) :-
    findall(Rel, walk_file(Abs, Root, Rel), All),
    length(All, N),
    (   N > Max -> prefix(Max, All, Files), Trunc = true ; Files = All, Trunc = false ).

walk_file(Dir, Root, Rel) :-
    directory_files(Dir, Ents),
    member(E, Ents),
    \+ hidden_name(E),
    directory_file_path(Dir, E, P),
    (   exists_directory(P)
    ->  walk_file(P, Root, Rel)
    ;   relative_to_root(Root, P, Rel)
    ).

relative_to_root(Root, Abs, Rel) :-
    absolute_file_name(Root, R, [access(none)]),
    absolute_file_name(Abs, A, [access(none)]),
    (   atom_concat(R, Rest, A)
    ->  strip_lead_sep(Rest, Rel0),
        (   Rel0 == '' -> Rel = '.' ; Rel = Rel0 )
    ;   Rel = Abs
    ).

strip_lead_sep(S, R) :-
    (   sub_atom(S, 0, 1, _, '/') -> sub_atom(S, 1, _, 0, R)
    ;   sub_atom(S, 0, 1, _, '\\') -> sub_atom(S, 1, _, 0, R)
    ;   R = S
    ).

tool_file_info(S, A, R) :-
    flex_get(path, A, Rel, ""),
    catch((safe_resolve(S, Rel, Abs),
           (   exists_file(Abs)
           ->  size_file(Abs, Size),
               time_file(Abs, T),
               R = _{ok:true, tool:file_info, path:Rel, type:file, size:Size, mtime:T}
           ;   exists_directory(Abs)
           ->  time_file(Abs, T),
               R = _{ok:true, tool:file_info, path:Rel, type:directory, size:0, mtime:T}
           ;   R = _{ok:false, tool:file_info,
                     error:_{type:not_found, message:"Path does not exist"}}
           )),
          E, fail_err(file_info, E, R)).

tool_make_directory(S, A, R) :-
    flex_get(path, A, Rel, ""),
    catch((safe_resolve(S, Rel, Abs),
           writable_allowed(S, Abs),
           make_directory_path(Abs),
           R = _{ok:true, tool:make_directory, path:Rel}),
          E, fail_err(make_directory, E, R)).

/* ---------------- search ---------------- */

tool_search(S, A, R) :-
    flex_get(query, A, Query0, ""),
    text_of(Query0, Query),
    flex_get(path, A, Rel, "."),
    flex_get(glob, A, Glob, ""),
    flex_get(max_results, A, Max0, 50),
    flex_get(case_sensitive, A, CS, false),
    Max is max(1, min(500, Max0)),
    catch(safe_resolve(S, Rel, Abs), E, fail_err(search, E, R)),
    (   var(R)
    ->  (   Query == ""
        ->  R = _{ok:false, tool:search, error:_{type:validation_error, message:"query required"}}
    ;   (   rg_available,
            catch(rg_search(S, Abs, Query, Glob, Max, CS, Hits0, Trunc0), _, fail),
            Hits0 \== []
        ->  Hits = Hits0, Trunc = Trunc0
        ;   fallback_search(Abs, S.root, Query, Glob, Max, CS, Hits, Trunc)
        ),
        R = _{ok:true, tool:search, matches:Hits, truncated:Trunc}
    )
    ;   true
    ).

rg_available :-
    catch((process_create(path(rg), ["--version"],
                          [stdout(null), stderr(null), process(PID)]),
           process_wait(PID, exit(0))),
          _, fail).

rg_search(S, Abs, Query, Glob, Max, CS, Hits, Trunc) :-
    atom_number(MaxA, Max),
    Args0 = ["--json","-m",MaxA,"--",Query,Abs],
    (   CS == true -> Args1 = ["-s"|Args0] ; Args1 = ["-i"|Args0] ),
    (   Glob == "" -> Args = Args1 ; Args = ["-g",Glob|Args1] ),
    run_process(S, path(rg), Args, 20, Codes, _, _),
    string_codes(Out, Codes),
    split_string(Out, "\n", "\n", Lines),
    convlist(rg_hit(S.root), Lines, Hits0),
    length(Hits0, N),
    (   N > Max -> prefix(Max, Hits0, Hits), Trunc = true ; Hits = Hits0, Trunc = false ).

rg_hit(Root, Line, _{path:Rel, line:LN, text:Text}) :-
    Line \== "",
    atom_json_dict(Line, D, []),
    get_dict(type, D, "match"),
    get_dict(data, D, Data),
    get_dict(path, Data, PDict),
    get_dict(text, PDict, Path),
    get_dict(line_number, Data, LN),
    get_dict(lines, Data, LDict),
    get_dict(text, LDict, Text0),
    text_of(Text0, Text),
    relative_to_root(Root, Path, Rel).

fallback_search(Abs, Root, Query, Glob, Max, CS, Hits, Trunc) :-
    findall(Hit, fallback_hit(Abs, Root, Query, Glob, CS, Hit), All),
    length(All, N),
    (   N > Max -> prefix(Max, All, Hits), Trunc = true ; Hits = All, Trunc = false ).

fallback_hit(Dir, Root, Query, Glob, CS, _{path:Rel, line:LN, text:Text}) :-
    walk_file(Dir, Root, Rel),
    (   Glob == "" -> true ; wildcard_match(Glob, Rel) ),
    directory_file_path(Root, Rel, File),
    catch(read_file_to_string(File, Body, [encoding(utf8)]), _, fail),
    split_string(Body, "\n", "", Lines),
    nth1(LN, Lines, Text),
    contains_q(Text, Query, CS).

contains_q(Text, Query, true) :-
    sub_string(Text, _, _, _, Query).
contains_q(Text, Query, CS) :-
    CS \== true,
    string_lower(Text, T),
    string_lower(Query, Q),
    sub_string(T, _, _, _, Q).

/* ---------------- patch ---------------- */

tool_apply_patch(S, A, R) :-
    flex_get(patch, A, Patch0, ""),
    text_of(Patch0, Patch),
    catch(apply_unified_patch(S, Patch, Report), E, fail_err(apply_patch, E, R)),
    (   var(R)
    ->  R = Report
    ;   true
    ).

apply_unified_patch(S, Patch, Result) :-
    split_patch_files(Patch, Files),
    (   Files == []
    ->  Result = _{ok:false, tool:apply_patch,
                   error:_{type:validation_error, message:"No file hunks in patch"}}
    ;   maplist(validate_patch_path(S), Files),
    maplist(preview_one_file(S), Files, Previews),
    (   include(preview_failed, Previews, Bad), Bad \== []
    ->  maplist(preview_report, Previews, Reports),
        Result = _{ok:false, tool:apply_patch, files:Reports,
                   error:_{type:patch_rejected, message:"One or more hunks failed; no files written"}}
    ;   maplist(commit_preview, Previews, Reports),
        Result = _{ok:true, tool:apply_patch, files:Reports}
    )
    ).

validate_patch_path(S, file(Path,_,_,_)) :-
    safe_resolve(S, Path, Abs),
    (   writable_allowed(S, Abs) -> true
    ;   throw(error(permission_error(write, file, Path), _))
    ).

preview_failed(preview(false, _, _, _)).
preview_report(preview(true, Path, Hunks, _), _{ok:true, path:Path, hunks:N}) :-
    length(Hunks, N).
preview_report(preview(false, Path, _, Rejected), _{ok:false, path:Path, rejected:Rejected}).

preview_one_file(S, file(Path, OldName, _NewName, Hunks),
                 preview(Ok, Path, Hunks, Payload)) :-
    safe_resolve(S, Path, Abs),
    (   exists_file(Abs)
    ->  read_file_to_string(Abs, Old, [encoding(utf8)])
    ;   OldName == "/dev/null"
    ->  Old = ""
    ;   Old = ""
    ),
    split_string(Old, "\n", "", Lines0),
    strip_final_nl(Old, Lines0, Lines),
    (   apply_hunks(Lines, Hunks, NewLines, Rejected),
        Rejected == []
    ->  atomic_list_concat(NewLines, "\n", New0),
        restore_final_nl(Old, New0, New),
        Ok = true,
        Payload = Abs-New
    ;   Ok = false,
        Payload = ["hunk application failed"]
    ).

commit_preview(preview(true, Path, Hunks, Abs-New), _{ok:true, path:Path, hunks:N}) :-
    file_directory_name(Abs, Dir),
    make_directory_path(Dir),
    atomic_write(Abs, New),
    length(Hunks, N).

strip_final_nl(Text, Lines0, Lines) :-
    (   sub_string(Text, _, 1, 0, "\n"),
        append(Lines, [""], Lines0)
    ->  true
    ;   Lines = Lines0
    ).

restore_final_nl(Old, New0, New) :-
    (   sub_string(Old, _, 1, 0, "\n")
    ->  string_concat(New0, "\n", New)
    ;   New = New0
    ).

split_patch_files(Patch, Files) :-
    split_string(Patch, "\n", "", Lines0),
    exclude(==(""), Lines0, Lines),
    phrase(patch_files(Files), Lines).

patch_files([]) --> [].
patch_files([file(Path,Old,New,Hunks)|Rest]) -->
    file_header(Old, New),
    { pick_path(Old, New, Path) },
    hunks(Hunks),
    patch_files(Rest).

file_header(Old, New) -->
    [L1], { sub_string(L1, 0, 4, _, "--- ") , sub_string(L1, 4, _, 0, Old0), strip_ab(Old0, Old) },
    [L2], { sub_string(L2, 0, 4, _, "+++ ") , sub_string(L2, 4, _, 0, New0), strip_ab(New0, New) }.

strip_ab(S0, S) :-
    (   sub_string(S0, 0, 2, _, "a/") -> sub_string(S0, 2, _, 0, S1)
    ;   sub_string(S0, 0, 2, _, "b/") -> sub_string(S0, 2, _, 0, S1)
    ;   S1 = S0
    ),
    split_string(S1, "\t", "\t", [S|_]).

pick_path("/dev/null", New, New) :- New \== "/dev/null", !.
pick_path(Old, "/dev/null", Old) :- !.
pick_path(_, New, New).

hunks([H|Hs]) --> hunk(H), hunks(Hs).
hunks([]) --> [].

hunk(hunk(OldStart, Lines)) -->
    [Hdr],
    { sub_string(Hdr, 0, 2, _, "@@"),
      split_string(Hdr, " ", " ", Parts),
      member(P, Parts),
      sub_string(P, 0, 1, _, "-"),
      sub_string(P, 1, _, 0, Rest),
      split_string(Rest, ",", "", [StartS|_]),
      number_string(OldStart, StartS)
    },
    hunk_body(Lines).

hunk_body([L|Ls]) -->
    [Raw],
    { \+ sub_string(Raw, 0, 4, _, "--- "),
      \+ sub_string(Raw, 0, 4, _, "+++ "),
      \+ sub_string(Raw, 0, 2, _, "@@"),
      string_length(Raw, N), N > 0,
      sub_string(Raw, 0, 1, _, C),
      memberchk(C, [" ","+","-","\\"]),
      L = Raw
    },
    hunk_body(Ls).
hunk_body([]) --> [].

apply_hunks(Lines, [], Lines, []).
apply_hunks(Lines, [hunk(Start, Body)|Hs], Out, Rejected) :-
    (   apply_one_hunk(Lines, Start, Body, Mid)
    ->  apply_hunks(Mid, Hs, Out, Rejected)
    ;   apply_hunks(Lines, Hs, Out, Rest),
        format(string(Msg), "rejected hunk at ~w", [Start]),
        Rejected = [Msg|Rest]
    ).

apply_one_hunk(Lines, Start, Body, New) :-
    Start1 is max(1, Start),
    PrefixN is Start1 - 1,
    prefix(PrefixN, Lines, Prefix),
    length(Prefix, PrefixN),
    append(Prefix, Rest, Lines),
    consume_body(Body, Rest, Kept, Suffix),
    append(Prefix, Kept, Mid),
    append(Mid, Suffix, New).

consume_body([], Rest, [], Rest).
consume_body([Raw|Body], Rest, Kept, Suffix) :-
    sub_string(Raw, 0, 1, _, C),
    sub_string(Raw, 1, _, 0, Text),
    (   C == "\\"
    ->  consume_body(Body, Rest, Kept, Suffix)
    ;   C == "+"
    ->  consume_body(Body, Rest, Kept0, Suffix),
        Kept = [Text|Kept0]
    ;   Rest = [Text|Rest1],
        (   C == "-"
        ->  consume_body(Body, Rest1, Kept, Suffix)
        ;   C == " "
        ->  consume_body(Body, Rest1, Kept0, Suffix),
            Kept = [Text|Kept0]
        )
    ).

/* ---------------- process / shell / tests / git ---------------- */

tool_shell(S, A, R) :-
    (   S.allow_shell == true
    ->  flex_get(command, A, Cmd0, ""),
        text_of(Cmd0, Cmd),
        flex_get(args, A, Args0, []),
        flex_get(timeout, A, TO0, S.command_timeout),
        flex_get(env, A, Env0, []),
        (   Cmd == ""
        ->  R = _{ok:false, tool:shell, error:_{type:validation_error, message:"command required"}}
        ;   maplist(text_of, Args0, Args),
            exec_program(S, Cmd, Args, Env0, TO0, shell, R)
        )
    ;   R = _{ok:false, tool:shell,
              error:_{type:permission_error, message:"Shell is disabled"}}
    ).

tool_run_tests(S, A, R) :-
    flex_get(command, A, Cmd0, ""),
    flex_get(args, A, Args0, []),
    (   % An explicit command/args override is only honored when the
        % harness has general shell access. Without allow_shell(true) the
        % model can only trigger the auto-detected/configured test
        % runner, never an arbitrary caller-supplied command -- otherwise
        % run_tests would be a permission-check bypass for tool_shell.
        S.allow_shell == true, Cmd0 \== ""
    ->  text_of(Cmd0, Cmd),
        maplist(text_of, Args0, Args)
    ;   detect_tests(S, Cmd, Args)
    ),
    exec_program(S, Cmd, Args, [], S.command_timeout, run_tests, R0),
    (   get_dict(exit_code, R0, 0)
    ->  R = R0.put(ok, true)
    ;   R = R0.put(ok, false)
    ).

detect_tests(S, Cmd, Args) :-
    is_list(S.default_test_command),
    S.default_test_command = [C|As], !,
    text_of(C, Cmd), maplist(text_of, As, Args).
detect_tests(S, "python", ["-m","pytest","-q"]) :-
    directory_file_path(S.root, 'pyproject.toml', P), exists_file(P), !.
detect_tests(S, "npm", ["test","--silent"]) :-
    directory_file_path(S.root, 'package.json', P), exists_file(P), !.
detect_tests(S, "cargo", ["test"]) :-
    directory_file_path(S.root, 'Cargo.toml', P), exists_file(P), !.
detect_tests(_, "swipl", ["-g","run_tests","-t","halt"]).

tool_git(S, Verb, A, R) :-
    git_args(Verb, A, Args),
    catch(exec_program(S, path(git), Args, [], 20, git, R0),
          E, fail_err(git, E, R)),
    (   var(R)
    ->  R = R0.put(tool, git)
    ;   true
    ).

git_args(status, _, ["status","--porcelain"]).
git_args(diff, A, ["diff"|Rest]) :-
    flex_get(args, A, Rest0, []),
    maplist(text_of, Rest0, Rest).
git_args(log, A, ["log","--oneline","-n",N]) :-
    flex_get(max_count, A, N0, 10),
    format(string(N), "~w", [N0]).
git_args(show, A, ["show",Rev]) :-
    flex_get(revision, A, Rev0, "HEAD"),
    text_of(Rev0, Rev).

exec_program(S, Cmd0, Args, Env, Timeout, Tool, Result) :-
    resolve_cmd(Cmd0, Cmd),
    check_cancelled(S),
    get_time(T0),
    process_opts(S, Env, Out, Err, PID, Opts),
    setup_call_cleanup(
        process_create(Cmd, Args, Opts),
        (   thread_create(read_pipe(Out), TidOut, []),
            thread_create(read_pipe(Err), TidErr, []),
            (   process_wait(PID, Status, [timeout(Timeout)])
            ->  true
            ;   catch(process_kill(PID), _, true),
                process_wait(PID, _),
                Status = timeout
            ),
            join_pipe(TidOut, OutS),
            join_pipe(TidErr, ErrS)
        ),
        (   catch(close(Out), _, true),
            catch(close(Err), _, true)
        )),
    get_time(T1),
    Dur is round((T1-T0)*1000),
    status_code(Status, Code),
    truncate_text(OutS, S.max_output_bytes, Stdout, Tr1),
    truncate_text(ErrS, S.max_output_bytes, Stderr, Tr2),
    (   Tr1 == true ; Tr2 == true -> Trunc = true ; Trunc = false ),
    (   Status == timeout
    ->  Result = _{ok:false, tool:Tool, exit_code:(-1), stdout:Stdout, stderr:Stderr,
                   duration_ms:Dur, truncated:Trunc,
                   error:_{type:timeout, message:"command timeout"}}
    ;   Result = _{ok:true, tool:Tool, exit_code:Code, stdout:Stdout, stderr:Stderr,
                   duration_ms:Dur, truncated:Trunc}
    ).

read_pipe(Stream) :-
    read_string(Stream, _, S),
    thread_exit(S).

join_pipe(Tid, Text) :-
    thread_join(Tid, Status),
    (   Status = exited(S)
    ->  text_of(S, Text)
    ;   Text = ""
    ).

process_opts(S, Env, Out, Err, PID, Opts) :-
    Base = [cwd(S.cwd), stdout(pipe(Out)), stderr(pipe(Err)), process(PID)],
    (   Env == []
    ->  Opts0 = Base
    ;   Opts0 = [environment(Env)|Base]
    ),
    (   current_prolog_flag(windows, true)
    ->  Opts = [window(false)|Opts0]
    ;   Opts = Opts0
    ).

resolve_cmd(path(N), path(N)) :- !.
resolve_cmd(N, path(A)) :-
    atom(N), !, atom_string(N, S), atom_string(A, S).
resolve_cmd(S, path(A)) :-
    string(S), atom_string(A, S).

status_code(exit(C), C) :- !.
status_code(killed(_), -1) :- !.
status_code(timeout, -1) :- !.
status_code(_, -1).

run_process(S, Cmd, Args, TO, Codes, ErrCodes, Exit) :-
    exec_program(S, Cmd, Args, [], TO, proc, R),
    string_codes(R.stdout, Codes),
    string_codes(R.stderr, ErrCodes),
    Exit = R.exit_code.

/* ---------------- web ---------------- */

tool_web_search(S, A, R) :-
    require_network(S, web_search, R0),
    (   nonvar(R0) -> R = R0
    ;   flex_get(query, A, Q0, ""),
        text_of(Q0, Q),
        (   S.web_search_backend == none
        ->  R = _{ok:false, tool:web_search,
                  error:_{type:no_backend, message:"No web_search_backend configured"}}
        ;   Backend = S.web_search_backend,
            call(Backend, Q, Hits),
            R = _{ok:true, tool:web_search, query:Q, results:Hits}
        )
    ).

tool_web_get(S, A, R) :-
    require_network(S, web_get, R0),
    (   nonvar(R0) -> R = R0
    ;   flex_get(url, A, Url0, ""),
        text_of(Url0, Url),
        catch(http_fetch(S, Url, Codes, Meta), E, fail_err(web_get, E, R)),
        (   var(R)
        ->  string_codes(Text0, Codes),
            truncate_text(Text0, S.max_output_bytes, Text, Trunc),
            R = _{ok:true, tool:web_get, url:Url, content:Text,
                  truncated:Trunc, meta:Meta}
        ;   true
        )
    ).

tool_download(S, A, R) :-
    require_network(S, download, R0),
    (   nonvar(R0) -> R = R0
    ;   flex_get(url, A, Url0, ""),
        flex_get(path, A, Rel, ""),
        text_of(Url0, Url),
        catch((safe_resolve(S, Rel, Abs),
               writable_allowed(S, Abs),
               http_fetch(S, Url, Codes, Meta),
               length(Codes, N),
               (   N > S.max_download_bytes
               ->  throw(error(permission_error(download, url, Url),
                               context(_, "download-size limit")))
               ;   true
               ),
               string_codes(Bin, Codes),
               file_directory_name(Abs, Dir),
               make_directory_path(Dir),
               atomic_write(Abs, Bin),
               R = _{ok:true, tool:download, url:Url, path:Rel, bytes:N, meta:Meta}),
              E, fail_err(download, E, R))
    ).

require_network(S, Tool, R) :-
    (   S.allow_network == true
    ->  true
    ;   R = _{ok:false, tool:Tool,
              error:_{type:permission_error, message:"Network access is disabled"}}
    ).

http_fetch(S, Url, Codes, Meta) :-
    uri_components(Url, uri_components(Scheme, Auth, _Path, _Q, _F)),
    (   memberchk(Scheme, [http, https])
    ->  true
    ;   throw(error(permission_error(open, url, Url),
                    context(_, "only http/https allowed")))
    ),
    uri_authority_components(Auth, uri_authority(_, _, Host, _)),
    (   Host == '' -> throw(error(permission_error(open, url, Url), _))
    ;   true
    ),
    (   unsafe_host(Host)
    ->  throw(error(permission_error(open, url, Url),
                    context(_, "loopback/link-local/internal host blocked")))
    ;   true
    ),
    (   S.allowed_hosts == []
    ->  true
    ;   (   memberchk(Host, S.allowed_hosts) -> true
        ;   throw(error(permission_error(open, url, Url),
                        context(_, "host is not on the allowlist")))
        )
    ),
    use_module(library(http/http_open)),
    setup_call_cleanup(
        http_open(Url, In,
                  [ timeout(15),
                    size_limit(S.max_download_bytes),
                    redirect(false)
                  ]),
        read_stream_to_codes(In, Codes),
        close(In)),
    Meta = _{scheme:Scheme, host:Host}.

unsafe_host(Host) :-
    memberchk(Host, ['localhost','127.0.0.1','::1','0.0.0.0']).
unsafe_host(Host) :-
    atom_concat('127.', _, Host).
unsafe_host(Host) :-
    atom_concat('10.', _, Host).
unsafe_host(Host) :-
    atom_concat('192.168.', _, Host).
unsafe_host(Host) :-
    atom_concat('169.254.', _, Host).
unsafe_host(Host) :-
    % RFC1918 172.16.0.0/12, i.e. second octet 16-31 inclusive.
    atom_concat('172.', Rest, Host),
    sub_atom(Rest, B, _, _, '.'), !,
    sub_atom(Rest, 0, B, _, Oct2A),
    atom_number(Oct2A, Oct2),
    integer(Oct2), Oct2 >= 16, Oct2 =< 31.
unsafe_host(Host) :-
    % IPv6 unique-local (fc00::/7) and link-local (fe80::/10) literals.
    % Gate on ':' so ordinary hostnames like "fcbank.example.com" are
    % never mistaken for an IPv6 address.
    sub_atom(Host, _, _, _, ':'), !,
    downcase_atom(Host, H),
    (   sub_atom(H, 0, 2, _, 'fc')
    ;   sub_atom(H, 0, 2, _, 'fd')
    ;   sub_atom(H, 0, 4, _, 'fe80')
    ).

/* ---------------- subagents ---------------- */

tool_subagents(S, A, R) :-
    flex_get(tasks, A, Tasks0, []),
    (   \+ is_list(Tasks0)
    ->  R = _{ok:false, tool:subagents,
              error:_{type:validation_error, message:"tasks must be a list"}}
    ;   normalize_tasks(Tasks0, Tasks),
        Limit is max(1, S.subagent_limit),
        run_subagents(S, Tasks, Limit, Results),
        R = _{ok:true, tool:subagents, results:Results}
    ).

normalize_tasks([], []).
normalize_tasks([T|Ts], [_{task:Text, id:Id}|Rest]) :-
    (   is_dict(T)
    ->  flex_get(task, T, Text0, ""),
        flex_get(id, T, Id0, ""),
        text_of(Text0, Text),
        (   Id0 == "" -> uuid(Id) ; text_of(Id0, Id) )
    ;   text_of(T, Text),
        uuid(Id)
    ),
    normalize_tasks(Ts, Rest).

run_subagents(S, Tasks, Limit, Results) :-
    length(Tasks, N),
    message_queue_create(Q),
    setup_call_cleanup(
        true,
        (   First is min(Limit, N),
            prefix(First, Tasks, Start),
            nth1_start(1, Start, S, Q, Alive0),
            skip(First, Tasks, Tail),
            pump_subagents(S, Q, Tail, First, Alive0, Limit, N, Pairs),
            keysort(Pairs, Sorted),
            pairs_values(Sorted, Results)
        ),
        message_queue_destroy(Q)).

nth1_start(_, [], _, _, []).
nth1_start(I, [T|Ts], S, Q, [Tid|More]) :-
    spawn_sub(S, I, T, Q, Tid),
    I2 is I + 1,
    nth1_start(I2, Ts, S, Q, More).

skip(0, L, L) :- !.
skip(N, [_|T], R) :- N > 0, N1 is N-1, skip(N1, T, R).

pump_subagents(_S, _Q, [], _NextIdx, [], _Lim, _N, []) :- !.
pump_subagents(S, Q, Tail, NextIdx, Alive, Lim, N, [I-Res|Rest]) :-
    thread_get_message(Q, done(I, Res, Tid)),
    (   member(Tid, Alive) -> delete(Alive, Tid, Alive1) ; Alive1 = Alive ),
    catch(thread_join(Tid, _), _, true),
    (   Tail = [T|Ts]
    ->  spawn_sub(S, NextIdx, T, Q, NewTid),
        Next2 is NextIdx + 1,
        pump_subagents(S, Q, Ts, Next2, [NewTid|Alive1], Lim, N, Rest)
    ;   pump_subagents(S, Q, [], NextIdx, Alive1, Lim, N, Rest)
    ).

spawn_sub(S, I, Task, Q, Tid) :-
    thread_create(subagent_body(S, I, Task, Q), Tid, [at_exit(true)]).

subagent_body(S, I, Task, Q) :-
    thread_self(Me),
    catch(run_one_sub(S, Task, Res0),
          E,
          (   term_string(E, Msg),
              Res0 = _{ok:false, id:Task.id, error:_{type:exception, message:Msg}}
          )),
    (   var(Res0)
    ->  Res = _{ok:false, id:Task.id, error:_{type:failed, message:"subagent failed"}}
    ;   Res = Res0
    ),
    thread_send_message(Q, done(I, Res, Me)).

run_one_sub(S, Task, Result) :-
    child_tools(S, Allowed),
    harness_new(
        [ adapter(S.adapter),
          root(S.root),
          cwd(S.cwd),
          model(S.model),
          allow_shell(false),
          allow_network(false),
          max_steps(8),
          timeout(30),
          parent(S.id),
          allowed_tools(Allowed),
          mock_replies(S.mock_script)
        ],
        Child),
    setup_call_cleanup(
        true,
        (   harness_run(Child, Task.task, Answer),
            harness_messages(Child, Msgs),
            Result = _{ok:true, id:Task.id, task:Task.task, answer:Answer,
                       messages:Msgs}
        ),
        harness_close(Child)).

child_tools(S, all) :-
    S.subagent_allow_writes == true, !.
child_tools(_, [read_file,list_files,search,file_info,git_status,git_diff,git_log,git_show]).

/* ---------------- conversation / state ---------------- */

detect_repeat_failures(Id, Results) :-
    include(is_fail, Results, Fails),
    maplist(fail_sig, Fails, Sigs),
    mutate(Id, add_fail_sigs(Sigs)),
    state(Id, S),
    (   member(Sig, Sigs),
        include(=(Sig), S.fail_signatures, Same),
        length(Same, N),
        N >= 3
    ->  mutate(Id, add_message(_{role:system,
                                 content:"Repeated identical tool failure detected; stop retrying the same call."}))
    ;   true
    ).

is_fail(R) :- get_dict(ok, R, false).
fail_sig(R, sig(T, E)) :-
    get_dict(tool, R, T),
    (   get_dict(error, R, Err), get_dict(type, Err, E) -> true ; E = unknown ).

state(Id, S) :-
    harness_rec(Id, Mutex, _),
    !,
    with_mutex(Mutex, harness_rec(Id, Mutex, S)).
state(Id, _) :-
    existence_error(codex_harness, Id).

mutate(Id, Action) :-
    harness_rec(Id, Mutex, _),
    with_mutex(Mutex,
               (   retract(harness_rec(Id, Mutex, S0)),
                   apply_mut(Action, S0, S1),
                   assertz(harness_rec(Id, Mutex, S1)))).

apply_mut(cancel, S0, S1) :-
    S1 = S0.put(cancelled, true).
apply_mut(reset, S0, S1) :-
    S1 = S0.put(_{messages:[], iteration:0, last_answer:"",
                  last_error:null, tool_activity:[], fail_signatures:[],
                  cancelled:false, current_task:""}).
apply_mut(start_run(Task), S0, S1) :-
    text_of(Task, T),
    S1 = S0.put(_{running:true, current_task:T, cancelled:false, last_error:null}).
apply_mut(finish_run(Answer), S0, S1) :-
    text_of(Answer, A),
    persist_if(S0),
    S1 = S0.put(_{running:false, last_answer:A}).
apply_mut(set_iteration(I), S0, S1) :-
    S1 = S0.put(iteration, I).
apply_mut(set_error(E), S0, S1) :-
    S1 = S0.put(last_error, E).
apply_mut(add_message(M), S0, S1) :-
    append(S0.messages, [M], Ms),
    S1 = S0.put(messages, Ms),
    persist_msg(S0, M).
apply_mut(record_tool(Res), S0, S1) :-
    append(S0.tool_activity, [Res], Act),
    S1 = S0.put(tool_activity, Act).
apply_mut(add_fail_sigs(Sigs), S0, S1) :-
    append(S0.fail_signatures, Sigs, All),
    S1 = S0.put(fail_signatures, All).

persist_if(_).
persist_msg(S, Msg) :-
    (   S.transcript == none
    ->  true
    ;   get_time(TS),
        catch(setup_call_cleanup(
                  open(S.transcript, append, Out, [encoding(utf8)]),
                  (   json_write_dict(Out, Msg.put(ts, TS), [width(0)]),
                      nl(Out)
                  ),
                  close(Out)),
              _, true)
    ).

emit(Id, Event) :-
    state(Id, S),
    redact_result(Id, Event, Safe),
    debug(codex_harness, '~w', [Safe]),
    (   S.on_event == none
    ->  true
    ;   OnEvent = S.on_event,
        % A misbehaving/unreachable callback must never break the run,
        % but silently eating the error made real bugs (e.g. an
        % unqualified callback goal resolving in the wrong module)
        % invisible. Log it under the codex_harness debug topic instead.
        catch(call(OnEvent, Safe), CallbackError,
              debug(codex_harness, 'on_event callback failed: ~q', [CallbackError]))
    ).

redact_result(Id, Dict0, Dict) :-
    state(Id, S),
    term_string(Dict0, T0),
    foldl(redact_one, S.secrets, T0, T1),
    (   T0 == T1
    ->  Dict = Dict0
    ;   term_string(Dict, T1)
    ).

redact_one(Secret, In, Out) :-
    text_of(Secret, S),
    (   sub_string(In, _, _, _, S)
    ->  atomic_list_concat(Parts, S, In),
        atomic_list_concat(Parts, '***', Out)
    ;   Out = In
    ).

/* ---------------- utilities ---------------- */

fail_err(Tool, Error, _{ok:false, tool:Tool,
                        error:_{type:Type, message:Msg}}) :-
    (   Error = error(permission_error(_,_,_), _)
    ->  Type = permission_error
    ;   Error = error(existence_error(_,_), _)
    ->  Type = not_found
    ;   Type = exception
    ),
    term_string(Error, Msg).

flex_get(Key, Dict, Value, Default) :-
    is_dict(Dict),
    !,
    (   atom_key(Key, Atom),
        get_dict(Atom, Dict, Value)
    ->  true
    ;   Value = Default
    ).
flex_get(_, _, Default, Default).

atom_key(Key, Key) :-
    atom(Key), !.
atom_key(Key, Atom) :-
    string(Key),
    atom_string(Atom, Key).

ensure_dict(D, D) :-
    is_dict(D), !.
ensure_dict(json(Pairs), D) :-
    !, dict_create(D, _, Pairs).
ensure_dict(Atom, D) :-
    (   atom(Atom) ; string(Atom) ),
    catch(atom_json_dict(Atom, D, []), _, fail), !.
ensure_dict(_, _{}).

text_of(Var, "") :-
    var(Var), !.
text_of(S, S) :-
    string(S), !.
text_of(A, S) :-
    atom(A), !, atom_string(A, S).
text_of(N, S) :-
    number(N), !, format(string(S), "~w", [N]).
text_of(T, S) :-
    term_string(T, S).

name_atom(A, A) :-
    atom(A), !.
name_atom(S, A) :-
    atom_string(A, S).

truncate_text(Text0, Max, Text, Trunc) :-
    text_of(Text0, T),
    string_length(T, N),
    (   N =< Max
    ->  Text = T, Trunc = false
    ;   sub_string(T, 0, Max, _, Head),
        string_concat(Head, "\n[truncated]", Text),
        Trunc = true
    ).

slice_text(Text, Off, Lim, Out) :-
    split_string(Text, "\n", "", Lines),
    (   number(Off), Off > 0 -> skip(Off, Lines, Mid) ; Mid = Lines ),
    (   number(Lim), Lim >= 0 -> prefix(Lim, Mid, Keep) ; Keep = Mid ),
    atomic_list_concat(Keep, "\n", Out).

prefix(N, List, Pref) :-
    length(Pref, N),
    append(Pref, _, List), !.
prefix(_, List, List).

is_absolute_filename(P) :-
    atom_string(A, P),
    (   sub_atom(A, 1, 1, _, ':')
    ;   sub_atom(A, 0, 1, _, '/')
    ;   sub_atom(A, 0, 1, _, '\\')
    ).
