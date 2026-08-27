# 9. Connecting a Real Model

Every lesson so far used the `scripted` adapter -- a stand-in that
replays canned answers instead of thinking. This lesson is about the
seam that lets you swap it for something that actually calls a real
LLM, without touching the loop itself.

## The whole contract, again

An adapter is *any* goal matching:

```prolog
call(Adapter, RequestDict, ReplyDict)
```

`wrap_adapter/3` special-cases the atoms `scripted` and `mock` (and an
already-wrapped `scripted_adapter(_)` term), plus one more: `openai`,
which wraps to a complete, ready-to-use translation adapter for
OpenAI-compatible Chat Completions APIs (more on that below). Anything
else you supply passes straight through untouched. That means a fully
custom adapter for some *other* provider still needs **zero changes**
to `codex_harness.pl` -- you just write a goal and pass it as
`adapter(YourGoal)`.

## Prove that to yourself with a non-scripted adapter

This one isn't a real LLM either, but it *isn't* `scripted` -- it's an
ordinary user-defined predicate, which is the whole point: anything
callable works.

```prolog
shout_adapter(Request, _{content:Upper, tool_calls:[]}) :-
    last(Request.messages, LastMsg),
    string_upper(LastMsg.content, Upper).
```

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new([root('.'), adapter(shout_adapter)], H),
   harness_run(H, "hello there", Answer),
   format("~w~n", [Answer]).
```

You'll get back the *entire* first user message, uppercased --
including the gathered repository context from `gather_context/3`
(Lesson 2). That's not a bug in the example: it's proof that
`Request.messages` really does contain everything the model would see,
and that an adapter can be anything at all as long as it returns a
`{content, tool_calls}` dict.

## What a *real* provider adapter has to do

`http_json_adapter(Url, Request, Reply)` is a documented skeleton, not
a drop-in for any specific provider: it POSTs `Request` as JSON and
expects `{content, tool_calls}` JSON straight back -- i.e. it assumes
the far end already speaks this harness's own wire format.

For OpenAI-compatible Chat Completions APIs specifically -- OpenAI
itself, Azure OpenAI, or a self-hosted server speaking the same wire
format (vLLM, Ollama's `/v1` shim, LM Studio, ...) -- you don't have to
write this translation layer: `adapter(openai)` (`openai_chat_adapter/3`
in `codex_harness.pl`) already does it, and it's reachable both
in-process and, safely, over the REST API:

```prolog
?- harness_new([root('.'), adapter(openai), allow_network(true),
                adapter_url('https://api.openai.com/v1/chat/completions'),
                adapter_api_key("sk-...")], H),
   harness_run(H, "List the files in this repo", Answer).
```

```http
POST /harnesses
{"root": ".", "adapter": "openai", "allow_network": true,
 "adapter_api_key": "sk-...", "model": "gpt-4o-mini"}
```

Read `openai_chat_adapter/3` (and its helpers --
`openai_request_body/2`, `openai_message/2`, `openai_tool/2`,
`json_schema_of_params/2`, `openai_extract_message/2`) as a fully
worked example of the three steps every *other* provider's translation
adapter needs too (Anthropic's messages API, or anything else that
doesn't speak either wire format above):

1. Build the provider's request body from `Request.model`,
   `Request.instructions`, `Request.messages`, and `Request.tools`
   (field names and role conventions differ per provider -- check
   their docs). A detail that trips people up: several providers'
   tool-call APIs encode a call's `arguments` as a JSON-encoded
   *string*, not a ready-made object -- `openai_tool_call/2` shows how
   to produce that, and `normalize_call/2` (already in the harness)
   parses it back a second time on the way in via `ensure_dict/2`, so
   you don't have to write that half yourself.
2. Send the HTTP request with your API key attached. `openai_chat_adapter/3`
   stores the key in harness state (`adapter_api_key`) rather than
   capturing it in a closure, specifically because a REST-created
   harness has no way to receive a closure at all -- see the
   checkpoint below for why that's safe here (redaction + a snapshot
   allowlist) in a way that wouldn't be safe for, say, `approval`.
3. Translate the provider's response back into
   `_{content:Text, tool_calls:[_{id, name, arguments}]}` --
   `normalize_reply/2` already does the last mile of this (parsing
   `arguments` and defaulting a missing `id`), so your adapter only
   needs to get the provider's raw JSON into roughly that shape, the
   way `openai_extract_message/2` does for Chat Completions.

For a provider with no compatible shim at all, the pattern is the same
one this lesson always taught -- write a small goal and pass it as
`adapter(YourGoal)`:

```prolog
anthropic_style_adapter(ApiKey, Model, Request, Reply) :-
    build_provider_body(Model, Request, Body),
    http_post_with_auth(ApiKey, Body, RawReply),   % you write this
    translate_reply(RawReply, Reply).              % you write this
```

```prolog
harness_new([adapter(anthropic_style_adapter(ApiKey, "claude-...")), root('.')], H)
```

Here, capturing `ApiKey` as a closure argument (instead of a new
`harness_new/2` option) is still the right call: this adapter only
ever gets wired up by an in-process Prolog caller, so there's no REST
surface needing a plain-data option, and a closure keeps the key out
of `harness_snapshot/2` by construction rather than by remembering to
redact it.

## Checkpoint

1. Why does `wrap_adapter/3` need to special-case `scripted`/`mock`/
   `openai` at all, if "anything callable" already works as an
   adapter?
2. `openai_chat_adapter/3` stores its API key in harness state instead
   of capturing it in a closure like `anthropic_style_adapter/4` above
   does. What two things make that safe here, and why wouldn't the
   same reasoning justify storing, say, an `approval` callback in
   state and accepting it from REST JSON?
3. If a provider's tool-call `arguments` come back as a JSON string
   instead of an object, at which exact step in the translation above
   would you parse it -- and which existing harness predicate already
   does that step for you?
