#!/usr/bin/env python3
"""Create invented bilingual PCM sources locally. No capture or cloud API."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    phrases = [
        ('english', 'Samantha', 'Synthetic meeting test. Marker one. Confirm the meeting notes and the next review. One, two, three. This is invented test speech.'),
        ('mandarin', 'Tingting', '这是一段合成会议测试录音。标记一。请确认会议记录和下次讨论时间。一，二，三。这不是客户资料。'),
    ]
    payloads = []
    for name, voice, text in phrases:
        source = root / (name + '.aiff')
        target = root / (name + '.wav')
        subprocess.run(['/usr/bin/say', '-v', voice, '-r', '170', '-o', str(source), text], check=True)
        subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(source), str(target)], check=True)
        with wave.open(str(target), 'rb') as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                raise RuntimeError('Unexpected generated PCM format')
            payloads.append(audio.readframes(audio.getnframes()))
    silence = bytes(32000)
    manifest = {'source': 'Local macOS speech synthesis; invented English and Mandarin text', 'macOS': platform.mac_ver()[0], 'sample_rate': 16000, 'channels': 1, 'sample_width_bytes': 2, 'voices': [p[1] for p in phrases], 'files': {}}
    for name, speech in [('mic.wav', payloads), ('system.wav', payloads[::-1])]:
        payload = silence + speech[0] + silence + speech[1] + silence
        with wave.open(str(root / name), 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(payload)
        manifest['files'][name] = {'frames': len(payload) // 2, 'duration_seconds': len(payload) / 32000, 'pcm_sha256': hashlib.sha256(payload).hexdigest()}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(str(root / 'manifest.json'))


if __name__ == '__main__':
    main()
