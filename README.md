# claude-recall

Cross-project recall for [Claude Code](https://claude.com/claude-code), plus a
local, token-free index of your past sessions.

Claude Code keeps memory per working directory, so a session in one repo can't
see what you worked out in another, and finding "the session where we fixed the
auth thing" means grepping gigabytes of transcripts. This repo has two parts:

- **`/recall` skill.** Searches the memory stores of *other* projects, the
  session index below, and (only when you ask) raw transcripts. It can also
  file a memory into a different project's store.
- **Session indexer.** Every 15 minutes, finds sessions that have grown and
  then gone idle, and has a **local Ollama model** summarize the new part into
  one markdown entry per session: directory, branch, dates, topics, tickets,
  decisions, and a ready-to-paste `claude --resume` command. Long-running
  sessions are updated incrementally, so it works even if you keep a session
  open for days.

No Claude API calls are made by the indexer, so it costs no tokens.

## Requirements

- Claude Code (reads `~/.claude/projects`)
- Python 3.8+ (standard library only)
- [Ollama](https://ollama.com) with a model pulled (default `gemma4:e4b-it-q8_0`)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`), used by the skill
- Linux with systemd, or macOS (launchd). Elsewhere, run the indexer from cron.

## Install

```bash
git clone <this repo> ~/src/claude-recall
cd ~/src/claude-recall
./install.sh                         # default model
./install.sh --model qwen3:8b        # or pick a model
```

The installer:

1. copies the skill to `~/.claude/skills/recall/`
   (`--dev` symlinks it to the checkout instead, for working on it),
2. writes `~/.config/claude-recall/config.json` if it doesn't exist,
3. checks Ollama is reachable and the model is pulled,
4. schedules the indexer: a systemd user timer on Linux
   (`claude-recall-index.timer`) or a launchd agent on macOS
   (`local.claude-recall.index`).

Re-running it is safe. To update, `git pull && ./install.sh`.

Before the first scheduled run, see what it would send to the model:

```bash
~/.claude/skills/recall/scripts/session_index.py --dry-run
```

Index older sessions on demand (the timer only looks back `lookback_days`):

```bash
~/.claude/skills/recall/scripts/session_index.py --backfill --limit 20
```

## Configuration

`~/.config/claude-recall/config.json` (or `$CLAUDE_RECALL_CONFIG`):

| Key | Default | Meaning |
|---|---|---|
| `ollama_url` | `http://localhost:11434` | Ollama server |
| `model` | `gemma4:e4b-it-q8_0` | Model tag used for summaries |
| `num_ctx` | `32768` | Context size to request. **Omit it** if your tag sets its own `num_ctx`: sending a different one makes Ollama reload the model, evicting a copy other tools are using. Without it, Ollama's small default silently truncates input; the indexer detects that and refuses to save the summary. `install.sh` sets this for you. |
| `idle_minutes` | `60` | A session must be idle this long before it's summarized |
| `lookback_days` | `2` | Ignore transcripts untouched for longer (use `--backfill`) |
| `max_chunk_chars` | `60000` | New text is sent in chunks of this size |
| `max_sessions_per_run` | `5` | Bounds how long one run takes |
| `min_new_chars` | `300` | Smaller increments wait until more accumulates |
| `out_dir` | `~/notes/claude-sessions` | Where entries, `INDEX.md` and state live |

Larger models write noticeably better summaries of long sessions; a 2B model
tends to forget the early part of a multi-day session.

While it is summarizing, each run writes
`~/.local/state/claude-recall/indexer-<pid>.json` (session id, dir, chunk
`n` of `m`, model) and removes it on exit, so a dashboard or status line can
show that extraction is running. Ignore a file whose pid is no longer alive.

## What gets sent to the model, and what's stored

The indexer reads transcripts from `~/.claude/projects/*/*.jsonl` and sends
**only** your messages, Claude's prose replies, and short tool descriptions.
Tool output (file contents, command output, query results) is never sent,
which is most of the transcript volume and most of its sensitive data. The
model is told to record topics and decisions, never values or secrets, but it
is a small model: treat the entries as pointers back to sessions, not as
facts, and keep `out_dir` private. Nothing leaves your machine unless
`ollama_url` points elsewhere.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the skill and the timer. Your config and `out_dir` are kept; delete
them by hand if you want them gone.

## License

MIT
