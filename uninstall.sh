#!/usr/bin/env bash
# Uninstaller for the omarchy-ollama-cost Omarchy bar widget.
#
#   curl -fsSL https://raw.githubusercontent.com/neilmc81/omarchy-ollama-cost/main/uninstall.sh | bash
#
# Removes the bar entry, the plugin clone and cached data. API keys in
# ~/.config/ollama-cost are kept unless you say yes or pass --purge.
# ~/.hermes/.env is never touched.
set -euo pipefail

WIDGET_ID="ollama.cost"
REPO="${OLLAMA_COST_REPO:-https://github.com/neilmc81/omarchy-ollama-cost}"
OMARCHY_DIR="$HOME/.config/omarchy"
PLUGINS_DIR="${OMARCHY_PLUGINS_DIR:-$OMARCHY_DIR/plugins}"
PLUGIN_DIR="$PLUGINS_DIR/$WIDGET_ID"
SHELL_JSON="$OMARCHY_DIR/shell.json"
KEY_DIR="$HOME/.config/ollama-cost"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ollama-cost"

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
Usage: uninstall.sh [--yes] [--purge] [--no-restart]

  -y, --yes       don't ask; API keys are still kept
  --purge         also delete ~/.config/ollama-cost (your API keys)
  --no-restart    don't run `omarchy restart shell`

Env: OMARCHY_PLUGINS_DIR, OLLAMA_COST_REPO, OLLAMA_COST_NO_RESTART=1
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

# Remove every { "id": WIDGET_ID } entry from shell.json, after a backup.
# Prints a message; exit code 0 = changed, 10 = nothing to do, 3 = can't edit.
remove_from_shell_json() {
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

def strip_id(node):
    n = 0
    if isinstance(node, dict):
        for v in node.values():
            n += strip_id(v)
    elif isinstance(node, list):
        keep = [v for v in node if not (isinstance(v, dict) and v.get("id") == wid)]
        n += len(node) - len(keep)
        node[:] = keep
        for v in node:
            n += strip_id(v)
    return n

if not strip_id(data):
    print("not registered"); sys.exit(10)

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

unregister_widget() {
  say "Removing the widget from the bar"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; remove { \"id\": \"$WIDGET_ID\" } from $SHELL_JSON yourself"
    return
  fi
  local msg rc=0
  msg=$(remove_from_shell_json) || rc=$?
  case $rc in
    0)  ok "removed from shell.json (backup: $msg)" ;;
    10) ok "not in shell.json; nothing to change" ;;
    *)  warn "didn't touch shell.json: $msg" ;;
  esac
}

remove_plugin() {
  say "Removing $PLUGIN_DIR"
  if [ -L "$PLUGIN_DIR" ]; then
    warn "it's a symlink (→ $(readlink "$PLUGIN_DIR")); leaving it and its target alone"
  elif [ ! -e "$PLUGIN_DIR" ]; then
    ok "not installed; nothing to remove"
  elif ! command -v git >/dev/null 2>&1 || ! is_our_clone "$PLUGIN_DIR"; then
    warn "it isn't a git clone of $REPO; leaving it alone"
  elif [ -n "$(git -C "$PLUGIN_DIR" status --porcelain 2>/dev/null)" ]; then
    warn "it has local changes; leaving it alone (delete it yourself if you're sure)"
  else
    rm -rf -- "$PLUGIN_DIR"
    ok "removed"
  fi
}

remove_state() {
  say "Removing cached data"
  if [ -e "$STATE_DIR" ]; then
    rm -rf -- "$STATE_DIR"
    ok "removed $STATE_DIR"
  else
    ok "none found"
  fi
}

remove_keys() {
  say "API keys"
  if [ ! -e "$KEY_DIR" ]; then
    ok "none found in $KEY_DIR"
    return
  fi
  local answer=""
  if [ "$PURGE" = 1 ]; then
    answer=y
  elif [ "$YES" = 0 ] && have_tty; then
    printf '  Delete %s (your API keys)? [y/N] ' "$KEY_DIR" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi
  case $answer in
    y|Y|yes|YES)
      rm -rf -- "$KEY_DIR"
      ok "deleted $KEY_DIR" ;;
    *)
      ok "kept $KEY_DIR (delete it yourself, or re-run with --purge)" ;;
  esac
}

restart_shell() {
  if [ "$NO_RESTART" = 1 ] || [ "${OLLAMA_COST_NO_RESTART:-}" = 1 ]; then
    say "Skipping shell restart; run 'omarchy restart shell' to drop the widget"
  elif command -v omarchy >/dev/null 2>&1; then
    say "Restarting the Omarchy shell"
    omarchy restart shell </dev/null >/dev/null 2>&1 || warn "'omarchy restart shell' failed; run it yourself"
  fi
}

main() {
  YES=0 PURGE=0 NO_RESTART=0
  for arg in "$@"; do
    case $arg in
      -y|--yes)     YES=1 ;;
      --purge)      PURGE=1 ;;
      --no-restart) NO_RESTART=1 ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "unknown option: $arg (try --help)" ;;
    esac
  done

  unregister_widget
  remove_plugin
  remove_state
  remove_keys
  restart_shell
  printf '%sDone.%s The Ollama cost widget is uninstalled.\n' "$G" "$N"
}

# Everything runs from main so a `curl | bash` pipe is fully read before
# anything executes.
main "$@"
