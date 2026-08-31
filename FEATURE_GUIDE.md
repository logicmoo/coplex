# coplex — Extra Feature Guidance

This is a companion to `README.md` for whoever picks up `coplex`
next. It describes the known extension points, how to implement each
optional feature safely, and the pitfalls already discovered in this
codebase so they aren't re-learned the hard way.

## 1. Real LLM adapter — **DONE** (`adapter(openai)` / `openai_chat_adapter/3`)

`codex_harness.pl` now ships a complete, working translation adapter
for OpenAI-compatible Chat Completions APIs (OpenAI itself, Azure
OpenAI, and self-hosted servers speaking the same wire format --
vLLM, Ollama's `/v1` shim, LM Studio, ...):

- Select it with `adapter(openai)` -- reachable both in-process
  (`harness_new/2`) and, safely, over REST
  (`POST /coplex/harnesses {"adapter": "openai", ...}` --
  `coplex_server.pl`'s `sanitize_value/3` still only ever normalizes
  `adapter` to one of a fixed, closed set of atoms).
- Point it at a real endpoint with `adapter_url` (default the public
  OpenAI endpoint) and authenticate with `adapter_api_key`
  (sent as `Authorization: Bearer <key>`, never included in any
  request/reply body). Both are plain safe-option-key text, unlike
  `approval`/`on_event`/etc.
- **The API key does live in harness state** (`adapter_api_key`) --
  a deliberate change from the "pass it as a closure argument, never
  store it" advice below, because a REST-created harness has no way
  to receive a closure at all. The mitigation: it's auto-folded into
  `secrets` (see `secrets_with_adapter_key/3`) so `redact_result/3`
  scrubs it from any tool result or emitted event that might
  accidentally echo it, and `harness_snapshot/2`/`harness_summary/2`
  build an explicit field allowlist that never includes it, so it can
  never come back out through any ordinary harness read.
- `allow_network(true)` gates it exactly like `web_search`/`web_get`/
  `download` -- reaching a real hosted LLM is real, costed network
  egress. Unlike those tools, `validate_adapter_url/2` deliberately
  does **not** block loopback/private-range hosts: `adapter_url` is
  trusted, operator-set configuration (like `root`), not task/model-
  controlled input, and a locally-hosted model server is a completely
  ordinary value for it. `allowed_hosts`, if set, is still honored.
- See `test/test_codex_harness.pl`'s `openai_adapter_full_tool_loop`
  for the pattern this guide originally suggested: a real localhost
  HTTP server standing in for the provider, driving a genuine
  multi-turn tool-calling loop end-to-end with no live network egress.

`http_json_adapter(Url, Request, Reply)` is unchanged and still useful
for a provider (or in-house shim) that already speaks this harness's
own `{content, tool_calls}` wire format directly. For a provider that
speaks neither that nor the OpenAI shape (e.g. Anthropic's messages
API), the same recipe still applies -- write one small translation
adapter goal:

- builds the provider-specific JSON body from the harness `Request`
  dict (`model`, `instructions`, `messages`, `tools`, `options`),
- sets the `Authorization` header itself,
- maps the provider's tool-call format back into
  `_{content, tool_calls:[_{id, name, arguments}]}`,

and register it the same way as any built-in adapter --
`harness_new([adapter(your_adapter(Key,Model)), ...], H)`; `wrap_adapter/3`
passes anything it doesn't special-case straight through, so a
fully custom adapter still needs zero core-module changes.

## 2. Minimal UI — **DONE** (`coplex_server.pl` + `plugin.py`)

`harness_snapshot/2` is the intended observation surface — it already
returns a dict with running state, step count, last error, etc. This
is now exposed over HTTP:

- **Web**: `coplex_server.pl` implements `library(http/thread_httpd)`
  + `library(http/http_dispatch)`, exposing `GET
  /coplex/harnesses/<id>` (snapshot as JSON) and `POST
  /coplex/harnesses/<id>/run|cancel|reset`. See the README's "REST
  API" section for the full endpoint table and security model (fixed
  option allowlist; goal-shaped options like
  `approval`/`on_event`/`web_search_backend` are never accepted from
  JSON).
- **Endpoints for a management web UI**: `GET /coplex/harnesses`
  returns a `harnesses` array of `harness_summary/2` dicts (running,
  current_task, message/tool-call counts, created_at) alongside the
  plain `ids`, so a dashboard can list every live agent with one
  request. `POST /coplex/harnesses/<id>/run` accepts `{"async": true}`
  to return immediately (`{ok:true, started:true}`) while the run
  continues in a background thread (`harness_run_async/3` in
  `codex_harness.pl`, which shares its timeout/error handling with the
  synchronous path via `run_body/4`); a UI polls `GET
  /harnesses/<id>`/the list above for `running` to flip back to
  `false`. A second concurrent run on the same harness is rejected
  with HTTP 409 (`guard_not_running/1`) instead of corrupting shared
  state. CORS (`library(http/http_cors)`) is enabled by default for any
  origin — including `OPTIONS` preflight — via
  `COPLEX_CORS_ORIGIN` (comma-separated origins, default `*`,
  `""` disables it), so a browser UI on a different origin/dev-server
  port needs no proxy.
- The runnable entry point lives in a separate file,
  `coplex_server_main.pl` — *not* in `coplex_server.pl`
  itself — because `:- initialization(Goal, main)` fires on plain
  `use_module/1` too, not only when a file is run as the top-level
  script. Putting it in the library file would auto-start a server
  (and block) the moment anything, including a test suite, merely
  loaded the module. Keep this split if you touch either file.
- `plugin.py` supervises the server as a subprocess (start/stop/health
  via `plugin-lifecycle` hooks) and mirrors status/config/restart/
  shutdown through `plugin-api`.
- **Browser-based admin UI — DONE**: `GET /coplex` (and bare `GET /`)
  serves a small, self-contained HTML console (`admin_ui_handler/1`
  + the `admin_ui_html/1` constant, both in `coplex_server.pl`) — a
  two-pane dark-themed layout (sidebar: create-harness form, harness
  list, tool catalog; detail pane: pending-approvals panel, selected
  harness's summary/task/answer/messages), styled after the
  `coplex_stdpy` sibling plugin's task console for a consistent look
  across the workbench's agent-harness plugins. Create/run/cancel/
  reset/inspect/delete harnesses, all via plain `fetch()` calls against
  the JSON endpoints above through absolute `/coplex/...` paths (so it
  works the same loaded directly or through the workbench's proxy). No
  external CSS/JS, no build step. This *is* the "new UI" the bullet
  below originally asked for kept out of the core module -- it lives in
  `coplex_server.pl`, the file already responsible for every UI/network-
  facing concern, not in `codex_harness.pl`. The JSON status/endpoint-
  list document that used to live at `GET /coplex` moved to `GET
  /coplex/endpoints` (`coplex_endpoints_handler/1`, the renamed former
  `coplex_status_handler/1`) to make room for it.
  **Interactive tool-call approvals — DONE** (this used to be the
  first item in "not ported from `coplex_stdpy`'s console" below):
  `approval_mode(interactive)` (also settable over REST as
  `{"approval_mode": "interactive"}`) pauses any non-`read_only`-risk
  tool call in `wait_for_approval/6`, which registers a
  `pending_approval_rec/3` fact (mutex `coplex_pending_approvals`),
  emits an `approval_requested` event, and polls every 0.25s for
  either: a decision via the new `harness_decide_approval/3` (wired to
  `POST /coplex/harnesses/<id>/approvals/<call_id>`, body
  `{"decision": "allow"|"deny"}`, 404 for an unknown/already-resolved
  `call_id`), `approval_timeout` seconds elapsing (auto-deny, default
  300), or the harness being cancelled/closed (`deny_all_pending_
  approvals/1`, called from `harness_close/1`, denies every pending
  approval for that harness before its state is retracted). Pending
  approvals surface through `harness_snapshot/2`'s `pending_approvals`
  list and `harness_summary/2`'s `pending_approval_count`, and the
  admin UI renders one Allow/Deny row per pending call. `approval_mode`
  is a *second*, independent gate alongside the pre-existing in-process
  `approval(Goal)` callback (unchanged, still never REST-settable,
  still takes priority when set) -- `deny_risky` is the same
  non-`read_only` trigger but denies immediately with no pause, for
  unattended REST automation. Two subtleties worth knowing if you touch
  this code: (1) SWI dict dot-notation (`Info.tool`) does *not*
  goal-expand correctly inside a `findall/3` *template* argument --
  see `pending_approvals_for/2`'s comment for the fix (build the dict
  inside the findall *goal*, not the template); (2) the auto-generated
  per-call approval key must be a string, not an atom (`uuid/1`'s
  default), because every model-driven `call_id` is already a string
  (`normalize_call/2` via `text_of/2`) and a REST caller always POSTs a
  string (a URL path segment) back -- an atom/string mismatch would
  make `harness_decide_approval/3` claim a perfectly valid, currently-
  pending `call_id` doesn't exist.
  **Still not ported from `coplex_stdpy`'s console**: durable
  disk-persisted tasks that survive a restart, and the separate
  human-input-request mechanism (`coplex_stdpy`'s `provide_input`/
  `POST /tasks/<id>/input`) -- `coplex` has no equivalent of a task
  pausing to *ask the model's caller a question* mid-run, only tool-
  call approval. `coplex_stdpy`'s `HarnessTaskManager` (see its
  `runtime.py`) persists every task as JSON + a JSONL event log under a
  state directory and rehydrates it on startup; `coplex`'s harnesses
  (and their pending approvals) remain purely in-memory and vanish on
  restart. Bringing that part of parity would mean persisting
  `harness_rec/3` state (and an incrementally-appended event log) to
  disk and rehydrating it on `workbench_startup/0` -- real new
  engineering on the core agent loop, not a UI-only change -- treat it
  as a separate, deliberately-scoped feature.
- A remaining idea, not yet done: a CLI/REPL loop calling
  `harness_run/3` directly in-process for local scripting (as opposed
  to the REST API) — still worth adding if useful, but the REST layer
  now covers the "workbench can puppet us" requirement. Also not done:
  a push-based progress channel (SSE/WebSocket) — polling `GET
  /harnesses/<id>` covers it for now, but would cut the poll latency
  for a busier UI if ever needed.
- Keep any *new* UI in its own file that depends on `codex_harness`
  (as `coplex_server.pl` already does) — don't fold UI/network
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
- **SWI dict dot-notation does not goal-expand inside a `findall/3`
  *template* argument.** Writing
  `findall(_{k:Dict.field}, Goal, List)` throws `instantiation_error`
  even when `Goal` has solutions, because `Dict.field` expands into an
  extra `get_dict/3` goal sequenced *before* `findall/3` starts (when
  `Dict` is still unbound) rather than once per solution. Fix: build
  the dict inside the *goal* (second argument), where the generator
  has already bound the dict earlier in the same conjunction --
  `findall(Record, (Goal, Record = _{k:Dict.field}), List)` -- see
  `pending_approvals_for/2`. The same eager-evaluation trap applies to
  *any* goal-term built as data and meta-called later (`catch/3`,
  `forall/2`, `thread_create/3`, a test helper like `check(Label,
  Goal)`): dict dot-notation only expands correctly if the enclosing
  predicate declares that argument a goal position, e.g.
  `:- meta_predicate check(?, 0).` -- without it, prefer explicit
  `get_dict/3` in those deferred goals instead of `.` syntax.
- **`assertion/1` (library(debug)) discards variable bindings made by
  its argument.** `assertion(get_dict(k, Dict, V)), assertion(V ==
  something)` fails on the second call with `V` unbound again -- any
  binding a later line needs must come from a plain (non-`assertion`-
  wrapped) call; only wrap the final, self-contained check in
  `assertion/1`.
- **A JSON round-trip through `json_read_dict/2` always decodes string
  values as Prolog strings, never atoms** -- even when the original
  server-side dict used an atom (`_{type:denied}`). REST tests must
  compare against `"denied"`, not `denied`; see
  `test_codex_harness_server.pl`'s `Reply.error.type == "unknown_tool"`
  -style assertions.
- **An auto-generated id used as a lookup key must match the type
  every other producer of that same key uses.** `uuid/1` defaults to
  an atom, but every model-driven `call_id` in this codebase is a
  string (`normalize_call/2`, via `text_of/2`), and a REST caller
  always supplies a string (a URL path segment via `split_string/4`).
  Registering the auto-generated approval key as an atom would make
  `harness_decide_approval/3`'s plain unification silently never match
  a REST-supplied `call_id` for the *same* logical call -- normalize to
  a string at the point of generation (`atom_string/2`) rather than
  trying to make every consumer type-tolerant.

## Suggested order of work

1. Real adapter for one concrete provider + hermetic test.
2. `web_search_backend` reference implementation.
3. ~~Minimal CLI or HTTP UI on top of `harness_snapshot/2`.~~ Done —
   see `coplex_server.pl` / `coplex_server_main.pl`.
4. Git write support / diff parser hardening (only if a task actually
   needs them — the read-only subset already covers most agent use
   cases).

Each item above is independent and additive; none require touching the
core loop (`loop_steps/4`) or the permission model.
