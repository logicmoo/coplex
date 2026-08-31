# coplex

SWI-Prolog Codex/Copilot-style coding-agent harness, packaged as a
standard SWI-Prolog pack (`pack.pl` + `prolog/`). One module,
`codex_harness`, exposes object terms `codex_harness(Id)` with
mutex-protected per-instance state.

> For the complete system design (architecture diagrams, the agent
> loop, the permission model, the REST/UI contract, plugin process
> management, and the test suites), see [`docs/`](docs/README.md).
> This README stays a quickstart/reference; `FEATURE_GUIDE.md` covers
> extension points and known pitfalls. New to how coding agents work
> at all? Start with [`docs/curriculum/`](docs/curriculum/README.md)
> instead -- a hands-on teaching track, no API key required.

## Layout

```
pack.pl                        SWI-Prolog pack metadata
prolog/
  coplex_server.pl              REST facade -- library(coplex_server)
  coplex_server_main.pl         runnable REST server entry point
  coplex/
    codex_harness.pl            core engine -- library(coplex/codex_harness)
test/                           plunit suites
examples/                       example scripts
docs/                           design documentation
plugin.py, plugin.json          symbolic_learner_workbench plugin glue
```

## Install

As a pack, straight from GitHub:

```prolog
?- pack_install('https://github.com/logicmoo/coplex').
?- use_module(library(coplex/codex_harness)).
```

Or clone/use in place without installing (as this repo itself does):

```prolog
?- [prolog/coplex/codex_harness].
```

## Load

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new([root('.'), adapter(scripted),
                mock_replies([_{content:"hello", tool_calls:[]}])], H).
?- harness_run(H, "Say hello", Answer).
?- harness_close(H).
```

## Public API

| Predicate | Role |
| --- | --- |
| `harness_new(+Options, -Harness)` | Create instance |
| `harness_close(+Harness)` | Destroy instance |
| `harness_run(+H, +Task, -Answer)` | Run the tool loop |
| `harness_run(+H, +Task, +Opts, -Answer)` | Same, extra run options |
| `harness_cancel(+H)` | Cooperative cancel |
| `harness_reset(+H)` | Clear conversation, keep config |
| `harness_messages(+H, -Msgs)` | Persisted conversation |
| `harness_snapshot(+H, -Dict)` | Status for a future UI |
| `harness_tool(+H, +Name, +Args, -Result)` | Invoke one tool |
| `harness_tool_specs(-Specs)` | Built-in tool catalog |

## Adapter contract

Option `adapter(Adapter)` is invoked as:

```prolog
call(Adapter, RequestDict, ReplyDict)
```

Request:

```
_{ model, instructions, messages, tools, options }
```

Reply:

```
_{ content:"...", tool_calls:[ _{id, name, arguments} ] }
```

Empty `tool_calls` is the final answer.

Built-in `adapter(scripted)` / `adapter(mock)` consume `mock_replies/1`.
`adapter(openai)` is a complete adapter for OpenAI-compatible Chat
Completions APIs (OpenAI, Azure OpenAI, or a self-hosted server
speaking the same wire format -- vLLM, Ollama's `/v1` shim, LM
Studio, ...); point it at a real endpoint with `adapter_url` and
`adapter_api_key` (sent as `Authorization: Bearer <key>`), and set
`allow_network(true)` -- reaching a real hosted LLM is real network
egress, gated the same way `web_search`/`web_get`/`download` already
are. `http_json_adapter(Url)` remains a documented skeleton for an
endpoint that already speaks this harness's own `{content,
tool_calls}` wire format directly; anything else needs a small
translation adapter of its own (see `FEATURE_GUIDE.md` §1 and
`docs/curriculum/09-connecting-a-real-model.md`). Do not persist
secrets for a *custom* adapter in harness state -- pass them as
closure arguments instead (`adapter(openai)` is the one built-in
exception, and only because it must be reachable from JSON-only REST
callers with no way to pass a closure; see `FEATURE_GUIDE.md` §1 for
how the key still never leaks back out).

## Options

`root`, `cwd`, `model`, `instructions`, `extra_instructions`,
`allow_shell` (default false), `allow_network` (default false),
`allow_shell_string` (default false; unused unless you add a string
shell later), `allowed_hosts`, `writable_paths`, `readable_paths`,
`max_output_bytes`, `max_download_bytes`, `timeout`, `command_timeout`,
`max_steps`, `subagent_limit`, `subagent_allow_writes` (default false),
`approval(Goal)` where `call(Goal, Tool, Args, allow|deny(Reason))`,
`on_event(Goal)`, `transcript(Path)`, `secrets([...])`,
`default_test_command([Cmd|Args])`, `web_search_backend(Goal)`,
`mock_replies([...])`, `allowed_tools(all|[...])`, `adapter_url`
(default the public OpenAI endpoint; only consulted by
`adapter(openai)`), `adapter_api_key` (default `""`; ditto).

## Tools

`read_file`, `write_file`, `list_files`, `search` (rg or fallback),
`apply_patch` (unified diff, all-or-nothing write), `file_info`,
`make_directory`, `shell` (explicit argv via `process_create/3`, no
`/bin/sh -c` by default), `run_tests` (auto-detects/uses
`default_test_command`; an explicit `command`/`args` override is only
honored when `allow_shell(true)`, otherwise it's ignored so `run_tests`
can't be used to bypass the shell permission gate), read-only
`git_status`, `git_diff`, `git_log`, `git_show`, `web_search`,
`web_get`, `download`, `subagents`.

Network is off by default. HTTP(S) only, host allowlist, loopback and
RFC1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) plus
link-local (`169.254.0.0/16`, IPv6 `fe80::/10`) and IPv6 unique-local
(`fc00::/7`) blocked. Downloads stay under the repo and size limit.

## Subagents

`subagents` runs independent tasks concurrently with a worker pool.
Safe default: analysis-only children (`read_file`, `list_files`,
`search`, `file_info`, git read). Set `subagent_allow_writes(true)`
only if you accept concurrent writes. Isolated child harness state;
no Git worktree required.

## REST API

`prolog/coplex_server.pl` exposes the harness over JSON/HTTP so a host
process -- e.g. the workbench -- can create, drive, observe, and tear
down harness instances without embedding SWI-Prolog. It is a plain
library (loading it never starts a server); `prolog/coplex_server_main.pl`
is the runnable entry point:

```
swipl prolog/coplex_server_main.pl --port=8840 --host=localhost
```

`plugin.py` manages this as a background subprocess through the plugin
lifecycle hooks (`workbenchStartup`/`workbenchShutdown`) and exposes
it through the plugin-api (`status`/`config`/`restart`/`shutdown`); see
`plugin.json`. Manual equivalent: `python plugin.py start|stop|status|restart`.

Endpoints (JSON in, JSON out, except `/coplex` itself which is HTML).
Every path below is shown in its canonical, documented `/coplex`-
prefixed form; each also answers unprefixed at the bare root purely so
the workbench's stripped-prefix proxy mount can reach it (see
"REST API" in `docs/04-rest-api.md` for the mechanics):

| Method | Path                                 | Behavior                            |
|--------|--------------------------------------|--------------------------------------|
| GET    | `/coplex`                            | Self-contained HTML admin dashboard (browse tools, create/run/inspect/delete harnesses). |
| GET    | `/coplex/endpoints`                  | Status/endpoint-list JSON (used to live at `/coplex` itself -- see below). |
| GET    | `/coplex/health`                     | Liveness check.                              |
| GET    | `/coplex/tools`                      | `harness_tool_specs/1`, each entry annotated with a real `method`/`endpoint` (below). |
| POST   | `/coplex/tools/<name>`               | `harness_tool/4` against a shared, lazily-created harness; body is the tool's Arguments. No harness id needed. |
| GET    | `/coplex/harnesses`                  | `harness_list/1` ids, plus a `harnesses` array of `harness_summary/2` status dicts (see below). |
| POST   | `/coplex/harnesses`                  | `harness_new/2` (safe option subset below).  |
| GET    | `/coplex/harnesses/<id>`             | `harness_snapshot/2`.                        |
| DELETE | `/coplex/harnesses/<id>`             | `harness_close/1`.                           |
| POST   | `/coplex/harnesses/<id>/run`         | `harness_run/4`; body `{task, context?, async?}`. |
| POST   | `/coplex/harnesses/<id>/cancel`      | `harness_cancel/1`.                          |
| POST   | `/coplex/harnesses/<id>/reset`       | `harness_reset/1`.                           |
| GET    | `/coplex/harnesses/<id>/messages`    | `harness_messages/2`.                        |
| POST   | `/coplex/harnesses/<id>/tools/<name>`| `harness_tool/4`; body is the tool's Arguments.|
| POST   | `/coplex/shutdown`                   | Graceful self-terminate (replies, then halts).|

Unknown/nonexistent harness ids return HTTP 404; a `run` request against
a harness that's already running returns HTTP 409; internal errors
return HTTP 500 with `{"ok": false, "error": "..."}`.

### Admin UI

`GET /coplex` (also bare `GET /`) serves a small, self-contained HTML
dashboard -- no external CSS/JS, no build step, no CDN dependency --
for driving this REST API by hand: browse the tool catalog, create a
harness (root/adapter/model/allow_shell/allow_network), run/cancel/
reset it, inspect its message transcript, and delete it. Everything it
does is a plain `fetch()` against the JSON endpoints in the table
above through absolute `/coplex/...` paths, so it works identically
whether you load it directly (`http://localhost:8840/coplex`) or
through the workbench's proxy mount. It carries no authentication of
its own -- same security model as the rest of this API (see below).

The JSON status/endpoint-list document that used to live at `GET
/coplex` itself moved to `GET /coplex/endpoints` (and bare
`/endpoints`), so a script or monitoring tool that used to poll
`/coplex` for that JSON should point at `/coplex/endpoints` instead.

### Calling a tool directly

`GET /coplex/tools` used to only return `name`/`risk`/`description`/
`schema`, leaving a UI to guess a URL for "running" a tool -- which
produced broken, non-routable URLs like `http://host:port/read_file`.
Each entry now also carries the endpoint that actually works:

```json
{"name": "read_file", "risk": "read_only",
 "description": "Read a UTF-8 file under the repository root.",
 "schema": {"path": "string"},
 "method": "POST", "endpoint": "/coplex/tools/read_file"}
```

`POST /coplex/tools/<name>` runs that tool immediately against a
single shared harness that's created lazily on first use with the
same defaults as `POST /coplex/harnesses` with an empty body
(`root: "."`, `allow_shell`/`allow_network` both `false`,
`approval: none`). It's for callers that just want to run one tool
without first creating and tearing down a harness; an unknown tool
name still comes back as a normal `200` with
`{"ok": false, "error": {"type": "unknown_tool", ...}}`, matching
`POST /coplex/harnesses/<id>/tools/<name>`'s behavior.


### Building a UI around this API

`POST /coplex/harnesses/<id>/run` blocks until the agent loop finishes
by default -- fine for scripts, awkward for a web UI that wants to
render progress. Pass `{"async": true}` in the body instead:

```
POST /coplex/harnesses/<id>/run  {"task": "...", "async": true}
-> {"ok": true, "id": "...", "started": true, "async": true}
```

The run then continues in a background thread; poll `GET
/coplex/harnesses/<id>` (or the lighter list below) until `running`
flips back to `false`, then read `last_answer`/`last_error`. A second
`run` while one is already in flight is rejected with HTTP 409 instead
of corrupting shared state, so a UI's "run" button can safely no-op on
a double click.

`GET /coplex/harnesses` returns both the original `ids` array and a
`harnesses` array of `harness_summary/2` dicts -- `id`, `current_task`,
`iteration`, `running`, `cancelled`, `last_answer`, `last_error`,
`message_count`, `tool_call_count`, `created_at` -- so a dashboard can
render a table of every live harness with one request instead of one
per row. `GET /coplex/harnesses/<id>` still returns the full
`harness_snapshot/2` (same fields plus the complete `messages` and
`tool_activity` history) for a detail view.

CORS (`Access-Control-Allow-Origin`) is enabled by default for any
origin, including the `OPTIONS` preflight every browser sends before a
cross-origin `POST`/`DELETE`, so a UI served from a different origin
(e.g. a Vite/webpack dev server) can call this API directly with no
proxy. Set `COPLEX_CORS_ORIGIN` to a comma-separated list of
allowed origins, or to `""` to disable CORS entirely, for anything
beyond local development.

**Security model.** The server binds to `localhost` by default. Request
bodies are never parsed as Prolog source and never used to build a
callable term:

- `POST /coplex/harnesses` only honors a fixed allowlist of scalar/
  text/list `harness_new/2` options (`root`, `cwd`, `model`,
  `instructions`, `allow_shell`, `allow_network`, `allowed_hosts`,
  `writable_paths`, `readable_paths`, `timeout`, `max_steps`,
  `transcript`, `mock_replies`, `allowed_tools`, `adapter_url`,
  `adapter_api_key`, ... -- see `config()` in `plugin.py` for the
  full, current list). `adapter` is normalized to one of three fixed
  atoms -- `scripted`, `mock`, or `openai` -- any other value falls
  back to `scripted`. `adapter_api_key` is plain text, never a
  callable, but it is real network-facing configuration: see the
  Adapter contract section above for how the key is redacted/never
  echoed back despite living in harness state.
- `approval`, `on_event`, `parent`, and `web_search_backend` are
  **never** settable over REST, because `codex_harness.pl` eventually
  `call/N`'s each of them -- accepting them from untrusted JSON would
  be a remote-code-execution vector. Set them only via a direct,
  in-process `harness_new/2` call.
- Tool names on `POST /coplex/harnesses/<id>/tools/<name>` (and the
  harness-less `POST /coplex/tools/<name>`) are only ever unified
  against `dispatch_tool/5`'s fixed clause table (see
  `codex_harness.pl`), so an unknown/attacker-chosen name can never
  resolve to an arbitrary predicate.
- CORS defaults to `*` (any origin), which is safe *only* because the
  server binds to `localhost` by default; tighten
  `COPLEX_CORS_ORIGIN` if that default host binding is ever
  changed.

Tests: `swipl -g run_tests -t halt test/test_codex_harness_server.pl` (spins
up a real server on an ephemeral localhost port and drives it with
`library(http/http_open)`).

## Tests

```
swipl -g run_tests -t halt test/test_codex_harness.pl
swipl -g run_tests -t halt test/test_codex_harness_server.pl
```

Example: `swipl -s examples/example_codex_harness.pl -t halt`.

## Limitations

- `http_json_adapter/3` remains a skeleton for a bespoke endpoint that
  already speaks this harness's own wire format; a provider that
  speaks neither that nor `adapter(openai)`'s OpenAI-compatible shape
  (e.g. Anthropic's messages API) still needs its own small
  translation adapter (see `FEATURE_GUIDE.md` §1).
- Unified-diff parser handles standard `---`/`+++`/`@@` hunks, not git
  binary patches or rename headers.
- `web_search` requires an injected `web_search_backend/2` goal.
- No bundled UI: the REST API above (async run, list summaries, CORS)
  is designed to be driven by a separately-built web UI, not to ship
  one itself.

## Packaging

- **SWI-Prolog pack**: `pack.pl` at the repo root plus the required
  `prolog/` directory make this installable via `pack_install/1` (see
  Install above).
- **Python**: `pyproject.toml` packages `plugin.py` (the
  `symbolic_learner_workbench` process-manager glue, see
  `plugin.json`) as the `coplex` PyPI distribution, without moving it
  out of the repo root.

## License

LGPL-3.0-or-later -- see `LICENSE` (the LGPL addendum) and `COPYING`
(the GPLv3 text it incorporates by reference).
