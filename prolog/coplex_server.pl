:- encoding(utf8).
:- module(coplex_server,
          [ server_start/2,            % +Port, +Host
            server_stop/0
          ]).

/** <module> REST facade over codex_harness (the "coplex" pack)

Exposes the codex_harness/1 API (see prolog/coplex/codex_harness.pl) as
a small JSON REST service so a host process -- e.g. the
symbolic_learner_workbench "workbench" -- can create, drive, observe,
and tear down harness instances over HTTP instead of embedding
SWI-Prolog directly. This is the concrete implementation of the
`plugin-api` / `routePrefix` surface declared in plugin.json: it lets
the workbench "puppet" this plugin.

Run standalone for manual testing:

    swipl prolog/coplex_server_main.pl --port=8840 --host=localhost

This module is a plain library: loading it with use_module/1 never
starts a server or blocks a thread.  The `coplex_server_main.pl`
sibling file is the runnable entry point that calls server_start/2 and
then blocks the process; keeping the two separate means test suites
and other libraries can safely `:- use_module(coplex_server)`
without accidentally spinning up a background HTTP server.

Normally the server is started/stopped by plugin.py's process manager
(see `workbench_startup/0` and `workbench_shutdown/0` there), which
launches `coplex_server_main.pl` as a subprocess and also
exposes the server through the plugin-api `status/0`, `config/0`,
`restart/0` and `shutdown/0` hooks.

## Security model

The request body coming over the network is **never** parsed as
Prolog source and never handed to call/1 with an attacker-controlled
functor:

  * harness_new/2 options accepted from JSON are restricted to a fixed
    allowlist (safe_option_key/1) of scalar/text/list options.  The
    goal-shaped options `approval`, `on_event`, `parent`, and
    `web_search_backend` (all of which the core module eventually
    call/N's) are *not* in the allowlist and can only be set by an
    in-process Prolog caller of harness_new/2 directly.
  * `adapter` is normalised to one of the two built-in atoms
    `scripted` or `mock`; any other value is silently mapped to
    `scripted` rather than passed through.
  * Tool names arriving on the URL (`POST /harnesses/<Id>/tools/<Name>`)
    are only ever unified against codex_harness's fixed
    `dispatch_tool/5` clause table, so an unknown/attacker-chosen name
    can never resolve to an arbitrary predicate.
  * The server binds to `localhost` by default; pass a different
    `--host` only if the workbench genuinely runs in a different
    network namespace from this plugin.
  * CORS is enabled (Access-Control-Allow-Origin) so a browser-based
    web UI can call this API directly, since that is the whole point
    of exposing a REST surface for "someone to design a UI around".
    This is safe *because* the server only binds to localhost by
    default -- a remote page can still reach it via a victim's
    browser, so set `COPLEX_CORS_ORIGIN` to a specific origin
    (or the empty string to disable CORS entirely) instead of the
    default `*` wildcard for anything beyond local development.

## Endpoints for a management UI

Every mutating action a UI needs is a plain REST call, and every piece
of state it needs to render is a plain REST read -- nothing requires
an open connection or a Prolog client:

  * `POST /harnesses/<id>/run` blocks until the agent loop finishes by
    default. Pass `{"async": true}` in the body instead to get an
    immediate `{ok:true, started:true}` reply while the run continues
    in a background thread; poll `GET /harnesses/<id>` (or the lighter
    `GET /harnesses` list) for `running`/`last_answer`/`last_error` to
    know when it's done. A second `run` while one is already in flight
    is rejected with HTTP 409 rather than corrupting shared state.
  * `GET /harnesses` returns both `ids` (unchanged, for existing
    callers) and `harnesses`, a list of lightweight per-harness status
    dicts (`running`, `current_task`, `iteration`, `last_answer`,
    `last_error`, `message_count`, `tool_call_count`, `created_at`) --
    enough to render a dashboard table without an extra request per
    row.
  * `GET /harnesses/<id>` returns the full snapshot (same fields plus
    the complete `messages`/`tool_activity` history) for a detail view.

@see prolog/coplex/codex_harness.pl, README.md, FEATURE_GUIDE.md
*/

:- use_module(coplex/codex_harness).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(http/http_cors)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(debug)).
:- use_module(library(settings)).

:- dynamic running_port/1.

%   CORS is on by default (any origin) so a browser-based web UI can
%   call this API straight from JavaScript without a proxy; this is a
%   deliberate trade-off documented in the module docstring above.
%   Override with the COPLEX_CORS_ORIGIN environment variable:
%   a comma-separated list of allowed origins, or "" to disable CORS.
:- initialization(configure_cors).

configure_cors :-
    (   getenv('COPLEX_CORS_ORIGIN', Raw)
    ->  true
    ;   Raw = "*"
    ),
    cors_origin_list(Raw, Origins),
    set_setting(http:cors, Origins).

cors_origin_list("", []) :- !.
cors_origin_list(Raw, Origins) :-
    split_string(Raw, ",", " ", Parts0),
    exclude(==(""), Parts0, Parts),
    maplist(atom_string, Origins, Parts).

%   Declared meta_predicate (before any use) so that dict functional
%   notation (e.g. `Snap.put(ok, true)`) embedded in a caller's Goal
%   argument is expanded at compile time, matching how catch/3 treats
%   its own first argument.
:- meta_predicate with_existing_harness(+, 0).
:- meta_predicate with_json_body(+, -, 0).

%   Every route answers at the root and, in parity, under the /coplex
%   prefix (the pack's slug), so both the workbench's stripped-prefix
%   proxy mount and direct prefixed callers reach the same handlers.
:- http_handler('/health', health_handler, [methods([get,options])]).
:- http_handler('/shutdown', shutdown_handler, [methods([post,options])]).
:- http_handler('/tools', tools_handler, [methods([get,options])]).
:- http_handler('/harnesses', harnesses_collection, [methods([get,post,options])]).
:- http_handler('/harnesses/', harnesses_item, [prefix]).
:- http_handler('/coplex', coplex_status_handler, [methods([get,options])]).
:- http_handler('/coplex/health', health_handler, [methods([get,options])]).
:- http_handler('/coplex/shutdown', shutdown_handler, [methods([post,options])]).
:- http_handler('/coplex/tools', tools_handler, [methods([get,options])]).
:- http_handler('/coplex/harnesses', harnesses_collection, [methods([get,post,options])]).
:- http_handler('/coplex/harnesses/', harnesses_item, [prefix]).

%!  server_start(+Port, +Host) is det.
%
%   Start the REST server bound to Host:Port.  Throws
%   permission_error(start, server, already_running) if a server is
%   already running in this process.
server_start(Port, Host) :-
    (   running_port(_)
    ->  throw(error(permission_error(start, server, already_running), _))
    ;   true
    ),
    http_server(http_dispatch, [port(Port), ip(Host)]),
    asserta(running_port(Port)),
    debug(coplex_server, 'listening on ~w:~w', [Host, Port]).

%!  server_stop is det.
%
%   Stop the server started by server_start/2, if any.  Idempotent.
server_stop :-
    (   retract(running_port(Port))
    ->  catch(http_stop_server(Port, []), _, true)
    ;   true
    ).

/* --------------------------------------------------------------- */
/* handlers                                                         */
/* --------------------------------------------------------------- */

health_handler(Request) :-
    ( memberchk(method(options), Request)
    ->  cors_enable(Request, [methods([get])]),
        format('~n')
    ;   cors_enable,
        reply_json_dict(_{ok:true, service:"coplex"})
    ).

%!  coplex_status_handler(+Request) is det.
%
%   GET /coplex -- the same status document `python plugin.py status`
%   prints on the host side: identity, swipl version, server binding,
%   path prefixes, and the endpoint list.
coplex_status_handler(Request) :-
    ( memberchk(method(options), Request)
    ->  cors_enable(Request, [methods([get])]),
        format('~n')
    ;   cors_enable,
        swipl_version_string(Version),
        ( running_port(Port) -> Running = true ; Port = null, Running = false ),
        rest_endpoints(Endpoints),
        reply_json_dict(_{
            ok: true,
            plugin_id: "coplex",
            slug: "coplex",
            standalone: true,
            swipl_version: Version,
            server: _{running: Running, port: Port},
            rest_api: Running,
            path_prefixes: ["/", "/coplex"],
            endpoints: Endpoints
        })
    ).

swipl_version_string(Version) :-
    current_prolog_flag(version, N),
    Major is N // 10000,
    Minor is (N // 100) mod 100,
    Patch is N mod 100,
    format(string(Version), "~w.~w.~w", [Major, Minor, Patch]).

rest_endpoints([
    "GET    /health",
    "GET    /tools",
    "GET    /harnesses",
    "POST   /harnesses",
    "GET    /harnesses/<id>",
    "DELETE /harnesses/<id>",
    "POST   /harnesses/<id>/run",
    "POST   /harnesses/<id>/cancel",
    "POST   /harnesses/<id>/reset",
    "GET    /harnesses/<id>/messages",
    "POST   /harnesses/<id>/tools/<name>",
    "POST   /shutdown"
]).

shutdown_handler(Request) :-
    ( memberchk(method(options), Request)
    ->  cors_enable(Request, [methods([post])]),
        format('~n')
    ;   cors_enable,
        reply_json_dict(_{ok:true, message:"shutting down"}),
        thread_create(delayed_halt, _, [detached(true)])
    ).

delayed_halt :-
    sleep(0.2),
    server_stop,
    halt(0).

tools_handler(Request) :-
    ( memberchk(method(options), Request)
    ->  cors_enable(Request, [methods([get])]),
        format('~n')
    ;   cors_enable,
        harness_tool_specs(Specs),
        maplist(spec_dict, Specs, Dicts),
        reply_json_dict(_{ok:true, tools:Dicts})
    ).

spec_dict(spec(Name, Risk, Desc, Schema),
          _{name:Name, risk:Risk, description:Desc, schema:Schema}).

harnesses_collection(Request) :-
    memberchk(method(Method), Request),
    harnesses_collection_(Method, Request).

harnesses_collection_(options, Request) :- !,
    cors_enable(Request, [methods([get,post])]),
    format('~n').
harnesses_collection_(get, _Request) :-
    cors_enable,
    harness_list(Ids),
    maplist(list_summary, Ids, Summaries),
    reply_json_dict(_{ok:true, ids:Ids, harnesses:Summaries}).
harnesses_collection_(post, Request) :-
    cors_enable,
    with_json_body(Request, Body,
        ( dict_options(Body, Options),
          harness_new(Options, codex_harness(Id)),
          reply_json_dict(_{ok:true, id:Id})
        )).

list_summary(Id, Summary) :-
    harness_summary(codex_harness(Id), Summary).

harnesses_item(Request) :-
    memberchk(method(Method), Request),
    ( Method == options
    ->  cors_enable(Request, [methods([get,post,delete])]),
        format('~n')
    ;   cors_enable,
        memberchk(path(Path), Request),
        path_segments_after('/harnesses/', Path, Segments),
        dispatch_item(Segments, Method, Request)
    ).

path_segments_after(Prefix, Path, Segments) :-
    %   The same handler serves the root route and its /coplex-prefixed
    %   parity route, so an optional /coplex is stripped before matching.
    (   atom_concat(Prefix, Rest, Path)
    ->  true
    ;   atom_concat('/coplex', Unprefixed, Path),
        atom_concat(Prefix, Rest, Unprefixed)
    ),
    split_string(Rest, "/", "", Segments0),
    exclude(==(""), Segments0, Segments).

dispatch_item([IdS], get, _Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        ( harness_snapshot(codex_harness(Id), Snap),
          reply_json_dict(Snap.put(ok, true))
        )).
dispatch_item([IdS], delete, _Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        ( harness_close(codex_harness(Id)),
          reply_json_dict(_{ok:true})
        )).
dispatch_item([IdS, "run"], post, Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        with_json_body(Request, Body,
            ( flex_task_text(Body, Task),
              flex_run_options(Body, RunOptions),
              flex_async_flag(Body, Async),
              (   Async == true
              ->  harness_run_async(codex_harness(Id), Task, RunOptions),
                  reply_json_dict(_{ok:true, id:Id, started:true, async:true})
              ;   harness_run(codex_harness(Id), Task, RunOptions, Answer),
                  reply_json_dict(_{ok:true, answer:Answer})
              )
            ))).
dispatch_item([IdS, "cancel"], post, _Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        ( harness_cancel(codex_harness(Id)),
          reply_json_dict(_{ok:true})
        )).
dispatch_item([IdS, "reset"], post, _Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        ( harness_reset(codex_harness(Id)),
          reply_json_dict(_{ok:true})
        )).
dispatch_item([IdS, "messages"], get, _Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        ( harness_messages(codex_harness(Id), Msgs),
          reply_json_dict(_{ok:true, messages:Msgs})
        )).
dispatch_item([IdS, "tools", NameS], post, Request) :- !,
    atom_string(Id, IdS),
    atom_string(Name, NameS),
    with_existing_harness(Id,
        with_json_body(Request, Body,
            ( harness_tool(codex_harness(Id), Name, Body, Result),
              reply_json_dict(Result)
            ))).
dispatch_item(_Segments, _Method, _Request) :-
    reply_error(404, error(existence_error(http_route, not_found), _)).

/* --------------------------------------------------------------- */
/* helpers                                                          */
/* --------------------------------------------------------------- */

with_existing_harness(Id, Goal) :-
    (   harness_known(Id)
    ->  catch(Goal, Error, (error_status(Error, Code), reply_error(Code, Error)))
    ;   reply_error(404, error(existence_error(codex_harness, Id), _))
    ).

harness_known(Id) :-
    harness_list(Ids),
    memberchk(Id, Ids), !.

with_json_body(Request, Body, Goal) :-
    catch(http_read_json_dict(Request, Body0), _, Body0 = _{}),
    ( is_dict(Body0) -> Body = Body0 ; Body = _{} ),
    catch(Goal, Error, (error_status(Error, Code), reply_error(Code, Error))).

%!  error_status(+Error, -HttpCode) is det.
%   Maps a caught Prolog error term to the HTTP status code a REST
%   client should see. Anything not recognised falls back to 500.
error_status(error(permission_error(start, harness_run, already_running), _), 409) :- !.
error_status(_, 500).

flex_task_text(Body, Task) :-
    ( get_dict(task, Body, T) -> Task = T ; Task = "" ).

flex_run_options(Body, Options) :-
    ( get_dict(context, Body, Ctx) -> Options = [context(Ctx)] ; Options = [] ).

%!  flex_async_flag(+Body, -Async) is det.
%   Async is `true` only when the request body explicitly asked for
%   it (`{"async": true}`); anything else -- absent, false, or any
%   other JSON value -- keeps the default blocking behaviour.
flex_async_flag(Body, Async) :-
    ( get_dict(async, Body, V), V == true -> Async = true ; Async = false ).

reply_error(Code, Error) :-
    message_to_string_safe(Error, Msg),
    reply_json_dict(_{ok:false, error:Msg}, [status(Code)]).

message_to_string_safe(Error, Msg) :-
    catch(message_to_codes(Error, [], Codes), _, fail),
    !,
    string_codes(Msg, Codes).
message_to_string_safe(Error, Msg) :-
    term_string(Error, Msg).

/* --------------------------------------------------------------- */
/* safe option translation (JSON body -> harness_new/2 Options)     */
/* --------------------------------------------------------------- */

%   Deliberately excludes approval/1, on_event/1, parent/1, and
%   web_search_backend/1: the core module eventually call/N's each of
%   those, so they must never be constructible from untrusted JSON.
safe_option_key(root). safe_option_key(cwd). safe_option_key(model).
safe_option_key(instructions). safe_option_key(extra_instructions).
safe_option_key(allow_shell). safe_option_key(allow_network).
safe_option_key(allow_shell_string). safe_option_key(allowed_hosts).
safe_option_key(writable_paths). safe_option_key(readable_paths).
safe_option_key(max_output_bytes). safe_option_key(max_download_bytes).
safe_option_key(timeout). safe_option_key(command_timeout).
safe_option_key(max_steps). safe_option_key(subagent_limit).
safe_option_key(subagent_allow_writes). safe_option_key(transcript).
safe_option_key(secrets). safe_option_key(default_test_command).
safe_option_key(mock_replies). safe_option_key(allowed_tools).
safe_option_key(adapter).

dict_options(Dict, Options) :-
    dict_pairs(Dict, _, Pairs),
    convlist(safe_pair_option, Pairs, Options).

safe_pair_option(Key-Value, Opt) :-
    to_key_atom(Key, KeyAtom),
    safe_option_key(KeyAtom),
    !,
    sanitize_value(KeyAtom, Value, Safe),
    Opt =.. [KeyAtom, Safe].

to_key_atom(Key, Key) :- atom(Key), !.
to_key_atom(Key, Atom) :- atom_string(Atom, Key).

sanitize_value(adapter, V, Out) :-
    !,
    (   (V == "mock" ; V == mock)
    ->  Out = mock
    ;   Out = scripted
    ).
sanitize_value(_, V, V).
