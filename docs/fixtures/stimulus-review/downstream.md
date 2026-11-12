# Downstream readers of a marked turn

The workbook skill’s invented G1 archive contains two quotes from separate Guide questions. The upgrade verifies “我会选绿色。” and holds “I prefer violet.” for review. The following results used the real `import-rti`, `check`, `matrix` and `dg-grid.py filled` commands.

| Change to the fixture | Accepted / held | What downstream saw |
| --- | --- | --- |
| Add optional `stimulus_id` to the extraction, cell and quote | 1 / 1 | Check passed. Extraction and review JSON kept the ID. The staged transcript, Markdown matrix, content skeleton and Excel Grid all omitted it. The accepted quote still appeared in the matrix and grid. |
| Insert a Markdown section heading between the two live proof records | 0 / 2 | Check passed. The parser appended the heading to the first turn’s words. The formerly verified quote failed its verbatim check. |
| Change the live proof label from `Remote speaker 1` to `Them/S2` | 0 / 2 | Check passed. The importer looked for the historic label corresponding to `remote_1`. |
| Add an optional ID to one group’s guide question and import alongside a group on the original guide | Import refused | The importer compares the complete `sections` arrays; the two snapshots differ. |

**Reproduce the silent quote loss.** Run from the RTI repository root with Python and openpyxl. Set `SKILLS_ROOT` to the skills checkout if it lives elsewhere. Both inputs are synthetic and the test removes its temporary archives.

```bash
SKILLS_ROOT="${SKILLS_ROOT:-$HOME/skills}" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, runpy
from pathlib import Path
skill = Path(os.environ["SKILLS_ROOT"]) / "ic-synthesis-workbook"
f = runpy.run_path(str(skill / "tests/test_rti_import.py"))
for variant, expected in [("original", (1, 1)), ("heading", (0, 2))]:
    t = f["RTIImport"]()
    t.setUp()
    try:
        if variant == "heading":
            proof = t.live.replace("\n`00:00:08", "\n\n## Next board\n\n`00:00:08")
            (t.session / "transcript.live.md").write_text(proof)
        result = t.import_group()
        assert result.returncode == 0, result.stderr
        checked = f["run"](f["SCRIPT"], "check", t.out)
        assert checked.returncode == 0, checked.stdout + checked.stderr
        cells = json.loads((t.out / "extraction-G1.json").read_text())["cells"]
        held = json.loads((t.out / "review-G1.json").read_text())["quotes"]
        counts = sum(len(c["quotes"]) for c in cells), len(held)
        assert counts == expected, (variant, counts)
        print(variant, "accepted/held", *counts)
    finally:
        t.doCleanups()
PY
```

**Beta acceptance.** Keep the live proof grammar `` `HH:MM:SS.mmm` **Remote speaker N:** words `` available to historical readers. Current RTICore decodes optional fields in `GuideExtraction` and drops them when it re-encodes on rename or re-anchor. Its canonical raw transcript renderer also skips standalone headings. The meeting skill reads the raw text, sidecar and speaker names. Give that reader a human-readable material label for each turn and a reference to the durable projection. Keep quote text literal. Verify the upgraded export, staged evidence JSON, matrix and grid for mixed old/new groups. Assert the exact accepted and held identities and quote words at each step. Legacy sessions should show untracked material.

One acceptance case in this fixture is `fixture-session/G1/t5`, “I remember B1.” at 5500 ms. It belongs to S1Q2. A1 was shown after correction; the turn explicitly discusses B1. An agent reading the raw export and an analyst using the grid must both recover that difference. Run `python3 docs/fixtures/stimulus-review/check.py --show` for the expected record, including package digest and visit ID. This fixture projection demonstrates the intended behavior; the current workbook projections above still omit it.
