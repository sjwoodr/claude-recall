---
name: recall
description: >-
  Search and read Claude Code memory stores belonging to OTHER projects, which
  a session cannot otherwise see because memory is siloed per working
  directory. Use when the user asks what you remember about another project,
  refers to work done elsewhere ("the billing service thing", "how did I solve
  this in the CLI repo"), wants memories listed across projects, or asks to
  save a memory into a different project's store than the current one. Also
  searches the per-session index (~/notes/claude-sessions) for "which session
  was the X thing in / how do I get back to it".
---

# recall — cross-project memory access

Claude Code keys file memory to a slugified cwd, so `~/src/billing-service` and
`~/src/cli-tool` have entirely separate stores and neither session sees the
other. Automatic recall (the memories that arrive in `<system-reminder>`
blocks) only ever draws on the current directory's store. This skill reaches
the rest deliberately.

## 1. Find the stores

Always enumerate from disk. Never work from a hardcoded list — new stores
appear whenever Claude is started in a new directory. (Use `rg` for every
corpus search below; the `grep -c` in the loop is a pipe filter, not a search,
where `rg` buys nothing.)

```bash
for d in ~/.claude/projects/*/memory/; do
  s=$(basename "$(dirname "$d")")
  n=$(ls "$d" 2>/dev/null | grep -c '\.md$')
  [ "$n" -gt 0 ] && printf "%-50s %3s files\n" "$s" "$n"
done
```

The slug is the absolute path with `/` and `.` replaced by `-`, so
`-home-alex-src-billing-service` is `~/src/billing-service` (dashes in names
make the reverse mapping ambiguous; check the disk when it matters). Convert
back when reporting: say "billing-service", not the slug.

## 2. Search

Two stages, cheapest first.

Each store has a `MEMORY.md` index with one line per memory. Grep those to see
which stores are relevant at all:

```bash
rg -li "<topic>" ~/.claude/projects/*/memory/MEMORY.md
```

Then search the memory bodies for actual hits:

```bash
rg -li "<topic>" ~/.claude/projects/*/memory/ | rg -v '/MEMORY\.md$'
```

Read only the files that matched. Do not bulk-read a whole store: a busy
project's store can hold close to a hundred files, and pulling all of it in
defeats the point of the memory being on-demand.

If the topic is vague, search the `description:` frontmatter lines instead,
which is what the indexes are for:

```bash
rg -N "^description:" ~/.claude/projects/*/memory/*.md
```

## 2a. Session index — search with memory, before transcripts

`scripts/session_index.py` runs on a timer (systemd on Linux, launchd on
macOS) and keeps one short entry per session in `~/notes/claude-sessions/<id>.md`
(the `out_dir` in `~/.config/claude-recall/config.json`), summarized by a
local Ollama model from the transcript with tool output left out, plus
`INDEX.md`. Each entry has the dir, branch, dates and a `claude --resume`
command. Use it for "which session was the X thing in?":

```bash
rg -li "<topic>" ~/notes/claude-sessions/*.md
```

Read only matching entries. A small local model wrote them: treat an entry as a
pointer to the session, not as fact, and say so when quoting one. Hand the user
the `Resume:` line rather than reading the transcript yourself. Sessions active
within the last hour (`idle_minutes`) are not in it yet. If the directory does
not exist, the indexer is not installed; skip this step.

## 2b. Transcripts — opt-in only

Memory stores are curated. **Session transcripts** are the raw record, and they
live NEXT TO the memory dirs, not inside them:

```
~/.claude/projects/<slug>/memory/*.md     <- searched by default (above)
~/.claude/projects/<slug>/*.jsonl         <- NOT searched by default
```

The corpus is large (often hundreds of MB to GBs) and a single JSONL line can
be megabytes of tool output, so pulling content from it costs real context.
**Do not read transcript content unless the user asks.**

But a memory miss should not dead-end, because the user often does not know a
transcript exists. So when memory comes up empty, run the **cheap probe only** —
file names and dates, no content extracted:

```bash
~/.claude/skills/recall/scripts/search-transcripts.py '<regex>' --files-only
```

That is one line per matching transcript. Report it as an offer:

> Nothing in memory. 2 transcripts mention this (cli-tool, 2026-08-23).
> Want me to pull the details?

Only on a yes — or when the user asked for transcripts up front — extract:

```bash
~/.claude/skills/recall/scripts/search-transcripts.py '<regex>' --limit 12
```

The script prints only **user messages** (which carry the intent and are usually
the story you want) and **tool_use commands** (what was actually done). It never
prints raw JSONL. Results are newest-first. `--context` widens to all commands
in a matching transcript rather than only matching ones.

Never `cat`, `head`, or Read a `.jsonl` directly. One line can blow the context
window on its own.

## 3. Report

Always attribute the store. "This is from cli-tool" is half the answer,
because a fact true in one project may be false in another.

Distinguish the current store from the others. Memories from the current
project may already be in context via automatic recall, so leading with those
is usually redundant; the value here is what came from elsewhere.

Memories record what was true when written. If one names a file, command or
flag, verify it still exists before recommending it — especially across
projects, where you have less surrounding context to catch a stale claim.

## 4. Writing into another store

To save a memory into a project other than the current one, write it to that
project's directory and add its pointer line to that store's `MEMORY.md`:

```
~/.claude/projects/<target-slug>/memory/<type>_<slug>.md
~/.claude/projects/<target-slug>/memory/MEMORY.md
```

Match the target store's own conventions rather than the current one's — file
naming prefixes and index section headings differ between them. Read a couple
of the target's existing files first.

Be explicit with the user about which store you wrote to. A memory filed in
the wrong project is worse than not filing it, because it will surface as
context in a session where it does not apply.

## Limits, worth stating plainly

This is a search, not ambient memory. It makes other stores reachable when
asked; it cannot make them surface on their own. If the user wants genuinely
ambient cross-project recall, the honest answer is that the file-based store
does not do that, and an MCP memory server is the construct that would.
