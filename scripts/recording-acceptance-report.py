#!/usr/bin/env python3
"""Summarize immutable recording acceptance receipts without inventing passes."""
import argparse
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text()) if path.exists() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--writer', type=Path, required=True)
    parser.add_argument('--pipeline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    writer = read(args.writer / 'replay' / 'metrics.json')
    pipeline = read(args.pipeline / 'result.json')
    probes = read(args.writer / 'probes.json')
    crash = read(args.writer / 'crash' / 'metrics.json')
    write_failure = read(args.writer / 'write-failure' / 'metrics.json')
    result = {
        'writer_replay': writer,
        'pipeline_replay': pipeline,
        'writer_probes': probes,
        'process_crash_probe': crash,
        'bounded_write_failure_probe': write_failure,
        'all_timed_runs_complete': writer is not None and pipeline is not None,
        'scope_limits': [
            'Capture sources and transcription transport are injected; physical devices and live recognition quality are not measured.',
            'Pipeline process metrics include XCTest and generated callback work, not the installed app compositor.',
            'PCM callbacks in the endurance fixture run on MainActor; legacy backend queue safety is not proven.',
            'Production default system-capture startup delay is eight seconds; fixture delay is zero.',
            'Process termination after completed append is measured; power loss and termination during header rewrite are not.',
            'The ongoing pipeline run predates the close-failure latch; final close-error policy is verified separately by deterministic regressions.',
        ],
    }
    if writer is not None and 'append_cpu_seconds' in writer:
        result['writer_append_wall_seconds'] = writer['append_cpu_seconds']
        result['legacy_metric_note'] = 'The original append_cpu_seconds field measures DispatchTime wall duration including I/O; it is not CPU time. New harness runs name it append_wall_seconds.'
    if pipeline:
        wall = pipeline.get('wall_seconds', 0)
        result['pipeline_mean_cpu_percent_of_one_core'] = 100 * pipeline['cpu_seconds'] / wall if wall else None
        samples = pipeline.get('samples', [])
        if samples:
            result['pipeline_sampled_rss_range_bytes'] = [min(s['rss_bytes'] for s in samples), max(s['rss_bytes'] for s in samples)]
    result['component_pcm_acceptance_passed'] = bool(writer and writer.get('state') == 'passed' and pipeline and pipeline.get('verified_pcm_integrity') and not pipeline.get('fatal_errors') and not pipeline.get('provider_errors'))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'complete': result['all_timed_runs_complete'], 'pcm_passed': result['component_pcm_acceptance_passed'], 'report': str(args.output)}))


if __name__ == '__main__':
    main()
