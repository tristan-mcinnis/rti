"""Executable example of the proposed archive contract. Uses only the files beside it."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def load(name):
    return json.loads((ROOT / name).read_text())


def package_digest(manifest):
    paths = ["stim-manifest.json"]
    paths += [f"{manifest['source']}/{slide['id']}.html" for slide in manifest["slides"]]
    parts = [[p, hashlib.sha256((ROOT / p).read_bytes()).hexdigest()] for p in sorted(paths)]
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()


def markers(events, by_code):
    seen, positions = {}, {}
    ordered = []
    for event in events:
        key = event["id"]
        if key in seen:
            if seen[key] != event:
                raise ValueError("conflicting retry")
            continue
        seen[key] = event
        if event["kind"] == "note":
            continue
        if event["kind"] == "marker":
            positions[key] = len(ordered)
            ordered.append(event.copy())
        elif event["kind"] == "correction":
            index = positions[event["replaces"]]
            original = ordered[index]
            replacement = event["replacement"]
            if not set(replacement) <= {"text", "guideQuestionID", "shownCodes"}:
                raise ValueError("correction changed marker identity or offset")
            ordered[index] = {k: original[k] for k in ("kind", "id", "offsetMs", "leg")} | replacement
        else:
            raise ValueError("unknown event kind")

    for marker in ordered:
        codes = marker.get("shownCodes", [])
        if len(codes) != len(set(codes)) or not set(codes) <= by_code.keys():
            raise ValueError("duplicate or unknown stimulus")
    # A stable sort makes the later journal entry win at an equal boundary.
    return sorted(ordered, key=lambda marker: marker["offsetMs"])


def at(ms, timeline, by_code):
    state = {"markerID": None, "showEventID": None, "guideQuestionID": None,
             "shownCodes": None, "revealHistory": "unknown"}
    for marker in timeline:
        if marker["offsetMs"] > ms:
            break
        state["markerID"] = marker["id"]
        if "guideQuestionID" in marker:
            state["guideQuestionID"] = marker["guideQuestionID"]
        if "shownCodes" in marker:
            codes = marker["shownCodes"]
            state.update(shownCodes=codes, showEventID=marker["id"])
            if any(by_code[code].get("ends_blind") for code in codes):
                state["revealHistory"] = "reveal recorded"
            elif state["revealHistory"] == "unknown":
                state["revealHistory"] = "no recorded reveal"
    return state


def project(turn, timeline, by_code, session):
    live = at(turn["liveStartMs"], timeline, by_code)
    playback = turn.get("upgradedStartMs")
    if playback is None:
        anchor = "approximate"
    elif at(playback, timeline, by_code)["markerID"] != live["markerID"]:
        anchor = "review boundary"
    else:
        anchor = "matched"
    # Project only these keys. Manifest paths, product mappings, and moderator
    # notes are available in the manifest, never inherited into the blind view.
    evidence = {k: turn[k] for k in ("turnID", "rawSpeaker", "liveStartMs", "original")}
    discussed = turn.get("discussedCodes")
    if discussed and not set(discussed) <= by_code.keys():
        raise ValueError("unknown discussion code")
    return {**evidence, **live, "sessionId": session["sessionId"], "groupID": session["groupID"],
            "packageSHA256": session["stimulusPackage"]["sha256"], "discussedCodes": discussed,
            "upgradedStartMs": playback, "anchor": anchor}


def check():
    manifest, session, turns = load("stim-manifest.json"), load("session.json"), load("turns.json")
    assert package_digest(manifest) == session["stimulusPackage"]["sha256"]
    assert manifest["version"] == session["stimulusPackage"]["version"]
    by_code = {slide["code"]: slide for slide in manifest["slides"]}
    assert len(by_code) == len(manifest["slides"])
    events = [json.loads(line) for line in (ROOT / "notes.jsonl").read_text().splitlines()]
    timeline = markers(events, by_code)
    assert timeline == markers(events + events, by_code)
    assert at(5500, markers(events[:-2], by_code), by_code)["shownCodes"] == ["B1"]
    try:
        markers(events + [events[-1] | {"offsetMs": 9999}], by_code)
    except ValueError as error:
        assert str(error) == "conflicting retry"
    else:
        raise AssertionError("conflicting retries must fail")

    rows = [project(turn, timeline, by_code, session) for turn in turns]
    # A Guide-only marker keeps the displayed pair; an empty list clears it.
    expected = [
        (None, None, None, None), ("m1", "m1", "S1Q1", ["A1"]),
        ("m2", "m2", "S1Q1", ["A1", "B1"]), ("m3", "m2", "S1Q2", ["A1", "B1"]),
        ("m4", "m4", "S1Q2", []), ("m5", "m5", "S1Q2", ["A1"]),
        ("m6", "m6", "S1Q2", ["R1"]), ("m7", "m7", "S1Q2", ["A1"]),
    ]
    assert [(r["markerID"], r["showEventID"], r["guideQuestionID"], r["shownCodes"]) for r in rows] == expected
    assert [r["revealHistory"] for r in rows] == ["unknown"] + ["no recorded reveal"] * 5 + ["reveal recorded"] * 2
    assert rows[3]["anchor"] == "review boundary" and rows[4]["anchor"] == "approximate"
    assert rows[5]["discussedCodes"] == ["B1"] and rows[5]["shownCodes"] == ["A1"]
    assert all(r["discussedCodes"] is None for i, r in enumerate(rows) if i != 5)
    assert all(r["original"] == t["original"] and r["turnID"] == t["turnID"]
               and r["liveStartMs"] == t["liveStartMs"] for t, r in zip(turns, rows))
    # These invented strings occupy private fields, so the leakage check is observable.
    private = [p["name"] for p in manifest["products"]] + manifest["brand_words"]
    private += [s["id"] for s in manifest["slides"]]
    blind_text = json.dumps(rows[:6], ensure_ascii=False)
    assert all(value not in blind_text for value in private)
    assert not ({"product", "products", "brand_words", "text", "notes", "id"} & rows[0].keys())
    return rows


if __name__ == "__main__":
    try:
        output = check()
    except (AssertionError, KeyError, ValueError) as error:
        frame = error.__traceback__
        while frame.tb_next:
            frame = frame.tb_next
        sys.exit(f"{frame.tb_frame.f_code.co_filename}:{frame.tb_lineno}: fixture failed {error} -> check the proposed contract")
    if "--show" in sys.argv:
        for row in output:
            print(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
