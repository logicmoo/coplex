# task_harness_pl — Extra Feature Guidance

This is a companion to `README.md` for whoever picks up `task_harness_pl`
next. It describes the known extension points, how to implement each
optional feature safely, and the pitfalls already discovered in this
codebase so they aren't re-learned the hard way.

## 1. Real LLM adapter (replace/extend `http_json_adapter/3`)

`http_json_adapter(Url, Request, Reply)` already POSTs the normalized
request JSON and parses a `{content, tool_calls}` reply, but it assumes
the remote endpoint speaks the harness's own wire schema. Real
providers (OpenAI-style chat completions, Anthropic messages API, etc.)
need a small translation layer:

- Write one adapter goal per provider, e.g. `openai_adapter(ApiKey, Model)`,
  that:
  1. builds the provider-specific JSON body from the harness `Request`
     dict (`model`, `instructions`, `messages`, `tools`, `options`),
  2. sets the `Authorization` header itself (never store the key in
     harness state — pass it via a closure argument, e.g.
     `adapter(openai_adapter(Key, "gpt-4o"))`),
  3. maps the provider's tool-call format back into
     `_{content, tool_calls:[_{id, name, arguments}]}`.
- Register it the same way as any other adapter: `harness_new([adapter(openai_adapter(Key,Model)), ...], H)`.
- Keep `wrap_adapter/3` untouched — it only special-cases `scripted`/`mock`;
  anything else passes through as-is, so custom adapters need no core
  changes.
- Add a plunit test using a fake HTTP server (e.g. `library(http/http_server)`
  bound to `localhost` on an ephemeral port) rather than a live provider,
  so tests stay hermetic and offline.

## 2. Minimal UI — **DONE** (`codex_harness_server.pl` + `plugin.py`)

`harness_snapshot/2` is the intended observation surface — it already
returns a dict with running state, step count, last error, etc. This
is now exposed over HTTP:

- **Web**: `codex_harness_server.pl` implements `library(http/thread_httpd)`
  + `library(http/http_dispatch)`, exposing `GET /harnesses/<id>`
  (snapshot as JSON) and `POST /harnesses/<id>/run|cancel|reset`. See
  the README's "REST API" section for the full endpoint table and
  security model (fixed option allowlist; goal-shaped options like
  `approval`/`on_event`/`web_search_backend` are never accepted from
  JSON).
- **Endpoints for a management web UI**: `GET /harnesses` returns a
  `harnesses` array of `harness_summary/2` dicts (running,
  current_task, message/tool-call counts, created_at) alongside the
  plain `ids`, so a dashboard can list every live agent with one
  request. `POST /harnesses/<id>/run` accepts `{"async": true}` to
  return immediately (`{ok:true, started:true}`) while the run
  continues in a background thread (`harness_run_async/3` in
  `codex_harness.pl`, which shares its timeout/error handling with the
  synchronous path via `run_body/4`); a UI polls `GET
  /harnesses/<id>`/the list above for `running` to flip back to
  `false`. A second concurrent run on the same harness is rejected
  with HTTP 409 (`guard_not_running/1`) instead of corrupting shared
  state. CORS (`library(http/http_cors)`) is enabled by default for any
  origin — including `OPTIONS` preflight — via
  `TASK_HARNESS_CORS_ORIGIN` (comma-separated origins, default `*`,
  `""` disables it), so a browser UI on a different origin/dev-server
  port needs no proxy.
- The runnable entry point lives in a separate file,
  `codex_harness_server_main.pl` — *not* in `codex_harness_server.pl`
  itself — because `:- initialization(Goal, main)` fires on plain
  `use_module/1` too, not only when a file is run as the top-level
  script. Putting it in the library file would auto-start a server
  (and block) the moment anything, including a test suite, merely
  loaded the module. Keep this split if you touch either file.
- `plugin.py` supervises the server as a subprocess (start/stop/health
  via `plugin-lifecycle` hooks) and mirrors status/config/restart/
  shutdown through `plugin-api`.
- A remaining idea, not yet done: a CLI/REPL loop calling
  `harness_run/3` directly in-process for local scripting (as opposed
  to the REST API) — still worth adding if useful, but the REST layer
  now covers the "workbench can puppet us" requirement. Also not done:
  a push-based progress channel (SSE/WebSocket) — polling `GET
  /harnesses/<id>` covers it for now, but would cut the poll latency
  for a busier UI if ever needed.
- Keep any *new* UI in its own file that depends on `codex_harness`
  (as `codex_harness_server.pl` already does) — don't fold UI/network
  code into the core module.

## 3. Additional tools

Follow the existing `dispatch_tool/5` pattern in `codex_harness.pl`:

```prolog
dispatch_tool(my_tool, ReadWriteClass, S, A, R) :- tool_my_tool(S, A, R).
tool_my_tool(S, A, R) :- ...
```

- `ReadWriteClass` drives permission checks (`_`/`write`/`process`/`network`)
  — reuse the existing classes, don't invent a new gate without also
  updating `allowed_tool_name/2`.
- Tag results with `.put(tool, Name)` for consistency, but remember
  `harness_tool/4` **always** overwrites `tool` with the dispatch name
  before returning to the caller (see pitfall below) — so any internal
  tagging you do inside `tool_my_tool/3` is cosmetic only and does not
  need to match the dispatch name.
- Add the tool's JSON-schema-ish spec to `harness_tool_specs/1` so
  models can discover it.
- Add a plunit test exercising both the success path and one
  permission-denied path (mirror `path_escape_denied` /
  `network_disabled` for style).

## 4. Git parity improvements

`tool_git/4` currently supports `status`, `diff`, `log`, `show`
(read-only). If write operations (`git_commit`, `git_apply`) are ever
needed:
- Keep them read-only by default; require an explicit
  `allow_git_write(true)` option mirroring `allow_shell`/`allow_network`.
- Route through `exec_program/7` like the existing verbs so timeout/
  truncation/cancellation behavior is inherited for free.

## 5. Unified diff parser hardening

The current `tool_apply_patch/3` handles standard `---`/`+++`/`@@`
hunks only. If git binary patches or rename headers are needed:
- Detect `diff --git a/... b/...`, `rename from`/`rename to`, and
  `Binary files ... differ` headers up front and either reject them
  with a clear `error:_{type:unsupported_patch}` or shell out to
  `git apply` (gated behind `allow_shell(true)` since it's an external
  process) rather than hand-rolling binary/rename support in Prolog.

## 6. `web_search` backend

`web_search` requires an injected `web_search_backend(Goal)` where
`call(Goal, Query, Results)`. To make this usable out of the box:
- Ship one or two reference backends (e.g. a `bing_backend(ApiKey)` or
  a local search index) as separate opt-in files, not a hard dependency
  of `codex_harness.pl`.
- Same secret-handling rule as adapters: pass keys as closure
  arguments, never store them in harness state (`S.secrets` is only for
  redacting known strings from logs/transcripts, not for holding keys).

## Pitfalls already discovered (avoid re-debugging these)

- **Fixed 2026-08-26 — `run_tests` ignored the shell permission gate.**
  `tool_run_tests/3` used to execute an explicit caller-supplied
  `command`/`args` unconditionally, regardless of `allow_shell`, making
  it a full arbitrary-command-execution bypass of `tool_shell`'s gate.
  Now an explicit override is honored only when `allow_shell(true)`;
  otherwise the auto-detected/configured `default_test_command` is
  always used. See `run_tests_ignores_override_without_shell` in
  `test_codex_harness.pl`.
- **Fixed 2026-08-26 — SSRF guard missed `172.16.0.0/12`.**
  `unsafe_host/1` blocked `10.0.0.0/8`, `192.168.0.0/16`, and
  `169.254.0.0/16` but not the RFC1918 `172.16.0.0/12` range, nor IPv6
  unique-local (`fc00::/7`) / link-local (`fe80::/10`) literals. All are
  now blocked; the IPv6 checks are gated on the host containing `:` so
  ordinary hostnames (e.g. `fcbank.example.com`) are never
  false-positived.
- **Fixed 2026-08-26 — `detect_tests/3` had unreachable normalization
  code.** Its first clause cut before ever falling through to the
  second clause that ran values through `text_of/2`, so a
  `default_test_command` with non-string elements was never normalized.
  Consolidated into a single clause that always normalizes.
- **`harness_tool/4` overwrites `tool` in the result.** Any test or
  caller must expect `Result.tool == DispatchName` (e.g. `git_status`),
  not whatever the underlying `tool_*` predicate tagged internally
  (e.g. `git`). See `test_codex_harness.pl:git_status_and_log`.
- **`start_run/3` resets `cancelled` to `false`.** Calling
  `harness_cancel/1` *before* `harness_run/3` has no effect — cancel
  must happen *during* an active run (e.g. from an `on_event/1`
  callback reacting to a `tool_finish` event).
- **plunit test bodies compile into a private per-unit module**, not
  `user` and not the module under test. Any goal passed from a test
  into the library (like an `on_event(Goal)` callback) must be
  explicitly qualified, e.g. `on_event(M:my_callback(H))` with
  `M` captured via `context_module(M)` — otherwise the library's
  `call(Goal, ...)` resolves in the wrong module, raises a silent
  `existence_error` (often swallowed by a `catch/3`), and the feature
  silently no-ops instead of failing loudly.
- **Windows `process_create/3` pipes deadlock** unless stdout/stderr
  are drained on separate threads (see `read_pipe/1` + `join_pipe/2`)
  and `window(false)` is passed on Windows — don't inline
  `read_string/3` directly against a live pipe in the main thread.
- **`once/1` wrap test bodies that can leave choicepoints** (e.g. via
  `setup_call_cleanup/3` combined with disjunction) to avoid plunit's
  "succeeded with choicepoint" warnings; see `with_h/2` in
  `test_codex_harness.pl`.

## Suggested order of work

1. Real adapter for one concrete provider + hermetic test.
2. `web_search_backend` reference implementation.
3. ~~Minimal CLI or HTTP UI on top of `harness_snapshot/2`.~~ Done —
   see `codex_harness_server.pl` / `codex_harness_server_main.pl`.
4. Git write support / diff parser hardening (only if a task actually
   needs them — the read-only subset already covers most agent use
   cases).

Each item above is independent and additive; none require touching the
core loop (`loop_steps/4`) or the permission model.
