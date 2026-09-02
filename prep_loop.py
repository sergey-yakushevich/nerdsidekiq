#!/usr/bin/env python3
"""prep_loop.py <session_dir>

Mock-interview coach (the "Interview Preparation" mode). Started by the app
together with the recorder. The AI plays the interviewer in the overlay:
it prints questions, transcribes your spoken answers from the mic channel,
detects when you stop talking (a pause of PAUSE_S seconds), judges whether
the answer is finished (asks if unsure), streams coaching feedback, asks you
to recite an improved answer, then moves to the next question.

Reads <session_dir>/prep.json: {"about": "...", "notes_path": "..."}
Writes <session_dir>/prep_transcript.txt (the full dialogue).

Events to the overlay (http://127.0.0.1:17865/assist):
  captions            dialogue bubbles (Them = interviewer, You = your voice)
  question/delta/done coach pane (streamed feedback)
  status              footer status line
"""
import json
import os
import signal
import sys
import time
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from calllib import (RAW_FRAME_BYTES, RAW_RATE, SILENCE_DB, answer_model,
                     channel_to_mp3, chat, chat_stream, die,
                     ensure_whisper_server, log, mean_volume_db, rolling_model,
                     transcribe)

CYCLE = float(os.environ.get("NERDSIDEKIQ_PREP_CYCLE_S", "2.5"))
WINDOW = float(os.environ.get("NERDSIDEKIQ_PREP_WINDOW_S", "30"))
PAUSE_S = float(os.environ.get("NERDSIDEKIQ_PREP_PAUSE_S", "5"))
GIVE_UP_S = float(os.environ.get("NERDSIDEKIQ_PREP_GIVEUP_S", "20"))
NUM_QUESTIONS = int(os.environ.get("NERDSIDEKIQ_PREP_QUESTIONS", "6"))
TAIL_S = 1.6            # audio tail checked for "still speaking" energy
SPEECH_DB = -45.0       # louder than this in the tail = still speaking
OVERLAY_URL = "http://127.0.0.1:17865/assist"


class Prep:
    def __init__(self, session_dir):
        self.dir = session_dir
        self.raw = os.path.join(session_dir, "call.raw")
        cfg = {}
        try:
            with open(os.path.join(session_dir, "prep.json")) as f:
                cfg = json.load(f)
        except (OSError, json.JSONDecodeError):
            pass
        self.about = (cfg.get("about") or "").strip()
        self.notes = ""
        p = os.path.expanduser((cfg.get("notes_path") or "").strip())
        if p and os.path.isfile(p):
            try:
                with open(p, encoding="utf-8", errors="replace") as f:
                    self.notes = f.read()[:6000]
                log(f"notes loaded: {p} ({len(self.notes)} chars)")
            except OSError as e:
                log(f"cannot read notes {p}: {e}")
        self.dialog = []        # [(who, text)]
        self.t0 = time.time()
        self.stopping = False
        self.last_end = 0.0     # transcription cursor in call.raw seconds
        self.recent = []        # last texts, dedupe across windows

    # ---------- overlay ----------

    def overlay_post(self, event):
        try:
            req = urllib.request.Request(
                OVERLAY_URL, data=json.dumps(event).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=2).read()
        except OSError:
            pass  # overlay not running — events silently skipped

    def stamp(self):
        s = int(time.time() - self.t0)
        return f"{s // 60:02d}:{s % 60:02d}"

    def say(self, text):
        """Interviewer speaks (a chat bubble with the mascot avatar)."""
        self.dialog.append(("Them", text, self.stamp()))
        self.overlay_post({"type": "prep_add", "who": "them", "text": text})
        self.save_transcript()
        log(f"interviewer: {text[:80]}")

    def heard(self, text):
        self.dialog.append(("You", text, self.stamp()))
        self.overlay_post({"type": "prep_add", "who": "you", "text": text})

    def status(self, text):
        self.overlay_post({"type": "status", "text": text})

    def thinking(self, on):
        """Typing-dots indicator in the chat."""
        self.overlay_post({"type": "thinking", "on": bool(on)})

    # ---------- listening ----------

    def new_text(self):
        """Transcribe the last WINDOW seconds of the mic channel, return
        only lines not seen before."""
        try:
            size = os.path.getsize(self.raw)
        except OSError:
            return []
        total_s = (size // RAW_FRAME_BYTES) / RAW_RATE
        if total_s < 1.5:
            return []
        win_start = max(0.0, total_s - WINDOW)
        offset = int(win_start * RAW_RATE) * RAW_FRAME_BYTES
        with open(self.raw, "rb") as f:
            f.seek(offset)
            blob = f.read(size - offset)
        mp3 = os.path.join(self.dir, "prep-you.mp3")
        channel_to_mp3(["-f", "f32le", "-ar", str(RAW_RATE), "-ac", "2", "-i", "-"],
                       "c0", mp3, input_bytes=blob)
        if mean_volume_db(mp3) < SILENCE_DB:
            return []
        segs, _ = transcribe(mp3)
        win_len = len(blob) / (RAW_FRAME_BYTES * RAW_RATE)
        out = []
        for s, e, txt in segs:
            start, end = win_start + s, win_start + e
            # a segment that touches the window end is still being spoken —
            # leave it for the next cycle so we never commit half a sentence
            if e > win_len - 1.2:
                continue
            if start < self.last_end - 0.3:
                continue
            if txt in self.recent[-3:]:
                continue
            self.last_end = max(self.last_end, end)
            self.recent = (self.recent + [txt])[-5:]
            out.append(txt)
        return out

    def speaking_now(self):
        """Energy check on the audio tail — catches speech before the
        transcription confirms it."""
        try:
            size = os.path.getsize(self.raw)
        except OSError:
            return False
        tail = int(TAIL_S * RAW_RATE) * RAW_FRAME_BYTES
        if size < tail:
            return False
        with open(self.raw, "rb") as f:
            f.seek(size - tail)
            blob = f.read(tail)
        mp3 = os.path.join(self.dir, "prep-tail.mp3")
        channel_to_mp3(["-f", "f32le", "-ar", str(RAW_RATE), "-ac", "2", "-i", "-"],
                       "c0", mp3, input_bytes=blob)
        return mean_volume_db(mp3) > SPEECH_DB

    def collect_speech(self, first_timeout=None):
        """Wait for speech, then keep listening until a PAUSE_S pause.
        Returns the spoken text; "" if first_timeout passed with no speech."""
        parts = []
        waited_from = time.time()
        last_voice = time.time()
        while not self.stopping:
            time.sleep(CYCLE)
            lines = self.new_text()
            if lines:
                for t in lines:
                    self.heard(t)
                parts += lines
                last_voice = time.time()
            elif self.speaking_now():
                last_voice = time.time()
            if parts and time.time() - last_voice >= PAUSE_S:
                break
            if not parts and first_timeout is not None \
                    and time.time() - waited_from >= first_timeout:
                return ""
        self.save_transcript()
        return " ".join(parts)

    # ---------- judging ----------

    def safe(self, fn, fallback):
        """One failed AI call must not kill the mock interview."""
        try:
            return fn()
        except (Exception, SystemExit) as e:
            log(f"AI call failed (continuing): {e}")
            return fallback

    def judge_finished(self, question, answer):
        prompt = f"""Live mock job interview. The interviewer asked:
"{question}"
The candidate answered out loud (voice transcription, small errors possible):
"{answer}"
The candidate has now paused for {PAUSE_S:.0f}+ seconds.

Is the answer finished?
- "finished": it reads as a complete answer (even a short or a weak one)
- "more": it clearly stops mid-thought / mid-sentence
- "unsure": cannot tell
Return JSON: {{"verdict": "finished"|"more"|"unsure"}}"""
        raw = self.safe(lambda: chat(rolling_model(), prompt, effort="low", schema={
            "type": "object",
            "properties": {"verdict": {"type": "string",
                                       "enum": ["finished", "more", "unsure"]}},
            "required": ["verdict"], "additionalProperties": False}), "")
        try:
            return json.loads(raw)["verdict"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return "finished"

    def judge_confirmation(self, reply):
        prompt = f"""In a mock interview the interviewer just asked the candidate:
"Did you finish your answer, or do you need more time?"
The candidate then said: "{reply}"

Is this a confirmation that they are done (e.g. "yes", "done", "that's it"),
or is it a continuation of the actual answer?
Return JSON: {{"done": true|false}}"""
        raw = self.safe(lambda: chat(rolling_model(), prompt, effort="low", schema={
            "type": "object", "properties": {"done": {"type": "boolean"}},
            "required": ["done"], "additionalProperties": False}), "")
        try:
            return bool(json.loads(raw)["done"])
        except (json.JSONDecodeError, KeyError, TypeError):
            return True

    def answer_turn(self, question):
        """One full spoken answer: listen -> pause -> judge; ask if unsure."""
        self.status("Listening — answer out loud…")
        text = self.collect_speech()
        while not self.stopping:
            self.status("Checking your answer…")
            self.thinking(True)
            verdict = self.judge_finished(question, text)
            self.thinking(False)
            if verdict == "finished":
                return text
            if verdict == "more":
                self.status("Sounds unfinished — take your time.")
                extra = self.collect_speech(first_timeout=GIVE_UP_S)
                if not extra:
                    return text
                text += " " + extra
                continue
            # unsure -> ask
            self.say("Did you finish your answer, or do you need more time?")
            self.status("Listening…")
            extra = self.collect_speech(first_timeout=GIVE_UP_S)
            if not extra:
                return text
            self.thinking(True)
            done = self.judge_confirmation(extra)
            self.thinking(False)
            if done:
                return text
            text += " " + extra
        return text

    # ---------- coaching ----------

    def stream_coach(self, label, prompt):
        """Streams into a Coach bubble; typing dots show until the first
        token arrives (the overlay swaps them for the bubble)."""
        self.status("Coaching…")
        self.thinking(True)
        started = []

        def on_delta(piece):
            if not started:
                started.append(1)
                self.overlay_post({"type": "question", "question": label})
            self.overlay_post({"type": "delta", "text": piece})

        out = self.safe(lambda: chat_stream(answer_model(), prompt, on_delta),
                        "(coaching unavailable — API error, see live.log)")
        if not started:  # stream failed before the first token
            self.overlay_post({"type": "question", "question": label})
            self.overlay_post({"type": "delta", "text": out})
        self.thinking(False)
        self.overlay_post({"type": "done"})
        return out

    def feedback(self, n, question, answer):
        prompt = f"""You are an interview coach in a live mock interview.
Interview context: {self.about or "(not given)"}
Candidate notes (may be empty):
{self.notes[:3000] or "(none)"}

Question {n}: "{question}"
The candidate answered out loud (voice transcription, small errors possible):
"{answer}"

Reply in the language of the answer, max 170 words, GitHub markdown:
**What worked** — 1-2 short bullets
**What to improve** — 2-3 short bullets (missing points, structure, specifics)
**Stronger answer outline** — 3-5 crisp bullets the candidate can recite
Do not mention the transcription. No preamble."""
        return self.stream_coach(f"Q{n} · feedback", prompt)

    def recite_review(self, n, question, coaching, recite):
        prompt = f"""You are an interview coach in a live mock interview.
Question {n}: "{question}"
Your earlier coaching:
{coaching}
The candidate then recited an improved answer out loud:
"{recite}"

In the language of the answer, max 60 words: one encouraging line on what
got better, and at most one remaining gap. Then say you are moving on.
No preamble."""
        return self.stream_coach(f"Q{n} · take two", prompt)

    # ---------- questions ----------

    def gen_questions(self):
        prompt = f"""You prepare a candidate with a realistic mock job interview.
Interview context (written by the candidate): {self.about or "(not given)"}
Candidate notes (may include common questions or a CV):
{self.notes[:5000] or "(none)"}

Write exactly {NUM_QUESTIONS} interview questions for this position, ordered
like a real interview: a short intro question first, then experience,
then technical/behavioral depth, then a closing question.
Write the questions in the language the context text above is WRITTEN in
(not the language of the company's country).
Return JSON: {{"questions": ["...", ...]}}"""
        raw = chat(answer_model(), prompt, schema={
            "type": "object",
            "properties": {"questions": {"type": "array",
                                         "items": {"type": "string"}}},
            "required": ["questions"], "additionalProperties": False})
        try:
            qs = [q.strip() for q in json.loads(raw)["questions"] if q.strip()]
        except (json.JSONDecodeError, KeyError):
            die(f"question generation: bad JSON: {raw[:300]}")
        return qs[:NUM_QUESTIONS]

    # ---------- persistence ----------

    def save_transcript(self):
        path = os.path.join(self.dir, "prep_transcript.txt")
        with open(path, "w") as f:
            for who, text, t in self.dialog:
                f.write(f"[{t}] {'Interviewer' if who == 'Them' else 'You'}: {text}\n")

    def stop(self, *_):
        self.stopping = True

    # ---------- main flow ----------

    def run(self):
        self.status("Preparing your interviewer…")
        self.thinking(True)
        qs = self.gen_questions()
        self.thinking(False)
        log(f"{len(qs)} questions ready")
        self.say(f"Hi! I am your interviewer today. I have {len(qs)} questions. "
                 "Answer out loud; when you finish an answer, just pause for "
                 f"about {PAUSE_S:.0f} seconds. Let's start.")
        for i, q in enumerate(qs, 1):
            if self.stopping:
                break
            self.say(f"Question {i}/{len(qs)}: {q}")
            answer = self.answer_turn(q)
            if self.stopping:
                break
            if not answer:
                continue
            coaching = self.feedback(i, q, answer)
            if self.stopping:
                break
            self.say("Now recite the improved answer in your own words.")
            recite = self.answer_turn(q)
            if self.stopping:
                break
            if recite:
                self.recite_review(i, q, coaching, recite)
        if not self.stopping:
            self.say("That was my last question — great work today. "
                     "Click End when you are ready.")
            self.status("Mock interview finished — click End.")
        self.save_transcript()


def main():
    if len(sys.argv) < 2:
        die("usage: prep_loop.py <session_dir>")
    prep = Prep(sys.argv[1])
    signal.signal(signal.SIGTERM, prep.stop)
    signal.signal(signal.SIGINT, prep.stop)
    ensure_whisper_server()
    log(f"prep loop: cycle {CYCLE:.1f}s, pause {PAUSE_S:.0f}s, "
        f"coach={answer_model()} checks={rolling_model()}")
    try:
        prep.run()
    finally:
        prep.save_transcript()
        log("prep loop stopped")


if __name__ == "__main__":
    main()
