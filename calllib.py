"""Shared helpers for NerdSidekiq pipelines (live_loop.py, process_call.py).

AI: the user's own Claude account via the Anthropic SDK. Credentials resolve
from ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or the `ant auth login` OAuth
profile (~/.config/anthropic) — authorize once with: ant auth login

Other secrets, read at runtime and never printed:
  OPENAI_API_KEY  from OPENAI_ENV_FILE (only for NERDSIDEKIQ_STT=openai fallback)
  NOTION_TOKEN    from ~/.claude.json (notion-local MCP server env)
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime

FFMPEG = "/opt/homebrew/bin/ffmpeg"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OPENAI_ENV_FILE = os.environ.get(
    "OPENAI_ENV_FILE", "/Users/test/Code/ai-search-optimisation/lead-magnet/.env")

# Claude models. The user picks them in Settings (settings.json); env overrides win.
#   answer_model  — interview hints + final title/summary
#   rolling_model — rolling summary + question detection (runs every ~10 s)
DEFAULT_MODEL = "claude-opus-5"
MODEL_CHOICES = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
                 "claude-opus-4-8"]

# Local whisper (whisper.cpp server): the model loads once and stays warm.
STT_MODE = os.environ.get("NERDSIDEKIQ_STT", "local")     # local | openai
WHISPER_PORT = int(os.environ.get("NERDSIDEKIQ_WHISPER_PORT", "8178"))
WHISPER_MODEL = os.environ.get(
    "NERDSIDEKIQ_WHISPER_MODEL",
    os.path.expanduser("~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"))
WHISPER_SERVER = "/opt/homebrew/bin/whisper-server"
MEETING_NOTES_PAGE = "3cec798c-0744-80cb-9fe0-cf1872904f0b"  # Job search > Meeting notes
NOTION_VERSION = "2022-06-28"
SILENCE_DB = -60.0  # channels quieter than this are skipped (no hallucinations)

RAW_RATE = 48000          # call.raw layout: float32le, interleaved
RAW_CHANNELS = 2          # L = you (mic), R = them (system audio)
RAW_FRAME_BYTES = RAW_CHANNELS * 4


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def die(msg):
    log(f"ERROR: {msg}")
    sys.exit(1)


# ---------- secrets ----------

def openai_key():
    try:
        with open(OPENAI_ENV_FILE) as f:
            for line in f:
                m = re.match(r"^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.+?)\s*$", line)
                if m:
                    return m.group(1).strip("'\"")
    except OSError as e:
        die(f"cannot read {OPENAI_ENV_FILE}: {e}")
    die(f"OPENAI_API_KEY not found in {OPENAI_ENV_FILE}")


def notion_token():
    path = os.path.expanduser("~/.claude.json")
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        log("Notion not configured (~/.claude.json unreadable) — notes stay local only")
        return None

    def walk(obj):
        if isinstance(obj, dict):
            srv = obj.get("notion-local")
            if isinstance(srv, dict):
                tok = srv.get("env", {}).get("NOTION_TOKEN")
                if tok:
                    return tok
            for v in obj.values():
                got = walk(v)
                if got:
                    return got
        elif isinstance(obj, list):
            for v in obj:
                got = walk(v)
                if got:
                    return got
        return None

    tok = walk(cfg)
    if not tok:
        log("Notion not configured (no NOTION_TOKEN) — notes stay local only")
        return None
    return tok


# ---------- audio ----------

def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        die(f"command failed: {' '.join(cmd)}\n{p.stderr[-2000:]}")
    return p


def channel_to_mp3(src_args, chan, out_mp3, input_bytes=None):
    """Extract one channel to 16 kHz mono mp3. src_args is the ffmpeg input
    spec; pass input_bytes to feed raw data on stdin."""
    cmd = [FFMPEG, "-y", "-loglevel", "error"] + src_args + [
        "-af", f"pan=mono|c0={chan}", "-ar", "16000", "-b:a", "48k", out_mp3]
    p = subprocess.run(cmd, input=input_bytes, capture_output=True)
    if p.returncode != 0:
        die(f"ffmpeg channel extract failed: {p.stderr.decode()[-800:]}")


def mean_volume_db(path):
    p = subprocess.run(
        [FFMPEG, "-i", path, "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True)
    m = re.search(r"mean_volume:\s*(-?[\d.]+)\s*dB", p.stderr)
    return float(m.group(1)) if m else -99.0


# ---------- transcription (local whisper server, OpenAI fallback) ----------

def ensure_whisper_server():
    """Start whisper-server if it is not already answering. Stays running
    between calls so the model loads only once."""
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{WHISPER_PORT}/", timeout=2)
        return
    except urllib.error.HTTPError:
        return  # answered (even an error page means the server is up)
    except OSError:
        pass
    if not os.path.exists(WHISPER_MODEL):
        die(f"whisper model not found: {WHISPER_MODEL}")
    logdir = os.path.join(BASE_DIR, "logs")
    os.makedirs(logdir, exist_ok=True)
    logf = open(os.path.join(logdir, "whisper-server.log"), "ab")
    proc = subprocess.Popen(
        [WHISPER_SERVER, "-m", WHISPER_MODEL, "--host", "127.0.0.1",
         "--port", str(WHISPER_PORT), "-t", "6", "-sns"],
        stdout=logf, stderr=logf, start_new_session=True)
    with open(os.path.join(logdir, "whisper-server.pid"), "w") as f:
        f.write(str(proc.pid))
    for _ in range(60):
        time.sleep(0.5)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{WHISPER_PORT}/", timeout=2)
            break
        except urllib.error.HTTPError:
            break
        except OSError:
            continue
    else:
        die("whisper-server did not come up — see logs/whisper-server.log")
    log("whisper-server started (model stays warm)")


def stt_language():
    """Spoken-language lock: 'auto' lets whisper guess per window (can flip
    on short/noisy windows); a fixed code ('en', 'ru') stops the flips.
    Set in Settings ("stt_language") or via NERDSIDEKIQ_LANG."""
    return (os.environ.get("NERDSIDEKIQ_LANG")
            or load_settings().get("stt_language") or "auto")


def _curl_transcribe(url, path, headers):
    lang = stt_language()
    args = ["-F", f"file=@{path}", "-F", "response_format=verbose_json"]
    # whisper-server takes "auto"; the OpenAI API wants the flag omitted
    if lang != "auto" or "127.0.0.1" in url:
        args += ["-F", f"language={lang}"]
    p = subprocess.run(
        ["curl", "-sS", "--max-time", "900", url] + headers + args,
        capture_output=True, text=True)
    if p.returncode != 0:
        die(f"transcription request failed: {p.stderr[-500:]}")
    try:
        d = json.loads(p.stdout)
    except json.JSONDecodeError:
        die(f"transcription: bad response: {p.stdout[:500]}")
    if "error" in d:
        die(f"transcription: {d['error']}")
    return d


def _seg_confident(s):
    """Drop hallucinated segments (faint speaker-bleed, noise)."""
    if s.get("no_speech_prob", 0) > 0.5 or s.get("avg_logprob", 0) < -1.2:
        return False
    words = s.get("words") or []
    if words:
        avg = sum(w.get("probability", 1) for w in words) / len(words)
        if avg < 0.45:
            return False
    return True


def transcribe(path):
    """-> ([(start, end, text)], language). Local whisper-server by default."""
    if STT_MODE == "openai":
        d = _curl_transcribe("https://api.openai.com/v1/audio/transcriptions", path,
                             ["-H", f"Authorization: Bearer {openai_key()}",
                              "-F", "model=whisper-1"])
    else:
        d = _curl_transcribe(f"http://127.0.0.1:{WHISPER_PORT}/inference", path, [])
    segs = [(s["start"], s.get("end", s["start"]), s["text"].strip())
            for s in d.get("segments", [])
            if s.get("text", "").strip() and _seg_confident(s)]
    return segs, d.get("language", "")


# ---------- Claude (the user's Anthropic account) ----------

_claude = None


def claude():
    """Lazy Anthropic client. Credentials: ANTHROPIC_API_KEY /
    ANTHROPIC_AUTH_TOKEN / the `ant auth login` OAuth profile."""
    global _claude
    if _claude is None:
        try:
            import anthropic
        except ImportError:
            die("anthropic SDK not installed — run: .venv/bin/pip install anthropic")
        try:
            _claude = anthropic.Anthropic()
        except Exception as e:
            die(f"Claude auth not set up ({e}) — run: ant auth login")
    return _claude


def answer_model():
    return (os.environ.get("NERDSIDEKIQ_ANSWER_MODEL")
            or load_settings().get("answer_model") or DEFAULT_MODEL)


def rolling_model():
    return (os.environ.get("NERDSIDEKIQ_ROLLING_MODEL")
            or load_settings().get("rolling_model") or DEFAULT_MODEL)


def _claude_call(fn, what):
    import anthropic
    try:
        return fn()
    except (anthropic.AuthenticationError, TypeError):
        die(f"{what}: Claude auth not set up — run: ant auth login "
            "(or Settings → Claude Account → Authorize)")
    except anthropic.APIError as e:
        die(f"{what}: Claude API error: {e}")


def chat(model, prompt, schema=None, effort=None, max_tokens=8000):
    """One-shot Claude message -> text. With schema (JSON Schema dict) the
    reply is guaranteed valid JSON matching it (structured outputs)."""
    kwargs = {"model": model, "max_tokens": max_tokens,
              "messages": [{"role": "user", "content": prompt}]}
    output_config = {}
    if effort and "haiku" not in model:   # haiku models reject `effort`
        output_config["effort"] = effort
    if schema:
        output_config["format"] = {"type": "json_schema", "schema": schema}
    if output_config:
        kwargs["output_config"] = output_config

    def go():
        r = claude().messages.create(**kwargs)
        if r.stop_reason == "refusal":
            die(f"Claude declined the request ({model})")
        return next(b.text for b in r.content if b.type == "text").strip()

    return _claude_call(go, f"chat({model})")


def chat_stream(model, prompt, on_delta, max_tokens=8000):
    """Streaming Claude message; calls on_delta(text_piece) per chunk,
    returns the full text."""
    def go():
        full = []
        with claude().messages.stream(
                model=model, max_tokens=max_tokens,
                messages=[{"role": "user", "content": prompt}]) as stream:
            for piece in stream.text_stream:
                full.append(piece)
                on_delta(piece)
            final = stream.get_final_message()
            if final.stop_reason == "refusal":
                die(f"Claude declined the request ({model})")
        return "".join(full)

    return _claude_call(go, f"chat_stream({model})")


def load_settings():
    """settings.json in the app dir; written by the NerdSidekiq Settings window."""
    try:
        with open(os.path.join(BASE_DIR, "settings.json")) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


# ---------- Notion ----------

def notion_req(method, path, token, payload=None):
    req = urllib.request.Request(
        f"https://api.notion.com/v1/{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token}",
                 "Notion-Version": NOTION_VERSION,
                 "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:500]
            if e.code in (429, 502, 503) and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            die(f"Notion HTTP {e.code} on {path}: {body}")
        except OSError as e:
            if attempt < 2:
                time.sleep(2)
                continue
            die(f"Notion request failed: {e}")


def rt(text):
    return [{"type": "text", "text": {"content": text[:1990]}}]


def paragraphs(text):
    """Plain text -> paragraph blocks (splits on blank lines, packs <=1900)."""
    blocks = []
    for chunk in re.split(r"\n\s*\n", text.strip()):
        chunk = chunk.strip()
        while chunk:
            blocks.append({"type": "paragraph", "paragraph": {"rich_text": rt(chunk[:1900])}})
            chunk = chunk[1900:]
    return blocks


def transcript_blocks(lines):
    """Pack transcript lines into paragraphs of <=1900 chars."""
    blocks, buf = [], ""
    for line in lines:
        if len(buf) + len(line) + 1 > 1900:
            blocks.append({"type": "paragraph", "paragraph": {"rich_text": rt(buf)}})
            buf = ""
        buf += (("\n" if buf else "") + line)
    if buf:
        blocks.append({"type": "paragraph", "paragraph": {"rich_text": rt(buf)}})
    return blocks


def create_page(token, parent_id, title, icon, blocks):
    first, rest = blocks[:80], blocks[80:]
    page = notion_req("POST", "pages", token, {
        "parent": {"page_id": parent_id},
        "icon": {"type": "emoji", "emoji": icon},
        "properties": {"title": {"title": rt(title)}},
        "children": first,
    })
    while rest:
        batch, rest = rest[:80], rest[80:]
        notion_req("PATCH", f"blocks/{page['id']}/children", token, {"children": batch})
    return page


def lang_code(raw):
    return {"russian": "RU", "english": "EN"}.get((raw or "").lower(),
                                                  (raw or "??").upper()[:5])
