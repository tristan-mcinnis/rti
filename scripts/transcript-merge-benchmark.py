#!/usr/bin/env python3
"""Build and measure the actual transcript sources without an app/test host."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Artifact directory")
    parser.add_argument("--reference", type=Path, help="Baseline result.json; require identical output and >=2x CPU improvement")
    parser.add_argument("--pipeline-source", type=Path, help="Optional preserved production TranscriptPipeline.swift for a baseline")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = [root / value for value in [
        "RTI/Core/Session/TranscriptPipeline.swift",
        "RTI/Core/Session/TranscriptAggregator.swift",
        "RTI/Core/Session/LiveEntry.swift",
        "RTI/Core/Session/SpeakerTurn.swift",
        "RTI/Core/Session/LiveTranscriptPresentation.swift",
        "RTI/Core/Session/EchoFilter.swift",
        "RTI/Core/Session/CalendarMeeting.swift",
        "RTI/Core/Support/SpeakerLabelMapping.swift",
        "RTI/Core/Support/AudioFormat.swift",
        "RTI/Core/Soniox/SonioxProtocol.swift",
        "scripts/TranscriptMergeBenchmark.swift",
    ]]
    if args.pipeline_source:
        sources[0] = args.pipeline_source.resolve()
    executable = output / "transcript-merge-benchmark"
    receipt = output / "result.json"
    compile_command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-target", "arm64-apple-macos14.0",
                       "-module-cache-path", str(output / "module-cache"), "-module-name", "RTICore", "-parse-as-library",
                       *map(str, sources), "-o", str(executable)]
    run_command = [str(executable), str(receipt)]
    if args.reference:
        run_command.append(str(args.reference.resolve()))
    metadata = {
        "compile_command": compile_command, "run_command": run_command,
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
        "source_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
    }
    (output / "commands.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for name, command in [("build", compile_command), ("run", run_command)]:
        with (output / f"{name}.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=root)
    if args.reference:
        baseline = json.loads(args.reference.read_text())
        result = json.loads(receipt.read_text())
        if baseline["profile"] != result["profile"]:
            raise ValueError("baseline and repaired compiler profiles differ")
        old = next(value for value in baseline["measurements"] if value["fixture_seconds"] == 7200)
        new = next(value for value in result["measurements"] if value["fixture_seconds"] == 7200)
        ratio = new["steady_cpu_seconds"] / old["steady_cpu_seconds"]
        proof = {"equivalent": result["equivalent_to_baseline"], "full_session_steady_cpu_ratio": ratio,
                 "cpu_ratio_limit": 0.5, "passed": result["equivalent_to_baseline"] and ratio <= 0.5}
        (output / "verification.json").write_text(json.dumps(proof, indent=2) + "\n")
        if not proof["passed"]:
            raise ValueError("full-session steady CPU did not improve by at least 2x")


if __name__ == "__main__":
    try:
        run()
    except Exception as error:
        print(f"scripts/transcript-merge-benchmark.py:1: {error} -> inspect the artifact build/run logs", file=sys.stderr)
        sys.exit(1)
