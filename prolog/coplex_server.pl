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
  * `adapter` is normalised to one of three built-in atoms --
    `scripted`, `mock`, or `openai` -- any other value is silently
    mapped to `scripted` rather than passed through. `openai` (see
    `openai_chat_adapter/3`) does make real outbound HTTP calls, but
    only ever to `adapter_url` (plain, harness-creation-time
    configuration, gated by the same `allow_network` flag the web
    tools already require), never to anything derived from a
    request's `call/N`-shaped fields.
  * Tool names arriving on the URL (`POST /coplex/harnesses/<Id>/tools/<Name>`
    or the harness-less `POST /coplex/tools/<Name>`) are only ever unified
    against codex_harness's fixed `dispatch_tool/5` clause table, so an
    unknown/attacker-chosen name can never resolve to an arbitrary
    predicate.
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
an open connection or a Prolog client. Every path below is shown
`/coplex`-prefixed (the canonical, documented form -- see
rest_endpoints/1); each also answers unprefixed at the bare root
purely so the workbench's stripped-prefix proxy mount can reach it
(see path_segments_after/3 and the http_handler/3 directives below):

  * `POST /coplex/harnesses/<id>/run` blocks until the agent loop
    finishes by default. Pass `{"async": true}` in the body instead to
    get an immediate `{ok:true, started:true}` reply while the run
    continues in a background thread; poll `GET
    /coplex/harnesses/<id>` (or the lighter `GET /coplex/harnesses`
    list) for `running`/`last_answer`/`last_error` to know when it's
    done. A second `run` while one is already in flight is rejected
    with HTTP 409 rather than corrupting shared state.
  * `GET /coplex/harnesses` returns both `ids` (unchanged, for
    existing callers) and `harnesses`, a list of lightweight
    per-harness status dicts (`running`, `current_task`, `iteration`,
    `last_answer`, `last_error`, `message_count`, `tool_call_count`,
    `created_at`) -- enough to render a dashboard table without an
    extra request per row.
  * `GET /coplex/harnesses/<id>` returns the full snapshot (same
    fields plus the complete `messages`/`tool_activity` history) for a
    detail view.
  * `GET /coplex/tools` advertises a real, working `method` + `endpoint`
    for every tool (`POST /coplex/tools/<name>`) backed by a shared,
    lazily-created harness, for callers that just want to run one tool
    without first managing a harness's lifecycle.
  * `GET /coplex` itself now serves the browser-facing admin UI (see
    admin_ui_handler/1) -- a thin client over exactly the endpoints
    above. The JSON status/endpoint-list document that used to live
    here moved to `GET /coplex/endpoints` (coplex_endpoints_handler/1).

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

%   The `/coplex`-prefixed form of every route below is the canonical,
%   documented one (see rest_endpoints/1, README.md, docs/04-rest-
%   api.md) -- but each also answers unprefixed at the bare root, in
%   parity, purely so the workbench's stripped-prefix proxy mount
%   (which forwards e.g. `<workbench>/coplex/tools` to this server's
%   bare `/tools`) can still reach it. `/coplex` (and bare `/`) serve
%   the admin UI (see admin_ui_handler/1); the JSON status/endpoint-
%   list document that used to live at `/coplex` moved to
%   `/coplex/endpoints` (and bare `/endpoints`) -- see
%   coplex_endpoints_handler/1.
:- http_handler('/', admin_ui_handler, [methods([get,options])]).
:- http_handler('/endpoints', coplex_endpoints_handler, [methods([get,options])]).
:- http_handler('/health', health_handler, [methods([get,options])]).
:- http_handler('/shutdown', shutdown_handler, [methods([post,options])]).
:- http_handler('/tools', tools_handler, [methods([get,options])]).
:- http_handler('/tools/', direct_tool_item, [prefix]).
:- http_handler('/harnesses', harnesses_collection, [methods([get,post,options])]).
:- http_handler('/harnesses/', harnesses_item, [prefix]).
:- http_handler('/coplex', admin_ui_handler, [methods([get,options])]).
:- http_handler('/coplex/endpoints', coplex_endpoints_handler, [methods([get,options])]).
:- http_handler('/coplex/health', health_handler, [methods([get,options])]).
:- http_handler('/coplex/shutdown', shutdown_handler, [methods([post,options])]).
:- http_handler('/coplex/tools', tools_handler, [methods([get,options])]).
:- http_handler('/coplex/tools/', direct_tool_item, [prefix]).
:- http_handler('/coplex/harnesses', harnesses_collection, [methods([get,post,options])]).
:- http_handler('/coplex/harnesses/', harnesses_item, [prefix]).

%!  server_start(+Port, +Host) is det.
%
%   Start the REST server bound to Host:Port.  Throws
%   permission_error(start, server, already_running) if a server is
%   already running in this process. Restores any harness a previous
%   process persisted to disk (see codex_harness.pl's
%   rehydrate_harnesses/0) *before* the listener comes up, so there's
%   no window where the server answers requests without yet having
%   loaded what survived the restart. Idempotent to call more than
%   once across a process's lifetime (e.g. the test suite's
%   setup_server/0 stops and restarts its own server per run) --
%   rehydrate_harnesses/0 skips any harness id that's already live.
server_start(Port, Host) :-
    (   running_port(_)
    ->  throw(error(permission_error(start, server, already_running), _))
    ;   true
    ),
    rehydrate_harnesses,
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

%!  admin_ui_handler(+Request) is det.
%
%   GET /coplex (and bare `/`) -- a small, self-contained (no
%   external CSS/JS, no build step, no network dependency) HTML admin
%   dashboard for this REST API: browse the tool catalog, create/run/
%   inspect/delete harnesses. All of its client-side JS just calls the
%   ordinary JSON endpoints documented in rest_endpoints/1 through the
%   absolute `/coplex/...` paths, so it works identically whether the
%   browser loaded it directly from this server or through the
%   workbench's stripped-prefix proxy mount (see the module docstring).
admin_ui_handler(Request) :-
    ( memberchk(method(options), Request)
    ->  cors_enable(Request, [methods([get])]),
        format('~n')
    ;   cors_enable,
        format('Content-type: text/html; charset=UTF-8~n~n'),
        admin_ui_html(Html),
        format('~s', [Html])
    ).

%!  admin_ui_html(-Html) is det.
%
%   The admin UI's markup, styling, and client-side JS as one
%   self-contained string -- no external CSS/JS, no build step, no
%   CDN dependency. All data comes from client-side fetch() calls
%   against the ordinary JSON endpoints below (absolute /coplex/...
%   paths), never server-side templating, so this predicate is a
%   pure, static constant.
admin_ui_html(Html) :-
    Html = "<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<meta http-equiv='Content-Security-Policy' content='default-src self; style-src unsafe-inline; script-src unsafe-inline; connect-src self; frame-ancestors self'>
<title>coplex admin</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #06141a;
    --panel: #0a2028;
    --line: #24505e;
    --text: #d7eef2;
    --muted: #7fa2aa;
    --cyan: #33e6db;
    --violet: #b79aff;
    --amber: #f6c85f;
    --red: #ff7e97;
    --green: #63e6a4;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background: linear-gradient(145deg, #06141a 0%, #081a22 60%, #0b1726 100%);
    color: var(--text);
    font: 13px/1.45 ui-monospace, SFMono-Regular, Consolas, monospace;
  }
  button, input, select, textarea { font: inherit; }
  button, input, select, textarea {
    border: 1px solid var(--line);
    border-radius: 3px;
    background: #071b22;
    color: var(--text);
  }
  button { cursor: pointer; padding: 8px 12px; color: var(--cyan); }
  button:hover:not(:disabled) { border-color: var(--cyan); background: #0b2b33; }
  button:disabled { cursor: not-allowed; opacity: .45; }
  input, select, textarea { width: 100%; padding: 8px 9px; }
  textarea { min-height: 80px; resize: vertical; }
  label { display: grid; gap: 5px; color: var(--muted); font-size: 11px; }
  label.inline { display: flex; flex-direction: row; align-items: center; gap: 6px !important; }
  label.inline input { width: auto; }
  header {
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
    padding: 14px 20px; border-bottom: 1px solid var(--line);
    background: rgba(5, 20, 26, .92); position: sticky; top: 0; z-index: 3;
  }
  h1, h2, h3, p { margin: 0; }
  h1 { font-size: 18px; color: var(--cyan); letter-spacing: .04em; }
  h2 { font-size: 13px; color: var(--violet); text-transform: uppercase; letter-spacing: .08em; }
  h3 { font-size: 12px; color: var(--cyan); margin: 12px 0 6px; }
  small { color: var(--muted); }
  .badges { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 7px; align-items: center; }
  .badge { padding: 4px 7px; border: 1px solid var(--line); color: var(--muted); }
  .badge.ok { border-color: #28745a; color: var(--green); }
  .badge.warn { border-color: #806b33; color: var(--amber); }
  main { display: grid; grid-template-columns: minmax(280px, .8fr) minmax(420px, 1.4fr); min-height: calc(100vh - 62px); }
  aside, .detail { min-width: 0; padding: 14px; }
  aside { border-right: 1px solid var(--line); }
  .panel { border: 1px solid var(--line); background: rgba(7, 28, 35, .88); margin-bottom: 12px; }
  .panel.attention { border-color: var(--amber); }
  .panel-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 9px 11px; border-bottom: 1px solid var(--line); background: #12253a; }
  .panel-body { padding: 11px; }
  .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; }
  .form-grid .wide { grid-column: 1 / -1; }
  .row-list { display: grid; gap: 6px; max-height: 34vh; overflow: auto; }
  .row-btn { display: grid; grid-template-columns: 1fr auto; gap: 5px 9px; width: 100%; text-align: left; color: var(--text); }
  .row-btn.active { border-color: var(--cyan); background: #0b2b33; }
  .row-btn span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .row-btn small { grid-column: 1 / -1; }
  .state { color: var(--muted); text-transform: uppercase; font-size: 10px; }
  .state.running { color: var(--amber); }
  .state.idle { color: var(--green); }
  .state.error { color: var(--red); }
  .state.pending { color: var(--amber); }
  .summary { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
  .summary div { padding: 8px; border: 1px solid var(--line); background: #071b22; }
  .summary b, .summary span { display: block; overflow-wrap: anywhere; }
  .summary span { margin-top: 3px; color: var(--muted); font-size: 10px; }
  pre { margin: 0; padding: 10px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; background: #05151b; border: 1px solid var(--line); color: #bfe4e8; max-height: 30vh; }
  .answer { min-height: 60px; }
  .answer.error { color: var(--red); }
  .events { display: grid; gap: 5px; max-height: 40vh; overflow: auto; }
  .event { display: grid; grid-template-columns: 32px minmax(90px, .4fr) minmax(0, 1.6fr); gap: 8px; padding: 7px; border: 1px solid #183d48; background: #071b22; }
  .event code { color: var(--violet); }
  .event span:last-child { color: var(--muted); overflow-wrap: anywhere; white-space: pre-wrap; }
  .approvals { display: grid; gap: 8px; }
  .approval-row { display: grid; gap: 7px; padding: 9px; border: 1px solid var(--amber); background: #1c1706; }
  .approval-row .head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .approval-row .head b { color: var(--amber); }
  .approval-row pre { max-height: 14vh; }
  .approval-row .actions { display: flex; gap: 7px; }
  .approval-row .actions button { flex: 1; }
  .btn-allow { color: var(--green); border-color: #28745a; }
  .btn-deny { color: var(--red); border-color: #70404a; }
  .risk-read_only { color: var(--muted); }
  .risk-write { color: var(--amber); border-color: var(--amber); }
  .risk-process, .risk-network { color: var(--red); border-color: var(--red); }
  .danger { color: var(--red); border-color: #70404a; }
  .secondary { color: var(--text); }
  .empty { padding: 18px; text-align: center; color: var(--muted); }
  .toolbar { display: flex; flex-wrap: wrap; gap: 7px; }
  #run-modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.6); align-items: center; justify-content: center; z-index: 10; }
  #run-modal .box { background: var(--panel); border: 1px solid var(--line); border-radius: 4px; padding: 16px; width: 520px; max-width: 92vw; }
  footer { text-align: center; color: var(--muted); font-size: 11px; padding: 16px; }
  footer a { color: var(--cyan); }
  @media (max-width: 900px) {
    main { grid-template-columns: 1fr; }
    aside { border-right: 0; border-bottom: 1px solid var(--line); }
    .summary { grid-template-columns: 1fr 1fr; }
  }
</style>
</head>
<body>
<header>
  <div>
    <h1>coplex</h1>
    <small>SWI-Prolog coding-agent harness console</small>
  </div>
  <div class='badges'>
    <span id='server-badge' class='badge'>loading...</span>
    <button id='refresh' type='button'>Refresh</button>
  </div>
</header>
<main>
  <aside>
    <section class='panel'>
      <div class='panel-head'><h2>New harness</h2><span id='submit-state' class='state'></span></div>
      <form id='create-form' class='panel-body form-grid'>
        <label class='wide'>Task (optional - runs immediately if given)
          <textarea id='f-task' placeholder='Describe the repository work...'></textarea>
        </label>
        <label>Root <input id='f-root' value='.'></label>
        <label>Adapter
          <select id='f-adapter'>
            <option value='scripted'>scripted</option>
            <option value='mock'>mock</option>
            <option value='openai'>openai</option>
          </select>
        </label>
        <label>Model <input id='f-model' list='models' placeholder='default' autocomplete='off'>
          <datalist id='models'>
            <option value='gpt-4o-mini'></option>
            <option value='gpt-4o'></option>
            <option value='gpt-4.1-mini'></option>
          </datalist>
        </label>
        <label>Approval mode
          <select id='f-approval-mode'>
            <option value='none'>none (no gating)</option>
            <option value='interactive'>interactive (pause for a decision)</option>
            <option value='deny_risky'>deny_risky (auto-deny, no pause)</option>
          </select>
        </label>
        <label>Approval timeout (s) <input id='f-approval-timeout' type='number' min='1' value='300'></label>
        <label class='inline'><input type='checkbox' id='f-shell'> allow_shell</label>
        <label class='inline'><input type='checkbox' id='f-network'> allow_network</label>
        <button id='submit' class='wide' type='submit'>Create harness</button>
      </form>
    </section>
    <section class='panel'>
      <div class='panel-head'><h2>Harnesses</h2><span id='harness-count' class='state'>0</span></div>
      <div id='harness-list' class='panel-body row-list'><div class='empty'>No harnesses yet.</div></div>
    </section>
    <section class='panel'>
      <div class='panel-head'><h2>Tools</h2><span id='tool-count' class='state'>0</span></div>
      <div id='tool-list' class='panel-body row-list'></div>
    </section>
  </aside>
  <section class='detail'>
    <div id='no-selection' class='panel'><div class='empty'>Select or create a harness to inspect it.</div></div>
    <div id='harness-detail' hidden>
      <section id='approvals-panel' class='panel' hidden>
        <div class='panel-head'><h2>Pending approvals</h2><span id='approval-count' class='state pending'>0</span></div>
        <div id='approvals' class='panel-body approvals'></div>
      </section>
      <section class='panel'>
        <div class='panel-head'>
          <h2>Selected harness</h2>
          <div class='toolbar'>
            <button id='run-btn' type='button'>Run</button>
            <button id='reset-btn' class='secondary' type='button'>Reset</button>
            <button id='cancel-btn' class='secondary' type='button'>Cancel</button>
            <button id='delete-btn' class='danger' type='button'>Delete</button>
          </div>
        </div>
        <div class='panel-body'>
          <div id='harness-summary' class='summary'></div>
          <h3>Task</h3>
          <pre id='harness-task'></pre>
          <h3>Answer / error</h3>
          <pre id='harness-answer' class='answer'></pre>
        </div>
      </section>
      <section class='panel'>
        <div class='panel-head'><h2>Messages</h2><span id='message-count' class='state'>0</span></div>
        <div id='messages' class='panel-body events'></div>
      </section>
    </div>
  </section>
</main>
<footer>
  raw status/endpoint list: <a href='/coplex/endpoints'>/coplex/endpoints</a>
  - <a href='https://github.com/logicmoo/coplex'>coplex on GitHub</a>
</footer>

<div id='run-modal'>
  <div class='box'>
    <h2 style='margin-bottom:10px'>Run task</h2>
    <p id='run-modal-id' class='state' style='margin-bottom:8px'></p>
    <textarea id='run-task' rows='4' placeholder='Describe the task...'></textarea>
    <p style='margin-top:10px'>
      <button id='run-submit'>Run (async)</button>
      <button class='secondary' id='run-cancel'>Cancel</button>
    </p>
  </div>
</div>

<script>
const BASE = '/coplex';
let selectedId = null;
let polling = false;

const byId = (id) => document.getElementById(id);
const esc = (value) => String(value ?? '');
const jsonText = (value) => JSON.stringify(value ?? {}, null, 2);

async function api(path, options) {
  const res = await fetch(`${BASE}${path}`, {
    ...(options || {}),
    headers: {'Content-Type': 'application/json', ...((options || {}).headers || {})}
  });
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch (e) { body = null; }
  if (!res.ok) {
    const msg = (body && body.error) ? body.error : `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return body;
}

function showError(error) {
  byId('submit-state').textContent = error instanceof Error ? error.message : String(error);
  byId('submit-state').className = 'state error';
}

async function loadStatus() {
  try {
    const s = await api('/endpoints');
    byId('server-badge').textContent = `swipl ${s.swipl_version} - port ${s.server.port || '?'} - ${s.server.running ? 'running' : 'stopped'}`;
    byId('server-badge').className = `badge ${s.server.running ? 'ok' : 'warn'}`;
  } catch (error) {
    byId('server-badge').textContent = `unavailable: ${error.message}`;
    byId('server-badge').className = 'badge warn';
  }
}

async function loadTools() {
  const t = await api('/tools');
  const tools = t.tools || [];
  byId('tool-count').textContent = String(tools.length);
  byId('tool-list').innerHTML = tools.map((tool) => `
    <div class='row-btn'>
      <span>${esc(tool.name)}</span>
      <b class='state risk-${esc(tool.risk)}'>${esc(tool.risk)}</b>
      <small>${esc(tool.method)} ${esc(tool.endpoint)}</small>
    </div>`).join('');
}

function renderHarnessList(harnesses) {
  byId('harness-count').textContent = String(harnesses.length);
  const list = byId('harness-list');
  if (!harnesses.length) {
    list.innerHTML = `<div class='empty'>No harnesses yet.</div>`;
    return;
  }
  list.innerHTML = harnesses.map((h) => {
    const pending = h.pending_approval_count || 0;
    const state = pending ? 'pending' : (h.running ? 'running' : (h.last_error ? 'error' : 'idle'));
    const stateLabel = pending ? `${pending} pending` : state;
    return `
    <button class='row-btn ${h.id === selectedId ? 'active' : ''}' data-id='${esc(h.id)}' type='button'>
      <span>${esc(h.current_task) || '(no task yet)'}</span>
      <b class='state ${state}'>${esc(stateLabel)}</b>
      <small>${esc(h.id).slice(0, 8)} - msgs ${esc(h.message_count)} - ${new Date((h.created_at || 0) * 1000).toLocaleString()}</small>
    </button>`;
  }).join('');
  list.querySelectorAll('[data-id]').forEach((btn) => {
    btn.addEventListener('click', () => selectHarness(btn.dataset.id));
  });
}

async function loadHarnesses() {
  const h = await api('/harnesses');
  const harnesses = h.harnesses || [];
  if (!selectedId && harnesses.length) selectedId = harnesses[0].id;
  renderHarnessList(harnesses);
  return harnesses;
}

function renderMessages(messages) {
  byId('message-count').textContent = String(messages.length);
  byId('messages').innerHTML = messages.length ? messages.map((m, i) => {
    const content = (typeof m.content === 'string') ? m.content : jsonText(m.content);
    return `<div class='event'><b>#${i}</b><code>${esc(m.role)}</code><span>${esc(content)}</span></div>`;
  }).join('') : `<div class='empty'>No messages yet.</div>`;
}

function renderApprovals(id, pending) {
  const panel = byId('approvals-panel');
  byId('approval-count').textContent = String(pending.length);
  if (!pending.length) {
    panel.hidden = true;
    byId('approvals').innerHTML = '';
    return;
  }
  panel.hidden = false;
  byId('approvals').innerHTML = pending.map((p) => `
    <div class='approval-row' data-call-id='${esc(p.call_id)}'>
      <div class='head'>
        <b>${esc(p.tool)}</b>
        <span class='state risk-${esc(p.risk)}'>${esc(p.risk)}</span>
      </div>
      <pre>${esc(jsonText(p.arguments))}</pre>
      <small>requested ${new Date((p.requested_at || 0) * 1000).toLocaleString()} - call_id ${esc(p.call_id)}</small>
      <div class='actions'>
        <button class='btn-allow' type='button' data-decision='allow'>Allow</button>
        <button class='btn-deny' type='button' data-decision='deny'>Deny</button>
      </div>
    </div>`).join('');
  byId('approvals').querySelectorAll('[data-decision]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const row = btn.closest('[data-call-id]');
      void decideApproval(id, row.dataset.callId, btn.dataset.decision);
    });
  });
}

async function decideApproval(id, callId, decision) {
  try {
    await api(`/harnesses/${encodeURIComponent(id)}/approvals/${encodeURIComponent(callId)}`, {
      method: 'POST', body: JSON.stringify({decision})
    });
    await refreshAll();
  } catch (error) { showError(error); }
}

async function refreshSelected() {
  if (!selectedId) {
    byId('no-selection').hidden = false;
    byId('harness-detail').hidden = true;
    return;
  }
  let snap;
  try {
    snap = await api(`/harnesses/${encodeURIComponent(selectedId)}`);
  } catch (error) {
    selectedId = null;
    byId('no-selection').hidden = false;
    byId('harness-detail').hidden = true;
    return;
  }
  byId('no-selection').hidden = true;
  byId('harness-detail').hidden = false;
  const pending = snap.pending_approvals || [];
  const state = pending.length ? 'pending' : (snap.running ? 'running' : (snap.last_error ? 'error' : 'idle'));
  byId('harness-summary').innerHTML = [
    ['Status', pending.length ? `${pending.length} pending` : state], ['Iteration', snap.iteration], ['Messages', (snap.messages || []).length], ['Tools run', (snap.tool_activity || []).length]
  ].map(([label, value]) => `<div><b class='state ${state}'>${esc(value)}</b><span>${esc(label)}</span></div>`).join('');
  byId('harness-task').textContent = snap.current_task || '(no task submitted yet)';
  const answerEl = byId('harness-answer');
  if (snap.last_error) {
    answerEl.textContent = `ERROR: ${snap.last_error.message || jsonText(snap.last_error)}`;
    answerEl.className = 'answer error';
  } else {
    answerEl.textContent = snap.last_answer || 'No final answer yet.';
    answerEl.className = 'answer';
  }
  byId('cancel-btn').disabled = !snap.running;
  renderApprovals(selectedId, pending);
  renderMessages(snap.messages || []);
}

async function selectHarness(id) {
  selectedId = id;
  await Promise.all([loadHarnesses(), refreshSelected()]);
}

async function refreshAll() {
  if (polling) return;
  polling = true;
  try {
    await loadStatus();
    await loadHarnesses();
    await refreshSelected();
  } catch (error) {
    showError(error);
  } finally {
    polling = false;
  }
}

byId('create-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  byId('submit').disabled = true;
  byId('submit-state').textContent = 'creating...';
  byId('submit-state').className = 'state';
  try {
    const body = {
      root: byId('f-root').value || '.',
      adapter: byId('f-adapter').value,
      allow_shell: byId('f-shell').checked,
      allow_network: byId('f-network').checked,
      approval_mode: byId('f-approval-mode').value,
      approval_timeout: Number(byId('f-approval-timeout').value) || 300
    };
    const model = byId('f-model').value;
    if (model) body.model = model;
    const created = await api('/harnesses', {method: 'POST', body: JSON.stringify(body)});
    selectedId = created.id;
    const task = byId('f-task').value;
    if (task) {
      await api(`/harnesses/${encodeURIComponent(created.id)}/run`, {
        method: 'POST', body: JSON.stringify({task, async: true})
      });
    }
    byId('f-task').value = '';
    byId('submit-state').textContent = 'created';
    byId('submit-state').className = 'state idle';
    await refreshAll();
  } catch (error) {
    showError(error);
  } finally {
    byId('submit').disabled = false;
  }
});

byId('run-btn').addEventListener('click', () => {
  if (!selectedId) return;
  byId('run-modal-id').textContent = selectedId;
  byId('run-task').value = '';
  byId('run-modal').style.display = 'flex';
});
byId('run-cancel').addEventListener('click', () => { byId('run-modal').style.display = 'none'; });
byId('run-submit').addEventListener('click', async () => {
  const task = byId('run-task').value;
  const id = selectedId;
  byId('run-modal').style.display = 'none';
  try {
    await api(`/harnesses/${encodeURIComponent(id)}/run`, {
      method: 'POST', body: JSON.stringify({task, async: true})
    });
    await refreshAll();
  } catch (error) { showError(error); }
});

byId('cancel-btn').addEventListener('click', async () => {
  if (!selectedId) return;
  try {
    await api(`/harnesses/${encodeURIComponent(selectedId)}/cancel`, {method: 'POST', body: '{}'});
    await refreshAll();
  } catch (error) { showError(error); }
});
byId('reset-btn').addEventListener('click', async () => {
  if (!selectedId) return;
  try {
    await api(`/harnesses/${encodeURIComponent(selectedId)}/reset`, {method: 'POST', body: '{}'});
    await refreshAll();
  } catch (error) { showError(error); }
});
byId('delete-btn').addEventListener('click', async () => {
  if (!selectedId) return;
  if (!confirm(`Delete harness ${selectedId}?`)) return;
  try {
    await api(`/harnesses/${encodeURIComponent(selectedId)}`, {method: 'DELETE'});
    selectedId = null;
    await refreshAll();
  } catch (error) { showError(error); }
});
byId('refresh').addEventListener('click', refreshAll);

void loadTools();
void refreshAll();
window.setInterval(() => { if (!document.hidden) void refreshAll(); }, 2000);
</script>
</body>
</html>
".


%!  coplex_endpoints_handler(+Request) is det.
%
%   GET /coplex/endpoints (and bare `/endpoints`) -- the same status
%   document `python plugin.py status` prints on the host side:
%   identity, swipl version, server binding, path prefixes, and the
%   endpoint list. This used to live at `/coplex` itself; that path
%   now serves the admin UI instead (see admin_ui_handler/1) and this
%   JSON document moved here so a script/monitoring tool can still get
%   the same machine-readable status it always could.
coplex_endpoints_handler(Request) :-
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
    "GET    /coplex (admin UI, HTML)",
    "GET    /coplex/endpoints",
    "GET    /coplex/health",
    "GET    /coplex/tools",
    "POST   /coplex/tools/<name>",
    "GET    /coplex/harnesses",
    "POST   /coplex/harnesses",
    "GET    /coplex/harnesses/<id>",
    "DELETE /coplex/harnesses/<id>",
    "POST   /coplex/harnesses/<id>/run",
    "POST   /coplex/harnesses/<id>/cancel",
    "POST   /coplex/harnesses/<id>/reset",
    "GET    /coplex/harnesses/<id>/messages",
    "POST   /coplex/harnesses/<id>/tools/<name>",
    "POST   /coplex/harnesses/<id>/approvals/<call_id>",
    "POST   /coplex/shutdown"
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

%!  spec_dict(+Spec, -Dict) is det.
%
%   Each tool advertises a *real, working* `method` + `endpoint` --
%   `POST /coplex/tools/<name>` -- rather than leaving a UI to guess
%   one from the bare tool name (which would produce a URL that
%   matches no route at all). See direct_tool_item/1 for the handler
%   backing that endpoint.
spec_dict(spec(Name, Risk, Desc, Schema), Dict) :-
    format(atom(Endpoint), '/coplex/tools/~w', [Name]),
    Dict = _{name:Name, risk:Risk, description:Desc, schema:Schema,
             method:"POST", endpoint:Endpoint}.

%!  direct_tool_item(+Request) is det.
%
%   POST /coplex/tools/<name> (and its bare-root parity route) --
%   runs one named tool immediately, with no caller-managed harness
%   id at all. Backed by a single lazily-created, shared harness (see
%   ensure_default_harness/1) built from harness_new/2's plain
%   defaults, i.e. exactly what `POST /coplex/harnesses` with an empty
%   body would create: root ".", allow_shell/allow_network both false,
%   allowed_tools all, approval none (so nothing blocks waiting on an
%   external approval callback -- see codex_harness.pl's approve/6).
%   An unknown tool name isn't a routing 404; like the per-harness
%   route below, it comes back as an ordinary 200 reply with
%   `{"ok":false, "error":{"type":"unknown_tool", ...}}` (see
%   codex_harness.pl's known_or_dispatch/5).
direct_tool_item(Request) :-
    memberchk(method(Method), Request),
    ( Method == options
    ->  cors_enable(Request, [methods([post])]),
        format('~n')
    ;   cors_enable,
        memberchk(path(Path), Request),
        path_segments_after('/tools/', Path, Segments),
        dispatch_direct_tool(Segments, Method, Request)
    ).

dispatch_direct_tool([NameS], post, Request) :- NameS \== "", !,
    atom_string(Name, NameS),
    with_json_body(Request, Body,
        ( ensure_default_harness(Id),
          harness_tool(codex_harness(Id), Name, Body, Result),
          reply_json_dict(Result)
        )).
dispatch_direct_tool(_Segments, _Method, _Request) :-
    reply_error(404, error(existence_error(http_route, not_found), _)).

%!  ensure_default_harness(-Id) is det.
%
%   Get-or-create the singleton harness backing direct_tool_item/1.
%   Guarded by a mutex so two first-use requests racing each other
%   can't each create (and leak) their own default harness. Self-
%   healing: if the default harness is ever deleted via
%   `DELETE /coplex/harnesses/<id>`, the next direct call just creates
%   a fresh one.
:- dynamic default_harness_id/1.

ensure_default_harness(Id) :-
    with_mutex(coplex_default_harness, ensure_default_harness_(Id)).

ensure_default_harness_(Id) :-
    default_harness_id(Id),
    harness_known(Id),
    !.
ensure_default_harness_(Id) :-
    retractall(default_harness_id(_)),
    harness_new([], codex_harness(Id)),
    assertz(default_harness_id(Id)).

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
dispatch_item([IdS, "approvals", CallIdS], post, Request) :- !,
    atom_string(Id, IdS),
    with_existing_harness(Id,
        with_json_body(Request, Body,
            ( flex_decision(Body, Decision),
              harness_decide_approval(codex_harness(Id), CallIdS, Decision),
              reply_json_dict(_{ok:true})
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
error_status(error(existence_error(pending_approval, _), _), 404) :- !.
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

%!  flex_decision(+Body, -Decision) is det.
%   Decision is `allow` only when the request body explicitly says so
%   (`{"decision": "allow"}`, the shape a REST client sends, or the
%   bare atom/boolean equivalents for a Prolog-level caller); anything
%   else -- absent, `"deny"`, `false`, a typo, or any other JSON value
%   -- normalizes to `deny`. A fail-safe default: an ambiguous request
%   must never be misread as an approval.
flex_decision(Body, Decision) :-
    (   get_dict(decision, Body, V),
        ( V == "allow" ; V == allow ; V == true )
    ->  Decision = allow
    ;   Decision = deny
    ).

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
%   adapter_url/adapter_api_key are plain text (a URL, a bearer token)
%   consumed only by openai_chat_adapter/3's HTTP POST -- never
%   call/N'd -- so they're as safe to accept as root/instructions/
%   secrets; see sanitize_value/3 for how `adapter` itself stays a
%   closed, fixed set of atoms.
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
safe_option_key(adapter). safe_option_key(adapter_url).
safe_option_key(adapter_api_key).
safe_option_key(approval_mode). safe_option_key(approval_timeout).

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

%!  sanitize_value(+Key, +RawValue, -Value) is det.
%   `adapter` only ever normalizes to one of three fixed, built-in
%   atoms -- never an arbitrary value, let alone a callable term.
%   `openai` is a real, network-capable adapter (see
%   openai_chat_adapter/3), but it's still just a name from this
%   closed enumeration, not attacker-controlled code.
sanitize_value(adapter, V, Out) :-
    !,
    (   (V == "mock" ; V == mock)
    ->  Out = mock
    ;   (V == "openai" ; V == openai)
    ->  Out = openai
    ;   Out = scripted
    ).
%   allowed_hosts is compared against a URI-parsed host, which is
%   always an atom (library(uri)) -- but a JSON array can only ever
%   supply strings, so without this normalization every host in an
%   allowed_hosts sent over REST would silently fail to ever match
%   (atom \== string), making the option useless -- effectively
%   blocking every host -- for exactly the callers who need it, i.e.
%   anyone driving this over HTTP rather than embedding SWI-Prolog
%   directly. Affects both the network *tools* (http_fetch/4) and
%   openai_chat_adapter/3's validate_adapter_url/2.
sanitize_value(allowed_hosts, V, Out) :-
    !,
    (   is_list(V)
    ->  maplist(host_atom, V, Out)
    ;   Out = []
    ).
sanitize_value(_, V, V).

host_atom(H, A) :- atom_string(A, H).
