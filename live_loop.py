#!/usr/bin/env python3
"""live_loop.py <session_dir> [name hint]

Runs DURING the call, started by the app together with the recorder.
Every CYCLE seconds it takes the last WINDOW seconds of call.raw,
transcribes both sides (local whisper-server), appends the new lines to a
running transcript, streams captions to the overlay, and updates a
"Rolling Summary" note in Notion (Claude). On SIGTERM it saves its state
for process_call.py.

Files it writes into <session_dir>:
  live.json            parent/rolling page ids + parent url (written at start)
  live_transcript.txt  the running transcript
  live_state.json      final state for process_call.py (written on exit)
"""
import json
import os
import signal
import sys
import threading
import time
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from calllib import (MEETING_NOTES_PAGE, RAW_RATE, RAW_FRAME_BYTES,
                     SILENCE_DB, answer_model, channel_to_mp3, chat, chat_stream,
                     create_page, die, ensure_whisper_server, lang_code,
                     load_settings, log, mean_volume_db, notion_req, notion_token,
                     rolling_model, rt, transcribe)

CYCLE = float(os.environ.get("NERDSIDEKIQ_CYCLE_S", "4"))
WINDOW = float(os.environ.get("NERDSIDEKIQ_WINDOW_S", "60"))
SUMMARY_EVERY = float(os.environ.get("NERDSIDEKIQ_SUMMARY_S", "30"))
# "transcript" = captions only, "sidekiq" = captions + streamed answer tips.
# Empty (legacy headless start) falls back to the settings.json "hints" flag.
MODE = os.environ.get("NERDSIDEKIQ_MODE", "")
MAX_CONTEXT_CHARS = 6000
OVERLAY_URL = "http://127.0.0.1:17865/assist"


class Live:
    def __init__(self, session_dir, hint):
        self.dir = session_dir
        self.raw = os.path.join(session_dir, "call.raw")
        self.hint = hint
        self.ntoken = notion_token()
        self.last_end = {"you": 0.0, "them": 0.0}
        self.recent = {"you": [], "them": []}   # last texts, extra dedupe
        self.lines = []
        self.language = ""
        self.summary = ""
        self.stopping = False
        self.answered = []          # questions already handled (normalized)
        self.hint_busy = False
        self.last_summary_at = 0.0

    def setup_notion(self):
        if not self.ntoken:
            return  # Notion optional — captions and hints still work
        title = f"{self.hint or 'Call'} — in progress {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        parent = create_page(self.ntoken, MEETING_NOTES_PAGE, title, "📞", [])
        rolling = create_page(self.ntoken, parent["id"], "Rolling Summary", "🔄", [])
        added = notion_req("PATCH", f"blocks/{rolling['id']}/children", self.ntoken, {
            "children": [{"type": "paragraph",
                          "paragraph": {"rich_text": rt("Listening…")}}]})
        self.rolling_block = added["results"][0]["id"]
        self.parent_id = parent["id"]
        self.rolling_id = rolling["id"]
        with open(os.path.join(self.dir, "live.json"), "w") as f:
            json.dump({"parent_id": parent["id"], "parent_url": parent.get("url"),
                       "rolling_page_id": rolling["id"],
                       "rolling_block_id": self.rolling_block}, f, indent=2)
        log(f"notion ready: {parent.get('url')}")

    def cycle(self):
        try:
            size = os.path.getsize(self.raw)
        except OSError:
            return
        total_s = (size // RAW_FRAME_BYTES) / RAW_RATE
        if total_s < 3:
            return
        win_start = max(0.0, total_s - WINDOW)
        offset = int(win_start * RAW_RATE) * RAW_FRAME_BYTES
        with open(self.raw, "rb") as f:
            f.seek(offset)
            blob = f.read(size - offset)

        new_lines = []
        for side, chan, label in (("you", "c0", "You"), ("them", "c1", "Them")):
            mp3 = os.path.join(self.dir, f"live-{side}.mp3")
            channel_to_mp3(["-f", "f32le", "-ar", str(RAW_RATE), "-ac", "2", "-i", "-"],
                           chan, mp3, input_bytes=blob)
            if mean_volume_db(mp3) < SILENCE_DB:
                continue
            segs, lang = transcribe(mp3)
            if lang:
                self.language = lang
            for s, e, txt in segs:
                start, end = win_start + s, win_start + e
                if start < self.last_end[side] - 0.3:
                    continue
                if txt in self.recent[side][-3:]:
                    continue
                self.last_end[side] = max(self.last_end[side], end)
                self.recent[side].append(txt)
                self.recent[side] = self.recent[side][-5:]
                new_lines.append((start, label, txt))

        if not new_lines:
            return
        new_lines.sort(key=lambda x: x[0])
        for t, who, txt in new_lines:
            self.lines.append(f"[{int(t)//60:02d}:{int(t)%60:02d}] {who}: {txt}")
        with open(os.path.join(self.dir, "live_transcript.txt"), "w") as f:
            f.write("\n".join(self.lines) + "\n")
        log(f"+{len(new_lines)} lines (total {len(self.lines)})")
        self.push_captions()
        hints = MODE == "sidekiq" if MODE else load_settings().get("hints", False)
        if hints:
            self.maybe_hint()
        # the rolling Notion summary is slow (a Claude call) — throttle it so
        # captions and question detection stay on the fast CYCLE cadence
        if self.ntoken and time.time() - self.last_summary_at >= SUMMARY_EVERY:
            self.last_summary_at = time.time()
            self.update_summary()

    def update_summary(self):
        context = "\n".join(self.lines)[-MAX_CONTEXT_CHARS:]
        prompt = f"""This is a live, partial transcript of an ongoing call (a job-search call:
interview, HR screen or recruiter call). "You" = the candidate, "Them" = the other side.
The transcript may contain small transcription errors near chunk borders.

Previous rolling summary:
{self.summary or '(none yet)'}

Transcript so far (may be truncated at the start):
{context}

Write the UPDATED rolling summary of the call so far. Language: {self.language or 'same as the call'}.
Max 1200 characters. Use short "- " bullet lines. Facts only, no invention.
Reply with the summary text only — no preamble."""
        self.summary = chat(rolling_model(), prompt, effort="low")
        stamp = datetime.now().strftime("%H:%M:%S")
        notion_req("PATCH", f"blocks/{self.rolling_block}", self.ntoken, {
            "paragraph": {"rich_text": rt(self.summary[:1900] + f"\n\n(updated {stamp})")}})
        log("rolling summary updated")

    # ---------- interview hints (floating Electron overlay) ----------

    def overlay_post(self, event):
        try:
            req = urllib.request.Request(
                OVERLAY_URL, data=json.dumps(event).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=2).read()
        except OSError:
            pass  # overlay not running — events silently skipped

    def push_captions(self):
        """Live subtitles for the overlay sidebar."""
        lines = []
        for raw_line in self.lines[-40:]:
            # "[MM:SS] Who: text"
            try:
                stamp, rest = raw_line.split("] ", 1)
                who, text = rest.split(": ", 1)
                lines.append({"t": stamp.lstrip("["), "who": who, "text": text})
            except ValueError:
                continue
        self.overlay_post({"type": "captions", "lines": lines})

    def maybe_hint(self):
        if self.hint_busy:
            return
        recent = "\n".join(self.lines[-14:])
        prompt = f"""Live job-interview transcript. "You" = the candidate, "Them" = interviewer.
Recent lines:
{recent}

Questions already handled: {json.dumps(self.answered[-5:])}

Did "Them" just ask the candidate a NEW substantive question (technical,
experience, opinion, salary) that is not in the handled list and that the
candidate has not fully answered yet? Small talk does not count.
Return JSON: {{"question": "the question text"}} or {{"question": null}}."""
        raw = chat(rolling_model(), prompt, effort="low", schema={
            "type": "object",
            "properties": {"question": {"type": ["string", "null"]}},
            "required": ["question"],
            "additionalProperties": False})
        try:
            q = json.loads(raw).get("question")
        except json.JSONDecodeError:
            return
        if not q or q.strip().lower() in self.answered:
            return
        self.answered.append(q.strip().lower())
        self.hint_busy = True
        threading.Thread(target=self.stream_hint, args=(q,), daemon=True).start()

    def stream_hint(self, question):
        try:
            log(f"hint: {question}")
            self.overlay_post({"type": "question", "question": question})
            prompt = f"""You quietly help a candidate during a live job interview.
The interviewer asked: "{question}"
Context (recent transcript):
{chr(10).join(self.lines[-20:])}

Give the candidate a strong talking-point answer. HARD LIMIT: 120 words of prose.
Answer in the language of the question. GitHub-flavored markdown: you may use
**bold**, short bullets, `inline code`, and a fenced code block (```lang) when
the question asks for code. No preamble — start with the substance."""
            buf = []

            def on_delta(piece):
                buf.append(piece)
                self.overlay_post({"type": "delta", "text": piece})

            chat_stream(answer_model(), prompt, on_delta)
            self.overlay_post({"type": "done"})
            log(f"hint done ({len(''.join(buf).split())} words)")
        except Exception as e:
            log(f"hint error: {e}")
            self.overlay_post({"type": "done"})
        finally:
            self.hint_busy = False

    def save_state(self):
        with open(os.path.join(self.dir, "live_state.json"), "w") as f:
            json.dump({"lines": self.lines, "language": self.language,
                       "summary": self.summary,
                       "lang_code": lang_code(self.language)}, f, indent=2)

    def stop(self, *_):
        self.stopping = True


def main():
    if len(sys.argv) < 2:
        die("usage: live_loop.py <session_dir> [name hint]")
    live = Live(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    signal.signal(signal.SIGTERM, live.stop)
    signal.signal(signal.SIGINT, live.stop)
    ensure_whisper_server()
    live.setup_notion()
    log(f"live loop: every {CYCLE:.0f}s, window {WINDOW:.0f}s, "
        f"rolling={rolling_model()} answers={answer_model()}")
    next_at = time.time() + CYCLE
    while not live.stopping:
        time.sleep(0.3)
        if time.time() < next_at:
            continue
        try:
            live.cycle()
        except (Exception, SystemExit) as e:
            # never let one bad cycle (interrupted curl, transient API error)
            # kill the live loop — the next cycle retries with a fresh window
            log(f"cycle error (continuing): {e}")
        live.save_state()
        next_at = time.time() + CYCLE
    live.save_state()
    log("live loop stopped")


if __name__ == "__main__":
    main()
