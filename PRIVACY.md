# Privacy

RTI is a local-first macOS app — but it talks to two third-party services to
do its job. This document is the honest version of what leaves your machine
and what stays.

## TL;DR

| Data | Where it goes |
|------|---------------|
| Your microphone audio | **Soniox** (`api.soniox.com`) over WebSocket, in real time, while a session is recording |
| System audio (when you opt in) | **Soniox**, same channel |
| Transcript text + your prompts + recent transcript context | **Your configured LLM provider** — DeepSeek (`api.deepseek.com`) by default. Configurable in `Sources/LLM/LLMProvider.swift`. |
| Screenshot OCR text (when you press ⌘⇧H) | **Your LLM provider**, attached to the next prompt |
| The screenshot image itself | Discarded after OCR — never uploaded, never written to disk |
| Recordings (`.wav`), transcripts (`.md`), chat history, summaries, modes | **Stay on this Mac.** SQLite at `~/Library/Application Support/RTI/rti.db`; markdown corpus at `~/meetings/` |
| API keys | **Stay on this Mac.** `~/Library/Application Support/RTI/credentials.json`, mode 0600 |
| Calendar events | Read locally via EventKit; only event titles attach to session metadata |
| Crash reports | Written to `~/Library/Application Support/RTI/crash.log` (mode 0600). Never sent anywhere. |

## What this means in practice

- **Soniox sees every word you say while RTI is recording.** Their privacy policy and data retention apply: <https://soniox.com/privacy>. RTI does not control or modify their handling.
- **DeepSeek (or whichever provider you point RTI at) sees your transcript and prompts.** DeepSeek is operated from the People's Republic of China; their privacy policy applies: <https://platform.deepseek.com/privacy>. If that is unacceptable for your meetings, swap to OpenAI / Anthropic / a self-hosted endpoint via `LLMProviders` in code — RTI is provider-agnostic.
- **Both keys are yours.** RTI never proxies, mirrors, or uploads them. They are sent only as `Authorization: Bearer …` headers directly to the providers.
- **There is no telemetry.** RTI does not phone home, count installs, or report errors anywhere off-device. Crash logs are local.

## How to verify

Everything above is observable:

```bash
# What RTI is talking to right now (run while a session is recording)
sudo lsof -nP -p $(pgrep -x RTI) | grep -E 'TCP|IPv4'

# Inspect outbound traffic
sudo tcpdump -i any -w rti.pcap host api.soniox.com or host api.deepseek.com
```

## Removing your data

```bash
# Database, audio cache, credentials, crash log
rm -rf ~/Library/Application\ Support/RTI

# Markdown corpus (the canonical record)
rm -rf ~/meetings

# Onboarding flag, hotkey state, UserDefaults
defaults delete com.tristan.rti
```

## When this document needs to change

Any time RTI starts sending data to a new endpoint, or starts persisting
something it didn't before, this file must be updated in the same commit.
