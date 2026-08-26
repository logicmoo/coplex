/*  pack.pl -- SWI-Prolog pack metadata for "coplex"

    See https://www.swi-prolog.org/pldoc/man?section=pack-metadata
*/

name(coplex).
title('Codex/Copilot-style coding-agent harness').
keywords([agent, llm, codex, copilot, coding_agent, rest, http, tools]).
description(
    [ 'A provider-agnostic, tool-using coding-agent harness for SWI-Prolog.',
      'One module (codex_harness) exposes object terms codex_harness(Id)',
      'with mutex-protected per-instance state, a pluggable model-adapter',
      'contract, a permissioned tool catalog (file I/O, search, unified-diff',
      'patching, shell, git, network with SSRF guarding, and concurrent',
      'read-only subagents), and an optional JSON REST facade',
      '(coplex_server) so a host process or a browser-based web UI can',
      'drive it over HTTP.'
    ]).
version('1.0.0').
author('logicmoo', 'https://github.com/logicmoo').
maintainer('logicmoo', 'https://github.com/logicmoo').
packager('logicmoo', 'https://github.com/logicmoo').
home('https://github.com/logicmoo/coplex').
download('https://github.com/logicmoo/coplex/archive/refs/tags/*.zip').
requires(prolog >= '9.0').
