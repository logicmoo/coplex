# task_harness_pl

SWI-Prolog Codex/Copilot-style coding-agent harness. One module,
`codex_harness`, exposes object terms `codex_harness(Id)` with
mutex-protected per-instance state.

> For the complete system design (architecture diagrams, the agent
> loop, the permission model, the REST/UI contract, plugin process
> management, and the test suites), see [`docs/`](docs/README.md).
> This README stays a quickstart/reference; `FEATURE_GUIDE.md` covers
> extension points and known pitfalls.

## Load

```prolog
?- [codex_harness].
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
`http_json_adapter(Url)` is a documented skeleton: POST the request JSON,
expect the reply JSON. Do not persist secrets in harness state.

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
`mock_replies([...])`, `allowed_tools(all|[...])`.

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

`codex_harness_server.pl` exposes the harness over JSON/HTTP so a host
process -- e.g. the workbench -- can create, drive, observe, and tear
down harness instances without embedding SWI-Prolog. It is a plain
library (loading it never starts a server); `codex_harness_server_main.pl`
is the runnable entry point:

```
swipl codex_harness_server_main.pl --port=8840 --host=localhost
```

`plugin.py` manages this as a background subprocess through the plugin
lifecycle hooks (`workbenchStartup`/`workbenchShutdown`) and exposes
it through the plugin-api (`status`/`config`/`restart`/`shutdown`); see
`plugin.json`. Manual equivalent: `python plugin.py start|stop|status|restart`.

Endpoints (JSON in, JSON out):

| Method | Path                          | Behavior                                   |
|--------|-------------------------------|---------------------------------------------|
| GET    | `/health`                     | Liveness check.                              |
| GET    | `/tools`                      | `harness_tool_specs/1`.                      |
| GET    | `/harnesses`                  | `harness_list/1` ids, plus a `harnesses` array of `harness_summary/2` status dicts (see below). |
| POST   | `/harnesses`                  | `harness_new/2` (safe option subset below).  |
| GET    | `/harnesses/<id>`             | `harness_snapshot/2`.                        |
| DELETE | `/harnesses/<id>`             | `harness_close/1`.                           |
| POST   | `/harnesses/<id>/run`         | `harness_run/4`; body `{task, context?, async?}`. |
| POST   | `/harnesses/<id>/cancel`      | `harness_cancel/1`.                          |
| POST   | `/harnesses/<id>/reset`       | `harness_reset/1`.                           |
| GET    | `/harnesses/<id>/messages`    | `harness_messages/2`.                        |
| POST   | `/harnesses/<id>/tools/<name>`| `harness_tool/4`; body is the tool's Arguments.|
| POST   | `/shutdown`                   | Graceful self-terminate (replies, then halts).|

Unknown/nonexistent harness ids return HTTP 404; a `run` request against
a harness that's already running returns HTTP 409; internal errors
return HTTP 500 with `{"ok": false, "error": "..."}`.

### Building a UI around this API

`POST /harnesses/<id>/run` blocks until the agent loop finishes by
default -- fine for scripts, awkward for a web UI that wants to render
progress. Pass `{"async": true}` in the body instead:

```
POST /harnesses/<id>/run  {"task": "...", "async": true}
-> {"ok": true, "id": "...", "started": true, "async": true}
```

The run then continues in a background thread; poll `GET
/harnesses/<id>` (or the lighter list below) until `running` flips back
to `false`, then read `last_answer`/`last_error`. A second `run` while
one is already in flight is rejected with HTTP 409 instead of
corrupting shared state, so a UI's "run" button can safely no-op on a
double click.

`GET /harnesses` returns both the original `ids` array and a
`harnesses` array of `harness_summary/2` dicts -- `id`, `current_task`,
`iteration`, `running`, `cancelled`, `last_answer`, `last_error`,
`message_count`, `tool_call_count`, `created_at` -- so a dashboard can
render a table of every live harness with one request instead of one
per row. `GET /harnesses/<id>` still returns the full
`harness_snapshot/2` (same fields plus the complete `messages` and
`tool_activity` history) for a detail view.

CORS (`Access-Control-Allow-Origin`) is enabled by default for any
origin, including the `OPTIONS` preflight every browser sends before a
cross-origin `POST`/`DELETE`, so a UI served from a different origin
(e.g. a Vite/webpack dev server) can call this API directly with no
proxy. Set `TASK_HARNESS_CORS_ORIGIN` to a comma-separated list of
allowed origins, or to `""` to disable CORS entirely, for anything
beyond local development.

**Security model.** The server binds to `localhost` by default. Request
bodies are never parsed as Prolog source and never used to build a
callable term:

- `POST /harnesses` only honors a fixed allowlist of scalar/text/list
  `harness_new/2` options (`root`, `cwd`, `model`, `instructions`,
  `allow_shell`, `allow_network`, `allowed_hosts`, `writable_paths`,
  `readable_paths`, `timeout`, `max_steps`, `transcript`,
  `mock_replies`, `allowed_tools`, ... -- see `config()` in `plugin.py`
  for the full, current list). `adapter` is normalized to the atom
  `scripted` or `mock` only; any other value falls back to `scripted`.
- `approval`, `on_event`, `parent`, and `web_search_backend` are
  **never** settable over REST, because `codex_harness.pl` eventually
  `call/N`'s each of them -- accepting them from untrusted JSON would
  be a remote-code-execution vector. Set them only via a direct,
  in-process `harness_new/2` call.
- Tool names on `POST /harnesses/<id>/tools/<name>` are only ever
  unified against `dispatch_tool/5`'s fixed clause table (see
  `codex_harness.pl`), so an unknown/attacker-chosen name can never
  resolve to an arbitrary predicate.
- CORS defaults to `*` (any origin), which is safe *only* because the
  server binds to `localhost` by default; tighten
  `TASK_HARNESS_CORS_ORIGIN` if that default host binding is ever
  changed.

Tests: `swipl -g run_tests -t halt test_codex_harness_server.pl` (spins
up a real server on an ephemeral localhost port and drives it with
`library(http/http_open)`).

## Tests

```
swipl -g run_tests -t halt test_codex_harness.pl
swipl -g run_tests -t halt test_codex_harness_server.pl
```

Example: `swipl -s example_codex_harness.pl -t halt`.

## Limitations

- `http_json_adapter/3` is a skeleton; providers must map their schema.
- Unified-diff parser handles standard `---`/`+++`/`@@` hunks, not git
  binary patches or rename headers.
- `web_search` requires an injected `web_search_backend/2` goal.
- No bundled UI: the REST API above (async run, list summaries, CORS)
  is designed to be driven by a separately-built web UI, not to ship
  one itself.
