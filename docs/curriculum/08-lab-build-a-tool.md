# 8. Lab: Build a Tool

Goal: add a brand-new, read-only, stateless tool end-to-end -- the
minimum four edits every tool in this codebase needs -- and prove it
works with a test. This mirrors `FEATURE_GUIDE.md` §3, written here as
a step-by-step you can actually follow along with.

We'll build `word_count`: given a path, return how many whitespace-
separated words are in it.

## The four edits

All in `prolog/coplex/codex_harness.pl`.

**1. Advertise it** -- add to `harness_tool_specs/1`, next to
`subagents`:

```prolog
spec(word_count, read_only, "Count words in a UTF-8 text file.",
     _{path:string})
```

**2. Route it** -- add to the `dispatch_tool/5` table:

```prolog
dispatch_tool(word_count, _, S, A, R)       :- tool_word_count(S, A, R).
```

**3. Implement it** -- next to `tool_make_directory/3`, following the
same shape every read-only file tool already uses (`safe_resolve/3`
for the path fence, `catch/3` + `fail_err/3` for a clean error shape):

```prolog
tool_word_count(S, A, R) :-
    flex_get(path, A, Rel, ""),
    catch((safe_resolve(S, Rel, Abs),
           (   exists_file(Abs)
           ->  read_file_to_string(Abs, Text, [encoding(utf8)]),
               split_string(Text, " \t\n", " \t\n", Parts0),
               exclude(==(""), Parts0, Parts),
               length(Parts, N),
               R = _{ok:true, tool:word_count, path:Rel, words:N}
           ;   R = _{ok:false, tool:word_count,
                     error:_{type:not_found, message:"File does not exist"}}
           )),
          E, fail_err(word_count, E, R)).
```

**4. Test it** -- add a test to `test/test_codex_harness.pl` (or a
scratch file), following the file's existing pattern: `with_h/2` calls
a named helper predicate with the harness appended as its last
argument (see `run_eq/3`, `call_tool/3` in that file for the same
style):

```prolog
test(word_count_basic) :-
    tmp_repo(Dir),
    setup_call_cleanup(
        true,
        with_h([root(Dir), adapter(scripted)], word_count_check),
        cleanup_repo(Dir)).

word_count_check(H) :-
    harness_tool(H, write_file, _{path:"words.txt", content:"a b c d"}, _),
    harness_tool(H, word_count, _{path:"words.txt"}, R),
    assertion(R.ok == true),
    assertion(R.words == 4).
```

## Try it directly (bypassing the model entirely)

`harness_tool/4` calls a tool without any model involved -- useful for
exactly this kind of manual check:

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new([root('.'), adapter(scripted)], H),
   harness_tool(H, write_file, _{path:"scratch/sample.txt",
                                  content:"one two three\nfour five\n"}, _),
   harness_tool(H, word_count, _{path:"scratch/sample.txt"}, R),
   format("~p~n", [R]).
```

Expect `words:5`. Try a path that doesn't exist and confirm you get a
clean `not_found` error rather than a Prolog exception escaping to the
top level -- that's `fail_err/3` doing its job, converting whatever
`safe_resolve/3` or `read_file_to_string/3` might throw into the same
`{ok:false, tool:..., error:{type, message}}` shape every other tool
uses.

## Now make the *model* use it

Give it a scripted reply that calls your new tool, and run it through
the real loop instead of `harness_tool/4` directly:

```prolog
?- harness_new(
     [ root('.'), adapter(scripted),
       mock_replies([
           _{content:"Counting words.",
             tool_calls:[_{id:"c1", name:word_count,
                            arguments:_{path:"scratch/sample.txt"}}]},
           _{content:"It has five words.", tool_calls:[]}
       ])
     ], H2),
   harness_run(H2, "How many words are in sample.txt?", Answer).
```

If this works, you've independently confirmed everything from Lessons
1-3: the tool shows up in the catalog `call_model/3` sends, the model
(scripted, here) can request it by name, `dispatch_tool/5` finds it,
and the result comes back as a new message.

## Checkpoint

1. Why does `tool_word_count/3` follow the exact same `catch/3` +
   `fail_err/3` shape as every other read-only tool, instead of just
   letting a missing-file exception propagate?
2. What would you have to change if you wanted `word_count` to also
   accept a directory and sum words across every file in it?
3. Is `word_count` correctly classified as `read_only`? What in the
   permission model (Lesson 3, and
   [`../03-tools-and-permissions.md`](../03-tools-and-permissions.md))
   would change if it were misclassified as `write`?
