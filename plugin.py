"""coplex workbench plugin (backed by the "coplex" pack).

The coding-agent loop lives in SWI-Prolog (`prolog/coplex/codex_harness.pl`)
and is exposed over HTTP by `prolog/coplex_server.pl`, a small JSON REST
facade built only from SWI's bundled http libraries (see that file's
module docstring for the endpoint list and the security model: no
request body is ever parsed as Prolog code or call/N'd by name).

This module is the Python side of the contract declared in
`plugin.json`:

* `plugin-lifecycle.hooks` -- each named phase (install, workbench
  startup/shutdown, workspace startup/shutdown, ...) maps to a
  function here.  Every hook returns a small JSON-able dict with at
  least an "ok" key rather than raising, since the exact host-side
  error handling convention isn't something this plugin can verify.
* `plugin-api` -- `status`, `config`, `restart`, `shutdown` are the
  plugin's admin surface: whatever calls them (an HTTP handler, a CLI,
  a test) can inspect/drive this plugin without touching Prolog.

The lifecycle hooks manage *this process's* one shared
coplex_server.pl instance (started once at workbench startup,
stopped at workbench shutdown); the plugin-api functions let a caller
inspect/restart/stop that same instance on demand. Harness instances
themselves are created on demand per caller via POST /harnesses, so
there is nothing workspace-scoped to start or stop.

No new third-party dependencies: only the standard library and
`swipl` (already required by plugin.json) are used.

This file intentionally stays at the repository root rather than
moving under `prolog/`/`src/` -- the workbench loads it directly via
plugin.json's `"entrypoint": "plugin.py"` contract. `pyproject.toml`
declares it as a top-level py-module so it can *also* be published to
PyPI without disturbing that contract.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

PLUGIN_ID = "coplex"
HARNESS_MODULE = "prolog/coplex/codex_harness.pl"
SERVER_MODULE = "prolog/coplex_server.pl"
SERVER_MAIN = "prolog/coplex_server_main.pl"
TEST_SUITE = "test/test_codex_harness.pl"

PLUGIN_DIR = Path(__file__).resolve().parent
STATE_FILE = PLUGIN_DIR / ".harness_server_state.json"

DEFAULT_PORT = 8840
DEFAULT_HOST = "localhost"
START_TIMEOUT_SECONDS = 10
HEALTH_POLL_INTERVAL = 0.2

# The REST surface served by prolog/coplex_server.pl. Every route also
# answers under the /coplex prefix (the pack's slug), both directly on the
# server port and through the workbench's /coplex mount.
REST_ENDPOINTS = [
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
    "POST   /shutdown",
]
PATH_PREFIXES = ["/", "/coplex"]


# --------------------------------------------------------------------------
# swipl discovery / subprocess helpers
# --------------------------------------------------------------------------

def _swipl_path() -> Optional[str]:
    return shutil.which("swipl")


def _run_swipl(args: list, timeout: int = 60, cwd: Optional[Path] = None) -> dict:
    """Run swipl with args, capturing output.

    Never raises for a non-zero swipl exit; callers inspect the
    returned dict's "ok"/"returncode" instead.
    """
    swipl = _swipl_path()
    if swipl is None:
        return {"ok": False, "error": "swipl not found on PATH"}
    try:
        proc = subprocess.run(
            [swipl, *args],
            cwd=str(cwd or PLUGIN_DIR),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "error": f"swipl timed out after {timeout}s: {exc}"}
    except OSError as exc:
        return {"ok": False, "error": f"failed to launch swipl: {exc}"}
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def _swipl_version() -> Optional[str]:
    result = _run_swipl(["--version"], timeout=10)
    stdout = result.get("stdout")
    return stdout.strip() if stdout else None


# --------------------------------------------------------------------------
# REST server process management
# --------------------------------------------------------------------------

def _read_state() -> Optional[dict]:
    if not STATE_FILE.exists():
        return None
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _write_state(state: Optional[dict]) -> None:
    if state is None:
        try:
            STATE_FILE.unlink(missing_ok=True)
        except OSError:
            pass
        return
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def _health_url(host: str, port: int) -> str:
    return f"http://{host}:{port}/health"


def _http_get_json(url: str, timeout: float = 2.0) -> Optional[dict]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - localhost only
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None


def _http_post_json(url: str, body: Optional[dict] = None, timeout: float = 5.0) -> Optional[dict]:
    data = json.dumps(body or {}).encode("utf-8")
    req = urllib.request.Request(  # noqa: S310 - localhost only
        url, data=data, method="POST", headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None


def _pid_alive(pid: int) -> bool:
    if not pid or pid <= 0:
        return False
    if os.name == "nt":
        try:
            import ctypes

            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
            if not handle:
                return False
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
        except Exception:
            return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def server_status() -> dict:
    """Report on the (possibly nonexistent) running server, checked
    both at the OS level (PID) and by an actual /health request."""
    state = _read_state()
    if state is None:
        return {"running": False}
    host, port, pid = state.get("host"), state.get("port"), state.get("pid")
    health = _http_get_json(_health_url(host, port)) if host and port else None
    alive = _pid_alive(pid) if pid else False
    running = bool(health) or alive
    if not running:
        _write_state(None)
    return {
        "running": running,
        "host": host,
        "port": port,
        "pid": pid,
        "started_at": state.get("started_at"),
        "health": health,
    }


def start_server(port: int = DEFAULT_PORT, host: str = DEFAULT_HOST) -> dict:
    """Start coplex_server_main.pl as a background swipl process, if
    not already running. Waits for /health to answer before returning."""
    existing = server_status()
    if existing.get("running"):
        return {"ok": True, "already_running": True, **existing}

    swipl = _swipl_path()
    if swipl is None:
        return {"ok": False, "error": "swipl not found on PATH"}

    server_pl = PLUGIN_DIR / SERVER_MAIN
    if not server_pl.exists():
        return {"ok": False, "error": f"{SERVER_MAIN} not found under the plugin directory"}

    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0

    try:
        proc = subprocess.Popen(
            [swipl, str(server_pl), f"--port={port}", f"--host={host}"],
            cwd=str(PLUGIN_DIR),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            creationflags=creationflags,
        )
    except OSError as exc:
        return {"ok": False, "error": f"failed to start server: {exc}"}

    _write_state({"pid": proc.pid, "port": port, "host": host, "started_at": time.time()})

    deadline = time.time() + START_TIMEOUT_SECONDS
    health = None
    while time.time() < deadline:
        if proc.poll() is not None:
            _write_state(None)
            return {"ok": False, "error": f"server process exited early with code {proc.returncode}"}
        health = _http_get_json(_health_url(host, port))
        if health:
            break
        time.sleep(HEALTH_POLL_INTERVAL)

    if not health:
        return {"ok": False, "error": "server did not become healthy in time", "pid": proc.pid, "port": port}

    return {"ok": True, "already_running": False, "pid": proc.pid, "port": port, "host": host, "health": health}


def stop_server(timeout: float = 5.0) -> dict:
    """Ask the server to shut down gracefully via POST /shutdown; fall
    back to an OS-level terminate if that doesn't work within timeout."""
    state = _read_state()
    if state is None:
        return {"ok": True, "was_running": False}

    host, port, pid = state.get("host"), state.get("port"), state.get("pid")
    graceful = _http_post_json(f"http://{host}:{port}/shutdown") if host and port else None

    deadline = time.time() + timeout
    while time.time() < deadline:
        if not (pid and _pid_alive(pid)):
            break
        time.sleep(HEALTH_POLL_INTERVAL)

    if pid and _pid_alive(pid):
        try:
            import signal

            os.kill(pid, getattr(signal, "SIGTERM", 15))
        except OSError:
            pass
        time.sleep(0.5)

    _write_state(None)
    return {"ok": True, "was_running": True, "graceful": bool(graceful)}


# --------------------------------------------------------------------------
# plugin-lifecycle hooks (names referenced from plugin.json)
# --------------------------------------------------------------------------

def install() -> dict:
    """Verify the one hard requirement (swipl on PATH) before anything
    else runs."""
    swipl = _swipl_path()
    if swipl is None:
        return {"ok": False, "error": "swipl not found on PATH; install SWI-Prolog 9+ first"}
    return {"ok": True, "swipl": swipl, "version": _swipl_version()}


def install_after() -> dict:
    """Post-install smoke test: run the plunit suite once so a broken
    checkout is caught immediately instead of at first use."""
    result = _run_swipl(["-g", "run_tests", "-t", "halt", TEST_SUITE], timeout=120)
    return {
        "ok": bool(result.get("ok")),
        "returncode": result.get("returncode"),
        "log": (result.get("stdout") or "") + (result.get("stderr") or ""),
    }


def uninstall() -> dict:
    """Make sure the REST server isn't left running."""
    return stop_server()


def uninstall_after() -> dict:
    return {
        "ok": True,
        "note": "Nothing to remove beyond SWI-Prolog itself; no files were installed outside this plugin directory.",
    }


def workbench_startup() -> dict:
    """Start the shared REST server so the workbench can immediately
    drive this plugin over HTTP."""
    port = int(os.environ.get("COPLEX_PORT", DEFAULT_PORT))
    host = os.environ.get("COPLEX_HOST", DEFAULT_HOST)
    return start_server(port=port, host=host)


def workbench_startup_after() -> dict:
    return status()


def workbench_shutdown() -> dict:
    return stop_server()


def workbench_shutdown_after() -> dict:
    return {"ok": True}


def workspace_startup() -> dict:
    """No-op: harness instances are created on demand per caller via
    POST /harnesses (or a direct harness_new/2 call), not one per
    workspace, so there is nothing workspace-scoped to start."""
    return {"ok": True, "note": "no per-workspace resources"}


def workspace_startup_after() -> dict:
    return {"ok": True}


def workspace_shutdown() -> dict:
    return {"ok": True, "note": "no per-workspace resources"}


def workspace_shutdown_after() -> dict:
    return {"ok": True}


# --------------------------------------------------------------------------
# plugin loader hook
# --------------------------------------------------------------------------

def create_router(manifest: dict | None = None):
    """Plugin hook: ensure the standalone swipl REST server is running.

    Standalone-only -- the harness lives in its own swipl process
    (prolog/coplex_server_main.pl) and the workbench reaches it through the
    web_proxy mount declared in plugin.json, so this contributes no in-process
    routes. A missing swipl is reported by status()/lifecycle surfaces, never
    raised here (the catalog should list the plugin either way).
    """

    port = int(os.environ.get("COPLEX_PORT", DEFAULT_PORT))
    host = os.environ.get("COPLEX_HOST", DEFAULT_HOST)
    start_server(port=port, host=host)
    from fastapi import APIRouter

    return APIRouter()


# --------------------------------------------------------------------------
# plugin-api surface (names referenced from plugin.json)
# --------------------------------------------------------------------------

def status() -> dict:
    """Everything a host needs to know to decide whether this plugin
    is usable right now."""
    swipl = _swipl_path()
    server = server_status()
    running = server.get("running", False)
    return {
        "ok": True,
        "plugin_id": PLUGIN_ID,
        "standalone": True,
        "swipl": swipl,
        "swipl_version": _swipl_version() if swipl else None,
        "harness_module": HARNESS_MODULE,
        "server_module": SERVER_MODULE,
        "server": server,
        "rest_api": running,
        "base_url": f"http://{server.get('host')}:{server.get('port')}" if running else None,
        "path_prefixes": PATH_PREFIXES,
        "endpoints": REST_ENDPOINTS,
    }


def config() -> dict:
    """Describe the REST surface and the safe harness_new/2 option
    subset it accepts, for a host settings UI."""
    return {
        "ok": True,
        "server": {
            "default_host": DEFAULT_HOST,
            "default_port": DEFAULT_PORT,
            "host_env": "COPLEX_HOST",
            "port_env": "COPLEX_PORT",
            "cors_origin_env": "COPLEX_CORS_ORIGIN",
            "cors_origin_default": "*",
        },
        "endpoints": REST_ENDPOINTS,
        "path_prefixes": PATH_PREFIXES,
        "ui_notes": (
            "GET /harnesses returns both 'ids' and a lightweight 'harnesses' summary list "
            "(running/current_task/iteration/last_answer/last_error/message_count/"
            "tool_call_count/created_at) so a dashboard can render a table with one request. "
            "POST /harnesses/<id>/run blocks until the run finishes by default; pass "
            "{'async': true} to get an immediate {ok, started:true} reply while the run "
            "continues in a background thread, then poll GET /harnesses/<id> (or the list "
            "above) for 'running' to flip back to false. A run request while one is already "
            "in flight is rejected with HTTP 409. CORS is enabled by default (any origin) so "
            "a browser-based UI can call this API directly; restrict it with "
            "COPLEX_CORS_ORIGIN (comma-separated origins, or '' to disable) for anything "
            "beyond local development. Each GET /tools entry carries a real 'method'/"
            "'endpoint' (POST /coplex/tools/<name>) that a UI can call directly against a "
            "shared, lazily-created harness -- no need to create/manage a harness id just to "
            "run one tool."
        ),
        "harness_new_options": {
            "root": "string, repository root (default '.')",
            "cwd": "string, working directory (default = root)",
            "model": "string, adapter-defined model name",
            "instructions": "string, system prompt override",
            "extra_instructions": "string, appended to instructions",
            "allow_shell": "boolean, enable the shell/run_tests-override tools",
            "allow_network": "boolean, enable web_search/web_get/download",
            "allowed_hosts": "list of strings, extra allowed network hosts",
            "writable_paths": "list of strings, extra writable paths",
            "readable_paths": "list of strings, extra readable paths",
            "max_output_bytes": "integer",
            "max_download_bytes": "integer",
            "timeout": "integer, seconds, overall run timeout",
            "command_timeout": "integer, seconds, per-shell-command timeout",
            "max_steps": "integer, agent loop iteration cap",
            "subagent_limit": "integer",
            "subagent_allow_writes": "boolean",
            "transcript": "string, JSONL transcript file path",
            "secrets": "list of strings, values redacted from tool output",
            "default_test_command": "string/list, or 'auto'",
            "mock_replies": "list of {content, tool_calls} dicts (scripted adapter only)",
            "allowed_tools": "list of tool-name strings, or 'all'",
            "adapter": "'scripted', 'mock', or 'openai' over REST; a fully custom adapter callable can only be set in-process",
            "adapter_url": "string, endpoint openai_chat_adapter/3 POSTs to (default the public OpenAI Chat Completions endpoint)",
            "adapter_api_key": "string, sent as 'Authorization: Bearer <key>' by the openai adapter; auto-redacted from tool output/events, never returned by any harness read",
        },
        "note": (
            "approval, on_event, parent, and web_search_backend are intentionally not settable over REST: "
            "codex_harness.pl call/N's each of them, so accepting them from untrusted JSON would be a "
            "code-injection risk. Set them only via a direct, in-process harness_new/2 call."
        ),
    }


def restart() -> dict:
    stop_server()
    port = int(os.environ.get("COPLEX_PORT", DEFAULT_PORT))
    host = os.environ.get("COPLEX_HOST", DEFAULT_HOST)
    return start_server(port=port, host=host)


def shutdown() -> dict:
    return stop_server()


# --------------------------------------------------------------------------
# manual CLI for local testing: `python plugin.py start|stop|status|restart`
# --------------------------------------------------------------------------

if __name__ == "__main__":
    _COMMANDS = {
        "start": workbench_startup,
        "stop": workbench_shutdown,
        "status": status,
        "restart": restart,
        "install": install,
        "install-after": install_after,
        "config": config,
    }
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    fn = _COMMANDS.get(cmd)
    if fn is None:
        print(f"Unknown command {cmd!r}. Choose from: {', '.join(_COMMANDS)}", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(fn(), indent=2, default=str))
