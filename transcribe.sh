#!/bin/bash
# Turns a nerdsidekiq 2-channel capture into a labelled, time-ordered transcript.
# Channel L = you (microphone). Channel R = everybody else (system audio).
set -euo pipefail

WAV="${1:?usage: transcribe.sh capture.wav}"
MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper/ggml-large-v3-turbo-q5_0.bin}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ffmpeg -y -loglevel error -i "$WAV" -af "pan=mono|c0=c0" -ar 16000 "$WORK/you.wav"
ffmpeg -y -loglevel error -i "$WAV" -af "pan=mono|c0=c1" -ar 16000 "$WORK/them.wav"

for side in you them; do
  whisper-cli -m "$MODEL" -f "$WORK/$side.wav" -oj -of "$WORK/$side" >/dev/null 2>&1
done

python3 - "$WORK/you.json" "$WORK/them.json" <<'PY'
import json, sys

def load(path, label):
    try:
        d = json.load(open(path))
    except Exception:
        return []
    out = []
    for s in d.get("transcription", []):
        text = s.get("text", "").strip()
        if not text or text.startswith("["):
            continue
        out.append((s["offsets"]["from"] / 1000.0, label, text))
    return out

segs = load(sys.argv[1], "You") + load(sys.argv[2], "Them")
segs.sort(key=lambda x: x[0])

for t, who, text in segs:
    print(f"[{int(t)//60:02d}:{int(t)%60:02d}] {who:>4}: {text}")
PY
