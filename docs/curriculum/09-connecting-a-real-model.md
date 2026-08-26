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

`wrap_adapter/3` only special-cases the atoms `scripted` and `mock`
(and an already-wrapped `scripted_adapter(_)` term); literally
anything else you supply passes straight through untouched. That
means a "real" adapter needs **zero changes** to `codex_harness.pl` --
you just write a goal and pass it as `adapter(YourGoal)`.

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
the far end already speaks this harness's own wire format. A real
provider (OpenAI-style chat completions, Anthropic's messages API,
etc.) speaks *its own* JSON shape, so your adapter is a small
**translation layer**, not a pass-through:

1. Build the provider's request body from `Request.model`,
   `Request.instructions`, `Request.messages`, and `Request.tools`
   (field names and role conventions differ per provider -- check
   their docs). A detail that trips people up: several providers'
   tool-call APIs encode a call's `arguments` as a JSON-encoded
   *string*, not a ready-made object -- you'll need to parse it a
   second time on the way in.
2. Send the HTTP request yourself, with your API key attached however
   your closure captures it -- **never** put a credential in harness
   state (the `secrets` option is for *redacting* known strings from
   logs/output, not for storing keys).
3. Translate the provider's response back into
   `_{content:Text, tool_calls:[_{id, name, arguments}]}`.

```prolog
openai_style_adapter(ApiKey, Model, Request, Reply) :-
    build_provider_body(Model, Request, Body),
    http_post_with_auth(ApiKey, Body, RawReply),   % you write this
    translate_reply(RawReply, Reply).              % you write this
```

Wire it up exactly like any other adapter:

```prolog
harness_new([adapter(openai_style_adapter(ApiKey, "gpt-4o")), root('.')], H)
```

## Checkpoint

1. Why does `wrap_adapter/3` need to special-case `scripted`/`mock` at
   all, if "anything callable" already works as an adapter?
2. What's the one thing a real provider adapter must *never* do with
   the API key it's given, and why does that matter more for an
   adapter than for, say, a one-off script?
3. If a provider's tool-call `arguments` come back as a JSON string
   instead of an object, at which exact step in the translation above
   would you parse it?
