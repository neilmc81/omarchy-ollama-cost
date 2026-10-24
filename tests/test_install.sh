#!/usr/bin/env bash
# Tests for the API key step of install.sh. Every run uses a throwaway HOME
# and a fake key, so your real config is never read or changed. Nothing is
# fetched from Ollama (--no-verify) and the shell isn't restarted.
#
#   bash tests/test_install.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/install.sh"
REF=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
FAKE="fake0123456789abcdef0123456789ab.FAKEKEYFORTESTS"
PASS=0 FAIL=0
TMPS=()
trap 'rm -rf "${TMPS[@]}"' EXIT

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$OUT"; fi; }

new_home() {
  H=$(mktemp -d); TMPS+=("$H")
  mkdir -p "$H/.config/omarchy"
  printf '{\n  "bar": {\n    "layout": {\n      "right": []\n    }\n  }\n}\n' >"$H/.config/omarchy/shell.json"
  CONF="$H/.config/ollama-cost/conf.json"
}

# The saved key (or "" if none), read from conf.json.
saved() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("api_key",""))' "$CONF" 2>/dev/null; }

run_notty() {
  OUT=$(env -i PATH="$PATH" HOME="$H" "$@" OLLAMA_COST_REPO="$ROOT" OLLAMA_COST_REF="$REF" \
    setsid -w bash "$INSTALL" --no-restart --no-verify </dev/null 2>&1); RC=$?
}

# Runs the installer on a pseudo-terminal and types $1 at the key prompt.
# The typing waits a moment so it lands after the prompt (typed-ahead input
# is echoed by the terminal before the installer can hide it).
run_tty() {
  OUT=$({ sleep 3; printf '%s\n' "$1"; } | env -i PATH="$PATH" HOME="$H" TERM=dumb SHELL=/bin/bash \
    OLLAMA_COST_REPO="$ROOT" OLLAMA_COST_REF="$REF" \
    script -qec "bash '$INSTALL' ${2:-} --no-restart --no-verify" /dev/null 2>&1); RC=$?
}

mode() { stat -c %a "$1"; }

# 1. No terminal and no key: skips with a one-line hint, writes nothing.
new_home; run_notty
check "no tty: exits 0" '[ $RC -eq 0 ]'
check "no tty: no conf.json" '[ ! -e "$CONF" ]'
check "no tty: says how to add it later" 'grep -q "add one later" <<<"$OUT"'

# 2. --no-prompt on a terminal: doesn't ask.
new_home; run_tty "$FAKE" --no-prompt
check "--no-prompt: no prompt shown" '! grep -q "Paste your" <<<"$OUT"'
check "--no-prompt: no conf.json" '[ ! -e "$CONF" ]'

# 3. Key from the environment is saved, trimmed, mode 600, never printed.
new_home; run_notty OLLAMA_API_KEY="  $FAKE "
check "env: exits 0" '[ $RC -eq 0 ]'
check "env: key saved and trimmed" '[ "$(saved)" = "$FAKE" ]'
check "env: mode 600" '[ "$(mode "$CONF")" = 600 ]'
check "env: key not in output" '! grep -qF "$FAKE" <<<"$OUT"'

# 4. A configured key is left alone, even if another one is offered.
run_notty OLLAMA_API_KEY="other0123456789abcdef0123456789"
check "existing: key untouched" '[ "$(saved)" = "$FAKE" ]'
check "existing: says it's configured" 'grep -q "already configured" <<<"$OUT"'

# 5. Other settings in conf.json are kept and the key appears once.
new_home; mkdir -p "$(dirname "$CONF")"; printf '{"monthly_credits": 60}\n' >"$CONF"
run_notty OLLAMA_API_KEY="$FAKE"
check "merge: key saved" '[ "$(saved)" = "$FAKE" ]'
check "merge: other settings kept" 'grep -q "monthly_credits" "$CONF"'
check "merge: key stored once" '[ "$(grep -c "$FAKE" "$CONF")" -eq 1 ]'
check "merge: mode 600" '[ "$(mode "$CONF")" = 600 ]'

# 6. Pasting at the prompt saves the key, hidden.
new_home; run_tty "$FAKE"
check "prompt: asks with the right text" 'grep -q "Paste your Ollama API key (press Enter to skip)" <<<"$OUT"'
check "prompt: key saved" '[ "$(saved)" = "$FAKE" ]'
check "prompt: mode 600" '[ "$(mode "$CONF")" = 600 ]'
check "prompt: key not echoed" '! grep -qF "$FAKE" <<<"$OUT"'

# 7. Pressing Enter skips with a hint.
new_home; run_tty ""
check "enter: no conf.json" '[ ! -e "$CONF" ]'
check "enter: says how to add it later" 'grep -q "add one later" <<<"$OUT"'

# 8. An odd-looking key gets a warning but is still saved.
new_home; run_notty OLLAMA_API_KEY="short"
check "format: warns" 'grep -q "doesn.t look like an Ollama API key" <<<"$OUT"'
check "format: still saved" '[ "$(saved)" = "short" ]'

# 9. update.py finds the saved key (no network).
new_home; run_notty OLLAMA_API_KEY="$FAKE"
OUT=$(env -i PATH="$PATH" HOME="$H" python3 -I -c "
import sys; sys.path.insert(0, '$ROOT'); import update; print(len(update.load_keys(update.load_conf())))" 2>&1)
check "update.py finds the saved key" '[ "$OUT" = 1 ]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
