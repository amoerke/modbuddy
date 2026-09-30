# modbuddy – Model Router für Claude Code

Ein Hook plus Skill, der bei jedem Prompt in Claude Code fragt: **Welches Claude-Modell braucht diese Aufgabe wirklich?** Die Antwort liefert [Jev](https://typesafe.ai) von TypeSafe AI in etwa 300 ms. Liegt die Stufe unter deinem Session-Modell, ist Jev sich sicher genug und ist die Aufgabe in sich geschlossen, gibt Claude sie an einen Subagenten mit dem günstigeren Modell.

Aufgebaut auf [Jev-Model-Router-Claude-Code](https://github.com/AlexPEClub/Jev-Model-Router-Claude-Code), mit gemessener Delegationsschwelle, kalibrierten Wahrscheinlichkeiten statt nur der Top-Wahl und einem Testsatz zum Nachmessen.

## Wie es funktioniert

1. Ein `UserPromptSubmit`-Hook (`route.sh`) schickt den Text deines Prompts an Jev.
2. Jev liefert **kalibrierte** Wahrscheinlichkeiten für `haiku` / `sonnet` / `opus` / `fable` und dafür, dass die Aufgabe vom bisherigen Gespräch abhängt.
3. Delegiert wird, wenn die wahrscheinlichste Stufe unter dem Session-Modell liegt, ihre Wahrscheinlichkeit mindestens `min_confidence` (0.9) beträgt und `needs_context` unter 0.5 liegt. Sonst bleibt die Aufgabe in der Session.
4. Der Hook blendet Claude die Entscheidung ein. Die Antwort beginnt dann mit `→ haiku (modbuddy)` oder `→ opus (modbuddy: sonnet, conf 0.72, ctx 0.1)`.

**Was an TypeSafe geht:** nur der Prompt-Text (max. 12.000 Zeichen), keine Dateien, kein Code, kein Verlauf. Fail-open: Antwortet Jev nicht innerhalb von 5 s, läuft der Prompt unverändert durch.

## Warum Jev? (gemessen, 30.09.2026)

Verglichen wurden drei Ansätze auf 48 gelabelten Test-Prompts, Jev zusätzlich auf 235 weiteren:

| | Jev | lokal: Embeddings + kNN | lokal: llama3 8B |
|---|---|---|---|
| exakte Stufe | **88 %** | 79 % (53 % auf 235 Prompts) | 79 % |
| „hängt vom Gespräch ab" richtig | **98 %** | 90 % | 90 % |
| Konfidenz kalibriert | **ja** (≥ 0.9 → 99–100 % richtig) | nein | nein |
| Latenz | ~300 ms | ~40 ms | ~1.000 ms |

Mit `min_confidence` 0.9 hat Jev auf 283 Prompts 99 Aufgaben delegiert, davon 1 fälschlich. Kosten: etwa 565 Input-Tokens pro Prompt, also wenige Cent pro 1.000 Prompts. Eine Kaskade (lokal zuerst, Jev nur bei Unsicherheit) brachte nichts: Der lokale Klassifizierer war nur bei 11 % der Prompts sicher genug.

Typische Schwäche von Jev: Fehlersuche („finde heraus, warum…") stuft es öfter als `sonnet` statt `opus` ein.

## Voraussetzungen

- Claude Code, `bash`, `curl` und `jq` (Mac: `brew install jq`; ab macOS 15 ist jq schon dabei)
- API-Key von [console.typesafe.ai](https://console.typesafe.ai)

## Installation

```bash
mkdir -p ~/.claude/modbuddy/data ~/.claude/skills/modbuddy
cp modbuddy/route.sh modbuddy/modbuddy.sh modbuddy/config.json ~/.claude/modbuddy/
chmod +x ~/.claude/modbuddy/*.sh
cp modbuddy/data/eval.jsonl ~/.claude/modbuddy/data/
cp skills/modbuddy/SKILL.md ~/.claude/skills/modbuddy/
```

Den Key selbst in `~/.claude/modbuddy/.env` eintragen, als Zeile `TYPESAFE_API_KEY=...`, und die Datei mit `chmod 600` schützen. Alternativ die Umgebungsvariable `TYPESAFE_API_KEY` setzen. Dann den Block aus `hook-settings.json` in `~/.claude/settings.json` unter `hooks.UserPromptSubmit` **ergänzen** und Claude Code neu starten.

## Benutzen

| Befehl | Was er tut |
|--------|------------|
| `/modbuddy on` | Router einschalten (Prompt-Text geht ab jetzt an api.typesafe.ai) |
| `/modbuddy off` | Router ausschalten |
| `/modbuddy status` | An/Aus, Schwellen, Key vorhanden?, Verteilung, Delegationen, Latenz, Tokens |
| `/modbuddy test <Prompt>` | Trockenlauf mit allen Wahrscheinlichkeiten |
| `/modbuddy log 20` | Die letzten 20 Entscheidungen |
| `/modbuddy eval` | Trefferquote auf den 48 Test-Prompts (48 API-Aufrufe) |

Slash-Commands und Prompts unter 12 Zeichen werden nie klassifiziert.

## Anpassen (`~/.claude/modbuddy/config.json`)

| Feld | Bedeutung | Standard |
|------|-----------|----------|
| `session_model` | Modell deiner Session, delegiert wird nur an Stufen darunter | `opus` |
| `min_confidence` | Mindestwahrscheinlichkeit der Stufe für eine Delegation. 0.8 delegiert etwas mehr, bei etwa 4 % Fehlgriffen. | `0.9` |
| `context_threshold` | Ab dieser Wahrscheinlichkeit für „hängt vom Gespräch ab" bleibt die Aufgabe in der Session | `0.5` |
| `questions.route.criteria` | Beschreibung der vier Stufen. Hier nachschärfen, z. B. für Debugging. | siehe Datei |
| `model` | Jev-Version. Nach dem Kalibrieren auf eine feste Version pinnen (aktuell `jev-1.13.0`). | `jev-latest` |

## Einschränkungen

- Der Hook blendet nur die Entscheidung ein. Die Delegation macht Claude selbst.
- Subagenten starten mit frischem Kontext. Deshalb bleibt alles, was vom Gespräch abhängt, in der Session.
- Der Prompt-Text geht an einen zusätzlichen US-Anbieter. Bei Kunden- oder Firmendaten muss TypeSafe eigens freigegeben sein (AVV), siehe [docs.typesafe.ai/legal](https://docs.typesafe.ai/legal). Im Zweifel `/modbuddy off`.
- `log.jsonl` enthält die ersten 120 Zeichen jedes Prompts. Nicht teilen, nicht committen.

## Dateien

```
modbuddy/route.sh           der Hook (bash, curl, jq)
modbuddy/modbuddy.sh        CLI hinter /modbuddy: on, off, status, test, log, eval
modbuddy/config.json        Schwellen, Session-Modell, Jev-Fragen und -Kriterien
modbuddy/data/eval.jsonl    48 gelabelte Test-Prompts für /modbuddy eval
skills/modbuddy/SKILL.md    der Skill /modbuddy
hook-settings.json          der Block für ~/.claude/settings.json
```
