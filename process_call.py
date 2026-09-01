#!/usr/bin/env python3
"""process_call.py <session_dir> [name hint]

Post-call pipeline for NerdSidekiq (runs after live_loop.py has stopped):
  1. convert call.raw -> call.wav, split channels (L = you, R = them)
  2. full-quality transcription of the whole call (local whisper-server)
  3. final analysis (Claude): note title + 5-10 sentence summary,
     in the language of the call
  4. Notion: rename the parent note (created live under Meeting notes),
     add "Raw Transcript" and "Final Summary" child notes
     ("Rolling Summary" already exists from the live loop)
  5. write result.json; compress audio -> m4a
"""
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from calllib import (FFMPEG, MEETING_NOTES_PAGE, RAW_RATE, SILENCE_DB,
                     answer_model, channel_to_mp3, chat, create_page, die,
                     ensure_whisper_server, lang_code, log, mean_volume_db,
                     notion_req, notion_token, paragraphs, rt, run, transcribe,
                     transcript_blocks)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def final_analysis(transcript, language, hint):
    prompt = f"""Analyze this job-search call (interview, HR screen or recruiter call).
"You" = the candidate (Sergey), "Them" = the other side.
The call language is {language}.{f' The user labeled the call: "{hint}".' if hint else ''}

Return JSON with exactly these keys:
  "title": a short note title, max 60 characters, in the call language.
           Format: who/company — role or purpose (e.g. "Yandex HR — backend screen").
           Use the company and role from the transcript when present.
  "summary": the main points of the call in 5-10 plain sentences, in the call
             language. Include what was discussed, any numbers (salary, dates),
             agreements and next steps. Facts only, no invention, no bullets.

TRANSCRIPT:
{transcript}"""
    raw = chat(answer_model(), prompt, max_tokens=16000, schema={
        "type": "object",
        "properties": {"title": {"type": "string"},
                       "summary": {"type": "string"}},
        "required": ["title", "summary"],
        "additionalProperties": False})
    try:
        d = json.loads(raw)
        return d["title"].strip(), d["summary"].strip()
    except (json.JSONDecodeError, KeyError):
        die(f"final analysis: bad JSON: {raw[:300]}")


def main():
    if len(sys.argv) < 2:
        die("usage: process_call.py <session_dir> [name hint]")
    workdir = os.path.abspath(sys.argv[1])
    hint = sys.argv[2] if len(sys.argv) > 2 else ""

    raw = os.path.join(workdir, "call.raw")
    wav = os.path.join(workdir, "call.wav")
    if os.path.exists(raw):
        run([FFMPEG, "-y", "-loglevel", "error", "-f", "f32le",
             "-ar", str(RAW_RATE), "-ac", "2", "-i", raw, wav])
    if not os.path.exists(wav):
        die(f"no call.raw / call.wav in {workdir}")

    ntoken = notion_token()
    ensure_whisper_server()

    log("splitting channels…")
    sides = {}
    for side, chan in (("you", "c0"), ("them", "c1")):
        mp3 = os.path.join(workdir, f"{side}.mp3")
        channel_to_mp3(["-i", wav], chan, mp3)
        sides[side] = mp3

    segs, langs = {}, {}
    for side, label in (("you", "You"), ("them", "Them")):
        vol = mean_volume_db(sides[side])
        if vol < SILENCE_DB:
            log(f"{side}: silent ({vol:.1f} dB) — skipped")
            segs[side] = []
            continue
        log(f"{side}: transcribing ({vol:.1f} dB)…")
        s, lang = transcribe(sides[side])
        segs[side] = [(t, end, label, txt) for t, end, txt in s]
        if lang:
            langs[side] = lang
        log(f"{side}: {len(s)} segments, language={lang}")

    merged = sorted(segs["you"] + segs["them"], key=lambda x: x[0])
    if not merged:
        die("no speech found on either channel")
    lines = [f"[{int(t)//60:02d}:{int(t)%60:02d}] {who}: {txt}" for t, _, who, txt in merged]
    transcript = "\n".join(lines)
    with open(os.path.join(workdir, "transcript.txt"), "w") as f:
        f.write(transcript + "\n")

    lang_raw = langs.get("them") or langs.get("you") or "unknown"
    lang = lang_code(lang_raw)
    log(f"call language: {lang} ({lang_raw})")

    log(f"final analysis with {answer_model()}…")
    title, summary = final_analysis(transcript, lang_raw, hint)
    log(f"title: {title}")
    with open(os.path.join(workdir, "summary.md"), "w") as f:
        f.write(f"# {title}\n\n{summary}\n")

    now = datetime.now()
    duration = max(end for _, end, _, _ in merged)
    live = load_json(os.path.join(workdir, "live.json"))

    parent_id = parent_url = None
    if not ntoken:
        log("Notion not configured — transcript and summary stay local")
    elif live and live.get("parent_id"):
        log("saving to Notion…")
        parent_id = live["parent_id"]
        notion_req("PATCH", f"pages/{parent_id}", ntoken, {
            "properties": {"title": {"title": rt(f"{title} — {now.strftime('%Y-%m-%d')}")}},
            "icon": {"type": "emoji", "emoji": "📞"}})
        parent_url = live.get("parent_url")
    else:
        log("saving to Notion (no live.json — creating the parent note now)…")
        page = create_page(ntoken, MEETING_NOTES_PAGE,
                           f"{title} — {now.strftime('%Y-%m-%d')}", "📞", [])
        parent_id, parent_url = page["id"], page.get("url")

    if ntoken and parent_id:
        notion_req("PATCH", f"blocks/{parent_id}/children", ntoken, {"children": [
            {"type": "paragraph", "paragraph": {"rich_text": rt(
                f"📅 {now.strftime('%Y-%m-%d %H:%M')}   ·   🌐 {lang}   ·   ⏱ "
                f"{int(duration)//60} min {int(duration)%60} s   ·   recorded by NerdSidekiq")}}]})
        create_page(ntoken, parent_id, "Raw Transcript", "📝", transcript_blocks(lines))
        create_page(ntoken, parent_id, f"Final Summary ({lang})", "✅", paragraphs(summary))

    result = {"notion_url": parent_url, "page_id": parent_id, "title": title,
              "language": lang, "duration_s": int(duration)}
    with open(os.path.join(workdir, "result.json"), "w") as f:
        json.dump(result, f, indent=2)

    # keep disk lean: raw/wav -> m4a
    m4a = os.path.join(workdir, "call.m4a")
    run([FFMPEG, "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "96k", m4a])
    for f in [raw, wav, sides["you"], sides["them"],
              os.path.join(workdir, "live-you.mp3"), os.path.join(workdir, "live-them.mp3")]:
        if os.path.exists(f):
            os.remove(f)

    log(f"done: {parent_url}")


if __name__ == "__main__":
    main()
