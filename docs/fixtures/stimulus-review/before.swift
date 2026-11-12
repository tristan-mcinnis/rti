// Baseline observation against the RTICore library built from 67c44ec8.
// Four board-A turns fill a Guide cell before the first board-B turn arrives.
import Foundation
import RTICore

let guideInput = """
{
  "title": "Storage mock group",
  "stimulus": [{"code": "M", "section": 1, "minutes": 3, "what": "Compare storage boards"}],
  "sections": [{"id": "S1", "title": "Boards", "questions": [{
    "qid": "S1Q1", "en": "What catches your eye?", "zh": "你先看到什么？", "probes": []
  }]}]
}
"""
let guide = try GuideDocument.parse(Data(guideInput.utf8))
let encoded = try JSONEncoder().encode(guide)
let guideFields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
precondition(guide.questions.count == 1 && guideFields?["stimulus"] == nil)

let originals = ["盖子。", "The blue edge.", "透明的。", "A small handle.", "B 的字更大。"]
let turns = originals.enumerated().map { index, original in
    GuideTurn(id: "turn-\(index)", speaker: "remote_1", startMs: 1000 * index, text: original)
}

var extraction = GuideExtraction(group: "G1", transcript: "invented.md", guide: guide)
for turn in turns {
    let cell: [String: Any] = [
        "qid": "S1Q1", "coverage": "Lightly covered", "summary": "", "turns": [turn.id],
        "quotes": [["turn": turn.id, "english": ""]], "votes": [],
    ]
    let pass: [String: Any] = ["evidence": [], "cells": [cell]]
    let data = try JSONSerialization.data(withJSONObject: pass)
    try extraction.apply(JSONDecoder().decode(GuidePass.self, from: data),
                         turns: [turn], speakers: [:], rosterBase: nil)
}

let captured = extraction.cells[0].quotes.map(\.original)
precondition(captured == Array(originals.prefix(4)))
