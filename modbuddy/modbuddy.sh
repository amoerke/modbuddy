#!/usr/bin/env bash
# CLI behind the /modbuddy skill.
#
#   modbuddy.sh on|off|status   toggle / inspect
#   modbuddy.sh test <prompt>   dry run, never touches the ON/OFF state or the log
#   modbuddy.sh log [n]         last n decisions
#   modbuddy.sh eval [file]     accuracy on a labelled file (default: data/eval.jsonl)
. "$(dirname "$0")/route.sh"

need_key() {
  api_key || { echo "no API key: put TYPESAFE_API_KEY=... into $ENV_FILE (chmod 600) or set it in the environment" >&2; exit 1; }
}

case "${1:-status}" in
  on)
    touch "$ENABLED"
    echo "modbuddy: ON — every prompt in new turns is classified by Jev (prompt text goes to api.typesafe.ai).$(api_key >/dev/null || echo ' WARNING: no API key found, the hook will do nothing.')"
    ;;
  off)
    rm -f "$ENABLED"
    echo "modbuddy: OFF — no prompt leaves the machine for routing."
    ;;
  status)
    if [ -f "$ENABLED" ]; then echo "modbuddy: ON (Jev, prompt text goes to api.typesafe.ai)"; else echo "modbuddy: OFF"; fi
    cfg '"session model: \(.session_model) | min_confidence \(.min_confidence) | context_threshold \(.context_threshold) | model \(.model)"'
    if api_key >/dev/null; then echo "API key: found"; else echo "API key: MISSING → $ENV_FILE"; fi
    if [ -s "$LOG" ]; then
      jq -rs '"decisions logged: \(length), delegated: \(map(select(.decision == "delegate")) | length), avg latency \(map(.ms) | add / length | floor) ms, input tokens \(map(.input_tokens // 0) | add)",
              "by tier: " + ([["haiku", "sonnet", "opus", "fable"][] as $t | "\($t) \(map(select(.route == $t)) | length)"] | join(", "))' "$LOG"
    fi
    ;;
  test)
    shift
    [ -n "$*" ] || { echo "usage: modbuddy.sh test <prompt text>"; exit 1; }
    key=$(need_key) || exit 1
    r=$(ask_jev "$*" "$key" 15) || { echo "Jev request failed"; exit 1; }
    printf '%s' "$r" | jq -r '"→ \(.route)  (\(.decision | ascii_upcase), confidence \(.confidence), needs_context \(.needs_context), \(.ms) ms, \(.model))",
      "  probs: " + ([.probs | to_entries[] | "\(.key) \(.value * 100 | round / 100)"] | join("  "))'
    ;;
  log)
    [ -f "$LOG" ] || { echo "no log yet"; exit 0; }
    tail -n "${2:-20}" "$LOG" | jq -r '"\(.ts)  \(.route | ascii_upcase | . + "      " | .[:6]) conf=\(.confidence | tostring | . + "    " | .[:4]) ctx=\(.needs_context | tostring | . + "    " | .[:4]) \(.decision + "        " | .[:8]) \(.ms)ms  \(.prompt[:100])"'
    ;;
  eval)
    file="${2:-$DIR/data/eval.jsonl}"
    key=$(need_key) || exit 1
    tiers='["haiku","sonnet","opus","fable"]'
    results=$(while IFS= read -r row; do
      [ -n "$row" ] || continue
      r=$(ask_jev "$(printf '%s' "$row" | jq -r .prompt)" "$key" 15) || r='null'
      jq -cn --argjson row "$row" --argjson r "$r" '{row: $row, r: $r}'
    done < "$file")
    printf '%s\n' "$results" | jq -rs --argjson t "$tiers" --slurpfile c "$CONFIG" '
      length as $n
      | map(select(.r != null) | .r.route as $got | .row.tier as $want
            | . + {d: (($t | index($got)) - ($t | index($want))), ctx: (.row.context // false)}) as $ok
      | ($c[0].context_threshold // 0.5) as $ct
      | ($ok | map(select(.r.decision == "delegate"))) as $del
      | "\($n) prompts (session model \($c[0].session_model), min_confidence \($c[0].min_confidence))"
        + (if ($ok | length) < $n then ", \($n - ($ok | length)) failed" else "" end),
        "exact tier:      \($ok | map(select(.d == 0)) | length * 100 / $n | round)%",
        "tier too small:  \($ok | map(select(.d < 0)) | length * 100 / $n | round)%",
        "needs_context:   \($ok | map(select((.r.needs_context >= $ct) == .ctx)) | length * 100 / $n | round)% correct",
        "delegated:       \($del | length) of \($n), of which harmful: \($del | map(select(.d < 0 or .ctx)) | length)"'
    ;;
  *)
    echo "usage: modbuddy.sh on|off|status|test <prompt>|log [n]|eval [file]"
    exit 1
    ;;
esac
