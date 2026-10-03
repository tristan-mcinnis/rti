# RTI prompt lab

Offline loop to tune RTI's analysis prompts against a real transcript chunk,
scoring outputs automatically instead of guessing then rebuilding the app.

## Setup
```bash
export DEEPSEEK_API_KEY=...        # the same key RTI uses (Settings → Keys)
```
Drop ~2–5 min of a real bilingual FGD transcript into `chunk.txt` (Speaker N: …
lines), ideally dense with Chinese terms so the pinyin rule gets exercised.

## Run
```bash
cd scripts/prompt-lab
python3 run.py --prompt notes   --transcript chunk.txt --runs 8
python3 run.py --prompt summary --transcript chunk.txt --runs 5 --show
python3 run.py --prompt findings --transcript chunk.txt --runs 6
```

It runs the prompt N times and scores **pinyin compliance** — every kept Chinese
term must be written as `中文 (pīnyīn, English)`. Output:
```
[1] OK  han_runs=14 pinyin_violations=0
[2] ERR han_runs=12 pinyin_violations=3  e.g. 没得选, 撞车, 保温杯
...
clean runs: 6/8 | term compliance: 92/100 (92%)
```

## Single source — no hand-syncing
The real shipping prompts live in the Swift registry
(`RTI/Core/LLM/PromptID.swift`). To tune the EXACT prompts the app runs:
1. In RTI, open **Settings → Prompts → "Export defaults…"** and save the JSON as
   `rti-prompt-defaults.json` next to this README. The lab loads it
   automatically (it prints `[prompts] using exported registry`).
2. Without that file, the lab falls back to the inline copies in `prompts.py`
   (which are no longer kept in sync — they're just a default).

## Workflow
1. Export defaults (above) so you're tuning the live prompts.
2. Edit a candidate — either in the exported JSON, or inline in `prompts.py`.
3. Re-run; compare `clean runs` + `term compliance` across variants.
4. When a variant is reliably high, put it back into the registry default
   (`PromptID`/`PromptDefaults`) — or just paste it into Settings → Prompts for
   a runtime override (no rebuild). The registry is the source the app, the
   Settings editor, and this lab all read.

`RTI_LAB_MODEL` env overrides the model (default `deepseek-chat`); set it to the
exact flash model RTI runs to tune against the real target.

## Next scorers to add
- Guide-match hit-rate (feed unanswered questions + transcript, count valid matches).
- JSON validity / truncation rate for findings.
