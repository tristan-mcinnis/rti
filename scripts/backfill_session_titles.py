#!/usr/bin/env python3

import json
import sys
from pathlib import Path
from urllib import request, error


API_URL = "https://api.deepseek.com/v1/chat/completions"
MODEL = "deepseek-v4-flash"

TITLE_INSTRUCTION = """SESSION TITLE — on the VERY FIRST LINE of your response, output exactly:
TITLE: <a 4–7 word title for this session>

The title names what this session actually IS. Lead with the format/type —
Briefing, Research, Interview, Review, Demo, Standup, 1:1, Planning, Debrief,
Strategy — then the subject, and the brand or organisation if one is
discernible from the transcript. No trailing punctuation, no quotes, no prefix
other than "TITLE: ".
"""


def load_credentials() -> dict:
    path = Path.home() / "Library/Application Support/RTI/credentials.json"
    if not path.exists():
        raise SystemExit(f"Missing credentials file: {path}")
    return json.loads(path.read_text())


def deepseek_key() -> str:
    creds = load_credentials()
    key = creds.get("deepseek", "").strip()
    if not key:
        raise SystemExit("Missing DeepSeek key in credentials.json")
    return key


def session_dirs() -> list[Path]:
    base = Path.home() / "Library/Application Support/RTI/sessions"
    return [p for p in sorted(base.iterdir()) if p.is_dir()]


def strip_frontmatter(text: str) -> str:
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---\n", 4)
    if end == -1:
        return text
    return text[end + 5 :]


def source_text(session_dir: Path) -> str | None:
    for name in ("summary.md", "transcript.md", "chat.md"):
        path = session_dir / name
        if path.exists():
            text = strip_frontmatter(path.read_text(encoding="utf-8")).strip()
            if text:
                return text
    return None


def request_title(api_key: str, transcript_text: str) -> str | None:
    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": f"{TITLE_INSTRUCTION}\n\nTranscript:\n{transcript_text}",
            }
        ],
        "stream": False,
        "temperature": 0.2,
        "max_tokens": 256,
    }
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        API_URL,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"DeepSeek HTTP {exc.code}: {detail}") from exc
    content = (
        body.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
        .strip()
    )
    if not content:
        return None
    first = next((line.strip() for line in content.splitlines() if line.strip()), "")
    if first.lower().startswith("title:"):
        title = first[len("title:") :].strip()
        return title or None
    return None


def main() -> int:
    api_key = deepseek_key()
    updated = 0
    skipped = 0
    for session_dir in session_dirs():
        title_path = session_dir / "title.txt"
        if title_path.exists():
            skipped += 1
            continue
        text = source_text(session_dir)
        if not text:
            skipped += 1
            continue
        title = request_title(api_key, text[:20000])
        if not title:
            print(f"skip {session_dir.name}: no title returned", file=sys.stderr)
            continue
        title_path.write_text(title + "\n", encoding="utf-8")
        updated += 1
        print(f"wrote {session_dir.name}: {title}")
    print(f"updated={updated} skipped={skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
