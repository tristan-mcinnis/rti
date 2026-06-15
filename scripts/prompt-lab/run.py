#!/usr/bin/env python3
"""
RTI prompt lab — offline loop to tune the analysis prompts against a real
transcript chunk, scoring outputs automatically so we stop guessing.

It runs a chosen prompt against DeepSeek N times over a fixed transcript chunk
and scores the outputs (currently: pinyin compliance — every kept Chinese term
must be written as 中文 (pinyin, English)). Edit the prompt in prompts.py, re-run,
compare pass rates, then port the winner into the Swift source.

Usage:
    export DEEPSEEK_API_KEY=...                 # the key RTI uses
    python3 run.py --prompt notes --transcript chunk.txt --runs 8
    python3 run.py --prompt summary --transcript chunk.txt --runs 5 --show

A good transcript chunk: paste ~2–5 min of a real bilingual FGD transcript
(Speaker N: text lines) into a .txt file — ideally one dense with Chinese terms,
so the pinyin rule gets exercised.
"""
import argparse
import json
import os
import re
import sys
import urllib.request

from prompts import PROMPTS

API_URL = "https://api.deepseek.com/chat/completions"
MODEL = os.environ.get("RTI_LAB_MODEL", "deepseek-chat")

HAN = re.compile(r"[一-鿿]+")
# A Han run is "compliant" when immediately followed (allowing a space) by an
# opening paren whose contents contain latin letters (the pinyin + gloss).
COMPLIANT_AFTER = re.compile(r"^\s*[（(][^）)]*[A-Za-z][^）)]*[）)]")


def call(prompt_text: str) -> str:
    key = os.environ.get("DEEPSEEK_API_KEY")
    if not key:
        sys.exit("Set DEEPSEEK_API_KEY (the key RTI uses).")
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt_text}],
        "stream": False,
        "max_tokens": 8192,
        "temperature": 0.6,
    }).encode()
    req = urllib.request.Request(API_URL, data=body, headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


def score_pinyin(text: str):
    """Return (violations, total_han_runs, list_of_violating_terms)."""
    violations, total, bad = 0, 0, []
    for m in HAN.finditer(text):
        total += 1
        tail = text[m.end():m.end() + 60]
        if not COMPLIANT_AFTER.match(tail):
            violations += 1
            if len(bad) < 12:
                bad.append(m.group())
    return violations, total, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True, choices=list(PROMPTS))
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--runs", type=int, default=6)
    ap.add_argument("--show", action="store_true", help="print each output")
    args = ap.parse_args()

    transcript = open(args.transcript, encoding="utf-8").read()
    base = PROMPTS[args.prompt] + "\n\nTranscript:\n" + transcript

    clean_runs, totals = 0, []
    print(f"=== {args.prompt} · {args.runs} runs · model={MODEL} ===")
    for i in range(1, args.runs + 1):
        out = call(base)
        v, t, bad = score_pinyin(out)
        totals.append((v, t))
        ok = v == 0 and t > 0
        clean_runs += ok
        flag = "OK " if ok else "ERR"
        print(f"[{i}] {flag} han_runs={t} pinyin_violations={v}" +
              (f"  e.g. {', '.join(bad)}" if bad else ""))
        if args.show:
            print("-" * 60 + "\n" + out + "\n" + "-" * 60)

    tv = sum(v for v, _ in totals)
    tt = sum(t for _, t in totals)
    print(f"\nclean runs: {clean_runs}/{args.runs}"
          f" | term compliance: {tt - tv}/{tt}"
          f" ({0 if tt == 0 else round(100 * (tt - tv) / tt)}%)")


if __name__ == "__main__":
    main()
