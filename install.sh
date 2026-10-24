#!/usr/bin/env bash
# Installer for the omarchy-ollama-cost Omarchy bar widget.
#
#   curl -fsSL https://raw.githubusercontent.com/neilmc81/omarchy-ollama-cost/main/install.sh | bash
#
# Pass options through the pipe with `| bash -s -- --no-restart`; see usage().
# OLLAMA_COST_REPO / OLLAMA_COST_REF pick the source to clone (a local path
# works too, for testing).
set -euo pipefail

WIDGET_ID="ollama.cost"
REPO="${OLLAMA_COST_REPO:-https://github.com/neilmc81/omarchy-ollama-cost}"
REF="${OLLAMA_COST_REF:-main}"
OMARCHY_DIR="$HOME/.config/omarchy"
PLUGINS_DIR="${OMARCHY_PLUGINS_DIR:-$OMARCHY_DIR/plugins}"
PLUGIN_DIR="$PLUGINS_DIR/$WIDGET_ID"
SHELL_JSON="$OMARCHY_DIR/shell.json"
KEY_DIR="$HOME/.config/ollama-cost"
CONF_FILE="$KEY_DIR/conf.json"

if [ -t 1 ]; then
  B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'
else
  B="" G="" Y="" R="" N=""
fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

have_tty() { (exec </dev/tty) 2>/dev/null; }

usage() {
  cat <<'EOF'
Usage: install.sh [--no-prompt] [--no-register] [--no-restart] [--no-verify]

  --no-prompt     don't ask for an API key (also skipped with no terminal)
  --no-register   don't add the widget to ~/.config/omarchy/shell.json
  --no-restart    don't run `omarchy restart shell`
  --no-verify     don't fetch your usage once to check the key

Env: OLLAMA_API_KEY / OLLAMA_KEY (saved to ~/.config/ollama-cost/conf.json
     if no key is configured yet), OLLAMA_COST_REPO, OLLAMA_COST_REF,
     OMARCHY_PLUGINS_DIR, OLLAMA_COST_NO_RESTART=1, OLLAMA_COST_NO_PROMPT=1
EOF
}

# True if $1 is a real directory (not a symlink) that is the top of a git
# clone of this repo.
is_our_clone() {
  local d=$1 top url
  [ ! -L "$d" ] && [ -d "$d" ] || return 1
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$d" && pwd -P)" = "$top" ] || return 1
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || return 1
  url=${url%/}; url=${url%.git}
  case "$url" in
    "${REPO%/}" | "${REPO%.git}" | *[/:]neilmc81/omarchy-ollama-cost) return 0 ;;
  esac
  return 1
}

# True if update.py would find a key in any of its file sources (conf.json,
# the key file, ~/.hermes/.env). Asks update.py itself so the rules match.
key_on_disk() {
  [ -f "$PLUGIN_DIR/update.py" ] || return 1
  env -u OLLAMA_API_KEY -u OLLAMA_KEY python3 -I - "$PLUGIN_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import update
sys.exit(0 if update.load_keys(update.load_conf()) else 1)
PY
}

# Store $1 as "api_key" in conf.json (mode 600), keeping any other settings
# already in the file. The key goes through the environment, not argv, so it
# never shows up in `ps`.
save_key() {
  OLLAMA_COST_NEW_KEY=$1 python3 -I - "$CONF_FILE" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
key = os.environ["OLLAMA_COST_NEW_KEY"]
conf = {}
try:
    with open(path) as f:
        j = json.load(f)
    if isinstance(j, dict):
        conf = j
except FileNotFoundError:
    pass
except (OSError, ValueError):
    shutil.copy2(path, "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S")))
conf["api_key"] = key
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(conf, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

# Add the widget to bar.layout.right in shell.json unless an entry with its id
# exists anywhere. Prints a message; exit code 0 = changed (prints the backup
# path), 10 = nothing to do, 3 = can't edit safely.
add_to_shell_json() {
  python3 -I - "$SHELL_JSON" "$WIDGET_ID" <<'PY'
import json, os, shutil, sys, tempfile, time
path, wid = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    data = json.loads(text)
except FileNotFoundError:
    print("%s not found" % path); sys.exit(3)
except (OSError, ValueError) as e:
    print("%s could not be parsed (%s)" % (path, e)); sys.exit(3)

def has_id(node):
    if isinstance(node, dict):
        return node.get("id") == wid or any(has_id(v) for v in node.values())
    if isinstance(node, list):
        return any(has_id(v) for v in node)
    return False

if has_id(data):
    print("already registered"); sys.exit(10)
bar = data.get("bar") if isinstance(data, dict) else None
layout = bar.get("layout") if isinstance(bar, dict) else None
if not isinstance(layout, dict) or not isinstance(layout.setdefault("right", []), list):
    print("unexpected structure (no bar.layout.right list)"); sys.exit(3)
layout["right"].insert(0, {"id": wid})

# Keep the file's indentation style and trailing newline.
indent = 2
for line in text.splitlines()[1:]:
    ws = line[:len(line) - len(line.lstrip())]
    if ws:
        indent = "\t" if ws[0] == "\t" else len(ws)
        break
out = json.dumps(data, indent=indent, ensure_ascii=False) + ("\n" if text.endswith("\n") else "")

backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
i = 1
while os.path.exists(backup):
    backup = "%s.bak-%s-%d" % (path, time.strftime("%Y%m%d-%H%M%S"), i); i += 1
shutil.copy2(path, backup)

real = os.path.realpath(path)  # write through a symlinked shell.json
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".shell.json.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(out)
shutil.copymode(real, tmp)
os.replace(tmp, real)
print(backup)
PY
}

print_snippet() {
  cat <<EOF
     Add it yourself to $SHELL_JSON under "bar" → "layout" → "right":
         { "id": "$WIDGET_ID" }
     then run: omarchy restart shell
EOF
}

install_plugin() {
  say "Installing plugin to $PLUGIN_DIR"
  if [ -L "$PLUGIN_DIR" ]; then
    warn "it's a symlink (→ $(readlink "$PLUGIN_DIR")); leaving it alone"
  elif [ -e "$PLUGIN_DIR" ]; then
    if is_our_clone "$PLUGIN_DIR"; then
      if git -C "$PLUGIN_DIR" pull --ff-only --quiet </dev/null; then
        ok "updated to $(git -C "$PLUGIN_DIR" describe --tags --always 2>/dev/null)"
      else
        warn "git pull --ff-only failed (local changes?); keeping the current version"
      fi
    else
      warn "it already exists and isn't a git clone of $REPO; leaving it alone"
    fi
  else
    mkdir -p "$PLUGINS_DIR"
    GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$REF" "$REPO" "$PLUGIN_DIR" </dev/null \
      || die "git clone of $REPO ($REF) failed"
    ok "cloned $REPO ($REF)"
  fi
}

# Light format check only: a key that fails it is still saved.
key_looks_ok() { [ ${#1} -ge 20 ] && [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }

setup_key() {
  say "API key"
  local later="add one later: re-run this installer, or put it in $KEY_DIR/key (chmod 600)"
  if key_on_disk; then
    ok "already configured (conf.json, key file or ~/.hermes/.env); leaving it alone"
    return
  fi
  local key="${OLLAMA_API_KEY:-${OLLAMA_KEY:-}}" from="environment"
  key=${key//[[:space:]]/}
  if [ -z "$key" ]; then
    if [ "$NO_PROMPT" = 1 ] || ! have_tty; then
      warn "no API key yet, the widget will show ⚠; $later"
      return
    fi
    printf '  Create one at https://ollama.com/settings/keys. One key is enough:\n' >/dev/tty
    printf '  Ollama reports usage for the whole account, whichever key you use.\n' >/dev/tty
    printf '  Paste your Ollama API key (press Enter to skip): ' >/dev/tty
    IFS= read -rs key </dev/tty || key=""
    printf '\n' >/dev/tty
    key=${key//[[:space:]]/}
    from="prompt"
    if [ -z "$key" ]; then
      warn "skipped, the widget will show ⚠; $later"
      return
    fi
  fi
  key_looks_ok "$key" ||
    warn "that doesn't look like an Ollama API key (too short or odd characters); saving it anyway"
  save_key "$key"
  ok "saved the key from the $from to $CONF_FILE (mode 600)"
}

register_widget() {
  say "Registering the widget in the bar"
  local msg rc=0
  msg=$(add_to_shell_json) || rc=$?
  case $rc in
    0)  ok "added { \"id\": \"$WIDGET_ID\" } to bar → layout → right"
        ok "backup: $msg" ;;
    10) ok "already in shell.json; nothing to change" ;;
    *)  warn "didn't touch shell.json: $msg"
        print_snippet ;;
  esac
}

verify_key() {
  say "Checking the key with Ollama"
  if [ "$NO_VERIFY" = 1 ]; then
    ok "skipped (--no-verify)"
    return
  fi
  if [ ! -f "$PLUGIN_DIR/update.py" ]; then
    warn "no update.py in $PLUGIN_DIR; skipping"
    return
  fi
  local out rc=0
  out=$(timeout 90 python3 "$PLUGIN_DIR/update.py" </dev/null 2>&1) || rc=$?
  local last=${out##*$'\n'}
  last=${last#ollama-cost: }
  if [ $rc -eq 0 ]; then
    ok "it works: fetched your plan usage"
  elif [[ $last == "no API key found"* ]]; then
    warn "no key configured yet; the widget will show ⚠"
  else
    warn "couldn't fetch data yet (${last:-exit $rc}); the widget will show ! until this is fixed"
  fi
}

restart_shell() {
  if [ "$NO_RESTART" = 1 ] || [ "${OLLAMA_COST_NO_RESTART:-}" = 1 ]; then
    say "Skipping shell restart; run 'omarchy restart shell' to load the widget"
  elif command -v omarchy >/dev/null 2>&1; then
    say "Restarting the Omarchy shell"
    omarchy restart shell </dev/null >/dev/null 2>&1 || warn "'omarchy restart shell' failed; run it yourself"
  else
    say "Restart the Omarchy shell to load the widget"
  fi
}

main() {
  NO_REGISTER=0 NO_RESTART=0 NO_VERIFY=0
  NO_PROMPT=0; [ "${OLLAMA_COST_NO_PROMPT:-}" = 1 ] && NO_PROMPT=1
  for arg in "$@"; do
    case $arg in
      --no-prompt)   NO_PROMPT=1 ;;
      --no-verify)   NO_VERIFY=1 ;;
      --no-register) NO_REGISTER=1 ;;
      --no-restart)  NO_RESTART=1 ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "unknown option: $arg (try --help)" ;;
    esac
  done

  command -v git >/dev/null 2>&1     || die "git is required (sudo pacman -S git)"
  command -v python3 >/dev/null 2>&1 || die "python3 is required (sudo pacman -S python)"
  [ -d "$OMARCHY_DIR" ] || die "$OMARCHY_DIR not found; this widget needs Omarchy (https://omarchy.org)"

  install_plugin
  setup_key
  if [ "$NO_REGISTER" = 1 ]; then
    say "Skipping registration (--no-register)"
    print_snippet
  else
    register_widget
  fi
  verify_key
  restart_shell
  printf '%sDone.%s Click the Ollama icon in the bar for plan usage and the reset date.\n' "$G" "$N"
}

# Everything runs from main so a `curl | bash` pipe is fully read before
# anything executes.
main "$@"
