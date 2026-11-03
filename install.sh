#!/usr/bin/env bash
# Install the /recall skill and the session indexer, and schedule the indexer
# (systemd user timer on Linux, launchd agent on macOS).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  --dev            symlink the skill to this checkout instead of copying it
  --model TAG      Ollama model for summaries (default: gemma4:e4b-it-q8_0)
  --num-ctx N      context size to request, for a tag that does not set its own
                   (default 32768; ignored when the tag sets num_ctx)
  --no-timer       install the skill and config but do not schedule the indexer
  --uninstall      remove the skill and the timer; keeps config and summaries
  -h, --help       show this help

Re-running is safe: skill files are replaced, an existing config is kept
(only --model / --num-ctx change it), and the timer is reloaded.
EOF
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$HOME/.claude/skills/recall"
CONF="$HOME/.config/claude-recall/config.json"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT=claude-recall-index
LABEL=local.claude-recall.index
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

DEV=0 TIMER=1 UNINSTALL=0 MODEL="" NUM_CTX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) DEV=1 ;;
    --model) MODEL="${2:?--model needs a tag}"; shift ;;
    --num-ctx) NUM_CTX="${2:?--num-ctx needs a number}"; shift ;;
    --no-timer) TIMER=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
OS="$(uname -s)"

remove_timer() {
  case "$OS" in
    Linux)
      if [ -f "$UNIT_DIR/$UNIT.timer" ]; then
        systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
        systemctl --user stop "$UNIT.service" 2>/dev/null || true
        rm -f "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT.service"
        systemctl --user daemon-reload 2>/dev/null || true
        say "removed systemd timer $UNIT"
      fi ;;
    Darwin)
      if [ -f "$PLIST" ]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        say "removed launchd agent $LABEL"
      fi ;;
  esac
}

if [ "$UNINSTALL" = 1 ]; then
  remove_timer
  if [ -L "$SKILL_DIR" ]; then rm "$SKILL_DIR"; say "removed skill symlink $SKILL_DIR"
  elif [ -d "$SKILL_DIR" ]; then rm -r "$SKILL_DIR"; say "removed skill $SKILL_DIR"; fi
  say "kept $CONF and the summaries in out_dir; delete them by hand if you want them gone"
  exit 0
fi

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || { echo "python3 not found" >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 8))' || { echo "python3 3.8+ required" >&2; exit 1; }
command -v rg >/dev/null || warn "ripgrep (rg) not found; the /recall skill's searches use it"

# --- skill -------------------------------------------------------------------
mkdir -p "$(dirname "$SKILL_DIR")"
if [ "$DEV" = 1 ]; then
  if [ -e "$SKILL_DIR" ] && [ ! -L "$SKILL_DIR" ]; then
    # Outside ~/.claude/skills, or Claude Code would load the backup as a second skill.
    BAK="$HOME/.claude/recall-skill.bak.$(date +%Y%m%d%H%M%S)"
    mv "$SKILL_DIR" "$BAK"
    say "moved existing skill aside to $BAK"
  fi
  ln -sfn "$REPO/skill" "$SKILL_DIR"
  say "linked $SKILL_DIR -> $REPO/skill"
else
  [ -L "$SKILL_DIR" ] && rm "$SKILL_DIR"
  mkdir -p "$SKILL_DIR/scripts"
  cp "$REPO/skill/SKILL.md" "$SKILL_DIR/"
  cp "$REPO/skill/scripts/"*.py "$SKILL_DIR/scripts/"
  say "copied skill to $SKILL_DIR"
fi
chmod +x "$REPO/skill/scripts/"*.py "$SKILL_DIR/scripts/"*.py

# --- config ------------------------------------------------------------------
mkdir -p "$(dirname "$CONF")"
if [ ! -f "$CONF" ]; then
  cp "$REPO/config.example.json" "$CONF"
  say "wrote $CONF"
  [ -n "$MODEL" ] || MODEL="$("$PYTHON" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$CONF")"
fi
if [ -n "$MODEL" ] || [ -n "$NUM_CTX" ]; then
  [ -n "$MODEL" ] || MODEL="$("$PYTHON" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$CONF")"
  # A tag that sets its own num_ctx must not be sent a different one: Ollama would
  # reload it, evicting the copy other tools share. A tag without one needs it,
  # or Ollama falls back to a small default and silently truncates input.
  TAG_CTX=""
  if command -v ollama >/dev/null; then
    TAG_CTX="$(ollama show --parameters "$MODEL" 2>/dev/null | awk '$1=="num_ctx"{print $2}' || true)"
  else
    warn "ollama CLI not found; cannot check whether $MODEL sets its own num_ctx"
  fi
  "$PYTHON" -I - "$CONF" "$MODEL" "$TAG_CTX" "${NUM_CTX:-32768}" <<'PY'
import json, sys
path, model, tag_ctx, want = sys.argv[1:]
cfg = json.load(open(path))
cfg["model"] = model
if tag_ctx:
    cfg.pop("num_ctx", None)
else:
    cfg["num_ctx"] = int(want)
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
print("==> config: model %s, num_ctx %s" % (model, "from the tag (%s)" % tag_ctx if tag_ctx else want))
PY
fi

# --- Ollama check (warn only) --------------------------------------------------
"$PYTHON" -I - "$CONF" <<'PY' || warn "Ollama check failed; the indexer will retry each run until it is reachable"
import json, sys, urllib.request
cfg = json.load(open(sys.argv[1]))
url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/")
tags = json.load(urllib.request.urlopen(url + "/api/tags", timeout=5))
names = {m.get("name") for m in tags.get("models", [])}
if cfg["model"] not in names:
    print("WARNING: model %s is not pulled; run: ollama pull %s" % (cfg["model"], cfg["model"]), file=sys.stderr)
else:
    print("==> Ollama reachable, %s present" % cfg["model"])
PY

# --- timer -------------------------------------------------------------------
if [ "$TIMER" = 0 ]; then
  say "skipping the timer (--no-timer); run the indexer by hand: $SKILL_DIR/scripts/session_index.py"
  exit 0
fi
fill() { sed -e "s#__PYTHON__#$PYTHON#g" -e "s#__HOME__#$HOME#g" "$1"; }
case "$OS" in
  Linux)
    if ! systemctl --user show-environment >/dev/null 2>&1; then
      warn "no systemd user session; schedule $SKILL_DIR/scripts/session_index.py yourself (cron, etc.)"
      exit 0
    fi
    mkdir -p "$UNIT_DIR"
    fill "$REPO/schedulers/$UNIT.service" > "$UNIT_DIR/$UNIT.service"
    fill "$REPO/schedulers/$UNIT.timer" > "$UNIT_DIR/$UNIT.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT.timer" >/dev/null
    say "systemd timer $UNIT enabled; logs: journalctl --user -u $UNIT.service"
    ;;
  Darwin)
    mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    fill "$REPO/schedulers/$UNIT.plist" > "$PLIST"
    plutil -lint "$PLIST" >/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    say "launchd agent $LABEL loaded; logs: ~/Library/Logs/$UNIT.log"
    ;;
  *)
    warn "unsupported OS $OS; schedule $SKILL_DIR/scripts/session_index.py yourself"
    ;;
esac

say "done. Preview what it would summarize: $SKILL_DIR/scripts/session_index.py --dry-run"
