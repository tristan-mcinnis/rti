#!/usr/bin/env python3
"""Replay invented PCM through the production writer without launching RTI.

The Swift compiler receives the repository's real writer and format sources.
No capture, provider, credential, application, or vault API is used.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--probes-only", action="store_true")
    parser.add_argument("--mic-wav", type=Path, help="invented 16 kHz mono PCM speech fixture")
    parser.add_argument("--system-wav", type=Path, help="invented 16 kHz mono PCM speech fixture")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 7200:
        parser.error("--seconds must be between 1 and 7200")
    for fixture in [args.mic_wav, args.system_wav]:
        if fixture and not fixture.is_file():
            parser.error(f"speech fixture does not exist: {fixture}")
    root = Path(__file__).resolve().parent.parent
    output = args.output or Path(tempfile.mkdtemp(prefix="rti-writer-benchmark-"))
    output.mkdir(parents=True, exist_ok=False) if args.output else None
    output = output.resolve()
    executable = output / "writer-benchmark"
    command = [
        "xcrun", "swiftc", "-swift-version", "6", "-O", "-module-name", "RTICore",
        "-target", f"{platform.machine()}-apple-macosx14.0",
        "-module-cache-path", str(output / "module-cache"),
        str(root / "RTI/Core/Audio/WAVWriter.swift"),
        str(root / "RTI/Core/Support/AudioFormat.swift"),
        str(root / "RTI/Core/Support/CoreLog.swift"),
        str(root / "scripts/RecordingWriterBenchmark.swift"),
        "-o", str(executable),
    ]
    with (output / "build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=log, check=True)
    print(json.dumps({"output": str(output), "pid": os.getpid()}), flush=True)
    outcomes = []
    outcomes.append(subprocess.run([str(executable), "probes", str(output)]).returncode)

    # Only this invented-data child is killed. It publishes a completed block
    # marker after append returns, then waits without closing its recorder.
    crash = output / "crash"
    child = subprocess.Popen([str(executable), "crash-child", str(crash)])
    try:
        deadline = time.monotonic() + 10
        while not (crash / "ready.json").exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("crash fixture did not become ready")
            time.sleep(0.02)
        child.send_signal(signal.SIGKILL)
        child.wait(timeout=5)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
    outcomes.append(subprocess.run([str(executable), "verify-crash", str(crash)]).returncode)
    outcomes.append(subprocess.run([str(executable), "write-failure", str(output / "write-failure")]).returncode)
    if any(outcomes):
        raise RuntimeError(f"acceptance probes failed: {outcomes}; inspect {output}")
    if not args.probes_only:
        subprocess.run([
            str(executable), "replay", str(output / "replay"), str(args.seconds),
            "realtime" if args.realtime else "accelerated",
            str(args.mic_wav.resolve()) if args.mic_wav else "-",
            str(args.system_wav.resolve()) if args.system_wav else "-",
        ], check=True)
    print(json.dumps({"result": "pass", "output": str(output)}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(f"recording-writer-benchmark: {error}", file=sys.stderr)
        sys.exit(1)
