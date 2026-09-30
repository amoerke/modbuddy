#!/usr/bin/env bash
# modbuddy installer: copies hook, CLI and skill into ~/.claude, registers the hook in
# ~/.claude/settings.json and stores the TypeSafe API key. Safe to run again for updates.
#
#   ./install.sh               install or update
#   ./install.sh --uninstall   remove hook, skill and files (asks before deleting key and log)
#
# Options: --key <key>            API key without prompting (skipped if one exists in .env or env)
#          --session-model <tier> haiku|sonnet|opus|fable, written into a fresh config.json
#          --on                   switch the router on right away
#
# One-liner without cloning (downloads the repo into a temp dir first):
#   curl -fsSL https://raw.githubusercontent.com/amoerke/modbuddy/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/amoerke/modbuddy/main/install.sh | bash -s -- --on
set -euo pipefail

REPO="${MODBUDDY_REPO:-amoerke/modbuddy}"
REF="${MODBUDDY_REF:-main}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

# Piped from curl: the other files are not next to us and stdin is the pipe, not the keyboard.
# Fetch the repo, then re-run the real install.sh with the terminal as stdin (if there is one).
if [ ! -f "$SRC/modbuddy/route.sh" ] || [ ! -f "$SRC/hook-settings.json" ]; then
  command -v curl >/dev/null && command -v tar >/dev/null || { echo "✗ curl und tar werden benötigt" >&2; exit 1; }
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "modbuddy herunterladen ($REPO@$REF) ..."
  curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xz -C "$TMP" --strip-components=1 \
    || { echo "✗ Download von github.com/$REPO fehlgeschlagen" >&2; exit 1; }
  if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
    bash "$TMP/install.sh" "$@" </dev/tty
  else
    bash "$TMP/install.sh" "$@"
  fi
  exit $?
fi
CLAUDE_DIR="$HOME/.claude"   # hook command and SKILL.md expect exactly this path
DEST="$CLAUDE_DIR/modbuddy"
SKILL_DEST="$CLAUDE_DIR/skills/modbuddy"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_MARK="modbuddy/route.sh"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

ask_yes() {
  local answer
  [ -t 0 ] || return 1
  read -r -p "  $1 [j/N] " answer
  case "$answer" in [jJyY]*) return 0 ;; *) return 1 ;; esac
}

check_deps() {
  local missing=()
  for cmd in bash curl jq; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
  [ ${#missing[@]} -eq 0 ] && { ok "bash, curl, jq gefunden"; return; }
  if [[ " ${missing[*]} " == *" jq "* ]] && command -v brew >/dev/null && ask_yes "jq fehlt. Mit Homebrew installieren?"; then
    brew install jq
    missing=("${missing[@]/jq}")
  fi
  for cmd in "${missing[@]}"; do [ -n "$cmd" ] && die "$cmd fehlt. Bitte installieren (Mac: brew install $cmd, Linux: apt install $cmd) und erneut starten."; done
}

# Writes settings.json atomically, keeping a backup of the previous version.
write_settings() {
  local tmp="$SETTINGS.tmp.$$"
  printf '%s\n' "$1" > "$tmp"
  jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "Interner Fehler: neue settings.json ist kein gültiges JSON. Nichts geändert."; }
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-modbuddy"
  mv "$tmp" "$SETTINGS"
}

read_settings() {
  if [ -f "$SETTINGS" ]; then
    jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS ist kein gültiges JSON. Bitte erst reparieren, dann erneut starten."
    cat "$SETTINGS"
  else
    echo '{}'
  fi
}

register_hook() {
  local current hook_group
  current=$(read_settings)
  if printf '%s' "$current" | jq -e --arg m "$HOOK_MARK" \
      '[.hooks.UserPromptSubmit[]?.hooks[]?.command // empty | select(contains($m))] | length > 0' >/dev/null; then
    ok "Hook ist bereits in settings.json eingetragen"
    return
  fi
  hook_group=$(jq -c '.hooks.UserPromptSubmit[0]' "$SRC/hook-settings.json")
  write_settings "$(printf '%s' "$current" | jq --argjson g "$hook_group" \
    '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [$g])')"
  ok "Hook in $SETTINGS eingetragen (Sicherung: settings.json.bak-modbuddy)"
}

unregister_hook() {
  [ -f "$SETTINGS" ] || return 0
  local current
  current=$(read_settings)
  printf '%s' "$current" | jq -e --arg m "$HOOK_MARK" \
    '[.hooks.UserPromptSubmit[]?.hooks[]?.command // empty | select(contains($m))] | length > 0' >/dev/null || return 0
  write_settings "$(printf '%s' "$current" | jq --arg m "$HOOK_MARK" '
    .hooks.UserPromptSubmit |= (map(.hooks |= map(select((.command // "") | contains($m) | not)))
                                | map(select((.hooks | length) > 0)))
    | if .hooks.UserPromptSubmit == [] then del(.hooks.UserPromptSubmit) else . end
    | if .hooks == {} then del(.hooks) else . end')"
  ok "Hook aus settings.json entfernt (Sicherung: settings.json.bak-modbuddy)"
}

has_key() { MODBUDDY_DIR="$DEST" bash -c '. "$1"; api_key >/dev/null' _ "$DEST/route.sh" </dev/null 2>/dev/null; }

store_key() {
  local key="${1:-}"
  if [ -z "$key" ] && has_key; then ok "API-Key bereits vorhanden"; return; fi
  if [ -z "$key" ] && [ -t 0 ]; then
    echo "  TypeSafe API-Key (von https://console.typesafe.ai), leer lassen zum Überspringen:"
    read -r -s -p "  > " key; echo
  fi
  if [ -z "$key" ]; then
    warn "Kein API-Key gespeichert. Später nachholen: ./install.sh erneut starten oder TYPESAFE_API_KEY=... in $DEST/.env eintragen."
    return
  fi
  ( umask 077; printf 'TYPESAFE_API_KEY=%s\n' "$key" > "$DEST/.env" )
  chmod 600 "$DEST/.env"
  ok "API-Key in $DEST/.env gespeichert (chmod 600)"
}

install() {
  local key="" session_model="" turn_on=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) key="${2:?--key braucht einen Wert}"; shift 2 ;;
      --session-model) session_model="${2:?--session-model braucht einen Wert}"; shift 2 ;;
      --on) turn_on=1; shift ;;
      *) die "Unbekannte Option: $1 (siehe ./install.sh --help)" ;;
    esac
  done
  case "$session_model" in ""|haiku|sonnet|opus|fable) ;; *) die "--session-model muss haiku, sonnet, opus oder fable sein" ;; esac

  say "modbuddy installieren nach $DEST"
  check_deps

  mkdir -p "$DEST/data" "$SKILL_DEST"
  cp "$SRC/modbuddy/route.sh" "$SRC/modbuddy/modbuddy.sh" "$DEST/"
  chmod +x "$DEST/route.sh" "$DEST/modbuddy.sh"
  cp "$SRC/modbuddy/data/eval.jsonl" "$DEST/data/"
  cp "$SRC/skills/modbuddy/SKILL.md" "$SKILL_DEST/"
  ok "Hook, CLI, Testdaten und Skill kopiert"

  if [ -f "$DEST/config.json" ]; then
    cp "$SRC/modbuddy/config.json" "$DEST/config.default.json"
    ok "Eigene config.json behalten (neue Vorlage: config.default.json)"
  else
    cp "$SRC/modbuddy/config.json" "$DEST/config.json"
    ok "config.json angelegt"
  fi
  if [ -n "$session_model" ]; then
    jq --arg m "$session_model" '.session_model = $m' "$DEST/config.json" > "$DEST/config.json.tmp" \
      && mv "$DEST/config.json.tmp" "$DEST/config.json"
    ok "session_model = $session_model"
  fi

  register_hook
  store_key "$key"

  if [ "$turn_on" = 1 ]; then
    bash "$DEST/modbuddy.sh" on | sed 's/^/  /'
  fi

  echo
  say "Fertig. Claude Code neu starten, dann:"
  echo "  /modbuddy on       Router einschalten (Prompt-Text geht an api.typesafe.ai)"
  echo "  /modbuddy status   prüfen, ob alles passt"
  [ -f "$DEST/enabled" ] || echo "  Der Router ist noch AUS, bis du /modbuddy on eingibst."
}

uninstall() {
  say "modbuddy entfernen"
  unregister_hook
  rm -rf "$SKILL_DEST"
  ok "Skill entfernt"
  if [ -d "$DEST" ]; then
    rm -f "$DEST/route.sh" "$DEST/modbuddy.sh" "$DEST/config.default.json" "$DEST/enabled"
    rm -rf "$DEST/data"
    ok "Hook und CLI entfernt"
    if ask_yes "Auch API-Key, config.json und Log ($DEST) löschen?"; then
      rm -rf "$DEST"
      ok "$DEST gelöscht"
    else
      echo "  Behalten: $DEST (.env, config.json, log.jsonl)"
    fi
  fi
  say "Fertig. Claude Code neu starten."
}

case "${1:-}" in
  --uninstall|uninstall) uninstall ;;
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) install "$@" ;;
esac
