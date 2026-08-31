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
  * Tool names arriving on the URL (`POST /harnesses/<Id>/tools/<Name>`
    or the harness-less `POST /tools/<Name>`) are only ever unified
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
  * `GET /tools` advertises a real, working `method` + `endpoint` for
    every tool (`POST /coplex/tools/<name>`) backed by a shared,
    lazily-created harness, for callers that just want to run one tool
    without first managing a harness's lifecycle.

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
%   `/coplex` (and bare `/`) now serve the admin UI (see
%   admin_ui_handler/1); the JSON status/endpoint-list document that
%   used to live at `/coplex` moved to `/coplex/endpoints` (and bare
%   `/endpoints`) -- see coplex_endpoints_handler/1.
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
    Html = "<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<title>coplex admin</title>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<style>
  :root {
    --bg: #0f1115; --panel: #171a21; --border: #2a2f3a; --text: #e6e8eb;
    --muted: #9aa3b2; --accent: #4da3ff; --good: #3ecf8e; --bad: #ff6b6b;
    --warn: #f5b043;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 14px/1.45 -apple-system, Segoe UI, Roboto, sans-serif;
  }
  header {
    display: flex; align-items: center; gap: 12px;
    padding: 14px 20px; border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .tag {
    font-size: 11px; color: var(--muted); border: 1px solid var(--border);
    border-radius: 4px; padding: 2px 6px;
  }
  #status { margin-left: auto; font-size: 12px; color: var(--muted); }
  main { padding: 20px; max-width: 1100px; margin: 0 auto; }
  section { margin-bottom: 28px; }
  h2 {
    font-size: 13px; text-transform: uppercase; letter-spacing: .04em;
    color: var(--muted); margin: 0 0 10px;
  }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td {
    text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--border);
    vertical-align: top;
  }
  th { color: var(--muted); font-weight: 600; font-size: 12px; }
  tr:hover td { background: rgba(255,255,255,0.02); }
  .panel {
    background: var(--panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 14px 16px;
  }
  .badge {
    display: inline-block; padding: 1px 7px; border-radius: 10px; font-size: 11px;
    border: 1px solid var(--border); color: var(--muted);
  }
  .badge-running { color: var(--good); border-color: var(--good); }
  .badge-idle { color: var(--muted); }
  .badge-error { color: var(--bad); border-color: var(--bad); }
  .risk-read_only { color: var(--muted); }
  .risk-write { color: var(--warn); border-color: var(--warn); }
  .risk-process, .risk-network { color: var(--bad); border-color: var(--bad); }
  code { font-family: ui-monospace, Consolas, monospace; font-size: 12px; }
  button {
    background: var(--accent); color: #08131f; border: none; border-radius: 5px;
    padding: 4px 10px; font-size: 12px; cursor: pointer; font-weight: 600;
    margin-right: 4px;
  }
  button:hover { filter: brightness(1.1); }
  button.secondary { background: transparent; color: var(--text); border: 1px solid var(--border); }
  button.danger { background: var(--bad); color: #2a0808; }
  button:disabled { opacity: .4; cursor: default; }
  input[type=text], select, textarea {
    background: #0c0e12; border: 1px solid var(--border); color: var(--text);
    border-radius: 5px; padding: 5px 8px; font-size: 13px; font-family: inherit;
  }
  form.create-form { display: flex; flex-wrap: wrap; gap: 10px; align-items: end; }
  form.create-form label {
    display: flex; flex-direction: column; gap: 3px; font-size: 11px; color: var(--muted);
  }
  label.inline { flex-direction: row !important; align-items: center; gap: 5px !important; }
  .muted { color: var(--muted); }
  .empty { color: var(--muted); font-style: italic; padding: 10px 0; }
  #run-modal, #msg-modal {
    display: none; position: fixed; inset: 0; background: rgba(0,0,0,.6);
    align-items: center; justify-content: center; z-index: 10;
  }
  #run-modal .box, #msg-modal .box {
    background: var(--panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 18px; width: 560px; max-width: 92vw; max-height: 80vh; overflow: auto;
  }
  #msg-modal .box { width: 720px; }
  .msg-entry { border-bottom: 1px dashed var(--border); padding: 8px 0; }
  .msg-role { font-weight: 600; text-transform: uppercase; font-size: 11px; color: var(--accent); }
  pre.msg-content {
    white-space: pre-wrap; word-break: break-word; margin: 4px 0 0; font-size: 12px;
    color: var(--text);
  }
  footer { text-align: center; color: var(--muted); font-size: 12px; padding: 20px; }
  footer a { color: var(--accent); }
</style>
</head>
<body>
<header>
  <h1>coplex</h1>
  <span class='tag'>admin</span>
  <span id='status'>loading…</span>
</header>
<main>

  <section>
    <h2>Create harness</h2>
    <form class='create-form panel' id='create-form'>
      <label>root <input type='text' id='f-root' value='.' size='18'></label>
      <label>adapter
        <select id='f-adapter'>
          <option value='scripted'>scripted</option>
          <option value='mock'>mock</option>
          <option value='openai'>openai</option>
        </select>
      </label>
      <label>model <input type='text' id='f-model' placeholder='default' size='14'></label>
      <label class='inline'><input type='checkbox' id='f-shell'> allow_shell</label>
      <label class='inline'><input type='checkbox' id='f-network'> allow_network</label>
      <button type='submit'>Create</button>
    </form>
  </section>

  <section>
    <h2>Harnesses <span class='muted' id='harness-count'></span></h2>
    <div class='panel'>
      <table>
        <thead><tr>
          <th>id</th><th>task</th><th>state</th><th>step</th><th>msgs/tools</th>
          <th>last answer / error</th><th>created</th><th>actions</th>
        </tr></thead>
        <tbody id='harnesses-body'></tbody>
      </table>
      <div class='empty' id='harnesses-empty' style='display:none'>No harnesses yet — create one above.</div>
    </div>
  </section>

  <section>
    <h2>Tools</h2>
    <div class='panel'>
      <table>
        <thead><tr><th>name</th><th>risk</th><th>endpoint</th><th>description</th></tr></thead>
        <tbody id='tools-body'></tbody>
      </table>
    </div>
  </section>

</main>
<footer>
  raw status/endpoint list: <a href='/coplex/endpoints'>/coplex/endpoints</a>
  · <a href='https://github.com/logicmoo/coplex'>coplex on GitHub</a>
</footer>

<div id='run-modal'>
  <div class='box'>
    <h2 style='margin-top:0'>Run task</h2>
    <p class='muted' id='run-modal-id'></p>
    <textarea id='run-task' rows='4' style='width:100%' placeholder='Describe the task…'></textarea>
    <p>
      <button id='run-submit'>Run (async)</button>
      <button class='secondary' id='run-cancel'>Cancel</button>
    </p>
  </div>
</div>

<div id='msg-modal'>
  <div class='box'>
    <h2 style='margin-top:0'>Messages</h2>
    <p class='muted' id='msg-modal-id'></p>
    <div id='msg-list'></div>
    <p><button class='secondary' id='msg-close'>Close</button></p>
  </div>
</div>

<script>
var BASE = '/coplex';
var runTargetId = null;

function jfetch(path, opts) {
  return fetch(BASE + path, opts).then(function (res) {
    return res.text().then(function (text) {
      var body = null;
      try { body = text ? JSON.parse(text) : null; } catch (e) { body = null; }
      if (!res.ok) {
        var msg = (body && body.error) ? body.error : ('HTTP ' + res.status);
        throw new Error(msg);
      }
      return body;
    });
  });
}

function el(tag, attrs, children) {
  var e = document.createElement(tag);
  attrs = attrs || {};
  for (var k in attrs) {
    if (k === 'text') e.textContent = attrs[k];
    else if (k === 'title') e.title = attrs[k];
    else if (k === 'class') e.className = attrs[k];
    else if (k.indexOf('on') === 0 && typeof attrs[k] === 'function') e[k] = attrs[k];
    else e.setAttribute(k, attrs[k]);
  }
  (children || []).forEach(function (c) { e.appendChild(c); });
  return e;
}

function truncate(s, n) {
  s = s || '';
  return s.length > n ? s.slice(0, n) + '…' : s;
}

function fmtTime(ts) {
  if (!ts) return '';
  return new Date(ts * 1000).toLocaleString();
}

function button(label, cls, fn) {
  return el('button', {class: cls || 'secondary', text: label, onclick: fn});
}

function loadStatus() {
  jfetch('/endpoints').then(function (s) {
    var elx = document.getElementById('status');
    elx.textContent = 'swipl ' + s.swipl_version + ' · port ' + (s.server.port || '?') +
      ' · ' + (s.server.running ? 'running' : 'stopped');
  }).catch(function (e) {
    document.getElementById('status').textContent = 'status unavailable: ' + e.message;
  });
}

function loadTools() {
  jfetch('/tools').then(function (t) {
    var tbody = document.getElementById('tools-body');
    tbody.innerHTML = '';
    (t.tools || []).forEach(function (tool) {
      tbody.appendChild(el('tr', null, [
        el('td', null, [el('code', {text: tool.name})]),
        el('td', null, [el('span', {class: 'badge risk-' + tool.risk, text: tool.risk})]),
        el('td', null, [el('code', {text: tool.method + ' ' + tool.endpoint})]),
        el('td', {text: tool.description})
      ]));
    });
  }).catch(function () {});
}

function openRunModal(id) {
  runTargetId = id;
  document.getElementById('run-modal-id').textContent = id;
  document.getElementById('run-task').value = '';
  document.getElementById('run-modal').style.display = 'flex';
}

function closeRunModal() {
  document.getElementById('run-modal').style.display = 'none';
  runTargetId = null;
}

function openMsgModal(id) {
  document.getElementById('msg-modal-id').textContent = id;
  var list = document.getElementById('msg-list');
  list.innerHTML = '';
  list.appendChild(el('p', {class: 'muted', text: 'loading…'}));
  document.getElementById('msg-modal').style.display = 'flex';
  jfetch('/harnesses/' + id + '/messages').then(function (r) {
    list.innerHTML = '';
    if (!r.messages || !r.messages.length) {
      list.appendChild(el('p', {class: 'muted', text: 'No messages yet.'}));
      return;
    }
    r.messages.forEach(function (m) {
      var content = (typeof m.content === 'string') ? m.content : JSON.stringify(m.content, null, 2);
      list.appendChild(el('div', {class: 'msg-entry'}, [
        el('div', {class: 'msg-role', text: m.role}),
        el('pre', {class: 'msg-content', text: content})
      ]));
    });
  }).catch(function (e) {
    list.innerHTML = '';
    list.appendChild(el('p', {class: 'muted', text: 'Failed to load: ' + e.message}));
  });
}

function closeMsgModal() {
  document.getElementById('msg-modal').style.display = 'none';
}

function harnessAction(id, action) {
  return jfetch('/harnesses/' + id + '/' + action, {method: 'POST',
    headers: {'Content-Type': 'application/json'}, body: '{}'})
    .then(loadHarnesses).catch(function (e) { alert(action + ' failed: ' + e.message); });
}

function deleteHarness(id) {
  if (!confirm('Delete harness ' + id + '?')) return;
  jfetch('/harnesses/' + id, {method: 'DELETE'})
    .then(loadHarnesses).catch(function (e) { alert('delete failed: ' + e.message); });
}

function loadHarnesses() {
  return jfetch('/harnesses').then(function (h) {
    var tbody = document.getElementById('harnesses-body');
    var empty = document.getElementById('harnesses-empty');
    tbody.innerHTML = '';
    var list = h.harnesses || [];
    document.getElementById('harness-count').textContent = list.length ? ('(' + list.length + ')') : '';
    empty.style.display = list.length ? 'none' : 'block';
    list.forEach(function (hh) {
      var stateCls = hh.running ? 'badge-running' : (hh.last_error ? 'badge-error' : 'badge-idle');
      var stateText = hh.running ? 'running' : (hh.last_error ? 'error' : 'idle');
      var lastText = hh.last_error ? ('error: ' + (hh.last_error.message || hh.last_error))
                                    : (hh.last_answer || '');
      var actions = el('td');
      actions.appendChild(button('Run', null, function () { openRunModal(hh.id); }));
      actions.appendChild(button('Cancel', null, function () { harnessAction(hh.id, 'cancel'); }));
      actions.appendChild(button('Reset', null, function () { harnessAction(hh.id, 'reset'); }));
      actions.appendChild(button('Msgs', null, function () { openMsgModal(hh.id); }));
      actions.appendChild(button('Delete', 'danger', function () { deleteHarness(hh.id); }));
      tbody.appendChild(el('tr', null, [
        el('td', null, [el('code', {text: hh.id.slice(0, 8), title: hh.id})]),
        el('td', {text: truncate(hh.current_task, 40)}),
        el('td', null, [el('span', {class: 'badge ' + stateCls, text: stateText})]),
        el('td', {text: hh.iteration}),
        el('td', {text: hh.message_count + ' / ' + hh.tool_call_count}),
        el('td', {text: truncate(lastText, 60)}),
        el('td', {text: fmtTime(hh.created_at)}),
        actions
      ]));
    });
  }).catch(function () {});
}

document.getElementById('create-form').addEventListener('submit', function (ev) {
  ev.preventDefault();
  var body = {
    root: document.getElementById('f-root').value || '.',
    adapter: document.getElementById('f-adapter').value,
    allow_shell: document.getElementById('f-shell').checked,
    allow_network: document.getElementById('f-network').checked
  };
  var model = document.getElementById('f-model').value;
  if (model) body.model = model;
  jfetch('/harnesses', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body)})
    .then(loadHarnesses)
    .catch(function (e) { alert('create failed: ' + e.message); });
});

document.getElementById('run-submit').addEventListener('click', function () {
  var task = document.getElementById('run-task').value;
  var id = runTargetId;
  closeRunModal();
  jfetch('/harnesses/' + id + '/run', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({task: task, async: true})})
    .then(loadHarnesses)
    .catch(function (e) { alert('run failed: ' + e.message); });
});
document.getElementById('run-cancel').addEventListener('click', closeRunModal);
document.getElementById('msg-close').addEventListener('click', closeMsgModal);

loadStatus();
loadTools();
loadHarnesses();
setInterval(loadStatus, 5000);
setInterval(loadHarnesses, 3000);
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
    "GET    /health",
    "GET    /tools",
    "POST   /tools/<name>",
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
%   POST /tools/<name> (and its /coplex-prefixed parity route) --
%   runs one named tool immediately, with no caller-managed harness
%   id at all. Backed by a single lazily-created, shared harness (see
%   ensure_default_harness/1) built from harness_new/2's plain
%   defaults, i.e. exactly what `POST /harnesses` with an empty body
%   would create: root ".", allow_shell/allow_network both false,
%   allowed_tools all, approval none (so nothing blocks waiting on an
%   external approval callback -- see codex_harness.pl's approve/4).
%   An unknown tool name isn't a routing 404; like the per-harness
%   route below, it comes back as an ordinary 200 reply with
%   `{"ok":false, "error":{"type":"unknown_tool", ...}}` (see
%   codex_harness.pl's known_or_dispatch/4).
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
%   `DELETE /harnesses/<id>`, the next direct call just creates a
%   fresh one.
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
