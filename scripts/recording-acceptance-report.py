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
    parser.add_argument('--pipeline-accelerated', type=Path)
    parser.add_argument('--pipeline-baseline', type=Path)
    args = parser.parse_args()
    writer = read(args.writer / 'replay' / 'metrics.json')
    pipeline = read(args.pipeline / 'result.json')
    accelerated = read(args.pipeline_accelerated / 'result.json') if args.pipeline_accelerated else None
    baseline_progress = read(args.pipeline_baseline / 'progress.json') if args.pipeline_baseline else None
    baseline_stop = read(args.pipeline_baseline / 'stopped.json') if args.pipeline_baseline else None
    probes = read(args.writer / 'probes.json')
    crash = read(args.writer / 'crash' / 'metrics.json')
    write_failure = read(args.writer / 'write-failure' / 'metrics.json')
    result = {
        'writer_replay': writer,
        'pipeline_replay': pipeline,
        'accelerated_pipeline_replay': accelerated,
        'baseline_pipeline': {
            'outcome': baseline_stop,
            'latest_sample': baseline_progress['samples'][-1] if baseline_progress and baseline_progress.get('samples') else None,
            'pcm_completion_verified': False,
        } if args.pipeline_baseline else None,
        'writer_probes': probes,
        'process_crash_probe': crash,
        'bounded_write_failure_probe': write_failure,
        'all_timed_runs_complete': writer is not None and pipeline is not None and (not args.pipeline_accelerated or accelerated is not None),
        'scope_limits': [
            'Capture sources and transcription transport are injected; physical devices and live recognition quality are not measured.',
            'Pipeline process metrics include XCTest and generated callback work, not the installed app compositor.',
            'PCM callbacks in the endurance fixture run on MainActor; legacy backend queue safety is not proven.',
            'Production default system-capture startup delay is eight seconds; fixture delay is zero.',
            'Process termination after completed append is measured; power loss and termination during header rewrite are not.',
            'Historical baseline and repaired replays have separate source-hash receipts; baseline PCM completion is not claimed.',
            'Accelerated replay verifies the full playback workload but does not establish real-time scheduling or physical capture behaviour.',
            'Historical writer peak RSS includes verification-read autoreleases; follow-up matched replays isolate this harness overhead. New harness runs record recording-phase RSS separately.',
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
    def pipeline_passed(value):
        return bool(value and value.get('state') == 'complete' and value.get('verified_pcm_integrity') is True and value.get('recording_closed_cleanly') is True and value.get('fatal_errors') == [] and value.get('provider_errors') == [])
    result['controlled_failure_probes_passed'] = bool(probes and probes.get('passed') is True and crash and crash.get('passed') is True and write_failure and write_failure.get('passed') is True)
    result['component_pcm_acceptance_passed'] = bool(writer and writer.get('state') == 'passed' and pipeline_passed(pipeline) and (not args.pipeline_accelerated or pipeline_passed(accelerated)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'complete': result['all_timed_runs_complete'], 'pcm_passed': result['component_pcm_acceptance_passed'], 'report': str(args.output)}))


if __name__ == '__main__':
    main()
