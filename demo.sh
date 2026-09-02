#!/bin/bash
# End-to-end demo without clicking: starts the app headlessly, plays a
# synthetic "far side" voice, finishes the call, and waits for the Notion note.
# Usage: ./demo.sh [en|ru]
set -uo pipefail
cd "$(dirname "$0")"

LANG_SEL="${1:-en}"
mkdir -p assets
if [ "$LANG_SEL" = "ru" ]; then
  VOICE=Milena
  TEXT="Здравствуйте, это удалённый участник. Договоримся: дедлайн в следующую пятницу, контракт я пришлю в понедельник."
else
  VOICE=Samantha
  TEXT="Hello, this is the remote participant. Let us agree the deadline is next Friday, and I will send the contract on Monday."
fi
AIFF="assets/remote-$LANG_SEL.aiff"
[ -f "$AIFF" ] || say -v "$VOICE" -o "$AIFF" "$TEXT"

open -a "$PWD/build/NerdSidekiq.app"
sleep 3
echo '{"mode": "transcript", "about": "", "notes_path": ""}' > session.json
notifyutil -p dev.cyberjosef.nerdsidekiq.start
sleep 2
echo ">>> RECORDING — talk over the voice if you want to test your mic <<<"
afplay "$AIFF"
sleep 1
notifyutil -p dev.cyberjosef.nerdsidekiq.finish

# sessions land in the configured transcript folder (settings.json)
REC_DIR="$(python3 -c 'import json;print(json.load(open("settings.json")).get("transcript_dir",""))' 2>/dev/null)"
[ -d "$REC_DIR" ] || REC_DIR="recordings"
DIR="$(ls -td "$REC_DIR"/*/ | head -1)"
echo "processing… ($DIR)"
for _ in $(seq 1 60); do [ -f "$DIR/result.json" ] && break; sleep 5; done
if [ -f "$DIR/result.json" ]; then
  cat "$DIR/result.json"
else
  echo "pipeline did not finish — see $DIR/pipeline.log"
  tail -20 "$DIR/pipeline.log" 2>/dev/null
fi
