#!/usr/bin/env python3
"""Search Claude Code session transcripts (~/.claude/projects/<slug>/*.jsonl).

Transcripts are the fallback when the curated memory/ stores miss. They are
large (hundreds of MB) and a single JSONL line can be megabytes of tool output,
so this NEVER prints raw lines. It extracts only:

  - user messages     (state intent; usually the story you want)
  - tool_use commands (what was actually done)

Usage:
  search-transcripts.py <regex> [--limit N] [--context] [--files-only]
"""
import argparse, glob, json, os, re, sys

def transcript_roots():
    """~/.claude/projects, then other config dirs' (~/.claude-*/projects, from CLAUDE_CONFIG_DIR)."""
    roots = [os.path.expanduser("~/.claude/projects")]
    roots += sorted(glob.glob(os.path.expanduser("~/.claude-*/projects")))
    return [r for r in roots if os.path.isdir(r)]


def transcripts():
    """Every transcript once: a copy of the same slug/file in a later root is skipped."""
    seen, out = set(), []
    for root in transcript_roots():
        for p in glob.glob(os.path.join(root, "*", "*.jsonl")):
            rel = os.path.relpath(p, root)
            if rel not in seen:
                seen.add(rel)
                out.append(p)
    return out


HOME_SLUG = re.sub(r"[/.]", "-", os.path.expanduser("~"))


def slug_to_path(slug):
    # Approximate: the slug turned "/" and "." into "-", so dashes in names can't be told apart.
    return "~" + slug[len(HOME_SLUG):].replace("-", "/") if slug.startswith(HOME_SLUG) else slug


def scan(path, pat, limit, want_context):
    users, cmds = [], []
    try:
        fh = open(path, errors="replace")
    except OSError:
        return users, cmds
    with fh:
        for line in fh:
            if not pat.search(line):          # cheap reject before JSON parse
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            msg = d.get("message") or {}
            ts = (d.get("timestamp") or "")[:16].replace("T", " ")
            content = msg.get("content")

            if d.get("type") == "user":
                text = content
                if isinstance(text, list):
                    text = " ".join(b.get("text", "") for b in text
                                    if isinstance(b, dict) and b.get("type") == "text")
                if isinstance(text, str) and text.strip() and not text.lstrip().startswith("<"):
                    if pat.search(text):
                        users.append((ts, " ".join(text.split())[:400]))

            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        c = (b.get("input") or {}).get("command") or ""
                        if c and (pat.search(c) or want_context):
                            cmds.append((ts, " ".join(c.split())[:300]))
    return users[:limit], cmds[:limit]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pattern")
    ap.add_argument("--limit", type=int, default=12)
    ap.add_argument("--context", action="store_true",
                    help="include all commands from matching transcripts, not just matching ones")
    ap.add_argument("--files-only", action="store_true")
    a = ap.parse_args()

    pat = re.compile(a.pattern, re.I)
    files = sorted(transcripts(),
                   key=lambda p: os.path.getmtime(p), reverse=True)
    if not files:
        print("  no transcripts found"); return

    # Candidate files: rg is ~4.5x faster than a Python scan over ~400 MB.
    # Fall back to reading in-process if rg is unavailable.
    import shutil, subprocess
    candidates = None
    if shutil.which("rg"):
        try:
            r = subprocess.run(["rg", "-l", "-i", a.pattern, *transcript_roots(), "-g", "*.jsonl"],
                               capture_output=True, text=True, timeout=120)
            candidates = set(r.stdout.split())
        except Exception:
            candidates = None

    hits = 0
    for path in files:
        slug = os.path.basename(os.path.dirname(path))
        if candidates is not None:
            if path not in candidates:
                continue
        else:
            try:
                with open(path, errors="replace") as fh:
                    if not any(pat.search(l) for l in fh):
                        continue
            except OSError:
                continue
        hits += 1
        mt = __import__("datetime").datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")
        size = os.path.getsize(path) / 1048576
        print("\n=== %s  [%s]  %.1f MB  last %s" % (os.path.basename(path), slug_to_path(slug), size, mt))
        print("    %s" % path)
        if a.files_only:
            continue
        users, cmds = scan(path, pat, a.limit, a.context)
        if users:
            print("  --- user messages (%d) ---" % len(users))
            for ts, t in users:
                print("    [%s] %s" % (ts, t))
        if cmds:
            print("  --- commands (%d) ---" % len(cmds))
            for ts, c in cmds:
                print("    $ %s" % c)
        if not users and not cmds:
            print("  (matched only inside tool output; refine the pattern)")

    if not hits:
        print("  no transcript matched /%s/" % a.pattern)
    else:
        print("\n  %d transcript(s) matched, newest first" % hits)


if __name__ == "__main__":
    main()
