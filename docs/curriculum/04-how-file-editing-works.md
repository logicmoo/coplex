# 4. How File Editing Works

A coding agent's most important capability is also the most dangerous
one: changing files. This lesson covers the two strategies real agents
use, why the harness offers both, and the safety properties that make
each one trustworthy enough to run unattended.

## Strategy 1: whole-file rewrite (`write_file`)

The simplest possible editing tool: the model sends the **complete new
file content**, and the harness writes it. `tool_write_file/3` does
exactly that, but with one safety detail worth noticing --
`atomic_write/2` never writes to the real path directly:

```prolog
atomic_write(Abs, Content) :-
    atom_concat(Abs, '.tmp-harness', Tmp),
    setup_call_cleanup(
        open(Tmp, write, Out, [encoding(utf8)]),
        write(Out, Content),
        close(Out)),
    (   exists_file(Abs) -> delete_file(Abs) ; true ),
    rename_file(Tmp, Abs).
```

It writes to a temp file first, then **renames** it over the real
path. A single-file rename on the same filesystem is atomic on both
POSIX and Windows -- there's no instant in time where a reader (or a
crash) could observe a half-written file. This pattern (write to a
temp file, then rename) is worth remembering generally: it's the
standard way to make "replace this file" crash-safe in *any* language,
not just here.

Whole-file rewrite is simple and always correct -- but it means
resending the *entire* file's content through the model every time,
even to fix one line. For a 2,000-line file, that's thousands of
wasted tokens, slower, and -- because the model has to reproduce
everything byte-for-byte except the part it means to change -- it's an
easy way to accidentally introduce a subtle diff (dropped trailing
whitespace, a "helpfully" fixed unrelated line, truncation if the
model runs out of room).

## Strategy 2: patch/diff editing (`apply_patch`)

This is why every major coding agent (Codex CLI, Copilot's coding
agent, Claude Code, and this harness) prefers a **patch-based** edit
tool for anything beyond a brand-new file: the model sends only the
*changed* lines, in unified-diff form, with a little surrounding
context:

```diff
--- a/greet.py
+++ b/greet.py
@@ -1,3 +1,3 @@
 def greet(name):
-    print("Hi " + name)
+    print(f"Hello, {name}!")
 greet("world")
```

`tool_apply_patch/3` parses this (`split_patch_files/2`,
`patch_files//1`) into per-file hunks, each with a starting line number
and a body of ` ` (context), `-` (remove), and `+` (add) lines.

### Hunks are verified, not just trusted

`apply_one_hunk/4` doesn't just blindly insert/delete at the given line
number -- for every context (` `) or removed (`-`) line, it *unifies*
the patch's line text against the actual next line of the file
(`consume_body/4`: `Rest = [Text|Rest1]`). If they don't match --
because the file has since changed, the model miscounted, or it
invented context that isn't really there -- unification fails, the
hunk fails, and it's rejected rather than silently mis-applied
somewhere else in the file.

### All-or-nothing, across the whole patch

A patch can touch several files, each with several hunks.
`apply_unified_patch/3` runs *every* file's hunks first as a dry-run
preview (`preview_one_file/3`) before writing anything at all. If even
one hunk in one file fails, **the entire patch is rejected and nothing
is written** -- not even the files whose own hunks were perfectly
fine. This is the same idea as a database transaction: partial
success would leave the repository in a state nobody asked for and
nobody can easily reconstruct, so the harness simply refuses to leave
things half-done.

## Try it yourself

```prolog
?- [prolog/coplex/codex_harness].
?- harness_new([root('.'), adapter(scripted), allow_shell(true)], H).
?- harness_tool(H, write_file, _{path:"scratch/greet.py",
                                  content:"def greet(name):\n    print(\"Hi \" + name)\ngreet(\"world\")\n"}, _).
?- Patch = "--- a/scratch/greet.py\n+++ b/scratch/greet.py\n@@ -1,3 +1,3 @@\n def greet(name):\n-    print(\"Hi \" + name)\n+    print(f\"Hello, {name}!\")\n greet(\"world\")\n",
   harness_tool(H, apply_patch, _{patch:Patch}, Result1).
?- harness_tool(H, read_file, _{path:"scratch/greet.py"}, Result2).
```

`Result1` should be `_{ok:true, tool:apply_patch, files:[_{ok:true,
path:"scratch/greet.py", hunks:1}]}` and `Result2.content` should show
the `f"Hello, {name}!"` line. Now break it: change the second `-` line
in `Patch` to something that *doesn't* match the file (e.g.
`-    print("wrong text")`) and re-run `apply_patch`. You should get
`ok:false` with a `patch_rejected` error, **and `read_file` afterward
should show the file completely unchanged** -- prove that to yourself
before moving on.

## Checkpoint

1. Why does `apply_one_hunk/4` check the *content* of context/removed
   lines instead of just trusting the line number the patch supplies?
2. If a patch touches three files and only the third file's hunk
   fails, what happens to the first two files' changes?
3. When would you reach for `write_file` instead of `apply_patch`?
   (Hint: think about brand-new files.)
