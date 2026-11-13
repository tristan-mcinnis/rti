#!/usr/bin/env python3
"""Build the invented research replay transcript from its script.

Reads RTI/Tests/Fixtures/ResearchReplay/script.tsv and writes
transcript.jsonl beside it, in the shape of RTI's live token journal
(SonioxLiveJournal: one batch per line, {leg, stream, baseMs, tokens}).
Every scripted line becomes one batch of final tokens. Bland filler lines
from the banks below go into long system-leg gaps, so the room talks at
a normal rate. The output is deterministic: run it again after editing
the script and commit both files.

Usage: python3 scripts/research-replay-fixture.py [--check]
--check exits 1 when transcript.jsonl is not what the script makes.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "RTI/Tests/Fixtures/ResearchReplay"
STREAMS = {"mic": "00000000-0000-4000-8000-00000000000a", "system": "00000000-0000-4000-8000-00000000000b"}
CJK_MS = 220        # one character
PUNCT_MS = 60
WORD_MS = 380       # one English word
JOIN_GAP_MS = 300   # a joined line follows with no pause
MIN_GAP_MS = 1200   # lines on one leg stay separate utterances
FILLER_GAP_MS = 8000
FILLER_LEAD_MS = 1800

# No filler while the room settles, while the system leg is silent, or at the close.
NO_FILLER = [(0, 125000), (2243000, 2525000), (3415000, 3600000)]

# Section banks: no brand, no question, no opener a role rule reads as the moderator.
BANKS = [
    (0, 1620000, [
        "我早上一般比较赶，基本没有时间坐下来吃。",
        "周一到周五都差不多，就是起床出门上班。",
        "我会提前一天晚上把要喝的放在门口。",
        "有时候在公司吃，公司有微波炉。",
        "早上我一般听着播客走路去地铁站。",
        "我家附近早餐店很多，但是排队太久。",
        "我喜欢一边走一边喝，不耽误时间。",
        "早上喝点热的会舒服一点。",
        "下雨天我就更不想出去买了。",
        "我一般在地铁上刷手机，顺便喝东西。",
        "我早上起得早，时间相对多一点。",
        "我会看天气决定喝冷的还是热的。",
        "上班路上一般就二十分钟，正好喝完一盒。",
        "我老公早上会顺手帮我带一份，我就不用操心了。",
        "公司楼下的便利店早上人特别多，结账要排很久。",
        "我早上要先送孩子上学，自己吃饭都是在车里。",
        "我比较喜欢常温的，冰的早上喝了胃不舒服。",
        "早饭吃得太饱上午反而犯困，所以我吃得很少。",
        "我周末起得晚，早饭和午饭就一起吃了。",
        "我家冰箱里一直备着几盒，早上拿一盒就走。",
        "早上时间就那么点，能省一步是一步。",
        "以前我是吃包子豆浆，现在换成喝的了。",
    ]),
    (1620000, 2520000, [
        "我买东西主要看口碑，身边的人说好就试试。",
        "超市里燕麦饮的种类越来越多了。",
        "包装上的字太多我一般不看。",
        "我会对比一下同价位的几款。",
        "有些牌子打折很多，原价就不太想买。",
        "我喝过的牌子挺多的，记不太清名字。",
        "新出的牌子我会买一盒试试。",
        "口味上我还是喜欢原味的。",
        "我一般在电商平台买，有活动的时候一次买很多。",
        "身边同事喝什么我也会跟着试一下。",
        "我对新品牌没有什么偏见，好喝就行。",
        "有的牌子包装做得很好看，但是喝起来一般。",
        "我觉得这几年燕麦饮的价格涨了不少。",
        "我买过好几个牌子，最后还是回到最常喝的那个。",
        "喝的东西我不太会研究，看着顺眼就买了。",
        "便利店里能买到的牌子其实就那几个。",
    ]),
    (2520000, 3600000, [
        "颜色亮一点确实容易注意到。",
        "包装上写的卖点我会扫一眼。",
        "我觉得字体大一点更清楚。",
        "放在冰箱里的话，小瓶的更方便拿。",
        "我更看重里面的东西，包装其次。",
        "大家的想法都挺有道理的。",
        "我会先看保质期，再看配料。",
        "如果有试喝装我会更愿意买。",
        "第一眼看过去，我会先注意颜色和图片。",
        "包装太复杂的话我反而不知道它在卖什么。",
        "我觉得简单一点的设计看起来更高级。",
        "放在货架上，亮色的确实更容易被拿起来。",
        "我更想知道一盒里面有多少燕麦。",
        "瓶子的大小也很重要，太大的我拿着不方便。",
        "如果价格合适，两个方向我都可以接受。",
        "包装上写的字我会看几个关键的，别的就跳过了。",
    ]),
]


def ms(stamp: str) -> int:
    minutes, seconds = stamp.split(":")
    return (int(minutes) * 60 + int(seconds)) * 1000


def is_cjk(character: str) -> bool:
    return "㐀" <= character <= "鿿"


def tokens(text: str, start: int, leg: str) -> list[dict]:
    """Two CJK characters per token, one token per English word, marks alone."""
    out, cursor, index = [], start, 0
    language = "zh" if any(is_cjk(c) for c in text) else "en"
    while index < len(text):
        character = text[index]
        if is_cjk(character):
            piece = text[index:index + 2]
            piece = piece if len(piece) == 2 and is_cjk(piece[1]) else character
            length = CJK_MS * len(piece)
        elif character == " ":
            index += 1
            continue
        elif character.isascii() and character.isalnum():
            end = index
            while end < len(text) and text[end] not in " " and not is_cjk(text[end]):
                end += 1
            word = text[index:end]
            piece = (" " if out and language == "en" else "") + word
            length = WORD_MS
            index = end
            out.append(token(piece, cursor, cursor + length, leg, language))
            cursor += length
            continue
        else:
            piece = character
            length = PUNCT_MS
        out.append(token(piece, cursor, cursor + length, leg, language))
        cursor += length
        index += len(piece)
    return out


def token(text: str, start: int, end: int, leg: str, language: str) -> dict:
    # Key order of SonioxWord's JSONEncoder form; speaker "0" (labels off).
    return {"text": text, "start_ms": start, "end_ms": end, "speaker": "0", "confidence": 0.97,
            "is_final": True, "translation_status": "none", "language": language}


def read_script() -> list[dict]:
    lines = []
    for raw in (FIXTURE / "script.tsv").read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        key, stamp, leg, text = raw.split("\t")
        lines.append({"key": key, "join": stamp == "+", "start": None if stamp == "+" else ms(stamp),
                      "leg": {"sys": "system", "mic": "mic"}[leg], "text": text})
    return lines


def place(lines: list[dict]) -> list[list[dict]]:
    """Time every line; a joined line rides in its predecessor's batch."""
    groups, last_end = [], {"mic": -10**9, "system": -10**9}
    for line in lines:
        if line["join"]:
            previous = groups[-1]
            start = previous[-1]["tokens"][-1]["end_ms"] + JOIN_GAP_MS
        else:
            start = line["start"]
            if start < last_end[line["leg"]] + MIN_GAP_MS:
                sys.exit(f"script.tsv:{line['key']}: starts {last_end[line['leg']] + MIN_GAP_MS - start} ms too early -> move it later")
        line["tokens"] = tokens(line["text"], start, line["leg"])
        last_end[line["leg"]] = line["tokens"][-1]["end_ms"]
        if line["join"]:
            groups[-1].append(line)
        else:
            groups.append([line])
    return groups


def fillers(groups: list[list[dict]]) -> list[list[dict]]:
    system = sorted((g for g in groups if g[0]["leg"] == "system"), key=lambda g: g[0]["tokens"][0]["start_ms"])
    added, counters = [], [0] * len(BANKS)
    for before, after in zip(system, system[1:]):
        cursor = before[-1]["tokens"][-1]["end_ms"]
        limit = after[0]["tokens"][0]["start_ms"]
        while limit - cursor > FILLER_GAP_MS:
            start = cursor + FILLER_LEAD_MS
            if any(lo <= start < hi for lo, hi in NO_FILLER):
                break
            bank_index = next(i for i, (lo, hi, _) in enumerate(BANKS) if lo <= start < hi)
            bank = BANKS[bank_index][2]
            text = bank[counters[bank_index] % len(bank)]
            counters[bank_index] += 1
            line = {"key": f"F{len(added) + 1:03d}", "leg": "system", "text": text,
                    "tokens": tokens(text, start, "system")}
            if line["tokens"][-1]["end_ms"] > limit - 3000:
                break
            added.append([line])
            cursor = line["tokens"][-1]["end_ms"]
    return added


def build() -> str:
    groups = place(read_script())
    groups += fillers(groups)
    groups.sort(key=lambda g: (g[-1]["tokens"][-1]["end_ms"], g[0]["leg"]))
    out = []
    for group in groups:
        leg = group[0]["leg"]
        batch = {"leg": leg, "stream": STREAMS[leg], "baseMs": 0,
                 "tokens": [t for line in group for t in line["tokens"]]}
        out.append(json.dumps(batch, ensure_ascii=False, separators=(",", ":")))
    return "\n".join(out) + "\n"


def main() -> int:
    text = build()
    target = FIXTURE / "transcript.jsonl"
    if "--check" in sys.argv:
        if not target.exists() or target.read_text(encoding="utf-8") != text:
            print(f"{target.relative_to(ROOT)}:1: out of date -> run python3 scripts/research-replay-fixture.py")
            return 1
        return 0
    target.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
