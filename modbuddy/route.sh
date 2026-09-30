#!/usr/bin/env bash
# modbuddy: Jev model router for Claude Code — UserPromptSubmit hook.
#
# Sends the prompt text to TypeSafe's Jev, which returns calibrated probabilities for the cheapest
# Claude tier that can handle it and for whether it depends on the earlier conversation.
# Self-contained requests with a confident tier below the session model are delegated to a subagent.
# Only runs while ~/.claude/modbuddy/enabled exists (toggle: /modbuddy on|off).
# Needs bash, curl and jq. Fail-open: any error → exit 0 with no output, the prompt goes through untouched.
#
# Sourced by modbuddy.sh for its helper functions; executed directly it runs the hook.

DIR="${MODBUDDY_DIR:-$HOME/.claude/modbuddy}"
CONFIG="$DIR/config.json"
ENV_FILE="$DIR/.env"
LOG="$DIR/log.jsonl"
ENABLED="$DIR/enabled"

cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }

# TYPESAFE_API_KEY, JEV_API_KEY or JEV-API-KEY, from the environment or from .env
api_key() {
  local name value
  [ -n "$TYPESAFE_API_KEY" ] && { printf '%s' "$TYPESAFE_API_KEY"; return; }
  [ -n "$JEV_API_KEY" ] && { printf '%s' "$JEV_API_KEY"; return; }
  [ -f "$ENV_FILE" ] || return 1
  while IFS='=' read -r name value || [ -n "$name" ]; do
    name=$(printf '%s' "$name" | tr -d '[:space:]')
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")
    case "$name" in TYPESAFE_API_KEY|JEV_API_KEY|JEV-API-KEY) [ -n "$value" ] && { printf '%s' "$value"; return; } ;; esac
  done < "$ENV_FILE"
  return 1
}

# Millisecond clock without python: perl ships with macOS and nearly every Linux; else whole seconds.
now_ms() {
  perl -MTime::HiRes=time -e 'printf("%d\n", time*1000)' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

# ask_jev <prompt> <key> <timeout>
# Prints one JSON line: {route, confidence, needs_context, probs, decision, ms, model, input_tokens}.
# Takes the most likely tier; delegates only if it is below the session model, confident enough and
# self-contained. Jev's probabilities are calibrated, so min_confidence means what it says.
ask_jev() {
  local body resp start end
  body=$(jq -cn --arg p "$1" --slurpfile c "$CONFIG" \
    '{state: ("User request to a coding agent (Claude Code):\n" + $p[:($c[0].max_state_chars // 12000)]),
      model: ($c[0].model // "jev-latest"), questions: $c[0].questions}') || return 1
  start=$(now_ms)
  resp=$(curl -sf --max-time "$3" -X POST "$(cfg '.api_url // "https://api.typesafe.ai/v1/systemone"')" \
    -H "Authorization: Bearer $2" -H "Content-Type: application/json" -d "$body") || return 1
  end=$(now_ms)
  printf '%s' "$resp" | jq -ce --argjson ms "$((end - start))" --slurpfile c "$CONFIG" '
    ["haiku", "sonnet", "opus", "fable"] as $tiers
    | .answers.route as $r
    | ($r.probabilities // {($r.choice): ($r.confidence // 0)}) as $p
    | ($tiers | map({t: ., p: ($p[.] // 0 | tonumber)})) as $probs
    | ($probs | sort_by(-.p) | .[0]) as $best
    | (.answers.needs_context.noul | tonumber) as $ctx
    | ($c[0].session_model // "opus") as $session
    | (($tiers | index($best.t)) < ($tiers | index($session) // -1)
       and $best.p >= ($c[0].min_confidence // 0.9)
       and $ctx < ($c[0].context_threshold // 0.5)) as $delegate
    | {route: $best.t, confidence: ($best.p * 100 | round / 100), needs_context: ($ctx * 100 | round / 100),
       probs: ($probs | map({(.t): .p}) | add), decision: (if $delegate then "delegate" else "handle" end),
       ms: $ms, model: (.model // ""), input_tokens: (.usage.input_tokens // 0)}' 2>/dev/null
}

hook() {
  local key prompt min r route conf ctx decision session msg
  [ -f "$ENABLED" ] || return 0
  key=$(api_key) || return 0
  prompt=$(jq -r '.prompt // empty' 2>/dev/null) || return 0
  case "$prompt" in /*) return 0 ;; esac
  min=$(cfg '.min_prompt_chars // 12')
  [ "$(printf '%s' "$prompt" | jq -Rrs 'length')" -ge "$min" ] || return 0

  r=$(ask_jev "$prompt" "$key" "$(cfg '.timeout_seconds // 5')") || return 0
  route=$(printf '%s' "$r" | jq -r .route)
  conf=$(printf '%s' "$r" | jq -r .confidence)
  ctx=$(printf '%s' "$r" | jq -r .needs_context)
  decision=$(printf '%s' "$r" | jq -r .decision)
  session=$(cfg '.session_model // "opus"')

  printf '%s' "$r" | jq -c --arg ts "$(date -u +%FT%TZ)" --arg p "$prompt" --argjson n "$(cfg '.log_prompt_chars // 120')" \
    '{ts: $ts, route, confidence, needs_context, decision, ms, model, input_tokens, prompt: $p[:$n]}' >> "$LOG" 2>/dev/null

  if [ "$decision" = "delegate" ]; then
    msg="[modbuddy] tier=$route confidence=$conf needs_context=$ctx → DELEGATE. Hand this request to a subagent via the Agent tool with model=\"$route\" and a self-contained prompt: include the exact file paths, the docs to read, and the expected output. The subagent starts with a fresh context, so give it everything it needs. Relay the subagent's result; do not redo the work yourself. Start your reply with one short line: \"→ $route (modbuddy)\"."
  else
    msg="[modbuddy] tier=$route confidence=$conf needs_context=$ctx → handle in this session. Start your reply with one short line: \"→ $session (modbuddy: $route, conf $conf, ctx $ctx)\"."
  fi
  jq -cn --arg msg "$msg" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hook
  exit 0
fi
