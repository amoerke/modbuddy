---
name: modbuddy
description: Toggle and inspect the modbuddy model router (TypeSafe's Jev picks the cheapest Claude tier per prompt). Use when the user types /modbuddy on, /modbuddy off, /modbuddy status, /modbuddy test <prompt>, /modbuddy log or /modbuddy eval.
---

# /modbuddy — Jev model router

The router is a `UserPromptSubmit` hook (`~/.claude/modbuddy/route.sh`). When it is ON, every
non-slash prompt is sent to TypeSafe's Jev, which returns calibrated probabilities for the cheapest
Claude tier that can handle it (`haiku` / `sonnet` / `opus` / `fable`) and for whether the request
depends on the earlier conversation. Self-contained requests whose tier is below the session model
with confidence ≥ `min_confidence` are delegated to a subagent; everything else stays in the session.
Criteria, thresholds and the session model live in `~/.claude/modbuddy/config.json`.

Run exactly one command for the argument the user gave, then report its output in the language
the user writes in. Do not add commentary beyond the output unless asked.

| Argument | Command |
|----------|---------|
| `on` | `bash ~/.claude/modbuddy/modbuddy.sh on` |
| `off` | `bash ~/.claude/modbuddy/modbuddy.sh off` |
| `status` (or none) | `bash ~/.claude/modbuddy/modbuddy.sh status` |
| `test <prompt>` | `bash ~/.claude/modbuddy/modbuddy.sh test <prompt>` — dry run, never changes the ON/OFF state |
| `log [n]` | `bash ~/.claude/modbuddy/modbuddy.sh log [n]` — last n decisions (default 20) |
| `eval` | `bash ~/.claude/modbuddy/modbuddy.sh eval` — accuracy on 48 labelled test prompts (48 API calls) |

Quote the prompt argument for the shell (single quotes; escape any single quote inside it).

Notes for you, the agent:
- `on` means prompt text leaves the machine (api.typesafe.ai). If the user is about to paste
  customer data or secrets, remind them once that the router is on.
- The hook only injects context; you still make the delegation call. When the injected line says
  DELEGATE, use the Agent tool with the named `model` and a self-contained prompt.
- Never print or copy the API key in `~/.claude/modbuddy/.env`.
- The toggle takes effect on the next prompt; no restart needed.
