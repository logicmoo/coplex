# 06 — Testing

## Two suites, two different guarantees

| Suite | File | Style | What it proves |
|---|---|---|---|
| Core engine | `test/test_codex_harness.pl` | Pure in-process plunit, `scripted`/`mock`/`openai` adapters only — no external network, no live model | The agent loop, every tool, and the permission model behave correctly in isolation. The `openai` adapter tests are the one exception to "no network": they stand up a real localhost HTTP server as a stand-in provider, so the full request/response translation and multi-turn tool-calling loop are exercised end-to-end without any external network egress or live model call. |
| REST facade | `test/test_codex_harness_server.pl` | plunit driving a **real HTTP server** on an ephemeral localhost port via `library(http/http_open)` | The JSON wire format, routing, status codes, and REST-specific security/UI contracts (async run, CORS, list summaries) all work end-to-end over the wire, not just at the Prolog call level. |

Run both:

```
swipl -g run_tests -t halt test/test_codex_harness.pl
swipl -g run_tests -t halt test/test_codex_harness_server.pl
```

(42 tests / 22 tests respectively at the time of writing — see below
for what each one covers.)

## `test/test_codex_harness.pl` — 42 tests, by category

**Lifecycle & conversation state**
- `new_close` — create/destroy doesn't leak or error.
- `messages_persist_and_reset` — `harness_reset/1` clears messages but
  keeps configuration.
- `snapshot_shape` — `harness_snapshot/2`'s dict has the expected keys.
- `harness_list_tracks_live_instances` — `harness_list/1` reflects
  creation/close accurately.
- `cancel_stops_run` — `harness_cancel/1` actually interrupts a
  multi-step run (proves cooperative cancellation, not just the flag).
- `transcript_written` — `transcript(Path)` produces a readable JSONL
  audit file independent of in-memory state.

**Agent loop mechanics**
- `scripted_final_answer` — the simplest possible run: one model reply
  with no tool calls ends the loop immediately.
- `scripted_tool_loop` — a multi-turn loop where tool results feed
  back into subsequent model calls.
- `max_steps_stops` — the loop actually stops at `max_steps` rather
  than running forever.

**File tools & path safety**
- `read_file_tool`, `write_and_read_roundtrip`, `list_files_and_info`,
  `make_directory` — the basic file-tool happy paths.
- `path_escape_denied` — a path that resolves outside `root` is
  rejected by `safe_resolve/3`, not silently clamped.
- `apply_patch_ok` — a clean unified diff applies.
- `apply_patch_reject_no_write` — a patch targeting a
  non-writable-allowed path is rejected wholesale (all-or-nothing), not
  partially applied.
- `search_fallback` — content search still works when `rg` isn't on
  `PATH` (pure-Prolog fallback path).

**Shell / process gating**
- `shell_disabled_by_default` — `shell` refuses without
  `allow_shell(true)`.
- `shell_enabled_argv` — `shell` executes via explicit argv when
  enabled.
- `run_tests_explicit_command` — an explicit override is honored *with*
  `allow_shell(true)`.
- `run_tests_ignores_override_without_shell` — regression test for the
  2026-08-26 fix: an explicit override is **ignored** without
  `allow_shell(true)`, so `run_tests` can't be used to bypass
  `shell`'s own gate.

**Network / SSRF**
- `network_disabled` — network tools refuse without
  `allow_network(true)`.
- `loopback_blocked_even_with_network` — the SSRF blocklist
  (`unsafe_host/1`) still applies even when network access is
  otherwise enabled — enabling network doesn't mean "trust any host".
- `web_search_backend` — the injected `web_search_backend(Goal)` hook
  is actually invoked and its results returned.

**Real LLM adapter (`openai`)**
- `openai_adapter_full_tool_loop` — the strongest test in the suite: a
  real localhost HTTP server stands in for an OpenAI-compatible
  provider and drives a genuine two-turn tool-calling loop (model
  requests `read_file`, harness executes it for real, model reads the
  result and gives a final answer), proving the request/response
  translation, the `Authorization` header, and the harness's own loop
  all compose correctly end-to-end.
- `openai_adapter_requires_allow_network` — `adapter(openai)` never
  attempts a network call at all while `allow_network` is left at its
  default `false`; fails gracefully with a permission error instead.
- `openai_adapter_respects_allowed_hosts` — `adapter_url` is checked
  against `allowed_hosts` exactly like any tool-initiated fetch; the
  stub server is provably never even contacted on a mismatch.
- `openai_json_schema_of_params` — pure translation check: the
  lightweight per-tool param dicts from `harness_tool_specs/1` convert
  to valid JSON Schema.

**Permission model & tool dispatch**
- `unknown_tool` — an unrecognized tool name gets a clean
  `unknown_tool` error, not a Prolog existence error leaking out.
- `approval_deny` — the `approval(Goal)` hook can veto a call with a
  specific reason.
- `tool_specs_nonempty` — the tool catalog is never empty (a basic
  sanity check the model-facing spec list actually populates).

**Interactive approvals (`approval_mode`)**
- `approval_interactive_allow` — a paused `write_file` call (driven
  from a background thread, since the call blocks synchronously)
  actually completes once `harness_decide_approval/3` allows it.
- `approval_interactive_deny` — a denied call never touches the
  filesystem — proves `deny` isn't just "doesn't throw", the tool
  genuinely didn't run.
- `approval_read_only_bypasses_gating` — a `read_only` tool
  (`git_status`) runs immediately even in `approval_mode(interactive)`
  and never appears in `pending_approvals` — the mode only ever gates
  non-`read_only` risk.
- `approval_deny_risky_denies_without_pause` — `approval_mode
  (deny_risky)` denies a risky call in well under a second (asserted
  via wall-clock timing), proving it's a genuine immediate denial, not
  an accidental one-tick pause.
- `approval_timeout_auto_denies` — a short `approval_timeout` with no
  decision ever posted auto-denies at (not before) the deadline, with
  an error message mentioning the timeout.
- `approval_visible_in_snapshot_and_summary` — while paused, the call
  shows up in `harness_snapshot/2`'s `pending_approvals` (with the
  right `call_id`/`tool`/`risk`) and `harness_summary/2`'s
  `pending_approval_count`.
- `approval_harness_close_denies_pending` — `harness_close/1` resolves
  a pending approval (as denied) and returns promptly, rather than
  hanging until `approval_timeout` elapses or leaking the blocked
  thread.
- `approval_unknown_call_id_errors` — `harness_decide_approval/3` on a
  `call_id` that isn't currently pending throws
  `existence_error(pending_approval, CallId)`, which
  `test_codex_harness_server.pl` separately proves maps to HTTP 404.

**Git tools**
- `git_status_and_log`, `git_show_head` — read-only git subcommands
  return expected shapes (also covers the "result always overwrites
  `tool` with the dispatch name" pitfall noted in `FEATURE_GUIDE.md`).

**Subagents**
- `subagents_analysis_only` — the default child-harness tool allowlist
  is genuinely read-only, proving `subagent_allow_writes` actually
  gates write access rather than being decorative.

## `test/test_codex_harness_server.pl` — 22 tests

- `health` — `GET /coplex/health` liveness.
- `admin_ui_serves_html` — `GET /coplex` replies HTML (not JSON),
  `Content-Type: text/html`, containing the dashboard's markup.
- `admin_ui_bare_root_parity` — bare `GET /` serves byte-identical
  content to `GET /coplex` (the same root/prefix parity every other
  route in this server has).
- `endpoints_moved_to_coplex_endpoints` — the JSON status/endpoint
  document that used to live at `GET /coplex` now lives at `GET
  /coplex/endpoints` (and bare `/endpoints`), and `GET /coplex` itself
  no longer parses as JSON at all — proving the move actually
  happened, not just additively.
- `tools_nonempty` — `GET /coplex/tools` mirrors the core catalog over HTTP.
- `tools_advertise_real_endpoint` — every `GET /coplex/tools` entry
  carries a real `method`/`endpoint` (e.g. `read_file` → `POST
  /coplex/tools/read_file`) instead of leaving a caller to guess a URL.
- `tool_endpoint_is_callable` — `POST /coplex/tools/<name>` (the
  endpoint `GET /coplex/tools` advertises) actually works with no
  harness id at all, using the canonical `/coplex`-prefixed path.
- `direct_tool_endpoint_bare_root_parity` — same route, reached
  through the bare-root parity mount kept for the workbench's
  stripped-prefix proxy.
- `direct_tool_endpoint_unknown_tool_is_200` — an unknown name on
  `POST /coplex/tools/<name>` is an ordinary `200` with an
  `unknown_tool` error body, matching
  `POST /coplex/harnesses/<id>/tools/<name>`'s behavior, not a routing
  404.
- `direct_tool_endpoint_reuses_shared_harness` — repeated direct calls
  share one lazily-created harness (`ensure_default_harness/1`)
  instead of leaking a fresh one per request.
- `create_run_snapshot_delete` — the core CRUD lifecycle over REST:
  create → synchronous run → snapshot (including `created_at`) →
  messages → delete → confirm it's gone from the list.
- `harnesses_list_has_summaries` — `GET /coplex/harnesses` includes
  the `harnesses` summary array (not just `ids`), with correct
  `running`/`message_count` values for a freshly-created harness —
  protects the list-view UI contract described in
  [04-rest-api.md](04-rest-api.md).
- `async_run_completes_in_background` — `{"async": true}` returns
  `started:true` immediately, and polling `GET
  /coplex/harnesses/<id>` eventually observes `running == false` with
  the expected `last_answer` — protects the non-blocking run contract
  end-to-end (not just at the Prolog predicate level).
- `unknown_harness_is_404` — a nonexistent id returns HTTP 404, not a
  500 or a hang.
- `tool_dispatch_over_rest` — `POST /coplex/harnesses/<id>/tools/<name>`
  correctly reaches `harness_tool/4` and returns its result shape.
- `goal_shaped_options_are_ignored` — **security regression test**:
  posting `{"approval": "shell(rm)", "on_event": "shell(rm)",
  "web_search_backend": "shell(rm)"}` at creation must still succeed
  (the keys are silently dropped, not rejected, not — worse — turned
  into a callable goal). This is the test that would fail loudly if
  `safe_option_key/1`'s allowlist were ever accidentally widened to
  include a goal-shaped option.
- `openai_adapter_selectable_and_key_not_leaked` — **security
  regression test**: `adapter:"openai"` plus `adapter_url`/
  `adapter_api_key` must be accepted at creation, but the API key must
  never come back out through `GET /coplex/harnesses/<id>` or `GET
  /coplex/harnesses`'s summary list — the same "never reflected back"
  contract `goal_shaped_options_are_ignored` protects for
  `approval`/`on_event`/etc., applied to the one REST-reachable option
  that is a real secret.
- `cors_preflight_and_headers` — an `OPTIONS` preflight against
  `/coplex/harnesses` returns 200 with `Access-Control-Allow-Origin: *`,
  and a normal `GET /health` (bare-root parity route) reply carries the
  same header — protects the browser-UI CORS contract described in
  [04-rest-api.md](04-rest-api.md) for both route families.
- `approval_over_rest_allow` — full round trip over real HTTP: a
  `write_file` call posted from a background thread pauses, the main
  thread polls `GET /coplex/harnesses/<id>` for `pending_approvals`,
  posts `{"decision": "allow"}` to
  `POST .../approvals/<call_id>`, and the file is confirmed written
  afterward via a follow-up `read_file` call.
- `approval_over_rest_deny` — same shape, `{"decision": "deny"}`; the
  file is confirmed to never have been written.
- `approval_unknown_call_id_is_404` — `POST .../approvals/<call_id>`
  for a `call_id` that was never pending returns HTTP 404, matching
  `unknown_harness_is_404`'s pattern for the harness-id case.
- `approval_mode_deny_risky_over_rest` — `{"approval_mode":
  "deny_risky"}` is accepted by `POST /coplex/harnesses` and actually
  changes behavior end-to-end (an immediate denial on a risky tool
  call) — checked via observable behavior rather than trusting that
  harness creation alone proves the option took effect, since creation
  never echoes options back.

## Testing philosophy notes worth preserving

- **Everything is hermetic.** No test ever calls a live LLM or a live
  external network host; the `scripted`/`mock` adapter
  (`mock_replies`) drives every agent-loop test deterministically, and
  the REST suite starts its own throwaway server on an ephemeral
  localhost port per test run (`test_port/1`, currently `8797`, kept
  distinct from the production default `8840` in `plugin.py` so a real
  running server is never accidentally hijacked by the test suite).
- **The REST suite talks real HTTP**, deliberately *not* reusing the
  server's own `with_json_body/3` helper for the client side — it
  hand-rolls minimal `http_get_json`/`http_post_json`/`http_delete_json`
  helpers around `library(http/http_open)` so the test is exercising
  the actual wire format a real client would send/receive, not just
  the server's internal Prolog call graph.
- **plunit test bodies compile into a private per-unit module**, not
  `user` and not the module under test. This matters if you ever pass
  a goal from a test *into* the library as a callback (e.g.
  `on_event(Goal)`) — it must be explicitly module-qualified
  (`on_event(M:my_callback(H))` with `M` captured via
  `context_module(M)`), or the library's `call(Goal, ...)` resolves in
  the wrong module and raises a silent `existence_error` that a
  surrounding `catch/3` can easily swallow — the bug looks like the
  feature just silently no-ops. See `FEATURE_GUIDE.md`'s pitfall list
  for the full writeup.
- **`once/1` wraps test bodies that can leave a choicepoint** (common
  with `setup_call_cleanup/3` combined with a disjunction) to avoid
  plunit's "succeeded with choicepoint" warning — see `with_h/2` in
  `test_codex_harness.pl`.
- **`assertion/1` discards variable bindings its argument makes.**
  `assertion(get_dict(k, Dict, V))` followed by a later
  `assertion(V == x)` fails with `V` unbound again on the second call
  — bind first with a plain `get_dict/3`, then wrap only the final
  comparison in `assertion/1`. Bit several of the interactive-approval
  tests above during development; see `FEATURE_GUIDE.md`'s pitfall
  list.
- **A JSON round-trip always decodes string values as Prolog strings,
  never atoms**, even when the server-side dict used an atom — REST
  assertions compare `Reply.error.type` against `"denied"`, not
  `denied`. See `FEATURE_GUIDE.md`'s pitfall list.
