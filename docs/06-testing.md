# 06 — Testing

## Two suites, two different guarantees

| Suite | File | Style | What it proves |
|---|---|---|---|
| Core engine | `test_codex_harness.pl` | Pure in-process plunit, `scripted`/`mock` adapter only — no network, no live model | The agent loop, every tool, and the permission model behave correctly in isolation. |
| REST facade | `test_codex_harness_server.pl` | plunit driving a **real HTTP server** on an ephemeral localhost port via `library(http/http_open)` | The JSON wire format, routing, status codes, and REST-specific security/UI contracts (async run, CORS, list summaries) all work end-to-end over the wire, not just at the Prolog call level. |

Run both:

```
swipl -g run_tests -t halt test_codex_harness.pl
swipl -g run_tests -t halt test_codex_harness_server.pl
```

(30 tests / 9 tests respectively at the time of writing — see below
for what each one covers.)

## `test_codex_harness.pl` — 30 tests, by category

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

**Permission model & tool dispatch**
- `unknown_tool` — an unrecognized tool name gets a clean
  `unknown_tool` error, not a Prolog existence error leaking out.
- `approval_deny` — the `approval(Goal)` hook can veto a call with a
  specific reason.
- `tool_specs_nonempty` — the tool catalog is never empty (a basic
  sanity check the model-facing spec list actually populates).

**Git tools**
- `git_status_and_log`, `git_show_head` — read-only git subcommands
  return expected shapes (also covers the "result always overwrites
  `tool` with the dispatch name" pitfall noted in `FEATURE_GUIDE.md`).

**Subagents**
- `subagents_analysis_only` — the default child-harness tool allowlist
  is genuinely read-only, proving `subagent_allow_writes` actually
  gates write access rather than being decorative.

## `test_codex_harness_server.pl` — 9 tests

- `health` — `GET /health` liveness.
- `tools_nonempty` — `GET /tools` mirrors the core catalog over HTTP.
- `create_run_snapshot_delete` — the core CRUD lifecycle over REST:
  create → synchronous run → snapshot (including `created_at`) →
  messages → delete → confirm it's gone from the list.
- `harnesses_list_has_summaries` — `GET /harnesses` includes the
  `harnesses` summary array (not just `ids`), with correct
  `running`/`message_count` values for a freshly-created harness —
  protects the list-view UI contract described in
  [04-rest-api.md](04-rest-api.md).
- `async_run_completes_in_background` — `{"async": true}` returns
  `started:true` immediately, and polling `GET /harnesses/<id>`
  eventually observes `running == false` with the expected
  `last_answer` — protects the non-blocking run contract end-to-end
  (not just at the Prolog predicate level).
- `unknown_harness_is_404` — a nonexistent id returns HTTP 404, not a
  500 or a hang.
- `tool_dispatch_over_rest` — `POST /harnesses/<id>/tools/<name>`
  correctly reaches `harness_tool/4` and returns its result shape.
- `goal_shaped_options_are_ignored` — **security regression test**:
  posting `{"approval": "shell(rm)", "on_event": "shell(rm)",
  "web_search_backend": "shell(rm)"}` at creation must still succeed
  (the keys are silently dropped, not rejected, not — worse — turned
  into a callable goal). This is the test that would fail loudly if
  `safe_option_key/1`'s allowlist were ever accidentally widened to
  include a goal-shaped option.
- `cors_preflight_and_headers` — an `OPTIONS` preflight against
  `/harnesses` returns 200 with `Access-Control-Allow-Origin: *`, and
  a normal `GET /health` reply carries the same header — protects the
  browser-UI CORS contract described in
  [04-rest-api.md](04-rest-api.md).

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
